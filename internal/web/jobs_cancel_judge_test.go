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
// (PGVIGIL_REPO_TEST_DSN, skipped without it) a cancelled SQL Agent run (run_status 3) and an aborted pg_cron run are
// failures, as 0137's job_status counts them (DBA Dash 4.24.1 JobHistory_Upd / JobStats_RAW: run_status IN (0, 3)):
//   - the jobs history grid (both engines): the job's last failure is the cancel / the abort, its outcome word
//     'cancelled', the failures in the range count it, and a job whose last run was cancelled sorts with the failed
//     ones (before a job that succeeded, whatever their names);
//   - the SQL Server Jobs page's failed-runs list holds the cancelled run, its outcome 'cancelled';
//   - 0066's finding 'a job failed' (mssql_jobs_findings, replaced whole by 0149) names the cancelled run 'was
//     cancelled at', under the same check name.
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
	var t1, t2 time.Time // three and two hours back, whole minutes
	if err := pool.QueryRow(ctx, `SELECT date_trunc('minute', now()) - interval '3 hours', date_trunc('minute', now()) - interval '2 hours'`).Scan(&t1, &t2); err != nil {
		t.Fatal(err)
	}
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', m) FROM unnest(ARRAY[$1::timestamptz, $2::timestamptz]) m`, t1, t2)
	// SQL Server: 'a-ok' succeeded last; 'z-cancelled' succeeded at t1 and was cancelled at t2 (its last run)
	for _, j := range []struct {
		id      string
		outcome int
	}{{"a-ok", 1}, {"z-cancelled", 3}} {
		exec(`INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, category, description, last_outcome, last_run_at)
		      VALUES ($1, $2, now(), $2, true, 'test', 'jobs_cancel_judge_test', $3, $4)`, ms, j.id, j.outcome, t2)
	}
	exec(`INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, run_status, duration_s, retries, message)
	      VALUES ($1, $2, 1, 'a-ok', 'a-ok', 0, 1, 4, 0, 'The job succeeded.'),
	             ($1, $3, 2, 'a-ok', 'a-ok', 0, 1, 4, 0, 'The job succeeded.'),
	             ($1, $2, 3, 'z-cancelled', 'z-cancelled', 0, 1, 5, 0, 'The job succeeded.'),
	             ($1, $3, 4, 'z-cancelled', 'z-cancelled', 0, 3, 6, 0, 'The job was stopped prior to completion by User sa.')`, ms, t1, t2)
	// PostgreSQL: 'a ok' succeeded; 'z aborted' succeeded at t1 and was aborted at t2
	for _, j := range []struct {
		id   int
		name string
	}{{7, "a ok"}, {8, "z aborted"}} {
		exec(`INSERT INTO pgvigil.jobs (instance_id, scheduler, job_id, snapshot_at, job_name, schedule, command, datname, active, first_seen, is_present)
		      VALUES ($1, 'pg_cron', $2, now(), $3, '*/30 * * * *', 'SELECT 1', 'postgres', true, now() - interval '1 day', true)`, pg, j.id, j.name)
	}
	exec(`INSERT INTO pgvigil.job_runs (instance_id, scheduler, job_id, run_id, status, start_time, end_time, duration_secs, snapshot_at, return_message)
	      VALUES ($1, 'pg_cron', 7, 1, 'succeeded', $2, $2::timestamptz + interval '4 seconds', 4, $2, '1 row'),
	             ($1, 'pg_cron', 7, 2, 'succeeded', $3, $3::timestamptz + interval '4 seconds', 4, $3, '1 row'),
	             ($1, 'pg_cron', 8, 3, 'succeeded', $2, $2::timestamptz + interval '5 seconds', 5, $2, '1 row'),
	             ($1, 'pg_cron', 8, 4, 'aborted', $3, $3::timestamptz + interval '6 seconds', 6, $3, 'canceling statement due to user request')`, pg, t1, t2)

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
	from, to := t1.Add(-time.Hour), t2.Add(time.Hour)
	hm := t2.UTC().Format("15:04")
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
	want("SQL Server grid: the cancelled job's last failure", line(by["z-cancelled"]), fmt.Sprintf("last failure %s cancelled, failures 1", hm))
	want("SQL Server grid: the job that succeeded", line(by["a-ok"]), "last failure null null, failures 0")
	want("SQL Server grid's order: a cancelled last run sorts with the failed", order, "z-cancelled, a-ok")
	order, by = grid("pg", pg)
	want("PostgreSQL grid: the aborted job's last failure", line(by["z aborted"]), fmt.Sprintf("last failure %s cancelled, failures 1", hm))
	want("PostgreSQL grid: the job that succeeded", line(by["a ok"]), "last failure null null, failures 0")
	want("PostgreSQL grid's order: an aborted last run sorts with the failed", order, "z aborted, a ok")

	// F5: the SQL Server Jobs page's failed-runs list
	var failed []string
	for _, m := range rows(sqlMSSQLJobsFailed, ms, from, to) {
		failed = append(failed, fmt.Sprintf("%s %s %s", cell(m, "job"), cell(m, "run_at"), cell(m, "outcome")))
	}
	want("the failed-runs list", strings.Join(failed, ", "), fmt.Sprintf("z-cancelled %s cancelled", hm))

	// F4: 'a job failed' names the cancelled run
	var findings []string
	for _, m := range rows(`SELECT check_name, object, detail FROM pgvigil.mssql_jobs_findings WHERE instance_id = $1 AND check_name = 'a job failed'`, ms) {
		d := cell(m, "detail")
		if i := strings.Index(d, " at "); i > 0 {
			d = d[:i]
		}
		findings = append(findings, fmt.Sprintf("%s: %s", cell(m, "object"), d))
	}
	want("'a job failed' for the cancelled run", strings.Join(findings, ", "), "z-cancelled: job z-cancelled was cancelled")
}
