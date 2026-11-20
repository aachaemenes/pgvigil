package main

import (
	"strings"
	"testing"
)

// TestJudgeACLRules: a broad SID is a FAIL (inherited: the folder's fix, never a per-file remove), a single account
// that may change a file outside the page's folders a FAIL with its remove line, a single account (serve's, in the
// page's folders) and an unresolved SID a WARN with no remove line; a drive root's path is quoted for cmd.exe; one fix
// a line.
func TestJudgeACLRules(t *testing.T) {
	allowed := map[string]bool{"S-1-5-18": true, "S-1-5-32-544": true}
	users := aclReader{SID: "S-1-5-32-545", Name: `BUILTIN\Users`, Resolved: true}
	everyone := aclReader{SID: "S-1-1-0", Name: "Everyone", Resolved: true}
	alice := aclReader{SID: "S-1-5-21-1-2-3-1104", Name: `CONTOSO\alice`, Resolved: true, Write: true}
	for _, c := range []struct {
		name      string
		path      string
		readers   []aclReader
		page      bool
		level     string
		says, not []string
	}{
		{"inherited Users", `C:\ProgramData\pgvigil\repo.dsn`, []aclReader{{SID: users.SID, Name: users.Name, Resolved: true, Inherited: true}}, false, "FAIL",
			[]string{"inherited from above", "run 'pgvigil install' again"}, []string{"/remove:g"}},
		{"serve's account on the page's folder", `C:\ProgramData\pgvigil\instances`, []aclReader{alice}, true, "WARN",
			[]string{`CONTOSO\alice`, "the one serve runs as"}, []string{"/remove:g"}},
		{"a single writer elsewhere", `C:\ProgramData\pgvigil\pgvigil.yaml`, []aclReader{alice}, false, "FAIL",
			[]string{"who may change it", `/remove:g *S-1-5-21-1-2-3-1104`}, nil},
		{"an unresolved SID", `C:\ProgramData\pgvigil\repo.dsn`, []aclReader{{SID: "S-1-5-21-9-9-9-500", Name: "S-1-5-21-9-9-9-500"}}, false, "WARN",
			[]string{"does not resolve"}, []string{"/remove:g"}},
		{"a drive root, two fixes", `C:\`, []aclReader{users, everyone}, false, "FAIL",
			[]string{`icacls "C:\\" /remove:g *S-1-5-32-545`, "\n      icacls \"C:\\\\\" /remove:g *S-1-1-0"}, []string{"; icacls"}},
	} {
		level, words := judgeACL(c.path, c.readers, allowed, c.page)
		if level != c.level {
			t.Errorf("%s: %s %q, want %s", c.name, level, words, c.level)
		}
		for _, w := range c.says {
			if !strings.Contains(words, w) {
				t.Errorf("%s: %q does not say %q", c.name, words, w)
			}
		}
		for _, w := range c.not {
			if strings.Contains(words, w) {
				t.Errorf("%s: %q says %q", c.name, words, w)
			}
		}
	}
}

// TestDSNFiles: the files a literal connection string names for its secrets, in both forms.
func TestDSNFiles(t *testing.T) {
	got := strings.Join(dsnFiles("host=h passfile=/etc/pgvigil/pg.pass sslkey='/etc/pgvigil/client.key' sslcert=/etc/x.crt"), ",")
	if got != "/etc/pgvigil/pg.pass,/etc/pgvigil/client.key" {
		t.Errorf("keyword form: %q", got)
	}
	if got := strings.Join(dsnFiles("postgres://u@h/db?passfile=/etc/pgvigil/pg.pass"), ","); got != "/etc/pgvigil/pg.pass" {
		t.Errorf("URL form: %q", got)
	}
}
