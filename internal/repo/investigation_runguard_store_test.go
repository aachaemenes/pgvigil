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
// investigationOff). 0300 also grants the function to pgvigil_requester (for a later release's queue path), and a
// session of that role could write 'run' lines under any ui_user, with any sql / rows / outcome, and fill the request's
// 195-row budget of calls so the agent's claim, renew and select are refused. A session that is no member of
// pgvigil_collector is refused op 'run' (SQLSTATE 42501, the words naming the role) and writes no journal row; a
// member of pgvigil_collector writes it; the requester's other op (close) is unchanged. The roles are made for the test
// and dropped after it.
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
	requester, collector := fmt.Sprintf("pgvrg_rq_%d", n), fmt.Sprintf("pgvrg_co_%d", n)
	// the roles' drop, registered before the fresh database's (it runs after the database is dropped)
	t.Cleanup(func() {
		for _, r := range []string{requester, collector} {
			_, _ = admin.Exec(context.Background(), `DROP ROLE IF EXISTS `+pgx.Identifier{r}.Sanitize())
		}
	})
	st := haJoinFreshStore(ctx, t)
	for _, x := range []struct{ role, group string }{{requester, "pgvigil_requester"}, {collector, "pgvigil_collector"}} {
		if _, err := admin.Exec(ctx, `CREATE ROLE `+pgx.Identifier{x.role}.Sanitize()+` NOLOGIN IN ROLE `+pgx.Identifier{x.group}.Sanitize()); err != nil {
			t.Fatalf("make %s IN ROLE %s: %v", x.role, x.group, err)
		}
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
	// event calls import_investigation_event in a session as role (SET SESSION AUTHORIZATION: session_user is the role)
	event := func(role string, payload string) (string, error) {
		c, err := pgx.ConnectConfig(ctx, cfg)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = c.Close(ctx) }()
		if _, err := c.Exec(ctx, `SET SESSION AUTHORIZATION `+pgx.Identifier{role}.Sanitize()); err != nil {
			t.Fatal(err)
		}
		var out string
		err = c.QueryRow(ctx, `SELECT pgvigil.import_investigation_event(now(), $1::jsonb)::text`, payload).Scan(&out)
		return out, err
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
	// the requester's run: refused in words naming the role, and nothing written
	out, err := event(requester, run(id, "someone-else"))
	var pe *pgconn.PgError
	switch {
	case err == nil:
		t.Errorf("a session as %s (IN ROLE pgvigil_requester) wrote a run line: %s - want it refused (SQLSTATE 42501)", requester, out)
	case !errors.As(err, &pe) || pe.Code != "42501" || !strings.Contains(pe.Message, "pgvigil_collector"):
		t.Errorf("a session as %s: %v - want SQLSTATE 42501 with words naming pgvigil_collector", requester, err)
	}
	if got := runs(id); got != 0 {
		t.Errorf("after the requester's refused run: %d run line(s) on investigation %d, want 0", got, id)
	}
	// the audit login's run (a member of pgvigil_collector): written
	out, err = event(collector, run(id, "u1"))
	if err != nil || !strings.Contains(out, `"outcome": "done"`) {
		t.Errorf("a session as %s (IN ROLE pgvigil_collector): %s, %v - want outcome done", collector, out, err)
	}
	if got := runs(id); got != 1 {
		t.Errorf("after the audit login's run: %d run line(s) on investigation %d, want 1", got, id)
	}
	// the requester's other op: close, unchanged
	id2 := ask("u2")
	out, err = event(requester, fmt.Sprintf(`{"op": "close", "id": %d, "ui_user": "u2", "reason": "the runguard row"}`, id2))
	if err != nil || !strings.Contains(out, `"outcome": "done"`) {
		t.Errorf("the requester's close: %s, %v - want outcome done (op close unchanged)", out, err)
	}
}
