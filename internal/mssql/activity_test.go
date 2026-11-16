package mssql

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// One read of the counters gives the four throughput counters as 'counter' rows exactly as before (counter, value);
// every other counter is mssql_counters' (task 401) and leaves this read.
func TestCPUCounterRows(t *testing.T) {
	rows := []collect.Row{
		{"object": "SQLServer:SQL Statistics", "counter": "Batch Requests/sec", "instance": "", "value": int64(900), "type": int64(272696576)},
		{"object": "SQLServer:Databases", "counter": "Transactions/sec", "instance": "_Total", "value": int64(50), "type": int64(272696576)},
		{"object": "SQLServer:Databases", "counter": "Transactions/sec", "instance": "sales", "value": int64(12), "type": int64(272696576)},
		{"object": "MSSQL$NAMED:General Statistics", "counter": "Processes blocked", "instance": "", "value": int64(0), "type": int64(65792)},
	}
	got := cpuCounterRows(rows)
	if len(got) != 2 || got[0]["counter"] != "Batch Requests/sec" || got[1]["counter"] != "Transactions/sec" || len(got[1]) != 3 || got[1]["kind"] != "counter" {
		t.Fatalf("the 'counter' rows: %v (want Batch Requests/sec and _Total Transactions/sec, keys kind, counter, value)", got)
	}
}

// The read's IN lists quote a name with a quote; the CPU read names the four throughput counters only.
func TestNListAndCPUCounterSQL(t *testing.T) {
	if got := nList([]string{"a'b", "c"}); got != "N'a''b', N'c'" {
		t.Errorf("nList = %s", got)
	}
	if !strings.Contains(cpuCounterSQL, "N'SQL Re-Compilations/sec'") || strings.Contains(cpuCounterSQL, "N'Wait for the worker'") {
		t.Error("the CPU read is not the four throughput counters alone")
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
