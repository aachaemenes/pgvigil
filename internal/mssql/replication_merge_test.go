package mssql

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"
)

// subscriberCol: MSmerge_subscriptions' subscriber column itself, never subscriber_id or subscriber_db
var subscriberCol = regexp.MustCompile(`m\.subscriber([^_A-Za-z0-9]|$)`)

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
		if without := replSubscriptionsOf("d", mapped, false); strings.Contains(without, "MSmerge_") {
			t.Errorf("mapped %v: the statement without the merge tables still reads them", mapped)
		}
		// the subscriber's name is read only where the probe found the column (Microsoft's page lists none): the plain
		// form names no m.subscriber column at all (a 2016-2019 distributor without it would refuse the whole read)
		if subscriberCol.MatchString(sub) || !strings.Contains(replSubscriptionsWith("d", mapped, true, true), "UPPER(m.subscriber)") {
			t.Errorf("mapped %v: the subscriber name match must be in the names form only", mapped)
		}
		up := strings.ToUpper(sub + replSubscriptionsWith("d", mapped, true, true) + replMergeTablesSQL("d"))
		for _, never := range []string{"INSERT ", "UPDATE ", "DELETE ", "EXEC ", "EXECUTE ", "CREATE ", "ALTER ", "DROP "} {
			if strings.Contains(up, never) {
				t.Errorf("mapped %v: the subscriptions statement contains %q", mapped, never)
			}
		}
	}
}

// The merge rows over crafted history (PGVIGIL_MSSQL_TEST_MERGESTUB: a database with tables in the shape of a
// distribution database's merge tables, made by proof-mssql-merge.sh part T). Each agent's history marks the error id
// whose MSrepl_errors time its failing time must equal with the comment 'expected since', the cause code with
// 'expected code <n>', and a failing agent with no error time with 'expected untimed'; an agent that must not be
// failing has none of them. A session in progress is healthy while its own history holds no error row (the Windows
// lab: a continuous merge agent's healthy session stays in progress until its job stops), so a retry's first seconds
// read 'not failing' (merge-flicker-b) and its first error row puts the first failure's time back (merge-flicker-c).
// A merge publication's articles are NULL: the distributor keeps none for it. Every merge agent is one subscription row and no agent row;
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
  `+utcText(`(SELECT MIN(e.time) FROM `+s+`.dbo.MSrepl_errors e JOIN `+s+`.dbo.MSmerge_history h ON h.error_id = e.id
             WHERE h.agent_id = a.id AND h.comments = N'expected since')`)+` AS since,
  CAST((SELECT MAX(h.comments) FROM `+s+`.dbo.MSmerge_history h WHERE h.agent_id = a.id AND h.comments LIKE N'expected code %') AS nvarchar(100)) AS code,
  (SELECT TOP (1) 1 FROM `+s+`.dbo.MSmerge_history h WHERE h.agent_id = a.id AND h.comments = N'expected untimed') AS untimed,
  (SELECT TOP (1) x.runstatus FROM `+s+`.dbo.MSmerge_sessions x WHERE x.agent_id = a.id ORDER BY x.session_id DESC) AS runstatus,
  `+utcText(`(SELECT TOP (1) COALESCE(x.end_time, x.start_time) FROM `+s+`.dbo.MSmerge_sessions x WHERE x.agent_id = a.id ORDER BY x.session_id DESC)`)+` AS last_run
FROM `+s+`.dbo.MSmerge_agents a`)
	types := map[string]string{"merge-idle": "push", "merge-retrying": "push", "merge-failed-again": "push", "merge-recovered": "push",
		"merge-never-ok": "pull", "merge-pull2": "pull", "merge-2022-names": "push", "merge-late-error": "push",
		"merge-recovered-running": "push", "merge-failing-in-progress": "push", "merge-flicker-a": "push", "merge-flicker-b": "push",
		"merge-flicker-c": "push", "merge-untimed": "push", "merge-flapping": "push", "merge-start-error": "push",
		"merge-day-old-error": "push", "merge-errors-60s": "push", "merge-recovered-then-failing": "push", "merge-hold": "push",
		"merge-hold-expired": "push"}
	if err != nil || len(want) == 0 {
		t.Fatalf("the stub's expectations: %v %v", want, err)
	}
	// as the collector does: the probe first (this stub has the four merge tables, MSmerge_subscriptions in the 2022
	// shape with its subscriber column: has_merge 1, has_sub_names 1)
	mt, err := QueryRows(ctx, conn, replMergeTablesSQL(stub))
	if err != nil || len(mt) != 1 || mt[0]["has_merge"] != int64(1) || mt[0]["has_sub_names"] != int64(1) {
		t.Fatalf("the merge tables of the stub (all four, the subscriber column: has_merge 1, has_sub_names 1): %v %v", mt, err)
	}
	got, err := QueryRows(ctx, conn, replSubscriptionsWith(stub, false, true, true))
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
		if fmt.Sprint(r["failing_untimed"]) != fmt.Sprint(w["untimed"]) {
			t.Errorf("%s: failing with no error time %v, want %v", name, r["failing_untimed"], w["untimed"])
		}
		t.Logf("%s: runstatus %v, failing since %v, untimed %v, error %v: %v", name, r["runstatus"], r["failing_since_utc"], r["failing_untimed"], r["error_code"], r["error_text"])
	}
	// the flicker: the retry's error row gives back the first failure's time, never its own
	if a, c := by["merge-flicker-a"], by["merge-flicker-c"]; a == nil || c == nil || a["failing_since_utc"] == nil ||
		fmt.Sprint(a["failing_since_utc"]) != fmt.Sprint(c["failing_since_utc"]) {
		t.Errorf("the flicker: merge-flicker-a since %v, merge-flicker-c since %v (want the same, not nil)", a["failing_since_utc"], c["failing_since_utc"])
	}
	pubs, err := QueryRows(ctx, conn, replPublicationsFor(stub, false))
	if err != nil {
		t.Fatalf("the publications read of the stub: %v", err)
	}
	wantArticles := map[string]string{"mpub": "<nil>", "mpub2": "<nil>", "mpub3": "<nil>", "tpub": "2"}
	for _, r := range pubs {
		name := fmt.Sprint(r["publication"])
		if want, ok := wantArticles[name]; !ok || fmt.Sprint(r["articles"]) != want {
			t.Errorf("publication %s (%v): articles %v, want %s (a merge publication's articles are not at the distributor)", name, r["publication_type"], r["articles"], want)
		}
		delete(wantArticles, name)
	}
	if len(wantArticles) > 0 {
		t.Errorf("publications not read: %v", wantArticles)
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

// A failed probe's row must keep nothing at the import: 0142's keep rule matches a collector_error whose source, cut at
// '.dbo.', equals a stored distribution database (and 'published databases' for the publisher side).
func TestReplicationProbeErrorKeepsNothing(t *testing.T) {
	for _, db := range []string{"distribution", "dist.prod", "Distribution2"} {
		r := replProbeError(db, errors.New("lock request time out"))
		src, _ := r["source"].(string)
		if r["kind"] != "collector_error" || r["message"] != "lock request time out" {
			t.Errorf("%s: %v", db, r)
		}
		if strings.SplitN(src, ".dbo.", 2)[0] == db || src == "published databases" {
			t.Errorf("%s: the source %q keeps the database's last rows at the import", db, src)
		}
	}
}
