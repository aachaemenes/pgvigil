-- 0017: import_statements keeps one row per (dbid, userid, queryid, toplevel) of a payload.
--
-- A payload that carries one statement twice (a collector that scanned pg_stat_statements twice while
-- the counters moved, or any client sending duplicates) used to fail the whole cycle: the upsert into
-- statements_current cannot update one row twice in one statement (SQLSTATE 21000) and statements_delta
-- would get two rows for one key. The row with the most calls (then the most time) is taken as the later
-- reading and wins; a reset between two readings of one payload makes the earlier one win, so a client
-- reads the view once, as the collector does since the same change (internal/collect/statements.go).
-- Everything else in the function is unchanged from 0003. Same signature: CREATE OR REPLACE.

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
         (r->>'wal_bytes')::numeric AS wal_bytes, r->>'query' AS query
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'stmt' AND r->>'queryid' IS NOT NULL AND r->>'dbid' IS NOT NULL AND r->>'userid' IS NOT NULL
   ORDER BY dbid, userid, queryid, toplevel, calls DESC NULLS LAST, total_exec_ms DESC NULLS LAST;

  -- statement text, once per (instance, queryid)
  INSERT INTO pgvigil.statement_text AS t (instance_id, queryid, dbid, first_seen, last_seen, query)
  SELECT DISTINCT ON (queryid) p_instance_id, queryid, dbid, p_snapshot_at, p_snapshot_at, query
    FROM pgv_stmt_in WHERE coalesce(query, '') <> ''
   ORDER BY queryid
  ON CONFLICT (instance_id, queryid) DO UPDATE SET last_seen = EXCLUDED.last_seen;

  -- A reset is: the extension's stats_reset differs from the one stored with the row's last
  -- cumulative values (so a statement absent from the import that first saw the reset is still
  -- caught when it comes back), or any counter going backwards on the row (an evicted entry that
  -- re-entered: dealloc). After a reset the delta is the cumulative value since the reset, and
  -- when the reset time is known the interval starts there, not at the stale baseline; for an
  -- eviction the start is unknown and the interval is the whole gap (said in the row by reset
  -- with no stats_reset move).
  SELECT (r->>'stats_reset')::timestamptz INTO v_new_reset
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'info' LIMIT 1;

  INSERT INTO pgvigil.statements_delta (
    instance_id, snapshot_at, interval_secs, reset, dbid, datname, userid, usename, queryid, toplevel,
    calls, total_exec_ms, rows, shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
    temp_blks_read, temp_blks_written, blk_read_ms, blk_write_ms, temp_read_ms, temp_write_ms, wal_bytes)
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
         CASE WHEN x.rs THEN i.wal_bytes ELSE i.wal_bytes - c.wal_bytes END
    FROM pgv_stmt_in i
    JOIN pgvigil.statements_current c
      ON c.instance_id = p_instance_id AND c.dbid = i.dbid AND c.userid = i.userid
     AND c.queryid = i.queryid AND c.toplevel = i.toplevel
    CROSS JOIN LATERAL (SELECT (v_new_reset IS NOT NULL AND c.stats_reset IS NOT NULL AND c.stats_reset <> v_new_reset)
                           OR i.calls < c.calls OR i.total_exec_ms < c.total_exec_ms OR i.rows < c.rows
                           OR i.shared_blks_hit < c.shared_blks_hit OR i.shared_blks_read < c.shared_blks_read
                           OR i.wal_bytes < c.wal_bytes AS rs) x
   WHERE (i.calls <> c.calls OR x.rs) AND i.calls > 0;   -- nothing ran and no reset: no row

  INSERT INTO pgvigil.statements_current AS c (
    instance_id, dbid, userid, queryid, toplevel, snapshot_at, stats_reset, calls, total_exec_ms, rows,
    shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written, temp_blks_read, temp_blks_written,
    blk_read_ms, blk_write_ms, temp_read_ms, temp_write_ms, wal_bytes)
  SELECT p_instance_id, dbid, userid, queryid, toplevel, p_snapshot_at, v_new_reset, calls, total_exec_ms, rows,
         shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written, temp_blks_read, temp_blks_written,
         blk_read_ms, blk_write_ms, temp_read_ms, temp_write_ms, wal_bytes
    FROM pgv_stmt_in
  ON CONFLICT (instance_id, dbid, userid, queryid, toplevel) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, stats_reset = coalesce(EXCLUDED.stats_reset, c.stats_reset), calls = EXCLUDED.calls, total_exec_ms = EXCLUDED.total_exec_ms, rows = EXCLUDED.rows,
    shared_blks_hit = EXCLUDED.shared_blks_hit, shared_blks_read = EXCLUDED.shared_blks_read,
    shared_blks_dirtied = EXCLUDED.shared_blks_dirtied, shared_blks_written = EXCLUDED.shared_blks_written,
    temp_blks_read = EXCLUDED.temp_blks_read, temp_blks_written = EXCLUDED.temp_blks_written,
    blk_read_ms = EXCLUDED.blk_read_ms, blk_write_ms = EXCLUDED.blk_write_ms,
    temp_read_ms = EXCLUDED.temp_read_ms, temp_write_ms = EXCLUDED.temp_write_ms, wal_bytes = EXCLUDED.wal_bytes;

  INSERT INTO pgvigil.statements_info (instance_id, snapshot_at, dealloc, stats_reset)
  SELECT p_instance_id, p_snapshot_at, (r->>'dealloc')::bigint, (r->>'stats_reset')::timestamptz
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'info'
  ON CONFLICT (instance_id, snapshot_at) DO NOTHING;
END $$;
