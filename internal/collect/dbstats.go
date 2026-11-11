package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// dbstatsCollector reads the cumulative counters every minute: pg_stat_database
// per database (transactions, blocks, tuples, temp, deadlocks, checksum failures,
// sessions) and one server row (bgwriter, checkpointer, WAL). Rows are stored as
// read; the repository's *_rate functions take the difference to the previous row
// over a window and treat a reset (stats_reset moved, or a counter went backwards)
// as a new baseline. pg_stat_io is the iostats collection's read (every 5 minutes
// by default: its rows were most of what this collection stored). Database sizes
// are the hourly databases collection's job: a pg_database_size walks every
// relation file and is not a per-minute read.
type dbstatsCollector struct{}

func init() { Register(dbstatsCollector{}) }

func (dbstatsCollector) Name() string                   { return "dbstats" }
func (dbstatsCollector) DefaultInterval() time.Duration { return time.Minute }
func (dbstatsCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

func (dbstatsCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	dbc, err := viewColumns(ctx, conn, "pg_catalog.pg_stat_database")
	if err != nil {
		return nil, err
	}
	dbSQL := fmt.Sprintf(`
SELECT 'db' AS kind, d.datid::bigint AS dbid, d.datname::text AS datname, d.stats_reset,
       pg_postmaster_start_time() AS postmaster_start,
       d.numbackends, d.xact_commit, d.xact_rollback, d.blks_read, d.blks_hit,
       d.tup_returned, d.tup_fetched, d.tup_inserted, d.tup_updated, d.tup_deleted,
       d.conflicts, d.temp_files, d.temp_bytes, d.deadlocks,
       %s AS checksum_failures, %s AS checksum_last_failure,
       d.blk_read_time, d.blk_write_time,
       %s AS session_time, %s AS active_time, %s AS idle_in_transaction_time,
       %s AS sessions, %s AS sessions_abandoned, %s AS sessions_fatal, %s AS sessions_killed
  FROM pg_stat_database d
  JOIN pg_database db ON db.oid = d.datid
 WHERE NOT db.datistemplate AND db.datallowconn`,
		col(dbc, "d", "checksum_failures", "bigint"), col(dbc, "d", "checksum_last_failure", "timestamptz"),
		col(dbc, "d", "session_time", "float8"), col(dbc, "d", "active_time", "float8"), col(dbc, "d", "idle_in_transaction_time", "float8"),
		col(dbc, "d", "sessions", "bigint"), col(dbc, "d", "sessions_abandoned", "bigint"), col(dbc, "d", "sessions_fatal", "bigint"), col(dbc, "d", "sessions_killed", "bigint"))
	rows, err := conn.Query(ctx, dbSQL)
	if err != nil {
		return nil, fmt.Errorf("pg_stat_database: %w", err)
	}
	out, err := rowsToMaps(rows)
	if err != nil {
		return nil, err
	}

	// server row: bgwriter + checkpointer (split in PG17) + wal (PG14+)
	bgc, err := viewColumns(ctx, conn, "pg_catalog.pg_stat_bgwriter")
	if err != nil {
		return nil, err
	}
	hasCheckpointer := info.ServerVersionNum >= 170000
	// Aurora refuses pg_stat_get_wal() (0A000): its storage layer has no local WAL counters
	hasWal := info.ServerVersionNum >= 140000 && info.Kind != platform.Aurora
	ckFrom, walFrom := "", ""
	var ckc, walc map[string]bool
	if hasCheckpointer {
		if ckc, err = viewColumns(ctx, conn, "pg_catalog.pg_stat_checkpointer"); err != nil {
			return nil, err
		}
		ckFrom = ", pg_stat_checkpointer c"
	}
	if hasWal {
		if walc, err = viewColumns(ctx, conn, "pg_catalog.pg_stat_wal"); err != nil {
			return nil, err
		}
		walFrom = ", pg_stat_wal w"
	}
	// checkpoint counters: pre-17 on bgwriter, 17+ on checkpointer under new names
	ckTimed := col(bgc, "b", "checkpoints_timed", "bigint")
	ckReq := col(bgc, "b", "checkpoints_req", "bigint")
	ckWrite := col(bgc, "b", "checkpoint_write_time", "float8")
	ckSync := col(bgc, "b", "checkpoint_sync_time", "float8")
	ckBuffers := col(bgc, "b", "buffers_checkpoint", "bigint")
	ckReset := "b.stats_reset"
	if hasCheckpointer {
		ckTimed, ckReq = col(ckc, "c", "num_timed", "bigint"), col(ckc, "c", "num_requested", "bigint")
		ckWrite, ckSync = col(ckc, "c", "write_time", "float8"), col(ckc, "c", "sync_time", "float8")
		ckBuffers, ckReset = col(ckc, "c", "buffers_written", "bigint"), "c.stats_reset"
	}
	serverSQL := fmt.Sprintf(`
SELECT 'server' AS kind, b.stats_reset AS bgwriter_stats_reset, %s AS checkpointer_stats_reset,
       %s AS checkpoints_timed, %s AS checkpoints_req, %s AS checkpoint_write_time, %s AS checkpoint_sync_time,
       %s AS buffers_checkpoint, b.buffers_clean, b.maxwritten_clean,
       %s AS buffers_backend, %s AS buffers_backend_fsync, b.buffers_alloc,
       %s AS wal_records, %s AS wal_fpi, %s AS wal_bytes, %s AS wal_buffers_full,
       %s AS wal_write, %s AS wal_sync, %s AS wal_write_time, %s AS wal_sync_time
  FROM pg_stat_bgwriter b%s%s`,
		ckReset, ckTimed, ckReq, ckWrite, ckSync, ckBuffers,
		col(bgc, "b", "buffers_backend", "bigint"), col(bgc, "b", "buffers_backend_fsync", "bigint"),
		col(walc, "w", "wal_records", "bigint"), col(walc, "w", "wal_fpi", "bigint"), col(walc, "w", "wal_bytes", "numeric"),
		col(walc, "w", "wal_buffers_full", "bigint"), col(walc, "w", "wal_write", "bigint"), col(walc, "w", "wal_sync", "bigint"),
		col(walc, "w", "wal_write_time", "float8"), col(walc, "w", "wal_sync_time", "float8"),
		ckFrom, walFrom)
	srows, err := conn.Query(ctx, serverSQL)
	if err != nil {
		return nil, fmt.Errorf("server stats: %w", err)
	}
	server, err := rowsToMaps(srows)
	if err != nil {
		return nil, err
	}
	out = append(out, server...)

	wal, err := dbstatsWal(ctx, conn, info)
	if err != nil {
		// the server state is a part of its own: the counters above are stored, the run reads partial
		out = append(out, Row{"kind": "collector_error", "source": "dbstats:wal", "message": err.Error()})
	} else {
		out = append(out, wal)
	}
	return out, nil
}

// dbstatsWalSQL (task 155, K11.10 and K11.14): the server's state at the read, one row - the last checkpoint (its time,
// timeline and redo point from pg_control_checkpoint, open to every login) and the WAL written since its redo point, the
// cluster's system identifier, the checkpoint_timeout in force, the client sessions against the connections a client may
// use, and the physical standbys streaming from this server (a walsender of a logical slot is not a standby). On a standby
// the WAL since the redo point is the replay position's. Aurora keeps no local WAL or control file: dbstatsWal leaves the
// checkpoint and WAL columns out there.
const dbstatsWalSQL = `
SELECT 'wal' AS kind, pg_is_in_recovery() AS in_recovery,
       %[1]s,
       (SELECT setting::int FROM pg_settings WHERE name = 'checkpoint_timeout') AS checkpoint_timeout_s,
       (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_connections,
       (SELECT setting::int FROM pg_settings WHERE name = 'superuser_reserved_connections') AS superuser_reserved,
       coalesce((SELECT setting::int FROM pg_settings WHERE name = 'reserved_connections'), 0) AS reserved_connections,
       (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend')::int AS client_backends,
       (SELECT count(*) FROM pg_stat_replication r
         WHERE r.state = 'streaming'
           AND NOT EXISTS (SELECT 1 FROM pg_replication_slots l WHERE l.active_pid = r.pid AND l.slot_type = 'logical'))::int AS standbys,
       (SELECT setting FROM pg_settings WHERE name = 'archive_mode') AS archive_mode`

// dbstatsWalControl is the checkpoint and WAL part of dbstatsWalSQL where the platform keeps them.
const dbstatsWalControl = `(SELECT c.checkpoint_time FROM pg_control_checkpoint() c) AS checkpoint_time,
       (SELECT c.timeline_id FROM pg_control_checkpoint() c) AS timeline_id,
       (SELECT c.redo_lsn::text FROM pg_control_checkpoint() c) AS redo_lsn,
       (SELECT pg_wal_lsn_diff(CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END, c.redo_lsn)::bigint
          FROM pg_control_checkpoint() c) AS wal_since_redo,
       (SELECT s.system_identifier::text FROM pg_control_system() s) AS system_identifier`

const dbstatsWalNoControl = `NULL::timestamptz AS checkpoint_time, NULL::int AS timeline_id, NULL::text AS redo_lsn,
       NULL::bigint AS wal_since_redo, NULL::text AS system_identifier`

// dbstatsWalFilesSQL: the archiver's backlog (the .ready files in pg_wal/archive_status, the oldest by its file time) and
// pg_wal's segment count and size. Both functions need pg_monitor (or a superuser); a refusal leaves the four NULL and
// says why in wal_note, the rest of the row stands.
const dbstatsWalFilesSQL = `
SELECT (SELECT count(*) FROM pg_ls_archive_statusdir() a WHERE a.name LIKE '%.ready')::int AS archive_ready,
       (SELECT min(a.modification) FROM pg_ls_archive_statusdir() a WHERE a.name LIKE '%.ready') AS archive_oldest_ready,
       (SELECT count(*) FROM pg_ls_waldir() w WHERE w.name ~ '^[0-9A-F]{24}$')::int AS wal_files,
       (SELECT coalesce(sum(w.size), 0) FROM pg_ls_waldir() w)::bigint AS wal_dir_bytes`

// dbstatsWal reads the server state row.
func dbstatsWal(ctx context.Context, conn *pgx.Conn, info platform.Info) (Row, error) {
	control := dbstatsWalControl
	if info.Kind == platform.Aurora {
		control = dbstatsWalNoControl
	}
	rows, err := conn.Query(ctx, fmt.Sprintf(dbstatsWalSQL, control))
	if err != nil {
		return nil, fmt.Errorf("server state: %w", err)
	}
	got, err := rowsToMaps(rows)
	if err != nil {
		return nil, fmt.Errorf("server state: %w", err)
	}
	if len(got) != 1 {
		return nil, fmt.Errorf("server state: %d rows", len(got))
	}
	row := got[0]
	if info.Kind == platform.Aurora {
		row["wal_note"] = "Aurora keeps no local WAL: no checkpoint, archive or pg_wal figures"
		return row, nil
	}
	frows, err := conn.Query(ctx, dbstatsWalFilesSQL)
	var files []Row
	if err == nil {
		files, err = rowsToMaps(frows)
	}
	if err != nil || len(files) != 1 {
		if err == nil {
			err = fmt.Errorf("%d rows", len(files))
		}
		row["wal_note"] = "archive and pg_wal not read: " + err.Error()
		return row, nil
	}
	for k, v := range files[0] {
		row[k] = v
	}
	return row, nil
}
