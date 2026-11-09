package main

import (
	"errors"
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

// The installer owns the config's folder (permissions, -purge), so it takes a folder named pgvigil, a
// folder that does not exist yet, or one holding only its own files; anything else is refused.
func TestDedicatedFolder(t *testing.T) {
	root := t.TempDir()
	if err := dedicatedFolder(filepath.Join(root, "etc", "pgvigil"), "pgvigil.yaml"); err != nil {
		t.Errorf("a folder named pgvigil: %v", err)
	}
	if err := dedicatedFolder(filepath.Join(root, "missing"), "pgvigil.yaml"); err != nil {
		t.Errorf("a folder that does not exist yet: %v", err)
	}
	own := filepath.Join(root, "own")
	for _, f := range []string{"pgvigil.yaml", "pgvigil.env", "repo.dsn"} {
		if err := os.WriteFile(filepath.Join(own, f), nil, 0o600); err != nil && !errors.Is(err, os.ErrNotExist) {
			t.Fatal(err)
		} else if err != nil {
			_ = os.MkdirAll(own, 0o755)
			if err := os.WriteFile(filepath.Join(own, f), nil, 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := dedicatedFolder(own, "pgvigil.yaml"); err != nil {
		t.Errorf("a folder holding only the installer's files: %v", err)
	}
	if err := os.WriteFile(filepath.Join(own, "hosts"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := dedicatedFolder(own, "pgvigil.yaml"); err == nil || !strings.Contains(err.Error(), "hosts") {
		t.Errorf("a shared folder was accepted: %v", err)
	}
}

// A configuration-shape failure exits 3 (the unit's RestartPreventExitStatus), a runtime failure 1.
func TestConfigErrorExitCode(t *testing.T) {
	_, _, err := loadConfig([]string{"-config", filepath.Join(t.TempDir(), "none.yaml")}, false)
	var ec interface{ ExitCode() int }
	if err == nil || !errors.As(err, &ec) || ec.ExitCode() != 3 {
		t.Fatalf("a missing config: %v (want a configError with exit code 3)", err)
	}
	if code := run([]string{"run", "-config", filepath.Join(t.TempDir(), "none.yaml")}); code != 3 {
		t.Fatalf("run with a missing config exited %d, want 3", code)
	}
}
