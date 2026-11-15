package mssql

import (
	"fmt"
	"os"
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

// The new statements against a real distributor (PGVIGIL_MSSQL_TEST_DSN, PGVIGIL_MSSQL_TEST_DISTRIBUTION: a real
// distribution database; proof-mssql-replication.sh runs this as its monitoring login): each compiles and runs.
func TestReplicationStatementsLive(t *testing.T) {
	ctx, conn, info := liveConn(t)
	dist := os.Getenv("PGVIGIL_MSSQL_TEST_DISTRIBUTION")
	if dist == "" {
		t.Skip("PGVIGIL_MSSQL_TEST_DISTRIBUTION is not set")
	}
	m, err := QueryRows(ctx, conn, replServersSQL(dist))
	if err != nil || len(m) != 1 {
		t.Fatalf("the server map: %v %v", m, err)
	}
	mapped := m[0]["mapped"] == int64(1)
	for name, q := range map[string]string{
		"published": replPublishedSQL(info.ViewServerState), "jobs": replJobsSQL(dist, info.ViewServerState),
		"publications": replPublicationsFor(dist, mapped), "subscriptions": replSubscriptionsFor(dist, mapped), "agents": replAgentsFor(dist, mapped),
	} {
		rows, err := QueryRows(ctx, conn, q)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		t.Logf("%s: %d row(s)", name, len(rows))
	}
}

// The failing time and the error over crafted history (PGVIGIL_MSSQL_TEST_REPLSTUB: a database with tables in the
// shape of a distribution database's, made by proof-mssql-replication.sh). Each agent's history marks the row its
// failing time must equal with the comment 'expected since'; an agent that must not be failing has none.
func TestReplicationFailingLive(t *testing.T) {
	ctx, conn, _ := liveConn(t)
	stub := os.Getenv("PGVIGIL_MSSQL_TEST_REPLSTUB")
	if stub == "" {
		t.Skip("PGVIGIL_MSSQL_TEST_REPLSTUB is not set")
	}
	want, err := QueryRows(ctx, conn, `SELECT CAST(a.name AS nvarchar(200)) AS agent_name, `+
		utcText("(SELECT MAX(h.time) FROM "+quoteName(stub)+".dbo.MSdistribution_history h WHERE h.agent_id = a.id AND h.comments = N'expected since')")+` AS since,
  CAST((SELECT MAX(h.comments) FROM `+quoteName(stub)+`.dbo.MSdistribution_history h WHERE h.agent_id = a.id AND h.comments LIKE N'expected code %') AS nvarchar(100)) AS code
FROM `+quoteName(stub)+`.dbo.MSdistribution_agents a`)
	if err != nil || len(want) == 0 {
		t.Fatalf("the stub's expectations: %v %v", want, err)
	}
	// as the collector does: the merge arm only where the database has the merge tables (this stub has none: the
	// statement without them must still read its distribution agents - the guard of replMergeTablesSQL)
	mt, err := QueryRows(ctx, conn, replMergeTablesSQL(stub))
	if err != nil || len(mt) != 1 {
		t.Fatalf("the merge tables of the stub: %v %v", mt, err)
	}
	got, err := QueryRows(ctx, conn, replSubscriptionsOf(stub, false, mt[0]["merge"] == int64(1)))
	if err != nil {
		t.Fatalf("the subscriptions read of the stub: %v", err)
	}
	by := map[string]map[string]any{}
	for _, r := range got {
		by[fmt.Sprint(r["agent_name"])] = r
	}
	for _, w := range want {
		name := fmt.Sprint(w["agent_name"])
		r, ok := by[name]
		if !ok {
			t.Errorf("%s: not read", name)
			continue
		}
		if fmt.Sprint(r["failing_since_utc"]) != fmt.Sprint(w["since"]) {
			t.Errorf("%s: failing since %v, want %v", name, r["failing_since_utc"], w["since"])
		}
		if code, _ := w["code"].(string); code != "" && fmt.Sprint(r["error_code"]) != strings.TrimPrefix(code, "expected code ") {
			t.Errorf("%s: error code %v, want %s", name, r["error_code"], strings.TrimPrefix(code, "expected code "))
		}
		t.Logf("%s: failing since %v, error %v", name, r["failing_since_utc"], r["error_code"])
	}
}
