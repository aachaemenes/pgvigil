-- 0061_memory: memory and poolers (task 62): the buffercache, temp_files and pgbouncer collections' imports and the
-- findings they feed.
--
--   buffercache_sample   monthly partitions; per hourly read one 'total' row (status ok | not available and the reason,
--                        shared_buffers in pages, the used and dirty buffers, the block size) and up to 50 'rel' rows
--                        (the relations holding the most buffers, their dirty buffers and usage counts). A relation of
--                        another database than the connected one keeps its database's name and its file node only.
--   temp_sample          monthly partitions; the hourly rollup of what the repository already holds: 'statement' rows
--                        (pg_stat_statements' temp_blks_read / temp_blks_written per statement, toplevel and hour, from
--                        statements_delta, in bytes by the instance's block size) and one 'hour' row per hour (the log
--                        readers' 'temporary file' lines: the count, the bytes and the largest file; the top-level
--                        statements' written bytes summed (a nested statement's bytes are in its caller's too); the instance's data size at that hour). import_temp_files rebuilds the
--                        last six hours on each read (a log line read late still lands in its hour) and keeps the data
--                        size an hour was first stored with.
--   pooler_state         one row per instance with a pgbouncer: DSN: the last read's status ('ok' | 'error') and reason,
--                        the pooler's version, SHOW DATABASES and SHOW CONFIG as read (jsonb), the last ok read.
--   pooler_sample        monthly partitions; per minute a 'pool' row per pool (SHOW POOLS: clients active and waiting,
--                        servers active, idle, used, tested, logging in, maxwait in ms, the pool mode and the pool's
--                        size from SHOW DATABASES) and a 'stats' row per database (SHOW STATS: PgBouncer's per-second
--                        averages of transactions and queries, the average wait and query time, the totals).
--   memory_findings      the findings view's columns. The UNION arm in pgvigil.findings and the purge lines (the three
--                        partition parents; pooler_state of an instance not read past the window) are the wave's join:
--     'clients waiting on the pooler'  a pool's cl_waiting above 0 in every read of the last 5 minutes (warning);
--                                      its latest read's maxwait over 5 s (critical)
--     'a pool at its size'             sv_active at the pool's pool_size in every read of the last 5 minutes (warning)
--     'temp-file spills'               a statement that wrote more than 1 GB of temp files in one hour of the last 24
--                                      (info); an hour of the last 24 whose temp files came to more than 10 % of the
--                                      data size (warning)
--     'one relation holds over half of shared_buffers'   the latest buffercache read (info)
--   "Every read of the last 5 minutes": the reads of the last 5.5 minutes, the first at least 4 minutes old and the
--   last at most 2 minutes old (a pooler not read lately fires nothing).

CREATE TABLE IF NOT EXISTS pgvigil.buffercache_sample (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('total', 'rel')),
  status         text,                 -- total: ok | not available
  reason         text,
  total_buffers  bigint,
  used_buffers   bigint,
  dirty_buffers  bigint,
  block_size     int,
  datname        text,
  schemaname     text,
  relname        text,
  relkind        text,
  relfilenode    bigint,
  buffers        bigint,
  dirty          bigint,
  usage_avg      double precision,
  usage_hot      bigint
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.temp_sample (
  instance_id         int NOT NULL,
  snapshot_at         timestamptz NOT NULL,   -- the hour's start
  source              text NOT NULL CHECK (source IN ('statement', 'hour')),
  dbid                bigint,
  userid              bigint,
  queryid             bigint,
  toplevel            boolean,
  datname             text,
  usename             text,
  temp_read_bytes     numeric,
  temp_written_bytes  numeric,
  log_files           bigint,
  log_bytes           numeric,
  log_max_file_bytes  numeric,
  data_bytes          bigint
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.pooler_state (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at  timestamptz NOT NULL,
  status       text NOT NULL CHECK (status IN ('ok', 'error')),
  reason       text,
  version      text,
  databases    jsonb,
  config       jsonb,
  last_ok      timestamptz
);

CREATE TABLE IF NOT EXISTS pgvigil.pooler_sample (
  instance_id        int NOT NULL,
  snapshot_at        timestamptz NOT NULL,
  kind               text NOT NULL CHECK (kind IN ('pool', 'stats')),
  database           text NOT NULL,
  usr                text,
  cl_active          int,
  cl_waiting         int,
  sv_active          int,
  sv_idle            int,
  sv_used            int,
  sv_tested          int,
  sv_login           int,
  maxwait_ms         double precision,
  pool_mode          text,
  pool_size          int,
  xact_rate          bigint,
  query_rate         bigint,
  avg_wait_us        bigint,
  avg_query_us       bigint,
  total_xact_count   bigint,
  total_query_count  bigint,
  total_wait_us      bigint
) PARTITION BY RANGE (snapshot_at);

-- payload: one {kind:'total', status, reason, total_buffers, used_buffers, dirty_buffers, block_size} and the 'rel' rows
CREATE OR REPLACE FUNCTION pgvigil.import_buffercache(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'total') THEN
    RAISE EXCEPTION 'import_buffercache: the payload has no total row';
  END IF;
  PERFORM pgvigil.ensure_month_partition('buffercache_sample', p_snapshot_at);
  DELETE FROM pgvigil.buffercache_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;  -- a re-run of one read
  INSERT INTO pgvigil.buffercache_sample (instance_id, snapshot_at, kind, status, reason, total_buffers, used_buffers, dirty_buffers,
                                          block_size, datname, schemaname, relname, relkind, relfilenode, buffers, dirty, usage_avg, usage_hot)
  SELECT p_instance_id, p_snapshot_at, r->>'kind', r->>'status', r->>'reason', (r->>'total_buffers')::bigint,
         (r->>'used_buffers')::bigint, (r->>'dirty_buffers')::bigint, (r->>'block_size')::int, r->>'datname', r->>'schemaname',
         r->>'relname', r->>'relkind', (r->>'relfilenode')::bigint, (r->>'buffers')::bigint, (r->>'dirty')::bigint,
         (r->>'usage_avg')::float8, (r->>'usage_hot')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'total' OR (r->>'kind' = 'rel' AND r->>'buffers' IS NOT NULL);
END $$;

-- payload: one {kind:'state', data_bytes, block_size}; the rollup of the last six hours (see the header)
CREATE OR REPLACE FUNCTION pgvigil.import_temp_files(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_state jsonb;
  v_block numeric;
  v_data  bigint;
  v_from  timestamptz := date_trunc('hour', p_snapshot_at) - interval '6 hours';
  v_to    timestamptz := date_trunc('hour', p_snapshot_at);
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_temp_files'), p_instance_id);
  SELECT r INTO v_state FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'state' LIMIT 1;
  IF v_state IS NULL THEN
    RAISE EXCEPTION 'import_temp_files: the payload has no state row';
  END IF;
  v_block := coalesce((v_state->>'block_size')::numeric, 8192);
  v_data := (v_state->>'data_bytes')::bigint;
  PERFORM pgvigil.ensure_month_partition('temp_sample', v_from);
  PERFORM pgvigil.ensure_month_partition('temp_sample', v_to);

  -- the data size each hour was first stored with stays (the size at that hour, not now)
  CREATE TEMP TABLE pgv_temp_kept ON COMMIT DROP AS
  SELECT snapshot_at, data_bytes FROM pgvigil.temp_sample
   WHERE instance_id = p_instance_id AND source = 'hour' AND snapshot_at >= v_from AND data_bytes IS NOT NULL;
  -- bounded by the read's own hour: a late read (a clock behind, a one-off collect) rebuilds its six hours and leaves
  -- the newer hours as they were
  DELETE FROM pgvigil.temp_sample WHERE instance_id = p_instance_id AND snapshot_at >= v_from AND snapshot_at <= v_to;

  INSERT INTO pgvigil.temp_sample (instance_id, snapshot_at, source, dbid, userid, queryid, toplevel, datname, usename,
                                   temp_read_bytes, temp_written_bytes)
  SELECT p_instance_id, date_trunc('hour', d.snapshot_at), 'statement', d.dbid, d.userid, d.queryid, d.toplevel,
         max(d.datname), max(d.usename),
         sum(coalesce(d.temp_blks_read, 0)) * v_block, sum(coalesce(d.temp_blks_written, 0)) * v_block
    FROM pgvigil.statements_delta d
   WHERE d.instance_id = p_instance_id AND d.snapshot_at >= v_from AND d.snapshot_at < v_to + interval '1 hour'
   GROUP BY 2, 4, 5, 6, 7
  HAVING sum(coalesce(d.temp_blks_read, 0)) + sum(coalesce(d.temp_blks_written, 0)) > 0;

  INSERT INTO pgvigil.temp_sample (instance_id, snapshot_at, source, temp_written_bytes, log_files, log_bytes, log_max_file_bytes, data_bytes)
  SELECT p_instance_id, h, 'hour',
         (SELECT sum(s.temp_written_bytes) FROM pgvigil.temp_sample s
           WHERE s.instance_id = p_instance_id AND s.source = 'statement' AND s.snapshot_at = h AND s.toplevel IS NOT FALSE),
         l.files, l.bytes, l.max_bytes,
         coalesce((SELECT k.data_bytes FROM pgv_temp_kept k WHERE k.snapshot_at = h), v_data)
    FROM generate_series(v_from, v_to, interval '1 hour') h
    CROSS JOIN LATERAL (
      SELECT count(*) AS files, sum(x.size) AS bytes, max(x.size) AS max_bytes
        FROM (SELECT (substring(e.detail FROM 'size (\d+)'))::numeric AS size
                FROM pgvigil.log_events e
               WHERE e.instance_id = p_instance_id AND e.kind = 'temp_file'
                 AND e.snapshot_at >= h AND e.snapshot_at < h + interval '1 hour') x) l;
  DROP TABLE pgv_temp_kept;
END $$;

-- payload: one {kind:'state', status, reason, version}; when ok, the 'pool', 'stats', 'database' and 'config' rows
CREATE OR REPLACE FUNCTION pgvigil.import_pgbouncer(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_state jsonb;
  v_ok    boolean;
BEGIN
  SELECT r INTO v_state FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'state' LIMIT 1;
  IF v_state IS NULL THEN
    RAISE EXCEPTION 'import_pgbouncer: the payload has no state row';
  END IF;
  v_ok := v_state->>'status' = 'ok';
  INSERT INTO pgvigil.pooler_state AS s (instance_id, snapshot_at, status, reason, version, databases, config, last_ok)
  VALUES (p_instance_id, p_snapshot_at, v_state->>'status', v_state->>'reason', v_state->>'version',
          CASE WHEN v_ok THEN (SELECT coalesce(jsonb_agg(r - 'kind'), '[]'::jsonb) FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'database') END,
          CASE WHEN v_ok THEN (SELECT coalesce(jsonb_agg(r - 'kind'), '[]'::jsonb) FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'config') END,
          CASE WHEN v_ok THEN p_snapshot_at END)
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, status = EXCLUDED.status, reason = EXCLUDED.reason,
    version = coalesce(EXCLUDED.version, s.version),
    databases = coalesce(EXCLUDED.databases, s.databases), config = coalesce(EXCLUDED.config, s.config),
    last_ok = coalesce(EXCLUDED.last_ok, s.last_ok)
  WHERE s.snapshot_at <= EXCLUDED.snapshot_at;
  IF NOT v_ok THEN
    RETURN;
  END IF;
  PERFORM pgvigil.ensure_month_partition('pooler_sample', p_snapshot_at);
  INSERT INTO pgvigil.pooler_sample (instance_id, snapshot_at, kind, database, usr, cl_active, cl_waiting, sv_active, sv_idle, sv_used,
                                     sv_tested, sv_login, maxwait_ms, pool_mode, pool_size, xact_rate, query_rate, avg_wait_us,
                                     avg_query_us, total_xact_count, total_query_count, total_wait_us)
  SELECT p_instance_id, p_snapshot_at, r->>'kind', r->>'database', r->>'user', (r->>'cl_active')::int, (r->>'cl_waiting')::int,
         (r->>'sv_active')::int, (r->>'sv_idle')::int, (r->>'sv_used')::int, (r->>'sv_tested')::int, (r->>'sv_login')::int,
         (r->>'maxwait_ms')::float8, r->>'pool_mode', (r->>'pool_size')::int, (r->>'xact_rate')::bigint, (r->>'query_rate')::bigint,
         (r->>'avg_wait_us')::bigint, (r->>'avg_query_us')::bigint, (r->>'total_xact_count')::bigint,
         (r->>'total_query_count')::bigint, (r->>'total_wait_us')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' IN ('pool', 'stats') AND r->>'database' IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pgvigil.pooler_sample x
                      WHERE x.instance_id = p_instance_id AND x.snapshot_at = p_snapshot_at AND x.kind = r->>'kind'
                        AND x.database = r->>'database' AND x.usr IS NOT DISTINCT FROM r->>'user');
END $$;

-- memory_findings: the findings view's columns (instance_id, severity, setting, value, is_set, suggested, platforms,
-- detail, source, at)
CREATE OR REPLACE VIEW pgvigil.memory_findings AS
WITH pool5 AS (
  SELECT p.instance_id, p.database, p.usr, min(p.cl_waiting) AS min_waiting, max(p.cl_waiting) AS max_waiting,
         bool_and(p.pool_size > 0 AND p.sv_active >= p.pool_size) AS at_size, max(p.pool_size) AS pool_size,
         min(p.snapshot_at) AS first_at, max(p.snapshot_at) AS last_at
    FROM pgvigil.pooler_sample p
   WHERE p.kind = 'pool' AND p.snapshot_at > now() - interval '5 minutes 30 seconds'
   GROUP BY 1, 2, 3
  HAVING min(p.snapshot_at) <= now() - interval '4 minutes' AND max(p.snapshot_at) > now() - interval '2 minutes'
), pool_last AS (
  SELECT DISTINCT ON (p.instance_id, p.database, p.usr) p.*
    FROM pgvigil.pooler_sample p
   WHERE p.kind = 'pool' AND p.snapshot_at > now() - interval '2 minutes'
   ORDER BY p.instance_id, p.database, p.usr, p.snapshot_at DESC
), temp_stmt AS (
  SELECT DISTINCT ON (t.instance_id, t.dbid, t.userid, t.queryid) t.*
    FROM pgvigil.temp_sample t
   WHERE t.source = 'statement' AND t.snapshot_at > now() - interval '1 day' AND t.temp_written_bytes > 1073741824
   ORDER BY t.instance_id, t.dbid, t.userid, t.queryid, t.temp_written_bytes DESC
), temp_hour AS (
  SELECT DISTINCT ON (t.instance_id) t.instance_id, t.snapshot_at, t.data_bytes,
         greatest(coalesce(t.log_bytes, 0), coalesce(t.temp_written_bytes, 0)) AS bytes
    FROM pgvigil.temp_sample t
   WHERE t.source = 'hour' AND t.snapshot_at > now() - interval '1 day' AND t.data_bytes > 0
     AND greatest(coalesce(t.log_bytes, 0), coalesce(t.temp_written_bytes, 0)) > 0.1 * t.data_bytes
   ORDER BY t.instance_id, greatest(coalesce(t.log_bytes, 0), coalesce(t.temp_written_bytes, 0)) DESC
), buf_last AS (
  SELECT DISTINCT ON (b.instance_id) b.instance_id, b.snapshot_at, b.total_buffers, coalesce(b.block_size, 8192) AS block_size
    FROM pgvigil.buffercache_sample b
   WHERE b.kind = 'total' AND b.status = 'ok' AND b.snapshot_at > now() - interval '2 hours'
   ORDER BY b.instance_id, b.snapshot_at DESC
), f AS (
  SELECT w.instance_id, 'warning'::text AS severity, 'clients waiting on the pooler'::text AS setting,
         w.max_waiting::text || ' waiting' AS value, 'a larger pool_size, or shorter transactions' AS suggested,
         format('pool %s/%s: clients waiting for a server connection in every read of the last 5 minutes (%s to %s). The pool is full: the application waits on the pooler before the database sees the query.',
                w.database, coalesce(w.usr, '?'), w.min_waiting, w.max_waiting) AS detail, w.last_at AS at
    FROM pool5 w WHERE w.min_waiting > 0
  UNION ALL
  SELECT l.instance_id, 'critical', 'clients waiting on the pooler', round((l.maxwait_ms / 1000.0)::numeric, 1)::text || ' s maxwait',
         'a larger pool_size, or find what holds the servers (Running queries)',
         format('pool %s/%s: the oldest waiting client has waited %s s (over 5 s), %s clients waiting.',
                l.database, coalesce(l.usr, '?'), round((l.maxwait_ms / 1000.0)::numeric, 1), coalesce(l.cl_waiting, 0)),
         l.snapshot_at
    FROM pool_last l WHERE l.maxwait_ms > 5000
  UNION ALL
  SELECT w.instance_id, 'warning', 'a pool at its size', w.pool_size::text || ' servers',
         'a larger pool_size if the database has room, or shorter transactions',
         format('pool %s/%s: every server connection of the pool (pool_size %s) was active in every read of the last 5 minutes; the next client waits.',
                w.database, coalesce(w.usr, '?'), w.pool_size),
         w.last_at
    FROM pool5 w WHERE w.at_size
  UNION ALL
  SELECT t.instance_id, 'info', 'temp-file spills', pg_size_pretty(t.temp_written_bytes) || ' in an hour',
         'more work_mem for this statement (SET LOCAL), or a plan that sorts or hashes less',
         format('statement %s (database %s, role %s) wrote %s of temp files in the hour from %s: a sort or hash that did not fit work_mem. %s',
                t.queryid, coalesce(t.datname, t.dbid::text), coalesce(t.usename, t.userid::text), pg_size_pretty(t.temp_written_bytes),
                to_char(t.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
                coalesce(left((SELECT x.query FROM pgvigil.statement_text x WHERE x.instance_id = t.instance_id AND x.queryid = t.queryid), 200), '')),
         t.snapshot_at
    FROM temp_stmt t
  UNION ALL
  SELECT h.instance_id, 'warning', 'temp-file spills', round(100.0 * h.bytes / h.data_bytes, 1)::text || ' % of the data',
         'find the statements that spill (the Memory tab) and raise their work_mem, or fix their plans',
         format('the hour from %s wrote %s of temp files, more than 10 %% of the data size (%s): the larger of the log''s temporary-file lines and pg_stat_statements'' temp blocks.',
                to_char(h.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), pg_size_pretty(h.bytes), pg_size_pretty(h.data_bytes)),
         h.snapshot_at
    FROM temp_hour h
  UNION ALL
  SELECT b.instance_id, 'info', 'one relation holds over half of shared_buffers',
         round(100.0 * r.buffers / b.total_buffers, 1)::text || ' %', 'nothing, if it is the hot table; else find what reads it whole',
         format('%s holds %s of %s buffers (%s): one relation crowds the rest of the working set out of the cache.',
                coalesce(r.schemaname || '.' || r.relname, r.datname || ' file node ' || r.relfilenode::text),
                r.buffers, b.total_buffers, pg_size_pretty(r.buffers * b.block_size)),
         b.snapshot_at
    FROM buf_last b
    JOIN LATERAL (SELECT x.* FROM pgvigil.buffercache_sample x
                   WHERE x.instance_id = b.instance_id AND x.snapshot_at = b.snapshot_at AND x.kind = 'rel'
                   ORDER BY x.buffers DESC LIMIT 1) r ON true
   WHERE b.total_buffers > 0 AND r.buffers > 0.5 * b.total_buffers
)
SELECT f.instance_id, f.severity, f.setting, f.value, true AS is_set, f.suggested, 'all'::text AS platforms, f.detail,
       'pgvigil memory'::text AS source, f.at
  FROM f JOIN pgvigil.instances i ON i.instance_id = f.instance_id AND i.is_active;
