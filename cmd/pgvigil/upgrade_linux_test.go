//go:build linux

package main

import (
	"os"
	"path/filepath"
	"strings"
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

// The purge's env file: what the purge unit names (README's deploy/pgvigil-purge.service: EnvironmentFile=), README's
// place beside the config when the unit is gone or the file is there too (review w9d finding 3).
func TestPurgeEnvFiles(t *testing.T) {
	dir := t.TempDir()
	def := filepath.Join(dir, "pgvigil-purge.env")
	if got := purgeEnvFiles(filepath.Join(dir, "none.service"), def); strings.Join(got, ",") != def {
		t.Errorf("no unit: %v", got)
	}
	unit := filepath.Join(dir, "pgvigil-purge.service")
	if err := os.WriteFile(unit, []byte("[Service]\nEnvironmentFile=-/srv/purge.env\nEnvironmentFile=/srv/purge.env\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := purgeEnvFiles(unit, def); strings.Join(got, ",") != "/srv/purge.env" {
		t.Errorf("the unit's file: %v", got)
	}
	if err := os.WriteFile(def, []byte("PGVIGIL_REPO_DSN=x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := purgeEnvFiles(unit, def); strings.Join(got, ",") != "/srv/purge.env,"+def {
		t.Errorf("the unit's file and README's place: %v", got)
	}
}
