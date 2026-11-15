package config

import (
	"testing"
	"time"
)

// TestRunningPlansSwitch: task 406's running plans of a page instance are off until its box is ticked, then each
// minute; the file's global schedules: beats the page (0 = off for all); a file instance keeps its own schedules:.
func TestRunningPlansSwitch(t *testing.T) {
	file := []Instance{{Name: "f1", Engine: EngineSQLServer, Schedules: map[string]Duration{"mssql_running_plans": {Duration: 2 * time.Minute}}}}
	page := []PageInstance{
		{Name: "p_off", Engine: EngineSQLServer, DSNRef: "file:/x/p_off"},
		{Name: "p_on", Engine: EngineSQLServer, DSNRef: "file:/x/p_on", RunningPlans: true},
		{Name: "pg_on", Engine: EnginePostgres, DSNRef: "file:/x/pg_on", RunningPlans: true},
	}
	all, skipped := Merge(file, page, "full")
	if len(skipped) != 0 || len(all) != 4 {
		t.Fatalf("merge: %d instances, skipped %v", len(all), skipped)
	}
	by := map[string]Instance{}
	for _, in := range all {
		by[in.Name] = in
	}
	c := &Config{}
	for _, x := range []struct {
		name string
		want time.Duration
	}{{"f1", 2 * time.Minute}, {"p_off", 0}, {"p_on", time.Minute}, {"pg_on", 0}} {
		if got := c.Interval(by[x.name], "mssql_running_plans", 0); got != x.want {
			t.Errorf("%s: %v, want %v", x.name, got, x.want)
		}
	}
	c.Schedules = map[string]Duration{"mssql_running_plans": {Duration: 0}}
	if got := c.Interval(by["p_on"], "mssql_running_plans", 0); got != 0 {
		t.Errorf("a ticked page instance under the global schedules: 0 runs every %v", got)
	}
	if got := c.Interval(by["f1"], "mssql_running_plans", 0); got != 2*time.Minute {
		t.Errorf("a file instance's own schedules: under the global 0: %v", got)
	}
	if Fingerprint(by["p_on"]) == Fingerprint(Instance{Name: "p_on", Engine: EngineSQLServer, Platform: "auto", DSNRaw: "file:/x/p_on", QueryText: "full"}) {
		t.Error("ticking the box does not change the instance's fingerprint: its loops would not restart")
	}
}
