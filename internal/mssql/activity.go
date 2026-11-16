package mssql

import (
	"context"
	"database/sql"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// activityCollector is mssql_activity (task 177 D14): what PerformanceMonitor's Activity tab and sp_PressureDetector
// read about the server's sessions, every 5 minutes (PerformanceMonitor's session_stats cadence):
//
//   - Sessions: one read of sys.dm_exec_sessions grouped by GROUPING SETS: the totals of PerformanceMonitor's
//     SessionSummaryStatsCollector over the sessions over 50, as its read has them (running, sleeping, background = not a user process, dormant,
//     idle over 30 minutes = sleeping user sessions whose last request ended 30 or more minutes ago, the databases
//     with a connection), and per application, per host and per database PerformanceMonitor's SessionStatsCollector
//     figures over the user sessions over 50 with a program name (connections, running, sleeping, dormant, CPU,
//     reads, writes, logical reads). pgvigil's own sessions are left out of the groups by their program name: the
//     reading connection's own (PROGRAM_NAME(), whatever the connection string set) and any 'pgvigil%', as
//     PerformanceMonitor leaves out 'PerformanceMonitor%'. sys.dm_exec_requests is not joined: the requests a page
//     needs (waiting for memory) come from mssql_requests, read each minute (requests.go).
//   - Sessions holding tempdb: sp_PressureDetector's tempdb read (L2700-2745): sys.dm_db_task_space_usage (running
//     tasks) and sys.dm_db_session_space_usage (the session's finished tasks) summed per session over 50, kept when
//     the allocations are over 0, the 20 largest by allocations, with the running tasks' part apart and the session's
//     login, program, host, status, open transactions and last request's end.
//   - sp_PressureDetector's CPU details from sys.dm_os_sys_info: the columns it lists that this server has
//     (socket_count, numa_node_count, cpu_count, cores_per_socket, hyperthread_ratio, softnuma_configuration_desc,
//     scheduler_total_count, scheduler_count), found in sys.all_columns as sp_PressureDetector finds them (L3843-3881).
//
// Each read but the sessions' is taken on its own: a server that refuses one keeps the others, and the refused one is
// a 'collector_error' row the import keeps. Rights: VIEW SERVER STATE (other logins' sessions). Not on Azure SQL
// Database.
type activityCollector struct{}

func init() { Register(activityCollector{}) }

func (activityCollector) Name() string                   { return Prefix + "activity" }
func (activityCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (activityCollector) Applies(in Info) (bool, string) {
	if in.Kind == KindAzureDB {
		return false, "not on Azure SQL Database: sys.dm_os_performance_counters and the server's sessions there are the host's"
	}
	if !in.ViewServerState {
		return false, "the login lacks VIEW SERVER STATE: the sessions of other logins cannot be read"
	}
	return true, ""
}

// activitySessionsSQL: one read of sys.dm_exec_sessions grouped by GROUPING SETS (task 413's one read, the lead 11-15):
//   - the total over ALL sessions (the Connections page's one user / system rule: background = the
//     system sessions, is_user_process = 0; before 413 the total counted sessions over 50, PerformanceMonitor's rule);
//   - per program, host and database, the user sessions with a program name that are not pgvigil's own
//     (PerformanceMonitor's SessionStatsCollector groups): any other session has no key there and falls in the NULL
//     group of the set, which activityRows drops;
//   - kind 'session_by' (0163's mssql_session_by): every session per login, per status x user / system, per network
//     interface and per client address of its physical connection (sys.dm_exec_connections, parent_connection_id IS
//     NULL in the join: a MARS session counted once; a session with no connection, a system one, has NULL there: a
//     bucket of its own, kept) and per isolation level; of login, interface and address the 50 largest names, the rest
//     summed in one row whose is_other is 1 (the set's own column, so a NULL name and the rest stay apart).
//
// OPTION (RECOMPILE): a plan of the session and connection DMVs compiled at a few sessions and reused at thousands ran
// 44 s CPU-bound on SQL Server 2017 (box diag 413-d2017d: 193 ms at 32 sessions, 43,967 ms reused at 5,037, 293 ms
// recompiled) - a connection surge would cost every read; one compile per 5-minute read.
const activitySessionsSQL = `WITH b AS (
  SELECT s.session_id, s.status, CAST(s.is_user_process AS int) AS is_user_process, s.last_request_end_time, s.database_id,
         s.cpu_time, s.reads, s.writes, s.logical_reads, s.login_time, s.login_name, s.transaction_isolation_level,
         c.net_transport, c.protocol_type, c.client_net_address,
         CASE WHEN s.is_user_process = 1 AND ISNULL(s.program_name, N'') <> N''
                   AND s.program_name <> ISNULL(PROGRAM_NAME(), N'') AND s.program_name NOT LIKE N'pgvigil%' THEN 1 ELSE 0 END AS mine,
         s.program_name, s.host_name
    FROM sys.dm_exec_sessions s
    LEFT JOIN sys.dm_exec_connections c ON c.session_id = s.session_id AND c.parent_connection_id IS NULL),
k AS (
  SELECT b.*,
         CAST(b.login_name AS nvarchar(128)) AS lg,
         CAST(CASE WHEN b.is_user_process = 1 THEN N'user ' ELSE N'system ' END + b.status AS nvarchar(60)) AS st,
         CAST(CASE WHEN b.net_transport IS NULL THEN NULL ELSE b.net_transport + N' / ' + ISNULL(b.protocol_type, N'?') END AS nvarchar(80)) AS itf,
         CAST(b.client_net_address AS nvarchar(48)) AS addr,
         CAST(CASE b.transaction_isolation_level WHEN 0 THEN N'unspecified' WHEN 1 THEN N'read uncommitted' WHEN 2 THEN N'read committed'
                   WHEN 3 THEN N'repeatable read' WHEN 4 THEN N'serializable' WHEN 5 THEN N'snapshot' END AS nvarchar(30)) AS iso
    FROM b),
n AS (
  SELECT k.*, COUNT(*) OVER (PARTITION BY k.lg) AS lg_n, COUNT(*) OVER (PARTITION BY k.itf) AS itf_n,
         COUNT(*) OVER (PARTITION BY k.addr) AS addr_n
    FROM k),
x AS (
  SELECT n.*,
         CASE WHEN n.mine = 1 THEN n.program_name END AS gp,
         CASE WHEN n.mine = 1 THEN n.host_name END AS gh,
         CASE WHEN n.mine = 1 THEN DB_NAME(n.database_id) END AS gd,
         CASE WHEN DENSE_RANK() OVER (ORDER BY n.lg_n DESC, n.lg) > 50 THEN 1 ELSE 0 END AS lg_o,
         CASE WHEN DENSE_RANK() OVER (ORDER BY n.itf_n DESC, n.itf) > 50 THEN 1 ELSE 0 END AS itf_o,
         CASE WHEN DENSE_RANK() OVER (ORDER BY n.addr_n DESC, n.addr) > 50 THEN 1 ELSE 0 END AS addr_o
    FROM n),
y AS (
  SELECT x.*, CASE WHEN x.lg_o = 0 THEN x.lg END AS lg_k, CASE WHEN x.itf_o = 0 THEN x.itf END AS itf_k,
         CASE WHEN x.addr_o = 0 THEN x.addr END AS addr_k
    FROM x)
SELECT
  CASE WHEN GROUPING(y.lg_o) = 0 OR GROUPING(y.st) = 0 OR GROUPING(y.itf_o) = 0 OR GROUPING(y.addr_o) = 0 OR GROUPING(y.iso) = 0
       THEN 'session_by' ELSE 'sessions' END AS kind,
  CASE WHEN GROUPING(y.lg_o) = 0 OR GROUPING(y.st) = 0 OR GROUPING(y.itf_o) = 0 OR GROUPING(y.addr_o) = 0 OR GROUPING(y.iso) = 0 THEN NULL
       WHEN GROUPING(y.gp) = 0 THEN N'program' WHEN GROUPING(y.gh) = 0 THEN N'host' WHEN GROUPING(y.gd) = 0 THEN N'database'
       ELSE N'total' END AS grp,
  CASE WHEN GROUPING(y.lg_o) = 0 THEN N'login' WHEN GROUPING(y.st) = 0 THEN N'status' WHEN GROUPING(y.itf_o) = 0 THEN N'interface'
       WHEN GROUPING(y.addr_o) = 0 THEN N'address' WHEN GROUPING(y.iso) = 0 THEN N'isolation' END AS dimension,
  CAST(CASE WHEN GROUPING(y.lg_o) = 0 THEN y.lg_k WHEN GROUPING(y.st) = 0 THEN y.st WHEN GROUPING(y.itf_o) = 0 THEN y.itf_k
            WHEN GROUPING(y.addr_o) = 0 THEN y.addr_k WHEN GROUPING(y.iso) = 0 THEN y.iso
            ELSE COALESCE(y.gp, y.gh, y.gd) END AS nvarchar(256)) AS name,
  CASE WHEN GROUPING(y.lg_o) = 0 THEN y.lg_o WHEN GROUPING(y.itf_o) = 0 THEN y.itf_o WHEN GROUPING(y.addr_o) = 0 THEN y.addr_o ELSE 0 END AS is_other,
  CAST(COUNT(*) AS bigint) AS sessions,
  CAST(SUM(y.is_user_process) AS bigint) AS user_sessions,
  CAST(SUM(1 - y.is_user_process) AS bigint) AS system_sessions,
  CAST(SUM(CASE WHEN y.status = N'running' THEN 1 ELSE 0 END) AS bigint) AS running,
  CAST(SUM(CASE WHEN y.status = N'sleeping' THEN 1 ELSE 0 END) AS bigint) AS sleeping,
  CAST(SUM(CASE WHEN y.status = N'dormant' THEN 1 ELSE 0 END) AS bigint) AS dormant,
  CAST(SUM(1 - y.is_user_process) AS bigint) AS background,
  CAST(SUM(CASE WHEN y.status = N'sleeping' AND y.is_user_process = 1
                 AND y.last_request_end_time < DATEADD(MINUTE, -30, SYSDATETIME()) THEN 1 ELSE 0 END) AS bigint) AS idle_30min,
  CAST(COUNT(DISTINCT y.database_id) AS bigint) AS databases,
  SUM(CAST(y.cpu_time AS bigint)) AS cpu_ms, SUM(CAST(y.reads AS bigint)) AS reads, SUM(CAST(y.writes AS bigint)) AS writes,
  SUM(CAST(y.logical_reads AS bigint)) AS logical_reads,
  CONVERT(varchar(33), DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), MAX(y.login_time)), 126) + 'Z' AS newest_login
FROM y
GROUP BY GROUPING SETS ((y.gp), (y.gh), (y.gd), (), (y.lg_o, y.lg_k), (y.st), (y.itf_o, y.itf_k), (y.addr_o, y.addr_k), (y.iso))
OPTION (RECOMPILE)`

// activityTempdbSQL: the sessions holding tempdb (sp_PressureDetector's allocations and current pages, in KB), the 20
// largest by allocations; the last request's end in UTC.
const activityTempdbSQL = `SELECT TOP (20) 'tempdb' AS kind, u.session_id,
  CAST(SUM(u.ua + u.ia) * 8 AS bigint) AS alloc_kb,
  CAST(SUM(u.ua + u.ia - u.ud - u.id) * 8 AS bigint) AS current_kb,
  CAST(SUM(u.ua - u.ud) * 8 AS bigint) AS user_kb,
  CAST(SUM(u.ia - u.id) * 8 AS bigint) AS internal_kb,
  CAST(SUM(CASE WHEN u.task = 1 THEN u.ua + u.ia ELSE 0 END) * 8 AS bigint) AS task_alloc_kb,
  CAST(SUM(CASE WHEN u.task = 1 THEN u.ua + u.ia - u.ud - u.id ELSE 0 END) * 8 AS bigint) AS task_current_kb,
  CAST(MAX(s.login_name) AS nvarchar(128)) AS login_name, CAST(MAX(s.program_name) AS nvarchar(128)) AS program_name,
  CAST(MAX(s.host_name) AS nvarchar(128)) AS host_name, CAST(MAX(s.status) AS nvarchar(30)) AS status,
  MAX(s.open_transaction_count) AS open_tran,
  CONVERT(varchar(33), DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), MAX(s.last_request_end_time)), 126) + 'Z' AS last_request_end
FROM (SELECT t.session_id, 1 AS task, CAST(t.user_objects_alloc_page_count AS bigint) AS ua, CAST(t.internal_objects_alloc_page_count AS bigint) AS ia,
             CAST(t.user_objects_dealloc_page_count AS bigint) AS ud, CAST(t.internal_objects_dealloc_page_count AS bigint) AS id
        FROM sys.dm_db_task_space_usage t
      UNION ALL
      SELECT s2.session_id, 0, s2.user_objects_alloc_page_count, s2.internal_objects_alloc_page_count,
             s2.user_objects_dealloc_page_count, s2.internal_objects_dealloc_page_count
        FROM sys.dm_db_session_space_usage s2) u
LEFT JOIN sys.dm_exec_sessions s ON s.session_id = u.session_id
WHERE u.session_id > 50
GROUP BY u.session_id
HAVING SUM(u.ua + u.ia) > 0
ORDER BY SUM(u.ua + u.ia) DESC`

// cpuInfoColumns: sp_PressureDetector's CPU details, in its order; a server lists only those sys.dm_os_sys_info has.
var cpuInfoColumns = []string{"socket_count", "numa_node_count", "cpu_count", "cores_per_socket", "hyperthread_ratio",
	"softnuma_configuration_desc", "scheduler_total_count", "scheduler_count"}

const cpuInfoColumnsSQL = `SELECT CAST(ac.name AS nvarchar(128)) AS name FROM sys.all_columns ac
WHERE ac.object_id = OBJECT_ID(N'sys.dm_os_sys_info')
  AND ac.name IN (N'socket_count', N'numa_node_count', N'cpu_count', N'cores_per_socket', N'hyperthread_ratio',
                  N'softnuma_configuration_desc', N'scheduler_total_count', N'scheduler_count')`

func (activityCollector) Run(ctx context.Context, conn *sql.Conn, _ Info) ([]collect.Row, error) {
	out, err := QueryRows(ctx, conn, perfStateSQL)
	if err != nil {
		return nil, err
	}
	sessions, err := QueryRows(ctx, conn, activitySessionsSQL)
	if err != nil {
		return nil, err
	}
	out = append(out, activityRows(sessions)...)
	apart := func(source, q string, keep func([]collect.Row) []collect.Row) {
		rows, err := QueryRows(ctx, conn, q)
		if err != nil {
			out = append(out, collect.Row{"kind": "collector_error", "source": source, "message": err.Error()})
			return
		}
		out = append(out, keep(rows)...)
	}
	apart("sys.dm_db_session_space_usage", activityTempdbSQL, func(r []collect.Row) []collect.Row { return r })
	// the per-database counters are mssql_counters_db's (task 401): one writer per series
	if q, err := cpuInfoSQL(ctx, conn); err != nil {
		out = append(out, collect.Row{"kind": "collector_error", "source": "sys.dm_os_sys_info", "message": err.Error()})
	} else if q != "" {
		apart("sys.dm_os_sys_info", q, func(r []collect.Row) []collect.Row { return r })
	}
	return out, nil
}

// activityRows keeps the totals row, the group rows with a name (a program, host or database group's NULL key holds
// the sessions that are not counted per group) and every 'session_by' row (its NULL name is a bucket of its own: the
// sessions without a connection, an address or a login).
func activityRows(rows []collect.Row) []collect.Row {
	out := make([]collect.Row, 0, len(rows))
	for _, r := range rows {
		if r["kind"] != "session_by" && r["grp"] != "total" && r["name"] == nil {
			continue
		}
		out = append(out, r)
	}
	return out
}

// cpuInfoSQL builds sp_PressureDetector's CPU details select from the columns this server's sys.dm_os_sys_info has;
// none = no statement.
func cpuInfoSQL(ctx context.Context, conn *sql.Conn) (string, error) {
	rows, err := QueryRows(ctx, conn, cpuInfoColumnsSQL)
	if err != nil {
		return "", err
	}
	return cpuInfoSelect(rows), nil
}

func cpuInfoSelect(rows []collect.Row) string {
	have := map[string]bool{}
	for _, r := range rows {
		if n, ok := r["name"].(string); ok {
			have[n] = true
		}
	}
	var cols []string
	for _, c := range cpuInfoColumns {
		if !have[c] {
			continue
		}
		if c == "softnuma_configuration_desc" {
			cols = append(cols, "CAST(osi."+c+" AS nvarchar(60)) AS "+c)
		} else {
			cols = append(cols, "CAST(osi."+c+" AS bigint) AS "+c)
		}
	}
	if len(cols) == 0 {
		return ""
	}
	return "SELECT 'cpuinfo' AS kind, " + strings.Join(cols, ", ") + " FROM sys.dm_os_sys_info AS osi"
}
