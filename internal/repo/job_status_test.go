package repo

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0137's job_status_view and job_status:
//   - with no threshold row the rule is DBA Dash's default: a job that failed two hours ago and succeeded since is
//     'warn' (a failure inside 7 days), one that failed 30 minutes ago 'crit' (inside 60 minutes), one whose last run
//     failed 'crit' whatever its age, one that failed 8 days ago 'ok' with no last failure (older than the horizon),
//     on SQL Agent and on pg_cron alike; the horizon is 7 days (10080 minutes);
//   - a cancelled run is a failure, as in DBA Dash 4.24.1 (JobHistory_Upd's LastFailed and JobStats_RAW's FailedCount
//     count run_status IN (0,3)): a SQL Agent job cancelled two hours ago and successful since is 'warn', one whose
//     last run was cancelled 'crit' ('the last run was cancelled'), a pg_cron run that was aborted counts as pg_cron's
//     failed one does, and a cancelled step is a failed step;
//   - the view of two instances holds every job of both, and job_status of one instance is the view's rows of it;
//   - a threshold row with a longer 'since' span lengthens the horizon of the views that hold its instance and of no
//     other: the failure 8 days back is then found, and a job with no success inside the horizon that ran before it
//     breaks 'no success for' with the words 'no success in the last 14 day(s)'; the horizon stops at 400 days.
func TestJobStatusOnAStore(t *testing.T) {
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
		fmt.Sprintf("jobstatus-sql-%d", sfx)).Scan(&ms); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("jobstatus-pg-%d", sfx)).Scan(&pg); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 20*time.Second)
		defer stop()
		for _, q := range []string{
			`DELETE FROM pgvigil.mssql_job_runs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_runs WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.jobs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(c, q, []int{ms, pg}); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
	})
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', m) FROM generate_series(now() - interval '25 days', now() + interval '1 day', interval '5 days') m`)

	// a SQL Agent job: its row and its runs, each (minutes ago, run_status of the job row); a failed run has a failed step too
	type run struct {
		ago    int
		status int
	}
	hist := int64(0)
	agent := func(name string, lastOutcome int, runs ...run) {
		t.Helper()
		exec(`INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, last_outcome) VALUES ($1, $2, now(), $2, true, $3)`, ms, name, lastOutcome)
		for _, r := range runs {
			for step := 0; step <= 1; step++ {
				hist++
				exec(`INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, run_status)
				      VALUES ($1, now() - make_interval(mins => $2::int) + make_interval(secs => $3::int), $4, $5, $5, $3::int, $6)`, ms, r.ago, step, hist, name, r.status)
			}
		}
	}
	const day = 1440
	agent("a failed then succeeded", 1, run{120, 0}, run{60, 1})
	agent("b failed half an hour ago", 1, run{30, 0}, run{10, 1})
	agent("c last run failed", 0, run{5 * day, 1}, run{3 * day, 0})
	agent("d failed 8 days ago", 1, run{8 * day, 0}, run{60, 1})
	agent("e never failed", 1, run{2 * day, 1}, run{60, 1})
	agent("f no success for 20 days", 1, run{20 * day, 1})
	agent("h cancelled then succeeded", 1, run{120, 3}, run{60, 1})
	agent("i last run cancelled", 3, run{5 * day, 1}, run{2 * day, 3})
	exec(`INSERT INTO pgvigil.jobs (instance_id, scheduler, job_id, snapshot_at, job_name, schedule, command, active, first_seen, is_present)
	      VALUES ($1, 'pg_cron', 1, now(), 'g failed then succeeded', '0 * * * *', 'SELECT 1', true, now() - interval '30 days', true)`, pg)
	exec(`INSERT INTO pgvigil.job_runs (instance_id, scheduler, job_id, run_id, status, start_time, end_time, snapshot_at)
	      VALUES ($1, 'pg_cron', 1, 1, 'failed', now() - interval '120 minutes', now() - interval '119 minutes', now()),
	             ($1, 'pg_cron', 1, 2, 'succeeded', now() - interval '60 minutes', now() - interval '59 minutes', now())`, pg)
	exec(`INSERT INTO pgvigil.jobs (instance_id, scheduler, job_id, snapshot_at, job_name, schedule, command, active, first_seen, is_present)
	      VALUES ($1, 'pg_cron', 2, now(), 'j aborted then succeeded', '0 * * * *', 'SELECT 2', true, now() - interval '30 days', true)`, pg)
	exec(`INSERT INTO pgvigil.job_runs (instance_id, scheduler, job_id, run_id, status, start_time, end_time, snapshot_at)
	      VALUES ($1, 'pg_cron', 2, 3, 'aborted', now() - interval '120 minutes', now() - interval '119 minutes', now()),
	             ($1, 'pg_cron', 2, 4, 'succeeded', now() - interval '60 minutes', now() - interval '59 minutes', now())`, pg)

	type row struct {
		status, reason    string
		failed, succeeded bool // a last failure / success was found
		horizon           int
	}
	view := func(ids ...int) map[string]row {
		t.Helper()
		rows, err := pool.Query(ctx, `SELECT job_name, status, coalesce(reason, ''), last_failed_at IS NOT NULL, last_succeeded_at IS NOT NULL, horizon_min
		                                FROM pgvigil.job_status_view($1)`, ids)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		out := map[string]row{}
		for rows.Next() {
			var n string
			var r row
			if err := rows.Scan(&n, &r.status, &r.reason, &r.failed, &r.succeeded, &r.horizon); err != nil {
				t.Fatal(err)
			}
			out[n] = r
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		return out
	}
	check := func(what string, got map[string]row, want map[string]row) {
		t.Helper()
		if len(got) != len(want) {
			t.Errorf("%s: %d jobs, want %d (%v)", what, len(got), len(want), got)
		}
		for n, w := range want {
			if g, ok := got[n]; !ok || g != w {
				t.Errorf("%s: %q = %+v, want %+v", what, n, g, w)
			}
		}
	}

	// 1. no threshold row: DBA Dash's default, the horizon 7 days
	const week = 7 * day
	def := map[string]row{
		"a failed then succeeded":    {"warn", "failed 120 minute(s) ago (warning within 10080)", true, true, week},
		"b failed half an hour ago":  {"crit", "failed 30 minute(s) ago (critical within 60)", true, true, week},
		"c last run failed":          {"crit", "the last run failed", true, true, week},
		"d failed 8 days ago":        {"ok", "", false, true, week},
		"e never failed":             {"ok", "", false, true, week},
		"f no success for 20 days":   {"ok", "", false, false, week},
		"g failed then succeeded":    {"warn", "failed 120 minute(s) ago (warning within 10080)", true, true, week},
		"h cancelled then succeeded": {"warn", "failed 120 minute(s) ago (warning within 10080)", true, true, week},
		"i last run cancelled":       {"crit", "the last run was cancelled", true, true, week},
		"j aborted then succeeded":   {"warn", "failed 120 minute(s) ago (warning within 10080)", true, true, week},
	}
	check("the default, both instances", view(ms, pg), def)

	// 2. job_status of one instance = the view's rows of it
	var same bool
	if err := pool.QueryRow(ctx, `SELECT NOT EXISTS (
	    (SELECT scheduler, job_id, job_name, level, threshold_id, fail_24h, fail_7d, step_fail_24h, step_fail_7d, last_failed_at, last_succeeded_at, last_outcome, status, reason
	       FROM pgvigil.job_status($1)
	     EXCEPT
	     SELECT scheduler, job_id, job_name, level, threshold_id, fail_24h, fail_7d, step_fail_24h, step_fail_7d, last_failed_at, last_succeeded_at, last_outcome, status, reason
	       FROM pgvigil.job_status_view(ARRAY[$1::int, $2::int]) WHERE instance_id = $1))
	  AND (SELECT count(*) FROM pgvigil.job_status($1)) = 8`, ms, pg).Scan(&same); err != nil {
		t.Fatal(err)
	}
	if !same {
		t.Error("job_status of the SQL Server instance is not the view's eight rows of it")
	}
	var steps int64
	if err := pool.QueryRow(ctx, `SELECT step_fail_7d FROM pgvigil.job_status($1) WHERE job_name = 'a failed then succeeded'`, ms).Scan(&steps); err != nil || steps != 1 {
		t.Errorf("the failed step of job a in 7 days: %d (%v), want 1", steps, err)
	}
	if err := pool.QueryRow(ctx, `SELECT step_fail_7d FROM pgvigil.job_status($1) WHERE job_name = 'h cancelled then succeeded'`, ms).Scan(&steps); err != nil || steps != 1 {
		t.Errorf("the cancelled step of job h in 7 days: %d (%v), want 1 (a cancelled step is a failed step)", steps, err)
	}

	// 3. an instance threshold with a 14-day 'no success' span: the horizon of the views that hold the instance is 14
	// days (the failure 8 days back is found; the default's rules are replaced whole), the other instance's stays 7
	exec(`INSERT INTO pgvigil.job_thresholds (level, instance_id, since_ok_warn_min, created_by, created_at) VALUES ('instance', $1, 20160, 'test', now())`, ms)
	const two = 14 * day
	check("a 14-day threshold on the SQL Server instance", view(ms), map[string]row{
		"a failed then succeeded":    {"ok", "", true, true, two},
		"b failed half an hour ago":  {"ok", "", true, true, two},
		"c last run failed":          {"ok", "", true, true, two},
		"d failed 8 days ago":        {"ok", "", true, true, two},
		"e never failed":             {"ok", "", false, true, two},
		"f no success for 20 days":   {"warn", "no success in the last 14 day(s) (warning over 20160 minute(s))", false, false, two},
		"h cancelled then succeeded": {"ok", "", true, true, two},
		"i last run cancelled":       {"ok", "", true, true, two},
	})
	check("the PostgreSQL instance alone", view(pg), map[string]row{"g failed then succeeded": def["g failed then succeeded"],
		"j aborted then succeeded": def["j aborted then succeeded"]})
	if got := view(ms, pg)["g failed then succeeded"]; got.horizon != two || got.status != "warn" {
		t.Errorf("both instances with the 14-day threshold: g = %+v, want warn at the horizon %d", got, two)
	}

	// 4. the horizon stops at 400 days
	exec(`INSERT INTO pgvigil.job_thresholds (level, instance_id, since_ok_crit_min, created_by, created_at) VALUES ('instance', $1, 5256000, 'test', now())`, pg)
	if got := view(pg)["g failed then succeeded"]; got.horizon != 400*day || got.status != "ok" {
		t.Errorf("a 10-year threshold: g = %+v, want ok at the horizon %d", got, 400*day)
	}
}
