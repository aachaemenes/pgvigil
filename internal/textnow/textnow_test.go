package textnow

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const secret = "'secret-7731'"

// TestFindingCut: each check that quotes a statement, its message in its migration's shape with a literal-bearing
// statement, cut under none and normalized: the literal never survives, the words before the quote stay; a message
// whose quote is not found fails closed (the whole field is the statement).
func TestFindingCut(t *testing.T) {
	stmt := "UPDATE dbo.t SET a = " + secret + " WHERE id = 42"
	cases := []struct{ check, value, detail, head string }{
		{"temp-file spills", "", "3 temp files of 900 MB: a sort did not fit work_mem. " + stmt, "a sort did not fit work_mem. "},
		{"a blocking chain", "", "8 sessions wait on session 51. Its last statement: " + stmt, "Its last statement: "},
		{"a session idle in a transaction over an hour holding locks", "", "Session 60 holds 4 locks. Its last batch: " + stmt, "Its last batch: "},
		{"a request running over an hour", "", "Session 61 has run 2 h. Statement: " + stmt, "Statement: "},
		{"blocked-process reports naming the same head statement", stmt, "", ""},
		{"an availability replica changed role or state", "", "3 change(s) in the last hour; " + stmt, "in the last hour; "},
		{"an implicit transaction blocking", "", "Session 70 blocks 2. Its statement: " + stmt, "Its statement: "},
		{"a lead blocker", "", "Session 71 heads 5 waits. The statement: " + stmt, "The statement: "},
		{"a transaction open for a long time", "", "Session 72 open 3 h, its last statement: " + stmt, "its last statement: "},
		// a database name with ': ' in it (legal in SQL Server) before the quote
		{"a memory grant over 15 % of max workspace", "", "Session 55 holds a grant of 900 MB, 20.0 % of the 4000 MB Maximum Workspace Memory (sp_BlitzFirst 46, over 15 %) in sales:eu: " + stmt, "(sp_BlitzFirst 46, over 15 %) in sales:eu: "},
		{"the version store grows while cleanup is at zero", "", "Session 80 pins it, last statement: " + stmt, "last statement: "},
		{"the version store over a third of tempdb", "", "Session 81 pins it, last statement: " + stmt, "last statement: "},
		{"plan: seq scan on a large table", "", "4 plans; the worst: plan 12 (sales): " + stmt, "the worst: plan 12 (sales): "},
		{"plan: filter removes most rows", "removed by Filter: (a = " + secret + ")", "", ""},
		{"statement 123", "", "900 ms in all (2 calls): " + stmt, "900 ms in all (2 calls): "},
		// fail closed: a reworded message, its marker gone
		{"a lead blocker", "", "Session 71 heads 5 waits; statement " + stmt, ""},
	}
	for _, c := range cases {
		if !Listed(c.check) {
			t.Errorf("%q is not listed", c.check)
			continue
		}
		for _, mode := range []string{"none", "normalized"} {
			v, d := Finding(c.check, c.value, c.detail, mode)
			if strings.Contains(v+d, "secret-7731") {
				t.Errorf("%s under %s: the literal survives: value %q detail %q", c.check, mode, v, d)
			}
			if c.head != "" && !strings.Contains(d, c.head) && !strings.Contains(v, c.head) {
				t.Errorf("%s under %s: the words before the quote are lost: %q", c.check, mode, d)
			}
			if mode == "none" && !strings.Contains(v+d, textCut) {
				t.Errorf("%s under none: no %q: value %q detail %q", c.check, textCut, v, d)
			}
		}
		if v, d := Finding(c.check, c.value, c.detail, "full"); v != c.value || d != c.detail {
			t.Errorf("%s under full changed: %q %q", c.check, v, d)
		}
	}
	// the AG finding's last change is the server's words: kept under none
	ag := "3 change(s) in the last hour, a failover among them; sqlnode2: SECONDARY_NORMAL to PRIMARY_PENDING"
	if _, d := Finding("an availability replica changed role or state", "", ag, "none"); d != ag {
		t.Errorf("the AG state change under none: %q", d)
	}
	// the cut is idempotent (alert_record's sent value and a finding cut at read join while the policy stands)
	for _, mode := range []string{"none", "normalized"} {
		_, d1 := Finding("a lead blocker", "", "x. The statement: "+stmt, mode)
		if _, d2 := Finding("a lead blocker", "", d1, mode); d2 != d1 {
			t.Errorf("not idempotent under %s: %q then %q", mode, d1, d2)
		}
	}
	// an empty field stays empty
	if v, d := Finding("a lead blocker", "", "", "none"); v != "" || d != "" {
		t.Errorf("empty fields: %q %q", v, d)
	}
}

// TestSummaryLine: the Summary's cell lines ("<check>: <value> - <detail>") cut by their check.
func TestSummaryLine(t *testing.T) {
	stmt := "DELETE FROM t WHERE k = " + secret
	for _, l := range []string{
		"a lead blocker: session 71 - Session 71 heads 5 waits. The statement: " + stmt,
		"blocked-process reports naming the same head statement: " + stmt,
		"blocked-process reports naming the same head statement" + stmt, // no ': ': fails closed
	} {
		for _, mode := range []string{"none", "normalized"} {
			if got := SummaryLine(l, mode); strings.Contains(got, "secret-7731") {
				t.Errorf("under %s: %q", mode, got)
			}
		}
	}
}

// TestChecksInMigrations: every check findText names is a check name its migrations write (a rename there would
// leave the rule matching nothing).
func TestChecksInMigrations(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("..", "repo", "sql", "*.sql"))
	if err != nil || len(files) == 0 {
		t.Fatalf("the migrations: %v", err)
	}
	var all strings.Builder
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		all.Write(b)
	}
	for check := range findText {
		if !strings.Contains(all.String(), "'"+check+"'") {
			t.Errorf("no migration writes the check %q", check)
		}
	}
}
