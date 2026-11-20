package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestConfigImportL155 (the lead's 04:29 (1), (2)): import writes every file of the export back at its path with the
// folder's mode, refuses a folder that holds a configuration unless -force (the old file kept as .previous), refuses a
// path outside the folder and - where DPAPI cannot seal - a DPAPI entry before any write, and says in words when the
// folder's path is not the exporting host's.
func TestConfigImportL155(t *testing.T) {
	src, srcCfg := exportFolder(t)
	plainOpen := func(p string) ([]byte, bool, error) { b, err := os.ReadFile(p); return b, false, err }
	pl, err := collectExport(srcCfg, plainOpen)
	if err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(t.TempDir(), "pgvigil")
	if err := os.Mkdir(dst, 0o750); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(dst, "pgvigil.yaml")
	notes, err := importExport(pl, cfg, false, importWrite, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range pl.Files {
		b, err := os.ReadFile(filepath.Join(dst, filepath.FromSlash(f.Path)))
		st, _ := os.Stat(filepath.Join(dst, filepath.FromSlash(f.Path)))
		if err != nil || string(b) != string(f.Data) || st.Mode().Perm() != 0o640 {
			t.Errorf("%s back: %v, equal %v, mode %v", f.Path, err, string(b) == string(f.Data), st.Mode().Perm())
		}
	}
	if !strings.Contains(strings.Join(notes, "\n"), src) || !strings.Contains(strings.Join(notes, "\n"), "Admin > Instances") {
		t.Errorf("another folder's path not said: %q", notes)
	}
	if _, err := importExport(pl, cfg, false, importWrite, false); err == nil || !strings.Contains(err.Error(), "-force") {
		t.Errorf("an import over a configuration without -force: %v", err)
	}
	if err := os.WriteFile(cfg, []byte("the old one\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := importExport(pl, cfg, true, importWrite, false); err != nil {
		t.Fatalf("-force: %v", err)
	}
	if b, _ := os.ReadFile(cfg + ".previous"); string(b) != "the old one\n" {
		t.Errorf("-force kept %q as .previous, want the old file", b)
	}
	// refusals before any write
	empty := filepath.Join(t.TempDir(), "pgvigil")
	if err := os.Mkdir(empty, 0o750); err != nil {
		t.Fatal(err)
	}
	bad := pl
	bad.Files = append(append([]exportFile(nil), pl.Files...), exportFile{Path: "../escape.dsn", Mode: 0o600, Data: []byte("x")})
	if _, err := importExport(bad, filepath.Join(empty, "pgvigil.yaml"), false, importWrite, false); err == nil || !strings.Contains(err.Error(), "outside") {
		t.Errorf("a path outside the folder: %v", err)
	}
	sealed := pl
	sealed.Files = append(append([]exportFile(nil), pl.Files...), exportFile{Path: "instances/9.dpapi", Mode: 0o600, DPAPI: true, Data: []byte("x")})
	if _, err := importExport(sealed, filepath.Join(empty, "pgvigil.yaml"), false, importWrite, false); err == nil || !strings.Contains(err.Error(), "Windows") {
		t.Errorf("a DPAPI entry where DPAPI cannot seal: %v", err)
	}
	if left, _ := os.ReadDir(empty); len(left) != 0 {
		t.Errorf("a refused import wrote %d entries", len(left))
	}
	var sealedPaths []string
	fake := func(dir string, f exportFile, target string) error {
		if f.DPAPI {
			sealedPaths = append(sealedPaths, f.Path)
			return os.WriteFile(target, []byte("sealed here"), 0o600)
		}
		return importWrite(dir, f, target)
	}
	if _, err := importExport(sealed, filepath.Join(empty, "pgvigil.yaml"), false, fake, true); err != nil || strings.Join(sealedPaths, " ") != "instances/9.dpapi" {
		t.Errorf("a DPAPI entry where DPAPI seals: %v, sealed %q", err, sealedPaths)
	}
	if _, err := os.Stat(filepath.Join(empty, "missing", "pgvigil.yaml")); err == nil {
		t.Fatal("impossible")
	}
	if _, err := importExport(pl, filepath.Join(empty, "missing", "pgvigil.yaml"), false, importWrite, false); err == nil || !strings.Contains(err.Error(), "pgvigil install") {
		t.Errorf("a folder that does not exist: %v, want 'install pgvigil first'", err)
	}
}
