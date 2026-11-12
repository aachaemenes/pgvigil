package collect

// The collector's heartbeat (task 201, migration 0121): once a minute `pgvigil run` writes who it is and what the minute's
// runs did - per collection (runs, failures, rows written, durations as a histogram) and per instance (pgvigil's own
// load: connection attempts, connections opened and logins refused, counted at every connect of a collection through
// connectCounted / CountConnect, and the runs and failures) - and each instance's failed runs in a row. Many collectors
// may write to one repository (one per host). Watchdog is serve's: while a collector has not beaten for 5 minutes the
// alert pass that lives in it cannot run, so serve runs it; WatchdogStatus says on or off (the Collector page).

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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// RunsAs says how the process runs when set before StartHeartbeat (the Windows service handler sets "windows
// service"); empty = found here: a systemd unit, a container (Kubernetes), else a console.
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
	attempts, opened, runs, failures, auth int
}

type streak struct {
	fails   int
	lastErr string
	at      time.Time
	dirty   bool
	fresh   bool // loaded from the repository at the start: the first result after it is sent, whatever it is
}

// Heartbeat is one running collector's record keeper.
type Heartbeat struct {
	id, host string
	info     HeartbeatInfo
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

// CountConnect counts one connection attempt to an instance: opened when err is nil, a login refused when the server
// said so (AuthFailure). Every collection's connect calls it (connectCounted; the SQL Server connector directly).
func CountConnect(instance string, err error) {
	if h := current.Load(); h != nil {
		h.mu.Lock()
		defer h.mu.Unlock()
		l := h.loadOf(instance)
		l.attempts++
		if err == nil {
			l.opened++
		} else if AuthFailure(err) {
			l.auth++
		}
	}
}

// connectCounted is pgx.ConnectConfig counted for the instance's load.
func connectCounted(ctx context.Context, instance string, cfg *pgx.ConnConfig) (*pgx.Conn, error) {
	conn, err := pgx.ConnectConfig(ctx, cfg)
	CountConnect(instance, err)
	return conn, err
}

func (h *Heartbeat) loadOf(instance string) *loadAgg {
	l := h.load[instance]
	if l == nil {
		l = &loadAgg{}
		h.load[instance] = l
	}
	return l
}

// AuthFailure says whether the server refused the login - PostgreSQL 28P01 (bad password) or 28000 (no such role / not allowed),
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
	if skipped(res) {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	l := h.loadOf(instance)
	failed := res.Err != nil
	l.runs++
	if failed {
		l.failures++
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
		s = &streak{fresh: true} // never seen since the start: its first result is sent (a stored streak is replaced)
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
	// a streak row is written when it changes (a failure, the first success after failures) and for the first result
	// after a start (the repository's count, from before the restart, is carried on or reset)
	s.dirty = s.dirty || failed || was > 0 || s.fresh
	s.fresh = false
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
	Instance string `json:"instance"`
	Attempts int    `json:"attempts"`
	Opened   int    `json:"opened"`
	Runs     int    `json:"runs"`
	Failures int    `json:"failures"`
	Auth     int    `json:"auth"`
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
		b.Load = append(b.Load, beatLoad{Instance: name, Attempts: l.attempts, Opened: l.opened, Runs: l.runs, Failures: l.failures, Auth: l.auth})
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
	// systemd sets INVOCATION_ID for every unit it starts; a system service's parent is PID 1 (a shell in a terminal
	// of a user session inherits the variable, not the parent)
	if os.Getenv("INVOCATION_ID") != "" && os.Getppid() == 1 {
		return "systemd unit"
	}
	if os.Getenv("KUBERNETES_SERVICE_HOST") != "" {
		return "container (Kubernetes)"
	}
	for _, f := range []string{"/.dockerenv", "/run/.containerenv"} {
		if _, err := os.Stat(f); err == nil {
			return "container"
		}
	}
	return "console"
}

// StartHeartbeat writes this collector's row (its start in the repository's clock) and beats every minute until ctx ends,
// then marks a clean stop. dsn is the collector's repository DSN (the import_ door).
func StartHeartbeat(ctx context.Context, log *slog.Logger, dsn string, info HeartbeatInfo) error {
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
	h := &Heartbeat{id: fmt.Sprintf("%s/%d/%d", host, os.Getpid(), time.Now().UnixNano()), host: host, pool: pool, log: log,
		info: info, runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	if err := h.claim(ctx); err != nil {
		pool.Close()
		return err
	}
	h.loadStreaks(ctx)
	current.Store(h)
	log.Info("heartbeat started", "collector", h.id, "runs_as", runsAs())
	go h.loop(ctx)
	return nil
}

func (h *Heartbeat) claim(ctx context.Context) error {
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if _, err := h.pool.Exec(cctx, `SELECT pgvigil.import_collector_claim($1, $2, $3, $4, $5, $6)`,
		h.id, h.host, runtime.GOOS+"/"+runtime.GOARCH, runsAs(), h.info.Version, os.Getpid()); err != nil {
		return fmt.Errorf("heartbeat: the collector's row: %w", err)
	}
	return nil
}

// loadStreaks takes the failed runs in a row the repository holds (a restart keeps counting from them; the first result
// of each is sent).
func (h *Heartbeat) loadStreaks(ctx context.Context) {
	lctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	rows, err := h.pool.Query(lctx, `SELECT instance, collection, fail_streak, coalesce(last_error, '') FROM pgvigil.import_collector_streaks()`)
	if err != nil {
		h.log.Warn("heartbeat: the stored streaks were not read (counted from 0)", "err", err)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var inst, coll, lastErr string
		var n int
		if err := rows.Scan(&inst, &coll, &n, &lastErr); err != nil {
			h.log.Warn("heartbeat: a stored streak", "err", err)
			return
		}
		h.streaks[[2]string{inst, coll}] = &streak{fails: n, lastErr: lastErr, fresh: true}
	}
}

func (h *Heartbeat) loop(ctx context.Context) {
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
		h.beat(ctx, next.Truncate(time.Minute).Add(-time.Minute))
	}
}

// beat writes the minute.
func (h *Heartbeat) beat(ctx context.Context, minute time.Time) {
	b := h.take()
	body, err := json.Marshal(b)
	if err != nil {
		h.log.Warn("heartbeat: the beat was not encoded", "err", err)
		return
	}
	bctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var known bool
	if err := h.pool.QueryRow(bctx, `SELECT pgvigil.import_collector_beat($1, $2, $3::jsonb)`, h.id, minute, string(body)).Scan(&known); err != nil {
		// the minute's counts are lost with the beat (the page shows the gap); the streaks are sent again next minute
		h.log.Warn("heartbeat: the beat was not written", "err", err)
		h.mu.Lock()
		for _, s := range b.Streaks {
			if st := h.streaks[[2]string{s.Instance, s.Collection}]; st != nil {
				st.dirty = true
			}
		}
		h.mu.Unlock()
		return
	}
	if !known { // the row is gone (trimmed after 8 days without a beat, or deleted): claimed again
		if err := h.claim(ctx); err != nil {
			h.log.Warn("heartbeat: the collector's row was not written again", "err", err)
		}
	}
}

var watchdog atomic.Value // string: "on", or "off: <why>"; empty when no watchdog was asked (not serve)

// SetWatchdogOff records why serve runs no watchdog (logged by the caller; the Collector page shows it).
func SetWatchdogOff(why string) { watchdog.Store("off: " + why) }

// WatchdogStatus: "on", "off: <why>", or "" outside serve.
func WatchdogStatus() string {
	if v, ok := watchdog.Load().(string); ok {
		return v
	}
	return ""
}

// Watchdog runs in `pgvigil serve`: each minute it asks the repository whether a collector is not seen for 5 minutes
// (pgvigil.collector_down()); while one is, the alert pass that lives in it cannot run, so pass is called
// (the alert pass's advisory lock keeps one sender, alert_state keeps one alert). dsn: any repository login that may
// read (the reader's).
func Watchdog(ctx context.Context, log *slog.Logger, dsn string, pass func(context.Context) error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		SetWatchdogOff("the repository DSN: " + err.Error())
		log.Warn("collector watchdog off", "err", err)
		return
	}
	cfg.MaxConns = 1
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-watchdog"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		SetWatchdogOff("the repository: " + err.Error())
		log.Warn("collector watchdog off", "err", err)
		return
	}
	defer pool.Close()
	watchdog.Store("on")
	log.Info("collector watchdog on: serve runs the alert pass while a collector is not seen for 5 minutes")
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
