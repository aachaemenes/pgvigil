package web

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestCollectionWorstOnAStore (B6G-N, the lead's 15:3x: 'an alert that names nothing sends the DBA hunting'; a box row:
// PGVIGIL_REPO_TEST_DSN): a Collection-family rule that names no collection watches the instance's series - each hour's
// worst collection - so its alert's detail names the worst collection of its newest hour. alert_rule_findings is 0085's
// view, re-created whole at the join with scripts/b6g-join-lines.sql's line: until then PGVIGIL_B6G_DRAFT names the
// draft files applied first in each case's transaction (comma-separated, from the repository root:
// scripts/b6g-join-draft-arf-base.sql = 0085's view as it is, the red run; scripts/b6g-join-draft-arf.sql = the view with
// the line, the green run); after the join PGVIGIL_B6G_DRAFT=none reads the store as migrated.
//   - in turn: one instance, collections A and B failing in turn (hours h-3 and h-2 A 10 of 10, B 0; hour h-1 A 0, B 10
//     of 10) under collection.failed_pct above 50 for 60 minutes with no collection - judged at h-1 + 5 min (its newest
//     point is hour h-2's: A) and at now (hour h-1's: B): warning both times, the detail names A then B, and the alert's
//     key is the same both times (the detail is outside alert_finding_key: one alert as the worst passes);
//   - named: the same rule on collection A - its setting names A already, its detail gains nothing;
//   - collection_worst itself: a tie names the first by name; an hour with no row and a metric no row of the hour reads
//     (cpu_ms on PostgreSQL rows) are NULL; two collectors of one collection are summed before the comparison.
func TestCollectionWorstOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	draft := os.Getenv("PGVIGIL_B6G_DRAFT")
	if draft == "" {
		t.Skip("PGVIGIL_B6G_DRAFT is not set (the draft files until the join, 'none' after it)")
	}
	var sqls []string
	if draft != "none" {
		for _, f := range strings.Split(draft, ",") {
			b, err := os.ReadFile(filepath.Join("..", "..", strings.TrimSpace(f)))
			if err != nil {
				t.Fatalf("the draft %s: %v", f, err)
			}
			sqls = append(sqls, string(b))
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tag := time.Now().UnixNano() % 1000000000
	base := time.Now().UTC().Truncate(time.Hour)
	inTx := func(name string, body func(t *testing.T, tx pgx.Tx, exec func(string, ...any))) {
		t.Run(name, func(t *testing.T) {
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(context.Background()) }()
			for _, s := range sqls { // the simple protocol: a file may hold several statements
				if _, err := tx.Conn().PgConn().Exec(ctx, s).ReadAll(); err != nil {
					t.Fatalf("applying the draft: %v", err)
				}
			}
			exec := func(sql string, args ...any) {
				t.Helper()
				if _, err := tx.Exec(ctx, sql, args...); err != nil {
					t.Fatalf("%s: %v", strings.Fields(sql)[0], err)
				}
			}
			body(t, tx, exec)
		})
	}
	instance := func(t *testing.T, tx pgx.Tx, key, engine string) (int32, string) {
		t.Helper()
		name := fmt.Sprintf("cw-%d-%s", tag, key)
		var id int32
		if err := tx.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}'::text[], $2)`, name, engine).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id, name
	}
	// hour: one collector's hour row - runs, failed and the summed duration; ok = runs - failed
	hour := func(exec func(string, ...any), at time.Time, id int32, coll, collector string, runs, failed int, durSum int) {
		exec(`INSERT INTO pgvigil.collection_health_hour (hour, instance_id, collection, collector_id, runs, ok, partial, failed, skipped,
		        rows_written, dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s, last_ok_at, last_failure_at)
		      VALUES ($1, $2, $3, $4, $5, $5 - $6, 0, $6, 0, 0, $7, $7, 0, 0, 60, $1, $1)`, at, id, coll, collector, runs, failed, durSum)
	}
	rule := func(t *testing.T, tx pgx.Tx, name, coll string) {
		t.Helper()
		var out string
		if err := tx.QueryRow(ctx, `SELECT pgvigil.import_alert_rule(now(), jsonb_build_object('op', 'add', 'ui_user', 'proof',
		    'metric', 'collection.failed_pct', 'op_dir', 'above', 'warning', 50, 'for_minutes', 60, 'scope', 'instance',
		    'instance_name', $1::text, 'database', nullif($2::text, ''), 'name', 'cw rule'))->>'outcome'`, name, coll).Scan(&out); err != nil || out != "done" {
			t.Fatalf("the rule: %q, %v", out, err)
		}
	}
	type finding struct{ severity, setting, detail, key string }
	read := func(t *testing.T, tx pgx.Tx, id int32) []finding {
		t.Helper()
		rows, err := tx.Query(ctx, `SELECT f.severity, f.setting, f.detail, pgvigil.alert_finding_key(f.instance_id, f.source, f.setting, f.value)
		    FROM pgvigil.alert_rule_findings f WHERE f.instance_id = $1 ORDER BY f.setting`, id)
		if err != nil {
			t.Fatal(err)
		}
		out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (finding, error) {
			var f finding
			err := r.Scan(&f.severity, &f.setting, &f.detail, &f.key)
			return f, err
		})
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	const words = "the worst collection of its newest hour: "

	inTx("in turn", func(t *testing.T, tx pgx.Tx, exec func(string, ...any)) {
		id, name := instance(t, tx, "turn", "postgres")
		ca, cb := fmt.Sprintf("cwA%d", tag), fmt.Sprintf("cwB%d", tag)
		for k, failing := range map[int]string{3: ca, 2: ca, 1: cb} {
			for _, c := range []string{ca, cb} {
				f := 0
				if c == failing {
					f = 10
				}
				hour(exec, base.Add(-time.Duration(k)*time.Hour), id, c, "c1", 10, f, 1000)
			}
		}
		rule(t, tx, name, "")
		for _, step := range []struct {
			at   time.Time
			want string
		}{{base.Add(-time.Hour + 5*time.Minute), ca}, {time.Now().UTC(), cb}} {
			exec(`SELECT pgvigil.alert_rules_run($1)`, step.at)
			fs := read(t, tx, id)
			if len(fs) != 1 {
				t.Fatalf("judged at %s: %d finding(s), want 1 (%v)", step.at.Format("15:04"), len(fs), fs)
			}
			if fs[0].severity != "warning" || !strings.Contains(fs[0].detail, words+step.want) {
				t.Errorf("judged at %s: %s %q, want warning and its detail naming %s", step.at.Format("15:04"), fs[0].severity, fs[0].detail, step.want)
			}
			t.Logf("B6GN judged at %s: %s | %s | key %s", step.at.Format("15:04"), fs[0].severity, fs[0].detail, fs[0].key)
		}
	})

	inTx("the key kept", func(t *testing.T, tx pgx.Tx, exec func(string, ...any)) {
		id, name := instance(t, tx, "key", "postgres")
		ca, cb := fmt.Sprintf("cwA%d", tag), fmt.Sprintf("cwB%d", tag)
		for k, failing := range map[int]string{3: ca, 2: ca, 1: cb} {
			for _, c := range []string{ca, cb} {
				f := 0
				if c == failing {
					f = 10
				}
				hour(exec, base.Add(-time.Duration(k)*time.Hour), id, c, "c1", 10, f, 1000)
			}
		}
		rule(t, tx, name, "")
		var keys []string
		for _, at := range []time.Time{base.Add(-time.Hour + 5*time.Minute), time.Now().UTC()} {
			exec(`SELECT pgvigil.alert_rules_run($1)`, at)
			for _, f := range read(t, tx, id) {
				keys = append(keys, f.key)
			}
		}
		if len(keys) != 2 || keys[0] != keys[1] {
			t.Errorf("the alert's key across the two judgements: %v, want one key twice", keys)
		}
	})

	inTx("named", func(t *testing.T, tx pgx.Tx, exec func(string, ...any)) {
		id, name := instance(t, tx, "named", "postgres")
		ca := fmt.Sprintf("cwA%d", tag)
		for k := 1; k <= 2; k++ {
			hour(exec, base.Add(-time.Duration(k)*time.Hour), id, ca, "c1", 10, 10, 1000)
		}
		rule(t, tx, name, ca)
		exec(`SELECT pgvigil.alert_rules_run($1)`, time.Now().UTC())
		fs := read(t, tx, id)
		if len(fs) != 1 || !strings.Contains(fs[0].setting, "["+ca+"]") || strings.Contains(fs[0].detail, words) {
			t.Errorf("a rule naming its collection: %v, want one finding, its setting naming %s and no worst-collection words", fs, ca)
		}
	})

	inTx("collection_worst", func(t *testing.T, tx pgx.Tx, exec func(string, ...any)) {
		var have bool
		if err := tx.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.collection_worst(integer, text, timestamp with time zone)') IS NOT NULL`).Scan(&have); err != nil {
			t.Fatal(err)
		}
		if !have {
			t.Fatalf("pgvigil.collection_worst(int, text, timestamptz) does not exist")
		}
		id, _ := instance(t, tx, "worst", "postgres")
		ca, cb, cc := fmt.Sprintf("cwA%d", tag), fmt.Sprintf("cwB%d", tag), fmt.Sprintf("cwC%d", tag)
		h := base.Add(-2 * time.Hour)
		hour(exec, h, id, cb, "c1", 10, 5, 1000) // B 50 % failed, 100 ms
		hour(exec, h, id, ca, "c1", 10, 5, 3000) // A 50 % failed (a tie with B), 300 ms
		hour(exec, h, id, cc, "c1", 10, 0, 1000) // C 0 % ... but
		hour(exec, h, id, cc, "c2", 10, 9, 5000) // ... with its second collector 9 of 20 = 45 %, (1000 + 5000) / 20 = 300 ms
		for _, c := range []struct {
			metric string
			at     time.Time
			want   string
		}{
			{"failed_pct", h.Add(time.Hour), ca},     // A and B tie at 50 %: the first by name; C's two collectors summed: 45 %
			{"duration_ms", h.Add(time.Hour), ca},    // A 300 and C 300 tie (C summed over its collectors): A by name; B 100
			{"failed_pct", h, ""},                    // the hour before holds no row
			{"cpu_ms", h.Add(time.Hour), ""},         // no row of the hour read its session (PostgreSQL rows)
			{"no_such_metric", h.Add(time.Hour), ""}, // not a metric of the family
		} {
			var got *string
			if err := tx.QueryRow(ctx, `SELECT pgvigil.collection_worst($1, $2, $3)`, id, c.metric, c.at).Scan(&got); err != nil {
				t.Fatalf("collection_worst(%s, %s): %v", c.metric, c.at.Format("15:04"), err)
			}
			g := ""
			if got != nil {
				g = *got
			}
			if g != c.want {
				t.Errorf("collection_worst(%s, the hour ending %s) = %q, want %q", c.metric, c.at.Format("15:04"), g, c.want)
			}
		}
	})
}

// TestCollectionMetricPointsKeptOnAStore (B6G-N's refactor guard; a box row: PGVIGIL_REPO_TEST_DSN): metric_points'
// Collection family - the instance's series (each hour's worst collection) and one collection's - row for row against
// its formulas as 037a99b2 wrote them (copied here as the oracle), over two collectors, a SQL Server instance's CPU and
// reads, partial runs and an hour with nothing imported. Passes before and after the move of the formulas into
// collection_metric_values: a guard, not a red row.
func TestCollectionMetricPointsKeptOnAStore(t *testing.T) {
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
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	tag := time.Now().UnixNano() % 1000000000
	var id int32
	if err := tx.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("cwk-%d", tag)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	base := time.Now().UTC().Truncate(time.Hour)
	for k := 1; k <= 5; k++ {
		for ci, coll := range []string{"activity", "databases", "jobs"} {
			for _, col := range []string{"c1", "c2"} {
				if col == "c2" && (k+ci)%2 == 0 {
					continue
				}
				runs := 10 + k*ci
				if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collection_health_hour (hour, instance_id, collection, collector_id, runs, ok, partial,
				    failed, skipped, rows_written, dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s, last_ok_at, last_failure_at,
				    import_failed, import_runs, import_ms_sum, import_ms_max, cpu_runs, cpu_ms_sum, cpu_ms_max, reads_sum)
				  VALUES ($1, $2, $3, $4, $5, $5 - 1 - ($6 % 3), 1, $6 % 3, 0, 5, $5 * (30 + $6), 90 + $6, 0, 0, 60, $1, $1,
				          0, CASE WHEN $6 = 4 THEN 0 ELSE $5 END, $5 * 3, 9, CASE WHEN $6 = 2 THEN 0 ELSE $5 - 1 END, $5 * (2 + $6), 7, $5 * 100 * $6)`,
					base.Add(-time.Duration(k)*time.Hour), id, coll, col, runs, k); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	oracle := `WITH h AS (
	  SELECT h.hour, h.collection,
	         sum(h.dur_ms_sum) AS dur, sum(h.ok + h.partial + h.failed) AS ran, sum(h.failed) AS failed,
	         sum(h.cpu_ms_sum) AS cpu, sum(h.cpu_runs) AS cpu_runs, sum(h.reads_sum) AS reads,
	         sum(h.import_ms_sum) AS imp, sum(h.import_runs) AS imp_runs
	    FROM pgvigil.collection_health_hour h
	   WHERE h.instance_id = $1 AND ($4::text IS NULL OR h.collection = $4)
	     AND h.hour > $2::timestamptz - interval '1 hour' AND h.hour <= $3::timestamptz - interval '1 hour'
	   GROUP BY h.hour, h.collection
	)
	SELECT h.hour + interval '1 hour' AS at, v.metric, max(v.value) AS value
	  FROM h CROSS JOIN LATERAL (VALUES
	    ('duration_ms', (h.dur::numeric / nullif(h.ran, 0))::double precision),
	    ('cpu_ms', (h.cpu::numeric / nullif(h.cpu_runs, 0))::double precision),
	    ('logical_reads', (h.reads::numeric / nullif(h.cpu_runs, 0))::double precision),
	    ('import_ms', (h.imp::numeric / nullif(h.imp_runs, 0))::double precision),
	    ('failed_pct', (100.0 * h.failed / nullif(h.ran, 0))::double precision)) AS v(metric, value)
	 WHERE v.value IS NOT NULL
	 GROUP BY h.hour, v.metric
	 ORDER BY 1, 2`
	lines := func(sql string, args ...any) []string {
		t.Helper()
		rows, err := tx.Query(ctx, sql, args...)
		if err != nil {
			t.Fatal(err)
		}
		out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (string, error) {
			v, err := r.Values()
			return fmt.Sprint(v...), err
		})
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	from, to := base.Add(-6*time.Hour), base.Add(time.Minute)
	for _, coll := range []any{nil, "activity", "jobs"} {
		want := lines(oracle, id, from, to, coll)
		got := lines(`SELECT x.at, x.metric, x.value FROM pgvigil.metric_points($1, 'collection', $2, $3, interval '1 hour', $4) x ORDER BY 1, 2`, id, from, to, coll)
		if len(want) == 0 {
			t.Fatalf("collection %v: the oracle reads no point (the seed?)", coll)
		}
		if strings.Join(got, "\n") != strings.Join(want, "\n") {
			t.Errorf("collection %v: metric_points differs from the formulas as 037a99b2 wrote them:\n got  %v\n want %v", coll, got, want)
		}
	}
}
