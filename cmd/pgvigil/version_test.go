package main

import (
	"crypto/fips140"
	"strings"
	"testing"
)

// The version line keeps "pgvigil <version>" as its first two words (the installers grep for them) and
// states the FIPS 140-3 mode the binary runs in, which follows the build (GOFIPS140) or GODEBUG=fips140.
func TestVersionLine(t *testing.T) {
	got := versionLine()
	if !strings.HasPrefix(got, "pgvigil "+version+" (") {
		t.Fatalf("version line does not start with the name and version: %q", got)
	}
	switch {
	case !fips140.Enabled() && !strings.Contains(got, "; fips140 off)"):
		t.Fatalf("a non-FIPS build must say fips140 off: %q", got)
	case fips140.Enabled() && !strings.Contains(got, "; fips140 on"):
		t.Fatalf("a FIPS build must say fips140 on: %q", got)
	case fips140.Enabled() && !strings.Contains(got, "(module "+fips140.Version()+")"):
		t.Fatalf("a FIPS build must name the module version %s: %q", fips140.Version(), got)
	case fips140.Enforced() && !strings.Contains(got, "on, enforced"):
		t.Fatalf("GODEBUG=fips140=only must read enforced: %q", got)
	}
}
