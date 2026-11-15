package web

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), serve's queue mode (CQ 487):
//   - SetQueue refuses a login IN ROLE pgvigil_collector with words naming the role (serve exits on it);
//   - a login without pgvigil_requester starts, and the community door says the grant it needs;
//   - with reader + auth + requester: an ask is written for the session's user; GET /api/requests/<id> is the asker's
//     alone (another user 403 'this run was asked by another user'), answers at once with wait=0, and a waiting GET is
//     answered within 3 s of the request's end by the notify (LISTEN pgvigil_result held);
//   - under -no-login GET /api/requests/<id> is refused with words, never a panic;
//   - POST /api/requests/<id>/cancel cancels the asker's waiting request.
func TestQueueOnAStore(t *testing.T) {
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
	pc, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	sfx := time.Now().UnixNano() % 1000000000
	login := func(tag, roles string) string {
		t.Helper()
		name := fmt.Sprintf("t487%s_%d", tag, sfx)
		if _, err := pool.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s LOGIN IN ROLE %s`, name, roles)); err != nil {
			t.Skipf("this store's login may not make login roles: %v", err)
		}
		t.Cleanup(func() { _, _ = pool.Exec(context.Background(), fmt.Sprintf(`DROP ROLE IF EXISTS %s`, name)) })
		return fmt.Sprintf("host=%s port=%d user=%s dbname=%s", pc.Host, pc.Port, name, pc.Database)
	}
	inst, w := fmt.Sprintf("cq-q-%d", sfx), fmt.Sprintf("cq-qw-%d", sfx)
	t.Cleanup(func() {
		c := context.Background()
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.action_requests WHERE instance = $1`, inst)
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.cq_workers WHERE collector_id = $1`, w)
	})
	log := slog.New(slog.DiscardHandler)

	// a collector login: refused
	s1 := &Server{pool: pool, log: log}
	if err := s1.SetQueue(ctx, login("c", "pgvigil_collector")); err == nil || !strings.Contains(err.Error(), "IN ROLE pgvigil_collector") {
		t.Fatalf("SetQueue on a collector login: %v", err)
	}
	// no requester: starts, the door says the grant
	s2 := &Server{pool: pool, log: log, auth: newAuth(func(context.Context, string) (string, error) { return "h", nil }, false, time.Hour)}
	if err := s2.SetQueue(ctx, login("p", "pgvigil_reader, pgvigil_auth")); err != nil {
		t.Fatal(err)
	}
	if words := s2.communityOffWords(); !strings.Contains(words, "IN ROLE pgvigil_requester") {
		t.Fatalf("the door without the requester role: %q", words)
	}
	// reader + auth + requester
	au := newAuth(func(context.Context, string) (string, error) { return "h", nil }, false, time.Hour)
	s := &Server{pool: pool, log: log, auth: au}
	if err := s.SetQueue(ctx, login("q", "pgvigil_reader, pgvigil_auth, pgvigil_requester")); err != nil {
		t.Fatal(err)
	}
	q := s.queue()
	if q == nil || q.off != "" || s.communityOffWords() != "" {
		t.Fatalf("the queue with the requester role: %+v %q", q, s.communityOffWords())
	}
	alice, _ := au.issue("alice", "h")
	bob, _ := au.issue("bob", "h")
	// a worker holding the instance, its community door open (the owner writes them, as the worker would)
	if _, err := pool.Exec(ctx, `SELECT * FROM pgvigil.import_cq_beat($1, 'qhost', $2)`, w, []string{inst}); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_cq_doors($1, $2::jsonb)`, w, fmt.Sprintf(`[{"instance": %q, "kind": "community_run", "open": true}]`, inst)); err != nil {
		t.Fatal(err)
	}
	m, err := q.ask(ctx, "community_run", inst, "alice", "test", map[string]any{"tool": "pg_running"})
	if err != nil || m["outcome"] != "waiting" {
		t.Fatalf("the ask: %v %v", m, err)
	}
	id := int64(m["request_id"].(float64))

	get := func(tok string, wait int) (int, map[string]any) {
		t.Helper()
		r := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/requests/%d?wait=%d", id, wait), nil)
		r.SetPathValue("id", fmt.Sprint(id))
		if tok != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookie, Value: tok})
		}
		rec := httptest.NewRecorder()
		s.RequestGet(rec, r)
		out := map[string]any{}
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out
	}
	if code, out := get(bob, 0); code != http.StatusForbidden || !strings.Contains(fmt.Sprint(out["error"]), "this run was asked by another user") {
		t.Fatalf("bob's GET of alice's request: %d %v", code, out)
	}
	if code, out := get(alice, 0); code != http.StatusOK || out["state"] != "waiting" {
		t.Fatalf("alice's GET, wait 0: %d %v", code, out)
	}
	// a waiting GET answered by the notify
	time.Sleep(500 * time.Millisecond) // the listener's LISTEN is held by now
	type res struct {
		code int
		out  map[string]any
		took time.Duration
	}
	got := make(chan res, 1)
	go func() {
		t0 := time.Now()
		c, o := get(alice, 20)
		got <- res{c, o, time.Since(t0)}
	}()
	time.Sleep(300 * time.Millisecond)
	var cid int64
	if err := pool.QueryRow(ctx, `SELECT request_id FROM pgvigil.import_action_claim($1, 1, 0, '{}'::jsonb)`, w).Scan(&cid); err != nil || cid != id {
		t.Fatalf("the claim: %d %v", cid, err)
	}
	var ok bool
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_finish($1, $2, '{"state": "done", "outcome": "ran", "rows": 1, "result": {"sets": [{"columns": ["pid"], "rows": [[1]]}]}}'::jsonb)`, w, id).Scan(&ok); err != nil || !ok {
		t.Fatalf("the finish: %v %v", ok, err)
	}
	select {
	case r := <-got:
		if r.code != http.StatusOK || r.out["state"] != "done" || r.out["result"] == nil || r.took > 3*time.Second {
			t.Fatalf("the waiting GET: %d %v after %s", r.code, r.out, r.took)
		}
		if r.out["listening"] != true {
			t.Fatalf("the GET was answered without LISTEN: %v", r.out)
		}
	case <-time.After(25 * time.Second):
		t.Fatal("the waiting GET was not answered")
	}
	// -no-login: refused with words
	s4 := &Server{pool: pool, log: log}
	queues.Store(s4, q)
	r := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/requests/%d", id), nil)
	r.SetPathValue("id", fmt.Sprint(id))
	rec := httptest.NewRecorder()
	s4.RequestGet(rec, r)
	if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "without the UI login") {
		t.Fatalf("GET under -no-login: %d %s", rec.Code, rec.Body.String())
	}
	// cancel: the asker's waiting request
	m, err = q.ask(ctx, "community_run", inst, "alice", "test", map[string]any{"tool": "pg_running"})
	if err != nil || m["outcome"] != "waiting" {
		t.Fatalf("the second ask: %v %v", m, err)
	}
	id2 := int64(m["request_id"].(float64))
	cr := httptest.NewRequest(http.MethodPost, fmt.Sprintf("/api/requests/%d/cancel", id2), strings.NewReader("{}"))
	cr.SetPathValue("id", fmt.Sprint(id2))
	cr.Header.Set("X-Pgvigil", "1")
	cr.Header.Set("Content-Type", "application/json")
	cr.AddCookie(&http.Cookie{Name: sessionCookie, Value: alice})
	crec := httptest.NewRecorder()
	s.RequestCancel(crec, cr)
	var st string
	_ = pool.QueryRow(ctx, `SELECT state FROM pgvigil.action_requests WHERE request_id = $1`, id2).Scan(&st)
	if crec.Code != http.StatusOK || st != "cancelled" {
		t.Fatalf("alice's cancel: %d %s, state %s", crec.Code, crec.Body.String(), st)
	}
}
