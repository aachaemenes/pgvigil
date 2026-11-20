package mssql

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// A driver that answers one query with fixed rows and keeps what it was asked: the run's end read needs no SQL Server
// to show WHAT it asks, on WHICH context, and what it makes of the answer.
type costDriver struct {
	query  string
	ctxErr error
	left   time.Duration // the time left on the query's context; 0 = no deadline
	rows   [][]driver.Value
	err    error
}

type costConnector struct{ d *costDriver }

func (c costConnector) Connect(context.Context) (driver.Conn, error) { return costConn(c), nil }
func (c costConnector) Driver() driver.Driver                        { return costDrv{} }

type costDrv struct{}

func (costDrv) Open(string) (driver.Conn, error) { return nil, errors.New("not used") }

type costConn struct{ d *costDriver }

func (c costConn) Prepare(string) (driver.Stmt, error) { return nil, errors.New("not used") }
func (c costConn) Close() error                        { return nil }
func (c costConn) Begin() (driver.Tx, error)           { return nil, errors.New("not used") }
func (c costConn) QueryContext(ctx context.Context, q string, _ []driver.NamedValue) (driver.Rows, error) {
	c.d.query, c.d.ctxErr, c.d.left = q, ctx.Err(), 0
	if dl, ok := ctx.Deadline(); ok {
		c.d.left = time.Until(dl)
	}
	if c.d.err != nil {
		return nil, c.d.err
	}
	return &costRows{rows: c.d.rows}, nil
}

type costRows struct {
	rows [][]driver.Value
	i    int
}

func (r *costRows) Columns() []string { return []string{"cpu_time", "logical_reads"} }
func (r *costRows) Close() error      { return nil }
func (r *costRows) Next(dest []driver.Value) error {
	if r.i >= len(r.rows) {
		return io.EOF
	}
	copy(dest, r.rows[r.i])
	r.i++
	return nil
}

// TestSessionCost (B6g-1 row G1; N25, N26): the run's own cost is read at its end from the session's own row - one
// statement, no permission beyond the login's - on a context of its own after the run's context ended, bounded by
// sessionCostTimeout; an answer that cannot be read is 'not read' (nil), never a zero. (This driver keeps every
// connection: what the real driver does after a deadline - the connection dropped, nothing read - is
// TestSessionCostLive's.)
func TestSessionCost(t *testing.T) {
	d := &costDriver{rows: [][]driver.Value{{int64(1234), int64(56789)}}}
	db := sql.OpenDB(costConnector{d})
	defer func() { _ = db.Close() }()
	conn, err := db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close() }()

	cpu, reads := sessionCost(context.Background(), conn)
	if cpu == nil || reads == nil || *cpu != 1234 || *reads != 56789 {
		t.Fatalf("the read gave %v / %v, want 1234 ms and 56789 reads", cpu, reads)
	}
	q := strings.Join(strings.Fields(d.query), " ")
	if q != "SELECT cpu_time, logical_reads FROM sys.dm_exec_sessions WHERE session_id = @@SPID" {
		t.Errorf("the statement %q, want the session's own row of sys.dm_exec_sessions by @@SPID", q)
	}
	if d.left <= 0 || d.left > sessionCostTimeout {
		t.Errorf("the read's context has %v left, want a deadline within %v", d.left, sessionCostTimeout)
	}
	// the run's context is over (its own timeout, or pgvigil stopping): the end read still runs
	over, cancel := context.WithCancel(context.Background())
	cancel()
	d.query = ""
	if cpu, reads = sessionCost(over, conn); cpu == nil || reads == nil || d.query == "" || d.ctxErr != nil {
		t.Errorf("after the run's context ended: %v / %v, asked %q on a context with error %v - want the read made on a live context", cpu, reads, d.query, d.ctxErr)
	}
	// not readable: 'not read', never 0
	d.err = errors.New("the connection is gone")
	if cpu, reads = sessionCost(context.Background(), conn); cpu != nil || reads != nil {
		t.Errorf("a read that failed gave %v / %v, want nil / nil", cpu, reads)
	}
	d.err, d.rows = nil, [][]driver.Value{{nil, int64(5)}}
	if cpu, reads = sessionCost(context.Background(), conn); cpu != nil || reads != nil {
		t.Errorf("a NULL cpu_time gave %v / %v, want nil / nil", cpu, reads)
	}
	d.rows = nil
	if cpu, reads = sessionCost(context.Background(), conn); cpu != nil || reads != nil {
		t.Errorf("no row gave %v / %v, want nil / nil", cpu, reads)
	}
}

// TestEndRead: the run's deferred step. A run cut by pgvigil's own stop (its error
// set, the parent context over) makes NO end read - its result is dropped anyway, and the read would stand between the
// stop and the loop's end; every other return reads - a failed run on a live context, and a run that ended well just
// as the stop came.
func TestEndRead(t *testing.T) {
	d := &costDriver{rows: [][]driver.Value{{int64(7), int64(9)}}}
	db := sql.OpenDB(costConnector{d})
	defer func() { _ = db.Close() }()
	conn, err := db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close() }()
	over, cancel := context.WithCancel(context.Background())
	cancel()
	cut := collect.Result{Err: context.Canceled}
	endRead(over, conn, &cut)
	if d.query != "" || cut.CPUMs != nil || cut.Reads != nil {
		t.Errorf("a run cut by the stop: asked %q, cpu %v - want no end read", d.query, cut.CPUMs)
	}
	failed := collect.Result{Err: errors.New("waits on s1: read")}
	endRead(context.Background(), conn, &failed)
	if failed.CPUMs == nil || *failed.CPUMs != 7 || failed.Reads == nil || *failed.Reads != 9 {
		t.Errorf("a failed run on a live context: cpu %v, reads %v - want 7 and 9", failed.CPUMs, failed.Reads)
	}
	d.query = ""
	ok := collect.Result{Rows: 3}
	endRead(over, conn, &ok)
	if d.query == "" || ok.CPUMs == nil {
		t.Errorf("a run that ended well as the stop came: asked %q, cpu %v - want its end read", d.query, ok.CPUMs)
	}
}
