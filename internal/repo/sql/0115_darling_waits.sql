-- 0115: wait findings in Erik Darling's and the First Responder Kit's thresholds (task 177, darling-open D03), over the
-- differences of sys.dm_os_wait_stats that mssql_waits stores (0064, mssql_wait_sample) and the memory grant semaphores
-- that mssql_memory now reads per pool (internal/mssql/memory.go). Nothing is created, changed or switched on the
-- monitored server.
--
--   mssql_memory_pool     monthly partitions; one row per resource semaphore of sys.dm_exec_query_resource_semaphores
--                         per read: the pool, its target and max target, total, available, granted and used memory,
--                         grantees, waiters and the two counters since the server started (timeout errors, forced
--                         grants), whose differences between reads are the window's.
--   mssql_memory_numa     the newest read per instance: node 0's online schedulers and the other nodes that are not
--                         the DAC's (sys.dm_os_nodes), for sp_Blitz's CMEMTHREAD-on-NUMA check.
--   darling_benign_waits  sp_PerfCheck's list of benign waits, as data.
--   perfcheck_wait()      sp_PerfCheck's description and category of a wait type of its list, NULL outside it.
--   mssql_wait_covered()  the reads of a window: how many and the seconds their differences cover (the window's
--                         "uptime": every check below reads it where its source reads the server's uptime).
--   mssql_wait_findings_between(instance, from, to)   the findings over a window (the page's range, or the proof's);
--   mssql_wait_shares_between(instance, from, to)     the signal ratio with its label, SOS_SCHEDULER_YIELD and page
--                         latch time as shares of the window, the forced grants and grant timeouts of the window;
--   mssql_wait_rollup_between(instance, from, to)     the real waits by category (the category the Waits grid shows);
--   mssql_memory_pools_at(instance, at)               the semaphores of the newest read at or before at;
--   mssql_waits_findings  the findings over the last 15 minutes (instance_id, severity, check_name, object, at, detail).
--
-- The checks, each with its source's threshold and wording; the source's "uptime" (or "since startup") is the
-- window's covered seconds, and the counters' "since startup" the window's differences:
--   sp_PerfCheck 2.11 check 6001 (wait statistics): each wait type of its list whose time is more than 10 % of the
--     window, or whose average wait is more than 1,000 ms with at least 60 s in all; the ten largest, named by the
--     category's finding; priority High (20) at 50 % or more (or 1,000 ms average and 60 s), Medium (30) at 20 % (or
--     250 ms and 60 s), else Low (40), for the resource categories (Locking, Memory, I/O, TempDB Contention,
--     Transaction Log, CPU); Parallelism Medium only at 100 %; the others Low; SLEEP_TASK never raised.
--   sp_PerfCheck 6101: the signal wait ratio (signal / all wait time of the waits not on its benign list, SLEEP_TASK
--     left out) at 25 % or more: Low (40), 30 % Medium (30), 50 % High (20). The server-information line (Normal,
--     Moderate at 25 %, High at 50 %) is mssql_wait_shares_between's signal_label.
--   sp_PerfCheck 6102: SOS_SCHEDULER_YIELD time at 25 % of the window or more: Low, 30 % Medium, 50 % High; listed in
--     server information from 10 % (sos_listed).
--   sp_PerfCheck 2010 (Medium): page latch time (PAGELATCH_UP, _SH, _EX) at 1 % of the window or more (the source
--     divides two decimal(20,2) hour counts, which at uptime scale costs nothing and over a window of minutes moves the
--     share by tens of per cent: the share here is unrounded, the hours in the text are rounded as the source prints them) while tempdb has no more data files than the CPUs and fewer
--     than eight (the newest mssql_tempdb read, at most three hours old).
--   sp_PerfCheck 4101: forced grants (the largest difference of forced_grant_count over the window among the
--     semaphores) above 0: High at 10,000, Medium at 100, else Low. sp_Blitz 117 (the sum above 0) is named in its text.
--   sp_BlitzFirst 8.34 CheckID 30 (priority 10): a poison wait (its fourteen types) that grew by more than 1,000 ms.
--   sp_Blitz 8.34 check 121 (priority 50): range-lock waits (its nine LCK_M_R* types) above 5,000 ms per whole hour of
--     the window and above 60 s; check 162 (priority 50): CMEMTHREAD on a server whose node 0 has eight or more online
--     schedulers and another node that is not the DAC's, at the same floor, trace flag 8048 named.
-- Severity: sp_PerfCheck's own labels (10 Critical, 20 High, 30 Medium, 40 Low): Critical is critical, High and Medium
-- warning, Low info; sp_Blitz's 50 warning; the source and its priority end every text.
--
-- The lists, thresholds and texts are ported from the procedures' source:
--   sp_PerfCheck: Copyright 2026 Darling Data, LLC (https://www.erikdarling.com/), MIT.
--   sp_Blitz, sp_BlitzFirst (SQL Server First Responder Kit): Copyright (c) Brent Ozar Unlimited, MIT.
--   The MIT notice of both: Permission is hereby granted, free of charge, to any person obtaining a copy of this
--   software and associated documentation files (the "Software"), to deal in the Software without restriction,
--   including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
--   copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following
--   conditions: The above copyright notice and this permission notice shall be included in all copies or substantial
--   portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
--   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
--   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
--   SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- For the join (this file sorts after 0110): the arm in pgvigil.findings
--     SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_waits', at
--       FROM pgvigil.mssql_waits_findings
--   and 'mssql_memory_pool' on purge()'s month-partition parents.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_memory_pool (
  instance_id     int NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  pool_id         int NOT NULL,
  pool_name       text,
  semaphore_id    int NOT NULL,          -- 0 the regular semaphore, 1 the small-query one
  target_kb       bigint,
  max_target_kb   bigint,
  total_kb        bigint,
  available_kb    bigint,
  granted_kb      bigint,
  used_kb         bigint,
  grantees        int,
  waiters         int,
  timeout_errors  bigint,                -- since the server started
  forced_grants   bigint                 -- since the server started
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_memory_numa (
  instance_id       int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at       timestamptz NOT NULL,
  node0_schedulers  int,
  other_nodes       int
);

-- sp_PerfCheck 2.11's #benign_waits
CREATE TABLE IF NOT EXISTS pgvigil.darling_benign_waits (wait_type text PRIMARY KEY);
INSERT INTO pgvigil.darling_benign_waits (wait_type)
SELECT unnest(string_to_array(
  'BROKER_EVENTHANDLER BROKER_RECEIVE_WAITFOR BROKER_TASK_STOP BROKER_TO_FLUSH BROKER_TRANSMITTER CHECKPOINT_QUEUE '
  'CLR_AUTO_EVENT CLR_MANUAL_EVENT DIRTY_PAGE_POLL DISPATCHER_QUEUE_SEMAPHORE FSAGENT FT_IFTS_SCHEDULER_IDLE_WAIT '
  'FT_IFTSHC_MUTEX HADR_FILESTREAM_IOMGR_IOCOMPLETION HADR_LOGCAPTURE_WAIT HADR_TIMER_TASK HADR_WORK_QUEUE '
  'LAZYWRITER_SLEEP LOGMGR_QUEUE MEMORY_ALLOCATION_EXT ONDEMAND_TASK_QUEUE PARALLEL_REDO_DRAIN_WORKER '
  'PARALLEL_REDO_WORKER_WAIT_WORK PREEMPTIVE_XE_GETTARGETSTATE PVS_PREALLOCATE PWAIT_DIRECTLOGCONSUMER_GETNEXT '
  'PWAIT_EXTENSIBILITY_CLEANUP_TASK QDS_ASYNC_QUEUE QDS_PERSIST_TASK_MAIN_LOOP_SLEEP '
  'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP REQUEST_FOR_DEADLOCK_SEARCH RESOURCE_QUEUE SERVER_IDLE_CHECK '
  'SLEEP_DBSTARTUP SLEEP_DCOMSTARTUP SLEEP_MASTERDBREADY SLEEP_MASTERMDREADY SLEEP_MASTERUPGRADED SLEEP_MSDBSTARTUP '
  'SLEEP_SYSTEMTASK SLEEP_TEMPDBSTARTUP SNI_HTTP_ACCEPT SOS_WORK_DISPATCHER SP_SERVER_DIAGNOSTICS_SLEEP '
  'SQLTRACE_BUFFER_FLUSH SQLTRACE_INCREMENTAL_FLUSH_SLEEP SQLTRACE_WAIT_ENTRIES STARTUP_DEPENDENCY_MANAGER '
  'WAIT_FOR_RESULTS WAITFOR WAITFOR_TASKSHUTDOWN WAIT_XTP_HOST_WAIT WAIT_XTP_OFFLINE_CKPT_NEW_LOG WAIT_XTP_CKPT_CLOSE '
  'XE_DISPATCHER_JOIN XE_DISPATCHER_WAIT XE_LIVE_TARGET_TVF XE_TIMER_EVENT XTP_PREEMPTIVE_TASK', ' '))
ON CONFLICT DO NOTHING;

-- sp_PerfCheck 2.11's wait list (its #wait_stats insert): the description and the category of a wait type, NULL
-- outside the list
CREATE OR REPLACE FUNCTION pgvigil.perfcheck_wait(p_wait text, OUT description text, OUT category text)
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
           WHEN p_wait = 'PAGEIOLATCH_SH' THEN 'Selects reading pages from disk into memory'
           WHEN p_wait = 'PAGEIOLATCH_EX' THEN 'Modifications reading pages from disk into memory'
           WHEN p_wait = 'RESOURCE_SEMAPHORE' THEN 'Queries waiting to get memory to run'
           WHEN p_wait = 'RESOURCE_SEMAPHORE_QUERY_COMPILE' THEN 'Queries waiting to get memory to compile'
           WHEN p_wait IN ('CXPACKET', 'CXCONSUMER', 'CXSYNC_PORT', 'CXSYNC_CONSUMER') THEN 'Query parallelism'
           WHEN p_wait = 'SOS_SCHEDULER_YIELD' THEN 'Query scheduling'
           WHEN p_wait = 'THREADPOOL' THEN 'Potential worker thread exhaustion'
           WHEN p_wait = 'RESOURCE_GOVERNOR_IDLE' THEN 'Potential CPU cap waits'
           WHEN p_wait = 'CMEMTHREAD' THEN 'Tasks waiting on memory objects'
           WHEN p_wait IN ('PAGELATCH_EX', 'PAGELATCH_SH', 'PAGELATCH_UP') THEN 'Potential tempdb contention'
           WHEN p_wait LIKE 'LCK%' THEN 'Queries waiting to acquire locks'
           WHEN p_wait = 'WRITELOG' THEN 'Transaction Log writes'
           WHEN p_wait = 'LOGBUFFER' THEN 'Transaction Log buffering'
           WHEN p_wait IN ('LOG_RATE_GOVERNOR', 'POOL_LOG_RATE_GOVERNOR') THEN 'Azure Transaction Log throttling'
           WHEN p_wait = 'SLEEP_TASK' THEN 'Potential Hash spills'
           WHEN p_wait = 'BPSORT' THEN 'Potential batch mode sort performance issues'
           WHEN p_wait = 'EXECSYNC' THEN 'Potential eager index spool creation'
           WHEN p_wait = 'IO_COMPLETION' THEN 'Potential sort spills'
           WHEN p_wait = 'ASYNC_NETWORK_IO' THEN 'Potential client issues'
           WHEN p_wait = 'SLEEP_BPOOL_STEAL' THEN 'Potential buffer pool pressure'
           WHEN p_wait IN ('PWAIT_QRY_BPMEMORY', 'HTREPARTITION', 'HTBUILD', 'HTMEMO', 'HTDELETE', 'HTREINIT') THEN 'Potential batch mode performance issues'
           WHEN p_wait = 'BTREE_INSERT_FLOW_CONTROL' THEN 'Optimize For Sequential Key'
           WHEN p_wait IN ('HADR_SYNC_COMMIT', 'HADR_GROUP_COMMIT') THEN 'Potential Availability Group Issues'
           WHEN p_wait = 'WAIT_ON_SYNC_STATISTICS_REFRESH' THEN 'Waiting on sync stats updates (compilation)'
           WHEN p_wait = 'IO_QUEUE_LIMIT' THEN 'Azure SQLDB Throttling'
           WHEN p_wait = 'IO_RETRY' THEN 'I/O Failures retried'
           WHEN p_wait = 'RESMGR_THROTTLED' THEN 'Azure SQLDB Throttling'
         END,
         CASE
           WHEN p_wait IN ('PAGEIOLATCH_SH', 'PAGEIOLATCH_EX', 'IO_COMPLETION', 'IO_RETRY') THEN 'I/O'
           WHEN p_wait IN ('RESOURCE_SEMAPHORE', 'RESOURCE_SEMAPHORE_QUERY_COMPILE', 'CMEMTHREAD', 'SLEEP_BPOOL_STEAL') THEN 'Memory'
           WHEN p_wait IN ('CXPACKET', 'CXCONSUMER', 'CXSYNC_PORT', 'CXSYNC_CONSUMER') THEN 'Parallelism'
           WHEN p_wait IN ('SOS_SCHEDULER_YIELD', 'THREADPOOL', 'RESOURCE_GOVERNOR_IDLE') THEN 'CPU'
           WHEN p_wait IN ('PAGELATCH_EX', 'PAGELATCH_SH', 'PAGELATCH_UP') THEN 'TempDB Contention'
           WHEN p_wait LIKE 'LCK%' THEN 'Locking'
           WHEN p_wait IN ('WRITELOG', 'LOGBUFFER', 'LOG_RATE_GOVERNOR', 'POOL_LOG_RATE_GOVERNOR') THEN 'Transaction Log'
           WHEN p_wait IN ('SLEEP_TASK', 'BPSORT', 'PWAIT_QRY_BPMEMORY', 'HTREPARTITION', 'HTBUILD', 'HTMEMO', 'HTDELETE', 'HTREINIT') THEN 'Query Execution'
           WHEN p_wait = 'ASYNC_NETWORK_IO' THEN 'Network'
           WHEN p_wait IN ('HADR_SYNC_COMMIT', 'HADR_GROUP_COMMIT') THEN 'Availability Groups'
           WHEN p_wait IN ('IO_QUEUE_LIMIT', 'RESMGR_THROTTLED') THEN 'Azure SQL Throttling'
           WHEN p_wait = 'BTREE_INSERT_FLOW_CONTROL' THEN 'Index Management'
           WHEN p_wait = 'WAIT_ON_SYNC_STATISTICS_REFRESH' THEN 'Statistics'
           WHEN p_wait = 'EXECSYNC' THEN 'Other'
         END
$$;

-- the reads of a window: the differences stored in (p_from, p_to] and the seconds they cover
CREATE OR REPLACE FUNCTION pgvigil.mssql_wait_covered(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (reads int, covered_secs float8, first_read timestamptz, last_read timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT count(*)::int, coalesce(sum(r.interval_secs), 0)::float8, min(r.snapshot_at), max(r.snapshot_at)
    FROM (SELECT DISTINCT w.snapshot_at, w.interval_secs FROM pgvigil.mssql_wait_sample w
           WHERE w.instance_id = p_instance_id AND w.snapshot_at > p_from AND w.snapshot_at <= p_to) r
$$;

-- each wait type's time over the window
CREATE OR REPLACE FUNCTION pgvigil.mssql_wait_totals(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (wait_type text, category text, is_benign boolean, waiting_tasks bigint, wait_ms bigint, signal_ms bigint)
LANGUAGE sql STABLE AS $$
  SELECT w.wait_type, max(w.category), bool_or(w.is_benign), sum(w.waiting_tasks)::bigint, sum(w.wait_ms)::bigint, sum(w.signal_ms)::bigint
    FROM pgvigil.mssql_wait_sample w
   WHERE w.instance_id = p_instance_id AND w.snapshot_at > p_from AND w.snapshot_at <= p_to
   GROUP BY w.wait_type
$$;

-- the semaphores' counters over the window: per semaphore the sum of the differences between consecutive reads (a
-- counter that went down was reset by a restart: its new value is the difference), the read before the window the
-- first base (at most ten minutes before it)
CREATE OR REPLACE FUNCTION pgvigil.mssql_grant_deltas(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (pool_id int, semaphore_id int, forced_grants bigint, timeout_errors bigint, reads int, base_read timestamptz,
               last_read timestamptz)
LANGUAGE sql STABLE AS $$
  WITH r AS (
    SELECT p.pool_id, p.semaphore_id, p.snapshot_at, p.forced_grants, p.timeout_errors,
           lag(p.forced_grants) OVER w AS prev_forced, lag(p.timeout_errors) OVER w AS prev_timeouts, lag(p.snapshot_at) OVER w AS prev_at
      FROM pgvigil.mssql_memory_pool p
     WHERE p.instance_id = p_instance_id AND p.snapshot_at > p_from - interval '10 minutes' AND p.snapshot_at <= p_to
    WINDOW w AS (PARTITION BY p.pool_id, p.semaphore_id ORDER BY p.snapshot_at))
  SELECT r.pool_id, r.semaphore_id,
         sum(CASE WHEN r.forced_grants >= r.prev_forced THEN r.forced_grants - r.prev_forced ELSE r.forced_grants END)::bigint,
         sum(CASE WHEN r.timeout_errors >= r.prev_timeouts THEN r.timeout_errors - r.prev_timeouts ELSE r.timeout_errors END)::bigint,
         count(*)::int, min(r.prev_at), max(r.snapshot_at)
    FROM r
   WHERE r.snapshot_at > p_from AND r.prev_at IS NOT NULL
   GROUP BY r.pool_id, r.semaphore_id
$$;

-- D:HH:MM:SS of a number of milliseconds, as sp_Blitz prints a wait's time
CREATE OR REPLACE FUNCTION pgvigil.blitz_dhms(p_ms bigint) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT ((p_ms / 1000) / 86400)::text || ':' || to_char(make_interval(secs => ((p_ms / 1000) % 86400)::float8), 'HH24:MI:SS')
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_wait_shares_between(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (reads int, covered_secs float8, first_read timestamptz, last_read timestamptz, wait_ms bigint, signal_ms bigint,
               signal_ratio numeric, signal_label text, sos_ms bigint, sos_pct numeric, sos_listed boolean,
               pagelatch_ms bigint, pagelatch_hours numeric, pagelatch_pct numeric, tempdb_files int, cpu_count int,
               forced_grants bigint, timeout_errors bigint, grants_from timestamptz, grants_to timestamptz)
LANGUAGE sql STABLE AS $$
  WITH cov AS (SELECT * FROM pgvigil.mssql_wait_covered(p_instance_id, p_from, p_to)),
  t AS (SELECT * FROM pgvigil.mssql_wait_totals(p_instance_id, p_from, p_to)),
  -- sp_PerfCheck: the waits not on its benign list, SLEEP_TASK left out
  nb AS (SELECT coalesce(sum(t.signal_ms), 0)::bigint AS signal_ms, coalesce(sum(t.wait_ms), 0)::bigint AS wait_ms,
                coalesce(sum(t.wait_ms) FILTER (WHERE t.wait_type = 'SOS_SCHEDULER_YIELD'), 0)::bigint AS sos_ms
           FROM t WHERE t.wait_type <> 'SLEEP_TASK' AND NOT EXISTS (SELECT 1 FROM pgvigil.darling_benign_waits b WHERE b.wait_type = t.wait_type)),
  pl AS (SELECT coalesce(sum(t.wait_ms), 0)::bigint AS ms FROM t WHERE t.wait_type IN ('PAGELATCH_UP', 'PAGELATCH_SH', 'PAGELATCH_EX')),
  g AS (SELECT max(d.forced_grants)::bigint AS forced, max(d.timeout_errors)::bigint AS timeouts, min(d.base_read) AS g_from,
                max(d.last_read) AS g_to
          FROM pgvigil.mssql_grant_deltas(p_instance_id, p_from, p_to) d),
  td AS (SELECT x.data_files, x.cpu_count FROM pgvigil.mssql_tempdb x
          WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_to - interval '3 hours' AND x.snapshot_at <= p_to + interval '3 hours'),
  v AS (
    SELECT cov.*, nb.wait_ms, nb.signal_ms, nb.sos_ms, pl.ms AS pl_ms,
           CASE WHEN nb.wait_ms > 0 THEN round(nb.signal_ms * 100.0 / nb.wait_ms, 2) END AS ratio,
           CASE WHEN nb.wait_ms > 0 AND cov.covered_secs > 0 AND nb.sos_ms > 0 THEN round(nb.sos_ms * 100.0 / (cov.covered_secs * 1000)::numeric, 2) END AS sos_pct,
           round(pl.ms / 1000.0 / 3600.0, 2) AS pl_hours, g.forced, g.timeouts, g.g_from, g.g_to
      FROM cov, nb, pl, g)
  SELECT v.reads, v.covered_secs, v.first_read, v.last_read, v.wait_ms, v.signal_ms, v.ratio,
         CASE WHEN v.ratio IS NULL THEN NULL
              WHEN v.ratio >= 50 THEN 'High - CPU pressure detected'
              WHEN v.ratio >= 25 THEN 'Moderate - CPU pressure likely' ELSE 'Normal' END,
         v.sos_ms, v.sos_pct, coalesce(v.sos_pct >= 10, false), v.pl_ms, v.pl_hours,
         CASE WHEN v.covered_secs > 0 THEN round(v.pl_ms * 100.0 / (v.covered_secs * 1000)::numeric, 4) END,
         (SELECT td.data_files FROM td), (SELECT td.cpu_count FROM td), v.forced, v.timeouts, v.g_from, v.g_to
    FROM v
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_wait_findings_between(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (severity text, check_name text, object text, at timestamptz, detail text, source text, source_check int,
               source_priority int, value numeric)
LANGUAGE sql STABLE AS $$
  WITH sh AS (SELECT * FROM pgvigil.mssql_wait_shares_between(p_instance_id, p_from, p_to)),
  t AS (SELECT * FROM pgvigil.mssql_wait_totals(p_instance_id, p_from, p_to)),
  win AS (SELECT sh.covered_secs, sh.covered_secs * 1000 AS covered_ms, floor(sh.covered_secs / 3600)::bigint AS whole_hours,
                 round(sh.covered_secs / 60)::bigint AS minutes, sh.last_read FROM sh WHERE sh.reads > 0 AND sh.covered_secs > 0),
  -- sp_PerfCheck's #wait_stats over the window: its list, its two ways in (unrounded share, decimal average)
  ws AS (
    SELECT t.wait_type, pc.description, pc.category, t.wait_ms, t.waiting_tasks,
           t.wait_ms / nullif(t.waiting_tasks, 0) AS avg_wait_ms,              -- bigint / bigint, as the computed column
           round(t.wait_ms * 100.0 / win.covered_ms::numeric, 2) AS pct, round(t.wait_ms / 1000.0 / 3600.0, 2) AS hours
      FROM t CROSS JOIN win CROSS JOIN LATERAL pgvigil.perfcheck_wait(t.wait_type) pc
     WHERE pc.category IS NOT NULL
       AND ((t.wait_ms * 100.0 / win.covered_ms::numeric) > 10
            OR ((t.wait_ms * 1.0 / nullif(t.waiting_tasks, 0)) > 1000.0 AND t.wait_ms >= 60000))),
  w6001 AS (
    SELECT ws.*,
           CASE WHEN ws.category IN ('Locking', 'Memory', 'I/O', 'TempDB Contention', 'Transaction Log', 'CPU') THEN
                  CASE WHEN ws.pct >= 50 OR (ws.avg_wait_ms >= 1000 AND ws.wait_ms >= 60000) THEN 20
                       WHEN ws.pct >= 20 OR (ws.avg_wait_ms >= 250 AND ws.wait_ms >= 60000) THEN 30 ELSE 40 END
                WHEN ws.category = 'Parallelism' THEN CASE WHEN ws.pct >= 100 THEN 30 ELSE 40 END
                ELSE 40 END AS priority
      FROM ws
     WHERE (ws.pct >= 10 OR ((ws.wait_ms * 1.0 / nullif(ws.waiting_tasks, 0)) > 1000.0 AND ws.wait_ms >= 60000))
       AND ws.wait_type <> 'SLEEP_TASK'
     ORDER BY ws.pct DESC
     LIMIT 10),
  tf8048 AS (SELECT EXISTS (SELECT 1 FROM pgvigil.mssql_trace_flags f WHERE f.instance_id = p_instance_id AND f.trace_flag = 8048 AND f.is_global) AS on_),
  fr AS (
    SELECT w.priority, CASE w.category
             WHEN 'I/O' THEN 'Storage-Related Waits' WHEN 'Memory' THEN 'Memory-Related Waits' WHEN 'Parallelism' THEN 'Parallelism Waits'
             WHEN 'CPU' THEN 'CPU / Scheduling Waits' WHEN 'TempDB Contention' THEN 'TempDB Contention Waits'
             WHEN 'Locking' THEN 'Lock / Blocking Waits' WHEN 'Transaction Log' THEN 'Transaction Log Waits'
             WHEN 'Query Execution' THEN 'Query Execution Waits' WHEN 'Network' THEN 'Network / Client Waits'
             WHEN 'Availability Groups' THEN 'Availability Group Waits' WHEN 'Azure SQL Throttling' THEN 'Azure SQL Throttling Waits'
             WHEN 'Index Management' THEN 'Index Maintenance Waits' WHEN 'Statistics' THEN 'Statistics Update Waits'
             ELSE 'Other Significant Waits' END AS check_name,
           w.wait_type || ' (' || w.description || ')' AS object,
           format('Wait type %s accounts for %s%% of the %s minute(s) read (%s hours), averaging %s ms per wait. %s',
                  w.wait_type, to_char(w.pct, 'FM999999990.00'), win.minutes, to_char(w.hours, 'FM999999990.00'),
                  to_char(coalesce(w.avg_wait_ms, 0), 'FM999999990.00'),
                  CASE w.category
                    WHEN 'Locking' THEN 'Time lost to blocking. Investigate long-running transactions and blocking chains; sp_PressureDetector shows live blockers.'
                    WHEN 'Memory' THEN 'Queries are waiting on memory. Review max server memory and query memory grants; oversized grants force RESOURCE_SEMAPHORE waits.'
                    WHEN 'I/O' THEN 'Reads are waiting on storage. Check the per-file latency findings and whether the working set fits in the buffer pool.'
                    WHEN 'TempDB Contention' THEN 'Allocation-page contention in tempdb. Use equal-sized tempdb data files, and memory-optimized tempdb metadata on 2019+.'
                    WHEN 'Transaction Log' THEN 'Commits are waiting on the log. Check log storage latency, transaction sizes, and log backup frequency.'
                    WHEN 'CPU' THEN 'Scheduling pressure. Review parallelism settings and plan quality; THREADPOOL specifically means worker-thread exhaustion.'
                    WHEN 'Parallelism' THEN 'Usually a cost threshold for parallelism / MAXDOP tuning issue rather than a problem in itself.'
                    WHEN 'Network' THEN 'Usually client-side: the application consuming results slowly or a slow network, not the server.'
                    ELSE 'Description: ' || w.description || '.' END) AS detail,
           'sp_PerfCheck' AS source, 6001 AS source_check, w.pct AS value, win.last_read AS at
      FROM w6001 w CROSS JOIN win
    UNION ALL
    SELECT CASE WHEN sh.signal_ratio >= 50 THEN 20 WHEN sh.signal_ratio >= 30 THEN 30 ELSE 40 END, 'High Signal Wait Ratio', NULL,
           format('Signal wait ratio is %s%%. This indicates significant CPU scheduling pressure. Processes are waiting to get scheduled '
                  'on the CPU, which can impact query performance. Consider investigating high-CPU queries, reducing server load, or '
                  'adding CPU resources.', to_char(sh.signal_ratio, 'FM999999990.00')),
           'sp_PerfCheck', 6101, sh.signal_ratio, win.last_read
      FROM sh CROSS JOIN win WHERE sh.signal_ratio >= 25
    UNION ALL
    SELECT CASE WHEN sh.sos_pct >= 50 THEN 20 WHEN sh.sos_pct >= 30 THEN 30 ELSE 40 END, 'High SOS_SCHEDULER_YIELD Waits', 'SOS_SCHEDULER_YIELD',
           format('SOS_SCHEDULER_YIELD waits account for %s%% of the %s minute(s) read. This indicates tasks frequently giving up their '
                  'quantum of CPU time. This can be caused by CPU-intensive queries, causing threads to context switch frequently. '
                  'Consider tuning queries with high CPU usage or adding CPU resources.', to_char(sh.sos_pct, 'FM999999990.00'), win.minutes),
           'sp_PerfCheck', 6102, sh.sos_pct, win.last_read
      FROM sh CROSS JOIN win WHERE sh.sos_pct >= 25
    UNION ALL
    SELECT 30, 'TempDB Allocation Contention Detected', 'tempdb',
           format('Server has spent %s hours (%s%% of the %s minute(s) read) waiting on page latches. TempDB has %s data files. '
                  'Consider adding files up to %s total to reduce allocation contention.', to_char(sh.pagelatch_hours, 'FM999999990.00'),
                  to_char(round(sh.pagelatch_pct, 2), 'FM999999990.00'), win.minutes, sh.tempdb_files, least(sh.cpu_count, 8)),
           'sp_PerfCheck', 2010, sh.pagelatch_pct, win.last_read
      FROM sh CROSS JOIN win
     WHERE sh.tempdb_files <= sh.cpu_count AND sh.tempdb_files < 8 AND sh.pagelatch_pct >= 1.0
    UNION ALL
    SELECT CASE WHEN sh.forced_grants >= 10000 THEN 20 WHEN sh.forced_grants >= 100 THEN 30 ELSE 40 END,
           'Memory-Starved Queries: Forced Grants', 'memory grants',
           format('dm_exec_query_resource_semaphores reports %s forced memory grants over the %s minute(s) read. Queries ran with less '
                  'memory than they asked for and spilled to tempdb. Review oversized grants (large sorts and hashes), query tuning, and '
                  'max server memory. (sp_Blitz 117, Memory Pressure Affecting Queries: forced grants indicate memory pressure has '
                  'affected query runtimes.)', sh.forced_grants, round(extract(epoch FROM sh.grants_to - sh.grants_from) / 60)::bigint),
           'sp_PerfCheck', 4101, sh.forced_grants::numeric, sh.grants_to
      FROM sh WHERE sh.forced_grants > 0
    UNION ALL
    SELECT 10, 'Poison Wait Detected: ' || t.wait_type, t.wait_type,
           format('For %s seconds over the last %s seconds, SQL Server was waiting on this particular bottleneck. See '
                  'https://www.brentozar.com/go/poison/#%s for how to mitigate this wait type.', t.wait_ms / 1000, round(win.covered_secs)::bigint, t.wait_type),
           'sp_BlitzFirst', 30, (t.wait_ms / 1000)::numeric, win.last_read
      FROM t CROSS JOIN win
     WHERE t.wait_type IN ('IO_QUEUE_LIMIT', 'IO_RETRY', 'LOG_RATE_GOVERNOR', 'POOL_LOG_RATE_GOVERNOR', 'PREEMPTIVE_DEBUG', 'RESMGR_THROTTLED',
                           'RESOURCE_SEMAPHORE', 'RESOURCE_SEMAPHORE_QUERY_COMPILE', 'SE_REPL_CATCHUP_THROTTLE', 'SE_REPL_COMMIT_ACK',
                           'SE_REPL_COMMIT_TURN', 'SE_REPL_ROLLBACK_ACK', 'SE_REPL_SLOW_SECONDARY_THROTTLE', 'THREADPOOL')
       AND t.wait_ms > 1000
    UNION ALL
    SELECT 50, 'Poison Wait Detected: Serializable Locking', 'LCK_M_R*',
           pgvigil.blitz_dhms(sum(t.wait_ms)::bigint) || ' of LCK_M_R% waits have been recorded. This wait often indicates killer performance problems.',
           'sp_Blitz', 121, sum(t.wait_ms)::numeric, win.last_read
      FROM t CROSS JOIN win
     WHERE t.wait_type IN ('LCK_M_RS_S', 'LCK_M_RS_U', 'LCK_M_RIn_NL', 'LCK_M_RIn_S', 'LCK_M_RIn_U', 'LCK_M_RIn_X', 'LCK_M_RX_S', 'LCK_M_RX_U', 'LCK_M_RX_X')
     GROUP BY win.whole_hours, win.last_read
    HAVING sum(t.wait_ms) > 5000 * win.whole_hours AND sum(t.wait_ms) > 60000
    UNION ALL
    SELECT 50, 'Poison Wait Detected: CMEMTHREAD and NUMA', 'CMEMTHREAD',
           pgvigil.blitz_dhms(t.wait_ms) || ' of this wait have been recorded'
             || CASE WHEN tf8048.on_ THEN ' despite enabling trace flag 8048 already.'
                     ELSE '. In servers with over 8 cores per NUMA node, when CMEMTHREAD waits are a bottleneck, trace flag 8048 may be needed.' END,
           'sp_Blitz', 162, t.wait_ms::numeric, win.last_read
      FROM t CROSS JOIN win CROSS JOIN tf8048
      JOIN pgvigil.mssql_memory_numa n ON n.instance_id = p_instance_id
     WHERE t.wait_type = 'CMEMTHREAD' AND n.node0_schedulers >= 8 AND n.other_nodes > 0
       AND t.wait_ms > 5000 * win.whole_hours AND t.wait_ms > 60000)
  SELECT CASE WHEN r.source = 'sp_Blitz' THEN 'warning' WHEN r.priority <= 10 THEN 'critical' WHEN r.priority <= 30 THEN 'warning' ELSE 'info' END,
         r.check_name, r.object, r.at,
         r.detail || format(' (%s check %s, priority %s%s)', r.source, r.source_check, r.priority,
                            CASE WHEN r.source = 'sp_Blitz' THEN ''
                                 ELSE ' ' || CASE r.priority WHEN 10 THEN 'Critical' WHEN 20 THEN 'High' WHEN 30 THEN 'Medium' ELSE 'Low' END END),
         r.source, r.source_check, r.priority, r.value
    FROM fr r
$$;

-- the real waits of the window by the category the Waits grid shows ('(no category)' for a type without one)
CREATE OR REPLACE FUNCTION pgvigil.mssql_wait_rollup_between(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (category text, wait_types int, wait_ms bigint, pct numeric, waiting_tasks bigint, signal_ms bigint, top_wait text)
LANGUAGE sql STABLE AS $$
  WITH t AS (SELECT * FROM pgvigil.mssql_wait_totals(p_instance_id, p_from, p_to) x WHERE NOT x.is_benign AND x.wait_ms > 0),
  all_ AS (SELECT sum(t.wait_ms) AS ms FROM t)
  SELECT coalesce(t.category, '(no category)'), count(*)::int, sum(t.wait_ms)::bigint,
         round(sum(t.wait_ms) * 100.0 / nullif((SELECT ms FROM all_), 0), 1), sum(t.waiting_tasks)::bigint, sum(t.signal_ms)::bigint,
         (array_agg(t.wait_type ORDER BY t.wait_ms DESC))[1]
    FROM t
   GROUP BY coalesce(t.category, '(no category)')
   ORDER BY sum(t.wait_ms) DESC
$$;

-- the semaphores of the newest read at or before p_at (NULL: the newest)
CREATE OR REPLACE FUNCTION pgvigil.mssql_memory_pools_at(p_instance_id int, p_at timestamptz)
RETURNS SETOF pgvigil.mssql_memory_pool LANGUAGE sql STABLE AS $$
  SELECT p.* FROM pgvigil.mssql_memory_pool p
   WHERE p.instance_id = p_instance_id
     AND p.snapshot_at = (SELECT max(x.snapshot_at) FROM pgvigil.mssql_memory_pool x
                           WHERE x.instance_id = p_instance_id AND x.snapshot_at <= coalesce(p_at, 'infinity'))
   ORDER BY p.pool_id, p.semaphore_id
$$;

CREATE OR REPLACE VIEW pgvigil.mssql_waits_findings AS
SELECT i.instance_id, f.severity, f.check_name, f.object, f.at, f.detail
  FROM pgvigil.instances i
  CROSS JOIN LATERAL pgvigil.mssql_wait_findings_between(i.instance_id, now() - interval '15 minutes', now()) f
 WHERE i.engine = 'sqlserver';

-- import_mssql_memory (0074) with the semaphores and the NUMA nodes: the body of 0074 unchanged, the two blocks at its end
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_memory(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_m  jsonb;
  v_g  jsonb;
  v_t  jsonb;
  v_c  jsonb;
  v_n  jsonb;
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
  LOCK TABLE ONLY pgvigil.mssql_memory_clerk, ONLY pgvigil.mssql_memory_sample, ONLY pgvigil.mssql_memory_pool IN ROW EXCLUSIVE MODE;

  DELETE FROM pgvigil.mssql_memory_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_memory_sample (instance_id, snapshot_at, physical_kb, available_kb, system_state, process_kb, process_low,
      committed_kb, committed_target_kb, target_kb, total_kb, stolen_kb, buffer_pool_kb, plan_cache_kb, clerks_kb, ple,
      grants_pending, grants_outstanding, sem_granted, sem_waiting, sem_granted_kb, sem_target_kb, grants, grants_waiting,
      max_grant_kb, sum_grant_kb, max_requested_kb, memory_model)
  VALUES (p_instance_id, p_snapshot_at, (v_m->>'physical_kb')::bigint, (v_m->>'available_kb')::bigint, v_m->>'system_state',
          (v_m->>'process_kb')::bigint, ((v_m->>'process_low')::int = 1), (v_m->>'committed_kb')::bigint, (v_m->>'committed_target_kb')::bigint,
          (v_c->>'Target Server Memory (KB)')::bigint, (v_c->>'Total Server Memory (KB)')::bigint, (v_c->>'Stolen Server Memory (KB)')::bigint,
          (v_c->>'Database Cache Memory (KB)')::bigint, (v_t->>'plan_cache_kb')::bigint, (v_t->>'clerks_kb')::bigint,
          (v_c->>'Page life expectancy')::bigint, (v_c->>'Memory Grants Pending')::int, (v_c->>'Memory Grants Outstanding')::int,
          (v_g->>'sem_granted')::int, (v_g->>'sem_waiting')::int, (v_g->>'sem_granted_kb')::bigint, (v_g->>'sem_target_kb')::bigint,
          (v_g->>'grants')::int, (v_g->>'grants_waiting')::int, (v_g->>'max_grant_kb')::bigint, (v_g->>'sum_grant_kb')::bigint,
          (v_g->>'max_requested_kb')::bigint, v_m->>'memory_model');

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
END $$;
