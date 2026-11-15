package web

// metrics_prom.go (B24d; the audits' S3 and C77): GET /metrics - every active instance's newest collected figures in
// the Prometheus text format (version 0.0.4), so a site that runs Prometheus and Alertmanager reads pgvigil's
// collections without a login on every server.
//
//   - Off unless doors.prometheus_metrics is on in pgvigil.yaml (serve calls EnableMetrics); off, the route answers
//     404 with one line naming the switch (the route is there either way: the '/' catch-all would answer 200 with the
//     page shell). A configuration key only, no UI switch.
//   - Read with a live UI session OR 'Authorization: Bearer <token>' (metrics.token: file:/path or env:NAME). The
//     compare runs on SHA-256 digests in constant time; an empty presented token is refused before it; a token file is
//     read again when its mtime changes and the old token is accepted 60 s more; refused bearer attempts go through a
//     per-address limiter (5 a minute); a request with no credentials logs one WARN per address per minute; every
//     refusal counts in pgvigil_metrics_refused_total. A token in the URL is refused. Under -no-login (s.auth nil) no
//     session is read, so a stale cookie never reaches the nil login state.
//   - The figures: pgvigil.metrics_newest (0196, one set-based statement) in the Metrics grid's units, converted here
//     to base units by the frozen name table (promNames: one row per metric_catalog key; a key without a row fails
//     TestPromNamesCoverTheCatalog); gauges only, no explicit timestamps, a stale point left out and the newest sample's
//     time per family given as pgvigil_sample_timestamp_seconds. The database family's instance totals always; each
//     database's own series with metrics.databases on.
//   - The body is rendered in the background ahead of expiry (one render at a time), the previous body served while a
//     render runs, never a body older than 2 x cache_seconds: a scrape with nothing fresh enough waits for the render
//     up to its X-Prometheus-Scrape-Timeout-Seconds and gets 503 when it fails or does not end (Prometheus: up = 0).
//   - Content-Type text/plain; version=0.0.4; charset=utf-8 on the plain and the gzip reply.

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"math"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// promContentType is the text format's media type; Prometheus 3 fails a scrape without it.
const promContentType = "text/plain; version=0.0.4; charset=utf-8"

// MetricsOff is the 404's line while doors.prometheus_metrics is off.
const MetricsOff = "off on this install: doors.prometheus_metrics in pgvigil.yaml turns on the Prometheus endpoint /metrics; " +
	"it opens every active instance's newest figures, server names, engines, platforms, versions (and tags and database names when " +
	"metrics.tags / metrics.databases are on) to whoever reads that Prometheus"

// MetricsConfig is the metrics: block of pgvigil.yaml as serve resolves it.
type MetricsConfig struct {
	// Token is metrics.token as written: file:/path or env:NAME (resolved and checked by CheckMetricsToken); "" = only a
	// signed-in browser can read the endpoint.
	Token string
	// CacheSeconds is the body's life before a render; 0 = 60.
	CacheSeconds int
	// Databases turns each database's own series on (the database family); off = the instance totals only.
	Databases bool
	// MaxDatabases cuts the per-database series of one instance (largest first); 0 = 50.
	MaxDatabases int
	// IncludeDatabases names the databases to export in place of the largest; nil = by size.
	IncludeDatabases []string
	// Tags adds the instance's tags to pgvigil_instance_info.
	Tags bool
}

func (c *MetricsConfig) cache() time.Duration {
	if c == nil || c.CacheSeconds <= 0 {
		return 60 * time.Second
	}
	return time.Duration(c.CacheSeconds) * time.Second
}

func (c *MetricsConfig) maxDatabases() int {
	if c == nil || c.MaxDatabases <= 0 {
		return 50
	}
	return c.MaxDatabases
}

// metricsTokenMin is the shortest token serve accepts.
const metricsTokenMin = 32

// readMetricsToken resolves a token spec (file:/path or env:NAME), every surrounding whitespace trimmed; the file's
// mtime comes back for the rotation check.
func readMetricsToken(spec string) (string, time.Time, error) {
	switch {
	case strings.HasPrefix(spec, "file:"):
		p := strings.TrimPrefix(spec, "file:")
		st, err := os.Stat(p)
		if err != nil {
			return "", time.Time{}, err
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return "", time.Time{}, err
		}
		return strings.TrimSpace(string(b)), st.ModTime(), nil
	case strings.HasPrefix(spec, "env:"):
		return strings.TrimSpace(os.Getenv(strings.TrimPrefix(spec, "env:"))), time.Time{}, nil
	default:
		return "", time.Time{}, errors.New("metrics.token takes file:/path or env:NAME, never the token itself")
	}
}

// CheckMetricsToken is serve's start check of the switch and the token: an error ends serve with its line. login says
// whether the UI login is on (-no-login off). warns are the lines serve logs at start (what is open).
func CheckMetricsToken(c *MetricsConfig, login bool) (warns []string, err error) {
	if c == nil {
		return nil, nil
	}
	warns = append(warns, "doors.prometheus_metrics is on: /metrics opens every active instance's newest figures, server names, engines, platforms and versions"+
		map[bool]string{true: ", tags", false: ""}[c.Tags]+map[bool]string{true: ", database names", false: ""}[c.Databases]+
		" to whoever reads that Prometheus (and its remote_write targets)")
	if c.Token == "" {
		if !login {
			return warns, errors.New("doors.prometheus_metrics is on under -no-login with no metrics.token: set metrics.token (file:/path or env:NAME) or turn the door off")
		}
		return append(warns, "metrics.token is not set: only a signed-in browser can read /metrics (a Prometheus server cannot)"), nil
	}
	tok, _, err := readMetricsToken(c.Token)
	if err != nil {
		// a value without file: / env: may be the token itself: never printed
		if !strings.HasPrefix(c.Token, "file:") && !strings.HasPrefix(c.Token, "env:") {
			return warns, errors.New("metrics.token is not file:/path or env:NAME (its value is not shown: it may be the token itself)")
		}
		return warns, fmt.Errorf("metrics.token %s: %v", c.Token, err)
	}
	if len(tok) < metricsTokenMin {
		return warns, fmt.Errorf("metrics.token %s resolves to %d bytes: it needs %d at least (an empty or short token is refused)", c.Token, len(tok), metricsTokenMin)
	}
	return warns, nil
}

// promToken holds the accepted token digests: the current one and, for 60 s after a file change, the one before.
type promToken struct {
	spec      string
	mu        sync.Mutex
	cur, prev [sha256.Size]byte
	have      bool
	prevUntil time.Time
	mtime     time.Time
	checked   time.Time
	warned    bool
}

func (t *promToken) refresh(now time.Time, warn func(string)) {
	if !strings.HasPrefix(t.spec, "file:") && t.have {
		return
	}
	if t.have && now.Sub(t.checked) < time.Second {
		return
	}
	t.checked = now
	// read again at most once a second and judged by the content's digest (not the mtime: a rewrite within one mtime
	// tick would be missed); a read that fails or is short keeps the token in use, warned once per content
	tok, mt, err := readMetricsToken(t.spec)
	if err != nil || len(tok) < metricsTokenMin {
		if t.have && !t.warned {
			warn(fmt.Sprintf("metrics.token %s could not be read again or is under %d bytes: the token in use stays", t.spec, metricsTokenMin))
			t.warned = true
		}
		return
	}
	t.warned = false
	d := sha256.Sum256([]byte(tok))
	if t.have && d != t.cur {
		t.prev, t.prevUntil = t.cur, now.Add(60*time.Second)
	}
	t.cur, t.mtime, t.have = d, mt, true
}

// match compares the presented token's digest with the accepted ones in constant time.
func (t *promToken) match(presented string, now time.Time, warn func(string)) bool {
	if presented == "" {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.refresh(now, warn)
	if !t.have {
		return false
	}
	d := sha256.Sum256([]byte(presented))
	ok := subtle.ConstantTimeCompare(d[:], t.cur[:]) == 1
	if now.Before(t.prevUntil) {
		ok = subtle.ConstantTimeCompare(d[:], t.prev[:]) == 1 || ok
	}
	return ok
}

// promLimiter refuses an address for a minute after 5 refused bearer attempts, and lets one WARN a minute through per
// address for requests without credentials.
type promLimiter struct {
	mu    sync.Mutex
	fails map[string]failRecord
	warns map[string]time.Time
	swept time.Time
}

// sweepLocked drops the records older than a minute, at most once a minute (l.mu held).
func (l *promLimiter) sweepLocked(now time.Time) {
	if now.Sub(l.swept) < time.Minute {
		return
	}
	l.swept = now
	for k, f := range l.fails {
		if !now.Before(f.reset) {
			delete(l.fails, k)
		}
	}
	for k, t := range l.warns {
		if now.Sub(t) >= time.Minute {
			delete(l.warns, k)
		}
	}
}

func (l *promLimiter) wait(ip string, now time.Time) time.Duration {
	l.mu.Lock()
	defer l.mu.Unlock()
	if f, ok := l.fails[ip]; ok && now.Before(f.reset) && f.n >= maxFails {
		return f.reset.Sub(now)
	}
	return 0
}

func (l *promLimiter) fail(ip string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.fails == nil {
		l.fails = map[string]failRecord{}
	}
	l.sweepLocked(now)
	f := l.fails[ip]
	if !now.Before(f.reset) {
		f = failRecord{reset: now.Add(failWindow)}
	}
	f.n++
	l.fails[ip] = f
}

func (l *promLimiter) warnOnce(ip string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.warns == nil {
		l.warns = map[string]time.Time{}
	}
	if t, ok := l.warns[ip]; ok && now.Sub(t) < time.Minute {
		return false
	}
	l.sweepLocked(now)
	l.warns[ip] = now
	return true
}

// promState is one Server's endpoint: its config, token, limiter and the rendered body.
type promState struct {
	cfg     *MetricsConfig
	token   *promToken
	limit   promLimiter
	refused atomic.Int64
	renders atomic.Int64

	mu       sync.Mutex
	body, gz []byte
	at       time.Time
	running  chan struct{}
	lastErr  error
	lastDur  time.Duration
	series   int
}

// promStates maps a Server to its endpoint (set by EnableMetrics; absent = the door is off).
var promStates sync.Map

// EnableMetrics turns /metrics on for this server (serve, after CheckMetricsToken); nil leaves it off.
func (s *Server) EnableMetrics(c *MetricsConfig) {
	if c == nil {
		promStates.Delete(s)
		return
	}
	st := &promState{cfg: c}
	if c.Token != "" {
		st.token = &promToken{spec: c.Token}
	}
	promStates.Store(s, st)
}

func (s *Server) prom() *promState {
	v, ok := promStates.Load(s)
	if !ok {
		return nil
	}
	return v.(*promState)
}

// PromMetrics serves GET /metrics (registered on the outer mux, outside requireLogin: its own gate).
func (s *Server) PromMetrics(w http.ResponseWriter, r *http.Request) {
	st := s.prom()
	if st == nil {
		writeErr(w, http.StatusNotFound, errors.New(MetricsOff))
		return
	}
	now := time.Now()
	ip := clientIP(r)
	warn := func(m string) { s.log.Warn("metrics: " + m) }
	q := r.URL.Query()
	for _, k := range []string{"token", "access_token", "bearer", "auth"} {
		if q.Has(k) {
			st.refused.Add(1)
			writeErr(w, http.StatusBadRequest, errors.New("a token in the URL is refused: send it as 'Authorization: Bearer <token>'"))
			return
		}
	}
	ok := false
	// a live UI session, read only when the login is on (s.auth nil under -no-login: no cookie reaches it)
	if s.auth != nil && s.sessionUser(r) != "" {
		ok = true
	}
	if h := r.Header.Get("Authorization"); !ok && h != "" {
		tok, isBearer := strings.CutPrefix(h, "Bearer ")
		tok = strings.TrimSpace(tok)
		// the right token passes even while the address is locked out (a shared address - NAT, a proxy - must not let
		// another sender keep Prometheus out); a wrong one meets the lockout first
		if !isBearer || tok == "" || st.token == nil || !st.token.match(tok, now, warn) {
			st.refused.Add(1)
			if d := st.limit.wait(ip, now); d > 0 {
				w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(d.Seconds()))))
				writeErr(w, http.StatusTooManyRequests, errors.New("too many refused tokens from this address: wait a minute"))
				return
			}
			st.limit.fail(ip, now)
			writeErr(w, http.StatusUnauthorized, errors.New("the token is refused"))
			return
		}
		ok = true
	}
	if !ok {
		st.refused.Add(1)
		if st.limit.warnOnce(ip, now) {
			s.log.Warn("metrics: a request without credentials refused", "addr", ip)
		}
		w.Header().Set("WWW-Authenticate", `Bearer realm="pgvigil metrics"`)
		writeErr(w, http.StatusUnauthorized, errors.New("login required: a signed-in session or 'Authorization: Bearer <token>'"))
		return
	}
	wait := 10 * time.Second
	if v, err := strconv.ParseFloat(r.Header.Get("X-Prometheus-Scrape-Timeout-Seconds"), 64); err == nil && v > 0 {
		wait = time.Duration(v*float64(time.Second)) - 500*time.Millisecond
		if wait < time.Second {
			wait = time.Second
		}
		if wait > 70*time.Second { // serve's WriteTimeout is 75 s: a 503 with words, never a cut connection
			wait = 70 * time.Second
		}
	}
	body, gz, err := st.get(r.Context(), wait, s.renderMetrics)
	if err != nil {
		s.log.Warn("metrics: no body to serve", "err", err)
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the figures could not be read: %v", err))
		return
	}
	w.Header().Set("Content-Type", promContentType)
	w.Header().Set("Cache-Control", "no-store")
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Vary", "Accept-Encoding")
		_, _ = w.Write(gz)
		return
	}
	_, _ = w.Write(body)
}

// get returns a body no older than the cache (or, while a render runs, no older than 2 x the cache); otherwise it
// waits for the render up to wait.
func (st *promState) get(ctx context.Context, wait time.Duration, render func(context.Context, *promState) ([]byte, error)) ([]byte, []byte, error) {
	cache := st.cfg.cache()
	st.mu.Lock()
	age := time.Since(st.at)
	if st.body != nil && age < cache {
		if age >= cache*4/5 { // ahead of expiry
			st.startLocked(render)
		}
		b, g := st.body, st.gz
		st.mu.Unlock()
		return b, g, nil
	}
	done := st.startLocked(render)
	if st.body != nil && age < 2*cache {
		b, g := st.body, st.gz
		st.mu.Unlock()
		return b, g, nil
	}
	st.mu.Unlock()
	t := time.NewTimer(wait)
	defer t.Stop()
	select {
	case <-done:
	case <-t.C:
		return nil, nil, errors.New("the render did not end within the scrape's timeout")
	case <-ctx.Done():
		return nil, nil, ctx.Err()
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.body != nil && time.Since(st.at) < 2*cache {
		return st.body, st.gz, nil
	}
	if st.lastErr != nil {
		return nil, nil, st.lastErr
	}
	return nil, nil, errors.New("no render ended")
}

// startLocked starts the one render (st.mu held) and returns its done channel.
func (st *promState) startLocked(render func(context.Context, *promState) ([]byte, error)) chan struct{} {
	if st.running != nil {
		return st.running
	}
	done := make(chan struct{})
	st.running = done
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		t0 := time.Now()
		st.renders.Add(1)
		body, err := render(ctx, st)
		var gz []byte
		if err == nil {
			var b bytes.Buffer
			zw := gzip.NewWriter(&b)
			if _, err = zw.Write(body); err == nil {
				err = zw.Close()
			}
			gz = b.Bytes()
		}
		st.mu.Lock()
		if err == nil {
			st.body, st.gz, st.at, st.lastErr = body, gz, t0, nil // its age from the read's start, not its end
		} else {
			st.lastErr = err
		}
		st.lastDur = time.Since(t0)
		st.running = nil
		st.mu.Unlock()
		close(done)
	}()
	return done
}

// promName is one row of the frozen name table: the catalog key, its exported name (the instance's figure), the
// per-database name (the database family only) and the conversion from the grid's unit.
type promName struct {
	key, name, dbName, unit string
}

// promNames: the 62 rows of the B24d name table (notes '### The name table'); TestPromNamesCoverTheCatalog fails on a
// catalog key without a row. unit 'interval' = a count per interval exported per second.
var promNames = []promName{
	{"sessions.total", "pgvigil_sessions", "", "count"},
	{"sessions.active", "pgvigil_sessions_active", "", "count"},
	{"sessions.idle_in_txn", "pgvigil_sessions_idle_in_transaction", "", "count"},
	{"sessions.waiting_lock", "pgvigil_sessions_waiting_lock", "", "count"},
	{"sessions.connections_pct", "pgvigil_sessions_connections_used_ratio", "", "pct"},
	{"sessions.longest_active_secs", "pgvigil_sessions_longest_active_seconds", "", "secs"},
	{"sessions.longest_idle_txn_secs", "pgvigil_sessions_longest_idle_in_transaction_seconds", "", "secs"},
	{"sessions.oldest_xmin_age", "pgvigil_sessions_oldest_xmin_age", "", "xids"},
	{"database.commits_s", "pgvigil_instance_commits_per_second", "pgvigil_database_commits_per_second", "per_s"},
	{"database.rollbacks_s", "pgvigil_instance_rollbacks_per_second", "pgvigil_database_rollbacks_per_second", "per_s"},
	{"database.blks_read_s", "pgvigil_instance_blocks_read_per_second", "pgvigil_database_blocks_read_per_second", "per_s"},
	{"database.blks_hit_s", "pgvigil_instance_blocks_hit_per_second", "pgvigil_database_blocks_hit_per_second", "per_s"},
	{"database.cache_hit_pct", "pgvigil_instance_cache_hit_ratio", "pgvigil_database_cache_hit_ratio", "pct"},
	{"database.tup_read_s", "pgvigil_instance_tuples_read_per_second", "pgvigil_database_tuples_read_per_second", "per_s"},
	{"database.tup_written_s", "pgvigil_instance_tuples_written_per_second", "pgvigil_database_tuples_written_per_second", "per_s"},
	{"database.temp_bytes_s", "pgvigil_instance_temp_bytes_per_second", "pgvigil_database_temp_bytes_per_second", "bytes_per_s"},
	{"database.deadlocks", "pgvigil_instance_deadlocks_per_second", "pgvigil_database_deadlocks_per_second", "interval"},
	{"database.backends", "pgvigil_instance_backends", "pgvigil_database_backends", "count"},
	{"server.checkpoints", "pgvigil_server_checkpoints_per_second", "", "interval"},
	{"server.checkpoints_req", "pgvigil_server_checkpoints_requested_per_second", "", "interval"},
	{"server.buffers_written_s", "pgvigil_server_buffers_written_per_second", "", "per_s"},
	{"server.buffers_alloc_s", "pgvigil_server_buffers_allocated_per_second", "", "per_s"},
	{"server.wal_bytes_s", "pgvigil_server_wal_bytes_per_second", "", "bytes_per_s"},
	{"server.wal_records_s", "pgvigil_server_wal_records_per_second", "", "per_s"},
	{"io.read_bytes_s", "pgvigil_io_read_bytes_per_second", "", "bytes_per_s"},
	{"io.write_bytes_s", "pgvigil_io_write_bytes_per_second", "", "bytes_per_s"},
	{"io.extend_bytes_s", "pgvigil_io_extend_bytes_per_second", "", "bytes_per_s"},
	{"io.hits_s", "pgvigil_io_hits_per_second", "", "per_s"},
	{"io.fsyncs_s", "pgvigil_io_fsyncs_per_second", "", "per_s"},
	{"requests.sessions", "pgvigil_requests_sessions", "", "count"},
	{"requests.requests", "pgvigil_requests_running", "", "count"},
	{"requests.blocked", "pgvigil_requests_blocked", "", "count"},
	{"requests.heads", "pgvigil_requests_blocking_heads", "", "count"},
	{"requests.longest_wait_ms", "pgvigil_requests_longest_wait_seconds", "", "ms"},
	{"cpu.sql_pct", "pgvigil_cpu_sql_ratio", "", "pct"},
	{"cpu.other_pct", "pgvigil_cpu_other_ratio", "", "pct"},
	{"cpu.total_pct", "pgvigil_cpu_total_ratio", "", "pct"},
	{"scheduler.batch_s", "pgvigil_scheduler_batch_requests_per_second", "", "per_s"},
	{"scheduler.transactions_s", "pgvigil_scheduler_transactions_per_second", "", "per_s"},
	{"scheduler.compiles_s", "pgvigil_scheduler_compilations_per_second", "", "per_s"},
	{"scheduler.recompiles_s", "pgvigil_scheduler_recompilations_per_second", "", "per_s"},
	{"scheduler.runnable_tasks", "pgvigil_scheduler_runnable_tasks", "", "count"},
	{"scheduler.work_queue", "pgvigil_scheduler_work_queue", "", "count"},
	{"scheduler.pending_io", "pgvigil_scheduler_pending_io", "", "count"},
	{"scheduler.active_workers", "pgvigil_scheduler_active_workers", "", "count"},
	{"scheduler.current_workers", "pgvigil_scheduler_current_workers", "", "count"},
	{"memory.ple", "pgvigil_memory_page_life_expectancy_seconds", "", "secs"},
	{"memory.grants_pending", "pgvigil_memory_grants_pending", "", "count"},
	{"memory.grants_outstanding", "pgvigil_memory_grants_outstanding", "", "count"},
	{"memory.total_mb", "pgvigil_memory_total_bytes", "", "mb"},
	{"memory.target_mb", "pgvigil_memory_target_bytes", "", "mb"},
	{"memory.buffer_pool_mb", "pgvigil_memory_buffer_pool_bytes", "", "mb"},
	{"memory.plan_cache_mb", "pgvigil_memory_plan_cache_bytes", "", "mb"},
	{"memory.stolen_mb", "pgvigil_memory_stolen_bytes", "", "mb"},
	{"memory.available_mb", "pgvigil_memory_available_bytes", "", "mb"},
	{"memory.os_used_pct", "pgvigil_memory_os_used_ratio", "", "pct"},
	{"host.cpu_pct", "pgvigil_host_cpu_ratio", "", "pct"},
	{"host.cpu_iowait_pct", "pgvigil_host_cpu_iowait_ratio", "", "pct"},
	{"host.mem_used_pct", "pgvigil_host_memory_used_ratio", "", "pct"},
	{"host.mem_free", "pgvigil_host_memory_free_bytes", "", "bytes"},
	{"host.swap_used", "pgvigil_host_swap_used_bytes", "", "bytes"},
	{"host.load1", "pgvigil_host_load1", "", "count"},
}

// promUnitWords is a HELP line's account of the conversion from the Metrics grid's unit.
var promUnitWords = map[string]string{
	"count": "", "xids": " (a count of transaction ids)", "secs": " in seconds", "per_s": " per second",
	"bytes_per_s": " in bytes per second", "bytes": " in bytes", "pct": " as a ratio (the grid's percent / 100)",
	"ms": " in seconds (the grid's milliseconds / 1000)", "mb": " in bytes (the grid's MB x 1048576)",
	"interval": " per second (the grid's count per collection interval / the interval's seconds)",
}

// promValue converts a grid value; ok false = no value to give (an interval count without its interval, NaN, Inf).
func promValue(unit string, v float64, secs *int32) (float64, bool) {
	switch unit {
	case "pct":
		v /= 100
	case "ms":
		v /= 1000
	case "mb":
		v *= 1048576
	case "interval":
		if secs == nil || *secs <= 0 {
			return 0, false
		}
		v /= float64(*secs)
	}
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, false
	}
	return v, true
}

// promEscape escapes a label value: backslash, double quote and line feed.
func promEscape(v string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(v)
}

func promFloat(v float64) string { return strconv.FormatFloat(v, 'g', -1, 64) }

// promBody collects the samples of each name, then writes them metric-first: one HELP and one TYPE per name, every
// sample of a name together, in the order the names were first declared.
type promBody struct {
	order   []string
	help    map[string]string
	typ     map[string]string
	samples map[string][]string
	n       int
}

func (b *promBody) declare(name, typ, help string) {
	if b.help == nil {
		b.help, b.typ, b.samples = map[string]string{}, map[string]string{}, map[string][]string{}
	}
	if _, ok := b.help[name]; ok {
		return
	}
	b.order = append(b.order, name)
	b.help[name], b.typ[name] = help, typ
}

func (b *promBody) add(name string, labels [][2]string, v float64) {
	var sb strings.Builder
	sb.WriteString(name)
	if len(labels) > 0 {
		sb.WriteByte('{')
		for i, l := range labels {
			if i > 0 {
				sb.WriteByte(',')
			}
			sb.WriteString(l[0])
			sb.WriteString(`="`)
			sb.WriteString(promEscape(l[1]))
			sb.WriteByte('"')
		}
		sb.WriteByte('}')
	}
	sb.WriteByte(' ')
	sb.WriteString(promFloat(v))
	b.samples[name] = append(b.samples[name], sb.String())
	b.n++
}

func (b *promBody) bytes() []byte {
	var out bytes.Buffer
	for _, name := range b.order {
		if len(b.samples[name]) == 0 {
			continue
		}
		fmt.Fprintf(&out, "# HELP %s %s\n# TYPE %s %s\n", name, strings.ReplaceAll(strings.ReplaceAll(b.help[name], `\`, `\\`), "\n", `\n`), name, b.typ[name])
		for _, l := range b.samples[name] {
			out.WriteString(l)
			out.WriteByte('\n')
		}
	}
	return out.Bytes()
}

// promLookback is one instance's rate lookback, rateLookback's rule (web.go) over its three rate collections: 3 x the
// longest of its dbstats, serverstats and iostats intervals (its own where pgvigil.yaml sets one, else the default),
// 900 s at least. One instance's long cadence widens its own read only: the render groups the instances by lookback.
func (s *Server) promLookback(name string) time.Duration {
	secs := 0
	for _, c := range []string{"dbstats", "serverstats", "iostats"} {
		v := s.expected.Defaults[c]
		if o, ok := s.expected.Instances[name][c]; ok && o > 0 {
			v = o
		}
		if v > secs {
			secs = v
		}
	}
	lb := 3 * secs
	if lb < 900 {
		lb = 900
	}
	return time.Duration(lb) * time.Second
}

// promInst is an active instance as the body labels it.
type promInst struct{ name, engine string }

// renderMetrics reads every figure and writes the body.
func (s *Server) renderMetrics(ctx context.Context, st *promState) ([]byte, error) {
	t0 := time.Now()
	insts := map[int32]promInst{}
	var b promBody
	b.declare("pgvigil_instance_info", "gauge", "An active instance pgvigil collects from (1); labels server, engine, platform, version"+map[bool]string{true: ", tags (sorted, comma-wrapped)", false: ""}[st.cfg.Tags]+".")
	rows, err := s.pool.Query(ctx, `SELECT i.instance_id, i.name, i.engine, coalesce(i.platform, ''), coalesce(i.server_version, ''), coalesce(t.tags, '{}'::text[])
	                                  FROM pgvigil.instances i LEFT JOIN pgvigil.instance_tags_merged t USING (instance_id)
	                                 WHERE i.is_active ORDER BY i.name`)
	if err != nil {
		return nil, fmt.Errorf("instances: %w", err)
	}
	for rows.Next() {
		var id int32
		var name, engine, platform, version string
		var tags []string
		if err := rows.Scan(&id, &name, &engine, &platform, &version, &tags); err != nil {
			rows.Close()
			return nil, fmt.Errorf("instances: %w", err)
		}
		insts[id] = promInst{name, engine}
		l := [][2]string{{"server", name}, {"engine", engine}, {"platform", platform}, {"version", version}}
		if st.cfg.Tags {
			sort.Strings(tags)
			l = append(l, [2]string{"tags", "," + strings.Join(tags, ",") + ","})
		}
		b.add("pgvigil_instance_info", l, 1)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("instances: %w", err)
	}
	// the catalog's names first, in the table's order, then the per-database ones
	byKey := map[string]promName{}
	for _, p := range promNames {
		byKey[p.key] = p
		b.declare(p.name, "gauge", "pgvigil's metric "+p.key+promUnitWords[p.unit]+"; the newest collected value, left out when older than its freshness.")
	}
	for _, p := range promNames {
		if p.dbName != "" {
			b.declare(p.dbName, "gauge", "pgvigil's metric "+p.key+" of one database"+promUnitWords[p.unit]+" (metrics.databases: on).")
		}
	}
	b.declare("pgvigil_metrics_databases_cut", "gauge", "The databases of an instance left out of the per-database series (metrics.max_databases).")
	include := st.cfg.IncludeDatabases
	if len(include) == 0 {
		include = nil // an empty list is no list: the databases go by size
	}
	// one statement per lookback (most installs: one), its instances' ids in it
	groups := map[time.Duration][]int32{}
	for id, in := range insts {
		lb := s.promLookback(in.name)
		groups[lb] = append(groups[lb], id)
	}
	for lb, ids := range groups {
		if err := s.promNewest(ctx, &b, insts, byKey, ids, lb, st.cfg, include); err != nil {
			return nil, err
		}
	}
	b.declare("pgvigil_sample_timestamp_seconds", "gauge", "The Unix time of an instance's newest sample of a metric family, fresh or stale, no age bound (alert on time() - this).")
	rows, err = s.pool.Query(ctx, `SELECT instance_id, family, extract(epoch FROM at)::float8 FROM pgvigil.metrics_sample_times(NULL) ORDER BY 1, 2`)
	if err != nil {
		return nil, fmt.Errorf("metrics_sample_times: %w", err)
	}
	for rows.Next() {
		var id int32
		var family string
		var at float64
		if err := rows.Scan(&id, &family, &at); err != nil {
			rows.Close()
			return nil, fmt.Errorf("metrics_sample_times: %w", err)
		}
		if in, ok := insts[id]; ok {
			b.add("pgvigil_sample_timestamp_seconds", [][2]string{{"server", in.name}, {"family", family}}, at)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("metrics_sample_times: %w", err)
	}
	// findings: alert_findings (the setting rules' findings and the alert rules') of each active instance by severity,
	// acknowledged and muted ones counted (the Findings page's list before its own filters), the repository-wide ones
	// (no instance) left out; every severity of the fixed set given, 0 included
	b.declare("pgvigil_findings", "gauge", "The findings of an instance by severity (info, warning, critical): the setting rules' and the alert rules', acknowledged and muted ones included.")
	counts := map[int32]map[string]float64{}
	rows, err = s.pool.Query(ctx, `SELECT f.instance_id, f.severity, count(*)::float8 FROM pgvigil.alert_findings f
	                                WHERE f.instance_id IS NOT NULL GROUP BY 1, 2`)
	if err != nil {
		return nil, fmt.Errorf("findings: %w", err)
	}
	for rows.Next() {
		var id int32
		var sev string
		var n float64
		if err := rows.Scan(&id, &sev, &n); err != nil {
			rows.Close()
			return nil, fmt.Errorf("findings: %w", err)
		}
		if counts[id] == nil {
			counts[id] = map[string]float64{}
		}
		counts[id][sev] += n
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("findings: %w", err)
	}
	ids := make([]int32, 0, len(insts))
	for id := range insts {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return insts[ids[i]].name < insts[ids[j]].name })
	for _, id := range ids {
		for _, sev := range []string{"info", "warning", "critical"} {
			b.add("pgvigil_findings", [][2]string{{"server", insts[id].name}, {"severity", sev}}, counts[id][sev])
		}
	}
	// the endpoint's own: as of this render
	b.declare("pgvigil_metrics_series", "gauge", "The series of this body (pgvigil's own lines excluded).")
	b.declare("pgvigil_metrics_render_seconds", "gauge", "How long this body's render took.")
	b.declare("pgvigil_metrics_last_render_timestamp_seconds", "gauge", "The Unix time this body was rendered.")
	b.declare("pgvigil_metrics_refused_total", "counter", "Requests to /metrics refused since serve started (no credentials, a wrong or empty token, a token in the URL, the limiter), as of this render.")
	series := b.n
	b.add("pgvigil_metrics_series", nil, float64(series))
	b.add("pgvigil_metrics_render_seconds", nil, time.Since(t0).Seconds())
	b.add("pgvigil_metrics_last_render_timestamp_seconds", nil, float64(time.Now().UnixMilli())/1000)
	b.add("pgvigil_metrics_refused_total", nil, float64(st.refused.Load()))
	st.mu.Lock()
	st.series = series
	st.mu.Unlock()
	return b.bytes(), nil
}

// promNewest reads metrics_newest for one group of instances (one lookback) into the body.
func (s *Server) promNewest(ctx context.Context, b *promBody, insts map[int32]promInst, byKey map[string]promName, ids []int32,
	lb time.Duration, cfg *MetricsConfig, include []string) error {
	rows, err := s.pool.Query(ctx, `SELECT instance_id, family, metric, database, value, secs FROM pgvigil.metrics_newest($1::int[], $2, $3, $4, $5)`,
		ids, lb, cfg.Databases, cfg.maxDatabases(), include)
	if err != nil {
		return fmt.Errorf("metrics_newest: %w", err)
	}
	for rows.Next() {
		var id int32
		var family, metric string
		var database *string
		var value float64
		var secs *int32
		if err := rows.Scan(&id, &family, &metric, &database, &value, &secs); err != nil {
			rows.Close()
			return fmt.Errorf("metrics_newest: %w", err)
		}
		in, ok := insts[id]
		if !ok {
			continue
		}
		if family == "database" && metric == "cut" {
			b.add("pgvigil_metrics_databases_cut", [][2]string{{"server", in.name}}, value)
			continue
		}
		p, ok := byKey[family+"."+metric]
		if !ok {
			continue // a key the table does not name: the test fails on it, the endpoint stays up
		}
		v, ok := promValue(p.unit, value, secs)
		if !ok {
			continue
		}
		if database != nil {
			if p.dbName != "" {
				b.add(p.dbName, [][2]string{{"server", in.name}, {"engine", in.engine}, {"database", *database}}, v)
			}
			continue
		}
		b.add(p.name, [][2]string{{"server", in.name}, {"engine", in.engine}}, v)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("metrics_newest: %w", err)
	}
	return nil
}
