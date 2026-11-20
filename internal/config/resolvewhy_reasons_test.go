package config

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestWhyEmptyWhiteSpace: a reference whose value is only white space resolves as before (Resolve unchanged) but
// connects nowhere: WhyEmpty says so, naming the reference, never the value.
func TestWhyEmptyWhiteSpace(t *testing.T) {
	dir := t.TempDir()
	blank := filepath.Join(dir, "blank")
	if err := os.WriteFile(blank, []byte(" \t\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PGV_WS_BLANK", " ")
	for ref, resolved := range map[string]string{"env:PGV_WS_BLANK": " ", "file:" + blank: " \t"} {
		if got := Resolve(ref); got != resolved {
			t.Errorf("Resolve(%q) = %q, want %q (unchanged)", ref, got, resolved)
		}
		if why := WhyEmpty(ref); !strings.Contains(why, "holds only white space") || !strings.Contains(why, ref) {
			t.Errorf("WhyEmpty(%q) = %q, want the reference named and 'holds only white space'", ref, why)
		}
	}
	if why := WhyEmpty("host=h"); why != "" {
		t.Errorf("a literal dsn: %q", why)
	}
}

// TestDPAPIReasonsSorted: a dpapi: blob that does not open says why by the kind of error (Windows' own answers come
// from a replaced opener): a file error is the file's, an empty blob is empty, off Windows it opens on Windows only,
// and only Windows' refusal to decrypt is the moved host - its fix chosen by the blob's folder. A value the opener
// read never reaches a reason.
func TestDPAPIReasonsSorted(t *testing.T) {
	old := dpapiOpen
	defer func() { dpapiOpen = old }()
	const secret = "hunter2-planted"
	page := filepath.Join("C:", "ProgramData", "pgvigil", "instances", "win-pg-1a.dpapi")
	sealed := filepath.Join("C:", "ProgramData", "pgvigil", "secrets", "pg1.dpapi")
	for _, c := range []struct {
		name, path string
		val        string
		err        error
		says, not  []string
	}{
		{"unreadable", sealed, "", &fs.PathError{Op: "open", Path: sealed, Err: fs.ErrPermission}, []string{"cannot be read"}, []string{"did not open on this host"}},
		{"zero bytes", sealed, "", os.ErrInvalid, []string{"is empty"}, []string{"did not open on this host"}},
		{"off windows", sealed, "", ErrDPAPIOffWindows, []string{"opens on Windows only"}, []string{"did not open on this host"}},
		{"moved, a page instance", page, "", errors.New("The data is invalid."), []string{"did not open on this host", "Admin > Instances"}, []string{"secret seal"}},
		{"moved, a sealed line", sealed, "", errors.New("The data is invalid."), []string{"did not open on this host", "pgvigil secret seal"}, []string{"Admin > Instances"}},
		{"decrypted to nothing", sealed, "", nil, []string{"is empty"}, nil},
	} {
		dpapiOpen = func(string) (string, error) { return c.val, c.err }
		got, err := ResolveWhy("dpapi:" + c.path)
		if got != "" || err == nil {
			t.Errorf("%s: %q, %v - want nothing and a reason", c.name, got, err)
			continue
		}
		for _, w := range c.says {
			if !strings.Contains(err.Error(), w) {
				t.Errorf("%s: %q does not say %q", c.name, err, w)
			}
		}
		for _, w := range append(c.not, secret) {
			if strings.Contains(err.Error(), w) {
				t.Errorf("%s: %q says %q", c.name, err, w)
			}
		}
	}
	dpapiOpen = func(string) (string, error) { return secret, nil }
	if got, err := ResolveWhy("dpapi:" + sealed); got != secret || err != nil {
		t.Errorf("a blob that opens: %q, %v", got, err)
	}
	dpapiOpen = func(string) (string, error) {
		return "", &fs.PathError{Op: "open", Path: sealed, Err: fs.ErrPermission}
	}
	if _, err := ResolveWhy("dpapi:" + sealed); !errors.Is(err, fs.ErrPermission) {
		t.Errorf("the opener's error is not kept in the reason's chain (errors.Is): %v", err)
	}
}

// TestFileSecretReasons: a file: that is a folder says so; a missing file is the system's not-exist error (read by its
// kind, not its words: the words are each system's own); the real opener off Windows is ErrDPAPIOffWindows.
func TestFileSecretReasons(t *testing.T) {
	dir := t.TempDir()
	if _, err := ResolveWhy("file:" + dir); err == nil || !strings.Contains(err.Error(), "is a folder") {
		t.Errorf("a folder: %v", err)
	}
	if _, err := ResolveWhy("file:" + filepath.Join(dir, "missing")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("a missing file: %v, want fs.ErrNotExist in its chain", err)
	}
	if runtime.GOOS != "windows" {
		if _, err := ResolveWhy("dpapi:" + filepath.Join(dir, "x.dpapi")); !errors.Is(err, ErrDPAPIOffWindows) {
			t.Errorf("dpapi: off Windows: %v", err)
		}
	}
}
