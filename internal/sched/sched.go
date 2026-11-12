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

// Run blocks until ctx is cancelled. The instance list is the file's and the page's (task 204): config.WatchInventory
// reads the page's list at start and whenever its generation moves (every 15 s) and hands the merged list to apply,
// which stops the loops of a removed, disabled or changed instance and starts those of a new or changed one; each
// instance's loops run under its own context.
func Run(ctx context.Context, log *slog.Logger, r *repo.Repo, cfg *config.Config) error {
	var wg sync.WaitGroup
	running := map[string]context.CancelFunc{}
	var cur []config.Instance
	apply := func(all []config.Instance) {
		stop, start := config.Diff(cur, all)
		for _, n := range stop {
			if c, ok := running[n]; ok {
				c()
				delete(running, n)
			}
		}
		by := map[string]config.Instance{}
		for _, in := range all {
			by[in.Name] = in
		}
		schedules := 0
		for _, n := range start {
			ictx, cancel := context.WithCancel(ctx)
			running[n] = cancel
			schedules += startInstance(ictx, log, r, cfg, by[n], &wg)
		}
		cur = all
		log.Info("scheduler: instances applied", "instances", len(all), "stopped", len(stop), "started", len(start), "schedules", schedules)
	}
	config.WatchInventory(ctx, log, r, cfg.Instances, cfg.QueryText, 15*time.Second, apply)
	wg.Wait()
	log.Info("scheduler stopped")
	return nil
}

// startInstance starts one goroutine per applicable collection of the instance's engine; it answers how many.
func startInstance(ctx context.Context, log *slog.Logger, r *repo.Repo, cfg *config.Config, in config.Instance, wg *sync.WaitGroup) int {
	started := 0
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
	return started
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
