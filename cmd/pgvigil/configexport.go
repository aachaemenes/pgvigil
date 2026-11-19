package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// A configuration export (RELNOTES L155; DBA Dash 4.23.0's Export Config): what a move to a new server carries.

// exportPayload is the sealed file's content: the source folder and its files.
type exportPayload struct {
	Version int          `json:"version"`
	Folder  string       `json:"folder"` // the configuration's folder on the host that exported it, absolute
	OS      string       `json:"os"`
	Files   []exportFile `json:"files"`
}

// exportFile is one file by its path in the folder (forward slashes), its mode and its content; DPAPI = the content
// is a secret opened from a machine-scope blob, sealed again on the importing host.
type exportFile struct {
	Path  string `json:"path"`
	Mode  uint32 `json:"mode"`
	DPAPI bool   `json:"dpapi,omitempty"`
	Data  []byte `json:"data"`
}

// exportFolders are the configuration's secret folders (internal/config/inventory.go): the one 'pgvigil secret seal' writes, and
// the page's Admin > Instances and discovery credentials, whose references the repository holds.
var exportFolders = []string{"secrets", "instances", "sources"}

// exportInstallerFiles are the installer's own secret files beside the configuration: the repository's dsn (Windows
// repo.dsn, reports.dsn; Linux pgvigil.env).
var exportInstallerFiles = []string{"repo.dsn", "reports.dsn", "pgvigil.env"}

var fileRef = regexp.MustCompile(`file:([^\s"'#]+)`)

// exportOpener reads one file for the export: its content and whether it was a DPAPI blob opened here.
type exportOpener func(path string) ([]byte, bool, error)

// collectExport gathers the configuration at cfgPath for an export: the file itself, the installer's dsn files, the
// files its file: references name inside the folder, and every file of the three folders. serve's keys/ stays out (a
// new host makes its own).
func collectExport(cfgPath string, open exportOpener) (exportPayload, error) {
	dir, err := filepath.Abs(filepath.Dir(cfgPath))
	if err != nil {
		return exportPayload{}, err
	}
	pl := exportPayload{Version: 1, Folder: dir, OS: runtime.GOOS}
	want := map[string]bool{filepath.Base(cfgPath): true}
	for _, f := range exportInstallerFiles {
		if st, err := os.Stat(filepath.Join(dir, f)); err == nil && st.Mode().IsRegular() {
			want[f] = true
		}
	}
	text, err := os.ReadFile(cfgPath)
	if err != nil {
		return exportPayload{}, err
	}
	for _, m := range fileRef.FindAllSubmatch(text, -1) {
		if rel, ok := inFolder(dir, string(m[1])); ok {
			want[rel] = true
		}
	}
	for _, sub := range exportFolders {
		root := filepath.Join(dir, sub)
		err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				if os.IsNotExist(err) && p == root {
					return filepath.SkipDir
				}
				return err
			}
			if d.Type().IsRegular() {
				rel, _ := filepath.Rel(dir, p)
				want[filepath.ToSlash(rel)] = true
			}
			return nil
		})
		if err != nil {
			return exportPayload{}, err
		}
	}
	paths := make([]string, 0, len(want))
	for p := range want {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, rel := range paths {
		full := filepath.Join(dir, filepath.FromSlash(rel))
		st, err := os.Stat(full)
		if err != nil {
			return exportPayload{}, fmt.Errorf("%s: %w", rel, err)
		}
		data, sealed, err := open(full)
		if err != nil {
			return exportPayload{}, fmt.Errorf("%s did not open on this host (%v): the export stops - seal it again here first, or remove it if nothing uses it", rel, err)
		}
		pl.Files = append(pl.Files, exportFile{Path: rel, Mode: uint32(st.Mode().Perm()), DPAPI: sealed, Data: data})
	}
	return pl, nil
}

// inFolder says whether path lies inside dir, and its path there with forward slashes.
func inFolder(dir, path string) (string, bool) {
	rel, err := filepath.Rel(dir, filepath.Clean(path))
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") || filepath.IsAbs(rel) {
		return "", false
	}
	return filepath.ToSlash(rel), true
}

// inSecretFolder says whether a path in the folder lies in one of the three secret folders.
func inSecretFolder(rel string) bool {
	for _, sub := range exportFolders {
		if strings.HasPrefix(rel, sub+"/") {
			return true
		}
	}
	return false
}

// exportOpen is this host's opener: on Windows each file of the three folders is a machine-scope DPAPI blob
// (config.WriteSecret, config.SealFileSecret) opened here; every other file is read as it is.
func exportOpen(dir string) exportOpener {
	return func(p string) ([]byte, bool, error) {
		if runtime.GOOS == "windows" {
			if rel, ok := inFolder(dir, p); ok && inSecretFolder(rel) {
				s, err := config.ResolveDPAPI(p)
				return []byte(s), true, err
			}
		}
		b, err := os.ReadFile(p)
		return b, false, err
	}
}
