package web

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// oldAzdbWindowCols and sqlAzureDBSummaryMinutes: B2a's all-minutes read of one database's window (e4af7c3's
// sqlAzureDBSummary, before 0167), kept as the reference every window through pgvigil.mssql_azuredb_window must equal
var oldAzdbWindowCols = `
       sum(a.samples)::bigint AS samples, count(*) AS minutes,
       round(sum(a.avg_cpu_percent * a.samples) / nullif(sum(a.samples) FILTER (WHERE a.avg_cpu_percent IS NOT NULL), 0), 2) AS avg_cpu_percent,
       max(a.max_cpu_percent) AS max_cpu_percent,
       round(sum(a.avg_data_io_percent * a.samples) / nullif(sum(a.samples) FILTER (WHERE a.avg_data_io_percent IS NOT NULL), 0), 2) AS avg_data_io_percent,
       max(a.max_data_io_percent) AS max_data_io_percent,
       round(sum(a.avg_log_write_percent * a.samples) / nullif(sum(a.samples) FILTER (WHERE a.avg_log_write_percent IS NOT NULL), 0), 2) AS avg_log_write_percent,
       max(a.max_log_write_percent) AS max_log_write_percent,
       round(sum(a.avg_dtu_percent * a.samples) / nullif(sum(a.samples) FILTER (WHERE a.avg_dtu_percent IS NOT NULL), 0), 2) AS avg_dtu_percent,
       max(a.max_dtu_percent) AS max_dtu_percent,
       round(sum(a.avg_dtu * a.samples) / nullif(sum(a.samples) FILTER (WHERE a.avg_dtu IS NOT NULL), 0), 2) AS avg_dtu,
       max(a.max_dtu) AS max_dtu, min(a.dtu_limit) AS min_dtu_limit, max(a.dtu_limit) AS max_dtu_limit,
       max(a.dtu_limit) - max(a.max_dtu) AS unused_dtu,
       min(a.cpu_limit) AS min_cpu_limit, max(a.cpu_limit) AS max_cpu_limit,
       ` + azdbHist("cpu") + ` AS cpu_hist, ` + azdbHist("data") + ` AS data_hist, ` + azdbHist("log") + ` AS log_hist, ` + azdbHist("dtu") + ` AS dtu_hist,
       ` + azdbHot("cpu") + ` AS cpu_hot_pct, ` + azdbHot("data") + ` AS data_hot_pct, ` + azdbHot("log") + ` AS log_hot_pct, ` + azdbHot("dtu") + ` AS dtu_hot_pct`

var sqlAzureDBSummaryMinutes = `
SELECT ` + oldAzdbWindowCols + `
  FROM pgvigil.mssql_azuredb_minute a
 WHERE a.instance_id = $1 AND a.snapshot_at >= $2 AND a.snapshot_at < $3`

// TestAzureDBWindowOnAStore (B2a-N2, the review's finding 3): on a migrated repository (PGVIGIL_REPO_TEST_DSN) every
// reader's window through pgvigil.mssql_azuredb_window equals the all-minutes read, column for column, for
//   - windows: 01:23 to 27:41, inside one hour, on whole hours, ending inside the current hour, across a gap, wholly in
//     the gap (no minute: minutes 0, not NULL), inside a dirty range, the whole stored range; two of them again under a
//     +05:30 session;
//   - databases: A built from its first minute; B whose first_build row is gone (its hours stand but must not be read:
//     a window that took its hours AND its minutes counts twice); C built, with a dirty range over three hours that were
//     corrupted (a window that reads them, or that drops the dirty range's minutes, is wrong); D a store from before 0167
//     (its minutes stored with the hours' trigger held off: no hours, no first_build row, 'pgvigil purge' pending) before
//     and after its first build by heal_one (AzureDBHoursHeal's statement), after which it is no longer pending;
//   - the fleet's read (several databases in one call, as the Azure Summary) per database;
//   - the Azure tab's hours part (sqlAzureDBHours): each row carries snapshot_at = its hour (the chart's x), one row an
//     hour that has minutes, its minutes summed the window's.
//
// Broken variants it catches (each read once against the code): a window part from b.f instead of greatest(b.f, b.c)
// (a window inside one hour counts its minutes twice); the hours of an unbuilt database read (B doubled); a dirty range's
// minutes not read (C short); the dirty hours read from the hours (C corrupted); the hours part without snapshot_at.
func TestAzureDBWindowOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	sfx := time.Now().UnixNano() % 1000000000
	ids := map[string]int{}
	var all []int
	for _, n := range []string{"A", "B", "C", "D"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("azwin-%s-%d", n, sfx)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
		all = append(all, id)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_azuredb_hour WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_azuredb_read WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(context.Background(), q, all); err != nil {
				t.Error(err)
			}
		}
	}()

	now := time.Now().UTC()
	h0 := now.Truncate(time.Hour).Add(-30 * time.Hour)
	gapFrom, gapTo := h0.Add(10*time.Hour+20*time.Minute), h0.Add(11*time.Hour+40*time.Minute)
	// every figure varies by the minute's index k; every 13th minute carries no averages
	minute := func(k int) map[string]any {
		at := h0.Add(time.Duration(k) * time.Minute)
		samples := 3 + k%2
		avg := func(off int) any {
			if k%13 == 0 {
				return nil
			}
			return float64((k*7+off)%97) + 0.25
		}
		top := func(off int) float64 { return float64((k*7+off)%97) + 1.5 }
		var cpuLimit any = 2 + float64(k%2)
		if k%3 == 0 {
			cpuLimit = nil
		}
		bucket := func(off int) []int {
			b := make([]int, 10)
			b[(k+off)%10] = samples
			return b
		}
		return map[string]any{"kind": "minute", "minute": at.Format(time.RFC3339), "samples": samples,
			"avg_cpu_percent": avg(0), "max_cpu_percent": top(0), "avg_data_io_percent": avg(11), "max_data_io_percent": top(11),
			"avg_log_write_percent": avg(23), "max_log_write_percent": top(23), "avg_memory_usage_percent": avg(31), "max_memory_usage_percent": top(31),
			"max_worker_percent": float64(k%13) + 0.5, "max_session_percent": float64(k%11) + 0.75, "dtu_limit": 5 + 5*((k/30)%2), "cpu_limit": cpuLimit,
			"replica_role": k % 2, "avg_dtu_percent": avg(71), "max_dtu_percent": top(71), "avg_dtu": avg(83), "max_dtu": top(83),
			"dtu_buckets": bucket(0), "cpu_buckets": bucket(3), "data_buckets": bucket(5), "log_buckets": bucket(7)}
	}
	// the stored minutes: h0 to the minute before now, the gap left out, 60 a statement
	var batches [][]map[string]any
	var batch []map[string]any
	for k := 0; h0.Add(time.Duration(k) * time.Minute).Before(now.Truncate(time.Minute)); k++ {
		if at := h0.Add(time.Duration(k) * time.Minute); !at.Before(gapFrom) && at.Before(gapTo) {
			continue
		}
		batch = append(batch, minute(k))
		if len(batch) == 60 {
			batches = append(batches, batch)
			batch = nil
		}
	}
	if len(batch) > 0 {
		batches = append(batches, batch)
	}
	importAll := func(tx pgx.Tx, id int) {
		t.Helper()
		for _, b := range batches {
			p, _ := json.Marshal(b)
			if _, err := tx.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, now(), $2::jsonb)`, id, string(p)); err != nil {
				t.Fatal(err)
			}
		}
	}
	for _, n := range []string{"A", "B", "C", "D"} {
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if n == "D" { // a store from before 0167: the hours' trigger held off inside the transaction (a failure rolls it back)
			if _, err := tx.Exec(ctx, `ALTER TABLE pgvigil.mssql_azuredb_minute DISABLE TRIGGER mssql_azuredb_hour_ins`); err != nil {
				t.Fatal(err)
			}
		}
		importAll(tx, ids[n])
		if n == "D" {
			if _, err := tx.Exec(ctx, `ALTER TABLE pgvigil.mssql_azuredb_minute ENABLE TRIGGER mssql_azuredb_hour_ins`); err != nil {
				t.Fatal(err)
			}
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
	// B: unbuilt with its hours standing; C: three hours corrupted and their range dirty
	if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.mssql_azuredb_hour_first_build WHERE instance_id = $1`, ids["B"]); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.mssql_azuredb_hour SET minutes = 0, samples = 0, cpu_total = 0, cpu_counted = 0, max_cpu_percent = 0
	                              WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $3`, ids["C"], h0.Add(5*time.Hour), h0.Add(8*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_azuredb_hour_dirty (instance_id, from_at, to_at, why) VALUES ($1, $2, $3, 'the test')`,
		ids["C"], h0.Add(5*time.Hour), h0.Add(8*time.Hour)); err != nil {
		t.Fatal(err)
	}
	var built int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_azuredb_hour WHERE instance_id = $1`, ids["D"]).Scan(&built); err != nil || built != 0 {
		t.Fatalf("D (a store from before 0167) has %d hour rows (%v), want none", built, err)
	}

	// one window: the new read against the reference, key by key (jsonb compares numbers by value)
	compare := func(q queryer, what, newSQL, oldSQL string, args ...any) {
		t.Helper()
		var bad string
		if err := q.QueryRow(ctx, `
WITH n AS (`+newSQL+`), o AS (`+oldSQL+`)
SELECT coalesce(string_agg(format('%s: window %s, minutes %s', d.key, d.nv, d.ov), '; ' ORDER BY d.key), '')
  FROM (SELECT coalesce(x.key, y.key) AS key, x.value AS nv, y.value AS ov
          FROM jsonb_each(coalesce((SELECT to_jsonb(n) - 'instance_id' FROM n), '{}')) x
          FULL JOIN jsonb_each(coalesce((SELECT to_jsonb(o) - 'instance_id' FROM o), '{}')) y ON y.key = x.key
         WHERE x.value IS DISTINCT FROM y.value) d`, args...).Scan(&bad); err != nil {
			t.Fatalf("%s: %v", what, err)
		}
		if bad != "" {
			t.Errorf("%s: %s", what, bad)
		}
	}
	// the fleet's read, one database of it, against the all-minutes fleet read (a database with no minute in the window
	// has no row in either)
	fleetOne := `SELECT * FROM (SELECT a.instance_id, ` + azdbWindowCols + `
  FROM pgvigil.mssql_azuredb_window($4::int[], $2, $3) a GROUP BY a.instance_id) f WHERE f.instance_id = $1`
	fleetOneOld := `SELECT * FROM (SELECT a.instance_id, ` + oldAzdbWindowCols + `
  FROM pgvigil.mssql_azuredb_minute a WHERE a.instance_id = ANY ($4::int[]) AND a.snapshot_at >= $2 AND a.snapshot_at < $3 GROUP BY a.instance_id) f
 WHERE f.instance_id = $1`
	type window struct {
		name     string
		from, to time.Time
	}
	windows := []window{
		{"01:23 to 27:41", h0.Add(time.Hour + 23*time.Minute), h0.Add(27*time.Hour + 41*time.Minute)},
		{"inside one hour", h0.Add(9*time.Hour + 10*time.Minute), h0.Add(9*time.Hour + 50*time.Minute)},
		{"on whole hours", h0.Add(2 * time.Hour), h0.Add(20 * time.Hour)},
		{"ending inside the current hour", h0.Add(3*time.Hour + 17*time.Minute), now},
		{"across the gap", h0.Add(9*time.Hour + 30*time.Minute), h0.Add(12*time.Hour + 30*time.Minute)},
		{"wholly in the gap", h0.Add(10*time.Hour + 30*time.Minute), h0.Add(11*time.Hour + 30*time.Minute)},
		{"inside the dirty range", h0.Add(5*time.Hour + 30*time.Minute), h0.Add(7*time.Hour + 30*time.Minute)},
		{"the whole stored range", h0, now},
	}
	run := func(q queryer, stage string, names []string, ws []window) {
		t.Helper()
		for _, n := range names {
			for _, w := range ws {
				what := fmt.Sprintf("%s: database %s, %s", stage, n, w.name)
				compare(q, what, sqlAzureDBSummary, sqlAzureDBSummaryMinutes, ids[n], w.from, w.to)
				compare(q, what+" (the fleet's read)", fleetOne, fleetOneOld, ids[n], w.from, w.to, all)
			}
		}
	}
	run(pool, "first", []string{"A", "B", "C", "D"}, windows)
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `SET TimeZone = 'Asia/Kolkata'`); err != nil {
		t.Fatal(err)
	}
	run(conn, "under Asia/Kolkata", []string{"A", "C"}, []window{windows[0], windows[3]})
	conn.Release()

	// D's first build by 'pgvigil purge' (AzureDBHoursHeal's statement for one instance), then the same windows
	pending := func() bool {
		t.Helper()
		var p bool
		if err := pool.QueryRow(ctx, `SELECT $1::int IN (SELECT i FROM pgvigil.mssql_azuredb_hour_pending() i)`, ids["D"]).Scan(&p); err != nil {
			t.Fatal(err)
		}
		return p
	}
	if !pending() {
		t.Error("D (minutes from before 0167, no first_build row) is not pending for pgvigil purge")
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.mssql_azuredb_hour_heal_one($1)`, ids["D"]); err != nil {
		t.Fatal(err)
	}
	if pending() {
		t.Error("D is still pending after its first build")
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_azuredb_hour WHERE instance_id = $1`, ids["D"]).Scan(&built); err != nil || built < 30 {
		t.Errorf("D after its first build: %d hour rows (%v), want at least 30", built, err)
	}
	run(pool, "after D's first build", []string{"D"}, windows)

	// the Azure tab's hours part: snapshot_at on every row (the chart's x: lineChart reads r.snapshot_at), equal to the
	// hour; one row per hour that has minutes in the window; the minutes summed the window's
	w := windows[0]
	rows, err := pool.Query(ctx, `SELECT hour, snapshot_at, minutes FROM (`+sqlAzureDBHours+`) h`, ids["A"], w.from, w.to)
	if err != nil {
		t.Fatal(err)
	}
	var nrows, nmin int
	for rows.Next() {
		var hour, at *time.Time
		var mins int32
		if err := rows.Scan(&hour, &at, &mins); err != nil {
			t.Fatal(err)
		}
		nrows++
		nmin += int(mins)
		if hour == nil || at == nil || !hour.Equal(*at) {
			t.Errorf("an hours row: hour %v, snapshot_at %v, want both, equal", hour, at)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	var wantRows, wantMin int
	if err := pool.QueryRow(ctx, `SELECT count(DISTINCT date_trunc('hour', snapshot_at AT TIME ZONE 'UTC')), count(*) FROM pgvigil.mssql_azuredb_minute
	                               WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $3`, ids["A"], w.from, w.to).Scan(&wantRows, &wantMin); err != nil {
		t.Fatal(err)
	}
	if nrows != wantRows || nmin != wantMin {
		t.Errorf("the hours part over %s: %d rows and %d minutes, want %d and %d", w.name, nrows, nmin, wantRows, wantMin)
	}
}

// queryer: a pool or one connection of it (a session's time zone)
type queryer interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}
