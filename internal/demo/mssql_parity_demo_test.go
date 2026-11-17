package demo

import (
	"fmt"
	"testing"
)

// TestParityDemo (P25 task 11b, the lead 10:28): the pages P25 added have data on the demo, never only their
// empty-state words. The fleet holds two Azure SQL Databases on one logical server in one elastic pool; their steps
// carry what the collector sends on a pooled Azure SQL Database (the server row naming the logical server, the
// resources' minutes with their histograms, the governance row with the pool and one tier change in the week - the
// Service Objectives grid -, the pool's minutes, and master's limits as periods with one DTU change - Pool history);
// -sql01's steps carry a database's scoped configuration with one change in the week (0391), its schema reads with a
// change in the week (mssql_schema: the Snapshot Summary tab is DBA Dash's schema snapshots, row 2b as reworked) and
// function and trigger statistics (0343).
func TestParityDemo(t *testing.T) {
	specs := Specs("demo-", FleetSize)
	var az []int
	for i, s := range specs {
		if s.Engine == EngineSQLServer && s.Platform == "azuresqldb" {
			az = append(az, i)
		}
	}
	if len(az) != 2 {
		t.Errorf("Azure SQL Databases in the fleet: %d, want 2", len(az))
	}
	for _, i := range az {
		s := specs[i]
		seen := map[string]int{}
		servers, objectives, pools := map[string]bool{}, map[string]bool{}, map[string]bool{}
		var lastPeriods []Row
		for _, b := range run(t, s, i, 7) {
			seen[b.Collection] += len(b.Rows)
			for _, r := range b.Rows {
				switch {
				case b.Collection == "mssql_instance" && r["kind"] == "server":
					servers[fmt.Sprint(r["server_name"])] = true
				case b.Collection == "mssql_azuredb_governance" && r["kind"] == "governance":
					objectives[fmt.Sprint(r["service_objective"])] = true
					if r["pool"] != nil {
						pools[fmt.Sprint(r["pool"])] = true
					}
				}
			}
			if b.Collection == "mssql_pool_limits" {
				lastPeriods = nil
				for _, r := range b.Rows {
					if r["kind"] == "limit_period" {
						lastPeriods = append(lastPeriods, r)
					}
				}
			}
		}
		for _, c := range []string{"mssql_instance", "mssql_azuredb_resources", "mssql_azuredb_governance", "mssql_pool", "mssql_pool_limits"} {
			if seen[c] == 0 {
				t.Errorf("%s: no %s rows", s.Name, c)
			}
		}
		for _, c := range []string{"mssql_requests", "mssql_ag", "mssql_jobs", "mssql_backups", "mssql_storage"} {
			if seen[c] != 0 {
				t.Errorf("%s: %d %s rows (an Azure SQL Database's collector does not run it)", s.Name, seen[c], c)
			}
		}
		if len(servers) != 1 || !servers["demo-sqlsrv01"] {
			t.Errorf("%s: the logical server %v, want demo-sqlsrv01 alone", s.Name, servers)
		}
		if len(pools) != 1 || !pools["pool-ledger"] {
			t.Errorf("%s: the pool %v, want pool-ledger alone", s.Name, pools)
		}
		if !objectives["ElasticPool"] || len(objectives) != 2 {
			t.Errorf("%s: the service objectives %v, want ElasticPool and the one before it (a tier change)", s.Name, objectives)
		}
		var dtus []string
		for _, r := range lastPeriods {
			dtus = append(dtus, fmt.Sprint(r["dtu_limit"]))
		}
		if fmt.Sprint(dtus) != "[50 100]" {
			t.Errorf("%s: the last limits read's DTU periods %v, want [50 100] (one change)", s.Name, dtus)
		}
	}
	// -sql01: the database tabs' rows
	sql01 := -1
	for i, s := range specs {
		if s.Name == "demo-onprem-sql01" {
			sql01 = i
		}
	}
	if sql01 < 0 {
		t.Fatal("no demo-onprem-sql01")
	}
	seen := map[string]int{}
	maxdop := map[string]bool{}
	kinds := map[string]bool{}
	procDefs := map[string]bool{}
	pcStmts := map[string]bool{}
	queues := map[string]bool{}
	for _, b := range run(t, specs[sql01], sql01, 7) {
		seen[b.Collection] += len(b.Rows)
		for _, r := range b.Rows {
			if b.Collection == "mssql_db_scoped_config" && r["name"] == "MAXDOP" {
				maxdop[fmt.Sprint(r["value"])] = true
			}
			if b.Collection == "mssql_funcstats" {
				kinds[fmt.Sprint(r["kind"])] = true
			}
			if b.Collection == "mssql_schema" && r["kind"] == "obj" && r["object_kind"] == "procedure" && r["datname"] == "Sales" {
				procDefs[fmt.Sprint(r["definition"])] = true
			}
			// the database page's Query Stats (the plan cache cut to Sales; t11-2's walker found none) and its Service
			// Broker tab (P25 row 73)
			if b.Collection == "mssql_plancache" && r["kind"] == "stmt" && r["database_name"] == "Sales" {
				pcStmts[fmt.Sprint(r["query_key"])] = true
			}
			if b.Collection == "mssql_service_broker" && r["kind"] == "queue" && r["database_name"] == "Sales" {
				queues[fmt.Sprint(r["queue_name"], " ", r["is_receive_enabled"])] = true
			}
		}
	}
	for _, c := range []string{"mssql_db_scoped_config", "mssql_schema", "mssql_funcstats", "mssql_plancache", "mssql_service_broker"} {
		if seen[c] == 0 {
			t.Errorf("demo-onprem-sql01: no %s rows", c)
		}
	}
	if len(maxdop) != 2 {
		t.Errorf("demo-onprem-sql01: the scoped MAXDOP values %v, want two (one change in the week)", maxdop)
	}
	if len(procDefs) < 2 {
		t.Errorf("demo-onprem-sql01: Sales' procedure definitions %d, want a change in the week (two or more)", len(procDefs))
	}
	if !kinds["function"] || !kinds["trigger"] {
		t.Errorf("demo-onprem-sql01: the function statistics' kinds %v, want function and trigger", kinds)
	}
	if len(pcStmts) < 3 {
		t.Errorf("demo-onprem-sql01: Sales' plan-cache statements %d, want three (the Query Stats tab)", len(pcStmts))
	}
	if !queues["OrderQueue true"] || !queues["AuditQueue false"] {
		t.Errorf("demo-onprem-sql01: Sales' Service Broker queues %v, want OrderQueue receiving and AuditQueue receive-disabled", queues)
	}
}
