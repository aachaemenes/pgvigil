package mssql

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// One read of the counters gives the four throughput counters as 'counter' rows exactly as before (counter, value)
// and the listed counters as 'perfmon' rows; the per-database objects go to the 5-minute read only, the system
// names nowhere.
func TestCPUCounterRowsSplit(t *testing.T) {
	rows := []collect.Row{
		{"object": "SQLServer:SQL Statistics", "counter": "Batch Requests/sec", "instance": "", "value": int64(900), "type": int64(272696576)},
		{"object": "SQLServer:Databases", "counter": "Transactions/sec", "instance": "_Total", "value": int64(50), "type": int64(272696576)},
		{"object": "SQLServer:Databases", "counter": "Transactions/sec", "instance": "sales", "value": int64(12), "type": int64(272696576)},
		{"object": "SQLServer:Databases", "counter": "Log Bytes Flushed/sec", "instance": "master", "value": int64(7), "type": int64(272696576)},
		{"object": "MSSQL$NAMED:General Statistics", "counter": "Processes blocked", "instance": "", "value": int64(0), "type": int64(65792)},
		{"object": "SQLServer:Workload Group Stats", "counter": "Queued requests", "instance": "internal", "value": int64(3), "type": int64(65792)},
		{"object": "SQLServer:Workload Group Stats", "counter": "Queued requests", "instance": "default", "value": int64(2), "type": int64(65792)},
		{"object": "SQLServer:Plan Cache", "counter": "Cache Hit Ratio", "instance": "_Total", "value": int64(5), "type": int64(537003264)},
	}
	inst := cpuCounterRows(rows, false)
	var counters, perfmon []collect.Row
	for _, r := range inst {
		switch r["kind"] {
		case "counter":
			counters = append(counters, r)
		case "perfmon":
			perfmon = append(perfmon, r)
		}
	}
	if len(counters) != 2 || counters[0]["counter"] != "Batch Requests/sec" || counters[1]["counter"] != "Transactions/sec" || len(counters[1]) != 3 {
		t.Fatalf("the 'counter' rows: %v (want Batch Requests/sec and _Total Transactions/sec, keys kind, counter, value)", counters)
	}
	want := map[string]bool{"SQL Statistics|Batch Requests/sec|_Total": true, "General Statistics|Processes blocked|_Total": true,
		"Workload Group Stats|Queued requests|default": true}
	if len(perfmon) != len(want) {
		t.Fatalf("instance 'perfmon' rows: %v", perfmon)
	}
	for _, r := range perfmon {
		k := r["object"].(string) + "|" + r["counter"].(string) + "|" + r["instance"].(string)
		if !want[k] {
			t.Errorf("unexpected perfmon row %s (a per-database object, a system name or an unlisted counter)", k)
		}
	}
	db := cpuCounterRows(rows, true)
	if len(db) != 2 {
		t.Fatalf("per-database rows: %v (want _Total and sales Transactions/sec; master left out; no 'counter' rows)", db)
	}
	for _, r := range db {
		if r["kind"] != "perfmon" || r["object"] != "Databases" || r["instance"] == "master" {
			t.Errorf("per-database row %v", r)
		}
	}
}

// The counter list is PerformanceMonitor's 61 names, no name twice, and the read's IN lists quote a name with a quote.
func TestPerfmonListAndQuoting(t *testing.T) {
	seen := map[string]bool{}
	for _, c := range perfmonCounters {
		if seen[c] {
			t.Errorf("%q twice", c)
		}
		seen[c] = true
	}
	if len(perfmonCounters) != 61 {
		t.Errorf("%d names, want 61", len(perfmonCounters))
	}
	if got := nList([]string{"a'b", "c"}); got != "N'a''b', N'c'" {
		t.Errorf("nList = %s", got)
	}
	if !strings.Contains(cpuCounterSQL, "N'Wait for the worker'") || !strings.Contains(activityDBCounterSQL, "N'mssqlsystemresource'") {
		t.Error("the reads do not carry the list or the system names")
	}
}

// The session groups keep the totals and the named groups; the NULL group of a set (sessions not counted per group)
// is dropped.
func TestActivityRows(t *testing.T) {
	got := activityRows([]collect.Row{
		{"grp": "total", "name": nil, "sessions": int64(40)},
		{"grp": "program", "name": nil, "sessions": int64(30)},
		{"grp": "program", "name": "app1", "sessions": int64(10)},
		{"grp": "host", "name": "web01", "sessions": int64(10)},
		{"grp": "database", "name": nil, "sessions": int64(30)},
	})
	if len(got) != 3 || got[0]["grp"] != "total" || got[1]["name"] != "app1" || got[2]["name"] != "web01" {
		t.Fatalf("activityRows = %v", got)
	}
}

// sp_PressureDetector's CPU details: only the columns the server has, in its order; none = no statement.
func TestCPUInfoSelect(t *testing.T) {
	if q := cpuInfoSelect(nil); q != "" {
		t.Errorf("no columns gave %q", q)
	}
	q := cpuInfoSelect([]collect.Row{{"name": "softnuma_configuration_desc"}, {"name": "cpu_count"}, {"name": "socket_count"}})
	if q != "SELECT 'cpuinfo' AS kind, CAST(osi.socket_count AS bigint) AS socket_count, CAST(osi.cpu_count AS bigint) AS cpu_count, "+
		"CAST(osi.softnuma_configuration_desc AS nvarchar(60)) AS softnuma_configuration_desc FROM sys.dm_os_sys_info AS osi" {
		t.Errorf("cpuInfoSelect = %s", q)
	}
}

// sp_PressureDetector's SLEEP_TASK rule: kept (hash spills) at an average wait of 1,000 ms or more since the start.
func TestSleepTaskSpills(t *testing.T) {
	for _, c := range []struct {
		ms, n int64
		want  bool
	}{{1000, 1, true}, {999, 1, false}, {5000, 5, true}, {4999, 5, false}, {100, 0, false}} {
		if got := sleepTaskSpills(collect.Row{"wait_ms": c.ms, "waiting_tasks": c.n}); got != c.want {
			t.Errorf("wait %d ms over %d tasks: %v, want %v", c.ms, c.n, got, c.want)
		}
	}
}

// The remote admin connections finding carries sp_PressureDetector's command (task 177 D14, L1762).
func TestRemoteAdminCommand(t *testing.T) {
	v := serverOptionRules["remote admin connections"](0, machineFacts{})
	if !strings.Contains(v.Explain, "EXECUTE sp_configure 'remote admin connections', 1; RECONFIGURE;") || !strings.Contains(v.Rule, "sp_PressureDetector") {
		t.Errorf("remote admin connections = 0: %+v", v)
	}
}
