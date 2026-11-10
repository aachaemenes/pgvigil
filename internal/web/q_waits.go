package web

import (
	"net/http"
)

// The Waits tab (task 41): GET /api/waits?instance=<id>&[from=&to=] (Server.Waits). Where pg_wait_sampling (or Azure's
// pgms_wait_sampling) is installed the numbers are its samples (wait_sample, 0030: one sample per backend every
// profile period, 10 ms by default, so wait_secs is time); elsewhere they are the activity samples (one look at
// every active session a minute), counted as session samples, with no time. The source rides in every row, so the
// page says which it is. The lock tree is the newest activity snapshot at or before the window's end
// (pgvigil.lock_tree, after postgres_dba's l2_lock_trees.sql). No Summary column: waits are a view, not a check.

// sqlWaitsBase is the window's samples from the best source: the extension's rows when there are any, else the
// activity samples of active sessions. $1 instance, $2 from, $3 to.
const sqlWaitsBase = `
WITH ws AS (
  SELECT w.snapshot_at, w.source, w.event_type, w.event, w.queryid, w.samples, w.wait_secs
    FROM pgvigil.wait_sample w
   WHERE w.instance_id = $1 AND w.snapshot_at > $2 AND w.snapshot_at <= $3
), act AS (
  SELECT a.snapshot_at, 'activity'::text AS source, coalesce(a.wait_event_type, 'CPU') AS event_type,
         coalesce(a.wait_event, 'CPU') AS event, coalesce(a.query_id, 0) AS queryid, 1::bigint AS samples,
         NULL::float8 AS wait_secs, a.query_hash
    FROM pgvigil.activity_sample a
   WHERE a.instance_id = $1 AND a.snapshot_at > $2 AND a.snapshot_at <= $3 AND a.state = 'active'
     AND coalesce(a.backend_type, 'client backend') = 'client backend'
     AND NOT EXISTS (SELECT 1 FROM ws)
), s AS (
  SELECT snapshot_at, source, event_type, event, queryid, samples, wait_secs, NULL::bigint AS query_hash FROM ws
  UNION ALL
  SELECT * FROM act
)`

// sqlWaitsEvents: every wait event in the window with its share of the samples.
const sqlWaitsEvents = sqlWaitsBase + `
SELECT max(source) AS source, event_type, event, sum(samples)::bigint AS samples, sum(wait_secs) AS wait_secs,
       round(100.0 * sum(samples) / nullif(sum(sum(samples)) OVER (), 0), 1) AS pct
  FROM s
 GROUP BY event_type, event
 ORDER BY samples DESC, event_type, event
 LIMIT 100`

// sqlWaitsSeries: the samples per event type over time, in about 120 steps of at least a minute.
const sqlWaitsSeries = sqlWaitsBase + `
, step AS (SELECT greatest(60, extract(epoch FROM $3::timestamptz - $2::timestamptz) / 120)::int AS secs)
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / step.secs) * step.secs) AS snapshot_at, s.event_type,
       sum(s.samples)::bigint AS samples
  FROM s, step
 GROUP BY 1, 2
 ORDER BY 1, 2`

// sqlWaitsQueries: the statements that waited most, with their top wait; text from the statements collection (by
// queryid) or the activity sampler (by its text hash).
const sqlWaitsQueries = sqlWaitsBase + `
, q AS (
  SELECT s.queryid, max(s.query_hash) AS query_hash, sum(s.samples)::bigint AS samples, sum(s.wait_secs) AS wait_secs,
         (array_agg(s.event_type || ':' || s.event ORDER BY s.samples DESC))[1] AS top_wait
    FROM s
   WHERE s.queryid <> 0 OR s.query_hash IS NOT NULL
   GROUP BY s.queryid, CASE WHEN s.queryid = 0 THEN s.query_hash END
)
SELECT q.queryid, q.samples, q.wait_secs, q.top_wait,
       left(coalesce(st.query, qt.query), 2000) AS query
  FROM q
  LEFT JOIN pgvigil.statement_text st ON st.instance_id = $1 AND st.queryid = q.queryid AND q.queryid <> 0
  LEFT JOIN pgvigil.query_text qt ON qt.query_hash = q.query_hash
 ORDER BY q.samples DESC
 LIMIT 50`

// sqlWaitsState: the waits collection's last run on the instance (why it is skipped, where it is).
const sqlWaitsState = `
SELECT c.status, c.note, c.snapshot_at
  FROM pgvigil.collection_dates c
 WHERE c.instance_id = $1 AND c.collection = 'waits'`

// sqlWaitsLockTree: the blocking tree of the newest activity snapshot at or before the window's end.
const sqlWaitsLockTree = `
SELECT l.snapshot_at, l.top_blocker, l.level, l.pid, l.blocked_by, l.blocked, l.state, l.wait, l.xact_start, l.query_start,
       l.state_change, l.datname, l.usename, l.application_name, left(qt.query, 1000) AS query
  FROM pgvigil.lock_tree($1, $2) l
  LEFT JOIN pgvigil.query_text qt ON qt.query_hash = l.query_hash
 ORDER BY l.top_blocker, l.path`

// Waits serves /api/waits.
func (s *Server) Waits(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{
		{"state", sqlWaitsState, []any{id}},
		{"events", sqlWaitsEvents, []any{id, from, to}},
		{"series", sqlWaitsSeries, []any{id, from, to}},
		{"queries", sqlWaitsQueries, []any{id, from, to}},
		{"locktree", sqlWaitsLockTree, []any{id, to}},
	})
}
