package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestFleetJobsB9bOnAStore (B9b: B9-10, B9-12): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it),
// a SQL Server instance with three SQL Agent jobs and a PostgreSQL instance with one pg_cron job, their hours built:
//   - the fleet status part carries running_since (the SQL Agent job running now from mssql_jobs.running_since; the
//     pg_cron job's run without an end the newest read saw) and last_secs (the last finished run's seconds);
//   - the stats part carries failed_7d from the hours (a failed and a cancelled run: 2; 'b-ok': 0), so the page's
//     failure rate is 2 / 3 for 'b-rate';
//   - /api/jobs/history?part=cards: failed or cancelled 2, succeeded 5, 7 runs, 1 retry (a step retry row) on SQL
//     Server; retries NULL on PostgreSQL; part=top: 'b-rate' heads 'failed', 'b-ok' heads 'frequent', the 40 s run's
//     job heads 'longest' (b-ok and b-rate tie on 3 runs: the name breaks it);
//   - the grid's own reply (no part named) carries the 'jobs' part alone, as before.
func TestFleetJobsB9bOnAStore(t *testing.T) {
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
		fmt.Sprintf("b9b-sql-%d", sfx)).Scan(&ms); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("b9b-pg-%d", sfx)).Scan(&pg); err != nil {
		t.Fatal(err)
	}
	defer func() {
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		for _, q := range []string{`DELETE FROM pgvigil.job_stats_hourly WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_stats_dirty WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.job_stats_first_build WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_job_runs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_runs WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_jobs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.jobs WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(c, q, []int{ms, pg}); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
	}()
	var t3, t2, t1 time.Time // 3 h, 2 h and 1 h back, whole hours plus 10 minutes (each run in an hour of its own)
	if err := pool.QueryRow(ctx, `SELECT date_trunc('hour', now()) - interval '3 hours' + interval '10 minutes',
	                                     date_trunc('hour', now()) - interval '2 hours' + interval '10 minutes',
	                                     date_trunc('hour', now()) - interval '1 hour' + interval '10 minutes'`).Scan(&t3, &t2, &t1); err != nil {
		t.Fatal(err)
	}
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', m) FROM unnest(ARRAY[$1::timestamptz, $2::timestamptz]) m`, t3, t1)
	// SQL Server: 'b-run' runs now (since 5 minutes) and last took 40 s; 'b-rate' failed, was cancelled and succeeded;
	// 'b-ok' succeeded three times (7, 7 and 9 s, the last 9), its step 1 retried once
	exec(`INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, category, description, last_outcome, last_run_at, running_since)
	      VALUES ($1, 'b-run', now(), 'b-run', true, 'test', 'b9b', 1, $2, now() - interval '5 minutes'),
	             ($1, 'b-rate', now(), 'b-rate', true, 'test', 'b9b', 1, $3, NULL),
	             ($1, 'b-ok', now(), 'b-ok', true, 'test', 'b9b', 1, $3, NULL)`, ms, t3, t1)
	exec(`INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, step_name, run_status, duration_s, retries, message)
	      VALUES ($1, $2, 1, 'b-run', 'b-run', 0, NULL, 1, 40, 0, 'The job succeeded.'),
	             ($1, $2, 2, 'b-rate', 'b-rate', 0, NULL, 0, 3, 0, 'The job failed.'),
	             ($1, $3, 3, 'b-rate', 'b-rate', 0, NULL, 3, 4, 0, 'The job was stopped prior to completion.'),
	             ($1, $4, 4, 'b-rate', 'b-rate', 0, NULL, 1, 5, 0, 'The job succeeded.'),
	             ($1, $2, 5, 'b-ok', 'b-ok', 0, NULL, 1, 7, 0, 'The job succeeded.'),
	             ($1, $3, 6, 'b-ok', 'b-ok', 0, NULL, 1, 7, 0, 'The job succeeded.'),
	             ($1, $4, 7, 'b-ok', 'b-ok', 1, 'one', 2, 1, 1, 'step one will retry'),
	             ($1, $4, 8, 'b-ok', 'b-ok', 0, NULL, 1, 9, 0, 'The job succeeded.')`, ms, t3, t2, t1)
	// PostgreSQL: pg_cron job 71 finished in 12 s at t2 and runs now since t1
	exec(`INSERT INTO pgvigil.jobs (instance_id, scheduler, job_id, snapshot_at, job_name, first_seen, active, is_present)
	      VALUES ($1, 'pg_cron', 71, now(), 'b-cron', now() - interval '1 day', true, true)`, pg)
	exec(`INSERT INTO pgvigil.job_runs (instance_id, scheduler, job_id, run_id, status, start_time, end_time, duration_secs, snapshot_at)
	      VALUES ($1, 'pg_cron', 71, 1, 'succeeded', $2, $2::timestamptz + interval '12 seconds', 12, now()),
	             ($1, 'pg_cron', 71, 2, 'running', $3, NULL, NULL, now())`, pg, t2, t1)
	exec(`SELECT pgvigil.import_job_stats_build($1)`, ms)
	exec(`SELECT pgvigil.import_job_stats_build($1)`, pg)

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(h http.HandlerFunc, path string) map[string]*table {
		t.Helper()
		rec := httptest.NewRecorder()
		h(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", path, rec.Code, rec.Body.String())
		}
		out := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		return out
	}
	rowsOf := func(tb *table) []map[string]any {
		t.Helper()
		if tb == nil {
			t.Fatal("a part is missing")
		}
		var out []map[string]any
		for _, r := range tb.Rows {
			m := map[string]any{}
			for i, c := range tb.Columns {
				m[c] = r[i]
			}
			out = append(out, m)
		}
		return out
	}
	byJob := func(rs []map[string]any) map[string]map[string]any {
		m := map[string]map[string]any{}
		for _, r := range rs {
			m[fmt.Sprint(r["job_id"])] = r
		}
		return m
	}
	ids := fmt.Sprintf("%d,%d", ms, pg)

	st := byJob(rowsOf(call(s.JobsReport, "/api/jobsreport?part=status&ids="+ids)["status"]))
	if st["b-run"]["running_since"] == nil || st["b-rate"]["running_since"] != nil || st["71"]["running_since"] == nil {
		t.Fatalf("running_since: b-run %v, b-rate %v, pg_cron 71 %v", st["b-run"]["running_since"], st["b-rate"]["running_since"], st["71"]["running_since"])
	}
	if fmt.Sprint(st["b-ok"]["last_secs"]) != "9" || fmt.Sprint(st["b-run"]["last_secs"]) != "40" || fmt.Sprint(st["71"]["last_secs"]) != "12" {
		t.Fatalf("last_secs: b-ok %v (want 9), b-run %v (want 40), pg_cron 71 %v (want 12)", st["b-ok"]["last_secs"], st["b-run"]["last_secs"], st["71"]["last_secs"])
	}
	sx := byJob(rowsOf(call(s.JobsReport, "/api/jobsreport?part=stats&ids="+ids)["stats"]))
	if sx["b-rate"]["building"] != false || fmt.Sprint(sx["b-rate"]["failed_7d"]) != "2" || fmt.Sprint(sx["b-rate"]["ok_7d"]) != "1" || fmt.Sprint(sx["b-ok"]["failed_7d"]) != "0" {
		t.Fatalf("stats: b-rate %v, b-ok %v (want failed_7d 2 / ok_7d 1 and failed_7d 0, built)", sx["b-rate"], sx["b-ok"])
	}

	from, to := url.QueryEscape(t3.Add(-time.Hour).Format(time.RFC3339)), url.QueryEscape(time.Now().Add(time.Minute).Format(time.RFC3339))
	q := func(engine string, inst int, part string) string {
		return fmt.Sprintf("/api/jobs/history?engine=%s&instance=%d&from=%s&to=%s%s", engine, inst, from, to, part)
	}
	plain := call(s.JobsHistory, q("mssql", ms, ""))
	if _, ok := plain["cards"]; ok || plain["jobs"] == nil {
		t.Fatalf("the grid's own reply: parts %v, want jobs alone", keysOf(plain))
	}
	c := rowsOf(call(s.JobsHistory, q("mssql", ms, "&part=cards"))["cards"])[0]
	if fmt.Sprint(c["failed"], c["succeeded"], c["runs"], c["retries"], c["building"]) != "2 5 7 1 false" {
		t.Fatalf("SQL Server cards: %v (want failed 2, succeeded 5, runs 7, retries 1, built)", c)
	}
	cp := rowsOf(call(s.JobsHistory, q("pg", pg, "&part=cards"))["cards"])[0]
	if cp["retries"] != nil || fmt.Sprint(cp["succeeded"]) != "1" {
		t.Fatalf("PostgreSQL cards: %v (want retries NULL, succeeded 1)", cp)
	}
	head := map[string]string{}
	for _, r := range rowsOf(call(s.JobsHistory, q("mssql", ms, "&part=top"))["top"]) {
		if _, seen := head[fmt.Sprint(r["list"])]; !seen {
			head[fmt.Sprint(r["list"])] = fmt.Sprint(r["job_name"])
		}
	}
	if head["failed"] != "b-rate" || head["frequent"] != "b-ok" || head["longest"] != "b-run" {
		t.Fatalf("top 5 heads: %v (want failed b-rate, frequent b-ok, longest b-run)", head)
	}
}

func keysOf(m map[string]*table) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
