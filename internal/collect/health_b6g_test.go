package collect

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

// TestCollectionHealthImportAndCPU (B6g-1; N25, N26, N27 - rows G1 and G2's counting half): the hour's new totals.
// The import's time is counted apart from the run's (the r.Import calls only; the run's Duration stays the whole run)
// for every run that attempted one - a failed import too, a 0 ms one too; a run whose read succeeded and whose write
// failed is 'import failed': an ERROR for every count that judges (Failed includes it, as DBA Dash's FailedCount holds
// ImportFailedCount) and counted once more as Import Failed. A run that read its own session at its end (SQL Server)
// adds its CPU and logical reads and is a 'cpu run' - also when the run itself failed; a run that did not read them
// (PostgreSQL; an end read that failed) is not, and a skip adds nothing anywhere.
func TestCollectionHealthImportAndCPU(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	at := time.Date(2026, 11, 15, 9, 15, 0, 0, time.UTC)
	m, sec, ms := time.Minute, time.Second, time.Millisecond
	n := func(v int64) *int64 { return &v }
	h.record("s1", "sqlserver", "waits", Result{Duration: 200 * ms, Rows: 4, Imported: true, Import: 30 * ms, CPUMs: n(12), Reads: n(900)}, at, m)
	h.record("s1", "sqlserver", "waits", Result{Duration: 500 * ms, Err: errors.New("import waits from s1: boom"), Outcome: OutcomeImportFailed,
		Imported: true, Import: 400 * ms, CPUMs: n(20), Reads: n(100)}, at.Add(1*sec), m)
	h.record("s1", "sqlserver", "waits", Result{Duration: 50 * ms, Err: errors.New("waits on s1: read"), CPUMs: n(5), Reads: n(10)}, at.Add(2*sec), m)
	h.record("s1", "sqlserver", "waits", Result{Duration: 10 * ms, Rows: 1, Imported: true}, at.Add(3*sec), m)
	h.record("s1", "sqlserver", "waits", Result{Duration: 5 * ms, Note: " (skipped: not on this edition)", CPUMs: n(1), Reads: n(1)}, at.Add(4*sec), m)
	b := h.take()
	if len(b.Health) != 1 {
		t.Fatalf("health rows %d, want 1: %+v", len(b.Health), b.Health)
	}
	g := b.Health[0]
	if g.LastError == nil || !g.LastError.Equal(at.Add(2*sec)) {
		t.Errorf("last error %v, want the read error's start %v (an import failure is an error too: %v was the one before)", g.LastError, at.Add(2*sec), at.Add(1*sec))
	}
	g.LastOk, g.LastError, g.LastPartial = nil, nil, nil
	want := beatHealth{Instance: "s1", Collection: "waits", Hour: time.Date(2026, 11, 15, 9, 0, 0, 0, time.UTC),
		Runs: 4, Ok: 2, Error: 2, Skipped: 1, Rows: 5, DurSum: 200 + 500 + 50 + 10, DurMax: 500, IntervalS: 60,
		ImportFailed: 1, ImportRuns: 3, ImportSum: 30 + 400 + 0, ImportMax: 400,
		CPURuns: 3, CPUSum: 12 + 20 + 5, CPUMax: 20, ReadsSum: 900 + 100 + 10}
	if g != want {
		t.Fatalf("health row\n got %+v\nwant %+v", g, want)
	}
	// the beat's JSON names: import_collection_health (0166) reads these keys
	raw, _ := json.Marshal(g)
	for _, k := range []string{`"import_failed":1`, `"import_runs":3`, `"import_ms_sum":430`, `"import_ms_max":400`, `"cpu_runs":3`, `"cpu_ms_sum":37`, `"cpu_ms_max":20`, `"reads_sum":1010`} {
		if !strings.Contains(string(raw), k) {
			t.Errorf("the beat's row %s lacks %s", raw, k)
		}
	}
}

// TestOutcomeImportFailed (B6g-1, N27): 'import failed' is the run's outcome when the producer says so - checked
// before the plain error (the run's Err stays set: collection_dates and collection_log keep 'error', stage 'import')
func TestOutcomeImportFailed(t *testing.T) {
	if got := outcomeOf(Result{Err: errors.New("import x from i: boom"), Outcome: OutcomeImportFailed}); got != OutcomeImportFailed {
		t.Errorf("outcomeOf(an import failure) = %q, want %q", got, OutcomeImportFailed)
	}
	if got := outcomeOf(Result{Err: errors.New("x on i: read"), Outcome: OutcomePartial}); got != OutcomeError {
		t.Errorf("outcomeOf(a read error) = %q, want %q", got, OutcomeError)
	}
}

// TestTimedImport (B6g-1, N27): the helper every import path uses - each call's time added (two imports of one run
// sum), Imported set, the error passed through; a failed import marks the result 'import failed' with its error
func TestTimedImport(t *testing.T) {
	var res Result
	if err := res.TimedImport(func() error { time.Sleep(20 * time.Millisecond); return nil }); err != nil {
		t.Fatal(err)
	}
	if !res.Imported || res.Import < 20*time.Millisecond || res.Outcome != "" {
		t.Errorf("after one import: %+v, want Imported, at least 20 ms, no outcome", res)
	}
	first := res.Import
	boom := errors.New("boom")
	if err := res.TimedImport(func() error { time.Sleep(10 * time.Millisecond); return boom }); err != boom {
		t.Errorf("a failed import returned %v, want its own error", err)
	}
	if res.Import < first+10*time.Millisecond || res.Outcome != OutcomeImportFailed {
		t.Errorf("after a failed second import: %+v, want the two times summed and the outcome 'import failed'", res)
	}
}
