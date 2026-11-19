package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// runWith runs pgvigil with stdin holding in, and returns the exit code and what it wrote to stdout and stderr.
func runWith(t *testing.T, in string, args ...string) (int, string) {
	t.Helper()
	ir, iw, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	or, ow, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	oldIn, oldOut := os.Stdin, os.Stdout
	os.Stdin, os.Stdout = ir, ow
	go func() { _, _ = io.WriteString(iw, in); _ = iw.Close() }()
	got := make(chan string)
	go func() { b, _ := io.ReadAll(or); got <- string(b) }()
	code := 0
	errOut := stderrOf(t, func() { code = run(args) })
	_ = ow.Close()
	os.Stdin, os.Stdout = oldIn, oldOut
	return code, <-got + errOut
}

// TestConfigCommandsL155 (the lead's 04:29): 'pgvigil config export' writes -out only (0600), in one of its two forms;
// 'pgvigil config import' opens it with the same password before any write; no secret reaches stdout or stderr.
func TestConfigCommandsL155(t *testing.T) {
	src, cfg := exportFolder(t)
	secrets := []string{"repo-secret", "pg1-secret", "page-secret", "source-secret", "Pv9-export"}
	quiet := func(what, out string) {
		t.Helper()
		for _, s := range secrets {
			if strings.Contains(out, s) {
				t.Errorf("%s wrote %q to stdout or stderr", what, s)
			}
		}
	}
	dir := t.TempDir()
	masked := filepath.Join(dir, "masked.yaml")
	code, out := runWith(t, "", "config", "export", "-config", cfg, "-no-secrets", "-out", masked)
	quiet("export -no-secrets", out)
	if st, err := os.Stat(masked); code != 0 || err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("export -no-secrets: exit %d, %v, out %q", code, err, out)
	}
	sealed := filepath.Join(dir, "move.pgvigil")
	code, out = runWith(t, "Pv9-export\n", "config", "export", "-config", cfg, "-password-stdin", "-out", sealed)
	quiet("export -password-stdin", out)
	b, err := os.ReadFile(sealed)
	if code != 0 || err != nil || !strings.HasPrefix(string(b), exportMagic) {
		t.Fatalf("export -password-stdin: exit %d, %v, out %q", code, err, out)
	}
	quiet("the sealed file", string(b))
	dst := filepath.Join(t.TempDir(), "pgvigil")
	if err := os.Mkdir(dst, 0o750); err != nil {
		t.Fatal(err)
	}
	code, out = runWith(t, "a wrong one\n", "config", "import", "-config", filepath.Join(dst, "pgvigil.yaml"), "-password-stdin", sealed)
	if left, _ := os.ReadDir(dst); code == 0 || len(left) != 0 || !strings.Contains(out, "does not open") {
		t.Errorf("import with a wrong password: exit %d, %d entries written, out %q", code, len(left), out)
	}
	code, out = runWith(t, "Pv9-export\n", "config", "import", "-config", filepath.Join(dst, "pgvigil.yaml"), "-password-stdin", sealed)
	quiet("import", out)
	for _, rel := range []string{"pgvigil.yaml", "repo.dsn", "secrets/pg1-ab12.dsn", "instances/7.dsn", "sources/aws.json"} {
		want, _ := os.ReadFile(filepath.Join(src, filepath.FromSlash(rel)))
		got, err := os.ReadFile(filepath.Join(dst, filepath.FromSlash(rel)))
		if code != 0 || err != nil || string(got) != string(want) {
			t.Errorf("import: exit %d, %s back %v (%v)", code, rel, string(got) == string(want), err)
		}
	}
	for _, c := range [][]string{
		{"config", "export", "-config", cfg, "-no-secrets"},
		{"config", "export", "-config", cfg, "-no-secrets", "-password-stdin", "-out", filepath.Join(dir, "x")},
		{"config", "export", "-config", cfg, "-no-secrets", "-out", masked},
		{"config", "import", "-config", filepath.Join(dst, "pgvigil.yaml"), sealed},
		{"config"},
	} {
		if code, _ := runWith(t, "Pv9-export\n", c...); code == 0 {
			t.Errorf("%v: exit 0, want a refusal", c)
		}
	}
}
