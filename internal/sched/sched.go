// Package sched runs every applicable collection of every instance at its
// interval. One goroutine per (instance, collection); each tick runs
// collect.RunOnce with its own connection, so a slow instance never delays
// another. Intervals come from the collector default, the global override and
// the instance override (config.Interval); zero means off.
package sched

import (
	"context"
	"log/slog"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// Run blocks until ctx is cancelled.
func Run(ctx context.Context, log *slog.Logger, r *repo.Repo, cfg *config.Config) error {
	var wg sync.WaitGroup
	started := 0
	for _, in := range cfg.Instances {
		for _, c := range collect.All() {
			iv := cfg.Interval(in, c.Name(), c.DefaultInterval())
			if iv <= 0 {
				continue
			}
			started++
			wg.Add(1)
			go func(in config.Instance, name string, iv time.Duration) {
				defer wg.Done()
				loop(ctx, log, r, in, name, iv)
			}(in, c.Name(), iv)
		}
	}
	log.Info("scheduler started", "instances", len(cfg.Instances), "schedules", started)
	<-ctx.Done()
	wg.Wait()
	log.Info("scheduler stopped")
	return nil
}

func loop(ctx context.Context, log *slog.Logger, r *repo.Repo, in config.Instance, name string, iv time.Duration) {
	// a small random offset so every instance's minute collections do not fire together
	jitter := time.Duration(rand.Int64N(int64(min(iv, 10*time.Second))))
	select {
	case <-ctx.Done():
		return
	case <-time.After(jitter):
	}
	run := func() {
		res := collect.RunOnce(ctx, log, r, in, name)
		if res.Err != nil && ctx.Err() == nil {
			log.Warn("collection failed", "instance", in.Name, "collection", name, "err", res.Err)
		}
	}
	run()
	t := time.NewTicker(iv)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			run()
		}
	}
}
