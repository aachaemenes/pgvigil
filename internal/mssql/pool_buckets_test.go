package mssql

import (
	"fmt"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestPoolMinuteBuckets (control audit A5; DBA Dash's AzureDBElasticPoolResourceStats_Raw L36-65: one count a sample
// in ten 10 % buckets of CPU, data IO, log write and DTU, the last 90 % and over): a stored pool minute carries
// cpu_buckets, data_buckets, log_buckets and dtu_buckets - its samples counted by azdbBucket, the database histograms'
// rule; the DTU buckets count the view's avg_edtu_percent (Microsoft's own eDTU figure, the one the pool's DTU % reads),
// nil on a minute no sample carried it (a vCore pool).
func TestPoolMinuteBuckets(t *testing.T) {
	var ss []poolSample
	for _, r := range []collect.Row{
		{"end_time": "2026-11-13T12:00:15.000", "avg_cpu_percent": "5.00", "avg_data_io_percent": "50.00", "avg_log_write_percent": "10.00", "avg_edtu_percent": nil},
		{"end_time": "2026-11-13T12:00:30.000", "avg_cpu_percent": "15.00", "avg_data_io_percent": "55.00", "avg_log_write_percent": "9.99", "avg_edtu_percent": nil},
		{"end_time": "2026-11-13T12:00:45.000", "avg_cpu_percent": "100.00", "avg_data_io_percent": nil, "avg_log_write_percent": "90.00", "avg_edtu_percent": nil},
		{"end_time": "2026-11-13T11:59:50.000", "avg_cpu_percent": "1.00", "avg_data_io_percent": "1.00", "avg_log_write_percent": "1.00", "avg_edtu_percent": "1.00"}, // the read's oldest
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
	for k, want := range map[string]string{
		"cpu_buckets":  "[1 1 0 0 0 0 0 0 0 1]",
		"data_buckets": "[0 0 0 0 0 2 0 0 0 0]",
		"log_buckets":  "[1 1 0 0 0 0 0 0 0 1]",
		"dtu_buckets":  "<nil>",
	} {
		if g := fmt.Sprint(m[k]); g != want {
			t.Errorf("12:00's %s = %s, want %s", k, g, want)
		}
	}
}
