package web

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestCollectionPerfOnAStore (B6g-3, N42, design G4; a box row: PGVIGIL_REPO_TEST_DSN): DBA Dash's Collection Performance
// report (CollectionPerformance_Get.sql) over pgvigil's two sources, in one transaction rolled back:
//   - an Hour row per instance, collection and hour, summed over the collectors that wrote it (s1's hour h from c1 and
//     c2): Runs, Failed (the import's too, as DBA Dash's FailedCount + ImportFailedCount), Partial, the duration's
//     average over the runs that ran (skips left out) and its highest, the CPU and logical reads over the runs that read
//     their session, the import over the runs that wrote or tried to;
//   - a Run row per failed or partial run of collection_log (pgvigil logs no ok run one by one: the design's (iv)
//     CHANGED) - a skip and the job statistics' rollup rows (0139's 'job_stats_hourly') left out;
//   - a collection with ok runs only (p's): its Hour row and no Run row (G4's red variant);
//   - the newest first, a cap of $6 rows read as $6 + 1 so the page can say the cap was hit;
//   - the charts' hours over every instance in scope; the meta part's hourly retention (8 days by default) and the
//     hour it keeps from.
func TestCollectionPerfOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
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
	tag := time.Now().UnixNano() % 1000000000
	coll := fmt.Sprintf("cperf%d", tag)
	ids := map[string]int32{}
	for key, engine := range map[string]string{"s1": "sqlserver", "p": "postgres"} {
		var id int32
		if err := tx.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}'::text[], $2)`,
			fmt.Sprintf("cperf-%s-%d", key, tag), engine).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[key] = id
	}
	s1, p := ids["s1"], ids["p"]
	h := time.Now().UTC().Truncate(time.Hour).Add(-2 * time.Hour)
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collection_health_hour (hour, instance_id, collection, collector_id, runs, ok, partial, failed, skipped,
	         rows_written, dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s, last_ok_at, last_failure_at,
	         import_failed, import_runs, import_ms_sum, import_ms_max, cpu_runs, cpu_ms_sum, cpu_ms_max, reads_sum)
	  VALUES ($1, $3, $5, 'c1', 7, 4, 1, 1, 1, 10, 600, 300, 0, 0, 60, $1, $1, 1, 6, 60, 30, 5, 50, 20, 5000),
	         ($1, $3, $5, 'c2', 4, 4, 0, 0, 0, 10, 400, 150, 0, 0, 60, $1, NULL, 0, 4, 40, 25, 4, 30, 9, 3000),
	         ($2, $3, $5, 'c1', 2, 2, 0, 0, 0, 2, 50, 30, 0, 0, 60, $2, NULL, 0, 2, 8, 5, 2, 10, 6, 200),
	         ($1, $4, $5, 'c1', 5, 5, 0, 0, 0, 5, 250, 80, 0, 0, 60, $1, NULL, 0, 5, 25, 9, 0, 0, 0, 0)`,
		h, h.Add(time.Hour), s1, p, coll); err != nil {
		t.Fatalf("the hour rows: %v", err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, duration_ms, status, note)
	  VALUES ($1, $2, $3::timestamptz + interval '10 minutes', 120, 'error', 'proof: boom'),
	         ($1, $2, $3::timestamptz + interval '20 minutes', 90, 'partial', 'proof: one part refused'),
	         ($1, $2, $3::timestamptz + interval '30 minutes', NULL, 'skipped', 'proof: skipped'),
	         ($1, 'job_stats_hourly', $3::timestamptz + interval '40 minutes', 5, 'error', 'proof: rollup failed')`, s1, coll, h); err != nil {
		t.Fatalf("the log rows: %v", err)
	}
	from, to := h.Add(-time.Hour), h.Add(2*time.Hour)
	hm := func(d time.Duration) string { return h.Add(d).Format("15:04") }
	read := func(id int32, cap int, c string) string {
		t.Helper()
		rs, err := tx.Query(ctx, `SELECT concat_ws('|', CASE r.instance_id WHEN $7 THEN 's1' WHEN $8 THEN 'p' ELSE 'other' END,
		           CASE WHEN r.collection = $9 THEN 'c' ELSE r.collection END, to_char(r.at AT TIME ZONE 'UTC', 'HH24:MI'), r.period,
		           coalesce(r.outcome, '-'), r.runs, r.failed, r.partial, coalesce(r.duration_ms::text, '-'), coalesce(r.max_duration_ms::text, '-'),
		           coalesce(r.cpu_ms::text, '-'), coalesce(r.logical_reads::text, '-'), coalesce(r.import_ms::text, '-'), r.engine)
		      FROM (`+sqlCollPerfRows+"\n"+`) r`, from, to, id, []int32{s1, p}, c, cap, s1, p, coll)
		if err != nil {
			t.Fatalf("the report's rows: %v", err)
		}
		defer rs.Close()
		var out []string
		for rs.Next() {
			var v string
			if err := rs.Scan(&v); err != nil {
				t.Fatal(err)
			}
			out = append(out, v)
		}
		if err := rs.Err(); err != nil {
			t.Fatalf("the report's rows: %v", err)
		}
		return strings.Join(out, " ; ")
	}
	all := strings.Join([]string{
		"s1|c|" + hm(time.Hour) + "|Hour|-|2|0|0|25|30|5|100|4|sqlserver",
		"s1|c|" + hm(20*time.Minute) + "|Run|Partial|1|0|1|90|90|-|-|-|sqlserver",
		"s1|c|" + hm(10*time.Minute) + "|Run|Failed|1|1|0|120|120|-|-|-|sqlserver",
		"p|c|" + hm(0) + "|Hour|-|5|0|0|50|80|-|-|5|postgres", // ok runs only: its hour, no Run row
		"s1|c|" + hm(0) + "|Hour|-|11|1|1|100|300|9|889|10|sqlserver",
	}, " ; ")
	if got := read(0, 5000, coll); got != all {
		t.Errorf("the collection on both instances:\n got %s\nwant %s", got, all)
	}
	// every collection of the two: the same rows - the skip and the job statistics' rollup row are no Run row
	if got := read(0, 5000, ""); got != all {
		t.Errorf("every collection of the two:\n got %s\nwant %s", got, all)
	}
	// one instance
	if got, want := read(s1, 5000, coll), strings.Join([]string{
		"s1|c|" + hm(time.Hour) + "|Hour|-|2|0|0|25|30|5|100|4|sqlserver",
		"s1|c|" + hm(20*time.Minute) + "|Run|Partial|1|0|1|90|90|-|-|-|sqlserver",
		"s1|c|" + hm(10*time.Minute) + "|Run|Failed|1|1|0|120|120|-|-|-|sqlserver",
		"s1|c|" + hm(0) + "|Hour|-|11|1|1|100|300|9|889|10|sqlserver"}, " ; "); got != want {
		t.Errorf("instance s1:\n got %s\nwant %s", got, want)
	}
	// the cap: 2 asked, 3 read (the newest), so the page can say it was hit
	if got := strings.Count(read(0, 2, coll), " ; ") + 1; got != 3 {
		t.Errorf("a cap of 2: %d row(s) read, want 3 (the cap + 1)", got)
	}
	// the charts: per hour over every instance in scope
	var charts string
	if err := tx.QueryRow(ctx, `SELECT string_agg(concat_ws('|', to_char(c.at AT TIME ZONE 'UTC', 'HH24:MI'), c.succeeded, c.partial, c.failed,
	           c.collect_avg_ms, c.collect_max_ms, c.import_avg_ms, c.import_max_ms, coalesce(c.cpu_avg_ms::text, '-'), coalesce(c.cpu_max_ms::text, '-'),
	           coalesce(c.reads_avg::text, '-')), ' ; ' ORDER BY c.at)
	      FROM (`+sqlCollPerfCharts+"\n"+`) c`, from, to, 0, []int32{s1, p}, coll).Scan(&charts); err != nil {
		t.Fatalf("the report's charts: %v", err)
	}
	if want := hm(0) + "|13|1|1|83|300|8|30|9|20|889 ; " + hm(time.Hour) + "|2|0|0|25|30|4|5|5|6|100"; charts != want {
		t.Errorf("the charts:\n got %s\nwant %s", charts, want)
	}
	// the review of B6g-3 #7: the range's edges and an inactive instance - an hour row at h-2h read from h-90m (its hour
	// holds the start: in), one at h+2h and a log row at h+2h (the end: out), a log row a second before the start (out),
	// an inactive instance's hour and error rows (never listed); the charts over p alone (no CPU read: '-')
	var off int32
	if err := tx.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}'::text[], 'sqlserver')`, fmt.Sprintf("cperf-off-%d", tag)).Scan(&off); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `UPDATE pgvigil.instances SET is_active = false WHERE instance_id = $1`, off); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collection_health_hour (hour, instance_id, collection, collector_id, runs, ok, partial, failed, skipped,
	         rows_written, dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s, last_ok_at, last_failure_at)
	  VALUES ($1::timestamptz - interval '2 hours', $2, $4, 'c1', 1, 1, 0, 0, 0, 1, 7, 7, 0, 0, 60, $1, NULL),
	         ($1::timestamptz + interval '2 hours', $2, $4, 'c1', 1, 1, 0, 0, 0, 1, 7, 7, 0, 0, 60, $1, NULL),
	         ($1, $3, $4, 'c1', 1, 0, 0, 1, 0, 0, 7, 7, 0, 0, 60, NULL, $1)`, h, s1, off, coll); err != nil {
		t.Fatalf("the edge hour rows: %v", err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, duration_ms, status, note)
	  VALUES ($1, $3, $4::timestamptz + interval '2 hours', 5, 'error', 'proof: at the end'),
	         ($1, $3, $4::timestamptz - interval '90 minutes' - interval '1 second', 5, 'error', 'proof: before the start'),
	         ($2, $3, $4::timestamptz + interval '5 minutes', 5, 'error', 'proof: an inactive instance')`, s1, off, coll, h); err != nil {
		t.Fatalf("the edge log rows: %v", err)
	}
	from, to = h.Add(-90*time.Minute), h.Add(2*time.Hour)
	if got, want := read(0, 5000, coll), strings.Join(append(strings.Split(all, " ; "), "s1|c|"+hm(-2*time.Hour)+"|Hour|-|1|0|0|7|7|-|-|-|sqlserver"), " ; "); got != want {
		t.Errorf("the edges (from h-90m, to h+2h) with an inactive instance:\n got %s\nwant %s", got, want)
	}
	var pcharts string
	if err := tx.QueryRow(ctx, `SELECT string_agg(concat_ws('|', c.succeeded, coalesce(c.cpu_max_ms::text, '-')), ' ; ' ORDER BY c.at)
	      FROM (`+sqlCollPerfCharts+"\n"+`) c`, h.Add(-time.Hour), h.Add(2*time.Hour), 0, []int32{p}, coll).Scan(&pcharts); err != nil {
		t.Fatalf("the charts over p: %v", err)
	}
	if pcharts != "5|-" {
		t.Errorf("the charts over p alone: %s, want 5|- (no session read: no CPU, never 0)", pcharts)
	}
	// the review of B6g-3 #2: the first hour kept is the trim's own - hour rows at the edge of the retention, the trim
	// run (import_collection_health), then kept_from must be the oldest hour left
	var days int
	if err := tx.QueryRow(ctx, `SELECT m.days FROM (`+sqlCollPerfMeta+"\n"+`) m`).Scan(&days); err != nil {
		t.Fatalf("the report's meta: %v", err)
	}
	edge := time.Now().UTC().Add(-time.Duration(days) * 24 * time.Hour).Truncate(time.Hour)
	for _, d := range []time.Duration{-time.Hour, 0, time.Hour, 2 * time.Hour} {
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collection_health_hour (hour, instance_id, collection, collector_id, runs, ok, partial, failed, skipped,
		         rows_written, dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s) VALUES ($1, $2, $3, 'edge', 1, 1, 0, 0, 0, 0, 1, 1, 0, 0, 60)`,
			edge.Add(d), p, coll+"-edge"); err != nil {
			t.Fatalf("the retention edge rows: %v", err)
		}
	}
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collection_health('edge', '{}'::jsonb)`); err != nil {
		t.Fatalf("the trim: %v", err)
	}
	var keptFrom, oldest time.Time
	if err := tx.QueryRow(ctx, `SELECT m.kept_from, (SELECT min(hour) FROM pgvigil.collection_health_hour WHERE instance_id = $1 AND collection = $2)
	      FROM (`+sqlCollPerfMeta+"\n"+`) m`, p, coll+"-edge").Scan(&keptFrom, &oldest); err != nil {
		t.Fatalf("the meta after the trim: %v", err)
	}
	if !keptFrom.Equal(oldest) {
		t.Errorf("the first hour kept: kept_from %v, the oldest hour left %v (days %d)", keptFrom, oldest, days)
	}
}
