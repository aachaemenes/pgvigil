-- 0003_statements: pg_stat_statements as per-interval deltas. statements_current keeps the
-- last cumulative row per (instance, dbid, userid, queryid, toplevel); each import stores the
-- difference in statements_delta (monthly partitions) with the interval it spans and a
-- reset flag when a counter went backwards (pg_stat_statements_reset or a restart: the
-- stored delta is then the cumulative value since the reset).

CREATE TABLE IF NOT EXISTS pgvigil.statement_text (
  instance_id  int NOT NULL,
  queryid      bigint NOT NULL,
  dbid         bigint,
  first_seen   timestamptz NOT NULL,
  last_seen    timestamptz NOT NULL,
  query        text NOT NULL,
  PRIMARY KEY (instance_id, queryid)
);

CREATE TABLE IF NOT EXISTS pgvigil.statements_current (
  instance_id         int NOT NULL,
  dbid                bigint NOT NULL,
  userid              bigint NOT NULL,
  queryid             bigint NOT NULL,
  toplevel            boolean NOT NULL,
  snapshot_at         timestamptz NOT NULL,
  stats_reset         timestamptz,                 -- the extension's stats_reset when this row was stored (PG14+)
  calls               bigint,
  total_exec_ms       double precision,
  rows                bigint,
  shared_blks_hit     bigint,
  shared_blks_read    bigint,
  shared_blks_dirtied bigint,
  shared_blks_written bigint,
  temp_blks_read      bigint,
  temp_blks_written   bigint,
  blk_read_ms         double precision,
  blk_write_ms        double precision,
  temp_read_ms        double precision,
  temp_write_ms       double precision,
  wal_bytes           numeric,
  PRIMARY KEY (instance_id, dbid, userid, queryid, toplevel)
);

CREATE TABLE IF NOT EXISTS pgvigil.statements_delta (
  instance_id         int NOT NULL,
  snapshot_at         timestamptz NOT NULL,
  interval_secs       int NOT NULL,
  reset               boolean NOT NULL DEFAULT false,
  dbid                bigint NOT NULL,
  datname             text,
  userid              bigint NOT NULL,
  usename             text,
  queryid             bigint NOT NULL,
  toplevel            boolean NOT NULL,
  calls               bigint,
  total_exec_ms       double precision,
  rows                bigint,
  shared_blks_hit     bigint,
  shared_blks_read    bigint,
  shared_blks_dirtied bigint,
  shared_blks_written bigint,
  temp_blks_read      bigint,
  temp_blks_written   bigint,
  blk_read_ms         double precision,
  blk_write_ms        double precision,
  temp_read_ms        double precision,
  temp_write_ms       double precision,
  wal_bytes           numeric
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.statements_info (
  instance_id   int NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  dealloc       bigint,
  stats_reset   timestamptz,
  PRIMARY KEY (instance_id, snapshot_at)
);

CREATE OR REPLACE FUNCTION pgvigil.import_statements(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_new_reset  timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_statements'), p_instance_id);
  PERFORM pgvigil.ensure_month_partition('statements_delta', p_snapshot_at);

  CREATE TEMP TABLE pgv_stmt_in ON COMMIT DROP AS
  SELECT (r->>'dbid')::bigint AS dbid, r->>'datname' AS datname, (r->>'userid')::bigint AS userid, r->>'usename' AS usename,
         (r->>'queryid')::bigint AS queryid, coalesce((r->>'toplevel')::boolean, true) AS toplevel,
         (r->>'calls')::bigint AS calls, (r->>'total_exec_ms')::float8 AS total_exec_ms, (r->>'rows')::bigint AS rows,
         (r->>'shared_blks_hit')::bigint AS shared_blks_hit, (r->>'shared_blks_read')::bigint AS shared_blks_read,
         (r->>'shared_blks_dirtied')::bigint AS shared_blks_dirtied, (r->>'shared_blks_written')::bigint AS shared_blks_written,
         (r->>'temp_blks_read')::bigint AS temp_blks_read, (r->>'temp_blks_written')::bigint AS temp_blks_written,
         (r->>'blk_read_ms')::float8 AS blk_read_ms, (r->>'blk_write_ms')::float8 AS blk_write_ms,
         (r->>'temp_read_ms')::float8 AS temp_read_ms, (r->>'temp_write_ms')::float8 AS temp_write_ms,
         (r->>'wal_bytes')::numeric AS wal_bytes, r->>'query' AS query
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'stmt' AND r->>'queryid' IS NOT NULL AND r->>'dbid' IS NOT NULL AND r->>'userid' IS NOT NULL;

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
    CROSS JOIN LATERAL (SELECT (v_new_reset IS NOT NULL AND c.stats_reset IS DISTINCT FROM v_new_reset)
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
    snapshot_at = EXCLUDED.snapshot_at, stats_reset = EXCLUDED.stats_reset, calls = EXCLUDED.calls, total_exec_ms = EXCLUDED.total_exec_ms, rows = EXCLUDED.rows,
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

-- Top statements over a window. Each delta row covers (snapshot_at - interval_secs, snapshot_at];
-- a statement that fell out of the top set and came back days later carries one delta spanning
-- the gap, so every delta is scaled by the share of its span that lies inside the window instead
-- of being dropped whole into the snapshot where it landed.
CREATE OR REPLACE FUNCTION pgvigil.top_statements(p_instance_id int, p_from timestamptz, p_to timestamptz, p_limit int DEFAULT 50)
RETURNS TABLE (queryid bigint, datname text, usename text, calls double precision, total_exec_ms double precision, mean_exec_ms double precision,
               rows double precision, shared_blks_read double precision, shared_blks_hit double precision, temp_blks_written double precision,
               wal_bytes numeric, query text)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT d.*,
           greatest(0, extract(epoch FROM least(d.snapshot_at, p_to) - greatest(d.snapshot_at - make_interval(secs => d.interval_secs), p_from)))
             / d.interval_secs AS share
      FROM pgvigil.statements_delta d
     WHERE d.instance_id = p_instance_id
       AND d.snapshot_at > p_from                                            -- ends inside or after the window start
       AND d.snapshot_at - make_interval(secs => d.interval_secs) < p_to     -- starts before the window end
  )
  SELECT d.queryid, min(d.datname), min(d.usename),
         sum(d.calls * d.share), sum(d.total_exec_ms * d.share),
         sum(d.total_exec_ms * d.share) / nullif(sum(d.calls * d.share), 0),
         sum(d.rows * d.share), sum(d.shared_blks_read * d.share), sum(d.shared_blks_hit * d.share),
         sum(d.temp_blks_written * d.share), sum(d.wal_bytes * d.share),
         (SELECT t.query FROM pgvigil.statement_text t WHERE t.instance_id = p_instance_id AND t.queryid = d.queryid)
    FROM d
   WHERE d.share > 0
   GROUP BY d.queryid
   ORDER BY sum(d.total_exec_ms * d.share) DESC
   LIMIT p_limit
$$;

-- Retention for the new tables joins pgvigil.purge.
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
     WHERE ns.nspname = 'pgvigil' AND p.relname IN ('activity_sample', 'statements_delta')
       AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)   -- partition bounds are UTC months
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
