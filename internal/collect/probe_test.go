package collect

import (
	"context"
	"net"
	"os"
	"regexp"
	"testing"
	"time"
)

// TestProbeTCP (B24h-1b, row P2; the fold's #1, #6, #9): the TCP measure of the reachability probe
func TestProbeTCP(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			_ = c.Close()
		}
	}()
	closed, _ := net.Listen("tcp", "127.0.0.1:0")
	closedAddr := closed.Addr().String()
	_ = closed.Close()
	now := time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)
	one := func(rows []beatProbe, addr string) *beatProbe {
		for i := range rows {
			if rows[i].Address == addr {
				return &rows[i]
			}
		}
		return nil
	}

	// every minute: a listener answers; a closed port answers (refused); two instances on one address = one row
	p := newProber("tcp", true)
	p.noteRemote("i1", "db1", ln.Addr().String())
	p.noteRemote("i2", "db1", ln.Addr().String())
	p.noteRemote("i3", "db3", closedAddr)
	p.round(context.Background(), now)
	rows := p.take()
	if len(rows) != 2 {
		t.Fatalf("rows %d, want 2 (one per address): %+v", len(rows), rows)
	}
	if r := one(rows, ln.Addr().String()); r == nil || r.Method != "tcp" || r.Sent != 1 || r.Answered == nil || *r.Answered != 1 || r.Host != "db1" {
		t.Errorf("the listener: %+v, want db1 tcp sent 1 answered 1", r)
	}
	if r := one(rows, closedAddr); r == nil || r.Answered == nil || *r.Answered != 1 {
		t.Errorf("the closed port: %+v, want answered 1 (a refusal is an answer)", r)
	}

	// a dial that never answers: not answered at the connect's wait; one cut by the round's deadline: not probed
	p = newProber("tcp", true)
	p.connectMax = 50 * time.Millisecond
	p.dial = func(ctx context.Context, _ string) error { <-ctx.Done(); return ctx.Err() }
	p.noteRemote("i9", "black", "10.255.255.1:5432")
	p.round(context.Background(), now)
	if r := one(p.take(), "10.255.255.1:5432"); r == nil || r.Answered == nil || *r.Answered != 0 {
		t.Errorf("a black hole: %+v, want answered 0", r)
	}
	p = newProber("tcp", true)
	p.connectMax, p.roundMax = time.Second, 50*time.Millisecond
	p.dial = func(ctx context.Context, _ string) error { <-ctx.Done(); return ctx.Err() }
	p.noteRemote("i9", "slow", "10.255.255.2:5432")
	p.round(context.Background(), now)
	if r := one(p.take(), "10.255.255.2:5432"); r == nil || r.Answered != nil || r.Sent != 0 {
		t.Errorf("cut by the round's deadline: %+v, want not probed (answered NULL, sent 0)", r)
	}

	// the default mode: only an address whose instance failed since the last round
	p = newProber("tcp", false)
	p.noteRemote("i1", "db1", ln.Addr().String())
	p.round(context.Background(), now)
	if rows := p.take(); len(rows) != 0 {
		t.Errorf("default mode, nothing failed: %+v, want no probe", rows)
	}
	p.noteFailed("i1")
	p.round(context.Background(), now)
	if rows := p.take(); len(rows) != 1 {
		t.Errorf("default mode, i1 failed: %d rows, want 1", len(rows))
	}
	p.round(context.Background(), now.Add(time.Minute))
	if rows := p.take(); len(rows) != 0 {
		t.Errorf("default mode, the next round with nothing failed: %+v, want no probe", rows)
	}

	// an address that never answered: probed again only after 15 minutes. A TCP address always answered once (an opened
	// connection is a TCP answer: the review of B24h-1 part a #1), so the throttle is B24h-2's ICMP measure's - a
	// prober of another method stands for it here
	p = newProber("icmp", true)
	p.connectMax = 20 * time.Millisecond
	p.dial = func(ctx context.Context, _ string) error { <-ctx.Done(); return ctx.Err() }
	p.noteRemote("i9", "black", "10.255.255.1:5432")
	p.round(context.Background(), now)
	_ = p.take()
	p.round(context.Background(), now.Add(5*time.Minute))
	if rows := p.take(); len(rows) != 0 {
		t.Errorf("never answered, 5 minutes on: %+v, want not probed", rows)
	}
	p.round(context.Background(), now.Add(16*time.Minute))
	if rows := p.take(); len(rows) != 1 {
		t.Errorf("never answered, 16 minutes on: %d rows, want 1", len(rows))
	}
}

// TestProbeWiring (B24h-1b): the heartbeat's side - the host from the dial target, a loopback or socket address not
// probed ('local: not probed', the fold's #6d), a failed run marks its address due (the default mode), the rounds'
// rows ride the beat as 'probes' ([] when none)
func TestProbeWiring(t *testing.T) {
	for in, want := range map[string]string{"postgres:db1.example:5432": "db1.example", "postgres:db1:5432,db2:5433": "db1",
		"sqlserver:sql01.corp:1433": "sql01.corp", "postgres:[2001:db8::1]:5432": "2001:db8::1", "": ""} {
		if got := targetHost(in); got != want {
			t.Errorf("targetHost(%q) = %q, want %q", in, got, want)
		}
	}
	for addr, want := range map[string]bool{"10.1.2.3:5432": true, "127.0.0.1:5432": false, "[::1]:1433": false, "/var/run/postgresql/.s.PGSQL.5432": false, "": false} {
		if got := probeable(addr); got != want {
			t.Errorf("probeable(%q) = %v, want %v", addr, got, want)
		}
	}
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}, probe: newProber("tcp", false)}
	h.targets = map[string]string{"i1": "postgres:db1:5432"}
	h.noteRemote("i1", "10.1.2.3:5432")
	h.record("i1", "postgres", "activity", Result{Duration: time.Millisecond, Err: context.DeadlineExceeded}, time.Now(), time.Minute)
	if !h.probe.due["10.1.2.3:5432"] || h.probe.hostOf["10.1.2.3:5432"] != "db1" {
		t.Errorf("a failed run: due %v host %q, want the address due under db1", h.probe.due, h.probe.hostOf["10.1.2.3:5432"])
	}
	if b := h.take(); b.Probes == nil {
		t.Error("the beat's probes are null, want [] (jsonb_to_recordset refuses null)")
	}
}

// TestBeatImportsProbe (B24h-1c): beat() hands the same body to pgvigil.import_collector_probe after
// import_collector_beat (B6.1's form: B24h's own function, so no joined function changes), and stops calling it on a
// repository without it (42883: a collector newer than its repository)
func TestBeatImportsProbe(t *testing.T) {
	b, err := os.ReadFile("heartbeat.go")
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`(?s)import_collector_beat\(.*import_collector_probe\(\$1, \$2, \$3::jsonb\)`).Match(b) {
		t.Error("beat() does not call import_collector_probe after import_collector_beat")
	}
	if !regexp.MustCompile(`42883`).Match(b) {
		t.Error("beat() does not stop calling import_collector_probe on a repository without it (42883)")
	}
}
