package actions

// Save Table on a PostgreSQL instance (task 7b): the two logins' connections for internal/savetable's checks, and the
// write - CREATE TABLE and the COPY protocol's bulk load (pgx CopyFrom: the values travel as data, never as SQL text)
// in one transaction. The checks themselves are savetable.Check's; this file only answers them.

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/aachaemenes/pgvigil/internal/savetable"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// pgSave is one login's connection on the chosen database.
type pgSave struct{ c *pgx.Conn }

// Server: the postmaster's start as seconds since the epoch, so two logins' session time zones never differ it.
func (p pgSave) Server(ctx context.Context) (string, error) {
	var s string
	err := p.c.QueryRow(ctx, `SELECT extract(epoch FROM pg_catalog.pg_postmaster_start_time())::pg_catalog.text`).Scan(&s)
	return s, err
}

func (p pgSave) Login(ctx context.Context) (string, bool, error) {
	var name string
	var super bool
	err := p.c.QueryRow(ctx, `SELECT r.rolname, r.rolsuper FROM pg_catalog.pg_roles r WHERE r.rolname = current_user`).Scan(&name, &super)
	return name, super, err
}

// Schema: pgvigil_saved in this database, and whether the login is its owner (owned by a role the login is a member
// of is not its own: the lead 11-17 02:17, 'owned by the door login').
func (p pgSave) Schema(ctx context.Context) (bool, bool, error) {
	var owned bool
	err := p.c.QueryRow(ctx, `SELECT n.nspowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = current_user)
	                            FROM pg_catalog.pg_namespace n WHERE n.nspname = $1`, savetable.Schema).Scan(&owned)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, false, nil
	}
	return err == nil, owned, err
}

// Exists: the one quoted form, bound (review-29 S1).
func (p pgSave) Exists(ctx context.Context, quoted string) (bool, error) {
	var there bool
	err := p.c.QueryRow(ctx, `SELECT pg_catalog.to_regclass($1) IS NOT NULL`, quoted).Scan(&there)
	return there, err
}

// Place: whether the database this connection is in is a template NOW (review-31 part A2 SF4: the store's last read
// may be older than an ALTER DATABASE ... IS_TEMPLATE). The database owner role and the DDL triggers of SQL Server's
// Place have no read here; PostgreSQL's event triggers are not read.
func (p pgSave) Place(ctx context.Context) (savetable.Place, error) {
	var pl savetable.Place
	err := p.c.QueryRow(ctx, `SELECT d.datistemplate FROM pg_catalog.pg_database d WHERE d.datname = pg_catalog.current_database()`).Scan(&pl.DB.IsTemplate)
	return pl, err
}

// Write: CREATE TABLE, then CopyFrom into it, one transaction; rolled back on any error.
func (p pgSave) Write(ctx context.Context, t savetable.Target, cols []savetable.Col, rows [][]any) (int64, error) {
	create, err := savetable.CreateSQL(savetable.Postgres, t, cols)
	if err != nil {
		return 0, err
	}
	tx, err := p.c.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	return writeTx(ctx, tx, create, t, cols, rows)
}

// writeTx is the write inside its transaction, on a pgx.Tx so a unit row can record every statement it sends
// (review-31 part B B1): SET LOCAL, the CREATE, the COPY of the one quoted target, the commit.
func writeTx(ctx context.Context, tx pgx.Tx, create string, t savetable.Target, cols []savetable.Col, rows [][]any) (int64, error) {
	// again inside the transaction: a pooler in front of actions_dsn may drop the connection's startup settings, and
	// the CREATE TABLE's types must resolve in pg_catalog whatever the database's own search_path says (SF2)
	if _, err := tx.Exec(ctx, `SET LOCAL search_path = pg_catalog`); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, create); err != nil {
		if pe := (*pgconn.PgError)(nil); errors.As(err, &pe) && (pe.Code == "42P07" || pe.Code == "42710") {
			return 0, savetable.ErrExists
		}
		return 0, err
	}
	names := make([]string, len(cols))
	for i, c := range cols {
		names[i] = c.Name
	}
	n, err := tx.CopyFrom(ctx, pgx.Identifier{t.Schema, t.Table}, names, pgx.CopyFromRows(rows))
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		// the server answered the commit with an error, or with ROLLBACK: nothing was kept. Anything else (the
		// connection cut, the deadline passed in the round trip) leaves the outcome unknown (review-31 part A2 NIT 8)
		if pe := (*pgconn.PgError)(nil); errors.As(err, &pe) || errors.Is(err, pgx.ErrTxCommitRollback) {
			return 0, err
		}
		return 0, fmt.Errorf("%w: %v", savetable.ErrCommitUnknown, err)
	}
	return n, nil
}

// SaveConns opens the two connections Save Table checks on and writes through: the monitoring login (as every action
// checks with: read-only, 5 s) and the SAVE-ONLY connection of the actions login on the chosen database - read-write,
// its own statement timeout (budget), a 2 s lock timeout and a 30 s idle-in-transaction timeout (review-29 S9). The
// shared connect, read-only for cancel and terminate, is never changed for it. close ends both.
func (d Door) SaveConns(ctx context.Context, database string, budget time.Duration) (mon savetable.Conn, act savetable.Writer, closeAll func(), err error) {
	if d.Actions == "" {
		return nil, nil, nil, errors.New("the instance has no actions login")
	}
	m, err := connect(ctx, d.Monitor, d.Secret, "pgvigil-save-check")
	if err != nil {
		return nil, nil, nil, fmt.Errorf("the read login could not connect: %w", err)
	}
	cfg, err := pgx.ParseConfig(d.Actions)
	if err != nil {
		_ = m.Close(ctx)
		return nil, nil, nil, err
	}
	cfg.Database = database
	if cfg.ConnectTimeout == 0 || cfg.ConnectTimeout > 10*time.Second {
		cfg.ConnectTimeout = 10 * time.Second
	}
	rp := cfg.RuntimeParams
	rp["application_name"] = "pgvigil-save-table"
	rp["statement_timeout"] = strconv.FormatInt(budget.Milliseconds(), 10)
	rp["lock_timeout"] = "2000"
	rp["idle_in_transaction_session_timeout"] = "30000"
	// the save runs read-write whatever the role's or the DSN's default says (review-31 part A2 NIT 5: ALTER ROLE ...
	// SET default_transaction_read_only = on is a reasonable hardening of the cancel / terminate login)
	rp["default_transaction_read_only"] = "off"
	// pg_catalog alone: the database's own search_path (ALTER DATABASE ... SET search_path = public, pg_catalog) would
	// let its owner plant public.text, public.to_regclass or a public.pg_roles that this login then runs or trusts
	// (review-31 part A2 SF2). The target is always schema-qualified; the column types then resolve in pg_catalog.
	rp["search_path"] = "pg_catalog"
	a, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		_ = m.Close(ctx)
		return nil, nil, nil, err
	}
	closeAll = func() {
		bg := context.WithoutCancel(ctx)
		_ = a.Close(bg)
		_ = m.Close(bg)
	}
	return pgSave{m}, pgSave{a}, closeAll, nil
}
