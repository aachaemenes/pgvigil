package main

import (
	"io"
	"os"
	"strings"
	"testing"
)

// stderrOf runs f with os.Stderr on a pipe and returns what it wrote (the flag set's usage and the failure line go there).
func stderrOf(t *testing.T, f func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stderr
	os.Stderr = w
	got := make(chan string)
	go func() {
		b, _ := io.ReadAll(r)
		got <- string(b)
	}()
	defer func() { os.Stderr = old }()
	f()
	_ = w.Close()
	return <-got
}

// TestInstallHelpL131 (RELNOTES L131, DBA Dash 3.2's 'install --help'): 'pgvigil install -h' and 'pgvigil uninstall -h'
// print the flags and end with exit 0, no 'pgvigil failed' line; -user's help names what it means on each OS.
func TestInstallHelpL131(t *testing.T) {
	for _, name := range []string{"install", "uninstall"} {
		code := 0
		out := stderrOf(t, func() { code = run([]string{name, "-h"}) })
		if code != 0 {
			t.Errorf("pgvigil %s -h: exit %d, want 0", name, code)
		}
		if strings.Contains(out, "pgvigil failed") {
			t.Errorf("pgvigil %s -h logged a failure: %q", name, out)
		}
		for _, w := range []string{"-user", "-config", "Linux", "Windows", `NT SERVICE\pgvigil`, `DOMAIN\name$`, "gMSA"} {
			if !strings.Contains(out, w) {
				t.Errorf("pgvigil %s -h does not say %q:\n%s", name, w, out)
			}
		}
	}
}
