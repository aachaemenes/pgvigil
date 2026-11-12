package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// memoryCollector is mssql_memory: where the server's memory is, every minute.
//
//   - The machine and the process: sys.dm_os_sys_memory (physical and available memory, the OS's memory state) and
//     sys.dm_os_process_memory (the SQL Server process's working set, its low-memory flag); sys.dm_os_sys_info's
//     committed and target memory and the memory model (CONVENTIONAL, LOCK_PAGES, LARGE_PAGES).
//   - The Memory Manager and Buffer Manager counters of sys.dm_os_performance_counters (values as they stand, not
//     cumulative): Target and Total Server Memory, Stolen Server Memory, Database Cache Memory (the buffer pool),
//     Memory Grants Pending and Outstanding, Page life expectancy.
//   - The memory clerks: sys.dm_os_memory_clerks summed by type, the 25 largest by pages_kb and the total of all;
//     the plan cache is the four plan cache stores (SQLCP, OBJCP, PHDR, XPROC).
//   - Memory grants: sys.dm_exec_query_resource_semaphores summed (granted queries, waiters, granted and target KB)
//     and sys.dm_exec_query_memory_grants at the read (the largest and the summed grant, the queries waiting: the
//     Max / Sum Memory Grant KB of DBA Dash's Running Queries row), the collector's own session left out.
//   - The grant semaphores one by one (task 177, D03): each row of sys.dm_exec_query_resource_semaphores with its
//     resource pool's name: target and max target, total, available, granted and used memory, grantees and waiters,
//     and the two counters since the server started, timeout_error_count and forced_grant_count (the repository
//     stores their differences between reads: sp_PerfCheck's forced-grant check over an interval).
//   - The NUMA nodes (sp_Blitz's CMEMTHREAD-on-NUMA check): node 0's online schedulers and how many other nodes
//     there are that are not the dedicated admin connection's (sys.dm_os_nodes).
//   - Task 177, D13 (Erik Darling's sp_PressureDetector memory section and PerformanceMonitor 3.12.0's Memory tab,
//     MIT, Copyright (c) Erik Darling, Darling Data LLC; the First Responder Kit's sp_Blitz 145 / 146 and
//     sp_BlitzFirst 45 / 46, MIT, Copyright (c) Brent Ozar Unlimited): the MEMORYCLERK_XTP clerks and the
//     TokenAndPermUserStore of USERSTORE_TOKENPERM in the clerk totals; the Maximum and Granted Workspace Memory
//     counters; and five reads that are each kept apart (a failed one sends a 'skip' row naming it, the rest stand):
//     'rmon' the resource-monitor ring buffer (PerformanceMonitor's MemoryPressureEventsCollector: every record,
//     its time from ms_ticks in UTC to the millisecond, the notification and the process and system indicators;
//     sp_PressureDetector's available physical and virtual memory beside them; the record id keys it), 'cache' the
//     cache counters (sp_PressureDetector's cache_memory: the 20 largest by pages, UserStore and ObjPerm caches
//     folded, the system databases' caches left out), 'plantype' the plan cache by cache and object type
//     (PerformanceMonitor's PlanCacheStatsCollector, its columns), 'mgrant' the 50 largest asks of
//     sys.dm_exec_query_memory_grants (sp_PressureDetector's grant list: requested, granted, used, max used, ideal
//     and required memory, the queue, the wait order, the next candidate, the session's longest wait, the DOP; and
//     sp_BlitzWho's query_cost; the statement's text, its first 4,000 characters), 'rgroup' / 'rpool' the Resource
//     Governor workload groups and resource pools with their limits (sp_PressureDetector's grant cap and reduced
//     grants among them).
//
// Rights as mssql_cpu (perfApplies). Runs on SQL Server 2016 SP1 and later (sql_memory_model_desc), Amazon RDS and
// Azure SQL Managed Instance; not on Azure SQL Database (no sys.dm_os_sys_memory or sys.dm_os_process_memory there).
type memoryCollector struct{}

func init() { Register(memoryCollector{}) }

func (memoryCollector) Name() string                   { return Prefix + "memory" }
func (memoryCollector) DefaultInterval() time.Duration { return time.Minute }
func (memoryCollector) Applies(info Info) (bool, string) {
	return perfApplies(info, "sys.dm_os_sys_memory and sys.dm_os_memory_clerks")
}

const memorySQL = `SELECT 'memory' AS kind,
  CAST(sm.total_physical_memory_kb AS bigint) AS physical_kb, CAST(sm.available_physical_memory_kb AS bigint) AS available_kb,
  CAST(sm.system_memory_state_desc AS nvarchar(256)) AS system_state,
  CAST(pm.physical_memory_in_use_kb AS bigint) AS process_kb, CAST(pm.process_physical_memory_low AS int) AS process_low,
  CAST(si.committed_kb AS bigint) AS committed_kb, CAST(si.committed_target_kb AS bigint) AS committed_target_kb,
  CAST(si.sql_memory_model_desc AS nvarchar(60)) AS memory_model
FROM sys.dm_os_sys_memory sm CROSS JOIN sys.dm_os_process_memory pm CROSS JOIN sys.dm_os_sys_info si`

// memoryCounterSQL: the point-in-time Memory Manager and Buffer Manager counters (cntr_type 65792); Page life
// expectancy is the Buffer Manager's (instance_name blank), not a NUMA node's.
const memoryCounterSQL = `SELECT 'counter' AS kind, CAST(RTRIM(counter_name) AS nvarchar(128)) AS counter, CAST(cntr_value AS bigint) AS value
FROM sys.dm_os_performance_counters
WHERE (RTRIM(object_name) LIKE N'%:Memory Manager'
       AND counter_name IN (N'Target Server Memory (KB)', N'Total Server Memory (KB)', N'Stolen Server Memory (KB)',
                            N'Database Cache Memory (KB)', N'Memory Grants Pending', N'Memory Grants Outstanding',
                            N'Maximum Workspace Memory (KB)', N'Granted Workspace Memory (KB)'))
   OR (RTRIM(object_name) LIKE N'%:Buffer Manager' AND counter_name = N'Page life expectancy')`

const memoryClerkSQL = `SELECT TOP (25) 'clerk' AS kind, CAST(type AS nvarchar(60)) AS clerk_type, SUM(CAST(pages_kb AS bigint)) AS pages_kb,
  SUM(CAST(virtual_memory_committed_kb AS bigint)) AS vm_committed_kb
FROM sys.dm_os_memory_clerks GROUP BY type ORDER BY SUM(CAST(pages_kb AS bigint)) DESC`

const memoryTotalsSQL = `SELECT 'clerks' AS kind, SUM(CAST(pages_kb AS bigint)) AS clerks_kb,
  SUM(CASE WHEN type IN (N'CACHESTORE_SQLCP', N'CACHESTORE_OBJCP', N'CACHESTORE_PHDR', N'CACHESTORE_XPROC') THEN CAST(pages_kb AS bigint) ELSE 0 END) AS plan_cache_kb,
  SUM(CASE WHEN type = N'MEMORYCLERK_XTP' THEN CAST(pages_kb AS bigint) ELSE 0 END) AS xtp_kb,
  SUM(CASE WHEN type = N'USERSTORE_TOKENPERM' AND name = N'TokenAndPermUserStore' THEN CAST(pages_kb AS bigint) ELSE 0 END) AS tokenperm_kb
FROM sys.dm_os_memory_clerks`

const memoryGrantSQL = `SELECT 'grants' AS kind,
  (SELECT SUM(CAST(grantee_count AS bigint)) FROM sys.dm_exec_query_resource_semaphores) AS sem_granted,
  (SELECT SUM(CAST(waiter_count AS bigint)) FROM sys.dm_exec_query_resource_semaphores) AS sem_waiting,
  (SELECT SUM(CAST(granted_memory_kb AS bigint)) FROM sys.dm_exec_query_resource_semaphores) AS sem_granted_kb,
  (SELECT SUM(CAST(target_memory_kb AS bigint)) FROM sys.dm_exec_query_resource_semaphores) AS sem_target_kb,
  CAST(COUNT(g.session_id) AS bigint) AS grants,
  CAST(ISNULL(SUM(CASE WHEN g.grant_time IS NULL THEN 1 ELSE 0 END), 0) AS bigint) AS grants_waiting,
  ISNULL(MAX(CAST(g.granted_memory_kb AS bigint)), 0) AS max_grant_kb, ISNULL(SUM(CAST(g.granted_memory_kb AS bigint)), 0) AS sum_grant_kb,
  MAX(CAST(g.requested_memory_kb AS bigint)) AS max_requested_kb
FROM sys.dm_exec_query_memory_grants g
WHERE g.session_id <> @@SPID`

// memoryPoolSQL: one row per grant semaphore (two per resource pool: 0 the regular one, 1 the small-query one).
const memoryPoolSQL = `SELECT 'pool' AS kind, CAST(s.pool_id AS int) AS pool_id, CAST(p.name AS nvarchar(128)) AS pool_name,
  CAST(s.resource_semaphore_id AS int) AS semaphore_id, CAST(s.target_memory_kb AS bigint) AS target_kb,
  CAST(s.max_target_memory_kb AS bigint) AS max_target_kb, CAST(s.total_memory_kb AS bigint) AS total_kb,
  CAST(s.available_memory_kb AS bigint) AS available_kb, CAST(s.granted_memory_kb AS bigint) AS granted_kb,
  CAST(s.used_memory_kb AS bigint) AS used_kb, CAST(s.grantee_count AS int) AS grantees, CAST(s.waiter_count AS int) AS waiters,
  CAST(s.timeout_error_count AS bigint) AS timeout_errors, CAST(s.forced_grant_count AS bigint) AS forced_grants
FROM sys.dm_exec_query_resource_semaphores s
LEFT JOIN sys.dm_resource_governor_resource_pools p ON p.pool_id = s.pool_id`

// memoryNumaSQL: sp_Blitz's NUMA test (check 162): node 0's online schedulers, and the nodes after it that are not
// the dedicated admin connection's.
const memoryNumaSQL = `SELECT 'numa' AS kind,
  (SELECT CAST(online_scheduler_count AS int) FROM sys.dm_os_nodes WHERE node_id = 0) AS node0_schedulers,
  (SELECT CAST(COUNT(*) AS int) FROM sys.dm_os_nodes WHERE node_id > 0 AND node_state_desc NOT LIKE N'%DAC') AS other_nodes`

// memoryRmonSQL: PerformanceMonitor 3.12.0 MemoryPressureEventsCollector's read (the time in UTC from ms_ticks, to
// the millisecond) with the record's id and sp_PressureDetector's available physical and virtual memory.
const memoryRmonSQL = `DECLARE @ms_ticks bigint, @now datetime2(7) = SYSUTCDATETIME(), @start datetime;
SELECT @ms_ticks = ms_ticks, @start = sqlserver_start_time FROM sys.dm_os_sys_info;
SELECT 'rmon' AS kind, CAST(t.record.value('(/Record/@id)[1]', 'bigint') AS bigint) AS record_id,
  CONVERT(varchar(30), @start, 126) AS server_start,
  CONVERT(varchar(30), DATEADD(MILLISECOND, -((@ms_ticks - t.timestamp) % 1000), DATEADD(SECOND, -((@ms_ticks - t.timestamp) / 1000), @now)), 126) + 'Z' AS sample_at,
  CAST(t.record.value('(/Record/ResourceMonitor/Notification)[1]', 'nvarchar(100)') AS nvarchar(100)) AS notification,
  t.record.value('(/Record/ResourceMonitor/IndicatorsProcess)[1]', 'int') AS ind_process,
  t.record.value('(/Record/ResourceMonitor/IndicatorsSystem)[1]', 'int') AS ind_system,
  t.record.value('(/Record/MemoryRecord/AvailablePhysicalMemory)[1]', 'bigint') AS avail_phys_kb,
  t.record.value('(/Record/MemoryRecord/AvailableVirtualAddressSpace)[1]', 'bigint') AS avail_vas_kb
FROM (SELECT dorb.timestamp, CONVERT(xml, dorb.record) AS record FROM sys.dm_os_ring_buffers AS dorb
      WHERE dorb.ring_buffer_type = N'RING_BUFFER_RESOURCE_MONITOR') AS t
ORDER BY t.timestamp`

// memoryCacheSQL: sp_PressureDetector's cache_memory read (sys.dm_os_memory_cache_counters, its folding, its
// exclusions, its HAVING and its order), in KB.
const memoryCacheSQL = `SELECT TOP (20) 'cache' AS kind,
  CAST(CASE WHEN domcc.name LIKE N'%UserStore%' THEN N'UserStore' WHEN domcc.name LIKE N'ObjPerm%' THEN N'ObjPerm' ELSE domcc.name END AS nvarchar(256)) AS cache_name,
  SUM(CAST(domcc.pages_kb AS bigint)) AS pages_kb, SUM(CAST(domcc.pages_in_use_kb AS bigint)) AS pages_in_use_kb,
  SUM(CAST(domcc.entries_count AS bigint)) AS entries, SUM(CAST(domcc.entries_in_use_count AS bigint)) AS entries_in_use
FROM sys.dm_os_memory_cache_counters AS domcc
WHERE domcc.name NOT IN (N'msdb', N'model_replicatedmaster', N'model_msdb', N'model', N'master', N'mssqlsystemresource')
GROUP BY CASE WHEN domcc.name LIKE N'%UserStore%' THEN N'UserStore' WHEN domcc.name LIKE N'ObjPerm%' THEN N'ObjPerm' ELSE domcc.name END
HAVING SUM(domcc.pages_in_use_kb) / 1024. / 1024. > 0
ORDER BY SUM(CAST(domcc.pages_kb AS bigint)) DESC`

// memoryPlanTypeSQL: PerformanceMonitor 3.12.0 PlanCacheStatsCollector's read, sizes in KB (it rounds to MB).
const memoryPlanTypeSQL = `SELECT 'plantype' AS kind, CAST(cp.cacheobjtype AS nvarchar(50)) AS cache_type, CAST(cp.objtype AS nvarchar(20)) AS object_type,
  COUNT_BIG(*) AS plans, SUM(CAST(cp.size_in_bytes AS bigint)) / 1024 AS size_kb,
  SUM(CASE WHEN cp.usecounts = 1 THEN CAST(1 AS bigint) ELSE 0 END) AS single_use_plans,
  SUM(CASE WHEN cp.usecounts = 1 THEN CAST(cp.size_in_bytes AS bigint) ELSE 0 END) / 1024 AS single_use_kb,
  SUM(CASE WHEN cp.usecounts > 1 THEN CAST(1 AS bigint) ELSE 0 END) AS multi_use_plans,
  SUM(CASE WHEN cp.usecounts > 1 THEN CAST(cp.size_in_bytes AS bigint) ELSE 0 END) / 1024 AS multi_use_kb,
  CONVERT(decimal(38, 2), AVG(CONVERT(bigint, cp.usecounts))) AS avg_use_count
FROM sys.dm_exec_cached_plans AS cp
GROUP BY cp.cacheobjtype, cp.objtype`

// memoryGrantQuerySQL: sp_PressureDetector's grant list (its joins: the request, the session's longest waiting
// task, the statement's text) with sp_BlitzWho's query_cost; the 50 largest asks; the times as ages in ms at the read.
const memoryGrantQuerySQL = `SELECT TOP (50) 'mgrant' AS kind, CAST(g.session_id AS int) AS session_id, CAST(g.request_id AS int) AS request_id,
  CAST(DB_NAME(ISNULL(r.database_id, t.dbid)) AS nvarchar(128)) AS database_name,
  DATEDIFF_BIG(MILLISECOND, g.request_time, GETDATE()) AS request_age_ms,
  DATEDIFF_BIG(MILLISECOND, g.grant_time, GETDATE()) AS grant_age_ms,
  CAST(g.wait_time_ms AS bigint) AS wait_time_ms, CAST(g.requested_memory_kb AS bigint) AS requested_kb,
  CAST(g.granted_memory_kb AS bigint) AS granted_kb, CAST(g.used_memory_kb AS bigint) AS used_kb,
  CAST(g.max_used_memory_kb AS bigint) AS max_used_kb, CAST(g.ideal_memory_kb AS bigint) AS ideal_kb,
  CAST(g.required_memory_kb AS bigint) AS required_kb, CAST(g.queue_id AS int) AS queue_id, CAST(g.wait_order AS int) AS wait_order,
  CAST(g.is_next_candidate AS int) AS is_next_candidate, CAST(g.timeout_sec AS int) AS timeout_sec,
  CAST(g.resource_semaphore_id AS int) AS semaphore_id, CAST(g.pool_id AS int) AS pool_id, CAST(g.group_id AS int) AS group_id,
  CAST(g.is_small AS int) AS is_small, CAST(g.dop AS int) AS dop, CAST(g.query_cost AS float) AS query_cost,
  CAST(w.wait_type AS nvarchar(60)) AS wait_type, CAST(w.wait_duration_ms AS bigint) AS wait_ms,
  CONVERT(varchar(130), g.plan_handle, 1) AS plan_handle,
  CAST(LEFT(SUBSTRING(t.text, ISNULL(r.statement_start_offset, 0) / 2 + 1,
       CASE WHEN r.statement_end_offset IS NULL OR r.statement_end_offset = -1 THEN DATALENGTH(t.text)
            ELSE (r.statement_end_offset - r.statement_start_offset) / 2 + 1 END), 4000) AS nvarchar(4000)) AS statement
FROM sys.dm_exec_query_memory_grants AS g
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = g.session_id AND r.request_id = g.request_id
OUTER APPLY (SELECT TOP (1) dowt.wait_type, dowt.wait_duration_ms FROM sys.dm_os_waiting_tasks AS dowt
             WHERE dowt.session_id = g.session_id ORDER BY dowt.wait_duration_ms DESC) AS w
OUTER APPLY sys.dm_exec_sql_text(COALESCE(g.sql_handle, g.plan_handle)) AS t
WHERE g.session_id <> @@SPID
ORDER BY g.requested_memory_kb DESC, g.request_time`

// memoryRgGroupSQL / memoryRgPoolSQL: the Resource Governor's workload groups and resource pools with their limits.
const memoryRgGroupSQL = `SELECT 'rgroup' AS kind, CAST(g.group_id AS int) AS group_id, CAST(g.name AS nvarchar(128)) AS group_name,
  CAST(g.pool_id AS int) AS pool_id, CAST(g.importance AS nvarchar(60)) AS importance,
  CAST(g.request_max_memory_grant_percent AS int) AS max_grant_pct, CAST(g.request_max_cpu_time_sec AS int) AS max_cpu_sec,
  CAST(g.request_memory_grant_timeout_sec AS int) AS grant_timeout_sec, CAST(g.group_max_requests AS int) AS max_requests,
  CAST(g.max_dop AS int) AS max_dop, CAST(g.total_reduced_memgrant_count AS bigint) AS reduced_grants,
  CAST(g.total_request_count AS bigint) AS requests, CAST(g.active_request_count AS int) AS active_requests,
  CAST(g.queued_request_count AS int) AS queued_requests, CAST(g.max_request_grant_memory_kb AS bigint) AS max_request_grant_kb
FROM sys.dm_resource_governor_workload_groups AS g`

const memoryRgPoolSQL = `SELECT 'rpool' AS kind, CAST(p.pool_id AS int) AS pool_id, CAST(p.name AS nvarchar(128)) AS pool_name,
  CAST(p.min_memory_percent AS int) AS min_memory_pct, CAST(p.max_memory_percent AS int) AS max_memory_pct,
  CAST(p.max_memory_kb AS bigint) AS max_memory_kb, CAST(p.used_memory_kb AS bigint) AS used_memory_kb,
  CAST(p.target_memory_kb AS bigint) AS target_memory_kb, CAST(p.cache_memory_kb AS bigint) AS cache_memory_kb,
  CAST(p.used_memgrant_kb AS bigint) AS used_memgrant_kb, CAST(p.total_memgrant_count AS bigint) AS memgrants,
  CAST(p.total_memgrant_timeout_count AS bigint) AS memgrant_timeouts, CAST(p.memgrant_waiter_count AS int) AS memgrant_waiters,
  CAST(p.out_of_memory_count AS bigint) AS out_of_memory
FROM sys.dm_resource_governor_resource_pools AS p`

// memoryApart: the reads of D13 that a server may refuse on its own (a ring buffer or a view a managed service
// keeps back): each failure is a 'skip' row naming the read and the server's message, and the collection stands.
var memoryApart = []struct{ name, query string }{
	{"rmon", memoryRmonSQL}, {"cache", memoryCacheSQL}, {"plantype", memoryPlanTypeSQL}, {"mgrant", memoryGrantQuerySQL},
	{"rgroup", memoryRgGroupSQL}, {"rpool", memoryRgPoolSQL},
}

func (memoryCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "sys.dm_os_sys_memory and sys.dm_os_memory_clerks"); err != nil {
		return nil, err
	}
	var out []collect.Row
	for _, q := range []string{memorySQL, memoryCounterSQL, memoryClerkSQL, memoryTotalsSQL, memoryGrantSQL, memoryPoolSQL, memoryNumaSQL} {
		rows, err := QueryRows(ctx, conn, q)
		if err != nil {
			return nil, err
		}
		out = append(out, rows...)
	}
	for _, a := range memoryApart {
		rows, err := QueryRows(ctx, conn, a.query)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			out = append(out, collect.Row{"kind": "skip", "read": a.name, "error": err.Error()})
			continue
		}
		out = append(out, rows...)
	}
	return out, nil
}
