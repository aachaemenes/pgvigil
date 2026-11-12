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

// TestUnitEnvExtra (the join review w9e, finding 9, and its fold's review): the unit's other environment sources and
// the drop-ins that change what the service runs, as systemctl show prints them, are refused by name; the installer's
// own env file alone, unrelated variables and an unrelated drop-in pass.
func TestUnitEnvExtra(t *testing.T) {
	env := "/etc/pgvigil/pgvigil.env"
	files := map[string]string{
		"/etc/systemd/system/pgvigil.service.d/ip.conf":   "[Service]\nIPAddressAllow=10.0.0.0/8\n# ExecStart= in a comment\n",
		"/etc/systemd/system/pgvigil.service.d/exec.conf": "[Service]\nExecStart=\nExecStart=/usr/local/bin/pgvigil run -config /etc/pgvigil/prod.yaml\n",
		"/etc/systemd/system/pgvigil.service.d/user.conf": "[Service]\n  User = pgvprod\n",
	}
	read := func(f string) ([]byte, error) {
		if b, ok := files[f]; ok {
			return []byte(b), nil
		}
		return nil, os.ErrNotExist
	}
	base := "EnvironmentFiles=/etc/pgvigil/pgvigil.env (ignore_errors=no)\n"
	for _, c := range []struct {
		show, name, bad string
	}{
		{base + "Environment=\nDropInPaths=", "PGVIGIL_REPO_DSN", ""},
		{base + "Environment=GOMAXPROCS=2 TZ=UTC\nDropInPaths=/etc/systemd/system/pgvigil.service.d/ip.conf", "PGVIGIL_REPO_DSN", ""},
		{"Environment=\nDropInPaths=", "PGVIGIL_REPO_DSN", ""},
		{base + "EnvironmentFiles=/etc/pgvigil/prod.env (ignore_errors=yes)\nEnvironment=", "PGVIGIL_REPO_DSN", "EnvironmentFile=/etc/pgvigil/prod.env"},
		{base + "Environment=TZ=UTC PGVIGIL_REPO_DSN=host=x", "PGVIGIL_REPO_DSN", "Environment=PGVIGIL_REPO_DSN=..."},
		{base + "Environment=\"PGVIGIL_REPO_DSN=host=x user=y\"", "PGVIGIL_REPO_DSN", "Environment=PGVIGIL_REPO_DSN=..."},
		{base + "Environment=[unprintable]", "PGVIGIL_REPO_DSN", "an Environment= systemctl cannot print"},
		{base + "Environment=MY_PGVIGIL_REPO_DSN=x", "PGVIGIL_REPO_DSN", ""},
		{"EnvironmentFiles=/etc/pgvigil/prod.env (ignore_errors=yes)\nEnvironment=[unprintable]", "", ""}, // a file: dsn: no env source matters
		{base + "DropInPaths=/etc/systemd/system/pgvigil.service.d/exec.conf", "", "the drop-in /etc/systemd/system/pgvigil.service.d/exec.conf (ExecStart=)"},
		{base + "DropInPaths=/etc/systemd/system/pgvigil.service.d/ip.conf /etc/systemd/system/pgvigil.service.d/user.conf", "PGVIGIL_REPO_DSN", "the drop-in /etc/systemd/system/pgvigil.service.d/user.conf (User=)"},
		{base + "DropInPaths=/run/systemd/system/pgvigil.service.d/gone.conf", "", "(unreadable:"},
	} {
		err := unitEnvExtra(c.show, env, c.name, read)
		switch {
		case c.bad == "" && err != nil:
			t.Errorf("%q: %v", c.show, err)
		case c.bad != "" && (err == nil || !strings.Contains(err.Error(), c.bad)):
			t.Errorf("%q: want an error naming %q, got %v", c.show, c.bad, err)
		}
	}
}
