package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// exportFolder makes a configuration folder as the installer and the page leave it: pgvigil.yaml naming a sealed
// file, the repository's dsn file, the three folders, and two files an export leaves out (a note, serve's keys).
func exportFolder(t *testing.T) (dir, cfg string) {
	t.Helper()
	dir = filepath.Join(t.TempDir(), "pgvigil")
	files := map[string]string{
		"pgvigil.yaml":         "repository:\n  dsn: file:" + filepath.Join(dir, "repo.dsn") + "\ninstances:\n  - name: pg1\n    dsn: file:" + filepath.Join(dir, "secrets", "pg1-ab12.dsn") + "\n",
		"repo.dsn":             "host=repo user=pgvigil_collector password=repo-secret\n",
		"secrets/pg1-ab12.dsn": "host=pg1 user=mon password=pg1-secret\n",
		"instances/7.dsn":      "host=page7 user=mon password=page-secret\n",
		"sources/aws.json":     "{\"key\":\"source-secret\"}\n",
		"notes.txt":            "not the installer's\n",
		"keys/token.key":       "serve's own key, made again on a new host\n",
	}
	for p, body := range files {
		full := filepath.Join(dir, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	return dir, filepath.Join(dir, "pgvigil.yaml")
}

// TestExportPayloadL155 (the lead's 04:29 (2)): the payload is pgvigil.yaml, the installer's dsn files, the files its
// file: references name inside the folder and every file of secrets/, instances/ and sources/ - each by its path in
// the folder, its mode and its content, the folder's absolute path recorded; a note and serve's keys stay out. On
// Windows each file of the three folders is a DPAPI blob opened on this host (a test opener here), and one that does
// not open stops the export naming it.
func TestExportPayloadL155(t *testing.T) {
	dir, cfg := exportFolder(t)
	plainOpen := func(p string) ([]byte, bool, error) { b, err := os.ReadFile(p); return b, false, err }
	pl, err := collectExport(cfg, plainOpen)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, f := range pl.Files {
		got = append(got, f.Path)
		want, _ := os.ReadFile(filepath.Join(dir, filepath.FromSlash(f.Path)))
		if string(f.Data) != string(want) || f.Mode != 0o640 || f.DPAPI {
			t.Errorf("%s: data equal %v, mode %o, dpapi %v", f.Path, string(f.Data) == string(want), f.Mode, f.DPAPI)
		}
	}
	if w := "instances/7.dsn pgvigil.yaml repo.dsn secrets/pg1-ab12.dsn sources/aws.json"; strings.Join(got, " ") != w {
		t.Errorf("the payload's files %q, want %q", strings.Join(got, " "), w)
	}
	if abs, _ := filepath.Abs(dir); pl.Folder != abs {
		t.Errorf("the folder %q, want %q", pl.Folder, abs)
	}
	winOpen := func(p string) ([]byte, bool, error) {
		if strings.Contains(p, "sources") {
			return nil, false, errors.New("Key not valid for use in specified state.") //nolint:revive // CryptUnprotectData's own message, word for word
		}
		b, err := os.ReadFile(p)
		return append([]byte("opened:"), b...), true, err
	}
	if _, err := collectExport(cfg, winOpen); err == nil || !strings.Contains(err.Error(), "aws.json") || !strings.Contains(err.Error(), "did not open") {
		t.Errorf("a blob that does not open: %v, want the export stopped naming it", err)
	}
	winOpen2 := func(p string) ([]byte, bool, error) {
		b, err := os.ReadFile(p)
		inFolders := strings.Contains(p, string(os.PathSeparator)+"secrets"+string(os.PathSeparator)) || strings.Contains(p, "instances") || strings.Contains(p, "sources")
		if inFolders {
			return append([]byte("opened:"), b...), true, err
		}
		return b, false, err
	}
	pl, err = collectExport(cfg, winOpen2)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range pl.Files {
		inFolders := strings.HasPrefix(f.Path, "secrets/") || strings.HasPrefix(f.Path, "instances/") || strings.HasPrefix(f.Path, "sources/")
		if f.DPAPI != inFolders || (inFolders && !strings.HasPrefix(string(f.Data), "opened:")) {
			t.Errorf("%s: dpapi %v, data %q", f.Path, f.DPAPI, f.Data)
		}
	}
}
