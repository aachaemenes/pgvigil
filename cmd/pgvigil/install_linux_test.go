//go:build linux

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// deploy/pgvigil.service is the unit the installer writes with its defaults, kept in the repository
// for a hand install; the two must not drift.
func TestUnitMatchesDeployFile(t *testing.T) {
	want, err := os.ReadFile("../../deploy/pgvigil.service")
	if err != nil {
		t.Fatal(err)
	}
	d := defaultInstallOptions()
	got := renderUnit(d.Bin, d.Config, "/etc/pgvigil/pgvigil.env", d.User)
	if got != string(want) {
		t.Fatalf("deploy/pgvigil.service differs from the rendered unit:\n%s", got)
	}
}

// The installer names the one start failure an upgrade meets by design (the schema behind the new binary) with the
// file and the command left; any other failure points at the journal and is not called known.
func TestStartFailure(t *testing.T) {
	journal := "time=2026-11-11T13:00:01.000Z level=INFO msg=\"pgvigil starting\"\n" +
		"time=2026-11-11T13:00:01.200Z level=ERROR msg=\"pgvigil failed\" err=\"repository schema is behind this binary (needs 0089_alert_pagerduty.sql): run 'pgvigil migrate' as the repository owner\"\n"
	msg, known := startFailure(journal)
	if !known {
		t.Fatalf("the schema-behind start was not recognised: %q", msg)
	}
	for _, want := range []string{"the service did not come up", "0089_alert_pagerduty.sql", "pgvigil migrate", "starts by itself"} {
		if !strings.Contains(msg, want) {
			t.Errorf("the message lacks %q: %q", want, msg)
		}
	}
	if strings.Contains(msg, "\n") {
		t.Errorf("the message is more than one line: %q", msg)
	}
	for _, other := range []string{"", "level=ERROR msg=\"pgvigil failed\" err=\"repository: connection refused\"\n"} {
		msg, known := startFailure(other)
		if known || !strings.Contains(msg, "the service did not come up") || !strings.Contains(msg, "journalctl -u pgvigil") {
			t.Errorf("an unknown failure (%q): known=%v, %q", other, known, msg)
		}
	}
}

// install --remote's unit (R14): the hub unit's hardening with write access to the outbox and the state folder only
// (ReadWritePaths), ProtectSystem=strict and ProtectHome=yes kept, its own name, account and config so a box can run a hub
// collector beside it; deploy/pgvigil-remote.service is the same text for a hand install.
func TestRemoteUnitMatchesDeployFile(t *testing.T) {
	want, err := os.ReadFile("../../deploy/pgvigil-remote.service")
	if err != nil {
		t.Fatal(err)
	}
	got := renderRemoteUnit(remoteBin, remoteConfig, remoteEnvFile, remoteAccount, remoteOutbox, remoteStateDir)
	if got != string(want) {
		t.Errorf("the remote unit drifted from deploy/pgvigil-remote.service:\n%s", got)
	}
	for _, line := range []string{"ReadWritePaths=/var/lib/pgvigil-remote/outbox /var/lib/pgvigil-remote/state", "ProtectSystem=strict", "ProtectHome=yes",
		"User=pgvigil-remote", "ExecStart=/usr/local/bin/pgvigil-remote run -config /etc/pgvigil-remote/pgvigil-remote.yaml", "RestartPreventExitStatus=3"} {
		if !strings.Contains(got, line+"\n") {
			t.Errorf("the remote unit lacks %q", line)
		}
	}
	if remoteUnitPath == unitPath || remoteAccount == defaultInstallOptions().User || remoteBin == defaultInstallOptions().Bin {
		t.Errorf("the remote unit shares the hub collector's name, account or binary")
	}
}

// install -remote's folders: a parent it has to make (/var/lib/pgvigil-remote) is traversable by the service account
// (0755) - made with the outbox's 0750 and owned by root it locked the account out of its own folders and the collector
// exited 1 at start (proof-install's --remote run); the two folders keep their modes; an existing parent keeps its own.
func TestRemoteFolderParents(t *testing.T) {
	root := t.TempDir()
	parent := filepath.Join(root, "var", "lib", "pgvigil-remote")
	outbox, state := filepath.Join(parent, "outbox"), filepath.Join(parent, "state")
	if err := makeRemoteFolders(outbox, state, os.Getuid(), os.Getgid()); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		path string
		mode os.FileMode
	}{{filepath.Join(root, "var"), 0o755}, {filepath.Dir(parent), 0o755}, {parent, 0o755}, {outbox, 0o750}, {state, 0o700}} {
		if fi, err := os.Stat(c.path); err != nil || fi.Mode().Perm() != c.mode {
			t.Errorf("%s: mode %v, %v (want %v)", c.path, fi.Mode().Perm(), err, c.mode)
		}
	}
	shared := filepath.Join(root, "srv")
	if err := os.Mkdir(shared, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := makeRemoteFolders(filepath.Join(shared, "outbox"), filepath.Join(shared, "state"), os.Getuid(), os.Getgid()); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(shared); err != nil || fi.Mode().Perm() != 0o700 {
		t.Errorf("an existing parent's mode changed: %v %v", fi.Mode().Perm(), err)
	}
}

// A remote collector's folders are absolute and, under ProtectHome=yes, never under /home (refused at install, in words).
func TestRemoteFoldersChecked(t *testing.T) {
	for _, c := range []struct{ outbox, state, want string }{
		{"/var/lib/pgvigil-remote/outbox", "/var/lib/pgvigil-remote/state", ""},
		{"/home/ops/outbox", "/var/lib/pgvigil-remote/state", "ProtectHome"},
		{"/var/lib/pgvigil-remote/outbox", "/home/ops/state", "ProtectHome"},
		{"outbox", "/var/lib/pgvigil-remote/state", "absolute"},
		{"/var/lib/x", "/var/lib/x", "two folders"},
	} {
		err := checkRemoteFolders(c.outbox, c.state)
		if (c.want == "") != (err == nil) || (err != nil && !strings.Contains(err.Error(), c.want)) {
			t.Errorf("%s / %s: %v, want %q", c.outbox, c.state, err, c.want)
		}
	}
}
