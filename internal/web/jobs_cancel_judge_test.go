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

// TestJobsCancelIsAFailureOnAStore (FLEET FOLLOW-UP, one judge everywhere): on a migrated repository
// (PGVIGIL_REPO_TEST_DSN, skipped without it) a cancelled SQL Agent run (run_status 3) and an aborted pgAgent run are
// failures beside a failed one (run_status 0, 'failed', 'internal error'), as 0137's job_status counts them (DBA Dash
// 4.24.1 JobHistory_Upd / JobStats_RAW: run_status IN (0, 3)):
//   - the jobs history grid (both engines): each job's last failure is its newest failed or cancelled run (a job that
//     failed, then was cancelled, reads the cancel), its outcome word 'failed' or 'cancelled' ('internal error' reads
//     'failed'), the failures in the range count both, and the jobs whose last run failed or was cancelled sort first;
//   - the SQL Server Jobs page's failed-runs list holds every failed and cancelled run with its outcome, and the step
//     that ended it the same way (the cancelled step of a cancelled run, as the import stores the outcome row's);
//   - 0066's finding 'a job failed' (mssql_jobs_findings, replaced whole by 0149) says 'failed' or 'was cancelled' for
//     each job's newest such run, under the same check name, a cancelled run with its cancelled step.
func TestJobsCancelIsAFailureOnAStore(t *testing.T) {
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
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
	}
	sfx := time.Now().UnixNano() % 1000000000
	var ms, pg int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("cancel-sql-%d", sfx)).Scan(&ms); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("cancel-pg-%d", sfx)).Scan(&pg); err != nil {
		t.Fatal(err)
	}
	defer func() {
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		for _, q := range []string{`DELETE FROM pgvigil.mssql_job_runs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_runs WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_jobs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.jobs WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(c, q, []int{ms, pg}); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
	}()
	var tA, tB, tC, tD time.Time // 3 h, 2 h 30, 2 h and 1 h 30 back, whole minutes
	if err := pool.QueryRow(ctx, `SELECT date_trunc('minute', now()) - interval '3 hours', date_trunc('minute', now()) - interval '150 minutes',
	                                     date_trunc('minute', now()) - interval '2 hours', date_trunc('minute', now()) - interval '90 minutes'`).Scan(&tA, &tB, &tC, &tD); err != nil {
		t.Fatal(err)
	}
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', m) FROM unnest(ARRAY[$1::timestamptz, $2::timestamptz]) m`, tA, tD)
	// SQL Server: 'a-ok' succeeded; 'm-failed' failed at tB (step 1); 'n-both' failed at tA (step 1), then was cancelled at
	// tD in step 2; 'z-cancelled' was cancelled at tC with no step row
	for _, j := range []struct {
		id      string
		outcome int
		last    time.Time
	}{{"a-ok", 1, tC}, {"m-failed", 0, tB}, {"n-both", 3, tD}, {"z-cancelled", 3, tC}} {
		exec(`INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, category, description, last_outcome, last_run_at)
		      VALUES ($1, $2, now(), $2, true, 'test', 'jobs_cancel_judge_test', $3, $4)`, ms, j.id, j.outcome, j.last)
	}
	exec(`INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, step_name, run_status, duration_s, retries, message)
	      VALUES ($1, $2, 1, 'a-ok', 'a-ok', 0, NULL, 1, 4, 0, 'The job succeeded.'),
	             ($1, $4, 2, 'a-ok', 'a-ok', 0, NULL, 1, 4, 0, 'The job succeeded.'),
	             ($1, $2, 3, 'm-failed', 'm-failed', 0, NULL, 1, 4, 0, 'The job succeeded.'),
	             ($1, $3, 5, 'm-failed', 'm-failed', 1, 'one', 0, 2, 0, 'step one failed'),
	             ($1, $3, 6, 'm-failed', 'm-failed', 0, NULL, 0, 3, 0, 'The job failed.'),
	             ($1, $2, 7, 'n-both', 'n-both', 1, 'one', 0, 2, 0, 'step one failed'),
	             ($1, $2, 8, 'n-both', 'n-both', 0, NULL, 0, 3, 0, 'The job failed.'),
	             ($1, $5::timestamptz + interval '10 seconds', 9, 'n-both', 'n-both', 2, 'two', 3, 20, 0, 'stopped in step two'),
	             ($1, $5, 10, 'n-both', 'n-both', 0, NULL, 3, 30, 0, 'The job was stopped prior to completion by User sa.'),
	             ($1, $2, 11, 'z-cancelled', 'z-cancelled', 0, NULL, 1, 5, 0, 'The job succeeded.'),
	             ($1, $4, 12, 'z-cancelled', 'z-cancelled', 0, NULL, 3, 6, 0, 'The job was stopped prior to completion by User sa.')`, ms, tA, tB, tC, tD)
	// PostgreSQL: 'a ok' (pg_cron) succeeded; 'm internal' (pg_cron) ended in 'internal error' at tB; 'n both' (pgAgent)
	// failed at tA, then was aborted at tD; 'z aborted' (pgAgent) was aborted at tC - pgAgent's 'd', the collector's
	// 'aborted' (pg_cron writes no such state)
	for _, j := range []struct {
		sched string
		id    int
		name  string
	}{{"pg_cron", 7, "a ok"}, {"pg_cron", 9, "m internal"}, {"pgagent", 10, "n both"}, {"pgagent", 8, "z aborted"}} {
		exec(`INSERT INTO pgvigil.jobs (instance_id, scheduler, job_id, snapshot_at, job_name, schedule, command, datname, active, first_seen, is_present)
		      VALUES ($1, $2, $3, now(), $4, '*/30 * * * *', 'SELECT 1', 'postgres', true, now() - interval '1 day', true)`, pg, j.sched, j.id, j.name)
	}
	exec(`INSERT INTO pgvigil.job_runs (instance_id, scheduler, job_id, run_id, status, start_time, end_time, duration_secs, snapshot_at, return_message)
	      VALUES ($1, 'pg_cron', 7, 1, 'succeeded', $2, $2::timestamptz + interval '4 seconds', 4, $2, '1 row'),
	             ($1, 'pg_cron', 7, 2, 'succeeded', $4, $4::timestamptz + interval '4 seconds', 4, $4, '1 row'),
	             ($1, 'pg_cron', 9, 3, 'succeeded', $2, $2::timestamptz + interval '4 seconds', 4, $2, '1 row'),
	             ($1, 'pg_cron', 9, 4, 'internal error', $3, $3::timestamptz + interval '1 second', 1, $3, 'job startup timeout'),
	             ($1, 'pgagent', 10, 5, 'failed', $2, $2::timestamptz + interval '3 seconds', 3, $2, 'step 1 failed'),
	             ($1, 'pgagent', 10, 6, 'aborted', $5, $5::timestamptz + interval '6 seconds', 6, $5, 'aborted'),
	             ($1, 'pgagent', 8, 7, 'succeeded', $2, $2::timestamptz + interval '5 seconds', 5, $2, NULL),
	             ($1, 'pgagent', 8, 8, 'aborted', $4, $4::timestamptz + interval '6 seconds', 6, $4, 'aborted')`, pg, tA, tB, tC, tD)

	// rows: the query's rows as maps by column name ('none' for a column it does not give)
	rows := func(sql string, args ...any) []map[string]any {
		t.Helper()
		r, err := pool.Query(ctx, sql, args...)
		if err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
		defer r.Close()
		var out []map[string]any
		for r.Next() {
			v, err := r.Values()
			if err != nil {
				t.Fatal(err)
			}
			m := map[string]any{}
			for i, f := range r.FieldDescriptions() {
				m[f.Name] = v[i]
			}
			out = append(out, m)
		}
		if err := r.Err(); err != nil {
			t.Fatal(err)
		}
		return out
	}
	cell := func(m map[string]any, k string) string {
		v, ok := m[k]
		switch {
		case !ok:
			return "none"
		case v == nil:
			return "null"
		}
		if tm, ok := v.(time.Time); ok {
			return tm.UTC().Format("15:04")
		}
		return fmt.Sprint(v)
	}
	want := func(name, got, w string) {
		t.Helper()
		if got != w {
			t.Errorf("%s: got %s, want %s", name, got, w)
		}
	}
	from, to := tA.Add(-time.Hour), tD.Add(time.Hour)
	hm := func(at time.Time) string { return at.UTC().Format("15:04") }
	grid := func(engine string, inst int) (string, map[string]map[string]any) {
		t.Helper()
		sql := sqlJobsGridMS
		if engine == "pg" {
			sql = sqlJobsGridPG
		}
		var order []string
		by := map[string]map[string]any{}
		for _, m := range rows(sql, inst, from, to) {
			n := cell(m, "name")
			order = append(order, n)
			by[n] = m
		}
		return strings.Join(order, ", "), by
	}
	line := func(m map[string]any) string {
		return fmt.Sprintf("last failure %s %s, failures %s", cell(m, "last_failed_at"), cell(m, "last_failed_outcome"), cell(m, "failures"))
	}

	// F1 / F2: the history grid, SQL Server and PostgreSQL
	order, by := grid("mssql", ms)
	want("SQL Server grid: a cancelled job's last failure", line(by["z-cancelled"]), fmt.Sprintf("last failure %s cancelled, failures 1", hm(tC)))
	want("SQL Server grid: a failed job's last failure", line(by["m-failed"]), fmt.Sprintf("last failure %s failed, failures 1", hm(tB)))
	want("SQL Server grid: failed, then cancelled: the newer, both counted", line(by["n-both"]), fmt.Sprintf("last failure %s cancelled, failures 2", hm(tD)))
	want("SQL Server grid: the job that succeeded", line(by["a-ok"]), "last failure null null, failures 0")
	want("SQL Server grid's order: the jobs whose last run failed or was cancelled first", order, "m-failed, n-both, z-cancelled, a-ok")
	order, by = grid("pg", pg)
	want("PostgreSQL grid: an aborted pgAgent job's last failure", line(by["z aborted"]), fmt.Sprintf("last failure %s cancelled, failures 1", hm(tC)))
	want("PostgreSQL grid: 'internal error' reads failed", line(by["m internal"]), fmt.Sprintf("last failure %s failed, failures 1", hm(tB)))
	want("PostgreSQL grid: failed, then aborted: the newer, both counted", line(by["n both"]), fmt.Sprintf("last failure %s cancelled, failures 2", hm(tD)))
	want("PostgreSQL grid: the job that succeeded", line(by["a ok"]), "last failure null null, failures 0")
	want("PostgreSQL grid's order: the jobs whose last run failed or was aborted first", order, "m internal, n both, z aborted, a ok")

	// F5: the SQL Server Jobs page's failed-runs list, newest first, each with its outcome and the step that ended it
	var failed []string
	for _, m := range rows(sqlMSSQLJobsFailed, ms, from, to) {
		failed = append(failed, fmt.Sprintf("%s %s %s step %s", cell(m, "job"), cell(m, "run_at"), cell(m, "outcome"), cell(m, "step_id")))
	}
	want("the failed-runs list", strings.Join(failed, ", "), fmt.Sprintf("n-both %s cancelled step 2, z-cancelled %s cancelled step null, m-failed %s failed step 1, n-both %s failed step 1",
		hm(tD), hm(tC), hm(tB), hm(tA)))

	// F4: 'a job failed', each job's newest failed or cancelled run
	var findings []string
	for _, m := range rows(`SELECT check_name, object, detail FROM pgvigil.mssql_jobs_findings WHERE instance_id = $1 AND check_name = 'a job failed' ORDER BY object`, ms) {
		d := cell(m, "detail")
		if i := strings.Index(d, " at "); i > 0 {
			d = d[:i]
		}
		findings = append(findings, fmt.Sprintf("%s: %s", cell(m, "object"), d))
	}
	want("'a job failed' per job", strings.Join(findings, ", "), "m-failed: job m-failed failed, n-both: job n-both was cancelled, z-cancelled: job z-cancelled was cancelled")
	var nboth string
	if err := pool.QueryRow(ctx, `SELECT detail FROM pgvigil.mssql_jobs_findings WHERE instance_id = $1 AND check_name = 'a job failed' AND object = 'n-both'`, ms).Scan(&nboth); err != nil {
		t.Fatal(err)
	}
	want("the cancelled run's step in its finding", fmt.Sprint(strings.Contains(nboth, " at step 2 (two): stopped in step two")), "true")
}
