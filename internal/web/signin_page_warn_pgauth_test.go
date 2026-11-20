package web

import (
	"os"
	"strings"
	"testing"
)

// TestTestDetailCarriesTheWarnPGAUTH: every connection test of the page shows the sign-in guard's WARN
// as 'pgvigil check' does - a pgvigil.yaml instance's Test and Check all (testConnection), the by-name test and the
// page's own path all compose their words through testDetail; none returns the bare detail.
func TestTestDetailCarriesTheWarnPGAUTH(t *testing.T) {
	w := "the server signs this login in by ldap, which has pgvigil send the password in clear"
	if got, want := testDetail(testResult{ok: true, detail: "connected: PostgreSQL 16.4, as pgvigil", warn: w}), "connected: PostgreSQL 16.4, as pgvigil - WARN: "+w; got != want {
		t.Errorf("testDetail = %q, want %q", got, want)
	}
	if got := testDetail(testResult{ok: true, detail: "connected"}); got != "connected" {
		t.Errorf("without a warning: %q", got)
	}
	b, err := os.ReadFile("q_instances_admin.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if n := strings.Count(src, "testDetail(t)"); n < 3 {
		t.Errorf("testDetail(t) appears %d time(s) in q_instances_admin.go, want the three test paths (by name, the page's own, testConnection)", n)
	}
	for _, bare := range []string{`"detail": t.detail}`, "return t.ok, t.detail"} {
		if strings.Contains(src, bare) {
			t.Errorf("a test path still returns the bare detail: %q", bare)
		}
	}
}
