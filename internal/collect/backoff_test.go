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
// attempt, doubling each further failure, capped at 15 minutes (a high streak never overflows the shift) - and never
// past the instance's shortest collection interval + 2 minutes (rn-l214 B-1; 0 = not known: the 15 alone).
func TestBackoffWindowRule(t *testing.T) {
	last := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		fails int
		every time.Duration
		on    bool
		wait  time.Duration
	}{
		{0, 0, false, 0}, {1, 0, false, 0}, {2, 0, false, 0},
		{3, 0, true, time.Minute}, {4, 0, true, 2 * time.Minute}, {5, 0, true, 4 * time.Minute},
		{6, 0, true, 8 * time.Minute}, {7, 0, true, 15 * time.Minute}, {8, 0, true, 15 * time.Minute},
		{40, 0, true, 15 * time.Minute}, {500, 0, true, 15 * time.Minute},
		// B-1's cap: a minute instance waits at most 3 minutes, a 5-minute one 7, a 13-minute one and slower 15
		{2, time.Minute, false, 0}, {3, time.Minute, true, time.Minute}, {4, time.Minute, true, 2 * time.Minute},
		{5, time.Minute, true, 3 * time.Minute}, {9, time.Minute, true, 3 * time.Minute}, {500, time.Minute, true, 3 * time.Minute},
		{5, 5 * time.Minute, true, 4 * time.Minute}, {6, 5 * time.Minute, true, 7 * time.Minute}, {40, 5 * time.Minute, true, 7 * time.Minute},
		{7, 13 * time.Minute, true, 15 * time.Minute}, {7, time.Hour, true, 15 * time.Minute},
	} {
		next, on := BackoffWindow(c.fails, last, c.every)
		if on != c.on {
			t.Errorf("fails %d every %v: on = %v, want %v", c.fails, c.every, on, c.on)
			continue
		}
		if on && !next.Equal(last.Add(c.wait)) {
			t.Errorf("fails %d every %v: next try %v, want %v after the last attempt (%v)", c.fails, c.every, next, c.wait, last.Add(c.wait))
		}
	}
}

// TestConnectBackoffSkipsInsideTheWindow (L214, B1): an instance with 3 failed connects in a row skips its runs inside
// the window, the note naming the count (no times: a streak loaded at the start has no since - rn-l214 N-1); the
// probe is granted only once the window ends.
func TestConnectBackoffSkipsInsideTheWindow(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	now := time.Now()
	since := now.Add(-30 * time.Second)
	h.streaks[[2]string{"pg1", connectStreak}] = &streak{fails: 3, since: since, at: now.Add(-time.Second)}
	skip, note, release := ConnectBackoff("pg1", now)
	if !skip || release != nil {
		t.Fatalf("inside the window the run is skipped and no probe is granted: skip=%v probe=%v", skip, release != nil)
	}
	if want := " (skipped: backing off - 3 connects failed in a row)"; note != want {
		t.Errorf("the skip note = %q, want %q", note, want)
	}
	// another instance, and a streak under 3, run as before (no probe: nothing backs off)
	if skip, _, release := ConnectBackoff("pg2", now); skip || release != nil {
		t.Errorf("an instance without a streak: skip=%v probe=%v, want false false", skip, release != nil)
	}
	h.streaks[[2]string{"pg3", connectStreak}] = &streak{fails: 2, since: since, at: now}
	if skip, _, _ := ConnectBackoff("pg3", now); skip {
		t.Error("two failed connects back nothing off (the rule starts at 3)")
	}
}

// TestConnectBackoffOneProbe (L214, B1): when the window has ended, ONE loop takes the probe and the others keep
// skipping until that loop's run ends (its release); a failed probe's new window holds everyone again.
func TestConnectBackoffOneProbe(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	now := time.Now()
	h.streaks[[2]string{"pg1", connectStreak}] = &streak{fails: 3, since: now.Add(-5 * time.Minute), at: now.Add(-2 * time.Minute)}
	skip1, _, rel1 := ConnectBackoff("pg1", now)
	skip2, note2, rel2 := ConnectBackoff("pg1", now)
	if skip1 || rel1 == nil || !skip2 || rel2 != nil {
		t.Fatalf("one probe: first skip=%v probe=%v (want false true), second skip=%v probe=%v (want true false)", skip1, rel1 != nil, skip2, rel2 != nil)
	}
	if !strings.Contains(note2, "backing off") {
		t.Errorf("the second loop's note says backing off: %q", note2)
	}
	// the probe's connect fails and its run ends: the streak extends and the new window holds every loop
	_ = h.instanceConnectTimed("pg1", errors.New("dial tcp: connection refused"), now, 0)
	rel1()
	if skip, _, _ := ConnectBackoff("pg1", now.Add(time.Second)); !skip {
		t.Error("inside the new window after the probe's failure, a run was not skipped")
	}
	// the window ends again: exactly one probe again
	later := now.Add(16 * time.Minute)
	s1, _, r1 := ConnectBackoff("pg1", later)
	s2, _, r2 := ConnectBackoff("pg1", later)
	if s1 || r1 == nil || !s2 || r2 != nil {
		t.Fatalf("after the next window one probe again: first skip=%v probe=%v, second skip=%v probe=%v", s1, r1 != nil, s2, r2 != nil)
	}
	// an opened connect ends the streak: no skips, whether or not the probing run has ended yet
	_ = h.instanceConnectTimed("pg1", nil, later, 0)
	if skip, _, release := ConnectBackoff("pg1", later.Add(time.Second)); skip || release != nil {
		t.Errorf("after an opened connect the back-off is over: skip=%v probe=%v", skip, release != nil)
	}
	r1()
}

// TestConnectBackoffProbeIsItsLoops (L214, B1; rn-1's difference 1): the probe is released by its own loop alone
// (its release, when its run ends) - a run that ended before any connect frees it that way, and neither another
// loop's back-off hold nor any recorded run frees it early.
func TestConnectBackoffProbeIsItsLoops(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	now := time.Now()
	h.streaks[[2]string{"pg1", connectStreak}] = &streak{fails: 4, since: now.Add(-time.Hour), at: now.Add(-time.Hour)}
	skip, _, release := ConnectBackoff("pg1", now)
	if skip || release == nil {
		t.Fatalf("the window ended an hour ago: the first caller takes the probe (skip=%v probe=%v)", skip, release != nil)
	}
	// another loop's back-off hold is recorded while the probe is out: it must not free the probe
	_, note, _ := ConnectBackoff("pg1", now)
	h.record("pg1", "postgres", "dbstats", Result{Note: note, Held: true}, now, 0)
	if skip, _, _ := ConnectBackoff("pg1", now); !skip {
		t.Error("another loop's recorded back-off hold freed the probe: two probes at once")
	}
	// the probing loop's own run ended before any connect (a skip); its end frees the probe
	h.record("pg1", "postgres", "amcheck", Result{Note: " (skipped: amcheck is off)"}, now, 0)
	release()
	if skip, _, release := ConnectBackoff("pg1", now); skip || release == nil {
		t.Errorf("after the run ended the next caller takes the probe: skip=%v probe=%v", skip, release != nil)
	}
}

// TestProbeReleaseBoundToItsHeartbeat (rn-l214 N-5): a probe's release frees it on the heartbeat that granted it,
// whichever heartbeat is current when the run ends.
func TestProbeReleaseBoundToItsHeartbeat(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	now := time.Now()
	h.streaks[[2]string{"pg1", connectStreak}] = &streak{fails: 4, at: now.Add(-time.Hour)}
	_, _, release := ConnectBackoff("pg1", now)
	if release == nil {
		t.Fatal("no probe granted after the window")
	}
	h2, restore2 := testHeartbeat()
	defer restore2()
	h2.streaks[[2]string{"pg1", connectStreak}] = &streak{fails: 4, at: now.Add(-time.Hour)}
	h2.probing = map[string]bool{"pg1": true}
	release()
	if h.probing["pg1"] {
		t.Error("the release left the granting heartbeat's probe held")
	}
	if !h2.probing["pg1"] {
		t.Error("the release freed the current heartbeat's probe, not its own")
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

// TestHeldRunKeepsTheCollectionStreak (rn-l214 B-2): a run the back-off held ends no failing streak of the instance's
// collections - 0121's 'collection failing' stands through an outage (a held run did not try); the hour counts it
// skipped. The reviewer's case: 'roles' failing 5 runs in a row on a missing grant, then the server reboots.
func TestHeldRunKeepsTheCollectionStreak(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	now := time.Now()
	since := now.Add(-time.Hour)
	h.streaks[[2]string{"pg1", "roles"}] = &streak{fails: 5, lastErr: "permission denied for table pg_authid", since: since, at: now.Add(-time.Minute)}
	h.streaks[[2]string{"pg1", connectStreak}] = &streak{fails: 3, since: now.Add(-3 * time.Minute), at: now}
	skip, note, _ := ConnectBackoff("pg1", now)
	if !skip {
		t.Fatal("inside the window the run is held")
	}
	h.record("pg1", "postgres", "roles", Result{Note: note, Held: true}, now, time.Minute)
	s := h.streaks[[2]string{"pg1", "roles"}]
	if s.fails != 5 || !s.since.Equal(since) || s.lastErr == "" || s.dirty {
		t.Errorf("a held run changed the collection's failing streak: fails %d since %v err %q dirty %v; want 5, %v, the error kept, not dirty",
			s.fails, s.since, s.lastErr, s.dirty, since)
	}
	b := h.take()
	if len(b.Health) != 1 || b.Health[0].Skipped != 1 || b.Health[0].Error != 0 {
		t.Errorf("the hour counts a held run skipped, never failed: %+v", b.Health)
	}
	for _, bs := range b.Streaks {
		if bs.Collection == "roles" {
			t.Errorf("a held run sent the collection's streak (fails %d): the repository's row must stand", bs.Fails)
		}
	}
}

// TestStragglersInsideTheWindowMoveNothing (rn-l214 S-3): connects already in flight when the third failure opens the
// window, failing inside it with no probe out, are counted on the minute's load row but neither double the wait nor
// move it - the next try stays one unit after the third failure.
func TestStragglersInsideTheWindowMoveNothing(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	t0 := time.Now()
	lost := errors.New("dial tcp 10.0.0.9:5432: i/o timeout")
	for i := range 3 {
		_ = h.instanceConnectTimed("pg1", lost, t0.Add(time.Duration(i)*time.Second), 0)
	}
	third := t0.Add(2 * time.Second)
	_ = h.instanceConnectTimed("pg1", lost, third.Add(5*time.Second), 0) // two stragglers, each after its 10 s timeout
	_ = h.instanceConnectTimed("pg1", lost, third.Add(9*time.Second), 0)
	s := h.streaks[[2]string{"pg1", connectStreak}]
	if s.fails != 3 || !s.at.Equal(third) {
		t.Errorf("two stragglers inside the window moved the streak: fails %d at %v; want 3 at the third failure %v", s.fails, s.at, third)
	}
	if l := h.load["pg1"]; l == nil || l.attempts != 5 || l.noanswer != 5 {
		t.Errorf("every failed connect is counted on the minute's load row: %+v, want 5 attempts, 5 unanswered", l)
	}
	if skip, _, _ := ConnectBackoff("pg1", third.Add(BackoffUnit-time.Second)); !skip {
		t.Error("before one unit from the third failure the run is held")
	}
	skip, _, release := ConnectBackoff("pg1", third.Add(BackoffUnit))
	if skip || release == nil {
		t.Fatalf("one unit after the third failure the probe is granted: skip=%v probe=%v", skip, release != nil)
	}
	// the probe's own failure counts: 4 in a row, the wait doubles from it
	_ = h.instanceConnectTimed("pg1", lost, third.Add(BackoffUnit+time.Second), 0)
	release()
	if s.fails != 4 || !s.at.Equal(third.Add(BackoffUnit+time.Second)) {
		t.Errorf("the probe's failure counts: fails %d at %v, want 4 at the probe", s.fails, s.at)
	}
}

// TestBackoffStartProbesAtOnce (rn-l214 S-4): a changed instance's loops start again (a DSN fixed on Admin >
// Instances) - the old window is over and the first loop probes at once; the count is kept, so a DSN still wrong backs
// off again from its next failure.
func TestBackoffStartProbesAtOnce(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	now := time.Now()
	BackoffStart("pg1", time.Minute)
	h.streaks[[2]string{"pg1", connectStreak}] = &streak{fails: 9, since: now.Add(-time.Hour), at: now.Add(-time.Minute)}
	if skip, _, _ := ConnectBackoff("pg1", now); !skip {
		t.Fatal("before the restart the window holds the instance (3 minutes from a minute ago)")
	}
	BackoffStart("pg1", time.Minute) // the instance's loops start again
	skip, _, release := ConnectBackoff("pg1", now)
	if skip || release == nil {
		t.Fatalf("after the restart the first loop probes at once: skip=%v probe=%v", skip, release != nil)
	}
	if skip, _, _ := ConnectBackoff("pg1", now); !skip {
		t.Error("a second loop still waits for that one probe")
	}
	_ = h.instanceConnectTimed("pg1", errors.New("dial tcp: lookup pg1-typo: no such host"), now, 0)
	release()
	if s := h.streaks[[2]string{"pg1", connectStreak}]; s.fails != 10 {
		t.Errorf("the count is kept through the restart: %d, want 10", s.fails)
	}
	if skip, _, _ := ConnectBackoff("pg1", now.Add(time.Second)); !skip {
		t.Error("the probe's failure opens a window again")
	}
}

// TestBackoffStartCapsTheWindow (rn-l214 B-1, the gate's half; the repository's half is
// TestParentHoldsThroughTheBackoffOnAStore): the instance's shortest interval from its start caps the gate's wait at
// that interval + 2 units - a minute instance 9 failures in a row probes 3 minutes after its last attempt, not 15.
func TestBackoffStartCapsTheWindow(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	now := time.Now()
	BackoffStart("pg1", time.Minute)
	h.streaks[[2]string{"pg1", connectStreak}] = &streak{fails: 9, at: now.Add(-3*time.Minute - time.Second)}
	h.streaks[[2]string{"pg5", connectStreak}] = &streak{fails: 9, at: now.Add(-3*time.Minute - time.Second)} // never started: no interval known
	if skip, _, release := ConnectBackoff("pg1", now); skip || release == nil {
		t.Errorf("a minute instance waits at most 3 minutes: skip=%v probe=%v", skip, release != nil)
	}
	if skip, _, _ := ConnectBackoff("pg5", now); !skip {
		t.Error("an instance with no interval known keeps the 15 minutes")
	}
}
