package mssql

import (
	"database/sql"
	"strings"
	"testing"
	"time"
)

// TestVerifyStatementHoldsNoPath: the statement text names parameters only (the audit keeps it with no path in it);
// CHECKSUM only for a set that has checksums (Msg 3187 otherwise: probe 301bP1); HEADERONLY never takes CHECKSUM.
func TestVerifyStatementHoldsNoPath(t *testing.T) {
	for _, c := range []struct {
		verb     string
		n        int
		checksum bool
		want     string
	}{
		{"VERIFYONLY", 1, true, "RESTORE VERIFYONLY FROM DISK = @d1 WITH FILE = @f, CHECKSUM"},
		{"VERIFYONLY", 2, false, "RESTORE VERIFYONLY FROM DISK = @d1, DISK = @d2 WITH FILE = @f"},
		{"HEADERONLY", 2, true, "RESTORE HEADERONLY FROM DISK = @d1, DISK = @d2 WITH FILE = @f"},
	} {
		if got := verifyStatement(c.verb, c.n, c.checksum); got != c.want {
			t.Errorf("%s %d %v: %s, want %s", c.verb, c.n, c.checksum, got, c.want)
		}
	}
	args := verifyArgs([]string{`/var/opt/mssql/data/pb3_s1.bak`, `/var/opt/mssql/data/pb3_s2.bak`}, 2)
	if len(args) != 3 || args[0].(sql.NamedArg).Name != "d1" || args[1].(sql.NamedArg).Value != `/var/opt/mssql/data/pb3_s2.bak` || args[2].(sql.NamedArg).Name != "f" || args[2].(sql.NamedArg).Value != 2 {
		t.Errorf("the parameters: %#v", args)
	}
}

// TestVerifyNotOffered: what is never verified from the UI (F16), and when a set read now differs from the one shown.
func TestVerifyNotOffered(t *testing.T) {
	disk := VerifySet{Paths: []string{"/b/a.bak"}, devices: []int{2}}
	for name, c := range map[string]struct {
		s    VerifySet
		want string
	}{
		"disk":      {disk, ""},
		"permanent": {VerifySet{Paths: []string{`D:\b\a.bak`}, devices: []int{102}}, ""},
		"url":       {VerifySet{Paths: []string{"https://acct.blob.core.windows.net/c/a.bak"}, devices: []int{9}}, "not offered: not a disk backup (a URL, tape, virtual device or NUL)"},
		"s3 disk":   {VerifySet{Paths: []string{"s3://minio:9000/b/a.bak"}, devices: []int{2}}, "not offered: not a disk backup (a URL, tape, virtual device or NUL)"},
		"tape":      {VerifySet{Paths: []string{`\\.\Tape0`}, devices: []int{5}}, "not offered: not a disk backup (a URL, tape, virtual device or NUL)"},
		"vdi":       {VerifySet{Paths: []string{"{4A0C1E3B-1111-2222-3333-444455556666}"}, devices: []int{7}}, "not offered: not a disk backup (a URL, tape, virtual device or NUL)"},
		"nul":       {VerifySet{Paths: []string{"NUL"}, devices: []int{2}}, "not offered: not a disk backup (a URL, tape, virtual device or NUL)"},
		"password":  {VerifySet{Paths: []string{"/b/a.bak"}, devices: []int{2}, password: true}, "not offered: the media is password-protected (VERIFYONLY would need the password)"},
		"encrypted": {VerifySet{Paths: []string{"/b/a.bak"}, devices: []int{2}, encrypted: true}, "not offered: the backup is encrypted (VERIFYONLY needs the certificate or key on the server)"},
		"no file":   {VerifySet{}, "not offered: msdb names no file of this set"},
	} {
		if got := c.s.notOffered(); got != c.want {
			t.Errorf("%s: %q, want %q", name, got, c.want)
		}
	}
	shown := VerifySet{Position: 2, HasChecksums: true, SizeBytes: 100, Paths: []string{"/b/s1.bak", "/b/s2.bak"}}
	same := shown
	if !sameSet(same, shown) {
		t.Error("the same set reads as changed")
	}
	for name, now := range map[string]VerifySet{
		"position": {Position: 1, HasChecksums: true, SizeBytes: 100, Paths: shown.Paths},
		"checksum": {Position: 2, SizeBytes: 100, Paths: shown.Paths},
		"size":     {Position: 2, HasChecksums: true, SizeBytes: 101, Paths: shown.Paths},
		"a stripe": {Position: 2, HasChecksums: true, SizeBytes: 100, Paths: []string{"/b/s1.bak"}},
		"a path":   {Position: 2, HasChecksums: true, SizeBytes: 100, Paths: []string{"/b/s1.bak", "/c/s2.bak"}},
	} {
		if sameSet(now, shown) {
			t.Errorf("%s changed and reads as the same set", name)
		}
	}
}

// TestValidateVerifyAndRow: the request's shape, and the audit row (no pid; the uuid as the target id; the statement
// with no path).
func TestValidateVerifyAndRow(t *testing.T) {
	u := "8C48CFB3-5DAE-4130-822C-7E6F9D383120"
	ok := VerifyRequest{Instance: "lab", UUID: u, Shown: VerifySet{UUID: u, Position: 1, Paths: []string{"/b/a.bak"}}, Reason: "weekly check", User: "admin"}
	if err := ValidateVerify(ok); err != nil {
		t.Fatalf("a good request: %v", err)
	}
	bad := map[string]func(*VerifyRequest){
		"not a guid":   func(r *VerifyRequest) { r.UUID = "/b/a.bak" },
		"another set":  func(r *VerifyRequest) { r.Shown.UUID = "00000000-0000-0000-0000-000000000001" },
		"no files":     func(r *VerifyRequest) { r.Shown.Paths = nil },
		"short reason": func(r *VerifyRequest) { r.Reason = "x" },
		"no user":      func(r *VerifyRequest) { r.User = " " },
		"a NUL reason": func(r *VerifyRequest) { r.Reason = "weekly\x00check" },
		"no position":  func(r *VerifyRequest) { r.Shown.Position = 0 },
	}
	for name, f := range bad {
		r := ok
		r.Shown.Paths = append([]string{}, ok.Shown.Paths...)
		f(&r)
		if err := ValidateVerify(r); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	res := VerifyResult{Outcome: OutcomeDone, Detail: "the verify ended without an error", Statement: verifyStatement("VERIFYONLY", 1, true),
		ServerMessage: "The backup set on file 1 is valid.", Set: VerifySet{UUID: u, Database: "pb1", Type: "full", FinishUTC: "2026-11-15T12:43:14Z"}}
	row := VerifyRow(time.Unix(0, 0), ok, res)
	if row.PID != nil || row.Action != "verify_backup" || row.TargetID != u || row.Target != "pb1 full 2026-11-15T12:43:14Z" || strings.Contains(row.Statement, "/b/") {
		t.Errorf("the audit row: %+v", row)
	}
}
