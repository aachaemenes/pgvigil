package repo

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0134's move from DBA Dash (task 206):
//   - collect_from is the collector's first mssql_instance write after the add, kept after; the import is refused
//     before it; a server collected before, removed and moved again gets it at its next read (TestMoveCollectFrom);
//   - a moved server's rows at or after collect_from are never imported; cpu waits for the collector's ok CPU read
//     and jobruns for its ok or skipped job read since collect_from (TestMoveBounds);
//   - the collector's job outcome first, the import of the same history id with its local time an hour off stores
//     nothing (the daylight-saving double, TestMoveJobRunDST);
//   - one batch sent twice at once stores each row once, moved or not (TestMoveConcurrentImport);
//   - the add is refused, with no move row and an audit row, when the server is collected, its host and port are on
//     Admin > Instances, its DBA Dash proposal is approved, or the name is taken; a proposed one is approved by the
//     add; a remove of the never-read moved server takes its move rows with it (TestMoveAddRefusals);
//   - a collector-member login imports through the functions with no SELECT or INSERT on the tables; a reader-member
//     login may not call them (TestMoveCollectorLogin).

func moveStore(t *testing.T) (context.Context, *pgxpool.Pool, int64) {
	t.Helper()
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	t.Cleanup(cancel)
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return ctx, pool, time.Now().UnixNano() % 1000000000
}

// moveRepo makes a configured DBA Dash repository with the given InstanceIDs of one server (DBA Dash's Instance).
func moveRepo(ctx context.Context, t *testing.T, pool *pgxpool.Pool, repo, server string, ids ...int) {
	t.Helper()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.dbadash_repositories (repository, status, read_at) VALUES ($1, 'ok', now())
	                             ON CONFLICT (repository) DO UPDATE SET is_configured = true`, repo); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.dbadash_instances (repository, instance_id, instance, connection_id, display_name, first_seen, snapshot_at)
		                             VALUES ($1, $2, $3, $4, $3, now(), now())`, repo, id, server, fmt.Sprintf("%s-conn%d", strings.ToLower(server), id)); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.dbadash_repositories WHERE repository = $1`, repo)
	})
}

// moveCall runs import_dbadash_move and returns its answer.
func moveCall(ctx context.Context, t *testing.T, pool *pgxpool.Pool, pay map[string]any) map[string]any {
	t.Helper()
	b, _ := json.Marshal(pay)
	var raw []byte
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_dbadash_move(now(), $1::jsonb)::text`, string(b)).Scan(&raw); err != nil {
		t.Fatalf("import_dbadash_move %v: %v", pay["op"], err)
	}
	out := map[string]any{}
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// moveAdd is an add's payload; the ConnectionIDs (204's proposals) are read by the function from dbadash_instances.
func moveAdd(repo, server, name, host string, ids ...int) map[string]any {
	return map[string]any{"op": "add", "ui_user": "t206", "client": "test", "repository": repo, "server": server, "dbadash_ids": ids,
		"name": name, "platform": "", "dsn_ref": "file:/nonexistent/t206", "auth": "sql", "host": host, "port": "", "tags": []string{}}
}

// moved adds a moved server and returns its instance_id; the instance and its move go at the test's end.
func moved(ctx context.Context, t *testing.T, pool *pgxpool.Pool, repo, server, name, host string, ids ...int) int {
	t.Helper()
	ans := moveCall(ctx, t, pool, moveAdd(repo, server, name, host, ids...))
	if ans["outcome"] != "done" {
		t.Fatalf("the move of %s: %v", server, ans)
	}
	var id int
	if err := pool.QueryRow(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name = $1`, name).Scan(&id); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, name) })
	// the move made a day ago: the tests' reads 'an hour ago' come after it (a read before the add sets nothing)
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.dbadash_moves SET added_at = added_at - interval '1 day' WHERE instance_id = $1`, id); err != nil {
		t.Fatal(err)
	}
	return id
}

func dropInstance(pool *pgxpool.Pool, name string) {
	ctx := context.Background()
	// the four history tables have no foreign key to instances: their rows first
	for _, tbl := range []string{"mssql_cpu_sample", "mssql_volume_sample", "mssql_database_size", "mssql_job_runs"} {
		_, _ = pool.Exec(ctx, `DELETE FROM pgvigil.`+tbl+` WHERE instance_id IN (SELECT instance_id FROM pgvigil.instances WHERE name = $1)`, name)
	}
	_, _ = pool.Exec(ctx, `DELETE FROM pgvigil.admin_instances WHERE name = $1`, name)
	_, _ = pool.Exec(ctx, `DELETE FROM pgvigil.admin_removed WHERE name = $1`, name)
	_, _ = pool.Exec(ctx, `DELETE FROM pgvigil.instances WHERE name = $1`, name)
}

// firstRead writes the collector's mssql_instance row (insert, then update).
func firstRead(ctx context.Context, t *testing.T, pool *pgxpool.Pool, id int, at time.Time, server string) {
	t.Helper()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_instance (instance_id, snapshot_at, server_name) VALUES ($1, $2, $3)
	    ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, server_name = EXCLUDED.server_name`, id, at, server); err != nil {
		t.Fatal(err)
	}
}

// storeNow is the store's clock (an add's added_at is the store's now(), never this host's)
func storeNow(ctx context.Context, t *testing.T, pool *pgxpool.Pool, plus time.Duration) time.Time {
	t.Helper()
	var at time.Time
	if err := pool.QueryRow(ctx, `SELECT now() + make_interval(secs => $1)`, plus.Seconds()).Scan(&at); err != nil {
		t.Fatal(err)
	}
	return at.UTC().Truncate(time.Millisecond)
}

// heldRace runs first in a transaction of one connection and keeps it open, starts second on another connection,
// waits until second is seen waiting on an advisory lock (the code's own lock, not a row or key lock), then commits
// first and returns second's answer. Code without the lock fails here: second does not wait, or waits on a row.
func heldRace(ctx context.Context, t *testing.T, pool *pgxpool.Pool, first func(pgx.Tx) error, second func(*pgxpool.Conn) (any, error)) any {
	t.Helper()
	a, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Release()
	b, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Release()
	tx, err := a.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if err := first(tx); err != nil {
		t.Fatalf("the first call: %v", err)
	}
	var bpid int
	if err := b.QueryRow(ctx, `SELECT pg_backend_pid()`).Scan(&bpid); err != nil {
		t.Fatal(err)
	}
	type result struct {
		v   any
		err error
	}
	done := make(chan result, 1)
	go func() { v, err := second(b); done <- result{v, err} }()
	var typ, event string
	for deadline := time.Now().Add(10 * time.Second); ; {
		select {
		case r := <-done:
			t.Fatalf("the second call answered %v (%v) while the first was still open: it did not wait", r.v, r.err)
		default:
		}
		if err := pool.QueryRow(ctx, `SELECT coalesce(wait_event_type, ''), coalesce(wait_event, '') FROM pg_stat_activity WHERE pid = $1`, bpid).Scan(&typ, &event); err != nil {
			t.Fatal(err)
		}
		if typ == "Lock" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the second call did not wait on a lock in 10 s (wait %q %q)", typ, event)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if event != "advisory" {
		t.Fatalf("the second call waits on a %q lock, want the advisory one (a row or key wait = no lock of the code's own)", event)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	r := <-done
	if r.err != nil {
		t.Fatalf("the second call after the first's commit: %v", r.err)
	}
	return r.v
}

func collectFrom(ctx context.Context, t *testing.T, pool *pgxpool.Pool, id int) *time.Time {
	t.Helper()
	var at *time.Time
	if err := pool.QueryRow(ctx, `SELECT collect_from FROM pgvigil.dbadash_moves WHERE instance_id = $1`, id).Scan(&at); err != nil {
		t.Fatal(err)
	}
	return at
}

func collected(ctx context.Context, t *testing.T, pool *pgxpool.Pool, id int, collection, status string, at time.Time) {
	t.Helper()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, $2, $3, $4)
	    ON CONFLICT (instance_id, collection) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, status = EXCLUDED.status`, id, collection, at, status); err != nil {
		t.Fatal(err)
	}
}

// importRows calls import_dbadash_<key> with rows; err is the call's.
func importRows(ctx context.Context, q interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, key string, id int, rows []map[string]any) (int64, error) {
	b, _ := json.Marshal(rows)
	var n int64
	err := q.QueryRow(ctx, fmt.Sprintf(`SELECT pgvigil.import_dbadash_%s($1, $2::jsonb, '{"linux": false}'::jsonb)`, key), id, string(b)).Scan(&n)
	return n, err
}

func stored(ctx context.Context, t *testing.T, pool *pgxpool.Pool, id int, key string) int64 {
	t.Helper()
	var n int64
	if err := pool.QueryRow(ctx, `SELECT pgvigil.dbadash_import_stored($1, $2, '-infinity', 'infinity')`, id, key).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func refusedWith(err error, words string) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "55000" && strings.Contains(pe.Message, words)
}

func volRows(at ...time.Time) []map[string]any {
	var out []map[string]any
	for _, a := range at {
		out = append(out, map[string]any{"at": a.UTC().Format(time.RFC3339Nano), "volume": "/", "total_bytes": 1000, "free_bytes": 400})
	}
	return out
}

func cpuRows(at ...time.Time) []map[string]any {
	var out []map[string]any
	for _, a := range at {
		out = append(out, map[string]any{"at": a.UTC().Format(time.RFC3339Nano), "sql_pct": 7, "idle_pct": 90})
	}
	return out
}

func jobRow(at time.Time, history int64, local time.Time) map[string]any {
	return map[string]any{"at": at.UTC().Format(time.RFC3339Nano), "history_id": history, "job_id": "1d3c5e7a-0000-4000-8000-00000000abcd",
		"job_name": "nightly", "step_id": 0, "step_name": "(Job outcome)", "run_status": 1, "duration_s": 3, "sql_message_id": 0,
		"sql_severity": 0, "retries": 0, "message": "The job succeeded.", "local_at": local.Format("2006-01-02T15:04:05")}
}

func TestMoveCollectFrom(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo, srv := fmt.Sprintf("r206a-%d", sfx), fmt.Sprintf("SRVA%d", sfx)
	moveRepo(ctx, t, pool, repo, srv, 7)
	id := moved(ctx, t, pool, repo, srv, fmt.Sprintf("mva-%d", sfx), fmt.Sprintf("hosta-%d", sfx), 7)
	if at := collectFrom(ctx, t, pool, id); at != nil {
		t.Fatalf("collect_from after the add = %v, want NULL", *at)
	}
	if _, err := importRows(ctx, pool, "volumes", id, volRows(time.Now().Add(-time.Hour))); !refusedWith(err, "collect it first") {
		t.Fatalf("an import before the first read: %v, want refused 'collect it first'", err)
	}
	t1 := time.Now().UTC().Truncate(time.Millisecond)
	firstRead(ctx, t, pool, id, t1, srv)
	if at := collectFrom(ctx, t, pool, id); at == nil || !at.Equal(t1) {
		t.Fatalf("collect_from after the first read = %v, want %v", at, t1)
	}
	firstRead(ctx, t, pool, id, t1.Add(5*time.Minute), srv)
	if at := collectFrom(ctx, t, pool, id); at == nil || !at.Equal(t1) {
		t.Fatalf("collect_from after a later read = %v, want %v kept", at, t1)
	}
	// an InstanceID outside the move (DBA Dash re-added the server) under the moved name goes to the move too
	var raw []byte
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_dbadash_instance($1::jsonb)::text`,
		fmt.Sprintf(`{"repository": %q, "dbadash_id": 999, "name": "mva-%d", "platform": "sqlserver", "version": "1.0"}`, repo, sfx)).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"moved": true`) || !strings.Contains(string(raw), fmt.Sprintf(`"instance_id": %d`, id)) {
		t.Fatalf("an unmoved InstanceID under the moved name: %s, want the move %d", raw, id)
	}

	// the host reaches another server: nothing set, and the import says which server it reaches; a read of the moved
	// server from before the add sets nothing either
	srv3 := fmt.Sprintf("SRVW%d", sfx)
	moveRepo(ctx, t, pool, repo, srv3, 9)
	wid := moved(ctx, t, pool, repo, srv3, fmt.Sprintf("mvw-%d", sfx), fmt.Sprintf("hostw-%d", sfx), 9)
	firstRead(ctx, t, pool, wid, t1, "ANOTHER"+srv3)
	if at := collectFrom(ctx, t, pool, wid); at != nil {
		t.Fatalf("collect_from after a read of another server = %v, want NULL", *at)
	}
	if _, err := importRows(ctx, pool, "volumes", wid, volRows(t1.Add(-time.Hour))); !refusedWith(err, "pgvigil reaches ANOTHER"+srv3+" at this address, not "+srv3) {
		t.Fatalf("an import after a read of another server: %v, want refused naming it", err)
	}
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.dbadash_moves SET added_at = now() WHERE instance_id = $1`, wid); err != nil {
		t.Fatal(err)
	}
	firstRead(ctx, t, pool, wid, t1.Add(-time.Hour), srv3)
	if at := collectFrom(ctx, t, pool, wid); at != nil {
		t.Fatalf("collect_from after a read from before the add = %v, want NULL", *at)
	}

	// a server collected before (its mssql_instance row kept), removed, then moved under its old name
	srv2, old := fmt.Sprintf("SRVB%d", sfx), fmt.Sprintf("old-%d", sfx)
	moveRepo(ctx, t, pool, repo, srv2, 8)
	var oid int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0.4295.3', 160000, false, '{}'::text[], 'sqlserver')`, old).Scan(&oid); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, old) })
	firstRead(ctx, t, pool, oid, t1.Add(-48*time.Hour), srv2)
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.instances SET is_active = false WHERE instance_id = $1`, oid); err != nil {
		t.Fatal(err)
	}
	if ans := moveCall(ctx, t, pool, moveAdd(repo, srv2, old, fmt.Sprintf("hostb-%d", sfx), 8)); ans["outcome"] != "done" {
		t.Fatalf("the move of a server collected before and removed: %v", ans)
	}
	if at := collectFrom(ctx, t, pool, oid); at != nil {
		t.Fatalf("collect_from of the re-moved server before its next read = %v, want NULL", *at)
	}
	t2 := t1.Add(time.Minute)
	firstRead(ctx, t, pool, oid, t2, srv2)
	if at := collectFrom(ctx, t, pool, oid); at == nil || !at.Equal(t2) {
		t.Fatalf("collect_from of the re-moved server after its next read = %v, want %v", at, t2)
	}
}

func TestMoveBounds(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo, srv := fmt.Sprintf("r206b-%d", sfx), fmt.Sprintf("SRVC%d", sfx)
	moveRepo(ctx, t, pool, repo, srv, 3)
	id := moved(ctx, t, pool, repo, srv, fmt.Sprintf("mvb-%d", sfx), fmt.Sprintf("hostc-%d", sfx), 3)
	c := time.Now().UTC().Add(-time.Hour).Truncate(time.Second)
	firstRead(ctx, t, pool, id, c, srv)

	n, err := importRows(ctx, pool, "volumes", id, volRows(c.Add(-2*time.Hour), c.Add(-time.Hour), c, c.Add(time.Hour)))
	if err != nil || n != 2 {
		t.Fatalf("volumes on both sides of collect_from: inserted %d (%v), want 2 (the two before it)", n, err)
	}
	if n, err = importRows(ctx, pool, "volumes", id, volRows(c.Add(-2*time.Hour), c.Add(-time.Hour))); err != nil || n != 0 {
		t.Fatalf("the same volumes again: inserted %d (%v), want 0", n, err)
	}

	cpu := cpuRows(c.Add(-3*time.Minute), c.Add(-2*time.Minute), c.Add(time.Minute))
	if _, err = importRows(ctx, pool, "cpu", id, cpu); !refusedWith(err, "first CPU read") {
		t.Fatalf("cpu before the collector's CPU read: %v, want refused 'first CPU read'", err)
	}
	collected(ctx, t, pool, id, "mssql_cpu", "ok", c.Add(-time.Second))
	if _, err = importRows(ctx, pool, "cpu", id, cpu); !refusedWith(err, "first CPU read") {
		t.Fatalf("cpu with the collector's CPU read before collect_from: %v, want refused", err)
	}
	collected(ctx, t, pool, id, "mssql_cpu", "ok", c.Add(time.Minute))
	if n, err = importRows(ctx, pool, "cpu", id, cpu); err != nil || n != 2 {
		t.Fatalf("cpu after the collector's CPU read: inserted %d (%v), want 2", n, err)
	}
	collected(ctx, t, pool, id, "mssql_cpu", "error", c.Add(2*time.Minute))
	if n, err = importRows(ctx, pool, "cpu", id, cpuRows(c.Add(-10*time.Minute))); err != nil || n != 1 {
		t.Fatalf("cpu after a failed read that followed the first ok one: inserted %d (%v), want 1 (the first ok read is kept)", n, err)
	}

	jobs := []map[string]any{jobRow(c.Add(-time.Hour), 101, c.Add(-time.Hour-8*time.Hour)), jobRow(c.Add(time.Hour), 102, c.Add(-7*time.Hour))}
	collected(ctx, t, pool, id, "mssql_jobs", "error", c.Add(time.Minute))
	if _, err = importRows(ctx, pool, "jobruns", id, jobs); !refusedWith(err, "first Agent job read") {
		t.Fatalf("jobruns while the job read failed: %v, want refused 'first Agent job read'", err)
	}
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.collection_dates SET status = 'skipped', note = 'no msdb access' WHERE instance_id = $1 AND collection = 'mssql_jobs'`, id); err != nil {
		t.Fatal(err)
	}
	if _, err = importRows(ctx, pool, "jobruns", id, jobs); !refusedWith(err, "(its last read: skipped: no msdb access)") {
		t.Fatalf("jobruns after a skipped job read (no msdb right): %v, want refused with the read's words", err)
	}
	collected(ctx, t, pool, id, "mssql_jobs", "ok", c.Add(2*time.Minute))
	if n, err = importRows(ctx, pool, "jobruns", id, jobs); err != nil || n != 1 {
		t.Fatalf("jobruns after an ok job read: inserted %d (%v), want 1 (the one before collect_from)", n, err)
	}
	// the collector's doors write SQL Server history under a SQL Server instance only
	pg := fmt.Sprintf("pg-%d", sfx)
	var pgid int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'postgres', '17.0', 170000, false, '{}'::text[], 'postgres')`, pg).Scan(&pgid); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, pg) })
	if _, err = importRows(ctx, pool, "volumes", pgid, volRows(c)); !refusedWith(err, "is not a SQL Server instance") {
		t.Fatalf("an import under a PostgreSQL instance: %v, want refused", err)
	}
	if n, err = importRows(ctx, pool, "dbsize", id, []map[string]any{{"at": c.Add(-time.Hour).Format(time.RFC3339), "database_name": "db1",
		"data_bytes": 8192, "log_bytes": 8192, "data_used_bytes": nil, "log_used_bytes": nil, "files": 2}}); err != nil || n != 1 {
		t.Fatalf("dbsize: inserted %d (%v), want 1", n, err)
	}
	for key, want := range map[string]int64{"volumes": 2, "cpu": 3, "jobruns": 1, "dbsize": 1} {
		if got := stored(ctx, t, pool, id, key); got != want {
			t.Errorf("%s stored %d, want %d", key, got, want)
		}
	}
}

func TestMoveJobRunDST(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo, srv := fmt.Sprintf("r206d-%d", sfx), fmt.Sprintf("SRVD%d", sfx)
	moveRepo(ctx, t, pool, repo, srv, 4)
	id := moved(ctx, t, pool, repo, srv, fmt.Sprintf("mvd-%d", sfx), fmt.Sprintf("hostd-%d", sfx), 4)
	c := time.Now().UTC().Add(-time.Hour).Truncate(time.Second)
	firstRead(ctx, t, pool, id, c, srv)
	// the run: 10:00 PDT (17:00 UTC) on 2026-10-30, read by the collector with msdb's own date and time
	run := time.Date(2026, 10, 30, 17, 0, 0, 0, time.UTC)
	pay, _ := json.Marshal([]map[string]any{{"kind": "run", "run_utc": run.Format(time.RFC3339), "history_id": 4242, "job_id": "1D3C5E7A-0000-4000-8000-00000000ABCD",
		"job_name": "nightly", "step_id": 0, "step_name": "(Job outcome)", "run_date": 20261030, "run_time": 100000, "run_status": 1, "duration_s": 3,
		"sql_message_id": 0, "sql_severity": 0, "retries": 0, "message": "The job succeeded."}})
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_jobs($1, $2, $3::jsonb)`, id, c.Add(time.Minute), string(pay)); err != nil {
		t.Fatal(err)
	}
	collected(ctx, t, pool, id, "mssql_jobs", "ok", c.Add(time.Minute))
	// DBA Dash's row of that run after the change to PST: the same UTC start, its local time rebuilt an hour off (09:00);
	// and the same row with its UTC start an hour off too (within the key's 3 hours)
	for _, at := range []time.Time{run, run.Add(time.Hour)} {
		n, err := importRows(ctx, pool, "jobruns", id, []map[string]any{jobRow(at, 4242, time.Date(2026, 10, 30, 9, 0, 0, 0, time.UTC))})
		if err != nil || n != 0 {
			t.Fatalf("the DST row at %v: inserted %d (%v), want 0", at, n, err)
		}
	}
	if got := stored(ctx, t, pool, id, "jobruns"); got != 1 {
		t.Fatalf("job outcomes stored %d, want 1", got)
	}
}

func TestMoveConcurrentImport(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo, srv := fmt.Sprintf("r206e-%d", sfx), fmt.Sprintf("SRVE%d", sfx)
	moveRepo(ctx, t, pool, repo, srv, 5)
	mid := moved(ctx, t, pool, repo, srv, fmt.Sprintf("mve-%d", sfx), fmt.Sprintf("hoste-%d", sfx), 5)
	c := time.Now().UTC().Truncate(time.Second)
	firstRead(ctx, t, pool, mid, c, srv)
	plain := fmt.Sprintf("plain-%d", sfx)
	var pid int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', NULL, NULL, false, '{}'::text[], 'sqlserver')`, plain).Scan(&pid); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, plain) })
	collected(ctx, t, pool, mid, "mssql_cpu", "ok", c.Add(time.Minute))
	var at []time.Time
	for i := 0; i < 500; i++ {
		at = append(at, c.Add(-time.Duration(i+1)*time.Minute))
	}
	for _, r := range []struct {
		id   int
		key  string
		rows []map[string]any
	}{{mid, "volumes", volRows(at...)}, {mid, "cpu", cpuRows(at...)}, {pid, "volumes", volRows(at...)}} {
		got := heldRace(ctx, t, pool,
			func(tx pgx.Tx) error {
				n, err := importRows(ctx, tx, r.key, r.id, r.rows)
				if err == nil && n != 500 {
					err = fmt.Errorf("inserted %d, want 500", n)
				}
				return err
			},
			func(b *pgxpool.Conn) (any, error) { return importRows(ctx, b, r.key, r.id, r.rows) })
		if got != int64(0) || stored(ctx, t, pool, r.id, r.key) != 500 {
			t.Fatalf("instance %d %s: the second import inserted %v, stored %d; want 0 and 500", r.id, r.key, got, stored(ctx, t, pool, r.id, r.key))
		}
	}
}

// TestMoveBoundsEveryKey: for each mapping, rows an hour before pgvigil's first read, at it and an hour after: only the
// first is imported, and the same batch again inserts nothing; a DBA Dash minute within 30 s of the collector's own CPU
// sample is skipped, one 40 s away is not.
func TestMoveBoundsEveryKey(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo, srv := fmt.Sprintf("r206j-%d", sfx), fmt.Sprintf("SRVP%d", sfx)
	moveRepo(ctx, t, pool, repo, srv, 6)
	id := moved(ctx, t, pool, repo, srv, fmt.Sprintf("mvp-%d", sfx), fmt.Sprintf("hostp-%d", sfx), 6)
	c := time.Now().UTC().Add(-3 * time.Hour).Truncate(time.Second)
	firstRead(ctx, t, pool, id, c, srv)
	collected(ctx, t, pool, id, "mssql_cpu", "ok", c.Add(time.Minute))
	collected(ctx, t, pool, id, "mssql_jobs", "ok", c.Add(time.Minute))
	three := []time.Time{c.Add(-time.Hour), c, c.Add(time.Hour)}
	sizes := func(at ...time.Time) (out []map[string]any) {
		for _, a := range at {
			out = append(out, map[string]any{"at": a.Format(time.RFC3339), "database_name": "db1", "data_bytes": 8192, "log_bytes": 8192, "files": 2})
		}
		return out
	}
	for key, rows := range map[string][]map[string]any{
		"volumes": volRows(three...), "cpu": cpuRows(three...), "dbsize": sizes(three...),
		"jobruns": {jobRow(three[0], 201, three[0]), jobRow(three[1], 202, three[1]), jobRow(three[2], 203, three[2])},
	} {
		for i, want := range []int64{1, 0} {
			if n, err := importRows(ctx, pool, key, id, rows); err != nil || n != want {
				t.Fatalf("%s, send %d: inserted %d (%v), want %d (only the row before pgvigil's first read, once)", key, i+1, n, err, want)
			}
		}
	}
	// the collector's own CPU sample (a positive ring-buffer record number) two hours before its first read
	own := c.Add(-2 * time.Hour)
	if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition('mssql_cpu_sample', $1)`, own); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct) VALUES ($1, $2, 4711, 5)`, id, own); err != nil {
		t.Fatal(err)
	}
	if n, err := importRows(ctx, pool, "cpu", id, cpuRows(own.Add(10*time.Second))); err != nil || n != 0 {
		t.Fatalf("a DBA Dash minute 10 s from the collector's sample: inserted %d (%v), want 0", n, err)
	}
	if n, err := importRows(ctx, pool, "cpu", id, cpuRows(own.Add(40*time.Second))); err != nil || n != 1 {
		t.Fatalf("a DBA Dash minute 40 s from the collector's sample: inserted %d (%v), want 1", n, err)
	}
}

func TestMoveAddRefusals(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo := fmt.Sprintf("r206f-%d", sfx)
	audits := func(target, op string) (refused int) {
		t.Helper()
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE target = $1 AND op = $2 AND outcome = 'refused'`, target, op).Scan(&refused); err != nil {
			t.Fatal(err)
		}
		return refused
	}
	// moves: the server's moves (any name) and the name's moves (any server)
	moves := func(server, name string) (ofServer, ofName int) {
		t.Helper()
		if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM pgvigil.dbadash_moves WHERE repository = $1 AND server = $2),
		    (SELECT count(*) FROM pgvigil.dbadash_moves m JOIN pgvigil.instances i ON i.instance_id = m.instance_id WHERE i.name = $3)`, repo, server, name).Scan(&ofServer, &ofName); err != nil {
			t.Fatal(err)
		}
		return ofServer, ofName
	}
	// refuse: refused with its words, one refused audit row of op for the name, no move row, and - for the move's own
	// refusals (op 'dbadash move add') - no page row and no instance of the name written
	refuse := func(pay map[string]any, words, op string) {
		t.Helper()
		name, server := pay["name"].(string), pay["server"].(string)
		before := audits(name, op)
		serverBefore, _ := moves(server, name)
		ans := moveCall(ctx, t, pool, pay)
		if ans["outcome"] != "refused" || !strings.Contains(fmt.Sprint(ans["detail"]), words) {
			t.Fatalf("%s: %v, want refused '%s'", pay["server"], ans, words)
		}
		if audits(name, op) != before+1 {
			t.Fatalf("%s: no refused audit row '%s' for %s", pay["server"], op, name)
		}
		// no move written: the server's moves as before (a 'moved already' server keeps its earlier one), none of the name
		// unless it held one before (the name-taken case names another server's instance: none there either)
		if ofServer, ofName := moves(server, name); ofServer != serverBefore || ofName != 0 {
			t.Fatalf("%s: moves of the server %d (was %d), of %s %d after a refused add; want unchanged and 0", server, ofServer, serverBefore, name, ofName)
		}
		if op == "dbadash move add" {
			var pages, insts int
			if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM pgvigil.admin_instances WHERE name = $1), (SELECT count(*) FROM pgvigil.instances WHERE name = $1)`, name).Scan(&pages, &insts); err != nil {
				t.Fatal(err)
			}
			if pages != 0 || insts != 0 {
				t.Fatalf("%s: a refused move wrote %d page row(s) and %d instance(s) of %s", pay["server"], pages, insts, name)
			}
		}
	}

	// collected already: an active instance read under the server's @@SERVERNAME
	sa := fmt.Sprintf("SRVF%d", sfx)
	moveRepo(ctx, t, pool, repo, sa, 11)
	have := fmt.Sprintf("have-%d", sfx)
	var hid int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0.1', 160000, false, '{}'::text[], 'sqlserver')`, have).Scan(&hid); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, have) })
	firstRead(ctx, t, pool, hid, time.Now(), strings.ToLower(sa))
	pa := moveAdd(repo, sa, fmt.Sprintf("mvfa-%d", sfx), fmt.Sprintf("hostfa-%d", sfx), 11)
	refuse(pa, "collects "+sa+" already, as "+have, "dbadash move add")

	// its host and port on Admin > Instances already
	sb := fmt.Sprintf("SRVG%d", sfx)
	moveRepo(ctx, t, pool, repo, sb, 12)
	page, host := fmt.Sprintf("page-%d", sfx), fmt.Sprintf("hostg-%d", sfx)
	b, _ := json.Marshal(map[string]any{"op": "add", "ui_user": "t206", "name": page, "engine": "sqlserver", "dsn_ref": "file:/nonexistent/p", "auth": "sql",
		"host": host, "port": "1433"})
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_admin_instance(now(), $1::jsonb)`, string(b)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, page) })
	pb := moveAdd(repo, sb, fmt.Sprintf("mvfb-%d", sfx), strings.ToUpper(host), 12)
	refuse(pb, "Admin > Instances has", "dbadash move add")

	// approved already from a DBA Dash source of this repository
	sc := fmt.Sprintf("SRVH%d", sfx)
	moveRepo(ctx, t, pool, repo, sc, 13, 14)
	src := fmt.Sprintf("dd-%d", sfx)
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.admin_sources (name, kind, ref, credential_ref, created_by) VALUES ($1, 'dbadash', $2, 'file:/nonexistent/s', 't206')`, src, repo); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_sources WHERE name = $1`, src)
	})
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.admin_proposals (source, server, engine, host, state, instance_name) VALUES ($1, $2, 'sqlserver', $2, 'approved', 'other')`,
		src, strings.ToLower(sc)+"-conn13"); err != nil {
		t.Fatal(err)
	}
	pc := moveAdd(repo, sc, fmt.Sprintf("mvfc-%d", sfx), fmt.Sprintf("hostfc-%d", sfx), 13, 14)
	refuse(pc, "approved already from the source "+src+" as other", "dbadash move add")

	// InstanceIDs out of range or not numbers: refused, nothing dropped silently
	for _, bad := range []any{[]any{12, 9999999999}, []any{12, "x"}, []any{}} {
		pay := moveAdd(repo, sb, fmt.Sprintf("mvfx-%d", sfx), fmt.Sprintf("hostfx-%d", sfx))
		pay["dbadash_ids"] = bad
		refuse(pay, "each 1 to 2147483647", "dbadash move add")
	}

	// the name taken (import_admin_instance's refusal)
	sd := fmt.Sprintf("SRVI%d", sfx)
	moveRepo(ctx, t, pool, repo, sd, 15)
	pd := moveAdd(repo, sd, page, fmt.Sprintf("hostfd-%d", sfx), 15)
	refuse(pd, "exists already", "instance add")
	var pageHost string
	if err := pool.QueryRow(ctx, `SELECT host FROM pgvigil.admin_instances WHERE name = $1`, page).Scan(&pageHost); err != nil || pageHost != host {
		t.Fatalf("the page row of the taken name after the refused move: host %q (%v), want %s unchanged", pageHost, err, host)
	}

	// an InstanceID of another server, and a repository not configured
	sx := fmt.Sprintf("SRVX%d", sfx)
	moveRepo(ctx, t, pool, repo, sx, 17)
	px := moveAdd(repo, sx, fmt.Sprintf("mvfy-%d", sfx), fmt.Sprintf("hostfy-%d", sfx), 17, 11)
	refuse(px, "an InstanceID given is not "+sx+" in repository "+repo, "dbadash move add")
	pn := moveAdd(fmt.Sprintf("nosuch-%d", sfx), sx, fmt.Sprintf("mvfz-%d", sfx), fmt.Sprintf("hostfz-%d", sfx), 17)
	refuse(pn, "no DBA Dash repository nosuch-", "dbadash move add")

	// a proposed one of this repository is approved by the add, under the instance's name
	se := fmt.Sprintf("SRVJ%d", sfx)
	moveRepo(ctx, t, pool, repo, se, 16)
	conn := strings.ToLower(se) + "-conn16"
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.admin_proposals (source, server, engine, host) VALUES ($1, $2, 'sqlserver', $2)`, src, conn); err != nil {
		t.Fatal(err)
	}
	name := fmt.Sprintf("mvfe-%d", sfx)
	id := moved(ctx, t, pool, repo, se, name, fmt.Sprintf("hostfe-%d", sfx), 16)
	var state, inst string
	if err := pool.QueryRow(ctx, `SELECT state, coalesce(instance_name, '') FROM pgvigil.admin_proposals WHERE source = $1 AND server = $2`, src, conn).Scan(&state, &inst); err != nil {
		t.Fatal(err)
	}
	if state != "approved" || inst != name {
		t.Fatalf("the proposal after the add: %s as %q, want approved as %s", state, inst, name)
	}
	// the same server again, under another name; and its InstanceID under another @@SERVERNAME (DBA Dash renamed it)
	refuse(moveAdd(repo, se, fmt.Sprintf("mvfe2-%d", sfx), fmt.Sprintf("hostfe2-%d", sfx), 16), se+" was moved already, as "+name, "dbadash move add")
	se2 := se + "B"
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.dbadash_instances SET instance = $3 WHERE repository = $1 AND instance_id = $2`, repo, 16, se2); err != nil {
		t.Fatal(err)
	}
	refuse(moveAdd(repo, se2, fmt.Sprintf("mvfe3-%d", sfx), fmt.Sprintf("hostfe3-%d", sfx), 16), "an InstanceID of "+se2+" was moved already, as "+name, "dbadash move add")
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.dbadash_instances SET instance = $3 WHERE repository = $1 AND instance_id = $2`, repo, 16, se); err != nil {
		t.Fatal(err)
	}

	// a remove of the moved server never read takes its move rows with it
	b, _ = json.Marshal(map[string]any{"op": "remove", "ui_user": "t206", "name": name})
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_admin_instance(now(), $1::jsonb)`, string(b)); err != nil {
		t.Fatal(err)
	}
	var left, ids int
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM pgvigil.dbadash_moves WHERE instance_id = $1), (SELECT count(*) FROM pgvigil.dbadash_move_ids WHERE instance_id = $1)`, id).Scan(&left, &ids); err != nil {
		t.Fatal(err)
	}
	if left != 0 || ids != 0 {
		t.Fatalf("after the remove: %d move row(s), %d id row(s); want 0 and 0", left, ids)
	}
}

func TestMoveCollectorLogin(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	coll, rdr := fmt.Sprintf("t206c_%d", sfx), fmt.Sprintf("t206r_%d", sfx)
	for role, member := range map[string]string{coll: "pgvigil_collector", rdr: "pgvigil_reader"} {
		if _, err := pool.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s NOLOGIN IN ROLE %s`, role, member)); err != nil {
			t.Skipf("this store's login may not make roles (it needs CREATE ROLE and SET ROLE): %v", err)
		}
		t.Cleanup(func() { _, _ = pool.Exec(context.Background(), fmt.Sprintf(`DROP ROLE IF EXISTS %s`, role)) })
	}
	name := fmt.Sprintf("cl-%d", sfx)
	t.Cleanup(func() { dropInstance(pool, name) })
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SET ROLE `+coll); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = conn.Exec(context.Background(), `RESET ROLE`) }()
	var raw []byte
	if err := conn.QueryRow(ctx, `SELECT pgvigil.import_dbadash_instance($1::jsonb)::text`,
		fmt.Sprintf(`{"repository": "none", "dbadash_id": 1, "name": %q, "platform": "sqlserver", "version": "16.0.4295.3", "version_num": 160000, "tags": ["env:proof"]}`, name)).Scan(&raw); err != nil {
		t.Fatalf("import_dbadash_instance as a collector member: %v", err)
	}
	var tgt struct {
		ID int `json:"instance_id"`
	}
	if err := json.Unmarshal(raw, &tgt); err != nil || tgt.ID == 0 {
		t.Fatalf("import_dbadash_instance answered %s", raw)
	}
	// the dry run's read (the collector member has no SELECT: dbadash_import_target is its door)
	if err := conn.QueryRow(ctx, `SELECT pgvigil.dbadash_import_target($1::jsonb)::text`, fmt.Sprintf(`{"repository": "none", "dbadash_id": 1, "name": %q}`, name)).Scan(&raw); err != nil ||
		!strings.Contains(string(raw), fmt.Sprintf(`"instance_id": %d`, tgt.ID)) {
		t.Fatalf("dbadash_import_target as a collector member: %s (%v)", raw, err)
	}
	at := time.Now().UTC().Add(-48 * time.Hour).Truncate(time.Second)
	for key, rows := range map[string][]map[string]any{
		"cpu": cpuRows(at), "volumes": volRows(at), "jobruns": {jobRow(at, 7, at)},
		"dbsize": {{"at": at.Format(time.RFC3339), "database_name": "db1", "data_bytes": 8192, "log_bytes": 8192, "files": 2}},
	} {
		n, err := importRows(ctx, conn, key, tgt.ID, rows)
		if err != nil || n != 1 {
			t.Fatalf("import_dbadash_%s as a collector member: inserted %d (%v), want 1", key, n, err)
		}
		var s int64
		if err := conn.QueryRow(ctx, `SELECT pgvigil.dbadash_import_stored($1, $2, '-infinity', 'infinity')`, tgt.ID, key).Scan(&s); err != nil || s != 1 {
			t.Fatalf("dbadash_import_stored %s as a collector member: %d (%v), want 1", key, s, err)
		}
	}
	if _, err := conn.Exec(ctx, `RESET ROLE`); err != nil {
		t.Fatal(err)
	}
	for _, tbl := range []string{"mssql_cpu_sample", "mssql_volume_sample", "mssql_database_size", "mssql_job_runs"} {
		var sel, ins bool
		if err := pool.QueryRow(ctx, `SELECT has_table_privilege($1, $2, 'SELECT'), has_table_privilege($1, $2, 'INSERT')`, coll, "pgvigil."+tbl).Scan(&sel, &ins); err != nil {
			t.Fatal(err)
		}
		if sel || ins {
			t.Errorf("the collector member on %s: SELECT %v INSERT %v, want false and false", tbl, sel, ins)
		}
	}
	if _, err := conn.Exec(ctx, `SET ROLE `+rdr); err != nil {
		t.Fatal(err)
	}
	for fn, call := range map[string]string{
		"import_dbadash_cpu": `SELECT pgvigil.import_dbadash_cpu($1, '[]', '{}')`, "import_dbadash_volumes": `SELECT pgvigil.import_dbadash_volumes($1, '[]', '{}')`,
		"import_dbadash_dbsize": `SELECT pgvigil.import_dbadash_dbsize($1, '[]', '{}')`, "import_dbadash_jobruns": `SELECT pgvigil.import_dbadash_jobruns($1, '[]', '{}')`,
		"import_dbadash_instance": `SELECT pgvigil.import_dbadash_instance(jsonb_build_object('name', 'x' || $1::int))`,
		"import_dbadash_move":     `SELECT pgvigil.import_dbadash_move(now(), jsonb_build_object('op', 'tick', 'ui_user', 'x', 'name', 'x' || $1::int))`,
	} {
		_, err := conn.Exec(ctx, call, tgt.ID)
		var pe *pgconn.PgError
		if !errors.As(err, &pe) || pe.Code != "42501" || !strings.Contains(pe.Message, "function "+fn) {
			t.Errorf("%s as a reader member: %v, want permission denied for function %s", fn, err, fn)
		}
	}
}

func TestMoveRemovedThenAddedAgain(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo, srv, other := fmt.Sprintf("r206g-%d", sfx), fmt.Sprintf("SRVK%d", sfx), fmt.Sprintf("SRVL%d", sfx)
	moveRepo(ctx, t, pool, repo, srv, 31)
	moveRepo(ctx, t, pool, repo, other, 32)
	name, host := fmt.Sprintf("mvk-%d", sfx), fmt.Sprintf("hostk-%d", sfx)
	id := moved(ctx, t, pool, repo, srv, name, host, 31)
	t1 := time.Now().UTC().Truncate(time.Millisecond)
	firstRead(ctx, t, pool, id, t1, srv)
	admin := func(op string) {
		t.Helper()
		b, _ := json.Marshal(map[string]any{"op": op, "ui_user": "t206", "name": name, "engine": "sqlserver", "dsn_ref": "file:/nonexistent/k", "auth": "sql", "host": host})
		var out string
		if err := pool.QueryRow(ctx, `SELECT pgvigil.import_admin_instance(now(), $1::jsonb)->>'outcome'`, string(b)).Scan(&out); err != nil || out != "done" {
			t.Fatalf("instance %s: %s (%v)", op, out, err)
		}
	}
	moves := func() (n int) {
		t.Helper()
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.dbadash_moves WHERE instance_id = $1`, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	// the remove of a read instance (kept, inactive) ends its move
	admin("remove")
	if moves() != 0 {
		t.Fatal("the move survived the remove of its page row")
	}
	// a plain add under the name: no move, so no bound and no wait (rows after the old collect_from are taken)
	admin("add")
	if n, err := importRows(ctx, pool, "volumes", id, volRows(t1.Add(time.Hour))); err != nil || n != 1 {
		t.Fatalf("an import after a plain add again: inserted %d (%v), want 1", n, err)
	}
	// moved again: a new move, its collect_from from its own next read
	admin("remove")
	if ans := moveCall(ctx, t, pool, moveAdd(repo, srv, name, host, 31)); ans["outcome"] != "done" {
		t.Fatalf("the server moved again: %v", ans)
	}
	if at := collectFrom(ctx, t, pool, id); at != nil {
		t.Fatalf("collect_from of the move made again = %v, want NULL until its read", *at)
	}
	t2 := storeNow(ctx, t, pool, time.Second)
	firstRead(ctx, t, pool, id, t2, srv)
	if at := collectFrom(ctx, t, pool, id); at == nil || !at.Equal(t2) {
		t.Fatalf("collect_from of the move made again after its read = %v, want %v", at, t2)
	}
	// another server moved under the removed name: a move of it, no key error
	admin("remove")
	if ans := moveCall(ctx, t, pool, moveAdd(repo, other, name, fmt.Sprintf("hostl-%d", sfx), 32)); ans["outcome"] != "done" {
		t.Fatalf("another server moved under the removed name: %v", ans)
	}
	var server string
	if err := pool.QueryRow(ctx, `SELECT server FROM pgvigil.dbadash_moves WHERE instance_id = $1`, id).Scan(&server); err != nil || server != other {
		t.Fatalf("the move under the name: %q (%v), want %s", server, err, other)
	}
}

func TestMoveRunMarker(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo, srv := fmt.Sprintf("r206h-%d", sfx), fmt.Sprintf("SRVM%d", sfx)
	moveRepo(ctx, t, pool, repo, srv, 41)
	name := fmt.Sprintf("mvm-%d", sfx)
	id := moved(ctx, t, pool, repo, srv, name, fmt.Sprintf("hostm-%d", sfx), 41)
	op := func(o string, extra map[string]any) map[string]any {
		t.Helper()
		pay := map[string]any{"op": o, "ui_user": "t206", "name": name}
		for k, v := range extra {
			pay[k] = v
		}
		return moveCall(ctx, t, pool, pay)
	}
	want := func(ans map[string]any, outcome, words string) {
		t.Helper()
		if ans["outcome"] != outcome || !strings.Contains(fmt.Sprint(ans["detail"]), words) {
			t.Fatalf("%v, want %s '%s'", ans, outcome, words)
		}
	}
	want(op("run", nil), "refused", "collect it first")
	firstRead(ctx, t, pool, id, time.Now().UTC(), srv)
	r1 := op("run", nil)
	want(r1, "done", "run "+name)
	if fmt.Sprint(r1["run_id"]) != "1" {
		t.Fatalf("the first run's id: %v, want 1", r1["run_id"])
	}
	want(op("run", nil), "refused", "an import of "+name+" runs already: started by t206")
	want(op("beat", map[string]any{"run_id": 0}), "refused", "was taken over: run 1 is the current one")
	want(op("beat", map[string]any{"run_id": 1, "imported": map[string]any{"cpu": 5}}), "done", "beat "+name)
	want(op("ended", map[string]any{"run_id": 1, "outcome": "ok", "imported": map[string]any{"cpu": 7}}), "done", "ended "+name)
	var imported *time.Time
	if err := pool.QueryRow(ctx, `SELECT imported_at FROM pgvigil.dbadash_moves WHERE instance_id = $1`, id).Scan(&imported); err != nil || imported == nil {
		t.Fatalf("imported_at after a run ended ok: %v (%v)", imported, err)
	}
	want(op("run", nil), "done", "run "+name)
	want(op("ended", map[string]any{"run_id": 1, "outcome": "failed"}), "refused", "run 1 of "+name+" was taken over: run 2 is the current one")
	var audits int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE target = $1 AND op = 'dbadash move run'`, name).Scan(&audits); err != nil || audits != 4 {
		t.Fatalf("audit rows of 'dbadash move run': %d (%v), want 4 (two refused, two done)", audits, err)
	}
}

func TestMoveAddTwiceAtOnce(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo, srv := fmt.Sprintf("r206i-%d", sfx), fmt.Sprintf("SRVN%d", sfx)
	moveRepo(ctx, t, pool, repo, srv, 51)
	names := []string{fmt.Sprintf("mvn1-%d", sfx), fmt.Sprintf("mvn2-%d", sfx)}
	for _, n := range names {
		t.Cleanup(func() { dropInstance(pool, n) })
	}
	add := func(q interface {
		QueryRow(context.Context, string, ...any) pgx.Row
	}, k int) (string, error) {
		b, _ := json.Marshal(moveAdd(repo, srv, names[k], fmt.Sprintf("hostn%d-%d", k, sfx), 51))
		var out string
		err := q.QueryRow(ctx, `SELECT pgvigil.import_dbadash_move(now(), $1::jsonb)::text`, string(b)).Scan(&out)
		return out, err
	}
	got := heldRace(ctx, t, pool,
		func(tx pgx.Tx) error {
			out, err := add(tx, 0)
			if err == nil && !strings.Contains(out, `"outcome": "done"`) {
				err = fmt.Errorf("the first add: %s", out)
			}
			return err
		},
		func(b *pgxpool.Conn) (any, error) { return add(b, 1) })
	if !strings.Contains(fmt.Sprint(got), `"outcome": "refused"`) || !strings.Contains(fmt.Sprint(got), "was moved already, as "+names[0]) {
		t.Fatalf("the second add of one server at once: %v, want refused 'was moved already, as %s'", got, names[0])
	}
}

// TestMoveXEForeignOnAStore (task 206, W8 b): the collector's XE read stores DBA Dash's own sessions it listed - a
// read with the marker replaces the instance's list whole (a name that is not DBADash_% is dropped), a read older than
// the stored one changes nothing, a read without the marker (it failed before the list) keeps the list, a read that
// listed none empties it and says when.
func TestMoveXEForeignOnAStore(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	name := fmt.Sprintf("xef-%d", sfx)
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0.1', 160000, false, '{}'::text[], 'sqlserver')`, name).Scan(&id); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, name) })
	base := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	read := func(at time.Time, marker bool, sessions ...string) {
		t.Helper()
		var rows []map[string]any
		for _, s := range sessions {
			rows = append(rows, map[string]any{"kind": "foreign_session", "name": s, "running": s != "DBADash_AdHoc", "targets": []string{"ring_buffer"}})
		}
		if marker {
			rows = append(rows, map[string]any{"kind": "sessions_read", "count": len(sessions)})
		}
		b, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_xe($1, $2, $3::jsonb)`, id, at, string(b)); err != nil {
			t.Fatal(err)
		}
	}
	list := func() (names string, readAt time.Time, count int) {
		t.Helper()
		if err := pool.QueryRow(ctx, `SELECT coalesce((SELECT string_agg(name || ':' || running, ',' ORDER BY name) FROM pgvigil.mssql_xe_foreign WHERE instance_id = $1), ''),
		    r.read_at, r.sessions FROM pgvigil.mssql_xe_foreign_read r WHERE r.instance_id = $1`, id).Scan(&names, &readAt, &count); err != nil {
			t.Fatal(err)
		}
		return names, readAt, count
	}
	check := func(step string, wantNames string, wantAt time.Time, wantCount int) {
		t.Helper()
		if n, at, c := list(); n != wantNames || !at.Equal(wantAt) || c != wantCount {
			t.Fatalf("%s: %q read %v count %d; want %q read %v count %d", step, n, at, c, wantNames, wantAt, wantCount)
		}
	}
	read(base, true, "DBADash_SlowQueries", "DBADash_AdHoc", "system_health")
	check("the first read", "DBADash_AdHoc:false,DBADash_SlowQueries:true", base, 2)
	read(base.Add(time.Minute), true, "DBADash_1")
	check("a newer read", "DBADash_1:true", base.Add(time.Minute), 1)
	read(base.Add(-time.Minute), true, "DBADash_1", "DBADash_2", "DBADash_Deadlocks")
	check("an older read arriving late", "DBADash_1:true", base.Add(time.Minute), 1)
	read(base.Add(2*time.Minute), false, "DBADash_2")
	check("a read without the marker", "DBADash_1:true", base.Add(time.Minute), 1)
	read(base.Add(3*time.Minute), true)
	check("a read that listed none", "", base.Add(3*time.Minute), 0)
}

// TestMoveListStates (task 206, W2 / P2): dbadash_move_list gives each server of a repository the state the test set up
// for it, written down here first: one row per server (two InstanceIDs of one @@SERVERNAME are one row with both ids),
// a server DBA Dash no longer lists not at all.
func TestMoveListStates(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo := fmt.Sprintf("r206k-%d", sfx)
	srv := func(s string) string { return fmt.Sprintf("%s%d", s, sfx) }
	want := map[string]string{
		srv("NOTYET"): "not yet", srv("IMPONLY"): "imported only", srv("COLL"): "collected by pgvigil", srv("MOVING"): "moving",
		srv("COLLECTING"): "collecting", srv("READY"): "ready to switch", srv("PARTIAL"): "partial", srv("TWICE"): "moving",
		srv("DISABLED"): "disabled",
	}
	ids := map[string][]int{}
	n := 100
	for s := range want {
		k := []int{n}
		if s == srv("TWICE") {
			k = append(k, n+1)
		}
		moveRepo(ctx, t, pool, repo, s, k...)
		ids[s] = k
		n += 10
	}
	moveRepo(ctx, t, pool, repo, srv("GONE"), 999)
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.dbadash_instances SET is_present = false WHERE repository = $1 AND instance_id = 999`, repo); err != nil {
		t.Fatal(err)
	}
	ensure := func(name string) int {
		t.Helper()
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', NULL, NULL, false, '{}'::text[], 'sqlserver')`, name).Scan(&id); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { dropInstance(pool, name) })
		return id
	}
	// imported only: an instance under the display name, never read; collected: one read under the @@SERVERNAME
	ensure(srv("IMPONLY"))
	firstRead(ctx, t, pool, ensure(fmt.Sprintf("coll-%d", sfx)), time.Now(), srv("COLL"))
	mv := func(s string) int {
		return moved(ctx, t, pool, repo, s, strings.ToLower(s), "host-"+strings.ToLower(s), ids[s]...)
	}
	mv(srv("MOVING"))
	mv(srv("TWICE"))
	for _, s := range []string{srv("COLLECTING"), srv("READY"), srv("PARTIAL"), srv("DISABLED")} {
		firstRead(ctx, t, pool, mv(s), time.Now().UTC(), s)
	}
	for s, outcome := range map[string]string{srv("READY"): "ok", srv("PARTIAL"): "partial"} {
		name := strings.ToLower(s)
		run := moveCall(ctx, t, pool, map[string]any{"op": "run", "ui_user": "t206", "name": name})
		if end := moveCall(ctx, t, pool, map[string]any{"op": "ended", "ui_user": "t206", "name": name, "run_id": run["run_id"], "outcome": outcome}); end["outcome"] != "done" {
			t.Fatalf("%s: ended %v", s, end)
		}
	}
	b, _ := json.Marshal(map[string]any{"op": "disable", "ui_user": "t206", "name": strings.ToLower(srv("DISABLED"))})
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_admin_instance(now(), $1::jsonb)`, string(b)); err != nil {
		t.Fatal(err)
	}
	rows, err := pool.Query(ctx, `SELECT server, state, dbadash_ids FROM pgvigil.dbadash_move_list($1)`, repo)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for rows.Next() {
		var s, state string
		var k []int32
		if err := rows.Scan(&s, &state, &k); err != nil {
			t.Fatal(err)
		}
		got[s] = state
		if len(k) != len(ids[s]) {
			t.Errorf("%s: InstanceIDs %v, want %v", s, k, ids[s])
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(got) != len(want) {
		t.Errorf("rows %d, want %d (one per present server; %s not listed)", len(got), len(want), srv("GONE"))
	}
	for s, w := range want {
		if got[s] != w {
			t.Errorf("%s: state %q, want %q", s, got[s], w)
		}
	}
}
