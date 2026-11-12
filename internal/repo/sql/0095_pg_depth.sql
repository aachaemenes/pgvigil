-- 0095 PostgreSQL depth (task 155; the release audit's K11.01, K11.04, K11.05, K11.06, K11.10, K11.11 and K11.14's cheap
-- findings). What it adds:
--   1. statements: pg_stat_statements' planning, JIT, WAL record / full-page-image / buffers-full, parallel-worker,
--      local-block and generic / custom plan counters on statements_current and statements_delta (NULL where the
--      installed extension lacks them, and on rows stored before this file); import_statements is 0017's with the new
--      columns; statement_depth() reads them over a window.
--   2. wal_state_sample (monthly): the dbstats collection's new 'wal' row, one per read - the last checkpoint (time,
--      timeline, redo point, the WAL since it), the system identifier, the connections against the limit, the physical
--      standbys, the archiver's .ready backlog and pg_wal's size; import_dbstats is 0011's with that insert added;
--      wal_state_latest is the newest row per instance with its derived cells.
--   3. function_stats (monthly) from the new functions collection (pg_stat_user_functions per database, cumulative);
--      function_top() takes the differences over a window.
--   4. slru_sample (monthly) from the new slru collection (pg_stat_slru, cumulative); slru_rate() the differences.
--   5. sequence_state and db_checks (current state, is_present) from the new dbchecks collection: every sequence's headroom
--      and the catalog findings (SECURITY DEFINER without search_path, NOT VALID constraints, rows in a DEFAULT partition,
--      CREATE on public, MD5 passwords).
--   6. index_bloat (current state) from the new index_bloat collection: the btree estimate with its REINDEX line.
--   7. pg_depth_findings: the findings of all of the above (a table's dead rows are 0016's table_checks 'table dead rows',
--      over 20 % of over 1,000 rows, on the Tables page: one rule, not a second one here).
--   depth_databases records, per collection, which databases the last read covered (a database in error keeps its rows).
-- For the lead's join (0110): pg_depth_findings is a findings arm; wal_state_sample, function_stats and slru_sample are
-- monthly partition parents for purge(); sequence_state, db_checks, index_bloat and depth_databases keep rows no longer
-- present (is_present false) for purge()'s retention.

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. statements
-- ---------------------------------------------------------------------------------------------------------------------
ALTER TABLE pgvigil.statements_current
  ADD COLUMN IF NOT EXISTS plans bigint, ADD COLUMN IF NOT EXISTS total_plan_ms double precision,
  ADD COLUMN IF NOT EXISTS local_blks_hit bigint, ADD COLUMN IF NOT EXISTS local_blks_read bigint,
  ADD COLUMN IF NOT EXISTS local_blks_dirtied bigint, ADD COLUMN IF NOT EXISTS local_blks_written bigint,
  ADD COLUMN IF NOT EXISTS wal_records bigint, ADD COLUMN IF NOT EXISTS wal_fpi bigint,
  ADD COLUMN IF NOT EXISTS wal_buffers_full bigint, ADD COLUMN IF NOT EXISTS jit_functions bigint,
  ADD COLUMN IF NOT EXISTS jit_generation_ms double precision, ADD COLUMN IF NOT EXISTS jit_inlining_count bigint,
  ADD COLUMN IF NOT EXISTS jit_inlining_ms double precision, ADD COLUMN IF NOT EXISTS jit_optimization_count bigint,
  ADD COLUMN IF NOT EXISTS jit_optimization_ms double precision, ADD COLUMN IF NOT EXISTS jit_emission_count bigint,
  ADD COLUMN IF NOT EXISTS jit_emission_ms double precision, ADD COLUMN IF NOT EXISTS jit_deform_count bigint,
  ADD COLUMN IF NOT EXISTS jit_deform_ms double precision,
  ADD COLUMN IF NOT EXISTS parallel_workers_to_launch bigint,
  ADD COLUMN IF NOT EXISTS parallel_workers_launched bigint, ADD COLUMN IF NOT EXISTS generic_plan_calls bigint,
  ADD COLUMN IF NOT EXISTS custom_plan_calls bigint;
ALTER TABLE pgvigil.statements_delta
  ADD COLUMN IF NOT EXISTS plans bigint, ADD COLUMN IF NOT EXISTS total_plan_ms double precision,
  ADD COLUMN IF NOT EXISTS local_blks_hit bigint, ADD COLUMN IF NOT EXISTS local_blks_read bigint,
  ADD COLUMN IF NOT EXISTS local_blks_dirtied bigint, ADD COLUMN IF NOT EXISTS local_blks_written bigint,
  ADD COLUMN IF NOT EXISTS wal_records bigint, ADD COLUMN IF NOT EXISTS wal_fpi bigint,
  ADD COLUMN IF NOT EXISTS wal_buffers_full bigint, ADD COLUMN IF NOT EXISTS jit_functions bigint,
  ADD COLUMN IF NOT EXISTS jit_generation_ms double precision, ADD COLUMN IF NOT EXISTS jit_inlining_count bigint,
  ADD COLUMN IF NOT EXISTS jit_inlining_ms double precision, ADD COLUMN IF NOT EXISTS jit_optimization_count bigint,
  ADD COLUMN IF NOT EXISTS jit_optimization_ms double precision, ADD COLUMN IF NOT EXISTS jit_emission_count bigint,
  ADD COLUMN IF NOT EXISTS jit_emission_ms double precision, ADD COLUMN IF NOT EXISTS jit_deform_count bigint,
  ADD COLUMN IF NOT EXISTS jit_deform_ms double precision,
  ADD COLUMN IF NOT EXISTS parallel_workers_to_launch bigint,
  ADD COLUMN IF NOT EXISTS parallel_workers_launched bigint, ADD COLUMN IF NOT EXISTS generic_plan_calls bigint,
  ADD COLUMN IF NOT EXISTS custom_plan_calls bigint;

-- 0017's import with the new columns: read from the payload, their differences stored like the old counters' (a reset
-- row stores the value since the reset), the cumulative values kept on statements_current. A NULL on either side (the
-- extension lacks the column; the baseline was stored before 0095) stores NULL: not known, never 0.
CREATE OR REPLACE FUNCTION pgvigil.import_statements(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_new_reset  timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_statements'), p_instance_id);
  PERFORM pgvigil.ensure_month_partition('statements_delta', p_snapshot_at);

  CREATE TEMP TABLE pgv_stmt_in ON COMMIT DROP AS
  SELECT DISTINCT ON (dbid, userid, queryid, toplevel)
         (r->>'dbid')::bigint AS dbid, r->>'datname' AS datname, (r->>'userid')::bigint AS userid, r->>'usename' AS usename,
         (r->>'queryid')::bigint AS queryid, coalesce((r->>'toplevel')::boolean, true) AS toplevel,
         (r->>'calls')::bigint AS calls, (r->>'total_exec_ms')::float8 AS total_exec_ms, (r->>'rows')::bigint AS rows,
         (r->>'shared_blks_hit')::bigint AS shared_blks_hit, (r->>'shared_blks_read')::bigint AS shared_blks_read,
         (r->>'shared_blks_dirtied')::bigint AS shared_blks_dirtied, (r->>'shared_blks_written')::bigint AS shared_blks_written,
         (r->>'temp_blks_read')::bigint AS temp_blks_read, (r->>'temp_blks_written')::bigint AS temp_blks_written,
         (r->>'blk_read_ms')::float8 AS blk_read_ms, (r->>'blk_write_ms')::float8 AS blk_write_ms,
         (r->>'temp_read_ms')::float8 AS temp_read_ms, (r->>'temp_write_ms')::float8 AS temp_write_ms,
         (r->>'wal_bytes')::numeric AS wal_bytes, r->>'query' AS query,
         (r->>'plans')::bigint AS plans, (r->>'total_plan_ms')::float8 AS total_plan_ms,
         (r->>'local_blks_hit')::bigint AS local_blks_hit, (r->>'local_blks_read')::bigint AS local_blks_read,
         (r->>'local_blks_dirtied')::bigint AS local_blks_dirtied,
         (r->>'local_blks_written')::bigint AS local_blks_written, (r->>'wal_records')::bigint AS wal_records,
         (r->>'wal_fpi')::bigint AS wal_fpi, (r->>'wal_buffers_full')::bigint AS wal_buffers_full,
         (r->>'jit_functions')::bigint AS jit_functions, (r->>'jit_generation_ms')::float8 AS jit_generation_ms,
         (r->>'jit_inlining_count')::bigint AS jit_inlining_count,
         (r->>'jit_inlining_ms')::float8 AS jit_inlining_ms,
         (r->>'jit_optimization_count')::bigint AS jit_optimization_count,
         (r->>'jit_optimization_ms')::float8 AS jit_optimization_ms,
         (r->>'jit_emission_count')::bigint AS jit_emission_count,
         (r->>'jit_emission_ms')::float8 AS jit_emission_ms, (r->>'jit_deform_count')::bigint AS jit_deform_count,
         (r->>'jit_deform_ms')::float8 AS jit_deform_ms,
         (r->>'parallel_workers_to_launch')::bigint AS parallel_workers_to_launch,
         (r->>'parallel_workers_launched')::bigint AS parallel_workers_launched,
         (r->>'generic_plan_calls')::bigint AS generic_plan_calls,
         (r->>'custom_plan_calls')::bigint AS custom_plan_calls
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'stmt' AND r->>'queryid' IS NOT NULL AND r->>'dbid' IS NOT NULL AND r->>'userid' IS NOT NULL
   ORDER BY dbid, userid, queryid, toplevel, calls DESC NULLS LAST, total_exec_ms DESC NULLS LAST;

  INSERT INTO pgvigil.statement_text AS t (instance_id, queryid, dbid, first_seen, last_seen, query)
  SELECT DISTINCT ON (queryid) p_instance_id, queryid, dbid, p_snapshot_at, p_snapshot_at, query
    FROM pgv_stmt_in WHERE coalesce(query, '') <> ''
   ORDER BY queryid
  ON CONFLICT (instance_id, queryid) DO UPDATE SET last_seen = EXCLUDED.last_seen;

  SELECT (r->>'stats_reset')::timestamptz INTO v_new_reset
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'info' LIMIT 1;

  INSERT INTO pgvigil.statements_delta (
    instance_id, snapshot_at, interval_secs, reset, dbid, datname, userid, usename, queryid, toplevel,
    calls, total_exec_ms, rows, shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
    temp_blks_read, temp_blks_written, blk_read_ms, blk_write_ms, temp_read_ms, temp_write_ms, wal_bytes,
    plans, total_plan_ms, local_blks_hit, local_blks_read, local_blks_dirtied, local_blks_written, wal_records,
    wal_fpi, wal_buffers_full, jit_functions, jit_generation_ms, jit_inlining_count, jit_inlining_ms,
    jit_optimization_count, jit_optimization_ms, jit_emission_count, jit_emission_ms, jit_deform_count,
    jit_deform_ms, parallel_workers_to_launch, parallel_workers_launched, generic_plan_calls, custom_plan_calls)
  SELECT p_instance_id, p_snapshot_at,
         greatest(1, extract(epoch FROM p_snapshot_at - CASE WHEN x.rs AND v_new_reset IS NOT NULL AND v_new_reset > c.snapshot_at
                                                              THEN v_new_reset ELSE c.snapshot_at END))::int,
         x.rs,
         i.dbid, i.datname, i.userid, i.usename, i.queryid, i.toplevel,
         CASE WHEN x.rs THEN i.calls ELSE i.calls - c.calls END,
         CASE WHEN x.rs THEN i.total_exec_ms ELSE i.total_exec_ms - c.total_exec_ms END,
         CASE WHEN x.rs THEN i.rows ELSE i.rows - c.rows END,
         CASE WHEN x.rs THEN i.shared_blks_hit ELSE i.shared_blks_hit - c.shared_blks_hit END,
         CASE WHEN x.rs THEN i.shared_blks_read ELSE i.shared_blks_read - c.shared_blks_read END,
         CASE WHEN x.rs THEN i.shared_blks_dirtied ELSE i.shared_blks_dirtied - c.shared_blks_dirtied END,
         CASE WHEN x.rs THEN i.shared_blks_written ELSE i.shared_blks_written - c.shared_blks_written END,
         CASE WHEN x.rs THEN i.temp_blks_read ELSE i.temp_blks_read - c.temp_blks_read END,
         CASE WHEN x.rs THEN i.temp_blks_written ELSE i.temp_blks_written - c.temp_blks_written END,
         CASE WHEN x.rs THEN i.blk_read_ms ELSE i.blk_read_ms - c.blk_read_ms END,
         CASE WHEN x.rs THEN i.blk_write_ms ELSE i.blk_write_ms - c.blk_write_ms END,
         CASE WHEN x.rs THEN i.temp_read_ms ELSE i.temp_read_ms - c.temp_read_ms END,
         CASE WHEN x.rs THEN i.temp_write_ms ELSE i.temp_write_ms - c.temp_write_ms END,
         CASE WHEN x.rs THEN i.wal_bytes ELSE i.wal_bytes - c.wal_bytes END,
         CASE WHEN x.rs THEN i.plans ELSE i.plans - c.plans END,
         CASE WHEN x.rs THEN i.total_plan_ms ELSE i.total_plan_ms - c.total_plan_ms END,
         CASE WHEN x.rs THEN i.local_blks_hit ELSE i.local_blks_hit - c.local_blks_hit END,
         CASE WHEN x.rs THEN i.local_blks_read ELSE i.local_blks_read - c.local_blks_read END,
         CASE WHEN x.rs THEN i.local_blks_dirtied ELSE i.local_blks_dirtied - c.local_blks_dirtied END,
         CASE WHEN x.rs THEN i.local_blks_written ELSE i.local_blks_written - c.local_blks_written END,
         CASE WHEN x.rs THEN i.wal_records ELSE i.wal_records - c.wal_records END,
         CASE WHEN x.rs THEN i.wal_fpi ELSE i.wal_fpi - c.wal_fpi END,
         CASE WHEN x.rs THEN i.wal_buffers_full ELSE i.wal_buffers_full - c.wal_buffers_full END,
         CASE WHEN x.rs THEN i.jit_functions ELSE i.jit_functions - c.jit_functions END,
         CASE WHEN x.rs THEN i.jit_generation_ms ELSE i.jit_generation_ms - c.jit_generation_ms END,
         CASE WHEN x.rs THEN i.jit_inlining_count ELSE i.jit_inlining_count - c.jit_inlining_count END,
         CASE WHEN x.rs THEN i.jit_inlining_ms ELSE i.jit_inlining_ms - c.jit_inlining_ms END,
         CASE WHEN x.rs THEN i.jit_optimization_count ELSE i.jit_optimization_count - c.jit_optimization_count END,
         CASE WHEN x.rs THEN i.jit_optimization_ms ELSE i.jit_optimization_ms - c.jit_optimization_ms END,
         CASE WHEN x.rs THEN i.jit_emission_count ELSE i.jit_emission_count - c.jit_emission_count END,
         CASE WHEN x.rs THEN i.jit_emission_ms ELSE i.jit_emission_ms - c.jit_emission_ms END,
         CASE WHEN x.rs THEN i.jit_deform_count ELSE i.jit_deform_count - c.jit_deform_count END,
         CASE WHEN x.rs THEN i.jit_deform_ms ELSE i.jit_deform_ms - c.jit_deform_ms END,
         CASE WHEN x.rs THEN i.parallel_workers_to_launch ELSE i.parallel_workers_to_launch - c.parallel_workers_to_launch END,
         CASE WHEN x.rs THEN i.parallel_workers_launched ELSE i.parallel_workers_launched - c.parallel_workers_launched END,
         CASE WHEN x.rs THEN i.generic_plan_calls ELSE i.generic_plan_calls - c.generic_plan_calls END,
         CASE WHEN x.rs THEN i.custom_plan_calls ELSE i.custom_plan_calls - c.custom_plan_calls END
    FROM pgv_stmt_in i
    JOIN pgvigil.statements_current c
      ON c.instance_id = p_instance_id AND c.dbid = i.dbid AND c.userid = i.userid
     AND c.queryid = i.queryid AND c.toplevel = i.toplevel
    CROSS JOIN LATERAL (SELECT (v_new_reset IS NOT NULL AND c.stats_reset IS NOT NULL AND c.stats_reset <> v_new_reset)
                           OR i.calls < c.calls OR i.total_exec_ms < c.total_exec_ms OR i.rows < c.rows
                           OR i.shared_blks_hit < c.shared_blks_hit OR i.shared_blks_read < c.shared_blks_read
                           OR i.wal_bytes < c.wal_bytes AS rs) x
   WHERE (i.calls <> c.calls OR x.rs) AND i.calls > 0;

  INSERT INTO pgvigil.statements_current AS c (
    instance_id, dbid, userid, queryid, toplevel, snapshot_at, stats_reset, calls, total_exec_ms, rows,
    shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written, temp_blks_read, temp_blks_written,
    blk_read_ms, blk_write_ms, temp_read_ms, temp_write_ms, wal_bytes,
    plans, total_plan_ms, local_blks_hit, local_blks_read, local_blks_dirtied, local_blks_written, wal_records,
    wal_fpi, wal_buffers_full, jit_functions, jit_generation_ms, jit_inlining_count, jit_inlining_ms,
    jit_optimization_count, jit_optimization_ms, jit_emission_count, jit_emission_ms, jit_deform_count,
    jit_deform_ms, parallel_workers_to_launch, parallel_workers_launched, generic_plan_calls, custom_plan_calls)
  SELECT p_instance_id, dbid, userid, queryid, toplevel, p_snapshot_at, v_new_reset, calls, total_exec_ms, rows,
         shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written, temp_blks_read, temp_blks_written,
         blk_read_ms, blk_write_ms, temp_read_ms, temp_write_ms, wal_bytes,
         plans, total_plan_ms, local_blks_hit, local_blks_read, local_blks_dirtied, local_blks_written, wal_records,
         wal_fpi, wal_buffers_full, jit_functions, jit_generation_ms, jit_inlining_count, jit_inlining_ms,
         jit_optimization_count, jit_optimization_ms, jit_emission_count, jit_emission_ms, jit_deform_count,
         jit_deform_ms, parallel_workers_to_launch, parallel_workers_launched, generic_plan_calls, custom_plan_calls
    FROM pgv_stmt_in
  ON CONFLICT (instance_id, dbid, userid, queryid, toplevel) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, stats_reset = coalesce(EXCLUDED.stats_reset, c.stats_reset), calls = EXCLUDED.calls, total_exec_ms = EXCLUDED.total_exec_ms, rows = EXCLUDED.rows,
    shared_blks_hit = EXCLUDED.shared_blks_hit, shared_blks_read = EXCLUDED.shared_blks_read,
    shared_blks_dirtied = EXCLUDED.shared_blks_dirtied, shared_blks_written = EXCLUDED.shared_blks_written,
    temp_blks_read = EXCLUDED.temp_blks_read, temp_blks_written = EXCLUDED.temp_blks_written,
    blk_read_ms = EXCLUDED.blk_read_ms, blk_write_ms = EXCLUDED.blk_write_ms,
    temp_read_ms = EXCLUDED.temp_read_ms, temp_write_ms = EXCLUDED.temp_write_ms, wal_bytes = EXCLUDED.wal_bytes,
    plans = EXCLUDED.plans, total_plan_ms = EXCLUDED.total_plan_ms, local_blks_hit = EXCLUDED.local_blks_hit,
    local_blks_read = EXCLUDED.local_blks_read, local_blks_dirtied = EXCLUDED.local_blks_dirtied,
    local_blks_written = EXCLUDED.local_blks_written, wal_records = EXCLUDED.wal_records, wal_fpi = EXCLUDED.wal_fpi,
    wal_buffers_full = EXCLUDED.wal_buffers_full, jit_functions = EXCLUDED.jit_functions,
    jit_generation_ms = EXCLUDED.jit_generation_ms, jit_inlining_count = EXCLUDED.jit_inlining_count,
    jit_inlining_ms = EXCLUDED.jit_inlining_ms, jit_optimization_count = EXCLUDED.jit_optimization_count,
    jit_optimization_ms = EXCLUDED.jit_optimization_ms, jit_emission_count = EXCLUDED.jit_emission_count,
    jit_emission_ms = EXCLUDED.jit_emission_ms, jit_deform_count = EXCLUDED.jit_deform_count,
    jit_deform_ms = EXCLUDED.jit_deform_ms, parallel_workers_to_launch = EXCLUDED.parallel_workers_to_launch,
    parallel_workers_launched = EXCLUDED.parallel_workers_launched, generic_plan_calls = EXCLUDED.generic_plan_calls,
    custom_plan_calls = EXCLUDED.custom_plan_calls;

  INSERT INTO pgvigil.statements_info (instance_id, snapshot_at, dealloc, stats_reset)
  SELECT p_instance_id, p_snapshot_at, (r->>'dealloc')::bigint, (r->>'stats_reset')::timestamptz
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'info'
  ON CONFLICT (instance_id, snapshot_at) DO NOTHING;
END $$;

-- The statements of a window with their depth counters (top_statements_by's window scaling: a delta counts by the share of
-- its interval inside the window). p_order: plan (planning time), jit (JIT time), wal (WAL bytes), fpi (full-page images),
-- workers (workers planned and not launched, then launched), time (execution); anything else = plan. server_pct is the
-- statement's share of the execution time of every statement of the window (not only the rows returned).
CREATE OR REPLACE FUNCTION pgvigil.statement_depth(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                                   p_order text DEFAULT 'plan', p_limit int DEFAULT 50)
RETURNS TABLE (queryid bigint, datname text, usename text, calls double precision, total_exec_ms double precision,
               plans double precision, total_plan_ms double precision, mean_plan_ms double precision, plan_pct numeric,
               jit_functions double precision, jit_ms double precision, jit_pct numeric,
               wal_records double precision, wal_fpi double precision, wal_bytes numeric, fpi_pct numeric,
               wal_buffers_full double precision, workers_to_launch double precision, workers_launched double precision,
               workers_missing double precision, generic_plan_calls double precision, custom_plan_calls double precision,
               local_blks_read double precision, local_blks_written double precision, temp_blks_read double precision,
               temp_blks_written double precision, server_pct numeric, query text)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT d.*,
           greatest(0, extract(epoch FROM least(d.snapshot_at, p_to) - greatest(d.snapshot_at - make_interval(secs => d.interval_secs), p_from)))
             / d.interval_secs AS share
      FROM pgvigil.statements_delta d
     WHERE d.instance_id = p_instance_id
       AND d.snapshot_at > p_from
       AND d.snapshot_at - make_interval(secs => d.interval_secs) < p_to
  ), a AS (
    SELECT d.queryid, min(d.datname) AS datname, min(d.usename) AS usename,
           sum(d.calls * d.share) AS calls, sum(d.total_exec_ms * d.share) AS total_exec_ms,
           sum(d.plans * d.share) AS plans, sum(d.total_plan_ms * d.share) AS total_plan_ms,
           sum(d.jit_functions * d.share) AS jit_functions,
           sum((CASE WHEN d.jit_generation_ms IS NULL THEN NULL ELSE d.jit_generation_ms + coalesce(d.jit_inlining_ms, 0)
                     + coalesce(d.jit_optimization_ms, 0) + coalesce(d.jit_emission_ms, 0) + coalesce(d.jit_deform_ms, 0) END) * d.share) AS jit_ms,
           sum(d.wal_records * d.share) AS wal_records, sum(d.wal_fpi * d.share) AS wal_fpi,
           sum(d.wal_bytes * d.share::numeric) AS wal_bytes, sum(d.wal_buffers_full * d.share) AS wal_buffers_full,
           sum(d.parallel_workers_to_launch * d.share) AS workers_to_launch, sum(d.parallel_workers_launched * d.share) AS workers_launched,
           sum(d.generic_plan_calls * d.share) AS generic_plan_calls, sum(d.custom_plan_calls * d.share) AS custom_plan_calls,
           sum(d.local_blks_read * d.share) AS local_blks_read, sum(d.local_blks_written * d.share) AS local_blks_written,
           sum(d.temp_blks_read * d.share) AS temp_blks_read, sum(d.temp_blks_written * d.share) AS temp_blks_written
      FROM d WHERE d.share > 0
     GROUP BY d.queryid
  ), t AS (
    SELECT a.*, sum(a.total_exec_ms) OVER () AS all_exec_ms FROM a
  )
  SELECT t.queryid, t.datname, t.usename, t.calls, t.total_exec_ms, t.plans, t.total_plan_ms, t.total_plan_ms / nullif(t.plans, 0),
         round((100 * t.total_plan_ms / nullif(t.total_plan_ms + t.total_exec_ms, 0))::numeric, 1),
         t.jit_functions, t.jit_ms, round((100 * t.jit_ms / nullif(t.total_exec_ms, 0))::numeric, 1),
         t.wal_records, t.wal_fpi, t.wal_bytes, round((100 * t.wal_fpi / nullif(t.wal_records, 0))::numeric, 1),
         t.wal_buffers_full, t.workers_to_launch, t.workers_launched, t.workers_to_launch - t.workers_launched,
         t.generic_plan_calls, t.custom_plan_calls, t.local_blks_read, t.local_blks_written, t.temp_blks_read, t.temp_blks_written,
         round((100 * t.total_exec_ms / nullif(t.all_exec_ms, 0))::numeric, 1),
         (SELECT x.query FROM pgvigil.statement_text x WHERE x.instance_id = p_instance_id AND x.queryid = t.queryid)
    FROM t
   ORDER BY CASE lower(coalesce(p_order, 'plan'))
              WHEN 'time'    THEN t.total_exec_ms
              WHEN 'jit'     THEN t.jit_ms
              WHEN 'wal'     THEN t.wal_bytes::float8
              WHEN 'fpi'     THEN t.wal_fpi
              WHEN 'workers' THEN coalesce(t.workers_to_launch - t.workers_launched, 0) * 1e9 + coalesce(t.workers_launched, 0)
              ELSE t.total_plan_ms END DESC NULLS LAST, t.total_exec_ms DESC NULLS LAST, t.queryid
   LIMIT greatest(p_limit, 1)
$$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. the server's state (dbstats 'wal' rows)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.wal_state_sample (
  instance_id           int NOT NULL,
  snapshot_at           timestamptz NOT NULL,
  in_recovery           boolean,
  checkpoint_time       timestamptz,            -- pg_control_checkpoint(): the last checkpoint (a restartpoint on a standby)
  timeline_id           int,                    -- the server's timeline now (a primary's WAL insert, a standby's receiver)
  checkpoint_timeline_id int,                   -- the last checkpoint's
  redo_lsn              text,
  wal_since_redo        bigint,                 -- bytes from the redo point to the insert (on a standby: replay) position
  system_identifier     text,
  checkpoint_timeout_s  int,
  max_connections       int,
  superuser_reserved    int,
  reserved_connections  int,                    -- 16+, 0 before
  client_backends       int,
  standbys              int,                    -- physical walsenders streaming
  archive_mode          text,
  archive_ready         int,                    -- .ready files waiting for the archiver (NULL: not read, wal_note says why)
  archive_oldest_ready  timestamptz,
  wal_files             int,
  wal_dir_bytes         bigint,
  wal_note              text,
  checkpoint_age_s      bigint,                 -- the server's now() less checkpoint_time (no collector clock in it)
  archive_oldest_age_s  bigint                  -- the server's now() less the oldest .ready file's time
) PARTITION BY RANGE (snapshot_at);

-- 0011's import with the 'wal' row stored (the rest unchanged)
CREATE OR REPLACE FUNCTION pgvigil.import_dbstats(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_dbstats'), p_instance_id);
  PERFORM pgvigil.ensure_month_partition('dbstats', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('serverstats', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('iostats', p_snapshot_at);

  WITH n AS (SELECT DISTINCT ON ((r->>'dbid')::bigint) (r->>'dbid')::bigint AS dbid, r,
                    (r->>'postmaster_start')::timestamptz AS pm
               FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db'),
  e AS (SELECT n.dbid, n.r, n.pm, l.snapshot_at AS last_at,
               CASE WHEN l.instance_id IS NULL THEN 0
                    WHEN p_snapshot_at <= l.snapshot_at THEN
                      CASE WHEN n.pm <> l.postmaster_start
                             OR (n.r->>'stats_reset')::timestamptz IS DISTINCT FROM l.stats_reset
                             OR (n.r->>'xact_commit')::bigint > l.xact_commit
                             OR (n.r->>'deadlocks')::bigint > l.deadlocks
                             OR (n.r->>'checksum_failures')::bigint > l.checksum_failures THEN l.epoch - 1
                           ELSE l.epoch END
                    WHEN n.pm <> l.postmaster_start
                      OR (n.r->>'stats_reset')::timestamptz IS DISTINCT FROM l.stats_reset
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
  INSERT INTO pgvigil.dbstats_last AS l (instance_id, dbid, epoch, snapshot_at, postmaster_start, stats_reset, xact_commit, deadlocks, checksum_failures)
  SELECT p_instance_id, e.dbid, e.epoch, p_snapshot_at, e.pm, (e.r->>'stats_reset')::timestamptz, (e.r->>'xact_commit')::bigint,
         (e.r->>'deadlocks')::bigint, (e.r->>'checksum_failures')::bigint
    FROM e WHERE e.last_at IS NULL OR p_snapshot_at > e.last_at
  ON CONFLICT (instance_id, dbid) DO UPDATE SET epoch = EXCLUDED.epoch, snapshot_at = EXCLUDED.snapshot_at,
     postmaster_start = EXCLUDED.postmaster_start, stats_reset = EXCLUDED.stats_reset, xact_commit = EXCLUDED.xact_commit, deadlocks = EXCLUDED.deadlocks,
     checksum_failures = EXCLUDED.checksum_failures
   WHERE l.snapshot_at < EXCLUDED.snapshot_at;

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

  -- 0095: the server's state
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'wal') THEN
    PERFORM pgvigil.ensure_month_partition('wal_state_sample', p_snapshot_at);
    INSERT INTO pgvigil.wal_state_sample (
      instance_id, snapshot_at, in_recovery, checkpoint_time, timeline_id, checkpoint_timeline_id, redo_lsn, wal_since_redo, system_identifier,
      checkpoint_timeout_s, max_connections, superuser_reserved, reserved_connections, client_backends, standbys, archive_mode,
      archive_ready, archive_oldest_ready, wal_files, wal_dir_bytes, wal_note, checkpoint_age_s, archive_oldest_age_s)
    SELECT p_instance_id, p_snapshot_at, (r->>'in_recovery')::boolean, (r->>'checkpoint_time')::timestamptz, (r->>'timeline_id')::int,
           (r->>'checkpoint_timeline_id')::int,
           r->>'redo_lsn', (r->>'wal_since_redo')::bigint, r->>'system_identifier', (r->>'checkpoint_timeout_s')::int,
           (r->>'max_connections')::int, (r->>'superuser_reserved')::int, (r->>'reserved_connections')::int,
           (r->>'client_backends')::int, (r->>'standbys')::int, r->>'archive_mode', (r->>'archive_ready')::int,
           (r->>'archive_oldest_ready')::timestamptz, (r->>'wal_files')::int, (r->>'wal_dir_bytes')::bigint, r->>'wal_note',
           (r->>'checkpoint_age_s')::bigint, (r->>'archive_oldest_age_s')::bigint
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'wal'
     LIMIT 1;
  END IF;
END $$;

-- The newest server state per instance with its cells: the checkpoint's age at the read, the connections a client may use
-- (max_connections less the superuser and the reserved slots) and their share used, the oldest .ready file's age, and the
-- last timeline or system identifier change seen in the 24 hours before the read (prev_* is the value before it, changed_at
-- the first read that saw the new value).
CREATE OR REPLACE VIEW pgvigil.wal_state_latest AS
SELECT n.instance_id, n.snapshot_at, n.in_recovery, n.checkpoint_time, n.timeline_id, n.checkpoint_timeline_id, n.redo_lsn,
       n.wal_since_redo, n.system_identifier, n.checkpoint_timeout_s, n.max_connections, n.superuser_reserved,
       n.reserved_connections, n.client_backends, n.standbys, n.archive_mode, n.archive_ready, n.archive_oldest_ready,
       n.wal_files, n.wal_dir_bytes, n.wal_note,
       -- the server's own age where the collector sent it (0095's collector does), else the read time's
       coalesce(n.checkpoint_age_s, extract(epoch FROM n.snapshot_at - n.checkpoint_time)::bigint) AS checkpoint_age_s,
       n.max_connections - coalesce(n.superuser_reserved, 0) - coalesce(n.reserved_connections, 0) AS client_limit,
       round(100.0 * n.client_backends / nullif(n.max_connections - coalesce(n.superuser_reserved, 0) - coalesce(n.reserved_connections, 0), 0), 1) AS connections_pct,
       coalesce(n.archive_oldest_age_s, extract(epoch FROM n.snapshot_at - n.archive_oldest_ready)::bigint) AS archive_oldest_age_s,
       tl.timeline_id AS prev_timeline_id, tl_at.changed_at AS timeline_changed_at,
       si.system_identifier AS prev_system_identifier, si_at.changed_at AS system_identifier_changed_at
  FROM pgvigil.instances i
  CROSS JOIN LATERAL (SELECT s.* FROM pgvigil.wal_state_sample s WHERE s.instance_id = i.instance_id
                       ORDER BY s.snapshot_at DESC LIMIT 1) n
  LEFT JOIN LATERAL (SELECT p.timeline_id, p.snapshot_at FROM pgvigil.wal_state_sample p
                      WHERE p.instance_id = n.instance_id AND p.snapshot_at < n.snapshot_at
                        AND p.snapshot_at >= n.snapshot_at - interval '24 hours'
                        AND p.timeline_id IS NOT NULL AND n.timeline_id IS NOT NULL AND p.timeline_id <> n.timeline_id
                      ORDER BY p.snapshot_at DESC LIMIT 1) tl ON true
  LEFT JOIN LATERAL (SELECT min(q.snapshot_at) AS changed_at FROM pgvigil.wal_state_sample q
                      WHERE q.instance_id = n.instance_id AND tl.snapshot_at IS NOT NULL AND q.snapshot_at > tl.snapshot_at
                        AND q.timeline_id = n.timeline_id) tl_at ON true
  LEFT JOIN LATERAL (SELECT p.system_identifier, p.snapshot_at FROM pgvigil.wal_state_sample p
                      WHERE p.instance_id = n.instance_id AND p.snapshot_at < n.snapshot_at
                        AND p.snapshot_at >= n.snapshot_at - interval '24 hours'
                        AND p.system_identifier IS NOT NULL AND n.system_identifier IS NOT NULL AND p.system_identifier <> n.system_identifier
                      ORDER BY p.snapshot_at DESC LIMIT 1) si ON true
  LEFT JOIN LATERAL (SELECT min(q.snapshot_at) AS changed_at FROM pgvigil.wal_state_sample q
                      WHERE q.instance_id = n.instance_id AND si.snapshot_at IS NOT NULL AND q.snapshot_at > si.snapshot_at
                        AND q.system_identifier = n.system_identifier) si_at ON true;

-- ---------------------------------------------------------------------------------------------------------------------
-- the databases each per-database collection of this file read last (functions, dbchecks, index_bloat)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.depth_databases (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  collection       text NOT NULL,
  dbid             bigint NOT NULL,
  datname          text NOT NULL,
  track_functions  text,                       -- functions: the setting in force in that database
  snapshot_at      timestamptz NOT NULL,
  is_present       boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, collection, dbid)
);

-- import_depth_databases: the 'db' rows of a per-database payload upserted; a stored database neither read now nor in error
-- ('<collection>:<datname>' collector_error) is no longer present. Called by the three imports below.
CREATE OR REPLACE FUNCTION pgvigil.import_depth_databases(p_instance_id int, p_collection text, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.depth_databases AS d (instance_id, collection, dbid, datname, track_functions, snapshot_at, is_present)
  SELECT DISTINCT ON ((r->>'dbid')::bigint) p_instance_id, p_collection, (r->>'dbid')::bigint, r->>'datname', r->>'track_functions', p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND r->>'dbid' IS NOT NULL
  ON CONFLICT (instance_id, collection, dbid) DO UPDATE SET datname = EXCLUDED.datname, track_functions = EXCLUDED.track_functions,
    snapshot_at = EXCLUDED.snapshot_at, is_present = true;
  UPDATE pgvigil.depth_databases d SET is_present = false, snapshot_at = p_snapshot_at
   WHERE d.instance_id = p_instance_id AND d.collection = p_collection AND d.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = d.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'collector_error' AND r->>'source' = p_collection || ':' || d.datname);
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 3. functions
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.function_stats (
  instance_id   int NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  dbid          bigint NOT NULL,
  datname       text,
  funcid        bigint NOT NULL,
  schema_name   text,
  func_name     text,
  args          text,
  calls         bigint,
  total_ms      double precision,               -- with the functions it calls
  self_ms       double precision                -- without them
) PARTITION BY RANGE (snapshot_at);

CREATE OR REPLACE FUNCTION pgvigil.import_functions(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_functions'), p_instance_id);
  PERFORM pgvigil.import_depth_databases(p_instance_id, 'functions', p_snapshot_at, p_payload);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'func') THEN
    PERFORM pgvigil.ensure_month_partition('function_stats', p_snapshot_at);
    INSERT INTO pgvigil.function_stats (instance_id, snapshot_at, dbid, datname, funcid, schema_name, func_name, args, calls, total_ms, self_ms)
    SELECT DISTINCT ON ((r->>'dbid')::bigint, (r->>'funcid')::bigint)
           p_instance_id, p_snapshot_at, (r->>'dbid')::bigint, r->>'datname', (r->>'funcid')::bigint, r->>'schema_name', r->>'func_name',
           r->>'args', (r->>'calls')::bigint, (r->>'total_ms')::float8, (r->>'self_ms')::float8
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'func' AND r->>'dbid' IS NOT NULL AND r->>'funcid' IS NOT NULL;
  END IF;
END $$;

-- The functions of a window: per function the difference of its counters between consecutive reads that end inside the
-- window (a counter that went backwards - a stats reset, a restart - counts its value since then), so the first read after
-- p_from takes its baseline from the read before it (up to a day earlier). p_order: total (time with callees), self, calls,
-- mean (total per call); anything else = total. share_pct = the function's share of every function's total time in the
-- window.
CREATE OR REPLACE FUNCTION pgvigil.function_top(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                                p_order text DEFAULT 'total', p_limit int DEFAULT 50)
RETURNS TABLE (dbid bigint, datname text, funcid bigint, schema_name text, func_name text, args text, calls bigint,
               total_ms double precision, self_ms double precision, mean_ms double precision, self_mean_ms double precision,
               share_pct numeric, reads int)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT f.*, lag(f.calls) OVER w AS p_calls, lag(f.total_ms) OVER w AS p_total, lag(f.self_ms) OVER w AS p_self
      FROM pgvigil.function_stats f
     WHERE f.instance_id = p_instance_id AND f.snapshot_at > p_from - interval '1 day' AND f.snapshot_at <= p_to
    WINDOW w AS (PARTITION BY f.dbid, f.funcid ORDER BY f.snapshot_at)
  ), d AS (
    SELECT s.dbid, s.funcid, s.snapshot_at, s.datname, s.schema_name, s.func_name, s.args,
           CASE WHEN s.calls >= s.p_calls AND s.total_ms >= s.p_total THEN s.calls - s.p_calls ELSE s.calls END AS calls,
           CASE WHEN s.calls >= s.p_calls AND s.total_ms >= s.p_total THEN s.total_ms - s.p_total ELSE s.total_ms END AS total_ms,
           CASE WHEN s.calls >= s.p_calls AND s.total_ms >= s.p_total THEN s.self_ms - s.p_self ELSE s.self_ms END AS self_ms
      FROM s WHERE s.p_calls IS NOT NULL AND s.snapshot_at > p_from
  ), a AS (
    SELECT d.dbid, d.funcid, (array_agg(d.datname ORDER BY d.snapshot_at DESC))[1] AS datname,
           (array_agg(d.schema_name ORDER BY d.snapshot_at DESC))[1] AS schema_name,
           (array_agg(d.func_name ORDER BY d.snapshot_at DESC))[1] AS func_name,
           (array_agg(d.args ORDER BY d.snapshot_at DESC))[1] AS args,
           sum(d.calls)::bigint AS calls, sum(d.total_ms) AS total_ms, sum(d.self_ms) AS self_ms, count(*)::int AS reads
      FROM d GROUP BY d.dbid, d.funcid
  )
  SELECT a.dbid, a.datname, a.funcid, a.schema_name, a.func_name, a.args, a.calls, a.total_ms, a.self_ms,
         a.total_ms / nullif(a.calls, 0), a.self_ms / nullif(a.calls, 0),
         round((100 * a.total_ms / nullif(sum(a.total_ms) OVER (), 0))::numeric, 1), a.reads
    FROM a WHERE a.calls > 0
   ORDER BY CASE lower(coalesce(p_order, 'total'))
              WHEN 'self'  THEN a.self_ms
              WHEN 'calls' THEN a.calls::float8
              WHEN 'mean'  THEN a.total_ms / nullif(a.calls, 0)
              ELSE a.total_ms END DESC NULLS LAST, a.dbid, a.funcid
   LIMIT greatest(p_limit, 1)
$$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 4. SLRU caches
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.slru_sample (
  instance_id   int NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  name          text NOT NULL,
  blks_zeroed   bigint, blks_hit bigint, blks_read bigint, blks_written bigint, blks_exists bigint,
  flushes       bigint, truncates bigint,
  stats_reset   timestamptz
) PARTITION BY RANGE (snapshot_at);

CREATE OR REPLACE FUNCTION pgvigil.import_slru(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.ensure_month_partition('slru_sample', p_snapshot_at);
  INSERT INTO pgvigil.slru_sample (instance_id, snapshot_at, name, blks_zeroed, blks_hit, blks_read, blks_written, blks_exists, flushes, truncates, stats_reset)
  SELECT DISTINCT ON (r->>'name') p_instance_id, p_snapshot_at, r->>'name', (r->>'blks_zeroed')::bigint, (r->>'blks_hit')::bigint,
         (r->>'blks_read')::bigint, (r->>'blks_written')::bigint, (r->>'blks_exists')::bigint, (r->>'flushes')::bigint,
         (r->>'truncates')::bigint, (r->>'stats_reset')::timestamptz
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'slru' AND r->>'name' IS NOT NULL;
END $$;

-- slru_family: one name per cache whatever the version spells it (17 renamed them)
CREATE OR REPLACE FUNCTION pgvigil.slru_family(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE lower(replace(p_name, '_', ''))
           WHEN 'subtrans' THEN 'subtransaction' WHEN 'subtransaction' THEN 'subtransaction'
           WHEN 'multixactmember' THEN 'multixact_member' WHEN 'multixactoffset' THEN 'multixact_offset'
           WHEN 'xact' THEN 'transaction' WHEN 'transaction' THEN 'transaction'
           WHEN 'committs' THEN 'commit_timestamp' WHEN 'committimestamp' THEN 'commit_timestamp'
           WHEN 'serial' THEN 'serializable' WHEN 'serializable' THEN 'serializable'
           ELSE lower(p_name) END
$$;

-- The SLRU caches over a window: one row per read and cache with the difference to the read before it (NULL across a reset:
-- stats_reset moved or a counter went backwards) and the seconds between them; family groups the version's names
-- (Subtrans / subtransaction, MultiXactMember / multixact_member, ...) under one lower-case name.
CREATE OR REPLACE FUNCTION pgvigil.slru_rate(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, name text, family text, interval_secs int, blks_zeroed bigint, blks_hit bigint,
               blks_read bigint, blks_written bigint, blks_exists bigint, flushes bigint, truncates bigint, hit_pct numeric)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT x.*, lag(x.snapshot_at) OVER w AS p_at, lag(x.stats_reset) OVER w AS p_reset,
           lag(x.blks_zeroed) OVER w AS p_zeroed, lag(x.blks_hit) OVER w AS p_hit, lag(x.blks_read) OVER w AS p_read,
           lag(x.blks_written) OVER w AS p_written, lag(x.blks_exists) OVER w AS p_exists, lag(x.flushes) OVER w AS p_flushes,
           lag(x.truncates) OVER w AS p_truncates
      FROM pgvigil.slru_sample x
     WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from - interval '1 hour' AND x.snapshot_at <= p_to
    WINDOW w AS (PARTITION BY x.name ORDER BY x.snapshot_at)
  ), d AS (
    SELECT s.*, (s.stats_reset IS DISTINCT FROM s.p_reset OR coalesce(s.blks_read < s.p_read, false) OR coalesce(s.blks_hit < s.p_hit, false)
                 OR coalesce(s.blks_zeroed < s.p_zeroed, false) OR coalesce(s.blks_written < s.p_written, false)) AS rs
      FROM s WHERE s.p_at IS NOT NULL AND s.snapshot_at > p_from
  )
  SELECT d.snapshot_at, d.name, pgvigil.slru_family(d.name), extract(epoch FROM d.snapshot_at - d.p_at)::int,
         CASE WHEN NOT d.rs THEN d.blks_zeroed - d.p_zeroed END, CASE WHEN NOT d.rs THEN d.blks_hit - d.p_hit END,
         CASE WHEN NOT d.rs THEN d.blks_read - d.p_read END, CASE WHEN NOT d.rs THEN d.blks_written - d.p_written END,
         CASE WHEN NOT d.rs THEN d.blks_exists - d.p_exists END, CASE WHEN NOT d.rs THEN d.flushes - d.p_flushes END,
         CASE WHEN NOT d.rs THEN d.truncates - d.p_truncates END,
         CASE WHEN NOT d.rs THEN round(100.0 * (d.blks_hit - d.p_hit) / nullif((d.blks_hit - d.p_hit) + (d.blks_read - d.p_read), 0), 1) END
    FROM d
   ORDER BY d.snapshot_at, d.name
$$;

-- The newest two reads of each cache per instance and the pages read from disk between them (the finding's source).
CREATE OR REPLACE VIEW pgvigil.slru_latest AS
SELECT n.instance_id, n.snapshot_at, n.name, pgvigil.slru_family(n.name) AS family, p.snapshot_at AS prev_at,
       CASE WHEN n.stats_reset IS NOT DISTINCT FROM p.stats_reset AND n.blks_read >= p.blks_read THEN n.blks_read - p.blks_read END AS read_delta,
       CASE WHEN n.stats_reset IS NOT DISTINCT FROM p.stats_reset AND n.blks_hit >= p.blks_hit THEN n.blks_hit - p.blks_hit END AS hit_delta
  FROM pgvigil.instances i
  CROSS JOIN LATERAL (SELECT s.snapshot_at FROM pgvigil.slru_sample s WHERE s.instance_id = i.instance_id
                       ORDER BY s.snapshot_at DESC LIMIT 1) m
  JOIN pgvigil.slru_sample n ON n.instance_id = i.instance_id AND n.snapshot_at = m.snapshot_at
  JOIN LATERAL (SELECT q.* FROM pgvigil.slru_sample q
                 WHERE q.instance_id = n.instance_id AND q.name = n.name AND q.snapshot_at < n.snapshot_at
                   AND q.snapshot_at >= n.snapshot_at - interval '1 hour'
                 ORDER BY q.snapshot_at DESC LIMIT 1) p ON true;

-- ---------------------------------------------------------------------------------------------------------------------
-- 5. sequences and the catalog checks (dbchecks)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.sequence_state (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid          bigint NOT NULL,
  seqrelid      bigint NOT NULL,
  datname       text NOT NULL,
  schema_name   text NOT NULL,
  seq_name      text NOT NULL,
  data_type     text,
  increment_by  bigint,
  min_value     bigint,
  max_value     bigint,
  cycles        boolean,
  readable      boolean,                -- the login may read the sequence's value (SELECT or USAGE, or pg_read_all_data)
  last_value    bigint,                 -- NULL: not readable, or never used
  col_schema    text,                   -- the column the sequence feeds (identity, serial or DEFAULT nextval)
  col_table     text,
  col_name      text,
  col_type      text,
  col_max       numeric,
  pct_used      numeric,                -- against the smaller of the sequence's maximum and the column type's
  blks_read     bigint,
  blks_hit      bigint,
  first_seen    timestamptz NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  is_present    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid, seqrelid)
);

CREATE TABLE IF NOT EXISTS pgvigil.db_checks (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid          bigint NOT NULL,        -- 0 for the instance's own checks (md5)
  check_kind    text NOT NULL,          -- secdef, notvalid, defpart, public_create, md5
  object        text NOT NULL,
  datname       text,
  figure        numeric,
  detail        text,
  fix_sql       text,
  first_seen    timestamptz NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  is_present    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid, check_kind, object)
);

-- payload: {kind:'db'} per database read, {kind:'seq'} per sequence, {kind:'check', check_kind, object, ...} per catalog
-- finding, {kind:'md5_read'} / {kind:'md5_unread'} once (whether pg_authid could be read), {kind:'collector_error',
-- source:'dbchecks:<db>'} per database in error. A row of a database read now that is not in the payload is gone; an md5
-- row is gone only when pg_authid was read.
CREATE OR REPLACE FUNCTION pgvigil.import_dbchecks(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_dbchecks'), p_instance_id);
  PERFORM pgvigil.import_depth_databases(p_instance_id, 'dbchecks', p_snapshot_at, p_payload);

  INSERT INTO pgvigil.sequence_state AS q (instance_id, dbid, seqrelid, datname, schema_name, seq_name, data_type, increment_by,
    min_value, max_value, cycles, readable, last_value, col_schema, col_table, col_name, col_type, col_max, pct_used,
    blks_read, blks_hit, first_seen, snapshot_at, is_present)
  SELECT DISTINCT ON ((r->>'dbid')::bigint, (r->>'seqrelid')::bigint)
         p_instance_id, (r->>'dbid')::bigint, (r->>'seqrelid')::bigint, r->>'datname', r->>'schema_name', r->>'seq_name',
         r->>'data_type', (r->>'increment_by')::bigint, (r->>'min_value')::bigint, (r->>'max_value')::bigint,
         (r->>'cycles')::boolean, (r->>'readable')::boolean, (r->>'last_value')::bigint, r->>'col_schema', r->>'col_table',
         r->>'col_name', r->>'col_type', (r->>'col_max')::numeric, (r->>'pct_used')::numeric, (r->>'blks_read')::bigint,
         (r->>'blks_hit')::bigint, p_snapshot_at, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'seq' AND r->>'dbid' IS NOT NULL AND r->>'seqrelid' IS NOT NULL
  ON CONFLICT (instance_id, dbid, seqrelid) DO UPDATE SET datname = EXCLUDED.datname, schema_name = EXCLUDED.schema_name,
    seq_name = EXCLUDED.seq_name, data_type = EXCLUDED.data_type, increment_by = EXCLUDED.increment_by,
    min_value = EXCLUDED.min_value, max_value = EXCLUDED.max_value, cycles = EXCLUDED.cycles, readable = EXCLUDED.readable,
    last_value = EXCLUDED.last_value, col_schema = EXCLUDED.col_schema, col_table = EXCLUDED.col_table, col_name = EXCLUDED.col_name,
    col_type = EXCLUDED.col_type, col_max = EXCLUDED.col_max, pct_used = EXCLUDED.pct_used, blks_read = EXCLUDED.blks_read,
    blks_hit = EXCLUDED.blks_hit, first_seen = CASE WHEN q.is_present THEN q.first_seen ELSE EXCLUDED.first_seen END,
    snapshot_at = EXCLUDED.snapshot_at, is_present = true;

  INSERT INTO pgvigil.db_checks AS k (instance_id, dbid, check_kind, object, datname, figure, detail, fix_sql, first_seen, snapshot_at, is_present)
  SELECT DISTINCT ON ((r->>'dbid')::bigint, r->>'check_kind', r->>'object')
         p_instance_id, (r->>'dbid')::bigint, r->>'check_kind', r->>'object', r->>'datname', (r->>'figure')::numeric, r->>'detail',
         r->>'fix_sql', p_snapshot_at, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'check' AND r->>'dbid' IS NOT NULL AND r->>'check_kind' IS NOT NULL AND r->>'object' IS NOT NULL
  ON CONFLICT (instance_id, dbid, check_kind, object) DO UPDATE SET datname = EXCLUDED.datname, figure = EXCLUDED.figure,
    detail = EXCLUDED.detail, fix_sql = EXCLUDED.fix_sql,
    first_seen = CASE WHEN k.is_present THEN k.first_seen ELSE EXCLUDED.first_seen END,
    snapshot_at = EXCLUDED.snapshot_at, is_present = true;

  -- a database read now: its sequences and checks not in this read are gone
  UPDATE pgvigil.sequence_state q SET is_present = false, snapshot_at = p_snapshot_at
   WHERE q.instance_id = p_instance_id AND q.is_present
     AND (EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = q.dbid)
          OR EXISTS (SELECT 1 FROM pgvigil.depth_databases d WHERE d.instance_id = q.instance_id AND d.collection = 'dbchecks'
                                                              AND d.dbid = q.dbid AND NOT d.is_present))
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'seq' AND (r->>'dbid')::bigint = q.dbid AND (r->>'seqrelid')::bigint = q.seqrelid);
  UPDATE pgvigil.db_checks k SET is_present = false, snapshot_at = p_snapshot_at
   WHERE k.instance_id = p_instance_id AND k.is_present
     AND (CASE WHEN k.dbid = 0 THEN EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'md5_read')
               ELSE EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = k.dbid)
                    OR EXISTS (SELECT 1 FROM pgvigil.depth_databases d WHERE d.instance_id = k.instance_id AND d.collection = 'dbchecks'
                                                                        AND d.dbid = k.dbid AND NOT d.is_present) END)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'check' AND (r->>'dbid')::bigint = k.dbid AND r->>'check_kind' = k.check_kind
                        AND r->>'object' = k.object);
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 6. btree bloat (index_bloat)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.index_bloat (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid          bigint NOT NULL,
  indexrelid    bigint NOT NULL,
  datname       text NOT NULL,
  schema_name   text NOT NULL,
  table_name    text NOT NULL,
  index_name    text NOT NULL,
  index_bytes   bigint,
  est_bytes     bigint,                 -- the size its rows need at its fillfactor (NULL: not estimated, est_note says why)
  bloat_bytes   bigint,
  bloat_pct     numeric,
  fillfactor    int,
  tuples        bigint,
  partial       boolean,
  est_note      text,
  reindex_sql   text,
  first_seen    timestamptz NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  is_present    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid, indexrelid)
);

CREATE OR REPLACE FUNCTION pgvigil.import_index_bloat(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_index_bloat'), p_instance_id);
  PERFORM pgvigil.import_depth_databases(p_instance_id, 'index_bloat', p_snapshot_at, p_payload);
  INSERT INTO pgvigil.index_bloat AS b (instance_id, dbid, indexrelid, datname, schema_name, table_name, index_name, index_bytes,
    est_bytes, bloat_bytes, bloat_pct, fillfactor, tuples, partial, est_note, reindex_sql, first_seen, snapshot_at, is_present)
  SELECT DISTINCT ON ((r->>'dbid')::bigint, (r->>'indexrelid')::bigint)
         p_instance_id, (r->>'dbid')::bigint, (r->>'indexrelid')::bigint, r->>'datname', r->>'schema_name', r->>'table_name',
         r->>'index_name', (r->>'index_bytes')::bigint, (r->>'est_bytes')::bigint,
         -- not estimated (est_bytes NULL): no bloat figure, never 0
         CASE WHEN r->>'est_bytes' IS NOT NULL THEN greatest((r->>'index_bytes')::bigint - (r->>'est_bytes')::bigint, 0) END,
         CASE WHEN r->>'est_bytes' IS NOT NULL THEN
           round(100.0 * greatest((r->>'index_bytes')::bigint - (r->>'est_bytes')::bigint, 0) / nullif((r->>'index_bytes')::bigint, 0), 1) END,
         (r->>'fillfactor')::int, (r->>'tuples')::bigint, (r->>'partial')::boolean, r->>'est_note', r->>'reindex_sql',
         p_snapshot_at, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'bloat' AND r->>'dbid' IS NOT NULL AND r->>'indexrelid' IS NOT NULL
  ON CONFLICT (instance_id, dbid, indexrelid) DO UPDATE SET datname = EXCLUDED.datname, schema_name = EXCLUDED.schema_name,
    table_name = EXCLUDED.table_name, index_name = EXCLUDED.index_name, index_bytes = EXCLUDED.index_bytes,
    est_bytes = EXCLUDED.est_bytes, bloat_bytes = EXCLUDED.bloat_bytes, bloat_pct = EXCLUDED.bloat_pct,
    fillfactor = EXCLUDED.fillfactor, tuples = EXCLUDED.tuples, partial = EXCLUDED.partial, est_note = EXCLUDED.est_note,
    reindex_sql = EXCLUDED.reindex_sql, first_seen = CASE WHEN b.is_present THEN b.first_seen ELSE EXCLUDED.first_seen END,
    snapshot_at = EXCLUDED.snapshot_at, is_present = true;
  -- an index of a database read now that is not in the read: dropped, rebuilt under the floor, or no longer a valid btree
  UPDATE pgvigil.index_bloat b SET is_present = false, snapshot_at = p_snapshot_at
   WHERE b.instance_id = p_instance_id AND b.is_present
     AND (EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = b.dbid)
          OR EXISTS (SELECT 1 FROM pgvigil.depth_databases d WHERE d.instance_id = b.instance_id AND d.collection = 'index_bloat'
                                                              AND d.dbid = b.dbid AND NOT d.is_present))
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'bloat' AND (r->>'dbid')::bigint = b.dbid AND (r->>'indexrelid')::bigint = b.indexrelid);
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 7. the findings
-- ---------------------------------------------------------------------------------------------------------------------
-- One row per broken rule, findings' columns (0016's shape), source 'pg-depth'. The rules:
--   checkpoint late            (warning) the last checkpoint is older than twice checkpoint_timeout plus a minute while 16 MB
--                              or more of WAL waits since its redo point (an idle server skips its timed checkpoints: no
--                              WAL, no finding); a primary's read
--   archive backlog            (warning) 10 or more .ready files, or the oldest over 30 minutes old
--   timeline changed           (warning) the timeline differs from a read in the 24 hours before the newest (a promotion, a
--                              failover, a restore to a new timeline); clears 24 hours after
--   system identifier changed  (critical) the instance's name now reaches another cluster (a rebuild or restore)
--   no standby                 (info) a self-managed primary with no physical standby streaming from it
--   connections near the limit (warning at 90 %, critical at 100 % of the slots a client may use)
--   subtransaction SLRU reads, multixact SLRU reads (warning) 50 or more pages read from disk between the two newest SLRU
--                              reads (a few reads at a start or a multixact truncation are not the overflow)
--   sequence near its maximum  (warning at 90 %, critical at 98 %)
--   SECURITY DEFINER without search_path (warning), NOT VALID constraint (info), rows in a DEFAULT partition (info),
--   CREATE on schema public    (warning), MD5 password (warning)
--   index bloat                (info at 50 % of an index of 10 MB or more; warning when 1 GB or more of it is bloat)
CREATE OR REPLACE VIEW pgvigil.pg_depth_findings AS
SELECT w.instance_id, 'warning'::text AS severity, 'checkpoint late'::text AS setting,
       'last checkpoint ' || w.checkpoint_age_s || ' s ago' AS value, true AS is_set,
       'under ' || (2 * w.checkpoint_timeout_s + 60) || ' s (twice checkpoint_timeout + 60 s)' AS suggested, 'all'::text AS platforms,
       pg_size_pretty(w.wal_since_redo) || ' of WAL since the redo point and no checkpoint for ' || w.checkpoint_age_s
         || ' s (checkpoint_timeout ' || w.checkpoint_timeout_s || ' s): the checkpointer is stuck or far behind; crash recovery would replay all of it' AS detail,
       'pg-depth'::text AS source, w.snapshot_at AS at
  FROM pgvigil.wal_state_latest w
 WHERE NOT coalesce(w.in_recovery, false) AND w.checkpoint_age_s > 2 * w.checkpoint_timeout_s + 60 AND w.wal_since_redo >= 16777216
UNION ALL
SELECT w.instance_id, 'warning', 'archive backlog', w.archive_ready || ' WAL files waiting', true, 'under 10, none older than 30 minutes', 'all',
       w.archive_ready || ' .ready files in pg_wal/archive_status, the oldest ' || coalesce(w.archive_oldest_age_s || ' s', '?')
         || ' old: the archive_command is failing or slower than WAL is written; pg_wal grows until it succeeds',
       'pg-depth', w.snapshot_at
  FROM pgvigil.wal_state_latest w
 WHERE w.archive_ready >= 10 OR (w.archive_ready > 0 AND w.archive_oldest_age_s > 1800)
UNION ALL
SELECT w.instance_id, 'warning', 'timeline changed', 'timeline ' || w.prev_timeline_id || ' -> ' || w.timeline_id, true, NULL, 'all',
       'the server is on timeline ' || w.timeline_id || ' since about ' || to_char(w.timeline_changed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC (before: '
         || w.prev_timeline_id || '): a promotion, a failover or a point-in-time restore; check the old primary is fenced and the standbys follow',
       'pg-depth', w.snapshot_at
  FROM pgvigil.wal_state_latest w
 WHERE w.prev_timeline_id IS NOT NULL
UNION ALL
SELECT w.instance_id, 'critical', 'system identifier changed', w.prev_system_identifier || ' -> ' || w.system_identifier, true, NULL, 'all',
       'the instance now reaches another cluster (system identifier ' || w.system_identifier || ' since about '
         || to_char(w.system_identifier_changed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC): a rebuild, a restore or a DSN pointed elsewhere; the history before it is another server''s',
       'pg-depth', w.snapshot_at
  FROM pgvigil.wal_state_latest w
 WHERE w.prev_system_identifier IS NOT NULL
UNION ALL
SELECT w.instance_id, 'info', 'no standby', '0 standbys streaming', true, 'a physical standby', 'onprem',
       'no physical standby streams from this primary: a lost server is a restore from backup',
       'pg-depth', w.snapshot_at
  FROM pgvigil.wal_state_latest w JOIN pgvigil.instances i USING (instance_id)
 WHERE NOT coalesce(w.in_recovery, true) AND w.standbys = 0 AND i.platform = 'onprem'
UNION ALL
SELECT w.instance_id, CASE WHEN w.connections_pct >= 100 THEN 'critical' ELSE 'warning' END, 'connections near the limit',
       w.client_backends || ' of ' || w.client_limit || ' (' || w.connections_pct || ' %)', true, 'under 90 %', 'all',
       w.client_backends || ' client sessions of the ' || w.client_limit || ' a client may open (max_connections ' || w.max_connections
         || ' less ' || coalesce(w.superuser_reserved, 0) + coalesce(w.reserved_connections, 0) || ' reserved): new connections are refused at the limit',
       'pg-depth', w.snapshot_at
  FROM pgvigil.wal_state_latest w
 WHERE w.connections_pct >= 90
UNION ALL
SELECT l.instance_id, 'warning', CASE WHEN l.family = 'subtransaction' THEN 'subtransaction SLRU reads' ELSE 'multixact SLRU reads' END,
       l.name || ': ' || l.read_delta || ' pages read', true, '0 pages read from disk', 'all',
       l.read_delta || ' ' || l.name || ' pages read from disk between ' || to_char(l.prev_at AT TIME ZONE 'UTC', 'HH24:MI') || ' and '
         || to_char(l.snapshot_at AT TIME ZONE 'UTC', 'HH24:MI') || ' UTC (' || coalesce(l.hit_delta, 0) || ' hits): '
         || CASE WHEN l.family = 'subtransaction'
                 THEN 'a transaction with more than 64 subtransactions (SAVEPOINT, an EXCEPTION block per row) while older snapshots stay open makes every reader look up pg_subtrans'
                 ELSE 'many sessions locking the same rows (FOR SHARE / FOR KEY SHARE, foreign keys) make multixacts the cache no longer holds' END,
       'pg-depth', l.snapshot_at
  FROM pgvigil.slru_latest l
 WHERE l.family IN ('subtransaction', 'multixact_member', 'multixact_offset') AND l.read_delta >= 50
UNION ALL
SELECT q.instance_id, CASE WHEN q.pct_used >= 98 THEN 'critical' ELSE 'warning' END, 'sequence near its maximum',
       q.datname || ': ' || q.schema_name || '.' || q.seq_name || ' ' || q.pct_used || ' %', true, 'under 90 %', 'all',
       'last value ' || q.last_value || ' of ' || least(q.max_value::numeric, coalesce(q.col_max, q.max_value::numeric))
         || CASE WHEN q.col_max IS NOT NULL AND q.col_max < q.max_value THEN ' (the ' || q.col_type || ' column ' || q.col_table || '.' || q.col_name || '''s limit)' ELSE '' END
         || ': inserts fail when it runs out; ALTER the column (and the sequence) to bigint before then',
       'pg-depth', q.snapshot_at
  FROM pgvigil.sequence_state q
 WHERE q.is_present AND q.pct_used >= 90 AND NOT coalesce(q.cycles, false)
UNION ALL
SELECT k.instance_id,
       CASE k.check_kind WHEN 'notvalid' THEN 'info' WHEN 'defpart' THEN 'info' ELSE 'warning' END,
       CASE k.check_kind WHEN 'secdef' THEN 'SECURITY DEFINER without search_path' WHEN 'notvalid' THEN 'NOT VALID constraint'
                         WHEN 'defpart' THEN 'rows in a DEFAULT partition' WHEN 'public_create' THEN 'CREATE on schema public'
                         WHEN 'md5' THEN 'MD5 password' ELSE k.check_kind END,
       coalesce(k.datname || ': ', '') || k.object, true, k.fix_sql, 'all',
       k.detail || CASE k.check_kind WHEN 'secdef' THEN ': it runs as its owner with the caller''s search_path - pin it'
                                     WHEN 'notvalid' THEN ': old rows were never checked and the planner cannot rely on it'
                                     WHEN 'defpart' THEN ': rows no partition was made for; a new partition for their values must scan them'
                                     WHEN 'public_create' THEN ': any role can create objects that shadow the ones a search_path names (CVE-2018-1058)'
                                     ELSE '' END,
       'pg-depth', k.snapshot_at
  FROM pgvigil.db_checks k
 WHERE k.is_present
UNION ALL
SELECT b.instance_id, CASE WHEN b.bloat_bytes >= 1073741824 THEN 'warning' ELSE 'info' END, 'index bloat',
       b.datname || ': ' || b.schema_name || '.' || b.index_name || ' ' || b.bloat_pct || ' %', true, b.reindex_sql, 'all',
       pg_size_pretty(b.bloat_bytes) || ' of ' || pg_size_pretty(b.index_bytes) || ' is estimated free space (the rows need about '
         || pg_size_pretty(b.est_bytes) || ' at fillfactor ' || b.fillfactor || '): REINDEX CONCURRENTLY rebuilds it without blocking writes',
       'pg-depth', b.snapshot_at
  FROM pgvigil.index_bloat b
 WHERE b.is_present AND b.bloat_pct >= 50 AND b.index_bytes >= 10485760 AND b.bloat_bytes >= 0;
