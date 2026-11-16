package repo

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// TestAgentDoorRoleIsNotTheCollectorLogin (AGENTROLE, a box row: PGVIGIL_REPO_TEST_DSN, a login that may create a
// database and roles): pgvigil_agent is the collector's LOGIN since v0.3.0 (README's repository DSN, 'pgvigil roles'
// prints it IN ROLE pgvigil_collector), so the agent door's group role is another name - pgvigil_mcp - and a v0.3.0
// install's collector login gets none of the door. On a server where pgvigil_agent is a LOGIN IN ROLE pgvigil_collector,
// a database migrated from nothing (haJoinFreshStore) has pgvigil_mcp as a NOLOGIN role; pgvigil_agent is no member of
// it and may EXECUTE none of the seven agent_investigation_* functions; a session as pgvigil_agent is refused by
// agent_investigation_list. The roles are the server's: the test puts pgvigil_agent back as it found it.
func TestAgentDoorRoleIsNotTheCollectorLogin(t *testing.T) {
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
	var had, couldLogin, wasMember bool
	if err := admin.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_agent'),
       coalesce((SELECT rolcanlogin FROM pg_roles WHERE rolname = 'pgvigil_agent'), false),
       coalesce((SELECT pg_has_role('pgvigil_agent', 'pgvigil_collector', 'MEMBER') WHERE to_regrole('pgvigil_agent') IS NOT NULL
                 AND to_regrole('pgvigil_collector') IS NOT NULL), false)`).Scan(&had, &couldLogin, &wasMember); err != nil {
		t.Fatalf("read the server's roles: %v", err)
	}
	// v0.3.0's collector login as 'pgvigil roles' printed it (pgvigil_collector is 0008's group)
	if _, err := admin.Exec(ctx, `DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_collector') THEN CREATE ROLE pgvigil_collector NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_agent') THEN CREATE ROLE pgvigil_agent LOGIN;
  ELSE ALTER ROLE pgvigil_agent LOGIN; END IF;
END $$;
GRANT pgvigil_collector TO pgvigil_agent;`); err != nil {
		t.Fatalf("make v0.3.0's collector login pgvigil_agent: %v", err)
	}
	t.Cleanup(func() { // registered first: it runs after the fresh database (below) is dropped
		bg := context.Background()
		defer func() { _ = admin.Close(bg) }()
		switch {
		case !had:
			if _, err := admin.Exec(bg, `DROP ROLE IF EXISTS pgvigil_agent`); err != nil {
				t.Logf("pgvigil_agent left on the server (it holds grants elsewhere): %v", err)
			}
		default:
			if !couldLogin {
				_, _ = admin.Exec(bg, `ALTER ROLE pgvigil_agent NOLOGIN`)
			}
			if !wasMember {
				_, _ = admin.Exec(bg, `REVOKE pgvigil_collector FROM pgvigil_agent`)
			}
		}
	})
	r := haJoinFreshStore(ctx, t)
	db := r.pool.Config().ConnConfig.Database

	var mcpLogin *bool
	if err := r.pool.QueryRow(ctx, `SELECT (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'pgvigil_mcp')`).Scan(&mcpLogin); err != nil {
		t.Fatal(err)
	}
	switch {
	case mcpLogin == nil:
		t.Errorf("the door's role pgvigil_mcp is not on the server after the migrate")
	case *mcpLogin:
		t.Errorf("pgvigil_mcp may log in: want a NOLOGIN group role (the door's login is IN ROLE pgvigil_reader, pgvigil_mcp)")
	}
	var member bool
	if err := r.pool.QueryRow(ctx, `SELECT coalesce(pg_has_role('pgvigil_agent', to_regrole('pgvigil_mcp')::oid, 'MEMBER'), false)`).Scan(&member); err != nil {
		t.Fatal(err)
	}
	if member {
		t.Errorf("the collector login pgvigil_agent is a member of the door's role pgvigil_mcp")
	}
	var all int
	var execs []string
	if err := r.pool.QueryRow(ctx, `SELECT count(*)::int,
       coalesce(array_agg(p.proname::text ORDER BY p.proname) FILTER (WHERE has_function_privilege('pgvigil_agent', p.oid, 'EXECUTE')), '{}')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'pgvigil' AND p.proname LIKE 'agent\_investigation\_%'`).Scan(&all, &execs); err != nil {
		t.Fatal(err)
	}
	if all != 7 {
		t.Errorf("%d agent_investigation_* function(s) on the store, want the door's seven", all)
	}
	if len(execs) > 0 {
		t.Errorf("the collector login pgvigil_agent may EXECUTE %d of the door's functions: %s", len(execs), strings.Join(execs, ", "))
	}
	// a session as pgvigil_agent (SET SESSION AUTHORIZATION: session_user, which the door's check reads, is that login)
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.Database = db
	c, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close(context.Background()) }()
	if _, err := c.Exec(ctx, `SET SESSION AUTHORIZATION pgvigil_agent`); err != nil {
		t.Fatal(err)
	}
	var got []byte
	err = c.QueryRow(ctx, `SELECT pgvigil.agent_investigation_list(NULL, NULL, 10)::text`).Scan(&got)
	var pe *pgconn.PgError
	switch {
	case err == nil:
		t.Errorf("a session as the collector login pgvigil_agent read the door's list: %s - want it refused", got)
	case !errors.As(err, &pe) || pe.Code != "42501":
		t.Errorf("a session as pgvigil_agent: %v - want a refusal (SQLSTATE 42501)", err)
	}
}
