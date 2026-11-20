package web

import (
	"strings"
	"testing"
)

// TestMaintenanceQueries: the Maintenance tab's reads name 0161's objects, take the instance as their first
// parameter, write nothing, and never send a CommandLog command (it can hold a password; the collector masks it, the
// page has no use for it).
func TestMaintenanceQueries(t *testing.T) {
	for name, q := range map[string]string{"checks": sqlMaintChecks, "parts": sqlMaintParts, "databases": sqlMaintDatabases, "jobs": sqlMaintJobs,
		"last": sqlMaintLast, "commandlog": sqlMaintCommandLog, "runs": sqlMaintRuns} {
		u := strings.ToUpper(q)
		if h := strings.TrimSpace(u); !strings.HasPrefix(h, "SELECT") && !strings.HasPrefix(h, "WITH ") {
			t.Errorf("%s is not a SELECT", name)
		}
		for _, bad := range []string{"INSERT ", "UPDATE ", "DELETE ", "IMPORT_"} {
			if strings.Contains(u, bad) {
				t.Errorf("%s holds %q", name, bad)
			}
		}
		if !strings.Contains(q, "$1") {
			t.Errorf("%s does not take the instance", name)
		}
	}
	if !strings.Contains(sqlMaintChecks, "pgvigil.mssql_maintenance_checks_of($1)") {
		t.Error("the grid is read through 0161's function for one instance")
	}
	// the Jobs grid is 0161's own match (a site's own history job without the solution is not listed), the last part
	// a row per database and kind (never a scan of every CommandLog row), and no command text
	if !strings.Contains(sqlMaintJobs, "pgvigil.mssql_ola_matched_jobs($1)") || strings.Contains(sqlMaintJobs, "~*") {
		t.Error("the Jobs grid reads 0161's matcher, never a looser pattern of its own")
	}
	if !strings.Contains(sqlMaintLast, "FROM pgvigil.mssql_maint_last l") || strings.Contains(sqlMaintLast, "DIFFERENTIAL") || strings.Contains(sqlMaintLast, "c.command") {
		t.Error("the last part reads mssql_maint_last: the backup's kind told by the collector, never from a cut command")
	}
	if strings.Contains(sqlMaintCommandLog, "c.command,") || strings.Contains(sqlMaintCommandLog, "c.command ") {
		t.Error("the CommandLog part sends a command")
	}
	if !strings.Contains(sqlMaintCommandLog, "LIMIT 2000") || !strings.Contains(sqlMaintCommandLog, "$2") || !strings.Contains(sqlMaintCommandLog, "$3") {
		t.Error("the CommandLog part reads the window, at most 2,000 rows")
	}
}
