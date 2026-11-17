package web

import (
	"os"
	"strings"
	"testing"
)

// TestReviewPart10Fold (review t11-10, 11-17 15:36: no BLOCKER, 3 SHOULD, 5 NIT - folded at the branch's tip, the strip
// being E6's since): each finding's fix, by its file's words.
func TestReviewPart10Fold(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	for _, c := range []struct{ file, want, why string }{
		// SHOULD 1: the strip's empty words say when a collection's last read is before the window
		{"../../web/src/performance.ts", "esEmpty(rowsOf(d.execstats_state), window_(ctx).from)", "SHOULD 1: esEmpty does not take the window's start"},
		{"../../web/src/performance.ts", "before this window", "SHOULD 1: no words for a last read before the window"},
		// SHOULD 2: a membership through an Entra group is not seen - said, not proven otherwise (the Azure lab)
		{"../mssql/pool_limits.go", "a membership through an Entra group is not seen", "SHOULD 2: noRightWords"},
		{"../../docs/sqlserver-cloud.md", "a membership through an Entra group is not seen", "SHOULD 2: the docs"},
		// SHOULD 3: the demo's Azure SQL Database sends every capture's state, as xe.go does
		{"../demo/mssql_parity_demo.go", `"state": "not installed", "source": "product"`, "SHOULD 3: the demo keeps one capture state"},
		// NIT 4: two lines with one label get their ids
		{"../../web/src/performance.ts", "`${name} (${id})`", "NIT 4: a repeated label is not told apart"},
		// NIT 5: the line's key carries its kind
		{"internal", "", ""},
		// NIT 6: objKind cuts the read's own ORDER BY with its LIMIT
		{"q_mssql_procs.go", `strings.LastIndex(body, "\n ORDER BY ")`, "NIT 6: the inner ORDER BY is kept"},
		// NIT 7: the search's timer writes no other page's address
		{"../../web/src/mssql_objexec.ts", "if (!sec.isConnected) return;", "NIT 7: the timer writes after the page is gone"},
		// NIT 8: the server-role row skips visibly; the right's name and the docs name both reads
		{"../mssql/pool_limits_test.go", `t.Skipf("no ##MS_DatabaseManager##`, "NIT 8: the server-role row only logs"},
		{"../mssql/rights.go", "or the server role ##MS_DatabaseManager##", "NIT 8: the right's name says only dbmanager"},
		{"../../docs/sqlserver-cloud.md", "`sys.server_principals`", "NIT 8: the docs name sys.sql_logins only"},
	} {
		if c.file == "internal" {
			if !strings.Contains(read("q_performance.go"), "AS line_kind") || !strings.Contains(read("../../web/src/performance.ts"), "r.line_kind") {
				t.Error("NIT 5: the strip's line key leaves out its kind")
			}
			continue
		}
		if !strings.Contains(read(c.file), c.want) {
			t.Errorf("%s (%s)", c.why, c.file)
		}
	}
}
