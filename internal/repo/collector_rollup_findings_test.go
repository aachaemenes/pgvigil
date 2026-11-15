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
// after the heal raises it again; a row older than a day raises nothing; another source's heal does not clear it; a
// heal and then a failure in ONE transaction (one now(): equal snapshot_at) leave the finding standing ('after' is by
// log_id). Most rows are written in 0139's note shape by hand (the store needs no 0139); on a store with 0139 one
// instance's rows come from 0139's own job_stats_failed and job_stats_heal_one, so a change of their notes shows here.
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
	var a, b, c int
	sfx := time.Now().UnixNano() % 1000000000
	for i, id := range []*int{&a, &b, &c} {
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("rollupfind-%d-%d", i, sfx)).Scan(id); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		cx, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		if _, err := pool.Exec(cx, `DELETE FROM pgvigil.instances WHERE instance_id IN ($1, $2, $3)`, a, b, c); err != nil {
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

	// a heal, then a failure, in one transaction: equal snapshot_at, the failure is the newer
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range [][2]string{{"ok", healed("job_runs")}, {"error", failed("job_runs")}} {
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note) VALUES ($1, 'job_stats_hourly', now(), $2, $3)`, b, r[0], r[1]); err != nil {
			_ = tx.Rollback(ctx)
			t.Fatal(err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	want("a heal then a failure in one transaction: the failure stands", findings(b), "warning job_runs pgvigil collector")

	// 0139's own writers, where the store has them
	var with0139 bool
	if err := pool.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.job_stats_heal_one(integer)') IS NOT NULL`).Scan(&with0139); err != nil {
		t.Fatal(err)
	}
	if !with0139 {
		t.Log("no 0139 on this store: its own writers not driven")
		return
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.job_stats_failed($1, 'mssql_job_runs', now() - interval '2 hours', now() - interval '1 hour', 'a table in the way')`, c); err != nil {
		t.Fatal(err)
	}
	want("0139's job_stats_failed raises it", findings(c), "warning mssql_job_runs pgvigil collector")
	if _, err := pool.Exec(ctx, `SELECT pgvigil.job_stats_heal_one($1)`, c); err != nil {
		t.Fatal(err)
	}
	want("0139's heal ('rollup healed') clears it", findings(c), "none")
}
