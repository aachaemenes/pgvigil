package mssql

import (
	"context"
	"strings"
	"testing"
)

// Google Cloud SQL for SQL Server's rules (CLOUDSQL C2): SQL Server Agent's jobs skipped with Google's reason when msdb
// refuses the login (Google protects msdb from logins made in T-SQL); the host's power plan not read; the mark asked
// only of a box edition with no rdsadmin and no platform named.
func TestCloudSQLRules(t *testing.T) {
	for _, c := range []struct {
		kind  Kind
		msdb  bool
		run   bool
		words string
	}{
		{KindCloudSQL, true, true, ""},
		{KindCloudSQL, false, false, "Cloud SQL protects msdb from logins made in T-SQL"},
		{KindServer, false, false, "no access to msdb"},
	} {
		run, why := jobsCollector{}.Applies(Info{Kind: c.kind, MsdbAccess: c.msdb})
		if run != c.run || !strings.Contains(why, c.words) {
			t.Errorf("jobs on %s (msdb %v): run %v %q, want run %v with %q", c.kind, c.msdb, run, why, c.run, c.words)
		}
	}
	if v, note := powerPlan(context.Background(), nil, Info{Kind: KindCloudSQL}, "Linux", true, ""); v != nil || !strings.Contains(note, "Google Cloud SQL runs the host") {
		t.Errorf("Cloud SQL's power plan: %v %q", v, note)
	}
	for _, c := range []struct {
		ee     int
		rds    bool
		forced string
		ask    bool
	}{
		{2, false, "", true}, {3, false, "auto", true}, {4, false, "", true},
		{5, false, "", false}, {8, false, "", false}, {3, true, "", false}, {3, false, "onprem", false}, {3, false, "cloudsql", false},
	} {
		if got := askCloudSQL(c.ee, c.rds, c.forced); got != c.ask {
			t.Errorf("askCloudSQL(%d, rds %v, %q) = %v, want %v (Azure SQL Database, Managed Instance and RDS never run the mark's statement)", c.ee, c.rds, c.forced, got, c.ask)
		}
	}
}
