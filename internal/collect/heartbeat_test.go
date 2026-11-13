package collect

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type msErr struct{ n int32 }

func (e msErr) Error() string         { return fmt.Sprintf("mssql: %d", e.n) }
func (e msErr) SQLErrorNumber() int32 { return e.n }

func TestAuthFailure(t *testing.T) {
	for _, c := range []struct {
		err  error
		want bool
	}{
		{&pgconn.PgError{Code: "28P01"}, true},
		{fmt.Errorf("connect: %w", &pgconn.PgError{Code: "28000"}), true},
		{&pgconn.PgError{Code: "57014"}, false},
		{msErr{18456}, true},
		{fmt.Errorf("login: %w", msErr{18456}), true},
		{msErr{4060}, false},
		{errors.New("dial tcp: connection refused"), false},
		{nil, false},
	} {
		if got := AuthFailure(c.err); got != c.want {
			t.Errorf("AuthFailure(%v) = %v, want %v", c.err, got, c.want)
		}
	}
}

func TestBucket(t *testing.T) {
	for d, want := range map[time.Duration]int{0: 0, 500 * time.Microsecond: 0, time.Millisecond: 1, 3 * time.Millisecond: 2,
		4 * time.Millisecond: 3, time.Second: 10, 200 * time.Second: histBuckets - 1} {
		if got := bucket(d); got != want {
			t.Errorf("bucket(%v) = %d, want %d", d, got, want)
		}
	}
}

// TestRecordTake: a minute's runs per collection and per instance (a skipped run not counted), the connects counted
// at the connect (an opened one, a refused login, a per-database connect), the failed runs in a row kept across takes
// and sent when they change.
func TestRecordTake(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	current.Store(h)
	defer current.Store(nil)
	now := time.Now()
	CountConnect("t1", nil)
	h.record("t1", "postgres", "activity", Result{Rows: 5, Duration: 3 * time.Millisecond}, now, 0)
	CountConnect("t1", fmt.Errorf("connect t1: %w", &pgconn.PgError{Code: "28P01"}))
	h.record("t1", "postgres", "activity", Result{Duration: 20 * time.Millisecond, Err: errors.New("connect t1: refused")}, now, 0)
	CountConnect("t1", nil)                            // the run of tables
	CountConnect("t1", &pgconn.PgError{Code: "28000"}) // its per-database connect refused by pg_hba
	h.record("t1", "postgres", "logs", Result{Note: " (skipped: no log door)"}, now, 0)
	CountConnect("t2", nil)
	h.record("t2", "sqlserver", "activity", Result{Rows: 2, Duration: time.Millisecond}, now, 0)
	b := h.take()
	if len(b.Runs) != 2 || len(b.Load) != 2 || b.Instances != 2 {
		t.Fatalf("take: runs %d, load %d, instances %d", len(b.Runs), len(b.Load), b.Instances)
	}
	for _, r := range b.Runs {
		if r.Engine == "postgres" && (r.Runs != 2 || r.Failures != 1 || r.Rows != 5 || r.DurMax != 20 || r.Hist[2] != 1 || r.Hist[5] != 1) {
			t.Errorf("postgres activity: %+v", r)
		}
	}
	for _, l := range b.Load {
		if l.Instance == "t1" && (l.Attempts != 4 || l.Opened != 2 || l.Auth != 2 || l.Runs != 2 || l.Failures != 1) {
			t.Errorf("t1 load: %+v", l)
		}
		if l.Instance == "t2" && (l.Attempts != 1 || l.Opened != 1 || l.Auth != 0 || l.Runs != 1) {
			t.Errorf("t2 load: %+v", l)
		}
	}
	// t1's failure, and t2's first result since the start (fresh: sent once, 0)
	sk := map[string]int{}
	for _, x := range b.Streaks {
		sk[x.Instance] = x.Fails
	}
	if len(b.Streaks) != 2 || sk["t1"] != 1 || sk["t2"] != 0 {
		t.Errorf("streaks: %+v", b.Streaks)
	}
	// the next minute: nothing new, nothing sent; a success after the failure resets and is sent once
	if b2 := h.take(); len(b2.Runs) != 0 || len(b2.Streaks) != 0 || len(b2.Load) != 0 {
		t.Errorf("an empty minute sent %+v", b2)
	}
	h.record("t1", "postgres", "activity", Result{Rows: 1}, now, 0)
	if b3 := h.take(); len(b3.Streaks) != 1 || b3.Streaks[0].Fails != 0 {
		t.Errorf("the reset: %+v", b3.Streaks)
	}
	h.record("t1", "postgres", "activity", Result{Rows: 1}, now, 0)
	if b4 := h.take(); len(b4.Streaks) != 0 {
		t.Errorf("a success after a success was sent: %+v", b4.Streaks)
	}
}

// TestNoHeartbeat: without StartHeartbeat (pgvigil collect, a test) counting is a no-op.
func TestNoHeartbeat(_ *testing.T) {
	current.Store(nil)
	CountConnect("t1", nil)
	RecordRun("t1", "postgres", "activity", Result{})
}

// TestStreakAfterRestart: a streak loaded from the repository (5 failed in a row before a restart) - the first success
// after the start resets it and is sent; a first failure counts on from 5.
func TestStreakAfterRestart(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{
		{"t1", "activity"}: {fails: 5, fresh: true}, {"t1", "dbstats"}: {fails: 5, fresh: true}}}
	now := time.Now()
	h.record("t1", "postgres", "activity", Result{Rows: 1}, now, 0)
	h.record("t1", "postgres", "dbstats", Result{Err: errors.New("down")}, now, 0)
	h.record("t2", "postgres", "activity", Result{Rows: 1}, now, 0) // never failed: its first result is sent once (0)
	got := map[string]int{}
	for _, s := range h.take().Streaks {
		got[s.Instance+"/"+s.Collection] = s.Fails
	}
	if len(got) != 3 || got["t1/activity"] != 0 || got["t1/dbstats"] != 6 || got["t2/activity"] != 0 {
		t.Errorf("after the restart: %v", got)
	}
	h.record("t2", "postgres", "activity", Result{Rows: 1}, now, 0)
	if b := h.take(); len(b.Streaks) != 0 {
		t.Errorf("a second success was sent: %+v", b.Streaks)
	}
}

// TestEmptyBeatJSON: a minute with nothing in it encodes its lists as [] (never null: the SQL reads them as arrays).
func TestEmptyBeatJSON(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	body, err := json.Marshal(h.take())
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{`"runs":[]`, `"load":[]`, `"streaks":[]`} {
		if !strings.Contains(string(body), k) {
			t.Errorf("%s not in %s", k, body)
		}
	}
}

// TestStopCutRun: a run the stop cut short (context.Canceled, wrapped) is no failure: not counted, no streak.
func TestStopCutRun(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	now := time.Now()
	h.record("t1", "postgres", "activity", Result{Err: fmt.Errorf("activity t1: %w", context.Canceled)}, now, 0)
	if b := h.take(); len(b.Runs) != 0 || len(b.Load) != 0 || len(b.Streaks) != 0 {
		t.Fatalf("a cut run was counted: runs %d, load %d, streaks %d", len(b.Runs), len(b.Load), len(b.Streaks))
	}
	h.record("t1", "postgres", "activity", Result{Err: fmt.Errorf("activity t1: %w", context.DeadlineExceeded)}, now, 0)
	if b := h.take(); len(b.Runs) != 1 || b.Runs[0].Failures != 1 {
		t.Errorf("a timeout is a failure: %+v", b.Runs)
	}
}

// TestSkipEndsStreak: a skipped run after failures (the login refused, then a collection that skips on this target)
// ends the streak, a stored one too, and is not counted as a run; a skip with no failing streak writes nothing.
func TestSkipEndsStreak(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{
		{"t2", "host"}: {fails: 7, lastErr: "refused", fresh: true}}}
	now := time.Now()
	skip := Result{Note: " (skipped: no system_stats)"}
	h.record("t2", "postgres", "host", skip, now, 0)
	h.record("t2", "postgres", "jobs", Result{Err: errors.New("connect t2: refused")}, now, 0)
	h.record("t2", "postgres", "jobs", skip, now, 0)
	h.record("t1", "postgres", "host", skip, now, 0)
	b := h.take()
	got := map[string]int{}
	for _, s := range b.Streaks {
		got[s.Instance+"/"+s.Collection] = s.Fails
	}
	if len(got) != 2 || got["t2/host"] != 0 || got["t2/jobs"] != 0 {
		t.Errorf("streaks after the skips: %v", got)
	}
	if len(b.Runs) != 1 || b.Runs[0].Runs != 1 || b.Runs[0].Failures != 1 {
		t.Errorf("a skip was counted as a run: %+v", b.Runs)
	}
}

// TestConnectFailNoStreak: a run that failed at the instance's own connect (InstanceConnect) is counted in the load
// and the collection's runs (the parent's test reads them) but builds no per-collection streak: one refused login is
// one 'authentication failing', never a 'collection failing' per collection. A failure after the connect still does.
func TestConnectFailNoStreak(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	now := time.Now()
	refused := &pgconn.PgError{Code: "28P01", Message: "password authentication failed"}
	for _, c := range []string{"activity", "jobs", "host", "waits"} {
		err := h.instanceConnect("t2", refused, now)
		h.record("t2", "postgres", c, Result{Err: fmt.Errorf("connect t2: %w", err)}, now, 0)
	}
	h.record("t1", "postgres", "activity", Result{Err: errors.New("activity on t1: relation missing")}, now, 0)
	b := h.take()
	got := map[string]int{}
	for _, s := range b.Streaks {
		got[s.Instance+"/"+s.Collection] = s.Fails
	}
	if len(got) != 2 || got["t2/"+connectStreak] != 0 || got["t1/activity"] != 1 {
		t.Errorf("streaks: %v (want t2's connect streak at 0 - refused = the server answered - and t1/activity 1)", got)
	}
	var l2 *beatLoad
	for i := range b.Load {
		if b.Load[i].Instance == "t2" {
			l2 = &b.Load[i]
		}
	}
	if l2 == nil || l2.Runs != 4 || l2.Failures != 4 || l2.Auth != 4 || l2.Attempts != 4 || l2.Opened != 0 {
		t.Errorf("t2's load: %+v (want 4 runs, 4 failures, 4 attempts, 4 refused, 0 opened)", l2)
	}
	if !AuthFailure(fmt.Errorf("connect t2: %w", h.instanceConnect("t2", refused, now))) {
		t.Error("the marked error hides the PgError from errors.As")
	}
}

// TestConnectStreak: the instance's own connect streak - a network failure adds one, an opened or a refused connect
// ends it, a stop's cancel touches nothing; per-database connects (CountConnect) never touch it.
func TestConnectStreak(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	now := time.Now()
	dial := errors.New("dial tcp 10.0.0.9:5432: connect: connection timed out")
	fails := func() int { return h.streaks[[2]string{"t3", connectStreak}].fails }
	for range 3 {
		_ = h.instanceConnect("t3", dial, now)
	}
	_ = h.instanceConnect("t3", fmt.Errorf("connect: %w", context.Canceled), now)
	h.countConnect("t3", errors.New("per-database connect refused"))
	if fails() != 3 {
		t.Fatalf("after 3 timeouts, a cancel and a per-database failure: %d (want 3)", fails())
	}
	if InstanceConnect("t3", nil) != nil {
		t.Error("InstanceConnect(nil) is not nil")
	}
	_ = h.instanceConnect("t3", nil, now)
	if fails() != 0 {
		t.Errorf("an opened connect left the streak at %d", fails())
	}
	_ = h.instanceConnect("t3", dial, now)
	_ = h.instanceConnect("t3", &pgconn.PgError{Code: "28000"}, now)
	if fails() != 0 {
		t.Errorf("a refused login (the server answered) left the streak at %d", fails())
	}
}

// TestStreakSince: a streak carries its FIRST failure's time (the beat's 'since'), kept across beats until it ends;
// a stop-cut instance connect counts as no attempt.
func TestStreakSince(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	t0 := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	boom := Result{Err: errors.New("waits on t1: boom")}
	h.record("t1", "postgres", "waits", boom, t0, 0)
	if b := h.take(); len(b.Streaks) != 1 || b.Streaks[0].Since == nil || !b.Streaks[0].Since.Equal(t0) {
		t.Fatalf("first beat: %+v (want since %s)", b.Streaks, t0)
	}
	h.record("t1", "postgres", "waits", boom, t0.Add(30*time.Second), 0)
	h.record("t1", "postgres", "waits", boom, t0.Add(70*time.Second), 0)
	b := h.take()
	if len(b.Streaks) != 1 || b.Streaks[0].Fails != 3 || b.Streaks[0].Since == nil || !b.Streaks[0].Since.Equal(t0) {
		t.Errorf("second beat: %+v (want 3 fails since %s)", b.Streaks, t0)
	}
	h.record("t1", "postgres", "waits", Result{Rows: 1}, t0.Add(90*time.Second), 0)
	if b := h.take(); len(b.Streaks) != 1 || b.Streaks[0].Fails != 0 || b.Streaks[0].Since != nil {
		t.Errorf("after a success: %+v (want 0 fails, no since)", b.Streaks)
	}
	_ = h.instanceConnect("t9", fmt.Errorf("connect: %w", context.Canceled), t0)
	if l := h.load["t9"]; l != nil && l.attempts != 0 {
		t.Errorf("a stop-cut connect counted as an attempt: %+v", l)
	}
}

// TestChannelBackoff: serve's watchdog pass backs a failing channel off as the collector's own alert loop does
// (alerts.Run): 1, 2, 4, 8, 16 minutes, then 30 at most; a channel that succeeds is tried every pass again.
func TestChannelBackoff(t *testing.T) {
	var b ChannelBackoff
	t0 := time.Date(2026, 11, 12, 10, 0, 0, 0, time.UTC)
	if n := len(b.Skip(t0)); n != 0 {
		t.Fatalf("a fresh backoff skips %d channel(s), want 0", n)
	}
	bad := map[string]error{"hook": errors.New("503"), "mail": nil}
	at := t0
	for i, want := range []time.Duration{time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 16 * time.Minute, 30 * time.Minute, 30 * time.Minute} {
		b.Note(at, bad)
		if s := b.Skip(at.Add(want - time.Second)); !s["hook"] || s["mail"] {
			t.Fatalf("failure %d: %v before its wait of %v ends the skip map is %v, want hook only", i+1, time.Second, want, s)
		}
		if s := b.Skip(at.Add(want)); s["hook"] {
			t.Fatalf("failure %d: hook is still skipped after its wait of %v", i+1, want)
		}
		at = at.Add(want)
	}
	b.Note(at, map[string]error{"hook": nil})
	if s := b.Skip(at.Add(time.Second)); len(s) != 0 {
		t.Fatalf("after a success the skip map is %v, want empty", s)
	}
	b.Note(at, map[string]error{"hook": errors.New("503")})
	if s := b.Skip(at.Add(61 * time.Second)); s["hook"] {
		t.Fatal("a failure after a success waits 1 minute again, not the old wait")
	}
}

// TestSeenDue: the heartbeat names an instance in the repository at its first connect in a run and again when its name
// was not written for seenEvery (an instance read once an hour), never at every connect; a write that failed is due
// again at the next connect; a beat names what it loads, so an instance read every minute is never due between beats.
func TestSeenDue(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	t0 := time.Date(2026, 11, 12, 10, 0, 0, 0, time.UTC)
	if !h.seenDue("t1", t0) {
		t.Fatal("the first connect of an instance in a run must name it")
	}
	if h.seenDue("t1", t0.Add(seenEvery-time.Second)) {
		t.Fatal("named again before seenEvery passed")
	}
	if !h.seenDue("t2", t0.Add(time.Second)) {
		t.Fatal("another instance's first connect must name it")
	}
	if !h.seenDue("t1", t0.Add(seenEvery)) {
		t.Fatal("not named again after seenEvery")
	}
	h.seenFailed("t1")
	if !h.seenDue("t1", t0.Add(seenEvery+time.Second)) {
		t.Fatal("a failed write must be due again at the next connect")
	}
	// the beat names what it loads
	h.loadOf("t3")
	h.take()
	if h.seenDue("t3", time.Now().Add(time.Minute)) {
		t.Fatal("an instance the beat just named is due again a minute later")
	}
}

// TestWatchdogStarting: serve says 'starting' from the moment it decides to run the watchdog until the alerts login and
// the repository answered (up to 40 s) - the Collector page says so instead of 'not this process' (task 201 DONE-2,
// the review of the merges' finding 2); the goroutine then moves it on to 'on' or 'off: <why>'.
func TestWatchdogStarting(t *testing.T) {
	defer watchdog.Store("")
	SetWatchdogStarting()
	if got := WatchdogStatus(); got != "starting" {
		t.Fatalf("after SetWatchdogStarting the status is %q, want 'starting'", got)
	}
	SetWatchdogOff("the alerts login: no answer")
	if got := WatchdogStatus(); got != "off: the alerts login: no answer" {
		t.Fatalf("after SetWatchdogOff the status is %q", got)
	}
}

// TestRecordInterval (task 201 DONE-2 N3): an instance's minute carries the fastest configured interval of the runs it
// counted - the span's input (0121 collector_span_take); a run recorded without one (RecordRun) never lowers a known
// one, and an instance with none sends no interval_s at all (the repository keeps NULL: unknown, not 0).
func TestRecordInterval(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	current.Store(h)
	defer current.Store(nil)
	RecordRunEvery("t1", "postgres", "activity", Result{Rows: 1}, 5*time.Minute)
	RecordRunEvery("t1", "postgres", "waits", Result{Rows: 1}, time.Minute)
	RecordRun("t1", "postgres", "tables", Result{Rows: 1})
	RecordRunEvery("t2", "postgres", "indexes", Result{Err: errors.New("boom")}, 5*time.Minute)
	RecordRun("t3", "postgres", "activity", Result{Rows: 1})
	RecordRunEvery("t4", "postgres", "logs", Result{Note: " (skipped: no log door)"}, time.Minute)
	got := map[string]int{}
	for _, l := range h.take().Load {
		got[l.Instance] = l.IntervalS
	}
	if len(got) != 3 || got["t1"] != 60 || got["t2"] != 300 || got["t3"] != 0 {
		t.Errorf("intervals: %v (want t1 60, t2 300, t3 0; t4's skip counts no run)", got)
	}
	body, err := json.Marshal(beatLoad{Instance: "t3"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), "interval_s") {
		t.Errorf("an unknown interval was sent: %s", body)
	}
	if b2 := h.take(); len(b2.Load) != 0 {
		t.Errorf("the next minute kept a load row: %+v", b2.Load)
	}
}

// TestConnectTimeoutDefault (task 201 DONE-2, N10): an instance connect whose DSN sets no connect_timeout ends in about
// DefaultConnectTimeout at a server that accepts and never answers (the startup hangs, as at a black-holed address
// after its SYN), through both connect paths (the instance's own Connect, a collection's connectCounted), and is
// counted as one failed attempt each - never a run held to its context.
func TestConnectTimeoutDefault(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	var mu sync.Mutex
	var held []net.Conn
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			held = append(held, c) // accepted and never answered
			mu.Unlock()
		}
	}()
	defer func() {
		mu.Lock()
		for _, c := range held {
			_ = c.Close()
		}
		mu.Unlock()
	}()
	old := DefaultConnectTimeout
	DefaultConnectTimeout = 300 * time.Millisecond
	defer func() { DefaultConnectTimeout = old }()
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	current.Store(h)
	defer current.Store(nil)
	dsn := fmt.Sprintf("host=127.0.0.1 port=%d user=x dbname=x sslmode=disable", ln.Addr().(*net.TCPAddr).Port)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	start := time.Now()
	if c, err := Connect(ctx, config.Instance{Name: "bh1", DSNRaw: dsn}); err == nil {
		_ = c.Close(ctx)
		t.Fatal("Connect: connected to a server that never answers")
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("Connect ended after %v (want about %v)", d.Round(time.Millisecond), DefaultConnectTimeout)
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	start = time.Now()
	if c, err := connectCounted(ctx, "bh2", cfg); err == nil {
		_ = c.Close(ctx)
		t.Fatal("connectCounted: connected to a server that never answers")
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("connectCounted ended after %v (want about %v)", d.Round(time.Millisecond), DefaultConnectTimeout)
	}
	for _, n := range []string{"bh1", "bh2"} {
		if l := h.load[n]; l == nil || l.attempts != 1 || l.opened != 0 || l.auth != 0 {
			t.Errorf("%s counted %+v (want 1 attempt, none opened, no refused login)", n, l)
		}
	}
}

// TestConnectTimeoutKept (N10): a DSN's own connect_timeout is kept; none gets DefaultConnectTimeout.
func TestConnectTimeoutKept(t *testing.T) {
	for dsn, want := range map[string]time.Duration{
		"host=127.0.0.1 port=1 user=x connect_timeout=3":  3 * time.Second,
		"host=127.0.0.1 port=1 user=x connect_timeout=60": 60 * time.Second,
		"host=127.0.0.1 port=1 user=x":                    DefaultConnectTimeout,
		"host=127.0.0.1 port=1 user=x connect_timeout=0":  DefaultConnectTimeout, // pgx parses 0 as none set (libpq: wait for ever)
	} {
		cfg, err := pgx.ParseConfig(dsn)
		if err != nil {
			t.Fatal(err)
		}
		withConnectTimeout(cfg)
		if cfg.ConnectTimeout != want {
			t.Errorf("%q: %v (want %v)", dsn, cfg.ConnectTimeout, want)
		}
	}
}
