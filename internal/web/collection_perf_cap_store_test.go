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

// TestCollectionPerfCapOrderOnAStore (J5 after the index, the lead's 16:0x (a): 'a cap that keeps the wrong 5,001 is a
// wrong page'; a box row: PGVIGIL_REPO_TEST_DSN): the capped rows read (pgvigil.collection_perf_rows, walking the range
// newest first and stopping at the cap) equals the whole-range form ROW FOR ROW - every column, in order - for every
// scope (the root, one collection, one instance, an instance list) and cap (0, 1, 5, 17, 60, 10000), over two ranges:
// one to now from a time inside an hour, one that ends inside an hour in the past. The seed, in one transaction rolled
// back: three active instances whose names sort against their ids (b, a, c inserted in that order) and one inactive,
// two collections, 10 hours of hour rows (two collectors on even hours, so the sums count), and runs - failed and
// partial, one exactly at an hour's start (beside that hour's Hour row: 'Hour' sorts first), one in the range's first
// partial hour, one a second before an hour ends - with a skipped run, a job statistics rollup run and the inactive
// instance's runs, which neither read shows.
func TestCollectionPerfCapOrderOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
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
	ranges := map[string][2]time.Time{
		"to now, from inside an hour": {base.Add(-7*time.Hour - 20*time.Minute), now},
		"ending inside a past hour":   {base.Add(-9 * time.Hour), base.Add(-4*time.Hour + 10*time.Minute)},
	}
	scopes := map[string][3]any{
		"the root":         {0, nil, ""},
		"one collection":   {0, nil, ca},
		"one instance":     {int(ids["a"]), nil, ""},
		"an instance list": {0, []int32{ids["a"], ids["c"]}, cb},
	}
	for rn, rg := range ranges {
		for sn, sc := range scopes {
			for _, cap := range []int{0, 1, 5, 17, 60, 10000} {
				args := []any{rg[0], rg[1], sc[0], sc[1], sc[2], cap}
				want, got := read(sqlCollPerfRowsWhole, args), read(sqlCollPerfRows, args)
				if len(want) == 0 {
					t.Fatalf("%s, %s, cap %d: the whole-range form reads no row (the seed?)", rn, sn, cap)
				}
				if strings.Join(got, "\n") != strings.Join(want, "\n") {
					n := 0
					for n < len(got) && n < len(want) && got[n] == want[n] {
						n++
					}
					g, w := "<none>", "<none>"
					if n < len(got) {
						g = got[n]
					}
					if n < len(want) {
						w = want[n]
					}
					t.Errorf("%s, %s, cap %d: %d row(s), want %d; first difference at row %d:\n got  %s\n want %s", rn, sn, cap, len(got), len(want), n+1, g, w)
				}
			}
		}
	}
}
