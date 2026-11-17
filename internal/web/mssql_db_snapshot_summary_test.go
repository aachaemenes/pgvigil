package web

import (
	"os"
	"regexp"
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
	// review t11-4 NIT 12 / SHOULD 4: the tab's own case draws snapshotSummary, which maps the name to its id through the
	// collection's per-database rows (part mssql_dbs: the never-read and not-readable databases too), never the
	// instance's databases part (present databases only), shows the section by that id, and says why a database has no read
	cs := regexp.MustCompile(`(?s)case 'snapshots':\s*(.*?)break;`).FindStringSubmatch(src)
	if cs == nil || !strings.Contains(cs[1], "snapshotSummary(ctx, db)") {
		t.Error("mssql_db.ts: case 'snapshots' does not draw snapshotSummary(ctx, db)")
	}
	fn := regexp.MustCompile(`(?s)async function snapshotSummary\(ctx: Ctx, db: string\): Promise<HTMLElement> \{(.*?)\n\}\n`).FindStringSubmatch(src)
	if fn == nil {
		t.Fatal("mssql_db.ts: no snapshotSummary(ctx, db)")
	}
	for _, want := range []string{"part: 'mssql_dbs'", "part: 'state'", "schemaDbSection(ctx, row.dbid", "row.note", "st.note"} {
		if !strings.Contains(fn[1], want) {
			t.Errorf("mssql_db.ts: snapshotSummary lacks %q", want)
		}
	}
	if strings.Contains(fn[1], "get<{ databases: Table | null }>('schema'") {
		t.Error("mssql_db.ts: snapshotSummary maps the name through the instance's databases part (present databases only)")
	}
	q, err := os.ReadFile("q_mssql_checks.go")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(q), `"snapshots"`) {
		t.Error(`q_mssql_checks.go still serves part=snapshots (database snapshots)`)
	}
}
