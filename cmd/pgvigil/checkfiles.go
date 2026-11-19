package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// The 'secret files' part of 'pgvigil check' (RELNOTES L169; PerformanceMonitor 3.5.0's --harden-files, the lead's
// 04:29 (a)): every file of the configuration's folder that can hold a secret, judged by who may read it. check
// changes nothing: a FAIL prints its fix, and 'pgvigil install' run again re-applies the installer's own access.

// secretFileFolders hold secrets beside the configuration: the seals, the page's and the discovery sources'
// credentials, serve's own keys.
var secretFileFolders = []string{"secrets", "instances", "sources", "keys"}

// aclReader is one account an access list lets read a file: its SID and its name.
type aclReader struct{ SID, Name string }

// judgeMode judges a Linux mode: any bit for others is a FAIL; a group bit beyond read a WARN (a folder's group may
// traverse it); each with its chmod line.
func judgeMode(path string, mode fs.FileMode, dir bool) (string, string) {
	perm := mode.Perm()
	switch {
	case perm&0o007 != 0:
		return "FAIL", fmt.Sprintf("%s is open to every account of this host (mode %04o): chmod o-rwx %s", path, perm, path)
	case dir && perm&0o020 != 0:
		return "WARN", fmt.Sprintf("%s is writable by its group (mode %04o): chmod g-w %s", path, perm, path)
	case !dir && perm&0o030 != 0:
		return "WARN", fmt.Sprintf("%s is writable or runnable by its group (mode %04o): chmod g-wx %s", path, perm, path)
	}
	return "OK", ""
}

// judgeACL judges a Windows access list's readers: anyone not allowed (SYSTEM, the Administrators, the service's
// account) is a FAIL naming that reader and its icacls line.
func judgeACL(path string, readers []aclReader, allowed map[string]bool) (string, string) {
	var who, fix []string
	for _, r := range readers {
		if allowed[r.SID] {
			continue
		}
		who = append(who, r.Name)
		fix = append(fix, fmt.Sprintf(`icacls "%s" /remove:g *%s`, path, r.SID))
	}
	if len(who) == 0 {
		return "OK", ""
	}
	return "FAIL", fmt.Sprintf("%s is readable by %s: %s", path, strings.Join(who, ", "), strings.Join(fix, "; "))
}

// secretPaths lists the files of the configuration's folder that can hold a secret - the file, the installer's dsn
// files, everything under the four folders - and the folders themselves.
func secretPaths(cfgPath string) (files, dirs []string) {
	dir := filepath.Dir(cfgPath)
	dirs = append(dirs, dir)
	files = append(files, cfgPath)
	for _, f := range exportInstallerFiles {
		if st, err := os.Lstat(filepath.Join(dir, f)); err == nil && st.Mode().IsRegular() {
			files = append(files, filepath.Join(dir, f))
		}
	}
	for _, sub := range secretFileFolders {
		root := filepath.Join(dir, sub)
		_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
			switch {
			case err != nil:
				return nil
			case d.IsDir():
				dirs = append(dirs, p)
			case d.Type().IsRegular():
				files = append(files, p)
			}
			return nil
		})
	}
	return files, dirs
}

// secretFileRows is the part's rows: one for each file or folder exposed, or one OK row.
func secretFileRows(cfgPath string) []checkRow {
	files, dirs := secretPaths(cfgPath)
	var rows []checkRow
	for _, p := range append(append([]string(nil), dirs...), files...) {
		level, words, err := judgeHost(p, slices.Contains(dirs, p))
		switch {
		case err != nil:
			rows = append(rows, checkRow{"WARN", "secret files", fmt.Sprintf("%s: its access was not read: %v", p, err)})
		case level != "OK":
			rows = append(rows, checkRow{level, "secret files", words})
		}
	}
	if len(rows) == 0 {
		rows = append(rows, checkRow{"OK", "secret files", fmt.Sprintf("%d file(s) and %d folder(s) of %s: none open to other accounts", len(files), len(dirs), filepath.Dir(cfgPath))})
	}
	return rows
}
