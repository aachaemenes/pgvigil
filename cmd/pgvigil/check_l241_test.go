package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

// unsetEnv clears a variable for this test and restores it after.
func unsetEnv(t *testing.T, names ...string) {
	t.Helper()
	for _, n := range names {
		t.Setenv(n, "")
		if err := os.Unsetenv(n); err != nil {
			t.Fatal(err)
		}
	}
}

// TestCheckEmptyRepositoryDSNL241 (RELNOTES L241, a fault of check.go): a repository dsn whose reference resolves to
// nothing is a FAIL with the reason and exit 2, and nothing is connected - an empty dsn is libpq's defaults (PGHOST /
// PGPORT, else localhost, as this OS account), which a listener stands in for here.
func TestCheckEmptyRepositoryDSNL241(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()
	var hits atomic.Int32
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			hits.Add(1)
			_ = c.Close()
		}
	}()
	t.Setenv("PGHOST", "127.0.0.1")
	t.Setenv("PGPORT", strconv.Itoa(ln.Addr().(*net.TCPAddr).Port))
	t.Setenv("PGCONNECT_TIMEOUT", "2")
	unsetEnv(t, "L241_REPO_UNSET")
	p := checkYaml(t, t.TempDir(), "repository:\n  dsn: env:L241_REPO_UNSET\ninstances: []\n")
	rows, exit := checkRun(context.Background(), testLog(), p, nil)
	if exit != 2 {
		t.Errorf("exit %d, want 2; rows:\n%s", exit, rowsText(rows))
	}
	if !rowWith(rows, "FAIL", "repository", "L241_REPO_UNSET is not set") || rowWith(rows, "FAIL", "repository", "unreachable") {
		t.Errorf("want a FAIL repository row with the reference's reason, not a connect's:\n%s", rowsText(rows))
	}
	if n := hits.Load(); n != 0 {
		t.Errorf("an empty repository dsn connected %d time(s) to libpq's defaults", n)
	}
}

// TestCheckReferencesL241 (RELNOTES L241): every env: / file: / dpapi: reference of the file that resolves to nothing
// is one FAIL with config.WhyEmpty's words; one that resolves is no row of its own and its value is never printed; the
// repository's and the instances' dsn keep their own rows (never a second FAIL); a file whose references all resolve
// has one OK 'references' row.
func TestCheckReferencesL241(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	dir := t.TempDir()
	t.Setenv("L241_SET", "s3cr3t-L241-value")
	unsetEnv(t, "L241_REPORTS_UNSET", "L241_ALERTS_UNSET", "L241_DSN_UNSET")
	missing := filepath.Join(dir, "no-such-actions.dsn")
	sealed := filepath.Join(dir, "pgb.dpapi")
	if err := os.WriteFile(sealed, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := checkYaml(t, dir, fmt.Sprintf(`repository:
  dsn: "host=127.0.0.1 port=%d user=u dbname=d sslmode=disable connect_timeout=1"
reports_dsn: env:L241_REPORTS_UNSET
alerts_dsn: env:L241_ALERTS_UNSET
instances:
  - name: pg-refs
    dsn: env:L241_DSN_UNSET
    actions_dsn: file:%s
    explain_dsn: env:L241_SET
    pgbouncer: dpapi:%s
`, port, missing, sealed))
	rows, _ := checkRun(context.Background(), testLog(), p, nil)
	for _, c := range []struct{ what, words string }{
		{"reference reports_dsn", "L241_REPORTS_UNSET is not set"},
		{"reference alerts_dsn", "L241_ALERTS_UNSET is not set"},
		{"reference instances[pg-refs].actions_dsn", "cannot be read"},
		{"reference instances[pg-refs].pgbouncer", "did not open on this host"},
	} {
		if !rowWith(rows, "FAIL", c.what, c.words) {
			t.Errorf("no FAIL %q with %q:\n%s", c.what, c.words, rowsText(rows))
		}
	}
	text := rowsText(rows)
	if strings.Contains(text, "explain_dsn") {
		t.Errorf("a reference that resolves has no row:\n%s", text)
	}
	if strings.Contains(text, "s3cr3t-L241-value") {
		t.Errorf("a resolved value is printed:\n%s", text)
	}
	named := 0
	for _, r := range rows {
		if strings.Contains(r.What+r.Words, "L241_DSN_UNSET") {
			named++
		}
	}
	if named != 1 {
		t.Errorf("the instance's own dsn is in its own row only: %d rows name it:\n%s", named, text)
	}
	if rowWith(rows, "OK", "references", "") {
		t.Errorf("an OK references row beside failures:\n%s", text)
	}

	p2 := checkYaml(t, t.TempDir(), fmt.Sprintf("repository:\n  dsn: \"host=127.0.0.1 port=%d user=u dbname=d sslmode=disable connect_timeout=1\"\nreports_dsn: env:L241_SET\ninstances: []\n", port))
	rows2, _ := checkRun(context.Background(), testLog(), p2, nil)
	if !rowWith(rows2, "OK", "references", "resolves") || rowWith(rows2, "FAIL", "reference ", "") {
		t.Errorf("every reference resolves: one OK references row:\n%s", rowsText(rows2))
	}
}
