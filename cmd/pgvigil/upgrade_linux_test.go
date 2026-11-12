//go:build linux

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The upgrade reads the installed unit's own paths and account (task 202, D8).

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

func TestEnvValue(t *testing.T) {
	f := filepath.Join(t.TempDir(), "pgvigil.env")
	if err := os.WriteFile(f, []byte("# the repository\nPGVIGIL_REPO_DSN=\nPGVIGIL_OTHER=x\nPGVIGIL_REPO_DSN=host=127.0.0.1 port=5432 user=pgvigil_agent password='a b' dbname=pgvigil\nQ=\"quoted value\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if v := envValue(f, "PGVIGIL_REPO_DSN"); v != "host=127.0.0.1 port=5432 user=pgvigil_agent password='a b' dbname=pgvigil" {
		t.Errorf("the DSN: %q", v)
	}
	if v := envValue(f, "Q"); v != "quoted value" {
		t.Errorf("a quoted value: %q", v)
	}
	if v := envValue(f, "MISSING"); v != "" {
		t.Errorf("a missing name: %q", v)
	}
	if v := envValue(filepath.Join(t.TempDir(), "none"), "PGVIGIL_REPO_DSN"); v != "" {
		t.Errorf("a missing file: %q", v)
	}
}
