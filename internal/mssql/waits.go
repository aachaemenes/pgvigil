package mssql

import (
	"context"
	"database/sql"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// waitsCollector is mssql_waits: the server's wait statistics, every minute. sys.dm_os_wait_stats counts since the
// server started (or since someone cleared it), so the collector sends the counters as they are and the
// repository's import function stores the difference between two reads. A wait is counted when it ENDS: a session
// that has waited ten minutes on a lock shows in the Running queries snapshot now and here when the wait is over.
type waitsCollector struct{}

func init() { Register(waitsCollector{}) }

func (waitsCollector) Name() string                   { return Prefix + "waits" }
func (waitsCollector) DefaultInterval() time.Duration { return time.Minute }
func (waitsCollector) Applies(in Info) (bool, string) {
	if !in.ViewServerState {
		return false, "the login lacks VIEW SERVER STATE: sys.dm_os_wait_stats cannot be read"
	}
	return true, ""
}

// waitsStateSQL: the server's clock and its start time, both moved to UTC on the server. SQL Server 2016 SP1 and
// later, Azure SQL Managed Instance, Amazon RDS, Azure SQL Database.
const waitsStateSQL = `SELECT 'state' AS kind,
  TODATETIMEOFFSET(SYSUTCDATETIME(), 0) AS server_utc,
  TODATETIMEOFFSET(DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), sqlserver_start_time), 0) AS server_start
FROM sys.dm_os_sys_info`

// waitsSQL: every wait type the server has counted. {{dmv}} is sys.dm_os_wait_stats, or on Azure SQL Database
// sys.dm_db_wait_stats (the database's own waits; the server-wide view is the logical server's, not the tenant's).
// SQL Server 2016 SP1 and later.
const waitsSQL = `SELECT 'wait' AS kind,
  CAST(wait_type AS nvarchar(60)) AS wait_type,
  CAST(waiting_tasks_count AS bigint) AS waiting_tasks,
  CAST(wait_time_ms AS bigint) AS wait_ms,
  CAST(signal_wait_time_ms AS bigint) AS signal_ms,
  CAST(max_wait_time_ms AS bigint) AS max_wait_ms
FROM {{dmv}}
WHERE waiting_tasks_count > 0 OR wait_time_ms > 0`

func (waitsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	dmv := "sys.dm_os_wait_stats"
	if info.Kind == KindAzureDB {
		dmv = "sys.dm_db_wait_stats"
	}
	state, err := QueryRows(ctx, conn, waitsStateSQL)
	if err != nil {
		return nil, err
	}
	rows, err := QueryRows(ctx, conn, strings.ReplaceAll(waitsSQL, "{{dmv}}", dmv))
	if err != nil {
		return nil, err
	}
	for _, r := range state {
		r["source"] = dmv
	}
	for _, r := range rows {
		w, _ := r["wait_type"].(string)
		r["is_benign"] = benignWaits[w]
		if c := waitCategory(w); c != "" {
			r["category"] = c
		}
	}
	return append(state, rows...), nil
}

// benignWaits are the wait types of idle background work: a queue reader waiting for work, a timer, a sleeping
// system task. They are stored like every other wait and kept out of the top list, where they would outweigh every
// real wait by sheer time. The list is the rows marked Ignorable in the wait category table of sp_BlitzFirst 8.34
// (SQL Server First Responder Kit, MIT, Copyright (c) 2022 Brent Ozar Unlimited), ported as data.
var benignWaits = func() map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Fields(`
BROKER_EVENTHANDLER BROKER_RECEIVE_WAITFOR BROKER_TASK_STOP BROKER_TO_FLUSH BROKER_TRANSMITTER CHECKPOINT_QUEUE
CLR_AUTO_EVENT CLR_MANUAL_EVENT CLR_SEMAPHORE DBMIRROR_DBM_EVENT DBMIRROR_DBM_MUTEX DBMIRROR_EVENTS_QUEUE
DBMIRRORING_CMD DBMIRROR_WORKER_QUEUE DIRTY_PAGE_POLL DISPATCHER_QUEUE_SEMAPHORE FT_IFTSHC_MUTEX FT_IFTSISM_MUTEX
FT_IFTS_SCHEDULER_IDLE_WAIT HADR_CLUSAPI_CALL HADR_FABRIC_CALLBACK HADR_FILESTREAM_IOMGR_IOCOMPLETION
HADR_LOGCAPTURE_WAIT HADR_NOTIFICATION_DEQUEUE HADR_TIMER_TASK HADR_WORK_QUEUE LAZYWRITER_SLEEP LOGMGR_QUEUE
ONDEMAND_TASK_QUEUE PARALLEL_REDO_DRAIN_WORKER PARALLEL_REDO_LOG_CACHE PARALLEL_REDO_TRAN_LIST
PARALLEL_REDO_TRAN_TURN PARALLEL_REDO_WORKER_SYNC PARALLEL_REDO_WORKER_WAIT_WORK POPULATE_LOCK_ORDINALS
PREEMPTIVE_HADR_LEASE_MECHANISM PREEMPTIVE_SP_SERVER_DIAGNOSTICS PREEMPTIVE_XE_DISPATCHER QDS_ASYNC_QUEUE
QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP QDS_PERSIST_TASK_MAIN_LOOP_SLEEP QDS_SHUTDOWN_QUEUE
REDO_THREAD_PENDING_WORK REQUEST_FOR_DEADLOCK_SEARCH SLEEP_SYSTEMTASK SLEEP_TASK SOS_WORK_DISPATCHER
SP_SERVER_DIAGNOSTICS_SLEEP SQLTRACE_BUFFER_FLUSH SQLTRACE_INCREMENTAL_FLUSH_SLEEP UCS_SESSION_REGISTRATION WAITFOR
WAIT_XTP_OFFLINE_CKPT_NEW_LOG XE_DISPATCHER_WAIT XE_LIVE_TARGET_TVF XE_TIMER_EVENT`) {
		m[w] = true
	}
	return m
}()

// waitCategories names what a wait points at, for the waits a DBA reads first. The grouping is the wait list of
// sp_PressureDetector 6.11 (DarlingData, MIT, Copyright (c) 2021 Darling Data, LLC), ported as data; every lock
// wait (LCK_M_*) is Locking.
var waitCategories = map[string]string{
	"PAGEIOLATCH_SH": "Disk", "PAGEIOLATCH_EX": "Disk",
	"RESOURCE_SEMAPHORE": "Memory", "RESOURCE_SEMAPHORE_QUERY_COMPILE": "Memory", "CMEMTHREAD": "Memory", "SLEEP_BPOOL_STEAL": "Memory",
	"CXPACKET": "Parallelism", "CXCONSUMER": "Parallelism", "CXSYNC_PORT": "Parallelism", "CXSYNC_CONSUMER": "Parallelism",
	"SOS_SCHEDULER_YIELD": "CPU", "THREADPOOL": "CPU", "RESOURCE_GOVERNOR_IDLE": "CPU",
	"PAGELATCH_EX": "Page latch (tempdb, potentially)", "PAGELATCH_SH": "Page latch (tempdb, potentially)", "PAGELATCH_UP": "Page latch (tempdb, potentially)",
	"WRITELOG": "Transaction log", "LOGBUFFER": "Transaction log", "LOG_RATE_GOVERNOR": "Transaction log", "POOL_LOG_RATE_GOVERNOR": "Transaction log",
	"ASYNC_NETWORK_IO": "Query (client, spills, spools)", "EXECSYNC": "Query (client, spills, spools)", "IO_COMPLETION": "Query (client, spills, spools)",
	"HTBUILD": "Batch mode", "HTDELETE": "Batch mode", "HTMEMO": "Batch mode", "HTREINIT": "Batch mode", "HTREPARTITION": "Batch mode",
	"PWAIT_QRY_BPMEMORY": "Batch mode", "BPSORT": "Batch mode",
	"BTREE_INSERT_FLOW_CONTROL": "Sequential key",
	"HADR_SYNC_COMMIT":          "Availability group", "HADR_GROUP_COMMIT": "Availability group",
	"WAIT_ON_SYNC_STATISTICS_REFRESH": "Statistics",
	"IO_QUEUE_LIMIT":                  "Throttling", "IO_RETRY": "Throttling", "RESMGR_THROTTLED": "Throttling",
}

// waitCategory is the category of a wait type, "" where the list has none.
func waitCategory(w string) string {
	if strings.HasPrefix(w, "LCK_") {
		return "Locking"
	}
	return waitCategories[w]
}
