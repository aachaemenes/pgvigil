// Package mssql is the SQL Server engine's collector frame: the connection with its safety settings, the detection
// of what the server is and what the login may read, the Collector interface with its registry, and RunOnce, which
// connects, detects, runs one collection and hands the rows to the repository's import function. A SQL Server
// collection is named mssql_<what>; its rows go to pgvigil.import_mssql_<what>. Nothing here writes to, or installs
// anything on, the monitored server.
package mssql

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb" // the sqlserver driver (BSD-3)

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// Prefix starts the name of every SQL Server collection.
const Prefix = "mssql_"

// RunTimeout bounds the SQL Server side of one collection run on one instance: the connection, the detection and
// the collection's statements; a collector that is a Timeouter names its own. The repository writes of the run are not under it (repoTimeout).
const RunTimeout = 60 * time.Second

// repoTimeout bounds each repository write of a run. It starts when the write starts, so a run that used up
// RunTimeout on the SQL Server side still stores its error row.
const repoTimeout = 30 * time.Second

// Collector is one SQL Server collection type.
type Collector interface {
	// Name is the collection's name as the config, the CLI and the repository know it; it starts with Prefix.
	Name() string
	// DefaultInterval is the cadence when nothing overrides it; zero = off by default.
	DefaultInterval() time.Duration
	// Applies says whether the collection runs on this kind, version and set of rights.
	Applies(Info) (ok bool, why string)
	// Run executes the collection on an open connection.
	Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error)
}

// Timeouter is what a collector adds when one run needs more (or must take less) than RunTimeout on the SQL
// Server side: a reader of an Extended Events file, a pass over every database.
type Timeouter interface {
	Timeout() time.Duration
}

// runTimeout is the SQL Server side's deadline for one run of a collector.
func runTimeout(c Collector) time.Duration {
	if t, ok := c.(Timeouter); ok && t.Timeout() > 0 {
		return t.Timeout()
	}
	return RunTimeout
}

var registry = map[string]Collector{}

// Register adds a collector; called from each collector's init.
func Register(c Collector) {
	if !strings.HasPrefix(c.Name(), Prefix) {
		panic("a SQL Server collection is named " + Prefix + "<what>: " + c.Name())
	}
	if _, dup := registry[c.Name()]; dup {
		panic("duplicate collector " + c.Name())
	}
	registry[c.Name()] = c
}

// Names lists the registered collections, sorted.
func Names() []string {
	out := make([]string, 0, len(registry))
	for n := range registry {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// Get returns a collector by name.
func Get(name string) (Collector, bool) {
	c, ok := registry[name]
	return c, ok
}

// All returns every registered collector, sorted by name.
func All() []Collector {
	names := Names()
	out := make([]Collector, 0, len(names))
	for _, n := range names {
		out = append(out, registry[n])
	}
	return out
}

// sessionSetup keeps a collector from joining a convoy on a busy server: it gives up on a lock after two seconds,
// loses any deadlock it is part of, and reads without taking shared locks (the DMVs do not care; the msdb and catalog
// reads then never wait behind a writer). go-mssqldb resets a pooled session when it is taken from the pool, so the
// settings are applied on the one connection a run holds, after it is taken.
const sessionSetup = `SET NOCOUNT ON;
SET LOCK_TIMEOUT 2000;
SET DEADLOCK_PRIORITY LOW;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;`

// withAppName names the session "pgvigil" on the SQL Server side unless the dsn names one.
func withAppName(dsn string) string {
	l := strings.ToLower(dsn)
	if strings.Contains(l, "app name") || strings.Contains(l, "app+name") || strings.Contains(l, "app%20name") || strings.Contains(l, "application name") {
		return dsn
	}
	if strings.HasPrefix(l, "sqlserver://") {
		if strings.Contains(dsn, "?") {
			return dsn + "&app+name=pgvigil"
		}
		return dsn + "?app+name=pgvigil"
	}
	if strings.HasPrefix(l, "odbc:") {
		return dsn
	}
	return strings.TrimRight(dsn, "; ") + ";app name=pgvigil"
}

// Connect opens one connection to a SQL Server instance with the safety settings applied. The caller closes both.
func Connect(ctx context.Context, in config.Instance) (*sql.DB, *sql.Conn, error) {
	dsn := in.DSN()
	if strings.TrimSpace(dsn) == "" {
		return nil, nil, fmt.Errorf("connect %s: the dsn resolved to an empty string (unset variable or unreadable file)", in.Name)
	}
	db, err := sql.Open("sqlserver", withAppName(dsn))
	if err != nil {
		return nil, nil, fmt.Errorf("connect %s: dsn: %w", in.Name, err)
	}
	db.SetMaxOpenConns(1)
	conn, err := db.Conn(ctx)
	if err != nil {
		_ = db.Close()
		return nil, nil, fmt.Errorf("connect %s: %w", in.Name, err)
	}
	if _, err := conn.ExecContext(ctx, sessionSetup); err != nil {
		_ = conn.Close()
		_ = db.Close()
		return nil, nil, fmt.Errorf("session setup %s: %w", in.Name, err)
	}
	return db, conn, nil
}

// QueryRows runs one statement and returns its rows keyed by the result's column names as written. The contract
// every collector builds on, by the column's SQL Server type:
//
//   - char, varchar, nchar, nvarchar, text, ntext, xml: a string.
//   - decimal, numeric, money, smallmoney: a string of the number as the server wrote it ("12.345").
//   - bit, tinyint, smallint, int, bigint, real, float: the Go value the driver gives (bool, int64, float64).
//   - uniqueidentifier: the canonical text, upper case (6F9619FF-8B86-D011-B42D-00C04FC964FF).
//   - binary, varbinary, image, timestamp / rowversion and any other value the driver hands over as bytes
//     (a handle, a hash, context_info): "0x" and upper-case hex, the form SSMS prints and a 0x literal takes.
//   - datetimeoffset: a time.Time in UTC; it is the only time type that says which instant it means.
//   - datetime, datetime2, smalldatetime: ZONE-LESS text, 2026-11-10T07:00:00.1234567 (the fraction without its
//     trailing zeros); date: 2026-11-10; time: 07:00:00.1234567. They are whatever clock the column was written
//     in, which for almost every DMV and msdb column is the SERVER'S LOCAL time; the driver cannot know, so
//     nothing here pretends they are UTC. A collector that stores an instant converts on the SQL Server side, in
//     its SELECT (a UTC column where the DMV has one, the server's offset or AT TIME ZONE ... AT TIME ZONE 'UTC'
//     where it does not), and returns a datetimeoffset or text ending in Z.
//   - NULL: nil.
func QueryRows(ctx context.Context, conn *sql.Conn, query string, args ...any) ([]collect.Row, error) {
	rs, err := conn.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rs.Close() }()
	cols, err := rs.Columns()
	if err != nil {
		return nil, err
	}
	types, err := rs.ColumnTypes()
	if err != nil {
		return nil, err
	}
	kinds := make([]string, len(cols))
	for i := range kinds {
		if i < len(types) {
			kinds[i] = strings.ToUpper(types[i].DatabaseTypeName())
		}
	}
	var out []collect.Row
	for rs.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rs.Scan(ptrs...); err != nil {
			return nil, err
		}
		row := make(collect.Row, len(cols))
		for i, c := range cols {
			row[c] = rowValue(kinds[i], vals[i])
		}
		out = append(out, row)
	}
	return out, rs.Err()
}

// rowValue turns one scanned value into what QueryRows promises for the column's type (the driver's
// DatabaseTypeName, upper case).
func rowValue(dbType string, v any) any {
	switch x := v.(type) {
	case []byte:
		switch dbType {
		case "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY":
			return string(x)
		case "UNIQUEIDENTIFIER":
			var u mssqldb.UniqueIdentifier
			if err := u.Scan(x); err == nil {
				return u.String()
			}
		}
		return "0x" + strings.ToUpper(hex.EncodeToString(x))
	case time.Time:
		switch dbType {
		case "DATETIMEOFFSET":
			return x.UTC()
		case "DATE":
			return x.Format("2006-01-02")
		case "TIME":
			return x.Format("15:04:05.9999999")
		}
		return x.Format("2006-01-02T15:04:05.9999999")
	}
	return v
}

// RunOnce runs one SQL Server collection against one instance and stores the rows. The SQL Server side runs
// under RunTimeout; every repository write gets its own repoTimeout on a context the run's deadline (and a
// shutdown's cancel) does not cut, so a run that timed out is recorded as an error instead of leaving the
// previous ok row in place.
func RunOnce(ctx context.Context, log *slog.Logger, r *repo.Repo, in config.Instance, name string) collect.Result {
	c, ok := Get(name)
	if !ok {
		return collect.Result{Err: fmt.Errorf("unknown collection %q; known: %v", name, Names())}
	}
	start := time.Now()
	limit := runTimeout(c)
	sctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	logRun := func(instanceID int, status, note string) {
		rctx, rcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
		defer rcancel()
		if err := r.LogCollection(rctx, instanceID, name, start, time.Since(start), status, note); err != nil {
			log.Warn("the collection's result was not recorded", "instance", in.Name, "collection", name, "status", status, "err", err)
		}
	}
	db, conn, err := Connect(sctx, in)
	if err != nil {
		// the server did not answer: recorded, so the 'server unreachable' finding sees it (0118); a connect cut by
		// pgvigil's own shutdown (the parent ctx cancelled) is not recorded - the run's own timeout (sctx) still is
		cerr := timeoutNote(sctx, limit, err)
		if ctx.Err() == nil {
			rctx, rcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
			if lerr := r.LogConnectFailure(rctx, in.Name, config.EngineSQLServer, in.Platform, in.Tags, name, start, time.Since(start), cerr); lerr != nil {
				log.Warn("the failed connect was not recorded", "instance", in.Name, "collection", name, "err", lerr)
			}
			rcancel()
		}
		return collect.Result{Err: cerr, Duration: time.Since(start)}
	}
	defer func() { _ = conn.Close(); _ = db.Close() }()

	info, err := Detect(sctx, conn, in.Platform)
	if err != nil {
		return collect.Result{Err: fmt.Errorf("%s: %w", in.Name, timeoutNote(sctx, limit, err)), Duration: time.Since(start)}
	}
	ectx, ecancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
	instanceID, err := r.EnsureInstanceEngine(ectx, config.EngineSQLServer, in.Name, string(info.Kind), info.Version, info.VersionNum, false, in.Tags)
	ecancel()
	if err != nil {
		return collect.Result{Err: err, Duration: time.Since(start)}
	}
	if ok, why := c.Applies(info); !ok {
		logRun(instanceID, "skipped", why)
		return collect.Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
	}
	// a collection that reads its source from a cursor imports batch by batch, each batch with its cursor (batch.go)
	if bc, ok := c.(BatchCollector); ok {
		return runBatched(ctx, sctx, log, r, in, name, bc, conn, info, instanceID, start, limit)
	}
	tctx, tcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
	err = StoreHADRThresholds(tctx, r, instanceID, name, start, in.MSSQLThresholds)
	tcancel()
	if err != nil {
		logRun(instanceID, "error", err.Error())
		return collect.Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	// a collection that reads on from one sequence number (the Agent job history) asks the repository where it stopped
	var rows []collect.Row
	if cc, ok := c.(CursorCollector); ok {
		rows, err = cc.RunFrom(sctx, conn, info, func(_ context.Context, source string) (int64, bool, error) {
			cctx, ccancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
			defer ccancel()
			return r.MSSQLSeqCursor(cctx, instanceID, source)
		})
	} else {
		rows, err = c.Run(sctx, conn, info)
	}
	if errors.Is(err, collect.ErrSkip) {
		why := strings.TrimSuffix(err.Error(), ": "+collect.ErrSkip.Error())
		logRun(instanceID, "skipped", why)
		return collect.Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
	}
	if err != nil {
		err = timeoutNote(sctx, limit, err)
		logRun(instanceID, "error", err.Error())
		return collect.Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	collect.ApplyTextPolicy(rows, in.QueryText)
	ictx, icancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
	err = r.Import(ictx, instanceID, name, start, rows)
	icancel()
	if err != nil {
		logRun(instanceID, "error", err.Error())
		return collect.Result{Err: fmt.Errorf("import %s from %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	d := time.Since(start)
	status, note := "ok", ""
	for _, row := range rows {
		if row["kind"] == "collector_error" {
			status, note = "partial", fmt.Sprintf("%v: %v", row["source"], row["message"])
			break
		}
	}
	logRun(instanceID, status, note)
	log.Debug("collected", "instance", in.Name, "collection", name, "rows", len(rows), "ms", d.Milliseconds())
	return collect.Result{Rows: len(rows), Duration: d, Note: partialNote(status, note)}
}

// timeoutNote says so when an error is the run's own deadline: the driver's text for it names no cause.
func timeoutNote(sctx context.Context, limit time.Duration, err error) error {
	if errors.Is(sctx.Err(), context.DeadlineExceeded) {
		return fmt.Errorf("the run hit its %d s timeout on the SQL Server side: %w", int(limit.Seconds()), err)
	}
	return err
}

func partialNote(status, note string) string {
	if status != "partial" {
		return ""
	}
	return " (partial: " + note + ")"
}
