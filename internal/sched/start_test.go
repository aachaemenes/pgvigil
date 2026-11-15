package sched

import (
	"testing"
	"time"
)

// TestFirstStartSpread: a loop's first run after a start falls at a random offset in min(interval, 5 min) (the M0
// measurement, the lead's decision 11-14): the minute collections of every instance spread over their whole minute and
// the 5-minute ones over 5 minutes - not all inside the first 10 s, where a collector's CPU queues every connect
// (about 2.4 ms of it per PostgreSQL connect with TLS) - while an hourly or daily collection still runs within 5 min.
func TestFirstStartSpread(t *testing.T) {
	for _, c := range []struct{ iv, want time.Duration }{
		{30 * time.Second, 30 * time.Second}, {time.Minute, time.Minute}, {5 * time.Minute, 5 * time.Minute},
		{15 * time.Minute, 5 * time.Minute}, {time.Hour, 5 * time.Minute}, {24 * time.Hour, 5 * time.Minute},
	} {
		if got := firstStartSpread(c.iv); got != c.want {
			t.Errorf("interval %v: spread %v, want %v", c.iv, got, c.want)
		}
		var hi time.Duration
		for i := 0; i < 2000; i++ {
			d := firstStart(c.iv)
			if d < 0 || d >= c.want {
				t.Fatalf("interval %v: a first start at %v, outside [0, %v)", c.iv, d, c.want)
			}
			hi = max(hi, d)
		}
		if hi < c.want*9/10 {
			t.Errorf("interval %v: the latest of 2000 first starts %v, want near %v (the whole spread used)", c.iv, hi.Round(time.Millisecond), c.want)
		}
	}
	if d := firstStart(0); d != 0 {
		t.Errorf("interval 0: a first start at %v, want 0", d)
	}
}
