package mssql

import (
	"context"
	"strings"
	"testing"
)

// Google Cloud SQL for SQL Server's rules (CLOUDSQL C2): SQL Server Agent's jobs are read with a SQL login and skipped,
// with Google's reason, for an Active Directory login there (only there); the host's power plan is not read.
func TestCloudSQLRules(t *testing.T) {
	for _, c := range []struct {
		kind    Kind
		windows bool
		run     bool
	}{
		{KindCloudSQL, false, true},
		{KindCloudSQL, true, false},
		{KindServer, true, true},
		{KindRDS, true, true},
	} {
		run, why := jobsCollector{}.Applies(Info{Kind: c.kind, WindowsLogin: c.windows, MsdbAccess: true})
		if run != c.run || (!run && !strings.Contains(why, "Active Directory logins")) {
			t.Errorf("jobs on %s (a Windows login %v): run %v %q, want run %v", c.kind, c.windows, run, why, c.run)
		}
	}
	if v, note := powerPlan(context.Background(), nil, Info{Kind: KindCloudSQL}, "Linux", true, ""); v != nil || !strings.Contains(note, "Google Cloud SQL runs the host") {
		t.Errorf("Cloud SQL's power plan: %v %q", v, note)
	}
}
