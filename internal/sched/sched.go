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
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// oldLoopsWait bounds the wait for a changed instance's old loops before its new ones start: a cancelled run's last
// repository write runs under context.WithoutCancel with a 30 s timeout (mssql's repoTimeout), and 5 s more.
const oldLoopsWait = 35 * time.Second

// Run blocks until ctx is cancelled. The instance list is the file's and the page's (task 204): config.WatchInventory
// reads the page's list at start and whenever its generation moves (every 15 s) and hands the merged list to apply,
// which stops the loops of a removed, disabled or changed instance and starts those of a new or changed one; each
// instance's loops run under its own context. The page's instances belong to one collector of a repository: the one
// holding the page_inventory lock (pageLock); another collects its file's instances only.
func Run(ctx context.Context, log *slog.Logger, r *repo.Repo, cfg *config.Config) error {
	lock := &pageLock{dsn: cfg.Repository.DSN()}
	defer lock.release()
	s := newScheduler(log, oldLoopsWait, func(ictx context.Context, in config.Instance, wg *sync.WaitGroup) int {
		return startInstance(ictx, log, r, cfg, in, wg)
	})
	config.WatchInventory(ctx, log, r, lock.hold, cfg.Instances, cfg.QueryText, 15*time.Second, func(all []config.Instance) { s.apply(ctx, all) })
	s.wait()
	log.Info("scheduler stopped")
	return nil
}

// scheduler is Run's state: each running instance's stop and the WaitGroup of its loops.
type scheduler struct {
	log       *slog.Logger
	start     func(context.Context, config.Instance, *sync.WaitGroup) int
	oldWait   time.Duration
	running   map[string]instLoops
	cur       []config.Instance
	all       sync.WaitGroup // every instance's loops, for the end of Run
	unmatched string         // the custom checks last warned as matching no instance
}

type instLoops struct {
	cancel context.CancelFunc
	wg     *sync.WaitGroup
}

func newScheduler(log *slog.Logger, oldWait time.Duration, start func(context.Context, config.Instance, *sync.WaitGroup) int) *scheduler {
	return &scheduler{log: log, start: start, oldWait: oldWait, running: map[string]instLoops{}}
}

// apply stops the loops of every instance gone or changed, then starts the new and changed ones; a changed
// instance's new loops start only once its old ones ended (oldWait at most), so a cancelled run still writing never
// overlaps the new loop's first read of the same cursor.
func (s *scheduler) apply(ctx context.Context, all []config.Instance) {
	stop, start := config.Diff(s.cur, all)
	stopped := map[string]*sync.WaitGroup{}
	for _, n := range stop {
		if l, ok := s.running[n]; ok {
			l.cancel()
			stopped[n] = l.wg
			delete(s.running, n)
		}
	}
	by := map[string]config.Instance{}
	for _, in := range all {
		by[in.Name] = in
	}
	schedules := 0
	for _, n := range start {
		if wg, ok := stopped[n]; ok && !waitFor(wg, s.oldWait) {
			s.log.Warn("scheduler: a changed instance's old loops did not end in time; its new ones start anyway", "instance", n, "waited", s.oldWait)
		}
		ictx, cancel := context.WithCancel(ctx)
		wg := &sync.WaitGroup{}
		s.running[n] = instLoops{cancel: cancel, wg: wg}
		schedules += s.start(ictx, by[n], wg)
		s.all.Add(1)
		go func() { wg.Wait(); s.all.Done() }()
	}
	s.cur = all
	s.warnUnmatched(all)
	s.log.Info("scheduler: instances applied", "instances", len(all), "stopped", len(stop), "started", len(start), "schedules", schedules)
}

// wait blocks until every instance's loops ended (ctx is done).
func (s *scheduler) wait() { s.all.Wait() }

// warnUnmatched logs each custom check that matches no instance of the merged list (the file's and the page's), once
// per change of that set: a typo like env:prd still shows now that the file alone no longer decides.
func (s *scheduler) warnUnmatched(all []config.Instance) {
	checks, _ := collect.CustomChecks()
	var none []string
	for _, c := range checks {
		matched := false
		for _, in := range all {
			if c.AppliesTo(in) {
				matched = true
				break
			}
		}
		if !matched {
			none = append(none, c.Name)
		}
	}
	if key := strings.Join(none, "\x1f"); key != s.unmatched {
		for _, n := range none {
			s.log.Warn("custom: a check matches no instance of the file or the page", "check", n)
		}
		s.unmatched = key
	}
}

// waitFor waits for wg up to d; false = it did not end in time.
func waitFor(wg *sync.WaitGroup, d time.Duration) bool {
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
		return true
	case <-time.After(d):
		return false
	}
}

// pageLock: the page's instances belong to one collector of a repository, the one holding the session advisory lock
// hashtext('pgvigil.page_inventory') on a connection of its own. A second collector (another host with its own
// file's instances) then collects its file's only: nothing is collected twice and no host tries another's credential
// files. Each tick pings the held connection (a repository restart drops the lock) and tries again when it is gone,
// so another collector takes over within a tick of the holder's end.
type pageLock struct {
	dsn  string
	conn *pgx.Conn
}

func (l *pageLock) hold(ctx context.Context) (bool, error) {
	if l.conn != nil {
		pctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		err := l.conn.Ping(pctx)
		cancel()
		if err == nil {
			return true, nil
		}
		_ = l.conn.Close(context.Background())
		l.conn = nil
	}
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	c, err := pgx.Connect(cctx, l.dsn)
	if err != nil {
		return false, err
	}
	var ok bool
	if err := c.QueryRow(cctx, `SELECT pg_try_advisory_lock(hashtext('pgvigil.page_inventory'))`).Scan(&ok); err != nil || !ok {
		_ = c.Close(context.Background())
		return false, err
	}
	l.conn = c
	return true, nil
}

func (l *pageLock) release() {
	if l.conn != nil {
		_ = l.conn.Close(context.Background())
		l.conn = nil
	}
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
