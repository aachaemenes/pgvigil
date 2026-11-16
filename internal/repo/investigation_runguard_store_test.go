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
)

// TestInvestigationRunNeedsTheAuditLoginOnAStore (J16-RUNGUARD, a box row: PGVIGIL_REPO_TEST_DSN, a superuser - its
// SET SESSION AUTHORIZATION needs one; run on PostgreSQL 13 and 18): import_investigation_event's op 'run' writes the audit of
// an ask's Run - serve writes it through the actions door's audit login, which holds pgvigil_collector (docs/alerts.md:
// the collector role is the actions door's audit login; a queue-mode serve offers no investigations, q_investigate.go
// investigationOff). A session that may call the function but is no member of pgvigil_collector is refused op 'run'
// (SQLSTATE 42501, the words naming the role) and writes no journal row - else it could write 'run' lines under any
// ui_user, with any sql / rows / outcome, and fill the request's 195-row budget of calls so the agent's claim, renew and
// select are refused; a member of pgvigil_collector writes it. J16-RUNGUARD OP CLOSE (review 6 #2, the lead's 15:07):
// the request queue's role pgvigil_requester holds neither investigation function in j16 (0300 granted both for a later
// release's queue path; no j16 path calls them as that role) - its request, its close (which would end another user's
// ask under any closed_by) and its run are each refused 42501 and change nothing. The roles are made for the test and
// dropped after it.
func TestInvestigationRunNeedsTheAuditLoginOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = admin.Close(context.Background()) }) // registered first: it runs last
	n := time.Now().UnixNano() % 1_000_000_000
	requester, collector, caller := fmt.Sprintf("pgvrg_rq_%d", n), fmt.Sprintf("pgvrg_co_%d", n), fmt.Sprintf("pgvrg_ex_%d", n)
	// the roles' drop, registered before the fresh database's (it runs after the database is dropped, its grants with it)
	t.Cleanup(func() {
		for _, r := range []string{requester, collector, caller} {
			_, _ = admin.Exec(context.Background(), `DROP ROLE IF EXISTS `+pgx.Identifier{r}.Sanitize())
		}
	})
	st := haJoinFreshStore(ctx, t)
	for _, x := range []struct{ role, group string }{{requester, "pgvigil_requester"}, {collector, "pgvigil_collector"}} {
		if _, err := admin.Exec(ctx, `CREATE ROLE `+pgx.Identifier{x.role}.Sanitize()+` NOLOGIN IN ROLE `+pgx.Identifier{x.group}.Sanitize()); err != nil {
			t.Fatalf("make %s IN ROLE %s: %v", x.role, x.group, err)
		}
	}
	// caller: may call import_investigation_event (its own grant, in the fresh database) and is in no pgvigil group
	if _, err := admin.Exec(ctx, `CREATE ROLE `+pgx.Identifier{caller}.Sanitize()+` NOLOGIN`); err != nil {
		t.Fatalf("make %s: %v", caller, err)
	}
	if _, err := st.pool.Exec(ctx, `GRANT USAGE ON SCHEMA pgvigil TO `+pgx.Identifier{caller}.Sanitize()+`; GRANT EXECUTE ON FUNCTION pgvigil.import_investigation_event(timestamptz, jsonb) TO `+pgx.Identifier{caller}.Sanitize()); err != nil {
		t.Fatalf("grant %s the event function: %v", caller, err)
	}
	ask := func(who string) int64 {
		t.Helper()
		var out []byte
		if err := st.pool.QueryRow(ctx, `SELECT pgvigil.import_investigation_request(now(), $1::jsonb)::text`,
			fmt.Sprintf(`{"ui_user": %q, "kind": "ask", "question": "which sessions block now?"}`, who)).Scan(&out); err != nil {
			t.Fatal(err)
		}
		var res struct {
			Outcome, Detail string
			ID              int64
		}
		if err := json.Unmarshal(out, &res); err != nil || res.Outcome != "done" || res.ID == 0 {
			t.Fatalf("the ask was not written: %s (%v)", out, err)
		}
		return res.ID
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.Database = st.pool.Config().ConnConfig.Database
	// call runs one investigation import function in a session as role (SET SESSION AUTHORIZATION: session_user is the role)
	call := func(role, fn, payload string) (string, error) {
		c, err := pgx.ConnectConfig(ctx, cfg)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = c.Close(ctx) }()
		if _, err := c.Exec(ctx, `SET SESSION AUTHORIZATION `+pgx.Identifier{role}.Sanitize()); err != nil {
			t.Fatal(err)
		}
		var out string
		err = c.QueryRow(ctx, `SELECT pgvigil.`+fn+`(now(), $1::jsonb)::text`, payload).Scan(&out)
		return out, err
	}
	event := func(role, payload string) (string, error) { return call(role, "import_investigation_event", payload) }
	refused := func(what string, err error, out string) {
		t.Helper()
		var pe *pgconn.PgError
		if err == nil {
			t.Errorf("%s: %s - want it refused (SQLSTATE 42501: the role holds no grant of the function in j16)", what, out)
		} else if !errors.As(err, &pe) || pe.Code != "42501" {
			t.Errorf("%s: %v - want SQLSTATE 42501", what, err)
		}
	}
	state := func(id int64) (st8 string) {
		t.Helper()
		if err := st.pool.QueryRow(ctx, `SELECT state FROM pgvigil.investigations WHERE id = $1`, id).Scan(&st8); err != nil {
			t.Fatal(err)
		}
		return st8
	}
	runs := func(id int64) (n int) {
		t.Helper()
		if err := st.pool.QueryRow(ctx, `SELECT count(*)::int FROM pgvigil.investigation_journal WHERE investigation_id = $1 AND event = 'run'`, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	run := func(id int64, who string) string {
		return fmt.Sprintf(`{"op": "run", "id": %d, "ui_user": %q, "rows": 1, "ms": 2, "outcome": "done", "sql": "SELECT 1"}`, id, who)
	}

	id := ask("u1")
	// a caller that may call the function and is no member of pgvigil_collector: its run refused in words naming the
	// role (the guard), and nothing written
	out, err := event(caller, run(id, "someone-else"))
	var pe *pgconn.PgError
	switch {
	case err == nil:
		t.Errorf("a session as %s (EXECUTE, no pgvigil_collector) wrote a run line: %s - want it refused (SQLSTATE 42501)", caller, out)
	case !errors.As(err, &pe) || pe.Code != "42501" || !strings.Contains(pe.Message, "pgvigil_collector"):
		t.Errorf("a session as %s: %v - want SQLSTATE 42501 with words naming pgvigil_collector", caller, err)
	}
	// the requester's run: refused (it holds no grant of the function), and nothing written
	out, err = event(requester, run(id, "someone-else"))
	refused(fmt.Sprintf("a session as %s (IN ROLE pgvigil_requester) asking a run line", requester), err, out)
	if got := runs(id); got != 0 {
		t.Errorf("after the refused runs: %d run line(s) on investigation %d, want 0", got, id)
	}
	// the audit login's run (a member of pgvigil_collector): written
	out, err = event(collector, run(id, "u1"))
	if err != nil || !strings.Contains(out, `"outcome": "done"`) {
		t.Errorf("a session as %s (IN ROLE pgvigil_collector): %s, %v - want outcome done", collector, out, err)
	}
	if got := runs(id); got != 1 {
		t.Errorf("after the audit login's run: %d run line(s) on investigation %d, want 1", got, id)
	}
	// the requester's close of another user's ask (any closed_by): refused, the ask still open
	id2 := ask("u2")
	out, err = event(requester, fmt.Sprintf(`{"op": "close", "id": %d, "ui_user": "someone-else", "reason": "the runguard row"}`, id2))
	refused(fmt.Sprintf("a session as %s (IN ROLE pgvigil_requester) closing u2's ask", requester), err, out)
	if got := state(id2); got != "open" {
		t.Errorf("u2's ask after the requester's refused close: state %q, want open", got)
	}
	// the requester's request (an ask under any ui_user): refused, nothing filed
	var before, after int
	if err := st.pool.QueryRow(ctx, `SELECT count(*)::int FROM pgvigil.investigations`).Scan(&before); err != nil {
		t.Fatal(err)
	}
	out, err = call(requester, "import_investigation_request", `{"ui_user": "someone-else", "kind": "ask", "question": "which sessions block now?"}`)
	refused(fmt.Sprintf("a session as %s (IN ROLE pgvigil_requester) filing an ask", requester), err, out)
	if err := st.pool.QueryRow(ctx, `SELECT count(*)::int FROM pgvigil.investigations`).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if after != before {
		t.Errorf("investigations after the requester's refused request: %d, want %d", after, before)
	}
}
