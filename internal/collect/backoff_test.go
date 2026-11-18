package collect

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// testHeartbeat installs a bare in-memory heartbeat as the current one and returns it with a restore func.
func testHeartbeat() (*Heartbeat, func()) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	old := current.Swap(h)
	return h, func() { current.Store(old) }
}

// TestBackoffWindowRule (L214): no window under 3 failed connects in a row; from 3 the wait is a minute from the last
// attempt, doubling each further failure, capped at 15 minutes (a high streak never overflows the shift).
func TestBackoffWindowRule(t *testing.T) {
	last := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		fails int
		on    bool
		wait  time.Duration
	}{
		{0, false, 0}, {1, false, 0}, {2, false, 0},
		{3, true, time.Minute}, {4, true, 2 * time.Minute}, {5, true, 4 * time.Minute},
		{6, true, 8 * time.Minute}, {7, true, 15 * time.Minute}, {8, true, 15 * time.Minute},
		{40, true, 15 * time.Minute}, {500, true, 15 * time.Minute},
	} {
		next, on := BackoffWindow(c.fails, last)
		if on != c.on {
			t.Errorf("fails %d: on = %v, want %v", c.fails, on, c.on)
			continue
		}
		if on && !next.Equal(last.Add(c.wait)) {
			t.Errorf("fails %d: next try %v, want %v after the last attempt (%v)", c.fails, next, c.wait, last.Add(c.wait))
		}
	}
}

// TestConnectBackoffSkipsInsideTheWindow (L214, B1): an instance with 3 failed connects in a row skips its runs inside
// the window, the note naming the count, since when, and the next try; the probe is granted only once the window ends.
func TestConnectBackoffSkipsInsideTheWindow(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	now := time.Now()
	since := now.Add(-30 * time.Second)
	h.streaks[[2]string{"pg1", connectStreak}] = &streak{fails: 3, since: since, at: now.Add(-time.Second)}
	skip, note, probe := ConnectBackoff("pg1", now)
	if !skip || probe {
		t.Fatalf("inside the window the run is skipped and no probe is granted: skip=%v probe=%v", skip, probe)
	}
	for _, want := range []string{" (skipped: backing off - 3 connects failed in a row since ", "; next try about "} {
		if !strings.Contains(note, want) {
			t.Errorf("the skip note lacks %q: %q", want, note)
		}
	}
	// another instance, and a streak under 3, run as before (no probe: nothing backs off)
	if skip, _, probe := ConnectBackoff("pg2", now); skip || probe {
		t.Errorf("an instance without a streak: skip=%v probe=%v, want false false", skip, probe)
	}
	h.streaks[[2]string{"pg3", connectStreak}] = &streak{fails: 2, since: since, at: now}
	if skip, _, _ := ConnectBackoff("pg3", now); skip {
		t.Error("two failed connects back nothing off (the rule starts at 3)")
	}
}

// TestConnectBackoffOneProbe (L214, B1): when the window has ended, ONE loop takes the probe and the others keep
// skipping until that loop's run ends (ProbeDone); a failed probe's new window holds everyone again.
func TestConnectBackoffOneProbe(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	now := time.Now()
	h.streaks[[2]string{"pg1", connectStreak}] = &streak{fails: 3, since: now.Add(-5 * time.Minute), at: now.Add(-2 * time.Minute)}
	skip1, _, probe1 := ConnectBackoff("pg1", now)
	skip2, note2, probe2 := ConnectBackoff("pg1", now)
	if skip1 || !probe1 || !skip2 || probe2 {
		t.Fatalf("one probe: first skip=%v probe=%v (want false true), second skip=%v probe=%v (want true false)", skip1, probe1, skip2, probe2)
	}
	if !strings.Contains(note2, "backing off") {
		t.Errorf("the second loop's note says backing off: %q", note2)
	}
	// the probe's connect fails and its run ends: the streak extends and the new window holds every loop
	_ = h.instanceConnectTimed("pg1", errors.New("dial tcp: connection refused"), now, 0)
	ProbeDone("pg1")
	if skip, _, _ := ConnectBackoff("pg1", now.Add(time.Second)); !skip {
		t.Error("inside the new window after the probe's failure, a run was not skipped")
	}
	// the window ends again: exactly one probe again
	later := now.Add(16 * time.Minute)
	s1, _, p1 := ConnectBackoff("pg1", later)
	s2, _, p2 := ConnectBackoff("pg1", later)
	if s1 || !p1 || !s2 || p2 {
		t.Errorf("after the next window one probe again: first skip=%v probe=%v, second skip=%v probe=%v", s1, p1, s2, p2)
	}
	// an opened connect ends the streak: no skips, whether or not the probing run has ended yet
	_ = h.instanceConnectTimed("pg1", nil, later, 0)
	if skip, _, probe := ConnectBackoff("pg1", later.Add(time.Second)); skip || probe {
		t.Errorf("after an opened connect the back-off is over: skip=%v probe=%v", skip, probe)
	}
	ProbeDone("pg1")
}

// TestConnectBackoffProbeIsItsLoops (L214, B1; rn-1's difference 1): the probe is released by its own loop alone
// (ProbeDone, when its run ends) - a run that skipped before any connect (a gated collection) frees it that way, and
// neither another loop's back-off skip nor any recorded run frees it early.
func TestConnectBackoffProbeIsItsLoops(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	now := time.Now()
	h.streaks[[2]string{"pg1", connectStreak}] = &streak{fails: 4, since: now.Add(-time.Hour), at: now.Add(-time.Hour)}
	if skip, _, probe := ConnectBackoff("pg1", now); skip || !probe {
		t.Fatalf("the window ended an hour ago: the first caller takes the probe (skip=%v probe=%v)", skip, probe)
	}
	// another loop's back-off skip is recorded while the probe is out: it must not free the probe
	_, note, _ := ConnectBackoff("pg1", now)
	h.record("pg1", "postgres", "dbstats", Result{Note: note}, now, 0)
	if skip, _, _ := ConnectBackoff("pg1", now); !skip {
		t.Error("another loop's recorded back-off skip freed the probe: two probes at once")
	}
	// the probing loop's own run skipped before any connect (a gated collection); its end frees the probe
	h.record("pg1", "postgres", "amcheck", Result{Note: " (skipped: amcheck is off)"}, now, 0)
	ProbeDone("pg1")
	if skip, _, probe := ConnectBackoff("pg1", now); skip || !probe {
		t.Errorf("after the gated run ended the next caller takes the probe: skip=%v probe=%v", skip, probe)
	}
}

// TestAuthFailureNeverBacksOff (L214, proof R4): a refused login is the server answering - it ends a streak and never
// builds one, so the instance is never backed off.
func TestAuthFailureNeverBacksOff(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	now := time.Now()
	auth := &pgconn.PgError{Code: "28P01", Message: "password authentication failed"}
	for i := 0; i < 5; i++ {
		_ = h.instanceConnectTimed("pg1", auth, now, 0)
	}
	if s := h.streaks[[2]string{"pg1", connectStreak}]; s != nil && s.fails != 0 {
		t.Fatalf("5 refused logins built a streak of %d; want 0", s.fails)
	}
	if skip, _, _ := ConnectBackoff("pg1", now); skip {
		t.Error("an instance refusing logins was backed off")
	}
	// a streak ends at a refused login too
	_ = h.instanceConnectTimed("pg2", errors.New("connection refused"), now, 0)
	_ = h.instanceConnectTimed("pg2", errors.New("connection refused"), now, 0)
	_ = h.instanceConnectTimed("pg2", errors.New("connection refused"), now, 0)
	_ = h.instanceConnectTimed("pg2", auth, now, 0)
	if skip, _, _ := ConnectBackoff("pg2", now); skip {
		t.Error("a streak ended by a refused login still backed the instance off")
	}
}

// TestOutcomeTimedOut (L250, B3): 'timed out' is its own outcome, set by the loop on a run its deadline cancelled; the
// hour counts it as a failure.
func TestOutcomeTimedOut(t *testing.T) {
	res := Result{Err: errors.New("timed out after 2m0s"), Outcome: OutcomeTimedOut}
	if got := outcomeOf(res); got != OutcomeTimedOut {
		t.Errorf("outcomeOf = %q, want %q", got, OutcomeTimedOut)
	}
	h, restore := testHeartbeat()
	defer restore()
	h.record("pg1", "postgres", "activity", res, time.Now(), time.Minute)
	b := h.take()
	if len(b.Health) != 1 || b.Health[0].Error != 1 || b.Health[0].Runs != 1 {
		t.Fatalf("a timed-out run counts as the hour's failure: %+v", b.Health)
	}
}
