package mssql

// review-31 part B, B1 (written 11-17 07:2x, before savetable-g3): Save Table's SQL Server write, recorded statement by
// statement through a database/sql driver of the test's own - the switch to the login's own database user, the CREATE
// (CreateSQL's text, every name quoted), the bulk copy's table and columns (mssqldb.CopyIn of the one quoted form), the
// commit; a cell's value is never in any statement's text: it travels as the bulk copy's data.

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/savetable"
	mssqldb "github.com/microsoft/go-mssqldb"
)

// recLog is every statement text the recording driver was asked, and every value it was handed (apart)
type recLog struct {
	mu    sync.Mutex
	texts []string
	vals  []any
}

func (l *recLog) text(s string) { l.mu.Lock(); l.texts = append(l.texts, s); l.mu.Unlock() }

var (
	recOnce sync.Once
	recCur  *recLog // the running test's log (the tests of this file do not run in parallel)
)

type recDriver struct{}

func (recDriver) Open(string) (driver.Conn, error) { return recConn{}, nil }

type recConn struct{}

func (recConn) Prepare(q string) (driver.Stmt, error) {
	recCur.text("PREPARE " + q)
	return &recStmt{}, nil
}
func (recConn) Close() error              { return nil }
func (recConn) Begin() (driver.Tx, error) { recCur.text("BEGIN"); return recTx{}, nil }
func (recConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	recCur.text("EXEC " + q)
	for _, a := range args {
		recCur.vals = append(recCur.vals, a.Value)
	}
	return driver.RowsAffected(0), nil
}

type recTx struct{}

func (recTx) Commit() error   { recCur.text("COMMIT"); return nil }
func (recTx) Rollback() error { return nil }

// recStmt is the bulk copy's statement: a row per call with values, the flush (no values) answers the rows it took
type recStmt struct{ n int64 }

func (s *recStmt) Close() error                             { return nil }
func (s *recStmt) NumInput() int                            { return -1 }
func (s *recStmt) CheckNamedValue(*driver.NamedValue) error { return nil } // any value the write binds
func (s *recStmt) Exec(args []driver.Value) (driver.Result, error) {
	if len(args) == 0 {
		return driver.RowsAffected(s.n), nil
	}
	s.n++
	for _, a := range args {
		recCur.vals = append(recCur.vals, a)
	}
	return driver.RowsAffected(0), nil
}
func (s *recStmt) Query([]driver.Value) (driver.Rows, error) { return nil, errors.New("no query here") }

func TestSaveTableWriteSendsNoValueText(t *testing.T) {
	recOnce.Do(func() { sql.Register("pgvigil-savetable-rec", recDriver{}) })
	recCur = &recLog{}
	db, err := sql.Open("pgvigil-savetable-rec", "")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	c, err := db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	tgt := savetable.Target{Database: "db", Schema: savetable.Schema, Table: `t"]'x`}
	cols := []savetable.Col{{Name: `a"b`, Type: "text"}, {Name: "a]b", Type: "int"}}
	const sentinel = "SENTINEL-7b'); DROP TABLE dbo.decoy;--"
	rows := [][]any{{sentinel, int64(424242)}, {"two", int64(2)}, {nil, nil}}
	n, err := msSave{c}.Write(context.Background(), tgt, cols, rows)
	if err != nil || n != 3 {
		t.Fatalf("Write: %d rows, %v; want 3 and no error", n, err)
	}
	create, _ := savetable.CreateSQL(savetable.SQLServer, tgt, cols)
	want := []string{
		"EXEC " + asOwnUser,
		"BEGIN",
		"EXEC " + create,
		"PREPARE " + mssqldb.CopyIn(savetable.Quoted(savetable.SQLServer, tgt), mssqldb.BulkOptions{}, `a"b`, "a]b"),
		"COMMIT",
	}
	if strings.Join(recCur.texts, "\n") != strings.Join(want, "\n") {
		t.Errorf("the statements:\n%s\nwant:\n%s", strings.Join(recCur.texts, "\n"), strings.Join(want, "\n"))
	}
	for _, s := range recCur.texts {
		if strings.Contains(s, "SENTINEL") || strings.Contains(s, "424242") {
			t.Errorf("a cell's value in a statement's text: %q", s)
		}
	}
	// the values went as data: every cell of every row, the sentinel among them
	if len(recCur.vals) != 6 || recCur.vals[0] != sentinel {
		t.Errorf("the values handed as data: %#v, want the 6 cells, the sentinel first", recCur.vals)
	}
}
