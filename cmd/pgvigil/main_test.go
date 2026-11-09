package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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
