package repo

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
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
	t.Cleanup(func() { _ = admin.Close(context.Background()) }) // registered first: it runs last
	for _, l := range publishedLogins {
		var had, couldLogin, wasMember bool
		// wasMember: a DIRECT membership (pg_auth_members), the one the GRANT below makes and the undo takes back
		if err := admin.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1),
       coalesce((SELECT rolcanlogin FROM pg_roles WHERE rolname = $1), false),
       EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member = to_regrole($1)::oid AND m.roleid = to_regrole($2)::oid)`,
			l.name, l.group).Scan(&had, &couldLogin, &wasMember); err != nil {
			t.Fatalf("read the server's role %s: %v", l.name, err)
		}
		// the undo before the change, so a failure below never leaves the server's role changed; it runs
		// after the fresh database (haJoinFreshStore, below) is dropped
		id, gid := pgx.Identifier{l.name}.Sanitize(), pgx.Identifier{l.group}.Sanitize()
		t.Cleanup(func() {
			bg := context.Background()
			if !had {
				if _, err := admin.Exec(bg, `DROP ROLE IF EXISTS `+id); err != nil {
					t.Logf("%s left on the server (it holds grants elsewhere): %v", l.name, err)
				}
				return
			}
			if !couldLogin {
				_, _ = admin.Exec(bg, `ALTER ROLE `+id+` NOLOGIN`)
			}
			if !wasMember {
				_, _ = admin.Exec(bg, `REVOKE `+gid+` FROM `+id)
			}
		})
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

// TestAgentDoorRoleGuard (AGENTROLE's guard (y), a box row like the one above): when a role of the door's
// name already exists as a LOGIN role, 0268 stops the migrate in words naming the role and why - a login of that name
// would get the door's grants and pass its check - and the database is left before 0268 (the file's own transaction).
// A role is the whole server's: the row must never make the door's role a LOGIN role on the server of
// PGVIGIL_REPO_TEST_DSN, which other packages and other test runs share - a fresh migrate of theirs reaching 0268 in that
// window stops at the guard. So the row runs in a PostgreSQL cluster of its
// own (guardClusterDSN); before the role is touched the cluster's system identifier must differ from the shared
// server's (the check that cannot miss), and a watcher on the shared server fails the row if the
// door's role turns LOGIN there while it runs, or if the watch could not read (a blind watch fails, never passes).
func TestAgentDoorRoleGuard(t *testing.T) {
	shared := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if shared == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	sharedID := systemIdentifier(t, shared, "the shared server of PGVIGIL_REPO_TEST_DSN")
	seen := watchSharedDoorLogin(t, shared)
	own := guardClusterDSN(t)
	if id := systemIdentifier(t, own, "the row's own cluster"); id == sharedID {
		t.Fatalf("the row's own cluster has the shared server's system identifier %s: the row would change the door's role on the shared server - refused before any change", id)
	}
	runDoorGuard(t, own)
	if at := seen(); at != "" {
		t.Errorf("%s was a LOGIN role on the shared server of PGVIGIL_REPO_TEST_DSN at %s while the row ran: another migrate reaching 0268 there stops at the guard", doorRole, at)
	}
}

// guardClusterDSN is the server the guard row changes the door's role on: a PostgreSQL cluster of the row's own, made
// by initdb in a fresh temp dir and started by pg_ctl with its socket in that dir alone (listen_addresses empty: no TCP),
// trust on that socket (safe only because MkdirTemp makes the dir 0700: no other user reaches the socket), fsync off;
// stopped (-m immediate) and removed at the row's end, after the row's own cleanups. initdb comes from
// PGVIGIL_TEST_PG_BINDIR (set there and missing: the row FAILs), else PATH (without it the row SKIPs and says why - it
// never falls back to the shared server); pg_ctl from initdb's own folder, so both are one major version.
func guardClusterDSN(t *testing.T) string {
	t.Helper()
	initdb := "initdb"
	if d := os.Getenv("PGVIGIL_TEST_PG_BINDIR"); d != "" {
		initdb = filepath.Join(d, "initdb")
		if _, err := exec.LookPath(initdb); err != nil {
			t.Fatalf("PGVIGIL_TEST_PG_BINDIR=%s holds no initdb: %v (the guard row needs a cluster of its own)", d, err)
		}
	}
	initdb, err := exec.LookPath(initdb)
	if err != nil {
		t.Skipf("no initdb on PATH (and PGVIGIL_TEST_PG_BINDIR unset): the guard row runs only in a cluster of its own, never on a shared server")
	}
	pgctl := filepath.Join(filepath.Dir(initdb), "pg_ctl")
	if _, err := exec.LookPath(pgctl); err != nil {
		t.Fatalf("no pg_ctl beside %s: %v", initdb, err)
	}
	dir, err := os.MkdirTemp("", "pgvg") // short: a socket's path is 107 bytes at most
	if err != nil {
		t.Fatal(err)
	}
	if sock := filepath.Join(dir, ".s.PGSQL.5432"); len(sock) > 107 || strings.ContainsAny(dir, " ,'\"\\") {
		t.Fatalf("the cluster's socket dir %q cannot carry a socket (%d bytes, at most 107; no space, comma or quote): set TMPDIR to a short plain path", dir, len(sock))
	}
	t.Logf("the guard row's own cluster: %s (pg_ctl -D %s/data -m immediate stop, if a run left it)", dir, dir)
	t.Cleanup(func() { _ = os.RemoveAll(dir) }) // registered first: it runs last, after the stop
	data := filepath.Join(dir, "data")
	if out, err := exec.Command(initdb, "-D", data, "-U", "pgvguard", "-A", "trust", "-E", "UTF8", "--locale=C", "--no-sync").CombinedOutput(); err != nil {
		t.Fatalf("initdb: %v\n%s", err, out)
	}
	logf := filepath.Join(dir, "server.log")
	opts := "-c listen_addresses= -c unix_socket_directories=" + dir + " -c port=5432 -c fsync=off"
	// the stop before the start: a start past -t 120 leaves the server running though pg_ctl fails; stopping a
	// cluster that is not running only errs, and the error is dropped
	t.Cleanup(func() { _ = exec.Command(pgctl, "-D", data, "-m", "immediate", "-w", "stop").Run() })
	if out, err := exec.Command(pgctl, "-D", data, "-l", logf, "-w", "-t", "120", "-o", opts, "start").CombinedOutput(); err != nil {
		l, _ := os.ReadFile(logf)
		t.Fatalf("pg_ctl start: %v\n%s\n%s", err, out, l)
	}
	dsn := "host=" + dir + " port=5432 user=pgvguard dbname=postgres sslmode=disable"
	if c, err := pgx.Connect(context.Background(), dsn); err == nil {
		var v string
		_ = c.QueryRow(context.Background(), `SHOW server_version`).Scan(&v)
		_ = c.Close(context.Background())
		t.Logf("the guard row's cluster runs PostgreSQL %s (whatever PGVIGIL_REPO_TEST_DSN runs)", v)
	}
	return dsn
}

// systemIdentifier is a server's pg_control_system() system identifier, read once; a read that fails ends the row (the
// identity check never passes blind)
func systemIdentifier(t *testing.T, dsn, what string) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	c, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatalf("%s: %v", what, err)
	}
	defer func() { _ = c.Close(context.Background()) }()
	var id string
	if err := c.QueryRow(ctx, `SELECT system_identifier::text FROM pg_control_system()`).Scan(&id); err != nil {
		t.Fatalf("%s: its system identifier: %v", what, err)
	}
	return id
}

// watchSharedDoorLogin reads the shared server's pg_roles every 50 ms from its own connection until the row ends; the
// function it returns stops the watch and gives the first time the door's role was a LOGIN role there ("" never). A
// role that already was a LOGIN role before the row (another run's) cannot be judged: said in the log, never failed.
func watchSharedDoorLogin(t *testing.T, shared string) func() string {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	c, err := pgx.Connect(ctx, shared)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	var readErrs atomic.Int64 // a read that fails is counted: a blind watch fails the row, never passes it
	login := func() bool {
		var l bool
		if err := c.QueryRow(ctx, `SELECT coalesce((SELECT rolcanlogin FROM pg_roles WHERE rolname = $1), false)`, doorRole).Scan(&l); err != nil && ctx.Err() == nil {
			readErrs.Add(1)
		}
		return l
	}
	if login() {
		t.Logf("HAZARD on the shared server: %s is already a LOGIN role there before the row (another run's?) - every migrate there stops at 0268 while it stays one; the watch cannot judge this row", doorRole)
		cancel()
		_ = c.Close(context.Background())
		return func() string { return "" }
	}
	var mu sync.Mutex
	first := ""
	done := make(chan struct{})
	go func() {
		defer close(done)
		tick := time.NewTicker(50 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				if login() {
					mu.Lock()
					if first == "" {
						first = time.Now().UTC().Format("15:04:05.000")
					}
					mu.Unlock()
				}
			}
		}
	}()
	var once sync.Once
	read := false
	stop := func() {
		once.Do(func() {
			cancel()
			<-done
			_ = c.Close(context.Background())
		})
	}
	// a row that fails before it reads the watch still stops it, and what the watch saw still fails the row
	t.Cleanup(func() {
		stop()
		mu.Lock()
		defer mu.Unlock()
		if !read && first != "" {
			t.Errorf("%s was a LOGIN role on the shared server of PGVIGIL_REPO_TEST_DSN at %s while the row ran", doorRole, first)
		}
		if n := readErrs.Load(); n > 0 {
			t.Errorf("the watch on the shared server failed %d read(s): it was blind for part of the row", n)
		}
	})
	return func() string {
		stop()
		mu.Lock()
		defer mu.Unlock()
		read = true
		return first
	}
}

// runDoorGuard is the guard row on the server of dsn: the door's role made a LOGIN role (and put back as found), a fresh
// database, its migrate refused at 0268 in the guard's words, the database left before 0268.
func runDoorGuard(t *testing.T, dsn string) {
	t.Helper()
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
	t.Cleanup(func() { _ = admin.Close(context.Background()) }) // registered first: it runs last
	// the role's undo before the change; it runs after the database's drop below
	t.Cleanup(func() {
		bg := context.Background()
		switch {
		case !had:
			if _, err := admin.Exec(bg, `DROP ROLE IF EXISTS `+id); err != nil {
				t.Logf("%s left on the server: %v", doorRole, err)
			}
		case !couldLogin:
			_, _ = admin.Exec(bg, `ALTER ROLE `+id+` NOLOGIN`)
		}
	})
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
		if _, err := admin.Exec(context.Background(), `DROP DATABASE IF EXISTS `+pgx.Identifier{name}.Sanitize()+` WITH (FORCE)`); err != nil {
			t.Errorf("drop %s: %v", name, err)
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
