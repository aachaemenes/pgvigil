// Package sched runs every applicable collection of every instance's engine at its
// interval. One goroutine per (instance, collection); each tick runs
// engines.RunOnce with its own connection, so a slow instance never delays
// another. Intervals come from the collector default, the global override and
// the instance override (config.Interval); zero means off.
package sched

import (
	"context"
	"log/slog"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// Run blocks until ctx is cancelled.
func Run(ctx context.Context, log *slog.Logger, r *repo.Repo, cfg *config.Config) error {
	var wg sync.WaitGroup
	started := 0
	for _, in := range cfg.Instances {
		// only the collections of the instance's own engine
		for _, c := range engines.Specs(in.Engine) {
			iv := cfg.Interval(in, c.Name, c.Default)
			if iv <= 0 {
				continue
			}
			if skip, why := engines.Gated(in, c.Name); skip {
				log.Debug("collection off by config", "instance", in.Name, "collection", c.Name, "why", why)
				continue
			}
			started++
			wg.Add(1)
			go func(in config.Instance, name string, iv time.Duration) {
				defer wg.Done()
				loop(ctx, log, r, in, name, iv)
			}(in, c.Name, iv)
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
		res := engines.RunOnce(ctx, log, r, in, name)
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
