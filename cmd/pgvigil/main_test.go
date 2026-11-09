package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The collector commands refuse a config with no instance; serve accepts one (config.Validate).
func TestLoadConfigNeedsAnInstance(t *testing.T) {
	p := filepath.Join(t.TempDir(), "c.yaml")
	if err := os.WriteFile(p, []byte("repository:\n  dsn: x\ninstances: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, _, err := loadConfig([]string{"-config", p})
	if err == nil || !strings.Contains(err.Error(), "at least one instance") {
		t.Fatalf("got %v, want the at-least-one-instance error", err)
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
