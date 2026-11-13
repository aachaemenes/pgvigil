// Package sched runs every applicable collection of every instance's engine at its
// interval. One goroutine per (instance, collection); each tick runs
// engines.RunOnce with its own connection, so a slow instance never delays
// another. Intervals come from the collector default, the global override and
// the instance override (config.Interval); zero means off.
package sched

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log/slog"
	mrand "math/rand/v2"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

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
// instance's loops run under its own context. The page's instances belong to one collector of a repository: the
// holder of the page lease (pageLease); another collects its file's instances only.
func Run(ctx context.Context, log *slog.Logger, r *repo.Repo, cfg *config.Config) error {
	lock := newPageLease(cfg.Repository.DSN(), log)
	defer lock.release()
	go lock.keep(ctx)
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
	stopping  map[string]chan struct{} // a stopped instance's "loops ended", kept across applies until they end
	cur       []config.Instance
	all       sync.WaitGroup // every instance's loops, for the end of Run
	unmatched string         // the custom checks last warned as matching no instance
}

type instLoops struct {
	cancel context.CancelFunc
	ended  chan struct{} // closed when every loop of the instance returned
}

func newScheduler(log *slog.Logger, oldWait time.Duration, start func(context.Context, config.Instance, *sync.WaitGroup) int) *scheduler {
	return &scheduler{log: log, start: start, oldWait: oldWait, running: map[string]instLoops{}, stopping: map[string]chan struct{}{}}
}

// apply stops the loops of every instance gone or changed, then starts the new and changed ones; an instance's new
// loops start only once its old ones ended (oldWait at most) - in this apply (a change) or an earlier one (a disable
// then an enable, the page lost then held again) - so a cancelled run still writing never overlaps the new loop's
// first read of the same cursor.
func (s *scheduler) apply(ctx context.Context, all []config.Instance) {
	for n, ended := range s.stopping {
		select {
		case <-ended:
			delete(s.stopping, n)
		default:
		}
	}
	stop, start := config.Diff(s.cur, all)
	for _, n := range stop {
		if l, ok := s.running[n]; ok {
			l.cancel()
			s.stopping[n] = l.ended
			delete(s.running, n)
		}
	}
	by := map[string]config.Instance{}
	for _, in := range all {
		by[in.Name] = in
	}
	schedules := 0
	for _, n := range start {
		if ended, ok := s.stopping[n]; ok {
			select {
			case <-ended:
			case <-time.After(s.oldWait):
				s.log.Warn("scheduler: an instance's old loops did not end in time; its new ones start anyway", "instance", n, "waited", s.oldWait)
			}
			delete(s.stopping, n)
		}
		ictx, cancel := context.WithCancel(ctx)
		wg := &sync.WaitGroup{}
		ended := make(chan struct{})
		s.running[n] = instLoops{cancel: cancel, ended: ended}
		schedules += s.start(ictx, by[n], wg)
		s.all.Add(1)
		go func() { wg.Wait(); close(ended); s.all.Done() }()
	}
	s.cur = all
	s.warnUnmatched(all)
	s.log.Info("scheduler: instances applied", "instances", len(all), "stopped", len(stop), "started", len(start), "schedules", schedules)
}

// wait blocks until every instance's loops ended (ctx is done).
func (s *scheduler) wait() { s.all.Wait() }

// warnUnmatched logs each custom check that matches none of this collector's instances (the file's, and the page's
// when it holds them), once per change of that set: a typo like env:prd still shows now that the file alone no
// longer decides.
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
			s.log.Warn("custom: a check matches none of this collector's instances (the file's, and the page's when it holds them)", "check", n)
		}
		s.unmatched = key
	}
}

// The page lease: renewed every pageLeaseEvery on a goroutine of its own (never behind apply's wait for old loops),
// taken by another collector once pageLeaseTTL passed without a renewal (three missed) - on the repository's clock.
const (
	pageLeaseEvery = 15 * time.Second
	pageLeaseTTL   = 45
)

// pageLease: the page's instances belong to one collector of a repository, the holder of the page lease (0122's
// admin_page_holder row, taken and renewed through import_admin_page_lease on a connection of its own). A second
// collector (another host with its own file's instances) collects its file's only: nothing is collected twice and
// no host tries another's credential files. A row, not a session lock, so it holds through a transaction-mode pooler
// and frees itself pageLeaseTTL after the holder's host is lost; a clean stop frees it at once. Fenced: a take-over
// bumps the generation and writes its own holder name, so a holder superseded while away is refused at its next
// renewal; and a holder that cannot renew lets go itself after two failures (30 s, inside the 45 s a taker waits),
// so it never collects beside the next holder while the repository does not answer it.
type pageLease struct {
	dsn    string
	holder string
	log    *slog.Logger
	// call takes or renews the lease once: the generation held, 0 = none (tests stand one in)
	call   func(ctx context.Context, holder string) (int64, error)
	mu     sync.Mutex
	conn   *pgx.Conn
	gen    int64 // the generation held, 0 = none
	err    error // the last renewal's error
	fails  int   // renewals failed in a row
	asked  bool  // a renewal has run
	closed bool  // released: no renewal after it
}

// pageLeaseLetGo: renewals failed in a row after which the holder lets go of the page's instances itself.
const pageLeaseLetGo = 2

func newPageLease(dsn string, log *slog.Logger) *pageLease {
	host, _ := os.Hostname()
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	l := &pageLease{dsn: dsn, log: log, holder: fmt.Sprintf("%s:%d:%s", host, os.Getpid(), hex.EncodeToString(b))}
	l.call = l.callRepo
	return l
}

// callRepo is call on the repository: a connection of its own, parsed as the repository's pool parses its DSN (a
// DSN's pool_* keys never reach the server as startup parameters). Called with mu held.
func (l *pageLease) callRepo(ctx context.Context, holder string) (int64, error) {
	if l.conn == nil {
		pc, err := pgxpool.ParseConfig(l.dsn)
		if err != nil {
			return 0, err
		}
		cc := pc.ConnConfig
		cc.RuntimeParams["application_name"] = "pgvigil-page-lease"
		c, err := pgx.ConnectConfig(ctx, cc)
		if err != nil {
			return 0, err
		}
		l.conn = c
	}
	var g int64
	if err := l.conn.QueryRow(ctx, `SELECT pgvigil.import_admin_page_lease($1, $2)`, holder, pageLeaseTTL).Scan(&g); err != nil {
		_ = l.conn.Close(context.Background())
		l.conn = nil
		return 0, err
	}
	return g, nil
}

// renew takes or renews the lease once: the lease goroutine every pageLeaseEvery, and hold's first call.
func (l *pageLease) renew(ctx context.Context) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return
	}
	l.asked = true
	// not cut by Run's end: a renewal in flight finishes, so release still holds the connection and frees the lease
	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	g, err := l.call(cctx, l.holder)
	if err != nil {
		l.err = err
		l.fails++
		if l.fails == pageLeaseLetGo && l.gen > 0 {
			l.log.Warn("instances: the page lease could not be renewed twice; this collector lets go of the page's instances until it is", "err", err)
		}
		return
	}
	l.gen, l.err, l.fails = g, nil, 0
}

// keep renews the lease until ctx ends.
func (l *pageLease) keep(ctx context.Context) {
	t := time.NewTicker(pageLeaseEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if ctx.Err() != nil {
				return
			}
			l.renew(ctx)
		}
	}
}

// hold is WatchInventory's question: whether this collector holds the page's instances now. One failed renewal is
// an error (the watcher keeps its last list); from the second in a row the holder has let go (false, no error).
func (l *pageLease) hold(ctx context.Context) (bool, error) {
	l.mu.Lock()
	asked := l.asked
	l.mu.Unlock()
	if !asked {
		l.renew(ctx)
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.fails >= pageLeaseLetGo {
		return false, nil
	}
	return l.gen > 0, l.err
}

func (l *pageLease) release() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closed = true
	if l.conn != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if l.gen > 0 {
			_, _ = l.conn.Exec(ctx, `SELECT pgvigil.import_admin_page_release($1, $2)`, l.holder, l.gen)
		}
		_ = l.conn.Close(ctx)
		l.conn = nil
	}
	l.gen = 0
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
	jitter := time.Duration(mrand.Int64N(int64(min(iv, 10*time.Second))))
	select {
	case <-ctx.Done():
		return
	case <-time.After(jitter):
	}
	run := func() {
		res := engines.RunOnce(ctx, log, r, in, name)
		if res.Err == nil || ctx.Err() == nil { // task 201: the heartbeat counts the run, never one the stop cut short
			collect.RecordRun(in.Name, in.Engine, name, res)
		}
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
