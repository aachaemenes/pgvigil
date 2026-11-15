-- 0156: PerformanceMonitor 3.13.0's moved rules in pgvigil (task 405, B11; audit-delta-dbadash-pm.md section 3:
-- Changed 2, 12, 13, 19, 46; Release 5; Fixed 8, 10, 20, 24). Each rule replaces the function or view that judged it,
-- under the same name and signature (a column only ever appended), so every reader keeps working:
--   mssql_plancache_summary_between  Fixed 10: plan cache bloat over compiled plans only (every cache type but Parse
--                                    Tree and Extended Proc, a stub counts), a 100 MB floor on the single-use compiled
--                                    plans' size with its two texts, the bands over 20 / 30 / 50 %, the advice
--                                    'optimize for ad hoc workloads' first; compiled_plans appended.
--   mssql_memory_findings_between    0119's body; its plan cache sentence names the compiled plans.
--   mssql_advised_maxdop             Fixed 24 / F10: the one MAXDOP advisor (checks.go's dbatools rule) from mssql_cpu_info.
--   mssql_parallelism_advice         Fixed 24: PerformanceMonitor's composed CXPACKET and THREADPOOL advice from the
--                                    settings in force at the window's end (mssql_config_history).
--   mssql_wait_findings_between      0115's body; its Parallelism and THREADPOOL advice composed.
--   mssql_memory_suggestion          Fixed 8: PerformanceMonitor's max server memory audit and number over checks.go's RAM.
-- Source (MIT): PerformanceMonitor 3.13.0 (Erik Darling, Darling Data LLC), PerformanceMonitor.Common/
-- PlanCacheBloatRule.cs L30-108, PerformanceMonitor.Analysis/FactAdvice.cs L736-827, ConfigAuditGuidance.cs L15-85.
-- The lead's calls on the design pass (20261114-141436-reviewer) are the build's shape; each behaviour change at an
-- upgraded site has its release-note line (no site runs pgvigil before v0.4.0).

-- ---- plan cache bloat (Fixed 10) -------------------------------------------------------------------------------------

-- the newest plan cache read of a window: its totals and PerformanceMonitor's bloat level and recommendation. plans and
-- size_kb are the whole cache (they say whether it is too small to judge); single_use_plans, single_use_kb and
-- single_use_pct are over compiled plans (a cache type but 'Parse Tree' and 'Extended Proc', as PerformanceMonitor's
-- CompiledPredicateSql); compiled_plans is their count. Under 100 MB of single-use compiled plans the level is NORMAL
-- with one of two texts: the whole cache under the floor (too small to judge) or the single-use share under it (no
-- action). The column list grows, so the function is dropped and made again (its readers: SELECT * in
-- q_mssql_perf.go, and mssql_memory_findings_between below, made again after it).
DROP FUNCTION IF EXISTS pgvigil.mssql_plancache_summary_between(int, timestamptz, timestamptz);
CREATE FUNCTION pgvigil.mssql_plancache_summary_between(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, plans bigint, single_use_plans bigint, single_use_pct numeric, size_kb bigint,
               single_use_kb bigint, wasted_pct numeric, bloat_level text, recommendation text, optimize_for_ad_hoc bigint,
               sqlcp_kb bigint, compiled_plans bigint)
LANGUAGE sql STABLE AS $$
  WITH n AS (SELECT max(t.snapshot_at) AS at FROM pgvigil.mssql_plancache_type t
              WHERE t.instance_id = p_instance_id AND t.snapshot_at > p_from AND t.snapshot_at <= p_to),
  s AS (SELECT n.at, sum(t.plans)::bigint AS plans, sum(t.size_kb)::bigint AS kb,
               sum(t.plans) FILTER (WHERE coalesce(t.cache_type, '') NOT IN ('Parse Tree', 'Extended Proc'))::bigint AS cp,
               sum(t.single_use_plans) FILTER (WHERE coalesce(t.cache_type, '') NOT IN ('Parse Tree', 'Extended Proc'))::bigint AS su,
               sum(t.single_use_kb) FILTER (WHERE coalesce(t.cache_type, '') NOT IN ('Parse Tree', 'Extended Proc'))::bigint AS su_kb
          FROM pgvigil.mssql_plancache_type t JOIN n ON t.snapshot_at = n.at
         WHERE t.instance_id = p_instance_id GROUP BY n.at),
  x AS (SELECT s.at, s.plans, s.kb, coalesce(s.cp, 0) AS cp, coalesce(s.su, 0) AS su, coalesce(s.su_kb, 0) AS su_kb,
               CASE WHEN coalesce(s.cp, 0) > 0 THEN coalesce(s.su, 0) * 100.0 / s.cp ELSE 0 END AS pct,
               coalesce(s.su_kb, 0) < 100 * 1024 AS under_floor
          FROM s)
  SELECT x.at, x.plans, x.su, round(x.pct, 1), x.kb, x.su_kb,
         CASE WHEN x.kb > 0 THEN round(100.0 * x.su_kb / x.kb, 1) ELSE 0 END,
         CASE WHEN x.under_floor THEN 'NORMAL' WHEN x.pct > 50 THEN 'CRITICAL' WHEN x.pct > 30 THEN 'HIGH' WHEN x.pct > 20 THEN 'MEDIUM' ELSE 'NORMAL' END,
         CASE WHEN x.under_floor AND x.kb < 100 * 1024
                THEN format('Plan cache is too small to judge: %s plans using %s MB, with %s MB in single-use compiled plans (the floor is 100 MB)',
                            to_char(x.plans, 'FM999,999,999,990'), to_char(x.kb / 1024, 'FM999,999,999,990'), to_char(x.su_kb / 1024, 'FM999,999,999,990'))
              WHEN x.under_floor
                THEN format('Single-use compiled plans take %s MB of the %s MB plan cache (%s plans), under the 100 MB bloat floor, so no action is needed',
                            to_char(x.su_kb / 1024, 'FM999,999,999,990'), to_char(x.kb / 1024, 'FM999,999,999,990'), to_char(x.plans, 'FM999,999,999,990'))
              WHEN x.pct > 20
                THEN 'Optimize for ad hoc workloads is the low-risk first step: the server then caches only a small stub for a plan''s first execution. '
                     'If single-use plans stay high after that, check for unparameterized queries and consider Forced Parameterization, which is a database-wide change'
              ELSE 'Plan cache composition is healthy' END,
         (SELECT c.value_in_use FROM pgvigil.mssql_config c WHERE c.instance_id = p_instance_id AND c.name = 'optimize for ad hoc workloads' AND c.is_present),
         (SELECT k.pages_kb FROM pgvigil.mssql_memory_clerk k
           WHERE k.instance_id = p_instance_id AND k.clerk_type = 'CACHESTORE_SQLCP'
             AND k.snapshot_at = (SELECT max(m.snapshot_at) FROM pgvigil.mssql_memory_clerk m
                                   WHERE m.instance_id = p_instance_id AND m.snapshot_at <= x.at + interval '1 minute' AND m.snapshot_at > p_from)),
         x.cp
    FROM x
$$;

-- 0119's body, the plan cache sentence over compiled plans (the rest unchanged)
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
         format('%s %% of the %s compiled plans are used once (%s KB of the %s KB plan cache, PerformanceMonitor''s bloat level %s; '
                'CACHESTORE_SQLCP %s MB) and ''optimize for ad hoc workloads'' is off: a single-use ad hoc plan is cached whole on its '
                'first run. %s.',
                pc.single_use_pct, pc.compiled_plans, pc.single_use_kb, pc.size_kb, pc.bloat_level, coalesce((pc.sqlcp_kb / 1024)::text, '-'),
                pc.recommendation)
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

-- ---- parallelism advice (Fixed 24) -----------------------------------------------------------------------------------

-- mssql_advised_maxdop: the MAXDOP pgvigil advises from the stored processor facts (mssql_cpu_info: sys.dm_os_sys_info
-- as last read) - checks.go's advisedMaxDOP, dbatools' rule: min(CPUs, 8) on one NUMA node, the CPUs of one node up to
-- 16 on several (the lead's F10: one advisor for the Checks page and the waits advice; PerformanceMonitor's min(cores
-- per socket, 8) is a stated departure). No row when the CPUs were not read.
CREATE OR REPLACE FUNCTION pgvigil.mssql_advised_maxdop(p_instance_id int)
RETURNS TABLE (maxdop bigint, basis text)
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN coalesce(x.n, 0) <= 1 THEN least(x.c, 8) ELSE least(greatest(x.c / x.n, 1), 16) END,
         CASE WHEN coalesce(x.n, 0) <= 1 THEN format('%s logical processors on one NUMA node: up to 8', x.c)
              ELSE format('%s logical processors over %s NUMA nodes: those of one node, up to 16', x.c, x.n) END
    FROM (SELECT (i.info->>'cpu_count')::bigint AS c, (i.info->>'numa_node_count')::bigint AS n
            FROM pgvigil.mssql_cpu_info i WHERE i.instance_id = p_instance_id) x
   WHERE x.c > 0
$$;

-- mssql_parallelism_advice: PerformanceMonitor 3.13.0's composed advice (FactAdvice.cs ComposeCxpacket /
-- ComposeThreadpoolGeneric, ReadParallelismSettings) from the server's own settings at p_at (mssql_config_history:
-- the value in force then, not today's) and the advised MAXDOP: the change to make when a setting is off guidance,
-- 'within topology guidance' when both are read and within it, the other setting to check by hand when one was not
-- read; NULL when neither was read (the caller keeps its static text). p_kind 'cx' (CXPACKET / CXCONSUMER) or
-- 'threadpool'. Departures: the advised MAXDOP is dbatools' rule (above); PerformanceMonitor's collection-gap note is
-- left out (pgvigil's read gaps are said on the page).
CREATE OR REPLACE FUNCTION pgvigil.mssql_parallelism_advice(p_instance_id int, p_at timestamptz, p_kind text)
RETURNS text
LANGUAGE sql STABLE AS $$
  WITH cfg AS (
    SELECT (SELECT h.value_in_use FROM pgvigil.mssql_config_history h
             WHERE h.instance_id = p_instance_id AND h.name = 'max degree of parallelism'
               AND (h.valid_from IS NULL OR h.valid_from <= p_at) AND (h.valid_to IS NULL OR h.valid_to > p_at)
             ORDER BY h.valid_from DESC NULLS LAST LIMIT 1) AS maxdop,
           (SELECT h.value_in_use FROM pgvigil.mssql_config_history h
             WHERE h.instance_id = p_instance_id AND h.name = 'cost threshold for parallelism'
               AND (h.valid_from IS NULL OR h.valid_from <= p_at) AND (h.valid_to IS NULL OR h.valid_to > p_at)
             ORDER BY h.valid_from DESC NULLS LAST LIMIT 1) AS ctfp),
  r AS (
    SELECT cfg.maxdop, cfg.ctfp, a.maxdop AS rec, a.basis,
           array_remove(ARRAY[
             CASE WHEN cfg.ctfp IS NOT NULL AND cfg.ctfp <= 5 THEN 'raise cost threshold for parallelism to 50'
                  WHEN cfg.ctfp IS NOT NULL AND cfg.ctfp < 50 THEN format('raise cost threshold for parallelism from %s toward 50', cfg.ctfp) END,
             CASE WHEN a.maxdop IS NULL THEN NULL
                  WHEN cfg.maxdop = 0 THEN format('cap MAXDOP at %s (%s)', a.maxdop, a.basis)
                  WHEN cfg.maxdop > a.maxdop THEN format('lower MAXDOP from %s to %s (%s)', cfg.maxdop, a.maxdop, a.basis) END], NULL) AS recs
      FROM cfg LEFT JOIN pgvigil.mssql_advised_maxdop(p_instance_id) a ON true),
  t AS (
    SELECT r.*, format('This server''s MAXDOP is %s and cost threshold for parallelism is %s%s. ',
                       coalesce(r.maxdop::text, 'not readable this window'), coalesce(r.ctfp::text, 'not readable this window'),
                       coalesce(' (advised MAXDOP ' || r.rec || ': ' || r.basis || ')', '')) AS statement,
           'What was read is within topology guidance; check the other setting by hand (cost threshold for parallelism at 50 '
           'or above, MAXDOP at the advised value). ' AS by_hand
      FROM r)
  SELECT CASE WHEN t.maxdop IS NULL AND t.ctfp IS NULL THEN NULL
              WHEN p_kind = 'cx' THEN t.statement
                || CASE WHEN cardinality(t.recs) > 0
                          THEN 'Bring them to guidance: ' || array_to_string(t.recs, ', ') || '. Most OLTP queries should not go parallel. '
                               'If CXPACKET persists after that, the parallelism is coming from the plans themselves: '
                        WHEN t.maxdop IS NOT NULL AND t.ctfp IS NOT NULL
                          THEN 'Both are within topology guidance, so the parallelism is coming from the plans themselves: '
                        ELSE t.by_hand || 'If both are at guidance the parallelism is coming from the plans themselves: ' END
                || 'examine the top parallel queries and fix the plan, or the estimate driving it; that is what removes the wait.'
              ELSE 'Resolve the dominant cause: parallelism or blocking. ' || t.statement
                || CASE WHEN cardinality(t.recs) > 0 THEN 'If it is parallelism, bring them to guidance: ' || array_to_string(t.recs, ', ') || '. '
                        WHEN t.maxdop IS NOT NULL AND t.ctfp IS NOT NULL
                          THEN 'Both are within topology guidance, so if it is parallelism the driver is the volume of concurrent parallel '
                               'queries, not loose settings: guard harder for that concurrency level and tune the specific high-DOP queries. '
                        ELSE t.by_hand END
                || 'This is a report on a window that has already passed, so the worker pool has long since recovered: aim at stopping '
                   'the recurrence, not a one-off KILL. For the blocking case that means fixing the abandoned-transaction code path (a '
                   'BEGIN TRAN left open on an error or timeout path; SET XACT_ABORT ON) or the slow operation under the held lock. Do '
                   'NOT raise max worker threads to mask it: that trades thread exhaustion for memory pressure (each worker reserves a '
                   'thread stack outside max server memory) without fixing the cause.' END
    FROM t
$$;

-- 0115's body, its Parallelism and THREADPOOL advice composed by mssql_parallelism_advice (the rest unchanged)
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
                    WHEN 'CPU' THEN CASE WHEN w.wait_type = 'THREADPOOL'
                                         THEN coalesce(pgvigil.mssql_parallelism_advice(p_instance_id, win.last_read, 'threadpool'),
                                                       'Scheduling pressure. Review parallelism settings and plan quality; THREADPOOL specifically means worker-thread exhaustion.')
                                         ELSE 'Scheduling pressure. Review parallelism settings and plan quality; THREADPOOL specifically means worker-thread exhaustion.' END
                    WHEN 'Parallelism' THEN coalesce(pgvigil.mssql_parallelism_advice(p_instance_id, win.last_read, 'cx'),
                                                     'Usually a cost threshold for parallelism / MAXDOP tuning issue rather than a problem in itself.')
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

-- ---- max server memory (Fixed 8) ------------------------------------------------------------------------------------

-- mssql_memory_suggestion: PerformanceMonitor 3.13.0's max server memory audit (ConfigAuditGuidance.cs AuditMaxMemory)
-- over the RAM checks.go weighs it against (sys_info's physical memory, stored in mssql_instance) and the value in use
-- (mssql_config): the OS reserve is the larger of 4,096 MB and 10 % of RAM but never more than half of it, the
-- suggestion RAM minus the reserve (whole MB); unlimited (2147483647) = warning, over 95 % of RAM or under 50 % of more
-- than 8,192 MB = review, else ok. No row on Managed Instance or Azure SQL Database (engine edition 8 or 5: the
-- platform sets the memory) or before the configuration was read.
CREATE OR REPLACE FUNCTION pgvigil.mssql_memory_suggestion(p_instance_id int)
RETURNS TABLE (ram_mb bigint, reserve_mb bigint, suggested_mb bigint, max_server_memory_mb bigint, status text, message text)
LANGUAGE sql STABLE AS $$
  WITH x AS (
    SELECT coalesce(m.physical_memory_mb, 0)::double precision AS ram,
           (SELECT c.value_in_use FROM pgvigil.mssql_config c
             WHERE c.instance_id = p_instance_id AND c.name = 'max server memory (MB)' AND c.is_present)::bigint AS msm
      FROM pgvigil.instances i LEFT JOIN pgvigil.mssql_instance m ON m.instance_id = i.instance_id
     WHERE i.instance_id = p_instance_id AND i.engine = 'sqlserver' AND coalesce(m.engine_edition, 0) NOT IN (5, 8)),
  s AS (SELECT x.ram, x.msm,
               CASE WHEN x.ram <= 0 THEN 0 ELSE least(greatest(4096, x.ram * 0.10), x.ram / 2) END AS reserve,
               CASE WHEN x.ram <= 0 THEN 0 ELSE trunc(x.ram - least(greatest(4096, x.ram * 0.10), x.ram / 2))::bigint END AS sugg,
               CASE WHEN x.ram > 0 THEN x.msm / x.ram END AS ratio
          FROM x WHERE x.msm IS NOT NULL)
  SELECT s.ram::bigint, round(s.reserve)::bigint,
         CASE WHEN s.msm = 2147483647 AND s.ram <= 0 THEN s.msm WHEN s.msm = 2147483647 OR s.ratio > 0.95 OR (s.ratio < 0.50 AND s.ram > 8192) THEN s.sugg
              ELSE s.msm END,
         s.msm,
         CASE WHEN s.msm = 2147483647 THEN 'warning' WHEN s.ram <= 0 THEN 'ok' WHEN s.ratio > 0.95 OR (s.ratio < 0.50 AND s.ram > 8192) THEN 'review'
              ELSE 'ok' END,
         CASE WHEN s.msm = 2147483647 AND s.ram > 0
                THEN format('Max server memory is at the default (unlimited). SQL Server will consume all available RAM, starving the OS and '
                            'other processes. With %s MB physical RAM, set max server memory to ~%s MB (leaving %s MB for the OS).',
                            to_char(s.ram, 'FM999,999,999,990'), to_char(s.sugg, 'FM999,999,999,990'), to_char(round(s.reserve), 'FM999,999,999,990'))
              WHEN s.msm = 2147483647
                THEN 'Max server memory is at the default (unlimited). SQL Server will consume all available RAM. Set this to total physical '
                     'memory minus the OS reserve (the larger of 4 GB and 10% of RAM, but never more than half of RAM) to leave room for the OS.'
              WHEN s.ram <= 0 THEN format('Max server memory is set to %s MB.', to_char(s.msm, 'FM999,999,999,990'))
              WHEN s.ratio > 0.95
                THEN format('Max server memory (%s MB) is %s%% of physical RAM (%s MB). Consider reducing to ~%s MB to leave room for the OS.',
                            to_char(s.msm, 'FM999,999,999,990'), round(100 * s.ratio), to_char(s.ram, 'FM999,999,999,990'), to_char(s.sugg, 'FM999,999,999,990'))
              WHEN s.ratio < 0.50 AND s.ram > 8192
                THEN format('Max server memory (%s MB) is only %s%% of physical RAM (%s MB). SQL Server may be under-utilizing available memory. '
                            'Consider raising to ~%s MB unless other applications need the remaining RAM.',
                            to_char(s.msm, 'FM999,999,999,990'), round(100 * s.ratio), to_char(s.ram, 'FM999,999,999,990'), to_char(s.sugg, 'FM999,999,999,990'))
              ELSE format('Max server memory (%s MB) looks reasonable for %s MB physical RAM.', to_char(s.msm, 'FM999,999,999,990'), to_char(s.ram, 'FM999,999,999,990')) END
    FROM s
$$;
