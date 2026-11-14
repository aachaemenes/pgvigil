package repo

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0139's hourly job statistics:
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
//     holds the instance's lock waits for it and then reads its run;
//   - a trigger call that cannot write its hours (a table in the way of the month's partition) does not fail the
//     import: the run is stored and the alerting grid (job_status_view) reads it, a 'rollup failed' row names the hours
//     in collection_log, a dirty range holds them; once the cause is gone the instance's next import heals them with
//     no hand step;
//   - a history import (job_stats_defer first) writes its day-batches with no hour built and one merged dirty range;
//     job_stats_build at its end builds every hour once; a defer that lapsed no longer holds a write back;
//   - the first build is no migration row (a migrated store holds no '0139' dirty range): an instance whose runs were
//     stored before 0139 (no hours, no job_stats_built marker) is built whole by its first write, and a quiet one by
//     job_stats_hourly_purge;
//   - job_stats_hourly_purge drops the months older than hours_retention's 730 days and heals a quiet instance's dirty
//     range.
func TestJobStatsHourlyOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
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
	sfx := time.Now().UnixNano() % 1000000000
	var ms, pg, up1, up2 int
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 20*time.Second)
		defer stop()
		ids := []int{}
		for _, id := range []int{ms, pg, up1, up2} {
			if id > 0 {
				ids = append(ids, id)
			}
		}
		for _, q := range []string{
			`DELETE FROM pgvigil.job_stats_hourly WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_stats_dirty WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.job_stats_defer WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_stats_built WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_job_runs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.job_runs WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_jobs WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.jobs WHERE instance_id = ANY($1)`,
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
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("jobhours-sql-%d", sfx)).Scan(&ms); err != nil {
		t.Fatal(err)
	}
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
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', m) FROM unnest(ARRAY[$1::timestamptz, $2::timestamptz]) m`, h1, h2)
	hid := 0
	type mrun struct {
		job    string
		step   int
		at     time.Time
		status int
		secs   int
	}
	// msRunsOf: ONE INSERT of an instance's runs (as an import writes them); msRuns: the SQL Server instance's
	msRunsOf := func(inst int, runs ...mrun) {
		t.Helper()
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
	for _, j := range []string{"a", "b", "c", "d", "e", "f", "g"} {
		exec(`INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, category, description)
		      VALUES ($1, $2, now(), 'job ' || $2, true, 'test', 'job_stats_hourly_test')`, ms, j)
	}

	// 1. the hours and DBA Dash's arithmetic
	plus := func(at time.Time, m int) time.Time { return at.Add(time.Duration(m) * time.Minute) }
	msRuns(mrun{"a", 0, plus(h1, 5), 1, 3}, mrun{"a", 1, plus(h1, 5), 1, 2}, mrun{"a", 0, plus(h1, 20), 1, 3}, mrun{"a", 1, plus(h1, 20), 1, 2},
		mrun{"a", 0, plus(h1, 40), 1, 4}, mrun{"a", 1, plus(h1, 40), 1, 2}, mrun{"a", 0, plus(h2, 10), 1, 5}, mrun{"b", 0, plus(h1, 10), 3, 7})
	want("job a step 0, its first hour", hour(ms, "sqlagent", "a", 0, h1), "3/3/0 10/4/3")
	want("job a step 1: no step rows in the hours (step 0 only, a departure from DBA Dash)", hour(ms, "sqlagent", "a", 1, h1), "none")
	want("job a step 0, its second hour", hour(ms, "sqlagent", "a", 0, h2), "1/1/0 5/5/5")
	want("job b, a cancelled run is a failure", hour(ms, "sqlagent", "b", 0, h1), "1/0/1 7/7/7")
	seven := func(job string) string {
		t.Helper()
		return str(`SELECT format('%s %s %s %s', ok_24h, ok_7d, max_secs_7d, avg_secs_7d) FROM pgvigil.job_stats_7day(ARRAY[$1::int]) WHERE job_id = $2`, ms, job)
	}
	want("job_stats_7day job a (DBA Dash's whole seconds: (10 / 3 -> 3, 5 / 1 -> 5) -> 4)", seven("a"), "4 4 5 4")
	want("job_stats_7day job b", seven("b"), "0 0 7 7")

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

	// 5. a rebuild beside an import that holds the instance's lock: it waits, then reads the import's run
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
	want("job d after the import and the rebuild", hour(ms, "sqlagent", "d", 0, h2), "1/1/0 6/6/6")

	// 6. a trigger call that cannot write its hours, and the automatic heal
	old := time.Date(2019, 3, 10, 10, 10, 0, 0, time.UTC)
	exec(`DROP TABLE IF EXISTS pgvigil.job_stats_hourly_201903`)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', $1)`, old)
	// the job row as the collector's read of a job whose last run failed holds it: job_status_view looks past its horizon
	// only on the row's own last_outcome (0137 L85)
	exec(`UPDATE pgvigil.mssql_jobs SET last_outcome = 0, last_run_at = $2 WHERE instance_id = $1 AND job_id = 'e'`, ms, old)
	exec(`CREATE TABLE pgvigil.job_stats_hourly_201903 (in_the_way int)`) // ensure_month_partition sees the name and makes no partition
	msRuns(mrun{"e", 0, old, 0, 3})                                       // the import itself must not fail
	want("the run of the failed rollup is stored", str(`SELECT count(*)::text FROM pgvigil.mssql_job_runs WHERE instance_id = $1 AND job_id = 'e'`, ms), "1")
	want("the alerting grid reads it", str(`SELECT coalesce(to_char(last_failed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), 'none') FROM pgvigil.job_status_view(ARRAY[$1::int]) WHERE job_id = 'e'`, ms), "2019-03-10 10:10")
	want("no hour for it yet", hour(ms, "sqlagent", "e", 0, old), "none")
	want("the 'rollup failed' row", str(`SELECT count(*)::text FROM pgvigil.collection_log WHERE instance_id = $1 AND collection = 'job_stats_hourly' AND status = 'error'
	                                       AND note LIKE '%2019-03-10 10:00%' AND note LIKE 'rollup failed%'`, ms), "1")
	want("the dirty range", str(`SELECT coalesce(string_agg(format('%s %s %s', source, to_char(from_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), to_char(to_at AT TIME ZONE 'UTC', 'HH24:MI')), ', '), 'none')
	                              FROM pgvigil.job_stats_dirty WHERE instance_id = $1`, ms), "mssql_job_runs 2019-03-10 10:00 11:00")
	exec(`DROP TABLE pgvigil.job_stats_hourly_201903`)
	msRuns(mrun{"a", 0, plus(h2, 50), 1, 1}) // the instance's next import
	want("healed by the next import", hour(ms, "sqlagent", "e", 0, old), "1/0/1 3/3/3")
	want("no dirty range left", str(`SELECT count(*)::text FROM pgvigil.job_stats_dirty WHERE instance_id = $1`, ms), "0")
	want("that import's own hour", hour(ms, "sqlagent", "a", 0, h2), "2/2/0 6/5/1")

	// 8. a history import: deferred, three day-batches, one build; then a lapsed defer
	d1, d2, d3 := h1.Add(-72*time.Hour), h1.Add(-48*time.Hour), h1.Add(-24*time.Hour)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', m) FROM unnest(ARRAY[$1::timestamptz, $2::timestamptz, $3::timestamptz]) m`, d1, d2, d3)
	exec(`SELECT pgvigil.job_stats_defer($1)`, ms)
	msRuns(mrun{"f", 0, plus(d1, 5), 1, 2})
	msRuns(mrun{"f", 0, plus(d2, 5), 1, 4})
	msRuns(mrun{"f", 0, plus(d3, 5), 0, 6})
	want("a deferred batch builds no hour", hour(ms, "sqlagent", "f", 0, d2), "none")
	want("the three batches' one merged range", str(`SELECT coalesce(string_agg(format('%s %s %s', source, to_char(from_at AT TIME ZONE 'UTC', 'MM-DD HH24:MI'), to_char(to_at AT TIME ZONE 'UTC', 'MM-DD HH24:MI')), ', '), 'none')
	                                                 FROM pgvigil.job_stats_dirty WHERE instance_id = $1 AND why = 'deferred'`, ms),
		fmt.Sprintf("mssql_job_runs %s %s", d1.UTC().Format("01-02 15:04"), d3.Add(time.Hour).UTC().Format("01-02 15:04")))
	var built int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.job_stats_build($1)`, ms).Scan(&built); err != nil {
		t.Fatal(err)
	}
	want("the build at the import's end", fmt.Sprintf("%s | %s | %s", hour(ms, "sqlagent", "f", 0, d1), hour(ms, "sqlagent", "f", 0, d2), hour(ms, "sqlagent", "f", 0, d3)),
		"1/1/0 2/2/2 | 1/1/0 4/4/4 | 1/0/1 6/6/6")
	want("nothing dirty or deferred after the build", str(`SELECT (SELECT count(*) FROM pgvigil.job_stats_dirty WHERE instance_id = $1) || ' ' || (SELECT count(*) FROM pgvigil.job_stats_defer WHERE instance_id = $1)`, ms), "0 0")
	exec(`INSERT INTO pgvigil.job_stats_defer (instance_id, until_at) VALUES ($1, now() - interval '1 minute')`, ms) // an import that died
	msRuns(mrun{"g", 0, plus(h1, 45), 1, 8})
	want("a lapsed defer holds nothing back", hour(ms, "sqlagent", "g", 0, h1), "1/1/0 8/8/8")
	exec(`DELETE FROM pgvigil.job_stats_defer WHERE instance_id = $1`, ms)

	// 9. instances whose runs were stored before 0139 (an upgraded store: no hours, no build marker): runs written with
	// the trigger off, in one transaction; up1's next import builds its whole range, up2 writes no more (step 7's purge)
	for i, id := range []*int{&up1, &up2} {
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("jobhours-up%d-%d", i+1, sfx)).Scan(id); err != nil {
			t.Fatal(err)
		}
	}
	before0139 := func(inst int, at time.Time, secs int) {
		t.Helper()
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx.Rollback(ctx) }()
		hid++
		for _, q := range []string{`ALTER TABLE pgvigil.mssql_job_runs DISABLE TRIGGER job_stats_hourly_ins`,
			fmt.Sprintf(`INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, run_status, duration_s, retries)
			             VALUES (%d, '%s', %d, 'a', 'a', 0, 1, %d, 0)`, inst, at.UTC().Format(time.RFC3339), hid, secs),
			`ALTER TABLE pgvigil.mssql_job_runs ENABLE TRIGGER job_stats_hourly_ins`} {
			if _, err := tx.Exec(ctx, q); err != nil {
				t.Fatalf("%v\n%s", err, q)
			}
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
	before0139(up1, plus(d1, 5), 2)
	before0139(up2, plus(d2, 5), 4)
	want("a run stored before 0139 has no hour", hour(up1, "sqlagent", "a", 0, d1), "none")
	msRunsOf(up1, mrun{"a", 0, plus(h1, 5), 1, 1})
	want("the upgraded instance's first write builds its whole range (the old run's hour)", hour(up1, "sqlagent", "a", 0, d1), "1/1/0 2/2/2")
	want("and its own hour", hour(up1, "sqlagent", "a", 0, h1), "1/1/0 1/1/1")

	// 7. job_stats_hourly_purge: the months older than 730 days go; a quiet instance's dirty range is healed
	exec(`DELETE FROM pgvigil.job_stats_hourly WHERE instance_id = $1`, pg)
	exec(`INSERT INTO pgvigil.job_stats_dirty (instance_id, source, from_at, to_at, why) VALUES ($1, 'job_runs', $2, $3, 'the test')`, pg, h1, h2)
	var dropped int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.job_stats_hourly_purge()`).Scan(&dropped); err != nil {
		t.Fatal(err)
	}
	if dropped < 1 {
		t.Errorf("job_stats_hourly_purge dropped %d partitions, want 1 or more (2019-03 is older than 730 days)", dropped)
	}
	want("2019-03's hours dropped", str(`SELECT (to_regclass('pgvigil.job_stats_hourly_201903') IS NULL)::text`), "true")
	want("the quiet instance healed by the purge", hour(pg, "pg_cron", "7", 0, h1), "2/1/1 15/9/6")
	want("its dirty range gone", str(`SELECT count(*)::text FROM pgvigil.job_stats_dirty WHERE instance_id = $1`, pg), "0")
	want("the quiet upgraded instance built whole by the purge", hour(up2, "sqlagent", "a", 0, d2), "1/1/0 4/4/4")
	want("both upgraded instances marked built", str(`SELECT count(*)::text FROM pgvigil.job_stats_built WHERE instance_id IN ($1, $2)`, up1, up2), "2")
}
