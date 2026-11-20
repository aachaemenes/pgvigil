package main

import (
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// The 'secret files' part of 'pgvigil check' (RELNOTES L169; PerformanceMonitor 3.5.0's --harden-files, the lead's
// 04:29 (a)): every file that can hold a secret, judged by who may read it. check changes nothing: a FAIL prints its
// fix (on Windows 'pgvigil install' run again also re-applies the folder's list).

// secretFileFolders hold secrets beside the configuration: the seals and the page's and the discovery sources'
// credentials.
var secretFileFolders = []string{"secrets", "instances", "sources"}

// secretRootFiles are the folder's other files that can hold a secret: the purge's and the export's environment files
// (the repository owner's dsn), the Windows purge task's configuration, a TLS key 'pgvigil cert -out' wrote there.
var secretRootFiles = []string{"pgvigil-purge.env", "pgvigil-export.env", "pgvigil-purge.yaml", "pgvigil.key"}

// ownerOnlyFiles hold the repository owner's credential: root's alone (0600 root:root), so a group bit is a FAIL there.
var ownerOnlyFiles = map[string]bool{"pgvigil-purge.env": true, "pgvigil-export.env": true}

// secretPath is one path the part judges: whether it is a folder, whether it holds the repository owner's credential,
// whether it lies in the page's credential folders (instances/, sources/: the account serve runs as reads them).
type secretPath struct {
	Path                 string
	Dir, OwnerOnly, Page bool
}

// aclReader is one access-list entry an account holds on a path: its SID, its name (Resolved: read from the SID),
// whether it may change the file (Write: its data, its list or its owner) and whether the entry is inherited.
type aclReader struct {
	SID, Name                  string
	Resolved, Write, Inherited bool
}

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

// fixLines puts one command a line under a row (cmd.exe reads no ';' between commands).
func fixLines(fixes []string) string {
	if len(fixes) == 0 {
		return ""
	}
	return "\n      " + strings.Join(fixes, "\n      ")
}

// icaclsPath is a path as icacls is given it in double quotes: a trailing backslash (a drive's root) doubled, or cmd.exe
// reads \" as an escaped quote.
func icaclsPath(path string) string {
	if strings.HasSuffix(path, `\`) {
		return path + `\`
	}
	return path
}

// judgeACL judges a Windows access list's entries against the allowed (SYSTEM, the Administrators, the service's
// account): a SID that names many accounts (Users, Everyone, Authenticated Users ...) is a FAIL - an inherited one
// says where it comes from and that 'pgvigil install' run again protects the folder (a per-file remove changes nothing
// there); a single account that may change a file outside the page's folders is a FAIL; any other single account is a
// WARN without a remove line (in the page's credential folders it is most likely the account serve runs as, which the
// page grants on purpose), and so is a SID that does not resolve here (removing it could remove the service's own).
func judgeACL(path string, readers []aclReader, allowed map[string]bool, page bool) (string, string) {
	level := "OK"
	raise := func(l string) {
		if l == "FAIL" || level == "OK" {
			level = l
		}
	}
	var says, fixes []string
	inherited := false
	for _, r := range readers {
		if allowed[r.SID] {
			continue
		}
		switch {
		case isBroadPrincipal(r.SID) && r.Inherited:
			raise("FAIL")
			inherited = true
			says = append(says, r.Name+" (inherited from above "+filepath.Dir(path)+")")
		case isBroadPrincipal(r.SID):
			raise("FAIL")
			says = append(says, r.Name)
			fixes = append(fixes, fmt.Sprintf(`icacls "%s" /remove:g *%s`, icaclsPath(path), r.SID))
		case !r.Resolved:
			raise("WARN")
			says = append(says, r.SID+" (a SID that does not resolve here: not removed - read it with icacls)")
		case r.Write && !page:
			raise("FAIL")
			says = append(says, r.Name+" (who may change it)")
			if !r.Inherited {
				fixes = append(fixes, fmt.Sprintf(`icacls "%s" /remove:g *%s`, icaclsPath(path), r.SID))
			}
		default:
			raise("WARN")
			says = append(says, r.Name+" (a single account: where the page saved a credential, most likely the one serve runs as; if it is not, remove its grant by hand)")
		}
	}
	if level == "OK" {
		return "OK", ""
	}
	if inherited {
		fixes = append(fixes, "run 'pgvigil install' again: it protects the folder's list (an inherited grant is not removed file by file)")
	}
	return level, fmt.Sprintf("%s is readable by %s%s", path, strings.Join(says, ", "), fixLines(fixes))
}

// dsnFileKey: a connection string's keys that name a file holding a secret (libpq's password file and client key).
var dsnFileKey = regexp.MustCompile(`(?i)\b(passfile|sslkey)\s*=\s*('[^']*'|\S+)`)

// dsnFiles are the files a literal connection string names for its secrets (passfile, sslkey), in either form.
func dsnFiles(v string) []string {
	var out []string
	if lv := strings.ToLower(strings.TrimSpace(v)); strings.HasPrefix(lv, "postgres://") || strings.HasPrefix(lv, "postgresql://") {
		if u, err := url.Parse(strings.TrimSpace(v)); err == nil {
			for k, vals := range u.Query() {
				if lk := strings.ToLower(k); lk == "passfile" || lk == "sslkey" {
					out = append(out, vals...)
				}
			}
		}
		return out
	}
	for _, m := range dsnFileKey.FindAllStringSubmatch(v, -1) {
		out = append(out, strings.Trim(m[2], "'"))
	}
	return out
}

// literalDSNs are the connection strings pgvigil.yaml writes out (not a reference): under dsn, *_dsn and pgbouncer.
func literalDSNs(raw []byte) []string {
	var doc yaml.Node
	if yaml.Unmarshal(raw, &doc) != nil {
		return nil
	}
	var out []string
	var walk func(n *yaml.Node, key string)
	walk = func(n *yaml.Node, key string) {
		switch n.Kind {
		case yaml.DocumentNode, yaml.SequenceNode:
			for _, c := range n.Content {
				walk(c, key)
			}
		case yaml.MappingNode:
			for i := 0; i+1 < len(n.Content); i += 2 {
				walk(n.Content[i+1], n.Content[i].Value)
			}
		case yaml.ScalarNode:
			v := strings.TrimSpace(n.Value)
			ref := strings.HasPrefix(v, "env:") || strings.HasPrefix(v, "file:") || strings.HasPrefix(v, "dpapi:")
			if (key == "dsn" || strings.HasSuffix(key, "_dsn") || key == "pgbouncer") && v != "" && !ref {
				out = append(out, v)
			}
		}
	}
	walk(&doc, "")
	return out
}

// referencedSecrets are the files pgvigil.yaml (and a purge task's configuration) names for secrets wherever they lie:
// each file: reference named whole, and the passfile / sslkey of each literal connection string.
func referencedSecrets(paths ...string) []string {
	var out []string
	for _, p := range paths {
		raw, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		refs, err := exportRefs(raw)
		if err != nil {
			continue
		}
		for _, r := range refs {
			if r.Kind == "file:" && filepath.IsAbs(r.Path) {
				out = append(out, filepath.Clean(r.Path))
			}
		}
		for _, v := range literalDSNs(raw) {
			for _, f := range dsnFiles(v) {
				if filepath.IsAbs(f) {
					out = append(out, filepath.Clean(f))
				}
			}
		}
	}
	return out
}

// secretPaths lists what the part judges: the configuration's folder (when it is pgvigil's own: notDedicated says why
// not), the file, the installer's dsn files and the folder's other secret files (a .previous of an import too),
// everything under the three folders (a link to a file included, judged by its target), and every file a reference or
// a connection string names elsewhere; unlisted counts the folders that could not be listed.
func secretPaths(cfgPath string) (paths []secretPath, unlisted int, notDedicated error) {
	if abs, err := filepath.Abs(cfgPath); err == nil {
		cfgPath = abs
	}
	dir := filepath.Dir(cfgPath)
	seen := map[string]bool{}
	add := func(p secretPath) {
		if !seen[p.Path] {
			seen[p.Path] = true
			paths = append(paths, p)
		}
	}
	if notDedicated = dedicatedFolder(dir, filepath.Base(cfgPath)); notDedicated == nil {
		add(secretPath{Path: dir, Dir: true})
	}
	add(secretPath{Path: cfgPath})
	root := append(append([]string(nil), exportInstallerFiles...), secretRootFiles...)
	if prev, err := filepath.Glob(filepath.Join(dir, "*.previous")); err == nil {
		for _, p := range prev {
			root = append(root, filepath.Base(p))
		}
	}
	sort.Strings(root)
	for _, f := range root {
		p := filepath.Join(dir, f)
		if st, err := os.Lstat(p); err == nil && (st.Mode().IsRegular() || st.Mode()&fs.ModeSymlink != 0) {
			add(secretPath{Path: p, OwnerOnly: ownerOnlyFiles[f]})
		}
	}
	for _, sub := range secretFileFolders {
		top := filepath.Join(dir, sub)
		page := sub == "instances" || sub == "sources"
		_ = filepath.WalkDir(top, func(p string, d fs.DirEntry, err error) error {
			switch {
			case err != nil:
				if !(os.IsNotExist(err) && p == top) {
					unlisted++
				}
				return nil
			case d.IsDir():
				add(secretPath{Path: p, Dir: true, Page: page})
			case d.Type().IsRegular() || d.Type()&fs.ModeSymlink != 0:
				add(secretPath{Path: p, Page: page})
			}
			return nil
		})
	}
	for _, p := range referencedSecrets(cfgPath, filepath.Join(dir, "pgvigil-purge.yaml")) {
		if _, err := os.Lstat(p); err == nil {
			add(secretPath{Path: p})
		}
	}
	return paths, unlisted, notDedicated
}

// secretFileRows is the part's rows: one for each file or folder exposed, one for what was not judged, or one OK row.
func secretFileRows(cfgPath string) []checkRow {
	paths, unlisted, notDedicated := secretPaths(cfgPath)
	cfgDir := filepath.Dir(cfgPath)
	if abs, err := filepath.Abs(cfgPath); err == nil {
		cfgDir = filepath.Dir(abs)
	}
	jc := newJudgeCtx(cfgDir)
	var rows []checkRow
	if notDedicated != nil {
		rows = append(rows, checkRow{"WARN", "secret files", fmt.Sprintf("the configuration's folder is not pgvigil's own (%v): its access is not judged and no fix is printed for it - move the configuration into a folder of its own", notDedicated)})
	}
	if jc.warn != "" {
		rows = append(rows, checkRow{"WARN", "secret files", jc.warn})
	}
	files, dirs := 0, 0
	for _, p := range paths {
		if p.Dir {
			dirs++
		} else {
			files++
		}
		level, words, err := judgeHost(p, jc)
		switch {
		case err != nil:
			rows = append(rows, checkRow{"WARN", "secret files", fmt.Sprintf("%s: its access was not read: %v", p.Path, err)})
		case level != "OK":
			rows = append(rows, checkRow{level, "secret files", words})
		}
	}
	if unlisted > 0 {
		rows = append(rows, checkRow{"WARN", "secret files", fmt.Sprintf("%d folder(s) could not be listed: the files in them are not judged", unlisted)})
	}
	if len(rows) == 0 {
		rows = append(rows, checkRow{"OK", "secret files", fmt.Sprintf("%d file(s) and %d folder(s) that can hold a secret: none open to other accounts", files, dirs)})
	}
	return rows
}
