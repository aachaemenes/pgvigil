package mssql

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// A merge agent is its subscription (one agent per merge subscription, as a distribution agent is one per
// transactional subscription): it is read by the subscriptions statement, with its failing time and error, and no
// longer by the agents statement.
func TestReplicationMergeShape(t *testing.T) {
	for _, mapped := range []bool{false, true} {
		sub, agents := replSubscriptionsFor("d", mapped), replAgentsFor("d", mapped)
		for _, want := range []string{"[d].dbo.MSmerge_agents", "[d].dbo.MSmerge_sessions", "[d].dbo.MSmerge_history", "[d].dbo.MSmerge_subscriptions", "'merge'"} {
			if !strings.Contains(sub, want) {
				t.Errorf("mapped %v: the subscriptions statement does not read %s", mapped, want)
			}
		}
		if strings.Contains(agents, "MSmerge_agents") {
			t.Errorf("mapped %v: the agents statement still reads the merge agents (they are subscriptions now)", mapped)
		}
		up := strings.ToUpper(sub)
		for _, never := range []string{"INSERT ", "UPDATE ", "DELETE ", "EXEC ", "EXECUTE ", "CREATE ", "ALTER ", "DROP "} {
			if strings.Contains(up, never) {
				t.Errorf("mapped %v: the subscriptions statement contains %q", mapped, never)
			}
		}
	}
}

// The merge rows over crafted history (PGVIGIL_MSSQL_TEST_MERGESTUB: a database with tables in the shape of a
// distribution database's merge tables, made by proof-mssql-merge.sh part T). Each agent's history marks the session
// whose start its failing time must equal with the comment 'expected since', and the cause code with 'expected code
// <n>'; an agent that must not be failing has neither. Every merge agent is one subscription row and no agent row;
// its last run is its newest session's end, or its start while it runs; its subscriber falls back to MSmerge_agents'
// subscriber_name where the server map has no entry ('SUBX'); its type is the subscription's of its own publication
// (written here, not recomputed: merge-idle and merge-pull2 subscribe s1 to two publications, push and pull).
func TestReplicationMergeLive(t *testing.T) {
	ctx, conn, _ := liveConn(t)
	stub := os.Getenv("PGVIGIL_MSSQL_TEST_MERGESTUB")
	if stub == "" {
		t.Skip("PGVIGIL_MSSQL_TEST_MERGESTUB is not set")
	}
	s := quoteName(stub)
	want, err := QueryRows(ctx, conn, `SELECT CAST(a.name AS nvarchar(200)) AS agent_name,
  `+utcText(`(SELECT MAX(x.start_time) FROM `+s+`.dbo.MSmerge_sessions x JOIN `+s+`.dbo.MSmerge_history h ON h.session_id = x.session_id AND h.agent_id = x.agent_id
             WHERE x.agent_id = a.id AND h.comments = N'expected since')`)+` AS since,
  CAST((SELECT MAX(h.comments) FROM `+s+`.dbo.MSmerge_history h WHERE h.agent_id = a.id AND h.comments LIKE N'expected code %') AS nvarchar(100)) AS code,
  (SELECT TOP (1) x.runstatus FROM `+s+`.dbo.MSmerge_sessions x WHERE x.agent_id = a.id ORDER BY x.session_id DESC) AS runstatus,
  `+utcText(`(SELECT TOP (1) COALESCE(x.end_time, x.start_time) FROM `+s+`.dbo.MSmerge_sessions x WHERE x.agent_id = a.id ORDER BY x.session_id DESC)`)+` AS last_run
FROM `+s+`.dbo.MSmerge_agents a`)
	types := map[string]string{"merge-idle": "push", "merge-retrying": "push", "merge-failed-again": "push", "merge-recovered": "push",
		"merge-never-ok": "pull", "merge-pull2": "pull"}
	if err != nil || len(want) == 0 {
		t.Fatalf("the stub's expectations: %v %v", want, err)
	}
	got, err := QueryRows(ctx, conn, replSubscriptionsFor(stub, false))
	if err != nil {
		t.Fatalf("the subscriptions read of the stub: %v", err)
	}
	by := map[string]map[string]any{}
	for _, r := range got {
		if r["agent_type"] == "merge" {
			by[fmt.Sprint(r["agent_name"])] = r
		}
	}
	for _, w := range want {
		name := fmt.Sprint(w["agent_name"])
		r, ok := by[name]
		if !ok {
			t.Errorf("%s: not read as a merge subscription", name)
			continue
		}
		if r["kind"] != "subscription" {
			t.Errorf("%s: kind %v, want subscription", name, r["kind"])
		}
		if fmt.Sprint(r["failing_since_utc"]) != fmt.Sprint(w["since"]) {
			t.Errorf("%s: failing since %v, want %v", name, r["failing_since_utc"], w["since"])
		}
		var wantCode any // no mark: no error code
		if code, _ := w["code"].(string); code != "" {
			wantCode = strings.TrimPrefix(code, "expected code ")
		}
		if fmt.Sprint(r["error_code"]) != fmt.Sprint(wantCode) {
			t.Errorf("%s: error code %v, want %v", name, r["error_code"], wantCode)
		}
		if fmt.Sprint(r["runstatus"]) != fmt.Sprint(w["runstatus"]) {
			t.Errorf("%s: runstatus %v, want the newest session's %v", name, r["runstatus"], w["runstatus"])
		}
		if fmt.Sprint(r["subscription_type"]) != types[name] {
			t.Errorf("%s: subscription type %v, want %v", name, r["subscription_type"], types[name])
		}
		if fmt.Sprint(r["last_run_utc"]) != fmt.Sprint(w["last_run"]) {
			t.Errorf("%s: last run %v, want the newest session's end or start %v", name, r["last_run_utc"], w["last_run"])
		}
		if r["subscriber"] != "SUBX" {
			t.Errorf("%s: subscriber %v, want SUBX (MSmerge_agents.subscriber_name)", name, r["subscriber"])
		}
		if r["subscription_status"] != nil || r["undistributed"] != nil || r["latency_ms"] != nil {
			t.Errorf("%s: status %v, undistributed %v, latency %v: the distributor keeps none of them for merge (want NULL)",
				name, r["subscription_status"], r["undistributed"], r["latency_ms"])
		}
		t.Logf("%s: runstatus %v, failing since %v, error %v: %v", name, r["runstatus"], r["failing_since_utc"], r["error_code"], r["error_text"])
	}
	agents, err := QueryRows(ctx, conn, replAgentsFor(stub, false))
	if err != nil {
		t.Fatalf("the agents read of the stub: %v", err)
	}
	for _, r := range agents {
		if r["agent_type"] == "merge" {
			t.Errorf("%v: still read as an agent row", r["agent_name"])
		}
	}
}
