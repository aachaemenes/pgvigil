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

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0200's request queue (CQ):
//   - with no live worker an ask is refused 'no collector takes requests (cq.enabled ...)'; a worker that does not hold
//     the instance names the instance; a held instance with no door says 'not through the queue yet'; a shut door gives
//     the collector's own words and its host; a shut door of one tool (ST4's allow-list) refuses that tool alone;
//   - a forged ask is refused before any worker sees it: an unknown kind (no row), an argument the kind does not take,
//     a missing one, a session id given as a string or out of 1..32767, a short reason, a bad plan handle, a timeout
//     over the kind's cap;
//   - an accepted ask notifies pgvigil_request with its id only, at commit; a refused one notifies nobody;
//   - a worker claims only the instances it holds and only (instance, kind) pairs whose door is open on IT; the urgent
//     kinds take the reserved slot; remaining_ms is the repository's expires_at - now();
//   - a waiting request past its expiry is 'expired' and never claimed; a running one whose lease lapsed is 'lost', and
//     its late finish is refused (false); a clean stop ends the lease at once;
//   - cancel: another user is refused, a waiting request is 'cancelled' at once, a running one is asked and the holder's
//     beat returns its id;
//   - the result is the asker's alone (another user: 'this run was asked by another user'); a 'read' keep is cleared
//     at the sweep after it was read;
//   - 10 open requests per ui_user and per login; collect_now not again within 30 s;
//   - the rights: a reader cannot read ui_action_data, call import_action_request or import_action_claim (42501), and
//     reads action_requests (no payload there); a requester calls import_action_request and import_action_cancel and
//     not import_action_claim; an auth member calls ui_action_result.
func TestActionRequestsOnAStore(t *testing.T) {
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
	t.Cleanup(pool.Close)
	sfx := time.Now().UnixNano() % 1000000000
	i1, i2 := fmt.Sprintf("cq-a-%d", sfx), fmt.Sprintf("cq-b-%d", sfx)
	w1, w2 := fmt.Sprintf("cq-w1-%d", sfx), fmt.Sprintf("cq-w2-%d", sfx)
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 20*time.Second)
		defer stop()
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.action_requests WHERE instance = ANY($1)`, []string{i1, i2})
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.cq_workers WHERE collector_id = ANY($1)`, []string{w1, w2})
	})
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
	}
	type answer struct {
		Outcome   string `json:"outcome"`
		Detail    string `json:"detail"`
		RequestID int64  `json:"request_id"`
	}
	ask := func(kind, inst, user string, args string) answer {
		t.Helper()
		var raw []byte
		body := fmt.Sprintf(`{"kind": %q, "instance": %q, "ui_user": %q, "client": "test", "args": %s}`, kind, inst, user, args)
		if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_request($1::jsonb)::text`, body).Scan(&raw); err != nil {
			t.Fatalf("import_action_request %s: %v", body, err)
		}
		var a answer
		if err := json.Unmarshal(raw, &a); err != nil {
			t.Fatal(err)
		}
		return a
	}
	refused := func(a answer, want string) {
		t.Helper()
		if a.Outcome != "refused" || !strings.Contains(a.Detail, want) {
			t.Fatalf("want refused with %q, got %+v", want, a)
		}
	}
	beat := func(w string, insts ...string) []int64 {
		t.Helper()
		rows, err := pool.Query(ctx, `SELECT * FROM pgvigil.import_cq_beat($1, $2, $3)`, w, "host-"+w, insts)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var ids []int64
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				t.Fatal(err)
			}
			ids = append(ids, id)
		}
		return ids
	}
	doors := func(w, js string) {
		t.Helper()
		exec(`SELECT pgvigil.import_cq_doors($1, $2::jsonb)`, w, js)
	}
	type claimed struct {
		ID          int64
		Kind        string
		RemainingMS int64
	}
	claim := func(w string, free, urgent int) []claimed {
		t.Helper()
		rows, err := pool.Query(ctx, `SELECT request_id, kind, remaining_ms FROM pgvigil.import_action_claim($1, $2, $3, '{}'::jsonb)`, w, free, urgent)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var out []claimed
		for rows.Next() {
			var c claimed
			if err := rows.Scan(&c.ID, &c.Kind, &c.RemainingMS); err != nil {
				t.Fatal(err)
			}
			out = append(out, c)
		}
		return out
	}
	state := func(id int64) string {
		t.Helper()
		var s string
		if err := pool.QueryRow(ctx, `SELECT state FROM pgvigil.action_requests WHERE request_id = $1`, id).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	result := func(id int64, user string) map[string]any {
		t.Helper()
		var raw []byte
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ui_action_result($1, $2)::text`, id, user).Scan(&raw); err != nil {
			t.Fatal(err)
		}
		m := map[string]any{}
		if err := json.Unmarshal(raw, &m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	run := `{"tool": "sp_WhoIsActive"}`

	// no worker, then a worker of another instance, then a held instance without a door
	refused(ask("community_run", i1, "Alice", run), "no collector takes requests (cq.enabled")
	beat(w1, i2)
	refused(ask("community_run", i1, "alice", run), "no collector takes requests for "+i1)
	beat(w1, i1, i2)
	refused(ask("community_run", i1, "alice", run), "is not through the queue yet on "+i1)
	doors(w1, fmt.Sprintf(`[{"instance": %q, "kind": "community_run", "open": true},
		{"instance": %q, "kind": "community_run", "name": "sp_Blitz", "open": false, "why": "sp_Blitz is not in community_allow for this instance"},
		{"instance": %q, "kind": "mssql_kill", "open": false, "why": "kill is off: the instance has no actions_dsn"},
		{"instance": %q, "kind": "pg_terminate", "open": true}, {"instance": %q, "kind": "collect_now", "open": true}]`, i1, i1, i1, i1, i1))
	refused(ask("mssql_kill", i1, "alice", `{"session_id": 77, "login_time": "2026-11-14T10:00:00Z", "login": "CORP\\rpt", "reason": "runaway report"}`),
		"kill is off: the instance has no actions_dsn (the collector on host-"+w1+")")
	refused(ask("community_run", i1, "alice", `{"tool": "sp_Blitz"}`), "sp_Blitz is not in community_allow")

	// forged asks
	var before int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.action_requests WHERE instance = $1`, i1).Scan(&before); err != nil {
		t.Fatal(err)
	}
	refused(ask("drop_database", i1, "alice", `{}`), "the queue knows no kind drop_database")
	var after int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.action_requests WHERE instance = $1`, i1).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if after != before {
		t.Fatalf("an unknown kind left a row: %d -> %d", before, after)
	}
	refused(ask("community_run", i1, "alice", `{"tool": "sp_WhoIsActive", "sql": "DROP TABLE t"}`), "community_run takes no argument sql")
	refused(ask("pg_terminate", i1, "alice", `{"pid": 4242, "reason": "stuck vacuum"}`), "pg_terminate needs backend_start")
	refused(ask("mssql_kill", i1, "alice", `{"session_id": "77", "login_time": "2026-11-14T10:00:00Z", "login": "rpt", "reason": "runaway report"}`), "session_id is not a whole number")
	refused(ask("mssql_kill", i1, "alice", `{"session_id": 0, "login_time": "2026-11-14T10:00:00Z", "login": "rpt", "reason": "runaway report"}`), "the session id is 1 to 32767")
	refused(ask("pg_terminate", i1, "alice", `{"pid": 4242, "backend_start": "2026-11-14T10:00:00Z", "reason": "x"}`), "the reason is 5 to 500 characters")
	refused(ask("mssql_plan_evict", i1, "alice", `{"plan_handle": "0x0G", "confirm": "abc", "reason": "a bad plan for days"}`), "is not a hex handle")
	refused(ask("community_run", i1, "alice", `{"tool": "sp_WhoIsActive", "timeout_secs": 61}`), "timeout_secs is 1 to 60")

	// an accepted ask notifies its id at commit; a refused one notifies nobody
	lc, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lc.Exec(ctx, `LISTEN pgvigil_request`); err != nil {
		t.Fatal(err)
	}
	refused(ask("community_run", i1, "alice", `{"tool": "sp_Blitz"}`), "sp_Blitz")
	a1 := ask("community_run", i1, "Alice", run)
	if a1.Outcome != "waiting" || a1.RequestID == 0 {
		t.Fatalf("an open door's ask: %+v", a1)
	}
	nctx, nstop := context.WithTimeout(ctx, 3*time.Second)
	n, err := lc.Conn().WaitForNotification(nctx)
	nstop()
	if err != nil {
		t.Fatalf("no notify for request %d: %v", a1.RequestID, err)
	}
	if n.Channel != "pgvigil_request" || n.Payload != fmt.Sprint(a1.RequestID) {
		t.Fatalf("notify %s %q, want pgvigil_request %d (the refused ask must not notify, and the payload is the id only)", n.Channel, n.Payload, a1.RequestID)
	}
	_, _ = lc.Exec(ctx, `UNLISTEN *`)
	lc.Release()

	// the claim: a worker that holds the instance with its door shut takes nothing; the urgent slot; remaining_ms
	beat(w2, i1)
	doors(w2, fmt.Sprintf(`[{"instance": %q, "kind": "community_run", "open": false, "why": "community tools are off on this collector"}]`, i1))
	if got := claim(w2, 4, 1); len(got) != 0 {
		t.Fatalf("a worker whose door is shut claimed %+v", got)
	}
	t1 := ask("pg_terminate", i1, "bob", `{"pid": 4242, "backend_start": "2026-11-14T10:00:00Z", "reason": "stuck vacuum holds xmin"}`)
	if t1.Outcome != "waiting" {
		t.Fatalf("pg_terminate: %+v", t1)
	}
	got := claim(w1, 0, 1)
	if len(got) != 1 || got[0].ID != t1.RequestID || got[0].Kind != "pg_terminate" {
		t.Fatalf("the urgent slot with no free slot: %+v, want only %d", got, t1.RequestID)
	}
	if got[0].RemainingMS <= 0 || got[0].RemainingMS > 30000 {
		t.Fatalf("remaining_ms %d, want 1..30000 (an action lives 30 s)", got[0].RemainingMS)
	}
	// the worker's per-instance room: none left on i1 holds the community run back (an urgent kind would skip it)
	if rows, err := pool.Query(ctx, `SELECT request_id FROM pgvigil.import_action_claim($1, 4, 1, $2::jsonb)`, w1, fmt.Sprintf(`{%q: 0}`, i1)); err != nil {
		t.Fatal(err)
	} else {
		n := 0
		for rows.Next() {
			n++
		}
		rows.Close()
		if n != 0 {
			t.Fatalf("a claim with no room on %s took %d request(s)", i1, n)
		}
	}
	got = claim(w1, 4, 1)
	if len(got) != 1 || got[0].ID != a1.RequestID || got[0].RemainingMS > 90000 || got[0].RemainingMS < 80000 {
		t.Fatalf("the community run: %+v, want %d with about 90 s left (60 s timeout + 30 s)", got, a1.RequestID)
	}
	if s := state(a1.RequestID); s != "running" {
		t.Fatalf("claimed request is %s", s)
	}

	// cancel: another user refused; running -> asked, and the holder's beat returns it; waiting -> cancelled at once
	var raw []byte
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_cancel($1, 'bob')::text`, a1.RequestID).Scan(&raw); err != nil || !strings.Contains(string(raw), "asked by another user") {
		t.Fatalf("bob's cancel of alice's run: %s %v", raw, err)
	}
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_cancel($1, 'ALICE')::text`, a1.RequestID).Scan(&raw); err != nil || !strings.Contains(string(raw), `"asked"`) {
		t.Fatalf("alice's cancel of her running run: %s %v", raw, err)
	}
	if ids := beat(w1, i1, i2); len(ids) != 1 || ids[0] != a1.RequestID {
		t.Fatalf("the holder's beat returned %v, want [%d] (the cancel seen without LISTEN)", ids, a1.RequestID)
	}
	w := ask("community_run", i1, "alice", run)
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_cancel($1, 'alice')::text`, w.RequestID).Scan(&raw); err != nil || !strings.Contains(string(raw), `"cancelled"`) {
		t.Fatalf("a waiting cancel: %s %v", raw, err)
	}
	if s := state(w.RequestID); s != "cancelled" {
		t.Fatalf("a waiting cancel left %s", s)
	}

	// finish, the asker's read, another user's refusal, the read keep cleared at the sweep
	var ok bool
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_finish($1, $2, $3::jsonb)`, w1, a1.RequestID,
		`{"state": "done", "outcome": "1 set, 2 rows", "rows": 2, "duration_ms": 140, "keep": "read", "result": {"sets": [{"columns": ["session_id"], "rows": [[61], [62]]}]}}`).Scan(&ok); err != nil || !ok {
		t.Fatalf("finish: %v %v", ok, err)
	}
	if m := result(a1.RequestID, "bob"); m["refused"] != "this run was asked by another user" || m["result"] != nil {
		t.Fatalf("bob read alice's result: %v", m)
	}
	m := result(a1.RequestID, "alice")
	if m["state"] != "done" || m["result"] == nil || m["taken_host"] != "host-"+w1 {
		t.Fatalf("alice's read: %v", m)
	}
	exec(`SELECT pgvigil.import_action_sweep()`)
	if m := result(a1.RequestID, "alice"); m["result"] != nil || m["cleared"] != true {
		t.Fatalf("a read result after the sweep: %v (want cleared)", m)
	}

	// expiry and the lost lease, on the repository clock
	e := ask("community_run", i1, "alice", run)
	exec(`UPDATE pgvigil.action_requests SET expires_at = clock_timestamp() - interval '1 second' WHERE request_id = $1`, e.RequestID)
	if got := claim(w1, 4, 1); len(got) != 0 {
		t.Fatalf("an expired request was claimed: %+v", got)
	}
	if s := state(e.RequestID); s != "expired" {
		t.Fatalf("past expiry: %s, want expired", s)
	}
	exec(`UPDATE pgvigil.action_requests SET lease_until = clock_timestamp() - interval '1 second' WHERE request_id = $1`, t1.RequestID)
	if m := result(t1.RequestID, "bob"); m["state"] != "lost" || !strings.Contains(fmt.Sprint(m["outcome"]), "may or may not have run") {
		t.Fatalf("a lapsed lease read by its asker: %v", m)
	}
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_finish($1, $2, '{"state": "done"}'::jsonb)`, w1, t1.RequestID).Scan(&ok); err != nil || ok {
		t.Fatalf("a lost run's late finish: %v %v, want false", ok, err)
	}

	// the caps: 10 open per ui_user, then per login; collect_now's 30 s
	exec(`UPDATE pgvigil.action_requests SET state = 'cancelled' WHERE state IN ('waiting', 'running')`)
	for k := 0; k < 10; k++ {
		if a := ask("community_run", i1, "carol", run); a.Outcome != "waiting" {
			t.Fatalf("carol's ask %d: %+v", k+1, a)
		}
	}
	refused(ask("community_run", i1, "carol", run), "carol already has 10 open requests")
	refused(ask("community_run", i1, "dave", run), "already has 10 open requests")
	exec(`UPDATE pgvigil.action_requests SET state = 'cancelled' WHERE state IN ('waiting', 'running')`)
	if a := ask("collect_now", i1, "carol", `{"collection": "activity"}`); a.Outcome != "waiting" {
		t.Fatalf("collect_now: %+v", a)
	}
	refused(ask("collect_now", i1, "dave", `{"collection": "*"}`), "was asked in the last 30 seconds")

	// the page lease as the worker reads it: a holder of another process is not this one's
	var held bool
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_cq_page_held($1)`, fmt.Sprintf("cq-nohost-%d:1:", sfx)).Scan(&held); err != nil || held {
		t.Fatalf("import_cq_page_held of a host that holds nothing: %v %v", held, err)
	}
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_cq_page_held('')`).Scan(&held); err != nil || held {
		t.Fatalf("import_cq_page_held of an empty prefix: %v %v", held, err)
	}

	// a clean stop ends the lease at once
	exec(`SELECT pgvigil.import_cq_stop($1)`, w1)
	exec(`SELECT pgvigil.import_cq_stop($1)`, w2)
	refused(ask("community_run", i1, "carol", run), "no collector takes requests")

	// the rights
	rdr, req, au := fmt.Sprintf("t200r_%d", sfx), fmt.Sprintf("t200q_%d", sfx), fmt.Sprintf("t200a_%d", sfx)
	for role, member := range map[string]string{rdr: "pgvigil_reader", req: "pgvigil_reader, pgvigil_requester", au: "pgvigil_auth"} {
		if _, err := pool.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s NOLOGIN IN ROLE %s`, role, member)); err != nil {
			t.Skipf("this store's login may not make roles (it needs CREATE ROLE and SET ROLE): %v", err)
		}
		t.Cleanup(func() { _, _ = pool.Exec(context.Background(), fmt.Sprintf(`DROP ROLE IF EXISTS %s`, role)) })
	}
	as := func(role, sql string, args ...any) error {
		t.Helper()
		conn, err := pool.Acquire(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Release()
		if _, err := conn.Exec(ctx, `SET ROLE `+role); err != nil {
			t.Fatal(err)
		}
		defer func() { _, _ = conn.Exec(context.Background(), `RESET ROLE`) }()
		_, err = conn.Exec(ctx, sql, args...)
		return err
	}
	denied := func(err error, what string) {
		t.Helper()
		var pe *pgconn.PgError
		if !errors.As(err, &pe) || pe.Code != "42501" {
			t.Fatalf("%s: want 42501, got %v", what, err)
		}
	}
	denied(as(rdr, `SELECT * FROM pgvigil.ui_action_data`), "the reader reads ui_action_data")
	denied(as(rdr, `SELECT pgvigil.import_action_request('{}'::jsonb)`), "the reader asks")
	denied(as(rdr, `SELECT * FROM pgvigil.import_action_claim('x', 1, 1, '{}'::jsonb)`), "the reader claims")
	denied(as(rdr, `SELECT pgvigil.ui_action_result(1, 'x')`), "the reader reads a result")
	if err := as(rdr, `SELECT request_id, state, outcome FROM pgvigil.action_requests LIMIT 1`); err != nil {
		t.Fatalf("the reader reads action_requests: %v", err)
	}
	if err := as(req, `SELECT pgvigil.import_action_request($1::jsonb)`, fmt.Sprintf(`{"kind": "community_run", "instance": %q, "ui_user": "erin", "args": %s}`, i1, run)); err != nil {
		t.Fatalf("the requester asks: %v", err)
	}
	if err := as(req, `SELECT pgvigil.import_action_cancel(1, 'erin')`); err != nil {
		t.Fatalf("the requester cancels: %v", err)
	}
	denied(as(req, `SELECT * FROM pgvigil.import_action_claim('x', 1, 1, '{}'::jsonb)`), "the requester claims")
	denied(as(req, `SELECT pgvigil.import_action_finish('x', 1, '{"state": "done"}'::jsonb)`), "the requester finishes")
	if err := as(au, `SELECT pgvigil.ui_action_result($1, 'alice')`, a1.RequestID); err != nil {
		t.Fatalf("the auth role reads a result: %v", err)
	}
}

// On a store whose purge() carries scripts/cq-wiring-a.patch (skipped otherwise): a read kind's ended row older than
// 7 days goes, a newer one stays, an action kind's row stays whatever its age, a waiting one stays; a worker silent
// for 8 days goes with its doors.
func TestActionRequestsPurgeOnAWiredStore(t *testing.T) {
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
	t.Cleanup(pool.Close)
	var wired bool
	if err := pool.QueryRow(ctx, `SELECT pg_get_functiondef('pgvigil.purge(int)'::regprocedure) LIKE '%pgvigil.action_requests%'`).Scan(&wired); err != nil {
		t.Fatal(err)
	}
	if !wired {
		t.Skip("purge() does not carry scripts/cq-wiring-a.patch on this store")
	}
	sfx := time.Now().UnixNano() % 1000000000
	inst, w := fmt.Sprintf("cq-p-%d", sfx), fmt.Sprintf("cq-pw-%d", sfx)
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.action_requests WHERE instance = $1`, inst)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.cq_workers WHERE collector_id = $1`, w)
	})
	ins := func(kind, class, state string, age string) int64 {
		t.Helper()
		var id int64
		if err := pool.QueryRow(ctx, `INSERT INTO pgvigil.action_requests (kind, class, instance, ui_user, asked_login, asked_at, expires_at, state)
			VALUES ($1, $2, $3, 'u', 'l', now() - $4::interval, now() - $4::interval + interval '1 minute', $5) RETURNING request_id`,
			kind, class, inst, age, state).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	oldRead, newRead := ins("community_run", "read", "done", "8 days"), ins("community_run", "read", "done", "6 days")
	oldAction, oldWait := ins("mssql_kill", "action", "done", "40 days"), ins("community_run", "read", "waiting", "8 days")
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.cq_workers (collector_id, host, instances, started_at, beat_at)
		VALUES ($1, 'h', '{}', now() - interval '9 days', now() - interval '9 days')`, w); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.purge(30)`); err != nil {
		t.Fatal(err)
	}
	for id, want := range map[int64]bool{oldRead: false, newRead: true, oldAction: true, oldWait: true} {
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.action_requests WHERE request_id = $1`, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if (n == 1) != want {
			t.Fatalf("request %d after purge: present %v, want %v", id, n == 1, want)
		}
	}
	var nw int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.cq_workers WHERE collector_id = $1`, w).Scan(&nw); err != nil || nw != 0 {
		t.Fatalf("a worker silent for 9 days after purge: %d row(s), %v", nw, err)
	}
}
