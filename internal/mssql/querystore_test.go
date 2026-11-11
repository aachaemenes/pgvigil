package mssql

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The collection is registered hourly, with a run long enough for a pass over every database, and reads on from
// the repository's cursors.
func TestQueryStoreRegistered(t *testing.T) {
	c, ok := Get("mssql_querystore")
	if !ok {
		t.Fatal("mssql_querystore is not registered")
	}
	if c.DefaultInterval() != time.Hour {
		t.Errorf("interval %v, want an hour", c.DefaultInterval())
	}
	if runTimeout(c) != 5*time.Minute {
		t.Errorf("the run's deadline is %v", runTimeout(c))
	}
	if _, ok := c.(CursorCollector); !ok {
		t.Error("the collector does not read on from a cursor")
	}
}

func TestQueryStoreApplies(t *testing.T) {
	for _, c := range []struct {
		name string
		info Info
		ok   bool
		why  string
	}{
		{"SQL Server 2022", Info{Kind: KindServer, Major: 16, ViewServerState: true}, true, ""},
		{"SQL Server 2016", Info{Kind: KindServer, Major: 13, ViewServerState: true}, true, ""},
		{"SQL Server 2014", Info{Kind: KindServer, Major: 12, ViewServerState: true}, false, "2016"},
		{"a managed instance, whatever its version says", Info{Kind: KindAzureMI, Major: 12, ViewServerState: true}, true, ""},
		{"Amazon RDS on SQL Server 2014", Info{Kind: KindRDS, Major: 12, ViewServerState: true}, false, "2016"},
		{"Amazon RDS on SQL Server 2019", Info{Kind: KindRDS, Major: 15, ViewServerState: true}, true, ""},
		{"Azure SQL Database", Info{Kind: KindAzureDB, Major: 12, ViewServerState: true}, false, "Azure SQL Database"},
		{"no VIEW SERVER STATE", Info{Kind: KindServer, Major: 16}, false, "VIEW SERVER STATE"},
	} {
		ok, why := queryStoreCollector{}.Applies(c.info)
		if ok != c.ok || !strings.Contains(why, c.why) {
			t.Errorf("%s: %v %q, want %v naming %q", c.name, ok, why, c.ok, c.why)
		}
	}
}

// The columns of later versions are asked for only where the server has them: wait statistics from 2017, the
// capture policy from 2019, both on a managed instance.
func TestQSOptionColsByVersion(t *testing.T) {
	for _, c := range []struct {
		name          string
		info          Info
		waits, policy bool
	}{
		{"2016", Info{Kind: KindServer, Major: 13}, false, false},
		{"2017", Info{Kind: KindServer, Major: 14}, true, false},
		{"2019", Info{Kind: KindServer, Major: 15}, true, true},
		{"managed instance", Info{Kind: KindAzureMI, Major: 12}, true, true},
	} {
		cols := qsOptionCols(c.info)
		if got := strings.Contains(cols, "wait_stats_capture_mode_desc"); got != c.waits {
			t.Errorf("%s: wait_stats_capture_mode_desc asked for = %v", c.name, got)
		}
		if got := strings.Contains(cols, "capture_policy_execution_count"); got != c.policy {
			t.Errorf("%s: the capture policy asked for = %v", c.name, got)
		}
		if qsHasWaits(c.info) != c.waits {
			t.Errorf("%s: qsHasWaits = %v", c.name, qsHasWaits(c.info))
		}
		forcing := qsForcingCol(c.info)
		if got := strings.Contains(forcing, "plan_forcing_type_desc"); got != c.waits {
			t.Errorf("%s: plan_forcing_type_desc asked for = %v (%s)", c.name, got, forcing)
		}
	}
}

// The reads are bounded on the server: the intervals by the cursor's time, the oldest first and a fixed number a
// run; the runtime and the wait statistics by the first and last interval of that list; the plans by their ids.
// (What the filter costs SQL Server inside its own store is not something a test of the text can see: the
// collector's comment says what the store's indexes allow.)
func TestQSReadsAreBounded(t *testing.T) {
	stmt := strings.Join(strings.Fields(strings.ReplaceAll(qsCandidatesSQL, "%s", qsWaitsCTE)), " ")
	for _, want := range []string{
		"FROM sys.query_store_runtime_stats r WHERE r.runtime_stats_interval_id BETWEEN @first AND @last",
		"FROM sys.query_store_wait_stats w WHERE w.runtime_stats_interval_id BETWEEN @first AND @last",
		"k.rn_duration <= @top OR k.rn_cpu <= @top OR k.rn_reads <= @top OR k.rn_memory <= @top OR (k.rn_wait <= @top AND k.wait_ms > 0)",
	} {
		if !strings.Contains(stmt, want) {
			t.Errorf("the candidate statement lacks %q", want)
		}
	}
	if n := strings.Count(stmt, "sys.query_store_runtime_stats "); n != 1 {
		t.Errorf("sys.query_store_runtime_stats is read %d times, want once", n)
	}
	iv := strings.Join(strings.Fields(qsIntervalsSQL), " ")
	if !strings.Contains(iv, "SELECT TOP (@max)") || !strings.HasSuffix(iv, "WHERE i.end_time > @since ORDER BY i.end_time, i.runtime_stats_interval_id") {
		t.Errorf("the interval statement is not the oldest intervals after the cursor, a bounded number: %s", iv)
	}
	plans := strings.Join(strings.Fields(qsPlansSQL), " ")
	if !strings.HasSuffix(plans, "WHERE p.is_forced_plan = 1 OR p.plan_id IN (%[2]s)") {
		t.Errorf("the plan statement does not read by plan id: %s", plans[len(plans)-80:])
	}
	if !strings.Contains(qsTuningSQL, "SELECT TOP (@max)") {
		t.Error("the recommendations are read without a bound")
	}
	// without wait statistics (2016) the statement still has its ws relation, empty
	if no := strings.ReplaceAll(qsCandidatesSQL, "%s", qsNoWaitsCTE); strings.Contains(no, "query_store_wait_stats") || !strings.Contains(no, "LEFT JOIN ws") {
		t.Error("the 2016 form of the candidate statement reads the wait statistics, or lost its ws relation")
	}
}

// The databases the repository holds least of are read first, by name among equals: the ones a cut run left out
// lead the next run.
func TestQSOldestFirst(t *testing.T) {
	turns := []qsTurn{{name: "a", last: 300, hasLast: true}, {name: "b"}, {name: "c", last: 100, hasLast: true}, {name: "d"}, {name: "e", last: 300, hasLast: true}}
	qsOldestFirst(turns)
	var got []string
	for _, x := range turns {
		got = append(got, x.name)
	}
	if strings.Join(got, ",") != "b,d,c,a,e" {
		t.Errorf("the read order is %v, want b,d,c,a,e (never read first, then the oldest, by name among equals)", got)
	}
}

// A statement runs inside a database through that database's sp_executesql; its text and its parameters travel as
// parameters.
func TestInDatabase(t *testing.T) {
	if got := inDatabase("[a]]b]", ""); got != "EXEC [a]]b].sys.sp_executesql @stmt" {
		t.Errorf("no parameters: %s", got)
	}
	want := "EXEC [db].sys.sp_executesql @stmt, N'@since datetimeoffset(7), @max int', @since = @since, @max = @max"
	if got := inDatabase("[db]", "@since datetimeoffset(7), @max int"); got != want {
		t.Errorf("two parameters:\n got %s\nwant %s", got, want)
	}
}

func TestQSIDList(t *testing.T) {
	if got := qsIDList(nil); got != "-1" {
		t.Errorf("no id: %q, want one that matches nothing", got)
	}
	got := qsIDList(map[int64]bool{7: true, 12: true, 3: true})
	if len(strings.Split(got, ",")) != 3 || !strings.Contains(","+got+",", ",7,") || !strings.Contains(","+got+",", ",12,") || !strings.Contains(","+got+",", ",3,") {
		t.Errorf("three ids: %q", got)
	}
	if strings.ContainsAny(got, " ;'") {
		t.Errorf("the list carries more than numbers and commas: %q", got)
	}
}

// The candidate set becomes one interval row per interval read (with the totals over every plan, taken once) and
// one runtime row per kept plan; a candidate of an interval that was not asked for is dropped.
func TestQSRuntimeRows(t *testing.T) {
	t0 := time.Date(2026, 11, 10, 7, 0, 0, 0, time.UTC)
	ivs := []collect.Row{
		{"interval_id": int64(11), "interval_start": t0.Add(time.Hour), "interval_end": t0.Add(2 * time.Hour)},
		{"interval_id": int64(10), "interval_start": t0, "interval_end": t0.Add(time.Hour)},
		{"interval_id": int64(12), "interval_start": t0.Add(2 * time.Hour), "interval_end": t0.Add(3 * time.Hour)}, // nothing ran
	}
	byID := map[int64]collect.Row{}
	for _, iv := range ivs {
		iv["kind"], iv["database_name"] = "interval", "db1"
		byID[iv["interval_id"].(int64)] = iv
	}
	cand := func(interval, plan, execs, totExecs int64) collect.Row {
		return collect.Row{"interval_id": interval, "plan_id": plan, "executions": execs, "duration_us": execs * 1000,
			"tot_plans": int64(9), "tot_executions": totExecs, "tot_duration_us": totExecs * 1000, "tot_cpu_us": int64(5),
			"tot_logical_reads": int64(6), "tot_wait_ms": int64(7)}
	}
	cands := []collect.Row{cand(10, 3, 40, 100), cand(10, 4, 60, 100), cand(11, 3, 5, 8), cand(9, 3, 1, 1)}
	planIDs := map[int64]bool{}
	out := qsRuntimeRows("db1", ivs, byID, cands, planIDs)
	var intervals, runtime int
	for _, r := range out {
		switch r["kind"] {
		case "interval":
			intervals++
		case "runtime":
			runtime++
			if r["database_name"] != "db1" {
				t.Errorf("a runtime row without its database: %v", r)
			}
			for k := range r {
				if strings.HasPrefix(k, "tot_") {
					t.Errorf("a runtime row still carries %s", k)
				}
			}
		default:
			t.Errorf("a row of kind %v", r["kind"])
		}
	}
	if intervals != 3 || runtime != 3 {
		t.Fatalf("%d interval rows and %d runtime rows, want 3 and 3 (the candidate of interval 9 is dropped)", intervals, runtime)
	}
	if byID[10]["executions"] != int64(100) || byID[10]["plans"] != int64(9) || byID[10]["duration_us"] != int64(100000) ||
		byID[10]["cpu_us"] != int64(5) || byID[10]["logical_reads"] != int64(6) || byID[10]["wait_ms"] != int64(7) {
		t.Errorf("interval 10's totals: %v", byID[10])
	}
	if byID[11]["executions"] != int64(8) {
		t.Errorf("interval 11's totals: %v", byID[11])
	}
	if _, has := byID[12]["executions"]; has {
		t.Errorf("an interval nothing ran in carries totals: %v", byID[12])
	}
	for _, r := range out {
		if r["kind"] == "runtime" && r["interval_id"] == int64(11) && r["interval_start"] != t0.Add(time.Hour) {
			t.Errorf("a runtime row of interval 11 with the start %v", r["interval_start"])
		}
	}
	if len(planIDs) != 2 || !planIDs[3] || !planIDs[4] {
		t.Errorf("the plans to read: %v", planIDs)
	}
}

// A plan's XML is not read again when the repository holds the plan under the same hash; another hash under the
// plan's number (a cleared store), no answer or no cursor at all means: read it. A cursor that fails is an error
// (the repository does not answer), never a silent "read it".
func TestQSPlanStored(t *testing.T) {
	ctx := context.Background()
	var asked string
	cursor := func(answer int64, ok bool, err error) SeqCursorFunc {
		return func(_ context.Context, source string) (int64, bool, error) {
			asked = source
			return answer, ok, err
		}
	}
	if stored, err := qsPlanStored(ctx, cursor(-77, true, nil), "db:1", 12, int64(-77)); !stored || err != nil {
		t.Errorf("the same hash: stored %v, err %v", stored, err)
	}
	if asked != "qs_plan:12:db:1" {
		t.Errorf("the cursor source is %q", asked)
	}
	for name, c := range map[string]struct {
		cursor SeqCursorFunc
		hash   any
	}{
		"another hash": {cursor(5, true, nil), int64(-77)},
		"never read":   {cursor(0, false, nil), int64(0)},
		"no cursor":    {nil, int64(-77)},
		"no hash read": {cursor(0, true, nil), nil},
	} {
		if stored, err := qsPlanStored(ctx, c.cursor, "db", 12, c.hash); stored || err != nil {
			t.Errorf("%s: stored %v, err %v", name, stored, err)
		}
	}
	if stored, err := qsPlanStored(ctx, cursor(-77, true, errors.New("down")), "db", 12, int64(-77)); stored || err == nil || !strings.Contains(err.Error(), "down") {
		t.Errorf("a cursor error: stored %v, err %v", stored, err)
	}
}

// The payload under the instance's text policy: a plan's XML is kept under full only, a query's text is
// normalized or dropped, and the store's own hashes, the recommendation's details and a collector_error's message
// stay (their column names are not the policy's).
func TestQSTextPolicy(t *testing.T) {
	rows := func() []collect.Row {
		return []collect.Row{
			{"kind": "plan", "database_name": "db", "plan_id": int64(7), "query_hash_hex": "0x0A", "plan_hash_hex": "0x0B", "plan_hash_n": int64(11),
				"query": "SELECT * FROM dbo.t WHERE name = N'secret' AND id = 42"},
			{"kind": "plan_xml", "kind_of": "plan", "database_name": "db", "plan_id": int64(7), "statement": "<ShowPlanXML>secret</ShowPlanXML>"},
			{"kind": "tuning", "database_name": "db", "rec_name": "PR_1", "reason": "Average query CPU time changed", "script": "exec sp_query_store_force_plan @query_id = 1, @plan_id = 7",
				"rec_details": `{"planForceDetails":{"queryId":1}}`},
			{"kind": "collector_error", "source": "sys.query_store_runtime_stats", "message": "the run's deadline came"},
			{"kind": "forced_read", "kind_of": "plan", "database_name": "db", "statement": "kept"},
		}
	}
	full := rows()
	collect.ApplyTextPolicy(full, "full")
	if full[0]["query"] != "SELECT * FROM dbo.t WHERE name = N'secret' AND id = 42" || full[1]["statement"] != "<ShowPlanXML>secret</ShowPlanXML>" {
		t.Errorf("full changed the text: %v %v", full[0]["query"], full[1]["statement"])
	}
	if full[4]["statement"] != "kept" {
		t.Errorf("full emptied the marker's policy probe: %v", full[4]["statement"])
	}
	for _, mode := range []string{"normalized", "none"} {
		r := rows()
		collect.ApplyTextPolicy(r, mode)
		if r[1]["statement"] != nil {
			t.Errorf("%s keeps the plan XML: %v", mode, r[1]["statement"])
		}
		q, _ := r[0]["query"].(string)
		if strings.Contains(q, "secret") || strings.Contains(q, "42") {
			t.Errorf("%s keeps a literal: %q", mode, q)
		}
		if mode == "normalized" && q != "SELECT * FROM dbo.t WHERE name = ? AND id = ?" {
			t.Errorf("normalized: %q", q)
		}
		if mode == "none" && r[0]["query"] != nil {
			t.Errorf("none keeps the text: %v", r[0]["query"])
		}
		if r[0]["query_hash_hex"] != "0x0A" || r[0]["plan_hash_hex"] != "0x0B" || r[0]["plan_hash_n"] != int64(11) {
			t.Errorf("%s changed the store's hashes: %v", mode, r[0])
		}
		if r[2]["rec_details"] != `{"planForceDetails":{"queryId":1}}` || r[2]["script"] == nil || r[2]["reason"] == nil {
			t.Errorf("%s changed the recommendation: %v", mode, r[2])
		}
		if r[3]["message"] != "the run's deadline came" {
			t.Errorf("%s changed the collector_error: %v", mode, r[3])
		}
		// the marker's probe: present and empty tells the import the policy keeps no plan XML
		if v, has := r[4]["statement"]; !has || v != nil {
			t.Errorf("%s left the marker's policy probe as %v (present %v)", mode, v, has)
		}
	}
}
