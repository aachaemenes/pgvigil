package mssql

// Save Table on a SQL Server instance (task 7b): the two logins' connections for internal/savetable's checks, and the
// write - CREATE TABLE and go-mssqldb's bulk copy (CopyIn: the values travel as data, never as SQL text) in one
// transaction. The checks themselves are savetable.Check's; this file only answers them. The target is the one quoted
// form [database].[pgvigil_saved].[table] everywhere: the CREATE, CopyIn's table and OBJECT_ID's bound argument.

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/aachaemenes/pgvigil/internal/savetable"
	mssqldb "github.com/microsoft/go-mssqldb"
)

// msSave is one login's connection.
type msSave struct{ c *sql.Conn }

// Server: @@SERVERNAME and tempdb's create date, as every action compares them (serverSQL2).
func (m msSave) Server(ctx context.Context) (string, error) {
	var name, start, login string
	err := m.c.QueryRowContext(ctx, serverSQL2).Scan(&name, &start, &login)
	return name + " started " + start, err
}

// Login: the login's name and whether it is sysadmin or holds CONTROL SERVER (actorSQL).
func (m msSave) Login(ctx context.Context) (string, bool, error) {
	var name string
	if err := m.c.QueryRowContext(ctx, `SELECT SUSER_SNAME()`).Scan(&name); err != nil {
		return "", false, err
	}
	var spid, sysadmin, control int
	if err := m.c.QueryRowContext(ctx, actorSQL).Scan(&spid, &sysadmin, &control); err != nil {
		return "", false, err
	}
	return name, sysadmin == 1 || control == 1, nil
}

// Schema: pgvigil_saved in the connection's database (USE'd at the open), and whether its owner is this login's user
// there (a schema owned by a role or dbo is not its own).
func (m msSave) Schema(ctx context.Context) (bool, bool, error) {
	var owned int
	err := m.c.QueryRowContext(ctx, `SELECT CASE WHEN s.principal_id = DATABASE_PRINCIPAL_ID() THEN 1 ELSE 0 END
	                                    FROM sys.schemas s WHERE s.name = @p1`, savetable.Schema).Scan(&owned)
	if errors.Is(err, sql.ErrNoRows) {
		return false, false, nil
	}
	return err == nil, owned == 1, err
}

// Exists: OBJECT_ID of the one quoted form, bound (review-29 S1). NULL also for an object the login cannot see: the
// CREATE stays the guard (Msg 2714 is the same refusal).
func (m msSave) Exists(ctx context.Context, quoted string) (bool, error) {
	var there int
	err := m.c.QueryRowContext(ctx, `SELECT CASE WHEN OBJECT_ID(@p1) IS NULL THEN 0 ELSE 1 END`, quoted).Scan(&there)
	return there == 1, err
}

// Place: RED STUB (review-31 part A2's rows) - nothing read.
func (m msSave) Place(context.Context) (savetable.Place, error) { return savetable.Place{}, nil }

// Write: CREATE TABLE, then CopyIn into the same quoted target, one transaction; rolled back on any error.
func (m msSave) Write(ctx context.Context, t savetable.Target, cols []savetable.Col, rows [][]any) (int64, error) {
	create, err := savetable.CreateSQL(savetable.SQLServer, t, cols)
	if err != nil {
		return 0, err
	}
	tx, err := m.c.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, create); err != nil {
		if me := (mssqldb.Error{}); errors.As(err, &me) && me.Number == 2714 {
			return 0, savetable.ErrExists
		}
		return 0, err
	}
	names := make([]string, len(cols))
	for i, c := range cols {
		names[i] = c.Name
	}
	stmt, err := tx.PrepareContext(ctx, mssqldb.CopyIn(savetable.Quoted(savetable.SQLServer, t), mssqldb.BulkOptions{}, names...))
	if err != nil {
		return 0, err
	}
	defer func() { _ = stmt.Close() }()
	for _, r := range rows {
		if _, err := stmt.ExecContext(ctx, r...); err != nil {
			return 0, err
		}
	}
	res, err := stmt.ExecContext(ctx) // the flush: the bulk copy's rows sent
	if err != nil {
		return 0, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	return n, tx.Commit()
}

// SaveConns opens the two connections Save Table checks on and writes through: the read login (as every action
// checks with) and a connection of the actions login of its own for this save, moved to the chosen database by USE
// with the name quoted (QUOTENAME's rule), the session's lock timeout 2 s (sessionSetup) and the save's budget as its
// context deadline (review-29 S9). close ends both.
func (d Door) SaveConns(ctx context.Context, database string, budget time.Duration) (mon savetable.Conn, act savetable.Writer, closeAll func(), err error) {
	if d.Actions == "" {
		return nil, nil, nil, errors.New("the instance has no actions login")
	}
	mdb, mc, err := d.openMonitor(ctx)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("the read login could not connect: %w", err)
	}
	adb, ac, err := openAction(ctx, d.Actions, "pgvigil-save-table")
	if err != nil {
		_ = mc.Close()
		_ = mdb.Close()
		return nil, nil, nil, err
	}
	closeAll = func() { _ = ac.Close(); _ = adb.Close(); _ = mc.Close(); _ = mdb.Close() }
	// READ COMMITTED for the write (sessionSetup reads uncommitted for the DMVs)
	if _, err := ac.ExecContext(ctx, `USE `+savetable.QuoteIdent(savetable.SQLServer, database)+`; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;`); err != nil {
		closeAll()
		return nil, nil, nil, fmt.Errorf("the actions login could not open the database %s: %w", database, err)
	}
	_ = budget // the caller's context carries the deadline; SQL Server has no per-session statement timeout
	return msSave{mc}, msSave{ac}, closeAll, nil
}
