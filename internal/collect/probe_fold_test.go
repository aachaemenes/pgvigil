package collect

import (
	"context"
	"net"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// The B24h-1 review's collector rows (notes/teams/pdfp-visual-s1-reviewb24h1-a-fallback.md; the lead's 12:4x calls).

// #a1: an opened connection is a TCP answer - an address a connection opened to is 'answered' from then on, so when its
// host goes down the default mode's first probe (answered 0) is no 'never answered' and the next failure probes it
// again a minute later, not 15 minutes later; and the beat carries the opened addresses (the repository's half)
func TestProbeOpenedIsAnswered(t *testing.T) {
	p := newProber("tcp", false)
	p.dial = func(ctx context.Context, addr string) error { <-ctx.Done(); return ctx.Err() } // black-holed: no answer within the wait
	p.connectMax = 20 * time.Millisecond
	p.noteRemote("i1", "db1", "10.1.2.3:5432")
	if !p.answered["10.1.2.3:5432"] {
		t.Fatalf("an opened connection: answered %v, want the address answered", p.answered)
	}
	t0 := time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	p.noteFailed("i1")
	p.round(context.Background(), t0)
	p.noteFailed("i1")
	p.round(context.Background(), t0.Add(time.Minute))
	rows := p.take()
	if len(rows) != 2 || rows[0].Answered == nil || *rows[0].Answered != 0 || rows[1].Answered == nil || *rows[1].Answered != 0 {
		t.Fatalf("two failed minutes of a host that answered a connection: %d probe row(s) %+v, want 2, each answered 0", len(rows), rows)
	}
	op := p.takeOpened()
	if len(op) != 1 || op[0].Address != "10.1.2.3:5432" || op[0].Host != "db1" || op[0].At.IsZero() {
		t.Errorf("the opened addresses for the beat: %+v, want one 10.1.2.3:5432 under db1 with its time", op)
	}
	if again := p.takeOpened(); len(again) != 0 {
		t.Errorf("the opened addresses are handed once: %+v left", again)
	}
}

// #a3: the default mode probes after a connect that failed or got no answer - never after a query the server refused
// on a connection that opened (a missing grant would probe every minute: the default's IDS concern)
func TestProbeOnlyAfterNoAnswer(t *testing.T) {
	for name, c := range map[string]struct {
		err  error
		want bool
	}{
		"a deadline (no answer)": {context.DeadlineExceeded, true},
		// the review of the fold #2: a refused dial is a *net.OpError (a net.Error), as pgconn and net.Dialer return it
		"the instance's own connect, refused": {&connectError{err: &net.OpError{Op: "dial", Net: "tcp", Err: syscall.ECONNREFUSED}}, true},
		"42501 on an opened connection":       {&pgconn.PgError{Code: "42501", Message: "permission denied for table x"}, false},
		"a SQL Server error the host sent":    {sqlNumbered(229), false},
		// the review of the fold #2: a login the server refused at the connect is an answer - no probe every minute
		"28P01 at the connect": {&connectError{err: &pgconn.PgError{Code: "28P01", Message: "password authentication failed"}}, false},
		"18456 at the connect": {&connectError{err: sqlNumbered(18456)}, false},
	} {
		h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}, probe: newProber("tcp", false)}
		h.targets = map[string]string{"i1": "postgres:db1:5432"}
		h.noteRemote("i1", "10.1.2.3:5432")
		h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond, Err: c.err}, time.Now(), time.Minute)
		if got := h.probe.due["10.1.2.3:5432"]; got != c.want {
			t.Errorf("%s: due %v, want %v", name, got, c.want)
		}
	}
}

// the review of the fold #8: an opened connection is an answer of the TCP method only - an icmp prober records no opened
// address (B24h-2's ICMP: an endpoint that never answers echo would read answered from its connections)
func TestProbeOpenedTCPOnly(t *testing.T) {
	p := newProber("icmp", false)
	p.noteRemote("i1", "db1", "10.1.2.3:5432")
	if n := len(p.takeOpened()); n != 0 {
		t.Errorf("an icmp prober's opened connection: %d opened, want 0", n)
	}
	if p.addrOf["i1"] != "10.1.2.3:5432" {
		t.Errorf("an icmp prober still keeps the instance's address: %q", p.addrOf["i1"])
	}
}

type sqlNumbered int32

func (e sqlNumbered) Error() string         { return "mssql: the SELECT permission was denied" }
func (e sqlNumbered) SQLErrorNumber() int32 { return int32(e) }

// #a4: an IPv6 literal's host as the repository's collector_target_host cuts it (a trailing ':port' off), the form
// PgTarget writes ('postgres:' + pgx's bracketless host + ':' + port); a SQL Server named instance's host without its
// instance name (#b6's Go half: 'mssql:sql01\a:0' -> 'sql01')
func TestTargetHostFold(t *testing.T) {
	for in, want := range map[string]string{
		"postgres:2001:db8::1:5432": "2001:db8::1", "postgres:fd00::10:5432": "fd00::10", "postgres:db1:5432": "db1",
		"mssql:fd00::20:1433": "fd00::20", `mssql:sql01\a:0`: "sql01", `mssql:sql01.corp\INST2:0`: "sql01.corp",
		"postgres:db1:5432,db2:5433": "db1", "sqlserver:sql01.corp:1433": "sql01.corp", "": "",
	} {
		if got := targetHost(in); got != want {
			t.Errorf("targetHost(%q) = %q, want %q", in, got, want)
		}
	}
}

// #a5: the probes in flight sized per round to finish 2,124 addresses within 20 s at one connect's wait (the design
// fold's Q3 figure), 32 at least, 512 at most
func TestProbeInFlight(t *testing.T) {
	for n, want := range map[int]int{0: 32, 213: 32, 640: 32, 2124: 107, 10000: 500, 20000: 512} {
		if got := probeInFlightFor(n, time.Second); got != want {
			t.Errorf("probeInFlightFor(%d, 1 s) = %d, want %d", n, got, want)
		}
	}
}

// #a9: an answered handshake under a millisecond is 1 ms, never 0 (the page read '0 ms'; P2's 'ms > 0')
func TestProbeAnsweredAtLeastOneMs(t *testing.T) {
	p := newProber("tcp", true)
	p.dial = func(ctx context.Context, addr string) error { return nil }
	p.noteRemote("i1", "db1", "10.1.2.3:5432")
	p.round(context.Background(), time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC))
	rows := p.take()
	if len(rows) != 1 || rows[0].Answered == nil || *rows[0].Answered != 1 || rows[0].MsMax < 1 || rows[0].MsSum < 1 {
		t.Errorf("an instant answer: %+v, want answered 1 with ms_sum and ms_max at least 1", rows)
	}
}

// F3 (#a1's beat half, #b7): the beat carries the opened addresses once (an empty list as [], never null:
// jsonb_to_recordset refuses null), and each probe row its mode
func TestBeatCarriesOpenedAndMode(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}, probe: newProber("tcp", false)}
	h.targets = map[string]string{"i1": "postgres:db1:5432"}
	h.noteRemote("i1", "10.1.2.3:5432")
	b := h.take()
	if len(b.Opened) != 1 || b.Opened[0].Address != "10.1.2.3:5432" || b.Opened[0].Host != "db1" {
		t.Errorf("the beat's opened: %+v, want 10.1.2.3:5432 under db1", b.Opened)
	}
	if b2 := h.take(); b2.Opened == nil || len(b2.Opened) != 0 {
		t.Errorf("the next beat's opened: %#v, want [] (handed once, never null)", b2.Opened)
	}
	for _, every := range []bool{true, false} {
		p := newProber("tcp", every)
		p.dial = func(ctx context.Context, addr string) error { return nil }
		p.noteRemote("i1", "db1", "10.1.2.3:5432")
		p.noteFailed("i1")
		p.round(context.Background(), time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC))
		if rows := p.take(); len(rows) != 1 || rows[0].Scheduled != every {
			t.Errorf("probe_every_minute %v: rows %+v, want one with scheduled %v", every, rows, every)
		}
	}
}
