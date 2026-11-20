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
	"github.com/aachaemenes/pgvigil/internal/secrets"
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
	// Start: when the run began - collection_log's snapshot_at for it; the hourly health rows file the run under its
	// hour. Zero = not known (the clock at the record is used).
	Start    time.Time
	Rows     int
	Duration time.Duration
	Note     string // " (skipped: <why>)" when the collection does not apply
	Err      error
	Outcome  string // OutcomePartial when the run ended with a collector error row, OutcomeImportFailed; "" = derived (outcomeOf)
	// B6g-1 (N27): the time the run spent writing into the repository (the Import calls only), apart from its read;
	// Imported = a write was attempted (its time counts, 0 ms too). Duration stays the whole run.
	Import   time.Duration
	Imported bool
	// B6g-1 (N25 / N26): the run's own session's cpu_time (ms) and logical_reads, read at the run's end on SQL
	// Server; nil = not read (PostgreSQL has no such read in pgvigil; an end read that failed)
	CPUMs, Reads *int64
	// Retries: the run's imports taken again after a deadlock (sched's loop sets it from repo.WithRetryCounter; N4)
	Retries int
}

// TimedImport runs one write into the repository and adds its time to the run's import time; a write that fails
// marks the run 'import failed' (its caller returns the error as the run's Err). Two imports of one run sum.
func (res *Result) TimedImport(write func() error) error {
	t0 := time.Now()
	err := write()
	res.Import += time.Since(t0)
	res.Imported = true
	if err != nil {
		res.Outcome = OutcomeImportFailed
	}
	return err
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
		return nil, InstanceConnect(in.Name, fmt.Errorf("connect %s: dsn %q resolved to an empty string (unset variable or unreadable file)", in.Name, in.DSNRaw))
	}
	// task 201 DONE-2 (N10): pgx.Connect's own two steps, with DefaultConnectTimeout where the DSN sets no
	// connect_timeout; a DSN that does not parse is a failed connect, as before
	cfg, err := pgx.ParseConfig(dsn)
	var conn *pgx.Conn
	var took time.Duration
	if err == nil {
		withConnectTimeout(cfg)
		t0 := time.Now()
		// the password from AWS Secrets Manager first (B24e): the target is recorded right before the dial, and a
		// secret that cannot be read is not the server's failure, so it is not reported as a connect
		conn, err = dialWithSecret(ctx, in, cfg, func() { InstanceTarget(in.Name, PgTarget(cfg)); t0 = time.Now() }, // task 201 DONE-2 N8
			func(c *pgx.ConnConfig) (*pgx.Conn, error) { return pgx.ConnectConfig(ctx, c) })
		var se *secrets.ReadError
		if errors.As(err, &se) {
			return nil, fmt.Errorf("connect %s: %w", in.Name, err)
		}
		took = connTook(t0) // the slow-connect tier: the connect itself, the session setup after it not counted
	}
	err = InstanceConnectTimed(in.Name, err, took)
	if err != nil {
		return nil, fmt.Errorf("connect %s: %w", in.Name, err)
	}
	if _, err := conn.Exec(ctx, sessionSetup); err != nil {
		_ = conn.Close(ctx)
		return nil, fmt.Errorf("session setup %s: %w", in.Name, err)
	}
	if nc := conn.PgConn().Conn(); nc != nil && nc.RemoteAddr() != nil {
		NoteRemote(in.Name, nc.RemoteAddr().String()) // B24h-1b: the probe's target is the address this connection used
	}
	return conn, nil
}

// RunOnce runs one collection against one instance and stores the rows.
func RunOnce(ctx context.Context, log *slog.Logger, r *repo.Repo, in config.Instance, name string) (res Result) {
	c, ok := Get(name)
	if !ok {
		return Result{Err: fmt.Errorf("unknown collection %q; known: %v", name, Names())}
	}
	start := time.Now()
	// every return carries the run's start, the time its collection_log row is written under (B6f3 #1)
	defer func() {
		if res.Start.IsZero() {
			res.Start = start
		}
	}()
	if skip, why := Gated(c, in); skip {
		return Result{Note: " (skipped: " + why + ")"}
	}
	conn, err := Connect(ctx, in)
	if err != nil {
		// the server did not answer: recorded, so the 'server unreachable' finding sees it (0118); a connect cut by
		// pgvigil's own shutdown (ctx cancelled) is not the server's failure and is not recorded
		var se *secrets.ReadError
		if errors.As(err, &se) && ctx.Err() == nil {
			// the password could not be read from AWS Secrets Manager (B24e): the collection's error, not the server's
			if lerr := r.LogSecretFailure(ctx, in.Name, config.EnginePostgres, in.Platform, in.Tags, name, start, time.Since(start), err); lerr != nil {
				log.Warn("the secret's failure was not recorded", "instance", in.Name, "collection", name, "err", lerr)
			}
			return Result{Err: err, Duration: time.Since(start)}
		}
		if ctx.Err() == nil {
			if lerr := r.LogConnectFailure(ctx, in.Name, config.EnginePostgres, in.Platform, in.Tags, name, start, time.Since(start), err); lerr != nil {
				log.Warn("the failed connect was not recorded", "instance", in.Name, "collection", name, "err", lerr)
			}
		}
		return Result{Err: err, Duration: time.Since(start)}
	}
	defer func() { _ = conn.Close(ctx) }()
	// the minute's query round trip on this connection, when no collection of the instance took it yet (B24h-1a)
	MeasurePgRoundTrip(ctx, in.Name, conn)

	info, err := platform.Detect(ctx, conn, in.Platform)
	if err != nil {
		// connected, then failed: recorded as the collection's failed run ('detect: '), so its failures in a
		// row reach the run status as the hourly counts do; a read cut by pgvigil's own shutdown is not recorded
		if ctx.Err() == nil {
			if lerr := r.LogRunFailure(ctx, in.Name, config.EnginePostgres, name, start, time.Since(start), err); lerr != nil {
				log.Warn("the failed run was not recorded", "instance", in.Name, "collection", name, "err", lerr)
			}
		}
		return Result{Err: err, Duration: time.Since(start)}
	}
	instanceID, err := r.EnsureInstance(ctx, in.Name, string(info.Kind), info.ServerVersion, info.ServerVersionNum, info.IsReplica, in.Tags)
	if err != nil {
		// the repository's own failure: nothing to record it in (the hourly counts still count it)
		return Result{Err: err, Duration: time.Since(start)}
	}
	// a page instance's aws: block (B24p): checked against the provider's own answer for this host before its first
	// read (pagecloud.go); refused = the instance collects without it, and a collection that needs it says why
	if in.AWS != nil && in.PageAWSHost != "" {
		if why := pageAWSVerdict(ctx, log, in, time.Now()); why != "" {
			in.AWS = nil
			if skip, _ := Gated(c, in); skip {
				why = "the page's aws: block is not used: " + why
				_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "skipped", why)
				return Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
			}
		}
	}
	if ok, why := c.Applies(info); !ok {
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "skipped", why)
		return Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
	}
	// a collection imported in parts (the schema collection: one call per database, under jsonb's 256 MB limit)
	if br, ok := c.(BatchRunner); ok {
		return runBatched(ctx, log, r, in, name, br, conn, info, instanceID, start)
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
	// query-text policy before the text policy below empties the log row's own copy under normalized and none. They
	// are imported BEFORE the log batch: the batch carries the reader's cursor, so a failed plans import leaves the
	// cursor where it was and the next run reads the same lines again (import_plans is idempotent on the plan key).
	var imp Result // the run's import time and, when a write fails, its outcome (B6g-1, N27)
	if extra := planRowsFromLog(name, rows, in.QueryText); len(extra) > 0 {
		if err := imp.TimedImport(func() error { return r.Import(ctx, instanceID, "plans", start, extra) }); err != nil {
			_ = r.LogCollectionStage(ctx, instanceID, name, start, time.Since(start), "error", err.Error(), "import")
			return Result{Err: fmt.Errorf("import plans from %s's %s: %w", in.Name, name, err), Duration: time.Since(start),
				Outcome: imp.Outcome, Import: imp.Import, Imported: true}
		}
	}
	applyTextPolicy(rows, in.QueryText)
	// a collector's note (kind collector_note: a part it does not read on this platform) goes to the collection's log,
	// never to the import
	var notes []string
	kept := rows[:0]
	for _, row := range rows {
		if row["kind"] == "collector_note" {
			notes = append(notes, fmt.Sprintf("%v", row["message"]))
			continue
		}
		kept = append(kept, row)
	}
	rows = kept
	if err := imp.TimedImport(func() error { return r.Import(ctx, instanceID, name, start, rows) }); err != nil {
		_ = r.LogCollectionStage(ctx, instanceID, name, start, time.Since(start), "error", err.Error(), "import")
		return Result{Err: fmt.Errorf("import %s from %s: %w", name, in.Name, err), Duration: time.Since(start),
			Outcome: imp.Outcome, Import: imp.Import, Imported: true}
	}
	d := time.Since(start)
	status, note := "ok", strings.Join(notes, "; ")
	for _, row := range rows {
		if row["kind"] == "collector_error" {
			status, note = "partial", fmt.Sprintf("%v: %v", row["source"], row["message"])
			if len(notes) > 0 { // a failed part does not hide what was not read on this platform
				note += "; " + strings.Join(notes, "; ")
			}
			break
		}
	}
	_ = r.LogCollection(ctx, instanceID, name, start, d, status, note)
	log.Debug("collected", "instance", in.Name, "collection", name, "rows", len(rows), "ms", d.Milliseconds())
	return Result{Rows: len(rows), Duration: d, Outcome: partialOutcome(status), Import: imp.Import, Imported: imp.Imported}
}
