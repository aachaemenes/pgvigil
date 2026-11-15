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
