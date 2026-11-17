package web

import (
	"os"
	"strings"
	"testing"
)

// TestObjectExecutionLinksCutE7 (control audit E7; DBA Dash's Object Execution Query Stats and Query Store links open
// the object's own tabs): the grid's Query Store column opens the object page's Query Store tab (mssqlObjectHref
// 'qs'), as its Query Stats column opens 'querystats' - never the whole database's Top Queries tab.
func TestObjectExecutionLinksCutE7(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_objexec.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "key: 'qstore_link'")
	if i < 0 {
		t.Fatal("mssql_objexec.ts: the Query Store column is gone")
	}
	line := src[i:]
	if k := strings.Index(line, "\n"); k > 0 {
		line = line[:k]
	}
	if !strings.Contains(line, "mssqlObjectHref(ctx, String(r.database), objName(r), 'qs', inst(r))") || strings.Contains(line, "'topqueries'") {
		t.Errorf("the Query Store column does not open the object's Query Store tab: %s", line)
	}
}
