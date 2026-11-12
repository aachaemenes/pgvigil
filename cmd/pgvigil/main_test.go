package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// collect -once refuses a config with no instance; run, migrate, serve and user accept one (run: Admin > Instances
// may hold every instance, task 204; a host that only serves the UI, the config of proof-auth.sh, the README's UI host).
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
	// the file's global schedules: reach Defaults (the stale check of an instance the page holds) and never Builtin
	// (the dialogs' default_s): statements at 30m, activity off
	g := &config.Config{Schedules: map[string]config.Duration{"statements": {Duration: 30 * time.Minute}, "activity": {}}}
	e = expectedIntervals(g)
	if e.Defaults["statements"] != 1800 || e.Defaults["activity"] != 0 || e.Builtin["activity"] != 60 || e.Builtin["statements"] == 1800 {
		t.Errorf("global schedules: defaults statements %d activity %d, builtin statements %d activity %d",
			e.Defaults["statements"], e.Defaults["activity"], e.Builtin["statements"], e.Builtin["activity"])
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

// run on the installer's template with its env variable unset ends as a configuration error, exit 3, which the unit
// (RestartPreventExitStatus=3) and the Windows service leave stopped: a host rebooted before the env file is filled
// in never loops (the join review of 204, finding 2).
func TestRunEmptyRepositoryDSNIsExit3(t *testing.T) {
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	if err := os.WriteFile(p, []byte(configTemplate("env:PGVIGIL_REPO_DSN")), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PGVIGIL_REPO_DSN", "")
	err := runScheduler(context.Background(), slog.New(slog.NewTextHandler(io.Discard, nil)), []string{"-config", p})
	var ec interface{ ExitCode() int }
	if !errors.As(err, &ec) || ec.ExitCode() != 3 || !strings.Contains(err.Error(), "resolves to nothing") {
		t.Fatalf("run with an empty repository dsn: %v (want a configuration error, exit 3)", err)
	}
}

// A custom: check loads over a file with no instance (the page may hold the instances it names; finding 1).
func TestCustomChecksOverNoFileInstance(t *testing.T) {
	p := filepath.Join(t.TempDir(), "c.yaml")
	y := "repository:\n  dsn: x\ninstances: []\ncustom:\n  - name: idle\n    sql: SELECT 1\n  - name: one\n    sql: SELECT 1\n    instances: [sql07]\n"
	if err := os.WriteFile(p, []byte(y), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := loadConfig([]string{"-config", p}, false); err != nil {
		t.Fatalf("custom checks over no file instance: %v", err)
	}
}
