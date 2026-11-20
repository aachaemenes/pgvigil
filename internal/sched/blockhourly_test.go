package sched

import (
	"testing"
	"time"
)

func TestNextBlockHourly(t *testing.T) {
	at := func(h, m, s int) time.Time { return time.Date(2026, 11, 15, h, m, s, 0, time.UTC) }
	for _, c := range []struct{ now, want time.Time }{
		{at(10, 0, 0), at(10, 16, 0)},
		{at(10, 15, 59), at(10, 16, 0)},
		{at(10, 16, 0), at(11, 16, 0)},
		{at(10, 59, 59), at(11, 16, 0)},
		{at(23, 30, 0), time.Date(2026, 11, 16, 0, 16, 0, 0, time.UTC)},
		// the fallback keeps UTC hours whatever the caller's zone: 10:05 UTC given in +5:45 is still 10:16 UTC
		{at(10, 5, 0).In(time.FixedZone("+0545", 5*3600+45*60)), at(10, 16, 0)},
	} {
		if got := nextBlockHourly(c.now); !got.Equal(c.want) {
			t.Errorf("nextBlockHourly(%s) = %s, want %s", c.now, got, c.want)
		}
	}
}
