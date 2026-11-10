// Package collect holds one Collector per collection type, the registry that
// names them, and RunOnce, which connects, detects the platform, runs the
// collection and hands its rows to the repository.
//
// A collection is: a name, a default interval, an applicability rule
// (platform and version), and a Run that returns rows as JSON-ready maps.
// The repository side (repo/sql) has an import function per collection that
// takes the instance id, the snapshot time and a JSONB array of those rows.
package collect

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// Row is one collected record, column name to value.
type Row = map[string]any

// Collector is one collection type.
type Collector interface {
	// Name is the collection's name as the config, the CLI and the repository know it.
	Name() string
	// DefaultInterval is the cadence when nothing overrides it; zero = off by default.
	DefaultInterval() time.Duration
	// Applies says whether the collection runs on this platform and version.
	Applies(platform.Info) (ok bool, why string)
	// Run executes the collection on an open connection.
	Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error)
}

// InstanceRunner is a Collector that also needs the instance's config and its stored log cursor
// (the log reader); RunOnce calls RunInstance instead of Run when a collector has it.
type InstanceRunner interface {
	RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, cursor CursorFunc) ([]Row, error)
}

// CursorFunc returns how far a source was read, and false when it never was.
type CursorFunc func(ctx context.Context, source string) (time.Time, bool, error)

// ConfigGate is a Collector that only runs on an instance whose config names its source (an aws:
// block); the scheduler skips the others without a connection, and RunOnce says why.
type ConfigGate interface {
	Configured(in config.Instance) (ok bool, why string)
}

// Gated reports whether a collection is off for an instance by its config alone.
func Gated(c Collector, in config.Instance) (skip bool, why string) {
	if g, ok := c.(ConfigGate); ok {
		if ok, why := g.Configured(in); !ok {
			return true, why
		}
	}
	return false, ""
}

// ErrSkip is returned (wrapped, with the reason) by a run that does not apply to this instance's config.
var ErrSkip = errors.New("skipped")

var registry = map[string]Collector{}

// Register adds a collector; called from each collector's init.
func Register(c Collector) {
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

// Result is what one run produced.
type Result struct {
	Rows     int
	Duration time.Duration
	Note     string // " (skipped: <why>)" when the collection does not apply
	Err      error
}

// sessionSetup keeps a collector from joining a convoy on a busy server: read
// only, a statement timeout and a short lock timeout, an application_name for
// pg_stat_activity readers.
const sessionSetup = `SET default_transaction_read_only = on;
SET statement_timeout = '30s';
SET lock_timeout = '2s';
SET application_name = 'pgvigil';`

// Connect opens one connection to an instance with the safety settings applied.
func Connect(ctx context.Context, in config.Instance) (*pgx.Conn, error) {
	dsn := in.DSN()
	if dsn == "" {
		return nil, fmt.Errorf("connect %s: dsn %q resolved to an empty string (unset variable or unreadable file)", in.Name, in.DSNRaw)
	}
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("connect %s: %w", in.Name, err)
	}
	if _, err := conn.Exec(ctx, sessionSetup); err != nil {
		_ = conn.Close(ctx)
		return nil, fmt.Errorf("session setup %s: %w", in.Name, err)
	}
	return conn, nil
}

// RunOnce runs one collection against one instance and stores the rows.
func RunOnce(ctx context.Context, log *slog.Logger, r *repo.Repo, in config.Instance, name string) Result {
	c, ok := Get(name)
	if !ok {
		return Result{Err: fmt.Errorf("unknown collection %q; known: %v", name, Names())}
	}
	start := time.Now()
	if skip, why := Gated(c, in); skip {
		return Result{Note: " (skipped: " + why + ")"}
	}
	conn, err := Connect(ctx, in)
	if err != nil {
		return Result{Err: err, Duration: time.Since(start)}
	}
	defer func() { _ = conn.Close(ctx) }()

	info, err := platform.Detect(ctx, conn, in.Platform)
	if err != nil {
		return Result{Err: err, Duration: time.Since(start)}
	}
	instanceID, err := r.EnsureInstance(ctx, in.Name, string(info.Kind), info.ServerVersion, info.ServerVersionNum, info.IsReplica, in.Tags)
	if err != nil {
		return Result{Err: err, Duration: time.Since(start)}
	}
	if ok, why := c.Applies(info); !ok {
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "skipped", why)
		return Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
	}
	var rows []Row
	if ir, ok := c.(InstanceRunner); ok {
		rows, err = ir.RunInstance(ctx, conn, info, in, func(ctx context.Context, source string) (time.Time, bool, error) {
			return r.LogCursor(ctx, instanceID, source)
		})
	} else {
		rows, err = c.Run(ctx, conn, info)
	}
	if errors.Is(err, ErrSkip) {
		why := strings.TrimSuffix(err.Error(), ": "+ErrSkip.Error())
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "skipped", why)
		return Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
	}
	if err != nil {
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "error", err.Error())
		return Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	// the log readers' auto_explain lines become plan rows too (the plans table, 0029), masked by the instance's
	// query-text policy before the text policy below empties the log row's own copy under normalized and none
	extra := planRowsFromLog(name, rows, in.QueryText)
	applyTextPolicy(rows, in.QueryText)
	if err := r.Import(ctx, instanceID, name, start, rows); err != nil {
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "error", err.Error())
		return Result{Err: fmt.Errorf("import %s from %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	if len(extra) > 0 {
		if err := r.Import(ctx, instanceID, "plans", start, extra); err != nil {
			_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "error", err.Error())
			return Result{Err: fmt.Errorf("import plans from %s's %s: %w", in.Name, name, err), Duration: time.Since(start)}
		}
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
	return Result{Rows: len(rows), Duration: d}
}
