package main

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestServeBasePathL55 (RELNOTES L55): 'pgvigil serve -base-path' wins over pgvigil.yaml's web.base_path and is held
// to the same words; neither set is the root.
func TestServeBasePathL55(t *testing.T) {
	cfg := &config.Config{Web: config.Web{BasePath: "/fromfile"}}
	for _, c := range []struct{ flag, want string }{{"", "/fromfile"}, {"/fromflag", "/fromflag"}} {
		got, err := serveBasePath(c.flag, cfg)
		if err != nil || got != c.want {
			t.Errorf("serveBasePath(%q) = %q, %v; want %q", c.flag, got, err, c.want)
		}
	}
	if got, err := serveBasePath("", &config.Config{}); err != nil || got != "" {
		t.Errorf("neither set: %q, %v; want the root", got, err)
	}
	if _, err := serveBasePath("bad/", cfg); err == nil {
		t.Error("a bad -base-path is taken")
	}
}
