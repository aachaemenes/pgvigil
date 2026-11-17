package web

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestMSSQLDatabasePageIsWired (P25, F101 / F103): a SQL Server database has its own page - web/src/mssql_db.ts with
// DBA Dash's 13 database tabs in DBA Dash's order (GUI/Main.cs L1903-1914: Performance first) - reached as the drill
// tab 'mssqldb' (router.ts drillTabs, its strip marked on DB Space), drawn by main.ts mssqlPages, and its page
// parameters (dbtab, the tab; fg, the IO chart's file group) kept by hrefWith and by a range change. The check reads
// the source.
func TestMSSQLDatabasePageIsWired(t *testing.T) {
	read := func(file string) string {
		t.Helper()
		b, err := os.ReadFile("../../web/src/" + file)
		if err != nil {
			t.Fatalf("web/src/%s: %v", file, err)
		}
		return string(b)
	}
	page := read("mssql_db.ts")
	want := []string{"Performance", "Object Execution", "Query Stats", "Slow Queries", "Files", "Snapshot Summary", "DB Space",
		"DB Configuration", "DB Options", "QS", "Top Queries", "Forced Plans", "Tuning Recommendations"}
	var got []string
	for _, m := range regexp.MustCompile(`\['[a-z]+', '([A-Za-z ]+)'\]`).FindAllStringSubmatch(page, -1) {
		got = append(got, m[1])
	}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("mssql_db.ts tabs %q, want DBA Dash's 13 in its order %q", got, want)
	}
	router := read("router.ts")
	if !regexp.MustCompile(`drillTabs: Record<string, string> = \{[^}]*\bmssqldb: 'Database'`).MatchString(router) {
		t.Error("router.ts drillTabs has no mssqldb: 'Database' (the page would open the Summary)")
	}
	if !regexp.MustCompile(`drillHome: Record<string, string> = \{[^}]*\bmssqldb: 'dbspace'`).MatchString(router) {
		t.Error("router.ts drillHome has no mssqldb: 'dbspace' (the strip would mark no tab)")
	}
	if !regexp.MustCompile(`const mssqlPages: Record<string, Render> = \{[\s\S]*?\bmssqldb: mssqlDbView\b`).MatchString(read("main.ts")) {
		t.Error("main.ts mssqlPages has no mssqldb: mssqlDbView")
	}
	keys := regexp.MustCompile(`export const pageKeys = \[([^\]]*)\]`).FindStringSubmatch(read("dbinfo.ts"))
	if keys == nil || !strings.Contains(keys[1], "'dbtab'") || !strings.Contains(keys[1], "'fg'") {
		t.Errorf("dbinfo.ts pageKeys %v keep no dbtab / fg (a link to another tab would carry the old one)", keys)
	}
	if !regexp.MustCompile(`for \(const k of \[[^\]]*'dbtab', 'fg'\]\)`).MatchString(router) {
		t.Error("router.ts: a range change on a drill page keeps no dbtab / fg")
	}
	// DBA Dash's four Query Store tabs are the Query Store page's views on this database (mssql_querystore.ts reads
	// qs= and qdb= from the hash): QS its store state, Top Queries its top, Forced Plans its forced plans, Tuning
	// Recommendations its tuning
	views := regexp.MustCompile(`const qsViews: Record<string, string> = \{([^}]*)\}`).FindStringSubmatch(page)
	if views == nil || !strings.Contains(views[1], "qs: 'state'") || !strings.Contains(views[1], "topqueries: 'top'") ||
		!strings.Contains(views[1], "forcedplans: 'forced'") || !strings.Contains(views[1], "tuning: 'tuning'") {
		t.Errorf("mssql_db.ts qsViews %v: want qs state, topqueries top, forcedplans forced, tuning tuning", views)
	}
	if !strings.Contains(page, "mssqlQueryStoreView(ctx)") {
		t.Error("mssql_db.ts draws no Query Store tab with mssqlQueryStoreView")
	}
}
