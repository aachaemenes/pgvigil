package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

// The batch path: a collection that reads its source from a cursor (an Extended Events file, a ring buffer).
//
// Such a collector does not hand RunOnce one slice of rows. It reads its cursor from the repository, reads a bounded
// number of events past it, and emits them TOGETHER WITH the cursor's new position as one batch; the batch is one
// import call, which is one repository transaction, so a batch is stored with its cursor moved or not at all, and a
// run that dies between two batches loses nothing and reads nothing twice. It repeats until the source is caught up
// or the run's own deadline is near, and the next run goes on from the stored cursor.

// Cursor is how far one source of an instance was read (pgvigil.mssql_cursor). An event_file source uses FileName
// and FileOffset (the last block read); a ring buffer uses LastEventAt and LastSeq (the newest event read).
type Cursor struct {
	Found       bool // false: the source was never read
	FileName    string
	FileOffset  int64
	LastEventAt time.Time
	LastSeq     int64
}

// CursorKind is the kind of the row that moves a cursor; the import function stores it with the batch's events.
const CursorKind = "cursor"

// Row is the cursor as a batch's row for one source.
func (c Cursor) Row(source string) collect.Row {
	row := collect.Row{"kind": CursorKind, "source": source, "file_name": nil, "file_offset": nil, "last_event_at": nil, "last_seq": c.LastSeq}
	if c.FileName != "" {
		row["file_name"], row["file_offset"] = c.FileName, c.FileOffset
	}
	if !c.LastEventAt.IsZero() {
		row["last_event_at"] = c.LastEventAt.UTC().Format(time.RFC3339Nano)
	}
	return row
}

// CursorFunc returns the stored cursor of one source of the run's instance.
type CursorFunc func(ctx context.Context, source string) (Cursor, error)

// EmitFunc stores one batch: the instance's query-text policy, then one import call. An error means nothing of the
// batch was stored, the cursor included; the collector stops reading that source.
type EmitFunc func(rows []collect.Row) error

// BatchOptions is what a batch run gives its collector.
type BatchOptions struct {
	// QueryText is the instance's query-text policy (full, normalized, none) for text a collector nests inside a
	// row (a deadlock's processes); the top-level statement columns are rewritten by the emit.
	QueryText string
	// AuditText is the instance's audit_text switch: the audit reader stores a listed event's statement text only
	// with it (and then under QueryText).
	AuditText bool
	// Deadline is when the collector stops starting new batches: the run's deadline less a margin for the last
	// batch's read.
	Deadline time.Time
	// SchemaDatabases is the instance's mssql_schema.databases list (the schema collection's scope: '*', names,
	// '-name' to leave one out); empty = the collection is off on this instance.
	SchemaDatabases []string
	// SchemaDue asks the repository which databases a schema pass reads whole (import_mssql_schema_due); nil when
	// the run has no repository.
	SchemaDue func(ctx context.Context, payload []byte) ([]byte, error)
}

// schemaDueStore is the repository's side of SchemaDue (*repo.Repo has it); a batchStore without it gives none.
type schemaDueStore interface {
	MSSQLSchemaDue(ctx context.Context, instanceID int, snapshotAt time.Time, payload []byte) ([]byte, error)
}

// BatchCollector is a Collector that reads from a cursor. RunOnce calls RunBatches instead of Run; an error it
// returns fails the run (the batches already emitted stay stored, with their cursors).
type BatchCollector interface {
	Collector
	RunBatches(ctx context.Context, conn *sql.Conn, info Info, opt BatchOptions, cursor CursorFunc, emit EmitFunc) error
}

// batchMargin is how long before the run's deadline a batch collector stops starting new batches.
const batchMargin = 10 * time.Second

// batchStore is what the batch path needs of the repository (*repo.Repo has all three).
type batchStore interface {
	MSSQLCursor(ctx context.Context, instanceID int, source string) (fileName string, fileOffset int64, lastEventAt time.Time, lastSeq int64, found bool, err error)
	Import(ctx context.Context, instanceID int, collection string, snapshotAt time.Time, rows []map[string]any) error
	LogCollectionStage(ctx context.Context, instanceID int, collection string, snapshotAt time.Time, d time.Duration, status, note, stage string) error
}

// runBatched is RunOnce's path for a BatchCollector. sctx is the run's SQL Server side context (its deadline is the
// collector's Timeout); every repository call gets its own repoTimeout on a context that deadline does not cut.
func runBatched(ctx, sctx context.Context, log *slog.Logger, st batchStore, in config.Instance, name string, bc BatchCollector,
	conn *sql.Conn, info Info, instanceID int, start time.Time, limit time.Duration) collect.Result {
	repoCtx := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
	}
	// a failed repository call - a batch's import, or the read of the collector's own cursor - makes the run's stage
	// 'import' (0198), whether RunBatches returned the error or turned it into a collector_error row and went on (the
	// Extended Events and audit readers' fail()); the first such error leads the run's note, so the note and the stage
	// tell of the same failure
	stage, repoErr := "", ""
	repoFailed := func(msg string) {
		stage = "import"
		if repoErr == "" {
			repoErr = msg
		}
	}
	logRun := func(status, note string) {
		rctx, cancel := repoCtx()
		defer cancel()
		if err := st.LogCollectionStage(rctx, instanceID, name, start, time.Since(start), status, note, stage); err != nil {
			log.Warn("the collection's result was not recorded", "instance", in.Name, "collection", name, "status", status, "err", err)
		}
	}
	n, batches := 0, 0
	status, note := "ok", ""
	// every batch's write is timed (B6g-1, N27); the run is 'import failed' only when it ENDED as an error at the
	// repository's side (stage 'import') - a batch refused while the run went on leaves it 'partial', as its log row says
	var imp collect.Result
	var lastImport *collect.ImportError // the import error last handed back to the reader: the run ended at it, or went on
	opt := BatchOptions{QueryText: in.QueryText, AuditText: in.AuditText, Deadline: start.Add(limit - batchMargin)}
	if in.MSSQLSchema != nil {
		opt.SchemaDatabases = in.MSSQLSchema.Databases
	}
	if dl, ok := sctx.Deadline(); ok && dl.Add(-batchMargin).Before(opt.Deadline) {
		opt.Deadline = dl.Add(-batchMargin)
	}
	if sd, ok := st.(schemaDueStore); ok {
		opt.SchemaDue = func(_ context.Context, payload []byte) ([]byte, error) {
			rctx, cancel := repoCtx()
			defer cancel()
			return sd.MSSQLSchemaDue(rctx, instanceID, start, payload)
		}
	}
	cursor := func(_ context.Context, source string) (Cursor, error) {
		rctx, cancel := repoCtx()
		defer cancel()
		f, off, at, seq, found, err := st.MSSQLCursor(rctx, instanceID, source)
		if err != nil {
			err = fmt.Errorf("the cursor of %s: %w", source, err)
			repoFailed(err.Error())
			return Cursor{}, err
		}
		return Cursor{Found: found, FileName: f, FileOffset: off, LastEventAt: at, LastSeq: seq}, nil
	}
	emit := func(rows []collect.Row) error {
		if len(rows) == 0 {
			return nil
		}
		collect.ApplyTextPolicy(rows, in.QueryText)
		rctx, cancel := repoCtx()
		defer cancel()
		if err := imp.TimedImport(func() error { return st.Import(rctx, instanceID, name, start, rows) }); err != nil {
			ie := &collect.ImportError{Err: err}
			lastImport = ie
			repoFailed("import: " + err.Error())
			return ie
		}
		batches++
		for _, row := range rows {
			switch row["kind"] {
			case CursorKind, "state", "foreign_session", "sessions_read": // DBA Dash's sessions (task 206): not collected rows
			case "collector_error":
				if status == "ok" {
					status, note = "partial", fmt.Sprintf("%v: %v", row["source"], row["message"])
				}
			default:
				n++
			}
		}
		return nil
	}
	if err := bc.RunBatches(sctx, conn, info, opt, cursor, emit); err != nil {
		// a collection off on this instance (the schema collection without its mssql_schema key) is skipped, as the
		// plain path skips one (mssql.go)
		if errors.Is(err, collect.ErrSkip) {
			why := strings.TrimSuffix(err.Error(), ": "+collect.ErrSkip.Error())
			logRun("skipped", why)
			return collect.Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
		}
		err = timeoutNote(sctx, limit, err)
		logRun("error", err.Error())
		out := collect.Result{Rows: n, Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start), Import: imp.Import, Imported: imp.Imported}
		if collect.EndedAtImport(err, lastImport) {
			out.Outcome = collect.OutcomeImportFailed
		}
		return out
	}
	d := time.Since(start)
	note = collect.LeadNote(repoErr, note)
	logRun(status, note)
	log.Debug("collected", "instance", in.Name, "collection", name, "rows", n, "batches", batches, "ms", d.Milliseconds())
	return collect.Result{Rows: n, Duration: d, Note: partialNote(status, note), Outcome: collect.PartialOutcome(status),
		Import: imp.Import, Imported: imp.Imported}
}
