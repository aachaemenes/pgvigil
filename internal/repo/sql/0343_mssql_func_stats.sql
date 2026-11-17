-- 0343: what each scalar function and each trigger did (D467). The collection mssql_funcstats sends, every five
-- minutes, the rows of sys.dm_exec_function_stats (kind 'function': scalar functions that ran without inlining;
-- the server lists no table-valued function and no scalar function it inlined) and of sys.dm_exec_trigger_stats
-- (kind 'trigger'), one per cached plan with its counters since the plan was cached and its extremes
-- (internal/mssql/funcstats.go). The import keeps the last counters per plan and stores what one interval added,
-- summed per object - 0084's rule for the procedures, with 0126's for a figure a server may lack:
--   mssql_func_state    per instance: the last read's clocks, whether it was cut, the kinds it read
--   mssql_func_last     per cached plan: the counters as last read (kind, plan handle, cached time)
--   mssql_func_sample   per read, kind and object: the interval's counters and the extremes over the plans that ran
--   mssql_func_read     per read: the interval and how many objects of each kind ran
--   mssql_func_inline   per scalar function: sys.sql_modules' is_inlineable and inline_type as last read (2019 on)
-- A kind the read did not hold (the server has no such view) leaves that kind's last counters as they were.
--
-- Lock order (0126's): the partitioned parents by name, then the last-read tables.
--
-- THE JOIN-FILE RULE: 0343 sorts after the join file and creates only its own objects. Its lines for the join are in
-- scripts/D467-join-lines.sql: mssql_func_read and mssql_func_sample among purge()'s month-partition parents, and
-- mssql_func_purge (the state, last and inline rows of an instance no longer read) in purge() with its owner-only
-- entry. Until a join file carries them those months and rows are not dropped.
SET LOCAL lock_timeout = '20s';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_func_state (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  server_utc    timestamptz NOT NULL,
  server_start  timestamptz,
  server_local  timestamp,               -- the server's own clock at the read, as the DMVs' cached_time is written
  capped        boolean NOT NULL DEFAULT false,   -- the read was cut at the collector's row limit: the state is not every plan
  kinds         text[] NOT NULL DEFAULT '{}'      -- the views the read held: 'function', 'trigger'
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_func_last (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  kind             text NOT NULL,          -- 'function' | 'trigger'
  plan_handle      text NOT NULL,          -- the cached plan, as 0x text: the server counts per plan
  cached_time      timestamp NOT NULL,     -- when the plan entered the cache, the server's own clock
  database_id      int NOT NULL,
  object_id        bigint NOT NULL,
  execution_count  bigint NOT NULL,
  worker_us        bigint NOT NULL,
  elapsed_us       bigint NOT NULL,
  logical_reads    bigint NOT NULL,
  physical_reads   bigint NOT NULL,
  logical_writes   bigint NOT NULL,
  spills           bigint,                 -- NULL: the view has no such column (the functions' never has)
  PRIMARY KEY (instance_id, kind, plan_handle, cached_time)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_func_sample (
  instance_id        int NOT NULL,
  snapshot_at        timestamptz NOT NULL,
  kind               text NOT NULL,
  database_id        int NOT NULL,
  object_id          bigint NOT NULL,
  database_name      text,
  schema_name        text,
  object_name        text,                 -- NULL: not read (the object is gone, the login cannot see it, or a lock)
  type_desc          text,
  trigger_scope      text,                 -- a DDL or logon trigger: 'server' or 'database' (named from its catalog)
  executions         bigint NOT NULL,
  cpu_us             bigint NOT NULL,
  duration_us        bigint NOT NULL,
  logical_reads      bigint NOT NULL,
  physical_reads     bigint NOT NULL,
  logical_writes     bigint NOT NULL,
  spills             bigint,               -- NULL: not read on this view or version, or a plan without the figure
  -- the smallest and the largest single run of the plans that ran in the interval, each since its cache entry
  min_cpu_us bigint, max_cpu_us bigint, min_duration_us bigint, max_duration_us bigint,
  min_logical_reads bigint, max_logical_reads bigint, min_physical_reads bigint, max_physical_reads bigint,
  min_logical_writes bigint, max_logical_writes bigint, min_spills bigint, max_spills bigint,
  interval_secs      real NOT NULL         -- between this read and the one before, by the server's own clock
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_func_read (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  interval_secs  real NOT NULL,
  functions      int NOT NULL,             -- the scalar functions that ran in the interval
  triggers       int NOT NULL              -- the triggers that ran in the interval
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_func_inline (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_id    int NOT NULL,
  object_id      bigint NOT NULL,
  is_inlineable  boolean,                  -- sys.sql_modules: the definition's constructs allow inlining
  inline_type    boolean,                  -- sys.sql_modules: inlining is on for the function (INLINE = ON)
  read_at        timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_id, object_id)
);

-- payload: a 'state' row (server_utc, server_start, server_local, capped, kinds: the views read), 'function' and
-- 'trigger' rows (plan_handle, cached_time, database_id, object_id, the names, type_desc, trigger_scope,
-- execution_count, worker_us, elapsed_us, logical_reads, physical_reads, logical_writes, spills and the 12
-- extremes; NULL: the view has no such column), 'inline' rows (database_id, object_id, is_inlineable,
-- inline_type: one database's scalar functions as sys.sql_modules holds them) and 'collector_error' notes.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_funcstats(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s        jsonb := pgvigil.mssql_perf_check('import_mssql_funcstats', p_instance_id, p_payload);
  v_now      timestamptz := (v_s->>'server_utc')::timestamptz;
  v_start    timestamptz := (v_s->>'server_start')::timestamptz;
  v_local    timestamp := (v_s->>'server_local')::timestamp;
  v_capped   boolean := coalesce((v_s->>'capped')::boolean, false);
  v_kinds    text[] := ARRAY(SELECT jsonb_array_elements_text(coalesce(v_s->'kinds', '[]'::jsonb)));
  v_prev     pgvigil.mssql_func_state;
  v_secs     real;
  v_restart  boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_funcstats'), p_instance_id);
  SELECT * INTO v_prev FROM pgvigil.mssql_func_state WHERE instance_id = p_instance_id;
  IF FOUND AND (v_prev.server_utc >= v_now OR v_prev.snapshot_at >= p_snapshot_at) THEN
    RETURN;  -- an older read arriving late (or the same read again): the counters stored are newer
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_func_in (
    kind text, plan_handle text, cached_time timestamp, database_id int, object_id bigint, database_name text, schema_name text,
    object_name text, type_desc text, trigger_scope text, execution_count bigint, worker_us bigint, elapsed_us bigint,
    logical_reads bigint, physical_reads bigint, logical_writes bigint, spills bigint,
    min_cpu_us bigint, max_cpu_us bigint, min_duration_us bigint, max_duration_us bigint, min_logical_reads bigint,
    max_logical_reads bigint, min_physical_reads bigint, max_physical_reads bigint, min_logical_writes bigint,
    max_logical_writes bigint, min_spills bigint, max_spills bigint,
    PRIMARY KEY (kind, plan_handle, cached_time)) ON COMMIT DROP;
  TRUNCATE pgv_mssql_func_in;
  -- a row of a kind the state does not list is not this read's (an inconsistent payload): left out
  INSERT INTO pgv_mssql_func_in
  SELECT DISTINCT ON (r->>'kind', r->>'plan_handle', (r->>'cached_time')::timestamp)
         r->>'kind', r->>'plan_handle', (r->>'cached_time')::timestamp, (r->>'database_id')::int, (r->>'object_id')::bigint,
         r->>'database_name', r->>'schema_name', r->>'object_name', r->>'type_desc', r->>'trigger_scope',
         (r->>'execution_count')::bigint, coalesce((r->>'worker_us')::bigint, 0), coalesce((r->>'elapsed_us')::bigint, 0),
         coalesce((r->>'logical_reads')::bigint, 0), coalesce((r->>'physical_reads')::bigint, 0),
         coalesce((r->>'logical_writes')::bigint, 0), (r->>'spills')::bigint,
         (r->>'min_worker_us')::bigint, (r->>'max_worker_us')::bigint, (r->>'min_elapsed_us')::bigint, (r->>'max_elapsed_us')::bigint,
         (r->>'min_logical_reads')::bigint, (r->>'max_logical_reads')::bigint, (r->>'min_physical_reads')::bigint,
         (r->>'max_physical_reads')::bigint, (r->>'min_logical_writes')::bigint, (r->>'max_logical_writes')::bigint,
         (r->>'min_spills')::bigint, (r->>'max_spills')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' IN ('function', 'trigger') AND r->>'kind' = ANY (v_kinds)
     AND r->>'plan_handle' IS NOT NULL AND r->>'cached_time' IS NOT NULL AND r->>'database_id' IS NOT NULL
     AND r->>'object_id' IS NOT NULL AND r->>'execution_count' IS NOT NULL
   ORDER BY 1, 2, 3;

  IF v_prev.instance_id IS NOT NULL AND v_now > v_prev.server_utc THEN
    v_secs := extract(epoch FROM v_now - v_prev.server_utc);
    v_restart := NOT pgvigil.mssql_same_run(v_prev.server_start, v_start);
    -- the parents in name order, before anything of this instance is written
    PERFORM pgvigil.ensure_month_partition('mssql_func_read', p_snapshot_at);
    PERFORM pgvigil.ensure_month_partition('mssql_func_sample', p_snapshot_at);
    LOCK TABLE ONLY pgvigil.mssql_func_read, ONLY pgvigil.mssql_func_sample IN ROW EXCLUSIVE MODE;
    -- a restart since the read before: every plan in the cache was cached after it, and the old counters mean nothing
    IF v_restart THEN
      DELETE FROM pgvigil.mssql_func_last WHERE instance_id = p_instance_id;
    END IF;
    DELETE FROM pgvigil.mssql_func_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    DELETE FROM pgvigil.mssql_func_read WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    INSERT INTO pgvigil.mssql_func_sample (instance_id, snapshot_at, kind, database_id, object_id, database_name, schema_name, object_name,
        type_desc, trigger_scope, executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, spills,
        min_cpu_us, max_cpu_us, min_duration_us, max_duration_us, min_logical_reads, max_logical_reads, min_physical_reads,
        max_physical_reads, min_logical_writes, max_logical_writes, min_spills, max_spills, interval_secs)
    SELECT p_instance_id, p_snapshot_at, d.kind, d.database_id, d.object_id, max(d.database_name), max(d.schema_name), max(d.object_name),
           max(d.type_desc), max(d.trigger_scope), sum(d.executions), sum(d.cpu_us), sum(d.duration_us), sum(d.logical_reads),
           sum(d.physical_reads), sum(d.logical_writes),
           -- one plan of the object without a known figure makes the object's interval unknown, never a part sum
           CASE WHEN count(d.spills) = count(*) THEN sum(d.spills) END,
           min(d.min_cpu_us), max(d.max_cpu_us), min(d.min_duration_us), max(d.max_duration_us), min(d.min_logical_reads),
           max(d.max_logical_reads), min(d.min_physical_reads), max(d.max_physical_reads), min(d.min_logical_writes),
           max(d.max_logical_writes), min(d.min_spills), max(d.max_spills), v_secs
      FROM (SELECT f.*,
                   CASE g.mode WHEN 'diff' THEN f.execution_count - l.execution_count WHEN 'whole' THEN f.execution_count ELSE 0 END AS executions,
                   CASE g.mode WHEN 'diff' THEN greatest(f.worker_us - l.worker_us, 0) WHEN 'whole' THEN f.worker_us ELSE 0 END AS cpu_us,
                   CASE g.mode WHEN 'diff' THEN greatest(f.elapsed_us - l.elapsed_us, 0) WHEN 'whole' THEN f.elapsed_us ELSE 0 END AS duration_us,
                   CASE g.mode WHEN 'diff' THEN greatest(f.logical_reads - l.logical_reads, 0) WHEN 'whole' THEN f.logical_reads ELSE 0 END AS logical_reads_d,
                   CASE g.mode WHEN 'diff' THEN greatest(f.physical_reads - l.physical_reads, 0) WHEN 'whole' THEN f.physical_reads ELSE 0 END AS physical_reads_d,
                   CASE g.mode WHEN 'diff' THEN greatest(f.logical_writes - l.logical_writes, 0) WHEN 'whole' THEN f.logical_writes ELSE 0 END AS logical_writes_d,
                   -- the spills: a difference only where the read before had the figure too; whole as the other counters
                   CASE g.mode WHEN 'diff' THEN CASE WHEN f.spills IS NOT NULL AND l.spills IS NOT NULL THEN greatest(f.spills - l.spills, 0) END
                               WHEN 'whole' THEN f.spills ELSE 0 END AS spills_d
              FROM pgv_mssql_func_in f
              LEFT JOIN pgvigil.mssql_func_last l ON l.instance_id = p_instance_id AND l.kind = f.kind AND l.plan_handle = f.plan_handle
                                                 AND l.cached_time = f.cached_time
                   -- diff: the plan was in the read before and grew. whole: it counts lower than before; or it was
                   -- not in the read before, and that read was complete or the server restarted since; or that read
                   -- was cut and the plan was cached at or after its clock (a cut read that did not hold this kind
                   -- falls under the same test). none: not in a cut read although cached earlier.
             CROSS JOIN LATERAL (SELECT CASE WHEN l.instance_id IS NOT NULL AND f.execution_count >= l.execution_count THEN 'diff'
                                             WHEN l.instance_id IS NOT NULL OR v_restart OR NOT v_prev.capped THEN 'whole'
                                             WHEN f.cached_time >= v_prev.server_local THEN 'whole'
                                             ELSE 'none' END AS mode) g) d0
     CROSS JOIN LATERAL (SELECT d0.kind, d0.database_id, d0.object_id, d0.database_name, d0.schema_name, d0.object_name, d0.type_desc,
                                d0.trigger_scope, d0.executions, d0.cpu_us, d0.duration_us, d0.logical_reads_d AS logical_reads,
                                d0.physical_reads_d AS physical_reads, d0.logical_writes_d AS logical_writes, d0.spills_d AS spills,
                                d0.min_cpu_us, d0.max_cpu_us, d0.min_duration_us, d0.max_duration_us, d0.min_logical_reads,
                                d0.max_logical_reads, d0.min_physical_reads, d0.max_physical_reads, d0.min_logical_writes,
                                d0.max_logical_writes, d0.min_spills, d0.max_spills) d
     WHERE d.executions > 0
     GROUP BY d.kind, d.database_id, d.object_id;
    INSERT INTO pgvigil.mssql_func_read (instance_id, snapshot_at, interval_secs, functions, triggers)
    SELECT p_instance_id, p_snapshot_at, v_secs,
           (SELECT count(*) FROM pgvigil.mssql_func_sample s WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at AND s.kind = 'function'),
           (SELECT count(*) FROM pgvigil.mssql_func_sample s WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at AND s.kind = 'trigger');
  END IF;

  -- the state is this read's plans, kind by kind: a kind the read held loses the plans the cache dropped; a kind it
  -- did not hold keeps its rows as they were. Only counters that moved are rewritten.
  DELETE FROM pgvigil.mssql_func_last l
   WHERE l.instance_id = p_instance_id AND l.kind = ANY (v_kinds)
     AND NOT EXISTS (SELECT 1 FROM pgv_mssql_func_in f WHERE f.kind = l.kind AND f.plan_handle = l.plan_handle AND f.cached_time = l.cached_time);
  INSERT INTO pgvigil.mssql_func_last AS l (instance_id, kind, plan_handle, cached_time, database_id, object_id, execution_count, worker_us,
      elapsed_us, logical_reads, physical_reads, logical_writes, spills)
  SELECT p_instance_id, f.kind, f.plan_handle, f.cached_time, f.database_id, f.object_id, f.execution_count, f.worker_us, f.elapsed_us,
         f.logical_reads, f.physical_reads, f.logical_writes, f.spills
    FROM pgv_mssql_func_in f
  ON CONFLICT (instance_id, kind, plan_handle, cached_time) DO UPDATE SET
      execution_count = EXCLUDED.execution_count, worker_us = EXCLUDED.worker_us, elapsed_us = EXCLUDED.elapsed_us,
      logical_reads = EXCLUDED.logical_reads, physical_reads = EXCLUDED.physical_reads, logical_writes = EXCLUDED.logical_writes,
      spills = EXCLUDED.spills
   WHERE (l.execution_count, l.worker_us, l.elapsed_us, l.logical_reads, l.physical_reads, l.logical_writes, l.spills)
         IS DISTINCT FROM (EXCLUDED.execution_count, EXCLUDED.worker_us, EXCLUDED.elapsed_us, EXCLUDED.logical_reads,
                           EXCLUDED.physical_reads, EXCLUDED.logical_writes, EXCLUDED.spills);

  -- inlineability: each database the read asked replaces its rows (a database not asked this time keeps its own)
  DELETE FROM pgvigil.mssql_func_inline i
   WHERE i.instance_id = p_instance_id
     AND i.database_id IN (SELECT DISTINCT (r->>'database_id')::int FROM jsonb_array_elements(p_payload) r
                            WHERE r->>'kind' = 'inline_read' AND r->>'database_id' IS NOT NULL);
  INSERT INTO pgvigil.mssql_func_inline (instance_id, database_id, object_id, is_inlineable, inline_type, read_at)
  SELECT DISTINCT ON ((r->>'database_id')::int, (r->>'object_id')::bigint)
         p_instance_id, (r->>'database_id')::int, (r->>'object_id')::bigint, (r->>'is_inlineable')::boolean,
         (r->>'inline_type')::boolean, v_now
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'inline' AND r->>'database_id' IS NOT NULL AND r->>'object_id' IS NOT NULL
   ORDER BY (r->>'database_id')::int, (r->>'object_id')::bigint
  ON CONFLICT (instance_id, database_id, object_id) DO UPDATE SET
      is_inlineable = EXCLUDED.is_inlineable, inline_type = EXCLUDED.inline_type, read_at = EXCLUDED.read_at;

  INSERT INTO pgvigil.mssql_func_state AS s (instance_id, snapshot_at, server_utc, server_start, server_local, capped, kinds)
  VALUES (p_instance_id, p_snapshot_at, v_now, v_start, v_local, v_capped, v_kinds)
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, server_utc = EXCLUDED.server_utc,
      server_start = EXCLUDED.server_start, server_local = EXCLUDED.server_local, capped = EXCLUDED.capped, kinds = EXCLUDED.kinds;
END $$;

-- What purge()'s month-partition list does not cover: the counters and the inlineability of an instance not read
-- within the window (its next read sets them again). Returns the rows it removed, as purge() sums them.
CREATE OR REPLACE FUNCTION pgvigil.mssql_func_purge(p_days int DEFAULT 30)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n bigint := 0;
  k bigint;
BEGIN
  DELETE FROM pgvigil.mssql_func_last l
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_func_state s
                      WHERE s.instance_id = l.instance_id AND s.snapshot_at >= now() - make_interval(days => p_days));
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  DELETE FROM pgvigil.mssql_func_inline i
   WHERE i.read_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  DELETE FROM pgvigil.mssql_func_state WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  RETURN n;
END $$;
