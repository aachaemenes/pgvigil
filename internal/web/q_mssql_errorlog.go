package web

import (
	"errors"
	"math"
	"net/http"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The SQL Server readers' pages (task 149): Error log, Default trace and System health of a SQL Server instance. They
// read only the tables of migration 0091 (and pgvigil.mssql_cursor for the instance's own search strings).
//
// GET /api/mssql/errorlog?instance=<id>&[from=&to=][&class=][&q=][&sev=][&part=] (Server.MSSQLErrorLog): the three
// readers' states, the readers' findings, the kept lines of the window newest first (class= one class, q= a text the
// line holds, sev= the lowest severity), the count per class, and the instance's own search strings.
// GET /api/mssql/defaulttrace?instance=<id>&[from=&to=][&part=] (Server.MSSQLDefaultTrace): file growths and shrinks
// per database and file kind and one by one, DBCC commands per command and one by one, DDL one by one.
// GET /api/mssql/syshealth?instance=<id>&[from=&to=][&part=] (Server.MSSQLSysHealth): the newest result of each
// component, the results that were not CLEAN, each component's figures over the window, and a series per bucket.

const sqlMSSQLReaderState = `
SELECT s.reader, s.state, s.state_since, s.snapshot_at, s.scope, s.scanned, s.stored, s.oldest_at, s.newest_at,
       s.search_count, s.search_only, s.note
  FROM pgvigil.mssql_reader_state s
 WHERE s.instance_id = $1
 ORDER BY CASE s.reader WHEN 'errorlog' THEN 0 WHEN 'defaulttrace' THEN 1 ELSE 2 END`

const sqlMSSQLReaderFindings = `
SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_readers_findings
 WHERE instance_id = $1
 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, at DESC`

const sqlMSSQLErrorLogLines = `
SELECT e.log_at, to_char(e.logged_local, 'YYYY-MM-DD HH24:MI:SS.MS') AS logged_local, e.severity, e.error_number, e.error_state, e.class, e.message, e.process, e.matched,
       e.custom, e.archive
  FROM pgvigil.mssql_errorlog e
 WHERE e.instance_id = $1 AND e.log_at > $2 AND e.log_at <= $3
   AND ($4::text IS NULL OR e.class = $4)
   AND ($5::text IS NULL OR strpos(lower(coalesce(e.message, '')), lower($5)) > 0 OR e.error_number::text = $5)
   AND ($6::int IS NULL OR e.severity >= $6)
 ORDER BY e.log_at DESC, e.line_key DESC
 LIMIT 1000`

const sqlMSSQLErrorLogClasses = `
SELECT e.class, count(*) AS lines, count(*) FILTER (WHERE e.severity >= 17) AS severe, count(*) FILTER (WHERE e.custom) AS own,
       max(e.log_at) AS last_at
  FROM pgvigil.mssql_errorlog e
 WHERE e.instance_id = $1 AND e.log_at > $2 AND e.log_at <= $3
 GROUP BY e.class
 ORDER BY count(*) DESC`

// the strings as the repository holds them (a JSON array of text); the page reads them
const sqlMSSQLErrorLogSearch = `
SELECT c.file_name AS strings, (c.file_offset = 1) AS only_these, c.updated_at
  FROM pgvigil.mssql_cursor c
 WHERE c.instance_id = $1 AND c.source = 'errorlog:search'`

const sqlMSSQLTraceGrowthSummary = `
SELECT t.database_name, t.kind, count(*) AS events, count(*) FILTER (WHERE t.duration_ms > 1000) AS slow,
       round(sum(t.duration_ms)) AS total_ms, round(max(t.duration_ms)) AS worst_ms, sum(t.size_change_mb) AS size_mb,
       max(t.event_at) AS last_at
  FROM pgvigil.mssql_trace_events t
 WHERE t.instance_id = $1 AND t.event_at > $2 AND t.event_at <= $3
   AND t.kind IN ('data growth', 'log growth', 'data shrink', 'log shrink')
 GROUP BY t.database_name, t.kind
 ORDER BY max(t.duration_ms) DESC NULLS LAST, count(*) DESC
 LIMIT 500`

const sqlMSSQLTraceGrowths = `
SELECT t.event_at, t.kind, t.database_name, t.file_name, round(t.duration_ms) AS duration_ms, t.size_change_mb,
       t.login_name, t.program_name, t.session_id
  FROM pgvigil.mssql_trace_events t
 WHERE t.instance_id = $1 AND t.event_at > $2 AND t.event_at <= $3
   AND t.kind IN ('data growth', 'log growth', 'data shrink', 'log shrink')
 ORDER BY t.event_at DESC, t.event_key DESC
 LIMIT 1000`

const sqlMSSQLTraceDBCCSummary = `
SELECT t.sub AS command, count(*) AS runs, min(t.event_at) AS first_at, max(t.event_at) AS last_at,
       string_agg(DISTINCT coalesce(t.login_name, '(login unknown)'), ', ') AS logins,
       string_agg(DISTINCT t.database_name, ', ') AS databases
  FROM pgvigil.mssql_trace_events t
 WHERE t.instance_id = $1 AND t.event_at > $2 AND t.event_at <= $3 AND t.kind = 'dbcc'
 GROUP BY t.sub
 ORDER BY max(t.event_at) DESC
 LIMIT 200`

const sqlMSSQLTraceDBCC = `
SELECT t.event_at, t.sub AS command, t.database_name, t.login_name, t.host_name, t.program_name, t.session_id, t.statement
  FROM pgvigil.mssql_trace_events t
 WHERE t.instance_id = $1 AND t.event_at > $2 AND t.event_at <= $3 AND t.kind = 'dbcc'
 ORDER BY t.event_at DESC, t.event_key DESC
 LIMIT 1000`

const sqlMSSQLTraceDDL = `
SELECT t.event_at, t.sub AS action, t.database_name, t.object_name, t.object_type, t.login_name, t.host_name, t.program_name,
       t.session_id
  FROM pgvigil.mssql_trace_events t
 WHERE t.instance_id = $1 AND t.event_at > $2 AND t.event_at <= $3 AND t.kind = 'ddl'
 ORDER BY t.event_at DESC, t.event_key DESC
 LIMIT 1000`

// healthComponents are the four component results; the table also holds the events read beside them (state EVENT,
// 0120), which have grids of their own
const healthComponents = `h.component IN ('SYSTEM', 'RESOURCE', 'QUERY_PROCESSING', 'IO_SUBSYSTEM')`

// the newest result of each component at the window's end, at most a day before it (the server writes one every
// five minutes)
const sqlMSSQLHealthLatest = `
SELECT DISTINCT ON (h.component) h.component, h.state, h.event_at, h.detail
  FROM pgvigil.mssql_health_components h
 WHERE h.instance_id = $1 AND h.event_at <= $2 AND h.event_at > $2::timestamptz - interval '1 day' AND ` + healthComponents + `
 ORDER BY h.component, h.event_at DESC`

const sqlMSSQLHealthIssues = `
SELECT h.event_at, h.component, h.state, h.detail->>'lastNotification' AS last_notification, h.detail
  FROM pgvigil.mssql_health_components h
 WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND h.state <> 'CLEAN' AND ` + healthComponents + `
 ORDER BY h.event_at DESC
 LIMIT 500`

const sqlMSSQLHealthSystem = `
SELECT h.event_at, h.state,
       pgvigil.mssql_health_num(h.detail, 'sqlCpuUtilization') AS sql_cpu, pgvigil.mssql_health_num(h.detail, 'systemCpuUtilization') AS system_cpu,
       pgvigil.mssql_health_num(h.detail, 'pageFaults') AS page_faults, pgvigil.mssql_health_num(h.detail, 'spinlockBackoffs') AS spinlock_backoffs,
       nullif(h.detail->>'sickSpinlockType', 'none') AS sick_spinlock, pgvigil.mssql_health_num(h.detail, 'latchWarnings') AS latch_warnings,
       pgvigil.mssql_health_num(h.detail, 'nonYieldingTasksReported') AS non_yielding,
       pgvigil.mssql_health_num(h.detail, 'isAccessViolationOccurred') AS access_violation,
       pgvigil.mssql_health_num(h.detail, 'writeAccessViolationCount') AS write_access_violations,
       pgvigil.mssql_health_num(h.detail, 'intervalDumpRequests') AS dump_requests,
       pgvigil.mssql_health_num(h.detail, 'BadPagesDetected') AS bad_pages_detected, pgvigil.mssql_health_num(h.detail, 'BadPagesFixed') AS bad_pages_fixed
  FROM pgvigil.mssql_health_components h
 WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND h.component = 'SYSTEM'
 ORDER BY h.event_at DESC
 LIMIT 500`

const sqlMSSQLHealthQP = `
SELECT h.event_at, h.state,
       pgvigil.mssql_health_num(h.detail, 'maxWorkers') AS max_workers, pgvigil.mssql_health_num(h.detail, 'workersCreated') AS workers_created,
       pgvigil.mssql_health_num(h.detail, 'workersIdle') AS workers_idle, pgvigil.mssql_health_num(h.detail, 'pendingTasks') AS pending_tasks,
       pgvigil.mssql_health_num(h.detail, 'oldestPendingTaskWaitingTime') AS oldest_pending_ms,
       pgvigil.mssql_health_num(h.detail, 'tasksCompletedWithinInterval') AS tasks_completed,
       pgvigil.mssql_health_num(h.detail, 'hasUnresolvableDeadlockOccurred') AS unresolvable_deadlock,
       pgvigil.mssql_health_num(h.detail, 'hasDeadlockedSchedulersOccurred') AS deadlocked_schedulers
  FROM pgvigil.mssql_health_components h
 WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND h.component = 'QUERY_PROCESSING'
 ORDER BY h.event_at DESC
 LIMIT 500`

// the IO results that saw a long IO or a latch timeout, or were not CLEAN
const sqlMSSQLHealthIO = `
SELECT h.event_at, h.state, pgvigil.mssql_health_num(h.detail, 'ioLatchTimeouts') AS io_latch_timeouts,
       pgvigil.mssql_health_num(h.detail, 'intervalLongIos') AS interval_long_ios, pgvigil.mssql_health_num(h.detail, 'totalLongIos') AS total_long_ios,
       h.detail->'longest' AS longest
  FROM pgvigil.mssql_health_components h
 WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND h.component = 'IO_SUBSYSTEM'
   AND (h.state <> 'CLEAN' OR pgvigil.mssql_health_num(h.detail, 'intervalLongIos') > 0 OR pgvigil.mssql_health_num(h.detail, 'ioLatchTimeouts') > 0)
 ORDER BY h.event_at DESC
 LIMIT 500`

// memory figures: the report gives bytes for the process and system counts and KB for the memory manager
const sqlMSSQLHealthResource = `
SELECT h.event_at, h.state, h.detail->>'lastNotification' AS last_notification,
       pgvigil.mssql_health_num(h.detail, 'outOfMemoryExceptions') AS oom_exceptions,
       pgvigil.mssql_health_num(h.detail, 'isAnyPoolOutOfMemory') AS pool_out_of_memory,
       pgvigil.mssql_health_num(h.detail, 'processOutOfMemoryPeriod') AS oom_period,
       round(pgvigil.mssql_health_num(h.detail->'memory', 'Available Physical Memory') / 1048576) AS available_physical_mb,
       round(pgvigil.mssql_health_num(h.detail->'memory', 'Available Virtual Memory') / 1048576) AS available_virtual_mb,
       round(pgvigil.mssql_health_num(h.detail->'memory', 'Available Paging File') / 1048576) AS available_paging_mb,
       round(pgvigil.mssql_health_num(h.detail->'memory', 'Working Set') / 1048576) AS working_set_mb,
       pgvigil.mssql_health_num(h.detail->'memory', 'Percent of Committed Memory in WS') AS pct_committed_in_ws,
       pgvigil.mssql_health_num(h.detail->'memory', 'Page Faults') AS page_faults,
       pgvigil.mssql_health_num(h.detail->'memory', 'System physical memory high') AS system_memory_high,
       pgvigil.mssql_health_num(h.detail->'memory', 'System physical memory low') AS system_memory_low,
       pgvigil.mssql_health_num(h.detail->'memory', 'Process physical memory low') AS process_memory_low,
       pgvigil.mssql_health_num(h.detail->'memory', 'Process virtual memory low') AS process_virtual_low,
       round(pgvigil.mssql_health_num(h.detail->'memory', 'Target Committed') / 1024) AS target_committed_mb,
       round(pgvigil.mssql_health_num(h.detail->'memory', 'Current Committed') / 1024) AS current_committed_mb
  FROM pgvigil.mssql_health_components h
 WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND h.component = 'RESOURCE'
 ORDER BY h.event_at DESC
 LIMIT 500`

// per bucket of $4 seconds, every bucket of the window: the results stored, those not CLEAN (no value where the bucket
// holds none: a read that stored nothing is not a clean one), the most pending tasks, the long IOs, SQL Server's and
// the machine's CPU, and the SYSTEM component's counters as PerformanceMonitor's Corruption and Contention Events
// charts draw them: each the largest value in its bucket, none where no SYSTEM result carried it
const sqlMSSQLHealthSeries = `
WITH b AS (
  SELECT to_timestamp(g * $4::bigint) AS snapshot_at
    FROM generate_series(floor(extract(epoch FROM $2::timestamptz) / $4)::bigint, floor(extract(epoch FROM $3::timestamptz) / $4)::bigint) g
), h AS (
  SELECT to_timestamp(floor(extract(epoch FROM h.event_at) / $4)::bigint * $4::bigint) AS snapshot_at,
         count(*) AS results, count(*) FILTER (WHERE h.state <> 'CLEAN') AS not_clean,
         max(pgvigil.mssql_health_num(h.detail, 'pendingTasks')) FILTER (WHERE h.component = 'QUERY_PROCESSING') AS pending_tasks,
         sum(pgvigil.mssql_health_num(h.detail, 'intervalLongIos')) FILTER (WHERE h.component = 'IO_SUBSYSTEM') AS long_ios,
         max(pgvigil.mssql_health_num(h.detail, 'sqlCpuUtilization')) FILTER (WHERE h.component = 'SYSTEM') AS sql_cpu,
         max(pgvigil.mssql_health_num(h.detail, 'systemCpuUtilization')) FILTER (WHERE h.component = 'SYSTEM') AS system_cpu,
         max(pgvigil.mssql_health_num(h.detail, 'BadPagesDetected')) FILTER (WHERE h.component = 'SYSTEM') AS bad_pages,
         max(pgvigil.mssql_health_num(h.detail, 'intervalDumpRequests')) FILTER (WHERE h.component = 'SYSTEM') AS dump_requests,
         max(pgvigil.mssql_health_num(h.detail, 'isAccessViolationOccurred')) FILTER (WHERE h.component = 'SYSTEM') AS access_violations,
         max(pgvigil.mssql_health_num(h.detail, 'writeAccessViolationCount')) FILTER (WHERE h.component = 'SYSTEM') AS write_access_violations,
         max(pgvigil.mssql_health_num(h.detail, 'nonYieldingTasksReported')) FILTER (WHERE h.component = 'SYSTEM') AS non_yielding,
         max(pgvigil.mssql_health_num(h.detail, 'latchWarnings')) FILTER (WHERE h.component = 'SYSTEM') AS latch_warnings
    FROM pgvigil.mssql_health_components h
   WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND ` + healthComponents + `
   GROUP BY 1
)
SELECT b.snapshot_at, coalesce(h.results, 0) AS results, h.not_clean, h.pending_tasks, h.long_ios, h.sql_cpu, h.system_cpu,
       h.bad_pages, h.dump_requests, h.access_violations, h.write_access_violations, h.non_yielding, h.latch_warnings
  FROM b LEFT JOIN h USING (snapshot_at)
 ORDER BY b.snapshot_at`

// a line per sick spinlock type (PerformanceMonitor's Contention Events: Sick Spinlocks): per bucket of $4 seconds,
// the type's largest backoff count among the SYSTEM results that named it
const sqlMSSQLHealthSpinlocks = `
SELECT to_timestamp(floor(extract(epoch FROM h.event_at) / $4)::bigint * $4::bigint) AS snapshot_at,
       h.detail->>'sickSpinlockType' AS spinlock_type, max(pgvigil.mssql_health_num(h.detail, 'spinlockBackoffs')) AS backoffs
  FROM pgvigil.mssql_health_components h
 WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND h.component = 'SYSTEM'
   AND coalesce(h.detail->>'sickSpinlockType', 'none') NOT IN ('none', '')
 GROUP BY 1, 2
 ORDER BY 1, 2`

// the memory broker's notifications (sp_HealthParser's 'memory broker notifications'), newest first
const sqlMSSQLHealthBroker = `
SELECT h.event_at, pgvigil.mssql_health_num(h.detail, 'broker_id') AS broker_id, h.detail->>'broker' AS broker,
       h.detail->>'notification' AS notification, pgvigil.mssql_health_num(h.detail, 'pool_metadata_id') AS pool_metadata_id,
       pgvigil.mssql_health_num(h.detail, 'delta_time') AS delta_time, pgvigil.mssql_health_num(h.detail, 'memory_ratio') AS memory_ratio,
       pgvigil.mssql_health_num(h.detail, 'new_target') AS new_target, pgvigil.mssql_health_num(h.detail, 'overall') AS overall,
       pgvigil.mssql_health_num(h.detail, 'rate') AS rate, pgvigil.mssql_health_num(h.detail, 'currently_predicated') AS currently_predicated,
       pgvigil.mssql_health_num(h.detail, 'currently_allocated') AS currently_allocated,
       pgvigil.mssql_health_num(h.detail, 'previously_allocated') AS previously_allocated
  FROM pgvigil.mssql_health_components h
 WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND h.component = 'MEMORY_BROKER'
 ORDER BY h.event_at DESC, h.event_key
 LIMIT 500`

// a memory node's out-of-memory records (sp_HealthParser's 'memory node OOM events'), newest first
const sqlMSSQLHealthNodeOOM = `
SELECT h.event_at, pgvigil.mssql_health_num(h.detail, 'node_id') AS node_id, pgvigil.mssql_health_num(h.detail, 'memory_node_id') AS memory_node_id,
       pgvigil.mssql_health_num(h.detail, 'memory_utilization_pct') AS memory_utilization_pct,
       pgvigil.mssql_health_num(h.detail, 'total_physical_memory_kb') AS total_physical_memory_kb,
       pgvigil.mssql_health_num(h.detail, 'available_physical_memory_kb') AS available_physical_memory_kb,
       pgvigil.mssql_health_num(h.detail, 'total_page_file_kb') AS total_page_file_kb,
       pgvigil.mssql_health_num(h.detail, 'available_page_file_kb') AS available_page_file_kb,
       pgvigil.mssql_health_num(h.detail, 'total_virtual_address_space_kb') AS total_virtual_address_space_kb,
       pgvigil.mssql_health_num(h.detail, 'available_virtual_address_space_kb') AS available_virtual_address_space_kb,
       pgvigil.mssql_health_num(h.detail, 'target_kb') AS target_kb, pgvigil.mssql_health_num(h.detail, 'reserved_kb') AS reserved_kb,
       pgvigil.mssql_health_num(h.detail, 'committed_kb') AS committed_kb, pgvigil.mssql_health_num(h.detail, 'shared_committed_kb') AS shared_committed_kb,
       pgvigil.mssql_health_num(h.detail, 'awe_kb') AS awe_kb, pgvigil.mssql_health_num(h.detail, 'pages_kb') AS pages_kb,
       h.detail->>'failure_type' AS failure_type, pgvigil.mssql_health_num(h.detail, 'failure_value') AS failure_value,
       h.detail->>'resources' AS resources, h.detail->>'factor_text' AS factor_text, pgvigil.mssql_health_num(h.detail, 'factor_value') AS factor_value,
       h.detail->>'last_error' AS last_error, pgvigil.mssql_health_num(h.detail, 'pool_metadata_id') AS pool_metadata_id,
       h.detail->>'is_process_in_job' AS is_process_in_job, h.detail->>'is_system_physical_memory_high' AS is_system_physical_memory_high,
       h.detail->>'is_system_physical_memory_low' AS is_system_physical_memory_low,
       h.detail->>'is_process_physical_memory_low' AS is_process_physical_memory_low,
       h.detail->>'is_process_virtual_memory_low' AS is_process_virtual_memory_low
  FROM pgvigil.mssql_health_components h
 WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND h.component = 'MEMORY_NODE_OOM'
 ORDER BY h.event_at DESC, h.event_key
 LIMIT 500`

// the scheduler monitor's samples that cross one of sp_HealthParser's warnings (SQL Server's CPU 90 % or more, other
// processes 50 % or more, memory utilization 50 or less), newest first; other = 100 - SQL Server - idle
const sqlMSSQLHealthScheduler = `
SELECT x.* FROM (
  SELECT h.event_at, pgvigil.mssql_health_num(h.detail, 'process_utilization') AS sql_cpu,
         100 - pgvigil.mssql_health_num(h.detail, 'process_utilization') - pgvigil.mssql_health_num(h.detail, 'system_idle') AS other_cpu,
         pgvigil.mssql_health_num(h.detail, 'system_idle') AS system_idle,
         pgvigil.mssql_health_num(h.detail, 'memory_utilization') AS memory_utilization,
         pgvigil.mssql_health_num(h.detail, 'page_faults') AS page_faults,
         round(pgvigil.mssql_health_num(h.detail, 'working_set_delta') / 1048576, 2) AS working_set_delta_mb
    FROM pgvigil.mssql_health_components h
   WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND h.component = 'SCHEDULER_MONITOR') x
 WHERE x.sql_cpu >= 90 OR x.other_cpu >= 50 OR x.memory_utilization <= 50
 ORDER BY x.event_at DESC
 LIMIT 500`

// how many scheduler monitor samples the window holds at all: the page tells 'none stored' from 'none crossed a warning'
const sqlMSSQLHealthSchedulerSamples = `
SELECT count(*) AS samples
  FROM pgvigil.mssql_health_components h
 WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND h.component = 'SCHEDULER_MONITOR'`

// sp_HealthParser's 'queries with significant waits': a wait_info event of a real session (not 0) with a statement that
// is not a BACKUP, waiting 500 ms or more on a wait type not on its ignorable list; newest first
const sqlMSSQLHealthWaits = `
SELECT h.event_at, h.detail->>'wait_type' AS wait_type, pgvigil.mssql_health_num(h.detail, 'duration_ms') AS duration_ms,
       pgvigil.mssql_health_num(h.detail, 'signal_duration_ms') AS signal_duration_ms, h.detail->>'wait_resource' AS wait_resource,
       pgvigil.mssql_health_num(h.detail, 'session_id') AS session_id, h.detail->>'statement' AS statement
  FROM pgvigil.mssql_health_components h
 WHERE h.instance_id = $1 AND h.event_at > $2 AND h.event_at <= $3 AND h.component = 'WAIT_INFO'
   AND coalesce(pgvigil.mssql_health_num(h.detail, 'session_id'), 0) <> 0 AND (h.detail->>'has_sql_text')::boolean
   AND NOT coalesce((h.detail->>'is_backup')::boolean, false) AND pgvigil.mssql_health_num(h.detail, 'duration_ms') >= 500
   AND NOT pgvigil.mssql_wait_ignorable(h.detail->>'wait_type')
 ORDER BY h.event_at DESC, h.event_key
 LIMIT 500`

// the system events' findings of the instance (0120) this tab owns: system_health's (the cut ring buffer is a capture's)
const sqlMSSQLSysEventFindings = `
SELECT f.severity, f.check_name, f.object, f.at, f.detail
  FROM pgvigil.mssql_sysevents_findings f
 WHERE f.instance_id = $1 AND f.check_name LIKE 'system_health:%'
 ORDER BY f.at DESC`

// errorLogClasses are the classes a line is filed under (errorlog.go's errorLogClassOrder).
var errorLogClasses = map[string]bool{"corruption": true, "memory": true, "io": true, "scheduler": true, "availability": true,
	"startup": true, "config": true, "general": true}

// MSSQLErrorLog serves the Error log tab of one SQL Server instance (?part= one of its parts).
func (s *Server) MSSQLErrorLog(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	var class, text, sev any
	if v := q.Get("class"); v != "" {
		if !errorLogClasses[v] {
			writeErr(w, http.StatusBadRequest, errors.New("class must be one of corruption, memory, io, scheduler, availability, startup, config, general"))
			return
		}
		class = v
	}
	if v := strings.TrimSpace(q.Get("q")); v != "" {
		if utf8.RuneCountInString(v) > 200 {
			writeErr(w, http.StatusBadRequest, errors.New("q is 200 characters at most"))
			return
		}
		if !utf8.ValidString(v) || strings.IndexFunc(v, func(c rune) bool { return c < 0x20 || c == 0x7f }) >= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("q must be text without control characters"))
			return
		}
		text = v
	}
	if v := q.Get("sev"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 || n > 25 {
			writeErr(w, http.StatusBadRequest, errors.New("sev must be a severity from 0 to 25"))
			return
		}
		sev = n
	}
	s.multiPart(w, r, []part{
		{"state", sqlMSSQLReaderState, []any{id}},
		{"findings", sqlMSSQLReaderFindings, []any{id}},
		{"lines", sqlMSSQLErrorLogLines, []any{id, from, to, class, text, sev}},
		{"classes", sqlMSSQLErrorLogClasses, []any{id, from, to}},
		{"search", sqlMSSQLErrorLogSearch, []any{id}},
	})
}

// MSSQLDefaultTrace serves the Default trace tab of one SQL Server instance.
func (s *Server) MSSQLDefaultTrace(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"state", sqlMSSQLReaderState, []any{id}},
		{"findings", sqlMSSQLReaderFindings, []any{id}},
		{"growth_summary", sqlMSSQLTraceGrowthSummary, []any{id, from, to}},
		{"growths", sqlMSSQLTraceGrowths, []any{id, from, to}},
		{"dbcc_summary", sqlMSSQLTraceDBCCSummary, []any{id, from, to}},
		{"dbcc", sqlMSSQLTraceDBCC, []any{id, from, to}},
		{"ddl", sqlMSSQLTraceDDL, []any{id, from, to}},
	})
}

// MSSQLSysHealth serves the System health tab of one SQL Server instance.
func (s *Server) MSSQLSysHealth(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// about 120 points over any window, never finer than the five minutes between two results
	step := int(math.Ceil(to.Sub(from).Seconds() / 120))
	if step < 300 {
		step = 300
	}
	s.multiPart(w, r, []part{
		{"state", sqlMSSQLReaderState, []any{id}},
		{"findings", sqlMSSQLReaderFindings, []any{id}},
		{"latest", sqlMSSQLHealthLatest, []any{id, to}},
		{"issues", sqlMSSQLHealthIssues, []any{id, from, to}},
		{"system", sqlMSSQLHealthSystem, []any{id, from, to}},
		{"query_processing", sqlMSSQLHealthQP, []any{id, from, to}},
		{"io", sqlMSSQLHealthIO, []any{id, from, to}},
		{"resource", sqlMSSQLHealthResource, []any{id, from, to}},
		{"series", sqlMSSQLHealthSeries, []any{id, from, to, step}},
		{"spinlocks", sqlMSSQLHealthSpinlocks, []any{id, from, to, step}},
		{"broker", sqlMSSQLHealthBroker, []any{id, from, to}},
		{"node_oom", sqlMSSQLHealthNodeOOM, []any{id, from, to}},
		{"scheduler", sqlMSSQLHealthScheduler, []any{id, from, to}},
		{"scheduler_samples", sqlMSSQLHealthSchedulerSamples, []any{id, from, to}},
		{"waits", sqlMSSQLHealthWaits, []any{id, from, to}},
		{"event_findings", sqlMSSQLSysEventFindings, []any{id}},
	})
}
