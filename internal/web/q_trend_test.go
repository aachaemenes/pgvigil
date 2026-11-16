package web

import (
	"os"
	"strings"
	"testing"
	"time"
)

// the fleet's file-IO window is one of the two the lead allowed (11-15 18:1x: 3 days when proof-trend's fleet-scale
// row reads both under 10 s, else 1 day), and the page's words name it
func TestTrendFleetFileIOWindow(t *testing.T) {
	if fleetFileIOWindow != 24*time.Hour && fleetFileIOWindow != 72*time.Hour {
		t.Fatalf("fleetFileIOWindow is %s: 1 day or 3 days only", fleetFileIOWindow)
	}
	if w := windowWords(fleetFileIOWindow); w != "1 day" && w != "3 days" {
		t.Fatalf("windowWords(%s) = %q", fleetFileIOWindow, w)
	}
	if instanceFileIOWindow != 7*24*time.Hour {
		t.Fatalf("instanceFileIOWindow is %s, the lead's 17:0x says 7 days", instanceFileIOWindow)
	}
}

func TestTrendWhy(t *testing.T) {
	for _, c := range []struct{ metric, engine, want string }{
		{"sql_cpu", "postgres", "PostgreSQL has no engine share of the host CPU"},
		{"os_cpu", "postgres", "no host read"},
		{"free_memory", "postgres", "no host read"},
		{"latency", "postgres", "track_io_timing"},
		{"active", "sqlserver", "no sample in the range"},
	} {
		if got := trendWhy(c.metric, c.engine); !strings.Contains(got, c.want) {
			t.Errorf("trendWhy(%s, %s) = %q, want it to say %q", c.metric, c.engine, got, c.want)
		}
	}
}

// every metric the handler takes is one trend_series reads (0273's CASE), and its statistics are the reader's
func TestTrendMetricsMatchTheReader(t *testing.T) {
	b, err := os.ReadFile("../repo/sql/0273_long_range_reports.sql")
	if err != nil {
		t.Fatal(err)
	}
	sql := string(b)
	for m := range trendLabel {
		if !strings.Contains(sql, "WHEN '"+m+"' THEN format(") {
			t.Errorf("metric %s: no arm in trend_series", m)
		}
	}
	for st := range trendStatHigh {
		if !strings.Contains(sql, "WHEN '"+st+"' THEN") {
			t.Errorf("stat %s: not in trend_series' fractions", st)
		}
	}
	for st := range trendStatLow {
		if !strings.Contains(sql, "WHEN '"+st+"' THEN") {
			t.Errorf("stat %s: not in trend_series' fractions", st)
		}
	}
}
