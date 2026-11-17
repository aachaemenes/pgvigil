package web

import (
	"os"
	"strings"
	"testing"
)

// TestSnapshotSummaryIsTheSchemaHistory (P25 row 2b, the lead 11:00): DBA Dash's database Snapshot Summary tab is its
// SCHEMA snapshots (map-dbadash.tsv L65: Changes.SchemaSnapshots, SchemaCompare/SchemaSnapshots.cs - the snapshot and
// validated dates, the created / modified / dropped objects, each with its diff), so the SQL Server database page's
// Snapshot Summary tab shows the Schema tab's section for that database (schemaDbSection over /api/schema db=: the
// read, the changes of the range with their diffs, the objects) - never database snapshots: no part=snapshots read is
// left in mssql_db.ts, and /api/mssql/checks names no snapshots part.
func TestSnapshotSummaryIsTheSchemaHistory(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_db.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if !strings.Contains(src, "['snapshots', 'Snapshot Summary']") {
		t.Error("mssql_db.ts: no 'Snapshot Summary' tab (snapshots)")
	}
	if !strings.Contains(src, "schemaDbSection(") {
		t.Error("mssql_db.ts: the Snapshot Summary tab does not show the schema history (schemaDbSection)")
	}
	if strings.Contains(src, "part: 'snapshots'") {
		t.Error("mssql_db.ts still reads part=snapshots (database snapshots, not DBA Dash's schema snapshots)")
	}
	q, err := os.ReadFile("q_mssql_checks.go")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(q), `"snapshots"`) {
		t.Error(`q_mssql_checks.go still serves part=snapshots (database snapshots)`)
	}
}
