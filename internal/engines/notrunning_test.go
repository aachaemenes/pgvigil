package engines

import (
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// N59: the list follows the scheduler (disabled:, schedules: disabled at both levels, a default of none) and each
// engine's Applies; a server not detected lists the configuration's reasons alone.
func TestNotRunning(t *testing.T) {
	cfg := &config.Config{Schedules: map[string]config.Duration{"mssql_waits": {Duration: 0}}}
	in := config.Instance{Name: "a", Engine: config.EngineSQLServer, Disabled: []string{"mssql_ag"},
		Schedules: map[string]config.Duration{"mssql_xe": {Duration: 0}}}
	box := &mssql.Info{Kind: mssql.KindServer, ViewServerState: true, ViewAnyDefinition: true, MsdbAccess: true, ViewDatabaseState: true, ServerStateRead: true, Major: 16, VersionNum: 160000, EngineEdition: 3}
	out, total := NotRunning(cfg, in, nil, box)
	why := map[string]string{}
	for _, n := range out {
		why[n.Name] = n.Why
	}
	if total == 0 || len(out) == 0 {
		t.Fatalf("total %d, not running %d", total, len(out))
	}
	for name, want := range map[string]string{
		"mssql_ag": "disabled: list", "mssql_xe": "instance's schedules", "mssql_waits": "configuration's schedules",
		"mssql_azuredb_resources": "Azure SQL Database",
	} {
		if !strings.Contains(why[name], want) {
			t.Errorf("%s: %q, want it naming %q", name, why[name], want)
		}
	}
	// PostgreSQL: a server not detected lists only the configuration's reasons; amcheck is off by default
	pout, _ := NotRunning(&config.Config{}, config.Instance{Name: "p"}, nil, nil)
	for _, n := range pout {
		if n.Name == "amcheck" && !strings.Contains(n.Why, "off by default") {
			t.Errorf("amcheck: %q", n.Why)
		}
	}
	// a detected RDS server: the CloudWatch reads say they need the aws: block
	rds := &platform.Info{Kind: platform.RDS, ServerVersionNum: 160000}
	rout, _ := NotRunning(&config.Config{}, config.Instance{Name: "r"}, rds, nil)
	found := false
	for _, n := range rout {
		if strings.Contains(n.Why, "aws") {
			found = true
		}
	}
	if !found {
		t.Error("an RDS instance without an aws: block: no line names it")
	}
	// rel-b24p's merge (B24e's WIRING line with 390a): an Azure SQL Database with no azure: block lists the failover
	// groups' read with its Configured reason, detected or not (RunOnce asks Applies, then Configured)
	az := &mssql.Info{Kind: mssql.KindAzureDB, ViewDatabaseState: true, Major: 12, VersionNum: 120000, EngineEdition: 5}
	for _, det := range []*mssql.Info{az, nil} {
		aout, _ := NotRunning(&config.Config{}, config.Instance{Name: "z", Engine: config.EngineSQLServer}, nil, det)
		got := ""
		for _, n := range aout {
			if n.Name == "mssql_failover_groups" {
				got = n.Why
			}
		}
		if !strings.Contains(got, "no azure: block") {
			t.Errorf("an Azure SQL Database without an azure: block (detected %v): mssql_failover_groups %q, want its Configured reason", det != nil, got)
		}
	}
	_ = time.Second
}

// Review 11: the list on the configuration and the instance as the scheduler builds them - the file's schedules:
// turning amcheck on, an aws: block opening the CloudWatch reads, a page instance's PageDefaults (its running plans
// box) - never the defaults alone.
func TestNotRunningOnTheConfig(t *testing.T) {
	names := func(out []NotRun) map[string]string {
		m := map[string]string{}
		for _, n := range out {
			m[n.Name] = n.Why
		}
		return m
	}
	// amcheck runs when the instance's own schedules name it (its Configured gate); the file's schedules: alone keeps
	// it off by that gate's words, not 'off by default'
	own := config.Instance{Name: "p", Schedules: map[string]config.Duration{"amcheck": {Duration: time.Hour}}}
	if why, ok := names(first(NotRunning(&config.Config{}, own, nil, nil)))["amcheck"]; ok {
		t.Errorf("amcheck listed (%q) on an instance whose schedules name it", why)
	}
	cfg := &config.Config{Schedules: map[string]config.Duration{"amcheck": {Duration: time.Hour}}}
	if why := names(first(NotRunning(cfg, config.Instance{Name: "p"}, nil, nil)))["amcheck"]; !strings.Contains(why, "opt-in per instance") {
		t.Errorf("amcheck with the file's schedules: alone: %q, want the gate's 'opt-in per instance'", why)
	}
	rds := &platform.Info{Kind: platform.RDS, ServerVersionNum: 160000}
	withAWS := config.Instance{Name: "r", AWS: &config.AWS{Region: "us-east-2", DBInstance: "db1"}}
	for name, why := range names(first(NotRunning(&config.Config{}, withAWS, rds, nil))) {
		if strings.Contains(why, "aws:") {
			t.Errorf("%s: %q on an instance with its aws: block", name, why)
		}
	}
	all, _ := config.Merge(nil, []config.PageInstance{{Name: "m", Engine: config.EngineSQLServer, DSNRef: "file:/x", RunningPlans: true}}, "", config.CounterEdits{})
	if len(all) != 1 {
		t.Fatalf("Merge: %v", all)
	}
	if why, ok := names(first(NotRunning(&config.Config{}, all[0], nil, nil)))["mssql_running_plans"]; ok {
		t.Errorf("mssql_running_plans listed (%q) on a page instance whose running plans box is ticked", why)
	}
}

func first(out []NotRun, _ int) []NotRun { return out }
