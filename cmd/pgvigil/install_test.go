package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// install takes flags only; uninstall knows -purge, install knows -no-start and -user.
func TestParseInstallArgs(t *testing.T) {
	def := installOptions{Bin: "/b", Config: "/c", User: "u"}
	o, err := parseInstallArgs("install", []string{"-no-start", "-config", "/x/p.yaml"}, def)
	if err != nil || !o.NoStart || o.Config != "/x/p.yaml" || o.Bin != "/b" || o.User != "u" {
		t.Fatalf("install flags: %+v %v", o, err)
	}
	if _, err := parseInstallArgs("install", []string{"extra"}, def); err == nil || !strings.Contains(err.Error(), "flags only") {
		t.Fatalf("a positional argument was accepted: %v", err)
	}
	if _, err := parseInstallArgs("install", []string{"-user", ""}, def); err == nil {
		t.Fatal("an empty -user was accepted")
	}
	o, err = parseInstallArgs("uninstall", []string{"-purge"}, def)
	if err != nil || !o.Purge {
		t.Fatalf("uninstall -purge: %+v %v", o, err)
	}
	if _, err := parseInstallArgs("uninstall", []string{"-no-start"}, def); err == nil {
		t.Fatal("uninstall accepted -no-start")
	}
}

// The template the installer writes is a valid config with no instance, so the installer keeps the
// service down until one is added; a second install never overwrites an edited file.
func TestConfigTemplate(t *testing.T) {
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	wrote, err := writeIfAbsent(p, configTemplate("env:PGVIGIL_REPO_DSN"), 0o640)
	if err != nil || !wrote {
		t.Fatalf("first write: %v %v", wrote, err)
	}
	if ok, why := configNamesAnInstance(p); ok || !strings.Contains(why, "no instance") {
		t.Fatalf("template: ok=%v why=%q, want a valid config with no instance", ok, why)
	}
	if err := os.WriteFile(p, []byte("repository:\n  dsn: x\ninstances:\n  - name: a\n    dsn: y\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if wrote, err := writeIfAbsent(p, "overwritten", 0o640); err != nil || wrote {
		t.Fatalf("second write replaced the file: %v %v", wrote, err)
	}
	if ok, why := configNamesAnInstance(p); !ok {
		t.Fatalf("an edited config with one instance: %q", why)
	}
	if ok, why := configNamesAnInstance(filepath.Join(t.TempDir(), "missing.yaml")); ok || why == "" {
		t.Fatal("a missing config counted as ready")
	}
}
