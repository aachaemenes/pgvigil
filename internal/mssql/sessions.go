package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// sessionsCollector is mssql_sessions (task 413, B22; SQLWATCH OVW#7, #14, #15, #31, #144 and COL#8): every minute, one
// row of counts for the Connections page's series:
//
//   - sessions by user / system x status: sys.dm_exec_sessions.is_user_process (1 user, 0 system) over ALL sessions,
//     the page's one rule (the lead 11-15 09:4x; not 'session_id > 50'), and a session's own statuses (running,
//     sleeping, dormant, preconnect; anything else 'other');
//   - requests by user / system x status: sys.dm_exec_requests with its session's is_user_process (background,
//     running, runnable, sleeping, suspended; anything else 'other');
//   - the waiting tasks of user sessions (sys.dm_os_waiting_tasks) and the longest of their waits, the benign waits of
//     waits.go left out (a WAITFOR, a broker or a sleep wait is no one waiting on the server).
//
// pgvigil's own sessions (the reading connection's program name, and any 'pgvigil%') are left out of every count and
// counted apart (own_sessions), as activity.go leaves them out of its groups. Rights: VIEW SERVER STATE (other logins'
// sessions). Not on Azure SQL Database (its sessions are the host's), as activity.go.
type sessionsCollector struct{}

func init() { Register(sessionsCollector{}) }

func (sessionsCollector) Name() string                   { return Prefix + "sessions" }
func (sessionsCollector) DefaultInterval() time.Duration { return time.Minute }
func (sessionsCollector) Applies(in Info) (bool, string) {
	return activityCollector{}.Applies(in)
}

// sessionsCountsSQL: the one counts row. A session is pgvigil's own when its program name is the reading connection's
// or starts with 'pgvigil'.
const sessionsCountsSQL = `WITH s AS (
  SELECT s.session_id, CAST(s.is_user_process AS int) AS u, s.status,
         CASE WHEN ISNULL(s.program_name, N'') <> N'' AND (s.program_name = ISNULL(PROGRAM_NAME(), N'') OR s.program_name LIKE N'pgvigil%')
              THEN 1 ELSE 0 END AS own
    FROM sys.dm_exec_sessions s),
r AS (
  SELECT q.status, s.u FROM sys.dm_exec_requests q JOIN s ON s.session_id = q.session_id WHERE s.own = 0)
SELECT 'counts' AS kind,
  (SELECT CAST(COUNT(*) AS int) FROM s WHERE own = 0 AND u = 1 AND status = N'running') AS user_running,
  (SELECT CAST(COUNT(*) AS int) FROM s WHERE own = 0 AND u = 1 AND status = N'sleeping') AS user_sleeping,
  (SELECT CAST(COUNT(*) AS int) FROM s WHERE own = 0 AND u = 1 AND status = N'dormant') AS user_dormant,
  (SELECT CAST(COUNT(*) AS int) FROM s WHERE own = 0 AND u = 1 AND status = N'preconnect') AS user_preconnect,
  (SELECT CAST(COUNT(*) AS int) FROM s WHERE own = 0 AND u = 1 AND status NOT IN (N'running', N'sleeping', N'dormant', N'preconnect')) AS user_other,
  (SELECT CAST(COUNT(*) AS int) FROM s WHERE own = 0 AND u = 0 AND status = N'running') AS system_running,
  (SELECT CAST(COUNT(*) AS int) FROM s WHERE own = 0 AND u = 0 AND status = N'sleeping') AS system_sleeping,
  (SELECT CAST(COUNT(*) AS int) FROM s WHERE own = 0 AND u = 0 AND status = N'dormant') AS system_dormant,
  (SELECT CAST(COUNT(*) AS int) FROM s WHERE own = 0 AND u = 0 AND status = N'preconnect') AS system_preconnect,
  (SELECT CAST(COUNT(*) AS int) FROM s WHERE own = 0 AND u = 0 AND status NOT IN (N'running', N'sleeping', N'dormant', N'preconnect')) AS system_other,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 1 AND status = N'running') AS req_user_running,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 1 AND status = N'runnable') AS req_user_runnable,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 1 AND status = N'suspended') AS req_user_suspended,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 1 AND status = N'sleeping') AS req_user_sleeping,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 1 AND status = N'background') AS req_user_background,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 1 AND status NOT IN (N'running', N'runnable', N'suspended', N'sleeping', N'background')) AS req_user_other,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 0 AND status = N'running') AS req_system_running,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 0 AND status = N'runnable') AS req_system_runnable,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 0 AND status = N'suspended') AS req_system_suspended,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 0 AND status = N'sleeping') AS req_system_sleeping,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 0 AND status = N'background') AS req_system_background,
  (SELECT CAST(COUNT(*) AS int) FROM r WHERE u = 0 AND status NOT IN (N'running', N'runnable', N'suspended', N'sleeping', N'background')) AS req_system_other,
  (SELECT CAST(COUNT(*) AS int) FROM s WHERE own = 1) AS own_sessions`

// sessionsWaitsSQL: the waiting tasks of user sessions (not pgvigil's own) per wait type, with the longest wait; the
// benign waits are taken out in Go (sessionsWaiting), from the same list the waits page uses.
const sessionsWaitsSQL = `SELECT CAST(w.wait_type AS nvarchar(60)) AS wait_type, CAST(COUNT(*) AS int) AS tasks,
  MAX(CAST(w.wait_duration_ms AS bigint)) AS longest_ms
FROM sys.dm_os_waiting_tasks w
JOIN sys.dm_exec_sessions s ON s.session_id = w.session_id
WHERE s.is_user_process = 1
  AND NOT (ISNULL(s.program_name, N'') <> N'' AND (s.program_name = ISNULL(PROGRAM_NAME(), N'') OR s.program_name LIKE N'pgvigil%'))
GROUP BY w.wait_type`

func (sessionsCollector) Run(ctx context.Context, conn *sql.Conn, _ Info) ([]collect.Row, error) {
	counts, err := QueryRows(ctx, conn, sessionsCountsSQL)
	if err != nil {
		return nil, err
	}
	waits, err := QueryRows(ctx, conn, sessionsWaitsSQL)
	if err != nil {
		return nil, err
	}
	if len(counts) == 0 {
		return nil, nil
	}
	row := counts[0]
	row["waiting_tasks"], row["waiting_longest_ms"] = sessionsWaiting(waits)
	return []collect.Row{row}, nil
}

// sessionsWaiting sums the waiting tasks of the wait types that are not benign and takes the longest of their waits.
func sessionsWaiting(rows []collect.Row) (int64, int64) {
	var tasks, longest int64
	for _, r := range rows {
		w, _ := r["wait_type"].(string)
		if benignWaits[w] {
			continue
		}
		tasks += asInt64(r["tasks"])
		longest = max(longest, asInt64(r["longest_ms"]))
	}
	return tasks, longest
}

func asInt64(v any) int64 {
	switch x := v.(type) {
	case int64:
		return x
	case int32:
		return int64(x)
	case int:
		return int64(x)
	case float64:
		return int64(x)
	}
	return 0
}
