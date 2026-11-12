package main

import (
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

func TestParseUnit(t *testing.T) {
	o, found, err := parseUnit(renderUnit("/opt/pgv/bin/pgvigil", "/srv/pgv/etc/pgvigil/pgvigil.yaml", "/srv/pgv/etc/pgvigil/pgvigil.env", "svc_pgv"))
	if err != nil || !found {
		t.Fatalf("found %v err %v", found, err)
	}
	if o.Bin != "/opt/pgv/bin/pgvigil" || o.Config != "/srv/pgv/etc/pgvigil/pgvigil.yaml" || o.User != "svc_pgv" {
		t.Errorf("got %+v", o)
	}
	if _, _, err := parseUnit("[Service]\nExecStart=/usr/bin/other\n"); err == nil {
		t.Error("a foreign unit was taken for the installer's")
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
