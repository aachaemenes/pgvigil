package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
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
	// Deadline is when the collector stops starting new batches: the run's deadline less a margin for the last
	// batch's read.
	Deadline time.Time
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
	LogCollection(ctx context.Context, instanceID int, collection string, snapshotAt time.Time, d time.Duration, status, note string) error
}

// runBatched is RunOnce's path for a BatchCollector. sctx is the run's SQL Server side context (its deadline is the
// collector's Timeout); every repository call gets its own repoTimeout on a context that deadline does not cut.
func runBatched(ctx, sctx context.Context, log *slog.Logger, st batchStore, in config.Instance, name string, bc BatchCollector,
	conn *sql.Conn, info Info, instanceID int, start time.Time, limit time.Duration) collect.Result {
	repoCtx := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
	}
	logRun := func(status, note string) {
		rctx, cancel := repoCtx()
		defer cancel()
		if err := st.LogCollection(rctx, instanceID, name, start, time.Since(start), status, note); err != nil {
			log.Warn("the collection's result was not recorded", "instance", in.Name, "collection", name, "status", status, "err", err)
		}
	}
	n, batches := 0, 0
	status, note := "ok", ""
	opt := BatchOptions{QueryText: in.QueryText, Deadline: start.Add(limit - batchMargin)}
	if dl, ok := sctx.Deadline(); ok && dl.Add(-batchMargin).Before(opt.Deadline) {
		opt.Deadline = dl.Add(-batchMargin)
	}
	cursor := func(_ context.Context, source string) (Cursor, error) {
		rctx, cancel := repoCtx()
		defer cancel()
		f, off, at, seq, found, err := st.MSSQLCursor(rctx, instanceID, source)
		if err != nil {
			return Cursor{}, fmt.Errorf("the cursor of %s: %w", source, err)
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
		if err := st.Import(rctx, instanceID, name, start, rows); err != nil {
			return err
		}
		batches++
		for _, row := range rows {
			switch row["kind"] {
			case CursorKind, "state":
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
		err = timeoutNote(sctx, limit, err)
		logRun("error", err.Error())
		return collect.Result{Rows: n, Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	d := time.Since(start)
	logRun(status, note)
	log.Debug("collected", "instance", in.Name, "collection", name, "rows", n, "batches", batches, "ms", d.Milliseconds())
	return collect.Result{Rows: n, Duration: d, Note: partialNote(status, note)}
}
