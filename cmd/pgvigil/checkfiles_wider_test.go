//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestSecretFilesWider: the part judges the folder's other secret files (the purge's environment file, root's alone:
// a group bit is a FAIL there; an import's .previous), a file: reference outside the folder, a passfile a literal dsn
// names, a link by its target, the configuration folder's own mode (the installer's 0750; 0755 a FAIL), and says when
// the folder is not pgvigil's own, judging nothing of it.
func TestSecretFilesWider(t *testing.T) {
	dir, cfg := exportFolder(t)
	elsewhere := t.TempDir()
	outside := filepath.Join(elsewhere, "pg2.dsn")
	pass := filepath.Join(elsewhere, "pg.pass")
	linked := filepath.Join(elsewhere, "linked.dsn")
	for p, mode := range map[string]os.FileMode{outside: 0o644, pass: 0o644, linked: 0o644,
		filepath.Join(dir, "pgvigil-purge.env"): 0o640, filepath.Join(dir, "pgvigil.yaml.previous"): 0o644} {
		if err := os.WriteFile(p, []byte("x\n"), mode); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(p, mode); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(linked, filepath.Join(dir, "secrets", "link.dsn")); err != nil {
		t.Fatal(err)
	}
	text := "repository:\n  dsn: file:" + filepath.Join(dir, "repo.dsn") + "\ninstances:\n" +
		"  - name: pg2\n    dsn: file:" + outside + "\n" +
		"  - name: pg3\n    dsn: host=pg3 user=mon passfile=" + pass + "\n"
	if err := os.WriteFile(cfg, []byte(text), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var all []string
	for _, r := range secretFileRows(cfg) {
		all = append(all, r.Level+" "+r.Words)
	}
	got := strings.Join(all, "\n")
	for _, want := range []string{
		"FAIL " + filepath.Join(dir, "pgvigil-purge.env") + " is open to its group",
		"FAIL " + filepath.Join(dir, "pgvigil.yaml.previous"),
		"FAIL " + outside,
		"FAIL " + pass,
		filepath.Join(dir, "secrets", "link.dsn") + " is a link to " + linked,
		"chmod o-rwx " + linked,
		"FAIL " + dir + " is open to every account",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("the rows lack %q:\n%s", want, got)
		}
	}
	// a folder that is not pgvigil's own: said, and nothing of the folder judged or fixed
	shared := t.TempDir()
	scfg := filepath.Join(shared, "pgvigil.yaml")
	if err := os.WriteFile(scfg, []byte("repository:\n  dsn: env:X\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(shared, "hosts"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(shared, 0o755); err != nil {
		t.Fatal(err)
	}
	var srows []string
	for _, r := range secretFileRows(scfg) {
		srows = append(srows, r.Level+" "+r.Words)
	}
	sgot := strings.Join(srows, "\n")
	if !strings.Contains(sgot, "not pgvigil's own") || strings.Contains(sgot, "chmod o-rwx "+shared+"\n") || strings.HasSuffix(sgot, "chmod o-rwx "+shared) {
		t.Errorf("a shared folder: %s", sgot)
	}
}
