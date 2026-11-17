package web

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestSchemaTabDatabaseLinkOnSQLServer (control audit row X1): DBA Dash's schema snapshots grid links each database to
// that database's own snapshots (SchemaCompare/SchemaSnapshots.cs colDB, SS:245-250). On a SQL Server instance's Schema
// tab, each database link (the Databases grid and the Changes grid's database column) opens the SQL Server database
// page's Snapshot Summary (mssqlDbLink with the 'snapshots' tab), never the PostgreSQL database drill (dbinfo.ts dbLink,
// the 'db' page keyed by a PostgreSQL oid). A PostgreSQL reply keeps dbLink. The walker (scripts/parity-s3-pages.mjs,
// schema-dblink) reads the link the page really draws on the demo's -sql01.
func TestSchemaTabDatabaseLinkOnSQLServer(t *testing.T) {
	b, err := os.ReadFile("../../web/src/schema.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if !strings.Contains(src, "import { mssqlDbLink } from './mssql_db';") {
		t.Error("schema.ts does not import mssqlDbLink from ./mssql_db")
	}
	def := regexp.MustCompile(`(?s)const schemaDbLink = \(([^)]*)\) =>\s*(.*?);\n`).FindStringSubmatch(src)
	if def == nil {
		t.Fatal("schema.ts: no schemaDbLink helper (a database link chosen by the reply's engine)")
	}
	for _, want := range []string{"mssql ?", "mssqlDbLink(ctx, ", "'snapshots'", ": dbLink(ctx, "} {
		if !strings.Contains(def[2], want) {
			t.Errorf("schema.ts: schemaDbLink's body lacks %q: %s", want, def[2])
		}
	}
	cols := regexp.MustCompile(`\{ key: 'datname', label: 'database', fmt: \(v, r\) => ([^}]*)\}`).FindAllStringSubmatch(src, -1)
	if len(cols) != 2 {
		t.Errorf("schema.ts: %d linked database columns, want 2 (the Databases grid, the Changes grid)", len(cols))
	}
	for _, c := range cols {
		if !strings.HasPrefix(c[1], "schemaDbLink(ctx, mssql, v, r.dbid") {
			t.Errorf("schema.ts: a database column links with %q, not schemaDbLink(ctx, mssql, v, r.dbid ...)", strings.TrimSpace(c[1]))
		}
	}
	m, err := os.ReadFile("../../web/src/mssql_db.ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(m), "['snapshots', 'Snapshot Summary']") {
		t.Error("mssql_db.ts: no Snapshot Summary tab ('snapshots') for the link to open")
	}
}
