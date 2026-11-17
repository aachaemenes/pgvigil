-- 0342: the plan cache's and the procedures' extremes (D421). Beside their counters, mssql_plancache and
-- mssql_procstats send what the server keeps per cached statement and per cached procedure plan as the smallest and
-- the largest single run since its compile, the plan's generation and its CLR time (internal/mssql/plancache.go
-- planCacheSpread, procstats.go procStatsSpread). An extreme is not a counter: nothing is subtracted from it, and a
-- statement recompile starts it again (the server gives the statement a later creation_time, which is in 0092's key).
--   mssql_pc_extreme                per read and query key, for every key mssql_pc_sample holds in that interval: the
--                                   extremes over the plans of the key that ran in the interval, the plans' counts
--                                   since their compile, the interval's CLR time and its own executions, CPU and
--                                   seconds. mssql_pc_sample is not widened: its readers are measured at its width.
--   mssql_pc_last.clr_us            the CLR time as last read: the next interval's difference starts from it
--   mssql_proc_sample               gains the procedures' 12 extremes, over the plans that ran in the interval
--   mssql_pc_diagnostics()          sp_QuickieCache's row-count variance, parameter-sniffing and wasteful-grant rules
--                                   on one statement's figures since its compile, as words (the Plan cache page)
--   mssql_plancache_grant_findings  one finding per instance: statements that ran in the last 3 hours with a memory
--                                   grant over 1 MB of which under 10 % was used (sp_QuickieCache's Wasteful grant)
-- The imports are 0092's import_mssql_plancache_0092 (0126's wrapper import_mssql_plancache calls it, unchanged) and
-- 0126's import_mssql_procstats, each word for word with D421's arms between the marker lines '-- [D421' and
-- '-- D421]' (internal/repo/mssql_cache_spread_test.go takes the arms out and compares the rest with the base).
--
-- Lock order (0126's): the partitioned parents by name, then the last-read tables. The imports lock
-- mssql_pc_extreme before mssql_pc_read and mssql_pc_sample, the order of their names.
--
-- THE JOIN-FILE RULE: 0342 sorts after the join file and touches only what is named above. The joined objects' lines
-- are in scripts/D421-join-lines.sql: the grant finding's arm of pgvigil.findings (source 'mssql_plancache') and
-- mssql_pc_extreme among purge()'s month-partition parents. Until a join file carries them the finding shows on the
-- Plan cache page only, and mssql_pc_extreme's months are not dropped.
SET LOCAL lock_timeout = '20s';

-- the partitioned parent, by name; then the last-read table
ALTER TABLE pgvigil.mssql_proc_sample
  ADD COLUMN IF NOT EXISTS min_cpu_us bigint,              -- each NULL: not read (the server has no such column, or an
  ADD COLUMN IF NOT EXISTS max_cpu_us bigint,              -- older collector sent the row)
  ADD COLUMN IF NOT EXISTS min_duration_us bigint,
  ADD COLUMN IF NOT EXISTS max_duration_us bigint,
  ADD COLUMN IF NOT EXISTS min_logical_reads bigint,
  ADD COLUMN IF NOT EXISTS max_logical_reads bigint,
  ADD COLUMN IF NOT EXISTS min_physical_reads bigint,
  ADD COLUMN IF NOT EXISTS max_physical_reads bigint,
  ADD COLUMN IF NOT EXISTS min_logical_writes bigint,
  ADD COLUMN IF NOT EXISTS max_logical_writes bigint,
  ADD COLUMN IF NOT EXISTS min_spills bigint,
  ADD COLUMN IF NOT EXISTS max_spills bigint;
ALTER TABLE pgvigil.mssql_pc_last ADD COLUMN IF NOT EXISTS clr_us bigint;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pc_extreme (
  instance_id           int NOT NULL,
  snapshot_at           timestamptz NOT NULL,
  database_id           int NOT NULL,
  query_key             text NOT NULL,
  executions            bigint NOT NULL,   -- the interval's own, as mssql_pc_sample's: a reader ranks and filters here
  cpu_us                bigint NOT NULL,
  interval_secs         real NOT NULL,
  min_cpu_us            bigint,            -- the extremes: each NULL where it was not read
  max_cpu_us            bigint,
  min_duration_us       bigint,
  max_duration_us       bigint,
  min_physical_reads    bigint,
  max_physical_reads    bigint,
  min_rows              bigint,
  max_rows              bigint,
  min_spills            bigint,
  max_spills            bigint,
  max_grant_kb          bigint,            -- as mssql_pc_sample's two: one row judges a grant against its use
  max_used_grant_kb     bigint,
  min_grant_kb          bigint,
  min_ideal_grant_kb    bigint,
  max_ideal_grant_kb    bigint,
  min_dop               bigint,
  min_reserved_threads  bigint,
  max_reserved_threads  bigint,
  min_used_threads      bigint,
  max_used_threads      bigint,
  plan_generation       bigint,            -- the largest of the plans that ran
  clr_us                bigint,            -- the interval's CLR time; NULL: not known for every plan that ran
  life_executions       bigint NOT NULL,   -- the plans that ran, since their compile: what an average over a
  life_cpu_us           bigint NOT NULL,   -- statement's cached life divides (sp_QuickieCache's diagnostics)
  life_physical_reads   bigint NOT NULL
) PARTITION BY RANGE (snapshot_at);

-- the finding reads every instance's last three hours: only the rows with a grant over 1 MB can raise it
CREATE INDEX IF NOT EXISTS mssql_pc_extreme_grant_idx ON pgvigil.mssql_pc_extreme (snapshot_at)
  WHERE max_grant_kb > 1024 AND max_used_grant_kb < 0.10 * max_grant_kb;

-- payload: 0092's; a 'stmt' row also carries min_ / max_worker_us, _elapsed_us, _physical_reads, _rows and _spills,
-- min_grant_kb, min_ / max_ideal_grant_kb, min_dop, min_ / max_reserved_threads and _used_threads, plan_generation
-- and clr_us (NULL: the server has no such column; absent: an older collector). 0092's function word for word,
-- with D421's arms between their marker lines.

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_plancache_0092(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
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
  -- the texts first: they stand on their own, and the collector does not send a text again within the hour.
  -- One per key; the words follow the policy the read was sent under (none: the stored words go too).
  INSERT INTO pgvigil.mssql_pc_text AS t (instance_id, query_key, database_id, object_name, query, snapshot_at, seen_at)
  SELECT DISTINCT ON (r->>'query_key') p_instance_id, r->>'query_key', (r->>'database_id')::int, r->>'object_name', r->>'query', p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'text' AND r->>'query_key' IS NOT NULL
   ORDER BY r->>'query_key'
  ON CONFLICT (instance_id, query_key) DO UPDATE SET
      database_id = EXCLUDED.database_id, object_name = coalesce(EXCLUDED.object_name, t.object_name),
      query = EXCLUDED.query, snapshot_at = greatest(EXCLUDED.snapshot_at, t.snapshot_at), seen_at = greatest(EXCLUDED.seen_at, t.seen_at);
  SELECT * INTO v_prev FROM pgvigil.mssql_pc_state WHERE instance_id = p_instance_id;
  IF FOUND AND (v_prev.server_utc >= v_now OR v_prev.snapshot_at >= p_snapshot_at) THEN
    RETURN;  -- an older read arriving late (or the same read again): the counters stored are newer
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_pc_in (
    plan_handle text, stmt_start int, stmt_end int, creation_time timestamp, database_id int, database_name text, query_key text,
    execution_count bigint, worker_us bigint, elapsed_us bigint, logical_reads bigint, physical_reads bigint, logical_writes bigint,
    row_count bigint, spills bigint, max_grant_kb bigint, max_used_grant_kb bigint, max_dop bigint, last_end timestamp,
    PRIMARY KEY (plan_handle, stmt_start, stmt_end, creation_time)) ON COMMIT DROP;
  TRUNCATE pgv_mssql_pc_in;
  INSERT INTO pgv_mssql_pc_in
  SELECT DISTINCT ON (r->>'plan_handle', (r->>'stmt_start')::int, (r->>'stmt_end')::int, (r->>'creation_time')::timestamp)
         r->>'plan_handle', (r->>'stmt_start')::int, (r->>'stmt_end')::int, (r->>'creation_time')::timestamp,
         coalesce((r->>'database_id')::int, 0), r->>'database_name', r->>'query_key', (r->>'execution_count')::bigint,
         coalesce((r->>'worker_us')::bigint, 0), coalesce((r->>'elapsed_us')::bigint, 0), coalesce((r->>'logical_reads')::bigint, 0),
         coalesce((r->>'physical_reads')::bigint, 0), coalesce((r->>'logical_writes')::bigint, 0), coalesce((r->>'row_count')::bigint, 0),
         coalesce((r->>'spills')::bigint, 0), (r->>'max_grant_kb')::bigint, (r->>'max_used_grant_kb')::bigint, (r->>'max_dop')::bigint,
         (r->>'last_execution')::timestamp + make_interval(secs => coalesce((r->>'last_elapsed_us')::bigint, 0) / 1e6)
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'stmt' AND r->>'plan_handle' IS NOT NULL AND r->>'stmt_start' IS NOT NULL AND r->>'stmt_end' IS NOT NULL
     AND r->>'creation_time' IS NOT NULL AND r->>'query_key' IS NOT NULL AND r->>'execution_count' IS NOT NULL
   ORDER BY 1, 2, 3, 4;
  -- [D421: the same rows' extremes, generation and CLR time (0342). They are not counters: the server keeps each as
  -- the smallest or the largest single run since the statement was compiled. A key the payload lacks stays NULL.
  CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_pc_x (
    plan_handle text, stmt_start int, stmt_end int, creation_time timestamp,
    min_cpu_us bigint, max_cpu_us bigint, min_duration_us bigint, max_duration_us bigint, min_physical_reads bigint,
    max_physical_reads bigint, min_rows bigint, max_rows bigint, min_spills bigint, max_spills bigint,
    min_grant_kb bigint, min_ideal_grant_kb bigint, max_ideal_grant_kb bigint, min_dop bigint,
    min_reserved_threads bigint, max_reserved_threads bigint, min_used_threads bigint, max_used_threads bigint,
    plan_generation bigint, clr_us bigint,
    PRIMARY KEY (plan_handle, stmt_start, stmt_end, creation_time)) ON COMMIT DROP;
  TRUNCATE pgv_mssql_pc_x;
  INSERT INTO pgv_mssql_pc_x
  SELECT DISTINCT ON (r->>'plan_handle', (r->>'stmt_start')::int, (r->>'stmt_end')::int, (r->>'creation_time')::timestamp)
         r->>'plan_handle', (r->>'stmt_start')::int, (r->>'stmt_end')::int, (r->>'creation_time')::timestamp,
         (r->>'min_worker_us')::bigint, (r->>'max_worker_us')::bigint, (r->>'min_elapsed_us')::bigint,
         (r->>'max_elapsed_us')::bigint, (r->>'min_physical_reads')::bigint, (r->>'max_physical_reads')::bigint,
         (r->>'min_rows')::bigint, (r->>'max_rows')::bigint, (r->>'min_spills')::bigint, (r->>'max_spills')::bigint,
         (r->>'min_grant_kb')::bigint, (r->>'min_ideal_grant_kb')::bigint, (r->>'max_ideal_grant_kb')::bigint,
         (r->>'min_dop')::bigint, (r->>'min_reserved_threads')::bigint, (r->>'max_reserved_threads')::bigint,
         (r->>'min_used_threads')::bigint, (r->>'max_used_threads')::bigint, (r->>'plan_generation')::bigint,
         (r->>'clr_us')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'stmt' AND r->>'plan_handle' IS NOT NULL AND r->>'stmt_start' IS NOT NULL AND r->>'stmt_end' IS NOT NULL
     AND r->>'creation_time' IS NOT NULL AND r->>'query_key' IS NOT NULL AND r->>'execution_count' IS NOT NULL
   ORDER BY 1, 2, 3, 4;
  -- D421]

  IF v_prev.instance_id IS NOT NULL AND v_now > v_prev.server_utc THEN
    v_secs := extract(epoch FROM v_now - v_prev.server_utc);
    v_restart := NOT pgvigil.mssql_same_run(v_prev.server_start, v_start);
    -- the parents in name order, the order purge() drops in (0067's lock-order note), before anything is written
    -- [D421: mssql_pc_extreme sorts before the two, and is locked before them
    PERFORM pgvigil.ensure_month_partition('mssql_pc_extreme', p_snapshot_at);
    LOCK TABLE ONLY pgvigil.mssql_pc_extreme IN ROW EXCLUSIVE MODE;
    -- D421]
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
                   -- its clock, or has run once and that run ENDED after its clock (a run is counted when it ends: the
                   -- read before could not have held it). none: not in a cut read although it may have been past the
                   -- cut: it only sets its counters.
             CROSS JOIN LATERAL (SELECT CASE WHEN l.instance_id IS NOT NULL AND f.execution_count >= l.execution_count THEN 'diff'
                                             WHEN l.instance_id IS NOT NULL OR v_restart OR NOT v_prev.capped THEN 'whole'
                                             WHEN f.creation_time >= v_prev.server_local THEN 'whole'
                                             WHEN f.execution_count = 1 AND f.last_end >= v_prev.server_local THEN 'whole'
                                             ELSE 'none' END AS mode) g) d
     WHERE d.executions > 0
     GROUP BY d.database_id, d.query_key;
    INSERT INTO pgvigil.mssql_pc_read (instance_id, snapshot_at, interval_secs, statements, capped)
    SELECT p_instance_id, p_snapshot_at, v_secs,
           (SELECT count(*) FROM pgvigil.mssql_pc_sample s WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at), v_capped;
    -- [D421: the interval's extremes, one row for each key mssql_pc_sample holds in it: over the plans of the key that
    -- RAN in the interval (the same rows and the same mode as above; the precedent is max_grant_kb there), each as
    -- read - the smallest of the smallest, the largest of the largest - with the plans' counts since their compile
    -- (life_*: what sp_QuickieCache divides by) and the interval's own executions, CPU and seconds, so a reader ranks,
    -- filters and takes a peak from this table alone. clr_us is the interval's own: a difference only where the read
    -- before had the figure too (0126's rule for the procedures' spills: greatest() skips a NULL), whole as read,
    -- and one plan without a known figure makes the key's interval unknown, never a part sum.
    DELETE FROM pgvigil.mssql_pc_extreme WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    INSERT INTO pgvigil.mssql_pc_extreme (instance_id, snapshot_at, database_id, query_key, executions, cpu_us, interval_secs,
        min_cpu_us, max_cpu_us, min_duration_us, max_duration_us, min_physical_reads, max_physical_reads, min_rows,
        max_rows, min_spills, max_spills, max_grant_kb, max_used_grant_kb, min_grant_kb, min_ideal_grant_kb,
        max_ideal_grant_kb, min_dop, min_reserved_threads, max_reserved_threads, min_used_threads, max_used_threads,
        plan_generation, clr_us,
        life_executions, life_cpu_us, life_physical_reads)
    SELECT p_instance_id, p_snapshot_at, d.database_id, d.query_key, sum(d.executions), sum(d.cpu_us), v_secs,
           min(d.min_cpu_us), max(d.max_cpu_us), min(d.min_duration_us), max(d.max_duration_us),
           min(d.min_physical_reads), max(d.max_physical_reads), min(d.min_rows), max(d.max_rows), min(d.min_spills),
           max(d.max_spills), max(d.max_grant_kb), max(d.max_used_grant_kb), min(d.min_grant_kb),
           min(d.min_ideal_grant_kb), max(d.max_ideal_grant_kb), min(d.min_dop), min(d.min_reserved_threads),
           max(d.max_reserved_threads), min(d.min_used_threads), max(d.max_used_threads), max(d.plan_generation),
           CASE WHEN count(d.clr_us) = count(*) THEN sum(d.clr_us) END,
           sum(d.execution_count), sum(d.worker_us), sum(d.physical_reads)
      FROM (SELECT f.database_id, f.query_key, f.execution_count, f.worker_us, f.physical_reads, f.max_grant_kb, f.max_used_grant_kb,
                   x.min_cpu_us, x.max_cpu_us, x.min_duration_us, x.max_duration_us, x.min_physical_reads,
                   x.max_physical_reads, x.min_rows, x.max_rows, x.min_spills, x.max_spills, x.min_grant_kb,
                   x.min_ideal_grant_kb, x.max_ideal_grant_kb, x.min_dop, x.min_reserved_threads,
                   x.max_reserved_threads, x.min_used_threads, x.max_used_threads, x.plan_generation,
                   CASE g.mode WHEN 'diff' THEN f.execution_count - l.execution_count WHEN 'whole' THEN f.execution_count ELSE 0 END AS executions,
                   CASE g.mode WHEN 'diff' THEN greatest(f.worker_us - l.worker_us, 0) WHEN 'whole' THEN f.worker_us ELSE 0 END AS cpu_us,
                   CASE g.mode WHEN 'diff' THEN CASE WHEN x.clr_us IS NOT NULL AND l.clr_us IS NOT NULL THEN greatest(x.clr_us - l.clr_us, 0) END
                               WHEN 'whole' THEN x.clr_us ELSE 0 END AS clr_us
              FROM pgv_mssql_pc_in f
              LEFT JOIN pgv_mssql_pc_x x ON x.plan_handle = f.plan_handle AND x.stmt_start = f.stmt_start AND x.stmt_end = f.stmt_end
                                        AND x.creation_time = f.creation_time
              LEFT JOIN pgvigil.mssql_pc_last l ON l.instance_id = p_instance_id AND l.plan_handle = f.plan_handle AND l.stmt_start = f.stmt_start
                                               AND l.stmt_end = f.stmt_end AND l.creation_time = f.creation_time
             CROSS JOIN LATERAL (SELECT CASE WHEN l.instance_id IS NOT NULL AND f.execution_count >= l.execution_count THEN 'diff'
                                             WHEN l.instance_id IS NOT NULL OR v_restart OR NOT v_prev.capped THEN 'whole'
                                             WHEN f.creation_time >= v_prev.server_local THEN 'whole'
                                             WHEN f.execution_count = 1 AND f.last_end >= v_prev.server_local THEN 'whole'
                                             ELSE 'none' END AS mode) g) d
     WHERE d.executions > 0
     GROUP BY d.database_id, d.query_key;
    -- D421]
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
  -- [D421: the CLR time the next interval's difference starts from (a figure that arrives where the row had none is
  -- a move, as 0126's spills)
  UPDATE pgvigil.mssql_pc_last l SET clr_us = x.clr_us
    FROM pgv_mssql_pc_x x
   WHERE l.instance_id = p_instance_id AND l.plan_handle = x.plan_handle AND l.stmt_start = x.stmt_start AND l.stmt_end = x.stmt_end
     AND l.creation_time = x.creation_time AND l.clr_us IS DISTINCT FROM x.clr_us;
  -- D421]
  INSERT INTO pgvigil.mssql_pc_state AS s (instance_id, snapshot_at, server_utc, server_start, server_local, capped, cached)
  VALUES (p_instance_id, p_snapshot_at, v_now, v_start, v_local, v_capped, (v_s->>'cached')::bigint)
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, server_utc = EXCLUDED.server_utc,
      server_start = EXCLUDED.server_start, server_local = EXCLUDED.server_local, capped = EXCLUDED.capped, cached = EXCLUDED.cached;

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

-- payload: 0126's; a 'proc' row also carries min_ / max_worker_us, _elapsed_us, _logical_reads, _physical_reads,
-- _logical_writes and _spills (NULL: the server has no such column; absent: an older collector). 0126's function
-- word for word, with D421's arms between their marker lines.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_procstats(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s        jsonb := pgvigil.mssql_perf_check('import_mssql_procstats', p_instance_id, p_payload);
  v_now      timestamptz := (v_s->>'server_utc')::timestamptz;
  v_start    timestamptz := (v_s->>'server_start')::timestamptz;
  v_local    timestamp := (v_s->>'server_local')::timestamp;
  v_capped   boolean := coalesce((v_s->>'capped')::boolean, false);
  v_prev     pgvigil.mssql_proc_state;
  v_secs     real;
  v_restart  boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_procstats'), p_instance_id);
  SELECT * INTO v_prev FROM pgvigil.mssql_proc_state WHERE instance_id = p_instance_id;
  IF FOUND AND (v_prev.server_utc >= v_now OR v_prev.snapshot_at >= p_snapshot_at) THEN
    RETURN;  -- an older read arriving late (or the same read again): the counters stored are newer
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_proc_in2 (
    plan_handle text, cached_time timestamp, database_id int, object_id bigint, database_name text, schema_name text, object_name text,
    type_desc text, execution_count bigint, worker_us bigint, elapsed_us bigint, logical_reads bigint, physical_reads bigint,
    logical_writes bigint, spills bigint, PRIMARY KEY (plan_handle, cached_time)) ON COMMIT DROP;
  TRUNCATE pgv_mssql_proc_in2;
  INSERT INTO pgv_mssql_proc_in2
  SELECT DISTINCT ON (r->>'plan_handle', (r->>'cached_time')::timestamp)
         r->>'plan_handle', (r->>'cached_time')::timestamp, (r->>'database_id')::int, (r->>'object_id')::bigint, r->>'database_name',
         r->>'schema_name', r->>'object_name', r->>'type_desc', (r->>'execution_count')::bigint, coalesce((r->>'worker_us')::bigint, 0),
         coalesce((r->>'elapsed_us')::bigint, 0), coalesce((r->>'logical_reads')::bigint, 0), coalesce((r->>'physical_reads')::bigint, 0),
         coalesce((r->>'logical_writes')::bigint, 0), (r->>'spills')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'proc' AND r->>'plan_handle' IS NOT NULL AND r->>'cached_time' IS NOT NULL AND r->>'database_id' IS NOT NULL
     AND r->>'object_id' IS NOT NULL AND r->>'execution_count' IS NOT NULL
   ORDER BY 1, 2;
  -- [D421: the same plans' extremes (0342): the smallest and the largest single execution since the plan was cached.
  -- A key the payload lacks stays NULL.
  CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_proc_x (
    plan_handle text, cached_time timestamp,
    min_cpu_us bigint, max_cpu_us bigint, min_duration_us bigint, max_duration_us bigint, min_logical_reads bigint,
    max_logical_reads bigint, min_physical_reads bigint, max_physical_reads bigint, min_logical_writes bigint,
    max_logical_writes bigint, min_spills bigint, max_spills bigint,
    PRIMARY KEY (plan_handle, cached_time)) ON COMMIT DROP;
  TRUNCATE pgv_mssql_proc_x;
  INSERT INTO pgv_mssql_proc_x
  SELECT DISTINCT ON (r->>'plan_handle', (r->>'cached_time')::timestamp)
         r->>'plan_handle', (r->>'cached_time')::timestamp,
         (r->>'min_worker_us')::bigint, (r->>'max_worker_us')::bigint, (r->>'min_elapsed_us')::bigint,
         (r->>'max_elapsed_us')::bigint, (r->>'min_logical_reads')::bigint, (r->>'max_logical_reads')::bigint,
         (r->>'min_physical_reads')::bigint, (r->>'max_physical_reads')::bigint, (r->>'min_logical_writes')::bigint,
         (r->>'max_logical_writes')::bigint, (r->>'min_spills')::bigint, (r->>'max_spills')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'proc' AND r->>'plan_handle' IS NOT NULL AND r->>'cached_time' IS NOT NULL AND r->>'database_id' IS NOT NULL
     AND r->>'object_id' IS NOT NULL AND r->>'execution_count' IS NOT NULL
   ORDER BY 1, 2;
  -- D421]

  IF v_prev.instance_id IS NOT NULL AND v_now > v_prev.server_utc THEN
    v_secs := extract(epoch FROM v_now - v_prev.server_utc);
    v_restart := NOT pgvigil.mssql_same_run(v_prev.server_start, v_start);
    -- the parents in name order, the order purge() drops in (0067's lock-order note), before anything of this
    -- instance is written: purge() holds them while mssql_reads_purge deletes a stale instance's counters
    PERFORM pgvigil.ensure_month_partition('mssql_proc_read', p_snapshot_at);
    PERFORM pgvigil.ensure_month_partition('mssql_proc_sample', p_snapshot_at);
    LOCK TABLE ONLY pgvigil.mssql_proc_read, ONLY pgvigil.mssql_proc_sample IN ROW EXCLUSIVE MODE;
    -- a restart since the read before: every plan in the cache was cached after it, and the old counters mean nothing
    IF v_restart THEN
      DELETE FROM pgvigil.mssql_proc_last WHERE instance_id = p_instance_id;
    END IF;
    DELETE FROM pgvigil.mssql_proc_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    DELETE FROM pgvigil.mssql_proc_read WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name,
        type_desc, executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, spills, interval_secs)
    SELECT p_instance_id, p_snapshot_at, d.database_id, d.object_id, max(d.database_name), max(d.schema_name), max(d.object_name),
           max(d.type_desc), sum(d.executions), sum(d.cpu_us), sum(d.duration_us), sum(d.logical_reads), sum(d.physical_reads),
           sum(d.logical_writes),
           -- one plan of the procedure without a known figure makes the procedure's interval unknown, never a part sum
           CASE WHEN count(d.spills) = count(*) THEN sum(d.spills) END, v_secs
      FROM (SELECT f.database_id, f.object_id, f.database_name, f.schema_name, f.object_name, f.type_desc,
                   CASE g.mode WHEN 'diff' THEN f.execution_count - l.execution_count WHEN 'whole' THEN f.execution_count ELSE 0 END AS executions,
                   CASE g.mode WHEN 'diff' THEN greatest(f.worker_us - l.worker_us, 0) WHEN 'whole' THEN f.worker_us ELSE 0 END AS cpu_us,
                   CASE g.mode WHEN 'diff' THEN greatest(f.elapsed_us - l.elapsed_us, 0) WHEN 'whole' THEN f.elapsed_us ELSE 0 END AS duration_us,
                   CASE g.mode WHEN 'diff' THEN greatest(f.logical_reads - l.logical_reads, 0) WHEN 'whole' THEN f.logical_reads ELSE 0 END AS logical_reads,
                   CASE g.mode WHEN 'diff' THEN greatest(f.physical_reads - l.physical_reads, 0) WHEN 'whole' THEN f.physical_reads ELSE 0 END AS physical_reads,
                   CASE g.mode WHEN 'diff' THEN greatest(f.logical_writes - l.logical_writes, 0) WHEN 'whole' THEN f.logical_writes ELSE 0 END AS logical_writes,
                   -- the spills: a difference only where the read before had the figure too (else the plan's count since
                   -- it was cached would land in one interval; greatest() skips a NULL, so the test is spelled out);
                   -- whole as the other counters; none: 0
                   CASE g.mode WHEN 'diff' THEN CASE WHEN f.spills IS NOT NULL AND l.spills IS NOT NULL THEN greatest(f.spills - l.spills, 0) END
                               WHEN 'whole' THEN f.spills ELSE 0 END AS spills
              FROM pgv_mssql_proc_in2 f
              LEFT JOIN pgvigil.mssql_proc_last l ON l.instance_id = p_instance_id AND l.plan_handle = f.plan_handle
                                                 AND l.cached_time = f.cached_time
                   -- diff: the plan was in the read before and grew. whole: it counts lower than before (again from
                   -- zero); or it was not in the read before, and that read was complete (or the server restarted
                   -- since): the plan was cached after it; or that read was cut and the plan was cached at or after
                   -- its clock. none: not in a cut read although cached earlier: it only sets its counters.
             CROSS JOIN LATERAL (SELECT CASE WHEN l.instance_id IS NOT NULL AND f.execution_count >= l.execution_count THEN 'diff'
                                             WHEN l.instance_id IS NOT NULL OR v_restart OR NOT v_prev.capped THEN 'whole'
                                             WHEN f.cached_time >= v_prev.server_local THEN 'whole'
                                             ELSE 'none' END AS mode) g) d
     WHERE d.executions > 0
     GROUP BY d.database_id, d.object_id;
    INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs)
    SELECT p_instance_id, p_snapshot_at, v_secs,
           (SELECT count(*) FROM pgvigil.mssql_proc_sample s WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at);
    -- [D421: the interval's extremes on the rows just stored: over the plans of the procedure that RAN in the
    -- interval (the same rows and the same mode as above), each as read
    UPDATE pgvigil.mssql_proc_sample s
       SET min_cpu_us = e.min_cpu_us, max_cpu_us = e.max_cpu_us, min_duration_us = e.min_duration_us, max_duration_us = e.max_duration_us,
           min_logical_reads = e.min_logical_reads, max_logical_reads = e.max_logical_reads, min_physical_reads = e.min_physical_reads, max_physical_reads = e.max_physical_reads,
           min_logical_writes = e.min_logical_writes, max_logical_writes = e.max_logical_writes, min_spills = e.min_spills, max_spills = e.max_spills
      FROM (SELECT d.database_id, d.object_id,
                   min(d.min_cpu_us) AS min_cpu_us, max(d.max_cpu_us) AS max_cpu_us,
                   min(d.min_duration_us) AS min_duration_us, max(d.max_duration_us) AS max_duration_us,
                   min(d.min_logical_reads) AS min_logical_reads, max(d.max_logical_reads) AS max_logical_reads,
                   min(d.min_physical_reads) AS min_physical_reads, max(d.max_physical_reads) AS max_physical_reads,
                   min(d.min_logical_writes) AS min_logical_writes, max(d.max_logical_writes) AS max_logical_writes,
                   min(d.min_spills) AS min_spills, max(d.max_spills) AS max_spills
              FROM (SELECT f.database_id, f.object_id,
                           x.min_cpu_us, x.max_cpu_us, x.min_duration_us, x.max_duration_us, x.min_logical_reads,
                           x.max_logical_reads, x.min_physical_reads, x.max_physical_reads, x.min_logical_writes,
                           x.max_logical_writes, x.min_spills, x.max_spills,
                           CASE g.mode WHEN 'diff' THEN f.execution_count - l.execution_count WHEN 'whole' THEN f.execution_count ELSE 0 END AS executions
                      FROM pgv_mssql_proc_in2 f
                      LEFT JOIN pgv_mssql_proc_x x ON x.plan_handle = f.plan_handle AND x.cached_time = f.cached_time
                      LEFT JOIN pgvigil.mssql_proc_last l ON l.instance_id = p_instance_id AND l.plan_handle = f.plan_handle
                                                         AND l.cached_time = f.cached_time
             CROSS JOIN LATERAL (SELECT CASE WHEN l.instance_id IS NOT NULL AND f.execution_count >= l.execution_count THEN 'diff'
                                             WHEN l.instance_id IS NOT NULL OR v_restart OR NOT v_prev.capped THEN 'whole'
                                             WHEN f.cached_time >= v_prev.server_local THEN 'whole'
                                             ELSE 'none' END AS mode) g) d
             WHERE d.executions > 0
             GROUP BY d.database_id, d.object_id) e
     WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at AND s.database_id = e.database_id AND s.object_id = e.object_id;
    -- D421]
  END IF;

  -- the state is this read's plans: one the cache dropped leaves it, and only counters that moved are rewritten (a
  -- spills figure that arrives where the row had none is a move: the next interval's difference starts from it)
  DELETE FROM pgvigil.mssql_proc_last l
   WHERE l.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM pgv_mssql_proc_in2 f WHERE f.plan_handle = l.plan_handle AND f.cached_time = l.cached_time);
  INSERT INTO pgvigil.mssql_proc_last AS l (instance_id, plan_handle, cached_time, database_id, object_id, execution_count, worker_us,
      elapsed_us, logical_reads, physical_reads, logical_writes, spills)
  SELECT p_instance_id, f.plan_handle, f.cached_time, f.database_id, f.object_id, f.execution_count, f.worker_us, f.elapsed_us,
         f.logical_reads, f.physical_reads, f.logical_writes, f.spills
    FROM pgv_mssql_proc_in2 f
  ON CONFLICT (instance_id, plan_handle, cached_time) DO UPDATE SET
      execution_count = EXCLUDED.execution_count, worker_us = EXCLUDED.worker_us, elapsed_us = EXCLUDED.elapsed_us,
      logical_reads = EXCLUDED.logical_reads, physical_reads = EXCLUDED.physical_reads, logical_writes = EXCLUDED.logical_writes,
      spills = EXCLUDED.spills
   WHERE (l.execution_count, l.worker_us, l.elapsed_us, l.logical_reads, l.physical_reads, l.logical_writes, l.spills)
         IS DISTINCT FROM (EXCLUDED.execution_count, EXCLUDED.worker_us, EXCLUDED.elapsed_us, EXCLUDED.logical_reads,
                           EXCLUDED.physical_reads, EXCLUDED.logical_writes, EXCLUDED.spills);
  INSERT INTO pgvigil.mssql_proc_state AS s (instance_id, snapshot_at, server_utc, server_start, server_local, capped)
  VALUES (p_instance_id, p_snapshot_at, v_now, v_start, v_local, v_capped)
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, server_utc = EXCLUDED.server_utc,
      server_start = EXCLUDED.server_start, server_local = EXCLUDED.server_local, capped = EXCLUDED.capped;
END $$;

-- One statement's diagnostics, as words: sp_QuickieCache 1.11's Step 5 rules (MIT, Darling Data, LLC) on the figures
-- of one read - the executions, CPU and physical reads of the statement's cached plans since their compile, and
-- their extremes. NULL: none applies.
--   Row count variance   the smallest run returned at least a row and the largest 100 times as many or more
--   Parameter sniffing   more than 3 executions and, where the average CPU is over 0, a smallest run under 0.70 of it
--                        or a largest over 1.30 of it; else the same band on the physical reads where their average
--                        (a whole number, as the procedure divides) is over 1,000
--   Wasteful grant       the largest grant over 1 MB, the largest use under 10 % of it
-- The procedure compares milliseconds and megabytes kept to two decimals; these are the microseconds and kilobytes
-- the server counts in; the CPU words truncate to whole milliseconds, as the procedure's CONVERT(bigint, ...) does.
-- STABLE, as format() and concat_ws() are. PARALLEL SAFE: it reads no table, and a function not so marked keeps every
-- statement that calls it (the extremes' read over a week of reads) to one process.
CREATE OR REPLACE FUNCTION pgvigil.mssql_pc_diagnostics(p_executions bigint, p_cpu_us bigint, p_min_cpu_us bigint, p_max_cpu_us bigint,
    p_physical_reads bigint, p_min_physical_reads bigint, p_max_physical_reads bigint, p_min_rows bigint, p_max_rows bigint,
    p_max_grant_kb bigint, p_max_used_grant_kb bigint)
RETURNS text LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT nullif(concat_ws('; ',
    CASE WHEN p_min_rows > 0 AND p_max_rows::numeric / p_min_rows >= 100
         THEN format('Row count variance (%s to %s)', p_min_rows, p_max_rows) END,
    CASE WHEN p_executions > 3 AND p_min_cpu_us IS NOT NULL AND p_max_cpu_us IS NOT NULL AND p_cpu_us > 0
              AND (p_min_cpu_us < 0.70 * p_cpu_us / p_executions OR p_max_cpu_us > 1.30 * p_cpu_us / p_executions)
         THEN format('Parameter sniffing (CPU %s-%s ms, avg %s ms)', trunc(p_min_cpu_us / 1000.0), trunc(p_max_cpu_us / 1000.0),
                     trunc(p_cpu_us / 1000.0 / p_executions))
         WHEN p_executions > 3 AND p_min_physical_reads IS NOT NULL AND p_max_physical_reads IS NOT NULL
              AND p_physical_reads / p_executions > 1000
              AND (p_min_physical_reads < 0.70 * (p_physical_reads / p_executions) OR p_max_physical_reads > 1.30 * (p_physical_reads / p_executions))
         THEN format('Parameter sniffing (physical reads %s-%s, avg %s)', p_min_physical_reads, p_max_physical_reads,
                     p_physical_reads / p_executions) END,
    CASE WHEN p_max_grant_kb > 1024 AND p_max_used_grant_kb < 0.10 * p_max_grant_kb
         THEN format('Wasteful grant (%s MB granted, %s %% used)', round(p_max_grant_kb / 1024.0, 1),
                     round(100.0 * p_max_used_grant_kb / p_max_grant_kb, 1)) END), '')
$$;

-- The grant finding (sp_QuickieCache 1.11's Wasteful grant: a grant over 1 MB of which under 10 % was used, both the
-- largest since the statement's compile). Judged at each read: a statement counts when any of its intervals of the
-- last three hours met the rule, and the finding goes three hours after the last such interval - its words name the
-- window, so a grant of a nightly job that left the list by morning is not read as fixed (the Plan cache page's own
-- grant columns follow the page's range). One row per instance under a constant name: the count and the five largest
-- are in the detail.
CREATE OR REPLACE VIEW pgvigil.mssql_plancache_grant_findings AS
WITH w AS (
  SELECT DISTINCT ON (e.instance_id, e.database_id, e.query_key)
         e.instance_id, e.database_id, e.query_key, e.snapshot_at, e.max_grant_kb, e.max_used_grant_kb
    FROM pgvigil.mssql_pc_extreme e
   WHERE e.snapshot_at > now() - interval '3 hours' AND e.max_grant_kb > 1024 AND e.max_used_grant_kb < 0.10 * e.max_grant_kb
   ORDER BY e.instance_id, e.database_id, e.query_key, e.snapshot_at DESC
), r AS (
  SELECT w.*, row_number() OVER (PARTITION BY w.instance_id ORDER BY w.max_grant_kb DESC, w.database_id, w.query_key) AS rn
    FROM w
)
SELECT r.instance_id, 'info'::text AS severity, 'wasteful memory grants'::text AS check_name, 'plan cache'::text AS object, max(r.snapshot_at) AS at,
       format('%s cached statement(s) that ran in the last 3 hours were granted over 1 MB of memory and used under 10 %% of it (the largest grant and the largest use since the statement was compiled). The largest: %s. '
              || 'Memory granted and not used is memory other queries wait for; the Plan cache page''s Memory grants columns show each statement over the page''s own range.',
              count(*),
              string_agg(format('%s %s (%s MB granted, %s %% used)', coalesce(d.database_name, 'database ' || r.database_id), r.query_key,
                                round(r.max_grant_kb / 1024.0, 1), round(100.0 * r.max_used_grant_kb / r.max_grant_kb, 1)), '; ' ORDER BY r.rn)
                FILTER (WHERE r.rn <= 5)) AS detail
  FROM r
  LEFT JOIN pgvigil.mssql_pc_database d ON d.instance_id = r.instance_id AND d.database_id = r.database_id
 GROUP BY r.instance_id;
