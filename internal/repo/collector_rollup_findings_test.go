package repo

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), collector_findings' 'job statistics not rolled up'
// (FLEET STATS ROLLUP, 0139's 'rollup failed' rows in collection_log): one finding per instance and source while its
// newest 'rollup failed' row of the last day has no 'rollup healed' row of that source after it - warning, source
// 'pgvigil collector', the value the source, the detail the row's note; a 'rollup healed' row clears it; a failure
// after the heal raises it again; a row older than a day raises nothing; another source's heal does not clear it.
// The rows are written as 0139 writes them (job_stats_failed / job_stats_heal's notes), so the store needs no 0139.
func TestCollectorFindingsRollupNotRolledUp(t *testing.T) {
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
	t.Cleanup(pool.Close)
	var a, b int
	sfx := time.Now().UnixNano() % 1000000000
	for i, id := range []*int{&a, &b} {
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("rollupfind-%d-%d", i, sfx)).Scan(id); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		if _, err := pool.Exec(c, `DELETE FROM pgvigil.instances WHERE instance_id IN ($1, $2)`, a, b); err != nil {
			t.Logf("cleanup: %v", err)
		}
	})
	logRow := func(inst int, ago time.Duration, status, note string) {
		t.Helper()
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
		                             VALUES ($1, 'job_stats_hourly', now() - $2::interval, $3, $4)`, inst, fmt.Sprintf("%d seconds", int(ago.Seconds())), status, note); err != nil {
			t.Fatal(err)
		}
	}
	failed := func(src string) string {
		return "rollup failed for the " + src + " hours 2026-11-14 10:00 to 2026-11-14 11:00 UTC (the runs are stored; the hours are rebuilt by the next import or purge): a table in the way"
	}
	healed := func(src string) string {
		return "rollup healed: the " + src + " hours 2026-11-14 10:00 to 2026-11-14 11:00 UTC rebuilt"
	}
	findings := func(inst int) string {
		t.Helper()
		var s string
		if err := pool.QueryRow(ctx, `SELECT coalesce(string_agg(format('%s %s %s', severity, value, source), ', ' ORDER BY value), 'none')
		                                FROM pgvigil.collector_findings WHERE instance_id = $1 AND setting = 'job statistics not rolled up'`, inst).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	want := func(name, got, w string) {
		t.Helper()
		if got != w {
			t.Errorf("%s: got %s, want %s", name, got, w)
		}
	}

	logRow(a, 30*time.Minute, "error", failed("mssql_job_runs"))
	want("a 'rollup failed' row raises the finding", findings(a), "warning mssql_job_runs pgvigil collector")
	var detail string
	if err := pool.QueryRow(ctx, `SELECT detail FROM pgvigil.collector_findings WHERE instance_id = $1 AND setting = 'job statistics not rolled up'`, a).Scan(&detail); err != nil {
		t.Fatal(err)
	}
	want("its detail is the row's note", detail, failed("mssql_job_runs"))
	logRow(a, 20*time.Minute, "ok", healed("job_runs"))
	want("another source's heal does not clear it", findings(a), "warning mssql_job_runs pgvigil collector")
	logRow(a, 10*time.Minute, "ok", healed("mssql_job_runs"))
	want("its 'rollup healed' row clears it", findings(a), "none")
	logRow(a, 5*time.Minute, "error", failed("mssql_job_runs"))
	logRow(a, 5*time.Minute, "error", failed("job_runs"))
	want("a failure after the heal raises it again, one per source", findings(a), "warning job_runs pgvigil collector, warning mssql_job_runs pgvigil collector")
	logRow(b, 26*time.Hour, "error", failed("mssql_job_runs"))
	want("a row older than a day raises nothing", findings(b), "none")
}
