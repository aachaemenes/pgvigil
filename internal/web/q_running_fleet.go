package web

import (
	"fmt"
	"net/http"
	"time"
)

// The fleet's Running queries page and the snapshot steps of one instance's page.
//
// GET /api/running/fleet (Server.RunningFleet): one row per active instance, both engines, from its NEWEST
// snapshot: how old it is by the repository's clock, the sessions, the blocked ones and the heads of their chains,
// the longest blocked wait, the longest running statement and the oldest open transaction. An instance without a
// snapshot keeps its row with the snapshot empty. Reads activity_summary, activity_sample and query_text
// (PostgreSQL) and mssql_requests_summary and mssql_requests_v (SQL Server).
// GET /api/running/snapshots?instance=<id>[&at=] (Server.RunningSnapshots): the PostgreSQL snapshot shown (the
// newest at or before at), the one before it, the one after it and the newest of all: the Earlier, Later and Latest
// buttons of the instance's page.
//
// The rules of a PostgreSQL row (the same the instance's page draws its chains by):
//   blocked            a session whose wait_event_type is Lock and that names a blocker; no other wait is blocking
//   chain head         a session a blocked one names that is not itself blocked (it holds and does not wait)
//   longest blocked    the age of the oldest blocked statement: pg_stat_activity has no start of a wait, so this is
//                      the most the wait can be (the wait began at or after the statement did)
//   longest statement  the oldest active statement of a client backend, by query_start
//   oldest transaction the oldest xact_start of the snapshot, whatever the session's state
// A SQL Server row takes blocked, heads and the longest wait from the snapshot's own summary (the server measures
// the wait), counts as idle in transaction a session without a request that holds an open transaction, and leaves a
// request whose wait is idle background work (wait_is_benign) out of the longest statement.

// sqlRunningFleet: both engines in one read, the instances with the most blocked sessions first.
const sqlRunningFleet = `
SELECT i.instance_id, i.name AS instance, i.engine, a.snapshot_at,
       extract(epoch FROM now() - a.snapshot_at)::bigint AS age_secs,
       a.total::bigint AS sessions, a.active::bigint AS active, a.idle_in_txn::bigint AS idle_in_txn,
       x.blocked::bigint AS blocked, h.heads::bigint AS heads, x.longest_wait_secs::bigint AS longest_wait_secs,
       l.secs::bigint AS longest_stmt_secs, l.session AS longest_stmt_session, l.statement AS longest_stmt,
       x.oldest_txn_secs::bigint AS oldest_txn_secs
  FROM pgvigil.instances i
  LEFT JOIN LATERAL (SELECT s.snapshot_at, s.total, s.active, s.idle_in_txn
                       FROM pgvigil.activity_summary s
                      WHERE s.instance_id = i.instance_id
                      ORDER BY s.snapshot_at DESC LIMIT 1) a ON true
  LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE s.wait_event_type = 'Lock' AND cardinality(s.blocking_pids) > 0) AS blocked,
                            floor(max(extract(epoch FROM s.snapshot_at - s.query_start))
                                  FILTER (WHERE s.wait_event_type = 'Lock' AND cardinality(s.blocking_pids) > 0)) AS longest_wait_secs,
                            floor(max(extract(epoch FROM s.snapshot_at - s.xact_start))) AS oldest_txn_secs
                       FROM pgvigil.activity_sample s
                      WHERE s.instance_id = i.instance_id AND s.snapshot_at = a.snapshot_at) x ON a.snapshot_at IS NOT NULL
  LEFT JOIN LATERAL (SELECT count(DISTINCT b.pid) AS heads
                       FROM pgvigil.activity_sample w
                      CROSS JOIN LATERAL unnest(w.blocking_pids) AS b(pid)
                      WHERE w.instance_id = i.instance_id AND w.snapshot_at = a.snapshot_at
                        AND w.wait_event_type = 'Lock'
                        AND NOT EXISTS (SELECT 1 FROM pgvigil.activity_sample o
                                         WHERE o.instance_id = w.instance_id AND o.snapshot_at = w.snapshot_at AND o.pid = b.pid
                                           AND o.wait_event_type = 'Lock' AND cardinality(o.blocking_pids) > 0)) h ON a.snapshot_at IS NOT NULL
  LEFT JOIN LATERAL (SELECT floor(extract(epoch FROM s.snapshot_at - s.query_start)) AS secs, s.pid AS session,
                            left(q.query, 4000) AS statement
                       FROM pgvigil.activity_sample s
                       LEFT JOIN pgvigil.query_text q ON q.query_hash = s.query_hash
                      WHERE s.instance_id = i.instance_id AND s.snapshot_at = a.snapshot_at
                        AND s.state = 'active' AND s.query_start IS NOT NULL
                        AND coalesce(s.backend_type, 'client backend') = 'client backend'
                      ORDER BY s.query_start, s.pid LIMIT 1) l ON a.snapshot_at IS NOT NULL
 WHERE i.is_active AND i.engine <> 'sqlserver'
UNION ALL
SELECT i.instance_id, i.name, i.engine, m.snapshot_at,
       extract(epoch FROM now() - m.snapshot_at)::bigint,
       m.sessions::bigint, m.requests::bigint, r.idle_in_txn::bigint,
       m.blocked::bigint, m.heads::bigint, floor(m.longest_wait_ms / 1000.0)::bigint,
       floor(l.elapsed_ms / 1000.0)::bigint, l.session_id, l.statement,
       floor(r.oldest_tran_ms / 1000.0)::bigint
  FROM pgvigil.instances i
  LEFT JOIN LATERAL (SELECT s.snapshot_at, s.sessions, s.requests, s.blocked, s.heads, s.longest_wait_ms
                       FROM pgvigil.mssql_requests_summary s
                      WHERE s.instance_id = i.instance_id
                      ORDER BY s.snapshot_at DESC LIMIT 1) m ON true
  LEFT JOIN LATERAL (SELECT count(DISTINCT q.session_id) FILTER (WHERE q.request_id IS NULL AND q.open_tran > 0) AS idle_in_txn,
                            max(q.tran_age_ms) AS oldest_tran_ms
                       FROM pgvigil.mssql_requests_v q
                      WHERE q.instance_id = i.instance_id AND q.snapshot_at = m.snapshot_at) r ON m.snapshot_at IS NOT NULL
  LEFT JOIN LATERAL (SELECT q.elapsed_ms, q.session_id, left(q.statement, 4000) AS statement
                       FROM pgvigil.mssql_requests_v q
                      WHERE q.instance_id = i.instance_id AND q.snapshot_at = m.snapshot_at
                        AND q.request_id IS NOT NULL AND NOT q.wait_is_benign AND q.elapsed_ms IS NOT NULL
                      ORDER BY q.elapsed_ms DESC, q.session_id LIMIT 1) l ON m.snapshot_at IS NOT NULL
 WHERE i.is_active AND i.engine = 'sqlserver'
 ORDER BY 9 DESC NULLS LAST, 11 DESC NULLS LAST, 2
 LIMIT 5000`

// RunningFleet serves /api/running/fleet.
func (s *Server) RunningFleet(w http.ResponseWriter, r *http.Request) {
	s.multiPart(w, r, []part{{"rows", sqlRunningFleet, nil}})
}

// sqlRunningSnapshots: the snapshot shown and its neighbours, all from the primary key of activity_summary.
const sqlRunningSnapshots = `
SELECT c.shown,
       (SELECT max(s.snapshot_at) FROM pgvigil.activity_summary s WHERE s.instance_id = $1 AND s.snapshot_at < c.shown) AS earlier,
       (SELECT min(s.snapshot_at) FROM pgvigil.activity_summary s WHERE s.instance_id = $1 AND s.snapshot_at > c.shown) AS later,
       (SELECT max(s.snapshot_at) FROM pgvigil.activity_summary s WHERE s.instance_id = $1) AS latest
  FROM (SELECT max(s.snapshot_at) AS shown FROM pgvigil.activity_summary s
         WHERE s.instance_id = $1 AND ($2::timestamptz IS NULL OR s.snapshot_at <= $2)) c`

// RunningSnapshots serves /api/running/snapshots.
func (s *Server) RunningSnapshots(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var at *time.Time
	if v := r.URL.Query().Get("at"); v != "" {
		x, err := time.Parse(time.RFC3339, v)
		if err != nil {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("at: %w", err))
			return
		}
		at = &x
	}
	s.multiPart(w, r, []part{{"steps", sqlRunningSnapshots, []any{id, at}}})
}
