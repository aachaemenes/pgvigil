package mssql

import (
	"strings"
	"testing"
)

// the replication statements added for task 385 (the publisher side, the agents' jobs, the server map, both forms of
// the distributor reads): every one a SELECT that writes nothing, calls no procedure and posts no tracer token
func TestReplicationStatementsReadOnly(t *testing.T) {
	stmts := map[string]string{
		"published": replPublishedSQL(true), "published without counters": replPublishedSQL(false),
		"jobs": replJobsSQL("distribution", true), "jobs without server state": replJobsSQL("distribution", false),
		"servers":             replServersSQL("distribution"),
		"publications mapped": replPublicationsFor("distribution", true), "subscriptions mapped": replSubscriptionsFor("distribution", true),
		"agents mapped": replAgentsFor("distribution", true),
	}
	for name, q := range stmts {
		up := strings.ToUpper(q)
		for _, never := range []string{"INSERT ", "UPDATE ", "DELETE ", "MERGE ", "EXEC ", "EXECUTE ", "CREATE ", "ALTER ", "DROP ",
			"SET LOCK_TIMEOUT", "SET TRANSACTION", "SP_POSTTRACERTOKEN", "SP_REPLMONITOR"} {
			if strings.Contains(up, never) {
				t.Errorf("%s contains %q", name, never)
			}
		}
		if !strings.HasPrefix(strings.TrimSpace(up), "SELECT") {
			t.Errorf("%s is not a SELECT", name)
		}
	}
	// the mapped forms name servers through the distribution database's MSreplservers, the plain forms through sys.servers
	if !strings.Contains(replSubscriptionsFor("d", true), "[d].dbo.MSreplservers") || strings.Contains(replSubscriptionsSQL("d"), "MSreplservers") {
		t.Error("the server map is not chosen by the flag")
	}
	// the counters need VIEW SERVER STATE: the form without them does not read them
	if strings.Contains(replPublishedSQL(false), "dm_os_performance_counters") || strings.Contains(replJobsSQL("d", false), "dm_server_services") {
		t.Error("a form without VIEW SERVER STATE reads a DMV that needs it")
	}
}
