package mssql

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_azuredb_resources runs on Azure SQL Database with VIEW DATABASE STATE (every tier: Microsoft's page for
// sys.dm_db_resource_stats), and nowhere else.
func TestAzureDBResourcesApplies(t *testing.T) {
	for _, c := range []struct {
		info Info
		run  bool
		word string
	}{
		{Info{Kind: KindAzureDB, ViewDatabaseState: true}, true, ""},
		{Info{Kind: KindAzureDB, ViewDatabaseState: true, ServiceObjective: "ElasticPool"}, true, ""},
		{Info{Kind: KindAzureDB, ViewServerState: true}, false, "the login lacks VIEW DATABASE STATE: the database's resource use is not readable"},
		{Info{Kind: KindAzureMI, ViewDatabaseState: true, ViewServerState: true}, false, "Azure SQL Database's"},
		{Info{Kind: KindServer, ViewDatabaseState: true, ViewServerState: true}, false, "Azure SQL Database's"},
	} {
		run, why := azureDBResourcesCollector{}.Applies(c.info)
		if run != c.run || !strings.Contains(why, c.word) {
			t.Errorf("%+v: %v %q, want %v with %q", c.info, run, why, c.run, c.word)
		}
	}
	if (azureDBResourcesCollector{}).Name() != "mssql_azuredb_resources" || (azureDBResourcesCollector{}).DefaultInterval() != time.Minute {
		t.Error("the collection is mssql_azuredb_resources, every minute")
	}
}

// azdbRow is one row of the read as QueryRows gives it: decimals as text, ints as int64, times as zone-less text.
func azdbRow(end, cpu, data, log string, dtu any) collect.Row {
	v := func(s string) any {
		if s == "" {
			return nil
		}
		return s
	}
	return collect.Row{"end_time": end, "avg_cpu_percent": v(cpu), "avg_data_io_percent": v(data), "avg_log_write_percent": v(log),
		"avg_memory_usage_percent": "20.00", "xtp_storage_percent": "0.00", "max_worker_percent": "1.00", "max_session_percent": "0.50",
		"dtu_limit": dtu, "avg_instance_cpu_percent": "3.00", "avg_instance_memory_percent": "40.00", "cpu_limit": nil, "replica_role": int64(0),
		"server_utc": "2026-11-14T12:02:40.1234567", "oldest_end": "2026-11-14T11:59:30.000"}
}

func minuteRows(t *testing.T, rows []collect.Row) (minutes []collect.Row, gaps []collect.Row) {
	t.Helper()
	for _, r := range rows {
		switch r["kind"] {
		case "minute":
			minutes = append(minutes, r)
		case "gap":
			gaps = append(gaps, r)
		default:
			t.Fatalf("a row of kind %v: %v", r["kind"], r)
		}
	}
	return minutes, gaps
}

// A first read (no stored minute): the read's oldest minute is dropped (the view trims its oldest rows one by one,
// so that minute may be short), the server's current minute waits (its rows are not all made), and each complete
// minute holds the averages of its 15-second rows, the per-sample maxima, DBA Dash's DTU % per sample (the
// greatest of CPU, data IO and log write when dtu_limit > 0), the DTUs that makes, and the 4 x 10 bucket counts.
func TestAzureDBMinutesFirstRead(t *testing.T) {
	raw := []collect.Row{
		azdbRow("2026-11-14T11:59:45.000", "50.00", "1.00", "1.00", int64(5)), // 11:59: the read's oldest minute
		azdbRow("2026-11-14T12:00:15.000", "10.00", "100.00", "0.00", int64(5)),
		azdbRow("2026-11-14T12:00:30.000", "9.99", "0.00", "20.00", int64(5)),
		azdbRow("2026-11-14T12:00:45.000", "90.00", "0.00", "0.00", int64(5)),
		azdbRow("2026-11-14T12:01:00.000", "30.01", "", "", int64(5)), // ends on the minute: 12:00's
		azdbRow("2026-11-14T12:01:15.000", "40.00", "0.00", "0.00", int64(5)),
		azdbRow("2026-11-14T12:01:30.000", "40.00", "0.00", "0.00", int64(5)),
		azdbRow("2026-11-14T12:01:45.000", "40.00", "0.00", "0.00", int64(5)),
		azdbRow("2026-11-14T12:02:00.000", "40.00", "0.00", "0.00", int64(5)),
		azdbRow("2026-11-14T12:02:15.000", "99.00", "0.00", "0.00", int64(5)), // 12:02: the server's current minute
	}
	rows, err := azdbRead(raw, time.Time{}, false)
	if err != nil {
		t.Fatal(err)
	}
	ms, gaps := minuteRows(t, rows)
	if len(gaps) != 0 {
		t.Errorf("a first read is no gap: %v", gaps)
	}
	if len(ms) != 2 || ms[0]["minute"] != "2026-11-14T12:00:00Z" || ms[1]["minute"] != "2026-11-14T12:01:00Z" {
		t.Fatalf("minutes %v, want 12:00 and 12:01 (11:59 the read's oldest, 12:02 the current one at 12:02:40)", ms)
	}
	m := ms[0]
	want := map[string]any{
		"samples":                     4,
		"avg_cpu_percent":             (10 + 9.99 + 90 + 30.01) / 4.0,
		"max_cpu_percent":             90.0,
		"avg_data_io_percent":         100.0 / 3,
		"max_data_io_percent":         100.0,
		"avg_log_write_percent":       20.0 / 3,
		"max_log_write_percent":       20.0,
		"avg_memory_usage_percent":    20.0,
		"max_memory_usage_percent":    20.0,
		"avg_xtp_storage_percent":     0.0,
		"max_worker_percent":          1.0,
		"max_session_percent":         0.5,
		"avg_instance_cpu_percent":    3.0,
		"avg_instance_memory_percent": 40.0,
		"dtu_limit":                   5.0,
		"cpu_limit":                   nil,
		"replica_role":                0.0,
		// per sample: max(10, 100, 0) = 100, max(9.99, 0, 20) = 20, max(90, 0, 0) = 90, max(30.01) = 30.01 (NULLs ignored)
		"avg_dtu_percent": (100 + 20 + 90 + 30.01) / 4.0,
		"max_dtu_percent": 100.0,
		"avg_dtu":         (5*1.0 + 5*0.2 + 5*0.9 + 5*0.3001) / 4.0,
		"max_dtu":         5.0,
		// < 10, [10, 20), ... [80, 90), >= 90
		"dtu_buckets":  []int{0, 0, 1, 1, 0, 0, 0, 0, 0, 2},
		"cpu_buckets":  []int{1, 1, 0, 1, 0, 0, 0, 0, 0, 1},
		"data_buckets": []int{2, 0, 0, 0, 0, 0, 0, 0, 0, 1}, // the NULL sample is in no bucket
		"log_buckets":  []int{2, 0, 1, 0, 0, 0, 0, 0, 0, 0},
	}
	for k, w := range want {
		g := m[k]
		if wf, ok := w.(float64); ok {
			gf, ok := g.(float64)
			if !ok || gf-wf > 1e-9 || wf-gf > 1e-9 {
				t.Errorf("12:00 %s = %v, want %v", k, g, w)
			}
			continue
		}
		if !reflect.DeepEqual(g, w) {
			t.Errorf("12:00 %s = %#v, want %#v", k, g, w)
		}
	}
}

// A vCore database (dtu_limit NULL): no DTU figures and empty DTU buckets, as DBA Dash's NULL avg_dtu_percent.
func TestAzureDBMinutesVCore(t *testing.T) {
	raw := []collect.Row{
		azdbRow("2026-11-14T11:59:45.000", "1.00", "1.00", "1.00", nil),
		azdbRow("2026-11-14T12:00:15.000", "95.00", "1.00", "1.00", nil),
		azdbRow("2026-11-14T12:00:30.000", "5.00", "1.00", "1.00", int64(0)),
	}
	raw[1]["cpu_limit"], raw[2]["cpu_limit"] = "1.00", "2.00"
	rows, err := azdbRead(raw, time.Time{}, false)
	if err != nil {
		t.Fatal(err)
	}
	ms, _ := minuteRows(t, rows)
	if len(ms) != 1 {
		t.Fatalf("minutes %v, want 12:00", ms)
	}
	for _, k := range []string{"avg_dtu_percent", "max_dtu_percent", "avg_dtu", "max_dtu"} {
		if ms[0][k] != nil {
			t.Errorf("vCore %s = %v, want nil", k, ms[0][k])
		}
	}
	if !reflect.DeepEqual(ms[0]["dtu_buckets"], []int{0, 0, 0, 0, 0, 0, 0, 0, 0, 0}) || ms[0]["cpu_limit"] != 2.0 || ms[0]["dtu_limit"] != 0.0 {
		t.Errorf("vCore: dtu_buckets %v (want all 0), cpu_limit %v and dtu_limit %v (want the minute's last, 2 and 0)", ms[0]["dtu_buckets"], ms[0]["cpu_limit"], ms[0]["dtu_limit"])
	}
}

// From the cursor: the read starts after the newest stored minute's end, so its first minute is whole and kept;
// a view whose oldest row starts after that end (the collector down over the view's hour, a failover, a serverless
// resume) leaves a gap: the gap row names the minutes missing and the read's oldest minute is dropped as on a first read.
func TestAzureDBMinutesCursorAndGap(t *testing.T) {
	since := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC) // 11:59 is the newest stored minute
	raw := []collect.Row{
		azdbRow("2026-11-14T12:00:15.000", "10.00", "0.00", "0.00", int64(5)),
		azdbRow("2026-11-14T12:01:00.000", "10.00", "0.00", "0.00", int64(5)),
		azdbRow("2026-11-14T12:01:15.000", "10.00", "0.00", "0.00", int64(5)),
	}
	for _, r := range raw {
		r["oldest_end"], r["server_utc"] = "2026-11-14T11:01:00.000", "2026-11-14T12:01:40.000" // the view holds the hour: no gap; 12:01 is current
	}
	rows, err := azdbRead(raw, since, true)
	if err != nil {
		t.Fatal(err)
	}
	ms, gaps := minuteRows(t, rows)
	if len(gaps) != 0 || len(ms) != 1 || ms[0]["minute"] != "2026-11-14T12:00:00Z" || ms[0]["samples"] != 2 {
		t.Fatalf("from the cursor: minutes %v gaps %v, want 12:00 of 2 samples and no gap", ms, gaps)
	}

	// the view starts at 12:30:15 (its oldest row ends 12:30:30): 12:00-12:30 are not in it
	raw = []collect.Row{
		azdbRow("2026-11-14T12:30:30.000", "10.00", "0.00", "0.00", int64(5)),
		azdbRow("2026-11-14T12:30:45.000", "10.00", "0.00", "0.00", int64(5)),
		azdbRow("2026-11-14T12:31:15.000", "10.00", "0.00", "0.00", int64(5)),
		azdbRow("2026-11-14T12:32:00.000", "10.00", "0.00", "0.00", int64(5)),
	}
	for _, r := range raw {
		r["oldest_end"], r["server_utc"] = "2026-11-14T12:30:30.000", "2026-11-14T12:32:45.000"
	}
	rows, err = azdbRead(raw, since, true)
	if err != nil {
		t.Fatal(err)
	}
	ms, gaps = minuteRows(t, rows)
	if len(ms) != 1 || ms[0]["minute"] != "2026-11-14T12:31:00Z" {
		t.Errorf("after a gap: minutes %v, want 12:31 only (12:30, the read's oldest, may be short)", ms)
	}
	if len(gaps) != 1 || gaps[0]["gap_from"] != "2026-11-14T12:00:00Z" || gaps[0]["gap_to"] != "2026-11-14T12:31:00Z" {
		t.Errorf("gap rows %v, want one from 12:00 (the stored end) to 12:31 (the first minute stored after it)", gaps)
	}

	// a view whose oldest row starts within a row's length of the stored end is no gap
	for _, r := range raw {
		r["oldest_end"] = "2026-11-14T12:00:15.000"
	}
	if _, gaps = minuteRows(t, mustRead(t, raw, since)); len(gaps) != 0 {
		t.Errorf("oldest row 12:00:00-12:00:15 after a stored end of 12:00: gap %v, want none", gaps)
	}
}

func mustRead(t *testing.T, raw []collect.Row, since time.Time) []collect.Row {
	t.Helper()
	rows, err := azdbRead(raw, since, true)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// The cursor is the newest stored minute's start as epoch seconds; the read asks for the rows ending after that
// minute's end, as text in the view's own (zone-less UTC) form, and for every row on a first read.
func TestAzureDBSince(t *testing.T) {
	since, arg := azdbSince(time.Date(2026, 11, 14, 11, 59, 0, 0, time.UTC).Unix(), true)
	if !since.Equal(time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)) || arg != "2026-11-14T12:00:00.000" {
		t.Errorf("since %v arg %v, want 12:00 and '2026-11-14T12:00:00.000'", since, arg)
	}
	if since, arg := azdbSince(0, false); !since.IsZero() || arg != nil {
		t.Errorf("no cursor: since %v arg %v, want zero and nil (every row)", since, arg)
	}
	if !strings.Contains(azdbStatsSQL, "FROM sys.dm_db_resource_stats") || !strings.Contains(azdbStatsSQL, "@p1 IS NULL OR end_time > CONVERT(datetime2(3), @p1, 126)") {
		t.Error("the read filters on the server from the cursor's end")
	}
}

// a row the read cannot use is an error, never a minute stored wrong
func TestAzureDBBadRow(t *testing.T) {
	r := azdbRow("2026-11-14T12:00:15.000", "x", "0.00", "0.00", int64(5))
	if _, err := azdbRead([]collect.Row{r}, time.Time{}, false); err == nil || !strings.Contains(err.Error(), "avg_cpu_percent") {
		t.Errorf("a figure that is not a number: %v, want an error naming the column", err)
	}
}
