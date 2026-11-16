package web

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestPromExportOnAStore (PROMEXPORT, on a migrated repository: PGVIGIL_REPO_TEST_DSN, skipped without it): the four
// SQL Server families of metric_catalog on /metrics. Two SQL Server instances read every minute for 20 minutes (the
// database scope every 5 minutes, the Agent jobs read stamped on every fifth instance read, the waits, the attention
// capture, three collections' hours); leftovers of a run killed before its cleanup (its own name prefixes) go first.
//   - 'pex-a': every series at every read, every rate above its floor. PARITY both ways with metric_grid: the counters,
//     xe and waits keys of the instance, and each collection's own series (metric_grid with that collection); the body
//     has a sample of each of the 51 exported names (a collection's under the label collection, never database), none
//     of counters.percent_log_used (promNotExported), and with metrics.databases on and max_databases 1 every
//     collection's series still (the collection family is not cut).
//   - 'pex-b': the batch rate under the per-batch floor (5/s) at the NEWEST instance read only, and no scheduler count
//     at its reads of the newest 6 minutes: no compilations-per-batch or page-splits-per-batch sample and no waits
//     sample - never the older read's value, which metric_points still has (B2).
//   - the HELP words: the counters' newest-read edge, the per-read counts' 'never sum_over_time', the collection
//     family's 'max by (server)'.
func TestPromExportOnAStore(t *testing.T) {
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
	defer pool.Close()
	exec := func(what, sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	}
	// the counter tables have no foreign key to instances: each table by instance, then the instances
	drop := func(c context.Context, ids []int32) {
		for _, tb := range []string{"mssql_counter_sample", "mssql_counter_read", "mssql_counter_series", "mssql_wait_sample",
			"mssql_sched_sample", "mssql_attentions", "mssql_attention_reads", "collection_health_hour"} {
			if _, err := pool.Exec(c, `DELETE FROM pgvigil.`+tb+` WHERE instance_id = ANY($1)`, ids); err != nil {
				t.Logf("cleanup %s: %v", tb, err)
			}
		}
		if _, err := pool.Exec(c, `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`, ids); err != nil {
			t.Logf("cleanup instances: %v", err)
		}
	}
	var old []int32
	rows, err := pool.Query(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name LIKE 'pex-a-%' OR name LIKE 'pex-b-%'`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id int32
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		old = append(old, id)
	}
	rows.Close()
	if len(old) > 0 {
		drop(ctx, old)
	}
	sfx := time.Now().UnixNano() % 1000000000
	names := []string{fmt.Sprintf("pex-a-%d", sfx), fmt.Sprintf("pex-b-%d", sfx)}
	ids := make([]int32, 2)
	for i, n := range names {
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}'::text[], 'sqlserver')`, n).Scan(&ids[i]); err != nil {
			t.Fatal(err)
		}
	}
	defer func() {
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		drop(c, ids)
	}()
	a, b := names[0], names[1]
	var t0 time.Time
	if err := pool.QueryRow(ctx, `SELECT date_trunc('minute', now()) - interval '30 seconds'`).Scan(&t0); err != nil {
		t.Fatal(err)
	}
	exec("partitions", `SELECT pgvigil.ensure_month_partition(tb, m)
	    FROM unnest(ARRAY['mssql_counter_read', 'mssql_counter_sample', 'mssql_wait_sample', 'mssql_sched_sample', 'mssql_attentions']) tb
	   CROSS JOIN unnest(ARRAY[now() - interval '2 hours', now()]) m`)
	// every series of mssql_counter_points' formulas, at both instances
	exec("series", `INSERT INTO pgvigil.mssql_counter_series (instance_id, object, counter, inst, kind)
	  SELECT i, s.object, s.counter, s.inst, s.kind FROM unnest($1::int[]) i CROSS JOIN (VALUES
	    ('General Statistics', 'Logins/sec', '', 'rate'), ('General Statistics', 'Logouts/sec', '', 'rate'),
	    ('General Statistics', 'Connection Reset/sec', '', 'rate'), ('General Statistics', 'User Connections', '', 'gauge'),
	    ('SQL Errors', 'Errors/sec', 'User Errors', 'rate'), ('SQL Errors', 'Errors/sec', 'Kill Connection Errors', 'rate'),
	    ('SQL Errors', 'Errors/sec', 'DB Offline Errors', 'rate'), ('SQL Errors', 'Errors/sec', 'Info Errors', 'rate'),
	    ('SQL Errors', 'Errors/sec', '_Total', 'rate'),
	    ('SQL Statistics', 'Batch Requests/sec', '', 'rate'), ('SQL Statistics', 'SQL Compilations/sec', '', 'rate'),
	    ('SQL Statistics', 'SQL Re-Compilations/sec', '', 'rate'), ('SQL Statistics', 'Misguided plan executions/sec', '', 'rate'),
	    ('Access Methods', 'Full Scans/sec', '', 'rate'), ('Access Methods', 'Index Searches/sec', '', 'rate'),
	    ('Access Methods', 'Page Splits/sec', '', 'rate'),
	    ('Buffer Manager', 'Page lookups/sec', '', 'rate'), ('Buffer Manager', 'Page reads/sec', '', 'rate'),
	    ('Buffer Manager', 'Page writes/sec', '', 'rate'), ('Buffer Manager', 'Readahead pages/sec', '', 'rate'),
	    ('Buffer Manager', 'Lazy writes/sec', '', 'rate'), ('Buffer Manager', 'Free list stalls/sec', '', 'rate'),
	    ('Buffer Manager', 'Buffer cache hit ratio', '', 'fraction'),
	    ('Locks', 'Lock Requests/sec', '_Total', 'rate'), ('Locks', 'Lock Waits/sec', '_Total', 'rate'),
	    ('Locks', 'Lock Timeouts (timeout > 0)/sec', '_Total', 'rate'), ('Locks', 'Average Wait Time (ms)', '_Total', 'average'),
	    ('Latches', 'Latch Waits/sec', '', 'rate'), ('Latches', 'Average Latch Wait Time (ms)', '', 'average'),
	    ('Transactions', 'Update conflict ratio', '', 'average'),
	    ('sys.dm_os_process_memory', 'physical_memory_in_use_kb', '', 'gauge'),
	    ('sys.dm_os_process_memory', 'available_commit_limit_kb', '', 'gauge'),
	    ('sys.dm_os_schedulers', 'failed_to_create_worker', '', 'gauge'),
	    ('Buffer Node', 'Page life expectancy', '000', 'gauge'), ('Buffer Node', 'Database pages', '000', 'gauge'),
	    ('Databases', 'Write Transactions/sec', '_Total', 'rate'), ('Databases', 'Log Flush Waits/sec', '_Total', 'rate'),
	    ('Databases', 'Log Flush Wait Time', '_Total', 'rate'), ('Databases', 'Percent Log Used', '_Total', 'gauge'),
	    ('Databases', 'Active Transactions', '_Total', 'gauge'), ('Databases', 'Log Growths', '_Total', 'count'),
	    ('Databases', 'Write Transactions/sec', 'db1', 'rate'), ('Databases', 'Percent Log Used', 'db1', 'gauge')
	  ) AS s(object, counter, inst, kind)`, ids)
	// the instance reads: one a minute for 20 minutes (k = 0 the newest), the Agent jobs read stamped on k = 2, 7, 12, 17
	exec("instance reads", `INSERT INTO pgvigil.mssql_counter_read (instance_id, snapshot_at, scope, server_utc, rows_read, interval_secs,
	    jobs_read_at, jobs_running, jobs_started, jobs_failed, jobs_succeeded)
	  SELECT i, $2::timestamptz - make_interval(mins => k), 'instance', $2::timestamptz - make_interval(mins => k), 40, 60,
	         CASE WHEN k % 5 = 2 THEN $2::timestamptz - make_interval(mins => k) - interval '10 seconds' END,
	         CASE WHEN k % 5 = 2 THEN 2 END, CASE WHEN k % 5 = 2 THEN 3 END, CASE WHEN k % 5 = 2 THEN 1 END, CASE WHEN k % 5 = 2 THEN 4 END
	    FROM unnest($1::int[]) i CROSS JOIN generate_series(0, 20) k`, ids, t0)
	exec("database reads", `INSERT INTO pgvigil.mssql_counter_read (instance_id, snapshot_at, scope, server_utc, rows_read, interval_secs)
	  SELECT i, $2::timestamptz - make_interval(mins => 5 * k) - interval '20 seconds', 'database',
	         $2::timestamptz - make_interval(mins => 5 * k) - interval '20 seconds', 8, 300
	    FROM unnest($1::int[]) i CROSS JOIN generate_series(0, 4) k`, ids, t0)
	// every series at every read of its scope; every rate at 6/s or more, the batch rate 10/s - but 2/s at pex-b's
	// newest instance read (k = 0); a fraction's value under its base; the averages' deltas over a base
	exec("samples", `INSERT INTO pgvigil.mssql_counter_sample (instance_id, snapshot_at, series_id, value, rate, base, dvalue, dbase)
	  SELECT r.instance_id, r.snapshot_at, s.series_id, 90 + s.sx + r.k,
	         CASE WHEN s.counter = 'Batch Requests/sec' AND r.ix = 2 AND r.k = 0 THEN 2
	              WHEN s.counter = 'Batch Requests/sec' THEN 10 ELSE 6 + s.sx % 5 END::real,
	         200 + s.sx, 10 + s.sx % 7 + r.k % 3, 20 + s.sx % 5
	    FROM (SELECT c.instance_id, c.snapshot_at, c.scope, array_position($1::int[], c.instance_id) AS ix,
	                 round(extract(epoch FROM $2::timestamptz - c.snapshot_at) / 60)::int AS k
	            FROM pgvigil.mssql_counter_read c WHERE c.instance_id = ANY($1::int[])) r
	    JOIN (SELECT x.*, (row_number() OVER (PARTITION BY x.instance_id ORDER BY x.series_id))::int AS sx
	            FROM pgvigil.mssql_counter_series x WHERE x.instance_id = ANY($1::int[])) s
	      ON s.instance_id = r.instance_id AND (s.object = 'Databases') = (r.scope = 'database')`, ids, t0)
	// the waits at every instance read; the scheduler count at every read of pex-a, at pex-b's older than 6 minutes only
	exec("waits", `INSERT INTO pgvigil.mssql_wait_sample (instance_id, snapshot_at, wait_type, is_benign, waiting_tasks, wait_ms, signal_ms, interval_secs)
	  SELECT i, $2::timestamptz - make_interval(mins => k), w.t, w.b, 1, 3000 + 100 * k + w.f, 0, 60
	    FROM unnest($1::int[]) i CROSS JOIN generate_series(0, 20) k
	   CROSS JOIN (VALUES ('PAGEIOLATCH_SH', false, 1), ('CXCONSUMER', false, 3), ('SLEEP_TASK', true, 7)) AS w(t, b, f)`, ids, t0)
	exec("schedulers", `INSERT INTO pgvigil.mssql_sched_sample (instance_id, snapshot_at, schedulers)
	  SELECT x.i, $2::timestamptz - make_interval(mins => k), 4
	    FROM unnest($1::int[]) WITH ORDINALITY AS x(i, ix) CROSS JOIN generate_series(0, 20) k
	   WHERE x.ix = 1 OR k >= 6`, ids, t0)
	// the attention capture: a read a minute, done, running; three client timeouts stored at each read
	exec("attention reads", `INSERT INTO pgvigil.mssql_attention_reads (instance_id, snapshot_at, state, read_done, counter)
	  SELECT i, $2::timestamptz - make_interval(mins => k), 'running', true, 2000 - 3 * k
	    FROM unnest($1::int[]) i CROSS JOIN generate_series(0, 20) k`, ids, t0)
	exec("attentions", `INSERT INTO pgvigil.mssql_attentions (instance_id, event_at, event_key, snapshot_at, interrupt_us, statement, program_name, has_text)
	  SELECT r.instance_id, r.snapshot_at - interval '20 seconds' - make_interval(secs => e), 'k' || e, r.snapshot_at, 5000,
	         CASE WHEN e = 0 THEN 'select 1' END, CASE WHEN e = 2 THEN 'Microsoft SQL Server Management Studio - Query' ELSE 'app' END, e = 0
	    FROM pgvigil.mssql_attention_reads r CROSS JOIN generate_series(0, 2) e WHERE r.instance_id = ANY($1::int[])`, ids)
	// three collections' hours, the newest four
	exec("collection hours", `INSERT INTO pgvigil.collection_health_hour (hour, instance_id, collection, collector_id, runs, ok, partial,
	    failed, skipped, rows_written, dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s, last_ok_at, last_failure_at,
	    import_failed, import_runs, import_ms_sum, import_ms_max, cpu_runs, cpu_ms_sum, cpu_ms_max, reads_sum)
	  SELECT date_trunc('hour', $2::timestamptz) - make_interval(hours => k), i, c.coll, 'c1', 10, 9, 0, 1, 0, 5,
	         (300 + 10 * k) * c.ci, 90, 0, 0, 60, NULL, NULL, 0, 10, 30 * c.ci, 9, 9, 20 * c.ci, 7, 100 * c.ci
	    FROM unnest($1::int[]) i CROSS JOIN generate_series(0, 3) k
	   CROSS JOIN (VALUES ('activity', 1), ('databases', 2), ('jobs', 3)) AS c(coll, ci)`, ids, t0)

	// PARITY with the Metrics grid, both ways, over the four families' keys
	parity := func(label, grid, newest string, args ...any) {
		t.Helper()
		rows, err := pool.Query(ctx, `
		  WITH g AS (SELECT g.key, g.current_value FROM `+grid+` g JOIN pgvigil.metric_catalog c ON c.key = g.key
		             WHERE g.current_value IS NOT NULL AND g.current_at > now() - make_interval(secs => c.fresh_secs)
		               AND c.family IN ('counters', 'xe', 'waits', 'collection')),
		       n AS (`+newest+`)
		  SELECT coalesce(g.key, n.key), g.current_value, n.value FROM g FULL JOIN n ON n.key = g.key
		   WHERE g.key IS NULL OR n.key IS NULL OR abs(g.current_value - n.value) > 1e-9 * greatest(1, abs(g.current_value))`, args...)
		if err != nil {
			t.Fatalf("parity %s: %v", label, err)
		}
		defer rows.Close()
		for rows.Next() {
			var key string
			var g, n *float64
			if err := rows.Scan(&key, &g, &n); err != nil {
				t.Fatal(err)
			}
			t.Errorf("parity %s %s: the grid's current %v, metrics_newest %v", label, key, promDeref(g), promDeref(n))
		}
	}
	// the instance's worst collection (the grid's collection keys without a collection) is no series: left out of this side
	parity("pex-a", `pgvigil.metric_grid($1::int, now() - interval '1 hour', now())`,
		`SELECT family || '.' || metric AS key, value FROM pgvigil.metrics_newest(ARRAY[$1::int])
		  WHERE family IN ('counters', 'xe', 'waits') AND database IS NULL`, ids[0])
	for _, coll := range []string{"activity", "databases", "jobs"} {
		parity("pex-a "+coll, `pgvigil.metric_grid($1::int, now() - interval '3 hours', now(), interval '15 minutes', $2::text, 'collection')`,
			`SELECT family || '.' || metric AS key, value FROM pgvigil.metrics_newest(ARRAY[$1::int]) WHERE family = 'collection' AND database = $2::text`, ids[0], coll)
	}

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	render := func(c MetricsConfig) string {
		t.Helper()
		body, err := s.renderMetrics(ctx, &promState{cfg: &c})
		if err != nil {
			t.Fatal(err)
		}
		return string(body)
	}
	body := render(MetricsConfig{})
	lab := func(n string) string { return `{server="` + n + `",engine="sqlserver"` }
	missing := []string{}
	for _, p := range promNames {
		f := strings.SplitN(p.key, ".", 2)[0]
		switch f {
		case "counters", "xe", "waits":
			if !strings.Contains(body, "\n"+p.name+lab(a)+"} ") {
				missing = append(missing, p.name)
			}
		case "collection":
			for _, coll := range []string{"activity", "databases", "jobs"} {
				if !strings.Contains(body, "\n"+p.name+lab(a)+`,collection="`+coll+`"} `) {
					missing = append(missing, p.name+"/"+coll)
				}
			}
		}
	}
	if len(missing) > 0 {
		t.Errorf("pex-a: no sample of %d exported names: %s\n%s", len(missing), strings.Join(missing, ", "), grepLines(body, a))
	}
	for _, l := range strings.Split(body, "\n") {
		if strings.HasPrefix(l, "pgvigil_collection_") && strings.Contains(l, `database="`) {
			t.Errorf("a collection series under the label database: %s", l)
		}
	}
	if strings.Contains(body, "log_used") || strings.Contains(body, "percent_log") {
		t.Errorf("counters.percent_log_used is on promNotExported and the body names it:\n%s", grepLines(body, "log_used"))
	}
	// pex-b: the newest read under the floor (and with no scheduler count) gives no sample, never the older read's
	for _, n := range []string{"pgvigil_counters_compilations_per_batch_ratio", "pgvigil_counters_page_splits_per_batch", "pgvigil_waits_wait_per_core_ratio"} {
		if strings.Contains(body, "\n"+n+lab(b)+"}") {
			t.Errorf("pex-b: %s sampled - its newest point has no value, so it gives none:\n%s", n, grepLines(body, b))
		}
	}
	var older int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.metric_points($1::int, 'counters', now() - interval '1 hour', now())
	                                WHERE metric = 'compiles_per_100_batches' AND value IS NOT NULL`, ids[1]).Scan(&older); err != nil || older == 0 {
		t.Errorf("pex-b: metric_points has %d older compilations-per-batch points with a value, %v (want some: the row above would prove nothing)", older, err)
	}
	if !strings.Contains(body, "\n"+"pgvigil_counters_batch_requests_per_second"+lab(b)+"} 2\n") {
		t.Errorf("pex-b: the batch rate of its newest read (2/s) is not the one given:\n%s", grepLines(body, "batch_requests_per_second"+lab(b)))
	}
	// the HELP words (task 4): the counters' newest-read edge, the per-read counts, the worst collection
	help := func(name string) string {
		for _, l := range strings.Split(body, "\n") {
			if strings.HasPrefix(l, "# HELP "+name+" ") {
				return l
			}
		}
		return ""
	}
	for name, words := range map[string]string{
		"pgvigil_counters_batch_requests_per_second":     "a metric with no point at the newest read has no sample, never an older read's value",
		"pgvigil_counters_write_transactions_per_second": "the server's total (_Total), never one database's",
		"pgvigil_counters_agent_jobs_started":            "per read (every 5 min); never sum_over_time",
		"pgvigil_counters_log_growths":                   "per read (every 5 min); never sum_over_time",
		"pgvigil_collection_duration_seconds":            "the instance's worst collection is max by (server)",
	} {
		if h := help(name); !strings.Contains(h, words) {
			t.Errorf("HELP of %s: %q lacks %q", name, h, words)
		}
	}
	// metrics.databases on with max_databases 1: the collection family is not the database family - never cut
	body = render(MetricsConfig{Databases: true, MaxDatabases: 1})
	for _, coll := range []string{"activity", "databases", "jobs"} {
		if !strings.Contains(body, "\npgvigil_collection_duration_seconds"+lab(a)+`,collection="`+coll+`"} `) {
			t.Errorf("metrics.databases on, max_databases 1: the collection %s's series is gone:\n%s", coll, grepLines(body, "pgvigil_collection_duration_seconds"+lab(a)))
		}
	}
	if strings.Contains(body, `pgvigil_metrics_databases_cut{server="`+a+`"}`) {
		t.Errorf("metrics.databases on, max_databases 1: a cut row for pex-a, whose only 'databases' are collections")
	}
}
