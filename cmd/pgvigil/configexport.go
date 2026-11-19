package main

import (
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"

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

// exportMask stands for a masked secret: plain letters, so a URL's user info carries it unescaped.
const exportMask = "MASKED"

// exportSecretKeys hold a secret as their whole value when it is not a reference (the configuration's and the alert
// channels' yaml tags); a channel's url is its webhook.
var exportSecretKeys = map[string]bool{
	"password": true, "api_key": true, "bot_token": true, "client_secret": true, "routing_key": true,
	"signing_secret": true, "token": true, "sas_url": true, "key": true, "webhook": true,
}

var dsnPassword = regexp.MustCompile(`(?i)\b(password|pwd)(\s*=\s*)('(?:[^'\\]|\\.)*'|"[^"]*"|[^\s;]*)`)

// maskDSN masks the password part of a connection string in each of its forms: a URL's user info and its password /
// pwd parameter, a libpq or ADO keyword string's password= / pwd=.
func maskDSN(v string) (string, bool) {
	if strings.Contains(v, "://") {
		u, err := url.Parse(v)
		if err != nil {
			return exportMask, true
		}
		changed := false
		if u.User != nil {
			if _, has := u.User.Password(); has {
				u.User, changed = url.UserPassword(u.User.Username(), exportMask), true
			}
		}
		q := u.Query()
		for k := range q {
			if lk := strings.ToLower(k); lk == "password" || lk == "pwd" {
				q.Set(k, exportMask)
				changed = true
			}
		}
		if changed {
			u.RawQuery = q.Encode()
		}
		return u.String(), changed
	}
	if !dsnPassword.MatchString(v) {
		return v, false
	}
	return dsnPassword.ReplaceAllString(v, "${1}${2}"+exportMask), true
}

// exportNoSecrets is pgvigil.yaml for 'config export -no-secrets': each inline secret masked, the rest as written, a
// dpapi: reference marked not portable; notes name what was masked or marked by its key path, never a value.
func exportNoSecrets(raw []byte) ([]byte, []string, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, nil, fmt.Errorf("the configuration is not valid YAML: %v", err)
	}
	var notes []string
	var walk func(n *yaml.Node, path, key string)
	walk = func(n *yaml.Node, path, key string) {
		switch n.Kind {
		case yaml.DocumentNode:
			for _, c := range n.Content {
				walk(c, path, key)
			}
		case yaml.MappingNode:
			for i := 0; i+1 < len(n.Content); i += 2 {
				k := n.Content[i].Value
				sub := k
				if path != "" {
					sub = path + "." + k
				}
				walk(n.Content[i+1], sub, k)
			}
		case yaml.SequenceNode:
			for _, c := range n.Content {
				walk(c, path+".[]", key)
			}
		case yaml.ScalarNode:
			v := strings.TrimSpace(n.Value)
			switch {
			case strings.HasPrefix(v, "dpapi:"):
				n.LineComment = "not portable: seal it again on the new host (pgvigil secret seal)"
				notes = append(notes, "not portable (dpapi:): "+path)
			case strings.HasPrefix(v, "env:") || strings.HasPrefix(v, "file:") || v == "":
			case key == "dsn" || strings.HasSuffix(key, "_dsn"):
				if m, changed := maskDSN(v); changed {
					n.Value, n.Style = m, 0
					notes = append(notes, "masked (its password): "+path)
				}
			case exportSecretKeys[key] || (key == "url" && strings.Contains(path, "channels")):
				n.Value, n.Style = exportMask, 0
				notes = append(notes, "masked: "+path)
			}
		}
	}
	walk(&doc, "", "")
	var b strings.Builder
	enc := yaml.NewEncoder(&b)
	enc.SetIndent(2)
	if err := enc.Encode(&doc); err != nil {
		return nil, nil, err
	}
	_ = enc.Close()
	return []byte(b.String()), notes, nil
}

// importWriter puts one file of an export into dir.
type importWriter func(dir string, f exportFile) error

// importWrite is this host's writer: the parent folder made with its folder's owner and mode, a DPAPI entry sealed at
// machine scope at its path, any other file written beside its path and renamed over it, then given its folder's
// owner and the installer's mode (config.OwnLikeFolder; on Windows the folder's access list is inherited).
func importWrite(dir string, f exportFile) error {
	full := filepath.Join(dir, filepath.FromSlash(f.Path))
	if parent := filepath.Dir(full); parent != dir {
		if err := os.MkdirAll(parent, 0o700); err != nil {
			return err
		}
		if err := config.OwnLikeFolder(parent); err != nil {
			return err
		}
	}
	if f.DPAPI {
		return config.SealDPAPIAt(full, string(f.Data))
	}
	tmp := full + ".new"
	if err := os.WriteFile(tmp, f.Data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, full); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return config.OwnLikeFolder(full)
}

// importExport writes an export's files into cfgPath's folder (RELNOTES L155). Before any write: every path inside
// the folder, no DPAPI entry where this host cannot seal one (canSealDPAPI), the folder there (made by 'pgvigil
// install'), and no configuration in it unless force - each file then written over is kept as <file>.previous. The
// notes say what the new host still has to do (another folder's path: the page's credentials, file: references).
func importExport(pl exportPayload, cfgPath string, force bool, write importWriter, canSealDPAPI bool) ([]string, error) {
	dir, err := filepath.Abs(filepath.Dir(cfgPath))
	if err != nil {
		return nil, err
	}
	sealed := 0
	for _, f := range pl.Files {
		if rel, ok := inFolder(dir, filepath.Join(dir, filepath.FromSlash(f.Path))); !ok || rel != f.Path {
			return nil, fmt.Errorf("the export names a path outside the configuration's folder (%q): refused, nothing written", f.Path)
		}
		if f.DPAPI {
			sealed++
		}
	}
	if sealed > 0 && !canSealDPAPI {
		return nil, fmt.Errorf("the export holds %d secret(s) sealed by DPAPI on a Windows host: import it on Windows, where each is sealed again for that machine; nothing written", sealed)
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return nil, fmt.Errorf("the folder %s does not exist: install pgvigil first ('pgvigil install' makes it and secures it), then import over its configuration with -force", dir)
	}
	if _, err := os.Stat(cfgPath); err == nil && !force {
		return nil, fmt.Errorf("%s already holds a configuration: import over it with -force (each file written over is kept as <file>.previous)", cfgPath)
	}
	for _, f := range pl.Files {
		full := filepath.Join(dir, filepath.FromSlash(f.Path))
		if _, err := os.Stat(full); err == nil {
			if err := os.Rename(full, full+".previous"); err != nil {
				return nil, fmt.Errorf("%s could not be kept as .previous: %w (nothing of it was written)", f.Path, err)
			}
		}
		if err := write(dir, f); err != nil {
			return nil, fmt.Errorf("%s: %w", f.Path, err)
		}
	}
	var notes []string
	if !samePath(pl.Folder, dir) {
		notes = append(notes, fmt.Sprintf("the export came from %s and is now in %s: the repository's references to instances/ and sources/ (Admin > Instances' and the discovery sources' credentials) and every file: reference in pgvigil.yaml still name %s - enter those credentials again in Admin > Instances and correct the references, or import into %s", pl.Folder, dir, pl.Folder, pl.Folder))
	}
	if sealed > 0 {
		notes = append(notes, fmt.Sprintf("%d DPAPI secret(s) sealed again at machine scope for this host", sealed))
	}
	return notes, nil
}
