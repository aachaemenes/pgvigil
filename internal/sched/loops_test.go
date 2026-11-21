package sched

import (
	"context"
	"sync"
)

// testLoops runs a test's loop goroutines under a WaitGroup (rn-l214 S-6): stop cancels them and returns only when
// each has returned, so no run reads a deadline or connect-timeout variable while the test's defers restore it, and
// no run writes the log buffer the test then reads.
type testLoops struct {
	wg     sync.WaitGroup
	cancel context.CancelFunc
}

// startTestLoops: the loops' context under ctx, and their keeper.
func startTestLoops(ctx context.Context) (context.Context, *testLoops) {
	lctx, cancel := context.WithCancel(ctx)
	return lctx, &testLoops{cancel: cancel}
}

// run starts one loop goroutine.
func (l *testLoops) run(f func()) {
	l.wg.Add(1)
	go func() {
		defer l.wg.Done()
		f()
	}()
}

// stop cancels every loop and waits for each to return; safe to call twice (a deferred stop after an explicit one).
func (l *testLoops) stop() {
	l.cancel()
	l.wg.Wait()
}
