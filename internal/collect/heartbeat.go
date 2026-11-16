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
	"io"
	"log/slog"
	"math/bits"
	"net"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/secrets"
)

// RunsAs says how the process runs when set before StartHeartbeat (the Windows service handler sets "windows
// service"); empty = found here: a systemd unit, a container (Kubernetes), else a console.
var RunsAs string

// HeartbeatInfo is what the caller knows about this collector.
type HeartbeatInfo struct {
	Version string
	// SendsAlerts: this run sends alerts (its alerts: list names a channel); each beat says so ('alert sender idle'
	// counts only the live runs that send: B6.2 part c #3)
	SendsAlerts bool
	// the reachability probe (B24h-1b, probe.go): 'tcp', 'icmp' (B24h-2; read as tcp until then), 'off'; "" = icmp;
	// ProbeEveryMinute probes every known address each minute (the opt-in), else only after a failed collection
	Probe            string
	ProbeEveryMinute bool
}

const histBuckets = 19 // b 0 = under 1 ms, b n = 2^(n-1) to 2^n ms, b 18 = 131 s and over

type runAgg struct {
	runs, failures int
	retries        int // the runs' imports taken again after a deadlock (Result.Retries; N4)
	rows           int64
	durSum         int64
	durMax         int
	hist           [histBuckets]int
}

type loadAgg struct {
	attempts, opened, runs, failures, auth int
	noanswer                               int           // failed connects the server never answered (NoAnswer: N8)
	every                                  time.Duration // the fastest configured interval of the runs counted (0: none known)
	// the slow-connect tier: the opened connects that were timed, their time summed and the longest, in milliseconds
	timed     int
	connMsSum int64
	connMsMax int
	// the query round trip (B24h-1a, roundtrip.go): the minute's measures (one an instance), their ms summed and the
	// longest; rtClaimed while a collection measures
	rtCount   int
	rtMsSum   int64
	rtMsMax   int
	rtClaimed bool
}

type streak struct {
	fails   int
	lastErr string
	at      time.Time
	since   time.Time // the first failure of the streak (zero: none, or carried from the repository at the start)
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
	runs     map[[2]string]*runAgg    // engine, collection
	load     map[string]*loadAgg      // instance name
	streaks  map[[2]string]*streak    // instance name, collection
	hourly   map[healthKey]*healthAgg // B6.1: instance, collection, UTC hour (health.go)
	hourNew  time.Time                // the newest hour counted
	seen     map[string]time.Time     // instance name: when this run last named it in the repository (seenDue)
	targets  map[string]string        // instance name: its dial target (InstanceTarget: N8)
	probe    *prober                  // the reachability probe (B24h-1b); nil when 'off'
	// noProbeImport: the repository has no import_collector_probe (0254): not asked again this run
	noProbeImport bool
}

var current atomic.Pointer[Heartbeat]

// RecordRun counts one run of a collection on an instance (sched's loop calls it after each run, never for a run its
// stop cut short); nothing when no heartbeat runs (`pgvigil collect`, a test).
func RecordRun(instance, engine, collection string, res Result) {
	RecordRunEvery(instance, engine, collection, res, 0)
}

// RecordRunEvery is RecordRun with the collection's configured interval on that instance (task 201 DONE-2 N3): the
// minute's load row carries the fastest one counted, and the repository reads the collector's span from them
// (collector_span_take, 0121) - how far apart one instance's written minutes may lie, so a host whose collections all
// run every 5 minutes is not read as a late 1-minute one. every 0 = not known.
func RecordRunEvery(instance, engine, collection string, res Result, every time.Duration) {
	if h := current.Load(); h != nil {
		h.record(instance, engine, collection, res, time.Now(), every)
	}
}

// cutShort: a run a stop cut short (context.Canceled: the process or the instance's loop ending) - no failure of the
// instance, and nothing is counted for it.
func cutShort(res Result) bool { return res.Err != nil && errors.Is(res.Err, context.Canceled) }

// skipped: a run that did not try (a skip note) - no run and no failure; it ends a failing streak it finds.
func skipped(res Result) bool { return res.Err == nil && strings.Contains(res.Note, "skipped") }

// CountConnect counts one connection attempt to an instance: opened when err is nil, a login refused when the server
// said so (AuthFailure). A collection's per-database connects call it (connectCounted); the instance's own connect
// (collect.Connect, the SQL Server connector) goes through InstanceConnect, which counts the same way.
func CountConnect(instance string, err error) { CountConnectTimed(instance, err, 0) }

// CountConnectTimed is CountConnect with the connect's own time (the slow-connect tier: from the call to the open
// connection - DNS, TCP, TLS, the startup and the login); an opened connect with a time above 0 is 'timed' on the
// beat's load row, its time added to the minute's sum and kept when it is the longest. took 0: not timed.
func CountConnectTimed(instance string, err error, took time.Duration) {
	if h := current.Load(); h != nil {
		h.mu.Lock()
		defer h.mu.Unlock()
		h.countConnectTimed(instance, err, took)
	}
}

func (h *Heartbeat) countConnect(instance string, err error) { h.countConnectTimed(instance, err, 0) }

func (h *Heartbeat) countConnectTimed(instance string, err error, took time.Duration) {
	l := h.loadOf(instance)
	l.attempts++
	if err == nil {
		l.opened++
		if took > 0 {
			ms := took.Milliseconds()
			l.timed++
			l.connMsSum += ms
			l.connMsMax = max(l.connMsMax, int(ms))
		}
	} else if AuthFailure(err) {
		l.auth++
	}
	if NoAnswer(err) {
		l.noanswer++
	}
}

// NoAnswer says whether a failed connect got no answer from the server (task 201 DONE-2 N8: the server's own parent
// counts these alone) - a network error (refused, unreachable, a name not found), a timeout or deadline, a reset or an
// end of stream in the handshake, a TLS handshake that died. Never a failure the server answered (a PostgreSQL
// SQLSTATE such as 3D000, 28P01 or 53300; a SQL Server error number such as 18456), never a stop's cancel. The SQL
// Server connector joins the network error the driver drops (a named instance whose SQL Server Browser answered no
// one, a TLS handshake's error: internal/mssql's withNetwork), so those read here as no answer too.
func NoAnswer(err error) bool {
	if err == nil || errors.Is(err, context.Canceled) {
		return false
	}
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return false
	}
	var ms interface{ SQLErrorNumber() int32 }
	if errors.As(err, &ms) {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return true
	}
	var ne net.Error
	return errors.As(err, &ne)
}

// InstanceTarget records the instance's dial target (task 201 DONE-2 N8): what the collector connects to - the engine,
// the DSN's host and port, lower-cased ('postgres:db1.example:5432'; PgTarget, and the SQL Server connector's own) -
// sent on the beat's load row. The repository names a server by it, never by the server's reported address (a pooler,
// a container's address, a virtual name). Nothing when no heartbeat runs.
func InstanceTarget(instance, target string) {
	if h := current.Load(); h != nil && target != "" {
		h.mu.Lock()
		defer h.mu.Unlock()
		if h.targets == nil {
			h.targets = map[string]string{}
		}
		h.targets[instance] = target
	}
}

// PgTarget is a PostgreSQL config's dial target: 'postgres:<host>:<port>', its fallback hosts after it in order, each
// once (pgx lists a host twice under sslmode=prefer: a try with TLS and one without).
func PgTarget(cfg *pgx.ConnConfig) string {
	if cfg == nil {
		return ""
	}
	first := strings.ToLower(cfg.Host) + ":" + strconv.Itoa(int(cfg.Port))
	t, seen := "postgres:"+first, map[string]bool{first: true}
	for _, f := range cfg.Fallbacks {
		if hp := strings.ToLower(f.Host) + ":" + strconv.Itoa(int(f.Port)); !seen[hp] {
			seen[hp] = true
			t += "," + hp
		}
	}
	return t
}

// connectError marks a failure of an instance's own connect (InstanceConnect): the run that meets it builds no
// per-collection streak - the instance's own findings ('authentication failing', 'server unreachable') speak for it.
type connectError struct{ err error }

func (e *connectError) Error() string { return e.err.Error() }
func (e *connectError) Unwrap() error { return e.err }

// connectStreak is the collection name under which an instance's own connect keeps its failed attempts in a row
// (0121's 'server unreachable'; never a collection's name).
const connectStreak = "(connect)"

// InstanceConnect counts an instance's own connect (a collection's first: collect.Connect, the SQL Server connector)
// as CountConnect does and keeps the instance's connect streak: a failure that is not a refused login adds one, an
// opened or refused connect ends it (the server answered), a stop's cancel touches nothing. It returns err marked as
// the instance's connect failure (its text unchanged; errors.Is / errors.As see through the mark).
func InstanceConnect(instance string, err error) error { return InstanceConnectTimed(instance, err, 0) }

// InstanceConnectTimed is InstanceConnect with the connect's own time (CountConnectTimed's rule; took 0: not timed).
func InstanceConnectTimed(instance string, err error, took time.Duration) error {
	if h := current.Load(); h != nil {
		now := time.Now()
		h.name(instance, now) // before the connect's outcome is reported: its failed read finds the instance covered
		return h.instanceConnectTimed(instance, err, now, took)
	}
	if err == nil {
		return nil
	}
	return &connectError{err}
}

// seenEvery: how long a name written to the repository stands before the next connect writes it again. The beat names
// every instance it loads, so only an instance with no activity for that long (read every 20 minutes, hourly) writes
// its name at a connect.
const seenEvery = 10 * time.Minute

// seenDue says whether the instance's name is to be written now - its first connect in this run, or seenEvery since
// the last write - and notes now as written.
func (h *Heartbeat) seenDue(instance string, now time.Time) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if t, ok := h.seen[instance]; ok && now.Sub(t) < seenEvery {
		return false
	}
	if h.seen == nil {
		h.seen = map[string]time.Time{}
	}
	h.seen[instance] = now
	return true
}

// seenFailed forgets a name whose write failed: the next connect writes it again.
func (h *Heartbeat) seenFailed(instance string) {
	h.mu.Lock()
	delete(h.seen, instance)
	h.mu.Unlock()
}

// name tells the repository that this run reads the instance (pgvigil.import_collector_seen), in the instance's own
// connect and before that connect's failure is recorded anywhere: 'server unreachable' of the stored reads (0118) is
// left out for an instance a collector that beats covers, and a load row only arrives with the next beat - a
// collector back after a long stop, an instance read once an hour, or one never reached would send that finding beside
// this file's own. By name: the instance's row may not exist yet. One short write, at most once in seenEvery.
func (h *Heartbeat) name(instance string, now time.Time) {
	if !h.seenDue(instance, now) || h.pool == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if _, err := h.pool.Exec(ctx, `SELECT pgvigil.import_collector_seen($1, $2, $3)`, h.id, instance, now); err != nil {
		h.seenFailed(instance)
		if h.log != nil {
			h.log.Debug("heartbeat: the instance was not named", "instance", instance, "err", err)
		}
	}
}

func (h *Heartbeat) instanceConnect(instance string, err error, now time.Time) error {
	return h.instanceConnectTimed(instance, err, now, 0)
}

func (h *Heartbeat) instanceConnectTimed(instance string, err error, now time.Time, took time.Duration) error {
	if err != nil && errors.Is(err, context.Canceled) {
		return &connectError{err} // a stop cut it: no attempt, no streak
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.countConnectTimed(instance, err, took)
	sk := [2]string{instance, connectStreak}
	s := h.streaks[sk]
	if s == nil {
		s = &streak{fresh: true}
		h.streaks[sk] = s
	}
	was := s.fails
	failed := err != nil && !AuthFailure(err)
	if failed {
		if s.fails == 0 {
			s.since = now
		}
		s.fails++
		s.lastErr = err.Error()
	} else {
		s.fails, s.lastErr, s.since = 0, "", time.Time{}
	}
	s.at = now
	s.dirty = s.dirty || failed || was > 0 || s.fresh
	s.fresh = false
	if err == nil {
		return nil
	}
	return &connectError{err}
}

// DefaultConnectTimeout bounds an instance connect whose DSN sets no connect_timeout (task 201 DONE-2, N10): pgx then
// waits on the caller's context alone, so a host that drops packets held each collection to its own deadline. With it
// the whole connect (dial, TLS, startup, login) ends in about 10 s per host address and is a failed attempt. A DSN's
// own connect_timeout is kept; connect_timeout=0 parses to the same 0 as none and takes this too. A variable so a test
// can shorten it.
var DefaultConnectTimeout = 10 * time.Second

// withConnectTimeout gives a config whose DSN set no connect_timeout DefaultConnectTimeout.
func withConnectTimeout(cfg *pgx.ConnConfig) {
	if cfg.ConnectTimeout == 0 {
		cfg.ConnectTimeout = DefaultConnectTimeout
	}
}

// connectCounted is pgx.ConnectConfig counted for the instance's load, under DefaultConnectTimeout where the DSN set
// no connect_timeout.
func connectCounted(ctx context.Context, in config.Instance, cfg *pgx.ConnConfig) (*pgx.Conn, error) {
	withConnectTimeout(cfg)
	t0 := time.Now()
	conn, err := dialWithSecret(ctx, in, cfg, func() { InstanceTarget(in.Name, PgTarget(cfg)); t0 = time.Now() },
		func(c *pgx.ConnConfig) (*pgx.Conn, error) { return pgx.ConnectConfig(ctx, c) })
	var se *secrets.ReadError
	if errors.As(err, &se) {
		return nil, err // the secret, not the server: not counted as a connect (B24e)
	}
	CountConnectTimed(in.Name, err, connTook(t0)) // the slow-connect tier times the per-database connects too (#6)
	return conn, err
}

// connTook: a PostgreSQL connect's time from t0, never under a nanosecond - a clock that moves in ticks (Windows'
// 15.6 ms one) reads a short connect as 0, which countConnectTimed would leave untimed; an opened connect is always
// timed, as SQL Server's connectTook (internal/mssql)
func connTook(t0 time.Time) time.Duration { return max(time.Since(t0), time.Nanosecond) }

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

func (h *Heartbeat) record(instance, engine, collection string, res Result, now time.Time, every time.Duration) {
	if cutShort(res) {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.health(instance, collection, res, now, every) // B6.1's hourly counts: every outcome, a skip too
	// B24h-1b: the default mode probes an address after a collection got no answer - a dial refused or timed out, a
	// deadline, a dropped connection (NoAnswer reads through connectError) - never after an error the server sent: a
	// query it refused on an opened connection (the review of B24h-1 part a #3: a missing grant probed every minute) or a
	// login it refused at the connect (28P01, 18456: the review of the fold #2 - a rotated password probed every minute)
	if res.Err != nil && h.probe != nil && NoAnswer(res.Err) {
		h.probe.noteFailed(instance)
	}
	if skipped(res) {
		// a collection that skips (no system_stats, no pg_cron, no log door) after it failed - its login refused, or
		// a setting changed - is failing no more: its streak (a stored one too) ends at 0 and is written
		if s := h.streaks[[2]string{instance, collection}]; s != nil && s.fails > 0 {
			s.fails, s.lastErr, s.at, s.since, s.dirty, s.fresh = 0, "", now, time.Time{}, true, false
		}
		return
	}
	l := h.loadOf(instance)
	if every > 0 && (l.every == 0 || every < l.every) {
		l.every = every
	}
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
	a.retries += res.Retries
	if failed {
		a.failures++
	} else {
		a.rows += int64(res.Rows)
	}
	ms := int(res.Duration.Milliseconds())
	a.durSum += int64(ms)
	a.durMax = max(a.durMax, ms)
	a.hist[bucket(res.Duration)]++
	if ce := (*connectError)(nil); failed && errors.As(res.Err, &ce) {
		return // the instance's own connect failed: its connect streak and 'authentication failing' speak for it
	}
	if se := (*secrets.ReadError)(nil); failed && errors.As(res.Err, &se) {
		// the login's password could not be read from AWS Secrets Manager (B24e, decision Q7): 0192's one finding
		// speaks for the instance, never a 'collection failing' streak per collection
		return
	}
	sk := [2]string{instance, collection}
	s := h.streaks[sk]
	if s == nil {
		s = &streak{fresh: true} // never seen since the start: its first result is sent (a stored streak is replaced)
		h.streaks[sk] = s
	}
	was := s.fails
	if failed {
		if s.fails == 0 {
			s.since = now
		}
		s.fails++
		s.lastErr = res.Err.Error()
	} else {
		s.fails, s.lastErr, s.since = 0, "", time.Time{}
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
	Retries    int    `json:"retries,omitempty"` // N4: collector_runs.retries (absent = 0)
}

type beatLoad struct {
	Instance string `json:"instance"`
	Attempts int    `json:"attempts"`
	Opened   int    `json:"opened"`
	Runs     int    `json:"runs"`
	Failures int    `json:"failures"`
	Auth     int    `json:"auth"`
	// IntervalS: the fastest configured interval, in seconds, of the minute's runs of the instance (none known: left out)
	IntervalS int `json:"interval_s,omitempty"`
	// NoAnswer: the minute's failed connects the server never answered; Target: the instance's dial target (N8)
	NoAnswer int    `json:"noanswer,omitempty"`
	Target   string `json:"target,omitempty"`
	// the slow-connect tier: the minute's timed connects, their milliseconds summed and the longest (none: left out;
	// an older repository ignores them, an older collector's beat leaves them NULL - 0121's coalesce)
	Timed        int   `json:"timed,omitempty"`
	ConnectMsSum int64 `json:"connect_ms_sum,omitempty"`
	ConnectMsMax int   `json:"connect_ms_max,omitempty"`
	// the query round trip (B24h-1a): read by import_collector_probe (0254), which import_collector_beat leaves alone
	RtCount int   `json:"rt_count,omitempty"`
	RtMsSum int64 `json:"rt_ms_sum,omitempty"`
	RtMsMax int   `json:"rt_ms_max,omitempty"`
}

type beatStreak struct {
	Instance   string     `json:"instance"`
	Collection string     `json:"collection"`
	Fails      int        `json:"fails"`
	Error      string     `json:"error"`
	At         time.Time  `json:"at"`
	Since      *time.Time `json:"since,omitempty"` // the streak's first failure (none: the repository keeps its own)
}

type beat struct {
	MemBytes    uint64       `json:"mem_bytes"`
	Goroutines  int          `json:"goroutines"`
	Instances   int          `json:"instances"`
	SendsAlerts bool         `json:"sends_alerts"`
	Runs        []beatRun    `json:"runs"`
	Load        []beatLoad   `json:"load"`
	Streaks     []beatStreak `json:"streaks"`
	Health      []beatHealth `json:"-"` // B6.1: running totals per instance, collection and UTC hour - their own body (healthBody)
	// the probe's rows since the last beat (B24h-1b; read by import_collector_probe, 0254; import_collector_beat leaves it)
	Probes []beatProbe `json:"probes"`
	// the addresses a connection opened to since the last beat (the review of B24h-1 part a #1: a TCP answer;
	// import_collector_probe sets the host's last answer from them)
	Opened []beatOpened `json:"opened"`
}

// take empties the minute's counts into a beat (the streaks keep their counts; only the changed ones are sent).
func (h *Heartbeat) take() beat {
	h.mu.Lock()
	defer h.mu.Unlock()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	// empty lists as [] (a nil slice is JSON null, which jsonb_to_recordset refuses)
	b := beat{MemBytes: ms.Sys, Goroutines: runtime.NumGoroutine(), Instances: len(h.load), SendsAlerts: h.info.SendsAlerts,
		Runs: []beatRun{}, Load: []beatLoad{}, Streaks: []beatStreak{}, Health: h.takeHealth(), Probes: []beatProbe{}, Opened: []beatOpened{}}
	if h.probe != nil {
		b.Probes = append(b.Probes, h.probe.take()...)
		b.Opened = append(b.Opened, h.probe.takeOpened()...)
	}
	for k, a := range h.runs {
		b.Runs = append(b.Runs, beatRun{Engine: k[0], Collection: k[1], Runs: a.runs, Failures: a.failures, Rows: a.rows,
			DurSum: a.durSum, DurMax: a.durMax, Hist: append([]int(nil), a.hist[:]...), Retries: a.retries})
	}
	now := time.Now()
	for name, l := range h.load {
		b.Load = append(b.Load, beatLoad{Instance: name, Attempts: l.attempts, Opened: l.opened, Runs: l.runs, Failures: l.failures, Auth: l.auth,
			IntervalS: int(l.every / time.Second), NoAnswer: l.noanswer, Target: h.targets[name],
			Timed: l.timed, ConnectMsSum: l.connMsSum, ConnectMsMax: l.connMsMax, RtCount: l.rtCount, RtMsSum: l.rtMsSum, RtMsMax: l.rtMsMax})
		if h.seen == nil {
			h.seen = map[string]time.Time{}
		}
		h.seen[name] = now // the beat door names what it loads: no write of its own is due
	}
	for k, s := range h.streaks {
		if s.dirty {
			bs := beatStreak{Instance: k[0], Collection: k[1], Fails: s.fails, Error: s.lastErr, At: s.at}
			if s.fails > 0 && !s.since.IsZero() {
				since := s.since
				bs.Since = &since
			}
			b.Streaks = append(b.Streaks, bs)
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

// repoNotices logs a WARNING the repository raises on the beat's connections (review B6f10 #6): import_collection_health
// warns when the 'collections run long' stamps fail and keeps the beat's hour rows - without this the warning reached
// only the server's log. The severity is read unlocalized; a NOTICE is not logged.
func repoNotices(log *slog.Logger) func(*pgconn.PgConn, *pgconn.Notice) {
	return func(_ *pgconn.PgConn, n *pgconn.Notice) {
		if n == nil {
			return
		}
		sev := n.SeverityUnlocalized
		if sev == "" {
			sev = n.Severity
		}
		if sev == "WARNING" {
			log.Warn("repository warning", "message", n.Message, "where", n.Where)
		}
	}
}

// StartHeartbeat writes this collector's row (its start in the repository's clock) and beats every minute until ctx ends,
// then writes the last minute and marks a clean stop. dsn is the collector's repository DSN (the import_ door). The
// returned wait blocks until that is done (at most 15 s: the final beat 8 s, the stop mark 5 s, the pool's close): the
// caller defers it, or the process ends first.
func StartHeartbeat(ctx context.Context, log *slog.Logger, dsn string, info HeartbeatInfo) (wait func(), err error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("heartbeat: %w", err)
	}
	cfg.MaxConns = 2
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-heartbeat"
	cfg.ConnConfig.OnNotice = repoNotices(log)
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("heartbeat: %w", err)
	}
	host, _ := os.Hostname()
	h := &Heartbeat{id: fmt.Sprintf("%s/%d/%d", host, os.Getpid(), time.Now().UnixNano()), host: host, pool: pool, log: log,
		info: info, runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	if err := h.claim(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	h.loadStreaks(ctx)
	switch info.Probe {
	case "off":
	case "", "icmp", "tcp":
		h.probe = newProber("tcp", info.ProbeEveryMinute) // B24h-1: the TCP measure ('icmp' lands in B24h-2)
		go h.probe.loop(ctx)
	}
	current.Store(h)
	log.Info("heartbeat started", "collector", h.id, "runs_as", runsAs())
	done := make(chan struct{})
	go func() { defer close(done); h.loop(ctx) }()
	return func() {
		select {
		case <-done:
		case <-time.After(15 * time.Second):
			log.Warn("heartbeat: the heartbeat's stop did not finish in 15 s")
		}
	}, nil
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
	// this host's own (task 201 DONE-2 N5: streaks are kept by host; a collector on another host never takes them)
	rows, err := h.pool.Query(lctx, `SELECT instance, collection, fail_streak, coalesce(last_error, '') FROM pgvigil.import_collector_streaks($1)`, h.host)
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
			// the last partial minute's counts and streaks, then the stop mark, each with its own time (a slow final
			// beat leaves the stop mark its 5 s, so a clean stop never reads as a collector not seen)
			bctx, bcancel := context.WithTimeout(context.WithoutCancel(ctx), 8*time.Second)
			h.beat(bctx, time.Now().Truncate(time.Minute))
			bcancel()
			sctx, scancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			if _, err := h.pool.Exec(sctx, `SELECT pgvigil.import_collector_stop($1)`, h.id); err != nil {
				h.log.Warn("heartbeat: the stop mark was not written", "err", err)
			}
			scancel()
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
	err = h.pool.QueryRow(bctx, `SELECT pgvigil.import_collector_beat($1, $2, $3::jsonb)`, h.id, minute, string(body)).Scan(&known)
	if err != nil || !known {
		// the minute's counts are lost with the beat (the page shows the gap); the streaks are sent again next minute
		h.mu.Lock()
		for _, s := range b.Streaks {
			if st := h.streaks[[2]string{s.Instance, s.Collection}]; st != nil {
				st.dirty = true
			}
		}
		h.mu.Unlock()
	}
	if err != nil {
		h.log.Warn("heartbeat: the beat was not written", "err", err)
		return
	}
	if len(b.Health) > 0 {
		// running totals: a beat lost here is repaired by the next one; their own body and their own 30 s (a slow
		// heartbeat statement leaves this one its full time; at a stop both share the caller's 8 s)
		q, args, err := healthWrite(h.id, b.Health)
		if err == nil {
			hctx, hcancel := context.WithTimeout(ctx, 30*time.Second)
			_, err = h.pool.Exec(hctx, q, args...)
			hcancel()
		}
		if err != nil {
			h.log.Warn("heartbeat: the hourly collection health was not written", "err", err)
		}
	}
	if !known { // the row is gone (trimmed after 8 days without a beat, or deleted): claimed again
		if err := h.claim(ctx); err != nil {
			h.log.Warn("heartbeat: the collector's row was not written again", "err", err)
		}
		return
	}
	// B24h (0254): the round trips and the probe's rows, through B24h's own import function with the same body (no
	// joined function changes); a repository without it (42883: not migrated to 0254) is not asked again
	if !h.noProbeImport && (len(b.Probes) > 0 || len(b.Opened) > 0 || anyRoundTrip(b.Load)) {
		if _, err := h.pool.Exec(bctx, `SELECT pgvigil.import_collector_probe($1, $2, $3::jsonb)`, h.id, minute, string(body)); err != nil {
			var pe *pgconn.PgError
			if errors.As(err, &pe) && pe.Code == "42883" {
				h.noProbeImport = true
				h.log.Warn("heartbeat: the repository has no import_collector_probe (0254): the round trips and probes are not kept until it is migrated")
			} else {
				h.log.Warn("heartbeat: the round trips and probes were not written", "err", err)
			}
		}
	}
}

// anyRoundTrip: a load row with a round trip measured
func anyRoundTrip(load []beatLoad) bool {
	for _, l := range load {
		if l.RtCount > 0 {
			return true
		}
	}
	return false
}

// healthWrite: the hourly rows' statement and its arguments as beat() sends them - their own body (healthBody), never
// the heartbeat's; TestBeatBodyHealthOnce reads what beat() writes through it
func healthWrite(id string, rows []beatHealth) (string, []any, error) {
	hb, err := healthBody(rows)
	if err != nil {
		return "", nil, err
	}
	return `SELECT pgvigil.import_collection_health($1, $2::jsonb)`, []any{id, string(hb)}, nil
}

// ChannelBackoff keeps a failing alert channel out of the next passes, as the collector's own alert loop does
// (alerts.Run): 1 minute after its first failure, then 2, 4, 8 and 16, then 30 at most; a pass in which it succeeds
// forgets it. serve's watchdog pass uses it: a collector may be down for long, and a webhook answering 5xx or 429 must
// not be retried every minute. Not safe for two goroutines: the watchdog calls its pass from one.
type ChannelBackoff struct {
	m map[string]*channelBack
}

type channelBack struct {
	fails int
	until time.Time
}

// Skip names the channels still waiting at now (the skip map of alerts.Pass).
func (b *ChannelBackoff) Skip(now time.Time) map[string]bool {
	skip := map[string]bool{}
	for n, c := range b.m {
		if now.Before(c.until) {
			skip[n] = true
		}
	}
	return skip
}

// Note takes a pass's outcome per channel (nil = it sent): a failure lengthens the channel's wait from now.
func (b *ChannelBackoff) Note(now time.Time, outcome map[string]error) {
	for n, e := range outcome {
		if e == nil {
			delete(b.m, n)
			continue
		}
		if b.m == nil {
			b.m = map[string]*channelBack{}
		}
		c := b.m[n]
		if c == nil {
			c = &channelBack{}
			b.m[n] = c
		}
		c.fails++
		c.until = now.Add(min(time.Minute<<min(c.fails-1, 5), 30*time.Minute))
	}
}

var watchdog atomic.Value // string: "starting", "on", "on; the last alert pass failed: <err>", or "off: <why>"; empty outside serve

// SetWatchdogOff records why serve runs no watchdog (logged by the caller; the Collector page shows it).
func SetWatchdogOff(why string) { watchdog.Store("off: " + why) }

// SetWatchdogStarting records that serve runs the watchdog and is still reaching the alerts login and the repository
// (each ping up to 20 s): the Collector page says 'Starting', never 'not this process', until the watchdog's goroutine
// stores 'on' or 'off: <why>'.
func SetWatchdogStarting() { watchdog.Store("starting") }

// WatchdogStatus is "starting" (serve reaching its logins), "on" (with the last pass's failure when it failed),
// "off: <why>", or "" outside serve.
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
	pctx, pcancel := context.WithTimeout(ctx, 20*time.Second)
	err = pool.Ping(pctx)
	pcancel()
	if err != nil { // a pool connects when first used: the page says on only once the repository answered
		SetWatchdogOff("the repository did not answer: " + err.Error())
		log.Warn("collector watchdog off", "err", err)
		return
	}
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
				watchdog.Store("on; the last alert pass failed: " + err.Error())
				log.Warn("collector watchdog: the alert pass failed", "err", err)
			} else {
				watchdog.Store("on")
			}
		}
	}
}
