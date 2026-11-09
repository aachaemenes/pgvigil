package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The collector commands refuse a config with no instance; migrate, serve and user accept one
// (a host that only serves the UI, the config of proof-auth.sh and the README's UI host).
func TestLoadConfigNeedsAnInstance(t *testing.T) {
	p := filepath.Join(t.TempDir(), "c.yaml")
	if err := os.WriteFile(p, []byte("repository:\n  dsn: x\ninstances: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, _, err := loadConfig([]string{"-config", p}, true)
	if err == nil || !strings.Contains(err.Error(), "at least one instance") {
		t.Fatalf("collect: got %v, want the at-least-one-instance error", err)
	}
	if _, _, err := loadConfig([]string{"-config", p}, false); err != nil {
		t.Fatalf("migrate with no instance: %v", err)
	}
}

// A collection the instance's config gates off (logs and dms without an aws: block) is 0 in the stale
// check's expectations: no row is ever written for it, and a row an earlier build left must not go stale.
func TestExpectedIntervalsGated(t *testing.T) {
	cfg := &config.Config{Instances: []config.Instance{
		{Name: "plain"},
		{Name: "aws", AWS: &config.AWS{Cluster: "c", DMS: &config.DMS{Tasks: []string{"*"}}}},
	}}
	e := expectedIntervals(cfg)
	if e.Instances["plain"]["logs"] != 0 || e.Instances["plain"]["dms"] != 0 {
		t.Errorf("plain instance: logs %d dms %d, want 0 0", e.Instances["plain"]["logs"], e.Instances["plain"]["dms"])
	}
	if e.Instances["aws"]["logs"] != 60 || e.Instances["aws"]["dms"] != 60 {
		t.Errorf("aws instance: logs %d dms %d, want 60 60", e.Instances["aws"]["logs"], e.Instances["aws"]["dms"])
	}
	if e.Instances["plain"]["activity"] != 60 {
		t.Errorf("activity %d, want 60", e.Instances["plain"]["activity"])
	}
}

// `pgvigil user` takes the name before or after -config (Go's flag parsing stops at the first positional
// argument; the README writes the name first), lower-cases it, and refuses a missing or a second name.
func TestUserArgs(t *testing.T) {
	for _, c := range []struct {
		args             []string
		verb, name, path string
		bad              bool
	}{
		{[]string{"add", "Admin", "-config", "x.yaml"}, "add", "admin", "x.yaml", false},
		{[]string{"add", "-config", "x.yaml", "admin"}, "add", "admin", "x.yaml", false},
		{[]string{"list", "-config", "x.yaml"}, "list", "", "x.yaml", false},
		{[]string{"passwd", "bob"}, "passwd", "bob", "pgvigil.yaml", false},
		{[]string{"add"}, "", "", "", true},
		{[]string{"add", "a", "b"}, "", "", "", true},
		{[]string{"list", "a"}, "", "", "", true},
		{[]string{"drop", "a"}, "", "", "", true},
		{[]string{"add", "bad name"}, "", "", "", true},
		{[]string{"-config", "x"}, "", "", "", true},
	} {
		verb, name, path, err := userArgs(c.args)
		if (err != nil) != c.bad || verb != c.verb || name != c.name || path != c.path {
			t.Errorf("%v: got %q %q %q err=%v; want %q %q %q bad=%v", c.args, verb, name, path, err, c.verb, c.name, c.path, c.bad)
		}
	}
}
