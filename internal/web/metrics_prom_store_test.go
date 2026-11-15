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

// TestPromMetricsOnAStore (B24d, P5 / P6 on a migrated repository, PGVIGIL_REPO_TEST_DSN; skipped without it): two
// PostgreSQL instances. Leftovers of a run killed before its cleanup (its own name prefixes) are removed first.
//   - 'fresh': sessions read 3 minutes ago (total 12) and 1 minute ago (total 10): the NEWEST is 10, not the largest;
//     three databases read 3, 2 and 1 minute ago - db1 with an uneven rate (its newest commits smaller than the read
//     before), db2 reset at the newest read (so the instance's newest database point is the one of 2 minutes ago,
//     metric_points' rule), db3 small. PARITY both ways with metric_grid: every key of the instance's figures and of
//     each database's own series (metric_grid with that database) where the grid's 'current' is fresh.
//   - the body: pgvigil_sessions 10, pgvigil_sessions_connections_used_ratio 0.1, pgvigil_instance_deadlocks_per_second
//     0.1 (the seed's 6 deadlocks of the 2-minute read over its 60 s, a literal: never the code's own value / secs),
//     pgvigil_instance_info, the findings' three severities (pgvigil.findings is a view over the rules: this row
//     proves the query runs and the zeros are given, not a count).
//   - 'stale': sessions read 20 minutes ago (fresh_secs 600): no pgvigil_sessions sample, its
//     pgvigil_sample_timestamp_seconds{family="sessions"} there.
//   - metrics.databases on, max_databases 1: db2's series alone (the largest by pgvigil.databases' size_bytes; in the
//     middle by dbid and by name, the smallest by activity) and pgvigil_metrics_databases_cut 2; with
//     include_databases [db1]: db1's series alone and no cut row (an include list cuts nothing).
func TestPromMetricsOnAStore(t *testing.T) {
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
	drop := func(c context.Context, ids []int) {
		for _, tb := range []string{"activity_summary", "dbstats", "databases"} {
			if _, err := pool.Exec(c, `DELETE FROM pgvigil.`+tb+` WHERE instance_id = ANY($1)`, ids); err != nil {
				t.Logf("cleanup %s: %v", tb, err)
			}
		}
		if _, err := pool.Exec(c, `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`, ids); err != nil {
			t.Logf("cleanup instances: %v", err)
		}
	}
	var old []int
	rows, err := pool.Query(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name LIKE 'b24d-fresh-%' OR name LIKE 'b24d-stale-%'`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		old = append(old, id)
	}
	rows.Close()
	if len(old) > 0 {
		drop(ctx, old)
	}
	var made []int
	defer func() {
		if len(made) == 0 {
			return
		}
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		drop(c, made)
	}()
	sfx := time.Now().UnixNano() % 1000000000
	inst := func(name string) (int, string) {
		t.Helper()
		n := fmt.Sprintf("%s-%d", name, sfx)
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`, n).Scan(&id); err != nil {
			t.Fatal(err)
		}
		made = append(made, id)
		return id, n
	}
	fresh, freshName := inst("b24d-fresh")
	stale, staleName := inst("b24d-stale")
	exec(`SELECT pgvigil.ensure_month_partition('dbstats', m) FROM unnest(ARRAY[now() - interval '1 hour', now()]) m`)
	exec(`INSERT INTO pgvigil.activity_summary (instance_id, snapshot_at, total, active, idle, idle_in_txn, waiting_lock, longest_active_secs,
	                                             longest_idle_txn_secs, oldest_xmin_age, max_connections)
	      VALUES ($1, now() - interval '3 minutes', 12, 5, 7, 2, 1, 9, 6, 300, 100),
	             ($1, now() - interval '1 minute', 10, 3, 6, 1, 0, 4, 2, 150, 100),
	             ($2, now() - interval '20 minutes', 5, 1, 4, 0, 0, 0, 0, 10, 100)`, fresh, stale)
	// cumulative counters at 3, 2 and 1 minutes ago (k = 0, 1, 2): db1's commits 1000, 3000, 4000 (deltas 2000 then
	// 1000: the newest smaller), deadlocks 0, 4, 6; db2's commits 10, 20, 30, deadlocks 0, 2, 4, its stats_reset new at
	// the newest read; db3's commits 100, 200, 300, no deadlock. The 2-minute read: deadlocks 4 + 2 + 0 = 6 over 60 s.
	exec(`INSERT INTO pgvigil.dbstats (instance_id, snapshot_at, dbid, datname, numbackends, xact_commit, xact_rollback, blks_read, blks_hit,
	                                    tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted, temp_bytes, deadlocks, stats_reset)
	      SELECT $1, date_trunc('second', now()) - make_interval(mins => 3 - k), d.dbid, d.name, 2,
	             (ARRAY[d.c0, d.c1, d.c2])[k + 1], 10 * k, 50 * k, 950 * k, 100 * k, 10 * k, 5 * k, 3 * k, k, 0, (ARRAY[d.l0, d.l1, d.l2])[k + 1],
	             CASE WHEN d.name = 'db2' AND k = 2 THEN now() - interval '61 seconds' ELSE now() - interval '1 day' END
	        FROM (VALUES (1, 'db1', 1000, 3000, 4000, 0, 4, 6), (2, 'db2', 10, 20, 30, 0, 2, 4), (3, 'db3', 100, 200, 300, 0, 0, 0))
	             d(dbid, name, c0, c1, c2, l0, l1, l2)
	       CROSS JOIN generate_series(0, 2) k`, fresh)
	exec(`INSERT INTO pgvigil.databases (instance_id, dbid, datname, snapshot_at, size_bytes, first_seen, is_present)
	      VALUES ($1, 1, 'db1', now(), 1000, now(), true), ($1, 2, 'db2', now(), 9000, now(), true), ($1, 3, 'db3', now(), 500, now(), true)`, fresh)

	// PARITY with the Metrics grid, both ways: the instance's figures, then each database's own series
	parity := func(label, grid, newest string, args ...any) {
		t.Helper()
		rows, err := pool.Query(ctx, `
		  WITH g AS (SELECT g.key, g.current_value FROM `+grid+` g JOIN pgvigil.metric_catalog c ON c.key = g.key
		             WHERE g.current_value IS NOT NULL AND g.current_at > now() - make_interval(secs => c.fresh_secs)),
		       n AS (`+newest+`)
		  SELECT coalesce(g.key, n.key), g.current_value, n.value FROM g FULL JOIN n ON n.key = g.key
		   WHERE g.key IS NULL OR n.key IS NULL OR abs(g.current_value - n.value) > 1e-9 * greatest(1, abs(g.current_value))`, args...)
		if err != nil {
			t.Fatalf("%s: %v", label, err)
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
	parity("instance", `pgvigil.metric_grid($1::int, now() - interval '1 hour', now())`,
		`SELECT family || '.' || metric AS key, value FROM pgvigil.metrics_newest(ARRAY[$1::int]) WHERE database IS NULL AND metric <> 'cut'`, fresh)
	for _, db := range []string{"db1", "db2", "db3"} {
		parity(db, `pgvigil.metric_grid($1::int, now() - interval '1 hour', now(), interval '15 minutes', $2::text, 'database')`,
			`SELECT family || '.' || metric AS key, value FROM pgvigil.metrics_newest(ARRAY[$1::int], interval '15 minutes', true, 50) WHERE database = $2::text`, fresh, db)
	}
	var nkeys int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.metrics_newest(ARRAY[$1::int]) WHERE database IS NULL`, fresh).Scan(&nkeys); err != nil || nkeys < 18 {
		t.Errorf("metrics_newest of 'fresh': %d keys, %v (want the 8 sessions and 10 database keys at least)", nkeys, err)
	}

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	render := func(c MetricsConfig) string {
		t.Helper()
		b, err := s.renderMetrics(ctx, &promState{cfg: &c})
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	body := render(MetricsConfig{})
	lab := func(n string) string { return `server="` + n + `",engine="postgres"` }
	for _, want := range []string{
		"pgvigil_sessions{" + lab(freshName) + "} 10\n",
		"pgvigil_sessions_connections_used_ratio{" + lab(freshName) + "} 0.1\n",
		"pgvigil_instance_deadlocks_per_second{" + lab(freshName) + "} 0.1\n",
		`pgvigil_instance_info{server="` + freshName + `",engine="postgres",platform="onprem",version="17.0"} 1` + "\n",
		`pgvigil_findings{server="` + freshName + `",severity="info"} `,
		`pgvigil_findings{server="` + freshName + `",severity="warning"} `,
		`pgvigil_findings{server="` + freshName + `",severity="critical"} `,
		`pgvigil_sample_timestamp_seconds{server="` + staleName + `",family="sessions"} `,
		"# TYPE pgvigil_metrics_refused_total counter\n",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("the body lacks %q", strings.TrimSpace(want))
		}
	}
	if strings.Contains(body, "pgvigil_sessions{"+lab(staleName)+"}") {
		t.Errorf("a stale sample was given: %s's pgvigil_sessions", staleName)
	}
	if strings.Contains(body, "pgvigil_database_") {
		t.Errorf("per-database series with metrics.databases off")
	}
	if strings.Count(body, "# TYPE pgvigil_sessions gauge\n") != 1 {
		t.Errorf("pgvigil_sessions declared %d times", strings.Count(body, "# TYPE pgvigil_sessions gauge\n"))
	}
	dbLab := func(db string) string { return `{` + lab(freshName) + `,database="` + db + `"}` }
	body = render(MetricsConfig{Databases: true, MaxDatabases: 1})
	if !strings.Contains(body, "pgvigil_database_backends"+dbLab("db2")+" ") || strings.Contains(body, dbLab("db1")) || strings.Contains(body, dbLab("db3")) ||
		!strings.Contains(body, `pgvigil_metrics_databases_cut{server="`+freshName+`"} 2`+"\n") {
		t.Errorf("databases on, max 1: want db2's series (the largest by size), no db1 or db3, the cut 2:\n%s", grepLines(body, freshName))
	}
	body = render(MetricsConfig{Databases: true, IncludeDatabases: []string{"db1"}})
	if !strings.Contains(body, "pgvigil_database_backends"+dbLab("db1")+" ") || strings.Contains(body, dbLab("db2")) || strings.Contains(body, dbLab("db3")) ||
		strings.Contains(body, `pgvigil_metrics_databases_cut{server="`+freshName+`"}`) {
		t.Errorf("include_databases [db1]: want db1's series alone, no cut row:\n%s", grepLines(body, freshName))
	}
}

func promDeref(p *float64) any {
	if p == nil {
		return nil
	}
	return *p
}

func grepLines(body, s string) string {
	var out []string
	for _, l := range strings.Split(body, "\n") {
		if strings.Contains(l, s) {
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n")
}
