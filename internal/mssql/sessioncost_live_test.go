package mssql

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestSessionCostLive (a box row: PGVIGIL_MSSQL_TEST_DSN names a SQL Server): what the
// run's end read gets from the REAL driver on the run's own connection -
//
//	after a healthy statement that burned CPU: the session's cost, above 0;
//	after a statement cut by a CANCEL (pgvigil stopping): the connection still answers, the cost holds the cut work;
//	after a statement cut by its DEADLINE (the run's own timeout): go-mssqldb takes the connection for bad
//	  (context.DeadlineExceeded is a net.Error), so the read gets nothing - nil / nil, 'not read'.
//
// Each case on a connection of its own, opened as a run opens it (Connect).
func TestSessionCostLive(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_MSSQL_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_MSSQL_TEST_DSN is not set")
	}
	open := func() (func(), func(ctx context.Context, q string) error, func() (*int64, *int64)) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		db, conn, err := Connect(ctx, config.Instance{Name: "live", DSNRaw: dsn})
		if err != nil {
			t.Fatalf("connect: %v", err)
		}
		return func() { _ = conn.Close(); _ = db.Close() },
			func(ctx context.Context, q string) error { _, err := conn.ExecContext(ctx, q); return err },
			func() (*int64, *int64) { return sessionCost(context.Background(), conn) }
	}
	show := func(p *int64) any {
		if p == nil {
			return "nil"
		}
		return *p
	}

	// a healthy run: one second of CPU
	closeConn, exec, cost := open()
	if err := exec(context.Background(), "DECLARE @i int = 0, @until datetime2 = DATEADD(second, 1, SYSUTCDATETIME()); WHILE SYSUTCDATETIME() < @until SET @i += 1;"); err != nil {
		t.Fatalf("the healthy statement: %v", err)
	}
	cpu, reads := cost()
	t.Logf("healthy: cpu %v ms, reads %v", show(cpu), show(reads))
	if cpu == nil || reads == nil || *cpu <= 0 { // above 0: a busy box schedules less CPU in a second of wall time
		t.Errorf("after a healthy second of CPU: cpu %v, reads %v - want the session's cost, above 0", show(cpu), show(reads))
	}
	closeConn()

	// cut by a cancel after one second of a five-second burn
	closeConn, exec, cost = open()
	cctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(time.Second, cancel)
	err := exec(cctx, "DECLARE @i int = 0, @until datetime2 = DATEADD(second, 5, SYSUTCDATETIME()); WHILE SYSUTCDATETIME() < @until SET @i += 1;")
	cancel()
	cpu, reads = cost()
	t.Logf("cancelled: the statement's error %v; cpu %v ms, reads %v", err, show(cpu), show(reads))
	if err == nil || cpu == nil || reads == nil || *cpu <= 0 {
		t.Errorf("after a cancel: error %v, cpu %v, reads %v - want the statement cut and the session's cost read, above 0", err, show(cpu), show(reads))
	}
	closeConn()

	// cut by its own deadline after one second of a five-second burn
	closeConn, exec, cost = open()
	dctx, dcancel := context.WithTimeout(context.Background(), time.Second)
	err = exec(dctx, "DECLARE @i int = 0, @until datetime2 = DATEADD(second, 5, SYSUTCDATETIME()); WHILE SYSUTCDATETIME() < @until SET @i += 1;")
	dcancel()
	cpu, reads = cost()
	t.Logf("deadline: the statement's error %v; cpu %v ms, reads %v", err, show(cpu), show(reads))
	if err == nil || cpu != nil || reads != nil {
		t.Errorf("after the run's own deadline: error %v, cpu %v, reads %v - want the statement cut and NO read (the driver drops the connection)", err, show(cpu), show(reads))
	}
	closeConn()
}
