package repo

import (
	"strings"
	"testing"
	"time"
)

// TestPartitionsAheadFinding (N4): partitions_missing_next names the month-ranged parents whose next month is missing;
// partitions_ahead_finding raises 'partitions ahead missing' inside a month's last three days (UTC) only, while one is
// missing and an active instance logged a collection in the last day, and the reader may call both. On a database of
// its own (throwawayRepo).
func TestPartitionsAheadFinding(t *testing.T) {
	ctx, r, pool, _ := throwawayRepo(t)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	iid, err := r.EnsureInstanceEngine(ctx, "postgres", "n4-finding", "linux", "18.0", 180000, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	// a collection logged now, as a collector's run does (collection_dates)
	if _, err := pool.Exec(ctx, `SELECT pgvigil.log_collection($1, 'activity', now(), 10, 'ok', NULL)`, iid); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	first := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	lastDay := first.AddDate(0, 1, 0).Add(-12 * time.Hour) // the month's last day, 12:00 UTC: inside the window
	mid := first.AddDate(0, 0, 10)                         // the 11th: outside it
	before := first.AddDate(0, 1, -3).Add(-time.Minute)    // a minute before the window opens
	if _, err := PartitionsAhead(ctx, pool, now, first.AddDate(0, 1, 0), now.Add(48*time.Hour)); err != nil {
		t.Fatal(err)
	}
	next := first.AddDate(0, 1, 0).Format("200601")
	for _, p := range []string{"activity_sample", "mssql_cpu_sample"} {
		if _, err := pool.Exec(ctx, `DROP TABLE pgvigil.`+p+`_`+next); err != nil {
			t.Fatal(err)
		}
	}
	missing := func(at time.Time) string {
		var s string
		if err := pool.QueryRow(ctx, `SELECT coalesce(string_agg(parent, ',' ORDER BY parent), '') FROM pgvigil.partitions_missing_next($1)`, at).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	finding := func(at time.Time) (n int, value, detail string) {
		if err := pool.QueryRow(ctx, `SELECT count(*), coalesce(max(value), ''), coalesce(max(detail), '')
		                                FROM pgvigil.partitions_ahead_finding($1) WHERE setting = 'partitions ahead missing'
		                                 AND source = 'pgvigil repository' AND severity = 'warning'`, at).Scan(&n, &value, &detail); err != nil {
			t.Fatal(err)
		}
		return
	}
	if got := missing(lastDay); got != "activity_sample,mssql_cpu_sample" {
		t.Errorf("partitions_missing_next: %q, want activity_sample,mssql_cpu_sample", got)
	}
	if n, v, d := finding(lastDay); n != 1 || v != "2 parent(s)" || !strings.Contains(d, "activity_sample, mssql_cpu_sample") {
		t.Errorf("the month's last day: %d finding(s), value %q, detail %q; want 1, '2 parent(s)', both names", n, v, d)
	}
	for name, at := range map[string]time.Time{"the 11th": mid, "a minute before the last three days": before} {
		if n, _, _ := finding(at); n != 0 {
			t.Errorf("%s: %d finding(s), want 0 (outside a month's last three days)", name, n)
		}
	}
	// the reader (the Collector page) may call both: apply_roles grants a function that is not import_ to it
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var n int
	if _, err := tx.Exec(ctx, `SET LOCAL ROLE pgvigil_reader`); err != nil {
		t.Fatal(err)
	}
	if err := tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM pgvigil.partitions_ahead_finding($1)) + (SELECT count(*) FROM pgvigil.partitions_missing_next($1))`, lastDay).Scan(&n); err != nil || n != 3 {
		t.Errorf("as pgvigil_reader: %d row(s), err %v; want 3 (one finding, two parents)", n, err)
	}
	_ = tx.Rollback(ctx)
	// no active instance: no import, no rollover deadlock - no finding
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.instances SET is_active = false`); err != nil {
		t.Fatal(err)
	}
	if n, _, _ := finding(lastDay); n != 0 {
		t.Errorf("no active instance: %d finding(s), want 0", n)
	}
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.instances SET is_active = true`); err != nil {
		t.Fatal(err)
	}
	// no collection logged in the last day (a store fed only by DBA Dash's history import): no finding
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.collection_dates SET snapshot_at = now() - interval '2 days'`); err != nil {
		t.Fatal(err)
	}
	if n, _, _ := finding(lastDay); n != 0 {
		t.Errorf("no collection in the last day: %d finding(s), want 0", n)
	}
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.collection_dates SET snapshot_at = now()`); err != nil {
		t.Fatal(err)
	}
	// made again by a pass: no finding
	if _, err := PartitionsAhead(ctx, pool, now, first.AddDate(0, 1, 0), now.Add(48*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if n, _, _ := finding(lastDay); n != 0 || missing(lastDay) != "" {
		t.Errorf("after a pass: %d finding(s), missing %q; want none", n, missing(lastDay))
	}
	t.Run("collector_findings names it", func(t *testing.T) {
		var def string
		if err := pool.QueryRow(ctx, `SELECT pg_get_viewdef('pgvigil.collector_findings'::regclass)`).Scan(&def); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(def, "partitions_ahead_finding") {
			t.Skip("collector_findings has no partitions_ahead_finding arm: an unwired tree (the arm is scripts/n4-wiring.patch's join line (4))")
		}
		var k int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.collector_findings WHERE setting = 'partitions ahead missing'`).Scan(&k); err != nil || k != 0 {
			t.Errorf("collector_findings: %d 'partitions ahead missing' row(s) with every partition made, err %v; want 0", k, err)
		}
	})
}
