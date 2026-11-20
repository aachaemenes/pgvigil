package main

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// checkYaml writes a pgvigil.yaml for 'pgvigil check' tests and returns its path. The folder is given the mode
// 'pgvigil install' gives the configuration's folder (0750, service_linux.go's cfgDir): t.TempDir makes it 0777 less
// the umask (0755 under 022), which check's 'secret files' part (L169) rightly fails as open to every account.
func checkYaml(t *testing.T, dir, body string) string {
	t.Helper()
	if err := os.Chmod(dir, 0o750); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "pgvigil.yaml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func rowWith(rows []checkRow, level, whatPart, wordsPart string) bool {
	for _, r := range rows {
		if r.Level == level && strings.Contains(r.What, whatPart) && strings.Contains(r.Words, wordsPart) {
			return true
		}
	}
	return false
}

func rowsText(rows []checkRow) string {
	var b strings.Builder
	for _, r := range rows {
		fmt.Fprintf(&b, "%s %s: %s\n", r.Level, r.What, r.Words)
	}
	return b.String()
}

// TestCheckConfigDoesNotLoad (L181, C2/C5): a configuration the loader refuses is one FAIL line with the loader's own
// error and exit 1.
func TestCheckConfigDoesNotLoad(t *testing.T) {
	p := checkYaml(t, t.TempDir(), "repository: [not, a, map\n")
	rows, exit := checkRun(context.Background(), testLog(), p, nil)
	if exit != 1 {
		t.Fatalf("exit %d, want 1; rows:\n%s", exit, rowsText(rows))
	}
	if !rowWith(rows, "FAIL", "configuration", "") {
		t.Errorf("no FAIL configuration row:\n%s", rowsText(rows))
	}
}

// checkStore makes this test's own migrated repository database and returns its dsn (skipped without
// PGVIGIL_REPO_TEST_DSN).
func checkStore(t *testing.T) string {
	t.Helper()
	base := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if base == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	name := fmt.Sprintf("rncheck_%d", rand.IntN(1_000_000_000))
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		_ = admin.Close(ctx)
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cctx, ccancel := context.WithTimeout(context.Background(), time.Minute)
		defer ccancel()
		_, _ = admin.Exec(cctx, "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)")
		_ = admin.Close(cctx)
	})
	cfg, err := pgx.ParseConfig(base)
	if err != nil {
		t.Fatal(err)
	}
	dsn := base
	if strings.Contains(dsn, "dbname=") {
		dsn = strings.ReplaceAll(dsn, "dbname="+cfg.Database, "dbname="+name)
	} else {
		dsn = dsn + " dbname=" + name
	}
	mcfg := checkYaml(t, t.TempDir(), "repository:\n  dsn: env:RNCHECK_DSN\ninstances: []\n")
	t.Setenv("RNCHECK_DSN", dsn)
	if err := runMigrate(ctx, testLog(), []string{"-config", mcfg}); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return dsn
}

func testLog() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
}

// TestCheckAllOK (L181, C3/C5): a loadable configuration with no instances on a store at this build's level is every
// row OK and exit 0; the repository row names the level and the size.
func TestCheckAllOK(t *testing.T) {
	dsn := checkStore(t)
	t.Setenv("RNCHECK_DSN", dsn)
	plentyFree(t)
	p := checkYaml(t, t.TempDir(), "repository:\n  dsn: env:RNCHECK_DSN\ninstances: []\n")
	rows, exit := checkRun(context.Background(), testLog(), p, nil)
	if exit != 0 {
		t.Fatalf("exit %d, want 0; rows:\n%s", exit, rowsText(rows))
	}
	if !rowWith(rows, "OK", "repository", "") {
		t.Errorf("no OK repository row:\n%s", rowsText(rows))
	}
}

// TestCheckStoreLevels (L181, C3): a store behind this build is a WARN naming 'pgvigil migrate' (exit 3); a store
// written by a newer pgvigil is a FAIL and exit 2.
func TestCheckStoreLevels(t *testing.T) {
	dsn := checkStore(t)
	t.Setenv("RNCHECK_DSN", dsn)
	p := checkYaml(t, t.TempDir(), "repository:\n  dsn: env:RNCHECK_DSN\ninstances: []\n")
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	c, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close(context.Background()) }()
	var top string
	if err := c.QueryRow(ctx, `SELECT max(version) FROM pgvigil.schema_version`).Scan(&top); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Exec(ctx, `DELETE FROM pgvigil.schema_version WHERE version = $1`, top); err != nil {
		t.Fatal(err)
	}
	rows, exit := checkRun(ctx, testLog(), p, nil)
	if exit != 3 || !rowWith(rows, "WARN", "repository", "pgvigil migrate") {
		t.Errorf("an older store: exit %d want 3, and a WARN repository row naming 'pgvigil migrate':\n%s", exit, rowsText(rows))
	}
	if _, err := c.Exec(ctx, `INSERT INTO pgvigil.schema_version (version) VALUES ('9999_from_the_future'), ($1)`, top); err != nil {
		t.Fatal(err)
	}
	rows, exit = checkRun(ctx, testLog(), p, nil)
	if exit != 2 || !rowWith(rows, "FAIL", "repository", "newer") {
		t.Errorf("a newer store: exit %d want 2, and a FAIL repository row saying newer:\n%s", exit, rowsText(rows))
	}
}

// TestCheckInlinePasswordWarns (L181 C2, L9): a PostgreSQL instance whose dsn carries an inline password still loads,
// and check WARNs on the instance naming the fix forms; with its connect failing too the exit is 3.
func TestCheckInlinePasswordWarns(t *testing.T) {
	dsn := checkStore(t)
	t.Setenv("RNCHECK_DSN", dsn)
	p := checkYaml(t, t.TempDir(), `repository:
  dsn: env:RNCHECK_DSN
instances:
  - name: pg-inline
    dsn: "host=127.0.0.1 port=9 user=u password=zz dbname=d sslmode=disable connect_timeout=1"
`)
	rows, exit := checkRun(context.Background(), testLog(), p, nil)
	if exit != 3 {
		t.Fatalf("exit %d, want 3; rows:\n%s", exit, rowsText(rows))
	}
	if !rowWith(rows, "WARN", "pg-inline", "password") {
		t.Errorf("no WARN row naming pg-inline's inline password:\n%s", rowsText(rows))
	}
	ok := false
	for _, w := range []string{"env:", "file:", "password_secret"} {
		if rowWith(rows, "WARN", "pg-inline", w) {
			ok = true
		}
	}
	if !ok {
		t.Errorf("the WARN names none of the fix forms (env:, file:, password_secret):\n%s", rowsText(rows))
	}
}

// TestCheckInstanceConnectFails (L181 C4): an instance nothing listens on is a FAIL row with the connection test's own
// words, and exit 3.
func TestCheckInstanceConnectFails(t *testing.T) {
	dsn := checkStore(t)
	t.Setenv("RNCHECK_DSN", dsn)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	p := checkYaml(t, t.TempDir(), fmt.Sprintf(`repository:
  dsn: env:RNCHECK_DSN
instances:
  - name: pg-down
    dsn: "host=127.0.0.1 port=%d user=u dbname=d sslmode=disable connect_timeout=1"
`, port))
	rows, exit := checkRun(context.Background(), testLog(), p, nil)
	if exit != 3 || !rowWith(rows, "FAIL", "pg-down", "") {
		t.Errorf("exit %d want 3 with a FAIL pg-down row:\n%s", exit, rowsText(rows))
	}
}

// TestCheckNoCollectionLeft (L181 C2): an instance whose schedules turn every collection off loads, and check WARNs
// that nothing is left to run there.
func TestCheckNoCollectionLeft(t *testing.T) {
	dsn := checkStore(t)
	t.Setenv("RNCHECK_DSN", dsn)
	var b strings.Builder
	b.WriteString("repository:\n  dsn: env:RNCHECK_DSN\ninstances:\n  - name: pg-idle\n    dsn: \"host=127.0.0.1 port=9 user=u dbname=d sslmode=disable connect_timeout=1\"\n    schedules:\n")
	for _, s := range pgSpecNames() {
		b.WriteString("      " + s + ": 0\n")
	}
	p := checkYaml(t, t.TempDir(), b.String())
	rows, exit := checkRun(context.Background(), testLog(), p, []string{"no-such-instance-filter-keeps-connects-out"})
	if exit != 3 || !rowWith(rows, "WARN", "pg-idle", "no collection") {
		t.Errorf("exit %d want 3 with a WARN pg-idle 'no collection left' row:\n%s", exit, rowsText(rows))
	}
}

// plentyFree (rn-l181 N6): the free-space read answers 1 TiB for the test, so the test box's own disk never turns a
// store on this host into a WARN (exit 3).
func plentyFree(t *testing.T) {
	t.Helper()
	old := upgradeHooksOf
	t.Cleanup(func() { upgradeHooksOf = old })
	h := upgradeHooks{}
	if old != nil {
		h = *old
	}
	h.freeBytes = func(string) (uint64, error) { return 1 << 40, nil }
	upgradeHooksOf = &h
}

// TestCheckAsTheCollectorLogin (rn-l181 B1): the configured repository login is the collector's (docs/acknowledge.md,
// README: it may execute the functions and read nothing) - check reads the level as 'run' does, through the
// functions, and a current store is an OK repository row and exit 0 for a LOGIN IN ROLE pgvigil_collector. Before the
// fold the level read SELECTed pgvigil.schema_version: permission denied, FAIL, exit 2 on a good install.
func TestCheckAsTheCollectorLogin(t *testing.T) {
	dsn := checkStore(t)
	plentyFree(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	role := fmt.Sprintf("rncheck_col_%d", rand.IntN(1_000_000_000))
	if _, err := admin.Exec(ctx, "CREATE ROLE "+role+" LOGIN PASSWORD 'rncheck' IN ROLE pgvigil_collector"); err != nil {
		_ = admin.Close(ctx)
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cctx, ccancel := context.WithTimeout(context.Background(), time.Minute)
		defer ccancel()
		_, _ = admin.Exec(cctx, "DROP ROLE IF EXISTS "+role)
		_ = admin.Close(cctx)
	})
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("RNCHECK_DSN", strings.Replace(dsn, "user="+cfg.User, "user="+role+" password=rncheck", 1))
	p := checkYaml(t, t.TempDir(), "repository:\n  dsn: env:RNCHECK_DSN\ninstances: []\n")
	rows, exit := checkRun(ctx, testLog(), p, nil)
	if exit != 0 || !rowWith(rows, "OK", "repository", "this build's level") {
		t.Errorf("as the collector's login: exit %d want 0, and an OK repository row at this build's level:\n%s", exit, rowsText(rows))
	}
}

// TestCheckPoolKeysInTheDSN (rn-l181 B2): README tells a site to cap the pool with pool_max_conns in the repository
// dsn; check parses it as the pool does, so the key never reaches the server as a startup parameter (FATAL
// 'unrecognized configuration parameter' before the fold: FAIL unreachable, exit 2).
func TestCheckPoolKeysInTheDSN(t *testing.T) {
	dsn := checkStore(t)
	plentyFree(t)
	t.Setenv("RNCHECK_DSN", dsn+" pool_max_conns=2")
	p := checkYaml(t, t.TempDir(), "repository:\n  dsn: env:RNCHECK_DSN\ninstances: []\n")
	rows, exit := checkRun(context.Background(), testLog(), p, nil)
	if exit != 0 || !rowWith(rows, "OK", "repository", "") {
		t.Errorf("a dsn with pool_max_conns: exit %d want 0 with an OK repository row:\n%s", exit, rowsText(rows))
	}
}

// TestCheckUnknownInstanceFails (rn-l181 S4): -instance naming no instance of the file or the page tests nothing -
// a FAIL row naming it and exit 3, never a silent exit 0 an install script would pass on.
func TestCheckUnknownInstanceFails(t *testing.T) {
	dsn := checkStore(t)
	plentyFree(t)
	t.Setenv("RNCHECK_DSN", dsn)
	p := checkYaml(t, t.TempDir(), "repository:\n  dsn: env:RNCHECK_DSN\ninstances: []\n")
	rows, exit := checkRun(context.Background(), testLog(), p, []string{"prod-db1"})
	if exit != 3 || !rowWith(rows, "FAIL", "instance prod-db1", "no instance of that name") {
		t.Errorf("-instance prod-db1 on a site without it: exit %d want 3 with a FAIL row naming it:\n%s", exit, rowsText(rows))
	}
}

// TestCheckAlertsBlockLoads (rn-l181 S1 a): the alerts: block loads as 'run' loads it - two channels of one name make
// 'run' exit 3, so check FAILs the configuration (exit 1) before anything else.
func TestCheckAlertsBlockLoads(t *testing.T) {
	p := checkYaml(t, t.TempDir(), "repository:\n  dsn: \"host=127.0.0.1 port=9 user=u dbname=d\"\ninstances: []\n"+
		"alerts:\n  - {name: a, kind: file, file: {dir: /tmp}}\n  - {name: a, kind: file, file: {dir: /tmp}}\n")
	rows, exit := checkRun(context.Background(), testLog(), p, nil)
	if exit != 1 || !rowWith(rows, "FAIL", "configuration", "listed twice") {
		t.Errorf("two alerts channels named a: exit %d want 1 with a FAIL configuration row:\n%s", exit, rowsText(rows))
	}
}

// TestCheckPositionalArgument (rn-l181 N8): 'pgvigil check /etc/pgvigil/pgvigil.yaml' is a usage error naming
// -config, never a check of ./pgvigil.yaml.
func TestCheckPositionalArgument(t *testing.T) {
	err := runCheck(context.Background(), testLog(), []string{"/etc/pgvigil/pgvigil.yaml"})
	if err == nil || !strings.Contains(err.Error(), "unexpected argument") || !strings.Contains(err.Error(), "-config") {
		t.Errorf("a positional argument: %v, want a usage error naming -config", err)
	}
}
