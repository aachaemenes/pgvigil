package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestResolveWhyL145 (RELNOTES L145, DBA Dash 3.25's start that cannot decrypt its config): a reference that resolves
// to nothing says why - the variable, the file and the OS's error, the dpapi: blob and its fix - and never what it
// read; Resolve's own answers are unchanged.
func TestResolveWhyL145(t *testing.T) {
	dir := t.TempDir()
	full, empty := filepath.Join(dir, "dsn"), filepath.Join(dir, "empty")
	if err := os.WriteFile(full, []byte("host=h user=u\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(empty, []byte("\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PGV_L145_SET", "host=h")
	t.Setenv("PGV_L145_EMPTY", "")
	os.Unsetenv("PGV_L145_UNSET")
	missing := filepath.Join(dir, "missing")
	for _, c := range []struct {
		ref, want string
		says      []string
	}{
		{"host=h user=u", "host=h user=u", nil},
		{"file:" + full, "host=h user=u", nil},
		{"env:PGV_L145_SET", "host=h", nil},
		{"file:" + missing, "", []string{missing, "no such file"}},
		{"file:" + empty, "", []string{empty, "is empty"}},
		{"env:PGV_L145_UNSET", "", []string{"PGV_L145_UNSET", "not set"}},
		{"env:PGV_L145_EMPTY", "", []string{"PGV_L145_EMPTY", "is empty"}},
		{"dpapi:" + missing, "", []string{missing, "did not open on this host", "pgvigil secret seal"}},
	} {
		got, err := ResolveWhy(c.ref)
		if got != c.want || got != Resolve(c.ref) {
			t.Errorf("%s: %q (Resolve %q), want %q", c.ref, got, Resolve(c.ref), c.want)
		}
		if c.says == nil {
			if err != nil || WhyEmpty(c.ref) != "" {
				t.Errorf("%s resolves, yet: %v / %q", c.ref, err, WhyEmpty(c.ref))
			}
			continue
		}
		if err == nil {
			t.Errorf("%s: no reason given", c.ref)
			continue
		}
		for _, w := range c.says {
			if !strings.Contains(err.Error(), w) || !strings.Contains(WhyEmpty(c.ref), w) {
				t.Errorf("%s: %q does not say %q", c.ref, err, w)
			}
		}
	}
}
