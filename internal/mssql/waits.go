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
  TODATETIMEOFFSET(DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), sqlserver_start_time), 0) AS server_start
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

// WaitFamily is a group of wait types that share the start of their name, and what a wait of the group means.
type WaitFamily struct {
	Prefix      string `json:"prefix"`
	Description string `json:"description"`
}

// waitFamilies describes the groups, the longest prefix first where one starts with another. The texts here and in
// waitDescriptions are this project's own wording of what each wait means for a DBA; none is copied from a tool's
// table or from the product documentation.
var waitFamilies = []WaitFamily{
	{"LCK_M_", "A session waited for a lock another session held. The rest of the name is the lock mode it asked for (S shared, U update, X exclusive, IS / IU / IX intent, SCH_S / SCH_M schema, RS / RI / RX key range). The cause is the holder's transaction, never the object waited on: the Running queries and Blocking pages name the head of the chain."},
	{"PAGEIOLATCH_", "A session waited for a data page to come from disk into memory (SH to read it, EX or UP to change it). A large share means slow data file storage, or too little memory for the pages the workload reads."},
	{"PAGELATCH_", "A session waited for a page that is already in memory, because other sessions were changing it. On tempdb's allocation pages this is the contention more tempdb data files relieve; on a user table it is many inserts at the end of one index."},
	{"LATCH_", "A wait for an internal structure that is not a data page: a parallel scan's shared state, a file that grows, an allocation cache. Some of it is normal with parallel queries; sys.dm_os_latch_stats names the latch class."},
	{"PREEMPTIVE_", "The thread left SQL Server's scheduler to call the operating system or an outside component (a file operation, an account lookup, a linked server, an extended or CLR procedure). The time runs until the call returns."},
	{"HADR_", "An Always On availability group wait. Most are background threads waiting for work; HADR_SYNC_COMMIT is the one that delays commits."},
	{"CX", "A parallel query's threads waited for each other."},
}

// waitDescriptions says what a wait type means, for the types a DBA meets most. A type without an entry takes its
// family's text; a wait of idle background work (benignWaits) says so on the page.
var waitDescriptions = map[string]string{
	"LCK_M_SCH_M":                      "A schema change (an index rebuild, ALTER TABLE, a partition switch) waited for every user of the object to finish. Every session that arrives after it queues behind it, so a short DDL statement can stall a busy table.",
	"LCK_M_SCH_S":                      "A session waited for a schema stability lock: a schema change holds the object, or is queued for it.",
	"LATCH_EX":                         "A wait for an exclusive latch on an internal structure. With parallel scans it is mostly the scan's shared range (ACCESS_METHODS_DATASET_PARENT); sys.dm_os_latch_stats names the class.",
	"CXPACKET":                         "Threads of a parallel query waited to pass rows to each other. Expected wherever queries run in parallel; a large share next to high CPU points at queries that go parallel too readily (cost threshold for parallelism, MAXDOP) or at plans whose threads get uneven shares of the rows.",
	"CXCONSUMER":                       "The reading side of a parallel exchange waited for rows from the threads that produce them. The query waits on its own work: mostly harmless.",
	"CXSYNC_PORT":                      "A parallel query's threads waited to open or line up an exchange. Newer versions count this apart from CXPACKET; read it the same way.",
	"CXSYNC_CONSUMER":                  "A parallel query's threads waited to line up at an exchange. Newer versions count this apart from CXPACKET; read it the same way.",
	"EXECSYNC":                         "A parallel query's threads waited for a shared area that is not an exchange: a bitmap, a spool, a large object.",
	"SOS_SCHEDULER_YIELD":              "A thread used its whole time slice and stepped aside for the next one. Nothing was missing: it marks queries that burn CPU. Read it with the signal share here and the runnable tasks on the CPU page.",
	"THREADPOOL":                       "A task waited for a worker thread because every one was in use. Serious: new logins and queries stall. The usual causes are a long blocking chain that holds workers, or many parallel queries at once.",
	"RESOURCE_SEMAPHORE":               "A query waited for its memory grant, the workspace its sorts and hashes asked for, before it could start. The Memory page shows the grants and the largest one.",
	"RESOURCE_SEMAPHORE_QUERY_COMPILE": "A query waited for memory to compile its plan: too many large compilations ran at once.",
	"CMEMTHREAD":                       "Threads waited for a shared memory allocator. It grows with very many small allocations on a machine with many cores.",
	"MEMORY_ALLOCATION_EXT":            "A thread took memory from the operating system or from SQL Server's own memory manager; it is counted as time outside the scheduler. Large totals come with very many small allocations.",
	"WRITELOG":                         "A session waited at commit for its log records to reach the disk. Slow log storage, or very many small transactions that each commit on their own.",
	"LOGBUFFER":                        "A session waited for room in the log buffer because the log writer was behind: the log's storage cannot keep up.",
	"LOGMGR_RESERVE_APPEND":            "A task waited to see whether truncating the log makes room for its record: the log file is full and can neither grow nor be truncated.",
	"ASYNC_NETWORK_IO":                 "SQL Server had rows ready and waited for the client to take them. The application reads slowly (row by row work, a very large result) or the network is slow; the server is not what holds the query back.",
	"IO_COMPLETION":                    "A wait for an I/O that is not a data page read: a sort or a hash spilling to tempdb, a backup or a restore, a file header.",
	"ASYNC_IO_COMPLETION":              "A wait for a long asynchronous I/O to finish: a backup, or a file created or grown without instant file initialization.",
	"WRITE_COMPLETION":                 "A task waited for a write outside the normal checkpoint path to finish: a file growing, a sort run, a bulk load.",
	"SLEEP_BPOOL_FLUSH":                "A checkpoint slowed itself down so that its writes do not flood the disks: the storage is the limit while a checkpoint runs.",
	"BACKUPIO":                         "A backup or a restore waited for its data: the backup's target (or source) is slower than the database's files.",
	"BACKUPBUFFER":                     "A backup or a restore waited for a free buffer: the backup's target (or source) is slower than the database's files.",
	"BACKUPTHREAD":                     "A task waited for a backup thread: another backup or restore of the same database was running.",
	"HADR_SYNC_COMMIT":                 "A commit on the primary waited for a synchronous secondary to write the log. The time is the network round trip and the secondary's log write: the price of synchronous commit.",
	"OLEDB":                            "SQL Server waited inside an OLE DB provider: a linked server query, or one of the DMVs and DBCC commands that go through the provider (a monitoring tool's own reads are counted here).",
	"MSQL_XP":                          "A session waited for an extended stored procedure (an xp_ call) to return.",
	"MSQL_DQ":                          "A session waited for a distributed query, a linked server, to return.",
	"DTC":                              "A task waited for the distributed transaction coordinator (MSDTC) while a distributed transaction changed its state.",
	"TRACEWRITE":                       "A SQL Trace reader (Profiler) waited for events. Idle time, unless a slow Profiler client holds the sessions it traces back.",
	"WAIT_ON_SYNC_STATISTICS_REFRESH":  "A query waited while statistics it needs were updated before it could compile (synchronous statistics update).",
	"BTREE_INSERT_FLOW_CONTROL":        "Inserts at the end of an index were slowed on purpose by OPTIMIZE_FOR_SEQUENTIAL_KEY, so that a busy last page does not stall every session at once.",
	"HTBUILD":                          "Batch mode hash threads waited for each other while a hash table was built.",
	"HTDELETE":                         "Batch mode hash threads waited for each other while a hash table was released.",
	"HTMEMO":                           "Batch mode hash threads waited for each other at a shared hash table.",
	"HTREINIT":                         "Batch mode hash threads waited for each other while a hash table was set up again.",
	"HTREPARTITION":                    "Batch mode hash threads waited for each other while a hash table's rows were spread over partitions again.",
	"BPSORT":                           "Batch mode sort threads waited for each other.",
	"LOG_RATE_GOVERNOR":                "The service limited how fast the log may be written (the log rate limit of the database's service tier): the workload writes more log than the tier allows.",
	"POOL_LOG_RATE_GOVERNOR":           "The service limited how fast the elastic pool's log may be written: the pool's databases write more log than its tier allows.",
	"INSTANCE_LOG_RATE_GOVERNOR":       "The service limited how fast the managed instance's log may be written: the workload writes more log than its tier allows.",
	"IO_QUEUE_LIMIT":                   "The service throttled the database's I/O: more was queued than its tier allows.",
	"RESMGR_THROTTLED":                 "Resource Governor held a request back because its pool or group was at a limit.",
	"RESOURCE_GOVERNOR_IDLE":           "Resource Governor kept a CPU idle to hold a pool under its CPU cap.",
	"PREEMPTIVE_OS_WRITEFILEGATHER":    "SQL Server waited for the operating system to grow and zero a file: a data file growing without instant file initialization, or any growth of a log file (a log is always zeroed).",
	"PREEMPTIVE_OS_AUTHENTICATIONOPS":  "SQL Server waited for the operating system to check an account: a slow or unreachable domain controller shows here.",
	"PREEMPTIVE_OS_LOOKUPACCOUNTSID":   "SQL Server waited for the operating system to resolve an account's identifier: a slow or unreachable domain controller shows here.",
	"PREEMPTIVE_OS_GETPROCADDRESS":     "SQL Server loaded and ran an extended stored procedure (an xp_ call); the time includes the procedure's own run.",
	"WAITFOR":                          "A session ran WAITFOR: it sleeps because its own code asked to.",
}

// WaitDescriptions returns what each described wait type means, by type.
func WaitDescriptions() map[string]string {
	out := make(map[string]string, len(waitDescriptions))
	for k, v := range waitDescriptions {
		out[k] = v
	}
	return out
}

// WaitFamilies returns the groups of wait types by the start of their name, in the order a type is matched against.
func WaitFamilies() []WaitFamily {
	return append([]WaitFamily(nil), waitFamilies...)
}
