package main

import (
	"context"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestSecretFileModesL169 (RELNOTES L169, PerformanceMonitor 3.5.0's --harden-files; the lead's 04:29 (2) = (a)): on
// Linux any bit for others is a FAIL and a group bit beyond read a WARN (a folder's group may traverse), each with its
// chmod line.
func TestSecretFileModesL169(t *testing.T) {
	for _, c := range []struct {
		mode        fs.FileMode
		dir         bool
		level, says string
	}{
		{0o600, false, "OK", ""}, {0o640, false, "OK", ""}, {0o400, false, "OK", ""},
		{0o644, false, "FAIL", "chmod o-rwx /x"}, {0o604, false, "FAIL", "chmod o-rwx /x"}, {0o666, false, "FAIL", "chmod o-rwx /x"},
		{0o660, false, "WARN", "chmod g-wx /x"}, {0o650, false, "WARN", "chmod g-wx /x"},
		{0o750, true, "OK", ""}, {0o700, true, "OK", ""}, {0o755, true, "FAIL", "chmod o-rwx /x"}, {0o770, true, "WARN", "chmod g-w /x"},
	} {
		level, words := judgeMode("/x", c.mode, c.dir)
		if level != c.level || !strings.Contains(words, c.says) {
			t.Errorf("mode %o dir %v: %s %q, want %s saying %q", c.mode, c.dir, level, words, c.level, c.says)
		}
	}
}

// TestSecretFileACLL169: on Windows an entry granting read to anyone but SYSTEM, the Administrators and the service's
// account is a FAIL naming that reader and its icacls line.
func TestSecretFileACLL169(t *testing.T) {
	allowed := map[string]bool{"S-1-5-18": true, "S-1-5-32-544": true, "S-1-5-80-1111": true}
	ok := []aclReader{{"S-1-5-18", `NT AUTHORITY\SYSTEM`}, {"S-1-5-32-544", `BUILTIN\Administrators`}, {"S-1-5-80-1111", `NT SERVICE\pgvigil`}}
	if level, words := judgeACL(`C:\ProgramData\pgvigil\repo.dsn`, ok, allowed); level != "OK" {
		t.Errorf("the installer's three readers: %s %q", level, words)
	}
	more := append(append([]aclReader(nil), ok...), aclReader{"S-1-5-32-545", `BUILTIN\Users`})
	level, words := judgeACL(`C:\ProgramData\pgvigil\repo.dsn`, more, allowed)
	if level != "FAIL" || !strings.Contains(words, `BUILTIN\Users`) || !strings.Contains(words, `icacls "C:\ProgramData\pgvigil\repo.dsn" /remove:g *S-1-5-32-545`) {
		t.Errorf("Users reading: %s %q", level, words)
	}
}

// TestSecretFilesRowsL169: the part judges every file that can hold a secret in the configuration's folder - the
// file, the installer's dsn files, secrets/, instances/, sources/, keys/ - and the folders, one OK row when none is
// exposed; a stray note is not judged. 'pgvigil check' carries the rows, so it ends non-zero.
func TestSecretFilesRowsL169(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the Linux modes; Windows reads access lists")
	}
	dir, cfg := exportFolder(t)
	rows := secretFileRows(cfg)
	if len(rows) != 1 || rows[0].Level != "OK" || rows[0].What != "secret files" {
		t.Fatalf("a folder as the installer leaves it: %+v", rows)
	}
	if err := os.Chmod(filepath.Join(dir, "notes.txt"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(dir, "secrets", "pg1-ab12.dsn"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(dir, "keys", "token.key"), 0o660); err != nil {
		t.Fatal(err)
	}
	rows = secretFileRows(cfg)
	var all []string
	for _, r := range rows {
		all = append(all, r.Level+" "+r.Words)
	}
	got := strings.Join(all, "\n")
	if !strings.Contains(got, "FAIL") || !strings.Contains(got, "secrets/pg1-ab12.dsn") || !strings.Contains(got, "chmod o-rwx") ||
		!strings.Contains(got, "WARN") || !strings.Contains(got, "keys/token.key") || strings.Contains(got, "notes.txt") {
		t.Errorf("the rows over an exposed file and a group-writable key:\n%s", got)
	}
	checked, _ := checkRun(context.Background(), slog.New(slog.NewTextHandler(io.Discard, nil)), cfg, nil)
	found := false
	for _, r := range checked {
		found = found || (r.What == "secret files" && r.Level == "FAIL")
	}
	if !found {
		t.Errorf("pgvigil check does not carry the secret files' FAIL: %+v", checked)
	}
}
