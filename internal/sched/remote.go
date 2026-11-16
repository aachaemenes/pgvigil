package sched

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
	"github.com/aachaemenes/pgvigil/internal/store"
)

// RunRemote is a remote collector's scheduler (R1): the same per-instance loops as Run over a remote store, the
// instances of its yaml only - no repository, so no inventory watch, no page lease, no partitions, no blocking rollup -
// and an interval clock that calls closeAt at each end of the interval (final at a clean stop). It returns when ctx ends
// and every loop has stopped.
func RunRemote(ctx context.Context, log *slog.Logger, st store.Store, cfg *config.Config, every time.Duration, closeAt func(end time.Time, final bool)) error {
	s := newScheduler(log, oldLoopsWait, func(ictx context.Context, in config.Instance, wg *sync.WaitGroup) int {
		return startInstance(ictx, log, st, cfg, in, wg)
	})
	s.apply(ctx, cfg.Instances)
	clockDone := make(chan struct{})
	go func() {
		intervalClock(ctx, every, time.Now, time.After, closeAt)
		close(clockDone)
	}()
	s.wait()
	<-clockDone
	log.Info("remote collector stopped")
	return nil
}

// intervalClock calls closeAt at each boundary of the interval (the boundaries of the clock, so every collector of a
// site ends its bundles together), and once more, final, when ctx ends.
func intervalClock(ctx context.Context, every time.Duration, now func() time.Time, after func(time.Duration) <-chan time.Time, closeAt func(end time.Time, final bool)) {
	for {
		if ctx.Err() != nil {
			closeAt(now(), true)
			return
		}
		next := now().Truncate(every).Add(every)
		select {
		case <-ctx.Done():
			closeAt(now(), true)
			return
		case <-after(next.Sub(now())):
			closeAt(next, false)
		}
	}
}

// RemoteSchedule is an instance's schedule as a manifest's reads name it: every collection of its engine with its
// interval on this collector, a collection switched off (no interval, or gated by the config) skipped 'off'.
func RemoteSchedule(cfg *config.Config, in config.Instance) []format.Read {
	var out []format.Read
	for _, c := range engines.Specs(in.Engine) {
		iv := cfg.Interval(in, c.Name, c.Default)
		if skip, _ := engines.Gated(in, c.Name); iv <= 0 || skip {
			out = append(out, format.Read{Collection: c.Name, Reason: "off"})
			continue
		}
		out = append(out, format.Read{Collection: c.Name, IntervalSecs: int(iv / time.Second)})
	}
	return out
}
