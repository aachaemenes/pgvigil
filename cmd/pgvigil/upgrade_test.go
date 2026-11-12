package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// install -upgrade's pure parts (task 202): the owner's password kept off pg_dump's command line, the flags' rules.

func TestSplitPassword(t *testing.T) {
	for _, c := range []struct{ in, conn, pw string }{
		{"host=db port=5432 user=owner password=s3cret dbname=pgvigil", "host=db port=5432 user=owner dbname=pgvigil", "s3cret"},
		{"host=db user=owner password='a b\\'c' dbname=pgvigil sslmode=verify-full", "host=db user=owner dbname=pgvigil sslmode=verify-full", "a b'c"},
		{"host = db  user=owner dbname=pgvigil", "host=db user=owner dbname=pgvigil", ""},
		{"postgres://owner:p%40ss@db:5432/pgvigil?sslmode=require", "postgres://owner@db:5432/pgvigil?sslmode=require", "p@ss"},
		{"postgresql://owner@db/pgvigil?password=x%3Ay&sslmode=disable", "postgresql://owner@db/pgvigil?sslmode=disable", "x:y"},
		{"dbname='my db' user=o", "dbname='my db' user=o", ""},
	} {
		conn, pw, err := splitPassword(c.in)
		if err != nil {
			t.Errorf("%q: %v", c.in, err)
			continue
		}
		if conn != c.conn || pw != c.pw {
			t.Errorf("%q: got (%q, %q), want (%q, %q)", c.in, conn, pw, c.conn, c.pw)
		}
		if pw != "" && strings.Contains(conn, pw) {
			t.Errorf("%q: the password is still in %q", c.in, conn)
		}
	}
	for _, bad := range []string{"host=db password='open", "justaword"} {
		if _, _, err := splitPassword(bad); err == nil {
			t.Errorf("%q: no error", bad)
		}
	}
}

func TestPgpassEscape(t *testing.T) {
	if got := pgpassEscape(`a:b\c`); got != `a\:b\\c` {
		t.Errorf("got %q", got)
	}
}

func TestUpgradeFlags(t *testing.T) {
	def := installOptions{Bin: "/usr/local/bin/pgvigil", Config: "/etc/pgvigil/pgvigil.yaml", User: "pgvigil"}
	o, err := parseInstallArgs("install", []string{"-upgrade", "-owner-dsn-file", "/root/owner.dsn", "-bin", "/opt/x"}, def)
	if err != nil {
		t.Fatal(err)
	}
	if !o.Upgrade || o.OwnerDSNFile != "/root/owner.dsn" || o.OwnerDSNEnv != "PGVIGIL_OWNER_DSN" || !o.set["bin"] || o.set["config"] {
		t.Errorf("got %+v", o)
	}
	for _, args := range [][]string{
		{"-dump", "/x.dump"},                          // an upgrade flag without -upgrade
		{"-upgrade", "-no-start"},                     // the upgrade starts what it stopped
		{"-upgrade", "-no-dump", "-dump", "/x.dump"},  // no dump and a dump file
		{"-upgrade", "-no-dump", "-pg-dump", "/x/pd"}, // no dump and a pg_dump
	} {
		if _, err := parseInstallArgs("install", args, def); err == nil {
			t.Errorf("%v: accepted", args)
		}
	}
}

func TestPgDumpVersionLine(t *testing.T) {
	for line, want := range map[string]string{
		"pg_dump (PostgreSQL) 15.10 (Debian 15.10-0+deb12u1)\n": "15",
		"pg_dump (PostgreSQL) 17.2\n":                           "17",
		"pg_dump (PostgreSQL) 9.6.24\n":                         "9",
	} {
		m := pgDumpVersion.FindStringSubmatch(line)
		if m == nil || m[1] != want {
			t.Errorf("%q: got %v, want %s", line, m, want)
		}
	}
}

func TestPreviousNameLinux(t *testing.T) {
	if upgradeHooksOf == nil {
		t.Skip("no upgrade on this platform")
	}
	if got := upgradeHooksOf.previous("/usr/local/bin/pgvigil"); got != "/usr/local/bin/pgvigil.previous" && !strings.HasSuffix(got, ".previous.exe") {
		t.Errorf("got %q", got)
	}
}

// The page's credential folders (task 204) beside a config in a folder not named pgvigil are the installer's own: an
// upgrade's folder check passes them and refuses anything else (the join review of 202, finding 2).
func TestDedicatedFolderCredentials(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "pgvconf")
	for _, d := range []string{"instances", "sources"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, d, "x.dsn"), []byte("host=x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"pgvigil.yaml", "pgvigil.env"} {
		if err := os.WriteFile(filepath.Join(dir, f), nil, 0o640); err != nil {
			t.Fatal(err)
		}
	}
	if err := dedicatedFolder(dir, "pgvigil.yaml"); err != nil {
		t.Fatalf("the credential folders were refused: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "notes.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := dedicatedFolder(dir, "pgvigil.yaml"); err == nil || !strings.Contains(err.Error(), "holds other files (notes.txt)") {
		t.Fatalf("a foreign file: %v", err)
	}
}
