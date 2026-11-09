-- 0004_dbstats: cumulative counters stored as read every minute - pg_stat_database per
-- database, one server row (bgwriter, checkpointer, WAL), pg_stat_io rows (PG16+) - in
-- monthly UTC partitions. The *_rate(instance, from, to) functions take the difference to the
-- previous row of the same key over a window; a reset (stats_reset moved, or a counter smaller
-- than before) yields NULL for that interval, so a chart shows a gap instead of a negative spike.

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
  sessions                 bigint, sessions_abandoned bigint, sessions_fatal bigint, sessions_killed bigint
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
    idle_in_transaction_time, sessions, sessions_abandoned, sessions_fatal, sessions_killed)
  SELECT p_instance_id, p_snapshot_at, (r->>'dbid')::bigint, r->>'datname', (r->>'stats_reset')::timestamptz,
         (r->>'numbackends')::int, (r->>'xact_commit')::bigint, (r->>'xact_rollback')::bigint,
         (r->>'blks_read')::bigint, (r->>'blks_hit')::bigint, (r->>'tup_returned')::bigint, (r->>'tup_fetched')::bigint,
         (r->>'tup_inserted')::bigint, (r->>'tup_updated')::bigint, (r->>'tup_deleted')::bigint, (r->>'conflicts')::bigint,
         (r->>'temp_files')::bigint, (r->>'temp_bytes')::bigint, (r->>'deadlocks')::bigint,
         (r->>'checksum_failures')::bigint, (r->>'checksum_last_failure')::timestamptz,
         (r->>'blk_read_time')::float8, (r->>'blk_write_time')::float8, (r->>'session_time')::float8,
         (r->>'active_time')::float8, (r->>'idle_in_transaction_time')::float8, (r->>'sessions')::bigint,
         (r->>'sessions_abandoned')::bigint, (r->>'sessions_fatal')::bigint, (r->>'sessions_killed')::bigint
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

-- Rates over a window. A view with lag() over the whole table cannot push a time filter below
-- the window function and scans every retained row per panel (measured: 1.7 M rows, 1.5 s for
-- one hour); these functions read from p_from minus a lookback so the first row inside the
-- window has its previous row, then filter. Lookback 15 minutes covers a 1-minute cadence
-- with gaps; a longer gap simply yields no delta for the first row after it.
CREATE OR REPLACE FUNCTION pgvigil.dbstats_rate(p_instance_id int, p_from timestamptz, p_to timestamptz, p_lookback interval DEFAULT interval '15 minutes')
RETURNS TABLE (instance_id int, snapshot_at timestamptz, dbid bigint, datname text, interval_secs int, reset boolean, numbackends int,
               xact_commit bigint, xact_rollback bigint, blks_read bigint, blks_hit bigint, tup_returned bigint, tup_fetched bigint,
               tup_inserted bigint, tup_updated bigint, tup_deleted bigint, conflicts bigint, temp_files bigint, temp_bytes bigint,
               deadlocks bigint, checksum_failures bigint, blk_read_time double precision, blk_write_time double precision,
               session_time double precision, active_time double precision, idle_in_transaction_time double precision,
               sessions bigint, sessions_abandoned bigint, sessions_fatal bigint, sessions_killed bigint)
LANGUAGE sql STABLE AS $$
  WITH w AS (
    SELECT d.*,
           extract(epoch FROM d.snapshot_at - lag(d.snapshot_at) OVER k)::int AS interval_secs,
           (d.stats_reset IS DISTINCT FROM lag(d.stats_reset) OVER k) AS rs,
           lag(d.xact_commit) OVER k AS p1, lag(d.xact_rollback) OVER k AS p2, lag(d.blks_read) OVER k AS p3, lag(d.blks_hit) OVER k AS p4,
           lag(d.tup_returned) OVER k AS p5, lag(d.tup_fetched) OVER k AS p6, lag(d.tup_inserted) OVER k AS p7, lag(d.tup_updated) OVER k AS p8,
           lag(d.tup_deleted) OVER k AS p9, lag(d.conflicts) OVER k AS p10, lag(d.temp_files) OVER k AS p11, lag(d.temp_bytes) OVER k AS p12,
           lag(d.deadlocks) OVER k AS p13, lag(d.checksum_failures) OVER k AS p14, lag(d.blk_read_time) OVER k AS p15,
           lag(d.blk_write_time) OVER k AS p16, lag(d.session_time) OVER k AS p17, lag(d.active_time) OVER k AS p18,
           lag(d.idle_in_transaction_time) OVER k AS p19, lag(d.sessions) OVER k AS p20, lag(d.sessions_abandoned) OVER k AS p21,
           lag(d.sessions_fatal) OVER k AS p22, lag(d.sessions_killed) OVER k AS p23
      FROM pgvigil.dbstats d
     WHERE d.instance_id = p_instance_id AND d.snapshot_at > p_from - p_lookback AND d.snapshot_at <= p_to
    WINDOW k AS (PARTITION BY d.dbid ORDER BY d.snapshot_at)
  )
  SELECT instance_id, snapshot_at, dbid, datname, interval_secs, rs, numbackends,
         pgvigil.delta(xact_commit, p1, rs), pgvigil.delta(xact_rollback, p2, rs), pgvigil.delta(blks_read, p3, rs), pgvigil.delta(blks_hit, p4, rs),
         pgvigil.delta(tup_returned, p5, rs), pgvigil.delta(tup_fetched, p6, rs), pgvigil.delta(tup_inserted, p7, rs), pgvigil.delta(tup_updated, p8, rs),
         pgvigil.delta(tup_deleted, p9, rs), pgvigil.delta(conflicts, p10, rs), pgvigil.delta(temp_files, p11, rs), pgvigil.delta(temp_bytes, p12, rs),
         pgvigil.delta(deadlocks, p13, rs), pgvigil.delta(checksum_failures, p14, rs), pgvigil.delta(blk_read_time, p15, rs),
         pgvigil.delta(blk_write_time, p16, rs), pgvigil.delta(session_time, p17, rs), pgvigil.delta(active_time, p18, rs),
         pgvigil.delta(idle_in_transaction_time, p19, rs), pgvigil.delta(sessions, p20, rs), pgvigil.delta(sessions_abandoned, p21, rs),
         pgvigil.delta(sessions_fatal, p22, rs), pgvigil.delta(sessions_killed, p23, rs)
    FROM w
   WHERE interval_secs IS NOT NULL AND snapshot_at > p_from
$$;

CREATE OR REPLACE FUNCTION pgvigil.serverstats_rate(p_instance_id int, p_from timestamptz, p_to timestamptz, p_lookback interval DEFAULT interval '15 minutes')
RETURNS TABLE (instance_id int, snapshot_at timestamptz, interval_secs int, reset boolean,
               checkpoints_timed bigint, checkpoints_req bigint, checkpoint_write_time double precision, checkpoint_sync_time double precision,
               buffers_checkpoint bigint, buffers_clean bigint, maxwritten_clean bigint, buffers_backend bigint, buffers_backend_fsync bigint,
               buffers_alloc bigint, wal_records bigint, wal_fpi bigint, wal_bytes numeric, wal_buffers_full bigint, wal_write bigint,
               wal_sync bigint, wal_write_time double precision, wal_sync_time double precision)
LANGUAGE sql STABLE AS $$
  WITH w AS (
    SELECT s.*,
           extract(epoch FROM s.snapshot_at - lag(s.snapshot_at) OVER k)::int AS interval_secs,
           (s.bgwriter_stats_reset IS DISTINCT FROM lag(s.bgwriter_stats_reset) OVER k
            OR s.checkpointer_stats_reset IS DISTINCT FROM lag(s.checkpointer_stats_reset) OVER k) AS rs,
           lag(s.checkpoints_timed) OVER k AS p1, lag(s.checkpoints_req) OVER k AS p2, lag(s.checkpoint_write_time) OVER k AS p3,
           lag(s.checkpoint_sync_time) OVER k AS p4, lag(s.buffers_checkpoint) OVER k AS p5, lag(s.buffers_clean) OVER k AS p6,
           lag(s.maxwritten_clean) OVER k AS p7, lag(s.buffers_backend) OVER k AS p8, lag(s.buffers_backend_fsync) OVER k AS p9,
           lag(s.buffers_alloc) OVER k AS p10, lag(s.wal_records) OVER k AS p11, lag(s.wal_fpi) OVER k AS p12, lag(s.wal_bytes) OVER k AS p13,
           lag(s.wal_buffers_full) OVER k AS p14, lag(s.wal_write) OVER k AS p15, lag(s.wal_sync) OVER k AS p16,
           lag(s.wal_write_time) OVER k AS p17, lag(s.wal_sync_time) OVER k AS p18
      FROM pgvigil.serverstats s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from - p_lookback AND s.snapshot_at <= p_to
    WINDOW k AS (ORDER BY s.snapshot_at)
  )
  SELECT instance_id, snapshot_at, interval_secs, rs,
         pgvigil.delta(checkpoints_timed, p1, rs), pgvigil.delta(checkpoints_req, p2, rs), pgvigil.delta(checkpoint_write_time, p3, rs),
         pgvigil.delta(checkpoint_sync_time, p4, rs), pgvigil.delta(buffers_checkpoint, p5, rs), pgvigil.delta(buffers_clean, p6, rs),
         pgvigil.delta(maxwritten_clean, p7, rs), pgvigil.delta(buffers_backend, p8, rs), pgvigil.delta(buffers_backend_fsync, p9, rs),
         pgvigil.delta(buffers_alloc, p10, rs), pgvigil.delta(wal_records, p11, rs), pgvigil.delta(wal_fpi, p12, rs), pgvigil.delta(wal_bytes, p13, rs),
         pgvigil.delta(wal_buffers_full, p14, rs), pgvigil.delta(wal_write, p15, rs), pgvigil.delta(wal_sync, p16, rs),
         pgvigil.delta(wal_write_time, p17, rs), pgvigil.delta(wal_sync_time, p18, rs)
    FROM w
   WHERE interval_secs IS NOT NULL AND snapshot_at > p_from
$$;

-- bytes are normalised across versions: PG18 reports read_bytes/write_bytes/extend_bytes,
-- PG16 and 17 report op_bytes per operation, so bytes = ops * op_bytes there.
CREATE OR REPLACE FUNCTION pgvigil.iostats_rate(p_instance_id int, p_from timestamptz, p_to timestamptz, p_lookback interval DEFAULT interval '15 minutes')
RETURNS TABLE (instance_id int, snapshot_at timestamptz, backend_type text, object text, context text, interval_secs int, reset boolean,
               reads bigint, read_bytes numeric, read_time double precision, writes bigint, write_bytes numeric, write_time double precision,
               writebacks bigint, writeback_time double precision, extends bigint, extend_bytes numeric, extend_time double precision,
               hits bigint, evictions bigint, reuses bigint, fsyncs bigint, fsync_time double precision)
LANGUAGE sql STABLE AS $$
  WITH w AS (
    SELECT i.*,
           extract(epoch FROM i.snapshot_at - lag(i.snapshot_at) OVER k)::int AS interval_secs,
           (i.stats_reset IS DISTINCT FROM lag(i.stats_reset) OVER k) AS rs,
           lag(i.reads) OVER k AS p1, lag(i.read_bytes) OVER k AS p2, lag(i.read_time) OVER k AS p3, lag(i.writes) OVER k AS p4,
           lag(i.write_bytes) OVER k AS p5, lag(i.write_time) OVER k AS p6, lag(i.writebacks) OVER k AS p7, lag(i.writeback_time) OVER k AS p8,
           lag(i.extends) OVER k AS p9, lag(i.extend_bytes) OVER k AS p10, lag(i.extend_time) OVER k AS p11, lag(i.hits) OVER k AS p12,
           lag(i.evictions) OVER k AS p13, lag(i.reuses) OVER k AS p14, lag(i.fsyncs) OVER k AS p15, lag(i.fsync_time) OVER k AS p16
      FROM pgvigil.iostats i
     WHERE i.instance_id = p_instance_id AND i.snapshot_at > p_from - p_lookback AND i.snapshot_at <= p_to
    WINDOW k AS (PARTITION BY i.backend_type, i.object, i.context ORDER BY i.snapshot_at)
  )
  SELECT instance_id, snapshot_at, backend_type, object, context, interval_secs, rs,
         pgvigil.delta(reads, p1, rs),
         coalesce(pgvigil.delta(read_bytes, p2, rs), pgvigil.delta(reads, p1, rs) * op_bytes),
         pgvigil.delta(read_time, p3, rs),
         pgvigil.delta(writes, p4, rs),
         coalesce(pgvigil.delta(write_bytes, p5, rs), pgvigil.delta(writes, p4, rs) * op_bytes),
         pgvigil.delta(write_time, p6, rs),
         pgvigil.delta(writebacks, p7, rs), pgvigil.delta(writeback_time, p8, rs),
         pgvigil.delta(extends, p9, rs),
         coalesce(pgvigil.delta(extend_bytes, p10, rs), pgvigil.delta(extends, p9, rs) * op_bytes),
         pgvigil.delta(extend_time, p11, rs),
         pgvigil.delta(hits, p12, rs), pgvigil.delta(evictions, p13, rs), pgvigil.delta(reuses, p14, rs),
         pgvigil.delta(fsyncs, p15, rs), pgvigil.delta(fsync_time, p16, rs)
    FROM w
   WHERE interval_secs IS NOT NULL AND snapshot_at > p_from
$$;

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
