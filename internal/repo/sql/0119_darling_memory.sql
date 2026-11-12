-- 0119: memory in Erik Darling's sp_PressureDetector's and PerformanceMonitor's shape (task 177, darling-open D13):
-- grants per resource pool and per semaphore over a window and at the newest read, the resource monitor's low-memory
-- notifications, the cache counters, the plan cache by cache and object type, the grants now, the Resource Governor's
-- groups and pools with their limits, and the memory findings. Everything comes from mssql_memory's reads
-- (internal/mssql/memory.go); nothing is created, changed or switched on the monitored server.
--
--   mssql_memory_sample      + xtp_kb, tokenperm_kb (the clerk totals), max_workspace_kb, granted_workspace_kb (the
--                            Memory Manager's Maximum / Granted Workspace Memory (KB)).
--   mssql_memory_rmon        monthly partitions by snapshot_at (the record's own time, not the read's); one row per RING_BUFFER_RESOURCE_MONITOR record (its id,
--                            the server's start, the time in UTC, the notification, the process and system indicators,
--                            the available physical and virtual memory); a record is stored once: a read keeps the
--                            records past the newest id stored for the same server start.
--   mssql_memory_cache       monthly partitions; per read sp_PressureDetector's 20 largest caches.
--   mssql_plancache_type     monthly partitions; per read the plan cache by cache and object type (PerformanceMonitor's).
--   mssql_memory_grant_query monthly partitions; per read the 50 largest asks of sys.dm_exec_query_memory_grants.
--   mssql_rg_group, mssql_rg_pool   the newest read per instance of the workload groups and the resource pools.
--   mssql_memory_reads       the newest read per instance: the reads the server refused ('skip' rows: read, error).
--   import_mssql_memory      0115's body with the new kinds.
--   mssql_grant_window_between(instance, from, to, by_semaphore)  PerformanceMonitor's 'Memory Grant Pressure' and
--                            'Resource Semaphore Pressure': per pool (its semaphores summed per read) or per semaphore,
--                            the reads, the peak waiters and when, the peak granted and when (a tie: the latest read,
--                            PerformanceMonitor's MemoryGrantsWindowSql order), the least available,
--                            the timeouts and forced grants over the window (0115's mssql_grant_deltas), first, last.
--   mssql_grant_newest_between(instance, from, to, by_semaphore)  PerformanceMonitor's 'Memory Grants' and 'Resource
--                            Semaphore': the newest read of the window, per pool or per semaphore, with the timeouts
--                            and forced grants since the read before it (and since the server started).
--   mssql_grant_series_between(instance, from, to, step)          per step and pool: the most waiters, the granted
--                            and available memory, the timeouts and forced grants of the step.
--   mssql_memory_rmon_hourly(instance, from, to)  PerformanceMonitor's pressure events per hour: a sample counts when
--                            an indicator reads 2 or more; 2 is medium, 3 or more severe; SQL Server is the process
--                            indicator, the operating system the system one; every hour of the window, 0 when none
--                            (a window over 62 days returns no hours).
--   mssql_plancache_summary_between(instance, from, to)  the newest plan cache read's totals and PerformanceMonitor's
--                            bloat level (single-use plans over all: > 50 % CRITICAL, > 30 % HIGH, > 20 % MEDIUM, else
--                            NORMAL) and recommendation.
--   mssql_memory_findings_between(instance, from, to), mssql_memory_findings (the last 15 minutes, the findings arm).
--
-- Per pool, the semaphores with a max target only (sp_PressureDetector's and PerformanceMonitor's WHERE
-- deqrs.max_target_memory_kb IS NOT NULL); per semaphore, every semaphore (the small-query one has no max target on
-- some versions: it is shown, its max target empty).
--
-- The findings, each with its source's threshold:
--   memory grant timeouts (warning)   a pool's timeout_error_count grew over the window (sp_PressureDetector and
--     PerformanceMonitor show the counter; a query that times out waiting for a grant fails with error 8645, or runs
--     with the minimum grant). Forced grants are raised by 0115 (sp_PerfCheck 4101), not again here.
--   low memory notification (warning)  a RESOURCE_MEMPHYSICAL_LOW or RESOURCE_MEMVIRTUAL_LOW record whose process or
--     system indicator is over 1 in the window (sp_PressureDetector's low_memory filter).
--   high memory use for In-Memory OLTP (warning)  MEMORYCLERK_XTP over 25 % of max server memory or over 250,000 MB
--     (sp_Blitz 145, priority 10); In-Memory OLTP in use (info): over 1,000 MB (sp_Blitz 146, priority 200).
--   memory leak in USERSTORE_TOKENPERM cache (warning)  TokenAndPermUserStore 10 % or more of all clerks' memory with
--     1 GB or more in all (sp_BlitzFirst 45, sp_Blitz's twin).
--   a memory grant over 15 % of max workspace (warning)  a grant of the newest read over 15 % of Maximum Workspace
--     Memory, the workspace counted in whole MB as its source does (sp_BlitzFirst 46, @MemoryGrantThresholdPct 15).
--   plan cache bloat with optimize for ad hoc workloads off (info)  PerformanceMonitor's bloat level MEDIUM or worse
--     (single-use plans over 20 % of the plans) while 'optimize for ad hoc workloads' is 0 (Glenn Berry's instance
--     query 50 names the pair and gives no number: the number is PerformanceMonitor's).
--   instant file initialization off (info)  the engine service of sys.dm_server_services with
--     instant_file_initialization_enabled N (mssql_service.ifi_enabled false), as read in the last 3 hours (0074's guard
--     on a newest-read table): the state now, whatever the window.
--
-- Ported in part from sp_PressureDetector and PerformanceMonitor (MIT License, Copyright (c) Erik Darling, Darling Data
-- LLC) and the First Responder Kit's sp_Blitz / sp_BlitzFirst (MIT License, Copyright (c) Brent Ozar Unlimited): the
-- reads' columns, filters and thresholds above. Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the "Software"), to deal in the Software without
-- restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
-- and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the
-- following conditions: The above copyright notice and this permission notice shall be included in all copies or
-- substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
-- NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
-- SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- For the join (this file sorts after 0110 and before 0190): the arm in pgvigil.findings
--     SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_memory', at
--       FROM pgvigil.mssql_memory_findings
--   and 'mssql_memory_rmon', 'mssql_memory_cache', 'mssql_plancache_type', 'mssql_memory_grant_query' on purge()'s
--   month-partition parents.

ALTER TABLE pgvigil.mssql_memory_sample
  ADD COLUMN IF NOT EXISTS xtp_kb bigint,
  ADD COLUMN IF NOT EXISTS tokenperm_kb bigint,
  ADD COLUMN IF NOT EXISTS max_workspace_kb bigint,
  ADD COLUMN IF NOT EXISTS granted_workspace_kb bigint;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_memory_rmon (
  instance_id    int NOT NULL,
  server_start   text NOT NULL,            -- sys.dm_os_sys_info.sqlserver_start_time as the server reads it
  record_id      bigint NOT NULL,          -- /Record/@id
  snapshot_at    timestamptz NOT NULL,     -- the record's own time in UTC (ensure_month_partition's index key)
  notification   text,                     -- RESOURCE_MEMPHYSICAL_LOW, RESOURCE_MEMPHYSICAL_HIGH, RESOURCE_MEM_STEADY ...
  ind_process    int,                      -- IndicatorsProcess
  ind_system     int,                      -- IndicatorsSystem
  avail_phys_kb  bigint,
  avail_vas_kb   bigint,
  read_at        timestamptz NOT NULL      -- the read that stored it
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_memory_cache (
  instance_id      int NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  cache_name       text NOT NULL,
  pages_kb         bigint,
  pages_in_use_kb  bigint,
  entries          bigint,
  entries_in_use   bigint
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_plancache_type (
  instance_id      int NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  cache_type       text NOT NULL,           -- cacheobjtype: Compiled Plan, Parse Tree, Extended Proc ...
  object_type      text NOT NULL,           -- objtype: Adhoc, Prepared, Proc, View, Trigger ...
  plans            bigint,
  size_kb          bigint,
  single_use_plans bigint,
  single_use_kb    bigint,
  multi_use_plans  bigint,
  multi_use_kb     bigint,
  avg_use_count    numeric
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_memory_grant_query (
  instance_id        int NOT NULL,
  snapshot_at        timestamptz NOT NULL,
  session_id         int NOT NULL,
  request_id         int,
  database_name      text,
  request_at         timestamptz,
  grant_at           timestamptz,            -- NULL: still waiting
  wait_time_ms       bigint,
  requested_kb       bigint,
  granted_kb         bigint,
  used_kb            bigint,
  max_used_kb        bigint,
  ideal_kb           bigint,
  required_kb        bigint,
  queue_id           int,
  wait_order         int,
  is_next_candidate  boolean,
  timeout_sec        int,
  semaphore_id       int,
  pool_id            int,
  group_id           int,
  is_small           boolean,
  dop                int,
  query_cost         double precision,
  wait_type          text,                   -- the session's longest waiting task's
  wait_ms            bigint,
  plan_handle        text,
  statement          text
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_rg_group (
  instance_id           int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  group_id              int NOT NULL,
  snapshot_at           timestamptz NOT NULL,
  group_name            text,
  pool_id               int,
  importance            text,
  max_grant_pct         int,                 -- request_max_memory_grant_percent
  max_cpu_sec           int,
  grant_timeout_sec     int,
  max_requests          int,
  max_dop               int,
  reduced_grants        bigint,              -- total_reduced_memgrant_count
  requests              bigint,
  active_requests       int,
  queued_requests       int,
  max_request_grant_kb  bigint,
  PRIMARY KEY (instance_id, group_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_rg_pool (
  instance_id        int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  pool_id            int NOT NULL,
  snapshot_at        timestamptz NOT NULL,
  pool_name          text,
  min_memory_pct     int,
  max_memory_pct     int,
  max_memory_kb      bigint,
  used_memory_kb     bigint,
  target_memory_kb   bigint,
  cache_memory_kb    bigint,
  used_memgrant_kb   bigint,
  memgrants          bigint,
  memgrant_timeouts  bigint,
  memgrant_waiters   int,
  out_of_memory      bigint,
  PRIMARY KEY (instance_id, pool_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_memory_reads (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  skipped       jsonb NOT NULL DEFAULT '[]',     -- [{read, error}]
  rmon_start    text,                            -- the ring buffer's watermark: the server start and the newest record id
  rmon_last_id  bigint                           -- stored, kept when purge() drops the records' month
);

-- import_mssql_memory (0115) with D13's kinds: 0115's body unchanged but the sample's four new columns, D13's blocks
-- after the NUMA block
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_memory(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_m  jsonb;
  v_g  jsonb;
  v_t  jsonb;
  v_c  jsonb;
  v_n  jsonb;
  v_mo timestamptz;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_memory: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  SELECT r INTO v_m FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'memory' LIMIT 1;
  IF v_m IS NULL THEN
    RAISE EXCEPTION 'import_mssql_memory: the payload has no memory row';
  END IF;
  SELECT r INTO v_g FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'grants' LIMIT 1;
  SELECT r INTO v_t FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'clerks' LIMIT 1;
  SELECT coalesce(jsonb_object_agg(r->>'counter', (r->>'value')::bigint), '{}') INTO v_c
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'counter' AND r->>'counter' IS NOT NULL;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_memory'), p_instance_id);
  PERFORM pgvigil.ensure_month_partition('mssql_memory_clerk', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_memory_sample', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_memory_pool', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_memory_cache', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_plancache_type', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_memory_grant_query', p_snapshot_at);
  -- the ring buffer reaches back days: a partition for each month its records fall in
  FOR v_mo IN SELECT DISTINCT date_trunc('month', (r->>'sample_at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
                FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'rmon' AND r->>'sample_at' IS NOT NULL
  LOOP
    PERFORM pgvigil.ensure_month_partition('mssql_memory_rmon', v_mo);
  END LOOP;
  LOCK TABLE ONLY pgvigil.mssql_memory_clerk, ONLY pgvigil.mssql_memory_sample, ONLY pgvigil.mssql_memory_pool,
             ONLY pgvigil.mssql_memory_cache, ONLY pgvigil.mssql_plancache_type, ONLY pgvigil.mssql_memory_grant_query,
             ONLY pgvigil.mssql_memory_rmon IN ROW EXCLUSIVE MODE;

  DELETE FROM pgvigil.mssql_memory_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_memory_sample (instance_id, snapshot_at, physical_kb, available_kb, system_state, process_kb, process_low,
      committed_kb, committed_target_kb, target_kb, total_kb, stolen_kb, buffer_pool_kb, plan_cache_kb, clerks_kb, ple,
      grants_pending, grants_outstanding, sem_granted, sem_waiting, sem_granted_kb, sem_target_kb, grants, grants_waiting,
      max_grant_kb, sum_grant_kb, max_requested_kb, memory_model, xtp_kb, tokenperm_kb, max_workspace_kb, granted_workspace_kb)
  VALUES (p_instance_id, p_snapshot_at, (v_m->>'physical_kb')::bigint, (v_m->>'available_kb')::bigint, v_m->>'system_state',
          (v_m->>'process_kb')::bigint, ((v_m->>'process_low')::int = 1), (v_m->>'committed_kb')::bigint, (v_m->>'committed_target_kb')::bigint,
          (v_c->>'Target Server Memory (KB)')::bigint, (v_c->>'Total Server Memory (KB)')::bigint, (v_c->>'Stolen Server Memory (KB)')::bigint,
          (v_c->>'Database Cache Memory (KB)')::bigint, (v_t->>'plan_cache_kb')::bigint, (v_t->>'clerks_kb')::bigint,
          (v_c->>'Page life expectancy')::bigint, (v_c->>'Memory Grants Pending')::int, (v_c->>'Memory Grants Outstanding')::int,
          (v_g->>'sem_granted')::int, (v_g->>'sem_waiting')::int, (v_g->>'sem_granted_kb')::bigint, (v_g->>'sem_target_kb')::bigint,
          (v_g->>'grants')::int, (v_g->>'grants_waiting')::int, (v_g->>'max_grant_kb')::bigint, (v_g->>'sum_grant_kb')::bigint,
          (v_g->>'max_requested_kb')::bigint, v_m->>'memory_model', (v_t->>'xtp_kb')::bigint, (v_t->>'tokenperm_kb')::bigint,
          (v_c->>'Maximum Workspace Memory (KB)')::bigint, (v_c->>'Granted Workspace Memory (KB)')::bigint);

  DELETE FROM pgvigil.mssql_memory_clerk WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_memory_clerk (instance_id, snapshot_at, clerk_type, pages_kb, vm_committed_kb)
  SELECT p_instance_id, p_snapshot_at, x.clerk_type, x.pages_kb, x.vm_committed_kb
    FROM (SELECT DISTINCT ON (r->>'clerk_type') r->>'clerk_type' AS clerk_type, (r->>'pages_kb')::bigint AS pages_kb,
                 (r->>'vm_committed_kb')::bigint AS vm_committed_kb
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'clerk' AND r->>'clerk_type' IS NOT NULL AND r->>'pages_kb' IS NOT NULL) x;
  -- the clerks past the 25 listed, as one row: the listed ones and this add up to the total
  INSERT INTO pgvigil.mssql_memory_clerk (instance_id, snapshot_at, clerk_type, pages_kb)
  SELECT p_instance_id, p_snapshot_at, '(other)', (v_t->>'clerks_kb')::bigint - sum(c.pages_kb)
    FROM pgvigil.mssql_memory_clerk c
   WHERE c.instance_id = p_instance_id AND c.snapshot_at = p_snapshot_at AND v_t->>'clerks_kb' IS NOT NULL
  HAVING (v_t->>'clerks_kb')::bigint - sum(c.pages_kb) > 0;

  -- 0115: the semaphores of the read (a collector before 0115 sends none: nothing is stored)
  DELETE FROM pgvigil.mssql_memory_pool WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_memory_pool (instance_id, snapshot_at, pool_id, pool_name, semaphore_id, target_kb, max_target_kb, total_kb,
      available_kb, granted_kb, used_kb, grantees, waiters, timeout_errors, forced_grants)
  SELECT DISTINCT ON ((r->>'pool_id')::int, (r->>'semaphore_id')::int)
         p_instance_id, p_snapshot_at, (r->>'pool_id')::int, r->>'pool_name', (r->>'semaphore_id')::int, (r->>'target_kb')::bigint,
         (r->>'max_target_kb')::bigint, (r->>'total_kb')::bigint, (r->>'available_kb')::bigint, (r->>'granted_kb')::bigint,
         (r->>'used_kb')::bigint, (r->>'grantees')::int, (r->>'waiters')::int, (r->>'timeout_errors')::bigint, (r->>'forced_grants')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'pool' AND r->>'pool_id' IS NOT NULL AND r->>'semaphore_id' IS NOT NULL;
  SELECT r INTO v_n FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'numa' LIMIT 1;
  IF v_n IS NOT NULL THEN
    INSERT INTO pgvigil.mssql_memory_numa AS m (instance_id, snapshot_at, node0_schedulers, other_nodes)
    VALUES (p_instance_id, p_snapshot_at, (v_n->>'node0_schedulers')::int, (v_n->>'other_nodes')::int)
    ON CONFLICT (instance_id) DO UPDATE
       SET snapshot_at = EXCLUDED.snapshot_at, node0_schedulers = EXCLUDED.node0_schedulers, other_nodes = EXCLUDED.other_nodes
     WHERE m.snapshot_at <= EXCLUDED.snapshot_at;
  END IF;

  -- 0119 (D13): the resource monitor's records past the newest stored for the same server start
  INSERT INTO pgvigil.mssql_memory_rmon (instance_id, server_start, record_id, snapshot_at, notification, ind_process, ind_system,
      avail_phys_kb, avail_vas_kb, read_at)
  SELECT DISTINCT ON (r->>'server_start', (r->>'record_id')::bigint)
         p_instance_id, r->>'server_start', (r->>'record_id')::bigint, (r->>'sample_at')::timestamptz, r->>'notification',
         (r->>'ind_process')::int, (r->>'ind_system')::int, (r->>'avail_phys_kb')::bigint, (r->>'avail_vas_kb')::bigint, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'rmon' AND r->>'record_id' IS NOT NULL AND r->>'server_start' IS NOT NULL AND r->>'sample_at' IS NOT NULL
     AND (r->>'record_id')::bigint > greatest(
           coalesce((SELECT max(x.record_id) FROM pgvigil.mssql_memory_rmon x
                      WHERE x.instance_id = p_instance_id AND x.server_start = r->>'server_start'), -1),
           coalesce((SELECT w.rmon_last_id FROM pgvigil.mssql_memory_reads w
                      WHERE w.instance_id = p_instance_id AND w.rmon_start = r->>'server_start'), -1));

  DELETE FROM pgvigil.mssql_memory_cache WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_memory_cache (instance_id, snapshot_at, cache_name, pages_kb, pages_in_use_kb, entries, entries_in_use)
  SELECT DISTINCT ON (r->>'cache_name') p_instance_id, p_snapshot_at, r->>'cache_name', (r->>'pages_kb')::bigint,
         (r->>'pages_in_use_kb')::bigint, (r->>'entries')::bigint, (r->>'entries_in_use')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'cache' AND r->>'cache_name' IS NOT NULL;

  DELETE FROM pgvigil.mssql_plancache_type WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_plancache_type (instance_id, snapshot_at, cache_type, object_type, plans, size_kb, single_use_plans,
      single_use_kb, multi_use_plans, multi_use_kb, avg_use_count)
  SELECT DISTINCT ON (r->>'cache_type', r->>'object_type') p_instance_id, p_snapshot_at, r->>'cache_type', r->>'object_type',
         (r->>'plans')::bigint, (r->>'size_kb')::bigint, (r->>'single_use_plans')::bigint, (r->>'single_use_kb')::bigint,
         (r->>'multi_use_plans')::bigint, (r->>'multi_use_kb')::bigint, (r->>'avg_use_count')::numeric
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'plantype' AND r->>'cache_type' IS NOT NULL AND r->>'object_type' IS NOT NULL;

  DELETE FROM pgvigil.mssql_memory_grant_query WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_memory_grant_query (instance_id, snapshot_at, session_id, request_id, database_name, request_at, grant_at,
      wait_time_ms, requested_kb, granted_kb, used_kb, max_used_kb, ideal_kb, required_kb, queue_id, wait_order, is_next_candidate,
      timeout_sec, semaphore_id, pool_id, group_id, is_small, dop, query_cost, wait_type, wait_ms, plan_handle, statement)
  SELECT p_instance_id, p_snapshot_at, (r->>'session_id')::int, (r->>'request_id')::int, r->>'database_name',
         p_snapshot_at - make_interval(secs => (r->>'request_age_ms')::bigint / 1000.0),
         p_snapshot_at - make_interval(secs => (r->>'grant_age_ms')::bigint / 1000.0),
         (r->>'wait_time_ms')::bigint, (r->>'requested_kb')::bigint, (r->>'granted_kb')::bigint, (r->>'used_kb')::bigint,
         (r->>'max_used_kb')::bigint, (r->>'ideal_kb')::bigint, (r->>'required_kb')::bigint, (r->>'queue_id')::int,
         (r->>'wait_order')::int, (r->>'is_next_candidate')::int = 1, (r->>'timeout_sec')::int, (r->>'semaphore_id')::int,
         (r->>'pool_id')::int, (r->>'group_id')::int, (r->>'is_small')::int = 1, (r->>'dop')::int, (r->>'query_cost')::double precision,
         r->>'wait_type', (r->>'wait_ms')::bigint, r->>'plan_handle', r->>'statement'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'mgrant' AND r->>'session_id' IS NOT NULL;

  -- the Resource Governor: the newest read replaces the last (a read the server refused keeps the last)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'rgroup') THEN
    DELETE FROM pgvigil.mssql_rg_group WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_rg_group (instance_id, group_id, snapshot_at, group_name, pool_id, importance, max_grant_pct, max_cpu_sec,
        grant_timeout_sec, max_requests, max_dop, reduced_grants, requests, active_requests, queued_requests, max_request_grant_kb)
    SELECT DISTINCT ON ((r->>'group_id')::int) p_instance_id, (r->>'group_id')::int, p_snapshot_at, r->>'group_name', (r->>'pool_id')::int,
           r->>'importance', (r->>'max_grant_pct')::int, (r->>'max_cpu_sec')::int, (r->>'grant_timeout_sec')::int, (r->>'max_requests')::int,
           (r->>'max_dop')::int, (r->>'reduced_grants')::bigint, (r->>'requests')::bigint, (r->>'active_requests')::int,
           (r->>'queued_requests')::int, (r->>'max_request_grant_kb')::bigint
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'rgroup' AND r->>'group_id' IS NOT NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'rpool') THEN
    DELETE FROM pgvigil.mssql_rg_pool WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_rg_pool (instance_id, pool_id, snapshot_at, pool_name, min_memory_pct, max_memory_pct, max_memory_kb,
        used_memory_kb, target_memory_kb, cache_memory_kb, used_memgrant_kb, memgrants, memgrant_timeouts, memgrant_waiters, out_of_memory)
    SELECT DISTINCT ON ((r->>'pool_id')::int) p_instance_id, (r->>'pool_id')::int, p_snapshot_at, r->>'pool_name',
           (r->>'min_memory_pct')::int, (r->>'max_memory_pct')::int, (r->>'max_memory_kb')::bigint, (r->>'used_memory_kb')::bigint,
           (r->>'target_memory_kb')::bigint, (r->>'cache_memory_kb')::bigint, (r->>'used_memgrant_kb')::bigint, (r->>'memgrants')::bigint,
           (r->>'memgrant_timeouts')::bigint, (r->>'memgrant_waiters')::int, (r->>'out_of_memory')::bigint
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'rpool' AND r->>'pool_id' IS NOT NULL;
  END IF;

  -- the watermark: the newest record of the newest server start read (a purge of the records' month cannot bring them back)
  INSERT INTO pgvigil.mssql_memory_reads AS m (instance_id, snapshot_at, skipped, rmon_start, rmon_last_id)
  SELECT p_instance_id, p_snapshot_at,
         coalesce((SELECT jsonb_agg(jsonb_build_object('read', r->>'read', 'error', r->>'error'))
                     FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'skip'), '[]'),
         w.s, w.id
    FROM (SELECT max(r->>'server_start') AS s, max((r->>'record_id')::bigint) AS id
            FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'rmon' AND r->>'record_id' IS NOT NULL) w
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, skipped = EXCLUDED.skipped,
         rmon_start = coalesce(EXCLUDED.rmon_start, m.rmon_start),
         rmon_last_id = CASE WHEN EXCLUDED.rmon_start IS NULL THEN m.rmon_last_id
                             WHEN EXCLUDED.rmon_start IS DISTINCT FROM m.rmon_start THEN EXCLUDED.rmon_last_id
                             ELSE greatest(EXCLUDED.rmon_last_id, m.rmon_last_id) END
   WHERE m.snapshot_at <= EXCLUDED.snapshot_at;
END $$;

-- the semaphores of a window, per pool (its semaphores with a max target summed per read) or per semaphore
CREATE OR REPLACE FUNCTION pgvigil.mssql_grant_window_between(p_instance_id int, p_from timestamptz, p_to timestamptz, p_by_semaphore boolean)
RETURNS TABLE (pool_id int, pool_name text, semaphore_id int, snapshots int, peak_waiters int, peak_waiters_at timestamptz,
               peak_granted_kb bigint, peak_granted_at timestamptz, min_available_kb bigint, timeouts bigint, forced_grants bigint,
               first_at timestamptz, last_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT p.snapshot_at, p.pool_id, p.pool_name, p.semaphore_id, p.waiters, p.granted_kb, p.available_kb
      FROM pgvigil.mssql_memory_pool p
     WHERE p.instance_id = p_instance_id AND p.snapshot_at > p_from AND p.snapshot_at <= p_to
       AND (p_by_semaphore OR p.max_target_kb IS NOT NULL)),
  r AS (
    SELECT s.snapshot_at, s.pool_id, max(s.pool_name) AS pool_name, CASE WHEN p_by_semaphore THEN s.semaphore_id END AS semaphore_id,
           sum(s.waiters)::int AS waiters, sum(s.granted_kb)::bigint AS granted_kb, sum(s.available_kb)::bigint AS available_kb
      FROM s GROUP BY s.snapshot_at, s.pool_id, 4),
  d AS (
    SELECT g.pool_id, CASE WHEN p_by_semaphore THEN g.semaphore_id END AS semaphore_id,
           sum(g.timeout_errors)::bigint AS timeouts, sum(g.forced_grants)::bigint AS forced
      FROM pgvigil.mssql_grant_deltas(p_instance_id, p_from, p_to) g
     WHERE EXISTS (SELECT 1 FROM s WHERE s.pool_id = g.pool_id AND s.semaphore_id = g.semaphore_id)
     GROUP BY 1, 2)
  SELECT r.pool_id, max(r.pool_name), r.semaphore_id, count(*)::int,
         max(r.waiters), (array_agg(r.snapshot_at ORDER BY r.waiters DESC NULLS LAST, r.snapshot_at DESC))[1],
         max(r.granted_kb), (array_agg(r.snapshot_at ORDER BY r.granted_kb DESC NULLS LAST, r.snapshot_at DESC))[1],
         min(r.available_kb), coalesce(max(d.timeouts), 0), coalesce(max(d.forced), 0), min(r.snapshot_at), max(r.snapshot_at)
    FROM r LEFT JOIN d ON d.pool_id = r.pool_id AND d.semaphore_id IS NOT DISTINCT FROM r.semaphore_id
   GROUP BY r.pool_id, r.semaphore_id
   ORDER BY r.pool_id, r.semaphore_id
$$;

-- the newest read of a window, per pool or per semaphore, the counters' growth since the read before it (at most ten
-- minutes before) and their values since the server started
CREATE OR REPLACE FUNCTION pgvigil.mssql_grant_newest_between(p_instance_id int, p_from timestamptz, p_to timestamptz, p_by_semaphore boolean)
RETURNS TABLE (snapshot_at timestamptz, pool_id int, pool_name text, semaphore_id int, target_kb bigint, max_target_kb bigint,
               total_kb bigint, granted_kb bigint, used_kb bigint, available_kb bigint, grantees int, waiters int,
               timeouts_delta bigint, forced_delta bigint, timeouts_total bigint, forced_total bigint, previous_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH n AS (SELECT max(p.snapshot_at) AS at FROM pgvigil.mssql_memory_pool p
              WHERE p.instance_id = p_instance_id AND p.snapshot_at > p_from AND p.snapshot_at <= p_to),
  v AS (SELECT max(p.snapshot_at) AS at FROM pgvigil.mssql_memory_pool p, n
         WHERE p.instance_id = p_instance_id AND p.snapshot_at < n.at AND p.snapshot_at >= n.at - interval '10 minutes'),
  s AS (
    SELECT c.*, (SELECT v.at FROM v) AS prev_at,
           CASE WHEN o.timeout_errors IS NULL THEN NULL WHEN c.timeout_errors >= o.timeout_errors THEN c.timeout_errors - o.timeout_errors ELSE c.timeout_errors END AS t_d,
           CASE WHEN o.forced_grants IS NULL THEN NULL WHEN c.forced_grants >= o.forced_grants THEN c.forced_grants - o.forced_grants ELSE c.forced_grants END AS f_d
      FROM pgvigil.mssql_memory_pool c
      JOIN n ON c.snapshot_at = n.at
      LEFT JOIN pgvigil.mssql_memory_pool o ON o.instance_id = c.instance_id AND o.snapshot_at = (SELECT v.at FROM v)
                                           AND o.pool_id = c.pool_id AND o.semaphore_id = c.semaphore_id
     WHERE c.instance_id = p_instance_id AND (p_by_semaphore OR c.max_target_kb IS NOT NULL))
  SELECT s.snapshot_at, s.pool_id, max(s.pool_name), CASE WHEN p_by_semaphore THEN s.semaphore_id END,
         sum(s.target_kb)::bigint, sum(s.max_target_kb)::bigint, sum(s.total_kb)::bigint, sum(s.granted_kb)::bigint, sum(s.used_kb)::bigint,
         sum(s.available_kb)::bigint, sum(s.grantees)::int, sum(s.waiters)::int, sum(s.t_d)::bigint, sum(s.f_d)::bigint,
         sum(s.timeout_errors)::bigint, sum(s.forced_grants)::bigint, max(s.prev_at)
    FROM s
   GROUP BY s.snapshot_at, s.pool_id, 4
   ORDER BY s.pool_id, 4
$$;

-- per step and pool (its semaphores with a max target): the most waiters, the average granted and the least available
-- memory, the timeouts and forced grants of the step (each difference counted at the later read)
CREATE OR REPLACE FUNCTION pgvigil.mssql_grant_series_between(p_instance_id int, p_from timestamptz, p_to timestamptz, p_step int)
RETURNS TABLE (at timestamptz, pool_id int, pool_name text, waiters int, granted_kb numeric, available_kb bigint, timeouts bigint, forced_grants bigint)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT p.snapshot_at, p.pool_id, p.pool_name, p.semaphore_id, p.waiters, p.granted_kb, p.available_kb, p.timeout_errors, p.forced_grants,
           lag(p.timeout_errors) OVER w AS prev_t, lag(p.forced_grants) OVER w AS prev_f
      FROM pgvigil.mssql_memory_pool p
     WHERE p.instance_id = p_instance_id AND p.snapshot_at > p_from - interval '10 minutes' AND p.snapshot_at <= p_to
       AND p.max_target_kb IS NOT NULL
    WINDOW w AS (PARTITION BY p.pool_id, p.semaphore_id ORDER BY p.snapshot_at)),
  r AS (
    SELECT s.snapshot_at, s.pool_id, max(s.pool_name) AS pool_name, sum(s.waiters)::int AS waiters, sum(s.granted_kb) AS granted_kb,
           sum(s.available_kb)::bigint AS available_kb,
           sum(CASE WHEN s.prev_t IS NULL THEN 0 WHEN s.timeout_errors >= s.prev_t THEN s.timeout_errors - s.prev_t ELSE s.timeout_errors END)::bigint AS t,
           sum(CASE WHEN s.prev_f IS NULL THEN 0 WHEN s.forced_grants >= s.prev_f THEN s.forced_grants - s.prev_f ELSE s.forced_grants END)::bigint AS f
      FROM s WHERE s.snapshot_at > p_from GROUP BY s.snapshot_at, s.pool_id)
  SELECT to_timestamp(floor(extract(epoch FROM r.snapshot_at) / p_step) * p_step), r.pool_id, max(r.pool_name), max(r.waiters),
         round(avg(r.granted_kb), 0), min(r.available_kb), sum(r.t)::bigint, sum(r.f)::bigint
    FROM r GROUP BY 1, 2 ORDER BY 1, 2
$$;

-- PerformanceMonitor's pressure events per hour (a sample counts when an indicator reads 2 or more)
CREATE OR REPLACE FUNCTION pgvigil.mssql_memory_rmon_hourly(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (at timestamptz, sql_medium int, sql_severe int, os_medium int, os_severe int)
LANGUAGE sql STABLE AS $$
  WITH e AS (
    SELECT date_trunc('hour', r.snapshot_at) AS h,
           count(*) FILTER (WHERE r.ind_process = 2)::int AS sm, count(*) FILTER (WHERE r.ind_process >= 3)::int AS ss,
           count(*) FILTER (WHERE r.ind_system = 2)::int AS om, count(*) FILTER (WHERE r.ind_system >= 3)::int AS os
      FROM pgvigil.mssql_memory_rmon r
     WHERE r.instance_id = p_instance_id AND r.snapshot_at > p_from AND r.snapshot_at <= p_to
       AND (r.ind_process >= 2 OR r.ind_system >= 2)
     GROUP BY 1)
  -- every hour of the window, an hour with none as 0 (PerformanceMonitor's pressureEventBuckets)
  SELECT g.h, coalesce(e.sm, 0), coalesce(e.ss, 0), coalesce(e.om, 0), coalesce(e.os, 0)
    FROM generate_series(date_trunc('hour', p_from), p_to, interval '1 hour') AS g(h)
    LEFT JOIN e ON e.h = g.h
   WHERE p_to - p_from <= interval '62 days'
   ORDER BY 1
$$;

-- the newest plan cache read of a window: its totals and PerformanceMonitor's bloat level and recommendation
CREATE OR REPLACE FUNCTION pgvigil.mssql_plancache_summary_between(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, plans bigint, single_use_plans bigint, single_use_pct numeric, size_kb bigint,
               single_use_kb bigint, wasted_pct numeric, bloat_level text, recommendation text, optimize_for_ad_hoc bigint,
               sqlcp_kb bigint)
LANGUAGE sql STABLE AS $$
  WITH n AS (SELECT max(t.snapshot_at) AS at FROM pgvigil.mssql_plancache_type t
              WHERE t.instance_id = p_instance_id AND t.snapshot_at > p_from AND t.snapshot_at <= p_to),
  s AS (SELECT n.at, sum(t.plans)::bigint AS plans, sum(t.single_use_plans)::bigint AS su, sum(t.size_kb)::bigint AS kb,
               sum(t.single_use_kb)::bigint AS su_kb
          FROM pgvigil.mssql_plancache_type t JOIN n ON t.snapshot_at = n.at
         WHERE t.instance_id = p_instance_id GROUP BY n.at),
  x AS (SELECT s.*, CASE WHEN s.plans > 0 THEN s.su * 100.0 / s.plans ELSE 0 END AS pct FROM s)
  SELECT x.at, x.plans, x.su, round(x.pct, 1), x.kb, x.su_kb,
         CASE WHEN x.kb > 0 THEN round(100.0 * x.su_kb / x.kb, 1) ELSE 0 END,
         CASE WHEN x.pct > 50 THEN 'CRITICAL' WHEN x.pct > 30 THEN 'HIGH' WHEN x.pct > 20 THEN 'MEDIUM' ELSE 'NORMAL' END,
         CASE WHEN x.pct > 20 THEN 'Check for unparameterized queries / Consider Forced Parameterization' ELSE 'Plan cache composition is healthy' END,
         (SELECT c.value_in_use FROM pgvigil.mssql_config c WHERE c.instance_id = p_instance_id AND c.name = 'optimize for ad hoc workloads' AND c.is_present),
         (SELECT k.pages_kb FROM pgvigil.mssql_memory_clerk k
           WHERE k.instance_id = p_instance_id AND k.clerk_type = 'CACHESTORE_SQLCP'
             AND k.snapshot_at = (SELECT max(m.snapshot_at) FROM pgvigil.mssql_memory_clerk m
                                   WHERE m.instance_id = p_instance_id AND m.snapshot_at <= x.at + interval '1 minute' AND m.snapshot_at > p_from))
    FROM x
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_memory_findings_between(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (instance_id int, severity text, check_name text, object text, at timestamptz, detail text)
LANGUAGE sql STABLE AS $$
  WITH ls AS (SELECT s.* FROM pgvigil.mssql_memory_sample s
               WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
               ORDER BY s.snapshot_at DESC LIMIT 1),
  msm AS (SELECT c.value_in_use AS mb FROM pgvigil.mssql_config c
           WHERE c.instance_id = p_instance_id AND c.name = 'max server memory (MB)' AND c.is_present),
  gw AS (SELECT * FROM pgvigil.mssql_grant_window_between(p_instance_id, p_from, p_to, false)),
  lg AS (SELECT g.* FROM pgvigil.mssql_memory_grant_query g
          WHERE g.instance_id = p_instance_id
            AND g.snapshot_at = (SELECT max(x.snapshot_at) FROM pgvigil.mssql_memory_sample x
                                  WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to)),
  lo AS (SELECT r.notification, count(*) AS n, max(r.snapshot_at) AS last_at, max(r.ind_process) AS ip, max(r.ind_system) AS isy,
                min(r.avail_phys_kb) AS phys
           FROM pgvigil.mssql_memory_rmon r
          WHERE r.instance_id = p_instance_id AND r.snapshot_at > p_from AND r.snapshot_at <= p_to
            AND r.notification IN ('RESOURCE_MEMPHYSICAL_LOW', 'RESOURCE_MEMVIRTUAL_LOW') AND (r.ind_process > 1 OR r.ind_system > 1)
          GROUP BY r.notification),
  pc AS (SELECT * FROM pgvigil.mssql_plancache_summary_between(p_instance_id, p_from, p_to))
  SELECT p_instance_id, 'warning', 'memory grant timeouts', coalesce(gw.pool_name, 'pool ' || gw.pool_id), gw.last_at,
         format('%s memory grant request(s) in resource pool %s timed out over the window (sys.dm_exec_query_resource_semaphores '
                'timeout_error_count, %s read(s) from %s to %s UTC; the most waiting at once %s). A query that times out '
                'waiting for its grant fails with error 8645, or runs with the minimum grant and spills.',
                gw.timeouts, coalesce(gw.pool_name, gw.pool_id::text), gw.snapshots,
                to_char(gw.first_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), to_char(gw.last_at AT TIME ZONE 'UTC', 'HH24:MI'), gw.peak_waiters)
    FROM gw WHERE gw.timeouts > 0
  UNION ALL
  SELECT p_instance_id, 'warning', 'low memory notification', lo.notification, lo.last_at,
         format('The resource monitor recorded %s %s notification(s) with an indicator over 1 in the window (the process''s up to %s, '
                'the system''s up to %s; the least available physical memory %s MB), the last at %s UTC: SQL Server was asked to '
                'shrink its memory (sp_PressureDetector''s low-memory read of RING_BUFFER_RESOURCE_MONITOR).',
                lo.n, lo.notification, coalesce(lo.ip::text, '-'), coalesce(lo.isy::text, '-'), coalesce((lo.phys / 1024)::text, '-'),
                to_char(lo.last_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'))
    FROM lo
  UNION ALL
  SELECT p_instance_id, 'warning', 'high memory use for In-Memory OLTP', 'MEMORYCLERK_XTP', ls.snapshot_at,
         format('MEMORYCLERK_XTP uses %s MB, %s %% of the %s MB max server memory (sp_Blitz 145: over 25 %% of max server memory, '
                'or over 250,000 MB).', round(ls.xtp_kb / 1024.0), round(100.0 * ls.xtp_kb / 1024.0 / msm.mb), msm.mb)
    FROM ls, msm WHERE msm.mb > 0 AND (ls.xtp_kb / 1024.0 > msm.mb * 0.25 OR ls.xtp_kb / 1024.0 > 250000)
  UNION ALL
  SELECT p_instance_id, 'info', 'In-Memory OLTP in use', 'MEMORYCLERK_XTP', ls.snapshot_at,
         format('MEMORYCLERK_XTP uses %s MB%s (sp_Blitz 146: over 1,000 MB).', round(ls.xtp_kb / 1024.0),
                CASE WHEN msm.mb > 0 THEN format(', %s %% of the %s MB max server memory', round(100.0 * ls.xtp_kb / 1024.0 / msm.mb, 1), msm.mb) ELSE '' END)
    FROM ls LEFT JOIN msm ON true WHERE ls.xtp_kb / 1024.0 > 1000
  UNION ALL
  SELECT p_instance_id, 'warning', 'memory leak in USERSTORE_TOKENPERM cache', 'TokenAndPermUserStore', ls.snapshot_at,
         format('The TokenAndPermUserStore of USERSTORE_TOKENPERM uses %s GB, %s %% of the %s GB in all memory clerks (sp_BlitzFirst 45: '
                '10 %% or more with 1 GB or more in all; DBCC FREESYSTEMCACHE (''TokenAndPermUserStore'') empties it).',
                round(ls.tokenperm_kb / 1024.0 / 1024.0, 2), round(100.0 * ls.tokenperm_kb / ls.clerks_kb, 1), round(ls.clerks_kb / 1024.0 / 1024.0, 2))
    FROM ls WHERE ls.clerks_kb > 0 AND ls.tokenperm_kb * 1.0 / ls.clerks_kb >= 0.1 AND ls.clerks_kb / 1024.0 / 1024.0 >= 1
  UNION ALL
  SELECT p_instance_id, 'warning', 'a memory grant over 15 % of max workspace', 'session ' || lg.session_id, lg.snapshot_at,
         format('Session %s holds a grant of %s MB, %s %% of the %s MB Maximum Workspace Memory (sp_BlitzFirst 46, over 15 %%)%s: %s',
                lg.session_id, lg.granted_kb / 1024, round(100.0 * (lg.granted_kb / 1024) / (ls.max_workspace_kb / 1024), 1),
                ls.max_workspace_kb / 1024, coalesce(' in ' || lg.database_name, ''), left(coalesce(lg.statement, '(no text)'), 300))
    FROM lg, ls
   WHERE ls.max_workspace_kb >= 1024 AND lg.granted_kb > 0.15 * ((ls.max_workspace_kb / 1024) * 1024)
  UNION ALL
  -- the read lists the 50 largest asks; a larger grant outside them is still the read's largest (mssql_memory_sample)
  SELECT p_instance_id, 'warning', 'a memory grant over 15 % of max workspace', 'the largest grant', ls.snapshot_at,
         format('The largest grant of the read is %s MB, %s %% of the %s MB Maximum Workspace Memory (sp_BlitzFirst 46, over 15 %%); '
                'its session is not among the 50 largest asks listed.', ls.max_grant_kb / 1024,
                round(100.0 * (ls.max_grant_kb / 1024) / (ls.max_workspace_kb / 1024), 1), ls.max_workspace_kb / 1024)
    FROM ls
   WHERE ls.max_workspace_kb >= 1024 AND ls.max_grant_kb > 0.15 * ((ls.max_workspace_kb / 1024) * 1024)
     AND NOT EXISTS (SELECT 1 FROM lg WHERE lg.granted_kb > 0.15 * ((ls.max_workspace_kb / 1024) * 1024))
  UNION ALL
  SELECT p_instance_id, 'info', 'plan cache bloat with optimize for ad hoc workloads off', 'plan cache', pc.snapshot_at,
         format('%s %% of the %s cached plans are used once (%s KB of %s KB, PerformanceMonitor''s bloat level %s; CACHESTORE_SQLCP '
                '%s MB) and ''optimize for ad hoc workloads'' is off: a single-use ad hoc plan is cached whole on its first run. %s.',
                pc.single_use_pct, pc.plans, pc.single_use_kb, pc.size_kb, pc.bloat_level, coalesce((pc.sqlcp_kb / 1024)::text, '-'), pc.recommendation)
    FROM pc WHERE pc.bloat_level <> 'NORMAL' AND pc.optimize_for_ad_hoc = 0
  UNION ALL
  SELECT p_instance_id, 'info', 'instant file initialization off', sv.service_name, sv.snapshot_at,
         format('Instant file initialization is off for %s (sys.dm_server_services, account %s): every data file growth and restore '
                'writes zeros over the new space first. Grant the account ''Perform volume maintenance tasks'' and restart the service.',
                sv.service_name, coalesce(sv.service_account, '-'))
    FROM pgvigil.mssql_service sv
   WHERE sv.instance_id = p_instance_id AND sv.is_present AND sv.ifi_enabled = false AND sv.service_name LIKE 'SQL Server (%'
     AND sv.snapshot_at > now() - interval '3 hours'
$$;

CREATE OR REPLACE VIEW pgvigil.mssql_memory_findings AS
SELECT i.instance_id, f.severity, f.check_name, f.object, f.at, f.detail
  FROM pgvigil.instances i
  CROSS JOIN LATERAL pgvigil.mssql_memory_findings_between(i.instance_id, now() - interval '15 minutes', now()) f
 WHERE i.engine = 'sqlserver';
