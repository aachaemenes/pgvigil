package collect

import (
	"fmt"
	"time"
)

// The connect back-off (L214): after backoffAfter failed connects of an instance in a row, no loop of the instance
// connects again before a wait of BackoffUnit from the last attempt, doubling each further failure up to backoffCap
// units; then ONE loop probes while the rest keep skipping (the probe is its loop's until that run ends). A refused login never counts (the server answered,
// heartbeat.AuthFailure), a skip counts no failure, and a per-database connect never feeds the streak - only the
// instance's own connect (InstanceConnect) does. pg_exporter 1.6.1 names the idea (its 'failure cooldown'); the rule
// here is pgvigil's own and docs/collection-health.md states it.

// BackoffUnit is the back-off's unit wait (a minute). A variable so a test can scale the rule's clock.
var BackoffUnit = time.Minute

const (
	backoffAfter = 3  // failed connects in a row before the instance backs off
	backoffCap   = 15 // the longest wait, in units
)

// BackoffWindow is the rule, shared by the loop's gate and the Collector page: from fails failed connects in a row,
// whether the instance is backing off, and until when (the wait from the last attempt). Under backoffAfter it is off.
func BackoffWindow(fails int, last time.Time) (next time.Time, on bool) {
	if fails < backoffAfter {
		return time.Time{}, false
	}
	n := fails - backoffAfter
	if n > 10 {
		n = 10 // 2^10 units is far past the cap already; a long streak never overflows the shift
	}
	wait := BackoffUnit << n
	if cap := backoffCap * BackoffUnit; wait > cap {
		wait = cap
	}
	return last.Add(wait), true
}

// ConnectBackoff is the loop's gate, asked before each run: whether the instance's run is skipped now (backing off),
// with the skip's note. When the window has ended, the first caller is granted the probe (skip false, probe true) and
// the others keep skipping until that caller calls ProbeDone. The probe is OWNED BY ITS LOOP: the loop releases it
// when its run ends, whatever the run did - connected, failed, was cut by a stop, or skipped before any connect (a
// collection gated off by the configuration never connects: released any other way, its loop would hold the
// instance forever - rn-1's difference 1). Without a heartbeat there is no streak and nothing backs off.
func ConnectBackoff(instance string, now time.Time) (skip bool, note string, probe bool) {
	h := current.Load()
	if h == nil {
		return false, "", false
	}
	return h.connectBackoff(instance, now)
}

// ProbeDone releases the instance's probe: the loop that ConnectBackoff granted it calls this when its run ends.
func ProbeDone(instance string) {
	if h := current.Load(); h != nil {
		h.mu.Lock()
		delete(h.probing, instance)
		h.mu.Unlock()
	}
}

func (h *Heartbeat) connectBackoff(instance string, now time.Time) (bool, string, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.streaks[[2]string{instance, connectStreak}]
	if s == nil || s.fails < backoffAfter {
		return false, "", false
	}
	next, _ := BackoffWindow(s.fails, s.at)
	note := fmt.Sprintf(" (skipped: backing off - %d connects failed in a row since %s; next try about %s)",
		s.fails, s.since.Format(time.RFC3339), next.Format(time.RFC3339))
	if now.Before(next) {
		return true, note, false
	}
	if h.probing[instance] {
		return true, note, false // another loop holds the probe
	}
	if h.probing == nil {
		h.probing = map[string]bool{}
	}
	h.probing[instance] = true
	return false, "", true
}
