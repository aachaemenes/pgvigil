package web

import (
	"os"
	"strings"
	"testing"
)

// TestObjectTabsKeepCompareTo (control audit E3 b's gap, found 11-17 15:1x): the object page's tab links carry ocmp=,
// so a move from Schema History back to Object Execution keeps DBA Dash's compare chart (hrefWith drops every page key
// it is not given).
func TestObjectTabsKeepCompareTo(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_object.ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "mssqlObjectHref(ctx, where, obj, k, undefined, { ocmp: hashParam('ocmp') ?? undefined })") {
		t.Error("mssql_object.ts: the object page's tab links drop ocmp=")
	}
}
