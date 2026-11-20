package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// Opening a query plan or a deadlock graph in the app's window: Explorer's Open with starts
// 'pgvigil-app.exe "<file>"', one start per selected file; a start that finds the app already running hands its
// paths to it over WM_COPYDATA and ends. The running app reads each file and posts it to the page in parts, which the
// page joins and opens in its viewer as it opens a dropped file (web/src/filedrop.ts), a tab per file.
//
// pgvigil is never the default handler: install lists it in each extension's OpenWithProgids only, and its ProgIDs
// carry AllowSilentDefaultTakeOver, so the program that opens a .sqlplan on a double-click (SSMS, where installed)
// stays the one that does.

const (
	MaxOpenBytes = 64 * 1024 * 1024 // the page's own limit (web/src/filedrop.ts MAX_BYTES)
	// MaxOpenFiles: a start's files; Explorer runs a Document-model verb once per item for at most 15 selected items
	MaxOpenFiles = 15
	// CopyDataMagic is the dwData of pgvigil's WM_COPYDATA: a message with another value is another program's
	CopyDataMagic = 0x31766770
	// MaxCopyData bounds the payload: 15 paths of Windows' longest (32,767 UTF-16 units, 3 UTF-8 bytes at most each)
	MaxCopyData = MaxOpenFiles * (3*32767 + 1)
	// PartBytes: a part's file bytes; its base64 is 4 MB, one script each
	PartBytes = 3 * 1024 * 1024
	// PageScriptPrefix starts each part's script: a page without the receiver (the login page, another page) ignores it
	PageScriptPrefix = "window.pgvigilAppFile&&window.pgvigilAppFile("
)

// OpenFile is one file for the page: its bytes as read, or the words of why it is not opened.
type OpenFile struct {
	Path string
	Name string // the file's name, shown on its tab
	Data []byte
	Why  string
}

// OpenPaths makes a start's file arguments absolute (a running app has its own working folder); past MaxOpenFiles each
// is a refusal.
func OpenPaths(args []string, abs func(string) (string, error)) (paths []string, refused []OpenFile) {
	for _, a := range args {
		name := filepath.Base(a)
		if len(paths) == MaxOpenFiles {
			refused = append(refused, OpenFile{Path: a, Name: name, Why: fmt.Sprintf("%s: not opened: one start opens at most %d files (Explorer's own limit for a selection)", name, MaxOpenFiles)})
			continue
		}
		p, err := abs(a)
		if err != nil {
			refused = append(refused, OpenFile{Path: a, Name: name, Why: name + ": " + err.Error()})
			continue
		}
		paths = append(paths, p)
	}
	return paths, refused
}

// ReadOpen reads one file for the page: a .sqlplan or a .xdl, at most MaxOpenBytes; its bytes go as they are (the
// page reads a byte-order mark: SSMS saves a plan as UTF-16).
func ReadOpen(path string) OpenFile { return readOpen(path, MaxOpenBytes) }

func readOpen(path string, limit int64) OpenFile {
	f := OpenFile{Path: path, Name: filepath.Base(path)}
	switch strings.ToLower(filepath.Ext(path)) {
	case ".sqlplan", ".xdl":
	default:
		f.Why = f.Name + ": the app opens a query plan (.sqlplan) or a deadlock graph (.xdl); other files open from the page's Tools menu"
		return f
	}
	// a device path (a pipe, a port: \\.\pipe\x.sqlplan) or anything but a regular file is refused before it is opened:
	// a read from one that never writes would hold every later file behind it until the app restarts
	if DevicePath(path) {
		f.Why = f.Name + `: a device path (\\.\ or \\?\) is not a file the viewers open`
		return f
	}
	if st, err := os.Stat(path); err == nil && !st.IsDir() && !st.Mode().IsRegular() {
		f.Why = f.Name + " is not a regular file"
		return f
	}
	h, err := os.Open(path)
	if err != nil {
		f.Why = f.Name + ": " + err.Error()
		return f
	}
	defer func() { _ = h.Close() }()
	st, err := h.Stat()
	switch {
	case err != nil:
		f.Why = f.Name + ": " + err.Error()
		return f
	case st.IsDir():
		f.Why = f.Name + " is a folder"
		return f
	case !st.Mode().IsRegular():
		f.Why = f.Name + " is not a regular file"
		return f
	case st.Size() > limit:
		f.Why = fmt.Sprintf("%s is %d bytes: the viewers open files up to %s", f.Name, st.Size(), sizeWords(limit))
		return f
	}
	b, err := io.ReadAll(io.LimitReader(h, limit+1))
	switch {
	case err != nil:
		f.Why = f.Name + ": " + err.Error()
	case int64(len(b)) > limit:
		f.Why = fmt.Sprintf("%s grew past %s while it was read: the viewers open files up to that size", f.Name, sizeWords(limit))
	default:
		f.Data = b
	}
	return f
}

// DevicePath says whether path names Windows' device namespace (\\.\ or \\?\, either slash): a pipe, a port, a
// volume - never a plan file the viewers open.
func DevicePath(path string) bool {
	p := strings.ReplaceAll(path, "/", `\`)
	return strings.HasPrefix(p, `\\.\`) || strings.HasPrefix(p, `\\?\`)
}

// PageGuard is a page script's head: the script runs only on the serve's own origin (a foreign page the window may
// show never receives a file or a ping).
func PageGuard(origin string) string {
	b, _ := json.Marshal(origin) // a string: Marshal cannot fail
	return "location.origin===" + string(b) + "&&"
}

// GuardScripts heads each script with PageGuard(origin).
func GuardScripts(origin string, scripts []string) []string {
	out := make([]string, len(scripts))
	for i, s := range scripts {
		out[i] = PageGuard(origin) + s
	}
	return out
}

func sizeWords(n int64) string {
	if n%(1024*1024) == 0 {
		return fmt.Sprintf("%d MB", n/(1024*1024))
	}
	return fmt.Sprintf("%d bytes", n)
}

// EncodeCopyData is a second start's payload: its absolute paths in UTF-8, separated by NUL.
func EncodeCopyData(paths []string) ([]byte, error) {
	if len(paths) == 0 || len(paths) > MaxOpenFiles {
		return nil, fmt.Errorf("a hand-over carries 1 to %d files, not %d", MaxOpenFiles, len(paths))
	}
	for _, p := range paths {
		if p == "" || strings.ContainsRune(p, 0) {
			return nil, fmt.Errorf("not a path: %q", p)
		}
	}
	b := []byte(strings.Join(paths, "\x00"))
	if len(b) > MaxCopyData {
		return nil, fmt.Errorf("the paths come to %d bytes, over %d", len(b), MaxCopyData)
	}
	return b, nil
}

// DecodeCopyData reads a received payload back with the same bounds; magic is the message's dwData.
func DecodeCopyData(magic uintptr, b []byte) ([]string, error) {
	switch {
	case magic != CopyDataMagic:
		return nil, errors.New("not pgvigil's hand-over (another dwData)")
	case len(b) == 0 || len(b) > MaxCopyData:
		return nil, fmt.Errorf("a hand-over of %d bytes (1 to %d)", len(b), MaxCopyData)
	case !utf8.Valid(b):
		return nil, errors.New("a hand-over that is not UTF-8")
	}
	paths := strings.Split(string(b), "\x00")
	if len(paths) > MaxOpenFiles {
		return nil, fmt.Errorf("a hand-over of %d files (at most %d)", len(paths), MaxOpenFiles)
	}
	for _, p := range paths {
		if !filepath.IsAbs(p) {
			return nil, fmt.Errorf("a hand-over path that is not absolute: %q", p)
		}
	}
	return paths, nil
}

// PagePart is one script's worth of a file for the page; a refusal is a single part with Error and no Data.
type PagePart struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Part  int    `json:"part"`
	Parts int    `json:"parts"`
	Data  string `json:"data,omitempty"` // base64 of this part's bytes
	Error string `json:"error,omitempty"`
}

// PageScripts are the scripts that post a file to the page, partBytes of the file each (base64, JSON-quoted: no raw
// U+2028 / U+2029 and no '<' reach the script).
func PageScripts(id int, f OpenFile, partBytes int) []string {
	if f.Why != "" {
		return []string{partScript(PagePart{ID: id, Name: f.Name, Parts: 1, Error: f.Why})}
	}
	n := max(1, (len(f.Data)+partBytes-1)/partBytes)
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		lo := i * partBytes
		hi := min(lo+partBytes, len(f.Data))
		out = append(out, partScript(PagePart{ID: id, Name: f.Name, Part: i, Parts: n, Data: base64.StdEncoding.EncodeToString(f.Data[lo:hi])}))
	}
	return out
}

func partScript(p PagePart) string {
	b, _ := json.Marshal(p) // a struct of strings and ints: Marshal cannot fail
	return PageScriptPrefix + string(b) + ")"
}

// RegLine is one registry value install writes, under HKCU (a per-user install) or HKLM (machine-wide).
type RegLine struct {
	Key   string
	Name  string // "" = the key's default value
	Kind  string // RegSz or RegNone
	Value string
}

// RegValue names a value to delete.
type RegValue struct{ Key, Name string }

const (
	RegSz   = "sz"
	RegNone = "none"
)

// assocTypes: each kind's ProgID, named [Vendor].[Component].[Version] (Microsoft Learn, 'Programmatic Identifiers')
var assocTypes = []struct{ ext, progID string }{{".sqlplan", "pgvigil.sqlplan.1"}, {".xdl", "pgvigil.xdl.1"}}

// AssocLines are the Open with entries for the app at exe: each kind's ProgID (no default value, so Explorer names the
// type as before) and its name in the extension's OpenWithProgids; never the extension's own default value.
func AssocLines(exe string) []RegLine {
	var out []RegLine
	for _, t := range assocTypes {
		pk := `Software\Classes\` + t.progID
		out = append(out,
			RegLine{pk, "AllowSilentDefaultTakeOver", RegNone, ""},
			RegLine{pk + `\DefaultIcon`, "", RegSz, exe + ",0"},
			RegLine{pk + `\shell\open`, "MultiSelectModel", RegSz, "Document"},
			RegLine{pk + `\shell\open\command`, "", RegSz, `"` + exe + `" "%1"`},
			RegLine{`Software\Classes\` + t.ext + `\OpenWithProgids`, t.progID, RegNone, ""},
		)
	}
	return out
}

// AssocRemoval is what uninstall deletes: the ProgID keys, a key after its subkeys, and pgvigil's values in the
// extensions' OpenWithProgids (the keys themselves stay: other programs list themselves there).
func AssocRemoval() (keys []string, values []RegValue) {
	for _, t := range assocTypes {
		pk := `Software\Classes\` + t.progID
		keys = append(keys, pk+`\shell\open\command`, pk+`\shell\open`, pk+`\shell`, pk+`\DefaultIcon`, pk)
		values = append(values, RegValue{`Software\Classes\` + t.ext + `\OpenWithProgids`, t.progID})
	}
	return keys, values
}
