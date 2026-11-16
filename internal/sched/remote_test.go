package sched

import (
	"context"
	"sync"
	"testing"
	"time"
)

// fakeTime is a clock the interval clock reads and waits on: each wait moves the clock to its end at once.
type fakeTime struct {
	mu  sync.Mutex
	now time.Time
}

func (f *fakeTime) Now() time.Time { f.mu.Lock(); defer f.mu.Unlock(); return f.now }

func (f *fakeTime) After(d time.Duration) <-chan time.Time {
	f.mu.Lock()
	f.now = f.now.Add(d)
	t := f.now
	f.mu.Unlock()
	c := make(chan time.Time, 1)
	c <- t
	return c
}

// A remote collector's interval ends on the interval's boundaries (12:05, 12:10 for 5 minutes from 12:03:20), one close
// per end (every instance: the empty interval is a bundle too); a clean stop closes once more at the stop's time, marked
// final (R2: the open bundles are closed before the collector ends; only an open one, never an empty second bundle).
func TestIntervalClock(t *testing.T) {
	start := time.Date(2026, 11, 16, 12, 3, 20, 0, time.UTC)
	ft := &fakeTime{now: start}
	ctx, cancel := context.WithCancel(context.Background())
	var ends []time.Time
	var finals []bool
	done := make(chan struct{})
	go func() {
		intervalClock(ctx, 5*time.Minute, ft.Now, ft.After, func(end time.Time, final bool) {
			ends = append(ends, end)
			finals = append(finals, final)
			if len(ends) == 3 {
				cancel()
			}
		})
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the clock did not stop")
	}
	want := []time.Time{start.Truncate(5 * time.Minute).Add(5 * time.Minute), start.Truncate(5 * time.Minute).Add(10 * time.Minute),
		start.Truncate(5 * time.Minute).Add(15 * time.Minute)}
	if len(ends) != 4 {
		t.Fatalf("ends: %v (three boundaries and the stop)", ends)
	}
	for i, w := range want {
		if !ends[i].Equal(w) {
			t.Errorf("end %d: %v, want %v", i, ends[i], w)
		}
	}
	if !ends[3].Equal(ft.Now()) || !finals[3] || finals[0] || finals[1] || finals[2] {
		t.Errorf("the stop's close at %v (final %v), want %v (final): %v", ends[3], finals[3], ft.Now(), finals)
	}
}
