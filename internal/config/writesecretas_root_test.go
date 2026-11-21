//go:build linux

package config

import (
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

// TestWriteSecretAsForNobody: as root, the page's credential written for another account (nobody) is that account's -
// the folder 0700 and the file 0600 owned by it - so the row fails when the owner is never given (run only as root).
func TestWriteSecretAsForNobody(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("a chown to another account needs root")
	}
	nobody, err := user.Lookup("nobody")
	if err != nil {
		t.Skip(err)
	}
	dir := filepath.Join(t.TempDir(), "instances")
	ref, err := WriteSecretAs(dir, "pg7", "host=pg7 user=mon password=x", "nobody")
	if err != nil {
		t.Fatal(err)
	}
	want, _ := strconv.Atoi(nobody.Uid)
	for _, p := range []string{dir, strings.TrimPrefix(ref, "file:")} {
		st, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if sys := st.Sys().(*syscall.Stat_t); int(sys.Uid) != want {
			t.Errorf("%s owned by uid %d, want nobody's %d", p, sys.Uid, want)
		}
	}
}
