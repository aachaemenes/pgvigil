package sched

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// TestConnectBackoffHoldsTheLoops (L214, proof R1): five collections of one down PostgreSQL instance tick every
// second for 20 s against a listener that accepts and closes at once (a failed connect that is not a refused login;
// the listener's accepted count is the instance's connect count). Today every tick connects - about one per
// collection per second, near 100 over the window. With the back-off (after 3 failed connects in a row the instance
// waits a minute from its last attempt, doubling to 15 minutes, one probe at a time) the listener sees the first
// streak and nothing more inside the window: 12 attempts or fewer. The streak lives in the heartbeat
// (PGVIGIL_REPO_TEST_DSN's store; skipped without it).
func TestConnectBackoffHoldsTheLoops(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	var attempts atomic.Int64
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			attempts.Add(1)
			_ = c.Close()
		}
	}()
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	waitBeat, err := collect.StartHeartbeat(ctx, log, dsn, collect.HeartbeatInfo{Probe: "off"})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { cancel(); waitBeat() }() // the beat's stop first: waited for before its cancel it runs out its 15 s
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	in := config.Instance{Name: fmt.Sprintf("backoff-r1-%d", time.Now().UnixNano()%1000000000),
		DSNRaw: fmt.Sprintf("host=127.0.0.1 port=%d user=pgv dbname=postgres sslmode=disable connect_timeout=1", port)}
	specs := engines.Specs(config.EnginePostgres)
	if len(specs) < 5 {
		t.Fatalf("fewer than 5 postgres collections: %d", len(specs))
	}
	lctx, lcancel := context.WithCancel(ctx)
	for _, s := range specs[:5] {
		go loop(lctx, log, r, in, s.Name, time.Second)
	}
	time.Sleep(20 * time.Second)
	lcancel()
	time.Sleep(500 * time.Millisecond)
	if got := attempts.Load(); got > 12 {
		t.Errorf("a down instance's five 1-second loops made %d connect attempts over 20 s; want at most 12 (the first streak of 3 and single probes - the back-off after 3 failed connects in a row)", got)
	}
}
