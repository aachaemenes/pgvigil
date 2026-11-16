//go:build linux

package main

import (
	"os"
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
