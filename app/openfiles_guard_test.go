package main

import (
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// TestDevicePathRefused: a device path (a pipe, a port) is refused before it is opened, in either slash form; a plain
// path is not a device path.
func TestDevicePathRefused(t *testing.T) {
	for _, p := range []string{`\\.\pipe\x.sqlplan`, `\\?\C:\plans\a.sqlplan`, `//./COM1.xdl`, `//?/C:/a.xdl`} {
		if f := readOpen(p, MaxOpenBytes); !strings.Contains(f.Why, "device path") || f.Data != nil {
			t.Errorf("readOpen(%q) = %q, want the device-path refusal", p, f.Why)
		}
	}
	for _, p := range []string{`C:\plans\a.sqlplan`, `\\server\share\a.sqlplan`, "/plans/a.sqlplan"} {
		if DevicePath(p) {
			t.Errorf("DevicePath(%q) = true", p)
		}
	}
}

// TestGuardScriptsOnTheServeOrigin: every file script and the ping run only on the serve's own origin.
func TestGuardScriptsOnTheServeOrigin(t *testing.T) {
	origin := "http://127.0.0.1:8123"
	scripts := GuardScripts(origin, PageScripts(1, OpenFile{Name: "a.sqlplan", Data: []byte("<x/>")}, PartBytes))
	want := `location.origin==="http://127.0.0.1:8123"&&` + PageScriptPrefix
	for i, s := range scripts {
		if !strings.HasPrefix(s, want) {
			t.Errorf("script %d starts %.80q, want %q", i, s, want)
		}
	}
	if g := PageGuard(`http://x"</script>`); strings.Contains(g, "</script>") && !strings.Contains(g, `\u003c/script\u003e`) {
		t.Errorf("the origin is not JSON-quoted: %s", g)
	}
}

// TestPartBytesFitsThePage: the app's part size is the page's (filedrop.ts MAX_PARTS counts 3 MiB parts), and the
// largest file the app reads fits the page's part count.
func TestPartBytesFitsThePage(t *testing.T) {
	b, err := os.ReadFile("../web/src/filedrop.ts")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`const MAX_PARTS = Math\.ceil\(MAX_BYTES / \((\d+) \* 1024 \* 1024\)\) \+ 1;`).FindSubmatch(b)
	if m == nil {
		t.Fatal("filedrop.ts has no MAX_PARTS line of the form read here")
	}
	mib, _ := strconv.Atoi(string(m[1]))
	if mib*1024*1024 != PartBytes {
		t.Errorf("the page counts %d MiB parts, the app sends %d bytes", mib, PartBytes)
	}
	pageParts := (MaxOpenBytes+mib*1024*1024-1)/(mib*1024*1024) + 1
	if need := (MaxOpenBytes + PartBytes - 1) / PartBytes; need > pageParts {
		t.Errorf("a %d-byte file is %d parts, the page takes %d", MaxOpenBytes, need, pageParts)
	}
}
