package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// cpuCollector is mssql_cpu: the server's CPU and scheduler pressure, every minute.
//
//   - CPU: the scheduler monitor's records in sys.dm_os_ring_buffers (RING_BUFFER_SCHEDULER_MONITOR), one a minute,
//     the last 256 kept by the server: the SQL Server process's share of the machine's CPU (ProcessUtilization) and
//     the idle share (SystemIdle); the rest is the other processes'. SQL Server on Linux writes SystemIdle as 0 in
//     every record (read on SQL Server 2022 on Linux: idle 0 at 1 % SQL Server CPU), so on a Linux host
//     (sys.dm_os_host_info) the idle and other shares are stored as not read and only the SQL Server share counts. Every run sends the records the buffer holds;
//     the import stores a record once, so a collector that was stopped for up to four hours loses no minute. The
//     ring buffer's records are documented by Microsoft as "for informational purposes only, not supported"; every
//     SQL Server monitoring tool reads them (sp_PressureDetector, sp_BlitzFirst, DBA Dash), and nothing else gives
//     the per-minute split on a box without an OS agent.
//   - Scheduler pressure: sys.dm_os_schedulers over the VISIBLE ONLINE schedulers at the read: the runnable tasks
//     (workers ready and waiting for a CPU), the work queue (tasks waiting for a worker), the pending disk IOs, the
//     current and active workers against max worker threads.
//   - Throughput: sys.dm_os_performance_counters' Batch Requests/sec, SQL Compilations/sec, SQL Re-Compilations/sec
//     and Databases _Total Transactions/sec, which count since the server started: the import stores each
//     interval's rate per second (no rate across a restart or a counter that went down).
//   - The performance counters (task 177 D14): the same read of sys.dm_os_performance_counters also returns the
//     counters of sp_PressureDetector's perfmon list and PerformanceMonitor's (perfmonCounters), every instance but
//     sp_PressureDetector's system names, as rows of their own kind 'perfmon' for mssql_counter_sample (0124); the
//     per-database objects (Databases, Database Replica) are read every 5 minutes by mssql_activity, not here.
//   - The schedulers taken offline (VISIBLE OFFLINE) and the NUMA nodes online and in all, the DAC's node left out
//     (PerformanceMonitor's CpuSchedulerStatsCollector), in the scheduler statement.
//
// Rights: VIEW SERVER STATE; on SQL Server 2022 and later VIEW SERVER PERFORMANCE STATE is enough (perfState). Runs
// on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed Instance; not on Azure SQL Database, where the
// ring buffer and the schedulers are the host's (the database's own CPU is sys.dm_db_resource_stats, a later wave).
type cpuCollector struct{}

func init() { Register(cpuCollector{}) }

func (cpuCollector) Name() string                   { return Prefix + "cpu" }
func (cpuCollector) DefaultInterval() time.Duration { return time.Minute }
func (cpuCollector) Applies(info Info) (bool, string) {
	return perfApplies(info, "sys.dm_os_ring_buffers and sys.dm_os_schedulers")
}

// perfApplies is the Applies rule of the performance collections (cpu, memory, fileio): not on Azure SQL Database;
// the right is VIEW SERVER STATE, or from SQL Server 2022 VIEW SERVER PERFORMANCE STATE, which Detect does not
// read: a 2022 (or Managed Instance) login without VIEW SERVER STATE is let through and perfState asks the server in the run.
func perfApplies(info Info, what string) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "not on Azure SQL Database: " + what + " there are the host's, not the database's"
	// Managed Instance answers 12.0 as its version and runs the current engine: perfState asks it in the run
	case !info.ViewServerState && info.Major < 16 && info.Kind != KindAzureMI:
		return false, "the login lacks VIEW SERVER STATE: " + what + " cannot be read"
	}
	return true, ""
}

// perfState says whether the login may read the server's performance DMVs: VIEW SERVER STATE, or on SQL Server
// 2022 and later VIEW SERVER PERFORMANCE STATE (a part of VIEW SERVER STATE since 2022). Without either the run is
// skipped with the missing right named.
func perfState(ctx context.Context, conn *sql.Conn, info Info, what string) error {
	if info.ViewServerState {
		return nil
	}
	var ok sql.NullInt64
	if err := conn.QueryRowContext(ctx, `SELECT CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE'), 0) AS int)`).Scan(&ok); err != nil {
		return err
	}
	if ok.Int64 == 1 {
		return nil
	}
	return fmt.Errorf("the login lacks VIEW SERVER STATE and VIEW SERVER PERFORMANCE STATE: %s cannot be read: %w", what, collect.ErrSkip)
}

// perfStateSQL: the server's clock and its start time, both in UTC, as mssql_waits reads them; the import's
// differences need the clock between two reads and the start time to see a restart.
const perfStateSQL = `SELECT 'state' AS kind,
  TODATETIMEOFFSET(SYSUTCDATETIME(), 0) AS server_utc,
  TODATETIMEOFFSET(DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), sqlserver_start_time), 0) AS server_start
FROM sys.dm_os_sys_info`

// cpuRingSQL: every scheduler monitor record the server holds, its time moved to UTC from the server's tick count
// (timestamp and ms_ticks are both milliseconds since the machine started). record_id counts up from the start.
const cpuRingSQL = `SELECT 'cpu' AS kind, x.record_id,
  CONVERT(varchar(33), DATEADD(millisecond, CAST(x.ts - si.ms_ticks AS int), SYSUTCDATETIME()), 126) + 'Z' AS sample_at,
  x.sql_pct, x.idle_pct
FROM (SELECT rb.[timestamp] AS ts,
             r.x.value('(./Record/@id)[1]', 'bigint') AS record_id,
             r.x.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS sql_pct,
             r.x.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS idle_pct
        FROM sys.dm_os_ring_buffers rb
        CROSS APPLY (SELECT CONVERT(xml, rb.record)) r(x)
       WHERE rb.ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND rb.record LIKE N'%<SystemHealth>%') x
CROSS JOIN sys.dm_os_sys_info si
WHERE x.ts <= si.ms_ticks AND si.ms_ticks - x.ts < 86400000`

// cpuSchedSQL: the schedulers that run user work, summed, with the server's worker limit and CPU count; the
// schedulers taken offline and the NUMA nodes (online, all; the DAC's node left out by its state, as
// PerformanceMonitor's collector does) as one-row pieces cross joined, which leave the sums as they are.
const cpuSchedSQL = `SELECT 'sched' AS kind, COUNT(*) AS schedulers,
  SUM(CAST(s.runnable_tasks_count AS bigint)) AS runnable_tasks, SUM(CAST(s.work_queue_count AS bigint)) AS work_queue,
  SUM(CAST(s.pending_disk_io_count AS bigint)) AS pending_io, SUM(CAST(s.current_workers_count AS bigint)) AS current_workers,
  SUM(CAST(s.active_workers_count AS bigint)) AS active_workers,
  MAX(CAST(si.max_workers_count AS bigint)) AS max_workers, MAX(CAST(si.cpu_count AS bigint)) AS cpu_count,
  MAX(o.offline_cpus) AS offline_cpus, MAX(n.nodes_total) AS nodes_total, MAX(n.nodes_online) AS nodes_online
FROM sys.dm_os_schedulers s CROSS JOIN sys.dm_os_sys_info si
CROSS JOIN (SELECT CAST(COUNT(*) AS bigint) AS offline_cpus FROM sys.dm_os_schedulers WHERE status = N'VISIBLE OFFLINE') o
CROSS JOIN (SELECT CAST(COUNT(*) AS bigint) AS nodes_total,
                   CAST(SUM(CASE WHEN node_state_desc NOT LIKE N'OFFLINE%' THEN 1 ELSE 0 END) AS bigint) AS nodes_online
              FROM sys.dm_os_nodes WHERE node_state_desc NOT LIKE N'%DAC%') n
WHERE s.status = N'VISIBLE ONLINE'`

// cpuCounterSQL: the cumulative throughput counters and the instance-level performance counters, in one read.
// object_name carries the instance's prefix (SQLServer: or MSSQL$<name>:) and is nchar padded with blanks: trimmed
// before the match. cpuCounterRows splits the rows into the two kinds.
var cpuCounterSQL = `SELECT CAST(RTRIM(object_name) AS nvarchar(128)) AS object, CAST(RTRIM(counter_name) AS nvarchar(128)) AS counter,
  CAST(RTRIM(instance_name) AS nvarchar(128)) AS instance, CAST(cntr_value AS bigint) AS value, CAST(cntr_type AS bigint) AS type
FROM sys.dm_os_performance_counters
WHERE (RTRIM(object_name) LIKE N'%:SQL Statistics'
       AND counter_name IN (N'Batch Requests/sec', N'SQL Compilations/sec', N'SQL Re-Compilations/sec'))
   OR (RTRIM(object_name) LIKE N'%:Databases' AND counter_name = N'Transactions/sec' AND instance_name = N'_Total')
   OR (counter_name IN (` + perfmonInList() + `)
       AND RTRIM(object_name) NOT LIKE N'%:Databases' AND RTRIM(object_name) NOT LIKE N'%:Database Replica'
       AND RTRIM(instance_name) NOT IN (` + perfmonSkipInList() + `))`

func (cpuCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "sys.dm_os_ring_buffers and sys.dm_os_schedulers"); err != nil {
		return nil, err
	}
	var out []collect.Row
	for _, q := range []string{perfStateSQL, cpuSchedSQL} {
		rows, err := QueryRows(ctx, conn, q)
		if err != nil {
			return nil, err
		}
		out = append(out, rows...)
	}
	counters, err := QueryRows(ctx, conn, cpuCounterSQL)
	if err != nil {
		return nil, err
	}
	out = append(out, cpuCounterRows(counters, false)...)
	// the ring buffer is read on its own: a server that refuses it (a build without the record) keeps the rest
	ring, err := QueryRows(ctx, conn, cpuRingSQL)
	if err != nil {
		return append(out, collect.Row{"kind": "collector_error", "source": "sys.dm_os_ring_buffers", "message": err.Error()}), nil
	}
	return append(out, cpuRows(ring, linuxHost(ctx, conn))...), nil
}

// linuxHost says whether SQL Server runs on Linux (sys.dm_os_host_info, SQL Server 2017 and later; an older
// server, which has no such view, runs on Windows).
func linuxHost(ctx context.Context, conn *sql.Conn) bool {
	var p sql.NullString
	if err := conn.QueryRowContext(ctx, `SELECT CAST(host_platform AS nvarchar(256)) FROM sys.dm_os_host_info`).Scan(&p); err != nil {
		return false
	}
	return p.String == "Linux"
}

// cpuRows keeps the ring buffer's records that carry both figures; other_pct is the machine's CPU the SQL Server
// process did not use (never below zero: the two figures are read a moment apart). On a Linux host the idle figure
// is always 0 and is dropped with the other share: only the SQL Server process's share is known.
func cpuRows(ring []collect.Row, linux bool) []collect.Row {
	out := make([]collect.Row, 0, len(ring))
	for _, r := range ring {
		s, ok1 := r["sql_pct"].(int64)
		i, ok2 := r["idle_pct"].(int64)
		if !ok1 || !ok2 || r["record_id"] == nil {
			continue
		}
		other := 100 - s - i
		if other < 0 {
			other = 0
		}
		r["other_pct"] = other
		if linux {
			r["idle_pct"], r["other_pct"] = nil, nil
		}
		out = append(out, r)
	}
	return out
}

// perfmonCounters is the counter list of task 177 D14: PerformanceMonitor's (PerfmonStatsCollector.DefaultCounters,
// 3.12.0, 61 names), which is sp_PressureDetector's perfmon list (sp_PressureDetector.sql, darlingdata-20261101,
// L2373-2386, 59 names) and the two Database Replica names. Every instance of each is read; sp_PressureDetector's
// system names (perfmonSkip) are left out.
var perfmonCounters = []string{
	"Forwarded Records/sec", "Table Lock Escalations/sec", "Page reads/sec", "Page writes/sec", "Checkpoint pages/sec", "Requests completed/sec",
	"Transactions/sec", "Lock Requests/sec", "Lock Wait Time (ms)", "Lock Waits/sec", "Number of Deadlocks/sec", "Log Flushes/sec", "Page lookups/sec",
	"Granted Workspace Memory (KB)", "Lock Memory (KB)", "Memory Grants Pending", "SQL Cache Memory (KB)", "Background writer pages/sec",
	"Stolen Server Memory (KB)", "Target Server Memory (KB)", "Total Server Memory (KB)", "Lazy writes/sec", "Readahead pages/sec",
	"Batch Requests/sec", "SQL Compilations/sec", "SQL Re-Compilations/sec", "Longest Transaction Running Time", "Log Bytes Flushed/sec",
	"Lock waits", "Log buffer waits", "Log write waits", "Memory grant queue waits", "Network IO waits", "Log Flush Write Time (ms)",
	"Non-Page latch waits", "Page IO latch waits", "Page latch waits", "Thread-safe memory objects waits", "Wait for the worker",
	"Active parallel threads", "Active requests", "Blocked tasks", "Query optimizations/sec", "Queued requests", "Reduced memory grants/sec",
	"Version Store Size (KB)", "Free Space in tempdb (KB)", "Active Temp Tables", "Processes blocked", "Full Scans/sec", "Index Searches/sec",
	"Page Splits/sec", "Free list stalls/sec", "Workfiles Created/sec", "Worktables Created/sec", "Temp Tables Creation Rate", "Version Generation rate (KB/s)",
	"Version Cleanup rate (KB/s)", "Lock Timeouts/sec",
	"Transaction Delay", "Mirrored Write Transactions/sec",
}

// perfmonSkip: the instance names sp_PressureDetector leaves out of its perfmon read (the system databases, and the
// internal workload group and resource pool).
var perfmonSkip = []string{"internal", "master", "model", "msdb", "model_msdb", "model_replicatedmaster", "mssqlsystemresource"}

func nList(names []string) string {
	q := make([]string, len(names))
	for i, n := range names {
		q[i] = "N'" + strings.ReplaceAll(n, "'", "''") + "'"
	}
	return strings.Join(q, ", ")
}

func perfmonInList() string     { return nList(perfmonCounters) }
func perfmonSkipInList() string { return nList(perfmonSkip) }

// perDBObject: the objects whose instances are databases (or a database's replica), read every 5 minutes.
func perDBObject(object string) bool {
	o := counterObject(object)
	return o == "Databases" || o == "Database Replica"
}

// counterObject drops the instance's prefix from object_name (SQLServer:Buffer Manager, MSSQL$NAMED:Buffer Manager).
func counterObject(object string) string {
	if i := strings.Index(object, ":"); i >= 0 {
		return object[i+1:]
	}
	return object
}

// cpuCounterRows splits one read of sys.dm_os_performance_counters into the two kinds the import takes:
//   - 'counter': the four throughput counters exactly as cpu.go always sent them (counter, value; 0074's import keys
//     them by name and keeps their last values in mssql_perf_counter_last);
//   - 'perfmon': a counter of perfmonCounters with its object (prefix dropped), instance (an empty name read as _Total, as
//     sp_PressureDetector does), raw value and cntr_type, for 0124's mssql_counter_sample. perDB keeps the per-database
//     objects (mssql_activity's 5-minute read); otherwise they are left to it.
func cpuCounterRows(rows []collect.Row, perDB bool) []collect.Row {
	want := make(map[string]bool, len(perfmonCounters))
	for _, c := range perfmonCounters {
		want[c] = true
	}
	skip := make(map[string]bool, len(perfmonSkip))
	for _, s := range perfmonSkip {
		skip[s] = true
	}
	var out []collect.Row
	for _, r := range rows {
		object, _ := r["object"].(string)
		counter, _ := r["counter"].(string)
		inst, _ := r["instance"].(string)
		obj := counterObject(object)
		if !perDB && ((obj == "SQL Statistics" && (counter == "Batch Requests/sec" || counter == "SQL Compilations/sec" || counter == "SQL Re-Compilations/sec")) ||
			(obj == "Databases" && counter == "Transactions/sec" && inst == "_Total")) {
			out = append(out, collect.Row{"kind": "counter", "counter": counter, "value": r["value"]})
		}
		if !want[counter] || skip[inst] || perDBObject(object) != perDB {
			continue
		}
		if inst == "" {
			inst = "_Total"
		}
		out = append(out, collect.Row{"kind": "perfmon", "object": obj, "counter": counter, "instance": inst, "value": r["value"], "type": r["type"]})
	}
	return out
}
