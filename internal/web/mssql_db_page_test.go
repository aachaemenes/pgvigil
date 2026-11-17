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
	// Query Stats (sys.dm_exec_query_stats per database and query hash) is the Plan cache page fixed on this database
	if !strings.Contains(page, "mssqlPlanCacheView(ctx, db)") {
		t.Error("mssql_db.ts draws no Query Stats tab with mssqlPlanCacheView(ctx, db)")
	}
	if !regexp.MustCompile(`export async function mssqlPlanCacheView\(ctx: Ctx, onlyDb\?: string\)`).MatchString(read("mssql_plancache.ts")) {
		t.Error("mssql_plancache.ts: mssqlPlanCacheView takes no database to fix the page on")
	}
	// Object Execution (F102 / F505): one grid of the procedures, functions and triggers (mssql_objexec.ts, part=objects
	// with its Type filter and Search), on the database page cut to the database and on the instance's Procedures page
	if !strings.Contains(page, "objectExecutionSection(ctx, db)") {
		t.Error("mssql_db.ts draws no Object Execution tab with objectExecutionSection(ctx, db)")
	}
	if !strings.Contains(read("mssql_procs.ts"), "objectExecutionSection(ctx)") {
		t.Error("mssql_procs.ts: the instance's Procedures page has no Object Execution grid")
	}
	oe := read("mssql_objexec.ts")
	for _, w := range []string{"part: 'objects'", "['procedure', 'Procedures'], ['function', 'Functions'], ['trigger', 'Triggers']", "label: 'Period Time (sec)'", "label: 'Query Stats'", "label: 'Query Store'"} {
		if !strings.Contains(oe, w) {
			t.Errorf("mssql_objexec.ts has no %q", w)
		}
	}
}
