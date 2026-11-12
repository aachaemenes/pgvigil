-- 0126: what PerformanceMonitor's Queries view needs that the stored rows did not hold (task 177, darling-open D10,
-- DONE-1): the Query Store's aborted and exception runs apart, the procedures' spills, and the plan cache's SQL handle
-- and plan hash. Everything comes from reads the collectors already take; nothing is created, changed or switched on
-- on the monitored server.
--
--   mssql_qs_runtime   + aborted_executions, aborted_cpu_us, aborted_duration_us (execution_type 3, Aborted: a client
--                        abort, a timeout or a cancel) and exception_executions, exception_cpu_us, exception_duration_us
--                        (execution_type 4, Exception: the run ended in an error). Written only where failed > 0 and
--                        NULL otherwise (a NULL costs a bit of the row's null bitmap): failed = 0 says all six are 0.
--                        failed > 0 with the six NULL = a row read before this file, or by an older collector: 'not
--                        read apart', and the pages never take it for 0.
--   mssql_proc_last,   + spills: sys.dm_exec_procedure_stats.total_spills (SQL Server 2016 SP2 / 2017 CU3 and later),
--   mssql_proc_sample    as last read per plan, and per procedure what the interval added. NULL where the server has
--                        no such column, where an older collector sent none, and for an interval whose read before
--                        had none (the plan's whole count since it was cached is never stored as one interval's).
--   mssql_pc_handles   the SQL handle and plan hash of each statement mssql_pc_last holds, written once per statement
--                        (the values never change for its key) and gone with it (the foreign key's cascade: a
--                        statement that leaves the cache, a restart, an instance removed).
--
-- import_mssql_querystore is 0083's, renamed import_mssql_querystore_0083 and called unchanged by a new
-- import_mssql_querystore that then writes the six values on the runtime rows the read stored (the intervals whose
-- read_at is this read's). import_mssql_plancache is 0092's, renamed import_mssql_plancache_0092 and called unchanged
-- by a new import_mssql_plancache that then adds the new statements' handles. import_mssql_procstats is 0084's
-- with the spills added (replaced whole: the delta is computed inside it). A payload without the new keys (a
-- collector older than this file, during an upgrade) stores NULL, never 0.
--
-- Locks: a nullable ADD COLUMN rewrites nothing but holds ACCESS EXCLUSIVE on the table, and on a partitioned parent
-- on every partition, until this file's transaction commits; the new table's foreign key takes SHARE ROW EXCLUSIVE
-- on mssql_pc_last. They are taken in purge()'s name order (0067's lock-order note): mssql_pc_last (the foreign
-- key), mssql_proc_last, mssql_proc_sample, mssql_qs_runtime. lock_timeout bounds the wait: a page read holds its
-- lock 15 seconds at most (the UI pool's statement timeout) and an import a few seconds, so 20 seconds outwaits
-- both; past it the file fails whole and the next 'pgvigil migrate' runs it again. While the file waits, the reads
-- and imports that come after it queue behind it, 20 seconds at most.
--
-- Partition parents for purge(): none new (mssql_pc_handles is not partitioned; the new columns go with their
-- monthly partitions). Findings: none.
SET LOCAL lock_timeout = '20s';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pc_handles (
  instance_id    int NOT NULL,
  plan_handle    text NOT NULL,
  stmt_start     int NOT NULL,
  stmt_end       int NOT NULL,
  creation_time  timestamp NOT NULL,
  sql_handle     text,                   -- 0x text, as the server wrote it
  plan_hash      text,                   -- query_plan_hash, 0x text
  PRIMARY KEY (instance_id, plan_handle, stmt_start, stmt_end, creation_time),
  FOREIGN KEY (instance_id, plan_handle, stmt_start, stmt_end, creation_time)
    REFERENCES pgvigil.mssql_pc_last (instance_id, plan_handle, stmt_start, stmt_end, creation_time) ON DELETE CASCADE
);

ALTER TABLE pgvigil.mssql_proc_last ADD COLUMN IF NOT EXISTS spills bigint;
ALTER TABLE pgvigil.mssql_proc_sample ADD COLUMN IF NOT EXISTS spills bigint;
ALTER TABLE pgvigil.mssql_qs_runtime
  ADD COLUMN IF NOT EXISTS aborted_executions bigint,
  ADD COLUMN IF NOT EXISTS aborted_cpu_us bigint,
  ADD COLUMN IF NOT EXISTS aborted_duration_us bigint,
  ADD COLUMN IF NOT EXISTS exception_executions bigint,
  ADD COLUMN IF NOT EXISTS exception_cpu_us bigint,
  ADD COLUMN IF NOT EXISTS exception_duration_us bigint;

-- 0083's and 0092's imports, renamed and called unchanged
DO $$ BEGIN
  IF to_regprocedure('pgvigil.import_mssql_querystore_0083(int, timestamptz, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_querystore(int, timestamptz, jsonb) RENAME TO import_mssql_querystore_0083;
  END IF;
  IF to_regprocedure('pgvigil.import_mssql_plancache_0092(int, timestamptz, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_plancache(int, timestamptz, jsonb) RENAME TO import_mssql_plancache_0092;
  END IF;
END $$;

-- payload: 0083's; a 'runtime' row with failed > 0 also carries aborted_executions, aborted_cpu_us,
-- aborted_duration_us, exception_executions, exception_cpu_us and exception_duration_us (querystore.go).
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_querystore(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.import_mssql_querystore_0083(p_instance_id, p_snapshot_at, p_payload);
  -- the rows this read stored: an interval it wrote (read_at = this read; a late or refused read wrote none). A row
  -- without failures keeps the six NULL; a key the payload lacks stays NULL.
  UPDATE pgvigil.mssql_qs_runtime t
     SET aborted_executions = (x.r->>'aborted_executions')::bigint, aborted_cpu_us = (x.r->>'aborted_cpu_us')::bigint,
         aborted_duration_us = (x.r->>'aborted_duration_us')::bigint, exception_executions = (x.r->>'exception_executions')::bigint,
         exception_cpu_us = (x.r->>'exception_cpu_us')::bigint, exception_duration_us = (x.r->>'exception_duration_us')::bigint
    FROM (SELECT DISTINCT ON (r->>'database_name', (r->>'interval_start')::timestamptz, (r->>'plan_id')::bigint)
                 r, r->>'database_name' AS database_name, (r->>'interval_start')::timestamptz AS at, (r->>'plan_id')::bigint AS plan_id
            FROM jsonb_array_elements(pgvigil.mssql_rows(p_payload)) r
           WHERE r->>'kind' = 'runtime' AND r->>'database_name' IS NOT NULL AND r->>'interval_start' IS NOT NULL
             AND r->>'plan_id' IS NOT NULL AND coalesce((r->>'failed')::bigint, 0) > 0
             AND (r ? 'aborted_executions' OR r ? 'exception_executions')) x
    JOIN pgvigil.mssql_qs_interval i ON i.instance_id = p_instance_id AND i.database_name = x.database_name AND i.snapshot_at = x.at
                                    AND i.read_at = p_snapshot_at
   WHERE t.instance_id = p_instance_id AND t.database_name = x.database_name AND t.snapshot_at = x.at AND t.plan_id = x.plan_id;
END $$;

-- payload: 0092's; the 'stmt' rows' sql_handle and plan_hash_hex (sent since 0092, stored from here on).
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_plancache(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.import_mssql_plancache_0092(p_instance_id, p_snapshot_at, p_payload);
  -- a statement mssql_pc_last holds after the read (a late read changed nothing there, and adds nothing here)
  INSERT INTO pgvigil.mssql_pc_handles AS h (instance_id, plan_handle, stmt_start, stmt_end, creation_time, sql_handle, plan_hash)
  SELECT DISTINCT ON (x.plan_handle, x.stmt_start, x.stmt_end, x.creation_time)
         p_instance_id, x.plan_handle, x.stmt_start, x.stmt_end, x.creation_time, x.sql_handle, x.plan_hash
    FROM (SELECT r->>'plan_handle' AS plan_handle, (r->>'stmt_start')::int AS stmt_start, (r->>'stmt_end')::int AS stmt_end,
                 (r->>'creation_time')::timestamp AS creation_time, r->>'sql_handle' AS sql_handle, r->>'plan_hash_hex' AS plan_hash
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'stmt' AND r->>'plan_handle' IS NOT NULL AND r->>'stmt_start' IS NOT NULL AND r->>'stmt_end' IS NOT NULL
             AND r->>'creation_time' IS NOT NULL AND (r->>'sql_handle' IS NOT NULL OR r->>'plan_hash_hex' IS NOT NULL)) x
    JOIN pgvigil.mssql_pc_last l ON l.instance_id = p_instance_id AND l.plan_handle = x.plan_handle AND l.stmt_start = x.stmt_start
                                AND l.stmt_end = x.stmt_end AND l.creation_time = x.creation_time
   ORDER BY x.plan_handle, x.stmt_start, x.stmt_end, x.creation_time
  ON CONFLICT (instance_id, plan_handle, stmt_start, stmt_end, creation_time) DO NOTHING;
END $$;

-- payload: 0084's; a 'proc' row also carries spills (NULL: the server has no total_spills; absent: an older
-- collector). 0084's function with the spills added: the interval's spills only where both reads had them.
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
