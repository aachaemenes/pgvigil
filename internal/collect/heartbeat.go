package collect

// The collector's heartbeat (task 201, migration 0121): once a minute `pgvigil run` writes who it is and what the minute's
// runs did - per collection (runs, failures, rows written, durations as a histogram) and per instance (the connections
// pgvigil opened - one per run on both engines - its failures and authentication failures) - and each instance's
// failed runs in a row. One collector per repository: StartHeartbeat refuses to start beside another host's live
// collector, and a running collector is told at its beat when an older one of another host is live; either way the
// reason is logged and the run's context is cancelled. Watchdog is serve's: while no collector has beaten for 5
// minutes the alert pass that lives in the collector cannot run, so serve runs it.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/bits"
	"os"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// RunsAs, when set before StartHeartbeat, says how the process runs (the Windows service handler sets "windows service");
// empty = found here: a systemd unit (INVOCATION_ID), a container, else a console.
var RunsAs string

// HeartbeatInfo is what the caller knows about this collector.
type HeartbeatInfo struct {
	Version string
}

const histBuckets = 19 // b 0 = under 1 ms, b n = 2^(n-1) to 2^n ms, b 18 = 131 s and over

type runAgg struct {
	runs, failures int
	rows           int64
	durSum         int64
	durMax         int
	hist           [histBuckets]int
}

type loadAgg struct {
	connections, runs, failures, auth int
}

type streak struct {
	fails   int
	lastErr string
	at      time.Time
	dirty   bool
}

// Heartbeat is one running collector's record keeper.
type Heartbeat struct {
	id, host string
	pool     *pgxpool.Pool
	log      *slog.Logger
	mu       sync.Mutex
	runs     map[[2]string]*runAgg // engine, collection
	load     map[string]*loadAgg   // instance name
	streaks  map[[2]string]*streak // instance name, collection
}

var current atomic.Pointer[Heartbeat]

// RecordRun counts one run of a collection on an instance (sched's loop calls it after each run); nothing when no
// heartbeat runs (`pgvigil collect`, a test).
func RecordRun(instance, engine, collection string, res Result) {
	if h := current.Load(); h != nil {
		h.record(instance, engine, collection, res, time.Now())
	}
}

func skipped(res Result) bool { return res.Err == nil && strings.Contains(res.Note, "skipped") }

// AuthFailure: the server refused the login - PostgreSQL 28P01 (bad password) or 28000 (no such role / not allowed),
// SQL Server 18456 (login failed).
func AuthFailure(err error) bool {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return pe.Code == "28P01" || pe.Code == "28000"
	}
	var ms interface{ SQLErrorNumber() int32 }
	if errors.As(err, &ms) {
		return ms.SQLErrorNumber() == 18456
	}
	return false
}

func bucket(d time.Duration) int {
	ms := d.Milliseconds()
	if ms < 1 {
		return 0
	}
	return min(bits.Len64(uint64(ms)), histBuckets-1)
}

func (h *Heartbeat) record(instance, engine, collection string, res Result, now time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	l := h.load[instance]
	if l == nil {
		l = &loadAgg{}
		h.load[instance] = l
	}
	l.connections++ // every run opens one connection, a skipped one too (it connects to find out)
	if skipped(res) {
		return
	}
	failed := res.Err != nil
	l.runs++
	if failed {
		l.failures++
		if AuthFailure(res.Err) {
			l.auth++
		}
	}
	k := [2]string{engine, collection}
	a := h.runs[k]
	if a == nil {
		a = &runAgg{}
		h.runs[k] = a
	}
	a.runs++
	if failed {
		a.failures++
	} else {
		a.rows += int64(res.Rows)
	}
	ms := int(res.Duration.Milliseconds())
	a.durSum += int64(ms)
	a.durMax = max(a.durMax, ms)
	a.hist[bucket(res.Duration)]++
	sk := [2]string{instance, collection}
	s := h.streaks[sk]
	if s == nil {
		s = &streak{}
		h.streaks[sk] = s
	}
	was := s.fails
	if failed {
		s.fails++
		s.lastErr = res.Err.Error()
	} else {
		s.fails, s.lastErr = 0, ""
	}
	s.at = now
	// a streak row is written when it changes: a failure, or the first success after failures
	s.dirty = s.dirty || failed || was > 0
}

type beatRun struct {
	Engine     string `json:"engine"`
	Collection string `json:"collection"`
	Runs       int    `json:"runs"`
	Failures   int    `json:"failures"`
	Rows       int64  `json:"rows"`
	DurSum     int64  `json:"dur_sum"`
	DurMax     int    `json:"dur_max"`
	Hist       []int  `json:"hist"`
}

type beatLoad struct {
	Instance    string `json:"instance"`
	Connections int    `json:"connections"`
	Runs        int    `json:"runs"`
	Failures    int    `json:"failures"`
	Auth        int    `json:"auth"`
}

type beatStreak struct {
	Instance   string    `json:"instance"`
	Collection string    `json:"collection"`
	Fails      int       `json:"fails"`
	Error      string    `json:"error"`
	At         time.Time `json:"at"`
}

type beat struct {
	MemBytes   uint64       `json:"mem_bytes"`
	Goroutines int          `json:"goroutines"`
	Instances  int          `json:"instances"`
	Runs       []beatRun    `json:"runs"`
	Load       []beatLoad   `json:"load"`
	Streaks    []beatStreak `json:"streaks"`
}

// take empties the minute's counts into a beat (the streaks keep their counts; only the changed ones are sent).
func (h *Heartbeat) take() beat {
	h.mu.Lock()
	defer h.mu.Unlock()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	b := beat{MemBytes: ms.Sys, Goroutines: runtime.NumGoroutine(), Instances: len(h.load)}
	for k, a := range h.runs {
		b.Runs = append(b.Runs, beatRun{Engine: k[0], Collection: k[1], Runs: a.runs, Failures: a.failures, Rows: a.rows,
			DurSum: a.durSum, DurMax: a.durMax, Hist: append([]int(nil), a.hist[:]...)})
	}
	for name, l := range h.load {
		b.Load = append(b.Load, beatLoad{Instance: name, Connections: l.connections, Runs: l.runs, Failures: l.failures, Auth: l.auth})
	}
	for k, s := range h.streaks {
		if s.dirty {
			b.Streaks = append(b.Streaks, beatStreak{Instance: k[0], Collection: k[1], Fails: s.fails, Error: s.lastErr, At: s.at})
			s.dirty = false
		}
	}
	h.runs = map[[2]string]*runAgg{}
	h.load = map[string]*loadAgg{}
	return b
}

func runsAs() string {
	if RunsAs != "" {
		return RunsAs
	}
	if os.Getenv("INVOCATION_ID") != "" { // systemd sets it for every unit it starts
		return "systemd unit"
	}
	for _, f := range []string{"/.dockerenv", "/run/.containerenv"} {
		if _, err := os.Stat(f); err == nil {
			return "container"
		}
	}
	return "console"
}

// StartHeartbeat claims the repository for this collector and beats every minute until ctx ends (then marks a clean
// stop). A refusal - another host's collector is live - is returned as the error before anything runs; a refusal told
// at a later beat is logged and stop() is called. dsn is the collector's repository DSN (the import_ door).
func StartHeartbeat(ctx context.Context, log *slog.Logger, dsn string, info HeartbeatInfo, stop context.CancelFunc) error {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return fmt.Errorf("heartbeat: %w", err)
	}
	cfg.MaxConns = 2
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-heartbeat"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return fmt.Errorf("heartbeat: %w", err)
	}
	host, _ := os.Hostname()
	started := time.Now()
	h := &Heartbeat{id: fmt.Sprintf("%s/%d/%d", host, os.Getpid(), started.Unix()), host: host, pool: pool, log: log,
		runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	var why *string
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	err = pool.QueryRow(cctx, `SELECT pgvigil.import_collector_claim($1, $2, $3, $4, $5, $6, $7)`,
		h.id, host, runtime.GOOS+"/"+runtime.GOARCH, runsAs(), info.Version, os.Getpid(), started).Scan(&why)
	cancel()
	if err != nil {
		pool.Close()
		return fmt.Errorf("heartbeat: the claim on the repository: %w", err)
	}
	if why != nil {
		pool.Close()
		return errors.New(*why)
	}
	current.Store(h)
	log.Info("heartbeat started", "collector", h.id, "runs_as", runsAs())
	go h.loop(ctx, stop)
	return nil
}

func (h *Heartbeat) loop(ctx context.Context, stop context.CancelFunc) {
	defer h.pool.Close()
	defer current.CompareAndSwap(h, nil)
	for {
		// at each minute's turn (2 s in, so the minute's runs are counted in it)
		next := time.Now().Truncate(time.Minute).Add(time.Minute + 2*time.Second)
		select {
		case <-ctx.Done():
			sctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			if _, err := h.pool.Exec(sctx, `SELECT pgvigil.import_collector_stop($1)`, h.id); err != nil {
				h.log.Warn("heartbeat: the stop mark was not written", "err", err)
			}
			cancel()
			return
		case <-time.After(time.Until(next)):
		}
		if why := h.beat(ctx, next.Truncate(time.Minute).Add(-time.Minute)); why != "" {
			h.log.Error("this collector is refused: "+why, "collector", h.id)
			stop()
		}
	}
}

// beat writes the minute; the refusal's reason when there is one.
func (h *Heartbeat) beat(ctx context.Context, minute time.Time) string {
	b := h.take()
	body, err := json.Marshal(b)
	if err != nil {
		h.log.Warn("heartbeat: the beat was not encoded", "err", err)
		return ""
	}
	bctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var why *string
	if err := h.pool.QueryRow(bctx, `SELECT pgvigil.import_collector_beat($1, $2, $3::jsonb)`, h.id, minute, string(body)).Scan(&why); err != nil {
		// the minute's counts are lost with the beat (the page shows the gap); the streaks are re-sent next minute
		h.log.Warn("heartbeat: the beat was not written", "err", err)
		h.mu.Lock()
		for _, s := range b.Streaks {
			if st := h.streaks[[2]string{s.Instance, s.Collection}]; st != nil {
				st.dirty = true
			}
		}
		h.mu.Unlock()
		return ""
	}
	if why != nil {
		return *why
	}
	return ""
}

// Watchdog runs in `pgvigil serve`: each minute it asks the repository whether a collector beat in the last 5 minutes
// (pgvigil.collector_down()); while none did, the alert pass that lives in the collector cannot run, so pass is called
// (the alert pass's advisory lock keeps one sender, alert_state keeps one alert). dsn: any repository login that may
// read (the reader's).
func Watchdog(ctx context.Context, log *slog.Logger, dsn string, pass func(context.Context) error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		log.Warn("collector watchdog off", "err", err)
		return
	}
	cfg.MaxConns = 1
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-watchdog"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		log.Warn("collector watchdog off", "err", err)
		return
	}
	defer pool.Close()
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	took := false
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		var down bool
		qctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		err := pool.QueryRow(qctx, `SELECT pgvigil.collector_down()`).Scan(&down)
		cancel()
		if err != nil {
			log.Warn("collector watchdog: the repository did not answer", "err", err)
			continue
		}
		if down != took {
			took = down
			log.Info("collector watchdog", "collector_down", down, "serve_runs_the_alert_pass", down)
		}
		if down {
			if err := pass(ctx); err != nil {
				log.Warn("collector watchdog: the alert pass failed", "err", err)
			}
		}
	}
}
