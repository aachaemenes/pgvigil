package config

import (
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
)

// TestWriteSecretAsL170 (RELNOTES L170): 'pgvigil instance add' writes a page credential for the service's account,
// never for the account running it - the folder 0700 and the file 0600, both owned by the named account; an account
// that does not exist is refused before anything is written.
func TestWriteSecretAsL170(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the Linux modes and owners; Windows gives the folder's list the account's SID")
	}
	me, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), "instances")
	ref, err := WriteSecretAs(dir, "pg7", "host=h user=u password=p", me.Username)
	if err != nil {
		t.Fatal(err)
	}
	p := strings.TrimPrefix(ref, "file:")
	for path, want := range map[string]os.FileMode{dir: 0o700, p: 0o600} {
		st, err := os.Stat(path)
		if err != nil || st.Mode().Perm() != want {
			t.Errorf("%s: %v, mode %v, want %o", path, err, st.Mode().Perm(), want)
			continue
		}
		if s, ok := st.Sys().(*syscall.Stat_t); ok && int(s.Uid) != os.Getuid() {
			t.Errorf("%s owned by %d, want %d", path, s.Uid, os.Getuid())
		}
	}
	if b, _ := os.ReadFile(p); string(b) != "host=h user=u password=p" {
		t.Errorf("the credential reads %q", b)
	}
	other := filepath.Join(t.TempDir(), "instances")
	if _, err := WriteSecretAs(other, "pg8", "x", "pgv-no-such-account-l170"); err == nil || !strings.Contains(err.Error(), "pgv-no-such-account-l170") {
		t.Errorf("an unknown account: %v", err)
	}
	if left, _ := os.ReadDir(other); len(left) != 0 {
		t.Errorf("a refused write left %d entries", len(left))
	}
}
