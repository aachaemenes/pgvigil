package repo

import (
	"context"
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

// doorRole is the agent door's group role (0268): a name no published release gave a login - v0.3.0's collector login
// is pgvigil_agent ('pgvigil roles', README's repository DSN) and its MCP reader login pgvigil_mcp (docs/mcp.md).
const doorRole = "pgvigil_investigator"

// publishedLogins are the logins a v0.3.0 install made as its documents said, each IN ROLE its group
var publishedLogins = []struct{ name, group string }{
	{"pgvigil_agent", "pgvigil_collector"}, // 'pgvigil roles': the collector's login
	{"pgvigil_mcp", "pgvigil_reader"},      // docs/mcp.md: the MCP reader's login
}

// TestAgentDoorRoleIsNotTheCollectorLogin (AGENTROLE, a box row: PGVIGIL_REPO_TEST_DSN, a login that may create a
// database and roles): on a server where v0.3.0's published logins exist - pgvigil_agent IN ROLE pgvigil_collector and
// pgvigil_mcp IN ROLE pgvigil_reader - a database migrated from nothing (haJoinFreshStore) has the door's role doorRole
// as a NOLOGIN role; neither published login is a member of it or may EXECUTE any of the seven agent_investigation_*
// functions, and agent_investigation_list refuses a session as either. The roles are the server's: the test puts each
// login back as it found it.
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
	type before struct{ had, couldLogin, wasMember bool }
	found := map[string]before{}
	for _, l := range publishedLogins {
		var b before
		if err := admin.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1),
       coalesce((SELECT rolcanlogin FROM pg_roles WHERE rolname = $1), false),
       coalesce((SELECT pg_has_role($1, $2, 'MEMBER') WHERE to_regrole($1) IS NOT NULL AND to_regrole($2) IS NOT NULL), false)`,
			l.name, l.group).Scan(&b.had, &b.couldLogin, &b.wasMember); err != nil {
			t.Fatalf("read the server's role %s: %v", l.name, err)
		}
		found[l.name] = b
		// as the documents printed it (the groups are 0008's)
		if _, err := admin.Exec(ctx, fmt.Sprintf(`DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %[2]s) THEN CREATE ROLE %[4]s NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %[1]s) THEN CREATE ROLE %[3]s LOGIN;
  ELSE ALTER ROLE %[3]s LOGIN; END IF;
END $$;
GRANT %[4]s TO %[3]s;`, quoteLit(l.name), quoteLit(l.group), pgx.Identifier{l.name}.Sanitize(), pgx.Identifier{l.group}.Sanitize())); err != nil {
			t.Fatalf("make v0.3.0's login %s IN ROLE %s: %v", l.name, l.group, err)
		}
	}
	t.Cleanup(func() { // registered first: it runs after the fresh database (below) is dropped
		bg := context.Background()
		defer func() { _ = admin.Close(bg) }()
		for _, l := range publishedLogins {
			b, id, gid := found[l.name], pgx.Identifier{l.name}.Sanitize(), pgx.Identifier{l.group}.Sanitize()
			if !b.had {
				if _, err := admin.Exec(bg, `DROP ROLE IF EXISTS `+id); err != nil {
					t.Logf("%s left on the server (it holds grants elsewhere): %v", l.name, err)
				}
				continue
			}
			if !b.couldLogin {
				_, _ = admin.Exec(bg, `ALTER ROLE `+id+` NOLOGIN`)
			}
			if !b.wasMember {
				_, _ = admin.Exec(bg, `REVOKE `+gid+` FROM `+id)
			}
		}
	})
	r := haJoinFreshStore(ctx, t)

	var doorLogin *bool
	if err := r.pool.QueryRow(ctx, `SELECT (SELECT rolcanlogin FROM pg_roles WHERE rolname = $1)`, doorRole).Scan(&doorLogin); err != nil {
		t.Fatal(err)
	}
	switch {
	case doorLogin == nil:
		t.Errorf("the door's role %s is not on the server after the migrate", doorRole)
	case *doorLogin:
		t.Errorf("%s may log in: want a NOLOGIN group role (the door's login is IN ROLE pgvigil_reader, %s)", doorRole, doorRole)
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.Database = r.pool.Config().ConnConfig.Database
	for _, l := range publishedLogins {
		var member bool
		var all int
		var execs []string
		if err := r.pool.QueryRow(ctx, `SELECT coalesce(pg_has_role($1, to_regrole($2)::oid, 'MEMBER'), false),
       (SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'pgvigil' AND p.proname LIKE 'agent\_investigation\_%'),
       (SELECT coalesce(array_agg(p.proname::text ORDER BY p.proname), '{}') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'pgvigil' AND p.proname LIKE 'agent\_investigation\_%' AND has_function_privilege($1, p.oid, 'EXECUTE'))`,
			l.name, doorRole).Scan(&member, &all, &execs); err != nil {
			t.Fatal(err)
		}
		if member {
			t.Errorf("the published login %s is a member of the door's role %s", l.name, doorRole)
		}
		if all != 7 {
			t.Errorf("%d agent_investigation_* function(s) on the store, want the door's seven", all)
		}
		if len(execs) > 0 {
			t.Errorf("the published login %s may EXECUTE %d of the door's functions: %s", l.name, len(execs), strings.Join(execs, ", "))
		}
		// a session as that login (SET SESSION AUTHORIZATION: session_user, which the door's check reads, is the login)
		c, err := pgx.ConnectConfig(ctx, cfg)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := c.Exec(ctx, `SET SESSION AUTHORIZATION `+pgx.Identifier{l.name}.Sanitize()); err != nil {
			_ = c.Close(ctx)
			t.Fatal(err)
		}
		var got string
		err = c.QueryRow(ctx, `SELECT pgvigil.agent_investigation_list(NULL, NULL, 10)::text`).Scan(&got)
		_ = c.Close(ctx)
		var pe *pgconn.PgError
		switch {
		case err == nil:
			t.Errorf("a session as the published login %s read the door's list: %s - want it refused", l.name, got)
		case !errors.As(err, &pe) || pe.Code != "42501":
			t.Errorf("a session as %s: %v - want a refusal (SQLSTATE 42501)", l.name, err)
		}
	}
}

// quoteLit is s as an SQL string literal (the role names here are this file's own constants)
func quoteLit(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// TestAgentDoorRoleGuard (AGENTROLE, the lead's guard (y), a box row like the one above): when a role of the door's
// name already exists as a LOGIN role, 0268 stops the migrate in words naming the role and why - a login of that name
// would get the door's grants and pass its check - and the database is left before 0268 (the file's own transaction).
func TestAgentDoorRoleGuard(t *testing.T) {
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
	id := pgx.Identifier{doorRole}.Sanitize()
	var had, couldLogin bool
	if err := admin.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1),
       coalesce((SELECT rolcanlogin FROM pg_roles WHERE rolname = $1), false)`, doorRole).Scan(&had, &couldLogin); err != nil {
		t.Fatal(err)
	}
	stmt := `CREATE ROLE ` + id + ` LOGIN`
	if had {
		stmt = `ALTER ROLE ` + id + ` LOGIN`
	}
	if _, err := admin.Exec(ctx, stmt); err != nil {
		t.Fatalf("make %s a login: %v", doorRole, err)
	}
	name := fmt.Sprintf("pgvguard_%d", time.Now().UnixNano()%1_000_000_000)
	if _, err := admin.Exec(ctx, `CREATE DATABASE `+pgx.Identifier{name}.Sanitize()); err != nil {
		t.Fatalf("a fresh database: %v", err)
	}
	t.Cleanup(func() {
		bg := context.Background()
		defer func() { _ = admin.Close(bg) }()
		if _, err := admin.Exec(bg, `DROP DATABASE IF EXISTS `+pgx.Identifier{name}.Sanitize()+` WITH (FORCE)`); err != nil {
			t.Errorf("drop %s: %v", name, err)
		}
		switch {
		case !had:
			if _, err := admin.Exec(bg, `DROP ROLE IF EXISTS `+id); err != nil {
				t.Logf("%s left on the server: %v", doorRole, err)
			}
		case !couldLogin:
			_, _ = admin.Exec(bg, `ALTER ROLE `+id+` NOLOGIN`)
		}
	})
	pcfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	pcfg.ConnConfig.Database = name
	pool, err := pgxpool.NewWithConfig(ctx, pcfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	r := &Repo{pool: pool}
	_, err = r.Migrate(ctx)
	switch {
	case err == nil:
		t.Errorf("migrate on a server where %s is a LOGIN role: no error, want the guard's refusal at 0268", doorRole)
	case !strings.Contains(err.Error(), "0268_investigations.sql") || !strings.Contains(err.Error(), doorRole+" exists and may log in"):
		t.Errorf("migrate on a server where %s is a LOGIN role: %v - want 0268's refusal naming it ('%s exists and may log in ...')", doorRole, err, doorRole)
	}
	var newest string
	if err := r.pool.QueryRow(ctx, `SELECT coalesce(max(version), '') FROM pgvigil.schema_version`).Scan(&newest); err != nil {
		t.Fatal(err)
	}
	if newest >= "0268" {
		t.Errorf("after the refusal the newest file recorded is %s, want one before 0268", newest)
	}
}
