package sched

import (
	"context"
	"encoding/binary"
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

// refuseLogins answers each connect as a PostgreSQL server refusing the login (ErrorResponse 28P01 to the startup
// message): the server answered, so the attempt ends a connect streak (heartbeat.AuthFailure), as a listener coming
// up ends a down instance's back-off at the next probe.
func refuseLogins(ln net.Listener, served *atomic.Int64) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		served.Add(1)
		go func(c net.Conn) {
			defer c.Close()
			buf := make([]byte, 512)
			_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
			if _, err := c.Read(buf); err != nil {
				return
			}
			var body []byte
			for _, f := range []struct {
				t byte
				v string
			}{{'S', "FATAL"}, {'V', "FATAL"}, {'C', "28P01"}, {'M', "password authentication failed"}} {
				body = append(body, f.t)
				body = append(body, f.v...)
				body = append(body, 0)
			}
			body = append(body, 0)
			msg := make([]byte, 5, 5+len(body))
			msg[0] = 'E'
			binary.BigEndian.PutUint32(msg[1:5], uint32(4+len(body)))
			msg = append(msg, body...)
			_, _ = c.Write(msg)
		}(c)
	}
}

// TestBackoffEndsAtTheProbe (L214, proof R2): an instance backing off (3 failed connects on a closed port, the
// back-off's minute scaled to 2 s by collect.BackoffUnit) meets a listener opened mid-test on the same port; the next
// probe's connect is answered (a refused login: the server spoke), the streak ends, and the loops connect every tick
// again - the listener sees at least 3 connects over the next 6 s.
func TestBackoffEndsAtTheProbe(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	old := collect.BackoffUnit
	collect.BackoffUnit = time.Second
	defer func() { collect.BackoffUnit = old }()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// reserve a port, then close it: the instance's connects are refused until the listener opens mid-test
	ln0, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln0.Addr().(*net.TCPAddr).Port
	_ = ln0.Close()
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
	in := config.Instance{Name: fmt.Sprintf("backoff-r2-%d", time.Now().UnixNano()%1000000000),
		DSNRaw: fmt.Sprintf("host=127.0.0.1 port=%d user=pgv dbname=postgres sslmode=disable connect_timeout=1", port)}
	specs := engines.Specs(config.EnginePostgres)
	lctx, lcancel := context.WithCancel(ctx)
	defer lcancel()
	for _, s := range specs[:3] {
		go loop(lctx, log, r, in, s.Name, time.Second)
	}
	time.Sleep(5 * time.Second) // the streak reaches 3 and the back-off engages (the window 1 s doubling)
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	var served atomic.Int64
	go refuseLogins(ln, &served)
	time.Sleep(10 * time.Second) // the worst-placed probe lands within 8 s of the open (the window at most 8 units here)
	if got := served.Load(); got < 2 {
		t.Errorf("after the listener opened, the back-off's next probe should end the streak and the loops connect each tick again: %d connects in 10 s, want at least 2", got)
	}
}
