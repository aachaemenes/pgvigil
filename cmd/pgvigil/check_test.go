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

// checkYaml writes a pgvigil.yaml for 'pgvigil check' tests and returns its path.
func checkYaml(t *testing.T, dir, body string) string {
	t.Helper()
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
