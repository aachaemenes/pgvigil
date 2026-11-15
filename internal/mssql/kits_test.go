package mssql

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// KITWATCH K4.3 (F14): the kits' versions per instance are read from the installed procedures' DEFINITIONS (three
// snippets the server cuts out: FRK's @Version line, DarlingData's @version_date, sp_WhoIsActive's header) - no
// community code runs; a definition the login cannot read (no VIEW DEFINITION) is 'not readable', never an error; a
// definition without a version line keeps its modify_date.
func TestKitVersionPayload(t *testing.T) {
	rows := []collect.Row{
		{"database_name": "master", "procedure_name": "sp_Blitz", "modify_date": "2026-07-09T10:00:00", "readable": int64(1),
			"v1": "@Version = '8.34', @VersionDate = '20260702';\nIF(@VersionCheckMode = 1)", "v2": nil, "v3": nil},
		{"database_name": "master", "procedure_name": "sp_PressureDetector", "modify_date": "2026-11-02T08:00:00", "readable": int64(1),
			"v1": "@version = '6.11',\n    @version_date = '2026", "v2": "@version_date = '20261101';", "v3": nil},
		{"database_name": "DBA", "procedure_name": "sp_WhoIsActive", "modify_date": "2026-04-10T00:00:00", "readable": int64(1),
			"v1": nil, "v2": nil, "v3": "Who Is Active? v2200.20260409 (2026-04-09)"},
		{"database_name": "master", "procedure_name": "sp_BlitzWho", "modify_date": "2026-07-09T10:00:00", "readable": int64(0), "v1": nil, "v2": nil, "v3": nil},
		{"database_name": "master", "procedure_name": "sp_HealthParser", "modify_date": "2025-01-01T00:00:00", "readable": int64(1), "v1": nil, "v2": nil, "v3": nil},
	}
	out := kitVersionPayload(rows)
	if len(out) != 6 || out[0]["kind"] != "read" {
		t.Fatalf("the payload: %d rows %v, want the read row and 5 procedures", len(out), out)
	}
	want := map[string][3]any{
		"sp_Blitz":            {"8.34", "20260702", true},
		"sp_PressureDetector": {"6.11", "20261101", true},
		"sp_WhoIsActive":      {"v2200.20260409", "20260409", true},
		"sp_BlitzWho":         {"", "", false},
		"sp_HealthParser":     {"", "", true},
	}
	for _, r := range out[1:] {
		w, ok := want[r["procedure_name"].(string)]
		if !ok || r["kind"] != "proc" || r["version"] != w[0] || r["version_date"] != w[1] || r["readable"] != w[2] || r["modify_date"] == "" {
			t.Errorf("%v: got %v, want version %v date %v readable %v and the modify_date", r["procedure_name"], r, w[0], w[1], w[2])
		}
	}
}
