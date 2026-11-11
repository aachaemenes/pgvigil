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
