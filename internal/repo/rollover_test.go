package repo

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// The month rollover (N4): an import that first meets a month without a partition made it inside its own transaction
// and held the parent's ACCESS EXCLUSIVE lock until it ended; a second import already holding a shared query_text row
// then closed a cycle (40P01). These tests run on a database of their own, made from PGVIGIL_REPO_TEST_DSN's server and
// dropped at the end, so no other package's Migrate makes or drops a month under them.

// throwawayRepo creates a database on the test DSN's server, opens a Repo on it (not migrated) and drops the database
// when the test ends; it returns the database's DSN too. It skips, naming why, when the DSN is unset or its login may
// not create a database.
func throwawayRepo(t *testing.T) (context.Context, *Repo, *pgxpool.Pool, string) {
	t.Helper()
	base := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if base == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	t.Cleanup(cancel)
	admin, err := pgxpool.New(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Close)
	var may bool
	if err := admin.QueryRow(ctx, `SELECT rolcreatedb OR rolsuper FROM pg_roles WHERE rolname = current_user`).Scan(&may); err != nil {
		t.Fatal(err)
	}
	if !may {
		t.Skip("the test login may not create a database (CREATEDB): these tests need a database of their own")
	}
	name := fmt.Sprintf("pgvigil_n4_%d_%d", os.Getpid(), time.Now().UnixNano()%1000000000)
	if _, err := admin.Exec(ctx, `CREATE DATABASE `+name); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec(context.Background(), `DROP DATABASE IF EXISTS `+name+` WITH (FORCE)`); err != nil {
			t.Errorf("drop the test database %s: %v", name, err)
		}
	})
	dsn := base + " dbname=" + name
	if strings.HasPrefix(base, "postgres://") || strings.HasPrefix(base, "postgresql://") {
		u, err := url.Parse(base)
		if err != nil {
			t.Fatal(err)
		}
		u.Path = "/" + name
		dsn = u.String()
	}
	r, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Close)
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return ctx, r, pool, dsn
}

// skipUnwiredMigrate skips, naming why, on an unwired tree: there Migrate makes no partition ahead (its pass,
// aheadAfterMigrate, is scripts/n4-wiring.patch's - repo.go is a shared file), so a test of what Migrate's pass
// gives fails by design. Called after Migrate. A tree without 0271 (the base) skips nothing: there the rollover tests
// are red by their own words.
func skipUnwiredMigrate(ctx context.Context, t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	var door, ahead bool
	if err := pool.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.import_partition_make(text, timestamp with time zone)') IS NOT NULL,
	                                     to_regclass('pgvigil.activity_sample_' || to_char(date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month', 'YYYYMM')) IS NOT NULL`).Scan(&door, &ahead); err != nil {
		t.Fatal(err)
	}
	if door && !ahead {
		t.Skip("an unwired tree: Migrate made no partition ahead (its pass is scripts/n4-wiring.patch's; repo.go is shared)")
	}
}

// nextMonthStart is the first second of the next UTC month.
func nextMonthStart() time.Time {
	n := time.Now().UTC()
	return time.Date(n.Year(), n.Month()+1, 1, 0, 0, 1, 0, time.UTC)
}

// TestRolloverImportMakesNoPartition: after Migrate, an import into next month - activity (one parent and the shared
// query_text) and mssql_cpu (four parents) - makes no partition inside its call. An event trigger records every table
// made with the statement that made it; it needs a superuser, and the test skips with that reason otherwise. Red on a
// tree whose Migrate makes no month ahead: the imports make next month's partitions themselves.
func TestRolloverImportMakesNoPartition(t *testing.T) {
	ctx, r, pool, _ := throwawayRepo(t)
	var super bool
	var who string
	if err := pool.QueryRow(ctx, `SELECT rolsuper, rolname FROM pg_roles WHERE rolname = current_user`).Scan(&super, &who); err != nil {
		t.Fatal(err)
	}
	if !super {
		t.Skipf("the event trigger that records a partition made inside an import needs a superuser: %q is not one (the box's store runs this test)", who)
	}
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	skipUnwiredMigrate(ctx, t, pool)
	if _, err := pool.Exec(ctx, `
CREATE TABLE public.n4_made (obj text, stmt text);
CREATE FUNCTION public.n4_made_fn() RETURNS event_trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.n4_made (obj, stmt)
  SELECT c.object_identity, current_query() FROM pg_event_trigger_ddl_commands() c WHERE c.command_tag = 'CREATE TABLE';
END $$;
CREATE EVENT TRIGGER n4_made ON ddl_command_end WHEN TAG IN ('CREATE TABLE') EXECUTE FUNCTION public.n4_made_fn();`); err != nil {
		t.Fatal(err)
	}
	next := nextMonthStart()
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance('n4-roll', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if err := r.Import(ctx, id, "activity", next, []map[string]any{{"kind": "session", "pid": 2, "state": "active", "query_hash": 9200000000001, "query": "select 'n4'"}}); err != nil {
		t.Fatalf("import_activity into next month: %v", err)
	}
	ts := next.Format(time.RFC3339Nano)
	if err := r.Import(ctx, id, "mssql_cpu", next, []map[string]any{
		{"kind": "state", "server_utc": ts, "server_start": "2026-01-01T00:00:00Z"},
		{"kind": "cpu", "record_id": 7, "sample_at": ts, "sql_pct": 5, "idle_pct": 90, "other_pct": 5},
		{"kind": "sched", "schedulers": 4},
	}); err != nil {
		t.Fatalf("import_mssql_cpu into next month: %v", err)
	}
	var made string
	if err := pool.QueryRow(ctx, `SELECT coalesce(string_agg(obj, ', ' ORDER BY obj), '') FROM public.n4_made WHERE stmt ~ 'pgvigil\.import_'`).Scan(&made); err != nil {
		t.Fatal(err)
	}
	if made != "" {
		t.Errorf("partitions made inside an import call for %s: %s (want none: the month is made ahead, outside any import)", next.Format("2006-01"), made)
	}
	var stored int
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM pgvigil.activity_sample WHERE instance_id = $1) + (SELECT count(*) FROM pgvigil.mssql_cpu_sample WHERE instance_id = $1)`, id).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored != 2 {
		t.Errorf("rows stored by the two imports: %d (want 1 activity + 1 cpu)", stored)
	}
}

// TestRolloverCycleCannotForm: rel-j15dl's cycle on real months. tx1 holds a shared query_text row; the Repo's import
// into next month waits on it - holding no lock at SHARE UPDATE EXCLUSIVE or stronger on any relation, read from another
// session while it waits - and tx1's own import into this month then commits without a wait on the parent: no
// deadlock, no retry (no WARN), both rows stored. Red on a tree whose Migrate makes no month ahead: the import holds
// activity_sample's ACCESS EXCLUSIVE while it waits, tx1 closes the cycle, and the retry clears it (one WARN).
func TestRolloverCycleCannotForm(t *testing.T) {
	ctx, r, pool, _ := throwawayRepo(t)
	var super bool
	var who string
	if err := pool.QueryRow(ctx, `SELECT rolsuper, rolname FROM pg_roles WHERE rolname = current_user`).Scan(&super, &who); err != nil {
		t.Fatal(err)
	}
	if !super {
		t.Skipf("the cycle's holder sets its own deadlock_timeout, a superuser's setting: %q is not one (the box's store runs this test)", who)
	}
	var logged bytes.Buffer
	r.SetLog(slog.New(slog.NewTextHandler(&logged, &slog.HandlerOptions{Level: slog.LevelWarn})))
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	skipUnwiredMigrate(ctx, t, pool)
	now, next := time.Now().UTC(), nextMonthStart()
	const hash = 9200000000002
	inst := func(n string) int {
		t.Helper()
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')`, n).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	i0, i1 := inst("n4-cyc-now"), inst("n4-cyc-next")
	// this month's partition as a running collector has it (an import of this month already ran)
	if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition('activity_sample', $1)`, now); err != nil {
		t.Fatal(err)
	}
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	tx1, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx1.Rollback(context.Background()) //nolint:errcheck // committed below on the happy path
	if _, err := tx1.Exec(ctx, `SET LOCAL deadlock_timeout = '10s'`); err != nil {
		t.Fatal(err)
	}
	var pid1 int
	if err := tx1.QueryRow(ctx, `SELECT pg_backend_pid()`).Scan(&pid1); err != nil {
		t.Fatal(err)
	}
	if _, err := tx1.Exec(ctx, `INSERT INTO pgvigil.query_text (query_hash, first_seen, last_seen, query) VALUES ($1, $2, $2, 'select ''n4''')`, hash, now); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		done <- r.Import(ctx, i1, "activity", next, []map[string]any{{"kind": "session", "pid": 2, "state": "active", "query_hash": hash, "query": "select 'n4'"}})
	}()
	waiter := 0
	for i := 0; i < 250 && waiter == 0; i++ {
		if err := pool.QueryRow(ctx, `SELECT coalesce(min(pid), 0) FROM pg_stat_activity WHERE $1 = ANY (pg_blocking_pids(pid))`, pid1).Scan(&waiter); err != nil {
			t.Fatal(err)
		}
		if waiter == 0 {
			time.Sleep(20 * time.Millisecond)
		}
	}
	if waiter == 0 {
		t.Fatal("the Repo's import never waited on tx1's query_text row")
	}
	var strong string
	if err := pool.QueryRow(ctx, `SELECT coalesce(string_agg(l.relation::regclass::text || '=' || l.mode, ' ' ORDER BY 1), '')
	  FROM pg_locks l WHERE l.pid = $1 AND l.granted AND l.locktype = 'relation'
	   AND l.mode IN ('ShareUpdateExclusiveLock', 'ShareLock', 'ShareRowExclusiveLock', 'ExclusiveLock', 'AccessExclusiveLock')`, waiter).Scan(&strong); err != nil {
		t.Fatal(err)
	}
	if strong != "" {
		t.Errorf("the import into %s holds, while it waits on a shared row: %s (want no lock above ROW EXCLUSIVE: its partition made ahead)", next.Format("2006-01"), strong)
	}
	if _, err := tx1.Exec(ctx, `SELECT pgvigil.import_activity($1, $2, $3::jsonb)`, i0, now,
		fmt.Sprintf(`[{"kind":"session","pid":1,"state":"active","query_hash":%d,"query":"select 'n4'"}]`, hash)); err != nil {
		t.Fatalf("tx1's import into this month: %v", err)
	}
	if err := tx1.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("the Repo's import into next month: %v", err)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("the Repo's import did not return within 60 s")
	}
	if n := strings.Count(logged.String(), "taking it again"); n != 0 {
		t.Errorf("the import was taken again %d time(s) after a deadlock (want 0: no cycle can form): %q", n, logged.String())
	}
	var n0, n1 int
	if err := pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE instance_id = $1), count(*) FILTER (WHERE instance_id = $2)
	  FROM pgvigil.activity_sample WHERE instance_id IN ($1, $2)`, i0, i1).Scan(&n0, &n1); err != nil {
		t.Fatal(err)
	}
	if n0 != 1 || n1 != 1 {
		t.Errorf("activity rows stored: this month %d, next month %d (want 1 and 1)", n0, n1)
	}
}
