-- 0124: CPU, schedulers, performance counters and sessions in Erik Darling's sp_PressureDetector's and
-- PerformanceMonitor's shape (task 177, darling-open D14). Everything comes from the reads of mssql_cpu (every minute,
-- internal/mssql/cpu.go) and mssql_activity (every 5 minutes, internal/mssql/activity.go); nothing is created,
-- changed or switched on the monitored server.
--
--   mssql_counter_series     one row per performance counter of an instance (object without its prefix, counter,
--                            instance, cntr_type): an integer id in place of three text columns on every sample.
--   mssql_counter_sample     monthly partitions; per read and series: the raw value and, for a cumulative counter
--                            (cntr_type 272696576 / 272696320), its rate per second over the interval since the read
--                            before (NULL across a restart, a counter that went down, or the first read). A gauge
--                            (65792 / 65536) is stored at every read, 0 included (a missing row is never a 0); a
--                            cumulative counter whose raw value is 0 (it never counted since the server started) is
--                            not stored: its rate is 0 while its read is recorded in mssql_counter_read.
--   mssql_counter_last       where the next rate starts, per series.
--   mssql_counter_read       monthly partitions; one row per read and scope ('instance' every minute, 'database'
--                            every 5 minutes) with the server's time and the rows read.
--   mssql_session_summary    monthly partitions; PerformanceMonitor's session totals per 5-minute read.
--   mssql_session_group      monthly partitions; per read, the user sessions per program, host and database.
--   mssql_session_tempdb     monthly partitions; the 20 sessions holding the most tempdb per read.
--   mssql_activity_read      monthly partitions; one row per mssql_activity read with the reads it could not take.
--   mssql_cpu_info           sp_PressureDetector's CPU details as last read (sockets, NUMA nodes, cores, ...).
--   mssql_sched_sample       + offline_cpus, nodes_total, nodes_online (PerformanceMonitor's offline CPU warning).
--
-- import_mssql_cpu is 0074's, renamed import_mssql_cpu_0074 and called unchanged by a new import_mssql_cpu that also
-- stores the 'perfmon' rows and the scheduler read's new columns: 0074's 'counter' rows, its rates and its
-- mssql_perf_counter_last are untouched (0074 keys them by counter name only).
--
-- Functions for the pages: mssql_sched_levels (pgvigil's scheduler level and verdict, and PerformanceMonitor's
-- ClassifyCpuSchedulerPressure level and recommendation word for word), mssql_cpu_newest (the newest scheduler read
-- of a window with both levels, the workload groups' counters, runnable requests and THREADPOOL from the reads
-- nearest it), mssql_counter_newest / mssql_counter_series_between (the Metrics page's counters),
-- mssql_session_newest / mssql_session_series_between / mssql_session_groups_newest (the Connections page),
-- mssql_session_tempdb_newest (the TempDB page), mssql_log_flush_between (log bytes flushed per database).
--
-- mssql_cpu_findings: other processes using the CPU (sp_PressureDetector's 50 %), a transaction open for a long time,
-- slow data file writes (sp_PressureDetector's 100 ms). The join adds the arm to pgvigil.findings (0190):
--   SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_cpu', at FROM pgvigil.mssql_cpu_findings
-- Partition parents for purge() (the join adds them): mssql_counter_sample, mssql_counter_read, mssql_session_summary,
-- mssql_session_group, mssql_session_tempdb, mssql_activity_read.
--
-- Sources (MIT): sp_PressureDetector (DarlingData, darlingdata-20261101): perfmon list L2373-2386, its rates L2410-2440,
-- CPU details L3839-3881, CPU over threshold L3935-4015, thread usage L4122-4256, THREADPOOL L4277-4320, tempdb per
-- session L2700-2745, @cpu_utilization_threshold 50, @minimum_disk_latency_ms 100. PerformanceMonitor 3.12.0:
-- PerfmonStatsCollector (counter list, gauge types), CpuSchedulerStatsCollector (warning flags, offline CPUs, nodes),
-- SessionStatsCollector and SessionSummaryStatsCollector (5 minutes), DarlingPlanCacheSchedulerReader
-- .ClassifyCpuSchedulerPressure (levels and recommendation).

CREATE TABLE IF NOT EXISTS pgvigil.mssql_counter_series (
  series_id    int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  object       text NOT NULL,              -- without the instance's prefix: 'Buffer Manager'
  counter      text NOT NULL,
  inst         text NOT NULL,              -- the counter's instance ('' read as _Total)
  cntr_type    bigint,
  UNIQUE (instance_id, object, counter, inst)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_counter_sample (
  instance_id  int NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  series_id    int NOT NULL,
  value        bigint NOT NULL,
  rate         real                        -- per second, cumulative types only
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_counter_last (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  series_id     int NOT NULL,
  value         bigint NOT NULL,
  server_utc    timestamptz NOT NULL,
  server_start  timestamptz,
  PRIMARY KEY (instance_id, series_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_counter_read (
  instance_id   int NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  scope         text NOT NULL,             -- 'instance' (every minute) or 'database' (every 5 minutes)
  server_utc    timestamptz,
  rows_read     int NOT NULL,
  interval_secs real,                      -- since the scope's read before, by the server's clock
  PRIMARY KEY (instance_id, snapshot_at, scope)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_session_summary (
  instance_id  int NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  sessions     int, running int, sleeping int, background int, dormant int, idle_30min int, databases int,
  PRIMARY KEY (instance_id, snapshot_at)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_session_group (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  grp            text NOT NULL,            -- 'program', 'host', 'database'
  name           text NOT NULL,
  sessions       int, running int, sleeping int, dormant int,
  cpu_ms         bigint, reads bigint, writes bigint, logical_reads bigint
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_session_tempdb (
  instance_id       int NOT NULL,
  snapshot_at       timestamptz NOT NULL,
  session_id        int NOT NULL,
  alloc_kb          bigint, current_kb bigint, user_kb bigint, internal_kb bigint,
  login_name        text, program_name text, host_name text, status text, open_tran int,
  last_request_end  timestamptz
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_activity_read (
  instance_id  int NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  server_utc   timestamptz,
  skipped      jsonb,                      -- [{read, error}] of the reads the server refused
  PRIMARY KEY (instance_id, snapshot_at)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_cpu_info (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at  timestamptz NOT NULL,
  info         jsonb NOT NULL              -- the columns the server has, as read
);

ALTER TABLE pgvigil.mssql_sched_sample ADD COLUMN IF NOT EXISTS offline_cpus int;
ALTER TABLE pgvigil.mssql_sched_sample ADD COLUMN IF NOT EXISTS nodes_total int;
ALTER TABLE pgvigil.mssql_sched_sample ADD COLUMN IF NOT EXISTS nodes_online int;

-- the 'perfmon' rows of one read (scope 'instance' or 'database'); the caller holds the instance's import lock and
-- has made the month's partitions of mssql_counter_read and mssql_counter_sample
CREATE OR REPLACE FUNCTION pgvigil.mssql_import_perfmon(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb, p_scope text,
                                                         p_now timestamptz, p_start timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_n     int;
  v_prev  timestamptz;
BEGIN
  SELECT count(*) INTO v_n FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'perfmon';
  IF v_n = 0 THEN RETURN; END IF;
  -- an older read arriving late: its scope's newest read is already stored
  SELECT max(c.server_utc) INTO v_prev FROM pgvigil.mssql_counter_read c WHERE c.instance_id = p_instance_id AND c.scope = p_scope;
  IF v_prev IS NOT NULL AND v_prev >= p_now THEN RETURN; END IF;

  INSERT INTO pgvigil.mssql_counter_series AS k (instance_id, object, counter, inst, cntr_type)
  SELECT DISTINCT p_instance_id, r->>'object', r->>'counter', r->>'instance', (r->>'type')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'perfmon' AND r->>'object' IS NOT NULL AND r->>'counter' IS NOT NULL AND r->>'instance' IS NOT NULL
  ON CONFLICT (instance_id, object, counter, inst) DO UPDATE SET cntr_type = EXCLUDED.cntr_type
   WHERE k.cntr_type IS DISTINCT FROM EXCLUDED.cntr_type;

  DELETE FROM pgvigil.mssql_counter_sample s USING pgvigil.mssql_counter_series k
   WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at AND k.series_id = s.series_id
     AND k.object IN (SELECT DISTINCT r->>'object' FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'perfmon');
  INSERT INTO pgvigil.mssql_counter_sample (instance_id, snapshot_at, series_id, value, rate)
  SELECT p_instance_id, p_snapshot_at, k.series_id, x.value,
         CASE WHEN x.cumulative AND l.series_id IS NOT NULL AND pgvigil.mssql_same_run(l.server_start, p_start)
                   AND x.value >= l.value AND p_now > l.server_utc
              THEN round(((x.value - l.value) / extract(epoch FROM p_now - l.server_utc))::numeric, 3)::real END
    FROM (SELECT DISTINCT ON (r->>'object', r->>'counter', r->>'instance') r->>'object' AS object, r->>'counter' AS counter,
                 r->>'instance' AS inst, (r->>'value')::bigint AS value, (r->>'type')::bigint AS ctype,
                 (r->>'type')::bigint IN (272696576, 272696320) AS cumulative
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'perfmon' AND r->>'value' IS NOT NULL) x
    JOIN pgvigil.mssql_counter_series k ON k.instance_id = p_instance_id AND k.object = x.object AND k.counter = x.counter AND k.inst = x.inst
    LEFT JOIN pgvigil.mssql_counter_last l ON l.instance_id = p_instance_id AND l.series_id = k.series_id
   WHERE NOT x.cumulative OR x.value > 0;

  INSERT INTO pgvigil.mssql_counter_last AS l (instance_id, series_id, value, server_utc, server_start)
  SELECT DISTINCT ON (k.series_id) p_instance_id, k.series_id, (r->>'value')::bigint, p_now, p_start
    FROM jsonb_array_elements(p_payload) r
    JOIN pgvigil.mssql_counter_series k ON k.instance_id = p_instance_id AND k.object = r->>'object' AND k.counter = r->>'counter'
                                       AND k.inst = r->>'instance'
   WHERE r->>'kind' = 'perfmon' AND r->>'value' IS NOT NULL
  ON CONFLICT (instance_id, series_id) DO UPDATE SET value = EXCLUDED.value, server_utc = EXCLUDED.server_utc, server_start = EXCLUDED.server_start;

  DELETE FROM pgvigil.mssql_counter_read WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at AND scope = p_scope;
  INSERT INTO pgvigil.mssql_counter_read (instance_id, snapshot_at, scope, server_utc, rows_read, interval_secs)
  VALUES (p_instance_id, p_snapshot_at, p_scope, p_now, v_n, extract(epoch FROM p_now - v_prev)::real);
END $$;

-- 0074's import, renamed and called unchanged (its 'counter' rows, rates and mssql_perf_counter_last stay as they are)
DO $$ BEGIN
  IF to_regprocedure('pgvigil.import_mssql_cpu_0074(int, timestamptz, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_cpu(int, timestamptz, jsonb) RENAME TO import_mssql_cpu_0074;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_cpu(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s      jsonb := pgvigil.mssql_perf_check('import_mssql_cpu', p_instance_id, p_payload);
  v_sched  jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_cpu'), p_instance_id);
  -- the parents in name order (0067's lock-order note): mssql_counter_read and mssql_counter_sample come before 0074's
  -- mssql_cpu_sample and mssql_sched_sample, which its import makes next
  PERFORM pgvigil.ensure_month_partition('mssql_counter_read', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_counter_sample', p_snapshot_at);
  PERFORM pgvigil.import_mssql_cpu_0074(p_instance_id, p_snapshot_at, p_payload);
  SELECT r INTO v_sched FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'sched' LIMIT 1;
  UPDATE pgvigil.mssql_sched_sample SET offline_cpus = (v_sched->>'offline_cpus')::int, nodes_total = (v_sched->>'nodes_total')::int,
         nodes_online = (v_sched->>'nodes_online')::int
   WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at AND v_sched IS NOT NULL;
  PERFORM pgvigil.mssql_import_perfmon(p_instance_id, p_snapshot_at, p_payload, 'instance',
                                       (v_s->>'server_utc')::timestamptz, (v_s->>'server_start')::timestamptz);
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_activity(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s      jsonb := pgvigil.mssql_perf_check('import_mssql_activity', p_instance_id, p_payload);
  v_t      jsonb;
  v_info   jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_activity'), p_instance_id);
  -- the parents in name order (0067's lock-order note)
  PERFORM pgvigil.ensure_month_partition('mssql_activity_read', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_counter_read', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_counter_sample', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_session_group', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_session_summary', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_session_tempdb', p_snapshot_at);

  -- a payload imported twice at one snapshot time leaves one set of rows
  DELETE FROM pgvigil.mssql_activity_read WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  DELETE FROM pgvigil.mssql_session_summary WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  DELETE FROM pgvigil.mssql_session_group WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  DELETE FROM pgvigil.mssql_session_tempdb WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;

  INSERT INTO pgvigil.mssql_activity_read (instance_id, snapshot_at, server_utc, skipped)
  SELECT p_instance_id, p_snapshot_at, (v_s->>'server_utc')::timestamptz,
         (SELECT jsonb_agg(jsonb_build_object('read', r->>'source', 'error', left(r->>'message', 2000)))
            FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'collector_error');

  SELECT r INTO v_t FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'sessions' AND r->>'grp' = 'total' LIMIT 1;
  IF v_t IS NOT NULL THEN
    INSERT INTO pgvigil.mssql_session_summary (instance_id, snapshot_at, sessions, running, sleeping, background, dormant, idle_30min, databases)
    VALUES (p_instance_id, p_snapshot_at, (v_t->>'sessions')::int, (v_t->>'running')::int, (v_t->>'sleeping')::int,
            (v_t->>'background')::int, (v_t->>'dormant')::int, (v_t->>'idle_30min')::int, (v_t->>'databases')::int);
  END IF;
  INSERT INTO pgvigil.mssql_session_group (instance_id, snapshot_at, grp, name, sessions, running, sleeping, dormant, cpu_ms, reads, writes, logical_reads)
  SELECT p_instance_id, p_snapshot_at, r->>'grp', r->>'name', (r->>'sessions')::int, (r->>'running')::int, (r->>'sleeping')::int,
         (r->>'dormant')::int, (r->>'cpu_ms')::bigint, (r->>'reads')::bigint, (r->>'writes')::bigint, (r->>'logical_reads')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'sessions' AND r->>'grp' IN ('program', 'host', 'database') AND r->>'name' IS NOT NULL;

  INSERT INTO pgvigil.mssql_session_tempdb (instance_id, snapshot_at, session_id, alloc_kb, current_kb, user_kb, internal_kb,
                                            login_name, program_name, host_name, status, open_tran, last_request_end)
  SELECT p_instance_id, p_snapshot_at, (r->>'session_id')::int, (r->>'alloc_kb')::bigint, (r->>'current_kb')::bigint,
         (r->>'user_kb')::bigint, (r->>'internal_kb')::bigint, r->>'login_name', r->>'program_name', r->>'host_name',
         r->>'status', (r->>'open_tran')::int, (r->>'last_request_end')::timestamptz
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'tempdb' AND r->>'session_id' IS NOT NULL;

  SELECT r - 'kind' INTO v_info FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cpuinfo' LIMIT 1;
  IF v_info IS NOT NULL THEN
    INSERT INTO pgvigil.mssql_cpu_info AS c (instance_id, snapshot_at, info) VALUES (p_instance_id, p_snapshot_at, v_info)
    ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, info = EXCLUDED.info WHERE c.snapshot_at <= EXCLUDED.snapshot_at;
  END IF;

  PERFORM pgvigil.mssql_import_perfmon(p_instance_id, p_snapshot_at, p_payload, 'database',
                                       (v_s->>'server_utc')::timestamptz, (v_s->>'server_start')::timestamptz);
END $$;

-- mssql_sched_levels: the scheduler pressure verdict of one read, two ways.
--   level / verdict: pgvigil's (the CPU page before D14, kept as the verdict): HIGH at a runnable task per scheduler
--     on average or any task in the work queue; ELEVATED at a quarter of a runnable task per scheduler or 80 % of the
--     workers in use; else NORMAL.
--   pm_level / pm_recommendation: PerformanceMonitor's ClassifyCpuSchedulerPressure (DarlingPlanCacheSchedulerReader,
--     3.12.0) word for word: the runnable bands over 50 / 20 / 10, workers over 90 %, then its collector's flags
--     (current workers >= 90 % of max; runnable tasks >= CPUs; Resource Governor's queued requests >= CPUs).
CREATE OR REPLACE FUNCTION pgvigil.mssql_sched_levels(p_runnable int, p_schedulers int, p_work_queue int, p_current int, p_max int,
                                                     p_cpus int, p_queued int,
                                                     OUT level text, OUT verdict text, OUT pm_level text, OUT pm_recommendation text)
LANGUAGE sql IMMUTABLE AS $$
  WITH x AS (SELECT coalesce(p_runnable, 0) AS rt, coalesce(p_runnable, 0)::numeric / nullif(p_schedulers, 0) AS per,
                    coalesce(p_work_queue, 0) AS wq, coalesce(p_current, 0) AS cur, coalesce(p_max, 0) AS mx,
                    CASE WHEN coalesce(p_max, 0) > 0 THEN 100.0 * coalesce(p_current, 0) / p_max ELSE 0 END AS wpct,
                    coalesce(p_cpus, 0) AS cpus, coalesce(p_queued, 0) AS q)
  SELECT CASE WHEN coalesce(x.per, 0) >= 1 OR x.wq > 0 THEN 'HIGH' WHEN coalesce(x.per, 0) >= 0.25 OR x.wpct >= 80 THEN 'ELEVATED' ELSE 'NORMAL' END,
         CASE WHEN x.wq > 0 THEN x.wq || ' task(s) wait for a worker thread: THREADPOOL waits follow; find what holds the workers (blocking, parallel queries) before raising max worker threads.'
              WHEN coalesce(x.per, 0) >= 1 THEN 'Work is ready and waits for a CPU on every scheduler: SOS_SCHEDULER_YIELD and signal waits follow; the queries using the most CPU are the lever.'
              WHEN coalesce(x.per, 0) >= 0.25 THEN 'Some tasks wait for a CPU: worth a look if it lasts.'
              WHEN x.wpct >= 80 THEN 'Most worker threads are in use: blocking or many parallel queries hold them.'
              ELSE 'No CPU scheduler pressure at the newest read.' END,
         CASE WHEN x.rt > 50 THEN 'CRITICAL - High runnable task queue'
              WHEN x.rt > 20 THEN 'HIGH - Moderate runnable task queue'
              WHEN x.rt > 10 THEN 'MEDIUM - Some runnable tasks queued'
              WHEN x.wpct > 90 THEN 'HIGH - Worker thread exhaustion'
              WHEN x.cur >= x.mx * 0.90 AND x.mx > 0 THEN 'CRITICAL - Worker thread exhaustion warning'
              WHEN x.rt >= x.cpus AND x.cpus > 0 THEN 'HIGH - Runnable tasks warning'
              WHEN x.q >= x.cpus AND x.cpus > 0 THEN 'MEDIUM - Queued requests warning'
              ELSE 'NORMAL' END,
         CASE WHEN x.rt > 20 THEN 'CPU pressure detected - check for CPU-intensive queries, consider adding CPU cores'
              WHEN x.cur >= x.mx * 0.90 AND x.mx > 0 THEN 'Worker thread exhaustion - check max worker threads setting'
              WHEN x.q > 0 THEN 'Requests queued for execution - CPU or worker thread pressure'
              ELSE 'No CPU scheduler pressure detected' END
    FROM x
$$;

-- mssql_cpu_newest: the newest scheduler read of a window, both levels, the Workload Group Stats counters of the same
-- read (summed over the groups but 'internal', which sp_PressureDetector's read leaves out), the runnable requests of
-- the requests read nearest it (sp_PressureDetector's high_runnable_percent: sessions over 50, not background or
-- sleeping; shown at 10 % of 4 or more) and THREADPOOL of the waiting-tasks read nearest it, each within 30 s (else
-- NULL), with its time.
CREATE OR REPLACE FUNCTION pgvigil.mssql_cpu_newest(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, schedulers int, cpu_count int, runnable_tasks int, work_queue int, current_workers int,
               active_workers int, max_workers int, offline_cpus int, nodes_total int, nodes_online int,
               level text, verdict text, pm_level text, pm_recommendation text,
               rg_active_requests bigint, rg_queued_requests bigint, rg_blocked_tasks bigint, rg_parallel_threads bigint,
               requests_at timestamptz, requests bigint, runnable_requests bigint, runnable_pct numeric,
               threadpool_at timestamptz, threadpool int, threadpool_longest_ms bigint, cpu_info jsonb)
LANGUAGE sql STABLE AS $$
  WITH s AS (SELECT * FROM pgvigil.mssql_sched_sample x WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
              ORDER BY x.snapshot_at DESC LIMIT 1),
  wg AS (SELECT sum(c.value) FILTER (WHERE k.counter = 'Active requests') AS act, sum(c.value) FILTER (WHERE k.counter = 'Queued requests') AS q,
                sum(c.value) FILTER (WHERE k.counter = 'Blocked tasks') AS blk, sum(c.value) FILTER (WHERE k.counter = 'Active parallel threads') AS par
           FROM s JOIN pgvigil.mssql_counter_sample c ON c.instance_id = p_instance_id AND c.snapshot_at = s.snapshot_at
           JOIN pgvigil.mssql_counter_series k ON k.series_id = c.series_id AND k.object = 'Workload Group Stats'),
  rq AS (SELECT q.snapshot_at FROM s, pgvigil.mssql_requests_summary q
          WHERE q.instance_id = p_instance_id AND q.snapshot_at BETWEEN s.snapshot_at - interval '30 seconds' AND s.snapshot_at + interval '30 seconds'
          ORDER BY abs(extract(epoch FROM q.snapshot_at - s.snapshot_at)) LIMIT 1),
  rc AS (SELECT count(*) AS n, count(*) FILTER (WHERE r.status = 'runnable') AS runnable
           FROM rq JOIN pgvigil.mssql_requests r ON r.instance_id = p_instance_id AND r.snapshot_at = rq.snapshot_at
          WHERE r.session_id > 50 AND coalesce(r.status, '') NOT IN ('background', 'sleeping')),
  tp AS (SELECT w.snapshot_at, w.threadpool, w.threadpool_longest_ms FROM s, pgvigil.mssql_waiting_summary w
          WHERE w.instance_id = p_instance_id AND w.snapshot_at BETWEEN s.snapshot_at - interval '30 seconds' AND s.snapshot_at + interval '30 seconds'
          ORDER BY abs(extract(epoch FROM w.snapshot_at - s.snapshot_at)) LIMIT 1)
  SELECT s.snapshot_at, s.schedulers, s.cpu_count, s.runnable_tasks, s.work_queue, s.current_workers, s.active_workers, s.max_workers,
         s.offline_cpus, s.nodes_total, s.nodes_online, l.level, l.verdict, l.pm_level, l.pm_recommendation,
         wg.act, wg.q, wg.blk, wg.par,
         rq.snapshot_at, rc.n, rc.runnable, CASE WHEN rc.n > 0 THEN round(100.0 * rc.runnable / rc.n, 2) END,
         tp.snapshot_at, tp.threadpool, tp.threadpool_longest_ms,
         (SELECT i.info FROM pgvigil.mssql_cpu_info i WHERE i.instance_id = p_instance_id)
    FROM s
    LEFT JOIN wg ON true LEFT JOIN rq ON true LEFT JOIN rc ON rq.snapshot_at IS NOT NULL LEFT JOIN tp ON true
    CROSS JOIN LATERAL pgvigil.mssql_sched_levels(s.runnable_tasks, s.schedulers, s.work_queue, s.current_workers, s.max_workers,
                                                  s.cpu_count, wg.q::int) l
$$;

-- the THREADPOOL tasks with a session at the waiting-tasks read nearest the newest scheduler read (D01's rows; a task
-- queued for a worker before its login has no session and is only in the count)
CREATE OR REPLACE FUNCTION pgvigil.mssql_threadpool_newest(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, session_id int, wait_ms bigint)
LANGUAGE sql STABLE AS $$
  SELECT t.snapshot_at, t.session_id, t.wait_ms
    FROM pgvigil.mssql_waiting_tasks t
   WHERE t.instance_id = p_instance_id AND t.wait_type = 'THREADPOOL'
     AND t.snapshot_at = (SELECT max(w.snapshot_at) FROM pgvigil.mssql_waiting_summary w
                           WHERE w.instance_id = p_instance_id AND w.snapshot_at > p_from AND w.snapshot_at <= p_to)
   ORDER BY t.wait_ms DESC NULLS LAST
$$;

-- the collections that could not connect in a window (D30's import_connect_failure rows): a login refused or timed out
-- while the server runs is what a worker shortage looks like from outside
CREATE OR REPLACE FUNCTION pgvigil.mssql_connect_failures_between(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, collection text, note text)
LANGUAGE sql STABLE AS $$
  SELECT l.snapshot_at, l.collection, l.note FROM pgvigil.collection_log l
   WHERE l.instance_id = p_instance_id AND l.status = 'error' AND l.note LIKE 'connect:%' AND l.snapshot_at > p_from AND l.snapshot_at <= p_to
   ORDER BY l.snapshot_at DESC LIMIT 500
$$;

-- the Metrics page's counters: the newest read of each scope in a window, a row per series (a cumulative counter's
-- rate and its total since the counter started, a gauge's value)
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_newest(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (series_id int, scope text, snapshot_at timestamptz, object text, counter text, inst text, cntr_type bigint,
               cumulative boolean, value bigint, rate real, interval_secs real)
LANGUAGE sql STABLE AS $$
  WITH r AS (SELECT DISTINCT ON (c.scope) c.scope, c.snapshot_at, c.interval_secs FROM pgvigil.mssql_counter_read c
              WHERE c.instance_id = p_instance_id AND c.snapshot_at > p_from AND c.snapshot_at <= p_to
              ORDER BY c.scope, c.snapshot_at DESC)
  SELECT k.series_id, r.scope, r.snapshot_at, k.object, k.counter, k.inst, k.cntr_type, k.cntr_type IN (272696576, 272696320),
         s.value, s.rate, r.interval_secs
    FROM r JOIN pgvigil.mssql_counter_sample s ON s.instance_id = p_instance_id AND s.snapshot_at = r.snapshot_at
    JOIN pgvigil.mssql_counter_series k ON k.series_id = s.series_id
   WHERE (r.scope = 'database') = (k.object IN ('Databases', 'Database Replica'))
   ORDER BY k.object, k.counter, k.inst
$$;

-- a series per id over a window in steps of p_step seconds: a cumulative counter's average rate per second, a
-- gauge's average value; a step with no read of the series' scope has no point
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_series_between(p_instance_id int, p_from timestamptz, p_to timestamptz, p_step int, p_series int[])
RETURNS TABLE (snapshot_at timestamptz, series_id int, value double precision)
LANGUAGE sql STABLE AS $$
  SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / p_step) * p_step), s.series_id,
         avg(CASE WHEN k.cntr_type IN (272696576, 272696320) THEN s.rate ELSE s.value END)
    FROM pgvigil.mssql_counter_sample s JOIN pgvigil.mssql_counter_series k ON k.series_id = s.series_id
   WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to AND s.series_id = ANY (p_series[1:10])
   GROUP BY 1, 2 ORDER BY 1, 2
$$;

-- the Connections page: the newest session read of a window with the requests waiting for memory (PerformanceMonitor's
-- wait_type LIKE '%MEMORY%', from the requests read nearest it within 30 s), the read series, the groups
CREATE OR REPLACE FUNCTION pgvigil.mssql_session_newest(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, sessions int, running int, sleeping int, background int, dormant int, idle_30min int,
               databases int, applications bigint, top_application text, top_application_sessions int, top_host text,
               top_host_sessions int, requests_at timestamptz, waiting_for_memory bigint)
LANGUAGE sql STABLE AS $$
  WITH s AS (SELECT * FROM pgvigil.mssql_session_summary x WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
              ORDER BY x.snapshot_at DESC LIMIT 1),
  rq AS (SELECT q.snapshot_at FROM s, pgvigil.mssql_requests_summary q
          WHERE q.instance_id = p_instance_id AND q.snapshot_at BETWEEN s.snapshot_at - interval '30 seconds' AND s.snapshot_at + interval '30 seconds'
          ORDER BY abs(extract(epoch FROM q.snapshot_at - s.snapshot_at)) LIMIT 1)
  SELECT s.snapshot_at, s.sessions, s.running, s.sleeping, s.background, s.dormant, s.idle_30min, s.databases,
         (SELECT count(*) FROM pgvigil.mssql_session_group g WHERE g.instance_id = p_instance_id AND g.snapshot_at = s.snapshot_at AND g.grp = 'program'),
         a.name, a.sessions, h.name, h.sessions, rq.snapshot_at,
         (SELECT count(*) FROM pgvigil.mssql_requests r WHERE r.instance_id = p_instance_id AND r.snapshot_at = rq.snapshot_at AND r.wait_type LIKE '%MEMORY%')
    FROM s
    LEFT JOIN LATERAL (SELECT g.name, g.sessions FROM pgvigil.mssql_session_group g WHERE g.instance_id = p_instance_id AND g.snapshot_at = s.snapshot_at
                        AND g.grp = 'program' ORDER BY g.sessions DESC, g.name LIMIT 1) a ON true
    LEFT JOIN LATERAL (SELECT g.name, g.sessions FROM pgvigil.mssql_session_group g WHERE g.instance_id = p_instance_id AND g.snapshot_at = s.snapshot_at
                        AND g.grp = 'host' ORDER BY g.sessions DESC, g.name LIMIT 1) h ON true
    LEFT JOIN rq ON true
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_session_series_between(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, sessions int, running int, sleeping int, background int, dormant int, idle_30min int, waiting_for_memory bigint)
LANGUAGE sql STABLE AS $$
  SELECT s.snapshot_at, s.sessions, s.running, s.sleeping, s.background, s.dormant, s.idle_30min,
         (SELECT count(*) FROM pgvigil.mssql_requests r
           WHERE r.instance_id = p_instance_id AND r.wait_type LIKE '%MEMORY%'
             AND r.snapshot_at = (SELECT q.snapshot_at FROM pgvigil.mssql_requests_summary q
                                   WHERE q.instance_id = p_instance_id
                                     AND q.snapshot_at BETWEEN s.snapshot_at - interval '30 seconds' AND s.snapshot_at + interval '30 seconds'
                                   ORDER BY abs(extract(epoch FROM q.snapshot_at - s.snapshot_at)) LIMIT 1))
    FROM pgvigil.mssql_session_summary s
   WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
   ORDER BY s.snapshot_at
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_session_groups_newest(p_instance_id int, p_from timestamptz, p_to timestamptz, p_grp text)
RETURNS TABLE (snapshot_at timestamptz, name text, sessions int, running int, sleeping int, dormant int, cpu_ms bigint,
               reads bigint, writes bigint, logical_reads bigint)
LANGUAGE sql STABLE AS $$
  SELECT g.snapshot_at, g.name, g.sessions, g.running, g.sleeping, g.dormant, g.cpu_ms, g.reads, g.writes, g.logical_reads
    FROM pgvigil.mssql_session_group g
   WHERE g.instance_id = p_instance_id AND g.grp = p_grp
     AND g.snapshot_at = (SELECT max(x.snapshot_at) FROM pgvigil.mssql_session_summary x
                           WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to)
   ORDER BY g.sessions DESC, g.name
$$;

-- the TempDB page: the sessions holding tempdb at the newest activity read, a running request's own tasks
-- (mssql_requests' tempdb figures from sys.dm_db_task_space_usage, the requests read nearest within 30 s) added per
-- session as sp_PressureDetector adds them
CREATE OR REPLACE FUNCTION pgvigil.mssql_session_tempdb_newest(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, session_id int, alloc_kb bigint, current_kb bigint, user_kb bigint, internal_kb bigint,
               task_alloc_kb bigint, task_current_kb bigint, login_name text, program_name text, host_name text, status text,
               open_tran int, last_request_end timestamptz, requests_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH a AS (SELECT max(x.snapshot_at) AS at FROM pgvigil.mssql_activity_read x
              WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to),
  rq AS (SELECT q.snapshot_at FROM a, pgvigil.mssql_requests_summary q
          WHERE q.instance_id = p_instance_id AND q.snapshot_at BETWEEN a.at - interval '30 seconds' AND a.at + interval '30 seconds'
          ORDER BY abs(extract(epoch FROM q.snapshot_at - a.at)) LIMIT 1)
  SELECT t.snapshot_at, t.session_id, t.alloc_kb, t.current_kb, t.user_kb, t.internal_kb, r.alloc, r.cur,
         t.login_name, t.program_name, t.host_name, t.status, t.open_tran, t.last_request_end, rq.snapshot_at
    FROM a JOIN pgvigil.mssql_session_tempdb t ON t.instance_id = p_instance_id AND t.snapshot_at = a.at
    LEFT JOIN rq ON true
    LEFT JOIN LATERAL (SELECT sum(x.tempdb_alloc_kb)::bigint AS alloc, sum(x.tempdb_current_kb)::bigint AS cur FROM pgvigil.mssql_requests x
                        WHERE x.instance_id = p_instance_id AND x.snapshot_at = rq.snapshot_at AND x.session_id = t.session_id) r ON true
   ORDER BY t.alloc_kb + coalesce(r.alloc, 0) DESC, t.session_id
$$;

-- log bytes flushed per second per database over a window (the Databases object's Log Bytes Flushed/sec, read every 5
-- minutes): per database the average and the highest rate, the five busiest first
CREATE OR REPLACE FUNCTION pgvigil.mssql_log_flush_between(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (series_id int, database_name text, avg_bytes_s double precision, max_bytes_s real, reads bigint, last_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT k.series_id, k.inst, avg(s.rate), max(s.rate), count(s.rate), max(s.snapshot_at)
    FROM pgvigil.mssql_counter_series k
    JOIN pgvigil.mssql_counter_sample s ON s.series_id = k.series_id AND s.instance_id = p_instance_id
   WHERE k.instance_id = p_instance_id AND k.object = 'Databases' AND k.counter = 'Log Bytes Flushed/sec' AND k.inst <> '_Total'
     AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
   GROUP BY k.series_id, k.inst
   ORDER BY avg(s.rate) DESC NULLS LAST, k.inst
$$;

-- the findings of D14:
--   other processes use the CPU: the other processes' share averaged 50 % or more (sp_PressureDetector's
--     @cpu_utilization_threshold) over the last 15 minutes with 10 or more records (0074's window); never on a Linux
--     host, whose records carry no idle figure.
--   a transaction open for a long time: at the newest requests read (of the last 10 minutes), a session with an open
--     transaction: idle (sleeping) 30 minutes or more a warning, 4 hours or more critical; running 4 hours or more a
--     warning, never critical on age (a long rebuild or load is not a fault by its age).
--   slow data file writes: a data file's average write stall over 100 ms (sp_PressureDetector's
--     @minimum_disk_latency_ms) over the last hour with 1,000 writes or more (0074's hour and floor).
CREATE OR REPLACE VIEW pgvigil.mssql_cpu_findings AS
SELECT c.instance_id, 'warning'::text AS severity, 'other processes use the CPU'::text AS check_name, 'cpu'::text AS object, c.at,
       format('processes other than SQL Server used %s %% of the machine''s CPU on average over the last %s minute(s) (peak %s %%; '
              || 'SQL Server %s %%): something else on the host competes with SQL Server for the CPU '
              || '(sp_PressureDetector lists each record at %s %% or more).', round(c.other_avg, 1), c.n, c.other_max,
              round(c.sql_avg, 1), 50) AS detail
  FROM (SELECT s.instance_id, count(*) AS n, avg(s.other_pct) AS other_avg, max(s.other_pct) AS other_max, avg(s.sql_pct) AS sql_avg,
               max(s.snapshot_at) AS at
          FROM pgvigil.mssql_cpu_sample s
         WHERE s.snapshot_at > now() - interval '15 minutes' AND s.other_pct IS NOT NULL
         GROUP BY s.instance_id) c
 WHERE c.n >= 10 AND c.other_avg >= 50
UNION ALL
SELECT t.instance_id,
       CASE WHEN t.idle AND t.age >= interval '4 hours' THEN 'critical' ELSE 'warning' END,
       'a transaction open for a long time', 'session ' || t.session_id, t.snapshot_at,
       format('session %s (%s, %s on %s, database %s) has had a transaction open since %s (%s), %s; %s',
              t.session_id, coalesce(t.login_name, 'login not read'), coalesce(t.program_name, 'no program name'),
              coalesce(t.host_name, 'no host name'), coalesce(t.database_name, '?'),
              to_char(t.tran_start AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS "UTC"'), justify_interval(date_trunc('second', t.age)),
              CASE WHEN t.idle THEN 'idle: the application left it open; it holds its locks and keeps the log from being reused until it ends'
                   ELSE 'running: a long statement or batch holds it (a rebuild or a load can; its age alone is not a fault)' END,
              CASE WHEN t.statement IS NULL THEN 'its last statement was not read.' ELSE 'its last statement: ' || left(t.statement, 300) END)
  FROM (SELECT r.instance_id, r.snapshot_at, r.session_id, r.login_name, r.program_name, r.host_name, r.database_name, r.tran_start,
               r.snapshot_at - r.tran_start AS age, coalesce(r.status, '') = 'sleeping' AS idle, st.statement
          FROM pgvigil.mssql_requests r
          JOIN (SELECT q.instance_id, max(q.snapshot_at) AS at FROM pgvigil.mssql_requests_summary q
                 WHERE q.snapshot_at > now() - interval '10 minutes' GROUP BY q.instance_id) n
            ON n.instance_id = r.instance_id AND n.at = r.snapshot_at
          LEFT JOIN pgvigil.mssql_statement_text st ON st.instance_id = r.instance_id AND st.text_id = r.text_id
         WHERE r.tran_start IS NOT NULL AND r.session_id > 50) t
 WHERE (t.idle AND t.age >= interval '30 minutes') OR (NOT t.idle AND t.age >= interval '4 hours')
UNION ALL
SELECT f.instance_id, 'warning', 'slow data file writes', f.database_name || ': ' || f.file_name, f.at,
       format('%s ms per write on average over the last hour (%s writes) to %s in %s (sp_PressureDetector reports a file over %s ms). '
              || 'Writes to data files are asynchronous (checkpoint and the lazy writer) and rarely make a query wait; tempdb''s files '
              || 'are the exception: spills and work tables wait on them.', round(f.ms, 1), f.writes, f.file_name, f.database_name, 100)
  FROM (SELECT s.instance_id, s.database_name, s.file_name, sum(s.writes) AS writes,
               sum(s.write_stall_ms)::numeric / nullif(sum(s.writes), 0) AS ms, max(s.snapshot_at) AS at
          FROM pgvigil.mssql_fileio_sample s
         WHERE s.snapshot_at > now() - interval '1 hour' AND s.type_desc = 'ROWS'
         GROUP BY s.instance_id, s.database_name, s.file_name) f
 WHERE f.writes >= 1000 AND f.ms > 100;

COMMENT ON VIEW pgvigil.mssql_cpu_findings IS 'Task 177 D14: other processes using the CPU, a transaction open for a long time, slow data file writes.';

SELECT pgvigil.apply_roles();
