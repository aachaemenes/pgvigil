package repo

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
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
	ix, wx := fmt.Sprintf("cq-x-%d", sfx), fmt.Sprintf("cq-wx-%d", sfx) // a foreign worker: the store is shared
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 20*time.Second)
		defer stop()
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.action_requests WHERE instance = ANY($1)`, []string{i1, i2})
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.cq_workers WHERE collector_id = ANY($1)`, []string{w1, w2, wx})
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
	askOn := func(q interface {
		QueryRow(context.Context, string, ...any) pgx.Row
	}, kind, inst, user string, args string) answer {
		t.Helper()
		var raw []byte
		body := fmt.Sprintf(`{"kind": %q, "instance": %q, "ui_user": %q, "client": "test", "args": %s}`, kind, inst, user, args)
		if err := q.QueryRow(ctx, `SELECT pgvigil.import_action_request($1::jsonb)::text`, body).Scan(&raw); err != nil {
			t.Fatalf("import_action_request %s: %v", body, err)
		}
		var a answer
		if err := json.Unmarshal(raw, &a); err != nil {
			t.Fatal(err)
		}
		return a
	}
	ask := func(kind, inst, user string, args string) answer {
		t.Helper()
		return askOn(pool, kind, inst, user, args)
	}
	// askWithNoWorker asks on a store with no live worker, whatever else runs on it: G runs ./internal/cq and
	// ./internal/web beside this package on one store, and their workers beat cq_workers rows meanwhile. The state is
	// built in a transaction no other session sees - the table locked against writes (reads go on; a beat waits the
	// few milliseconds), every lease ended, the ask, rolled back - so nothing of it outlives the call.
	askWithNoWorker := func(kind, inst, user string, args string) answer {
		t.Helper()
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx.Rollback(ctx) }()
		for _, sql := range []string{`LOCK TABLE pgvigil.cq_workers IN EXCLUSIVE MODE`, `UPDATE pgvigil.cq_workers SET beat_at = NULL`} {
			if _, err := tx.Exec(ctx, sql); err != nil {
				t.Fatalf("%v\n%s", err, sql)
			}
		}
		return askOn(tx, kind, inst, user, args)
	}
	refused := func(a answer, want string) {
		t.Helper()
		if a.Outcome != "refused" || !strings.Contains(a.Detail, want) {
			t.Fatalf("want refused with %q, got %+v", want, a)
		}
	}
	// beat: the worker's lease, and the lease of the runs it still holds (running)
	beat := func(w string, running []int64, insts ...string) []int64 {
		t.Helper()
		rows, err := pool.Query(ctx, `SELECT * FROM pgvigil.import_cq_beat($1, $2, $3, $4)`, w, "host-"+w, insts, running)
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

	// no worker, then a worker of another instance, then a held instance without a door. A foreign live worker is
	// beaten first, as the packages G runs beside this one do: the plain ask would answer 'no collector takes requests
	// for <instance>' (r01's red), so the no-worker ask is built in its own transaction.
	beat(wx, nil, ix)
	refused(askWithNoWorker("community_run", i1, "Alice", run), "no collector takes requests (cq.enabled")
	beat(w1, nil, i2)
	refused(ask("community_run", i1, "alice", run), "no collector takes requests for "+i1)
	beat(w1, nil, i1, i2)
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
	// a refused payload's timeout never reaches a cast: a refused row, never 22P02 / 22003
	refused(ask("community_run", i1, "alice", `{"tool": "sp_WhoIsActive", "timeout_secs": "abc"}`), "timeout_secs is not a whole number")
	refused(ask("community_run", i1, "alice", `{"tool": "sp_WhoIsActive", "timeout_secs": 1.5}`), "timeout_secs is not a whole number")
	refused(ask("community_run", i1, "alice", `{"tool": "sp_WhoIsActive", "timeout_secs": 99999999999}`), "timeout_secs is 1 to 60")
	// 100,000 three-byte characters pass the 200,000-character rule and not ui_action_data's 256 KB: words, never 23514
	long, _ := json.Marshal(map[string]any{"tool": "glenn_berry", "text": strings.Repeat("\u20ac", 100000)})
	refused(ask("community_run", i1, "alice", string(long)), "the arguments are over 256 KB")

	// an accepted ask notifies its id at commit; a refused one notifies nobody
	lc, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(lc.Release) // before pool.Close's cleanup (a second Release is a no-op): a Fatal below never hangs the close
	if _, err := lc.Exec(ctx, `LISTEN pgvigil_request`); err != nil {
		t.Fatal(err)
	}
	refused(ask("community_run", i1, "alice", `{"tool": "sp_Blitz"}`), "sp_Blitz")
	a1 := ask("community_run", i1, "Alice", run)
	if a1.Outcome != "waiting" || a1.RequestID == 0 {
		t.Fatalf("an open door's ask: %+v", a1)
	}
	// the store is shared (G runs ./internal/cq and ./internal/web beside this package and their asks notify on this
	// channel too): a payload of another instance's request is skipped; a request of this test's instances before a1's
	// is the refused ask notifying; every payload is an id alone
	nctx, nstop := context.WithTimeout(ctx, 5*time.Second)
	for {
		n, err := lc.Conn().WaitForNotification(nctx)
		if err != nil {
			nstop()
			t.Fatalf("no notify for request %d: %v", a1.RequestID, err)
		}
		id, perr := strconv.ParseInt(n.Payload, 10, 64)
		if n.Channel != "pgvigil_request" || perr != nil {
			nstop()
			t.Fatalf("notify %s %q: want pgvigil_request with the id only", n.Channel, n.Payload)
		}
		if id == a1.RequestID {
			break
		}
		var mine bool
		if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pgvigil.action_requests WHERE request_id = $1 AND instance = ANY ($2))`, id, []string{i1, i2}).Scan(&mine); err != nil {
			nstop()
			t.Fatal(err)
		}
		if mine {
			nstop()
			t.Fatalf("notify %d, a request of this test's before %d's (the refused ask must not notify)", id, a1.RequestID)
		}
	}
	nstop()
	_, _ = lc.Exec(ctx, `UNLISTEN *`)
	lc.Release()

	// the claim: a worker that holds the instance with its door shut takes nothing; the urgent slot; remaining_ms
	beat(w2, nil, i1)
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
	// the run lease: a beat renews only the runs the worker names (still in its memory); a running row it lost track of
	// (its finish failed) keeps its old lease_until, so it lapses and the sweep says 'lost'
	lease := func(id int64) time.Time {
		t.Helper()
		var at time.Time
		if err := pool.QueryRow(ctx, `SELECT lease_until FROM pgvigil.action_requests WHERE request_id = $1`, id).Scan(&at); err != nil {
			t.Fatal(err)
		}
		return at
	}
	l0 := lease(a1.RequestID)
	time.Sleep(1100 * time.Millisecond)
	beat(w1, nil, i1, i2)
	if l := lease(a1.RequestID); !l.Equal(l0) {
		t.Fatalf("a beat that does not name request %d renewed its lease: %v -> %v", a1.RequestID, l0, l)
	}
	beat(w1, []int64{a1.RequestID}, i1, i2)
	if l := lease(a1.RequestID); !l.After(l0) {
		t.Fatalf("a beat naming request %d did not renew its lease: %v -> %v", a1.RequestID, l0, l)
	}

	// cancel: another user refused; running -> asked, and the holder's beat returns it; waiting -> cancelled at once
	var raw []byte
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_cancel($1, 'bob')::text`, a1.RequestID).Scan(&raw); err != nil || !strings.Contains(string(raw), "asked by another user") {
		t.Fatalf("bob's cancel of alice's run: %s %v", raw, err)
	}
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_cancel($1, 'ALICE')::text`, a1.RequestID).Scan(&raw); err != nil || !strings.Contains(string(raw), `"asked"`) {
		t.Fatalf("alice's cancel of her running run: %s %v", raw, err)
	}
	if ids := beat(w1, []int64{a1.RequestID}, i1, i2); len(ids) != 1 || ids[0] != a1.RequestID {
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

	// task 488, the keeps: an unread 'read' result stays through a sweep and goes at its hour (keep_until moved back);
	// a '7d' result is kept 7 days, read or not, and every signed-in user reads it (the opt-in's words)
	finish := func(id int64, keep string) {
		t.Helper()
		var ok bool
		if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_finish($1, $2, $3::jsonb)`, w1, id,
			fmt.Sprintf(`{"state": "done", "outcome": "1 set, 1 row", "rows": 1, "keep": %q, "result": {"sets": [{"columns": ["n"], "rows": [[1]]}]}}`, keep)).Scan(&ok); err != nil || !ok {
			t.Fatalf("finish %d (%s): %v %v", id, keep, ok, err)
		}
	}
	stored := func(id int64) bool {
		t.Helper()
		var kept bool
		if err := pool.QueryRow(ctx, `SELECT result IS NOT NULL FROM pgvigil.ui_action_data WHERE request_id = $1`, id).Scan(&kept); err != nil {
			t.Fatal(err)
		}
		return kept
	}
	k1 := ask("community_run", i1, "alice", run)
	if got := claim(w1, 4, 1); len(got) != 1 || got[0].ID != k1.RequestID {
		t.Fatalf("the unread run's claim: %+v, want %d", got, k1.RequestID)
	}
	finish(k1.RequestID, "read")
	exec(`SELECT pgvigil.import_action_sweep()`)
	if !stored(k1.RequestID) {
		t.Fatal("an unread result was cleared by a sweep inside its hour")
	}
	if m := result(k1.RequestID, "bob"); m["refused"] != "this run was asked by another user" {
		t.Fatalf("bob read alice's unread 'read' result: %v", m)
	}
	exec(`UPDATE pgvigil.action_requests SET keep_until = clock_timestamp() - interval '1 second' WHERE request_id = $1`, k1.RequestID)
	exec(`SELECT pgvigil.import_action_sweep()`)
	if stored(k1.RequestID) {
		t.Fatal("an unread result outlived its hour")
	}
	k7 := ask("community_run", i1, "alice", run)
	if got := claim(w1, 4, 1); len(got) != 1 || got[0].ID != k7.RequestID {
		t.Fatalf("the 7d run's claim: %+v, want %d", got, k7.RequestID)
	}
	finish(k7.RequestID, "7d")
	var keep string
	var days bool
	if err := pool.QueryRow(ctx, `SELECT keep, keep_until BETWEEN done_at + interval '7 days' - interval '1 second' AND done_at + interval '7 days'
		FROM pgvigil.action_requests WHERE request_id = $1`, k7.RequestID).Scan(&keep, &days); err != nil || keep != "7d" || !days {
		t.Fatalf("the 7d keep: %q, 7 days %v (%v)", keep, days, err)
	}
	if m := result(k7.RequestID, "alice"); m["result"] == nil {
		t.Fatalf("alice's 7d read: %v", m)
	}
	exec(`SELECT pgvigil.import_action_sweep()`)
	if m := result(k7.RequestID, "bob"); m["refused"] != nil || m["result"] == nil || m["cleared"] != false {
		t.Fatalf("a 7d result after its asker read it and a sweep, read by bob: %v (want kept and served)", m)
	}
	var readBy bool
	if err := pool.QueryRow(ctx, `SELECT read_at IS NOT NULL FROM pgvigil.action_requests WHERE request_id = $1`, k7.RequestID).Scan(&readBy); err != nil || !readBy {
		t.Fatalf("the asker's read of a 7d result left read_at empty (%v)", err)
	}
	exec(`UPDATE pgvigil.action_requests SET keep_until = clock_timestamp() - interval '1 second' WHERE request_id = $1`, k7.RequestID)
	exec(`SELECT pgvigil.import_action_sweep()`)
	if stored(k7.RequestID) {
		t.Fatal("a 7d result outlived its 7 days")
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

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), two workers holding one instance (review
// 20261114-215058 findings 4 and 5):
//   - a tool one holder's community_allow shuts (a shut named door) and the other's leaves open is accepted, and only
//     the open holder claims it; the name matches whatever its case;
//   - shut on every open holder, it is refused with a holder's words;
//   - a result over 8 MB as jsonb's text ends 'failed' with words (the finish returns true), never 23514.
func TestActionRequestsNamedDoorsOnAStore(t *testing.T) {
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
	inst := fmt.Sprintf("cq-n-%d", sfx)
	wa, wb := fmt.Sprintf("cq-na-%d", sfx), fmt.Sprintf("cq-nb-%d", sfx)
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 20*time.Second)
		defer stop()
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.action_requests WHERE instance = $1`, inst)
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.cq_workers WHERE collector_id = ANY($1)`, []string{wa, wb})
	})
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
	}
	ask := func(tool string) (outcome, detail string, id int64) {
		t.Helper()
		var raw []byte
		body := fmt.Sprintf(`{"kind": "community_run", "instance": %q, "ui_user": "nina", "args": {"tool": %q}}`, inst, tool)
		if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_request($1::jsonb)::text`, body).Scan(&raw); err != nil {
			t.Fatalf("import_action_request %s: %v", body, err)
		}
		var a struct {
			Outcome   string `json:"outcome"`
			Detail    string `json:"detail"`
			RequestID int64  `json:"request_id"`
		}
		if err := json.Unmarshal(raw, &a); err != nil {
			t.Fatal(err)
		}
		return a.Outcome, a.Detail, a.RequestID
	}
	claim := func(w string) []int64 {
		t.Helper()
		rows, err := pool.Query(ctx, `SELECT request_id FROM pgvigil.import_action_claim($1, 4, 1, '{}'::jsonb)`, w)
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
	for _, w := range []string{wa, wb} {
		exec(`SELECT * FROM pgvigil.import_cq_beat($1, $2, $3, NULL)`, w, "host-"+w, []string{inst})
	}
	exec(`SELECT pgvigil.import_cq_doors($1, $2::jsonb)`, wa, fmt.Sprintf(`[{"instance": %q, "kind": "community_run", "open": true},
		{"instance": %q, "kind": "community_run", "name": "sp_Blitz", "open": false, "why": "sp_Blitz is not in community_allow for this instance"}]`, inst, inst))
	exec(`SELECT pgvigil.import_cq_doors($1, $2::jsonb)`, wb, fmt.Sprintf(`[{"instance": %q, "kind": "community_run", "open": true}]`, inst))

	out, detail, id := ask("sp_Blitz")
	if out != "waiting" {
		t.Fatalf("sp_Blitz shut on %s and open on %s: %s %q, want waiting", wa, wb, out, detail)
	}
	if got := claim(wa); len(got) != 0 {
		t.Fatalf("the holder whose community_allow shuts sp_Blitz claimed %v", got)
	}
	if got := claim(wb); len(got) != 1 || got[0] != id {
		t.Fatalf("the open holder claimed %v, want [%d]", got, id)
	}

	// an 8 MB result as Go measures it can be over 8 MB as jsonb's text: the end is 'failed' with words
	var ok bool
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_finish($1, $2, jsonb_build_object('state', 'done', 'outcome', 'ran',
		'result', jsonb_build_object('sets', jsonb_build_array(jsonb_build_object('columns', jsonb_build_array('x'),
		  'rows', (SELECT jsonb_agg(jsonb_build_array(repeat('y', 1000))) FROM generate_series(1, 9000)))))))`, wb, id).Scan(&ok); err != nil || !ok {
		t.Fatalf("the finish of a 9 MB result: %v %v, want true and no error", ok, err)
	}
	var st, outcome string
	var bytes *int
	var kept bool
	if err := pool.QueryRow(ctx, `SELECT r.state, r.outcome, r.result_bytes, a.result IS NOT NULL FROM pgvigil.action_requests r
		JOIN pgvigil.ui_action_data a USING (request_id) WHERE r.request_id = $1`, id).Scan(&st, &outcome, &bytes, &kept); err != nil {
		t.Fatal(err)
	}
	if st != "failed" || !strings.Contains(outcome, "over the 8 MB queue mode keeps") || bytes != nil || kept {
		t.Fatalf("a 9 MB result: %s %q bytes %v kept %v, want failed with the words, nothing kept", st, outcome, bytes, kept)
	}

	// shut on both holders: refused with a holder's words, whatever the name's case
	exec(`SELECT pgvigil.import_cq_doors($1, $2::jsonb)`, wb, fmt.Sprintf(`[{"instance": %q, "kind": "community_run", "open": true},
		{"instance": %q, "kind": "community_run", "name": "sp_Blitz", "open": false, "why": "sp_Blitz is not in community_allow for this instance"}]`, inst, inst))
	for _, tool := range []string{"sp_Blitz", "SP_BLITZ"} {
		if out, detail, _ := ask(tool); out != "refused" || !strings.Contains(detail, "sp_Blitz is not in community_allow for this instance (the collector on host-") {
			t.Fatalf("%s shut on both holders: %s %q", tool, out, detail)
		}
	}
	if out, detail, _ := ask("sp_WhoIsActive"); out != "waiting" {
		t.Fatalf("a tool no holder shuts: %s %q", out, detail)
	}
}

// On a store whose purge() carries scripts/cq-wiring-a.patch (skipped otherwise): a read kind's ended row older than
// 7 days goes, a newer one stays, an action kind's row that ran stays whatever its age, a refused one of any kind goes
// after 7 days, a waiting one stays; a worker silent for 8 days goes with its doors.
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
	oldRefused, newRefused := ins("mssql_kill", "action", "refused", "8 days"), ins("mssql_kill", "action", "refused", "6 days")
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.cq_workers (collector_id, host, instances, started_at, beat_at)
		VALUES ($1, 'h', '{}', now() - interval '9 days', now() - interval '9 days')`, w); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.purge(30)`); err != nil {
		t.Fatal(err)
	}
	for id, want := range map[int64]bool{oldRead: false, newRead: true, oldAction: true, oldWait: true, oldRefused: false, newRefused: true} {
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
