package web

import (
	"os"
	"strings"
	"testing"
)

// TestObjectCellsLandOnTheObjectPage (OBJ slice 4, the lead's 11-17 13:27: every object-name cell in pgvigil lands on
// the object page): web/src/mssql_object.ts exports mssqlObjectCell (a name as a link to its page, a part holding a dot,
// a bracket or a quote put in [brackets] with ]] so the page's name split reads it back); the Object Execution grid's
// name cell is one and its 'Query Stats' link opens the object page's own Query Stats tab (DBA Dash's OES Query Stats
// link, F15 / E6) - and scripts/PARITY-S3-join-lines.sql line 13 names the cells in other slices' files.
func TestObjectCellsLandOnTheObjectPage(t *testing.T) {
	read := func(p string) string {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	obj := read("../../web/src/mssql_object.ts")
	for _, want := range []string{
		"export const mssqlObjectCell = (ctx: Ctx, db: string, schema: unknown, name: unknown, tab?: string, instance = ctx.instance): Node =>",
		"const quotePart = (s: string) => /[.\\[\\]\"]/.test(s) ? `[${s.replace(/]/g, ']]')}]` : s;",
	} {
		if !strings.Contains(obj, want) {
			t.Errorf("mssql_object.ts lacks %q", want)
		}
	}
	oex := read("../../web/src/mssql_objexec.ts")
	for _, want := range []string{
		"{ key: 'object_name', label: 'name', fmt: (v, r) => mssqlObjectCell(ctx, String(r.database), r.schema_name, v, undefined, inst(r)) }",
		"mssqlObjectHref(ctx, String(r.database), objName(r), 'querystats', inst(r))",
	} {
		if !strings.Contains(oex, want) {
			t.Errorf("mssql_objexec.ts lacks %q", want)
		}
	}
	join := read("../../scripts/PARITY-S3-join-lines.sql")
	i := strings.Index(join, "-- 13. ")
	if i < 0 {
		t.Fatal("PARITY-S3-join-lines.sql: no line 13 (the object-name cells in other slices' files)")
	}
	for _, f := range []string{"web/src/mssql_procs.ts", "web/src/mssql_plancache.ts", "web/src/mssql_xe.ts", "web/src/reports.ts", "web/src/mssql_deadlocks.ts", "web/src/schema.ts", "web/src/tree.ts", "qsdd-pgtwin"} {
		if !strings.Contains(join[i:], f) {
			t.Errorf("join line 13 does not name %s", f)
		}
	}
}
