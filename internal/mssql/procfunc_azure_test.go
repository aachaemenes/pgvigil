package mssql

import (
	"strings"
	"testing"
)

// TestProcFuncStatsOnAzureSQLDatabase (control audit row A8, the lead's 13:08): mssql_procstats and mssql_funcstats
// run on Azure SQL Database, so a logical server's or an elastic pool's Object Execution has a source. Microsoft
// Learn (read 2026-11-17: sys.dm_exec_procedure_stats, _function_stats, _trigger_stats, sys.dm_os_sys_info): each
// applies to Azure SQL Database; on Basic, S0, S1 and in an elastic pool it asks for the server admin, the Entra
// admin or ##MS_ServerStateReader##, elsewhere VIEW DATABASE STATE or that role - the rule detect's ViewServerState
// already reads on Azure SQL Database. database_id there is 'unique within a single database or an elastic pool,
// but not within a logical server': each read is cut to the connection's own database (EngineEdition 5), so a pooled
// database never stores another's rows. sys.server_triggers is a server's catalog: on Azure SQL Database its read is
// not run (dynamic SQL behind the edition), and the databases asked for names are the connection's own.
func TestProcFuncStatsOnAzureSQLDatabase(t *testing.T) {
	for _, name := range []string{Prefix + "procstats", Prefix + "funcstats"} {
		c, ok := registry[name]
		if !ok {
			t.Fatalf("%s is not registered", name)
		}
		if ok, why := c.Applies(Info{Kind: KindAzureDB, ServiceObjective: "ElasticPool", ViewServerState: true}); !ok {
			t.Errorf("%s on Azure SQL Database with the right: skipped %q, want it run", name, why)
		}
		ok, why := c.Applies(Info{Kind: KindAzureDB, ServiceObjective: "ElasticPool"})
		if ok || !strings.Contains(why, "##MS_ServerStateReader##") || !strings.Contains(why, "VIEW DATABASE STATE") {
			t.Errorf("%s on Azure SQL Database without the right: %v %q, want skipped naming ##MS_ServerStateReader## and VIEW DATABASE STATE", name, ok, why)
		}
		if ok, _ := c.Applies(Info{Kind: KindServer, Major: 16, ViewServerState: true}); !ok {
			t.Errorf("%s on a server with VIEW SERVER STATE: skipped, want it run (unchanged)", name)
		}
	}
	cut := "(CAST(SERVERPROPERTY('EngineEdition') AS int) <> 5 OR ps.database_id = DB_ID())"
	for _, names := range []bool{true, false} {
		if q := procStatsQuery(names); !strings.Contains(q, cut) {
			t.Errorf("procStatsQuery(%v) is not cut to the connection's database on Azure SQL Database: %s", names, q)
		}
		for _, v := range []string{"sys.dm_exec_function_stats", "sys.dm_exec_trigger_stats"} {
			if q := funcStatsQuery("function", v, names, nil); !strings.Contains(q, strings.ReplaceAll(cut, "ps.", "fs.")) {
				t.Errorf("funcStatsQuery(%s, %v) is not cut to the connection's database: %s", v, names, q)
			}
		}
	}
	if !strings.Contains(funcStatsDatabasesSQL, "(CAST(SERVERPROPERTY('EngineEdition') AS int) <> 5 OR d.database_id = DB_ID())") {
		t.Errorf("funcStatsDatabasesSQL asks other databases on Azure SQL Database: %s", funcStatsDatabasesSQL)
	}
	if !strings.Contains(serverTriggersSQL, "EngineEdition") || !strings.Contains(serverTriggersSQL, "EXEC") {
		t.Errorf("serverTriggersSQL reads sys.server_triggers on Azure SQL Database too: %s", serverTriggersSQL)
	}
}

// TestProcFuncReadsLive (PGVIGIL_MSSQL_TEST_DSN, a sysadmin login on SQL Server 2017 or later): the reads with the
// Azure cut still run on a server someone runs (EngineEdition 2 or 3: the cut lets every database through).
func TestProcFuncReadsLive(t *testing.T) {
	ctx, conn, _ := liveConn(t)
	for name, q := range map[string]string{
		"procStatsQuery":          procStatsQuery(true),
		"funcStatsQuery function": funcStatsQuery("function", "sys.dm_exec_function_stats", true, nil),
		"funcStatsQuery trigger":  funcStatsQuery("trigger", "sys.dm_exec_trigger_stats", true, nil),
		"funcStatsDatabasesSQL":   funcStatsDatabasesSQL,
		"serverTriggersSQL":       serverTriggersSQL,
	} {
		if _, err := QueryRows(ctx, conn, q); err != nil {
			t.Errorf("%s on SQL Server: %v", name, err)
		}
	}
	rows, err := QueryRows(ctx, conn, funcStatsDatabasesSQL)
	if err != nil || len(rows) < 2 {
		t.Errorf("funcStatsDatabasesSQL on SQL Server: %d rows, %v - want every database the login enters (master, msdb, ...)", len(rows), err)
	}
}
