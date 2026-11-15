package collect

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

// TestCollectionHealthHourly: B6.1's hourly counts per instance, collection and UTC hour (DBA Dash's CollectionRuns,
// rolled up by the hour) - every outcome counted, a skip before record()'s early return (its time not in the
// durations), a connect failure an error (its rows not counted), a run cut short by a stop not counted; the runs over
// half their interval and over it (a run of exactly half is not over); the shortest interval kept; the last ok (a
// partial counts: a success for Last Success), the last error and the last partial each the time of its own run;
// running totals sent at every beat (a lost beat repaired by the next), the hour before the newest still sent, an hour
// dropped once the hour after next has begun.
func TestCollectionHealthHourly(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	at := time.Date(2026, 11, 14, 10, 15, 0, 0, time.FixedZone("ist", 5*3600+1800)) // a +05:30 clock: the hour is UTC's 04:00
	m, sec := time.Minute, time.Second
	h.record("i1", "postgres", "activity", Result{Duration: 10 * time.Millisecond, Rows: 3}, at, m)
	h.record("i1", "postgres", "activity", Result{Duration: 40 * sec, Rows: 2, Outcome: OutcomePartial}, at.Add(1*sec), m)
	h.record("i1", "postgres", "activity", Result{Duration: 70 * sec, Rows: 7, Err: errors.New("boom")}, at.Add(2*sec), m)
	h.record("i1", "postgres", "activity", Result{Duration: 2 * sec, Err: &connectError{err: errors.New("refused")}}, at.Add(3*sec), m)
	h.record("i1", "postgres", "activity", Result{Duration: 5 * sec, Note: " (skipped: no pg_cron)"}, at.Add(4*sec), m)
	h.record("i1", "postgres", "activity", Result{Err: context.Canceled}, at.Add(5*sec), m)
	h.record("i1", "postgres", "activity", Result{Duration: 30 * sec}, at.Add(6*sec), m)
	// the last partial BEFORE the last ok (the review of the fold, 20261115-001030 #1): an ok branch that stops setting
	// lastOk, or sets lastPartial, shows here
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond, Outcome: OutcomePartial}, at.Add(7*sec), m)
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond}, at.Add(8*sec), 2*m)
	b := h.take()
	if len(b.Health) != 1 {
		t.Fatalf("health rows %d, want 1: %+v", len(b.Health), b.Health)
	}
	g := b.Health[0]
	want := beatHealth{Instance: "i1", Collection: "activity", Hour: time.Date(2026, 11, 14, 4, 0, 0, 0, time.UTC),
		Runs: 7, Ok: 3, Partial: 2, Error: 2, Skipped: 1, Rows: 5, DurSum: 10 + 40000 + 70000 + 2000 + 30000 + 1 + 1, DurMax: 70000,
		OverHalf: 2, OverInterval: 1, IntervalS: 60}
	for _, c := range []struct {
		name string
		got  *time.Time
		want time.Time
	}{{"last ok (a partial included)", g.LastOk, at.Add(8 * sec)}, {"last error", g.LastError, at.Add(3 * sec)}, {"last partial", g.LastPartial, at.Add(7 * sec)}} {
		if c.got == nil || !c.got.Equal(c.want) {
			t.Errorf("%s %v, want %v", c.name, c.got, c.want.UTC())
		}
	}
	g.LastOk, g.LastError, g.LastPartial = nil, nil, nil
	if g != want {
		t.Fatalf("health row\n got %+v\nwant %+v", g, want)
	}
	// running totals: the next beat sends the same counts again (a lost beat is repaired), plus what came since
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond}, at.Add(9*sec), m)
	if b2 := h.take(); len(b2.Health) != 1 || b2.Health[0].Runs != 8 || b2.Health[0].Ok != 4 {
		t.Fatalf("second beat %+v, want the running totals runs 8 ok 4", b2.Health)
	}
	// the next hour: 04:00 is still sent beside 05:00 (a run counted into 04:00 after its last beat reaches the store)
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond}, at.Add(time.Hour), m)
	if b3 := h.take(); len(b3.Health) != 2 {
		t.Fatalf("next hour's beat %+v, want 04:00 and 05:00", b3.Health)
	}
	// the hour after next: 04:00 and 05:00 are sent no more
	later := at.Add(3 * time.Hour)
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond}, later, m)
	b4 := h.take()
	if len(b4.Health) != 1 || b4.Health[0].Hour != time.Date(2026, 11, 14, 7, 0, 0, 0, time.UTC) {
		t.Fatalf("beat three hours on %+v, want the 07:00 row alone", b4.Health)
	}
}

// TestCollectionHealthClockBack: a host clock stepped back (NTP after a clock that ran fast, a VM resumed) does not
// drop the runs of the hours it steps back to, and the hours ahead of it (sent already) are sent no more
func TestCollectionHealthClockBack(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	fast := time.Date(2026, 11, 14, 7, 10, 0, 0, time.UTC)
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond}, fast, time.Minute)
	_ = h.take()
	back := time.Date(2026, 11, 14, 3, 20, 0, 0, time.UTC)
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond}, back, time.Minute)
	b := h.take()
	if len(b.Health) != 1 || b.Health[0].Hour != time.Date(2026, 11, 14, 3, 0, 0, 0, time.UTC) || b.Health[0].Runs != 1 {
		t.Fatalf("after the clock stepped back %+v, want the 03:00 row alone, runs 1", b.Health)
	}
	// the hour's slack (the review of the fold, 20261115-001030 #3): two runs that read the clock either side of 06:00
	// and took the lock in the other order are one hour apart, not a clock step back - both hours are kept
	h = &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	six := time.Date(2026, 11, 14, 6, 0, 0, 0, time.UTC)
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond}, six.Add(500*time.Millisecond), time.Minute)
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond}, six.Add(-100*time.Millisecond), time.Minute)
	b = h.take()
	got := map[time.Time]int{}
	for _, r := range b.Health {
		got[r.Hour] = r.Runs
	}
	if len(b.Health) != 2 || got[six.Add(-time.Hour)] != 1 || got[six] != 1 {
		t.Fatalf("two runs either side of 06:00 recorded out of order %+v, want 05:00 runs 1 and 06:00 runs 1", b.Health)
	}
}

// TestBeatBodyHealthOnce: the hourly rows ride in their own statement's body, never in the heartbeat's (which
// import_collector_beat parses and ignores)
func TestBeatBodyHealthOnce(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond}, time.Date(2026, 11, 14, 7, 10, 0, 0, time.UTC), time.Minute)
	b := h.take()
	body, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), `"health"`) {
		t.Errorf("the heartbeat's body carries the hourly rows: %s", body)
	}
	// what beat() sends (healthWrite): the import door, the collector's id, the hourly rows' own body
	q, args, err := healthWrite("c1", b.Health)
	if err != nil {
		t.Fatal(err)
	}
	hb, _ := args[1].(string)
	if !strings.Contains(q, "pgvigil.import_collection_health($1, $2::jsonb)") || len(args) != 2 || args[0] != "c1" ||
		!strings.HasPrefix(hb, `{"health":[{"instance":"i1","collection":"activity"`) {
		t.Errorf("the hourly write %q %v, want import_collection_health with c1 and {\"health\":[{\"instance\":\"i1\",...", q, args)
	}
}

// TestAmcheckUnchecked: an amcheck run that left relations unchecked (a missing EXECUTE, a lock_timeout) ends partial -
// a collector_error row per such database and check; a run that only reached its budget (a note) stays ok
func TestAmcheckUnchecked(t *testing.T) {
	rows := []Row{
		{"kind": "run", "datname": "app", "check_name": "btree", "status": "error", "checked": 0, "errors": 4},
		{"kind": "run", "datname": "app", "check_name": "heap", "status": "partial", "checked": 3, "errors": 1},
		{"kind": "run", "datname": "web", "check_name": "btree", "status": "partial", "checked": 9, "errors": 0, "note": "budget reached"},
		{"kind": "problem", "datname": "app", "relation": "t1"},
	}
	got := amcheckUnchecked(rows)
	if len(got) != 2 {
		t.Fatalf("collector_error rows %+v, want 2 (app's btree and heap)", got)
	}
	for i, w := range []string{"btree: 4 relation(s) not checked", "heap: 1 relation(s) not checked"} {
		if got[i]["kind"] != "collector_error" || got[i]["source"] != "amcheck:app" || got[i]["message"] != w {
			t.Errorf("row %d %+v, want collector_error amcheck:app %q", i, got[i], w)
		}
	}
}

// TestOutcomeOf: the outcome a run reports - its own when a producer set it (partial), else error, skipped or ok
func TestOutcomeOf(t *testing.T) {
	for _, c := range []struct {
		res  Result
		want string
	}{
		{Result{}, OutcomeOK},
		{Result{Outcome: OutcomePartial}, OutcomePartial},
		{Result{Err: errors.New("x")}, OutcomeError},
		{Result{Err: errors.New("x"), Outcome: OutcomePartial}, OutcomeError},
		{Result{Note: " (skipped: why)"}, OutcomeSkipped},
	} {
		if got := outcomeOf(c.res); got != c.want {
			t.Errorf("outcomeOf(%+v) = %q, want %q", c.res, got, c.want)
		}
	}
}
