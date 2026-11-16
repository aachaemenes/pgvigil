package web

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// sqlCollPerfRowsWhole: the Collection Performance rows read as it was before J5 (the whole range aggregated, then
// sorted and cut) - the oracle TestCollectionPerfCapOrderOnAStore holds the capped read to
var sqlCollPerfRowsWhole = `
WITH h AS (
  SELECT h.hour AS at, h.instance_id, h.collection, 'Hour'::text AS period, NULL::text AS outcome, NULL::text AS stage,
         sum(h.runs)::bigint AS runs, sum(h.failed)::bigint AS failed, sum(h.partial)::bigint AS partial,
         round(sum(h.dur_ms_sum)::numeric / nullif(sum(h.ok + h.partial + h.failed), 0))::bigint AS duration_ms,
         max(h.dur_ms_max)::bigint AS max_duration_ms,
         round(sum(h.cpu_ms_sum)::numeric / nullif(sum(h.cpu_runs), 0))::bigint AS cpu_ms,
         round(sum(h.reads_sum)::numeric / nullif(sum(h.cpu_runs), 0))::bigint AS logical_reads,
         round(sum(h.import_ms_sum)::numeric / nullif(sum(h.import_runs), 0))::bigint AS import_ms
    FROM pgvigil.collection_health_hour h
   WHERE h.hour >= date_trunc('hour', $1::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AND h.hour < $2::timestamptz
     AND ` + chScopeOf("h") + `
   GROUP BY h.hour, h.instance_id, h.collection
), r AS (
  SELECT l.snapshot_at, l.instance_id, l.collection, 'Run'::text,
         CASE l.status WHEN 'error' THEN 'Failed' ELSE 'Partial' END, (pgvigil.collection_error_class(l.status, l.note, l.stage)).error_stage,
         1::bigint, (l.status = 'error')::int::bigint, (l.status = 'partial')::int::bigint,
         l.duration_ms::bigint, l.duration_ms::bigint, NULL::bigint, NULL::bigint, NULL::bigint
    FROM pgvigil.collection_log l
   WHERE l.status IN ('error', 'partial') AND l.collection <> 'job_stats_hourly'
     AND l.snapshot_at >= $1::timestamptz AND l.snapshot_at < $2::timestamptz AND ` + chScopeOf("l") + `
)
SELECT x.at, x.instance_id, i.name AS instance, i.engine, x.collection, x.period, x.outcome, x.stage, x.runs, x.failed, x.partial,
       x.duration_ms, x.max_duration_ms, x.cpu_ms, x.logical_reads, x.import_ms
  FROM (SELECT * FROM h UNION ALL SELECT * FROM r) x
  JOIN pgvigil.instances i ON i.instance_id = x.instance_id AND i.is_active
 ORDER BY x.at DESC, i.name, x.collection, x.period
 LIMIT $6::int + 1`

// sqlCollPerfRowsOwn: the function's own rows, unsorted and uncut (the review of J5 (a) #1: the caller sorts and cuts
// again, so a function that ignored its cap read right through sqlCollPerfRows)
var sqlCollPerfRowsOwn = `SELECT * FROM pgvigil.collection_perf_rows($1::timestamptz, $2::timestamptz, $3::int, $4::int[], coalesce($5::text, ''), $6::int)`

// TestCollectionPerfCapOrderOnAStore (J5 after the index (a): 'a cap that keeps the wrong 5,001 is a
// wrong page'; a box row: PGVIGIL_REPO_TEST_DSN): the capped rows read (pgvigil.collection_perf_rows, walking the range
// newest first and stopping at the cap) equals the whole-range form ROW FOR ROW - every column, in order - for every
// scope (the root, one collection, one instance, an instance list) and cap (0, 1, 5, 17, 60, 10000), over five ranges:
// one to now from a time inside an hour, one that ends inside a past hour, one ending on an hour, one under an hour and
// one with no row (zero from every read). Both as the page reads it (sqlCollPerfRows) and the function's OWN rows as it
// emits them, unsorted and uncut: exactly min(the whole range's rows, cap + 1), in the page's order (the review of J5
// (a) #1). Every case twice: in the session's own zone and under Asia/Kolkata (5:30 from UTC: the review's #3). The
// seed, in one transaction rolled back: three active instances whose names sort against their ids (b, a, c inserted in
// that order) and one inactive, two collections, 10 hours of hour rows (two collectors on even hours, so the sums
// count), and runs - failed and partial, one exactly at an hour's start (beside that hour's Hour row: 'Hour' sorts
// first), one in the range's first partial hour, one a second before an hour ends, one before the first range's start
// inside its first hour and one after the second range's end inside its hour (neither shown by the range it borders:
// the review's #2) -
// with a skipped run, a job statistics rollup run and the inactive instance's runs, which neither read shows. Then
// each of five MUTANTS planted in the store (the function's text from pg_get_functiondef, exactly one fragment changed,
// rolled back after) must be caught by the function's own rows: the window's LIMIT without the rows already out, no
// row count, the runs read from the window's start (not p_from), the first window an hour late, the first hour in the
// session's zone. And the function's two guards: plan_cache_mode = force_custom_plan set on it (the review's #4: the
// window statement is one cached plan run up to 11 times a call, the serve's setting lost behind a PgBouncer that drops
// it), and a NULL bound read as nothing (#5: a NULL p_from walked back through all of history - the two p_from rows
// fail on the guard without its NULL terms; the p_to and p_cap rows are kept as regression rows, passing either way).
func TestCollectionPerfCapOrderOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := tx.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", strings.Fields(sql)[0], err)
		}
	}
	tag := time.Now().UnixNano() % 1000000000
	ids := map[string]int32{}
	for _, key := range []string{"b", "a", "c", "z"} {
		var id int32
		if err := tx.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}'::text[], 'postgres')`,
			fmt.Sprintf("cpo-%d-%s", tag, key)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[key] = id
	}
	exec(`UPDATE pgvigil.instances SET is_active = false WHERE instance_id = $1`, ids["z"])
	ca, cb := fmt.Sprintf("cpoA%d", tag), fmt.Sprintf("cpoB%d", tag)
	base := time.Now().UTC().Truncate(time.Hour)
	for k := 0; k <= 9; k++ {
		hr := base.Add(-time.Duration(k) * time.Hour)
		for _, key := range []string{"b", "a", "c", "z"} {
			for ci, coll := range []string{ca, cb} {
				for _, col := range []string{"c1", "c2"} {
					if col == "c2" && k%2 == 1 {
						continue
					}
					runs := 10 + k + ci
					exec(`INSERT INTO pgvigil.collection_health_hour (hour, instance_id, collection, collector_id, runs, ok, partial, failed, skipped,
					         rows_written, dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s, last_ok_at, last_failure_at,
					         import_failed, import_runs, import_ms_sum, import_ms_max, cpu_runs, cpu_ms_sum, cpu_ms_max, reads_sum)
					  VALUES ($1, $2, $3, $4, $5, $5 - 2, 1, 1, 0, 5, $5 * 37, 90 + $6, 0, 0, 60, $1, $1, 0, $5, $5 * 3, 9, $5, $5 * 2, 7, $5 * 100)`,
						hr, ids[key], coll, col, runs, k)
				}
			}
		}
	}
	run := func(key, coll, status string, at time.Time) {
		exec(`INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, duration_ms, status, note)
		      VALUES ($1, $2, $3, 120, $4, 'cpo: ' || $4)`, ids[key], coll, at, status)
	}
	for _, key := range []string{"a", "b", "c", "z"} {
		run(key, ca, "error", base.Add(-3*time.Hour))                // exactly at an hour's start
		run(key, ca, "error", base.Add(-3*time.Hour+17*time.Minute)) // inside the hour
		run(key, cb, "partial", base.Add(-5*time.Hour-time.Second))  // a second before an hour ends
		run(key, cb, "error", base.Add(-7*time.Hour-10*time.Minute)) // the first range's first partial hour
		for _, coll := range []string{ca, cb} {
			run(key, coll, "error", base.Add(-7*time.Hour-25*time.Minute)) // before the first range's start, inside its first hour
			run(key, coll, "error", base.Add(-4*time.Hour+30*time.Minute)) // after the second range's end, inside its hour
		}
		run(key, ca, "partial", base.Add(-1*time.Hour+30*time.Minute))
		run(key, ca, "skipped", base.Add(-2*time.Hour+5*time.Minute))                     // never a row
		run(key, "job_stats_hourly", "error", base.Add(-2*time.Hour+6*time.Minute))       // never a row
		run(key, cb, "error", time.Now().UTC().Add(-2*time.Second).Truncate(time.Second)) // the newest hour
	}
	read := func(sql string, args []any) []string {
		t.Helper()
		rs, err := tx.Query(ctx, sql, args...)
		if err != nil {
			t.Fatalf("the read: %v", err)
		}
		out, err := pgx.CollectRows(rs, func(row pgx.CollectableRow) (string, error) {
			v, err := row.Values()
			return fmt.Sprint(v...), err
		})
		if err != nil {
			t.Fatalf("the read: %v", err)
		}
		return out
	}
	now := time.Now().UTC()
	ranges := []struct {
		name     string
		from, to time.Time
		empty    bool
	}{
		{"to now, from inside an hour", base.Add(-7*time.Hour - 20*time.Minute), now, false},
		{"ending inside a past hour", base.Add(-9 * time.Hour), base.Add(-4*time.Hour + 10*time.Minute), false},
		{"ending on an hour", base.Add(-3 * time.Hour), base.Add(-1 * time.Hour), false},
		{"under an hour", base.Add(-3*time.Hour + 5*time.Minute), base.Add(-3*time.Hour + 40*time.Minute), false},
		{"with no row", base.Add(-30 * time.Hour), base.Add(-29 * time.Hour), true},
	}
	scopes := []struct {
		name string
		sc   [3]any
	}{
		{"the root", [3]any{0, nil, ""}},
		{"one collection", [3]any{0, nil, ca}},
		{"one instance", [3]any{int(ids["a"]), nil, ""}},
		{"an instance list", [3]any{0, []int32{ids["a"], ids["c"]}, cb}},
	}
	var zone string
	if err := tx.QueryRow(ctx, `SHOW TimeZone`).Scan(&zone); err != nil {
		t.Fatal(err)
	}
	// check: every case in both zones; report = false counts the cases each read differs in (a mutant's run)
	check := func(report bool) (own, page, cases int) {
		t.Helper()
		for _, z := range []string{zone, "Asia/Kolkata"} {
			exec(`SELECT set_config('TimeZone', $1, true)`, z)
			for _, rg := range ranges {
				for _, sp := range scopes {
					for _, cap := range []int{0, 1, 5, 17, 60, 10000} {
						cases++
						args := []any{rg.from, rg.to, sp.sc[0], sp.sc[1], sp.sc[2], cap}
						want := read(sqlCollPerfRowsWhole, args)
						reads := []struct {
							name string
							rows []string
							n    *int
						}{{"the page's read", read(sqlCollPerfRows, args), &page}, {"the function's own rows", read(sqlCollPerfRowsOwn, args), &own}}
						if report && rg.empty != (len(want) == 0) {
							t.Fatalf("%s, %s, %s, cap %d: the whole-range form reads %d row(s) (the seed?)", z, rg.name, sp.name, cap, len(want))
						}
						for _, r := range reads {
							if strings.Join(r.rows, "\n") == strings.Join(want, "\n") {
								continue
							}
							*r.n++
							if !report {
								continue
							}
							n := 0
							for n < len(r.rows) && n < len(want) && r.rows[n] == want[n] {
								n++
							}
							g, w := "<none>", "<none>"
							if n < len(r.rows) {
								g = r.rows[n]
							}
							if n < len(want) {
								w = want[n]
							}
							t.Errorf("%s, %s, %s, cap %d, %s: %d row(s), want %d; first difference at row %d:\n got  %s\n want %s",
								z, rg.name, sp.name, cap, r.name, len(r.rows), len(want), n+1, g, w)
						}
					}
				}
			}
		}
		exec(`SELECT set_config('TimeZone', $1, true)`, zone)
		return own, page, cases
	}
	if own, page, cases := check(true); own+page == 0 {
		t.Logf("J5a: %d cases (5 ranges x 4 scopes x 6 caps x 2 zones), the page's read and the function's own rows equal to the whole-range form", cases)
	}

	// the mutants: each one fragment of the function's text changed, planted in a savepoint, rolled back after
	const sig = `'pgvigil.collection_perf_rows(timestamptz, timestamptz, int, int[], text, int)'::regprocedure`
	var def string
	if err := tx.QueryRow(ctx, `SELECT pg_get_functiondef(`+sig+`)`).Scan(&def); err != nil {
		t.Fatal(err)
	}
	for _, m := range []struct{ name, from, to string }{
		{"the window's LIMIT without the rows already out", `LIMIT p_cap + 1 - v_out;`, `LIMIT p_cap + 1;`},
		{"no row count", `GET DIAGNOSTICS v_got = ROW_COUNT;`, `v_got := 0;`},
		{"the runs from the window's start", `l.snapshot_at >= greatest(v_lo, p_from)`, `l.snapshot_at >= v_lo`},
		{"the first window an hour late", `(p_to - interval '1 microsecond') AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'`,
			`(p_to - interval '1 microsecond') AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' + interval '1 hour'`},
		{"the first hour in the session's zone", `date_trunc('hour', p_from AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'`, `date_trunc('hour', p_from)`},
	} {
		if c := strings.Count(def, m.from); c != 1 {
			t.Errorf("mutant %q NOT PLANTED: its fragment is in the function %d time(s)", m.name, c)
			continue
		}
		exec(`SAVEPOINT j5a_mutant`)
		exec(strings.Replace(def, m.from, m.to, 1))
		own, page, cases := check(false)
		exec(`ROLLBACK TO SAVEPOINT j5a_mutant`)
		t.Logf("J5a mutant %q: the function's own rows differ in %d of %d cases, the page's read in %d", m.name, own, cases, page)
		if own == 0 {
			t.Errorf("mutant %q NOT CAUGHT: the function's own rows equal the whole-range form in all %d cases", m.name, cases)
		}
	}
	if own, page, _ := check(false); own+page != 0 {
		t.Errorf("after the mutants were rolled back the reads still differ (own %d, page %d)", own, page)
	}

	// the review's #4: the function sets plan_cache_mode itself
	var conf string
	if err := tx.QueryRow(ctx, `SELECT coalesce(array_to_string(proconfig, ','), '') FROM pg_proc WHERE oid = `+sig).Scan(&conf); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(conf, "plan_cache_mode=force_custom_plan") {
		t.Errorf("collection_perf_rows' own settings %q: no plan_cache_mode=force_custom_plan (a generic plan of the window statement reads the hour-led key with the scope as a filter)", conf)
	}
	// the review's #5: a NULL bound or cap reads nothing, at once (each call in a savepoint under a 5 s statement timeout)
	for _, c := range []struct {
		name string
		args []any
	}{
		{"p_from NULL", []any{nil, now, 0, nil, "", 5}},
		{"p_from NULL, cap 10000", []any{nil, now, 0, nil, "", 10000}},
		{"p_to NULL", []any{base.Add(-3 * time.Hour), nil, 0, nil, "", 5}},
		{"p_cap NULL", []any{base.Add(-3 * time.Hour), now, 0, nil, "", nil}},
	} {
		exec(`SAVEPOINT j5a_null`)
		exec(`SET LOCAL statement_timeout = '5s'`)
		var n int
		err := tx.QueryRow(ctx, `SELECT count(*) FROM pgvigil.collection_perf_rows($1::timestamptz, $2::timestamptz, $3::int, $4::int[], $5::text, $6::int)`, c.args...).Scan(&n)
		exec(`ROLLBACK TO SAVEPOINT j5a_null`)
		if err != nil || n != 0 {
			t.Errorf("%s: %d row(s), err %v; want 0 rows and no error", c.name, n, err)
		}
	}
}
