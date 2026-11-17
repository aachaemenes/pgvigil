package mssql

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestPoolMinuteMaxima (control audit A3; Microsoft Learn's sys.dm_elastic_pool_resource_stats, read 2026-11-17: its
// only max_ columns are workers and sessions): DBA Dash's Pool chart's Max Data %, Max Log Write % and Max DTU % are a
// minute's largest sample of the view's avg_data_io_percent, avg_log_write_percent and avg_edtu_percent, sent as
// max_data_io_percent, max_log_write_percent and max_edtu_percent beside the minute's averages (as max_cpu_percent is);
// a figure no sample carried is nil.
func TestPoolMinuteMaxima(t *testing.T) {
	var ss []poolSample
	for _, r := range []collect.Row{
		{"end_time": "2026-11-13T12:00:15.000", "avg_data_io_percent": "10.00", "avg_log_write_percent": "5.00", "avg_edtu_percent": nil},
		{"end_time": "2026-11-13T12:00:30.000", "avg_data_io_percent": "30.00", "avg_log_write_percent": "25.00", "avg_edtu_percent": nil},
		{"end_time": "2026-11-13T12:00:45.000", "avg_data_io_percent": "20.00", "avg_log_write_percent": "15.00", "avg_edtu_percent": nil},
		{"end_time": "2026-11-13T11:59:50.000", "avg_data_io_percent": "1.00", "avg_log_write_percent": "1.00", "avg_edtu_percent": nil}, // the read's oldest
	} {
		r["server_utc"] = "2026-11-13T12:05:00.000"
		s, err := poolSampleOf(r)
		if err != nil {
			t.Fatal(err)
		}
		ss = append(ss, s)
	}
	ms := poolMinutes(ss, ss[0].serverUTC)
	if len(ms) != 1 {
		t.Fatalf("%d minutes, want 1 (12:00)", len(ms))
	}
	m := ms[0].row("srv1", "pool1", "tag")
	for k, want := range map[string]any{"max_data_io_percent": 30.0, "max_log_write_percent": 25.0, "avg_data_io_percent": 20.0, "max_edtu_percent": nil} {
		if m[k] != want {
			t.Errorf("12:00's %s = %v, want %v", k, m[k], want)
		}
	}
}
