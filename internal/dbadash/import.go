package dbadash

// The DBADash import (task 92): a DBADash repository's history loaded into pgvigil's own SQL Server tables, so a site
// that moves from DBADash to pgvigil keeps what DBADash collected. It reads the repository through the door's read
// login (SELECT on the dbo schema) and writes the pgvigil repository through its own functions (0134's
// import_dbadash_instance and import_dbadash_<mapping>, the collector's door: a login in role pgvigil_collector or the
// owner; no other login writes the history tables), one pgvigil row per DBADash row - the collector's import functions
// take a live read of a server (its clock, its counters, its cursors) and a replay of history is not one. A server
// moved from DBA Dash (task 206, Admin > Instances) is imported into its moved instance up to pgvigil's first read of
// it, and only after that read: the functions hold the bound and the order, whatever -to the caller gives.
//
// What is imported, per DBADash instance (docs/dbadash.md has the table of mappings and what is not imported):
//   - the instance: a pgvigil SQL Server instance under DBADash's display name, with DBADash's tags (an instance of
//     that name pgvigil already monitors keeps its own description and tags; one stored as PostgreSQL is skipped);
//   - cpu      dbo.CPU                                  -> mssql_cpu_sample
//   - volumes  dbo.DriveSnapshot + dbo.Drives            -> mssql_volume_sample
//   - dbsize   dbo.DBFileSnapshot + DBFiles + Databases  -> mssql_database_size (one row per snapshot and database)
//   - jobruns  dbo.JobHistory + dbo.Jobs                 -> mssql_job_runs
// Idempotent and resumable: a row already stored (the same instance, time and key) is skipped, every batch commits on
// its own, so a run cut short is run again and goes on where it stopped; a dry run reads the counts only. Each mapping
// reports the DBADash rows of the window, the rows inserted now and the rows pgvigil holds for the window after.

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
)

// ImportOptions shape one import.
type ImportOptions struct {
	// From and To bound the history taken (UTC); a zero From = everything DBADash keeps, a zero To = now.
	From, To time.Time
	// Instances are DBADash InstanceIDs; empty = every active SQL Server instance (Azure SQL databases left out).
	Instances []int
	// DryRun reads and counts; nothing is written to pgvigil.
	DryRun bool
	// Batch is the rows per insert (one transaction each); 0 = DefaultImportBatch.
	Batch int
	// Names maps a DBADash InstanceID to the pgvigil instance name to use (the name pgvigil.yaml will monitor it
	// under); an instance not named here takes DBADash's display name. A moved server's InstanceID goes to its move.
	Names map[int]string
	// Repository is the dbadash: repository's name in the configuration (the key of a move's InstanceIDs).
	Repository string
	// By names who runs it on a moved server's run marks (0134's import_dbadash_move run / ended); default "cli".
	By string
	// Store, when set, is the pgvigil repository the import writes through (serve's own pool, task 206's page); Import
	// checks its rights as it checks repoDSN's and leaves it open. Nil = Import opens repoDSN and closes it at the end.
	Store *pgxpool.Pool
	// Progress, when set, is called after every batch a mapping inserts (final false: Inserted so far, Stored not read
	// yet) and once when the mapping ends (final true: the count Import answers), on Import's own goroutine.
	Progress func(c ImportCount, final bool)
	// Run is a moved server's run its caller has marked already (serve's page takes the mark before it answers): Import
	// carries that run, beats it and ends it, whatever ends the run (an error, a panic); nil = Import marks its own.
	Run *MoveRun
}

// MoveRun is a run mark taken on a moved server's move (0134's import_dbadash_move run): the server's pgvigil name and
// the run's id.
type MoveRun struct {
	Name string
	ID   int64
}

// beatEvery is how often a moved server's run writes its beat: before each mapping's count, before its rows and
// between batches (0134 lets another run take a move over after 15 minutes without one). A variable: the store tests
// set it to 0.
var beatEvery = time.Minute

// moveRun is one moved server's run inside Import: one mark around all the InstanceIDs DBA Dash lists it under, ended
// ok only when every one ended ok.
type moveRun struct {
	id       int64
	marked   string // why no mark was taken (another run holds the move)
	imported map[string]any
	outcome  string
	lastBeat time.Time
	ended    bool
}

// DefaultImportBatch is the rows of one insert.
const DefaultImportBatch = 2000

// ImportCount is one mapping of one instance: what DBADash holds for the window, what was inserted now and what
// pgvigil holds for the window after; Skipped says why nothing was imported.
type ImportCount struct {
	Instance  string `json:"instance"`
	DBADashID int    `json:"dbadash_instance_id"`
	PgvigilID int    `json:"pgvigil_instance_id,omitempty"`
	Mapping   string `json:"mapping"`
	Source    int64  `json:"source"`
	Inserted  int64  `json:"inserted"`
	Stored    int64  `json:"stored"`
	Skipped   string `json:"skipped,omitempty"`
	// Bound is a moved server's: its history is taken up to pgvigil's first read of it, whatever -to says.
	Bound *time.Time `json:"bound,omitempty"`
}

// importMapping is one DBADash history table and its pgvigil home. The T-SQL takes @id, @from and @to; rows aliases
// its columns as the record names of the mapping's function (0134's import_dbadash_<Key>: instance_id, the batch as
// JSON, the instance's facts {"linux": bool}; it answers the rows it inserted) and orders by time ('at' is the row's
// UTC time).
type importMapping struct {
	Key, Table, Count, Rows string
}

var importMappings = []importMapping{
	{
		Key: "cpu", Table: "mssql_cpu_sample",
		Count: `SELECT COUNT_BIG(*) FROM dbo.CPU WHERE InstanceID = @id AND EventTime >= @from AND EventTime < @to`,
		Rows: `SELECT EventTime AS at, CAST(SQLProcessCPU AS int) AS sql_pct, CAST(SystemIdleCPU AS int) AS idle_pct
  FROM dbo.CPU WHERE InstanceID = @id AND EventTime >= @from AND EventTime < @to ORDER BY EventTime`,
		// the negative record number, the 30-second skip beside the collector's own minutes and Linux's empty idle figure:
		// 0134's import_dbadash_cpu
	},
	{
		Key: "volumes", Table: "mssql_volume_sample",
		Count: `SELECT COUNT_BIG(*) FROM dbo.DriveSnapshot S JOIN dbo.Drives D ON D.DriveID = S.DriveID
 WHERE D.InstanceID = @id AND S.SnapshotDate >= @from AND S.SnapshotDate < @to`,
		Rows: `SELECT S.SnapshotDate AS at, D.Name AS volume, S.Capacity AS total_bytes, S.FreeSpace AS free_bytes
  FROM dbo.DriveSnapshot S JOIN dbo.Drives D ON D.DriveID = S.DriveID
 WHERE D.InstanceID = @id AND S.SnapshotDate >= @from AND S.SnapshotDate < @to ORDER BY S.SnapshotDate, S.DriveID`,
	},
	{
		// DBADash keeps file sizes in 8 KB pages (sys.database_files' unit): bytes are pages * 8192; the collector's rule
		// (0067's import_mssql_storage): data is every file but the log (type 1), the log the LOG files, a size 0 when the
		// side has no file, a used figure only when every file of that side was read
		Key: "dbsize", Table: "mssql_database_size",
		Count: `SELECT COUNT_BIG(*) FROM (SELECT S.SnapshotDate, F.DatabaseID
  FROM dbo.DBFileSnapshot S JOIN dbo.DBFiles F ON F.FileID = S.FileID JOIN dbo.Databases D ON D.DatabaseID = F.DatabaseID
 WHERE D.InstanceID = @id AND S.SnapshotDate >= @from AND S.SnapshotDate < @to
 GROUP BY S.SnapshotDate, F.DatabaseID) g`,
		Rows: `SELECT S.SnapshotDate AS at, MAX(D.name) AS database_name,
       ISNULL(SUM(CASE WHEN F.type <> 1 THEN S.Size END), 0) * 8192 AS data_bytes, ISNULL(SUM(CASE WHEN F.type = 1 THEN S.Size END), 0) * 8192 AS log_bytes,
       CASE WHEN SUM(CASE WHEN F.type <> 1 THEN 1 ELSE 0 END) > 0 AND SUM(CASE WHEN F.type <> 1 AND S.space_used IS NULL THEN 1 ELSE 0 END) = 0
            THEN SUM(CASE WHEN F.type <> 1 THEN S.space_used END) * 8192 END AS data_used_bytes,
       CASE WHEN SUM(CASE WHEN F.type = 1 THEN 1 ELSE 0 END) > 0 AND SUM(CASE WHEN F.type = 1 AND S.space_used IS NULL THEN 1 ELSE 0 END) = 0
            THEN SUM(CASE WHEN F.type = 1 THEN S.space_used END) * 8192 END AS log_used_bytes, COUNT(*) AS files
  FROM dbo.DBFileSnapshot S JOIN dbo.DBFiles F ON F.FileID = S.FileID JOIN dbo.Databases D ON D.DatabaseID = F.DatabaseID
 WHERE D.InstanceID = @id AND S.SnapshotDate >= @from AND S.SnapshotDate < @to
 GROUP BY S.SnapshotDate, F.DatabaseID ORDER BY S.SnapshotDate, F.DatabaseID`,
	},
	{
		// DBADash stores a run's start in UTC (msdb's local time plus the instance's UTC offset); msdb's own run_date and
		// run_time integers (the server's local clock) are rebuilt with the instance's CURRENT offset, so a run from before a
		// daylight-saving change shows its local time an hour off (docs/dbadash.md); history_id is msdb's own
		// sysjobhistory.instance_id, which DBADash keeps
		Key: "jobruns", Table: "mssql_job_runs",
		Count: `SELECT COUNT_BIG(*) FROM dbo.JobHistory WHERE InstanceID = @id AND RunDateTime >= @from AND RunDateTime < @to`,
		Rows: `SELECT H.RunDateTime AS at, CAST(H.instance_id AS bigint) AS history_id, CONVERT(char(36), H.job_id) AS job_id, J.name AS job_name,
       H.step_id, H.step_name, H.run_status, H.RunDurationSec AS duration_s, H.sql_message_id, H.sql_severity,
       H.retries_attempted AS retries, H.message, DATEADD(minute, -ISNULL(I.UTCOffset, 0), H.RunDateTime) AS local_at
  FROM dbo.JobHistory H
  JOIN dbo.Instances I ON I.InstanceID = H.InstanceID
  LEFT JOIN dbo.Jobs J ON J.InstanceID = H.InstanceID AND J.job_id = H.job_id
 WHERE H.InstanceID = @id AND H.RunDateTime >= @from AND H.RunDateTime < @to ORDER BY H.RunDateTime, H.instance_id`,
	},
}

// ImportMappings names the mappings in the order they run (the docs' table, the proof's).
func ImportMappings() []string {
	out := make([]string, 0, len(importMappings))
	for _, m := range importMappings {
		out = append(out, m.Key+" -> "+m.Table)
	}
	return out
}

// srcInstance is one DBADash instance to import.
type srcInstance struct {
	ID       int
	Instance string
	Display  string
	Version  string
	Linux    bool
	Edition  int
	Tags     []string
}

// Import loads the history of a DBADash repository (srcDSN, the door's read login) into the pgvigil repository
// (repoDSN: a login in role pgvigil_collector, or the owner). The error is the whole run's; an instance or mapping that
// cannot be imported now (a moved server not read yet, or waiting for the collector's own first reads) is a count with
// its reason, and the run goes on. A real run of a moved server writes its run marks on the move (run, beat after each
// mapping, ended ok / partial / failed), so the page shows a CLI import as it shows its own; a run already marked
// there is not started twice. Every way out of a run that is not its end (an error, a panic, a run another import took
// over) ends its open marks 'failed' with why.
func Import(ctx context.Context, log *slog.Logger, srcDSN, repoDSN string, opt ImportOptions) (out []ImportCount, err error) {
	var pool *pgxpool.Pool
	ownPool := false
	runs := map[string]*moveRun{} // by the moved server's pgvigil name
	if opt.Run != nil && opt.Run.ID > 0 {
		runs[opt.Run.Name] = &moveRun{id: opt.Run.ID, imported: map[string]any{}, outcome: "ok", lastBeat: time.Now()}
		pool = opt.Store
	}
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("the import stopped on a panic: %v", p)
		}
		if err != nil && pool != nil {
			for name, r := range runs {
				if r.id > 0 && !r.ended {
					ectx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
					if _, why, merr := moveMark(ectx, pool, "ended", name, opt.By, r.id, r.imported, "failed: "+err.Error()); merr != nil || why != "" {
						log.Warn("dbadash import: the move's end mark", "instance", name, "refused", why, "err", merr)
					}
					cancel()
					r.ended = true
				}
			}
		}
		if ownPool && pool != nil {
			pool.Close()
		}
	}()
	if strings.TrimSpace(srcDSN) == "" {
		return nil, errors.New("the DBADash repository's dsn resolved to nothing")
	}
	if opt.Batch <= 0 {
		opt.Batch = DefaultImportBatch
	}
	if opt.To.IsZero() {
		opt.To = time.Now().UTC()
	}
	if opt.From.IsZero() {
		opt.From = time.Date(1900, 1, 1, 0, 0, 0, 0, time.UTC)
	}
	if !opt.From.Before(opt.To) {
		return nil, errors.New("from must be before to")
	}
	db, err := mssqlopen.Open(withAppName(srcDSN))
	if err != nil {
		return nil, fmt.Errorf("dbadash dsn: %w", err)
	}
	defer func() { _ = db.Close() }()
	db.SetMaxOpenConns(1)
	src, err := db.Conn(ctx)
	if err != nil {
		return nil, fmt.Errorf("dbadash connect: %w", err)
	}
	defer func() { _ = src.Close() }()
	var ver sql.NullString
	if err := src.QueryRowContext(ctx, `SELECT TOP (1) Version FROM dbo.DBVersionHistory ORDER BY DeployDate DESC`).Scan(&ver); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("dbo.DBVersionHistory: %w", err)
	}
	if !Proven(ver.String) {
		log.Warn("dbadash import: not proven on this DBADash version", "version", orNone(ver.String), "proven", ProvenVersion)
	}

	insts, leftOut, err := importInstances(ctx, src, opt.Instances)
	if err != nil {
		return nil, err
	}
	for _, t := range leftOut {
		log.Warn("dbadash import: a DBADash tag left out", "why", t)
	}
	out = []ImportCount{}
	found := map[int]bool{}
	for _, in := range insts {
		found[in.ID] = true
	}
	for _, id := range opt.Instances {
		if !found[id] {
			out = append(out, ImportCount{DBADashID: id, Mapping: "-", Skipped: "no SQL Server instance with this InstanceID in the repository (an Azure SQL database, or unknown)"})
		}
	}
	if pool = opt.Store; pool == nil {
		if pool, err = openImportStore(ctx, repoDSN, opt.DryRun); err != nil {
			return nil, err
		}
		ownPool = true
	} else if err := importRights(ctx, pool, opt.DryRun); err != nil {
		return nil, err
	}
	// the targets first: a moved server DBA Dash lists under several InstanceIDs is one run of one move
	tgts := make([]importTargetRow, len(insts))
	left := map[string]int{} // a moved server's InstanceIDs still to run
	for i, in := range insts {
		name := in.Display
		if n := strings.TrimSpace(opt.Names[in.ID]); n != "" {
			name = n
		}
		if tgts[i], err = importTarget(ctx, log, pool, opt.Repository, name, in, opt.DryRun); err != nil {
			return out, err
		}
		if tgts[i].Moved {
			left[tgts[i].Name]++
		}
	}
	for i, in := range insts {
		tgt := tgts[i]
		// a moved server: its own instance, its history up to pgvigil's first read of it (the functions hold it too)
		to, none := importBound(opt.From, opt.To, tgt)
		run := runs[tgt.Name]
		if run == nil && tgt.Moved && !opt.DryRun && tgt.ID > 0 && none == "" {
			run = &moveRun{imported: map[string]any{}, outcome: "ok", lastBeat: time.Now()}
			if run.id, run.marked, err = moveMark(ctx, pool, "run", tgt.Name, opt.By, 0, nil, ""); err != nil {
				return out, err
			}
			runs[tgt.Name] = run
		}
		if run == nil {
			run = &moveRun{imported: map[string]any{}, outcome: "ok"} // not a moved server's run: nothing marked
		}
		// beat writes the run's beat when beatEvery has passed; another import that took the move over stops this one
		beat := func(so map[string]any) error {
			if run.id == 0 || time.Since(run.lastBeat) < beatEvery {
				return nil
			}
			run.lastBeat = time.Now()
			_, why, err := moveMark(ctx, pool, "beat", tgt.Name, opt.By, run.id, so, "")
			switch {
			case err != nil:
				log.Warn("dbadash import: the move's run mark", "instance", tgt.Name, "err", err)
			case why != "":
				return fmt.Errorf("%s: this run's mark was refused (%s): it stops", tgt.Name, why)
			}
			return nil
		}
		for _, m := range importMappings {
			c := ImportCount{Instance: tgt.Name, DBADashID: in.ID, PgvigilID: tgt.ID, Mapping: m.Key, Skipped: tgt.Skipped}
			if tgt.Moved {
				c.Bound = tgt.CollectFrom
			}
			for _, why := range []string{run.marked, none, tgt.Wait[m.Key]} {
				if c.Skipped == "" {
					c.Skipped = why
				}
			}
			if err := beat(run.imported); err != nil {
				return out, err
			}
			if opt.From.Before(to) {
				if err := src.QueryRowContext(ctx, m.Count, sql.Named("id", in.ID), sql.Named("from", utc2(opt.From)), sql.Named("to", utc2(to))).Scan(&c.Source); err != nil {
					return out, fmt.Errorf("%s %s: count: %w", tgt.Name, m.Key, err)
				}
			}
			if c.Skipped == "" && !opt.DryRun && opt.From.Before(to) {
				running := func(n int64) map[string]any {
					so := map[string]any{m.Key: map[string]any{"source": c.Source, "inserted": n, "running": true}}
					for k, v := range run.imported {
						if k != m.Key {
							so[k] = v
						}
					}
					return so
				}
				if err := beat(running(0)); err != nil {
					return out, err
				}
				onBatch := func(n int64) error {
					if opt.Progress != nil {
						p := c
						p.Inserted = n
						opt.Progress(p, false)
					}
					return beat(running(n))
				}
				// the job runs' history (FLEET STATS ROLLUP, 0139): the hourly statistics are only marked while the
				// batches go in and built ONCE at the end, not once per batch (a defer a dead run leaves lapses 2 hours
				// after this call, and the next write or purge builds the hours); import_* is the collector's door
				if m.Key == "jobruns" {
					if _, err := pool.Exec(ctx, `SELECT pgvigil.import_job_stats_defer($1)`, tgt.ID); err != nil {
						return out, fmt.Errorf("%s %s: the job statistics' defer: %w", tgt.Name, m.Key, err)
					}
				}
				c.Inserted, err = importOne(ctx, src, pool, m, in, tgt.ID, opt, to, onBatch)
				if m.Key == "jobruns" {
					if _, berr := pool.Exec(ctx, `SELECT pgvigil.import_job_stats_build($1)`, tgt.ID); berr != nil && err == nil {
						err = fmt.Errorf("the job statistics' build (the runs are stored; the next write or purge builds the hours): %w", berr)
					}
				}
				var pe *pgconn.PgError
				switch {
				case errors.As(err, &pe) && pe.Code == "55000":
					// the store holds this mapping back now (a read of the collector's it waits for): said, the run goes on
					c.Skipped = strings.TrimPrefix(pe.Message, "dbadash import: ")
				case err != nil:
					// what was committed before the failure stays on the record (the batches before it are stored)
					run.imported[m.Key] = map[string]any{"source": c.Source, "inserted": c.Inserted, "failed": err.Error()}
					return out, fmt.Errorf("%s %s: %w", tgt.Name, m.Key, err)
				}
			}
			if tgt.ID > 0 && opt.From.Before(to) {
				if err := pool.QueryRow(ctx, `SELECT pgvigil.dbadash_import_stored($1, $2, $3, $4)`, tgt.ID, m.Key, opt.From, to).Scan(&c.Stored); err != nil {
					return out, fmt.Errorf("%s %s: stored: %w", tgt.Name, m.Key, err)
				}
			}
			if c.Skipped != "" {
				run.outcome = "partial"
			}
			// a server DBA Dash lists under several InstanceIDs: its sources and inserts summed, stored is the server's own
			e := map[string]any{"source": c.Source, "inserted": c.Inserted, "stored": c.Stored, "skipped": c.Skipped}
			if prev, ok := run.imported[m.Key].(map[string]any); ok {
				ps, _ := prev["source"].(int64)
				pi, _ := prev["inserted"].(int64)
				e["source"], e["inserted"] = ps+c.Source, pi+c.Inserted
				if was, _ := prev["skipped"].(string); was != "" && c.Skipped == "" {
					e["skipped"] = was
				}
			}
			run.imported[m.Key] = e
			if run.id > 0 {
				if _, why, err := moveMark(ctx, pool, "beat", tgt.Name, opt.By, run.id, run.imported, ""); err != nil {
					log.Warn("dbadash import: the move's run mark", "instance", tgt.Name, "err", err)
				} else if why != "" {
					return out, fmt.Errorf("%s: this run's mark was refused (%s): it stops", tgt.Name, why)
				}
				run.lastBeat = time.Now()
			}
			log.Info("dbadash import", "instance", tgt.Name, "mapping", m.Key, "to", to, "source", c.Source, "inserted", c.Inserted, "stored", c.Stored, "skipped", c.Skipped)
			out = append(out, c)
			if opt.Progress != nil {
				opt.Progress(c, true)
			}
		}
		if tgt.Moved {
			left[tgt.Name]--
		}
		if run.id > 0 && !run.ended && left[tgt.Name] <= 0 {
			if _, why, err := moveMark(ctx, pool, "ended", tgt.Name, opt.By, run.id, run.imported, run.outcome); err != nil || why != "" {
				log.Warn("dbadash import: the move's run mark", "instance", tgt.Name, "refused", why, "err", err)
			}
			run.ended = true
		}
	}
	// a run its caller marked for a server none of whose InstanceIDs is here (DBA Dash no longer holds any): ended, said
	for name, r := range runs {
		if r.id > 0 && !r.ended {
			if _, why, err := moveMark(ctx, pool, "ended", name, opt.By, r.id, r.imported, "failed: none of its InstanceIDs is in the DBA Dash repository now"); err != nil || why != "" {
				log.Warn("dbadash import: the move's run mark", "instance", name, "refused", why, "err", err)
			}
			r.ended = true
		}
	}
	return out, nil
}

// endRun ends a run its caller marked (opt.Run) 'failed' with err when the import stops before Import (an unknown
// repository), and answers err.
func endRun(ctx context.Context, log *slog.Logger, opt ImportOptions, err error) error {
	if opt.Run == nil || opt.Run.ID == 0 || opt.Store == nil {
		return err
	}
	ectx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	defer cancel()
	if _, why, merr := moveMark(ectx, opt.Store, "ended", opt.Run.Name, opt.By, opt.Run.ID, map[string]any{}, "failed: "+err.Error()); merr != nil || why != "" {
		log.Warn("dbadash import: the move's end mark", "instance", opt.Run.Name, "refused", why, "err", merr)
	}
	return err
}

// importBound is the newest time a run takes for one instance: the caller's To, or a moved server's first read by
// pgvigil when that is earlier; none says why nothing is taken (a From at or after that first read).
func importBound(from, to time.Time, tgt importTargetRow) (time.Time, string) {
	if tgt.Moved && tgt.CollectFrom != nil && tgt.CollectFrom.Before(to) {
		to = tgt.CollectFrom.UTC()
		if !from.Before(to) {
			return to, fmt.Sprintf("nothing to import: -from is at or after pgvigil's first read of the server (%s)", to.Format(time.RFC3339))
		}
	}
	return to, ""
}

// moveMark writes one run mark on a moved server's move (0134's import_dbadash_move: run, beat or ended); a refusal
// (another run marked, a run taken over) is its words, not an error. ended's outcome may carry a detail after "failed: ".
func moveMark(ctx context.Context, pool *pgxpool.Pool, op, name, by string, runID int64, imported map[string]any, outcome string) (int64, string, error) {
	if strings.TrimSpace(by) == "" {
		by = "cli"
	}
	pay := map[string]any{"op": op, "ui_user": by, "client": "pgvigil import dbadash", "name": name}
	if op != "run" {
		pay["run_id"] = runID
		pay["imported"] = imported
	}
	if op == "ended" {
		o, detail, _ := strings.Cut(outcome, ": ")
		pay["outcome"], pay["detail"] = o, detail
	}
	b, _ := json.Marshal(pay)
	var raw []byte
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_dbadash_move(now(), $1::jsonb)::text`, string(b)).Scan(&raw); err != nil {
		return 0, "", fmt.Errorf("the move's run mark (%s %s): %w", op, name, err)
	}
	var ans struct {
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
		RunID   int64  `json:"run_id"`
	}
	if err := json.Unmarshal(raw, &ans); err != nil {
		return 0, "", fmt.Errorf("import_dbadash_move answered %q", raw)
	}
	if ans.Outcome != "done" {
		return 0, ans.Detail, nil
	}
	return ans.RunID, "", nil
}

// importInstances reads the instances to import, never an Azure SQL database: the ids asked for, active or not (a
// server moved to pgvigil is often removed in DBA Dash's GUI once DBA Dash stops collecting it, and its history stays
// in DBA Dash's tables), else every active one.
func importInstances(ctx context.Context, src *sql.Conn, want []int) ([]srcInstance, []string, error) {
	// (an id asked for that is not here - an Azure SQL database, unknown - is reported by Import)
	rows, err := src.QueryContext(ctx, `
SELECT I.InstanceID, I.Instance, ISNULL(I.Alias, I.ConnectionID), ISNULL(I.ProductVersion, ''), ISNULL(I.host_platform, ''), ISNULL(I.EngineEdition, 0)
  FROM dbo.Instances I
 WHERE (I.IsActive = 1 OR @asked = 1) AND ISNULL(I.EngineEdition, 0) <> 5
 ORDER BY I.InstanceID`, sql.Named("asked", len(want) > 0))
	if err != nil {
		return nil, nil, fmt.Errorf("dbo.Instances: %w", err)
	}
	ok := map[int]bool{}
	for _, id := range want {
		ok[id] = true
	}
	var out []srcInstance
	for rows.Next() {
		var in srcInstance
		var plat string
		if err := rows.Scan(&in.ID, &in.Instance, &in.Display, &in.Version, &plat, &in.Edition); err != nil {
			_ = rows.Close()
			return nil, nil, fmt.Errorf("dbo.Instances: %w", err)
		}
		in.Linux = strings.EqualFold(strings.TrimSpace(plat), "Linux")
		if len(want) == 0 || ok[in.ID] {
			out = append(out, in)
		}
	}
	if err := rows.Close(); err != nil {
		return nil, nil, err
	}
	var leftOut []string
	for i := range out {
		tags, skipped, err := instanceTags(ctx, src, out[i].ID)
		if err != nil {
			return nil, nil, err
		}
		out[i].Tags = tags
		leftOut = append(leftOut, skipped...)
	}
	return out, leftOut, nil
}

// instanceTags are DBADash's own tags of an instance as pgvigil's key:value tags; DBADash's system tags (a name in
// braces: {Edition}, {Version} ...) are its own description of the server, which pgvigil reads from the server itself.
// A tag pgvigil's rule refuses (config.ParseTag: a lower-case key of letters, digits, '_', '.', '-'; a value of at most
// 100 characters without a comma) after the key is lower-cased and its spaces made '_' is left out and named.
func instanceTags(ctx context.Context, src *sql.Conn, id int) (tags, skipped []string, err error) {
	rows, err := src.QueryContext(ctx, `
SELECT T.TagName, T.TagValue FROM dbo.InstanceIDsTags IT JOIN dbo.Tags T ON T.TagID = IT.TagID
 WHERE IT.InstanceID = @id AND T.TagName IS NOT NULL AND T.TagName NOT LIKE N'{%' ORDER BY T.TagName, T.TagValue`, sql.Named("id", id))
	if err != nil {
		return nil, nil, fmt.Errorf("dbo.InstanceIDsTags: %w", err)
	}
	defer func() { _ = rows.Close() }()
	tags = []string{}
	for rows.Next() {
		var k string
		var v sql.NullString
		if err := rows.Scan(&k, &v); err != nil {
			return nil, nil, err
		}
		k = strings.ReplaceAll(strings.ToLower(strings.TrimSpace(k)), " ", "_")
		val := strings.TrimSpace(v.String)
		if k == "" || strings.Contains(k, ":") {
			continue
		}
		raw := k + ":" + val
		if val == "" {
			raw = k
		}
		t, perr := config.ParseTag(raw)
		if perr != nil {
			skipped = append(skipped, fmt.Sprintf("DBADash instance %d: %v", id, perr))
			continue
		}
		tags = append(tags, t.String())
	}
	return tags, skipped, rows.Err()
}

// The import's functions (0134): the run's writes and the reads of a dry run.
var (
	importRunFuncs = []string{"pgvigil.import_dbadash_instance(jsonb)", "pgvigil.import_dbadash_cpu(int, jsonb, jsonb)",
		"pgvigil.import_dbadash_volumes(int, jsonb, jsonb)", "pgvigil.import_dbadash_dbsize(int, jsonb, jsonb)",
		"pgvigil.import_dbadash_jobruns(int, jsonb, jsonb)", "pgvigil.import_job_stats_defer(int)", "pgvigil.import_job_stats_build(int)"}
	importReadFuncs = []string{"pgvigil.dbadash_import_target(jsonb)", "pgvigil.dbadash_import_stored(int, text, timestamptz, timestamptz)"}
)

// openImportStore connects to the pgvigil repository and checks the login may call what the import calls: the
// run's functions and the two reads (a login in role pgvigil_collector, or the owner; a reader may not), or for a dry
// run the two reads (any of the three).
func openImportStore(ctx context.Context, repoDSN string, dry bool) (*pgxpool.Pool, error) {
	if strings.TrimSpace(repoDSN) == "" {
		return nil, errors.New("the pgvigil repository's dsn is empty")
	}
	cfg, err := pgxpool.ParseConfig(repoDSN)
	if err != nil {
		return nil, fmt.Errorf("repository dsn: %w", err)
	}
	cfg.MaxConns = 2
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-dbadash-import"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("repository: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("repository ping: %w", err)
	}
	if err := importRights(ctx, pool, dry); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
}

// importRights checks the pool's login may call what the import calls (openImportStore's rule).
func importRights(ctx context.Context, pool *pgxpool.Pool, dry bool) error {
	need := importReadFuncs
	if !dry {
		need = append(append([]string{}, importReadFuncs...), importRunFuncs...)
	}
	var missing []string
	rows, err := pool.Query(ctx, `SELECT f FROM unnest($1::text[]) AS f
 WHERE NOT coalesce(has_function_privilege(to_regprocedure(f), 'EXECUTE'), false)`, need)
	if err == nil {
		missing, err = pgx.CollectRows(rows, pgx.RowTo[string])
	}
	if err != nil {
		return fmt.Errorf("repository rights: %w", err)
	}
	if len(missing) > 0 {
		if dry {
			return fmt.Errorf("this login may not read what the import reads (%s): run 'pgvigil migrate' (0134); then the owner's dsn or a login in role pgvigil_collector or pgvigil_reader may", strings.Join(missing, ", "))
		}
		return fmt.Errorf("this login may not write what the import writes (%s): run it with a login in role pgvigil_collector (the collector's) or the repository owner's dsn, after 'pgvigil migrate' (0134)", strings.Join(missing, ", "))
	}
	return nil
}

// importTargetRow is where a DBADash instance's history goes (0134's dbadash_import_target / import_dbadash_instance).
type importTargetRow struct {
	ID          int               `json:"instance_id"`
	Name        string            `json:"name"`
	Moved       bool              `json:"moved"`
	CollectFrom *time.Time        `json:"collect_from"`
	Skipped     string            `json:"skipped"`
	Wait        map[string]string `json:"wait"`
	Added       bool              `json:"added"`
	NeverRead   bool              `json:"never_read"`
}

// importTarget finds or (not in a dry run) creates the pgvigil SQL Server instance for a DBADash instance: a server
// moved from DBA Dash goes to its move (whatever name), with what holds its mappings back (collect it first, the
// collector's first CPU or job read); else the SQL Server instance of that name as it is (its description and tags are
// pgvigil's), except that a row Admin > Instances made at its add and pgvigil never read takes DBA Dash's version, and
// its platform when the page left it 'auto', as a new one would (the join's w9e, finding 4), and is seen now; one
// stored as PostgreSQL is a skip with its reason; none = a new instance with DBA Dash's version, platform and tags.
func importTarget(ctx context.Context, log *slog.Logger, pool *pgxpool.Pool, repo, name string, in srcInstance, dry bool) (importTargetRow, error) {
	platform := "sqlserver"
	if in.Edition == 8 { // DBADash's EngineEdition 8: Azure SQL Managed Instance (internal/mssql detect.go's kinds)
		platform = "azuresqlmi"
	}
	tags := in.Tags
	if tags == nil {
		tags = []string{}
	}
	p, _ := json.Marshal(map[string]any{"repository": repo, "dbadash_id": in.ID, "name": name, "platform": platform,
		"version": strings.TrimSpace(in.Version), "version_num": versionNum(in.Version), "tags": tags})
	fn := "import_dbadash_instance"
	if dry {
		fn = "dbadash_import_target"
	}
	var raw []byte
	if err := pool.QueryRow(ctx, `SELECT pgvigil.`+fn+`($1::jsonb)::text`, string(p)).Scan(&raw); err != nil {
		return importTargetRow{}, fmt.Errorf("%s %s: %w", fn, name, err)
	}
	var t importTargetRow
	if err := json.Unmarshal(raw, &t); err != nil {
		return importTargetRow{}, fmt.Errorf("%s answered %q: %w", fn, raw, err)
	}
	if t.Name == "" {
		t.Name = name
	}
	switch {
	case t.Moved:
		log.Info("dbadash import: a server moved from DBA Dash goes to its move", "dbadash_instance_id", in.ID, "name", t.Name, "instance_id", t.ID, "collect_from", t.CollectFrom)
	case t.Added:
		log.Info("dbadash import: instance added", "name", t.Name, "instance_id", t.ID, "platform", platform, "tags", in.Tags)
	case t.NeverRead:
		log.Info("dbadash import: a page instance never read takes the source's platform and version", "name", t.Name, "instance_id", t.ID, "platform", platform)
	}
	return t, nil
}

// versionNum is a SQL Server ProductVersion as pgvigil stores it: major * 10000 + minor (16.0.4295.3 -> 160000);
// nil when it does not parse.
func versionNum(v string) any {
	var major, minor int
	if n, _ := fmt.Sscanf(strings.TrimSpace(v), "%d.%d", &major, &minor); n < 1 || major <= 0 {
		return nil
	}
	return major*10000 + minor
}

// importOne copies one mapping of one instance in batches up to 'to', each batch one call of the mapping's function
// (one transaction: its months' partitions, the instance's import lock, the rows); onBatch gets the rows inserted so
// far after each batch.
func importOne(ctx context.Context, src *sql.Conn, pool *pgxpool.Pool, m importMapping, in srcInstance, pid int, opt ImportOptions, to time.Time, onBatch func(int64) error) (int64, error) {
	rows, err := src.QueryContext(ctx, m.Rows, sql.Named("id", in.ID), sql.Named("from", utc2(opt.From)), sql.Named("to", utc2(to)))
	if err != nil {
		return 0, fmt.Errorf("read: %w", err)
	}
	defer func() { _ = rows.Close() }()
	cols, err := rows.Columns()
	if err != nil {
		return 0, err
	}
	facts, _ := json.Marshal(map[string]any{"linux": in.Linux})
	var total int64
	batch := make([]map[string]any, 0, opt.Batch)
	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		n, _, err := importBatch(ctx, pool, m, pid, batch, string(facts))
		if err != nil {
			return err
		}
		total += n
		batch = batch[:0]
		if onBatch != nil {
			return onBatch(total)
		}
		return nil
	}
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return total, fmt.Errorf("read: %w", err)
		}
		rec := make(map[string]any, len(cols))
		for i, c := range cols {
			rec[c] = importValue(vals[i])
		}
		if _, ok := vals[0].(time.Time); !ok {
			return total, fmt.Errorf("read: the row's time is %T, not a date", vals[0])
		}
		batch = append(batch, rec)
		if len(batch) >= opt.Batch {
			if err := flush(); err != nil {
				return total, err
			}
		}
	}
	if err := rows.Err(); err != nil {
		return total, fmt.Errorf("read: %w", err)
	}
	return total, flush()
}

// importBatch is one batch of a mapping into the repository: one call of the mapping's function (one transaction: its
// months' partitions, the instance's import lock, the rows). It answers the rows inserted and how many times the call
// was taken again after a deadlock.
func importBatch(ctx context.Context, pool *pgxpool.Pool, m importMapping, pid int, batch []map[string]any, facts string) (int64, int, error) {
	payload, err := json.Marshal(batch)
	if err != nil {
		return 0, 0, err
	}
	var n int64
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_dbadash_`+m.Key+`($1, $2::jsonb, $3::jsonb)`, pid, string(payload), facts).Scan(&n); err != nil {
		return 0, 0, fmt.Errorf("insert: %w", err)
	}
	return n, 0, nil
}

// importValue makes a DBADash value a JSON value for jsonb_to_recordset: a date as RFC 3339 in UTC (DBADash keeps
// UTC: the wall clock as stored), a decimal as its text (a job id is read as text by the T-SQL itself).
func importValue(v any) any {
	switch x := v.(type) {
	case time.Time:
		return time.Date(x.Year(), x.Month(), x.Day(), x.Hour(), x.Minute(), x.Second(), x.Nanosecond(), time.UTC).Format(time.RFC3339Nano)
	case []byte:
		return string(x)
	}
	return v
}
