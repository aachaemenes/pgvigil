package collect

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"os"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestPgRoundTripThroughDelay (B24h-1 P3; PGVIGIL_REPO_TEST_DSN names a PostgreSQL server):
// MeasurePgRoundTrip through a proxy that holds every frontend message asking the server for an answer ('Q' a simple
// query, 'S' an extended-protocol Sync) 50 ms before passing it on - a server that answers 50 ms late. The measure
// reads 50-99 ms (two round trips would read 100 or more), and the proxy sees exactly one 'Q' and no 'P' (Parse)
// from it: one simple-protocol message, one round trip (a Parse first would be two round trips and read about 100 ms).
func TestPgRoundTripThroughDelay(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN not set: a box row (a PostgreSQL server to time 'SELECT 1' against)")
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatalf("PGVIGIL_REPO_TEST_DSN: %v", err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("the proxy's listener: %v", err)
	}
	defer func() { _ = ln.Close() }()
	p := &delayProxy{target: net.JoinHostPort(cfg.Host, strconv.Itoa(int(cfg.Port))), delay: 50 * time.Millisecond}
	go p.serve(ln)
	// through the proxy, in plain text (the proxy reads the messages), with no fallback past it
	cfg.Host, cfg.Port = "127.0.0.1", uint16(ln.Addr().(*net.TCPAddr).Port)
	cfg.TLSConfig, cfg.Fallbacks = nil, nil
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("connect through the proxy: %v", err)
	}
	defer func() { _ = conn.Close(context.Background()) }()

	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	if !current.CompareAndSwap(nil, h) {
		t.Fatal("a heartbeat is already current in this test binary")
	}
	defer current.CompareAndSwap(h, nil)

	q0, p0 := p.q.Load(), p.p.Load()
	MeasurePgRoundTrip(ctx, "p3", conn)
	q, pp := p.q.Load()-q0, p.p.Load()-p0
	var l beatLoad
	for _, x := range h.take().Load {
		if x.Instance == "p3" {
			l = x
		}
	}
	if l.RtCount != 1 {
		t.Fatalf("measures kept %d, want 1 (the load row %+v)", l.RtCount, l)
	}
	// one round trip is 50 ms and more (time.Sleep's floor); two are 100 and more (the mutant's floor), so the ceiling
	// sits at 100, not near 50: a loaded box's sleep overshoot is not a fault
	if l.RtMsMax < 50 || l.RtMsMax >= 100 {
		t.Errorf("the round trip read %d ms through a 50 ms delay, want 50-99 (one round trip; two would be 100 or more)", l.RtMsMax)
	}
	if q != 1 || pp != 0 {
		t.Errorf("the proxy saw %d 'Q' and %d 'P' from the measure, want 1 and 0 (one simple-protocol message)", q, pp)
	}
	t.Logf("P3: the round trip read %d ms through the 50 ms delay; the proxy saw %d 'Q' and %d 'P' from it", l.RtMsMax, q, pp)
}

// delayProxy: a TCP proxy to a PostgreSQL server that holds each frontend message asking for an answer ('Q', 'S') for
// delay before passing it on, and counts the frontend's 'Q' and 'P' messages. The startup message (no type byte) and
// every reply pass as they come.
type delayProxy struct {
	target string
	delay  time.Duration
	q, p   atomic.Int64
}

func (d *delayProxy) serve(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go d.pipe(c)
	}
}

func (d *delayProxy) pipe(c net.Conn) {
	defer func() { _ = c.Close() }()
	s, err := net.Dial("tcp", d.target)
	if err != nil {
		return
	}
	defer func() { _ = s.Close() }()
	go func() { _, _ = io.Copy(c, s); _ = c.Close() }()
	var n [4]byte
	if _, err := io.ReadFull(c, n[:]); err != nil {
		return
	}
	sl := binary.BigEndian.Uint32(n[:])
	if sl < 8 || sl > 1<<16 {
		return
	}
	start := make([]byte, sl)
	copy(start, n[:])
	if _, err := io.ReadFull(c, start[4:]); err != nil {
		return
	}
	if _, err := s.Write(start); err != nil {
		return
	}
	for {
		var hdr [5]byte
		if _, err := io.ReadFull(c, hdr[:]); err != nil {
			return
		}
		ml := binary.BigEndian.Uint32(hdr[1:])
		if ml < 4 || ml > 1<<26 {
			return
		}
		msg := make([]byte, 1+ml)
		copy(msg, hdr[:])
		if _, err := io.ReadFull(c, msg[5:]); err != nil {
			return
		}
		switch hdr[0] {
		case 'Q':
			d.q.Add(1)
		case 'P':
			d.p.Add(1)
		}
		if hdr[0] == 'Q' || hdr[0] == 'S' {
			time.Sleep(d.delay)
		}
		if _, err := s.Write(msg); err != nil {
			return
		}
	}
}
