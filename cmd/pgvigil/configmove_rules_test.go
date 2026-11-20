package main

import (
	"errors"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// importInto makes an installed folder for an import (the folder 'pgvigil install' makes) and the export of the
// sample folder.
func importInto(t *testing.T) (exportPayload, string) {
	t.Helper()
	_, srcCfg := exportFolder(t)
	plainOpen := func(p string) ([]byte, bool, error) { b, err := os.ReadFile(p); return b, false, err }
	pl, err := collectExport(srcCfg, plainOpen)
	if err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(t.TempDir(), "pgvigil")
	if err := os.Mkdir(dst, 0o750); err != nil {
		t.Fatal(err)
	}
	return pl, filepath.Join(dst, "pgvigil.yaml")
}

// TestImportPageFoldersAsTheAccount: instances/ and sources/ go to the installed service's account - the folder 0700,
// each file 0600 - so the page can still write there after a move; the folder's other files take its owner and the
// installer's mode. (The account here is this test's own: a chown to another needs root.)
func TestImportPageFoldersAsTheAccount(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows: the folders' access lists are the WIN turn's row")
	}
	me, err := user.Current()
	if err != nil {
		t.Skip(err)
	}
	pl, cfg := importInto(t)
	if _, err := importExport(pl, cfg, false, importWriteAs(me.Username), false); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Dir(cfg)
	for _, sub := range []string{"instances", "sources"} {
		if st, err := os.Stat(filepath.Join(dir, sub)); err != nil || st.Mode().Perm() != 0o700 {
			t.Errorf("%s/: %v, mode %v - want 0700 as the service's account", sub, err, st.Mode().Perm())
		}
	}
	for path, want := range map[string]os.FileMode{"instances/7.dsn": 0o600, "sources/aws.json": 0o600, "pgvigil.yaml": 0o640, "secrets/pg1-ab12.dsn": 0o640} {
		if st, err := os.Stat(filepath.Join(dir, filepath.FromSlash(path))); err != nil || st.Mode().Perm() != want {
			t.Errorf("%s: %v, mode %v - want %v", path, err, st.Mode().Perm(), want)
		}
	}
}

// TestImportRefusals: before any write, an export of another system, of another format, of another configuration's
// name, a link on the way to a file, and a .previous of an earlier import are each refused in words.
func TestImportRefusals(t *testing.T) {
	pl, cfg := importInto(t)
	dir := filepath.Dir(cfg)
	other := pl
	other.OS = "plan9"
	if _, err := importExport(other, cfg, false, importWrite, false); err == nil || !strings.Contains(err.Error(), "plan9") || !strings.Contains(err.Error(), "one system") {
		t.Errorf("another system's export: %v", err)
	}
	newer := pl
	newer.Version = 2
	if _, err := importExport(newer, cfg, false, importWrite, false); err == nil || !strings.Contains(err.Error(), "format 2") {
		t.Errorf("another format: %v", err)
	}
	named := pl
	named.Config = "prod.yaml"
	if _, err := importExport(named, cfg, false, importWrite, false); err == nil || !strings.Contains(err.Error(), "-config "+filepath.Join(dir, "prod.yaml")) {
		t.Errorf("another configuration's name: %v", err)
	}
	if left, _ := os.ReadDir(dir); len(left) != 0 {
		t.Errorf("the refusals wrote %d entries", len(left))
	}
	if runtime.GOOS != "windows" {
		elsewhere := t.TempDir()
		if err := os.Symlink(elsewhere, filepath.Join(dir, "instances")); err != nil {
			t.Fatal(err)
		}
		if _, err := importExport(pl, cfg, false, importWrite, false); err == nil || !strings.Contains(err.Error(), "symbolic link") {
			t.Errorf("a planted link: %v", err)
		}
		if left, _ := os.ReadDir(elsewhere); len(left) != 0 {
			t.Errorf("the import wrote %d entries through the link", len(left))
		}
		if err := os.Remove(filepath.Join(dir, "instances")); err != nil {
			t.Fatal(err)
		}
		if left, _ := os.ReadDir(dir); len(left) != 0 {
			t.Errorf("the refused import left %d entries", len(left))
		}
	}
	if _, err := importExport(pl, cfg, false, importWrite, false); err != nil {
		t.Fatal(err)
	}
	if _, err := importExport(pl, cfg, true, importWrite, false); err != nil {
		t.Fatalf("the first -force: %v", err)
	}
	if _, err := importExport(pl, cfg, true, importWrite, false); err == nil || !strings.Contains(err.Error(), ".previous is there") {
		t.Errorf("a second -force over a .previous: %v, want it refused (the first .previous is kept)", err)
	}
}

// TestImportAllOrNothing: a write that fails part-way changes nothing - every file as it was, no file of a fresh name
// left, no .previous made.
func TestImportAllOrNothing(t *testing.T) {
	pl, cfg := importInto(t)
	dir := filepath.Dir(cfg)
	if err := os.WriteFile(cfg, []byte("the old one\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	n := 0
	failing := func(d string, f exportFile, target string) error {
		if n++; n == 3 {
			return errors.New("the disk is full")
		}
		return importWrite(d, f, target)
	}
	if _, err := importExport(pl, cfg, true, failing, false); err == nil || !strings.Contains(err.Error(), "nothing was changed") {
		t.Fatalf("a failing write: %v", err)
	}
	if b, _ := os.ReadFile(cfg); string(b) != "the old one\n" {
		t.Errorf("the configuration after a failed import: %q", b)
	}
	entries, _ := os.ReadDir(dir)
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	if len(names) != 1 || names[0] != "pgvigil.yaml" {
		t.Errorf("the folder after a failed import holds %v, want pgvigil.yaml alone", names)
	}
}

// TestExportNoSecretsForms: -no-secrets masks a pgbouncer: dsn, a password in a comment, a libpq value holding ';'
// or an escaped space, sslpassword in both forms, and a socket host whose text holds '://'; what is no secret stays.
func TestExportNoSecretsForms(t *testing.T) {
	in := `repository:
  dsn: host=/var/run/postgresql user=pgv password=sockSecret application_name=a://b
instances:
  - name: pg1
    # dsn: host=pg1 user=mon password=Old-Pass-1
    dsn: env:PG1_DSN
    pgbouncer: host=pool1 port=6432 dbname=pgbouncer user=stats password=Pool-Secret-1
  - name: pg2
    dsn: host=pg2 user=mon password=semi;colonSecret sslpassword=KeyPass1 dbname=postgres
  - name: pg3
    dsn: host=pg3 user=mon password=esc\ spaceSecret dbname=postgres
  - name: pg4
    dsn: postgres://mon@pg4:5432/postgres?sslpassword=KeyPass2&sslmode=verify-full
`
	out, notes, err := exportNoSecrets([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	for _, secret := range []string{"sockSecret", "Old-Pass-1", "Pool-Secret-1", "colonSecret", "KeyPass1", "spaceSecret", "KeyPass2"} {
		if strings.Contains(s, secret) || strings.Contains(strings.Join(notes, "\n"), secret) {
			t.Errorf("-no-secrets kept %q:\n%s", secret, s)
		}
	}
	for _, kept := range []string{"host=/var/run/postgresql", "application_name=a://b", "host=pool1 port=6432", "user=stats", "env:PG1_DSN", "dbname=postgres", "sslmode=verify-full", "pg4:5432"} {
		if !strings.Contains(s, kept) {
			t.Errorf("-no-secrets lost %q:\n%s", kept, s)
		}
	}
	if !strings.Contains(strings.Join(notes, "\n"), "a password in a comment") {
		t.Errorf("the comment's mask is not named: %q", notes)
	}
}

// TestExportLeftBehind: references the export does not carry are named by their key - a file: outside the folder, a
// file: not named whole, a dpapi: blob outside the three folders - and a commented-out reference to a file that is
// gone neither stops the export nor is named.
func TestExportLeftBehind(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "pgvigil")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "pg2.dsn")
	if err := os.WriteFile(outside, []byte("host=pg2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(dir, "pgvigil.yaml")
	text := "repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n" +
		"  - name: pg2\n    # dsn: file:" + filepath.Join(dir, "gone.dsn") + "\n    dsn: file:" + outside + "\n" +
		"  - name: pg3\n    dsn: file:pg3.dsn\n" +
		"  - name: pg4\n    dsn: dpapi:" + filepath.Join(dir, "elsewhere", "pg4.dpapi") + "\n"
	if err := os.WriteFile(cfg, []byte(text), 0o640); err != nil {
		t.Fatal(err)
	}
	plainOpen := func(p string) ([]byte, bool, error) { b, err := os.ReadFile(p); return b, false, err }
	if _, err := collectExport(cfg, plainOpen); err != nil {
		t.Fatalf("a commented-out reference to a gone file stopped the export: %v", err)
	}
	left, err := exportLeftBehind(cfg)
	if err != nil {
		t.Fatal(err)
	}
	all := strings.Join(left, "\n")
	for _, want := range []string{outside, "pg3.dsn is not named whole", "pg4.dpapi lies outside secrets/", "instances.[].dsn"} {
		if !strings.Contains(all, want) {
			t.Errorf("left behind %q: want %q named", left, want)
		}
	}
	if strings.Contains(all, "gone.dsn") || len(left) != 3 {
		t.Errorf("left behind %q: want exactly the three references, never a comment", left)
	}
}

// TestExportPasswordFloor: an export password under 12 characters is refused in words; 12 or more is taken.
func TestExportPasswordFloor(t *testing.T) {
	if err := checkExportPassword("short-pw"); err == nil || !strings.Contains(err.Error(), "at least 12") {
		t.Errorf("an 8-character password: %v", err)
	}
	if err := checkExportPassword("correct horse battery"); err != nil {
		t.Errorf("a passphrase: %v", err)
	}
}
