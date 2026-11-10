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
                            N'Database Cache Memory (KB)', N'Memory Grants Pending', N'Memory Grants Outstanding'))
   OR (RTRIM(object_name) LIKE N'%:Buffer Manager' AND counter_name = N'Page life expectancy')`

const memoryClerkSQL = `SELECT TOP (25) 'clerk' AS kind, CAST(type AS nvarchar(60)) AS clerk_type, SUM(CAST(pages_kb AS bigint)) AS pages_kb,
  SUM(CAST(virtual_memory_committed_kb AS bigint)) AS vm_committed_kb
FROM sys.dm_os_memory_clerks GROUP BY type ORDER BY SUM(CAST(pages_kb AS bigint)) DESC`

const memoryTotalsSQL = `SELECT 'clerks' AS kind, SUM(CAST(pages_kb AS bigint)) AS clerks_kb,
  SUM(CASE WHEN type IN (N'CACHESTORE_SQLCP', N'CACHESTORE_OBJCP', N'CACHESTORE_PHDR', N'CACHESTORE_XPROC') THEN CAST(pages_kb AS bigint) ELSE 0 END) AS plan_cache_kb
FROM sys.dm_os_memory_clerks`

const memoryGrantSQL = `SELECT 'grants' AS kind,
  (SELECT SUM(CAST(grantee_count AS bigint)) FROM sys.dm_exec_query_resource_semaphores) AS sem_granted,
  (SELECT SUM(CAST(waiter_count AS bigint)) FROM sys.dm_exec_query_resource_semaphores) AS sem_waiting,
  (SELECT SUM(CAST(granted_memory_kb AS bigint)) FROM sys.dm_exec_query_resource_semaphores) AS sem_granted_kb,
  (SELECT SUM(CAST(target_memory_kb AS bigint)) FROM sys.dm_exec_query_resource_semaphores) AS sem_target_kb,
  CAST(COUNT(g.session_id) AS bigint) AS grants,
  CAST(SUM(CASE WHEN g.grant_time IS NULL THEN 1 ELSE 0 END) AS bigint) AS grants_waiting,
  MAX(CAST(g.granted_memory_kb AS bigint)) AS max_grant_kb, SUM(CAST(g.granted_memory_kb AS bigint)) AS sum_grant_kb,
  MAX(CAST(g.requested_memory_kb AS bigint)) AS max_requested_kb
FROM sys.dm_exec_query_memory_grants g
WHERE g.session_id <> @@SPID`

func (memoryCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "sys.dm_os_sys_memory and sys.dm_os_memory_clerks"); err != nil {
		return nil, err
	}
	var out []collect.Row
	for _, q := range []string{memorySQL, memoryCounterSQL, memoryClerkSQL, memoryTotalsSQL, memoryGrantSQL} {
		rows, err := QueryRows(ctx, conn, q)
		if err != nil {
			return nil, err
		}
		out = append(out, rows...)
	}
	return out, nil
}
