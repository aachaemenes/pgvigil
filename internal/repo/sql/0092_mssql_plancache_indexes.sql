-- 0092: SQL Server plan cache, indexes and statistics (the collections mssql_plancache, mssql_plancache_health,
-- mssql_indexes and mssql_stats; internal/mssql/plancache.go, indexes.go, stats.go).
--
-- mssql_plancache (every 5 minutes): sys.dm_exec_query_stats counts per statement of a cached plan since the plan was
-- compiled, so the import keeps the last counters per statement and plan (mssql_pc_last, mssql_pc_state) and stores
-- what one interval added, summed per database and query key (mssql_pc_sample; mssql_pc_read: every read's seconds,
-- an idle one too). The rule of the difference is 0084's, word for word: the first read of an instance only sets
-- the counters; a statement seen before and not lower than before gives now minus before; one that went DOWN gives
-- its whole count; one the read before did not list gives its whole count, unless that read was cut at the
-- collector's lists (capped) and the statement was compiled before that read's clock: then it may only have been
-- past the cut, and it sets its counters and gives nothing. Nothing is ever negative.
--   mssql_pc_text      one text per query key (the query hash, or handle:offset where the server gave no hash), sent
--                      by the collector once in a while, the instance's text policy applied before it was sent.
--   mssql_pc_database  the instance's databases with their Query Store switch (the page's scope).
--
-- mssql_plancache_health (hourly): what the cache holds per database, as last read.
--   mssql_pc_health        plans, single-use plans, statements, how recently they were compiled, the statements of a
--                          query hash with more than one cached plan.
--   mssql_pc_list          the two lists: the largest single-use plans, the query hashes with the most plans.
--
-- mssql_indexes (every 6 hours), stored database by database (one import call each):
--   mssql_index_db         the database's read and its USAGE WINDOW: the usage counters begin again at the latest of
--                          the server's start, the database's last restore and its create date; usage_since is that
--                          instant and usage_reason names which it was.
--   mssql_index            one row per index, as last read: definition, size, rows, reads and writes.
--   mssql_missing_index    the server's missing-index requests, the most benefit first.
--
-- mssql_stats (every 6 hours), stored database by database:
--   mssql_stats_db         the database's summary over every statistic.
--   mssql_stat             the statistics worth a row of their own.
--
-- The judgements are views and one function over these rows, so a threshold is changed here and nowhere else:
--   mssql_index_db_status  the usage window's length at the read and the guard: no index is called unused before the
--                          window is 7 days long ('too early'); under 14 days the verdict carries a warning.
--   mssql_index_verdicts() one row per index a rule names, with the text a DBA would run (pgvigil never does).
--   mssql_stat_status      one row per stored statistic with its flags.
--   mssql_plancache_findings, mssql_indexes_findings, mssql_stats_findings
--                          the slice's findings in the findings columns (instance_id, severity, check_name, object,
--                          at, detail).
--
-- For the join: add the three findings views as arms of pgvigil.findings (sources 'mssql_plancache',
-- 'mssql_indexes', 'mssql_stats'); add mssql_pc_read and mssql_pc_sample to purge()'s month-partition parents and
-- n := n + pgvigil.mssql_plancache_purge(p_days) for the rest; put 'mssql_plancache_purge' on apply_roles()'
-- owner-only list beside mssql_reads_purge (it deletes). mssql_qname, mssql_index_definition, mssql_index_verdicts
-- stay with the reader (the pages call them).

-- ---------------------------------------------------------------------------------------------------------------
-- the plan cache
-- ---------------------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pc_state (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  server_utc    timestamptz NOT NULL,
  server_start  timestamptz,
  server_local  timestamp,               -- the server's own clock at the read, as the DMV's creation_time is written
  capped        boolean NOT NULL DEFAULT false,  -- the cache held more statements than the collector's lists keep
  cached        bigint                   -- the statements the cache held at the read
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pc_last (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  plan_handle      text NOT NULL,          -- the cached plan, as 0x text
  stmt_start       int NOT NULL,           -- the statement's offsets in its batch: one plan holds several statements
  stmt_end         int NOT NULL,
  creation_time    timestamp NOT NULL,     -- when the plan was compiled, the server's own clock: a recompile counts anew
  database_id      int NOT NULL,
  query_key        text NOT NULL,
  execution_count  bigint NOT NULL,
  worker_us        bigint NOT NULL,
  elapsed_us       bigint NOT NULL,
  logical_reads    bigint NOT NULL,
  physical_reads   bigint NOT NULL,
  logical_writes   bigint NOT NULL,
  row_count        bigint NOT NULL,
  spills           bigint NOT NULL,
  PRIMARY KEY (instance_id, plan_handle, stmt_start, stmt_end, creation_time)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pc_sample (
  instance_id        int NOT NULL,
  snapshot_at        timestamptz NOT NULL,
  database_id        int NOT NULL,            -- the database the plan was compiled in; 0 = the server named none
  query_key          text NOT NULL,           -- the query hash as 0x text, or handle:offset where the server gave no hash
  database_name      text,
  executions         bigint NOT NULL,
  cpu_us             bigint NOT NULL,
  duration_us        bigint NOT NULL,
  logical_reads      bigint NOT NULL,
  physical_reads     bigint NOT NULL,
  logical_writes     bigint NOT NULL,
  row_count          bigint NOT NULL,
  spills             bigint NOT NULL,
  max_grant_kb       bigint,                  -- the largest grant since the plans that ran were compiled, not the interval's own
  max_used_grant_kb  bigint,
  max_dop            int,
  plans              int NOT NULL,            -- the cached plans of the key that ran in the interval
  interval_secs      real NOT NULL            -- between this read and the one before, by the server's own clock
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pc_read (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  interval_secs  real NOT NULL,
  statements     int NOT NULL,             -- the query keys that ran in the interval
  capped         boolean NOT NULL DEFAULT false
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pc_text (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  query_key    text NOT NULL,
  database_id  int,
  object_name  text,                      -- schema.module when the statement is a procedure's, a function's or a trigger's
  query        text,                      -- NULL under the text policy 'none'
  snapshot_at  timestamptz NOT NULL,      -- the read that sent the text
  seen_at      timestamptz NOT NULL,      -- the last read (to the day) whose statements carried the key
  PRIMARY KEY (instance_id, query_key)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pc_database (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_id     int NOT NULL,
  database_name   text,
  query_store_on  boolean,                -- NULL: not read (the database is not online)
  database_state  text,
  snapshot_at     timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pc_health_state (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  server_utc    timestamptz NOT NULL,
  server_start  timestamptz
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pc_health (
  instance_id           int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_id           int NOT NULL,
  database_name         text,
  snapshot_at           timestamptz NOT NULL,
  plans                 bigint NOT NULL,   -- compiled plans (sys.dm_exec_cached_plans)
  plan_bytes            bigint NOT NULL,
  single_use            bigint NOT NULL,   -- ad hoc and prepared plans used once
  single_use_bytes      bigint NOT NULL,
  adhoc_plans           bigint NOT NULL,
  prepared_plans        bigint NOT NULL,
  proc_plans            bigint NOT NULL,
  statements            bigint NOT NULL,   -- cached statements (sys.dm_exec_query_stats)
  compiled_24h          bigint NOT NULL,
  compiled_4h           bigint NOT NULL,
  compiled_1h           bigint NOT NULL,
  oldest_compile        timestamptz,
  duplicate_statements  bigint NOT NULL,   -- statements whose query hash has more than one cached plan in the database
  duplicate_hashes      bigint NOT NULL,
  PRIMARY KEY (instance_id, database_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pc_list (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  list           text NOT NULL,           -- single_use | duplicate
  ord            int NOT NULL,            -- the row's place in the list as the server ordered it
  database_id    int,
  database_name  text,
  plan_kind      text,                    -- single_use: Adhoc | Prepared
  size_bytes     bigint,                  -- single_use: the plan's size
  query_hash     text,                    -- duplicate
  plans          bigint,                  -- duplicate: the cached plans of the hash
  statements     bigint,
  executions     bigint,
  query          text,                    -- the start of the text; NULL under the text policy 'none'
  snapshot_at    timestamptz NOT NULL,
  PRIMARY KEY (instance_id, list, ord)
);

-- payload: one {kind:'state', server_utc, server_start, server_local, capped, cached}; the 'stmt' rows {plan_handle,
-- sql_handle, stmt_start, stmt_end, creation_time, query_key, database_id, database_name, execution_count, worker_us,
-- elapsed_us, logical_reads, physical_reads, logical_writes, row_count, spills, max_grant_kb, max_used_grant_kb,
-- max_dop}: the server's cumulative counters per statement of a cached plan (creation_time and server_local without
-- a zone, in the server's own clock); the 'text' rows {query_key, database_id, object_name, query}; the 'database'
-- rows {database_id, database_name, query_store_on, database_state}.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_plancache(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s        jsonb := pgvigil.mssql_perf_check('import_mssql_plancache', p_instance_id, p_payload);
  v_now      timestamptz := (v_s->>'server_utc')::timestamptz;
  v_start    timestamptz := (v_s->>'server_start')::timestamptz;
  v_local    timestamp := (v_s->>'server_local')::timestamp;
  v_capped   boolean := coalesce((v_s->>'capped')::boolean, false);
  v_prev     pgvigil.mssql_pc_state;
  v_secs     real;
  v_restart  boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_plancache'), p_instance_id);
  SELECT * INTO v_prev FROM pgvigil.mssql_pc_state WHERE instance_id = p_instance_id;
  IF FOUND AND (v_prev.server_utc >= v_now OR v_prev.snapshot_at >= p_snapshot_at) THEN
    RETURN;  -- an older read arriving late (or the same read again): the counters stored are newer
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_pc_in (
    plan_handle text, stmt_start int, stmt_end int, creation_time timestamp, database_id int, database_name text, query_key text,
    execution_count bigint, worker_us bigint, elapsed_us bigint, logical_reads bigint, physical_reads bigint, logical_writes bigint,
    row_count bigint, spills bigint, max_grant_kb bigint, max_used_grant_kb bigint, max_dop bigint,
    PRIMARY KEY (plan_handle, stmt_start, stmt_end, creation_time)) ON COMMIT DROP;
  TRUNCATE pgv_mssql_pc_in;
  INSERT INTO pgv_mssql_pc_in
  SELECT DISTINCT ON (r->>'plan_handle', (r->>'stmt_start')::int, (r->>'stmt_end')::int, (r->>'creation_time')::timestamp)
         r->>'plan_handle', (r->>'stmt_start')::int, (r->>'stmt_end')::int, (r->>'creation_time')::timestamp,
         coalesce((r->>'database_id')::int, 0), r->>'database_name', r->>'query_key', (r->>'execution_count')::bigint,
         coalesce((r->>'worker_us')::bigint, 0), coalesce((r->>'elapsed_us')::bigint, 0), coalesce((r->>'logical_reads')::bigint, 0),
         coalesce((r->>'physical_reads')::bigint, 0), coalesce((r->>'logical_writes')::bigint, 0), coalesce((r->>'row_count')::bigint, 0),
         coalesce((r->>'spills')::bigint, 0), (r->>'max_grant_kb')::bigint, (r->>'max_used_grant_kb')::bigint, (r->>'max_dop')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'stmt' AND r->>'plan_handle' IS NOT NULL AND r->>'stmt_start' IS NOT NULL AND r->>'stmt_end' IS NOT NULL
     AND r->>'creation_time' IS NOT NULL AND r->>'query_key' IS NOT NULL AND r->>'execution_count' IS NOT NULL
   ORDER BY 1, 2, 3, 4;

  IF v_prev.instance_id IS NOT NULL AND v_now > v_prev.server_utc THEN
    v_secs := extract(epoch FROM v_now - v_prev.server_utc);
    v_restart := NOT pgvigil.mssql_same_run(v_prev.server_start, v_start);
    -- the parents in name order, the order purge() drops in (0067's lock-order note), before anything is written
    PERFORM pgvigil.ensure_month_partition('mssql_pc_read', p_snapshot_at);
    PERFORM pgvigil.ensure_month_partition('mssql_pc_sample', p_snapshot_at);
    LOCK TABLE ONLY pgvigil.mssql_pc_read, ONLY pgvigil.mssql_pc_sample IN ROW EXCLUSIVE MODE;
    -- a restart since the read before: every plan in the cache was compiled after it, and the old counters mean nothing
    IF v_restart THEN
      DELETE FROM pgvigil.mssql_pc_last WHERE instance_id = p_instance_id;
    END IF;
    DELETE FROM pgvigil.mssql_pc_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    DELETE FROM pgvigil.mssql_pc_read WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    INSERT INTO pgvigil.mssql_pc_sample (instance_id, snapshot_at, database_id, query_key, database_name, executions, cpu_us, duration_us,
        logical_reads, physical_reads, logical_writes, row_count, spills, max_grant_kb, max_used_grant_kb, max_dop, plans, interval_secs)
    SELECT p_instance_id, p_snapshot_at, d.database_id, d.query_key, max(d.database_name), sum(d.executions), sum(d.cpu_us), sum(d.duration_us),
           sum(d.logical_reads), sum(d.physical_reads), sum(d.logical_writes), sum(d.row_count), sum(d.spills),
           max(d.max_grant_kb), max(d.max_used_grant_kb), max(d.max_dop)::int, count(DISTINCT d.plan_handle), v_secs
      FROM (SELECT f.database_id, f.query_key, f.database_name, f.plan_handle, f.max_grant_kb, f.max_used_grant_kb, f.max_dop,
                   CASE g.mode WHEN 'diff' THEN f.execution_count - l.execution_count WHEN 'whole' THEN f.execution_count ELSE 0 END AS executions,
                   CASE g.mode WHEN 'diff' THEN greatest(f.worker_us - l.worker_us, 0) WHEN 'whole' THEN f.worker_us ELSE 0 END AS cpu_us,
                   CASE g.mode WHEN 'diff' THEN greatest(f.elapsed_us - l.elapsed_us, 0) WHEN 'whole' THEN f.elapsed_us ELSE 0 END AS duration_us,
                   CASE g.mode WHEN 'diff' THEN greatest(f.logical_reads - l.logical_reads, 0) WHEN 'whole' THEN f.logical_reads ELSE 0 END AS logical_reads,
                   CASE g.mode WHEN 'diff' THEN greatest(f.physical_reads - l.physical_reads, 0) WHEN 'whole' THEN f.physical_reads ELSE 0 END AS physical_reads,
                   CASE g.mode WHEN 'diff' THEN greatest(f.logical_writes - l.logical_writes, 0) WHEN 'whole' THEN f.logical_writes ELSE 0 END AS logical_writes,
                   CASE g.mode WHEN 'diff' THEN greatest(f.row_count - l.row_count, 0) WHEN 'whole' THEN f.row_count ELSE 0 END AS row_count,
                   CASE g.mode WHEN 'diff' THEN greatest(f.spills - l.spills, 0) WHEN 'whole' THEN f.spills ELSE 0 END AS spills
              FROM pgv_mssql_pc_in f
              LEFT JOIN pgvigil.mssql_pc_last l ON l.instance_id = p_instance_id AND l.plan_handle = f.plan_handle AND l.stmt_start = f.stmt_start
                                               AND l.stmt_end = f.stmt_end AND l.creation_time = f.creation_time
                   -- diff: the statement was in the read before and grew. whole: it counts lower than before (again from
                   -- zero); or it was not in the read before, and that read was complete (or the server restarted
                   -- since): it was compiled after it; or that read was cut and the statement was compiled at or after
                   -- its clock. none: not in a cut read although compiled earlier: it only sets its counters.
             CROSS JOIN LATERAL (SELECT CASE WHEN l.instance_id IS NOT NULL AND f.execution_count >= l.execution_count THEN 'diff'
                                             WHEN l.instance_id IS NOT NULL OR v_restart OR NOT v_prev.capped THEN 'whole'
                                             WHEN f.creation_time >= v_prev.server_local THEN 'whole'
                                             ELSE 'none' END AS mode) g) d
     WHERE d.executions > 0
     GROUP BY d.database_id, d.query_key;
    INSERT INTO pgvigil.mssql_pc_read (instance_id, snapshot_at, interval_secs, statements, capped)
    SELECT p_instance_id, p_snapshot_at, v_secs,
           (SELECT count(*) FROM pgvigil.mssql_pc_sample s WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at), v_capped;
  END IF;

  -- the state is this read's statements: one the cache dropped (or the lists no longer hold) leaves it, and only
  -- counters that moved are rewritten
  DELETE FROM pgvigil.mssql_pc_last l
   WHERE l.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM pgv_mssql_pc_in f
                      WHERE f.plan_handle = l.plan_handle AND f.stmt_start = l.stmt_start AND f.stmt_end = l.stmt_end AND f.creation_time = l.creation_time);
  INSERT INTO pgvigil.mssql_pc_last AS l (instance_id, plan_handle, stmt_start, stmt_end, creation_time, database_id, query_key, execution_count,
      worker_us, elapsed_us, logical_reads, physical_reads, logical_writes, row_count, spills)
  SELECT p_instance_id, f.plan_handle, f.stmt_start, f.stmt_end, f.creation_time, f.database_id, f.query_key, f.execution_count, f.worker_us,
         f.elapsed_us, f.logical_reads, f.physical_reads, f.logical_writes, f.row_count, f.spills
    FROM pgv_mssql_pc_in f
  ON CONFLICT (instance_id, plan_handle, stmt_start, stmt_end, creation_time) DO UPDATE SET
      execution_count = EXCLUDED.execution_count, worker_us = EXCLUDED.worker_us, elapsed_us = EXCLUDED.elapsed_us,
      logical_reads = EXCLUDED.logical_reads, physical_reads = EXCLUDED.physical_reads, logical_writes = EXCLUDED.logical_writes,
      row_count = EXCLUDED.row_count, spills = EXCLUDED.spills
   WHERE (l.execution_count, l.worker_us, l.elapsed_us, l.logical_reads, l.physical_reads, l.logical_writes, l.row_count, l.spills)
         IS DISTINCT FROM (EXCLUDED.execution_count, EXCLUDED.worker_us, EXCLUDED.elapsed_us, EXCLUDED.logical_reads,
                           EXCLUDED.physical_reads, EXCLUDED.logical_writes, EXCLUDED.row_count, EXCLUDED.spills);
  INSERT INTO pgvigil.mssql_pc_state AS s (instance_id, snapshot_at, server_utc, server_start, server_local, capped, cached)
  VALUES (p_instance_id, p_snapshot_at, v_now, v_start, v_local, v_capped, (v_s->>'cached')::bigint)
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, server_utc = EXCLUDED.server_utc,
      server_start = EXCLUDED.server_start, server_local = EXCLUDED.server_local, capped = EXCLUDED.capped, cached = EXCLUDED.cached;

  -- the texts: one per key; a text that came without its words (the policy 'none', an encrypted module) keeps what is stored
  INSERT INTO pgvigil.mssql_pc_text AS t (instance_id, query_key, database_id, object_name, query, snapshot_at, seen_at)
  SELECT DISTINCT ON (r->>'query_key') p_instance_id, r->>'query_key', (r->>'database_id')::int, r->>'object_name', r->>'query', p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'text' AND r->>'query_key' IS NOT NULL
   ORDER BY r->>'query_key'
  ON CONFLICT (instance_id, query_key) DO UPDATE SET
      database_id = EXCLUDED.database_id, object_name = coalesce(EXCLUDED.object_name, t.object_name),
      query = coalesce(EXCLUDED.query, t.query), snapshot_at = EXCLUDED.snapshot_at, seen_at = EXCLUDED.seen_at;
  -- a key still in the cache keeps its text past the retention: marked once a day, not with every read
  UPDATE pgvigil.mssql_pc_text t SET seen_at = p_snapshot_at
   WHERE t.instance_id = p_instance_id AND t.seen_at < p_snapshot_at - interval '1 day'
     AND EXISTS (SELECT 1 FROM pgv_mssql_pc_in f WHERE f.query_key = t.query_key);

  -- the databases as this read listed them
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'database') THEN
    DELETE FROM pgvigil.mssql_pc_database WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_pc_database (instance_id, database_id, database_name, query_store_on, database_state, snapshot_at)
    SELECT DISTINCT ON ((r->>'database_id')::int) p_instance_id, (r->>'database_id')::int, r->>'database_name',
           CASE WHEN r->>'database_state' = 'ONLINE' THEN (r->>'query_store_on')::int = 1 END, r->>'database_state', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'database' AND r->>'database_id' IS NOT NULL
     ORDER BY (r->>'database_id')::int;
  END IF;
END $$;

-- payload: one {kind:'state', server_utc, server_start}; the 'health' rows (one per database: mssql_pc_health's
-- columns); the 'single_use' rows {database_id, database_name, plan_kind, size_bytes, query} and the 'duplicate' rows
-- {database_id, database_name, query_hash, plans, statements, executions, query}, each list in the server's order.
-- A read replaces the one before whole.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_plancache_health(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s    jsonb := pgvigil.mssql_perf_check('import_mssql_plancache_health', p_instance_id, p_payload);
  v_now  timestamptz := (v_s->>'server_utc')::timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_plancache_health'), p_instance_id);
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_pc_health_state s WHERE s.instance_id = p_instance_id AND (s.server_utc >= v_now OR s.snapshot_at >= p_snapshot_at)) THEN
    RETURN;  -- an older read arriving late (or the same read again)
  END IF;
  DELETE FROM pgvigil.mssql_pc_health WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_pc_health (instance_id, database_id, database_name, snapshot_at, plans, plan_bytes, single_use, single_use_bytes,
      adhoc_plans, prepared_plans, proc_plans, statements, compiled_24h, compiled_4h, compiled_1h, oldest_compile, duplicate_statements, duplicate_hashes)
  SELECT DISTINCT ON ((r->>'database_id')::int) p_instance_id, (r->>'database_id')::int, r->>'database_name', p_snapshot_at,
         coalesce((r->>'plans')::bigint, 0), coalesce((r->>'plan_bytes')::bigint, 0), coalesce((r->>'single_use')::bigint, 0),
         coalesce((r->>'single_use_bytes')::bigint, 0), coalesce((r->>'adhoc_plans')::bigint, 0), coalesce((r->>'prepared_plans')::bigint, 0),
         coalesce((r->>'proc_plans')::bigint, 0), coalesce((r->>'statements')::bigint, 0), coalesce((r->>'compiled_24h')::bigint, 0),
         coalesce((r->>'compiled_4h')::bigint, 0), coalesce((r->>'compiled_1h')::bigint, 0), (r->>'oldest_compile')::timestamptz,
         coalesce((r->>'duplicate_statements')::bigint, 0), coalesce((r->>'duplicate_hashes')::bigint, 0)
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'health' AND r->>'database_id' IS NOT NULL
   ORDER BY (r->>'database_id')::int;
  DELETE FROM pgvigil.mssql_pc_list WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_pc_list (instance_id, list, ord, database_id, database_name, plan_kind, size_bytes, query_hash, plans, statements,
      executions, query, snapshot_at)
  SELECT p_instance_id, r->>'kind', row_number() OVER (PARTITION BY r->>'kind' ORDER BY n), (r->>'database_id')::int, r->>'database_name',
         r->>'plan_kind', (r->>'size_bytes')::bigint, r->>'query_hash', (r->>'plans')::bigint, (r->>'statements')::bigint,
         (r->>'executions')::bigint, r->>'query', p_snapshot_at
    FROM jsonb_array_elements(p_payload) WITH ORDINALITY AS e(r, n)
   WHERE r->>'kind' IN ('single_use', 'duplicate');
  INSERT INTO pgvigil.mssql_pc_health_state AS s (instance_id, snapshot_at, server_utc, server_start)
  VALUES (p_instance_id, p_snapshot_at, v_now, (v_s->>'server_start')::timestamptz)
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, server_utc = EXCLUDED.server_utc, server_start = EXCLUDED.server_start;
END $$;

-- The plan cache's findings. A read older than three hours raises nothing: the Collections page says the collection
-- is stale. The per-database rules leave the system databases out (monitoring tools and the Agent run their ad hoc
-- statements there) and ask for 100 plans of the kind at least: a share of a handful of plans says nothing.
--   most cached plans are recent (warning): over 75 % of the 1,000 or more cached statements were compiled in the
--     last 24 hours on a server up for more than a day: the cache is flushed or under memory pressure, or the
--     statements recompile.
--   single-use plans (warning over 75 % of the database's compiled plans, info over 10 %).
--   one statement compiled into many plans (warning over 75 % of the database's cached statements, info over 5 %).
CREATE OR REPLACE VIEW pgvigil.mssql_plancache_findings AS
SELECT t.instance_id, 'warning'::text AS severity, 'most cached plans are recent'::text AS check_name, 'plan cache'::text AS object, t.snapshot_at AS at,
       format('%s of the %s cached statements (%s %%) were compiled in the last 24 hours, %s in the last 4 and %s in the last hour; the oldest is from %s UTC and the server has been up since %s UTC. '
              || 'The plan cache does not keep its plans: memory pressure, a flush (DBCC FREEPROCCACHE, a configuration change) or statements that recompile.',
              t.compiled_24h, t.statements, round(100.0 * t.compiled_24h / t.statements, 1), t.compiled_4h, t.compiled_1h,
              coalesce(to_char(t.oldest_compile AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), 'a time not read'),
              to_char(t.server_start AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI')) AS detail
  FROM (SELECT h.instance_id, max(h.snapshot_at) AS snapshot_at, sum(h.statements) AS statements, sum(h.compiled_24h) AS compiled_24h,
               sum(h.compiled_4h) AS compiled_4h, sum(h.compiled_1h) AS compiled_1h, min(h.oldest_compile) AS oldest_compile, max(s.server_start) AS server_start
          FROM pgvigil.mssql_pc_health h JOIN pgvigil.mssql_pc_health_state s ON s.instance_id = h.instance_id
         GROUP BY h.instance_id) t
 WHERE t.snapshot_at > now() - interval '3 hours' AND t.statements >= 1000 AND t.compiled_24h > 0.75 * t.statements
   AND t.server_start < t.snapshot_at - interval '24 hours'
UNION ALL
SELECT h.instance_id, CASE WHEN h.single_use > 0.75 * h.plans THEN 'warning' ELSE 'info' END, 'single-use plans in the cache',
       coalesce(h.database_name, 'database ' || h.database_id), h.snapshot_at,
       format('%s of the %s compiled plans of this database (%s %%, %s MB) are ad hoc or prepared plans used once: statements sent with their literals in the text, each compiled for one run. '
              || 'Parameters in the application, or the server option ''optimize for ad hoc workloads'', keep them out of the cache; the Plan cache page lists the largest.',
              h.single_use, h.plans, round(100.0 * h.single_use / h.plans, 1), round(h.single_use_bytes / 1048576.0, 1))
  FROM pgvigil.mssql_pc_health h
 WHERE h.snapshot_at > now() - interval '3 hours' AND h.database_id > 4 AND h.single_use >= 100 AND h.single_use > 0.10 * h.plans
UNION ALL
SELECT h.instance_id, CASE WHEN h.duplicate_statements > 0.75 * h.statements THEN 'warning' ELSE 'info' END, 'one statement compiled into many plans',
       coalesce(h.database_name, 'database ' || h.database_id), h.snapshot_at,
       format('%s of the %s cached statements of this database (%s %%) belong to %s query hash(es) that each have more than one cached plan: the same statement compiled again for other literals or other SET options. '
              || 'The Plan cache page lists the hashes with the most plans.',
              h.duplicate_statements, h.statements, round(100.0 * h.duplicate_statements / h.statements, 1), h.duplicate_hashes)
  FROM pgvigil.mssql_pc_health h
 WHERE h.snapshot_at > now() - interval '3 hours' AND h.database_id > 4 AND h.duplicate_statements >= 100
   AND h.duplicate_statements > 0.05 * h.statements;

-- ---------------------------------------------------------------------------------------------------------------
-- the indexes
-- ---------------------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_index_db (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name        text NOT NULL,
  database_id          int,
  snapshot_at          timestamptz NOT NULL,   -- the read that last listed the database
  read_at              timestamptz,            -- the read that last read its indexes; NULL = never
  database_state       text,
  note                 text,                   -- why the indexes were not read, or what was left out
  server_start         timestamptz,
  created_at           timestamptz,
  last_restore         timestamptz,            -- NULL: never restored on this server, or not read (restore_read)
  restore_read         boolean NOT NULL DEFAULT false,   -- the login may read msdb.dbo.restorehistory
  usage_since          timestamptz,            -- the latest of the three dates: where the usage counters begin
  usage_reason         text,                   -- server start | database restored | database created
  readable_secondary   boolean NOT NULL DEFAULT false,   -- the primary of an availability group with a readable secondary
  online_index_builds  boolean NOT NULL DEFAULT false,   -- the edition builds indexes online
  indexes              int,
  capped               boolean NOT NULL DEFAULT false,
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_index (
  instance_id           int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name         text NOT NULL,
  object_id             bigint NOT NULL,
  index_id              int NOT NULL,
  database_id           int,
  schema_name           text,
  table_name            text,
  index_name            text,
  index_type            text,                  -- CLUSTERED | NONCLUSTERED | CLUSTERED COLUMNSTORE | XML ...
  is_unique             boolean NOT NULL DEFAULT false,
  is_primary_key        boolean NOT NULL DEFAULT false,
  is_unique_constraint  boolean NOT NULL DEFAULT false,
  is_disabled           boolean NOT NULL DEFAULT false,
  is_hypothetical       boolean NOT NULL DEFAULT false,
  has_filter            boolean NOT NULL DEFAULT false,
  filter_definition     text,
  ignore_dup_key        boolean NOT NULL DEFAULT false,
  fill_factor           int,                   -- 0 = the server's default (full pages)
  key_columns           text[] NOT NULL DEFAULT '{}',     -- in key order, each name quoted, a descending one with ' DESC'
  include_columns       text[] NOT NULL DEFAULT '{}',     -- by name, each name quoted
  row_count             bigint,
  size_kb               bigint,                -- reserved pages
  partitions            int,
  compression           text,                  -- NONE | ROW | PAGE | COLUMNSTORE ... | MIXED (the partitions differ)
  user_seeks            bigint NOT NULL DEFAULT 0,
  user_scans            bigint NOT NULL DEFAULT 0,
  user_lookups          bigint NOT NULL DEFAULT 0,
  user_updates          bigint NOT NULL DEFAULT 0,
  last_read             timestamptz,
  last_write            timestamptz,
  table_created         timestamptz,
  table_modified        timestamptz,           -- the table's last ALTER, an index created or rebuilt on it included
  snapshot_at           timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, object_id, index_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_missing_index (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  ord                 int NOT NULL,            -- the request's place by benefit at the read
  database_id         int,
  database_name       text,
  object_id           bigint,
  table_ref           text,                    -- [database].[schema].[table] as the server writes it
  equality_columns    text,
  inequality_columns  text,
  included_columns    text,
  user_seeks          bigint,
  user_scans          bigint,
  compiles            bigint,
  avg_cost            float8,
  avg_impact          float8,                  -- the per cent of the cost the optimizer expected to save
  last_request        timestamptz,
  benefit             float8,                  -- (seeks + scans) x cost x impact, since the server started
  server_start        timestamptz,
  snapshot_at         timestamptz NOT NULL,
  PRIMARY KEY (instance_id, ord)
);

-- QUOTENAME: brackets, a closing bracket doubled.
CREATE OR REPLACE FUNCTION pgvigil.mssql_qname(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT '[' || replace(p_name, ']', ']]') || ']'
$$;

-- An index's definition as T-SQL, for the inventory's 'definition' column and for a merged definition (the text a
-- DBA reads; pgvigil runs none of it). A primary key or a unique constraint is written as its ALTER TABLE; any
-- other rowstore index as CREATE INDEX with the four options spelled out: ONLINE as the edition allows, the
-- index's own fill factor (0 is 100) and compression, SORT_IN_TEMPDB = OFF. p_drop_existing: the statement replaces
-- the index of that name. An index that is no rowstore index, or whose partitions differ in compression, has no
-- text here (NULL): its options cannot be written in one line.
CREATE OR REPLACE FUNCTION pgvigil.mssql_index_definition(p_index_type text, p_is_unique boolean, p_is_primary_key boolean, p_is_unique_constraint boolean,
    p_schema text, p_table text, p_index text, p_keys text[], p_includes text[], p_filter text, p_fill_factor int, p_compression text,
    p_online boolean, p_drop_existing boolean)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_index_type NOT IN ('CLUSTERED', 'NONCLUSTERED') OR coalesce(cardinality(p_keys), 0) = 0 OR p_index IS NULL OR p_table IS NULL THEN NULL
    WHEN coalesce(p_compression, 'NONE') NOT IN ('NONE', 'ROW', 'PAGE') THEN NULL
    WHEN (p_is_primary_key OR p_is_unique_constraint) AND NOT p_drop_existing THEN
      format('ALTER TABLE %s.%s ADD CONSTRAINT %s %s %s (%s) WITH (FILLFACTOR = %s, DATA_COMPRESSION = %s);',
             pgvigil.mssql_qname(coalesce(p_schema, 'dbo')), pgvigil.mssql_qname(p_table), pgvigil.mssql_qname(p_index),
             CASE WHEN p_is_primary_key THEN 'PRIMARY KEY' ELSE 'UNIQUE' END, p_index_type, array_to_string(p_keys, ', '),
             CASE WHEN coalesce(p_fill_factor, 0) = 0 THEN 100 ELSE p_fill_factor END, coalesce(p_compression, 'NONE'))
    ELSE
      format('CREATE %s%s INDEX %s ON %s.%s (%s)%s%s WITH (%sONLINE = %s, FILLFACTOR = %s, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = %s);',
             CASE WHEN p_is_unique THEN 'UNIQUE ' ELSE '' END, p_index_type, pgvigil.mssql_qname(p_index),
             pgvigil.mssql_qname(coalesce(p_schema, 'dbo')), pgvigil.mssql_qname(p_table), array_to_string(p_keys, ', '),
             CASE WHEN coalesce(cardinality(p_includes), 0) > 0 THEN ' INCLUDE (' || array_to_string(p_includes, ', ') || ')' ELSE '' END,
             CASE WHEN nullif(p_filter, '') IS NOT NULL THEN ' WHERE ' || p_filter ELSE '' END,
             CASE WHEN p_drop_existing THEN 'DROP_EXISTING = ON, ' ELSE '' END,
             CASE WHEN p_online THEN 'ON' ELSE 'OFF' END,
             CASE WHEN coalesce(p_fill_factor, 0) = 0 THEN 100 ELSE p_fill_factor END, coalesce(p_compression, 'NONE'))
  END
$$;

-- payload, one call per batch of the collector, every batch with the run's {kind:'state', server_utc, server_start,
-- online_index_builds}:
--   a database's batch: one {kind:'db', database_id, database_name, database_state, created_at, last_restore,
--     restore_read, readable_secondary, read, note, capped, indexes} and, when read is true, its 'index' rows
--     (mssql_index's columns; key_columns and include_columns as arrays). The database's stored indexes are replaced
--     by a batch that read them and kept by one that did not.
--   the run's last batch: {kind:'databases', names:[...]} (a stored database the server no longer lists goes, with
--     its indexes) and, when the missing-index read succeeded, the 'missing' rows in the server's order with
--     {kind:'missing_read'} (the stored requests are replaced).
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_indexes(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s      jsonb := pgvigil.mssql_perf_check('import_mssql_indexes', p_instance_id, p_payload);
  v_start  timestamptz := (v_s->>'server_start')::timestamptz;
  v_online boolean := coalesce((v_s->>'online_index_builds')::boolean, false);
  v_db     jsonb;
  v_name   text;
  v_made   timestamptz;
  v_rest   timestamptz;
  v_since  timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_indexes'), p_instance_id);
  FOR v_db IN SELECT r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND r->>'database_name' IS NOT NULL LOOP
    v_name := v_db->>'database_name';
    -- an older read arriving late changes nothing of the database
    CONTINUE WHEN EXISTS (SELECT 1 FROM pgvigil.mssql_index_db b
                           WHERE b.instance_id = p_instance_id AND b.database_name = v_name AND b.snapshot_at > p_snapshot_at);
    v_made := (v_db->>'created_at')::timestamptz;
    v_rest := (v_db->>'last_restore')::timestamptz;
    v_since := greatest(v_start, v_made, v_rest);   -- greatest() skips a date that was not read
    INSERT INTO pgvigil.mssql_index_db AS b (instance_id, database_name, database_id, snapshot_at, read_at, database_state, note, server_start,
        created_at, last_restore, restore_read, usage_since, usage_reason, readable_secondary, online_index_builds, indexes, capped)
    VALUES (p_instance_id, v_name, (v_db->>'database_id')::int, p_snapshot_at,
            CASE WHEN (v_db->>'read')::boolean THEN p_snapshot_at END, v_db->>'database_state', v_db->>'note', v_start, v_made, v_rest,
            coalesce((v_db->>'restore_read')::boolean, false), v_since,
            CASE WHEN v_since IS NULL THEN NULL WHEN v_since = v_rest THEN 'database restored' WHEN v_since = v_made THEN 'database created' ELSE 'server start' END,
            coalesce((v_db->>'readable_secondary')::boolean, false), v_online, (v_db->>'indexes')::int, coalesce((v_db->>'capped')::boolean, false))
    ON CONFLICT (instance_id, database_name) DO UPDATE SET
        database_id = EXCLUDED.database_id, snapshot_at = EXCLUDED.snapshot_at, read_at = coalesce(EXCLUDED.read_at, b.read_at),
        database_state = EXCLUDED.database_state, note = EXCLUDED.note, server_start = EXCLUDED.server_start, created_at = EXCLUDED.created_at,
        last_restore = EXCLUDED.last_restore, restore_read = EXCLUDED.restore_read, usage_since = EXCLUDED.usage_since,
        usage_reason = EXCLUDED.usage_reason, readable_secondary = EXCLUDED.readable_secondary, online_index_builds = EXCLUDED.online_index_builds,
        indexes = coalesce(EXCLUDED.indexes, b.indexes), capped = CASE WHEN EXCLUDED.read_at IS NULL THEN b.capped ELSE EXCLUDED.capped END;
    IF (v_db->>'read')::boolean THEN
      DELETE FROM pgvigil.mssql_index WHERE instance_id = p_instance_id AND database_name = v_name;
      INSERT INTO pgvigil.mssql_index (instance_id, database_name, object_id, index_id, database_id, schema_name, table_name, index_name, index_type,
          is_unique, is_primary_key, is_unique_constraint, is_disabled, is_hypothetical, has_filter, filter_definition, ignore_dup_key, fill_factor,
          key_columns, include_columns, row_count, size_kb, partitions, compression, user_seeks, user_scans, user_lookups, user_updates,
          last_read, last_write, table_created, table_modified, snapshot_at)
      SELECT DISTINCT ON ((r->>'object_id')::bigint, (r->>'index_id')::int)
             p_instance_id, v_name, (r->>'object_id')::bigint, (r->>'index_id')::int, (r->>'database_id')::int, r->>'schema_name', r->>'table_name',
             r->>'index_name', r->>'index_type', coalesce((r->>'is_unique')::int, 0) = 1, coalesce((r->>'is_primary_key')::int, 0) = 1,
             coalesce((r->>'is_unique_constraint')::int, 0) = 1, coalesce((r->>'is_disabled')::int, 0) = 1, coalesce((r->>'is_hypothetical')::int, 0) = 1,
             coalesce((r->>'has_filter')::int, 0) = 1, r->>'filter_definition', coalesce((r->>'ignore_dup_key')::int, 0) = 1, (r->>'fill_factor')::int,
             CASE WHEN jsonb_typeof(r->'key_columns') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(r->'key_columns')) ELSE '{}' END,
             CASE WHEN jsonb_typeof(r->'include_columns') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(r->'include_columns')) ELSE '{}' END,
             (r->>'row_count')::bigint, (r->>'size_kb')::bigint, (r->>'partitions')::int, r->>'compression',
             coalesce((r->>'user_seeks')::bigint, 0), coalesce((r->>'user_scans')::bigint, 0), coalesce((r->>'user_lookups')::bigint, 0),
             coalesce((r->>'user_updates')::bigint, 0), (r->>'last_read')::timestamptz, (r->>'last_write')::timestamptz,
             (r->>'table_created')::timestamptz, (r->>'table_modified')::timestamptz, p_snapshot_at
        FROM jsonb_array_elements(p_payload) r
       WHERE r->>'kind' = 'index' AND r->>'database_name' = v_name AND r->>'object_id' IS NOT NULL AND r->>'index_id' IS NOT NULL
       ORDER BY 3, 4;
    END IF;
  END LOOP;

  -- the run's last batch: the databases the server lists now, and the missing-index requests
  SELECT r INTO v_db FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'databases' AND jsonb_typeof(r->'names') = 'array' LIMIT 1;
  IF v_db IS NOT NULL THEN
    DELETE FROM pgvigil.mssql_index x
     WHERE x.instance_id = p_instance_id
       AND EXISTS (SELECT 1 FROM pgvigil.mssql_index_db b
                    WHERE b.instance_id = x.instance_id AND b.database_name = x.database_name AND b.snapshot_at < p_snapshot_at
                      AND NOT (v_db->'names') ? b.database_name);
    DELETE FROM pgvigil.mssql_index_db b
     WHERE b.instance_id = p_instance_id AND b.snapshot_at < p_snapshot_at AND NOT (v_db->'names') ? b.database_name;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'missing_read')
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_missing_index m WHERE m.instance_id = p_instance_id AND m.snapshot_at > p_snapshot_at) THEN
    DELETE FROM pgvigil.mssql_missing_index WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_missing_index (instance_id, ord, database_id, database_name, object_id, table_ref, equality_columns, inequality_columns,
        included_columns, user_seeks, user_scans, compiles, avg_cost, avg_impact, last_request, benefit, server_start, snapshot_at)
    SELECT p_instance_id, row_number() OVER (ORDER BY n), (r->>'database_id')::int, r->>'database_name', (r->>'object_id')::bigint, r->>'table_ref',
           r->>'equality_columns', r->>'inequality_columns', r->>'included_columns', (r->>'user_seeks')::bigint, (r->>'user_scans')::bigint,
           (r->>'compiles')::bigint, (r->>'avg_cost')::float8, (r->>'avg_impact')::float8, (r->>'last_request')::timestamptz, (r->>'benefit')::float8,
           v_start, p_snapshot_at
      FROM jsonb_array_elements(p_payload) WITH ORDINALITY AS e(r, n)
     WHERE r->>'kind' = 'missing';
  END IF;
END $$;

-- The usage window of each database at its last read, and the guard on every 'unused' verdict:
--   usage_days  the window's length at the read: the counters of sys.dm_db_index_usage_stats cover no more.
--   judged      true from 7 days: before that no index is called unused (duplicates are judged all the same).
--   guard       the sentence the page shows.
CREATE OR REPLACE VIEW pgvigil.mssql_index_db_status AS
SELECT b.*, u.usage_days, coalesce(u.usage_days > 7, false) AS judged,
       CASE WHEN b.read_at IS NULL THEN NULL
            WHEN u.usage_days IS NULL THEN 'the usage window is not known (no start date was read): no index is called unused'
            ELSE CASE WHEN u.usage_days <= 7 THEN 'too early: ' ELSE '' END
                 || format('the usage counters cover %s day(s), since %s (%s UTC)', round(u.usage_days::numeric, 1), b.usage_reason,
                           to_char(b.usage_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'))
                 || CASE WHEN u.usage_days <= 7 THEN '; no index is called unused before 7 days. Duplicates are judged all the same.'
                         WHEN u.usage_days < 14 THEN '; under 14 days a weekly or monthly job may not have run yet.'
                         ELSE '.' END
                 || CASE WHEN b.readable_secondary THEN ' This is the primary of an availability group with a readable secondary: reads on the secondary are counted there, not here.' ELSE '' END
                 || CASE WHEN NOT b.restore_read THEN ' The restore history was not read (msdb.dbo.restorehistory): a restore since then would make the window shorter.' ELSE '' END
       END AS guard
  FROM pgvigil.mssql_index_db b
 CROSS JOIN LATERAL (SELECT extract(epoch FROM b.read_at - b.usage_since) / 86400.0 AS usage_days) u;

-- One row per index a rule names, for one instance. Judged: enabled, real (not hypothetical) rowstore indexes with
-- a key; the duplicate rules compare NONCLUSTERED indexes of one table with each other (a primary key or a unique
-- constraint that is nonclustered takes part as the one to keep, never as the one to disable); the clustered index
-- is compared with nothing. An index gets ONE rule, the first that names it:
--   exact duplicate           the same key columns in the same order and direction, the same included columns and
--                             the same filter as another index. Kept: a constraint first, then a unique index, then
--                             the most read, then the lower index id. Text: DISABLE.
--   duplicate constraint      the same, and both back a primary key or a unique constraint: for review, no text (a
--                             foreign key may reference either).
--   key subset                not unique, and its key columns are the leading key columns of another index with the
--                             same filter; kept: the closest such index. Text: the kept index's definition with this
--                             one's included columns merged in (when it lacks any), then DISABLE. Not raised when the
--                             kept index is a constraint that would need included columns.
--   same keys, other includes the same key columns and filter as another index, other included columns. Text: the
--                             kept index's merged definition, then DISABLE.
--   constraint doubled        the same key columns as a unique constraint, with included columns the constraint
--                             cannot hold. Text: this index made UNIQUE, then the constraint dropped; for a primary
--                             key no text.
--   unused, written           (usage window over 7 days, table older than 7 days) a non-unique nonclustered index
--                             with no seek, scan or lookup and 10,000 or more writes. Text: DISABLE. Warning.
--   unused                    the same with fewer writes. Text: DISABLE.
--   written, seldom read      10,000 or more writes, under 10,000 reads, ten times more writes than reads. No text.
--   same keys, another order  the same leading column and the same set of key columns as another index, in another
--                             order. For review, no text.
--   same leading column       shares its first key column with another index of the table. For review, no text.
-- script is T-SQL for a DBA to read, test and run; pgvigil runs none of it. A disabled index comes back with
-- ALTER INDEX ... REBUILD.
CREATE OR REPLACE FUNCTION pgvigil.mssql_index_verdicts(p_instance_id int)
RETURNS TABLE (database_name text, object_id bigint, index_id int, rule text, severity text, detail text, script text, keeper text)
LANGUAGE sql STABLE AS $$
WITH d AS (
  SELECT s.database_name, s.read_at, s.usage_days, s.judged, s.usage_reason, s.usage_since, s.readable_secondary, s.online_index_builds
    FROM pgvigil.mssql_index_db_status s
   WHERE s.instance_id = p_instance_id AND s.read_at IS NOT NULL
), i AS (
  SELECT x.database_name, x.object_id, x.index_id, x.schema_name, x.table_name, x.index_name, x.index_type, x.is_unique, x.is_primary_key,
         x.is_unique_constraint, x.filter_definition, x.fill_factor, x.key_columns, x.include_columns, x.compression, x.size_kb,
         x.table_created, x.table_modified, x.snapshot_at,
         (x.is_primary_key OR x.is_unique_constraint) AS is_constraint,
         x.user_seeks + x.user_scans + x.user_lookups AS reads, x.user_updates AS writes,
         n.key_names, (SELECT array_agg(k ORDER BY k) FROM unnest(n.key_names) k) AS key_set,
         pgvigil.mssql_qname(coalesce(x.schema_name, 'dbo')) || '.' || pgvigil.mssql_qname(x.table_name) AS qtable,
         pgvigil.mssql_qname(x.index_name) AS qindex
    FROM pgvigil.mssql_index x
   CROSS JOIN LATERAL (SELECT array_agg(regexp_replace(k, ' DESC$', '') ORDER BY o) AS key_names FROM unnest(x.key_columns) WITH ORDINALITY AS u(k, o)) n
   WHERE x.instance_id = p_instance_id AND x.index_type IN ('CLUSTERED', 'NONCLUSTERED') AND NOT x.is_disabled AND NOT x.is_hypothetical
     AND cardinality(x.key_columns) > 0 AND x.index_name IS NOT NULL AND x.table_name IS NOT NULL
), nc AS (
  SELECT * FROM i WHERE index_type = 'NONCLUSTERED'
), ex AS (
  SELECT n.database_name, n.object_id, n.index_id, first_value(n.index_id) OVER w AS keeper_id, row_number() OVER w AS rn
    FROM nc n
  WINDOW w AS (PARTITION BY n.database_name, n.object_id, n.key_columns, n.include_columns, n.filter_definition
               ORDER BY n.is_constraint DESC, n.is_unique DESC, n.reads DESC, n.index_id)
), live AS (   -- the nonclustered indexes no exact duplicate replaces
  SELECT n.* FROM nc n JOIN ex e ON e.database_name = n.database_name AND e.object_id = n.object_id AND e.index_id = n.index_id AND e.rn = 1
), sub AS (
  SELECT DISTINCT ON (a.database_name, a.object_id, a.index_id) a.database_name, a.object_id, a.index_id, b.index_id AS keeper_id
    FROM live a
    JOIN live b ON b.database_name = a.database_name AND b.object_id = a.object_id AND b.index_id <> a.index_id
   WHERE NOT a.is_unique AND NOT a.is_constraint
     AND b.filter_definition IS NOT DISTINCT FROM a.filter_definition
     AND cardinality(b.key_columns) > cardinality(a.key_columns)
     AND b.key_columns[1:cardinality(a.key_columns)] = a.key_columns
     AND (NOT b.is_constraint OR a.include_columns <@ (b.key_names || b.include_columns))
   ORDER BY a.database_name, a.object_id, a.index_id, cardinality(b.key_columns), b.is_constraint DESC, b.is_unique DESC, b.reads DESC, b.index_id
), kd AS (
  SELECT l.database_name, l.object_id, l.index_id, first_value(l.index_id) OVER w AS keeper_id, row_number() OVER w AS rn
    FROM live l
  WINDOW w AS (PARTITION BY l.database_name, l.object_id, l.key_columns, l.filter_definition
               ORDER BY l.is_constraint DESC, l.is_unique DESC, l.reads DESC, l.index_id)
), oo AS (
  SELECT DISTINCT ON (a.database_name, a.object_id, a.index_id) a.database_name, a.object_id, a.index_id, b.index_id AS keeper_id
    FROM live a
    JOIN live b ON b.database_name = a.database_name AND b.object_id = a.object_id AND b.index_id <> a.index_id
   WHERE a.key_set = b.key_set AND a.key_names[1] = b.key_names[1] AND a.key_names <> b.key_names
     AND b.filter_definition IS NOT DISTINCT FROM a.filter_definition
   ORDER BY a.database_name, a.object_id, a.index_id, b.index_id
), ld AS (
  SELECT l.database_name, l.object_id, l.index_id,
         count(*) OVER (PARTITION BY l.database_name, l.object_id, l.key_names[1]) - 1 AS others
    FROM live l
), j AS (   -- every judged index with what each rule found for it
  SELECT a.*, d.usage_days, d.judged, d.usage_reason, d.usage_since, d.readable_secondary, d.online_index_builds, d.read_at,
         CASE WHEN e.rn > 1 THEN e.keeper_id END AS ex_keeper, s.keeper_id AS sub_keeper,
         CASE WHEN kd.rn > 1 THEN kd.keeper_id END AS kd_keeper, oo.keeper_id AS oo_other, coalesce(ld.others, 0) AS lead_others,
         -- an 'unused' verdict needs a window and a table both over 7 days old at the read
         (d.judged AND a.index_type = 'NONCLUSTERED' AND NOT a.is_unique AND NOT a.is_constraint
          AND (a.table_created IS NULL OR a.table_created < d.read_at - interval '7 days')) AS usage_judged
    FROM i a
    JOIN d ON d.database_name = a.database_name
    LEFT JOIN ex e ON e.database_name = a.database_name AND e.object_id = a.object_id AND e.index_id = a.index_id
    LEFT JOIN sub s ON s.database_name = a.database_name AND s.object_id = a.object_id AND s.index_id = a.index_id
    LEFT JOIN kd ON kd.database_name = a.database_name AND kd.object_id = a.object_id AND kd.index_id = a.index_id
    LEFT JOIN oo ON oo.database_name = a.database_name AND oo.object_id = a.object_id AND oo.index_id = a.index_id
    LEFT JOIN ld ON ld.database_name = a.database_name AND ld.object_id = a.object_id AND ld.index_id = a.index_id
), r AS (
  SELECT j.*,
         CASE WHEN j.ex_keeper IS NOT NULL AND j.is_constraint THEN 'duplicate constraint'
              WHEN j.ex_keeper IS NOT NULL THEN 'exact duplicate'
              WHEN j.sub_keeper IS NOT NULL THEN 'key subset'
              WHEN j.kd_keeper IS NOT NULL AND NOT j.is_constraint THEN 'same keys, other includes'
              WHEN j.usage_judged AND j.reads = 0 AND j.writes >= 10000 THEN 'unused, written'
              WHEN j.usage_judged AND j.reads = 0 THEN 'unused'
              WHEN j.usage_judged AND j.writes >= 10000 AND j.reads < 10000 AND j.writes >= 10 * j.reads THEN 'written, seldom read'
              WHEN j.oo_other IS NOT NULL THEN 'same keys, another order'
              WHEN j.index_type = 'NONCLUSTERED' AND j.lead_others > 0 THEN 'same leading column'
         END AS rule0,
         coalesce(j.ex_keeper, j.sub_keeper, j.kd_keeper, j.oo_other) AS keeper_id
    FROM j
), o AS (
  SELECT r.*, k.index_name AS keeper_name, k.qindex AS keeper_q, k.is_constraint AS keeper_constraint, k.is_primary_key AS keeper_pk,
         -- the rule's name once the kept index is known: the same keys as a CONSTRAINT with other includes is its own rule
         CASE WHEN r.rule0 = 'same keys, other includes' AND k.is_constraint THEN 'constraint doubled' ELSE r.rule0 END AS rule,
         -- the kept index with this one's included columns merged in, when it lacks any of them
         CASE WHEN r.rule0 IN ('key subset', 'same keys, other includes') AND NOT k.is_constraint
                   AND NOT r.include_columns <@ (k.key_names || k.include_columns)
              THEN pgvigil.mssql_index_definition(k.index_type, k.is_unique, false, false, k.schema_name, k.table_name, k.index_name, k.key_columns,
                     ARRAY(SELECT DISTINCT c FROM unnest(k.include_columns || r.include_columns) c WHERE c <> ALL (k.key_names) ORDER BY c),
                     k.filter_definition, k.fill_factor, k.compression, r.online_index_builds, true) END AS merged,
         format('ALTER INDEX %s ON %s DISABLE;', r.qindex, r.qtable) AS disable_line,
         CASE WHEN r.usage_days IS NOT NULL
              THEN format('%s day(s) of usage counters, since %s', round(r.usage_days::numeric, 1), r.usage_reason) END AS win
    FROM r LEFT JOIN i k ON k.database_name = r.database_name AND k.object_id = r.object_id AND k.index_id = r.keeper_id
   WHERE r.rule0 IS NOT NULL
)
SELECT o.database_name, o.object_id, o.index_id, o.rule,
       CASE o.rule WHEN 'exact duplicate' THEN 'warning' WHEN 'unused, written' THEN 'warning' ELSE 'info' END AS severity,
       CASE o.rule
         WHEN 'exact duplicate' THEN format('the same key columns, included columns and filter as %s, which is kept (%s). Every write to the table maintains both.',
              o.keeper_name, CASE WHEN o.keeper_constraint THEN 'it backs a constraint' ELSE 'unique first, then the most read' END)
         WHEN 'duplicate constraint' THEN format('backs a constraint on the same key columns as %s: one of the two is redundant. For review: a foreign key may reference either.', o.keeper_name)
         WHEN 'key subset' THEN format('its key columns (%s) are the leading key columns of %s, which serves the same seeks%s.', array_to_string(o.key_columns, ', '), o.keeper_name,
              CASE WHEN o.merged IS NOT NULL THEN ' once this index''s included columns are merged into it' ELSE '' END)
         WHEN 'same keys, other includes' THEN format('the same key columns and filter as %s with other included columns: one index with both sets of included columns serves both.', o.keeper_name)
         WHEN 'constraint doubled' THEN format('the same key columns as the %s %s, plus included columns a constraint cannot hold: this index, made unique, enforces the same rule.',
              CASE WHEN o.keeper_pk THEN 'primary key' ELSE 'unique constraint' END, o.keeper_name)
         WHEN 'unused, written' THEN format('no seek, scan or lookup in %s, and %s writes.', o.win, o.writes)
         WHEN 'unused' THEN format('no seek, scan or lookup in %s (%s writes).', o.win, o.writes)
         WHEN 'written, seldom read' THEN format('%s writes against %s reads in %s: the index costs more than ten times what it is used for.', o.writes, o.reads, o.win)
         WHEN 'same keys, another order' THEN format('the same key columns as %s in another order: one of the two orders may serve every query.', o.keeper_name)
         ELSE format('shares its first key column with %s other index(es) of the table.', o.lead_others)
       END
       || CASE WHEN o.rule IN ('unused, written', 'unused', 'written, seldom read') THEN
            CASE WHEN o.usage_days < 14 THEN ' Under 14 days of counters: a weekly or monthly job may not have run yet.' ELSE '' END
            || CASE WHEN o.readable_secondary THEN ' Reads on the availability group''s readable secondary are not counted here.' ELSE '' END
            || CASE WHEN o.table_modified > o.read_at - interval '7 days'
                    THEN format(' The table was last altered %s UTC: SQL Server keeps no creation date for an index, and one created since then has had less time than the window.',
                                to_char(o.table_modified AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI')) ELSE '' END
          WHEN o.rule IN ('exact duplicate', 'key subset', 'same keys, other includes') AND o.usage_judged AND o.reads = 0
            THEN format(' It also had no read in %s.', o.win)
          ELSE '' END AS detail,
       CASE o.rule
         WHEN 'exact duplicate' THEN o.disable_line
         WHEN 'key subset' THEN coalesce(o.merged || E'\n', '') || o.disable_line
         WHEN 'same keys, other includes' THEN coalesce(o.merged || E'\n', '') || o.disable_line
         WHEN 'constraint doubled' THEN
           CASE WHEN NOT o.keeper_pk THEN
             pgvigil.mssql_index_definition(o.index_type, true, false, false, o.schema_name, o.table_name, o.index_name, o.key_columns, o.include_columns,
                                            o.filter_definition, o.fill_factor, o.compression, o.online_index_builds, true)
             || E'\n' || format('ALTER TABLE %s DROP CONSTRAINT %s;', o.qtable, o.keeper_q) END
         WHEN 'unused, written' THEN o.disable_line
         WHEN 'unused' THEN o.disable_line
       END AS script,
       o.keeper_name AS keeper
  FROM o
$$;

-- The indexes' findings, one row per database and kind, never one per index (the Indexes page lists them). A read
-- older than 13 hours raises nothing (the collection runs every six).
--   exact duplicate indexes (warning), unused indexes that are written (warning), unused indexes (info, with the
--   unused share of the database's judged nonclustered indexes), redundant indexes (info: key subsets, the same keys
--   with other includes, a constraint doubled), and
--   a high-value missing-index request (info): a request whose benefit per day of uptime is 100,000 or more, the
--   twenty with the most at most; a hint with its columns, never an index to create as it stands.
CREATE OR REPLACE VIEW pgvigil.mssql_indexes_findings AS
WITH v AS (
  SELECT n.instance_id, t.database_name, t.rule, x.size_kb, b.read_at, b.usage_days, b.usage_reason
    FROM (SELECT DISTINCT b.instance_id FROM pgvigil.mssql_index_db b WHERE b.read_at > now() - interval '13 hours') n
   CROSS JOIN LATERAL pgvigil.mssql_index_verdicts(n.instance_id) t
    JOIN pgvigil.mssql_index_db_status b ON b.instance_id = n.instance_id AND b.database_name = t.database_name
    JOIN pgvigil.mssql_index x ON x.instance_id = n.instance_id AND x.database_name = t.database_name AND x.object_id = t.object_id AND x.index_id = t.index_id
   WHERE b.read_at > now() - interval '13 hours'
), vc AS (
  SELECT v.*, CASE WHEN v.rule = 'exact duplicate' THEN 'exact duplicate indexes'
                   WHEN v.rule = 'unused, written' THEN 'unused indexes that are written'
                   WHEN v.rule = 'unused' THEN 'unused indexes'
                   WHEN v.rule IN ('key subset', 'same keys, other includes', 'constraint doubled') THEN 'redundant indexes' END AS check_name
    FROM v
), g AS (
  SELECT vc.instance_id, vc.database_name, vc.check_name, max(vc.read_at) AS read_at, max(vc.usage_days) AS usage_days,
         max(vc.usage_reason) AS usage_reason, count(*) AS n, coalesce(sum(vc.size_kb), 0) AS size_kb
    FROM vc
   GROUP BY vc.instance_id, vc.database_name, vc.check_name
)
SELECT g.instance_id, CASE WHEN g.check_name IN ('exact duplicate indexes', 'unused indexes that are written') THEN 'warning' ELSE 'info' END::text AS severity,
       g.check_name::text, g.database_name::text AS object, g.read_at AS at,
       (CASE g.check_name
          WHEN 'exact duplicate indexes' THEN format('%s index(es), %s MB, have the same key columns, included columns and filter as another index of their table: every write maintains both.', g.n, round(g.size_kb / 1024.0, 1))
          WHEN 'unused indexes that are written' THEN format('%s nonclustered index(es), %s MB, had no read in the %s day(s) since %s and 10,000 or more writes each.', g.n, round(g.size_kb / 1024.0, 1), round(g.usage_days::numeric, 1), g.usage_reason)
          WHEN 'unused indexes' THEN format('%s nonclustered index(es), %s MB, had no read in the %s day(s) since %s.', g.n, round(g.size_kb / 1024.0, 1), round(g.usage_days::numeric, 1), g.usage_reason)
          ELSE format('%s index(es), %s MB, are covered by another index of their table (a key subset, the same keys with other included columns, or a unique constraint doubled).', g.n, round(g.size_kb / 1024.0, 1))
        END || ' The Indexes page lists them with the text to review.')::text AS detail
  FROM g
 WHERE g.check_name IS NOT NULL
UNION ALL
SELECT m.instance_id, 'info', 'a high-value missing-index request', coalesce(m.database_name, 'database ' || m.database_id) || ': ' || coalesce(m.table_ref, 'object ' || m.object_id),
       m.snapshot_at,
       format('the optimizer asked %s time(s) for an index on equality (%s), inequality (%s), included (%s): benefit %s a day of uptime (cost %s, expected saving %s %%). '
              || 'A hint from one query shape: it knows nothing of the indexes that exist or of the other requests.',
              coalesce(m.user_seeks, 0) + coalesce(m.user_scans, 0), coalesce(m.equality_columns, 'none'), coalesce(m.inequality_columns, 'none'),
              coalesce(m.included_columns, 'none'), round(u.per_day::numeric), round(m.avg_cost::numeric, 2), round(m.avg_impact::numeric, 1))
  FROM pgvigil.mssql_missing_index m
 CROSS JOIN LATERAL (SELECT m.benefit / greatest(extract(epoch FROM m.snapshot_at - m.server_start) / 86400.0, 1) AS per_day) u
 WHERE m.snapshot_at > now() - interval '13 hours' AND m.ord <= 20 AND u.per_day >= 100000;

-- ---------------------------------------------------------------------------------------------------------------
-- the statistics
-- ---------------------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_stats_db (
  instance_id            int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name          text NOT NULL,
  database_id            int,
  snapshot_at            timestamptz NOT NULL,   -- the read that last listed the database
  read_at                timestamptz,            -- the read that last read its statistics; NULL = never
  database_state         text,
  note                   text,
  statistics             bigint,                 -- every statistic of a user table or an indexed view
  statistics_with_props  bigint,                 -- those whose properties the login may read
  never_updated          bigint,
  oldest_update          timestamptz,
  newest_update          timestamptz,
  avg_modified_pct       float8,                 -- the average share of rows modified since the last update
  listed                 int,                    -- the rows in mssql_stat
  capped                 boolean NOT NULL DEFAULT false,
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_stat (
  instance_id           int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name         text NOT NULL,
  object_id             bigint NOT NULL,
  stats_id              int NOT NULL,
  database_id           int,
  schema_name           text,
  table_name            text,
  stats_name            text,
  stat_columns          text[] NOT NULL DEFAULT '{}',   -- each name quoted
  auto_created          boolean NOT NULL DEFAULT false,
  user_created          boolean NOT NULL DEFAULT false,
  no_recompute          boolean NOT NULL DEFAULT false,
  has_filter            boolean NOT NULL DEFAULT false,
  filter_definition     text,
  is_incremental        boolean NOT NULL DEFAULT false,
  partitioned           boolean NOT NULL DEFAULT false, -- the table has more than one partition
  props_read            boolean NOT NULL DEFAULT false, -- sys.dm_db_stats_properties answered for it
  last_updated          timestamptz,
  row_count             bigint,
  rows_sampled          bigint,                 -- NULL when props_read is false
  modifications         bigint,
  steps                 int,
  persisted_sample_pct  float8,                 -- 0 or NULL: none
  snapshot_at           timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, object_id, stats_id)
);

-- payload, one call per batch, every batch with the run's {kind:'state', server_utc, server_start}:
--   a database's batch: one {kind:'db', database_id, database_name, database_state, read, note, statistics,
--     statistics_with_props, never_updated, oldest_update, newest_update, avg_modified_pct, listed, capped} and, when
--     read is true, its 'stat' rows (mssql_stat's columns; stat_columns as an array);
--   the run's last batch: {kind:'databases', names:[...]}.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_stats(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s     jsonb := pgvigil.mssql_perf_check('import_mssql_stats', p_instance_id, p_payload);
  v_db    jsonb;
  v_name  text;
  v_read  boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_stats'), p_instance_id);
  FOR v_db IN SELECT r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND r->>'database_name' IS NOT NULL LOOP
    v_name := v_db->>'database_name';
    v_read := coalesce((v_db->>'read')::boolean, false);
    CONTINUE WHEN EXISTS (SELECT 1 FROM pgvigil.mssql_stats_db b
                           WHERE b.instance_id = p_instance_id AND b.database_name = v_name AND b.snapshot_at > p_snapshot_at);
    INSERT INTO pgvigil.mssql_stats_db AS b (instance_id, database_name, database_id, snapshot_at, read_at, database_state, note, statistics,
        statistics_with_props, never_updated, oldest_update, newest_update, avg_modified_pct, listed, capped)
    VALUES (p_instance_id, v_name, (v_db->>'database_id')::int, p_snapshot_at, CASE WHEN v_read THEN p_snapshot_at END, v_db->>'database_state',
            v_db->>'note', (v_db->>'statistics')::bigint, (v_db->>'statistics_with_props')::bigint, (v_db->>'never_updated')::bigint,
            (v_db->>'oldest_update')::timestamptz, (v_db->>'newest_update')::timestamptz, (v_db->>'avg_modified_pct')::float8,
            (v_db->>'listed')::int, coalesce((v_db->>'capped')::boolean, false))
    ON CONFLICT (instance_id, database_name) DO UPDATE SET
        database_id = EXCLUDED.database_id, snapshot_at = EXCLUDED.snapshot_at, read_at = coalesce(EXCLUDED.read_at, b.read_at),
        database_state = EXCLUDED.database_state, note = EXCLUDED.note,
        statistics = CASE WHEN v_read THEN EXCLUDED.statistics ELSE b.statistics END,
        statistics_with_props = CASE WHEN v_read THEN EXCLUDED.statistics_with_props ELSE b.statistics_with_props END,
        never_updated = CASE WHEN v_read THEN EXCLUDED.never_updated ELSE b.never_updated END,
        oldest_update = CASE WHEN v_read THEN EXCLUDED.oldest_update ELSE b.oldest_update END,
        newest_update = CASE WHEN v_read THEN EXCLUDED.newest_update ELSE b.newest_update END,
        avg_modified_pct = CASE WHEN v_read THEN EXCLUDED.avg_modified_pct ELSE b.avg_modified_pct END,
        listed = CASE WHEN v_read THEN EXCLUDED.listed ELSE b.listed END,
        capped = CASE WHEN v_read THEN EXCLUDED.capped ELSE b.capped END;
    IF v_read THEN
      DELETE FROM pgvigil.mssql_stat WHERE instance_id = p_instance_id AND database_name = v_name;
      INSERT INTO pgvigil.mssql_stat (instance_id, database_name, object_id, stats_id, database_id, schema_name, table_name, stats_name, stat_columns,
          auto_created, user_created, no_recompute, has_filter, filter_definition, is_incremental, partitioned, props_read, last_updated, row_count,
          rows_sampled, modifications, steps, persisted_sample_pct, snapshot_at)
      SELECT DISTINCT ON ((r->>'object_id')::bigint, (r->>'stats_id')::int)
             p_instance_id, v_name, (r->>'object_id')::bigint, (r->>'stats_id')::int, (r->>'database_id')::int, r->>'schema_name', r->>'table_name',
             r->>'stats_name',
             CASE WHEN jsonb_typeof(r->'stat_columns') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(r->'stat_columns')) ELSE '{}' END,
             coalesce((r->>'auto_created')::int, 0) = 1, coalesce((r->>'user_created')::int, 0) = 1, coalesce((r->>'no_recompute')::int, 0) = 1,
             coalesce((r->>'has_filter')::int, 0) = 1, r->>'filter_definition', coalesce((r->>'is_incremental')::int, 0) = 1,
             coalesce((r->>'partitioned')::int, 0) = 1, coalesce((r->>'props_read')::int, 0) = 1, (r->>'last_updated')::timestamptz,
             (r->>'row_count')::bigint, (r->>'rows_sampled')::bigint, (r->>'modifications')::bigint, (r->>'steps')::int,
             (r->>'persisted_sample_pct')::float8, p_snapshot_at
        FROM jsonb_array_elements(p_payload) r
       WHERE r->>'kind' = 'stat' AND r->>'database_name' = v_name AND r->>'object_id' IS NOT NULL AND r->>'stats_id' IS NOT NULL
       ORDER BY 3, 4;
    END IF;
  END LOOP;
  SELECT r INTO v_db FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'databases' AND jsonb_typeof(r->'names') = 'array' LIMIT 1;
  IF v_db IS NOT NULL THEN
    DELETE FROM pgvigil.mssql_stat x
     WHERE x.instance_id = p_instance_id
       AND EXISTS (SELECT 1 FROM pgvigil.mssql_stats_db b
                    WHERE b.instance_id = x.instance_id AND b.database_name = x.database_name AND b.snapshot_at < p_snapshot_at
                      AND NOT (v_db->'names') ? b.database_name);
    DELETE FROM pgvigil.mssql_stats_db b
     WHERE b.instance_id = p_instance_id AND b.snapshot_at < p_snapshot_at AND NOT (v_db->'names') ? b.database_name;
  END IF;
END $$;

-- One row per stored statistic with its judgement, as of the read that stored it:
--   stale           (warning) not updated in 30 days, 10 % or more of its rows modified since, on 10,000 rows or more.
--   low sample      (info) built on under 10 % of 10,000 to 1,000,000 rows, or under 1 % of more. Judged only where
--                   the sample is known (props_read).
--   persisted sample (info) a persisted sample rate other than 100 %: every later update samples at that rate.
--   NORECOMPUTE     (info) the statistic is never updated automatically.
--   filtered        (info) a filter: its modification counter counts the whole table's changes, so it goes stale
--                   unseen.
--   not incremental (info) on a partitioned table: an update reads every partition.
-- flags lists what applies, the gravest first; severity is the gravest flag's.
CREATE OR REPLACE VIEW pgvigil.mssql_stat_status AS
SELECT s.*, f.modified_pct, f.sampled_pct, f.flags,
       CASE WHEN 'stale' = ANY (f.flags) THEN 'warning' WHEN cardinality(f.flags) > 0 THEN 'info' END AS severity
  FROM pgvigil.mssql_stat s
 CROSS JOIN LATERAL (
   SELECT round((100.0 * s.modifications / nullif(s.row_count, 0))::numeric, 1) AS modified_pct,
          CASE WHEN s.props_read THEN round((100.0 * s.rows_sampled / nullif(s.row_count, 0))::numeric, 2) END AS sampled_pct,
          array_remove(ARRAY[
            CASE WHEN s.last_updated < s.snapshot_at - interval '30 days' AND s.row_count >= 10000 AND s.modifications >= 0.10 * s.row_count THEN 'stale' END,
            CASE WHEN s.props_read AND s.rows_sampled IS NOT NULL
                      AND ((s.row_count BETWEEN 10000 AND 1000000 AND s.rows_sampled < 0.10 * s.row_count)
                           OR (s.row_count > 1000000 AND s.rows_sampled < 0.01 * s.row_count)) THEN 'low sample' END,
            CASE WHEN s.persisted_sample_pct > 0 AND s.persisted_sample_pct <> 100 THEN 'persisted sample' END,
            CASE WHEN s.no_recompute THEN 'NORECOMPUTE' END,
            CASE WHEN s.has_filter THEN 'filtered' END,
            CASE WHEN s.partitioned AND NOT s.is_incremental THEN 'not incremental' END], NULL) AS flags) f;

-- The statistics' findings, one row per database and kind. A read older than 13 hours raises nothing.
CREATE OR REPLACE VIEW pgvigil.mssql_stats_findings AS
SELECT t.instance_id, 'warning'::text AS severity, 'stale statistics'::text AS check_name, t.database_name::text AS object, max(t.snapshot_at) AS at,
       format('%s statistic(s) on 10,000 or more rows were not updated in 30 days although 10 %% or more of their rows changed; the most modified: %s.%s.%s (%s %% of %s rows, last updated %s UTC). '
              || 'The Indexes page lists them.',
              count(*), (array_agg(t.schema_name ORDER BY t.modifications DESC))[1], (array_agg(t.table_name ORDER BY t.modifications DESC))[1],
              (array_agg(t.stats_name ORDER BY t.modifications DESC))[1], (array_agg(t.modified_pct ORDER BY t.modifications DESC))[1],
              (array_agg(t.row_count ORDER BY t.modifications DESC))[1],
              to_char((array_agg(t.last_updated ORDER BY t.modifications DESC))[1] AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'))::text AS detail
  FROM pgvigil.mssql_stat_status t
 WHERE 'stale' = ANY (t.flags) AND t.snapshot_at > now() - interval '13 hours'
 GROUP BY t.instance_id, t.database_name
UNION ALL
SELECT t.instance_id, 'info', 'statistics with NORECOMPUTE', t.database_name, max(t.snapshot_at),
       format('%s statistic(s) were created or updated WITH NORECOMPUTE: SQL Server never updates them by itself, only a job does.', count(*))
  FROM pgvigil.mssql_stat_status t
 WHERE 'NORECOMPUTE' = ANY (t.flags) AND t.snapshot_at > now() - interval '13 hours'
 GROUP BY t.instance_id, t.database_name
UNION ALL
SELECT t.instance_id, 'info', 'statistics with a low sample rate', t.database_name, max(t.snapshot_at),
       format('%s statistic(s) were built on under 10 %% of their rows (under 1 %% above a million rows).', count(*))
  FROM pgvigil.mssql_stat_status t
 WHERE 'low sample' = ANY (t.flags) AND t.snapshot_at > now() - interval '13 hours'
 GROUP BY t.instance_id, t.database_name;

-- What purge()'s month-partition list does not cover: the statement texts no read has carried within the window,
-- and everything of an instance or a database not read within it (its next read sets it again). Returns the rows it
-- removed, as purge() sums them.
CREATE OR REPLACE FUNCTION pgvigil.mssql_plancache_purge(p_days int DEFAULT 30)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n       bigint := 0;
  v_rows  bigint;
  v_old   timestamptz := now() - make_interval(days => p_days);
BEGIN
  DELETE FROM pgvigil.mssql_pc_text WHERE seen_at < v_old;
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_pc_last l
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_pc_state s WHERE s.instance_id = l.instance_id AND s.snapshot_at >= v_old);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_pc_state WHERE snapshot_at < v_old;
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_pc_database WHERE snapshot_at < v_old;
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_pc_health WHERE snapshot_at < v_old;
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_pc_list WHERE snapshot_at < v_old;
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_pc_health_state WHERE snapshot_at < v_old;
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_index x
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_index_db b
                      WHERE b.instance_id = x.instance_id AND b.database_name = x.database_name AND b.snapshot_at >= v_old);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_index_db WHERE snapshot_at < v_old;
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_missing_index WHERE snapshot_at < v_old;
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_stat x
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_stats_db b
                      WHERE b.instance_id = x.instance_id AND b.database_name = x.database_name AND b.snapshot_at >= v_old);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_stats_db WHERE snapshot_at < v_old;
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  RETURN n;
END $$;
