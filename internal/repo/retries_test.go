package repo

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

// TestRetryCounter: a context without a counter counts nothing; one with a counter counts every retry, through a
// context made from it (a run's timeout) too, and two runs' counters stay apart.
func TestRetryCounter(t *testing.T) {
	countRetry(context.Background()) // no counter: no panic, nothing counted
	var a, b atomic.Int64
	ca := WithRetryCounter(context.Background(), &a)
	cb := WithRetryCounter(context.Background(), &b)
	tctx, cancel := context.WithTimeout(ca, time.Minute)
	defer cancel()
	countRetry(ca)
	countRetry(tctx)
	countRetry(cb)
	if a.Load() != 2 || b.Load() != 1 {
		t.Errorf("counted %d and %d, want 2 (one through the run's timeout) and 1", a.Load(), b.Load())
	}
	var nilCounter *atomic.Int64
	countRetry(WithRetryCounter(context.Background(), nilCounter)) // a nil counter: nothing counted, no panic
}
