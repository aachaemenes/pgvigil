package collect

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

// TestRecordRetries (N4): a run's deadlock retries are summed per collection into the beat's runs[].retries, a failed
// run's too; a collection without any sends no retries key (collector_runs.retries 0, the beat as before); a run a
// stop cut short and a skipped run count nothing.
func TestRecordRetries(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	now := time.Now()
	h.record("db1", "postgres", "activity", Result{Rows: 3, Retries: 1}, now, 0)
	h.record("db2", "postgres", "activity", Result{Err: errors.New("import_activity: deadlock detected"), Retries: 2}, now, 0)
	h.record("db1", "postgres", "activity", Result{Err: context.Canceled, Retries: 5}, now, 0)
	h.record("db1", "postgres", "activity", Result{Note: " (skipped: not a replica)", Retries: 7}, now, 0)
	h.record("db1", "postgres", "dbstats", Result{Rows: 1}, now, 0)
	b := h.take()
	got := map[string]beatRun{}
	for _, r := range b.Runs {
		got[r.Collection] = r
	}
	if a := got["activity"]; a.Retries != 3 || a.Runs != 2 || a.Failures != 1 {
		t.Errorf("activity: runs %d, failures %d, retries %d; want 2, 1, 3", a.Runs, a.Failures, a.Retries)
	}
	if d := got["dbstats"]; d.Retries != 0 {
		t.Errorf("dbstats: retries %d, want 0", d.Retries)
	}
	body, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	s := string(body)
	if !strings.Contains(s, `"retries":3`) || strings.Count(s, `"retries"`) != 1 {
		t.Errorf("the beat's runs carry retries only where above 0 (once, 3): %s", s)
	}
}
