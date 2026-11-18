//go:build !windows

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestSecretSealWritesAFileRefL9 (L9): 'pgvigil secret seal -name <instance>' takes the connection string on stdin
// and writes it to secrets/ beside the configuration - a file of mode 0600 in a folder of mode 0700 (the form on
// Linux; a DPAPI blob and a dpapi: reference on Windows) - and prints the reference line for pgvigil.yaml. The value
// is never printed; config.Resolve reads it back; each seal is a file of its own; an empty value and a name that is
// not an instance name are refused and write nothing.
func TestSecretSealWritesAFileRefL9(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "pgvigil.yaml")
	if err := os.WriteFile(cfg, []byte("repository:\n  dsn: env:X\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	value := "host=db1 user=pgvigil password=s3cret-zz dbname=postgres"
	var out bytes.Buffer
	if err := secretSeal(cfg, "pg1", strings.NewReader(value+"\n"), &out); err != nil {
		t.Fatal(err)
	}
	line := strings.TrimSpace(out.String())
	if strings.Contains(out.String(), "s3cret-zz") {
		t.Fatalf("the output holds the secret: %q", out.String())
	}
	ref, ok := strings.CutPrefix(line, "dsn: ")
	if !ok || !strings.HasPrefix(ref, "file:"+filepath.Join(dir, "secrets")+string(filepath.Separator)+"pg1-") {
		t.Fatalf("the output is the reference line for pgvigil.yaml ('dsn: file:<config dir>/secrets/pg1-<random>...'): %q", line)
	}
	if got := config.Resolve(ref); got != value {
		t.Errorf("the reference reads back %q, want the value sealed (its trailing newline dropped)", got)
	}
	p := strings.TrimPrefix(ref, "file:")
	if st, err := os.Stat(p); err != nil || st.Mode().Perm() != 0o600 {
		t.Errorf("the sealed file's mode: %v %v, want 0600", st.Mode().Perm(), err)
	}
	if st, err := os.Stat(filepath.Dir(p)); err != nil || st.Mode().Perm() != 0o700 {
		t.Errorf("the secrets folder's mode: %v %v, want 0700", st.Mode().Perm(), err)
	}
	// a second seal of the same name is a file of its own: the first reference still reads
	var out2 bytes.Buffer
	if err := secretSeal(cfg, "pg1", strings.NewReader("host=db1 user=u2"), &out2); err != nil {
		t.Fatal(err)
	}
	if out2.String() == out.String() || config.Resolve(ref) != value {
		t.Errorf("a second seal replaced the first one's file: %q then %q", out.String(), out2.String())
	}
	// refusals: nothing written
	before, _ := os.ReadDir(filepath.Join(dir, "secrets"))
	for name, in := range map[string]string{"pg1": "  \n", "../evil": "host=h", "": "host=h"} {
		if err := secretSeal(cfg, name, strings.NewReader(in), &bytes.Buffer{}); err == nil {
			t.Errorf("secretSeal(%q, %q) was accepted", name, in)
		}
	}
	after, _ := os.ReadDir(filepath.Join(dir, "secrets"))
	if len(after) != len(before) {
		t.Errorf("a refused seal left a file: %d entries before, %d after", len(before), len(after))
	}
}
