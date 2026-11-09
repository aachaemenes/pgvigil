package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// activityCollector is the running-queries snapshot: every minute, the sessions
// that are active or idle in a transaction (with their statement, wait and, for
// a Lock waiter, the pids that block it) plus one summary row counting every
// client session by state. Idle sessions are counted, not stored: their last
// statement is only interesting when it was long, and that is the history
// sampler's job, not a one-minute poll.
//
// Semantics follow the house whoisactive rules: only wait_event_type = 'Lock'
// is blocking; pg_blocking_pids is called for Lock waiters only; an idle-in-
// transaction session still holds its locks and pins xmin; a parallel worker
// folds into its leader_pid.
type activityCollector struct{}

func init() { Register(activityCollector{}) }

func (activityCollector) Name() string                   { return "activity" }
func (activityCollector) DefaultInterval() time.Duration { return time.Minute }
func (activityCollector) Applies(info platform.Info) (bool, string) {
	if info.ServerVersionNum < 130000 {
		return false, "needs PostgreSQL 13 or later (leader_pid)"
	}
	return true, ""
}

// sessionsSQL stores active and idle-in-transaction client backends, plus every
// backend some Lock waiter names in pg_blocking_pids (an idle holder of an
// advisory lock, an autovacuum worker, a parallel worker), so a chain's head is
// always in the snapshot. query_id exists from PostgreSQL 14; the %s is
// 'a.query_id' or 'NULL::bigint'.
const sessionsSQL = `
WITH blockers AS (
  SELECT DISTINCT b AS pid
    FROM pg_stat_activity w, unnest(pg_blocking_pids(w.pid)) b
   WHERE w.wait_event_type = 'Lock' AND w.pid <> pg_backend_pid()
)
SELECT 'session'                                              AS kind,
       a.pid,
       a.backend_start,
       a.datname::text                                        AS datname,
       a.usename::text                                        AS usename,
       a.application_name,
       coalesce(a.client_hostname, host(a.client_addr))       AS client,
       a.state,
       a.wait_event_type,
       a.wait_event,
       a.xact_start,
       a.query_start,
       a.state_change,
       (a.backend_xid IS NOT NULL)                            AS xid_assigned,
       age(a.backend_xmin)                                    AS backend_xmin_age,
       CASE WHEN a.wait_event_type = 'Lock' THEN pg_blocking_pids(a.pid) END AS blocking_pids,
       a.leader_pid,
       %s                                                     AS query_id,
       hashtextextended(a.query, 0)                           AS query_hash,
       a.query,
       a.backend_type,
       (a.pid IN (SELECT pid FROM blockers))                  AS is_blocker
  FROM pg_stat_activity a
 WHERE a.pid <> pg_backend_pid()
   AND ( (a.backend_type = 'client backend'
          AND a.state IN ('active', 'idle in transaction', 'idle in transaction (aborted)'))
         OR a.pid IN (SELECT pid FROM blockers) )`

// summarySQL counts every client session once per snapshot.
const summarySQL = `
SELECT 'summary'                                                               AS kind,
       count(*)                                                                AS total,
       count(*) FILTER (WHERE state = 'active')                                AS active,
       count(*) FILTER (WHERE state = 'idle')                                  AS idle,
       count(*) FILTER (WHERE state = 'idle in transaction')                   AS idle_in_txn,
       count(*) FILTER (WHERE state = 'idle in transaction (aborted)')         AS idle_in_txn_aborted,
       count(*) FILTER (WHERE wait_event_type = 'Lock')                        AS waiting_lock,
       count(*) FILTER (WHERE state = 'active' AND wait_event_type = 'Client') AS active_client_wait,
       coalesce(max(extract(epoch FROM clock_timestamp() - query_start)) FILTER (WHERE state = 'active'), 0)::int AS longest_active_secs,
       coalesce(max(extract(epoch FROM clock_timestamp() - state_change)) FILTER (WHERE state LIKE 'idle in transaction%'), 0)::int AS longest_idle_txn_secs,
       coalesce(max(age(backend_xmin)), 0)                                     AS oldest_xmin_age,
       current_setting('max_connections')::int                                AS max_connections
  FROM pg_stat_activity
 WHERE pid <> pg_backend_pid()
   AND backend_type = 'client backend'`

func (activityCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	queryID := "NULL::bigint"
	if info.ServerVersionNum >= 140000 {
		queryID = "a.query_id"
	}
	rows, err := conn.Query(ctx, fmt.Sprintf(sessionsSQL, queryID))
	if err != nil {
		return nil, fmt.Errorf("sessions: %w", err)
	}
	out, err := rowsToMaps(rows)
	if err != nil {
		return nil, fmt.Errorf("sessions: %w", err)
	}
	srows, err := conn.Query(ctx, summarySQL)
	if err != nil {
		return nil, fmt.Errorf("summary: %w", err)
	}
	summary, err := rowsToMaps(srows)
	if err != nil {
		return nil, fmt.Errorf("summary: %w", err)
	}
	return append(out, summary...), nil
}
