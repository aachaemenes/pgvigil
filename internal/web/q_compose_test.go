package web

import "testing"

// TestCatalogGrain: the grain a catalog without its grain column gets is scripts/metric-catalog-grain.sql's rule.
func TestCatalogGrain(t *testing.T) {
	for _, c := range []struct{ key, unit, want string }{
		{"database.commits_s", "per_s", "rate"}, {"io.read_bytes_s", "bytes_per_s", "rate"}, {"database.cache_hit_pct", "pct", "ratio"},
		{"database.deadlocks", "count", "interval_count"}, {"server.checkpoints_req", "count", "interval_count"},
		{"sessions.total", "count", "gauge"}, {"memory.ple", "secs", "gauge"}, {"memory.total_mb", "mb", "gauge"},
	} {
		if got := catalogGrain(c.key, c.unit); got != c.want {
			t.Errorf("%s (%s): %s, want %s", c.key, c.unit, got, c.want)
		}
	}
}
