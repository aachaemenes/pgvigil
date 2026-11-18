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

// TestProbeNotHeldByAGatedCollection (L214; rn-1's difference 1): a backed-off instance's probe taken by a loop whose
// own run skips before any connect (a collection gated off by the configuration: amcheck by default) must be free
// again when that run ends. Here the gated loop ticks every 250 ms and the connecting one (activity) every 1.5 s, so
// with the unit at 1 s the gated loop is the first to ask after every window. Held forever, the instance never
// probes again and a listener opened later sees no connect; released, the connecting loop's next tick probes, the
// refused login ends the streak and the listener sees every tick.
func TestProbeNotHeldByAGatedCollection(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	old := collect.BackoffUnit
	collect.BackoffUnit = time.Second
	defer func() { collect.BackoffUnit = old }()
	ctx, cancel := context.WithCancel(context.Background())
	ln0, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln0.Addr().(*net.TCPAddr).Port
	_ = ln0.Close()
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	waitBeat, err := collect.StartHeartbeat(ctx, log, dsn, collect.HeartbeatInfo{Probe: "off"})
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	defer func() { cancel(); waitBeat() }()
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	in := config.Instance{Name: fmt.Sprintf("backoff-gated-%d", time.Now().UnixNano()%1000000000),
		DSNRaw: fmt.Sprintf("host=127.0.0.1 port=%d user=pgv dbname=postgres sslmode=disable connect_timeout=1", port)}
	if skip, _ := engines.Gated(in, "amcheck"); !skip {
		t.Fatal("the test's premise: amcheck is gated off on an instance without its block")
	}
	lctx, lcancel := context.WithCancel(ctx)
	defer lcancel()
	go loop(lctx, log, r, in, "activity", 1500*time.Millisecond)
	go loop(lctx, log, r, in, "amcheck", 250*time.Millisecond)
	time.Sleep(8 * time.Second) // activity's 3 failed connects by about 4.5 s; the gated loop asks first after each window
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	var served atomic.Int64
	go refuseLogins(ln, &served)
	time.Sleep(12 * time.Second) // the window at the open is at most 4 s; then a connect every 1.5 s
	if got := served.Load(); got < 2 {
		t.Errorf("a gated collection's loop held the instance's probe: %d connects in the 12 s after the listener opened, want at least 2", got)
	}
}
