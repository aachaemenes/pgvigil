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

// queryStoreCollector is mssql_querystore: per database, the Query Store's own state (actual against desired, why it
// is read-only, its size against its limit, the automatic tuning options), and for a store that holds data the top
// queries of each of its intervals by duration, CPU, logical reads, memory grant and waits, every forced plan with
// its failure count and reason, and the automatic tuning recommendations with their state.
//
// The store is read in two steps, so its history never leaves the server and the text, the plans and the plan XML
// are never joined for more than the plans that matter:
//
//  1. the intervals to read come from sys.query_store_runtime_stats_interval (one row per interval; its index on
//     end_time is a seek): from the newest interval the repository holds for the database (read again: it was
//     open), the oldest first, qsMaxIntervals a run, seven days back at most. A backlog is read over several runs;
//  2. sys.query_store_runtime_stats and sys.query_store_wait_stats are read for those interval ids alone, summed
//     per plan and interval on the server, and only the plans in an interval's top lists leave it (the candidate
//     set). A kept plan's aborted runs (execution_type 3: a client abort, a timeout or a cancel) and exception runs
//     (4: the run ended in an error) leave it apart, their executions, CPU and duration, where the interval had any
//     (failed > 0); otherwise NULL (0126 stores them so).
//
// What step 2 costs the server: the wait statistics are clustered by interval, the runtime statistics by plan
// (plan_id, runtime_stats_interval_id, execution_type; read on SQL Server 2022), so the filter on the interval
// cannot seek there and SQL Server reads the store's runtime statistics table through once per run, as SSMS's
// own Query Store reports and sp_QuickieStore do. That table is bounded by the store's MAX_STORAGE_SIZE_MB.
//
// The text, the plan's properties and the plan XML are then read for the candidate plans by their ids. A plan's XML
// is read once: the repository says which plans it already holds.
//
// The login needs VIEW SERVER STATE (which is VIEW DATABASE STATE in every database) and a way into each database:
// CONNECT ANY DATABASE, or a user in it. A database it cannot enter is listed with that note and not read.
//
// Runs on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed Instance; the wait statistics, the
// forcing type and automatic tuning from 2017 (14), the capture policy from 2019 (15). Not on Azure SQL Database
// yet (one database is the instance there; the per-database pass is a later wave). Nothing is written on the
// server: each read is one SELECT run through that database's sys.sp_executesql, which changes no session
// setting. The collector's own statements run inside the database and are captured by its Query Store like any
// other session's (two to seven short statements per database a run).
type queryStoreCollector struct{}

func init() { Register(queryStoreCollector{}) }

func (queryStoreCollector) Name() string                   { return Prefix + "querystore" }
func (queryStoreCollector) DefaultInterval() time.Duration { return time.Hour }

// Timeout: a few short reads per database; a server with many databases needs more than a minute.
func (queryStoreCollector) Timeout() time.Duration { return 5 * time.Minute }

func (queryStoreCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "not yet on Azure SQL Database (the per-database pass runs through other databases' sys.sp_executesql)"
	case info.Kind != KindAzureMI && info.Major > 0 && info.Major < 13:
		return false, "Query Store arrived in SQL Server 2016"
	case !info.ViewServerState:
		return false, "the login lacks VIEW SERVER STATE: the Query Store views of a database need VIEW DATABASE STATE, which it gives in every database the login can enter"
	}
	return true, ""
}

const (
	// qsTopN is how many plans of one interval each of the five top lists keeps.
	qsTopN = 50
	// qsFirstRead is how far back a database's first read goes; qsMaxBack how far any read goes.
	qsFirstRead = 24 * time.Hour
	qsMaxBack   = 7 * 24 * time.Hour
	// qsMaxIntervals bounds one read of one database (a 1-minute interval length over seven days is 10,080 rows):
	// the oldest intervals due come first, and the next run reads on from the newest of them.
	qsMaxIntervals = 200
	// qsPlanXMLPerRun bounds the plan XML one run of one database carries; qsPlanXMLMaxBytes one plan's XML.
	qsPlanXMLPerRun   = 100
	qsPlanXMLMaxBytes = 4 << 20
	// qsPlanXMLRunBytes bounds the plan XML one run carries over every database, as the server sizes it (two bytes
	// a character). A plan put off by either XML bound is stored without its XML and is asked for again the next
	// time it is among an interval's candidates (or while it is forced).
	qsPlanXMLRunBytes = 64 << 20
	// qsMaxRows: a run that already carries this many rows takes no further database (one database adds at most
	// qsMaxIntervals intervals of 5 x qsTopN plans each). The databases left over come first in the next run: a
	// first read of a busy server arrives over a few runs, not as one payload the repository's write would time
	// out on.
	qsMaxRows = 60000
	// qsMaxTuning bounds the recommendations read per database.
	qsMaxTuning = 200
	// qsSinceSource and qsPlanSource name the repository's cursors (pgvigil.mssql_hadr_cursor, 0083): the newest
	// interval stored for a database as epoch seconds, and the plan hash of a plan whose XML needs no read.
	qsSinceSource = "qs_since:"
	qsPlanSource  = "qs_plan:"
)

// qsDatabasesSQL lists the databases a Query Store can exist in (not master, not tempdb, not a database snapshot)
// and whether the login can enter each. SQL Server 2016+.
const qsDatabasesSQL = `SELECT d.database_id, d.name AS database_name, QUOTENAME(d.name) AS quoted_name,
  CAST(d.state_desc AS nvarchar(60)) AS database_state, CAST(d.is_read_only AS int) AS is_read_only,
  CAST(d.is_query_store_on AS int) AS is_query_store_on,
  CAST(CASE WHEN d.state = 0 AND HAS_DBACCESS(d.name) = 1 THEN 1 ELSE 0 END AS int) AS can_enter
FROM sys.databases d
WHERE d.database_id NOT IN (1, 2) AND d.source_database_id IS NULL
ORDER BY d.name`

// qsOptionsSQL runs inside one database: the store's options and whether the login may read the store.
// %s: the columns of later versions (qsOptionCols).
const qsOptionsSQL = `SELECT CAST(o.desired_state_desc AS nvarchar(60)) AS desired_state, CAST(o.actual_state_desc AS nvarchar(60)) AS actual_state,
  CAST(o.readonly_reason AS int) AS readonly_reason, CAST(o.current_storage_size_mb AS bigint) AS current_mb,
  CAST(o.max_storage_size_mb AS bigint) AS max_mb, CAST(o.flush_interval_seconds AS bigint) AS flush_interval_s,
  CAST(o.interval_length_minutes AS bigint) AS interval_minutes, CAST(o.stale_query_threshold_days AS bigint) AS stale_days,
  CAST(o.max_plans_per_query AS bigint) AS max_plans_per_query, CAST(o.query_capture_mode_desc AS nvarchar(60)) AS capture_mode,
  CAST(o.size_based_cleanup_mode_desc AS nvarchar(60)) AS cleanup_mode, CAST(o.actual_state_additional_info AS nvarchar(2000)) AS additional_info,
  CAST(HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE') AS int) AS can_read%s
FROM sys.database_query_store_options o`

// qsOptionCols: wait_stats_capture_mode from SQL Server 2017, the custom capture policy from 2019.
func qsOptionCols(info Info) string {
	var b strings.Builder
	if qsHasWaits(info) {
		b.WriteString(", CAST(o.wait_stats_capture_mode_desc AS nvarchar(60)) AS wait_stats_mode")
	}
	if info.Kind == KindAzureMI || info.Major >= 15 {
		b.WriteString(", o.capture_policy_execution_count AS policy_execution_count, o.capture_policy_total_compile_cpu_time_ms AS policy_compile_cpu_ms," +
			" o.capture_policy_total_execution_cpu_time_ms AS policy_exec_cpu_ms, o.capture_policy_stale_threshold_hours AS policy_stale_hours")
	}
	return b.String()
}

// qsHasWaits: sys.query_store_wait_stats, plan_forcing_type and automatic tuning arrived in SQL Server 2017 (14);
// Managed Instance has them whatever its product version says.
func qsHasWaits(info Info) bool { return info.Kind == KindAzureMI || info.Major >= 14 }

// qsIntervalsSQL: step one. The store's intervals that ended after @since, the oldest first: a backlog longer than
// @max is read over several runs, each going on from the newest interval the one before stored.
const qsIntervalsSQL = `SELECT TOP (@max) i.runtime_stats_interval_id AS interval_id, i.start_time AS interval_start, i.end_time AS interval_end
FROM sys.query_store_runtime_stats_interval i
WHERE i.end_time > @since
ORDER BY i.end_time, i.runtime_stats_interval_id`

// qsCandidatesSQL: step two. The runtime statistics of the intervals @first to @last, summed per plan and interval
// (a plan has a row per execution type: regular, aborted, exception), ranked inside each interval by total
// duration, CPU, logical reads, the largest memory grant and total wait time; a plan in the first @top of any list
// is kept. tot_* are the interval's totals over every plan, so the page can say what share the kept plans are.
// Durations and CPU are microseconds, memory is 8 KB pages. %s: the wait statistics' CTE (qsWaitsCTE or
// qsNoWaitsCTE, the first argument); %[2]s: a plan's wait time over it - qsWaitMS, 0 where no wait was recorded,
// or qsNoWaitMS, the empty relation's column: NULL where the server keeps no wait statistics (SQL Server 2016),
// so wait_ms and tot_wait_ms read as not measured (a column, never a constant: a window's ORDER BY refuses one).
const qsCandidatesSQL = `WITH rs AS (
  SELECT r.plan_id, r.runtime_stats_interval_id AS interval_id,
         SUM(r.count_executions) AS executions,
         SUM(CASE WHEN r.execution_type <> 0 THEN r.count_executions ELSE 0 END) AS failed,
         SUM(CASE WHEN r.execution_type = 3 THEN r.count_executions ELSE 0 END) AS aborted_executions,
         SUM(CASE WHEN r.execution_type = 3 THEN r.avg_cpu_time * r.count_executions ELSE 0 END) AS aborted_cpu_us,
         SUM(CASE WHEN r.execution_type = 3 THEN r.avg_duration * r.count_executions ELSE 0 END) AS aborted_duration_us,
         SUM(CASE WHEN r.execution_type = 4 THEN r.count_executions ELSE 0 END) AS exception_executions,
         SUM(CASE WHEN r.execution_type = 4 THEN r.avg_cpu_time * r.count_executions ELSE 0 END) AS exception_cpu_us,
         SUM(CASE WHEN r.execution_type = 4 THEN r.avg_duration * r.count_executions ELSE 0 END) AS exception_duration_us,
         SUM(r.avg_duration * r.count_executions) AS duration_us,
         SUM(r.avg_cpu_time * r.count_executions) AS cpu_us,
         SUM(r.avg_logical_io_reads * r.count_executions) AS logical_reads,
         SUM(r.avg_physical_io_reads * r.count_executions) AS physical_reads,
         SUM(r.avg_logical_io_writes * r.count_executions) AS logical_writes,
         SUM(r.avg_rowcount * r.count_executions) AS row_count,
         MAX(r.max_duration) AS max_duration_us,
         SUM(r.avg_query_max_used_memory * r.count_executions) AS memory_pages,
         MAX(r.max_query_max_used_memory) AS max_memory_pages,
         MAX(r.max_dop) AS max_dop,
         MIN(r.first_execution_time) AS first_execution, MAX(r.last_execution_time) AS last_execution
    FROM sys.query_store_runtime_stats r
   WHERE r.runtime_stats_interval_id BETWEEN @first AND @last
   GROUP BY r.plan_id, r.runtime_stats_interval_id
), %s, ranked AS (
  SELECT rs.*, %[2]s AS wait_ms, ws.top_wait,
         ROW_NUMBER() OVER (PARTITION BY rs.interval_id ORDER BY rs.duration_us DESC, rs.plan_id) AS rn_duration,
         ROW_NUMBER() OVER (PARTITION BY rs.interval_id ORDER BY rs.cpu_us DESC, rs.plan_id) AS rn_cpu,
         ROW_NUMBER() OVER (PARTITION BY rs.interval_id ORDER BY rs.logical_reads DESC, rs.plan_id) AS rn_reads,
         ROW_NUMBER() OVER (PARTITION BY rs.interval_id ORDER BY rs.max_memory_pages DESC, rs.plan_id) AS rn_memory,
         ROW_NUMBER() OVER (PARTITION BY rs.interval_id ORDER BY %[2]s DESC, rs.plan_id) AS rn_wait,
         COUNT(*) OVER (PARTITION BY rs.interval_id) AS tot_plans,
         SUM(rs.executions) OVER (PARTITION BY rs.interval_id) AS tot_executions,
         SUM(rs.duration_us) OVER (PARTITION BY rs.interval_id) AS tot_duration_us,
         SUM(rs.cpu_us) OVER (PARTITION BY rs.interval_id) AS tot_cpu_us,
         SUM(rs.logical_reads) OVER (PARTITION BY rs.interval_id) AS tot_logical_reads,
         SUM(%[2]s) OVER (PARTITION BY rs.interval_id) AS tot_wait_ms
    FROM rs LEFT JOIN ws ON ws.plan_id = rs.plan_id AND ws.interval_id = rs.interval_id
)
SELECT k.plan_id, k.interval_id, CAST(k.executions AS bigint) AS executions, CAST(k.failed AS bigint) AS failed,
       CASE WHEN k.failed > 0 THEN CAST(k.aborted_executions AS bigint) END AS aborted_executions,
       CASE WHEN k.failed > 0 THEN CAST(k.aborted_cpu_us AS bigint) END AS aborted_cpu_us,
       CASE WHEN k.failed > 0 THEN CAST(k.aborted_duration_us AS bigint) END AS aborted_duration_us,
       CASE WHEN k.failed > 0 THEN CAST(k.exception_executions AS bigint) END AS exception_executions,
       CASE WHEN k.failed > 0 THEN CAST(k.exception_cpu_us AS bigint) END AS exception_cpu_us,
       CASE WHEN k.failed > 0 THEN CAST(k.exception_duration_us AS bigint) END AS exception_duration_us,
       CAST(k.duration_us AS bigint) AS duration_us, CAST(k.cpu_us AS bigint) AS cpu_us,
       CAST(k.logical_reads AS bigint) AS logical_reads, CAST(k.physical_reads AS bigint) AS physical_reads,
       CAST(k.logical_writes AS bigint) AS logical_writes, CAST(k.row_count AS bigint) AS row_count,
       CAST(k.max_duration_us AS bigint) AS max_duration_us, CAST(k.memory_pages AS bigint) AS memory_pages,
       CAST(k.max_memory_pages AS bigint) AS max_memory_pages, CAST(k.max_dop AS bigint) AS max_dop,
       k.first_execution, k.last_execution, CAST(k.wait_ms AS bigint) AS wait_ms, CAST(k.top_wait AS nvarchar(60)) AS top_wait,
       CAST(k.tot_plans AS bigint) AS tot_plans, CAST(k.tot_executions AS bigint) AS tot_executions,
       CAST(k.tot_duration_us AS bigint) AS tot_duration_us, CAST(k.tot_cpu_us AS bigint) AS tot_cpu_us,
       CAST(k.tot_logical_reads AS bigint) AS tot_logical_reads, CAST(k.tot_wait_ms AS bigint) AS tot_wait_ms
  FROM ranked k
 WHERE k.rn_duration <= @top OR k.rn_cpu <= @top OR k.rn_reads <= @top OR k.rn_memory <= @top OR (k.rn_wait <= @top AND k.wait_ms > 0)
 ORDER BY k.interval_id, k.plan_id`

const (
	qsWaitsCTE = `w0 AS (
  SELECT w.plan_id, w.runtime_stats_interval_id AS interval_id, w.wait_category_desc, SUM(w.total_query_wait_time_ms) AS ms
    FROM sys.query_store_wait_stats w
   WHERE w.runtime_stats_interval_id BETWEEN @first AND @last
   GROUP BY w.plan_id, w.runtime_stats_interval_id, w.wait_category_desc
), ws AS (
  SELECT x.plan_id, x.interval_id, SUM(x.ms) AS wait_ms, MAX(CASE WHEN x.rn = 1 THEN x.wait_category_desc END) AS top_wait
    FROM (SELECT w0.*, ROW_NUMBER() OVER (PARTITION BY w0.plan_id, w0.interval_id ORDER BY w0.ms DESC, w0.wait_category_desc) AS rn FROM w0) x
   GROUP BY x.plan_id, x.interval_id
)`
	qsNoWaitsCTE = `ws AS (
  SELECT CAST(NULL AS bigint) AS plan_id, CAST(NULL AS bigint) AS interval_id, CAST(NULL AS bigint) AS wait_ms, CAST(NULL AS nvarchar(60)) AS top_wait WHERE 1 = 0
)`
	qsWaitMS   = `ISNULL(ws.wait_ms, 0)`
	qsNoWaitMS = `ws.wait_ms`
)

// qsPlansSQL reads the candidate plans by id, and every forced plan: the plan's properties, its query, the query's
// object and text, how many plans the query has. %[1]s: the forcing type (2017+) or NULL; %[2]s: the plan ids.
const qsPlansSQL = `SELECT p.plan_id, p.query_id, q.query_hash AS query_hash_hex, p.query_plan_hash AS plan_hash_hex,
  CAST(p.query_plan_hash AS bigint) AS plan_hash_n,
  CASE WHEN q.object_id > 0 THEN ISNULL(OBJECT_SCHEMA_NAME(q.object_id) + N'.', N'') + OBJECT_NAME(q.object_id) END AS object_name,
  CAST(p.is_forced_plan AS int) AS is_forced, %[1]s AS forcing_type, CAST(p.force_failure_count AS bigint) AS force_failure_count,
  CASE WHEN p.force_failure_count > 0 THEN CAST(p.last_force_failure_reason_desc AS nvarchar(128)) END AS force_failure_reason,
  CAST(p.is_parallel_plan AS int) AS is_parallel, CAST(p.is_trivial_plan AS int) AS is_trivial,
  CAST(p.count_compiles AS bigint) AS count_compiles, CAST(p.compatibility_level AS int) AS compatibility_level,
  p.initial_compile_start_time AS initial_compile, p.last_compile_start_time AS last_compile, p.last_execution_time AS plan_last_execution,
  q.last_execution_time AS query_last_execution, CAST(q.query_parameterization_type_desc AS nvarchar(60)) AS parameterization,
  (SELECT COUNT(*) FROM sys.query_store_plan p2 WHERE p2.query_id = p.query_id) AS plan_count,
  CAST(DATALENGTH(p.query_plan) AS bigint) AS plan_xml_bytes,
  CAST(LEFT(t.query_sql_text, 16000) AS nvarchar(max)) AS query
FROM sys.query_store_plan p
JOIN sys.query_store_query q ON q.query_id = p.query_id
JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id
WHERE p.is_forced_plan = 1 OR p.plan_id IN (%[2]s)`

// qsPlanXMLSQL reads the showplan XML of the named plans. %s: the plan ids.
const qsPlanXMLSQL = `SELECT p.plan_id, p.query_plan AS plan_xml FROM sys.query_store_plan p WHERE p.plan_id IN (%s) AND DATALENGTH(p.query_plan) <= @maxbytes`

// qsTuningOptionsSQL: the automatic tuning options of the database (FORCE_LAST_GOOD_PLAN; Azure has more). 2017+.
const qsTuningOptionsSQL = `SELECT CAST(o.name AS nvarchar(128)) AS option_name, CAST(o.desired_state_desc AS nvarchar(60)) AS desired_state,
  CAST(o.actual_state_desc AS nvarchar(60)) AS actual_state, CAST(o.reason_desc AS nvarchar(128)) AS reason
FROM sys.database_automatic_tuning_options o`

// qsTuningSQL: the automatic tuning recommendations. 2017+. state and details are JSON documents the server
// writes; details holds ids and measurements and the script that would force the plan, no statement text.
const qsTuningSQL = `SELECT TOP (@max) CAST(r.name AS nvarchar(4000)) AS rec_name, CAST(r.type AS nvarchar(128)) AS rec_type, CAST(r.reason AS nvarchar(4000)) AS reason,
  CONVERT(varchar(33), r.valid_since, 126) + 'Z' AS valid_since, CONVERT(varchar(33), r.last_refresh, 126) + 'Z' AS last_refresh,
  CAST(JSON_VALUE(r.state, '$.currentValue') AS nvarchar(60)) AS rec_state, CAST(JSON_VALUE(r.state, '$.reason') AS nvarchar(128)) AS state_reason,
  CAST(r.is_executable_action AS int) AS is_executable, CAST(r.is_revertable_action AS int) AS is_revertable,
  CASE WHEN r.execute_action_start_time > '2000-01-01' THEN CONVERT(varchar(33), r.execute_action_start_time, 126) + 'Z' END AS executed_at,
  CAST(r.execute_action_initiated_by AS nvarchar(60)) AS executed_by,
  CASE WHEN r.revert_action_start_time > '2000-01-01' THEN CONVERT(varchar(33), r.revert_action_start_time, 126) + 'Z' END AS reverted_at,
  CAST(r.revert_action_initiated_by AS nvarchar(60)) AS reverted_by,
  CAST(r.score AS int) AS score,
  CAST(JSON_VALUE(r.details, '$.planForceDetails.queryId') AS bigint) AS query_id,
  CAST(JSON_VALUE(r.details, '$.planForceDetails.regressedPlanId') AS bigint) AS regressed_plan_id,
  CAST(JSON_VALUE(r.details, '$.planForceDetails.recommendedPlanId') AS bigint) AS recommended_plan_id,
  CAST(JSON_VALUE(r.details, '$.implementationDetails.script') AS nvarchar(4000)) AS script,
  CAST(LEFT(r.details, 8000) AS nvarchar(max)) AS rec_details
FROM sys.dm_db_tuning_recommendations r
ORDER BY r.score DESC, r.last_refresh DESC`

// inDatabase wraps a statement to run inside one database: quoted is QUOTENAME(name) as the server wrote it; the
// statement and its parameter list travel as parameters, never spliced into the batch.
func inDatabase(quoted, decl string) string {
	if decl == "" {
		return "EXEC " + quoted + ".sys.sp_executesql @stmt"
	}
	names := []string{}
	for _, d := range strings.Split(decl, ",") {
		n := strings.Fields(strings.TrimSpace(d))[0]
		names = append(names, n+" = "+n)
	}
	return "EXEC " + quoted + ".sys.sp_executesql @stmt, N'" + decl + "', " + strings.Join(names, ", ")
}

// qsRead runs one statement inside a database.
func qsRead(ctx context.Context, conn *sql.Conn, quoted, stmt, decl string, args ...any) ([]collect.Row, error) {
	all := append([]any{sql.Named("stmt", stmt)}, args...)
	return QueryRows(ctx, conn, inDatabase(quoted, decl), all...)
}

// Run is the read without a cursor (a RunOnce that does not know CursorCollector): a day back, every plan's XML.
func (c queryStoreCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	return c.RunFrom(ctx, conn, info, nil)
}

// qsTurn is one database the run can enter: where its store row is, and the newest interval the repository holds
// for it (0: none).
type qsTurn struct {
	name, quoted string
	state        collect.Row
	last         int64
	hasLast      bool
}

// qsOldestFirst orders the databases to read: the one the repository holds least of first (never read, then the
// oldest newest interval), by name among equals. A run cut by its deadline or its row bound leaves the databases
// it did not reach; with this order they are the first of the next run, never the same tail every time.
func qsOldestFirst(turns []qsTurn) {
	sort.SliceStable(turns, func(i, j int) bool { return turns[i].last < turns[j].last })
}

// RunFrom reads every database's store state and, where a store holds data, its intervals on from the newest one
// the repository holds.
func (queryStoreCollector) RunFrom(ctx context.Context, conn *sql.Conn, info Info, cursor SeqCursorFunc) ([]collect.Row, error) {
	dbs, err := QueryRows(ctx, conn, qsDatabasesSQL)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	out := make([]collect.Row, 0, 4*len(dbs)+1)
	var failed []string
	var turns []qsTurn
	// noAccess and entered count the databases of the server's users (database ids above 4): any login enters msdb
	// through its guest user, which says nothing about the stores that matter
	noAccess, entered := 0, 0
	for _, d := range dbs {
		name, _ := d["database_name"].(string)
		quoted, _ := d["quoted_name"].(string)
		id, _ := d["database_id"].(int64)
		state := collect.Row{"kind": "store", "database_id": d["database_id"], "database_name": name, "database_state": d["database_state"],
			"database_read_only": d["is_read_only"]}
		out = append(out, state)
		if n, _ := d["can_enter"].(int64); n != 1 {
			if ds, _ := d["database_state"].(string); ds != "ONLINE" {
				state["note"] = "not read: the database is " + strings.ToLower(ds)
			} else {
				state["note"] = "not read: the login cannot enter the database (CONNECT ANY DATABASE, or a user in the database, is the missing right)"
				if id > 4 {
					noAccess++
				}
			}
			continue
		}
		if id > 4 {
			entered++
		}
		t := qsTurn{name: name, quoted: quoted, state: state}
		if cursor != nil {
			// a repository that does not answer ends the run: nothing read from here on could be stored
			if t.last, t.hasLast, err = cursor(ctx, qsSinceSource+name); err != nil {
				return nil, fmt.Errorf("the repository's cursor of %s: %w", name, err)
			}
		}
		turns = append(turns, t)
	}
	qsOldestFirst(turns)
	cut, stopWhy := 0, ""
	xmlBudget := int64(qsPlanXMLRunBytes)
	stop, hasStop := ctx.Deadline()
	for _, t := range turns {
		if stopWhy == "" {
			switch {
			case ctx.Err() != nil || (hasStop && time.Until(stop) < 15*time.Second):
				stopWhy = "the run's deadline came"
			case len(out) >= qsMaxRows:
				stopWhy = fmt.Sprintf("the run already carried %d rows", len(out))
			}
		}
		if stopWhy != "" {
			t.state["note"] = "not read: " + stopWhy + " before this database's turn; it comes first in the next run"
			cut++
			continue
		}
		rows, err := qsDatabase(ctx, conn, info, cursor, t, now, &xmlBudget)
		out = append(out, rows...)
		if err != nil {
			if ctx.Err() != nil {
				t.state["note"] = "not read whole: the run's deadline came during this database's read"
				stopWhy = "the run's deadline came"
				cut++
				continue
			}
			t.state["note"] = "the read of the store failed: " + err.Error()
			failed = append(failed, t.name)
		}
	}
	if cut > 0 {
		out = append(out, collect.Row{"kind": "collector_error", "source": "sys.query_store_runtime_stats",
			"message": fmt.Sprintf("%s before the Query Store of %d database(s) was read; they come first in the next run", stopWhy, cut)})
	}
	// a login that can enter none of the users' databases reads no store that matters: say which right is missing
	// (one database kept closed to the login is a choice, and only its row says so)
	if noAccess > 0 && entered == 0 {
		out = append(out, collect.Row{"kind": "collector_error", "source": "sys.databases",
			"message": fmt.Sprintf("the login cannot enter any of the %d user database(s): GRANT CONNECT ANY DATABASE (with VIEW SERVER STATE) lets it read each Query Store", noAccess)})
	}
	if len(failed) > 0 {
		out = append(out, collect.Row{"kind": "collector_error", "source": "sys.database_query_store_options",
			"message": fmt.Sprintf("the Query Store of %d database(s) was not read whole (%s): each store's note says why", len(failed), firstFew(failed, 5))})
	}
	return out, nil
}

// qsDatabase reads one database: the options into the store row, the automatic tuning options, then the
// intervals, the candidate plans and their properties, the plan XML and the recommendations.
//
// A database's intervals are complete or absent: an interval's runtime rows are returned only together with the
// plan rows that name their queries (the import moves the database's cursor past what it stores). An error
// before that point returns the tuning options alone and the next run reads the same intervals again; an error
// after it (the plan XML, the recommendations) keeps what is complete.
func qsDatabase(ctx context.Context, conn *sql.Conn, info Info, cursor SeqCursorFunc, t qsTurn, now time.Time, xmlBudget *int64) ([]collect.Row, error) {
	name, quoted, state := t.name, t.quoted, t.state
	opt, err := qsRead(ctx, conn, quoted, fmt.Sprintf(qsOptionsSQL, qsOptionCols(info)), "")
	if err != nil {
		return nil, err
	}
	if len(opt) == 0 {
		state["note"] = "sys.database_query_store_options returned no row"
		return nil, nil
	}
	for k, v := range opt[0] {
		state[k] = v
	}
	state["read"] = 1
	if n, _ := opt[0]["can_read"].(int64); n != 1 {
		state["note"] = "the store's contents were not read: the login lacks VIEW DATABASE STATE in this database"
		return nil, nil
	}
	var pre []collect.Row // what stands on its own: the tuning options
	if qsHasWaits(info) {
		tuning, err := qsRead(ctx, conn, quoted, qsTuningOptionsSQL, "")
		if err != nil {
			return pre, err
		}
		for _, r := range tuning {
			r["kind"], r["database_name"] = "tuning_option", name
		}
		pre = append(pre, tuning...)
	}
	if a, _ := opt[0]["actual_state"].(string); a != "READ_WRITE" && a != "READ_ONLY" {
		return pre, nil // OFF or ERROR: no data to read
	}
	since := now.Add(-qsFirstRead)
	if t.hasLast {
		since = time.Unix(t.last, 0).UTC()
	}
	if floor := now.Add(-qsMaxBack); since.Before(floor) {
		since = floor
	}
	ivs, err := qsRead(ctx, conn, quoted, qsIntervalsSQL, "@since datetimeoffset(7), @max int", sql.Named("since", since), sql.Named("max", qsMaxIntervals))
	if err != nil {
		return pre, err
	}
	planIDs := map[int64]bool{}
	var data []collect.Row
	if len(ivs) > 0 {
		first, last := int64(0), int64(0)
		byID := map[int64]collect.Row{}
		for _, iv := range ivs {
			id, _ := iv["interval_id"].(int64)
			if first == 0 || id < first {
				first = id
			}
			if id > last {
				last = id
			}
			iv["kind"], iv["database_name"] = "interval", name
			byID[id] = iv
		}
		waits, waitMS := qsNoWaitsCTE, qsNoWaitMS
		if qsHasWaits(info) {
			waits, waitMS = qsWaitsCTE, qsWaitMS
		}
		cands, err := qsRead(ctx, conn, quoted, fmt.Sprintf(qsCandidatesSQL, waits, waitMS), "@first bigint, @last bigint, @top int",
			sql.Named("first", first), sql.Named("last", last), sql.Named("top", qsTopN))
		if err != nil {
			return pre, err
		}
		data = qsRuntimeRows(name, ivs, byID, cands, planIDs)
	}
	// the candidate plans' properties and text, and every forced plan
	plans, err := qsRead(ctx, conn, quoted, fmt.Sprintf(qsPlansSQL, qsForcingCol(info), qsIDList(planIDs)), "")
	if err != nil {
		return pre, err
	}
	var want []int64
	sizes := map[int64]int64{}
	for _, p := range plans {
		p["kind"], p["database_name"] = "plan", name
		id, _ := p["plan_id"].(int64)
		size, _ := p["plan_xml_bytes"].(int64)
		switch {
		case size == 0:
		case size > qsPlanXMLMaxBytes:
			p["xml_note"] = fmt.Sprintf("the plan XML is %d bytes: over the %d MB a plan may take, not stored", size, qsPlanXMLMaxBytes>>20)
		default:
			if err := ctx.Err(); err != nil {
				return pre, err
			}
			stored, err := qsPlanStored(ctx, cursor, name, id, p["plan_hash_n"])
			if err != nil {
				return pre, err // the repository does not answer: one failed lookup, not one per plan
			}
			if !stored {
				want = append(want, id)
				sizes[id] = size
			}
		}
	}
	// Complete from here. The marker says the plan read succeeded: a plan the repository holds as forced and this
	// read does not list is no longer forced. It also carries the instance's text policy to the import: kind_of
	// 'plan' is the policy's word for a plan document, whose statement column it empties unless the policy is
	// full, and the import then drops the plan XML an earlier, wider policy stored for the database.
	out := append(append(append(pre, data...), plans...),
		collect.Row{"kind": "forced_read", "kind_of": "plan", "database_name": name, "statement": "kept"})
	sort.Slice(want, func(i, j int) bool { return want[i] > want[j] }) // the newest plans first when the run's share is cut
	ids := map[int64]bool{}
	for _, id := range want {
		if len(ids) >= qsPlanXMLPerRun {
			break
		}
		if sizes[id] > *xmlBudget {
			continue // stored without its XML: asked for again the next time the plan is a candidate
		}
		*xmlBudget -= sizes[id]
		ids[id] = true
	}
	if len(ids) > 0 {
		xml, err := qsRead(ctx, conn, quoted, fmt.Sprintf(qsPlanXMLSQL, qsIDList(ids)), "@maxbytes bigint", sql.Named("maxbytes", int64(qsPlanXMLMaxBytes)))
		if err != nil {
			return out, err
		}
		for _, x := range xml {
			// kind_of 'plan': its statement column is kept under the full policy only (a showplan carries the
			// statement's text and the compiled parameter values)
			out = append(out, collect.Row{"kind": "plan_xml", "kind_of": "plan", "database_name": name, "plan_id": x["plan_id"], "statement": x["plan_xml"]})
		}
	}
	if qsHasWaits(info) {
		recs, err := qsRead(ctx, conn, quoted, qsTuningSQL, "@max int", sql.Named("max", qsMaxTuning))
		if err != nil {
			return out, err
		}
		for _, r := range recs {
			r["kind"], r["database_name"] = "tuning", name
		}
		out = append(out, recs...)
		// the marker says the list is whole: a stored recommendation it does not hold is gone. A list cut at
		// its bound says nothing about the ones past it.
		if len(recs) < qsMaxTuning {
			out = append(out, collect.Row{"kind": "tuning_read", "database_name": name})
		}
	}
	return out, nil
}

// qsRuntimeRows turns the candidate set into the payload's rows: one 'interval' row per interval read (with the
// interval's totals over every plan, taken from its first candidate row) and one 'runtime' row per kept plan and
// interval. planIDs collects the plans to read next.
func qsRuntimeRows(name string, ivs []collect.Row, byID map[int64]collect.Row, cands []collect.Row, planIDs map[int64]bool) []collect.Row {
	out := make([]collect.Row, 0, len(ivs)+len(cands))
	for _, c := range cands {
		id, _ := c["interval_id"].(int64)
		iv, ok := byID[id]
		if !ok {
			continue // an interval between @first and @last that the interval read did not list
		}
		if _, has := iv["executions"]; !has {
			iv["plans"], iv["executions"], iv["duration_us"] = c["tot_plans"], c["tot_executions"], c["tot_duration_us"]
			iv["cpu_us"], iv["logical_reads"], iv["wait_ms"] = c["tot_cpu_us"], c["tot_logical_reads"], c["tot_wait_ms"]
		}
		for _, k := range []string{"tot_plans", "tot_executions", "tot_duration_us", "tot_cpu_us", "tot_logical_reads", "tot_wait_ms"} {
			delete(c, k)
		}
		// the split travels only where the interval had a failure: the import stores NULL for the rest anyway
		if f, _ := c["failed"].(int64); f == 0 {
			for _, k := range qsSplitKeys {
				delete(c, k)
			}
		}
		c["kind"], c["database_name"], c["interval_start"] = "runtime", name, iv["interval_start"]
		if p, _ := c["plan_id"].(int64); p > 0 {
			planIDs[p] = true
		}
		out = append(out, c)
	}
	return append(ivs, out...)
}

// qsSplitKeys are a runtime row's aborted and exception figures (0126).
var qsSplitKeys = []string{"aborted_executions", "aborted_cpu_us", "aborted_duration_us", "exception_executions", "exception_cpu_us", "exception_duration_us"}

// qsPlanStored asks the repository whether it holds this plan's XML already (or looked at it within a day and
// kept none under the instance's text policy): the stored plan's hash must be this plan's, since a cleared store
// numbers its plans again from 1. An error is the repository not answering.
func qsPlanStored(ctx context.Context, cursor SeqCursorFunc, name string, planID int64, hash any) (bool, error) {
	if cursor == nil {
		return false, nil
	}
	want, isNum := hash.(int64)
	got, ok, err := cursor(ctx, qsPlanSource+strconv.FormatInt(planID, 10)+":"+name)
	if err != nil {
		return false, fmt.Errorf("the repository's cursor of plan %d in %s: %w", planID, name, err)
	}
	return ok && isNum && got == want, nil
}

// qsForcingCol: plan_forcing_type_desc from SQL Server 2017.
func qsForcingCol(info Info) string {
	if qsHasWaits(info) {
		return "CAST(p.plan_forcing_type_desc AS nvarchar(60))"
	}
	return "CASE WHEN p.is_forced_plan = 1 THEN N'MANUAL' ELSE N'NONE' END"
}

// qsIDList writes plan ids as an IN list (numbers the server itself returned); no id = one that matches nothing.
func qsIDList(ids map[int64]bool) string {
	if len(ids) == 0 {
		return "-1"
	}
	s := make([]string, 0, len(ids))
	for id := range ids {
		s = append(s, strconv.FormatInt(id, 10))
	}
	sort.Strings(s)
	return strings.Join(s, ",")
}
