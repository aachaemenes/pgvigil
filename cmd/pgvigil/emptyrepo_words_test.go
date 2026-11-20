package main

import (
	"errors"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestEmptyRepoDSNWords: a repository dsn that resolves to nothing is refused with its reason and no other fix (a
// reason is its own fix), or with the fresh install's fix when there is no reason; every command that opens the
// repository refuses through repoDSNOf in those words (a configuration error, exit 3), white space included.
func TestEmptyRepoDSNWords(t *testing.T) {
	t.Setenv("PGV_EMPTY_REPO", "")
	t.Setenv("PGV_BLANK_REPO", "  ")
	for _, c := range []struct {
		raw       string
		says, not []string
	}{
		{"env:PGV_EMPTY_REPO", []string{`"PGV_EMPTY_REPO" is empty`, "config /etc/pgvigil/pgvigil.yaml"}, []string{"fill in the env file"}},
		{"env:PGV_BLANK_REPO", []string{"holds only white space"}, []string{"fill in the env file"}},
	} {
		cfg := &config.Config{Repository: config.Repository{DSNRaw: c.raw}}
		_, err := repoDSNOf("/etc/pgvigil/pgvigil.yaml", cfg)
		var ce *configError
		if err == nil || !errors.As(err, &ce) {
			t.Errorf("%s: %v, want a configuration error", c.raw, err)
			continue
		}
		for _, w := range c.says {
			if !strings.Contains(err.Error(), w) {
				t.Errorf("%s: %q does not say %q", c.raw, err, w)
			}
		}
		for _, w := range c.not {
			if strings.Contains(err.Error(), w) {
				t.Errorf("%s: %q says %q", c.raw, err, w)
			}
		}
	}
	if err := emptyRepoDSN("", "file:/nowhere-but-no-reason"); err == nil || strings.Contains(err.Error(), "config ") {
		t.Errorf("no path: %v, want the words without the configuration's name", err)
	}
	t.Setenv("PGV_FULL_REPO", "host=h dbname=pgvigil")
	if d, err := repoDSNOf("x", &config.Config{Repository: config.Repository{DSNRaw: "env:PGV_FULL_REPO"}}); err != nil || d != "host=h dbname=pgvigil" {
		t.Errorf("a dsn that resolves: %q, %v", d, err)
	}
}
