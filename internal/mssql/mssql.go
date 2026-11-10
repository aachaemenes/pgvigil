// Package mssql is the SQL Server engine's collector frame: the connection with its safety settings, the detection
// of what the server is and what the login may read, the Collector interface with its registry, and RunOnce, which
// connects, detects, runs one collection and hands the rows to the repository's import function. A SQL Server
// collection is named mssql_<what>; its rows go to pgvigil.import_mssql_<what>. Nothing here writes to, or installs
// anything on, the monitored server.
package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	_ "github.com/microsoft/go-mssqldb" // the sqlserver driver (BSD-3)

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// Prefix starts the name of every SQL Server collection.
const Prefix = "mssql_"

// RunTimeout bounds one collection run on one instance, the connection included.
const RunTimeout = 60 * time.Second

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

// QueryRows runs one statement and returns its rows keyed by the result's column names as written: text and
// decimal values as strings, times in UTC, NULL as nil.
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
			switch v := vals[i].(type) {
			case []byte:
				row[c] = string(v)
			case time.Time:
				row[c] = v.UTC()
			default:
				row[c] = v
			}
		}
		out = append(out, row)
	}
	return out, rs.Err()
}

// RunOnce runs one SQL Server collection against one instance and stores the rows.
func RunOnce(ctx context.Context, log *slog.Logger, r *repo.Repo, in config.Instance, name string) collect.Result {
	c, ok := Get(name)
	if !ok {
		return collect.Result{Err: fmt.Errorf("unknown collection %q; known: %v", name, Names())}
	}
	start := time.Now()
	ctx, cancel := context.WithTimeout(ctx, RunTimeout)
	defer cancel()
	db, conn, err := Connect(ctx, in)
	if err != nil {
		return collect.Result{Err: err, Duration: time.Since(start)}
	}
	defer func() { _ = conn.Close(); _ = db.Close() }()

	info, err := Detect(ctx, conn, in.Platform)
	if err != nil {
		return collect.Result{Err: fmt.Errorf("%s: %w", in.Name, err), Duration: time.Since(start)}
	}
	instanceID, err := r.EnsureInstanceEngine(ctx, config.EngineSQLServer, in.Name, string(info.Kind), info.Version, info.VersionNum, false, in.Tags)
	if err != nil {
		return collect.Result{Err: err, Duration: time.Since(start)}
	}
	if ok, why := c.Applies(info); !ok {
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "skipped", why)
		return collect.Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
	}
	rows, err := c.Run(ctx, conn, info)
	if errors.Is(err, collect.ErrSkip) {
		why := strings.TrimSuffix(err.Error(), ": "+collect.ErrSkip.Error())
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "skipped", why)
		return collect.Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
	}
	if err != nil {
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "error", err.Error())
		return collect.Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	collect.ApplyTextPolicy(rows, in.QueryText)
	if err := r.Import(ctx, instanceID, name, start, rows); err != nil {
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "error", err.Error())
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
	_ = r.LogCollection(ctx, instanceID, name, start, d, status, note)
	log.Debug("collected", "instance", in.Name, "collection", name, "rows", len(rows), "ms", d.Milliseconds())
	return collect.Result{Rows: len(rows), Duration: d, Note: partialNote(status, note)}
}

func partialNote(status, note string) string {
	if status != "partial" {
		return ""
	}
	return " (partial: " + note + ")"
}
