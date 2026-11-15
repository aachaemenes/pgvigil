package mssql

import (
	"testing"
	"time"
)

// TestTokenHoldNotCounted: the slow-connect tier times a SQL Server connect as db.Conn's elapsed time minus the time
// the sign-in was held for a third party (the pass's #7: an Entra token fetch is the identity provider's, not the
// server's) - Hold records it with a deadline of the dialer's and without one (a DSN with its own 'connection
// timeout'), a nested Hold once; connectTook takes it off and never answers less than a nanosecond (an opened connect
// is timed).
func TestTokenHoldNotCounted(t *testing.T) {
	for _, tc := range []struct {
		name  string
		until time.Time
	}{{"the DSN's own timeout", time.Time{}}, {"the dialer's deadline", time.Now().Add(10 * time.Second)}} {
		d := &deadlineDialer{until: tc.until}
		rel := d.Hold()
		inner := d.Hold() // the provider asked twice inside one sign-in: one hold
		time.Sleep(300 * time.Millisecond)
		inner()
		rel()
		if h := d.heldTotal(); h < 300*time.Millisecond || h > 550*time.Millisecond {
			t.Errorf("%s: held %v, want about 300 ms (the nested hold once: twice is 600 ms or more)", tc.name, h)
		}
	}
	if got := connectTook(400*time.Millisecond, 300*time.Millisecond); got != 100*time.Millisecond {
		t.Errorf("connectTook(400 ms, held 300 ms): %v, want 100 ms (the hold taken off)", got)
	}
	if got := connectTook(100*time.Millisecond, 300*time.Millisecond); got <= 0 {
		t.Errorf("connectTook under its hold: %v, want above 0 (an opened connect is timed)", got)
	}
}
