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

	return out, nil
}
