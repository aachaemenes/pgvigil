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
// PostgreSQL instances.
//   - 'fresh': sessions read 1 and 3 minutes ago, two databases read 3, 2 and 1 minute ago; 'db2' was reset 1 minute
//     ago, so the instance's newest database point is the one of 2 minutes ago (metric_points' rule: a reset interval
//     gives no point). PARITY: every key metric_grid gives a fresh 'current' equals metrics_newest's value (the
//     instance's figures, database NULL), and metrics_newest gives no key the grid does not; the body carries
//     pgvigil_sessions 10, pgvigil_sessions_connections_used_ratio 0.1, pgvigil_instance_deadlocks_per_second = the
//     grid's per-interval count / the interval's seconds, pgvigil_instance_info, three pgvigil_findings severities.
//   - 'stale': sessions read 20 minutes ago (fresh_secs 600): no pgvigil_sessions sample, its
//     pgvigil_sample_timestamp_seconds{family="sessions"} there.
//   - with metrics.databases on and max_databases 1: one database's series (the larger by database_sizes) and
//     pgvigil_metrics_databases_cut 1.
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
	var made []int
	defer func() {
		if len(made) == 0 {
			return
		}
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		for _, q := range []string{`DELETE FROM pgvigil.activity_summary WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.dbstats WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.database_sizes WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(c, q, made); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
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
	for _, tb := range []string{"dbstats", "database_sizes"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, m) FROM unnest(ARRAY[now() - interval '1 hour', now()]) m`, tb)
	}
	exec(`INSERT INTO pgvigil.activity_summary (instance_id, snapshot_at, total, active, idle, idle_in_txn, waiting_lock, longest_active_secs,
	                                             longest_idle_txn_secs, oldest_xmin_age, max_connections)
	      VALUES ($1, now() - interval '3 minutes', 8, 2, 6, 0, 0, 1, 0, 100, 100),
	             ($1, now() - interval '1 minute', 10, 3, 6, 1, 0, 4, 2, 150, 100),
	             ($2, now() - interval '20 minutes', 5, 1, 4, 0, 0, 0, 0, 10, 100)`, fresh, stale)
	// two databases, 60 s apart; db2's stats_reset changes at the newest read
	exec(`INSERT INTO pgvigil.dbstats (instance_id, snapshot_at, dbid, datname, numbackends, xact_commit, xact_rollback, blks_read, blks_hit,
	                                    tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted, temp_bytes, deadlocks, stats_reset)
	      SELECT $1, date_trunc('second', now()) - make_interval(mins => m), d.dbid, d.name, 2, 1000 * (4 - m) * d.dbid, 10 * (4 - m), 50 * (4 - m), 950 * (4 - m),
	             100 * (4 - m), 10 * (4 - m), 5 * (4 - m), 3 * (4 - m), 1 * (4 - m), 0, 3 * (4 - m),
	             CASE WHEN d.name = 'db2' AND m = 1 THEN now() - interval '61 seconds' ELSE now() - interval '1 day' END
	        FROM (VALUES (1, 'db1'), (2, 'db2')) d(dbid, name) CROSS JOIN generate_series(1, 3) m`, fresh)
	exec(`INSERT INTO pgvigil.database_sizes (instance_id, snapshot_at, dbid, datname, size_bytes)
	      VALUES ($1, now() - interval '5 minutes', 1, 'db1', 1000), ($1, now() - interval '5 minutes', 2, 'db2', 9000)`, fresh)

	// PARITY with the Metrics grid, both ways, the instance's figures
	rows, err := pool.Query(ctx, `
	  WITH g AS (SELECT g.key, g.current_value FROM pgvigil.metric_grid($1::int, now() - interval '1 hour', now()) g
	              JOIN pgvigil.metric_catalog c ON c.key = g.key
	             WHERE g.current_value IS NOT NULL AND g.current_at > now() - make_interval(secs => c.fresh_secs)),
	       n AS (SELECT family || '.' || metric AS key, value FROM pgvigil.metrics_newest(ARRAY[$1::int]) WHERE database IS NULL)
	  SELECT coalesce(g.key, n.key), g.current_value, n.value FROM g FULL JOIN n ON n.key = g.key
	   WHERE g.key IS NULL OR n.key IS NULL OR abs(g.current_value - n.value) > 1e-9 * greatest(1, abs(g.current_value))`, fresh)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var key string
		var g, n *float64
		if err := rows.Scan(&key, &g, &n); err != nil {
			t.Fatal(err)
		}
		t.Errorf("parity %s: the grid's current %v, metrics_newest %v", key, promDeref(g), promDeref(n))
	}
	rows.Close()
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
	var dl float64
	if err := pool.QueryRow(ctx, `SELECT value / secs FROM pgvigil.metrics_newest(ARRAY[$1::int]) WHERE family = 'database' AND metric = 'deadlocks' AND database IS NULL`, fresh).Scan(&dl); err != nil {
		t.Errorf("deadlocks: %v", err)
	}
	for _, want := range []string{
		"pgvigil_sessions{" + lab(freshName) + "} 10\n",
		"pgvigil_sessions_connections_used_ratio{" + lab(freshName) + "} 0.1\n",
		"pgvigil_instance_deadlocks_per_second{" + lab(freshName) + "} " + promFloat(dl) + "\n",
		`pgvigil_instance_info{server="` + freshName + `",engine="postgres",platform="onprem",version="17.0"} 1` + "\n",
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
	body = render(MetricsConfig{Databases: true, MaxDatabases: 1})
	if !strings.Contains(body, `pgvigil_database_backends{server="`+freshName+`",engine="postgres",database="db2"} `) ||
		strings.Contains(body, `database="db1"`) || !strings.Contains(body, `pgvigil_metrics_databases_cut{server="`+freshName+`"} 1`+"\n") {
		t.Errorf("databases on, max 1: want db2's series (the larger), no db1, the cut 1:\n%s", grepLines(body, freshName))
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
