package repo

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
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
func moveRepo(t *testing.T, ctx context.Context, pool *pgxpool.Pool, repo, server string, ids ...int) {
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
func moveCall(t *testing.T, ctx context.Context, pool *pgxpool.Pool, pay map[string]any) map[string]any {
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

func moveAdd(repo, server, name, host string, ids ...int) map[string]any {
	conns := []string{}
	for _, id := range ids {
		conns = append(conns, fmt.Sprintf("%s-conn%d", strings.ToLower(server), id))
	}
	return map[string]any{"op": "add", "ui_user": "t206", "client": "test", "repository": repo, "server": server, "dbadash_ids": ids,
		"connection_ids": conns, "name": name, "platform": "", "dsn_ref": "file:/nonexistent/t206", "auth": "sql", "host": host, "port": "",
		"tags": []string{}}
}

// moved adds a moved server and returns its instance_id; the instance and its move go at the test's end.
func moved(t *testing.T, ctx context.Context, pool *pgxpool.Pool, repo, server, name, host string, ids ...int) int {
	t.Helper()
	ans := moveCall(t, ctx, pool, moveAdd(repo, server, name, host, ids...))
	if ans["outcome"] != "done" {
		t.Fatalf("the move of %s: %v", server, ans)
	}
	var id int
	if err := pool.QueryRow(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name = $1`, name).Scan(&id); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, name) })
	return id
}

func dropInstance(pool *pgxpool.Pool, name string) {
	ctx := context.Background()
	_, _ = pool.Exec(ctx, `DELETE FROM pgvigil.admin_instances WHERE name = $1`, name)
	_, _ = pool.Exec(ctx, `DELETE FROM pgvigil.admin_removed WHERE name = $1`, name)
	_, _ = pool.Exec(ctx, `DELETE FROM pgvigil.instances WHERE name = $1`, name)
}

// firstRead writes the collector's mssql_instance row (insert, then update).
func firstRead(t *testing.T, ctx context.Context, pool *pgxpool.Pool, id int, at time.Time, server string) {
	t.Helper()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_instance (instance_id, snapshot_at, server_name) VALUES ($1, $2, $3)
	    ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, server_name = EXCLUDED.server_name`, id, at, server); err != nil {
		t.Fatal(err)
	}
}

func collectFrom(t *testing.T, ctx context.Context, pool *pgxpool.Pool, id int) *time.Time {
	t.Helper()
	var at *time.Time
	if err := pool.QueryRow(ctx, `SELECT collect_from FROM pgvigil.dbadash_moves WHERE instance_id = $1`, id).Scan(&at); err != nil {
		t.Fatal(err)
	}
	return at
}

func collected(t *testing.T, ctx context.Context, pool *pgxpool.Pool, id int, collection, status string, at time.Time) {
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

func stored(t *testing.T, ctx context.Context, pool *pgxpool.Pool, id int, key string) int64 {
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
	moveRepo(t, ctx, pool, repo, srv, 7)
	id := moved(t, ctx, pool, repo, srv, fmt.Sprintf("mva-%d", sfx), fmt.Sprintf("hosta-%d", sfx), 7)
	if at := collectFrom(t, ctx, pool, id); at != nil {
		t.Fatalf("collect_from after the add = %v, want NULL", *at)
	}
	if _, err := importRows(ctx, pool, "volumes", id, volRows(time.Now().Add(-time.Hour))); !refusedWith(err, "collect it first") {
		t.Fatalf("an import before the first read: %v, want refused 'collect it first'", err)
	}
	t1 := time.Now().UTC().Truncate(time.Millisecond)
	firstRead(t, ctx, pool, id, t1, srv)
	if at := collectFrom(t, ctx, pool, id); at == nil || !at.Equal(t1) {
		t.Fatalf("collect_from after the first read = %v, want %v", at, t1)
	}
	firstRead(t, ctx, pool, id, t1.Add(5*time.Minute), srv)
	if at := collectFrom(t, ctx, pool, id); at == nil || !at.Equal(t1) {
		t.Fatalf("collect_from after a later read = %v, want %v kept", at, t1)
	}

	// a server collected before (its mssql_instance row kept), removed, then moved under its old name
	srv2, old := fmt.Sprintf("SRVB%d", sfx), fmt.Sprintf("old-%d", sfx)
	moveRepo(t, ctx, pool, repo, srv2, 8)
	var oid int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0.4295.3', 160000, false, '{}'::text[], 'sqlserver')`, old).Scan(&oid); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, old) })
	firstRead(t, ctx, pool, oid, t1.Add(-48*time.Hour), srv2)
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.instances SET is_active = false WHERE instance_id = $1`, oid); err != nil {
		t.Fatal(err)
	}
	if ans := moveCall(t, ctx, pool, moveAdd(repo, srv2, old, fmt.Sprintf("hostb-%d", sfx), 8)); ans["outcome"] != "done" {
		t.Fatalf("the move of a server collected before and removed: %v", ans)
	}
	if at := collectFrom(t, ctx, pool, oid); at != nil {
		t.Fatalf("collect_from of the re-moved server before its next read = %v, want NULL", *at)
	}
	t2 := t1.Add(time.Minute)
	firstRead(t, ctx, pool, oid, t2, srv2)
	if at := collectFrom(t, ctx, pool, oid); at == nil || !at.Equal(t2) {
		t.Fatalf("collect_from of the re-moved server after its next read = %v, want %v", at, t2)
	}
}

func TestMoveBounds(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo, srv := fmt.Sprintf("r206b-%d", sfx), fmt.Sprintf("SRVC%d", sfx)
	moveRepo(t, ctx, pool, repo, srv, 3)
	id := moved(t, ctx, pool, repo, srv, fmt.Sprintf("mvb-%d", sfx), fmt.Sprintf("hostc-%d", sfx), 3)
	c := time.Now().UTC().Add(-time.Hour).Truncate(time.Second)
	firstRead(t, ctx, pool, id, c, srv)

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
	collected(t, ctx, pool, id, "mssql_cpu", "ok", c.Add(-time.Second))
	if _, err = importRows(ctx, pool, "cpu", id, cpu); !refusedWith(err, "first CPU read") {
		t.Fatalf("cpu with the collector's CPU read before collect_from: %v, want refused", err)
	}
	collected(t, ctx, pool, id, "mssql_cpu", "ok", c.Add(time.Minute))
	if n, err = importRows(ctx, pool, "cpu", id, cpu); err != nil || n != 2 {
		t.Fatalf("cpu after the collector's CPU read: inserted %d (%v), want 2", n, err)
	}

	jobs := []map[string]any{jobRow(c.Add(-time.Hour), 101, c.Add(-time.Hour-8*time.Hour)), jobRow(c.Add(time.Hour), 102, c.Add(-7*time.Hour))}
	collected(t, ctx, pool, id, "mssql_jobs", "error", c.Add(time.Minute))
	if _, err = importRows(ctx, pool, "jobruns", id, jobs); !refusedWith(err, "first Agent job read") {
		t.Fatalf("jobruns while the job read failed: %v, want refused 'first Agent job read'", err)
	}
	collected(t, ctx, pool, id, "mssql_jobs", "skipped", c.Add(time.Minute))
	if n, err = importRows(ctx, pool, "jobruns", id, jobs); err != nil || n != 1 {
		t.Fatalf("jobruns after a skipped job read: inserted %d (%v), want 1 (the one before collect_from)", n, err)
	}
	if n, err = importRows(ctx, pool, "dbsize", id, []map[string]any{{"at": c.Add(-time.Hour).Format(time.RFC3339), "database_name": "db1",
		"data_bytes": 8192, "log_bytes": 8192, "data_used_bytes": nil, "log_used_bytes": nil, "files": 2}}); err != nil || n != 1 {
		t.Fatalf("dbsize: inserted %d (%v), want 1", n, err)
	}
	for key, want := range map[string]int64{"volumes": 2, "cpu": 2, "jobruns": 1, "dbsize": 1} {
		if got := stored(t, ctx, pool, id, key); got != want {
			t.Errorf("%s stored %d, want %d", key, got, want)
		}
	}
}

func TestMoveJobRunDST(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo, srv := fmt.Sprintf("r206d-%d", sfx), fmt.Sprintf("SRVD%d", sfx)
	moveRepo(t, ctx, pool, repo, srv, 4)
	id := moved(t, ctx, pool, repo, srv, fmt.Sprintf("mvd-%d", sfx), fmt.Sprintf("hostd-%d", sfx), 4)
	c := time.Now().UTC().Add(-time.Hour).Truncate(time.Second)
	firstRead(t, ctx, pool, id, c, srv)
	// the run: 10:00 PDT (17:00 UTC) on 2026-10-30, read by the collector with msdb's own date and time
	run := time.Date(2026, 10, 30, 17, 0, 0, 0, time.UTC)
	pay, _ := json.Marshal([]map[string]any{{"kind": "run", "run_utc": run.Format(time.RFC3339), "history_id": 4242, "job_id": "1D3C5E7A-0000-4000-8000-00000000ABCD",
		"job_name": "nightly", "step_id": 0, "step_name": "(Job outcome)", "run_date": 20261030, "run_time": 100000, "run_status": 1, "duration_s": 3,
		"sql_message_id": 0, "sql_severity": 0, "retries": 0, "message": "The job succeeded."}})
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_jobs($1, $2, $3::jsonb)`, id, c.Add(time.Minute), string(pay)); err != nil {
		t.Fatal(err)
	}
	collected(t, ctx, pool, id, "mssql_jobs", "ok", c.Add(time.Minute))
	// DBA Dash's row of that run after the change to PST: the same UTC start, its local time rebuilt an hour off (09:00);
	// and the same row with its UTC start an hour off too (within the key's 3 hours)
	for _, at := range []time.Time{run, run.Add(time.Hour)} {
		n, err := importRows(ctx, pool, "jobruns", id, []map[string]any{jobRow(at, 4242, time.Date(2026, 10, 30, 9, 0, 0, 0, time.UTC))})
		if err != nil || n != 0 {
			t.Fatalf("the DST row at %v: inserted %d (%v), want 0", at, n, err)
		}
	}
	if got := stored(t, ctx, pool, id, "jobruns"); got != 1 {
		t.Fatalf("job outcomes stored %d, want 1", got)
	}
}

func TestMoveConcurrentImport(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo, srv := fmt.Sprintf("r206e-%d", sfx), fmt.Sprintf("SRVE%d", sfx)
	moveRepo(t, ctx, pool, repo, srv, 5)
	mid := moved(t, ctx, pool, repo, srv, fmt.Sprintf("mve-%d", sfx), fmt.Sprintf("hoste-%d", sfx), 5)
	c := time.Now().UTC().Truncate(time.Second)
	firstRead(t, ctx, pool, mid, c, srv)
	plain := fmt.Sprintf("plain-%d", sfx)
	var pid int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', NULL, NULL, false, '{}'::text[], 'sqlserver')`, plain).Scan(&pid); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, plain) })
	var at []time.Time
	for i := 0; i < 500; i++ {
		at = append(at, c.Add(-time.Duration(i+1)*time.Minute))
	}
	rows := volRows(at...)
	for _, id := range []int{mid, pid} {
		var wg sync.WaitGroup
		got := make([]int64, 2)
		errs := make([]error, 2)
		for k := range 2 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				got[k], errs[k] = importRows(ctx, pool, "volumes", id, rows)
			}()
		}
		wg.Wait()
		if errs[0] != nil || errs[1] != nil {
			t.Fatalf("instance %d: %v / %v", id, errs[0], errs[1])
		}
		if got[0]+got[1] != 500 || stored(t, ctx, pool, id, "volumes") != 500 {
			t.Fatalf("instance %d: two imports at once inserted %d + %d, stored %d; want 500 in all", id, got[0], got[1], stored(t, ctx, pool, id, "volumes"))
		}
	}
}

func TestMoveAddRefusals(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	repo := fmt.Sprintf("r206f-%d", sfx)
	audits := func(target string) (refused int) {
		t.Helper()
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE target = $1 AND outcome = 'refused'`, target).Scan(&refused); err != nil {
			t.Fatal(err)
		}
		return refused
	}
	noMove := func(server string) {
		t.Helper()
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.dbadash_moves WHERE repository = $1 AND server = $2`, repo, server).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Fatalf("%s: %d move row(s) after a refused add, want 0", server, n)
		}
	}
	refuse := func(pay map[string]any, words, target string) {
		t.Helper()
		before := audits(target)
		ans := moveCall(t, ctx, pool, pay)
		if ans["outcome"] != "refused" || !strings.Contains(fmt.Sprint(ans["detail"]), words) {
			t.Fatalf("%s: %v, want refused '%s'", pay["server"], ans, words)
		}
		if audits(target) != before+1 {
			t.Fatalf("%s: no refused audit row for %s", pay["server"], target)
		}
		noMove(pay["server"].(string))
	}

	// collected already: an active instance read under the server's @@SERVERNAME
	sa := fmt.Sprintf("SRVF%d", sfx)
	moveRepo(t, ctx, pool, repo, sa, 11)
	have := fmt.Sprintf("have-%d", sfx)
	var hid int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0.1', 160000, false, '{}'::text[], 'sqlserver')`, have).Scan(&hid); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, have) })
	firstRead(t, ctx, pool, hid, time.Now(), strings.ToLower(sa))
	pa := moveAdd(repo, sa, fmt.Sprintf("mvfa-%d", sfx), fmt.Sprintf("hostfa-%d", sfx), 11)
	refuse(pa, "collects "+sa+" already, as "+have, pa["name"].(string))

	// its host and port on Admin > Instances already
	sb := fmt.Sprintf("SRVG%d", sfx)
	moveRepo(t, ctx, pool, repo, sb, 12)
	page, host := fmt.Sprintf("page-%d", sfx), fmt.Sprintf("hostg-%d", sfx)
	b, _ := json.Marshal(map[string]any{"op": "add", "ui_user": "t206", "name": page, "engine": "sqlserver", "dsn_ref": "file:/nonexistent/p", "auth": "sql",
		"host": host, "port": "1433"})
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_admin_instance(now(), $1::jsonb)`, string(b)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropInstance(pool, page) })
	pb := moveAdd(repo, sb, fmt.Sprintf("mvfb-%d", sfx), strings.ToUpper(host), 12)
	refuse(pb, "Admin > Instances has", pb["name"].(string))

	// approved already from a DBA Dash source of this repository
	sc := fmt.Sprintf("SRVH%d", sfx)
	moveRepo(t, ctx, pool, repo, sc, 13, 14)
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
	refuse(pc, "approved already from the source "+src+" as other", pc["name"].(string))

	// the name taken (import_admin_instance's refusal)
	sd := fmt.Sprintf("SRVI%d", sfx)
	moveRepo(t, ctx, pool, repo, sd, 15)
	pd := moveAdd(repo, sd, page, fmt.Sprintf("hostfd-%d", sfx), 15)
	refuse(pd, "exists already", page)

	// a proposed one of this repository is approved by the add, under the instance's name
	se := fmt.Sprintf("SRVJ%d", sfx)
	moveRepo(t, ctx, pool, repo, se, 16)
	conn := strings.ToLower(se) + "-conn16"
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.admin_proposals (source, server, engine, host) VALUES ($1, $2, 'sqlserver', $2)`, src, conn); err != nil {
		t.Fatal(err)
	}
	name := fmt.Sprintf("mvfe-%d", sfx)
	id := moved(t, ctx, pool, repo, se, name, fmt.Sprintf("hostfe-%d", sfx), 16)
	var state, inst string
	if err := pool.QueryRow(ctx, `SELECT state, coalesce(instance_name, '') FROM pgvigil.admin_proposals WHERE source = $1 AND server = $2`, src, conn).Scan(&state, &inst); err != nil {
		t.Fatal(err)
	}
	if state != "approved" || inst != name {
		t.Fatalf("the proposal after the add: %s as %q, want approved as %s", state, inst, name)
	}

	// a remove of the moved server never read takes its move rows with it
	b, _ = json.Marshal(map[string]any{"op": "remove", "ui_user": "t206", "name": name})
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_admin_instance(now(), $1::jsonb)`, string(b)); err != nil {
		t.Fatal(err)
	}
	var moves, ids int
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM pgvigil.dbadash_moves WHERE instance_id = $1), (SELECT count(*) FROM pgvigil.dbadash_move_ids WHERE instance_id = $1)`, id).Scan(&moves, &ids); err != nil {
		t.Fatal(err)
	}
	if moves != 0 || ids != 0 {
		t.Fatalf("after the remove: %d move row(s), %d id row(s); want 0 and 0", moves, ids)
	}
}

func TestMoveCollectorLogin(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	coll, rdr := fmt.Sprintf("t206c_%d", sfx), fmt.Sprintf("t206r_%d", sfx)
	for role, member := range map[string]string{coll: "pgvigil_collector", rdr: "pgvigil_reader"} {
		if _, err := pool.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s NOLOGIN IN ROLE %s`, role, member)); err != nil {
			t.Fatal(err)
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
	_, err = importRows(ctx, conn, "cpu", tgt.ID, cpuRows(at.Add(-time.Hour)))
	var pe *pgconn.PgError
	if !errors.As(err, &pe) || pe.Code != "42501" {
		t.Fatalf("import_dbadash_cpu as a reader member: %v, want permission denied (42501)", err)
	}
}
