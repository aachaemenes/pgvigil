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
	"fmt"
	"log/slog"
	"sort"
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
	conn, err := Connect(ctx, in)
	if err != nil {
		return Result{Err: err, Duration: time.Since(start)}
	}
	defer conn.Close(ctx)

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
	rows, err := c.Run(ctx, conn, info)
	if err != nil {
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "error", err.Error())
		return Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	if err := r.Import(ctx, instanceID, name, start, rows); err != nil {
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "error", err.Error())
		return Result{Err: fmt.Errorf("import %s from %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	d := time.Since(start)
	_ = r.LogCollection(ctx, instanceID, name, start, d, "ok", "")
	log.Debug("collected", "instance", in.Name, "collection", name, "rows", len(rows), "ms", d.Milliseconds())
	return Result{Rows: len(rows), Duration: d}
}
