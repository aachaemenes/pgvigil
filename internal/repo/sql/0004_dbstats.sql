-- 0004_dbstats: cumulative counters stored as read every minute - pg_stat_database per
-- database, one server row (bgwriter, checkpointer, WAL), pg_stat_io rows (PG16+) - in
-- monthly UTC partitions. The *_rate views take the difference to the previous row of the
-- same key; a reset (stats_reset moved, or a counter smaller than before) yields NULL for
-- that interval, so a chart shows a gap instead of a negative spike.

CREATE TABLE IF NOT EXISTS pgvigil.dbstats (
  instance_id              int NOT NULL,
  snapshot_at              timestamptz NOT NULL,
  dbid                     bigint NOT NULL,
  datname                  text,
  stats_reset              timestamptz,
  numbackends              int,
  xact_commit              bigint, xact_rollback bigint,
  blks_read                bigint, blks_hit bigint,
  tup_returned             bigint, tup_fetched bigint, tup_inserted bigint, tup_updated bigint, tup_deleted bigint,
  conflicts                bigint, temp_files bigint, temp_bytes bigint, deadlocks bigint,
  checksum_failures        bigint, checksum_last_failure timestamptz,
  blk_read_time            double precision, blk_write_time double precision,
  session_time             double precision, active_time double precision, idle_in_transaction_time double precision,
  sessions                 bigint, sessions_abandoned bigint, sessions_fatal bigint, sessions_killed bigint,
  size_bytes               bigint
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.serverstats (
  instance_id              int NOT NULL,
  snapshot_at              timestamptz NOT NULL,
  bgwriter_stats_reset     timestamptz, checkpointer_stats_reset timestamptz,
  checkpoints_timed        bigint, checkpoints_req bigint,
  checkpoint_write_time    double precision, checkpoint_sync_time double precision,
  buffers_checkpoint       bigint, buffers_clean bigint, maxwritten_clean bigint,
  buffers_backend          bigint, buffers_backend_fsync bigint, buffers_alloc bigint,
  wal_records              bigint, wal_fpi bigint, wal_bytes numeric, wal_buffers_full bigint,
  wal_write                bigint, wal_sync bigint, wal_write_time double precision, wal_sync_time double precision
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.iostats (
  instance_id      int NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  backend_type     text NOT NULL,
  object           text NOT NULL,
  context          text NOT NULL,
  stats_reset      timestamptz,
  reads            bigint, read_bytes numeric, read_time double precision,
  writes           bigint, write_bytes numeric, write_time double precision,
  writebacks       bigint, writeback_time double precision,
  extends          bigint, extend_bytes numeric, extend_time double precision,
  op_bytes         bigint, hits bigint, evictions bigint, reuses bigint,
  fsyncs           bigint, fsync_time double precision
) PARTITION BY RANGE (snapshot_at);

CREATE OR REPLACE FUNCTION pgvigil.import_dbstats(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.ensure_month_partition('dbstats', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('serverstats', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('iostats', p_snapshot_at);

  INSERT INTO pgvigil.dbstats (
    instance_id, snapshot_at, dbid, datname, stats_reset, numbackends, xact_commit, xact_rollback, blks_read, blks_hit,
    tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted, conflicts, temp_files, temp_bytes, deadlocks,
    checksum_failures, checksum_last_failure, blk_read_time, blk_write_time, session_time, active_time,
    idle_in_transaction_time, sessions, sessions_abandoned, sessions_fatal, sessions_killed, size_bytes)
  SELECT p_instance_id, p_snapshot_at, (r->>'dbid')::bigint, r->>'datname', (r->>'stats_reset')::timestamptz,
         (r->>'numbackends')::int, (r->>'xact_commit')::bigint, (r->>'xact_rollback')::bigint,
         (r->>'blks_read')::bigint, (r->>'blks_hit')::bigint, (r->>'tup_returned')::bigint, (r->>'tup_fetched')::bigint,
         (r->>'tup_inserted')::bigint, (r->>'tup_updated')::bigint, (r->>'tup_deleted')::bigint, (r->>'conflicts')::bigint,
         (r->>'temp_files')::bigint, (r->>'temp_bytes')::bigint, (r->>'deadlocks')::bigint,
         (r->>'checksum_failures')::bigint, (r->>'checksum_last_failure')::timestamptz,
         (r->>'blk_read_time')::float8, (r->>'blk_write_time')::float8, (r->>'session_time')::float8,
         (r->>'active_time')::float8, (r->>'idle_in_transaction_time')::float8, (r->>'sessions')::bigint,
         (r->>'sessions_abandoned')::bigint, (r->>'sessions_fatal')::bigint, (r->>'sessions_killed')::bigint,
         (r->>'size_bytes')::bigint
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db';

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

-- delta of a counter against the previous row; NULL across a reset or a backwards step
CREATE OR REPLACE FUNCTION pgvigil.delta(p_cur anyelement, p_prev anyelement, p_reset boolean)
RETURNS anyelement LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_prev IS NULL OR p_reset OR p_cur < p_prev THEN NULL ELSE p_cur - p_prev END
$$;

CREATE OR REPLACE VIEW pgvigil.dbstats_rate AS
  WITH w AS (
    SELECT d.*,
           extract(epoch FROM d.snapshot_at - lag(d.snapshot_at) OVER k)::int AS interval_secs,
           (d.stats_reset IS DISTINCT FROM lag(d.stats_reset) OVER k) AS reset,
           lag(d.xact_commit) OVER k AS p_xact_commit, lag(d.xact_rollback) OVER k AS p_xact_rollback,
           lag(d.blks_read) OVER k AS p_blks_read, lag(d.blks_hit) OVER k AS p_blks_hit,
           lag(d.tup_returned) OVER k AS p_tup_returned, lag(d.tup_fetched) OVER k AS p_tup_fetched,
           lag(d.tup_inserted) OVER k AS p_tup_inserted, lag(d.tup_updated) OVER k AS p_tup_updated,
           lag(d.tup_deleted) OVER k AS p_tup_deleted, lag(d.temp_files) OVER k AS p_temp_files,
           lag(d.temp_bytes) OVER k AS p_temp_bytes, lag(d.deadlocks) OVER k AS p_deadlocks,
           lag(d.checksum_failures) OVER k AS p_checksum_failures,
           lag(d.blk_read_time) OVER k AS p_blk_read_time, lag(d.blk_write_time) OVER k AS p_blk_write_time,
           lag(d.sessions) OVER k AS p_sessions, lag(d.sessions_fatal) OVER k AS p_sessions_fatal,
           lag(d.sessions_killed) OVER k AS p_sessions_killed
      FROM pgvigil.dbstats d
    WINDOW k AS (PARTITION BY d.instance_id, d.dbid ORDER BY d.snapshot_at)
  )
  SELECT instance_id, snapshot_at, dbid, datname, interval_secs, reset, numbackends, size_bytes,
         pgvigil.delta(xact_commit, p_xact_commit, reset)         AS xact_commit,
         pgvigil.delta(xact_rollback, p_xact_rollback, reset)     AS xact_rollback,
         pgvigil.delta(blks_read, p_blks_read, reset)             AS blks_read,
         pgvigil.delta(blks_hit, p_blks_hit, reset)               AS blks_hit,
         pgvigil.delta(tup_returned, p_tup_returned, reset)       AS tup_returned,
         pgvigil.delta(tup_fetched, p_tup_fetched, reset)         AS tup_fetched,
         pgvigil.delta(tup_inserted, p_tup_inserted, reset)       AS tup_inserted,
         pgvigil.delta(tup_updated, p_tup_updated, reset)         AS tup_updated,
         pgvigil.delta(tup_deleted, p_tup_deleted, reset)         AS tup_deleted,
         pgvigil.delta(temp_files, p_temp_files, reset)           AS temp_files,
         pgvigil.delta(temp_bytes, p_temp_bytes, reset)           AS temp_bytes,
         pgvigil.delta(deadlocks, p_deadlocks, reset)             AS deadlocks,
         pgvigil.delta(checksum_failures, p_checksum_failures, reset) AS checksum_failures,
         pgvigil.delta(blk_read_time, p_blk_read_time, reset)     AS blk_read_time,
         pgvigil.delta(blk_write_time, p_blk_write_time, reset)   AS blk_write_time,
         pgvigil.delta(sessions, p_sessions, reset)               AS sessions,
         pgvigil.delta(sessions_fatal, p_sessions_fatal, reset)   AS sessions_fatal,
         pgvigil.delta(sessions_killed, p_sessions_killed, reset) AS sessions_killed
    FROM w
   WHERE interval_secs IS NOT NULL;

CREATE OR REPLACE VIEW pgvigil.serverstats_rate AS
  WITH w AS (
    SELECT s.*,
           extract(epoch FROM s.snapshot_at - lag(s.snapshot_at) OVER k)::int AS interval_secs,
           (s.bgwriter_stats_reset IS DISTINCT FROM lag(s.bgwriter_stats_reset) OVER k
            OR s.checkpointer_stats_reset IS DISTINCT FROM lag(s.checkpointer_stats_reset) OVER k) AS reset,
           lag(s.checkpoints_timed) OVER k AS p_ct, lag(s.checkpoints_req) OVER k AS p_cr,
           lag(s.checkpoint_write_time) OVER k AS p_cwt, lag(s.checkpoint_sync_time) OVER k AS p_cst,
           lag(s.buffers_checkpoint) OVER k AS p_bc, lag(s.buffers_clean) OVER k AS p_bcl,
           lag(s.maxwritten_clean) OVER k AS p_mw, lag(s.buffers_backend) OVER k AS p_bb,
           lag(s.buffers_backend_fsync) OVER k AS p_bbf, lag(s.buffers_alloc) OVER k AS p_ba,
           lag(s.wal_records) OVER k AS p_wr, lag(s.wal_fpi) OVER k AS p_wf, lag(s.wal_bytes) OVER k AS p_wb,
           lag(s.wal_buffers_full) OVER k AS p_wbf, lag(s.wal_write) OVER k AS p_ww, lag(s.wal_sync) OVER k AS p_ws,
           lag(s.wal_write_time) OVER k AS p_wwt, lag(s.wal_sync_time) OVER k AS p_wst
      FROM pgvigil.serverstats s
    WINDOW k AS (PARTITION BY s.instance_id ORDER BY s.snapshot_at)
  )
  SELECT instance_id, snapshot_at, interval_secs, reset,
         pgvigil.delta(checkpoints_timed, p_ct, reset) AS checkpoints_timed,
         pgvigil.delta(checkpoints_req, p_cr, reset) AS checkpoints_req,
         pgvigil.delta(checkpoint_write_time, p_cwt, reset) AS checkpoint_write_time,
         pgvigil.delta(checkpoint_sync_time, p_cst, reset) AS checkpoint_sync_time,
         pgvigil.delta(buffers_checkpoint, p_bc, reset) AS buffers_checkpoint,
         pgvigil.delta(buffers_clean, p_bcl, reset) AS buffers_clean,
         pgvigil.delta(maxwritten_clean, p_mw, reset) AS maxwritten_clean,
         pgvigil.delta(buffers_backend, p_bb, reset) AS buffers_backend,
         pgvigil.delta(buffers_backend_fsync, p_bbf, reset) AS buffers_backend_fsync,
         pgvigil.delta(buffers_alloc, p_ba, reset) AS buffers_alloc,
         pgvigil.delta(wal_records, p_wr, reset) AS wal_records,
         pgvigil.delta(wal_fpi, p_wf, reset) AS wal_fpi,
         pgvigil.delta(wal_bytes, p_wb, reset) AS wal_bytes,
         pgvigil.delta(wal_buffers_full, p_wbf, reset) AS wal_buffers_full,
         pgvigil.delta(wal_write, p_ww, reset) AS wal_write,
         pgvigil.delta(wal_sync, p_ws, reset) AS wal_sync,
         pgvigil.delta(wal_write_time, p_wwt, reset) AS wal_write_time,
         pgvigil.delta(wal_sync_time, p_wst, reset) AS wal_sync_time
    FROM w
   WHERE interval_secs IS NOT NULL;

CREATE OR REPLACE VIEW pgvigil.iostats_rate AS
  WITH w AS (
    SELECT i.*,
           extract(epoch FROM i.snapshot_at - lag(i.snapshot_at) OVER k)::int AS interval_secs,
           (i.stats_reset IS DISTINCT FROM lag(i.stats_reset) OVER k) AS reset,
           lag(i.reads) OVER k AS p_reads, lag(i.read_bytes) OVER k AS p_read_bytes, lag(i.read_time) OVER k AS p_read_time,
           lag(i.writes) OVER k AS p_writes, lag(i.write_bytes) OVER k AS p_write_bytes, lag(i.write_time) OVER k AS p_write_time,
           lag(i.writebacks) OVER k AS p_writebacks, lag(i.extends) OVER k AS p_extends, lag(i.hits) OVER k AS p_hits,
           lag(i.evictions) OVER k AS p_evictions, lag(i.reuses) OVER k AS p_reuses, lag(i.fsyncs) OVER k AS p_fsyncs,
           lag(i.fsync_time) OVER k AS p_fsync_time
      FROM pgvigil.iostats i
    WINDOW k AS (PARTITION BY i.instance_id, i.backend_type, i.object, i.context ORDER BY i.snapshot_at)
  )
  SELECT instance_id, snapshot_at, backend_type, object, context, interval_secs, reset, op_bytes,
         pgvigil.delta(reads, p_reads, reset) AS reads, pgvigil.delta(read_bytes, p_read_bytes, reset) AS read_bytes,
         pgvigil.delta(read_time, p_read_time, reset) AS read_time,
         pgvigil.delta(writes, p_writes, reset) AS writes, pgvigil.delta(write_bytes, p_write_bytes, reset) AS write_bytes,
         pgvigil.delta(write_time, p_write_time, reset) AS write_time,
         pgvigil.delta(writebacks, p_writebacks, reset) AS writebacks, pgvigil.delta(extends, p_extends, reset) AS extends,
         pgvigil.delta(hits, p_hits, reset) AS hits, pgvigil.delta(evictions, p_evictions, reset) AS evictions,
         pgvigil.delta(reuses, p_reuses, reset) AS reuses, pgvigil.delta(fsyncs, p_fsyncs, reset) AS fsyncs,
         pgvigil.delta(fsync_time, p_fsync_time, reset) AS fsync_time
    FROM w
   WHERE interval_secs IS NOT NULL;

-- the three new partitioned tables join the purge's partition drop
CREATE OR REPLACE FUNCTION pgvigil.purge(p_days int DEFAULT 30)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n       bigint := 0;
  v_rows  bigint;
  v_part  record;
BEGIN
  FOR v_part IN
    SELECT c.relname
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent
      JOIN pg_namespace ns ON ns.oid = p.relnamespace
     WHERE ns.nspname = 'pgvigil'
       AND p.relname IN ('activity_sample', 'statements_delta', 'dbstats', 'serverstats', 'iostats')
       AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    n := n + 1;
  END LOOP;
  DELETE FROM pgvigil.activity_summary WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statements_info WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statements_current WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.query_text t
   WHERE t.last_seen < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.activity_sample s WHERE s.query_hash = t.query_hash);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statement_text t
   WHERE t.last_seen < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.statements_delta d WHERE d.instance_id = t.instance_id AND d.queryid = t.queryid);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.collection_log WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  RETURN n;
END $$;
