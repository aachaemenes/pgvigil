package collect

import (
	"context"
	"errors"
	"testing"
	"time"
)

// TestCollectionHealthHourly: B6.1's hourly counts per instance, collection and UTC hour (DBA Dash's CollectionRuns,
// rolled up by the hour) - every outcome counted, a skip before record()'s early return, a connect failure an error, a
// run cut short by a stop not counted; the runs over half their interval and over it; running totals sent at every
// beat (a lost beat repaired by the next), an hour dropped once the hour after next has begun.
func TestCollectionHealthHourly(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	at := time.Date(2026, 11, 14, 10, 15, 0, 0, time.FixedZone("ist", 5*3600+1800)) // a +05:30 clock: the hour is UTC's 04:00
	m := time.Minute
	h.record("i1", "postgres", "activity", Result{Duration: 10 * time.Millisecond, Rows: 3}, at, m)
	h.record("i1", "postgres", "activity", Result{Duration: 40 * time.Second, Rows: 2, Outcome: OutcomePartial}, at, m)
	h.record("i1", "postgres", "activity", Result{Duration: 70 * time.Second, Err: errors.New("boom")}, at, m)
	h.record("i1", "postgres", "activity", Result{Duration: 2 * time.Second, Err: &connectError{err: errors.New("refused")}}, at, m)
	h.record("i1", "postgres", "activity", Result{Note: " (skipped: no pg_cron)"}, at, m)
	h.record("i1", "postgres", "activity", Result{Err: context.Canceled}, at, m)
	b := h.take()
	if len(b.Health) != 1 {
		t.Fatalf("health rows %d, want 1: %+v", len(b.Health), b.Health)
	}
	g := b.Health[0]
	want := beatHealth{Instance: "i1", Collection: "activity", Hour: time.Date(2026, 11, 14, 4, 0, 0, 0, time.UTC),
		Runs: 4, Ok: 1, Partial: 1, Error: 2, Skipped: 1, Rows: 5, DurSum: 10 + 40000 + 70000 + 2000, DurMax: 70000,
		OverHalf: 2, OverInterval: 1, IntervalS: 60}
	if g.LastOk == nil || g.LastError == nil || g.LastPartial == nil {
		t.Fatalf("last ok / error / partial: %v %v %v, want all set", g.LastOk, g.LastError, g.LastPartial)
	}
	g.LastOk, g.LastError, g.LastPartial = nil, nil, nil
	if g != want {
		t.Fatalf("health row\n got %+v\nwant %+v", g, want)
	}
	// running totals: the next beat sends the same counts again (a lost beat is repaired), plus what came since
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond}, at, m)
	if b2 := h.take(); len(b2.Health) != 1 || b2.Health[0].Runs != 5 || b2.Health[0].Ok != 2 {
		t.Fatalf("second beat %+v, want the running totals runs 5 ok 2", b2.Health)
	}
	// the hour after next: 04:00 is sent no more
	later := at.Add(2 * time.Hour)
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond}, later, m)
	b3 := h.take()
	for _, r := range b3.Health {
		if r.Hour.Equal(want.Hour) {
			t.Fatalf("hour %v still sent two hours on: %+v", want.Hour, b3.Health)
		}
	}
	if len(b3.Health) != 1 || b3.Health[0].Hour != time.Date(2026, 11, 14, 6, 0, 0, 0, time.UTC) {
		t.Fatalf("third beat %+v, want the 06:00 row alone", b3.Health)
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
