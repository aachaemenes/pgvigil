package mssql

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_pool runs on a pooled Azure SQL Database with the server-state right, and nowhere else.
func TestPoolApplies(t *testing.T) {
	for _, c := range []struct {
		info Info
		run  bool
		word string
	}{
		{Info{Kind: KindAzureDB, ServiceObjective: "ElasticPool", ViewServerState: true}, true, ""},
		{Info{Kind: KindAzureDB, ServiceObjective: "GP_S_Gen5_1", ViewServerState: true}, false, "not in an elastic pool (service objective GP_S_Gen5_1)"},
		{Info{Kind: KindAzureDB, ServiceObjective: "ElasticPool"}, false, "##MS_ServerStateReader##"},
		{Info{Kind: KindServer, ServiceObjective: "ElasticPool", ViewServerState: true}, false, "Azure SQL Database's"},
	} {
		run, why := poolCollector{}.Applies(c.info)
		if run != c.run || !strings.Contains(why, c.word) {
			t.Errorf("%+v: %v %q, want %v with %q", c.info, run, why, c.run, c.word)
		}
	}
}

// The view's few-second rows, as QueryRows gives them, become minute rows: complete minutes only (the server's current
// minute waits), the average of the averages, the largest of the maxima, the largest average CPU as the minute's
// maximum, the storage figures the minute's last; an interval ending on the minute belongs to the minute before.
func TestPoolMinutes(t *testing.T) {
	row := func(end string, cpu, workers, alloc string, limit int64) collect.Row {
		return collect.Row{"end_time": end, "server_utc": "2026-11-13T12:01:20.1234567", "avg_cpu_percent": cpu, "max_worker_percent": workers,
			"allocated_storage_percent": alloc, "storage_limit_mb": limit, "avg_edtu_percent": nil}
	}
	var ss []poolSample
	for _, r := range []collect.Row{
		row("2026-11-13T12:00:15.000", "10.00", "5.00", "80.00", 5120),
		row("2026-11-13T12:00:30.000", "20.00", "9.00", "80.50", 5120),
		row("2026-11-13T12:00:45.000", "30.00", "7.00", "81.00", 5120),
		row("2026-11-13T12:01:00.000", "40.00", "6.00", "81.25", 5120),
		row("2026-11-13T12:01:15.000", "99.00", "99.00", "99.00", 5120), // the current minute: not yet
		row("2026-11-13T11:59:50.000", "50.00", "1.00", "79.00", 5120),
	} {
		s, err := poolSampleOf(r)
		if err != nil {
			t.Fatal(err)
		}
		ss = append(ss, s)
	}
	// at 12:01:20 the minute 12:00 ended 20 s ago, inside the grace: nothing is complete but 11:59, the read's oldest
	if ms := poolMinutes(ss, ss[0].serverUTC); len(ms) != 0 {
		t.Fatalf("at 12:01:20: %d minutes, want none (12:00 within the %v grace, 11:59 the read's oldest)", len(ms), poolGrace)
	}
	ms := poolMinutes(ss, ss[0].serverUTC.Add(20*time.Second)) // 12:01:40: 12:00 is past its grace
	if len(ms) != 1 {
		t.Fatalf("at 12:01:40: %d minutes, want 1 (12:00; 11:59 is the read's oldest, 12:01 the current one)", len(ms))
	}
	m := ms[0].row("srv1", "pool1", "tag")
	want := map[string]any{"minute": "2026-11-13T12:00:00Z", "samples": 4, "avg_cpu_percent": 25.0, "max_cpu_percent": 40.0,
		"max_worker_percent": 9.0, "allocated_storage_percent": 81.25, "storage_limit_mb": 5120.0, "avg_edtu_percent": nil, "server": "srv1", "pool": "pool1", "name_from": "tag"}
	for k, v := range want {
		if m[k] != v {
			t.Errorf("12:00's %s = %v, want %v", k, m[k], v)
		}
	}
}

// TestPoolName: the database's own answer wins; a tag fills in when the login may not read it; a tag naming another
// pool is a skip, never a silent write under the wrong name.
func TestPoolName(t *testing.T) {
	for _, c := range []struct{ tag, objectives, pool, from, err string }{
		{"", "pool1", "pool1", "service objectives", ""},
		{"pool1", "", "pool1", "tag", ""},
		{"POOL1", "pool1", "pool1", "service objectives", ""},
		{"pool1", "pool2", "", "", "names another pool than the database's own, pool2"},
		{"", "", "", "", "tag the instance pool:<name>"},
	} {
		pool, from, err := poolName(c.tag, c.objectives)
		if pool != c.pool || from != c.from || (err == nil) != (c.err == "") || err != nil && (!strings.Contains(err.Error(), c.err) || !errors.Is(err, collect.ErrSkip)) {
			t.Errorf("poolName(%q, %q) = %q, %q, %v; want %q, %q, %q", c.tag, c.objectives, pool, from, err, c.pool, c.from, c.err)
		}
	}
}
