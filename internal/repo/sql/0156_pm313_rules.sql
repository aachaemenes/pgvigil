-- 0156: PerformanceMonitor 3.13.0's moved rules in pgvigil (task 405, B11; audit-delta-dbadash-pm.md section 3:
-- Changed 2, 12, 13, 19, 46; Release 5; Fixed 8, 10, 20, 24). Each rule replaces the function or view that judged it,
-- under the same name and signature (a column only ever appended), so every reader keeps working:
--   mssql_plancache_summary_between  Fixed 10: plan cache bloat over compiled plans only (every cache type but Parse
--                                    Tree and Extended Proc, a stub counts), a 100 MB floor on the single-use compiled
--                                    plans' size with its two texts, the bands over 20 / 30 / 50 %, the advice
--                                    'optimize for ad hoc workloads' first; compiled_plans appended.
--   mssql_memory_findings_between    0119's body; its plan cache sentence names the compiled plans.
-- Source (MIT): PerformanceMonitor 3.13.0 (Erik Darling, Darling Data LLC), PerformanceMonitor.Common/
-- PlanCacheBloatRule.cs L30-108. The lead's calls on the design pass (20261114-141436-reviewer) are the build's
-- shape; each behaviour change at an upgraded site has its release-note line (no site runs pgvigil before v0.4.0).

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
