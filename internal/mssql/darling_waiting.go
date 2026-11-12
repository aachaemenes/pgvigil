package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// waitingCollector is mssql_waiting_tasks (task 177, darling-open D01): what every waiting task of the server waits on
// now, every minute. One row per task of sys.dm_os_waiting_tasks (a parallel request has one per exec context), its
// blocker, the resource decoded to database, object and index where the server can say, and the statement of its
// request; migration 0108 keeps them.
//
// The read is PerformanceMonitor's waiting-tasks collector (PerformanceMonitor.Collectors/WaitingTasksCollector.cs,
// Darling Data, MIT; the notice is in 0108 and THIRD-PARTY-NOTICES.md): its FROM and WHERE kept as they are, and its
// ignore list (IgnoredWaitDefaults.All, 126 wait types, as data below) applied after the read as it applies it, so
// the rows are the rows PerformanceMonitor would store from the same server at the same moment, widened by the exec
// context, the resource and the request's statement (the columns Get-DbaWaitingTask reads). Like PerformanceMonitor's,
// the join to the request is by session: a MARS session's task can be paired with another request of the session.
// THREADPOOL is counted apart, with no filter, as sp_PressureDetector reads it: a login queued for a worker has no
// request yet, so the WHERE above would drop it.
//
// Decoding the resource: a lock resource names a database id and a hobt id (key, page, rid locks) or an object id
// (object locks); a page latch names database:file:page, which sys.dm_db_page_info (SQL Server 2019 and later, Azure)
// turns into an object and index. The names are read in each database's own catalog, one read per database; a
// database the login cannot read leaves its rows undecoded and the read says why (decode_note).
type waitingCollector struct{}

func init() { Register(waitingCollector{}) }

func (waitingCollector) Name() string                   { return Prefix + "waiting_tasks" }
func (waitingCollector) DefaultInterval() time.Duration { return time.Minute }
func (waitingCollector) Applies(in Info) (bool, string) {
	if !in.ViewServerState {
		return false, "the login lacks VIEW SERVER STATE: sys.dm_os_waiting_tasks shows the login's own tasks only"
	}
	return true, ""
}

// waitingCap is the most tasks one read keeps (the longest waits first); the summary keeps the full count.
const waitingCap = 2000

// pageLatchCap is the most contended pages one read decodes through sys.dm_db_page_info (a read of a hot page waits
// on the same latch it reports).
const pageLatchCap = 10

// pmIgnoredWaits is PerformanceMonitor's IgnoredWaitDefaults.All (v3.12.0, Darling Data, MIT), used as data: the wait
// types its waiting-tasks collector leaves out.
var pmIgnoredWaits = func() map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Fields(`
AZURE_IMDS_VERSIONS BMPALLOCATION BMPBUILD BMPREPARTITION BROKER_EVENTHANDLER BROKER_RECEIVE_WAITFOR
BROKER_TASK_STOP BROKER_TO_FLUSH BROKER_TRANSMITTER BUFFERPOOL_SCAN CHECKPOINT_QUEUE CHKPT CLR_AUTO_EVENT
CLR_MANUAL_EVENT CLR_SEMAPHORE COLUMNSTORE_BUILD_THROTTLE DAC_INIT DBMIRROR_DBM_EVENT DBMIRROR_DBM_MUTEX
DBMIRROR_EVENTS_QUEUE DBMIRRORING_CMD DBMIRROR_SEND DBMIRROR_WORKER_QUEUE DIRTY_PAGE_POLL DIRTY_PAGE_TABLE_LOCK
DISPATCHER_QUEUE_SEMAPHORE FSAGENT FT_IFTSHC_MUTEX FT_IFTS_SCHEDULER_IDLE_WAIT HADR_CLUSAPI_CALL
HADR_FABRIC_CALLBACK HADR_FILESTREAM_IOMGR_IOCOMPLETION HADR_LOGCAPTURE_WAIT HADR_NOTIFICATION_DEQUEUE
HADR_TIMER_TASK HADR_WORK_QUEUE KSOURCE_WAKEUP LAZYWRITER_SLEEP LOGMGR_QUEUE MEMORY_ALLOCATION_EXT
ONDEMAND_TASK_QUEUE PARALLEL_REDO_DRAIN_WORKER PARALLEL_REDO_FLOW_CONTROL PARALLEL_REDO_LOG_CACHE
PARALLEL_REDO_TRAN_LIST PARALLEL_REDO_TRAN_TURN PARALLEL_REDO_WORKER_SYNC PARALLEL_REDO_WORKER_WAIT_WORK
PERFORMANCE_COUNTERS_RWLOCK PREEMPTIVE_OS_FLUSHFILEBUFFERS PREEMPTIVE_XE_CALLBACKEXECUTE PREEMPTIVE_XE_DISPATCHER
PREEMPTIVE_XE_GETTARGETSTATE PREEMPTIVE_XE_SESSIONCOMMIT PREEMPTIVE_XE_TARGETFINALIZE PREEMPTIVE_XE_TARGETINIT
PRINT_ROLLBACK_PROGRESS PURVIEW_POLICY_SDK_PREEMPTIVE_SCHEDULING PVS_PREALLOCATE PWAIT_ALL_COMPONENTS_INITIALIZED
PWAIT_DIRECTLOGCONSUMER_GETNEXT PWAIT_EXTENSIBILITY_CLEANUP_TASK PWAIT_HADR_ACTION_COMPLETED
PWAIT_HADR_CHANGE_NOTIFIER_TERMINATION_SYNC PWAIT_HADR_CLUSTER_INTEGRATION PWAIT_HADR_FAILOVER_COMPLETED
PWAIT_HADR_JOIN PWAIT_HADR_OFFLINE_COMPLETED PWAIT_HADR_ONLINE_COMPLETED PWAIT_HADR_POST_ONLINE_COMPLETED
PWAIT_HADR_SERVER_READY_CONNECTIONS PWAIT_HADRSIM PWAIT_HADR_WORKITEM_COMPLETED PWAIT_MASTERDBREADY QDS_ASYNC_QUEUE
QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP QDS_PERSIST_TASK_MAIN_LOOP_SLEEP QDS_SHUTDOWN_QUEUE
QUERY_EXECUTION_INDEX_SORT_EVENT_OPEN QUERY_TASK_ENQUEUE_MUTEX RBIO_COMM_RETRY REDO_THREAD_PENDING_WORK
REQUEST_FOR_DEADLOCK_SEARCH RESOURCE_QUEUE RESOURCE_SEMAPHORE_MUTEX SECURITY_CNG_PROVIDER_MUTEX SERVER_IDLE_CHECK
SLEEP_BUFFERPOOL_HELPLW SLEEP_DBSTARTUP SLEEP_DCOMSTARTUP SLEEP_MASTERDBREADY SLEEP_MASTERMDREADY
SLEEP_MASTERUPGRADED SLEEP_MSDBSTARTUP SLEEP_PHYSMASTERDBREADY SLEEP_SYSTEMTASK SLEEP_TASK SLEEP_TEMPDBSTARTUP
SNI_CRITICAL_SECTION SNI_HTTP_ACCEPT SOS_PROCESS_AFFINITY_MUTEX SOS_WORK_DISPATCHER SP_SERVER_DIAGNOSTICS_SLEEP
SQLTRACE_BUFFER_FLUSH SQLTRACE_FILE_BUFFER SQLTRACE_FILE_READ_IO_COMPLETION SQLTRACE_FILE_WRITE_IO_COMPLETION
SQLTRACE_INCREMENTAL_FLUSH_SLEEP SQLTRACE_WAIT_ENTRIES SQP_STATS_REPORTING UCS_SESSION_REGISTRATION
VDI_CLIENT_OTHER WAITFOR WAIT_FOR_RESULTS WAITFOR_TASKSHUTDOWN WAIT_XTP_CKPT_CLOSE WAIT_XTP_HOST_WAIT
WAIT_XTP_OFFLINE_CKPT_NEW_LOG WAIT_XTP_RECOVERY WINDOW_AGGREGATES_MULTIPASS XE_BUFFERMGR_ALLPROCESSED_EVENT
XE_DISPATCHER_JOIN XE_DISPATCHER_WAIT XE_FILE_TARGET_TVF XE_LIVE_TARGET_TVF XE_TIMER_EVENT`) {
		m[w] = true
	}
	return m
}()

// threadpoolSQL counts the tasks waiting for a worker with no filter (sp_PressureDetector's read).
const threadpoolSQL = `SELECT COUNT(*) AS n, MAX(wait_duration_ms) AS longest FROM sys.dm_os_waiting_tasks WHERE wait_type = N'THREADPOOL'`

// waitingSQL is PerformanceMonitor's query (WaitingTasksCollector.QueryText) with pgvigil's columns added; its WHERE
// clause is unchanged, the PerformanceMonitor database test included (it is 0 on a server without one).
const waitingSQL = `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT /* pgvigil mssql_waiting_tasks: PerformanceMonitor's waiting-tasks read (Darling Data, MIT) */
    session_id = wt.session_id,
    exec_context_id = wt.exec_context_id,
    wait_type = wt.wait_type,
    wait_duration_ms = wt.wait_duration_ms,
    blocking_session_id = NULLIF(wt.blocking_session_id, @@SPID),
    blocking_exec_context_id = wt.blocking_exec_context_id,
    resource_description = LEFT(wt.resource_description, 1000),
    database_name = d.name,
    request_status = er.status,
    command = er.command,
    statement = LEFT(SUBSTRING(st.text, er.statement_start_offset / 2 + 1,
        CASE WHEN er.statement_end_offset = -1 THEN 2147483647
             ELSE (er.statement_end_offset - er.statement_start_offset) / 2 + 1 END), 4000),
    server_utc = TODATETIMEOFFSET(SYSUTCDATETIME(), 0)
FROM sys.dm_os_waiting_tasks AS wt
LEFT JOIN sys.dm_exec_requests AS er
  ON er.session_id = wt.session_id
LEFT JOIN sys.databases AS d
  ON d.database_id = er.database_id
OUTER APPLY sys.dm_exec_sql_text(er.sql_handle) AS st
WHERE wt.session_id >= 50
AND   wt.session_id <> @@SPID
AND   wt.wait_type IS NOT NULL
AND   er.database_id <> ISNULL(DB_ID(N'PerformanceMonitor'), 0)
OPTION(RECOMPILE);`

// waitResource is what a resource description names.
type waitResource struct {
	kind             string // key, page, rid, object, hobt, allocation unit, extent, metadata, application, page latch, exchange, other
	dbid, file, page int64
	hobt, object     int64
}

var (
	reLockDB   = regexp.MustCompile(`\bdbid=(\d+)`)
	reHobt     = regexp.MustCompile(`\bhobtid=(\d+)`)
	reAssoc    = regexp.MustCompile(`\bassociatedObjectId=(\d+)`)
	reObjID    = regexp.MustCompile(`\bobjid=(-?\d+)`)
	reFile     = regexp.MustCompile(`\bfileid=(\d+)`)
	rePage     = regexp.MustCompile(`\bpageid=(\d+)`)
	rePageLtch = regexp.MustCompile(`^\s*(\d+):(\d+):(\d+)\s*$`)
)

func num64(re *regexp.Regexp, s string) int64 {
	if m := re.FindStringSubmatch(s); m != nil {
		v, _ := strconv.ParseInt(m[1], 10, 64)
		return v
	}
	return 0
}

// parseResource reads a sys.dm_os_waiting_tasks resource_description.
func parseResource(desc string) waitResource {
	d := strings.TrimSpace(desc)
	r := waitResource{kind: "other"}
	switch {
	case d == "":
		r.kind = ""
	case strings.HasPrefix(d, "keylock"):
		r.kind, r.dbid, r.hobt = "key", num64(reLockDB, d), num64(reHobt, d)
	case strings.HasPrefix(d, "pagelock"):
		r.kind, r.dbid, r.hobt, r.file, r.page = "page", num64(reLockDB, d), num64(reAssoc, d), num64(reFile, d), num64(rePage, d)
	case strings.HasPrefix(d, "ridlock"):
		r.kind, r.dbid, r.hobt, r.file, r.page = "rid", num64(reLockDB, d), num64(reAssoc, d), num64(reFile, d), num64(rePage, d)
	case strings.HasPrefix(d, "objectlock"):
		r.kind, r.dbid, r.object = "object", num64(reLockDB, d), num64(reObjID, d)
	case strings.HasPrefix(d, "hobtlock"):
		r.kind, r.dbid, r.hobt = "hobt", num64(reLockDB, d), num64(reHobt, d)
	case strings.HasPrefix(d, "allocunitlock"):
		r.kind, r.dbid = "allocation unit", num64(reLockDB, d)
	case strings.HasPrefix(d, "extentlock"):
		r.kind, r.dbid = "extent", num64(reLockDB, d)
	case strings.HasPrefix(d, "metadatalock"):
		r.kind, r.dbid = "metadata", num64(reLockDB, d)
	case strings.HasPrefix(d, "applicationlock"):
		r.kind, r.dbid = "application", num64(reLockDB, d)
	case strings.HasPrefix(d, "exchangeEvent"):
		r.kind = "exchange"
	default:
		if m := rePageLtch.FindStringSubmatch(d); m != nil {
			r.kind = "page latch"
			r.dbid, _ = strconv.ParseInt(m[1], 10, 64)
			r.file, _ = strconv.ParseInt(m[2], 10, 64)
			r.page, _ = strconv.ParseInt(m[3], 10, 64)
		}
	}
	return r
}

// bracket quotes a database name as QUOTENAME does.
func bracket(name string) string { return "[" + strings.ReplaceAll(name, "]", "]]") + "]" }

// joinIDs writes integer ids for an IN list (they come from strconv, never from text).
func joinIDs(ids map[int64]bool) string {
	out := make([]string, 0, len(ids))
	for v := range ids {
		out = append(out, strconv.FormatInt(v, 10))
	}
	sort.Strings(out)
	return strings.Join(out, ",")
}

// pageInfoOK says whether sys.dm_db_page_info exists here (SQL Server 2019 and later, the Azure kinds).
func pageInfoOK(in Info) bool {
	return in.Kind == KindAzureDB || in.Kind == KindAzureMI || in.Major >= 15
}

func (waitingCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	start := time.Now()
	raw, err := QueryRows(ctx, conn, waitingSQL)
	if err != nil {
		return nil, err
	}
	var tasks []collect.Row
	var serverUTC any
	for _, r := range raw {
		if serverUTC == nil {
			serverUTC = r["server_utc"]
		}
		w, _ := r["wait_type"].(string)
		w = strings.TrimSpace(w)
		if w == "" || pmIgnoredWaits[w] {
			continue
		}
		r["wait_type"] = w
		tasks = append(tasks, r)
	}
	sort.SliceStable(tasks, func(i, j int) bool {
		a, _ := asInt(tasks[i]["wait_duration_ms"])
		b, _ := asInt(tasks[j]["wait_duration_ms"])
		return a > b
	})
	sessions := map[int64]bool{}
	var longest int64
	for i, t := range tasks {
		s, _ := asInt(t["session_id"])
		sessions[s] = true
		if ms, ok := asInt(t["wait_duration_ms"]); ok && (i == 0 || ms > longest) {
			longest = ms
		}
	}
	tp, err := QueryRows(ctx, conn, threadpoolSQL)
	if err != nil {
		return nil, err
	}
	var threadpool, tpLongest any = int64(0), nil
	if len(tp) == 1 {
		threadpool, tpLongest = tp[0]["n"], tp[0]["longest"]
	}
	total := len(tasks)
	if len(tasks) > waitingCap {
		tasks = tasks[:waitingCap]
	}
	notes := decodeResources(ctx, conn, info, tasks)
	out := make([]collect.Row, 0, len(tasks)+1)
	for _, t := range tasks {
		out = append(out, collect.Row{
			"kind": "task", "session_id": t["session_id"], "exec_context_id": t["exec_context_id"], "wait_type": t["wait_type"],
			"wait_ms": t["wait_duration_ms"], "blocking_session_id": t["blocking_session_id"],
			"blocking_exec_context_id": t["blocking_exec_context_id"], "resource_description": t["resource_description"],
			"resource_kind": t["resource_kind"], "database_name": t["database_name"], "object_name": t["object_name"],
			"index_name": t["index_name"], "request_status": t["request_status"], "command": t["command"],
			"statement": t["statement"],
		})
	}
	summary := collect.Row{
		"kind": "summary", "server_utc": serverUTC, "tasks": total, "stored": len(tasks), "sessions": len(sessions),
		"threadpool": threadpool, "threadpool_longest_ms": tpLongest, "decode_note": strings.Join(notes, "; "),
		"read_ms": time.Since(start).Milliseconds(),
	}
	if total > 0 {
		summary["longest_ms"] = longest
	}
	return append(out, summary), nil
}

// decodeResources fills resource_kind, and object_name / index_name where the resource names them; the notes say what
// could not be decoded. A lock's database is the resource's own dbid, which can differ from the request's database.
func decodeResources(ctx context.Context, conn *sql.Conn, info Info, tasks []collect.Row) []string {
	type want struct {
		hobts, objects map[int64]bool
		pages          map[[2]int64]bool
	}
	res := make([]waitResource, len(tasks))
	byDB := map[int64]*want{}
	pages := 0
	for i, t := range tasks {
		d, _ := t["resource_description"].(string)
		res[i] = parseResource(d)
		t["resource_kind"] = res[i].kind
		r := res[i]
		if r.dbid <= 0 || (r.hobt == 0 && r.object == 0 && r.kind != "page latch") {
			continue
		}
		if r.kind == "page latch" {
			if wt, _ := t["wait_type"].(string); !strings.HasPrefix(wt, "PAGELATCH_") || pages >= pageLatchCap {
				continue
			}
			pages++
		}
		w := byDB[r.dbid]
		if w == nil {
			w = &want{hobts: map[int64]bool{}, objects: map[int64]bool{}, pages: map[[2]int64]bool{}}
			byDB[r.dbid] = w
		}
		switch {
		case r.hobt != 0:
			w.hobts[r.hobt] = true
		case r.object != 0:
			w.objects[r.object] = true
		case r.kind == "page latch":
			w.pages[[2]int64{r.file, r.page}] = true
		}
	}
	if len(byDB) == 0 {
		return nil
	}
	var notes []string
	ids := map[int64]bool{}
	for db := range byDB {
		ids[db] = true
	}
	names := map[int64]string{}
	rows, err := QueryRows(ctx, conn, "SELECT database_id, name FROM sys.databases WHERE database_id IN ("+joinIDs(ids)+")")
	if err != nil {
		return []string{"database names not read: " + err.Error()}
	}
	for _, r := range rows {
		id, _ := asInt(r["database_id"])
		names[id], _ = r["name"].(string)
	}
	type key struct {
		db, a, b int64
	}
	hobtName := map[key][2]string{} // (db, hobt) -> object, index
	objName := map[key]string{}     // (db, object) -> object
	pageObj := map[key][2]int64{}   // (db, file, page) -> object id, index id
	idxName := map[key][2]string{}  // (db, object id, index id) -> object, index
	dbs := make([]int64, 0, len(byDB))
	for db := range byDB {
		dbs = append(dbs, db)
	}
	sort.Slice(dbs, func(i, j int) bool { return dbs[i] < dbs[j] })
	for _, db := range dbs {
		w, name := byDB[db], names[db]
		if name == "" {
			notes = append(notes, fmt.Sprintf("database %d: not in sys.databases", db))
			continue
		}
		q := bracket(name)
		if len(w.hobts) > 0 {
			rs, err := QueryRows(ctx, conn, `SELECT p.hobt_id, s.name AS schema_name, o.name AS object_name, i.name AS index_name, p.index_id
  FROM `+q+`.sys.partitions AS p
  JOIN `+q+`.sys.objects AS o ON o.object_id = p.object_id
  JOIN `+q+`.sys.schemas AS s ON s.schema_id = o.schema_id
  LEFT JOIN `+q+`.sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
 WHERE p.hobt_id IN (`+joinIDs(w.hobts)+`)`)
			if err != nil {
				notes = append(notes, "not decoded in "+name+": "+err.Error())
			} else if len(rs) < len(w.hobts) {
				notes = append(notes, fmt.Sprintf("%d of %d lock resources in %s not in its catalog to this login (VIEW DEFINITION there names them)", len(w.hobts)-len(rs), len(w.hobts), name))
			}
			for _, r := range rs {
				h, _ := asInt(r["hobt_id"])
				sn, _ := r["schema_name"].(string)
				on, _ := r["object_name"].(string)
				in, _ := r["index_name"].(string)
				if ix, _ := asInt(r["index_id"]); ix == 0 && in == "" {
					in = "(heap)"
				}
				hobtName[key{db, h, 0}] = [2]string{sn + "." + on, in}
			}
		}
		if len(w.objects) > 0 {
			rs, err := QueryRows(ctx, conn, `SELECT o.object_id, s.name AS schema_name, o.name AS object_name
  FROM `+q+`.sys.objects AS o JOIN `+q+`.sys.schemas AS s ON s.schema_id = o.schema_id
 WHERE o.object_id IN (`+joinIDs(w.objects)+`)`)
			if err != nil {
				notes = append(notes, "objects not decoded in "+name+": "+err.Error())
			} else if len(rs) < len(w.objects) {
				notes = append(notes, fmt.Sprintf("%d of %d locked objects in %s not in its catalog to this login (a temporary object, or no VIEW DEFINITION there)", len(w.objects)-len(rs), len(w.objects), name))
			}
			for _, r := range rs {
				o, _ := asInt(r["object_id"])
				sn, _ := r["schema_name"].(string)
				on, _ := r["object_name"].(string)
				objName[key{db, o, 0}] = sn + "." + on
			}
		}
		if len(w.pages) > 0 {
			if !pageInfoOK(info) {
				notes = append(notes, "page latches not decoded: sys.dm_db_page_info is SQL Server 2019 and later")
				continue
			}
			objs := map[[2]int64]bool{}
			for p := range w.pages {
				rs, err := QueryRows(ctx, conn, `SELECT object_id, index_id FROM sys.dm_db_page_info(@db, @file, @page, 'LIMITED')`,
					sql.Named("db", db), sql.Named("file", p[0]), sql.Named("page", p[1]))
				if err != nil {
					notes = append(notes, fmt.Sprintf("page %d:%d:%d not decoded: %v", db, p[0], p[1], err))
					continue
				}
				for _, r := range rs {
					o, _ := asInt(r["object_id"])
					ix, _ := asInt(r["index_id"])
					pageObj[key{db, p[0], p[1]}] = [2]int64{o, ix}
					objs[[2]int64{o, ix}] = true
				}
			}
			for oi := range objs {
				rs, err := QueryRows(ctx, conn, `SELECT s.name AS schema_name, o.name AS object_name, i.name AS index_name
  FROM `+q+`.sys.objects AS o JOIN `+q+`.sys.schemas AS s ON s.schema_id = o.schema_id
  LEFT JOIN `+q+`.sys.indexes AS i ON i.object_id = o.object_id AND i.index_id = @ix
 WHERE o.object_id = @obj`, sql.Named("obj", oi[0]), sql.Named("ix", oi[1]))
				if err != nil {
					notes = append(notes, "page objects not decoded in "+name+": "+err.Error())
					continue
				}
				for _, r := range rs {
					sn, _ := r["schema_name"].(string)
					on, _ := r["object_name"].(string)
					in, _ := r["index_name"].(string)
					if oi[1] == 0 && in == "" {
						in = "(heap)"
					}
					idxName[key{db, oi[0], oi[1]}] = [2]string{sn + "." + on, in}
				}
			}
		}
	}
	// database_name stays the request's database (PerformanceMonitor's column); the decoded object carries the
	// resource's own database: <database>.<schema>.<object>
	for i, t := range tasks {
		r := res[i]
		db := names[r.dbid]
		switch {
		case r.hobt != 0:
			if v, ok := hobtName[key{r.dbid, r.hobt, 0}]; ok {
				t["object_name"], t["index_name"] = db+"."+v[0], v[1]
			}
		case r.object != 0:
			if v, ok := objName[key{r.dbid, r.object, 0}]; ok {
				t["object_name"] = db + "." + v
			}
		case r.kind == "page latch":
			if oi, ok := pageObj[key{r.dbid, r.file, r.page}]; ok {
				if v, ok := idxName[key{r.dbid, oi[0], oi[1]}]; ok {
					t["object_name"], t["index_name"] = db+"."+v[0], v[1]
				}
			}
		}
	}
	return notes
}
