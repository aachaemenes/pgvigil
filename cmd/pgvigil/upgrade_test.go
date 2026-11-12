package main

import (
	"errors"
	"io"
	"log/slog"
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

// uninstall -all's pure parts (task 203): the flags' rules, the role decisions, the plan and its order.

func TestUninstallFlags(t *testing.T) {
	def := installOptions{Bin: "/usr/local/bin/pgvigil", Config: "/etc/pgvigil/pgvigil.yaml", User: "pgvigil"}
	for _, c := range []struct {
		args []string
		bad  string
	}{
		{[]string{"-all"}, ""},
		{[]string{"-all", "-dry-run"}, ""},
		{[]string{"-all", "-drop-repository", "-confirm-database", "pgvigil", "-owner-dsn-file", "/root/o.dsn", "-dump", "/root/x.dump"}, ""},
		{[]string{"-all", "-drop-repository", "-no-dump"}, ""},
		{[]string{"-purge"}, ""},
		{[]string{"-dry-run"}, "go with -all"},
		{[]string{"-drop-repository"}, "go with -all"},
		{[]string{"-all", "-confirm-database", "pgvigil"}, "-confirm-database goes with -drop-repository only"},
		{[]string{"-all", "-owner-dsn-file", "/root/o.dsn"}, "-owner-dsn-file goes with -drop-repository only"},
		{[]string{"-purge", "-dump", "/root/x.dump"}, "-dump goes with -drop-repository only"},
		{[]string{"-all", "-drop-repository", "-no-dump", "-dump", "/x"}, "-no-dump does not go with"},
		{[]string{"-all", "-upgrade"}, "flag provided but not defined"},
		{[]string{"-all", "-drop-repository", "-owner-dsn-file", "/root/o.dsn", "-owner-dsn-env", "OWNER"}, "-owner-dsn-file and -owner-dsn-env both name"},
		{[]string{"-all", "-drop-repository", "-owner-dsn-env", "OWNER"}, ""},
		{[]string{"-all", "-drop-repository", "-pg-dump", "/usr/bin/pg_dump", "-no-dump"}, "-no-dump does not go with"},
	} {
		_, err := parseInstallArgs("uninstall", c.args, def)
		switch {
		case c.bad == "" && err != nil:
			t.Errorf("%v: %v", c.args, err)
		case c.bad != "" && (err == nil || !strings.Contains(err.Error(), c.bad)):
			t.Errorf("%v: want an error with %q, got %v", c.args, c.bad, err)
		}
	}
	// install keeps its own rules: the owner's flags go with -upgrade, -all is not an install flag
	if _, err := parseInstallArgs("install", []string{"-dump", "/x"}, def); err == nil || !strings.Contains(err.Error(), "goes with -upgrade only") {
		t.Errorf("install -dump without -upgrade: %v", err)
	}
	if _, err := parseInstallArgs("install", []string{"-all"}, def); err == nil {
		t.Error("install -all was accepted")
	}
}

func TestDecideGroup(t *testing.T) {
	for _, c := range []struct {
		f    roleFacts
		drop bool
		why  string
	}{
		{roleFacts{name: "pgvigil_reader"}, true, "a pgvigil group"},
		{roleFacts{name: "pgvigil_reader", memberOf: []string{"pgvigil_auth"}}, true, "a pgvigil group"},
		{roleFacts{name: "pgvigil_reader", memberOf: []string{"pg_monitor"}}, false, "a member of pg_monitor"},
		{roleFacts{name: "pgvigil_reader", usedIn: "pgvigil_eu"}, false, "used in pgvigil_eu"},
		{roleFacts{name: "pgvigil_reader", super: true}, false, "a superuser"},
		{roleFacts{name: "pgvigil_reader", isConnected: true}, false, "the role this uninstall connects as"},
	} {
		s := decideGroup(c.f)
		if s.drop != c.drop || !strings.Contains(s.why, c.why) {
			t.Errorf("%+v: got drop %v (%s), want %v (%s)", c.f, s.drop, s.why, c.drop, c.why)
		}
	}
}

func TestDecideLogin(t *testing.T) {
	all := map[string]bool{"pgvigil_collector": true, "pgvigil_reader": true, "pgvigil_auth": true, "pgvigil_alerter": true}
	some := map[string]bool{"pgvigil_collector": true, "pgvigil_reader": false}
	for _, c := range []struct {
		f       roleFacts
		dropped map[string]bool
		drop    bool
		why     string
	}{
		{roleFacts{name: "pgvigil_agent", memberOf: []string{"pgvigil_collector"}}, all, true, "the login this host's configuration names"},
		{roleFacts{name: "pgvigil_ui", memberOf: []string{"pgvigil_reader"}}, all, false, "not the login this host's configuration names"},
		{roleFacts{name: "pgvigil_agent", memberOf: []string{"pgvigil_collector", "pgvigil_reader"}}, some, false, "a member of pgvigil_reader, which stay"},
		{roleFacts{name: "pgvigil_agent", memberOf: []string{"pgvigil_collector", "app_rw"}}, all, false, "a member of app_rw"},
		{roleFacts{name: "pgvigil_agent", memberOf: []string{"pgvigil_collector"}, usedIn: "other_db"}, all, false, "used in other_db"},
		{roleFacts{name: "pgvigil_agent", memberOf: []string{"pgvigil_collector"}, sessionsIn: "other_db"}, all, false, "a session in other_db"},
		{roleFacts{name: "pgvigil_agent", memberOf: []string{"pgvigil_collector"}, super: true}, all, false, "a superuser"},
		{roleFacts{name: "pgvigil_agent", memberOf: []string{"pgvigil_collector"}, isConnected: true}, all, false, "connects as"},
	} {
		s := decideLogin(c.f, "pgvigil_agent", c.dropped)
		if s.drop != c.drop || !strings.Contains(s.why, c.why) || !s.login {
			t.Errorf("%+v: got drop %v (%s), want %v (%s)", c.f, s.drop, s.why, c.drop, c.why)
		}
	}
}

func TestPathWithout(t *testing.T) {
	for _, c := range []struct {
		in, dir, out string
		found        bool
	}{
		{`C:\Windows;C:\Program Files\pgvigil;C:\Tools`, `C:\Program Files\pgvigil`, `C:\Windows;C:\Tools`, true},
		{`C:\Windows;c:\program files\PGVIGIL\;C:\Tools`, `C:\Program Files\pgvigil`, `C:\Windows;C:\Tools`, true},
		{`C:\Windows;C:\Tools`, `C:\Program Files\pgvigil`, `C:\Windows;C:\Tools`, false},
		{`C:\Program Files\pgvigil-old;C:\Tools`, `C:\Program Files\pgvigil`, `C:\Program Files\pgvigil-old;C:\Tools`, false},
	} {
		out, found := pathWithout(c.in, c.dir)
		if out != c.out || found != c.found {
			t.Errorf("%q: got %q %v, want %q %v", c.in, out, found, c.out, c.found)
		}
	}
}

// captureStdout runs f and returns what it printed.
func captureStdout(t *testing.T, f func() error) (string, error) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w
	done := make(chan string)
	go func() { b, _ := io.ReadAll(r); done <- string(b) }()
	ferr := f()
	os.Stdout = old
	_ = w.Close()
	return <-done, ferr
}

func TestUninstallAllOrder(t *testing.T) {
	oldU, oldH := uninstallHooksOf, upgradeHooksOf
	defer func() { uninstallHooksOf, upgradeHooksOf = oldU, oldH }()
	var removed []string
	stopped, privErr := 0, error(nil)
	items := func(present bool) []removal {
		rm := func(n string) func() error { return func() error { removed = append(removed, n); return nil } }
		return []removal{
			{what: "the service", present: present, remove: rm("service")},
			{what: "the binary", present: present, remove: rm("binary")},
			{what: "the dump folder", present: present, kept: "the repository's dumps", remove: rm("dumps")},
			{what: "the account", present: present, remove: rm("account")},
		}
	}
	present := true
	var others []string
	upgradeHooksOf = &upgradeHooks{
		installed: func() (installOptions, bool, error) { return installOptions{}, false, nil },
		stop:      func(*slog.Logger) error { stopped++; return nil },
		start:     func(*slog.Logger) error { return nil },
		others:    func(string) ([]string, error) { return others, nil },
		previous:  func(bin string) string { return bin + ".previous" },
	}
	uninstallHooksOf = &uninstallHooks{
		privileged: func() error { return privErr },
		running:    func() bool { return present },
		items:      func(installOptions, bool) []removal { return items(present) },
		repoDSN: func(installOptions) (string, bool, error) {
			return "host=db port=5432 user=pgvigil_agent dbname=pgvigil", true, nil
		},
	}
	log := slog.New(slog.DiscardHandler)
	o := installOptions{All: true, Bin: "/usr/local/bin/pgvigil", Config: "/etc/pgvigil/pgvigil.yaml", User: "pgvigil", set: map[string]bool{}}

	dry := o
	dry.DryRun = true
	out, err := captureStdout(t, func() error { return runUninstallAll(log, dry) })
	if err != nil || len(removed) != 0 || stopped != 0 || !strings.Contains(out, "dry run: nothing was changed") || !strings.Contains(out, "remove   the service") ||
		!strings.Contains(out, "kept     the dump folder: the repository's dumps") || !strings.Contains(out, "pgvigil on db:5432") {
		t.Fatalf("dry run: err %v, removed %v, stopped %d:\n%s", err, removed, stopped, out)
	}
	out, err = captureStdout(t, func() error { return runUninstallAll(log, o) })
	if err != nil || strings.Join(removed, ",") != "service,binary,account" || stopped != 1 || !strings.Contains(out, "kept: the dump folder: the repository's dumps") {
		t.Fatalf("the run: err %v, removed %v, stopped %d:\n%s", err, removed, stopped, out)
	}
	present, removed = false, nil
	out, err = captureStdout(t, func() error { return runUninstallAll(log, o) })
	if err != nil || len(removed) != 0 || stopped != 1 || !strings.Contains(out, "nothing of pgvigil is left to remove") {
		t.Fatalf("the second run: err %v, removed %v, stopped %d:\n%s", err, removed, stopped, out)
	}
	// another pgvigil process on the installed binary (a serve by hand): refused before any change; the dry run lists it
	present, removed, others = true, nil, []string{"pid 4242: /usr/local/bin/pgvigil serve -config /etc/pgvigil/pgvigil.yaml"}
	stoppedBefore := stopped
	if _, err = captureStdout(t, func() error { return runUninstallAll(log, o) }); err == nil || !strings.Contains(err.Error(), "uninstall refused, nothing was changed: other processes run the installed binary") ||
		!strings.Contains(err.Error(), "pid 4242") || len(removed) != 0 || stopped != stoppedBefore {
		t.Fatalf("a serve on the installed binary: err %v, removed %v, stopped %d", err, removed, stopped-stoppedBefore)
	}
	out, err = captureStdout(t, func() error { return runUninstallAll(log, dry) })
	if err != nil || !strings.Contains(out, "running  pid 4242: /usr/local/bin/pgvigil serve") || len(removed) != 0 {
		t.Fatalf("the dry run with a serve running: err %v:\n%s", err, out)
	}
	others = nil
	privErr = errors.New("uninstall -all needs root")
	if _, err = captureStdout(t, func() error { return runUninstallAll(log, o) }); err == nil || !strings.Contains(err.Error(), "uninstall refused, nothing was changed") {
		t.Fatalf("not root: %v", err)
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
