package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// requestsCollector is mssql_requests: what runs on the server now, every minute. One row per session that runs a
// request, holds an open transaction or blocks another, with the blocking chain of the snapshot built by one rule:
// the head is the session that blocks and does not itself wait behind a session; the root cause of a chain is the
// head's transaction and its last statement, never the object its victims wait on.
//
// Two sources fill the same rows. The default is a read of the DMVs: nothing has to exist on the server. Where a
// DBA has installed sp_WhoIsActive in master, or in the database the instance's connection string names, and the
// login may execute it, the procedure is CALLED into a session temp table of the schema it documents itself
// (@return_schema) and its rows are completed from the DMVs by session and request id. The summary row says which
// ran. Nothing of sp_WhoIsActive is copied here: only its documented parameters are used.
type requestsCollector struct{}

func init() { Register(requestsCollector{}) }

func (requestsCollector) Name() string                   { return Prefix + "requests" }
func (requestsCollector) DefaultInterval() time.Duration { return time.Minute }
func (requestsCollector) Applies(in Info) (bool, string) {
	if !in.ViewServerState {
		return false, "the login lacks VIEW SERVER STATE: the sessions and requests of other logins cannot be read"
	}
	return true, ""
}

// statementCap is the longest statement text one row carries, in characters; full_chars keeps the real length.
const statementCap = 16000

// requestsPreSQL: the server's clock, the memory grants pending, and where sp_WhoIsActive can be called.
// SQL Server 2016 SP1 and later, Azure SQL Managed Instance, Amazon RDS.
const requestsPreSQL = `SELECT
  TODATETIMEOFFSET(SYSUTCDATETIME(), 0) AS server_utc,
  (SELECT COUNT(*) FROM sys.dm_exec_query_memory_grants WHERE grant_time IS NULL) AS memory_grants_pending,
  CAST(CASE
    WHEN OBJECT_ID(N'master.dbo.sp_WhoIsActive', 'P') IS NOT NULL
     AND HAS_PERMS_BY_NAME(N'master.dbo.sp_WhoIsActive', 'OBJECT', 'EXECUTE') = 1 THEN N'master'
    WHEN OBJECT_ID(QUOTENAME(DB_NAME()) + N'.dbo.sp_WhoIsActive', 'P') IS NOT NULL
     AND HAS_PERMS_BY_NAME(QUOTENAME(DB_NAME()) + N'.dbo.sp_WhoIsActive', 'OBJECT', 'EXECUTE') = 1 THEN DB_NAME()
  END AS nvarchar(128)) AS wia_db,
  CAST(CASE WHEN OBJECT_ID(N'master.dbo.sp_WhoIsActive', 'P') IS NOT NULL
              OR OBJECT_ID(QUOTENAME(DB_NAME()) + N'.dbo.sp_WhoIsActive', 'P') IS NOT NULL THEN 1 ELSE 0 END AS int) AS wia_seen`

// requestsPreAzureDBSQL: the same on Azure SQL Database, where a name in master cannot be referenced from a user
// database: sp_WhoIsActive is looked for in the connection's own database only.
const requestsPreAzureDBSQL = `SELECT
  TODATETIMEOFFSET(SYSUTCDATETIME(), 0) AS server_utc,
  (SELECT COUNT(*) FROM sys.dm_exec_query_memory_grants WHERE grant_time IS NULL) AS memory_grants_pending,
  CAST(CASE WHEN OBJECT_ID(N'dbo.sp_WhoIsActive', 'P') IS NOT NULL
             AND HAS_PERMS_BY_NAME(N'dbo.sp_WhoIsActive', 'OBJECT', 'EXECUTE') = 1 THEN DB_NAME() END AS nvarchar(128)) AS wia_db,
  CAST(CASE WHEN OBJECT_ID(N'dbo.sp_WhoIsActive', 'P') IS NOT NULL THEN 1 ELSE 0 END AS int) AS wia_seen`

// requestsTemplate is the snapshot's SELECT; {{name}} tokens are filled per source (requestsDMV, requestsWIA) and
// per kind of server. Read only. SQL Server 2016 SP1 and later (sys.dm_exec_input_buffer, dm_exec_requests.dop and
// sys.dm_exec_session_wait_stats all exist there), Azure SQL Managed Instance, Amazon RDS; Azure SQL Database with
// the database filter and without sys.sysprocesses.
//
// The shape - one row per user session that runs a request or holds an open transaction, the session's oldest
// transaction, the tempdb pages of the request's tasks, the session's largest waits pivoted to three columns - is
// ported from DBA Dash 4.24.1, DBADash/SQL/SQLRunningQueries.sql (MIT, Copyright 2022 Trimble, Inc.). Added here:
// a session that blocks another is kept whatever it is, the statement is cut from the batch on the server, the
// input buffer of a session without a request, the transaction id and its log bytes, the task count and the CPU
// and IO summed over a parallel request's tasks (sys.dm_exec_requests carries the coordinator's alone).
//
// Sessions join requests on session_id and tasks on session_id and request_id, never on a time. Every instant is
// moved to UTC on the server by its own offset at the read.
const requestsTemplate = `/* pgvigil mssql_requests: read only. Shape ported from DBA Dash 4.24.1, DBADash/SQL/SQLRunningQueries.sql (MIT, Copyright 2022 Trimble, Inc.) */
/* the server's offset from UTC in minutes, from one read of its clock */
DECLARE @off int = -DATEPART(TZOFFSET, SYSDATETIMEOFFSET());
SELECT
  'request' AS kind,
  CAST(s.session_id AS int) AS session_id,
  CAST(r.request_id AS int) AS request_id,
  CAST({{status}} AS nvarchar(30)) AS status,
  CAST(r.command AS nvarchar(32)) AS command,
  CAST(r.wait_type AS nvarchar(60)) AS wait_type,
  CAST(r.wait_time AS bigint) AS wait_ms,
  CAST(NULLIF(r.wait_resource, N'') AS nvarchar(256)) AS wait_resource,
  CAST({{blocking}} AS int) AS blocking_session_id,
  CAST({{open_tran}} AS int) AS open_tran,
  CAST(ISNULL(NULLIF(r.transaction_id, 0), t.transaction_id) AS bigint) AS transaction_id,
  TODATETIMEOFFSET(DATEADD(minute, @off, {{tran_begin}}), 0) AS tran_start,
  CAST(t.log_bytes AS bigint) AS tran_log_bytes,
  CAST(t.is_implicit AS int) AS is_implicit_tran,
  CAST(CASE ISNULL(r.transaction_isolation_level, s.transaction_isolation_level)
         WHEN 0 THEN 'unspecified' WHEN 1 THEN 'read uncommitted' WHEN 2 THEN 'read committed'
         WHEN 3 THEN 'repeatable read' WHEN 4 THEN 'serializable' WHEN 5 THEN 'snapshot' END AS varchar(20)) AS isolation_level,
  CAST({{cpu}} AS bigint) AS cpu_ms,
  CAST({{reads}} AS bigint) AS reads,
  CAST({{writes}} AS bigint) AS writes,
  CAST({{logical_reads}} AS bigint) AS logical_reads,
  CAST(r.granted_query_memory AS bigint) * 8 AS granted_memory_kb,
  CAST({{tempdb_alloc}} AS bigint) * 8 AS tempdb_alloc_kb,
  CAST({{tempdb_current}} AS bigint) * 8 AS tempdb_current_kb,
  CAST(r.dop AS int) AS dop,
  CAST(tk.task_count AS int) AS task_count,
  {{tasks_cols}}
  CAST({{percent}} AS real) AS percent_complete,
  CAST(r.total_elapsed_time AS bigint) AS elapsed_ms,
  TODATETIMEOFFSET(DATEADD(minute, @off, r.start_time), 0) AS start_time,
  TODATETIMEOFFSET(DATEADD(minute, @off, s.last_request_start_time), 0) AS last_request_start,
  TODATETIMEOFFSET(DATEADD(minute, @off, s.last_request_end_time), 0) AS last_request_end,
  TODATETIMEOFFSET(DATEADD(minute, @off, s.login_time), 0) AS login_time,
  CAST(s.login_name AS nvarchar(128)) AS login_name,
  CAST(s.host_name AS nvarchar(128)) AS host_name,
  CAST(s.program_name AS nvarchar(128)) AS program_name,
  CAST(DB_NAME(ISNULL(r.database_id, s.database_id)) AS nvarchar(128)) AS database_name,
  ISNULL(r.sql_handle, c.most_recent_sql_handle) AS sql_handle,
  CAST(CASE WHEN r.sql_handle IS NOT NULL THEN r.statement_start_offset ELSE -1 END AS int) AS stmt_start,
  CAST(CASE WHEN r.sql_handle IS NOT NULL THEN r.statement_end_offset ELSE -1 END AS int) AS stmt_end,
  r.plan_handle AS plan_handle,
  NULLIF(r.query_hash, 0x0000000000000000) AS stmt_query_hash,
  NULLIF(r.query_plan_hash, 0x0000000000000000) AS stmt_plan_hash,
  CAST(LEFT({{statement}}, {{cap}}) AS nvarchar(max)) AS statement,
  CAST(LEN({{statement}}) AS int) AS full_chars,
  CAST(sw.w1 AS nvarchar(60)) AS sw1, sw.ms1 AS sw1_ms, sw.n1 AS sw1_tasks,
  CAST(sw.w2 AS nvarchar(60)) AS sw2, sw.ms2 AS sw2_ms, sw.n2 AS sw2_tasks,
  CAST(sw.w3 AS nvarchar(60)) AS sw3, sw.ms3 AS sw3_ms, sw.n3 AS sw3_tasks,
  CAST(s.is_user_process AS int) AS is_user_process
FROM {{base}}
LEFT JOIN sys.dm_exec_connections c ON c.session_id = s.session_id AND c.parent_connection_id IS NULL
LEFT JOIN (
    /* one row per session, whether or not a request runs. A session holds one transaction unless it uses MARS;
       with several, the start is the oldest one's, the id the lowest and the log bytes their sum */
    SELECT st.session_id, MIN(st.transaction_id) AS transaction_id, MIN(tat.transaction_begin_time) AS tran_begin,
           MAX(CASE WHEN tat.name = 'implicit_transaction' THEN 1 ELSE 0 END) AS is_implicit,
           SUM(CAST(dt.log_bytes AS bigint)) AS log_bytes
    FROM sys.dm_tran_session_transactions st
    JOIN sys.dm_tran_active_transactions tat ON tat.transaction_id = st.transaction_id
    LEFT JOIN (SELECT d.transaction_id, SUM(d.database_transaction_log_bytes_used) AS log_bytes
               FROM sys.dm_tran_database_transactions d
               GROUP BY d.transaction_id) dt ON dt.transaction_id = st.transaction_id
    GROUP BY st.session_id
  ) t ON t.session_id = s.session_id
LEFT JOIN (
    SELECT tsu.session_id, tsu.request_id,
           SUM(CAST(tsu.user_objects_alloc_page_count AS bigint) + tsu.internal_objects_alloc_page_count) AS alloc_pages,
           SUM(CAST(tsu.user_objects_dealloc_page_count AS bigint) + tsu.internal_objects_dealloc_page_count) AS dealloc_pages
    FROM sys.dm_db_task_space_usage tsu
    GROUP BY tsu.session_id, tsu.request_id
  ) tsu ON tsu.session_id = r.session_id AND tsu.request_id = r.request_id
LEFT JOIN (
    SELECT ot.session_id, ot.request_id, COUNT(*) AS task_count
    FROM sys.dm_os_tasks ot
    WHERE ot.session_id IS NOT NULL
    GROUP BY ot.session_id, ot.request_id
  ) tk ON tk.session_id = r.session_id AND tk.request_id = r.request_id
{{tasks_join}}
LEFT JOIN (
    /* the session's own three largest waits since it logged in (or its pooled connection was reset) */
    SELECT x.session_id,
           MAX(CASE WHEN x.rn = 1 THEN x.wait_type END) AS w1, MAX(CASE WHEN x.rn = 1 THEN x.wait_time_ms END) AS ms1, MAX(CASE WHEN x.rn = 1 THEN x.waiting_tasks_count END) AS n1,
           MAX(CASE WHEN x.rn = 2 THEN x.wait_type END) AS w2, MAX(CASE WHEN x.rn = 2 THEN x.wait_time_ms END) AS ms2, MAX(CASE WHEN x.rn = 2 THEN x.waiting_tasks_count END) AS n2,
           MAX(CASE WHEN x.rn = 3 THEN x.wait_type END) AS w3, MAX(CASE WHEN x.rn = 3 THEN x.wait_time_ms END) AS ms3, MAX(CASE WHEN x.rn = 3 THEN x.waiting_tasks_count END) AS n3
    FROM (SELECT ws.session_id, ws.wait_type, ws.wait_time_ms, ws.waiting_tasks_count,
                 ROW_NUMBER() OVER (PARTITION BY ws.session_id ORDER BY ws.wait_time_ms DESC, ws.wait_type) AS rn
          FROM sys.dm_exec_session_wait_stats ws
          WHERE ws.wait_time_ms > 0) x
    WHERE x.rn <= 3
    GROUP BY x.session_id
  ) sw ON sw.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) qt
OUTER APPLY (SELECT ISNULL(r.statement_start_offset, 0) AS b,
                    CASE WHEN r.statement_end_offset IS NULL OR r.statement_end_offset = -1 THEN DATALENGTH(qt.text)
                         ELSE r.statement_end_offset END AS e) o
OUTER APPLY (SELECT CASE WHEN o.e >= o.b THEN SUBSTRING(qt.text, o.b / 2 + 1, (o.e - o.b) / 2 + 1) END AS txt) cut
OUTER APPLY (SELECT x.event_info FROM sys.dm_exec_input_buffer(s.session_id, NULL) x WHERE r.sql_handle IS NULL) ib
WHERE {{where}}
OPTION (MAXDOP 1);`

// requestsDMV fills the template for the DMV read: a user session with a request or an open transaction, and any
// session at all that another request names as its blocker (a sleeping session without a transaction still holds
// its database lock; a system session can head a chain). The collector's own session is left out.
var requestsDMV = map[string]string{
	"base":           "sys.dm_exec_sessions s\nLEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id",
	"status":         "ISNULL(r.status, s.status)",
	"blocking":       "ISNULL(r.blocking_session_id, 0)",
	"open_tran":      "s.open_transaction_count",
	"tran_begin":     "t.tran_begin",
	"cpu":            "ISNULL(r.cpu_time, s.cpu_time)",
	"reads":          "ISNULL(r.reads, s.reads)",
	"writes":         "ISNULL(r.writes, s.writes)",
	"logical_reads":  "ISNULL(r.logical_reads, s.logical_reads)",
	"tempdb_alloc":   "tsu.alloc_pages",
	"tempdb_current": "tsu.alloc_pages - tsu.dealloc_pages",
	"percent":        "r.percent_complete",
	"statement":      "CASE WHEN r.sql_handle IS NOT NULL THEN cut.txt ELSE ib.event_info END",
	"where": `s.session_id <> @@SPID
  AND ((s.is_user_process = 1 AND (r.session_id IS NOT NULL OR s.open_transaction_count > 0))
       OR s.session_id IN (SELECT b.blocking_session_id FROM sys.dm_exec_requests b WHERE b.blocking_session_id > 0)){{dbfilter}}`,
}

// requestsWIA fills the template for sp_WhoIsActive's rows (the temp table #pgvigil_wia of its own schema): the
// procedure decides which sessions are listed and gives the statement, the blocker, the transaction's start and
// the counters it sums itself; what it does not return (the handles, the hashes, the wait resource, the isolation
// level, the granted memory) and what it can leave NULL (percent_complete) comes from the DMVs by session and
// request id. Its reads column is logical reads, physical_reads the physical ones.
var requestsWIA = map[string]string{
	"base": "#pgvigil_wia w\nJOIN sys.dm_exec_sessions s ON s.session_id = w.session_id\n" +
		"LEFT JOIN sys.dm_exec_requests r ON r.session_id = w.session_id AND r.request_id = w.request_id",
	"status":         "w.status",
	"blocking":       "ISNULL(w.blocking_session_id, 0)",
	"open_tran":      "ISNULL(w.open_tran_count, s.open_transaction_count)",
	"tran_begin":     "ISNULL(w.tran_start_time, t.tran_begin)",
	"cpu":            "ISNULL(w.CPU, ISNULL(r.cpu_time, s.cpu_time))",
	"reads":          "ISNULL(w.physical_reads, ISNULL(r.reads, s.reads))",
	"writes":         "ISNULL(w.writes, ISNULL(r.writes, s.writes))",
	"logical_reads":  "ISNULL(w.reads, ISNULL(r.logical_reads, s.logical_reads))",
	"tempdb_alloc":   "ISNULL(w.tempdb_allocations, tsu.alloc_pages)",
	"tempdb_current": "ISNULL(w.tempdb_current, tsu.alloc_pages - tsu.dealloc_pages)",
	"percent":        "ISNULL(w.percent_complete, r.percent_complete)",
	"statement":      "ISNULL(w.sql_text, CASE WHEN r.sql_handle IS NOT NULL THEN cut.txt ELSE ib.event_info END)",
	"where":          "1 = 1",
}

// tasksCols and tasksJoin add the CPU and the physical IO summed over a request's tasks. sys.sysprocesses is the
// one place that lists them per task (one row per execution context); Azure SQL Database does not offer it.
const (
	tasksCols     = "CAST(sp.tasks_cpu_ms AS bigint) AS tasks_cpu_ms,\n  CAST(sp.tasks_physical_io AS bigint) AS tasks_physical_io,"
	tasksColsNone = "CAST(NULL AS bigint) AS tasks_cpu_ms,\n  CAST(NULL AS bigint) AS tasks_physical_io,"
	tasksJoin     = `LEFT JOIN (
    SELECT p.spid, p.request_id, SUM(CAST(p.cpu AS bigint)) AS tasks_cpu_ms, SUM(CAST(p.physical_io AS bigint)) AS tasks_physical_io
    FROM sys.sysprocesses p
    GROUP BY p.spid, p.request_id
  ) sp ON sp.spid = r.session_id AND sp.request_id = r.request_id`
)

// whoIsActiveArgs are the documented parameters of the call: the transaction's start and log use, the batch
// around the statement, the block leaders, and plain values instead of formatted text.
const whoIsActiveArgs = "@get_transaction_info = 1, @get_outer_command = 1, @find_block_leaders = 1, @format_output = 0"

// requestsSQL builds the snapshot's statement for a source ("dmv" or "sp_whoisactive") on a kind of server.
func requestsSQL(source string, kind Kind) string {
	fill := requestsDMV
	if source == sourceWIA {
		fill = requestsWIA
	}
	q := strings.ReplaceAll(requestsTemplate, "{{cap}}", strconv.Itoa(statementCap))
	for k, v := range fill {
		q = strings.ReplaceAll(q, "{{"+k+"}}", v)
	}
	if kind == KindAzureDB {
		q = strings.ReplaceAll(q, "{{tasks_cols}}", tasksColsNone)
		q = strings.ReplaceAll(q, "{{tasks_join}}", "")
		q = strings.ReplaceAll(q, "{{dbfilter}}", "\n  AND s.database_id = DB_ID()")
	} else {
		q = strings.ReplaceAll(q, "{{tasks_cols}}", tasksCols)
		q = strings.ReplaceAll(q, "{{tasks_join}}", tasksJoin)
		q = strings.ReplaceAll(q, "{{dbfilter}}", "")
	}
	return q
}

// whoIsActiveSQL wraps the snapshot's statement in the call of sp_WhoIsActive: the procedure returns the CREATE
// TABLE of its own output for these parameters (@return_schema), the table is made as a session temp table, the
// procedure fills it (@destination_table) and the snapshot reads it. All of it is one dynamic batch, because a
// temp table lives no longer than the batch that made it. db is the database the procedure was found in.
func whoIsActiveSQL(db string, kind Kind) string {
	proc := "[" + strings.ReplaceAll(db, "]", "]]") + "].dbo.sp_WhoIsActive"
	if kind == KindAzureDB {
		proc = "dbo.sp_WhoIsActive"
	}
	inner := "\nEXEC " + proc + " " + whoIsActiveArgs + ", @destination_table = N'#pgvigil_wia';\n" + requestsSQL(sourceWIA, kind)
	return "DECLARE @schema nvarchar(max), @sql nvarchar(max);\n" +
		"EXEC " + proc + " " + whoIsActiveArgs + ", @return_schema = 1, @schema = @schema OUTPUT;\n" +
		"IF @schema IS NULL OR CHARINDEX(N'<table_name>', @schema) = 0\n" +
		"  THROW 50000, N'sp_WhoIsActive returned no schema for its output (@return_schema)', 1;\n" +
		"SET @sql = REPLACE(@schema, N'<table_name>', N'#pgvigil_wia') + N';" + strings.ReplaceAll(inner, "'", "''") + "';\n" +
		"EXEC sys.sp_executesql @sql;"
}

const (
	sourceDMV = "dmv"
	sourceWIA = "sp_whoisactive"
)

func (requestsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	start := time.Now()
	pre := requestsPreSQL
	if info.Kind == KindAzureDB {
		pre = requestsPreAzureDBSQL
	}
	head, err := QueryRows(ctx, conn, pre)
	if err != nil {
		return nil, err
	}
	if len(head) != 1 {
		return nil, fmt.Errorf("the server's clock read returned %d rows", len(head))
	}
	source, note := sourceDMV, "sp_WhoIsActive is not installed in master or in the connection's database"
	if seen, _ := asInt(head[0]["wia_seen"]); seen == 1 {
		note = "sp_WhoIsActive is installed, but the login has no EXECUTE permission on it"
	}
	var rows, extra []collect.Row
	if db, ok := head[0]["wia_db"].(string); ok && db != "" {
		rows, err = QueryRows(ctx, conn, whoIsActiveSQL(db, info.Kind))
		if err == nil {
			source, note = sourceWIA, "sp_WhoIsActive in "+db+", completed from the DMVs by session and request id"
		} else {
			if ctx.Err() != nil {
				return nil, err
			}
			// the call failed (an old version without a parameter, a right it needs): the DMV read is the fallback,
			// and the run says so
			note = "sp_WhoIsActive in " + db + " failed, the DMV read ran instead"
			extra = append(extra, collect.Row{"kind": "collector_error", "source": "sp_WhoIsActive", "message": err.Error() + "; the DMV read ran instead"})
		}
	}
	if source == sourceDMV {
		if rows, err = QueryRows(ctx, conn, requestsSQL(sourceDMV, info.Kind)); err != nil {
			return nil, err
		}
	}
	out := shapeRequests(rows)
	out = append(out, collect.Row{
		"kind": "summary", "server_utc": head[0]["server_utc"], "source": source, "source_note": note,
		"memory_grants_pending": head[0]["memory_grants_pending"], "read_ms": time.Since(start).Milliseconds(),
	})
	return append(out, extra...), nil
}

// shapeRequests turns the statement's rows into the payload: the request rows with their chain, one text row per
// distinct (sql_handle, stmt_start, stmt_end), and one blocking row per head. The text leaves the request rows
// here, so a minute's rows carry a key; the text rows keep it under "statement", the key the instance's
// query-text policy rewrites.
func shapeRequests(rows []collect.Row) []collect.Row {
	out := make([]collect.Row, 0, len(rows)+8)
	var texts []collect.Row
	seen := map[string]bool{}
	for _, r := range rows {
		if h, ok := r["sql_handle"].(string); ok && h != "" {
			key := fmt.Sprintf("%s|%v|%v", h, r["stmt_start"], r["stmt_end"])
			if !seen[key] {
				seen[key] = true
				texts = append(texts, collect.Row{"kind": "text", "sql_handle": h, "stmt_start": r["stmt_start"],
					"stmt_end": r["stmt_end"], "statement": r["statement"], "full_chars": r["full_chars"]})
			}
		} else {
			r["sql_handle"], r["stmt_start"], r["stmt_end"] = nil, nil, nil
		}
		delete(r, "statement")
		delete(r, "full_chars")
		var sw []map[string]any
		for _, n := range []string{"sw1", "sw2", "sw3"} {
			if w, ok := r[n].(string); ok && w != "" {
				sw = append(sw, map[string]any{"wait": w, "ms": r[n+"_ms"], "tasks": r[n+"_tasks"]})
			}
			delete(r, n)
			delete(r, n+"_ms")
			delete(r, n+"_tasks")
		}
		if sw != nil {
			r["session_waits"] = sw
		}
		if w, ok := r["wait_type"].(string); ok {
			r["wait_is_benign"] = benignWaits[w]
		}
		out = append(out, r)
	}
	blocking := buildChains(out)
	out = append(out, texts...)
	return append(out, blocking...)
}

// blockerNotes says what a negative blocking_session_id means: there is no session to name as the head.
var blockerNotes = map[int64]string{
	-2: "blocked by an orphaned distributed transaction (-2), no session",
	-3: "blocked by a deferred recovery transaction (-3), no session",
	-4: "blocked by a latch whose owner the server could not determine (-4), no session",
	-5: "blocked by a latch any task may release (-5), no session",
}

// buildChains writes the blocking chain of one snapshot onto its request rows and returns one blocking row per
// head. The rule: a session is blocked when one of its requests names another session as its blocker; the head of
// a chain is the session that blocks and is not itself blocked. A blocked row gets head_session_id and chain_depth
// (1 directly behind the head, 2 behind that); the head's rows get their own session as head_session_id, depth 0,
// victims (every session behind it, at any depth) and longest_victim_wait_ms. A negative blocker (an orphaned
// transaction, a latch without an owner) is not a session: a session that waits only behind one is not blocked
// for this rule, so it heads the sessions behind it, and its rows and its blocking row carry the note. A chain
// that closes on itself has no head: its members get in_cycle and a note, the sessions behind it the note. A
// head whose own row is not in the snapshot still gets its blocking row.
func buildChains(rows []collect.Row) []collect.Row {
	type sess struct {
		blocker   int64 // the session it waits behind; 0 = none
		waitMs    int64
		neg       int64 // a negative blocker (no session), when it waits behind no session
		negWaitMs int64
		rows      []collect.Row
	}
	byID := map[int64]*sess{}
	var order []int64
	for _, r := range rows {
		id, ok := asInt(r["session_id"])
		if !ok {
			continue
		}
		s := byID[id]
		if s == nil {
			s = &sess{}
			byID[id] = s
			order = append(order, id)
		}
		s.rows = append(s.rows, r)
		// MARS: a session can run several requests; the one that waits longest behind another SESSION counts. A
		// negative blocker is not a session: it is kept as a note and never hides a session the row waits behind.
		if b, ok := asInt(r["blocking_session_id"]); ok && b != 0 && b != id {
			w, _ := asInt(r["wait_ms"])
			if b < 0 {
				if s.blocker == 0 && (s.neg == 0 || w > s.negWaitMs) {
					s.neg, s.negWaitMs = b, w
				}
			} else if s.blocker == 0 || w > s.waitMs {
				s.blocker, s.waitMs, s.neg = b, w, 0
			}
		}
	}
	type headAgg struct {
		victims int
		longest int64
	}
	heads := map[int64]*headAgg{}
	for _, id := range order {
		s := byID[id]
		if s.blocker == 0 {
			continue
		}
		cur, depth := s.blocker, 1
		visited := map[int64]bool{id: true}
		var head int64
		found, cycle, note := false, false, ""
		for {
			if visited[cur] {
				// only a session the walk comes back to is a member of the cycle; the others wait behind it
				cycle, note = cur == id, "a blocking cycle: a deadlock the server has not resolved yet"
				if !cycle {
					note = "behind " + note
				}
				break
			}
			visited[cur] = true
			next, in := byID[cur]
			if !in || next.blocker == 0 {
				head, found = cur, true
				break
			}
			cur = next.blocker
			depth++
		}
		for _, r := range s.rows {
			if found {
				r["head_session_id"], r["chain_depth"] = head, depth
			} else {
				r["chain_note"], r["in_cycle"] = note, cycle
			}
		}
		if found {
			h := heads[head]
			if h == nil {
				h = &headAgg{}
				heads[head] = h
			}
			h.victims++
			if s.waitMs > h.longest {
				h.longest = s.waitMs
			}
		}
	}
	ids := make([]int64, 0, len(heads))
	for id := range heads {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	out := make([]collect.Row, 0, len(ids))
	for _, id := range ids {
		h := heads[id]
		b := collect.Row{"kind": "blocking", "head_session_id": id, "victims": h.victims, "longest_wait_ms": h.longest}
		if s, in := byID[id]; in {
			for _, r := range s.rows {
				r["head_session_id"], r["chain_depth"], r["victims"], r["longest_victim_wait_ms"] = id, 0, h.victims, h.longest
			}
			if s.neg != 0 {
				b["note"] = "the head itself is " + negNote(s.neg)
			}
		} else {
			b["note"] = "the head's own row was not in the read: it ended between two reads, or the source does not list it (sp_WhoIsActive leaves system sessions out)"
		}
		out = append(out, b)
	}
	// a session that waits behind no session but behind something that is none: said on its rows, head or not
	for _, id := range order {
		if s := byID[id]; s.blocker == 0 && s.neg != 0 {
			for _, r := range s.rows {
				r["chain_note"] = negNote(s.neg)
			}
		}
	}
	return out
}

// negNote is the note of a negative blocker.
func negNote(b int64) string {
	if n := blockerNotes[b]; n != "" {
		return n
	}
	return fmt.Sprintf("blocked by %d, no session", b)
}

// asInt reads an integer the driver or a test handed over.
func asInt(v any) (int64, bool) {
	switch x := v.(type) {
	case int64:
		return x, true
	case int:
		return int64(x), true
	case int32:
		return int64(x), true
	case int16:
		return int64(x), true
	case uint8:
		return int64(x), true
	case float64:
		return int64(x), true
	}
	return 0, false
}
