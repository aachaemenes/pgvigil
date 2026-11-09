-- 0010_dbstats_epoch: a restart epoch on each dbstats row, set at import against the previous row of that
-- database (pgvigil.dbstats_last), so a 24 h counter delta is max - min per epoch as a hash aggregate: no sort
-- of the day's rows, and no false rise when a crash or a failover restarts the counters under the same
-- stats_reset. Rows stored before this migration keep a NULL epoch.

ALTER TABLE pgvigil.dbstats ADD COLUMN IF NOT EXISTS epoch int;

CREATE TABLE IF NOT EXISTS pgvigil.dbstats_last (
  instance_id        int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid               bigint NOT NULL,
  epoch              int NOT NULL,
  snapshot_at        timestamptz NOT NULL,
  stats_reset        timestamptz,
  xact_commit        bigint, deadlocks bigint, checksum_failures bigint,
  PRIMARY KEY (instance_id, dbid)
);

CREATE OR REPLACE FUNCTION pgvigil.import_dbstats(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.ensure_month_partition('dbstats', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('serverstats', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('iostats', p_snapshot_at);

  -- restart epoch: a moved stats_reset, or a fall in xact_commit, deadlocks or checksum_failures against the
  -- previous stored row of that database, starts a new epoch (a crash or a failover leaves stats_reset NULL on
  -- PG15+ while the counters restart); within one epoch these counters only rise, so max - min is a delta
  WITH n AS (SELECT (r->>'dbid')::bigint AS dbid, r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db'),
  e AS (SELECT n.dbid, n.r, l.snapshot_at AS last_at,
               CASE WHEN l.instance_id IS NULL THEN 0
                    WHEN p_snapshot_at <= l.snapshot_at THEN l.epoch
                    WHEN (n.r->>'stats_reset')::timestamptz IS DISTINCT FROM l.stats_reset
                      OR (n.r->>'xact_commit')::bigint < l.xact_commit
                      OR (n.r->>'deadlocks')::bigint < l.deadlocks
                      OR (n.r->>'checksum_failures')::bigint < l.checksum_failures THEN l.epoch + 1
                    ELSE l.epoch END AS epoch
          FROM n LEFT JOIN pgvigil.dbstats_last l ON l.instance_id = p_instance_id AND l.dbid = n.dbid),
  ins AS (
  INSERT INTO pgvigil.dbstats (
    instance_id, snapshot_at, dbid, datname, stats_reset, numbackends, xact_commit, xact_rollback, blks_read, blks_hit,
    tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted, conflicts, temp_files, temp_bytes, deadlocks,
    checksum_failures, checksum_last_failure, blk_read_time, blk_write_time, session_time, active_time,
    idle_in_transaction_time, sessions, sessions_abandoned, sessions_fatal, sessions_killed, epoch)
  SELECT p_instance_id, p_snapshot_at, e.dbid, e.r->>'datname', (e.r->>'stats_reset')::timestamptz,
         (e.r->>'numbackends')::int, (e.r->>'xact_commit')::bigint, (e.r->>'xact_rollback')::bigint,
         (e.r->>'blks_read')::bigint, (e.r->>'blks_hit')::bigint, (e.r->>'tup_returned')::bigint, (e.r->>'tup_fetched')::bigint,
         (e.r->>'tup_inserted')::bigint, (e.r->>'tup_updated')::bigint, (e.r->>'tup_deleted')::bigint, (e.r->>'conflicts')::bigint,
         (e.r->>'temp_files')::bigint, (e.r->>'temp_bytes')::bigint, (e.r->>'deadlocks')::bigint,
         (e.r->>'checksum_failures')::bigint, (e.r->>'checksum_last_failure')::timestamptz,
         (e.r->>'blk_read_time')::float8, (e.r->>'blk_write_time')::float8, (e.r->>'session_time')::float8,
         (e.r->>'active_time')::float8, (e.r->>'idle_in_transaction_time')::float8, (e.r->>'sessions')::bigint,
         (e.r->>'sessions_abandoned')::bigint, (e.r->>'sessions_fatal')::bigint, (e.r->>'sessions_killed')::bigint, e.epoch
    FROM e
  RETURNING 1)
  INSERT INTO pgvigil.dbstats_last AS l (instance_id, dbid, epoch, snapshot_at, stats_reset, xact_commit, deadlocks, checksum_failures)
  SELECT p_instance_id, e.dbid, e.epoch, p_snapshot_at, (e.r->>'stats_reset')::timestamptz, (e.r->>'xact_commit')::bigint,
         (e.r->>'deadlocks')::bigint, (e.r->>'checksum_failures')::bigint
    FROM e WHERE e.last_at IS NULL OR p_snapshot_at > e.last_at
  ON CONFLICT (instance_id, dbid) DO UPDATE SET epoch = EXCLUDED.epoch, snapshot_at = EXCLUDED.snapshot_at,
     stats_reset = EXCLUDED.stats_reset, xact_commit = EXCLUDED.xact_commit, deadlocks = EXCLUDED.deadlocks,
     checksum_failures = EXCLUDED.checksum_failures;

  INSERT INTO pgvigil.serverstats (
    instance_id, snapshot_at, bgwriter_stats_reset, checkpointer_stats_reset, checkpoints_timed, checkpoints_req,
    checkpoint_write_time, checkpoint_sync_time, buffers_checkpoint, buffers_clean, maxwritten_clean,
    buffers_backend, buffers_backend_fsync, buffers_alloc, wal_records, wal_fpi, wal_bytes, wal_buffers_full,
    wal_write, wal_sync, wal_write_time, wal_sync_time)
  SELECT p_instance_id, p_snapshot_at, (r->>'bgwriter_stats_reset')::timestamptz, (r->>'checkpointer_stats_reset')::timestamptz,
         (r->>'checkpoints_timed')::bigint, (r->>'checkpoints_req')::bigint, (r->>'checkpoint_write_time')::float8,
         (r->>'checkpoint_sync_time')::float8, (r->>'buffers_checkpoint')::bigint, (r->>'buffers_clean')::bigint,
         (r->>'maxwritten_clean')::bigint, (r->>'buffers_backend')::bigint, (r->>'buffers_backend_fsync')::bigint,
         (r->>'buffers_alloc')::bigint, (r->>'wal_records')::bigint, (r->>'wal_fpi')::bigint, (r->>'wal_bytes')::numeric,
         (r->>'wal_buffers_full')::bigint, (r->>'wal_write')::bigint, (r->>'wal_sync')::bigint,
         (r->>'wal_write_time')::float8, (r->>'wal_sync_time')::float8
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'server';

  INSERT INTO pgvigil.iostats (
    instance_id, snapshot_at, backend_type, object, context, stats_reset, reads, read_bytes, read_time, writes, write_bytes,
    write_time, writebacks, writeback_time, extends, extend_bytes, extend_time, op_bytes, hits, evictions, reuses, fsyncs, fsync_time)
  SELECT p_instance_id, p_snapshot_at, r->>'backend_type', r->>'object', r->>'context', (r->>'stats_reset')::timestamptz,
         (r->>'reads')::bigint, (r->>'read_bytes')::numeric, (r->>'read_time')::float8, (r->>'writes')::bigint,
         (r->>'write_bytes')::numeric, (r->>'write_time')::float8, (r->>'writebacks')::bigint, (r->>'writeback_time')::float8,
         (r->>'extends')::bigint, (r->>'extend_bytes')::numeric, (r->>'extend_time')::float8, (r->>'op_bytes')::bigint,
         (r->>'hits')::bigint, (r->>'evictions')::bigint, (r->>'reuses')::bigint, (r->>'fsyncs')::bigint, (r->>'fsync_time')::float8
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'io';
END $$;
