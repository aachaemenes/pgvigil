package web

import (
	"os"
	"strings"
	"testing"
)

// TestExecPagesReview5Wired (review part 5's finding 4 and NITs 7-10, read in the pages' source):
//   - Compare To reads the typed start in the display zone (tz.ts fromInput, as stmt_trend.ts), never the browser's
//     (new Date on the input's value), skips a time that is not one, and bounds the input by the range's start;
//   - the Execution Stats strip keys its lines on database_id:object_id (one object, one line), draws on its own steps
//     (never the page's shared steps g), and its empty words name the two collections' state (execstats_state);
//   - Object Execution's search keeps 128 characters at most, aborts a stale read, is kept in the address (oesearch,
//     written back as typed; the router keeps it on a range change: the wiring patch's pageKeys), and says 'every
//     database' where it lists every database (the Procedures page: its filter narrows the grids below it).
func TestExecPagesReview5Wired(t *testing.T) {
	read := func(p string) string {
		t.Helper()
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	qs := read("../../web/src/mssql_querystore.ts")
	for _, w := range []string{"fromInput(at.value)", "at.max"} {
		if !strings.Contains(qs, w) {
			t.Errorf("mssql_querystore.ts has no %s", w)
		}
	}
	if strings.Contains(qs, "new Date(at.value)") {
		t.Error("mssql_querystore.ts reads Compare To's start with new Date(at.value): the browser's zone, not the display zone")
	}
	perf := read("../../web/src/performance.ts")
	i := strings.Index(perf, "function execStatsStrip(")
	j := strings.Index(perf, "export interface PerfCut")
	if i < 0 || j < i {
		t.Fatal("performance.ts: execStatsStrip not found before PerfCut")
	}
	strip := perf[i:j]
	for _, w := range []string{"r.database_id", "r.object_id", "execstats_state", "mssql_procstats", "mssql_funcstats"} {
		if !strings.Contains(strip, w) {
			t.Errorf("execStatsStrip has no %s", w)
		}
	}
	if strings.Contains(strip, "g.map(") {
		t.Error("execStatsStrip still lays its lines on the page's shared steps (g.map)")
	}
	oe := read("../../web/src/mssql_objexec.ts")
	for _, w := range []string{"maxlength: '128'", "new AbortController()", ".signal)", "'oesearch'", "every database"} {
		if !strings.Contains(oe, w) {
			t.Errorf("mssql_objexec.ts has no %s", w)
		}
	}
	patch := read("../../scripts/PARITY-S3-wiring.patch")
	if !strings.Contains(patch, "+export const pageKeys = ['db', 'rel', 'scheduler', 'job', 'idx', 'dbtab', 'fg', 'oesearch'];") {
		t.Error("PARITY-S3-wiring.patch's pageKeys has no 'oesearch' (a range change drops the tree's search)")
	}
}

// TestAzureNodeObjexecSaysNoSource (the five node tabs' read, 13:1x): a logical server's or an elastic pool's Object
// Execution lists Azure SQL Databases, where mssql_procstats and mssql_funcstats do not run yet (internal/mssql
// procstats.go, funcstats.go): its empty words say that, never 'nothing ran'.
func TestAzureNodeObjexecSaysNoSource(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_objexec.ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "not yet on Azure SQL Database") {
		t.Error("mssql_objexec.ts: a node's empty Object Execution does not say its databases' statistics are not read on Azure SQL Database")
	}
}
