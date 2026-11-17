package web

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestMSSQLObjectTabsRead (OBJ slice 3): each tab of the object page draws from its own read - Object Execution the
// object's intervals and history by its kind (db_id=, object=, kind=, one part a call), Query Stats part=object_statements
// by its module, Slow Queries part=object_slow by its bare name in its database, Schema History part=object_schema with
// the Schema tab's compare and DBA Dash's empty words, Query Store a link to the Query Store's Top list cut to the object
// (QSPAR's qs=top&qid=<schema.name>&qdb=, its find box), Running Queries the words that the running requests do not carry
// the object's name yet (qsdd-pgtwin's column, the lead's 13:42 D2 (a)) - and no tab says 'not built yet'.
func TestMSSQLObjectTabsRead(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_object.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if strings.Contains(src, "not built yet") {
		t.Error("mssql_object.ts still says a tab is not built yet")
	}
	body := func(fn string) string {
		m := regexp.MustCompile(`(?s)\n(?:async )?function ` + fn + `\(.*?\n\}\n`).FindString(src)
		if m == "" {
			t.Errorf("mssql_object.ts: no function %s", fn)
		}
		return m
	}
	for fn, wants := range map[string][]string{
		"objexecTab":    {"part: 'intervals'", "part: 'history'", "kind:", "db_id:", "object:"},
		"statementsTab": {"part: 'object_statements'", "module:"},
		"slowTab":       {"part: 'object_slow'", "dbname:"},
		"schemaTab":     {"part: 'object_schema'", "compareCell(ctx)", "No schema snapshots include this object"},
		"qsTab":         {"qs: 'top'", "qid:", "qdb:"},
		"runningTab":    {"do not carry the object's name yet"},
	} {
		b := body(fn)
		for _, w := range wants {
			if !strings.Contains(b, w) {
				t.Errorf("mssql_object.ts %s lacks %q", fn, w)
			}
		}
	}
	sw := regexp.MustCompile(`(?s)switch \(tab\) \{(.*?)\n  \}`).FindStringSubmatch(src)
	if sw == nil {
		t.Fatal("mssql_object.ts: no switch over the tab")
	}
	for tab, fn := range map[string]string{"objexec": "objexecTab", "querystats": "statementsTab", "running": "runningTab", "slow": "slowTab", "qs": "qsTab", "schema": "schemaTab"} {
		if !regexp.MustCompile(`case '` + tab + `':[^\n]*` + fn + `\(`).MatchString(sw[1]) {
			t.Errorf("mssql_object.ts: case '%s' does not draw %s", tab, fn)
		}
	}
	s, err := os.ReadFile("../../web/src/schema.ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(s), "export function compareCell(ctx: Ctx)") {
		t.Error("schema.ts: compareCell is not exported for the object page's Schema History")
	}
}
