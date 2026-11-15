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
--   mssql_protection_overrides       Changed 46: backup ages per tag or database (Admin, audited), the resolver
--   mssql_protection_limits          (a database row > the instance's yaml > its tags, the strictest > the default) and
--   mssql_backup_judged              0129's view judged by it, where each age comes from appended.
--   a seeded rule                    Changed 12 / Release 5: 'SQL Server: High CPU' on cpu.sql_pct, 80 / 95 for 4
--                                    minutes, OFF.
--   mssql_cpu_findings               Changed 2: 0124's view, 'slow data file writes' on tempdb's data files only at 10 / 30
--   mssql_perf_findings              ms over 250 writes; 0074's view, 'slow log writes' at 10 / 30 ms over 250 writes;
--                                    the open alerts on user data files closed as 'rule retired' (D1).
--   mssql_runnable_queue             Changed 13: the reading with its fallback window of the newest 3 reads.
-- Source (MIT): PerformanceMonitor 3.13.0 (Erik Darling, Darling Data LLC), PerformanceMonitor.Common/
-- PlanCacheBloatRule.cs L30-108, PerformanceMonitor.Analysis/FactAdvice.cs L736-827, ConfigAuditGuidance.cs L15-85,
-- AlertEngine.cs L1045-1404, RunnableQueueEvaluator.cs L55-125.
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

-- ---- protection ages (Changed 46) -----------------------------------------------------------------------------------

-- mssql_protection_overrides: the full backup and log backup ages a database is judged by, set from Admin for a tag
-- or for one database of one instance (the instance's own ages stay in pgvigil.yaml's mssql_thresholds). Precedence
-- (the lead's F2): a database row > the instance's yaml > the instance's tags (the strictest when they disagree: the
-- lowest age over 0; 0 only when every tag row says 0) > the default (168 h, 60 min). 0 = not judged; no clamp.
-- Written through import_mssql_protection_override only.
CREATE TABLE IF NOT EXISTS pgvigil.mssql_protection_overrides (
  override_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope               text NOT NULL CHECK (scope IN ('tag', 'database')),
  tag                 text,
  instance_name       text,
  database_name       text,
  full_backup_hours   numeric CHECK (full_backup_hours >= 0),
  log_backup_minutes  numeric CHECK (log_backup_minutes >= 0),
  note                text,
  replaces            bigint,
  created_by          text NOT NULL,
  created_at          timestamptz NOT NULL,
  client              text,
  ended_by            text,
  ended_at            timestamptz,
  CONSTRAINT "a tag row names its tag, a database row its instance and database" CHECK (
    (scope = 'tag' AND tag IS NOT NULL AND instance_name IS NULL AND database_name IS NULL)
    OR (scope = 'database' AND tag IS NULL AND instance_name IS NOT NULL AND database_name IS NOT NULL)),
  CONSTRAINT "a row sets an age" CHECK (full_backup_hours IS NOT NULL OR log_backup_minutes IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS mssql_protection_overrides_live_uq ON pgvigil.mssql_protection_overrides
  (scope, coalesce(tag, ''), coalesce(instance_name, ''), coalesce(database_name, '')) WHERE ended_at IS NULL;
COMMENT ON TABLE pgvigil.mssql_protection_overrides IS 'Admin''s backup ages per tag or database; written through import_mssql_protection_override only.';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_protection_override_log (
  log_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at           timestamptz NOT NULL,
  ui_user      text NOT NULL,
  client       text,
  op           text,
  override_id  bigint,
  outcome      text NOT NULL CHECK (outcome IN ('done', 'refused')),
  detail       text,
  payload      jsonb
);
CREATE INDEX IF NOT EXISTS mssql_protection_override_log_at_idx ON pgvigil.mssql_protection_override_log (at DESC);

-- import_mssql_protection_override: one edit from Admin (the actions door's audit login, behind the UI login): op
-- 'add' (scope tag | database, tag | instance_name and database_name, full_backup_hours, log_backup_minutes, note; a
-- live row for the same target is ended and replaced), 'end' (override_id). Every attempt is logged.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_protection_override(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op     text := p_payload->>'op';
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client text := nullif(p_payload->>'client', '');
  v_scope  text := p_payload->>'scope';
  v_tag    text := nullif(btrim(coalesce(p_payload->>'tag', '')), '');
  v_inst   text := nullif(btrim(coalesce(p_payload->>'instance_name', '')), '');
  v_db     text := nullif(btrim(coalesce(p_payload->>'database_name', '')), '');
  v_note   text := nullif(btrim(coalesce(p_payload->>'note', '')), '');
  v_full   numeric;
  v_log    numeric;
  v_id     bigint;
  v_new    bigint;
  v_why    text;
  v_done   text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_mssql_protection_override: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('add', 'end') THEN
    v_why := 'op must be add or end';
  ELSIF v_op = 'end' THEN
    IF coalesce(p_payload->>'override_id', '') ~ '^[0-9]{1,18}$' THEN
      v_id := (p_payload->>'override_id')::bigint;
    END IF;
    IF v_id IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.mssql_protection_overrides WHERE override_id = v_id AND ended_at IS NULL) THEN
      v_why := format('no live row %s', coalesce(p_payload->>'override_id', '(none)'));
    END IF;
  ELSE
    IF coalesce(p_payload->>'full_backup_hours', '') ~ '^[0-9]{1,6}(\.[0-9]{1,3})?$' THEN v_full := (p_payload->>'full_backup_hours')::numeric; END IF;
    IF coalesce(p_payload->>'log_backup_minutes', '') ~ '^[0-9]{1,7}(\.[0-9]{1,3})?$' THEN v_log := (p_payload->>'log_backup_minutes')::numeric; END IF;
    IF v_scope IS NULL OR v_scope NOT IN ('tag', 'database') THEN
      v_why := 'scope must be tag or database (an instance''s own ages are set in pgvigil.yaml''s mssql_thresholds)';
    ELSIF v_scope = 'tag' AND v_tag IS NULL THEN
      v_why := 'a tag row names its tag';
    ELSIF v_scope = 'database' AND (v_inst IS NULL OR v_db IS NULL) THEN
      v_why := 'a database row names its instance and its database';
    ELSIF v_scope = 'database' AND NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.name = v_inst AND i.is_active AND i.engine = 'sqlserver') THEN
      v_why := format('no active SQL Server instance %L', v_inst);
    ELSIF (coalesce(p_payload->>'full_backup_hours', '') <> '' AND v_full IS NULL) OR (coalesce(p_payload->>'log_backup_minutes', '') <> '' AND v_log IS NULL) THEN
      v_why := 'an age is a number of 0 or more (hours for the full backup, minutes for the log backup; 0 = not judged)';
    ELSIF v_full IS NULL AND v_log IS NULL THEN
      v_why := 'a row sets the full backup hours, the log backup minutes, or both';
    ELSIF length(coalesce(v_tag, '')) > 200 OR length(coalesce(v_db, '')) > 128 OR length(coalesce(v_note, '')) > 500 THEN
      v_why := 'a tag is 200 characters at most, a database name 128, a note 500';
    END IF;
    IF v_scope = 'tag' THEN v_inst := NULL; v_db := NULL; ELSE v_tag := NULL; END IF;
  END IF;
  IF v_why IS NULL THEN
    BEGIN
      IF v_op = 'end' THEN
        UPDATE pgvigil.mssql_protection_overrides SET ended_by = v_user, ended_at = p_at WHERE override_id = v_id;
        v_done := 'ended';
      ELSE
        UPDATE pgvigil.mssql_protection_overrides o SET ended_by = v_user, ended_at = p_at
         WHERE o.ended_at IS NULL AND o.scope = v_scope AND coalesce(o.tag, '') = coalesce(v_tag, '')
           AND coalesce(o.instance_name, '') = coalesce(v_inst, '') AND coalesce(o.database_name, '') = coalesce(v_db, '')
        RETURNING o.override_id INTO v_id;
        INSERT INTO pgvigil.mssql_protection_overrides (scope, tag, instance_name, database_name, full_backup_hours, log_backup_minutes,
                                                        note, replaces, created_by, created_at, client)
        VALUES (v_scope, v_tag, v_inst, v_db, v_full, v_log, v_note, v_id, v_user, p_at, v_client)
        RETURNING override_id INTO v_new;
        v_done := CASE WHEN v_id IS NOT NULL THEN format('row %s replaced by row %s', v_id, v_new) ELSE 'added' END;
      END IF;
    EXCEPTION
      WHEN unique_violation THEN
        v_why := 'a live row already holds this target';
        v_new := NULL;
      WHEN check_violation OR invalid_text_representation OR string_data_right_truncation OR numeric_value_out_of_range THEN
        v_why := 'refused by the store: ' || SQLERRM;
        v_new := NULL;
    END;
  END IF;
  INSERT INTO pgvigil.mssql_protection_override_log (at, ui_user, client, op, override_id, outcome, detail, payload)
  VALUES (p_at, v_user, v_client, v_op, coalesce(v_new, v_id), CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
          coalesce(v_why, v_done), p_payload);
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, v_done), 'override_id', coalesce(v_new, v_id));
END $$;

-- mssql_protection_limits: the full backup hours and log backup minutes one database of one instance is judged by,
-- each with where it comes from ('database row <n>', 'pgvigil.yaml', 'tag <tag> (row <n>)', 'the default')
CREATE OR REPLACE FUNCTION pgvigil.mssql_protection_limits(p_instance_id int, p_database text)
RETURNS TABLE (full_backup_hours numeric, full_from text, log_backup_minutes numeric, log_from text)
LANGUAGE sql STABLE AS $$
  WITH me AS (SELECT i.name, coalesce(t.tags, '{}'::text[]) AS tags FROM pgvigil.instances i
                LEFT JOIN pgvigil.instance_tags_merged t ON t.instance_id = i.instance_id WHERE i.instance_id = p_instance_id),
  o AS (SELECT x.* FROM pgvigil.mssql_protection_overrides x, me
         WHERE x.ended_at IS NULL
           AND ((x.scope = 'database' AND x.instance_name = me.name AND x.database_name = p_database)
                OR (x.scope = 'tag' AND x.tag = ANY (me.tags)))),
  y AS (SELECT t.full_backup_hours, t.log_backup_minutes FROM pgvigil.mssql_hadr_thresholds t WHERE t.instance_id = p_instance_id),
  -- per age: the database row, the yaml, the strictest tag row (the lowest over 0, else 0), the default
  f AS (SELECT coalesce(
          (SELECT ARRAY[o.full_backup_hours::text, 'database row ' || o.override_id] FROM o WHERE o.scope = 'database' AND o.full_backup_hours IS NOT NULL),
          (SELECT ARRAY[y.full_backup_hours::text, 'pgvigil.yaml'] FROM y WHERE y.full_backup_hours IS NOT NULL),
          (SELECT ARRAY[o.full_backup_hours::text, 'tag ' || o.tag || ' (row ' || o.override_id || ')'] FROM o
            WHERE o.scope = 'tag' AND o.full_backup_hours IS NOT NULL ORDER BY o.full_backup_hours = 0, o.full_backup_hours, o.override_id LIMIT 1),
          ARRAY['168', 'the default']) AS v),
  l AS (SELECT coalesce(
          (SELECT ARRAY[o.log_backup_minutes::text, 'database row ' || o.override_id] FROM o WHERE o.scope = 'database' AND o.log_backup_minutes IS NOT NULL),
          (SELECT ARRAY[y.log_backup_minutes::text, 'pgvigil.yaml'] FROM y WHERE y.log_backup_minutes IS NOT NULL),
          (SELECT ARRAY[o.log_backup_minutes::text, 'tag ' || o.tag || ' (row ' || o.override_id || ')'] FROM o
            WHERE o.scope = 'tag' AND o.log_backup_minutes IS NOT NULL ORDER BY o.log_backup_minutes = 0, o.log_backup_minutes, o.override_id LIMIT 1),
          ARRAY['60', 'the default']) AS v)
  SELECT f.v[1]::numeric, f.v[2], l.v[1]::numeric, l.v[2] FROM f, l
$$;

-- mssql_backup_judged: 0129's view (0066's with the Managed Instance reason for master, model and msdb), the full and
-- log ages from mssql_protection_limits; full_hours_from and log_minutes_from appended (a view made over it with b.*
-- keeps the columns it had: b.* was expanded when that view was made). internal/repo's TestBackupJudged0129Is0066PlusManagedInstance becomes '0156 = 0129 + the resolver'
-- (WIRING: the test is not this task's file).
CREATE OR REPLACE VIEW pgvigil.mssql_backup_judged AS
WITH own AS (
  SELECT s.*, i.name AS instance,
         pl.full_backup_hours, l.diff_backup_hours, pl.log_backup_minutes, l.new_database_hours, l.nul_backup_days,
         (SELECT p FROM unnest(l.backup_exclude) p WHERE s.database_name ILIKE p LIMIT 1) AS excluded_by,
         pl.full_from AS full_hours_from, pl.log_from AS log_minutes_from
    FROM pgvigil.mssql_backup_state s
    JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
    JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = s.instance_id
    CROSS JOIN LATERAL pgvigil.mssql_protection_limits(s.instance_id, s.database_name) pl
   WHERE s.is_present
), merged AS (
  SELECT o.*,
         coalesce(f.full_at, o.full_at) AS eff_full_at, coalesce(f.instance, o.instance) AS full_from,
         coalesce(f.full_copy_only, o.full_copy_only) AS eff_full_copy_only,
         coalesce(d.diff_at, o.diff_at) AS eff_diff_at, coalesce(d.instance, o.instance) AS diff_from,
         coalesce(g.log_at, o.log_at) AS eff_log_at, coalesce(g.instance, o.instance) AS log_from,
         coalesce(n.nul_at, o.nul_at) AS eff_nul_at, coalesce(n.nul_type, o.nul_type) AS eff_nul_type, coalesce(n.instance, o.instance) AS nul_from,
         r.replicas_total, r.replicas_monitored
    FROM own o
    LEFT JOIN LATERAL (SELECT x.full_at, x.full_copy_only, xi.name AS instance FROM pgvigil.mssql_backup_state x JOIN pgvigil.instances xi ON xi.instance_id = x.instance_id AND xi.is_active
                        WHERE o.ag_group_id IS NOT NULL AND x.ag_group_id = o.ag_group_id AND x.database_name = o.database_name AND x.is_present AND x.full_at IS NOT NULL
                        ORDER BY x.full_at DESC LIMIT 1) f ON true
    LEFT JOIN LATERAL (SELECT x.diff_at, xi.name AS instance FROM pgvigil.mssql_backup_state x JOIN pgvigil.instances xi ON xi.instance_id = x.instance_id AND xi.is_active
                        WHERE o.ag_group_id IS NOT NULL AND x.ag_group_id = o.ag_group_id AND x.database_name = o.database_name AND x.is_present AND x.diff_at IS NOT NULL
                        ORDER BY x.diff_at DESC LIMIT 1) d ON true
    LEFT JOIN LATERAL (SELECT x.log_at, xi.name AS instance FROM pgvigil.mssql_backup_state x JOIN pgvigil.instances xi ON xi.instance_id = x.instance_id AND xi.is_active
                        WHERE o.ag_group_id IS NOT NULL AND x.ag_group_id = o.ag_group_id AND x.database_name = o.database_name AND x.is_present AND x.log_at IS NOT NULL
                        ORDER BY x.log_at DESC LIMIT 1) g ON true
    LEFT JOIN LATERAL (SELECT x.nul_at, x.nul_type, xi.name AS instance FROM pgvigil.mssql_backup_state x JOIN pgvigil.instances xi ON xi.instance_id = x.instance_id AND xi.is_active
                        WHERE o.ag_group_id IS NOT NULL AND x.ag_group_id = o.ag_group_id AND x.database_name = o.database_name AND x.is_present AND x.nul_at IS NOT NULL
                        ORDER BY x.nul_at DESC LIMIT 1) n ON true
    LEFT JOIN LATERAL (SELECT (SELECT count(*) FROM pgvigil.mssql_ag_state a WHERE a.instance_id = o.instance_id AND lower(a.group_id) = o.ag_group_id) AS replicas_total,
                              (SELECT count(DISTINCT lower(a.replica_server)) FROM pgvigil.mssql_ag_state a JOIN pgvigil.instances ai ON ai.instance_id = a.instance_id AND ai.is_active
                                WHERE lower(a.group_id) = o.ag_group_id AND a.is_local
                                  AND EXISTS (SELECT 1 FROM pgvigil.mssql_backup_state b WHERE b.instance_id = a.instance_id AND b.ag_group_id = o.ag_group_id)) AS replicas_monitored
                      ) r ON o.ag_group_id IS NOT NULL
), j AS (
  SELECT m.*,
         CASE WHEN m.excluded_by IS NOT NULL THEN 'excluded by the pattern ' || m.excluded_by
              WHEN m.database_name = 'tempdb' THEN 'tempdb is never backed up'
              WHEN m.database_name IN ('master', 'model', 'msdb')
                   AND EXISTS (SELECT 1 FROM pgvigil.instances x WHERE x.instance_id = m.instance_id AND x.platform = 'azuresqlmi')
                THEN CASE WHEN m.database_name = 'master'
                          THEN 'Azure SQL Managed Instance does not back up the physical master database and records no system database backup in msdb'
                          ELSE 'Azure SQL Managed Instance backs up its system databases itself and does not record those backups in msdb' END
              WHEN m.is_snapshot THEN 'a database snapshot'
              WHEN m.state IS DISTINCT FROM 'ONLINE' THEN 'the database is ' || coalesce(lower(m.state), 'in an unknown state')
              WHEN m.is_standby THEN 'a standby database (restoring logs)'
              WHEN m.created_at > m.snapshot_at - make_interval(secs => (m.new_database_hours * 3600)::float8) THEN 'a new database'
         END AS not_judged
    FROM merged m
)
SELECT j.instance_id, j.instance, j.database_name, j.snapshot_at, j.state, j.recovery_model, j.created_at, j.ag_name, j.ag_group_id,
       j.replicas_total, j.replicas_monitored,
       (j.ag_group_id IS NOT NULL AND coalesce(j.replicas_monitored, 0) < coalesce(j.replicas_total, 0)) AS replicas_unseen,
       j.not_judged,
       -- <type>_from: the instance whose msdb holds that backup (where it ran)
       j.eff_full_at AS full_at, CASE WHEN j.eff_full_at IS NOT NULL THEN j.full_from END AS full_from, j.eff_full_copy_only AS full_copy_only,
       j.eff_diff_at AS diff_at, CASE WHEN j.eff_diff_at IS NOT NULL THEN j.diff_from END AS diff_from,
       j.eff_log_at AS log_at, CASE WHEN j.eff_log_at IS NOT NULL THEN j.log_from END AS log_from,
       j.eff_nul_at AS nul_at, j.eff_nul_type AS nul_type, CASE WHEN j.eff_nul_at IS NOT NULL THEN j.nul_from END AS nul_from,
       j.history_from, j.full_backup_hours, j.diff_backup_hours, j.log_backup_minutes, j.nul_backup_days,
       -- the ages AT THE READ: a view opened 50 minutes after an hourly read must not add those minutes to a log backup's age
       extract(epoch FROM greatest(j.snapshot_at - j.eff_full_at, interval '0')) / 3600.0 AS full_age_hours,
       extract(epoch FROM greatest(j.snapshot_at - j.eff_diff_at, interval '0')) / 3600.0 AS diff_age_hours,
       extract(epoch FROM greatest(j.snapshot_at - j.eff_log_at, interval '0')) / 60.0 AS log_age_minutes,
       CASE WHEN j.not_judged IS NOT NULL OR j.full_backup_hours = 0 THEN 'not judged'
            WHEN j.eff_full_at IS NULL THEN 'never'
            WHEN j.snapshot_at - j.eff_full_at > make_interval(secs => (j.full_backup_hours * 3600)::float8) THEN 'late'
            ELSE 'ok' END AS full_status,
       CASE WHEN j.not_judged IS NOT NULL OR j.diff_backup_hours = 0 OR j.database_name = 'master' THEN 'not judged'
            WHEN j.eff_diff_at IS NULL AND j.eff_full_at IS NULL THEN 'never'
            -- a full backup newer than the threshold stands in for a differential one
            WHEN j.snapshot_at - greatest(j.eff_diff_at, j.eff_full_at) > make_interval(secs => (j.diff_backup_hours * 3600)::float8) THEN 'late'
            ELSE 'ok' END AS diff_status,
       CASE WHEN j.not_judged IS NOT NULL OR j.log_backup_minutes = 0 OR j.recovery_model IS DISTINCT FROM 'FULL' AND j.recovery_model IS DISTINCT FROM 'BULK_LOGGED'
                 OR j.is_read_only OR j.database_name = 'model' THEN 'not judged'
            -- under the full recovery model the log chain starts with the first full backup: before it there is nothing to back up
            WHEN j.eff_full_at IS NULL THEN 'not judged'
            WHEN j.eff_log_at IS NULL THEN 'never'
            WHEN j.snapshot_at - j.eff_log_at > make_interval(secs => (j.log_backup_minutes * 60)::float8) THEN 'late'
            ELSE 'ok' END AS log_status,
       -- where each age the database is judged by comes from (0156: an override, pgvigil.yaml or the default)
       j.full_hours_from, j.log_minutes_from
  FROM j;

-- ---- High CPU (Changed 12, Release 5) --------------------------------------------------------------------------------

-- PerformanceMonitor 3.13.0's High CPU alert (AlertEngine.cs L1045-1404: 5 samples in a row at or over 80 %, critical
-- at 95 %) as a starter rule, seeded OFF (the lead's D2 a: 0074's 'CPU at 90 % or more' already alerts; a second CPU
-- page at upgrade would double it). 0153's seed rule: written only when the fleet has never had a rule on cpu.sql_pct,
-- live or ended, so an upgrade never brings back a rule a DBA ended or replaced, and a re-run adds nothing; created_by
-- 'pgvigil' with the client '0156 seed', one alert_rule_log row. Its 15-minute clear hold and its once-per-incident
-- page are B5's flapping hold (task 403): not built twice. 'above' is strict (0085), so 'at or over 80' is above
-- 79.999 (as 0153's lock waits).
WITH seed (name, metric, op, warning, critical, for_minutes, note) AS (VALUES
  ('SQL Server: High CPU', 'cpu.sql_pct', 'above', 79.999, 94.999, 4,
   'PerformanceMonitor 3.13 High CPU: SQL Server''s CPU at 80 % or more for 5 samples in a row (5 or 6 one-minute '
   'samples: the rule''s minutes run from the first sample to the newest, on ring-buffer times read again at each read), '
   'critical at 95 %. A channel''s clear delay (clear_after_secs, 600 s by default) holds the alert open after it clears, '
   'where PerformanceMonitor holds 15 minutes. Switched on, it pages beside pgvigil''s own ''CPU at 90 % or more''.')
), made AS (
  INSERT INTO pgvigil.alert_rules (name, metric, op, warning, critical, for_minutes, scope, note, enabled, created_by,
                                   created_at, client)
  SELECT s.name, s.metric, s.op, s.warning, s.critical, s.for_minutes, 'fleet', s.note, false, 'pgvigil', now(), '0156 seed'
    FROM seed s
   WHERE EXISTS (SELECT 1 FROM pgvigil.metric_catalog c WHERE c.key = s.metric)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.alert_rules r WHERE r.metric = s.metric AND r.scope = 'fleet')
  RETURNING rule_id, metric, name
)
INSERT INTO pgvigil.alert_rule_log (at, ui_user, client, op, rule_id, metric, outcome, detail)
SELECT now(), 'pgvigil', '0156 seed', 'seed', m.rule_id, m.metric, 'done', m.name || ': seeded off (task 405)'
  FROM made m;

-- ---- write latency (Changed 2) ------------------------------------------------------------------------------------

-- PerformanceMonitor 3.13.0 judges write latency on log files and tempdb's data files only (PgAnomalyDetector.cs
-- L401-426, PgFactCollector.Storage.cs L174-262), scored concerning at 10 ms and critical at 30 ms (FactScorer.cs L397)
-- over 250 writes (IoVolumeFloor.cs L42); a user data file is a sentence of its own, never scored. The lead's calls
-- (F6, F7, D1 a): 0124's 'slow data file writes' judges tempdb's data files only at 10 / 30 ms over 250 writes an
-- hour, its text giving the user data files' average; 0074's 'slow log writes' moves to 10 / 30 ms over 250 writes
-- (from 20 ms over 1,000, warning only: more alerts at an upgraded site, a release-note line); each stays per file
-- (PerformanceMonitor scores one server-wide figure: a stated departure). The two views are 0124's and 0074's whole
-- otherwise.
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
SELECT f.instance_id, CASE WHEN f.ms >= 30 THEN 'critical' ELSE 'warning' END, 'slow data file writes', f.database_name || ': ' || f.file_name, f.at,
       format('%s ms per write on average over the last hour (%s writes) to %s in tempdb (PerformanceMonitor 3.13 scores write latency '
              || 'concerning at 10 ms and critical at 30 ms over 250 writes): spills, sorts and work tables wait on tempdb''s writes.%s',
              round(f.ms, 1), f.writes, f.file_name,
              coalesce(' The user databases'' data files averaged ' || round(u.ms, 1) || ' ms per write over ' || u.writes
                       || ' writes in the same hour; they are not judged: their writes are asynchronous (checkpoint and the lazy writer).', ''))
  FROM (SELECT s.instance_id, s.database_name, s.file_name, sum(s.writes) AS writes,
               sum(s.write_stall_ms)::numeric / nullif(sum(s.writes), 0) AS ms, max(s.snapshot_at) AS at
          FROM pgvigil.mssql_fileio_sample s
         WHERE s.snapshot_at > now() - interval '1 hour' AND s.type_desc = 'ROWS' AND s.database_name = 'tempdb'
         GROUP BY s.instance_id, s.database_name, s.file_name) f
  LEFT JOIN LATERAL (SELECT sum(s.writes) AS writes, sum(s.write_stall_ms)::numeric / nullif(sum(s.writes), 0) AS ms
                       FROM pgvigil.mssql_fileio_sample s
                      WHERE s.instance_id = f.instance_id AND s.snapshot_at > now() - interval '1 hour' AND s.type_desc = 'ROWS'
                        AND s.database_name NOT IN ('tempdb', 'master', 'model', 'msdb')
                     HAVING sum(s.writes) > 0) u ON true
 WHERE f.writes >= 250 AND f.ms >= 10;

COMMENT ON VIEW pgvigil.mssql_cpu_findings IS 'Task 177 D14: other processes using the CPU, a transaction open for a long time; task 405: slow tempdb data file writes.';

CREATE OR REPLACE VIEW pgvigil.mssql_perf_findings AS
SELECT t.instance_id, 'warning'::text AS severity, 'tempdb has fewer data files than recommended'::text AS check_name,
       'tempdb'::text AS object, t.snapshot_at AS at,
       format('%s data file(s) on %s logical processors: Microsoft''s starting point is %s (as many as the processors, eight at most; '
              || 'more by fours only while allocation contention stays).', t.data_files, t.cpu_count, t.recommended_files) AS detail
  FROM pgvigil.mssql_tempdb t
 WHERE t.insufficient_files AND t.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT t.instance_id, 'warning', 'tempdb data files differ in size', 'tempdb', t.snapshot_at,
       format('the data files run from %s to %s: SQL Server fills them in proportion to their free space, so the largest takes most '
              || 'allocations and the contention more files were meant to spread comes back.', pg_size_pretty(t.min_file_bytes), pg_size_pretty(t.max_file_bytes))
  FROM pgvigil.mssql_tempdb t
 WHERE NOT t.even_size AND t.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT t.instance_id, 'warning', 'tempdb data files differ in growth', 'tempdb', t.snapshot_at,
       'the data files grow by different steps: the next growth leaves them of different sizes.'
  FROM pgvigil.mssql_tempdb t
 WHERE NOT t.even_growth AND t.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT t.instance_id, 'info', 'a tempdb data file grows by per cent', 'tempdb: ' || coalesce(f.file_name, f.file_id::text), t.snapshot_at,
       format('%s grows by %s %% of its size (%s now): each growth is larger than the last; a fixed size is the usual choice.',
              coalesce(f.file_name, f.file_id::text), f.growth_pct, pg_size_pretty(f.size_bytes))
  FROM pgvigil.mssql_tempdb t
  JOIN pgvigil.mssql_tempdb_files f ON f.instance_id = t.instance_id
 WHERE f.type_desc = 'ROWS' AND f.growth_pct > 0 AND t.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT t.instance_id, 'warning', 'tempdb trace flags 1117 / 1118 off before SQL Server 2016', 'tempdb', t.snapshot_at,
       format('SQL Server %s: trace flag 1117 is %s and 1118 is %s. Before 2016 they make the data files grow together and allocate '
              || 'full extents; from 2016 this is tempdb''s default and the flags are no longer required.', t.major,
              CASE WHEN t.tf1117 THEN 'on' ELSE 'off' END, CASE WHEN t.tf1118 THEN 'on' ELSE 'off' END)
  FROM pgvigil.mssql_tempdb t
 WHERE t.flags_required AND (t.tf1117 IS FALSE OR t.tf1118 IS FALSE) AND t.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT c.instance_id, CASE WHEN c.cpu_avg >= 95 THEN 'critical' ELSE 'warning' END, 'CPU at 90 % or more', 'cpu', c.at,
       CASE WHEN c.machine
            THEN format('the machine''s CPU averaged %s %% over the last %s minute(s) (SQL Server %s %%, other processes %s %%, peak %s %%).',
                        round(c.cpu_avg, 1), c.n, round(c.sql_avg, 1), round(c.cpu_avg - c.sql_avg, 1), c.cpu_max)
            ELSE format('the SQL Server process''s CPU averaged %s %% over the last %s minute(s), peak %s %% (a Linux host: the other processes are not read).',
                        round(c.cpu_avg, 1), c.n, c.cpu_max) END
  FROM (SELECT s.instance_id, count(*) AS n, avg(coalesce(100 - s.idle_pct, s.sql_pct)) AS cpu_avg, avg(s.sql_pct) AS sql_avg,
               max(coalesce(100 - s.idle_pct, s.sql_pct)) AS cpu_max, bool_and(s.idle_pct IS NOT NULL) AS machine,
               max(s.snapshot_at) AS at
          FROM pgvigil.mssql_cpu_sample s
         WHERE s.snapshot_at > now() - interval '15 minutes'
         GROUP BY s.instance_id) c
 WHERE c.n >= 10 AND c.cpu_avg >= 90
UNION ALL
SELECT p.instance_id, 'warning', 'scheduler pressure', 'schedulers', p.at,
       CASE WHEN p.runnable_per_sched >= 1
            THEN format('%s runnable task(s) per scheduler on average over the last %s reads (%s schedulers): work is ready and waits for a CPU '
                        || '(SOS_SCHEDULER_YIELD and signal wait follow).', round(p.runnable_per_sched, 2), p.n, p.schedulers)
            ELSE format('tasks waited in the work queue in %s of the last %s reads (at most %s): they wait for a worker thread (%s of %s in use '
                        || 'at the newest read); THREADPOOL waits follow.', p.queued_reads, p.n, p.max_queue, p.workers, p.max_workers) END
  FROM (SELECT s.instance_id, count(*) AS n, avg(s.runnable_tasks::numeric / nullif(s.schedulers, 0)) AS runnable_per_sched,
               count(*) FILTER (WHERE s.work_queue > 0) AS queued_reads, max(s.work_queue) AS max_queue, max(s.snapshot_at) AS at,
               (array_agg(s.schedulers ORDER BY s.snapshot_at DESC))[1] AS schedulers,
               (array_agg(s.current_workers ORDER BY s.snapshot_at DESC))[1] AS workers,
               (array_agg(s.max_workers ORDER BY s.snapshot_at DESC))[1] AS max_workers
          FROM pgvigil.mssql_sched_sample s
         WHERE s.snapshot_at > now() - interval '15 minutes'
         GROUP BY s.instance_id) p
 WHERE p.n >= 10 AND (p.runnable_per_sched >= 1 OR p.queued_reads * 2 >= p.n)
UNION ALL
SELECT m.instance_id, 'warning', 'available physical memory is low', 'memory', m.snapshot_at,
       format('the OS says "%s": %s available of %s; the SQL Server process uses %s%s.', m.system_state, pg_size_pretty(m.available_kb * 1024),
              pg_size_pretty(m.physical_kb * 1024), pg_size_pretty(m.process_kb * 1024),
              CASE WHEN m.process_low THEN ' and has had a low-memory notification' ELSE '' END)
  FROM (SELECT DISTINCT ON (s.instance_id) s.* FROM pgvigil.mssql_memory_sample s
         WHERE s.snapshot_at > now() - interval '15 minutes' ORDER BY s.instance_id, s.snapshot_at DESC) m
 WHERE m.system_state ILIKE '%memory is low%'
UNION ALL
SELECT g.instance_id, 'warning', 'queries wait for memory grants', 'memory grants', g.at,
       format('queries waited for a memory grant in %s of the last %s reads (at most %s at once): RESOURCE_SEMAPHORE waits; '
              || 'the largest grant granted was %s.', g.waiting_reads, g.n, g.max_waiting, pg_size_pretty(g.max_grant_kb * 1024))
  FROM (SELECT s.instance_id, count(*) AS n, count(*) FILTER (WHERE greatest(s.grants_pending, s.grants_waiting, s.sem_waiting) > 0) AS waiting_reads,
               max(greatest(s.grants_pending, s.grants_waiting, s.sem_waiting)) AS max_waiting, max(s.max_grant_kb) AS max_grant_kb,
               max(s.snapshot_at) AS at
          FROM pgvigil.mssql_memory_sample s
         WHERE s.snapshot_at > now() - interval '15 minutes'
         GROUP BY s.instance_id) g
 WHERE g.waiting_reads >= 3
UNION ALL
SELECT f.instance_id, CASE WHEN f.type_desc = 'LOG' THEN CASE WHEN f.write_ms >= 30 THEN 'critical' ELSE 'warning' END
                          WHEN f.read_ms >= 100 THEN 'critical' ELSE 'warning' END,
       CASE WHEN f.type_desc = 'LOG' THEN 'slow log writes' ELSE 'slow data file reads' END,
       coalesce(f.database_name, 'database ' || f.database_id) || ': ' || coalesce(f.file_name, 'file ' || f.file_id), f.at,
       CASE WHEN f.type_desc = 'LOG'
            THEN format('the log file''s writes took %s ms on average over the last hour (%s writes): every commit waits for them (WRITELOG; '
                        'PerformanceMonitor 3.13 scores write latency concerning at 10 ms and critical at 30 ms over 250 writes).',
                        round(f.write_ms, 1), f.writes)
            ELSE format('the data file''s reads took %s ms on average over the last hour (%s reads): PAGEIOLATCH waits follow.',
                        round(f.read_ms, 1), f.reads) END
  FROM (SELECT s.instance_id, s.database_id, s.file_id, max(s.database_name) AS database_name, max(s.file_name) AS file_name,
               max(s.type_desc) AS type_desc, sum(s.reads) AS reads, sum(s.writes) AS writes, max(s.snapshot_at) AS at,
               sum(s.read_stall_ms)::numeric / nullif(sum(s.reads), 0) AS read_ms,
               sum(s.write_stall_ms)::numeric / nullif(sum(s.writes), 0) AS write_ms
          FROM pgvigil.mssql_fileio_sample s
         WHERE s.snapshot_at > now() - interval '1 hour'
         GROUP BY s.instance_id, s.database_id, s.file_id) f
 WHERE (f.type_desc = 'LOG' AND f.writes >= 250 AND f.write_ms >= 10)
    OR (f.type_desc IS NOT NULL AND f.type_desc <> 'LOG' AND f.reads >= 1000 AND f.read_ms >= 50);

-- D1's retirement: an open alert of 'slow data file writes' on a user database's file (no longer judged) closes as
-- 'rule retired', not as a recovery: its alert_state row is cleared with no recovery message, and one 'cleared' row
-- per channel and instance in alert_log says why. A re-run finds none open.
SELECT pgvigil.ensure_month_partition('alert_log', now());
WITH r AS (
  UPDATE pgvigil.alert_state a SET missing_since = coalesce(a.missing_since, now()), cleared_at = now()
   WHERE a.cleared_at IS NULL AND a.source = 'mssql_cpu' AND a.setting = 'slow data file writes' AND a.value NOT LIKE 'tempdb: %'
  RETURNING a.channel, a.instance_id, a.finding_key
)
INSERT INTO pgvigil.alert_log (snapshot_at, instance_id, channel, n_resolved, outcome, error, keys)
SELECT now(), r.instance_id, r.channel, count(*), 'cleared',
       'rule retired (task 405, D1): a user data file''s write latency is no longer judged; no recovery is sent', array_agg(r.finding_key)
  FROM r GROUP BY r.channel, r.instance_id;

-- ---- Runnable Queue (Changed 13) ------------------------------------------------------------------------------------

-- mssql_runnable_queue: PerformanceMonitor 3.13.0's Runnable Queue reading (RunnableQueueEvaluator.cs L55-125) at p_at:
-- runnable tasks per scheduler averaged over the reads of the last 5 minutes when they are 3 or more; else over the
-- newest 3 reads when all 3 fall within the fallback window (10 minutes, or 4 times the reads' median spacing over the
-- last hour when that is longer: a collector running late under load, or one set to read every 5 minutes, is still
-- judged); else no row (no evaluation: the alert neither fires nor clears). darling_alert_findings' runnable arm reads
-- it (WIRING: 0118's view is not this task's file); the warning stays a warning and paging at critical only waits on
-- task 403's digest (the lead's D3 b); PerformanceMonitor's 30-minute stale resolve is not built (the lead's F3).
CREATE OR REPLACE FUNCTION pgvigil.mssql_runnable_queue(p_instance_id int, p_at timestamptz)
RETURNS TABLE (per_sched numeric, reads bigint, first_at timestamptz, at timestamptz, schedulers int, window_text text)
LANGUAGE sql STABLE AS $$
  WITH r AS (SELECT s.snapshot_at, s.runnable_tasks::numeric / s.schedulers AS ps, s.schedulers
               FROM pgvigil.mssql_sched_sample s
              WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_at - interval '60 minutes' AND s.snapshot_at <= p_at
                AND s.schedulers > 0 AND s.runnable_tasks IS NOT NULL),
  g AS (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY x.gap) AS cadence_s
          FROM (SELECT extract(epoch FROM r.snapshot_at - lag(r.snapshot_at) OVER (ORDER BY r.snapshot_at)) AS gap FROM r) x
         WHERE x.gap IS NOT NULL),
  w AS (SELECT r.* FROM r WHERE r.snapshot_at >= p_at - interval '5 minutes'),
  f AS (SELECT r.* FROM r ORDER BY r.snapshot_at DESC LIMIT 3),
  fw AS (SELECT greatest(600, 4 * coalesce(g.cadence_s, 60)) AS secs FROM g)
  SELECT avg(w.ps), count(*), min(w.snapshot_at), max(w.snapshot_at), (array_agg(w.schedulers ORDER BY w.snapshot_at DESC))[1],
         format('the %s reads of the last 5 minutes', count(*))
    FROM w HAVING count(*) >= 3
  UNION ALL
  SELECT avg(f.ps), count(*), min(f.snapshot_at), max(f.snapshot_at), (array_agg(f.schedulers ORDER BY f.snapshot_at DESC))[1],
         format('the newest 3 reads (fewer than 3 in the last 5 minutes; the 3 within %s minutes)', round((SELECT fw.secs FROM fw) / 60))
    FROM f
   WHERE (SELECT count(*) FROM w) < 3
  HAVING count(*) = 3 AND min(f.snapshot_at) >= p_at - make_interval(secs => coalesce((SELECT fw.secs FROM fw), 600))
$$;
