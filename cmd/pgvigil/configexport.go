package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
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
	Config  string       `json:"config"` // the configuration file's name in that folder (pgvigil.yaml)
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

// exportRef is one file: or dpapi: reference among pgvigil.yaml's values, by its key path.
type exportRef struct{ Key, Kind, Path string }

// exportRefs are the references pgvigil.yaml's values hold, read from its YAML nodes (a comment is no reference, and a
// path may hold a space).
func exportRefs(raw []byte) ([]exportRef, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("the configuration is not valid YAML: %v", err)
	}
	var refs []exportRef
	var walk func(n *yaml.Node, path string)
	walk = func(n *yaml.Node, path string) {
		switch n.Kind {
		case yaml.DocumentNode:
			for _, c := range n.Content {
				walk(c, path)
			}
		case yaml.MappingNode:
			for i := 0; i+1 < len(n.Content); i += 2 {
				sub := n.Content[i].Value
				if path != "" {
					sub = path + "." + sub
				}
				walk(n.Content[i+1], sub)
			}
		case yaml.SequenceNode:
			for _, c := range n.Content {
				walk(c, path+".[]")
			}
		case yaml.ScalarNode:
			v := strings.TrimSpace(n.Value)
			for _, kind := range []string{"file:", "dpapi:"} {
				if strings.HasPrefix(v, kind) {
					refs = append(refs, exportRef{Key: path, Kind: kind, Path: strings.TrimPrefix(v, kind)})
				}
			}
		}
	}
	walk(&doc, "")
	return refs, nil
}

// exportLeftBehind names what an export of cfgPath does not carry and the new host needs, each by its key path: a
// file: reference outside the folder or not named whole (read from the service's working folder), a dpapi: blob outside
// the three folders, a folder of the three that is a link (the export follows none).
func exportLeftBehind(cfgPath string) ([]string, error) {
	dir, err := filepath.Abs(filepath.Dir(cfgPath))
	if err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		return nil, err
	}
	refs, err := exportRefs(raw)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, r := range refs {
		rel, inside := inFolder(dir, r.Path)
		switch {
		case !filepath.IsAbs(r.Path):
			out = append(out, fmt.Sprintf("not in the export: %s %s%s is not named whole (it is read from the service's working folder) - name it whole and copy it to the new host", r.Key, r.Kind, r.Path))
		case r.Kind == "file:" && !inside:
			out = append(out, fmt.Sprintf("not in the export: %s %s%s lies outside %s - copy it to the new host", r.Key, r.Kind, r.Path, dir))
		case r.Kind == "dpapi:" && (!inside || !inSecretFolder(rel)):
			out = append(out, fmt.Sprintf("not in the export: %s %s%s lies outside secrets/, instances/ and sources/ - seal it again on the new host (pgvigil secret seal)", r.Key, r.Kind, r.Path))
		}
	}
	for _, sub := range exportFolders {
		if st, err := os.Lstat(filepath.Join(dir, sub)); err == nil && st.Mode()&fs.ModeSymlink != 0 {
			out = append(out, fmt.Sprintf("not in the export: %s/ is a symbolic link (an export follows none) - copy what it holds to the new host", sub))
		}
	}
	return out, nil
}

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
	pl := exportPayload{Version: 1, Folder: dir, Config: filepath.Base(cfgPath), OS: runtime.GOOS}
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
	refs, err := exportRefs(text)
	if err != nil {
		return exportPayload{}, err
	}
	for _, r := range refs {
		if r.Kind != "file:" || !filepath.IsAbs(r.Path) {
			continue // a relative path is not carried (exportLeftBehind names it)
		}
		if rel, ok := inFolder(dir, r.Path); ok {
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
			// Explorer's own files in a folder (desktop.ini, Thumbs.db) are no secret and no DPAPI blob
			if d.Type().IsRegular() && !strings.EqualFold(d.Name(), "desktop.ini") && !strings.EqualFold(d.Name(), "thumbs.db") {
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
// channels' yaml tags); a channel's webhook url is its secret too (alerts.[].webhook.url).
var exportSecretKeys = map[string]bool{
	"password": true, "api_key": true, "bot_token": true, "client_secret": true, "routing_key": true,
	"signing_secret": true, "token": true, "sas_url": true, "webhook": true,
}

// pwKeys are the connection-string keys whose value is a secret: a password, ADO's pwd, libpq's sslpassword (the client
// key's passphrase).
var pwKeys = map[string]bool{"password": true, "pwd": true, "sslpassword": true}

// adoPassword is an ADO / ODBC ';'-separated string's password (SQL Server's connection strings).
var adoPassword = regexp.MustCompile(`(?i)(^|;)(\s*(?:password|pwd)\s*=\s*)("[^"]*"|'[^']*'|[^;]*)`)

// loosePassword and looseURLUser find a password in free text (a comment, a value under any key): a key=value form and
// a URL's user info.
var (
	loosePassword = regexp.MustCompile(`(?i)\b((?:ssl)?password|pwd)(\s*=\s*)('(?:[^'\\]|\\.)*'|"[^"]*"|\S*)`)
	looseURLUser  = regexp.MustCompile(`(?i)\b([a-z][a-z0-9+.-]*://[^/\s:@]*:)([^@\s]*)(@)`)
)

// maskDSN masks the secret parts of a connection string in each of its forms: a postgres:// / postgresql:// /
// sqlserver:// URL's user info and its password / pwd / sslpassword parameter, a libpq keyword string's secret values
// by libpq's own rules (maskLibpq), an ADO string's Password= / Pwd= (its values end at ';').
func maskDSN(v string) (string, bool) {
	lv := strings.ToLower(strings.TrimSpace(v))
	if strings.HasPrefix(lv, "postgres://") || strings.HasPrefix(lv, "postgresql://") || strings.HasPrefix(lv, "sqlserver://") {
		u, err := url.Parse(strings.TrimSpace(v))
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
			if pwKeys[strings.ToLower(k)] {
				q.Set(k, exportMask)
				changed = true
			}
		}
		if changed {
			u.RawQuery = q.Encode()
		}
		return u.String(), changed
	}
	if m, ok := maskLibpq(v); ok {
		return m, true
	}
	if adoPassword.MatchString(v) {
		return adoPassword.ReplaceAllString(v, "${1}${2}"+exportMask), true
	}
	return v, false
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

// maskLibpq masks the secret values of a libpq keyword string as libpq reads it: key = value pairs apart by white
// space, a value single-quoted (\' and \\ escaped inside) or running to the next white space not escaped by \ - so
// 'password=ab;cd' and 'password=ab\ cd' are one value each. Text that is no pair stops the read (copied as it is).
func maskLibpq(v string) (string, bool) {
	var b strings.Builder
	changed := false
	n := len(v)
	for i := 0; i < n; {
		if isSpace(v[i]) {
			b.WriteByte(v[i])
			i++
			continue
		}
		ks := i
		for i < n && v[i] != '=' && !isSpace(v[i]) {
			i++
		}
		key := v[ks:i]
		j := i
		for j < n && isSpace(v[j]) {
			j++
		}
		if j >= n || v[j] != '=' {
			b.WriteString(v[ks:])
			return b.String(), changed
		}
		j++
		for j < n && isSpace(v[j]) {
			j++
		}
		b.WriteString(v[ks:j])
		vs := j
		if j < n && v[j] == '\'' {
			for j++; j < n; j++ {
				if v[j] == '\\' && j+1 < n {
					j++
					continue
				}
				if v[j] == '\'' {
					j++
					break
				}
			}
		} else {
			for j < n && !isSpace(v[j]) {
				if v[j] == '\\' && j+1 < n {
					j++
				}
				j++
			}
		}
		if pwKeys[strings.ToLower(key)] {
			b.WriteString(exportMask)
			if strings.HasSuffix(v[vs:j], ";") { // an ADO string with spaces read as libpq keeps its separator
				b.WriteByte(';')
			}
			changed = true
		} else {
			b.WriteString(v[vs:j])
		}
		i = j
	}
	return b.String(), changed
}

// maskText masks a password in free text: a key=value form and a URL's user info.
func maskText(v string) (string, bool) {
	m := loosePassword.ReplaceAllString(v, "${1}${2}"+exportMask)
	m = looseURLUser.ReplaceAllString(m, "${1}"+exportMask+"${3}")
	return m, m != v
}

// exportNoSecrets is pgvigil.yaml for 'config export -no-secrets': each inline secret masked, the rest as written, a
// dpapi: reference marked not portable; notes name what was masked or marked by its key path, never a value.
func exportNoSecrets(raw []byte) ([]byte, []string, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, nil, fmt.Errorf("the configuration is not valid YAML: %v", err)
	}
	var notes []string
	// every comment of a node: a dsn moved to env: often leaves its old line behind as a comment (a comment above a
	// key belongs to the key's node)
	maskComments := func(n *yaml.Node, path string) {
		for _, c := range []*string{&n.HeadComment, &n.LineComment, &n.FootComment} {
			if m, changed := maskText(*c); changed {
				*c = m
				notes = append(notes, "masked (a password in a comment): "+path)
			}
		}
	}
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
				maskComments(n.Content[i], sub)
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
			case key == "dsn" || strings.HasSuffix(key, "_dsn") || key == "pgbouncer":
				if m, changed := maskDSN(v); changed {
					n.Value, n.Style = m, 0
					notes = append(notes, "masked (its password): "+path)
				}
			case exportSecretKeys[key] || (key == "url" && strings.HasPrefix(path, "alerts.")):
				n.Value, n.Style = exportMask, 0
				notes = append(notes, "masked: "+path)
			default:
				// a password under any other key (a value that is a connection string by its form)
				if m, changed := maskText(n.Value); changed {
					n.Value, n.Style = m, 0
					notes = append(notes, "masked (a password in its text): "+path)
				}
			}
		}
		maskComments(n, path)
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

// importWriter writes one file of an export at target, a fresh name beside the file's path in dir (importExport
// renames it into place once every file is written).
type importWriter func(dir string, f exportFile, target string) error

// pageFolder says whether a path of the export lies in the page's credential folders, which belong to the installed
// service's account (Admin > Instances' and the discovery sources' credentials).
func pageFolder(rel string) bool {
	return strings.HasPrefix(rel, "instances/") || strings.HasPrefix(rel, "sources/")
}

// noLinkBelow refuses a symbolic link on the way from dir to path (each folder below dir, and path itself when it
// exists): a write as root never follows one a less trusted account could have planted.
func noLinkBelow(dir, path string) error {
	rel, err := filepath.Rel(dir, path)
	if err != nil {
		return err
	}
	at := dir
	for _, part := range strings.Split(rel, string(filepath.Separator)) {
		at = filepath.Join(at, part)
		st, err := os.Lstat(at)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if st.Mode()&fs.ModeSymlink != 0 {
			return fmt.Errorf("%s is a symbolic link: refused (an import follows none)", at)
		}
	}
	return nil
}

// writeNewFile writes data to a file that must not exist yet (O_EXCL: never through a link), mode 0600; a write that
// fails part-way removes what it wrote.
func writeNewFile(path string, data []byte) error {
	fh, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	_, werr := fh.Write(data)
	cerr := fh.Close()
	if werr != nil || cerr != nil {
		_ = os.Remove(path)
		return errors.Join(werr, cerr)
	}
	return nil
}

// importWriteAs is this host's writer. The page's credential folders (instances/, sources/) belong to the installed
// service's account (account; "" = none installed): the folder made 0700 as it and each file 0600 as it
// (config.PrepareDirAs / OwnFileAs: the form 'instance add' and Admin > Instances write), so the page can still write
// there after a move; every other file takes its folder's owner and the installer's mode (config.OwnLikeFolder). A
// DPAPI entry is sealed at machine scope. No link is followed (noLinkBelow, writeNewFile).
func importWriteAs(account string) importWriter {
	return func(dir string, f exportFile, target string) error {
		final := filepath.Join(dir, filepath.FromSlash(f.Path))
		if err := noLinkBelow(dir, final); err != nil {
			return err
		}
		page := account != "" && pageFolder(f.Path)
		if parent := filepath.Dir(final); parent != dir {
			if err := os.MkdirAll(parent, 0o700); err != nil {
				return err
			}
			if page {
				if err := config.PrepareDirAs(parent, account); err != nil {
					return fmt.Errorf("the credential folder's access for %s: %w", account, err)
				}
			} else if err := config.OwnLikeFolder(parent); err != nil {
				return err
			}
		}
		if f.DPAPI {
			return config.SealDPAPIAt(target, string(f.Data))
		}
		if err := writeNewFile(target, f.Data); err != nil {
			return err
		}
		if page {
			return config.OwnFileAs(target, account)
		}
		return config.OwnLikeFolder(target)
	}
}

// importWrite writes as importWriteAs with no service account: every file its folder's (the rows; an import before
// any install).
var importWrite = importWriteAs("")

// importExport writes an export's files into cfgPath's folder (RELNOTES L155). Before any write: an export of this
// format and of this system (a Linux export holds no DPAPI blob and a Windows one no 0600 files: each written in its
// own host's form), its configuration's name, every path inside the folder, no DPAPI entry where this host cannot
// seal one (canSealDPAPI), the folder there (made by 'pgvigil install'), no file of the export there unless force, and
// no <file>.previous of an earlier import. Then every file is written to a fresh name beside its path; only when all
// are written does each go into place, a file it replaces kept as <file>.previous - a failure puts every file back.
// The notes say what the new host still has to do.
func importExport(pl exportPayload, cfgPath string, force bool, write importWriter, canSealDPAPI bool) ([]string, error) {
	dir, err := filepath.Abs(filepath.Dir(cfgPath))
	if err != nil {
		return nil, err
	}
	if pl.Version != 1 {
		return nil, fmt.Errorf("the export is of format %d, this build reads 1: nothing written", pl.Version)
	}
	if pl.OS != runtime.GOOS {
		return nil, fmt.Errorf("the export was made on %s and this host runs %s: each file is written in its host's form (a DPAPI blob on Windows, a 0600 file elsewhere), so an export moves between hosts of one system only; nothing written", osName(pl.OS), osName(runtime.GOOS))
	}
	if pl.Config != "" && pl.Config != filepath.Base(cfgPath) {
		return nil, fmt.Errorf("the export's configuration is %s: import it with -config %s; nothing written", pl.Config, filepath.Join(dir, pl.Config))
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
	var there []string
	for _, f := range pl.Files {
		full := filepath.Join(dir, filepath.FromSlash(f.Path))
		if _, err := os.Lstat(full + ".previous"); err == nil {
			return nil, fmt.Errorf("%s.previous is there from an earlier import (it may hold the configuration before it): move it away first; nothing written", f.Path)
		}
		if _, err := os.Lstat(full); err == nil {
			there = append(there, f.Path)
		}
	}
	if len(there) > 0 && !force {
		return nil, fmt.Errorf("%s already holds %s: import over them with -force (each file written over is kept as <file>.previous)", dir, strings.Join(there, ", "))
	}
	// every file to a fresh name first: a failure here changes nothing - its fresh files and the folders the writer
	// made for them (not there before, deepest first) are removed
	var made []string
	for _, f := range pl.Files {
		for d := filepath.Dir(filepath.Join(dir, filepath.FromSlash(f.Path))); d != dir && len(d) > len(dir); d = filepath.Dir(d) {
			if _, err := os.Lstat(d); errors.Is(err, fs.ErrNotExist) && !slices.Contains(made, d) {
				made = append(made, d)
			}
		}
	}
	sort.Slice(made, func(a, b int) bool { return len(made[a]) > len(made[b]) })
	temps := make([]string, len(pl.Files))
	dropTemps := func() {
		for _, t := range temps {
			if t != "" {
				_ = os.Remove(t)
			}
		}
		for _, d := range made {
			_ = os.Remove(d) // only an empty folder goes
		}
	}
	for i, f := range pl.Files {
		full := filepath.Join(dir, filepath.FromSlash(f.Path))
		var rnd [6]byte
		if _, err := rand.Read(rnd[:]); err != nil {
			dropTemps()
			return nil, err
		}
		t := full + ".import-" + hex.EncodeToString(rnd[:])
		if err := write(dir, f, t); err != nil {
			_ = os.Remove(t)
			dropTemps()
			return nil, fmt.Errorf("%s: %w (nothing was changed)", f.Path, err)
		}
		temps[i] = t
	}
	// then each into place; a failure puts every file placed so far back
	type placed struct {
		full string
		kept bool
	}
	var done []placed
	putBack := func() {
		for k := len(done) - 1; k >= 0; k-- {
			if done[k].kept {
				_ = os.Rename(done[k].full+".previous", done[k].full)
			} else {
				_ = os.Remove(done[k].full)
			}
		}
		dropTemps()
	}
	for i, f := range pl.Files {
		full := filepath.Join(dir, filepath.FromSlash(f.Path))
		kept := false
		if _, err := os.Lstat(full); err == nil {
			if err := os.Rename(full, full+".previous"); err != nil {
				putBack()
				return nil, fmt.Errorf("%s could not be kept as .previous: %w (every file put back)", f.Path, err)
			}
			kept = true
		}
		if err := os.Rename(temps[i], full); err != nil {
			if kept {
				_ = os.Rename(full+".previous", full)
			}
			putBack()
			return nil, fmt.Errorf("%s: %w (every file put back)", f.Path, err)
		}
		temps[i] = ""
		done = append(done, placed{full, kept})
	}
	var notes []string
	if !samePath(pl.Folder, dir) {
		notes = append(notes, fmt.Sprintf("the export came from %s and is now in %s: the repository's references to instances/ and sources/ (Admin > Instances' and the discovery sources' credentials) and every file: and dpapi: reference in %s still name %s - enter those credentials again in Admin > Instances and correct the references, or import into %s", pl.Folder, dir, pl.Config, pl.Folder, pl.Folder))
	}
	if sealed > 0 {
		notes = append(notes, fmt.Sprintf("%d DPAPI secret(s) sealed again at machine scope for this host", sealed))
	}
	return notes, nil
}

// osName is a GOOS as a person names it.
func osName(goos string) string {
	switch goos {
	case "windows":
		return "Windows"
	case "linux":
		return "Linux"
	case "darwin":
		return "macOS"
	}
	return goos
}
