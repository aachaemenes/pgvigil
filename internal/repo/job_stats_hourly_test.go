package repo

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0139's hourly job statistics, every connection in a
// half-hour session zone (Asia/Kolkata, +05:30: the hours stay UTC hours):
//   - one INSERT of SQL Agent runs fills the UTC hours they started in, the job's outcome rows only (step 0: a stated
//     departure from DBA Dash, whose JobStats_60MIN keeps every step), exact: three successes of 3, 3 and 4 s in one
//     hour read '3/3/0 10/4/3', the step rows beside them none; a cancelled run is a failure;
//   - job_stats_7day reads DBA Dash 4.24.1's numbers (AgentJob7Day.sql): 10 s over 3 runs in one hour and 5 s over 1 in
//     the next average 4 whole seconds (the review's case: 4.2 in exact arithmetic, 3.8 as the runs' mean), the
//     longest 5, the successes 4 in 24 h and 7 days;
//   - a run in the next month (across the month's end) makes its own month's partition of the hours;
//   - a PostgreSQL run stored while it runs is not counted; the import that ends it (ON CONFLICT DO UPDATE) and adds a
//     failed run in one statement counts both; the same import again changes nothing; an ended run updated again is
//     recomputed, never counted twice;
//   - job_stats_rebuild twice equals once, and rebuilds deleted hours to the same rows; a rebuild beside an import that
//     holds the instance's lock waits for it and then reads its run (the import's own hour deleted before it commits,
//     so only the rebuild can write it);
//   - a trigger call that cannot write its hours (a table in the way of the month's partition) does not fail the
//     import: the run is stored and the alerting grid (job_status_view) reads it, a 'rollup failed' row names the hours
//     in collection_log - one, though a second import fails the same way - and one merged dirty range holds them; once
//     the cause is gone the instance's next import heals them with no hand step and writes one 'rollup healed' row;
//   - a heal removes a dirty range only as it read it: a range a failed writer widens while a heal rebuilds stays;
//   - a history import (import_job_stats_defer first) writes its day-batches with no hour built and one merged dirty
//     range, job_stats_7day says 'building' meanwhile, and a deferred write does not renew the defer;
//     import_job_stats_build at its end builds every hour once; a defer that lapsed no longer holds a write back;
//   - the first build is no migration row (a migrated store holds no '0139' dirty range): an instance whose runs were
//     stored before 0139 (no hours, no first build queued) reads 'building' in job_stats_7day, is built whole by its
//     first write, and a quiet one by the purge command's heals (job_stats_pending, job_stats_heal_one); under a heal
//     budget of 0 ms an import heals one week, newest first, and the oldest hour is built by a later import;
//   - job_stats_hourly_purge drops the months older than hours_retention's 730 days and returns their names.
func TestJobStatsHourlyOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["timezone"] = "Asia/Kolkata"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close) // registered first: it runs after the data cleanup below
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
	}
	str := func(sql string, args ...any) string {
		t.Helper()
		var s string
		if err := pool.QueryRow(ctx, sql, args...).Scan(&s); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
		return s
	}
	var have bool
	if err := pool.QueryRow(ctx, `SELECT to_regclass('pgvigil.job_stats_hourly') IS NOT NULL`).Scan(&have); err != nil {
		t.Fatal(err)
	}
	if !have {
		t.Fatal("0139 not applied: pgvigil.job_stats_hourly does not exist")
	}
	// the test makes and drops March 2019's partitions: a store that holds them already is not this test's
	if got := str(`SELECT coalesce(string_agg(n, ' '), '') FROM unnest(ARRAY['pgvigil.job_stats_hourly_201903', 'pgvigil.mssql_job_runs_201903']) n
	                WHERE to_regclass(n) IS NOT NULL`); got != "" {
		t.Skipf("the store already holds %s: the test would drop it", got)
	}
	sfx := time.Now().UnixNano() % 1000000000
	var ms, pg, up1, up2, up3 int
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 20*time.Second)
		defer stop()
		ids := []int{}
		for _, id := range []int{ms, pg, up1, up2, up3} {
			if id > 0 {
				ids = append(ids, id)
			}
		}
		for _, q := range []string{
			`DELETE FROM pgvigil.job_stats_hourly WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_stats_dirty WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.job_stats_defer WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_stats_first_build WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_job_runs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_runs WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_jobs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.jobs WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.collection_log WHERE instance_id = ANY($1) AND collection = 'job_stats_hourly'`,
			`DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(c, q, ids); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
		for _, q := range []string{`DROP TABLE IF EXISTS pgvigil.job_stats_hourly_201903`, `DROP TABLE IF EXISTS pgvigil.mssql_job_runs_201903`} {
			if _, err := pool.Exec(c, q); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
	})
	newSQL := func(name string) int {
		t.Helper()
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("jobhours-%s-%d", name, sfx)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	ms = newSQL("sql")
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("jobhours-pg-%d", sfx)).Scan(&pg); err != nil {
		t.Fatal(err)
	}
	if got := str(`SELECT days::text FROM pgvigil.hours_retention WHERE table_name = 'job_stats_hourly'`); got != "730" {
		t.Errorf("hours_retention job_stats_hourly = %s days, want 730", got)
	}
	if got := str(`SELECT count(*)::text FROM pgvigil.job_stats_dirty WHERE why LIKE '0139%'`); got != "0" {
		t.Errorf("the migration wrote %s first-build dirty row(s), want 0 (no migration writes a stored row)", got)
	}
	// h1: the UTC hour five hours back; h2 the next
	var h1 time.Time
	if err := pool.QueryRow(ctx, `SELECT date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - interval '5 hours'`).Scan(&h1); err != nil {
		t.Fatal(err)
	}
	h2 := h1.Add(time.Hour)
	d1, d2, d3 := h1.Add(-72*time.Hour), h1.Add(-48*time.Hour), h1.Add(-24*time.Hour)
	d20 := h1.Add(-20 * 24 * time.Hour)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', m) FROM unnest(ARRAY[$1::timestamptz, $2::timestamptz, $3::timestamptz, $4::timestamptz, $5::timestamptz, $6::timestamptz]) m`,
		h1, h2, d1, d2, d3, d20)
	hid := 0
	type mrun struct {
		job    string
		step   int
		at     time.Time
		status int
		secs   int
	}
	// runsSQL: ONE INSERT of an instance's runs (as an import writes them)
	runsSQL := func(inst int, runs ...mrun) (string, []any) {
		sql := `INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, run_status, duration_s, retries) VALUES `
		args := []any{inst}
		for i, r := range runs {
			hid++
			if i > 0 {
				sql += ", "
			}
			n := len(args)
			sql += fmt.Sprintf("($1, $%d, $%d, $%d, $%d, $%d, $%d, $%d, 0)", n+1, n+2, n+3, n+3, n+4, n+5, n+6)
			args = append(args, r.at, int64(hid), r.job, r.step, r.status, r.secs)
		}
		return sql, args
	}
	msRunsOf := func(inst int, runs ...mrun) {
		t.Helper()
		sql, args := runsSQL(inst, runs...)
		exec(sql, args...)
	}
	msRuns := func(runs ...mrun) {
		t.Helper()
		msRunsOf(ms, runs...)
	}
	hour := func(inst int, sched, job string, step int, at time.Time) string {
		t.Helper()
		return str(`SELECT coalesce((SELECT format('%s/%s/%s %s/%s/%s', runs, succeeded, failed, total_secs, max_secs, min_secs)
		                               FROM pgvigil.job_stats_hourly WHERE instance_id = $1 AND scheduler = $2 AND job_id = $3 AND step_id = $4
		                                AND snapshot_at = date_trunc('hour', $5::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'), 'none')`,
			inst, sched, job, step, at)
	}
	want := func(name, got, w string) {
		t.Helper()
		if got != w {
			t.Errorf("%s: got %s, want %s", name, got, w)
		}
	}
	jobsOf := func(inst int, jobs ...string) {
		t.Helper()
		for _, j := range jobs {
			exec(`INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, category, description)
			      VALUES ($1, $2, now(), 'job ' || $2, true, 'test', 'job_stats_hourly_test')`, inst, j)
		}
	}
	jobsOf(ms, "a", "b", "c", "d", "e", "f", "g")
	// seven: the 7-day columns of one job as the page reads them, 'null' for a NULL, then the 'building' flag
	seven := func(inst int, job string) string {
		t.Helper()
		return str(`SELECT format('%s %s %s %s %s', coalesce(ok_24h::text, 'null'), coalesce(ok_7d::text, 'null'), coalesce(max_secs_7d::text, 'null'),
		                          coalesce(avg_secs_7d::text, 'null'), building::text) FROM pgvigil.job_stats_7day(ARRAY[$1::int]) WHERE job_id = $2`, inst, job)
	}
	dirty := func(inst int) string {
		t.Helper()
		return str(`SELECT coalesce(string_agg(format('%s %s %s', source, to_char(from_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), to_char(to_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI')), ', ' ORDER BY source), 'none')
		              FROM pgvigil.job_stats_dirty WHERE instance_id = $1`, inst)
	}
	utc := func(at time.Time) string { return at.UTC().Format("2006-01-02 15:04") }

	// 1. the hours and DBA Dash's arithmetic
	plus := func(at time.Time, m int) time.Time { return at.Add(time.Duration(m) * time.Minute) }
	msRuns(mrun{"a", 0, plus(h1, 5), 1, 3}, mrun{"a", 1, plus(h1, 5), 1, 2}, mrun{"a", 0, plus(h1, 20), 1, 3}, mrun{"a", 1, plus(h1, 20), 1, 2},
		mrun{"a", 0, plus(h1, 40), 1, 4}, mrun{"a", 1, plus(h1, 40), 1, 2}, mrun{"a", 0, plus(h2, 10), 1, 5}, mrun{"b", 0, plus(h1, 10), 3, 7})
	want("job a step 0, its first hour", hour(ms, "sqlagent", "a", 0, h1), "3/3/0 10/4/3")
	want("job a step 1: no step rows in the hours (step 0 only, a departure from DBA Dash)", hour(ms, "sqlagent", "a", 1, h1), "none")
	want("job a step 0, its second hour", hour(ms, "sqlagent", "a", 0, h2), "1/1/0 5/5/5")
	want("job b, a cancelled run is a failure", hour(ms, "sqlagent", "b", 0, h1), "1/0/1 7/7/7")
	want("job_stats_7day job a (DBA Dash's whole seconds: (10 / 3 -> 3, 5 / 1 -> 5) -> 4)", seven(ms, "a"), "4 4 5 4 false")
	want("job_stats_7day job b", seven(ms, "b"), "0 0 7 7 false")

	// 2. across the month's end: the run of the next month makes its month's partition of the hours
	var nm time.Time
	if err := pool.QueryRow(ctx, `SELECT (date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month 5 minutes') AT TIME ZONE 'UTC'`).Scan(&nm); err != nil {
		t.Fatal(err)
	}
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', $1)`, nm)
	msRuns(mrun{"c", 0, nm, 1, 9})
	want("job c across the month's end", hour(ms, "sqlagent", "c", 0, nm), "1/1/0 9/9/9")
	want("the next month's partition of the hours", str(`SELECT (to_regclass('pgvigil.job_stats_hourly_' || to_char($1::timestamptz AT TIME ZONE 'UTC', 'YYYYMM')) IS NOT NULL)::text`, nm), "true")

	// 3. PostgreSQL: a run stored while it runs, then ended by the next import with a failed run in the same statement
	exec(`INSERT INTO pgvigil.jobs (instance_id, scheduler, job_id, snapshot_at, job_name, schedule, command, datname, active, first_seen, is_present)
	      VALUES ($1, 'pg_cron', 7, now(), 'job 7', '*/30 * * * *', 'SELECT 1', 'postgres', true, now() - interval '1 day', true)`, pg)
	exec(`INSERT INTO pgvigil.job_runs (instance_id, scheduler, job_id, run_id, status, start_time, end_time, duration_secs, snapshot_at)
	      VALUES ($1, 'pg_cron', 7, 1, 'running', $2, NULL, NULL, $2)`, pg, plus(h1, 5))
	want("a PostgreSQL run not ended", hour(pg, "pg_cron", "7", 0, h1), "none")
	importPg := `INSERT INTO pgvigil.job_runs AS x (instance_id, scheduler, job_id, run_id, status, start_time, end_time, duration_secs, snapshot_at)
	      VALUES ($1, 'pg_cron', 7, 1, 'succeeded', $2, $2::timestamptz + interval '4 seconds', 4, $2),
	             ($1, 'pg_cron', 7, 2, 'failed', $3, $3::timestamptz + interval '6 seconds', 6, $3)
	      ON CONFLICT (instance_id, scheduler, job_id, run_id) DO UPDATE SET status = excluded.status, end_time = excluded.end_time, duration_secs = excluded.duration_secs
	      WHERE x.end_time IS NULL`
	exec(importPg, pg, plus(h1, 5), plus(h1, 30))
	want("the import that ends it and adds a failed run", hour(pg, "pg_cron", "7", 0, h1), "2/1/1 10/6/4")
	exec(importPg, pg, plus(h1, 5), plus(h1, 30))
	want("the same import again", hour(pg, "pg_cron", "7", 0, h1), "2/1/1 10/6/4")
	exec(`UPDATE pgvigil.job_runs SET duration_secs = 9 WHERE instance_id = $1 AND run_id = 1`, pg)
	want("an ended run updated again", hour(pg, "pg_cron", "7", 0, h1), "2/1/1 15/9/6")

	// 4. job_stats_rebuild: twice = once; deleted hours rebuilt to the same rows
	fingerprint := func() string {
		t.Helper()
		return str(`SELECT coalesce(md5(string_agg(format('%s', s), ',' ORDER BY s.job_id, s.step_id, s.snapshot_at)), '') FROM pgvigil.job_stats_hourly s WHERE s.instance_id = $1`, ms)
	}
	before := fingerprint()
	exec(`SELECT pgvigil.job_stats_rebuild($1, '-infinity', 'infinity')`, ms)
	exec(`SELECT pgvigil.job_stats_rebuild($1, '-infinity', 'infinity')`, ms)
	want("two rebuilds change nothing", fingerprint(), before)
	exec(`DELETE FROM pgvigil.job_stats_hourly WHERE instance_id = $1 AND job_id = 'a'`, ms)
	exec(`SELECT pgvigil.job_stats_rebuild($1, '-infinity', 'infinity')`, ms)
	want("deleted hours rebuilt", fingerprint(), before)

	// 5. a rebuild beside an import that holds the instance's lock: it waits, then reads the import's run - the hour the
	// import's own trigger wrote is deleted inside the import's transaction, so only the rebuild can write it again
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	hid++
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, run_status, duration_s, retries)
	                           VALUES ($1, $2, $3, 'd', 'd', 0, 1, 6, 0)`, ms, plus(h2, 15), int64(hid)); err != nil {
		_ = tx.Rollback(ctx)
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM pgvigil.job_stats_hourly WHERE instance_id = $1 AND job_id = 'd'`, ms); err != nil {
		_ = tx.Rollback(ctx)
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := pool.Exec(ctx, `SELECT pgvigil.job_stats_rebuild($1, '-infinity', 'infinity')`, ms)
		done <- err
	}()
	time.Sleep(700 * time.Millisecond)
	select {
	case err := <-done:
		t.Errorf("the rebuild did not wait for the import's lock (it ended first: %v)", err)
	default:
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("the rebuild after the import: %v", err)
		}
	case <-time.After(20 * time.Second):
		t.Error("the rebuild did not end 20 s after the import committed")
	}
	want("job d's hour, written by the rebuild that waited", hour(ms, "sqlagent", "d", 0, h2), "1/1/0 6/6/6")

	// 6. a trigger call that cannot write its hours, and the automatic heal
	old := time.Date(2019, 3, 10, 10, 10, 0, 0, time.UTC)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', $1)`, old)
	// the job row as the collector's read of a job whose last run failed holds it: job_status_view looks past its horizon
	// only on the row's own last_outcome (0137 L85)
	exec(`UPDATE pgvigil.mssql_jobs SET last_outcome = 0, last_run_at = $2 WHERE instance_id = $1 AND job_id = 'e'`, ms, plus(old, 20))
	exec(`CREATE TABLE pgvigil.job_stats_hourly_201903 (in_the_way int)`) // ensure_month_partition sees the name and makes no partition
	msRuns(mrun{"e", 0, old, 0, 3})                                       // the import itself must not fail
	msRuns(mrun{"e", 0, plus(old, 20), 0, 3})                             // a second import fails the same way: no second log row
	want("the runs of the failed rollup are stored", str(`SELECT count(*)::text FROM pgvigil.mssql_job_runs WHERE instance_id = $1 AND job_id = 'e'`, ms), "2")
	want("the alerting grid reads it", str(`SELECT coalesce(to_char(last_failed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), 'none') FROM pgvigil.job_status_view(ARRAY[$1::int]) WHERE job_id = 'e'`, ms), "2019-03-10 10:30")
	want("no hour for it yet", hour(ms, "sqlagent", "e", 0, old), "none")
	want("one 'rollup failed' row for the two failed calls", str(`SELECT count(*)::text FROM pgvigil.collection_log WHERE instance_id = $1 AND collection = 'job_stats_hourly' AND status = 'error'
	                                       AND note LIKE '%2019-03-10 10:00%' AND note LIKE 'rollup failed%'`, ms), "1")
	want("one merged dirty range", dirty(ms), "mssql_job_runs 2019-03-10 10:00 2019-03-10 11:00")
	exec(`DROP TABLE pgvigil.job_stats_hourly_201903`)
	msRuns(mrun{"a", 0, plus(h2, 50), 1, 1}) // the instance's next import
	want("healed by the next import", hour(ms, "sqlagent", "e", 0, old), "2/0/2 6/3/3")
	want("no dirty range left", dirty(ms), "none")
	want("one 'rollup healed' row", str(`SELECT count(*)::text FROM pgvigil.collection_log WHERE instance_id = $1 AND collection = 'job_stats_hourly' AND status = 'ok'
	                                       AND note LIKE 'rollup healed: the mssql_job_runs hours 2019-03-10 10:00 to 2019-03-10 11:00%'`, ms), "1")
	want("that import's own hour", hour(ms, "sqlagent", "a", 0, h2), "2/2/0 6/5/1")

	// 10. a heal removes a range only as it read it: the heal (import_job_stats_build) reads ms's range of h1 and waits
	// on a row of job a's h1 hour another transaction holds; a writer that failed meanwhile widens the range to h2's
	// end and commits; the heal's end leaves the widened range
	exec(`INSERT INTO pgvigil.job_stats_dirty (instance_id, source, from_at, to_at, why) VALUES ($1, 'mssql_job_runs', $2, $3, 'the test')`, ms, h1, h2)
	holder, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := holder.Exec(ctx, `UPDATE pgvigil.job_stats_hourly SET runs = runs WHERE instance_id = $1 AND job_id = 'a' AND step_id = 0 AND snapshot_at = $2`, ms, h1); err != nil {
		_ = holder.Rollback(ctx)
		t.Fatal(err)
	}
	healed := make(chan error, 1)
	go func() {
		_, err := pool.Exec(ctx, `SELECT pgvigil.import_job_stats_build($1)`, ms)
		healed <- err
	}()
	time.Sleep(700 * time.Millisecond)
	exec(`SELECT pgvigil.job_stats_failed($1, 'mssql_job_runs', $2, $3, 'a writer that failed during the heal')`, ms, h2, h2.Add(time.Hour))
	if err := holder.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-healed:
		if err != nil {
			t.Errorf("the heal: %v", err)
		}
	case <-time.After(20 * time.Second):
		t.Error("the heal did not end 20 s after the row was let go")
	}
	want("the range widened during the heal stays", dirty(ms), fmt.Sprintf("mssql_job_runs %s %s", utc(h1), utc(h2.Add(time.Hour))))
	exec(`SELECT pgvigil.import_job_stats_build($1)`, ms)
	want("and the next heal takes it", dirty(ms), "none")

	// 8. a history import: deferred, three day-batches, one build; then a lapsed defer
	exec(`SELECT pgvigil.import_job_stats_defer($1)`, ms)
	exec(`UPDATE pgvigil.job_stats_defer SET until_at = now() + interval '10 minutes' WHERE instance_id = $1`, ms)
	msRuns(mrun{"f", 0, plus(d1, 5), 1, 2})
	msRuns(mrun{"f", 0, plus(d2, 5), 1, 4})
	msRuns(mrun{"f", 0, plus(d3, 5), 0, 6})
	want("a deferred batch builds no hour", hour(ms, "sqlagent", "f", 0, d2), "none")
	want("the three batches' one merged range", str(`SELECT coalesce(string_agg(format('%s %s %s', source, to_char(from_at AT TIME ZONE 'UTC', 'MM-DD HH24:MI'), to_char(to_at AT TIME ZONE 'UTC', 'MM-DD HH24:MI')), ', '), 'none')
	                                                 FROM pgvigil.job_stats_dirty WHERE instance_id = $1 AND why = 'deferred'`, ms),
		fmt.Sprintf("mssql_job_runs %s %s", d1.UTC().Format("01-02 15:04"), d3.Add(time.Hour).UTC().Format("01-02 15:04")))
	want("a deferred write does not renew the defer", str(`SELECT (until_at <= now() + interval '10 minutes')::text FROM pgvigil.job_stats_defer WHERE instance_id = $1`, ms), "true")
	want("job_stats_7day while the import's range is not built", seven(ms, "f"), "null null null null true")
	var built int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_job_stats_build($1)`, ms).Scan(&built); err != nil {
		t.Fatal(err)
	}
	want("the build at the import's end", fmt.Sprintf("%s | %s | %s", hour(ms, "sqlagent", "f", 0, d1), hour(ms, "sqlagent", "f", 0, d2), hour(ms, "sqlagent", "f", 0, d3)),
		"1/1/0 2/2/2 | 1/1/0 4/4/4 | 1/0/1 6/6/6")
	want("nothing dirty or deferred after the build", str(`SELECT (SELECT count(*) FROM pgvigil.job_stats_dirty WHERE instance_id = $1) || ' ' || (SELECT count(*) FROM pgvigil.job_stats_defer WHERE instance_id = $1)`, ms), "0 0")
	want("job_stats_7day after the build", seven(ms, "f"), "0 2 6 4 false")
	exec(`INSERT INTO pgvigil.job_stats_defer (instance_id, until_at) VALUES ($1, now() - interval '1 minute')`, ms) // an import that died
	msRuns(mrun{"g", 0, plus(h1, 45), 1, 8})
	want("a lapsed defer holds nothing back", hour(ms, "sqlagent", "g", 0, h1), "1/1/0 8/8/8")
	exec(`DELETE FROM pgvigil.job_stats_defer WHERE instance_id = $1`, ms)

	// 9. instances whose runs were stored before 0139 (an upgraded store: no hours, no first build queued): runs written
	// with the trigger off, in one transaction; up1's next import builds its whole range, up2 writes no more (step 7's
	// purge heals), up3 heals under a budget of 0 ms - one week an import, newest first
	up1, up2, up3 = newSQL("up1"), newSQL("up2"), newSQL("up3")
	jobsOf(up2, "a")
	before0139 := func(inst int, runs ...mrun) {
		t.Helper()
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx.Rollback(ctx) }()
		sql, args := runsSQL(inst, runs...)
		if _, err := tx.Exec(ctx, `ALTER TABLE pgvigil.mssql_job_runs DISABLE TRIGGER job_stats_hourly_ins`); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
		if _, err := tx.Exec(ctx, `ALTER TABLE pgvigil.mssql_job_runs ENABLE TRIGGER job_stats_hourly_ins`); err != nil {
			t.Fatal(err)
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
	before0139(up1, mrun{"a", 0, plus(d1, 5), 1, 2})
	before0139(up2, mrun{"a", 0, plus(h1, 5), 1, 4})
	before0139(up3, mrun{"a", 0, plus(d20, 5), 1, 7}, mrun{"a", 0, plus(d3, 5), 1, 3})
	want("a run stored before 0139 has no hour", hour(up1, "sqlagent", "a", 0, d1), "none")
	want("job_stats_7day of an upgraded instance not built yet", seven(up2, "a"), "null null null null true")
	msRunsOf(up1, mrun{"a", 0, plus(h1, 5), 1, 1})
	want("the upgraded instance's first write builds its whole range (the old run's hour)", hour(up1, "sqlagent", "a", 0, d1), "1/1/0 2/2/2")
	want("and its own hour", hour(up1, "sqlagent", "a", 0, h1), "1/1/0 1/1/1")
	// up3 under a budget of 0 ms: each import heals one week of the range, newest first
	budgeted := func(inst int, r mrun) {
		t.Helper()
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx.Rollback(ctx) }()
		sql, args := runsSQL(inst, r)
		if _, err := tx.Exec(ctx, `SET LOCAL pgvigil.job_stats_heal_ms = 0`); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
	budgeted(up3, mrun{"a", 0, plus(h1, 5), 1, 1})
	want("the budget's first import: the newest week's old run built", hour(up3, "sqlagent", "a", 0, d3), "1/1/0 3/3/3")
	want("the budget's first import: the 20-day-old run not yet", hour(up3, "sqlagent", "a", 0, d20), "none")
	if got := dirty(up3); !strings.Contains(got, "mssql_job_runs ") {
		t.Errorf("the rest of up3's range after one budgeted import: got %s, want the SQL Agent range kept", got)
	}
	imports := 1
	for ; imports < 8 && dirty(up3) != "none"; imports++ {
		budgeted(up3, mrun{"a", 0, plus(h1, 10+imports), 1, 1})
	}
	want(fmt.Sprintf("the 20-day-old run built by a later import (%d imports)", imports), hour(up3, "sqlagent", "a", 0, d20), "1/1/0 7/7/7")
	want("up3's range all healed", dirty(up3), "none")
	if imports < 2 {
		t.Errorf("up3 healed in %d budgeted import(s), want 2 or more (one week an import; the weeks with no run skipped)", imports)
	}

	// 7. job_stats_hourly_purge drops the months older than 730 days and returns their names; the purge command's heals
	// (job_stats_pending, job_stats_heal_one) take a quiet instance's dirty range and a quiet upgraded instance
	exec(`SELECT pgvigil.ensure_month_partition('job_stats_hourly', $1)`, old)
	exec(`DELETE FROM pgvigil.job_stats_hourly WHERE instance_id = $1`, pg)
	exec(`INSERT INTO pgvigil.job_stats_dirty (instance_id, source, from_at, to_at, why) VALUES ($1, 'job_runs', $2, $3, 'the test')`, pg, h1, h2)
	want("job_stats_hourly_purge's dropped months", str(`SELECT array_to_string(pgvigil.job_stats_hourly_purge(), ' ')`), "job_stats_hourly_201903")
	want("2019-03's hours dropped", str(`SELECT (to_regclass('pgvigil.job_stats_hourly_201903') IS NULL)::text`), "true")
	want("the instances pending a heal", str(`SELECT coalesce(string_agg(i::text, ' ' ORDER BY i), 'none') FROM pgvigil.job_stats_pending() i WHERE i = ANY($1)`, []int{ms, pg, up1, up2, up3}),
		fmt.Sprintf("%d %d", pg, up2))
	exec(`SELECT pgvigil.job_stats_heal_one(i) FROM pgvigil.job_stats_pending() i WHERE i = ANY($1)`, []int{pg, up2})
	want("the quiet instance healed", hour(pg, "pg_cron", "7", 0, h1), "2/1/1 15/9/6")
	want("its dirty range gone", dirty(pg), "none")
	want("the quiet upgraded instance built whole", hour(up2, "sqlagent", "a", 0, h1), "1/1/0 4/4/4")
	want("job_stats_7day of it now", seven(up2, "a"), "1 1 4 4 false")
	want("the upgraded instances' first builds queued", str(`SELECT count(*)::text FROM pgvigil.job_stats_first_build WHERE instance_id = ANY($1)`, []int{up1, up2, up3}), "3")
}
