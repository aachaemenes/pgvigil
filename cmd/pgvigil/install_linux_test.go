//go:build linux

package main

import (
	"os"
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
