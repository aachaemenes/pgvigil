package web

import (
	"os"
	"strings"
	"testing"
)

// TestDBConfigurationConfiguredOnlyD2 (control audit D2; DBA Dash's DB Configuration > Filter > Configured Only,
// checked by default, DBConfiguration_Get's @ConfiguredOnly: on one database the settings whose value is not the
// default): the database page's DB Configuration grid has the Configured Only box, ticked, keeping the rows whose
// default column is false; untick it for every setting. When the 0391 merge renames is_default to is_value_default
// (the lead's 13:32 map), the filter's key follows (configuredOnly's one line).
func TestDBConfigurationConfiguredOnlyD2(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_db.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i, j := strings.Index(src, "async function dbConfiguration("), strings.Index(src, "// snapshotSummary:")
	if i < 0 || j < i {
		t.Fatal("mssql_db.ts: dbConfiguration not found before snapshotSummary")
	}
	body := src[i:j]
	for _, w := range []string{"'Configured Only'", "checked: 'checked'", "configuredOnly(rows)", "r.is_default === false"} {
		if !strings.Contains(src[i-600:j], w) {
			t.Errorf("dbConfiguration lacks %s", w)
		}
	}
	if !strings.Contains(body, "'Configured Only'") {
		t.Error("the Configured Only box is not on the DB Configuration page")
	}
}
