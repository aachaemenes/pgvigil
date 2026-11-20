package collect

import (
	"fmt"
	"time"
)

// The connect back-off (L214): after backoffAfter failed connects of an instance in a row, no loop of the instance
// connects again before a wait of BackoffUnit from the last attempt, doubling each further failure up to backoffCap
// units and never past the host's span + backoffSlack units (rn-l214 B-1 as the lead ruled 21:55: the span 0121's
// freshness uses - the least collection interval of the host's instances, 1 to 5 units - never the instance's own); then ONE loop
// probes while the rest keep skipping (the probe is its loop's until that run ends). A connect already in flight
// that fails inside an open window is counted on the minute's load row but neither doubles the wait nor moves it
// (rn-l214 S-3: the first wait stays a unit). A refused login never counts (the server answered,
// heartbeat.AuthFailure), a held run counts no failure and ends no streak (Result.Held), and a per-database connect
// never feeds the streak - only the instance's own connect (InstanceConnect) does. pg_exporter 1.6.1 names the idea
// (its 'failure cooldown'); the rule here is pgvigil's own and docs/collection-health.md states it.

// BackoffUnit is the back-off's unit wait (a minute). A variable so a test can scale the rule's clock.
var BackoffUnit = time.Minute

const (
	backoffAfter = 3  // failed connects in a row before the instance backs off
	backoffCap   = 15 // the longest wait, in units, while no interval of the host is known (Q1's 15 minutes)
	// backoffSlack: the wait is never longer than the host's span + this many units (rn-l214 B-1, the lead's (a) of
	// 21:19 as ruled 21:55): the span is 0121's - the least collection interval of the host's instances, 1 to 5 units -
	// so a backed-off instance's 'dead' spell stays read inside the 'collector or network' parent's freshness (the
	// span + 3 minutes), an instance slower than its host's fastest one too; the parent holds through the outage
	backoffSlack = 2
	spanFloor    = 1 // 0121's span: at least a unit...
	spanCeil     = 5 // ...and at most five
)

// BackoffWindow is the rule, shared by the loop's gate and the Collector page: from fails failed connects in a row,
// whether the instance is backing off, and until when (the wait from the last attempt). Under backoffAfter it is off.
// every is the host's span (hostSpan): the wait never outgrows it + backoffSlack units (B-1); 0 = not known, the cap
// alone.
func BackoffWindow(fails int, last time.Time, every time.Duration) (next time.Time, on bool) {
	if fails < backoffAfter {
		return time.Time{}, false
	}
	n := fails - backoffAfter
	if n > 10 {
		n = 10 // 2^10 units is far past the cap already; a long streak never overflows the shift
	}
	wait := BackoffUnit << n
	longest := backoffCap * BackoffUnit
	if every > 0 {
		longest = min(longest, every+backoffSlack*BackoffUnit)
	}
	if wait > longest {
		wait = longest
	}
	return last.Add(wait), true
}

// BackoffStart is sched's, at each start of an instance's loops (the process's start, a changed instance's restart):
// the instance's shortest collection interval, of which the host's span is the least (hostSpan, BackoffWindow's
// every; B-1), and a changed instance's next try now (rn-l214 S-4: a DSN fixed on Admin > Instances probes at once, not at the old window's end;
// the count is kept, so a still-wrong DSN backs off again at its next failure). Nothing without a heartbeat.
func BackoffStart(instance string, every time.Duration) {
	h := current.Load()
	if h == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.every == nil {
		h.every = map[string]time.Duration{}
	}
	h.every[instance] = every
	if s := h.streaks[[2]string{instance, connectStreak}]; s != nil {
		s.retry = true
	}
}

// ConnectBackoff is the loop's gate, asked before each run: whether the instance's run is held now (backing off),
// with the hold's note. When the window has ended, the first caller is granted the probe (skip false, release
// non-nil) and the others keep skipping until that caller calls release. The probe is OWNED BY ITS LOOP: the loop
// releases it when its run ends, whatever the run did - connected, failed, was cut by a stop or its deadline, or
// ended before any instance connect (rn-l214 N-6: SQL Server's Wants and cached-detect skips, a password secret that
// could not be read, a stop in the middle of the connect - released any other way, such a loop would hold the
// instance forever: rn-1's difference 1). release is bound to the heartbeat that granted the probe (N-5). Without a
// heartbeat there is no streak and nothing backs off.
func ConnectBackoff(instance string, now time.Time) (skip bool, note string, release func()) {
	h := current.Load()
	if h == nil {
		return false, "", nil
	}
	return h.connectBackoff(instance, now)
}

func (h *Heartbeat) connectBackoff(instance string, now time.Time) (bool, string, func()) {
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.streaks[[2]string{instance, connectStreak}]
	if s == nil || s.fails < backoffAfter {
		return false, "", nil
	}
	// the note says why the run did not try; it feeds the hour's skipped count alone (Result.Held) - no row, no
	// line. No times in it: a streak loaded at the start has no since (N-1)
	note := fmt.Sprintf(" (skipped: backing off - %d connects failed in a row)", s.fails)
	if next, _ := BackoffWindow(s.fails, s.at, h.hostSpan()); !s.retry && now.Before(next) {
		return true, note, nil
	}
	if h.probing[instance] {
		return true, note, nil // another loop holds the probe
	}
	if h.probing == nil {
		h.probing = map[string]bool{}
	}
	h.probing[instance] = true
	return false, "", func() {
		h.mu.Lock()
		delete(h.probing, instance)
		h.mu.Unlock()
	}
}

// hostSpan is 0121's span as the gate knows it (rn-l214 B-1, the lead's 21:55): the least shortest interval of the
// instances this run started (BackoffStart), clamped to 1 to 5 units; 0 while none is known. The repository reads
// the same span from the load rows (collector_span_take), so the window and the parent's freshness share it. Called
// under h.mu.
func (h *Heartbeat) hostSpan() time.Duration {
	var least time.Duration
	for _, e := range h.every {
		if e > 0 && (least == 0 || e < least) {
			least = e
		}
	}
	if least == 0 {
		return 0
	}
	return min(max(least, spanFloor*BackoffUnit), spanCeil*BackoffUnit)
}
