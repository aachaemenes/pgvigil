package sched

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/repo"
	"github.com/jackc/pgx/v5"
)

// TestRunDeadlineRule (L250): a run's deadline is twice its interval, at least 2 minutes and at most 30; the first
// run after a start gets 30 minutes (PerformanceMonitor's first-run allowance).
func TestRunDeadlineRule(t *testing.T) {
	for _, c := range []struct {
		iv    time.Duration
		first bool
		want  time.Duration
	}{
		{time.Second, false, 2 * time.Minute},
		{time.Minute, false, 2 * time.Minute},
		{5 * time.Minute, false, 10 * time.Minute},
		{20 * time.Minute, false, 30 * time.Minute},
		{24 * time.Hour, false, 30 * time.Minute},
		{time.Minute, true, 30 * time.Minute},
	} {
		if got := runDeadline(c.iv, c.first); got != c.want {
			t.Errorf("runDeadline(%v, first=%v) = %v, want %v", c.iv, c.first, got, c.want)
		}
	}
}

// TestRunLimitNeverUnderTheEngines (rn-l214 S-2): the loop's deadline never cuts a SQL Server run before its own limit
// and its write - mssql_indexes (5 minutes on the SQL Server side) overridden to every minute gets 5 min 30 s, not 2
// minutes, so its error names one limit; a collection without a longer own limit, and PostgreSQL's, keep the
// interval's rule.
func TestRunLimitNeverUnderTheEngines(t *testing.T) {
	pg := engines.Specs(config.EnginePostgres)[0].Name
	for _, c := range []struct {
		iv    time.Duration
		first bool
		name  string
		want  time.Duration
	}{
		{time.Minute, false, "mssql_indexes", 5*time.Minute + 30*time.Second},
		{time.Minute, false, "mssql_backups", 2*time.Minute + 30*time.Second},
		{time.Minute, false, "mssql_waits", 2 * time.Minute}, // its own 60 s + 30 s: under the floor
		{time.Hour, false, "mssql_indexes", 30 * time.Minute},
		{time.Minute, true, "mssql_indexes", 30 * time.Minute},
		{time.Minute, false, pg, 2 * time.Minute},
		{time.Minute, false, "no_such_collection", 2 * time.Minute},
	} {
		if got := runLimit(c.iv, c.first, c.name); got != c.want {
			t.Errorf("runLimit(%v, first=%v, %s) = %v, want %v", c.iv, c.first, c.name, got, c.want)
		}
	}
}

// TestRunDeadlineCutsAHungRun (L250, proof R3): a run hung on its connect (a listener that accepts and never answers,
// the connect bound lifted) is cancelled at the run deadline (the floor scaled to 2 s by the test hook), logged as
// 'timed out after', and the next tick runs - the listener sees a second connect. Today the run holds its loop for
// the whole connect bound and no 'timed out' exists.
func TestRunDeadlineCutsAHungRun(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	oldFloor, oldCap := runDeadlineFloor, runDeadlineCap
	runDeadlineFloor, runDeadlineCap = 2*time.Second, 2*time.Second
	defer func() { runDeadlineFloor, runDeadlineCap = oldFloor, oldCap }()
	oldConnect := collect.DefaultConnectTimeout
	collect.DefaultConnectTimeout = time.Hour
	defer func() { collect.DefaultConnectTimeout = oldConnect }()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()
	var attempts atomic.Int64
	hold := make(chan struct{})
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			attempts.Add(1)
			go func(c net.Conn) { <-hold; _ = c.Close() }(c)
		}
	}()
	defer close(hold)
	var buf bytes.Buffer
	log := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelWarn}))
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	in := config.Instance{Name: fmt.Sprintf("deadline-r3-%d", time.Now().UnixNano()%1000000000),
		DSNRaw: fmt.Sprintf("host=127.0.0.1 port=%d user=pgv dbname=postgres sslmode=disable", port)}
	name := engines.Specs(config.EnginePostgres)[0].Name
	lctx, loops := startTestLoops(ctx)
	defer loops.stop()
	loops.run(func() { loop(lctx, log, r, in, name, time.Second) })
	time.Sleep(8 * time.Second)
	loops.stop() // every run has returned: the log is whole and the defers restore nothing a run still reads (S-6)
	if got := attempts.Load(); got < 2 {
		t.Errorf("a hung run held its loop: %d connect(s) in 8 s, want at least 2 (cancelled at the 2 s deadline, the next tick runs)", got)
	}
	if !strings.Contains(buf.String(), "timed out after") {
		t.Errorf("the cancelled run is logged 'timed out after <d>'; the log holds: %.400s", buf.String())
	}
	// rn-l214 S-1: the cut run's failure reaches collection_log (the Collector errors page, the instance's Collection
	// dates line) - written on a context the run's deadline does not cut; without that the write rode the cut
	// context and was dropped, and the deadline read as a stop dropped it too
	conn, err := pgx.Connect(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	var errs int
	if err := conn.QueryRow(context.Background(), `SELECT count(*) FROM pgvigil.collection_log l JOIN pgvigil.instances i USING (instance_id)
		 WHERE i.name = $1 AND l.collection = $2 AND l.status = 'error'`, in.Name, name).Scan(&errs); err != nil {
		t.Fatal(err)
	}
	if errs < 1 {
		t.Errorf("the deadline cut %d run(s) but collection_log holds no 'error' row for %s's %s: the Collector errors page shows nothing", attempts.Load(), in.Name, name)
	}
}
