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
// a SQL Server instance with three SQL Agent jobs and a dropped one, a PostgreSQL instance with three pg_cron jobs, and
// a SQL Server instance whose hours are deferred (being built):
//   - the fleet status part carries running_since (the SQL Agent job running now from mssql_jobs.running_since; pg_cron
//     71's newest run, without an end, the newest read saw = t1; NULL for 72 with a finished run only and for 73 whose
//     run without an end is older than its job's newest read) and last_secs (the last finished run's seconds; b-ok's
//     step rows come AFTER its step-0 row, so a read without the step 0 filter gives 1 or 2, not 9);
//   - the stats part carries failed_7d from the hours (a failed and a cancelled run: 2; 'b-ok': 0), so the page's
//     failure rate is 2 / 3 for 'b-rate'; the deferred instance's job: failed_7d NULL and building;
//   - /api/jobs/history?part=cards over the whole hours: failed or cancelled 3, succeeded 5, 8 runs, 1 retry (two step
//     rows with retries 1, only one of them run_status 2: the count rule gives 1, a sum of retries 2) on SQL Server;
//     a 30-minute range inside t2's hour reads that hour whole (failed 1, succeeded 1, 2 runs; 0 on a rule of the hours
//     that started in the range); PostgreSQL: retries NULL, succeeded 3; the deferred instance: building, failed NULL;
//   - part=top: 'failed' exactly b-rate (2) then the dropped job by its name in job_versions (1), never its id;
//     'frequent' headed by b-ok, 'longest' by b-run; PostgreSQL's 'frequent' headed by 'b-cron' (the numeric id
//     against the hours' text id), not '71';
//   - the grid's own reply (no part named) carries the 'jobs' part alone, as before.
//
// Each row is its own t.Errorf, so one red run names every row that is red.
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
	// the cleanup is registered before the first instance is made, and every instance joins it as it is made
	var made []int
	defer func() {
		if len(made) == 0 {
			return
		}
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		for _, q := range []string{`DELETE FROM pgvigil.job_stats_hourly WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_stats_dirty WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.job_stats_first_build WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_stats_defer WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.job_versions WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_job_runs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_runs WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_jobs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.jobs WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(c, q, made); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
	}()
	sfx := time.Now().UnixNano() % 1000000000
	instance := func(name, platform, version string, num int, engine string) int {
		t.Helper()
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, $3, $4, false, '{}'::text[], $5)`,
			fmt.Sprintf("%s-%d", name, sfx), platform, version, num, engine).Scan(&id); err != nil {
			t.Fatal(err)
		}
		made = append(made, id)
		return id
	}
	ms := instance("b9b-sql", "sqlserver", "16.0", 160000, "sqlserver")
	pg := instance("b9b-pg", "onprem", "17.0", 170000, "postgres")
	bld := instance("b9b-bld", "sqlserver", "16.0", 160000, "sqlserver")

	var t3, t2, t1 time.Time // 3 h, 2 h and 1 h back, whole hours plus 10 minutes (each run in an hour of its own)
	if err := pool.QueryRow(ctx, `SELECT date_trunc('hour', now()) - interval '3 hours' + interval '10 minutes',
	                                     date_trunc('hour', now()) - interval '2 hours' + interval '10 minutes',
	                                     date_trunc('hour', now()) - interval '1 hour' + interval '10 minutes'`).Scan(&t3, &t2, &t1); err != nil {
		t.Fatal(err)
	}
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', m) FROM unnest(ARRAY[$1::timestamptz, $2::timestamptz]) m`, t3, t1)
	// SQL Server: 'b-run' runs now (since 5 minutes) and last took 40 s; 'b-rate' failed, was cancelled and succeeded;
	// 'b-ok' succeeded three times (7, 7 and 9 s, the last 9), its step 1 retried once (a run_status 2 row, then the
	// step's success with retries 1, both after the step-0 row); 'b-gone' failed once and was dropped since (no
	// mssql_jobs row; its name only in job_versions)
	exec(`INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, category, description, last_outcome, last_run_at, running_since)
	      VALUES ($1, 'b-run', now(), 'b-run', true, 'test', 'b9b', 1, $2, now() - interval '5 minutes'),
	             ($1, 'b-rate', now(), 'b-rate', true, 'test', 'b9b', 1, $3, NULL),
	             ($1, 'b-ok', now(), 'b-ok', true, 'test', 'b9b', 1, $3, NULL)`, ms, t3, t1)
	exec(`INSERT INTO pgvigil.job_versions (instance_id, scheduler, job_id, valid_from, version_no, job_name, def_hash, definition, dropped)
	      VALUES ($1, 'sqlagent', 'b-gone', now() - interval '1 day', 1, 'b-gone-name', 'b9b', '{}'::jsonb, false)`, ms)
	exec(`INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, step_name, run_status, duration_s, retries, message)
	      VALUES ($1, $2, 1, 'b-run', 'b-run', 0, NULL, 1, 40, 0, 'The job succeeded.'),
	             ($1, $2, 2, 'b-rate', 'b-rate', 0, NULL, 0, 3, 0, 'The job failed.'),
	             ($1, $3, 3, 'b-rate', 'b-rate', 0, NULL, 3, 4, 0, 'The job was stopped prior to completion.'),
	             ($1, $4, 4, 'b-rate', 'b-rate', 0, NULL, 1, 5, 0, 'The job succeeded.'),
	             ($1, $2, 5, 'b-ok', 'b-ok', 0, NULL, 1, 7, 0, 'The job succeeded.'),
	             ($1, $3, 6, 'b-ok', 'b-ok', 0, NULL, 1, 7, 0, 'The job succeeded.'),
	             ($1, $4, 8, 'b-ok', 'b-ok', 0, NULL, 1, 9, 0, 'The job succeeded.'),
	             ($1, $4::timestamptz + interval '30 seconds', 7, 'b-ok', 'b-ok', 1, 'one', 2, 1, 1, 'step one will retry'),
	             ($1, $4::timestamptz + interval '40 seconds', 9, 'b-ok', 'b-ok', 1, 'one', 1, 2, 1, 'step one succeeded on its retry'),
	             ($1, $3, 10, 'b-gone', 'b-gone', 0, NULL, 0, 6, 0, 'The job failed.')`, ms, t3, t2, t1)
	// PostgreSQL: pg_cron job 71 finished in 20 s at t3 and in 12 s at t2 and runs now since t1; 72 finished in 5 s at
	// t2 and has no other run; 73's run without an end was last seen an hour before its job's newest read
	exec(`INSERT INTO pgvigil.jobs (instance_id, scheduler, job_id, snapshot_at, job_name, first_seen, active, is_present)
	      VALUES ($1, 'pg_cron', 71, now(), 'b-cron', now() - interval '1 day', true, true),
	             ($1, 'pg_cron', 72, now(), 'p-done', now() - interval '1 day', true, true),
	             ($1, 'pg_cron', 73, now(), 'p-stale', now() - interval '1 day', true, true)`, pg)
	exec(`INSERT INTO pgvigil.job_runs (instance_id, scheduler, job_id, run_id, status, start_time, end_time, duration_secs, snapshot_at)
	      VALUES ($1, 'pg_cron', 71, 1, 'succeeded', $2, $2::timestamptz + interval '20 seconds', 20, now()),
	             ($1, 'pg_cron', 71, 2, 'succeeded', $3, $3::timestamptz + interval '12 seconds', 12, now()),
	             ($1, 'pg_cron', 71, 3, 'running', $4, NULL, NULL, now()),
	             ($1, 'pg_cron', 72, 4, 'succeeded', $3, $3::timestamptz + interval '5 seconds', 5, now()),
	             ($1, 'pg_cron', 73, 5, 'running', $3, NULL, NULL, now() - interval '1 hour')`, pg, t3, t2, t1)
	exec(`SELECT pgvigil.import_job_stats_build($1)`, ms)
	exec(`SELECT pgvigil.import_job_stats_build($1)`, pg)
	// the deferred instance: a defer before its runs, so the trigger marks the hours dirty and builds none
	exec(`SELECT pgvigil.import_job_stats_defer($1)`, bld)
	exec(`INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, category, description, last_outcome, last_run_at)
	      VALUES ($1, 'c-bld', now(), 'c-bld', true, 'test', 'b9b', 0, $2)`, bld, t2)
	exec(`INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, step_name, run_status, duration_s, retries, message)
	      VALUES ($1, $2, 11, 'c-bld', 'c-bld', 0, NULL, 0, 3, 0, 'The job failed.')`, bld, t2)

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	// call: the parts of a 200 reply; nil (and the row red) on anything else
	call := func(h http.HandlerFunc, path string) map[string]*table {
		t.Helper()
		rec := httptest.NewRecorder()
		h(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("%s: %d %s", path, rec.Code, rec.Body.String())
			return nil
		}
		out := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Errorf("%s: %v", path, err)
			return nil
		}
		return out
	}
	rowsOf := func(parts map[string]*table, name string) []map[string]any {
		t.Helper()
		if parts == nil {
			return nil
		}
		tb := parts[name]
		if tb == nil {
			t.Errorf("the part %q is missing", name)
			return nil
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
	first := func(rs []map[string]any) map[string]any {
		if len(rs) == 0 {
			return map[string]any{}
		}
		return rs[0]
	}
	byJob := func(rs []map[string]any) map[string]map[string]any {
		m := map[string]map[string]any{}
		for _, r := range rs {
			m[fmt.Sprint(r["job_id"])] = r
		}
		return m
	}
	ids := fmt.Sprintf("%d,%d,%d", ms, pg, bld)

	st := byJob(rowsOf(call(s.JobsReport, "/api/jobsreport?part=status&ids="+ids), "status"))
	at := func(v any) string {
		if v == nil {
			return "<nil>"
		}
		if s, ok := v.(string); ok {
			if p, err := time.Parse(time.RFC3339Nano, s); err == nil {
				return p.UTC().Format(time.RFC3339)
			}
		}
		return fmt.Sprint(v)
	}
	if st["b-run"]["running_since"] == nil || st["b-rate"]["running_since"] != nil {
		t.Errorf("running_since SQL Agent: b-run %v (want a time), b-rate %v (want NULL)", st["b-run"]["running_since"], st["b-rate"]["running_since"])
	}
	if got := at(st["71"]["running_since"]); got != t1.UTC().Format(time.RFC3339) {
		t.Errorf("running_since pg_cron 71: %s (want t1 %s, its newest run without an end)", got, t1.UTC().Format(time.RFC3339))
	}
	if st["72"]["running_since"] != nil || st["73"]["running_since"] != nil {
		t.Errorf("running_since pg_cron 72 %v (a finished run only) and 73 %v (a run without an end older than its job's read): want NULL both", st["72"]["running_since"], st["73"]["running_since"])
	}
	if fmt.Sprint(st["b-ok"]["last_secs"]) != "9" || fmt.Sprint(st["b-run"]["last_secs"]) != "40" || fmt.Sprint(st["71"]["last_secs"]) != "12" {
		t.Errorf("last_secs: b-ok %v (want 9), b-run %v (want 40), pg_cron 71 %v (want 12)", st["b-ok"]["last_secs"], st["b-run"]["last_secs"], st["71"]["last_secs"])
	}
	sx := byJob(rowsOf(call(s.JobsReport, "/api/jobsreport?part=stats&ids="+ids), "stats"))
	if sx["b-rate"]["building"] != false || fmt.Sprint(sx["b-rate"]["failed_7d"]) != "2" || fmt.Sprint(sx["b-rate"]["ok_7d"]) != "1" || fmt.Sprint(sx["b-ok"]["failed_7d"]) != "0" {
		t.Errorf("stats: b-rate %v, b-ok %v (want failed_7d 2 / ok_7d 1 and failed_7d 0, built)", sx["b-rate"], sx["b-ok"])
	}
	if sx["c-bld"]["building"] != true || sx["c-bld"]["failed_7d"] != nil {
		t.Errorf("stats of the deferred instance: c-bld %v (want building, failed_7d NULL)", sx["c-bld"])
	}

	rng := func(from, to time.Time) string {
		return "&from=" + url.QueryEscape(from.Format(time.RFC3339)) + "&to=" + url.QueryEscape(to.Format(time.RFC3339))
	}
	wide := rng(t3.Add(-time.Hour), time.Now().Add(time.Minute))
	q := func(engine string, inst int, r, part string) string {
		return fmt.Sprintf("/api/jobs/history?engine=%s&instance=%d%s%s", engine, inst, r, part)
	}
	if plain := call(s.JobsHistory, q("mssql", ms, wide, "")); plain != nil && (len(plain) != 1 || plain["jobs"] == nil) {
		t.Errorf("the grid's own reply: parts %v, want jobs alone", keysOf(plain))
	}
	c := first(rowsOf(call(s.JobsHistory, q("mssql", ms, wide, "&part=cards")), "cards"))
	if fmt.Sprint(c["failed"], c["succeeded"], c["runs"], c["retries"], c["building"]) != "3 5 8 1 false" {
		t.Errorf("SQL Server cards: %v (want failed 3, succeeded 5, runs 8, retries 1 (the run_status 2 rows, not the sum of retries), built)", c)
	}
	// a 30-minute range inside t2's hour, after t2's runs: the hour counts whole
	h2 := t2.Truncate(time.Hour)
	cs := first(rowsOf(call(s.JobsHistory, q("mssql", ms, rng(h2.Add(20*time.Minute), h2.Add(50*time.Minute)), "&part=cards")), "cards"))
	if fmt.Sprint(cs["failed"], cs["succeeded"], cs["runs"]) != "2 1 3" || at(cs["hours_from"]) != h2.UTC().Format(time.RFC3339) || at(cs["hours_to"]) != h2.Add(time.Hour).UTC().Format(time.RFC3339) {
		t.Errorf("SQL Server cards of 30 minutes in t2's hour: %v (want failed 2 (b-rate's cancel, b-gone's failure), succeeded 1, runs 3, the hours %s to %s)", cs, h2.UTC().Format(time.RFC3339), h2.Add(time.Hour).UTC().Format(time.RFC3339))
	}
	cp := first(rowsOf(call(s.JobsHistory, q("pg", pg, wide, "&part=cards")), "cards"))
	if cp["retries"] != nil || fmt.Sprint(cp["succeeded"]) != "3" || cp["building"] != false {
		t.Errorf("PostgreSQL cards: %v (want retries NULL, succeeded 3, built)", cp)
	}
	cb := first(rowsOf(call(s.JobsHistory, q("mssql", bld, wide, "&part=cards")), "cards"))
	if cb["building"] != true || cb["failed"] != nil || cb["runs"] != nil || cb["retries"] != nil {
		t.Errorf("the deferred instance's cards: %v (want building, every count NULL)", cb)
	}
	lists := func(rs []map[string]any) map[string][]string {
		m := map[string][]string{}
		for _, r := range rs {
			m[fmt.Sprint(r["list"])] = append(m[fmt.Sprint(r["list"])], fmt.Sprint(r["job_name"]))
		}
		return m
	}
	top := lists(rowsOf(call(s.JobsHistory, q("mssql", ms, wide, "&part=top")), "top"))
	if fmt.Sprint(top["failed"]) != "[b-rate b-gone-name]" || len(top["frequent"]) == 0 || top["frequent"][0] != "b-ok" || len(top["longest"]) == 0 || top["longest"][0] != "b-run" {
		t.Errorf("SQL Server top 5: %v (want failed exactly [b-rate b-gone-name], frequent headed by b-ok, longest by b-run)", top)
	}
	tp := lists(rowsOf(call(s.JobsHistory, q("pg", pg, wide, "&part=top")), "top"))
	if len(tp["frequent"]) == 0 || tp["frequent"][0] != "b-cron" || len(tp["failed"]) != 0 {
		t.Errorf("PostgreSQL top 5: %v (want frequent headed by b-cron, the name, not 71; no failed list)", tp)
	}
}

func keysOf(m map[string]*table) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
