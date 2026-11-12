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

// sqlWaitsBase is the window's samples from the best source: the extension's rows when it wrote any in the window, else
// the activity samples of active client sessions. $1 instance, $2 from, $3 to. Left out of the extension's rows, so both
// sources count the same thing (work waiting, not idling): the Activity type (the background processes idling between
// their rounds) and Client:ClientRead without a statement (an idle connection waiting for its next command: the
// extension samples every backend, idle ones included, and a pooled server would read as a hundred sessions waiting).
const sqlWaitsBase = `
WITH raw AS (
  SELECT w.snapshot_at, w.source, w.event_type, w.event, w.queryid, w.samples, w.wait_secs, w.interval_secs
    FROM pgvigil.wait_sample w
   WHERE w.instance_id = $1 AND w.snapshot_at > $2 AND w.snapshot_at <= $3
), ws AS (
  SELECT * FROM raw
   WHERE event_type <> 'Activity' AND NOT (event_type = 'Client' AND event = 'ClientRead' AND queryid = 0)
), act AS (
  SELECT a.snapshot_at, 'activity'::text AS source, coalesce(a.wait_event_type, 'CPU') AS event_type,
         coalesce(a.wait_event, 'CPU') AS event, coalesce(a.query_id, 0) AS queryid, 1::bigint AS samples,
         NULL::float8 AS wait_secs, NULL::int AS interval_secs, a.query_hash
    FROM pgvigil.activity_sample a
   WHERE a.instance_id = $1 AND a.snapshot_at > $2 AND a.snapshot_at <= $3 AND a.state = 'active'
     AND coalesce(a.backend_type, 'client backend') = 'client backend'
     AND NOT EXISTS (SELECT 1 FROM raw)
), s AS (
  SELECT snapshot_at, source, event_type, event, queryid, samples, wait_secs, interval_secs, NULL::bigint AS query_hash FROM ws
  UNION ALL
  SELECT * FROM act
), reads AS (
  -- every read in the window, a quiet one included: the time the samples are spread over
  SELECT DISTINCT snapshot_at, coalesce(interval_secs, 60) AS secs FROM raw
  UNION ALL
  SELECT x.snapshot_at, 60 FROM pgvigil.activity_summary x
   WHERE x.instance_id = $1 AND x.snapshot_at > $2 AND x.snapshot_at <= $3 AND NOT EXISTS (SELECT 1 FROM raw)
)`

// sqlWaitsEvents: every wait event in the window with its share of the samples.
const sqlWaitsEvents = sqlWaitsBase + `
SELECT max(source) AS source, event_type, event, sum(samples)::bigint AS samples, sum(wait_secs) AS wait_secs,
       round(100.0 * sum(samples) / nullif(sum(sum(samples)) OVER (), 0), 1) AS pct
  FROM s
 GROUP BY event_type, event
 ORDER BY samples DESC, event_type, event
 LIMIT 100`

// sqlWaitsSeries: the average sessions waiting per event type over time, in about 120 steps of at least a minute: the
// wait time over the seconds the step's reads cover (pg_wait_sampling; NULL where the period is unknown, a gap in the
// chart), or the sessions seen per read (the activity samples, one a minute). Every read of the step counts in the
// denominator, so a step the reads only partly cover, or a quiet read, does not distort it.
const sqlWaitsSeries = sqlWaitsBase + `
, step AS (SELECT greatest(60, extract(epoch FROM $3::timestamptz - $2::timestamptz) / 120)::int AS secs)
, cover AS (
  SELECT to_timestamp(floor(extract(epoch FROM r.snapshot_at) / step.secs) * step.secs) AS bucket, sum(r.secs)::float8 AS secs
    FROM reads r, step
   GROUP BY 1
)
SELECT c.bucket AS snapshot_at, b.event_type,
       round((CASE WHEN max(b.source) = 'activity' THEN sum(b.samples) * 60.0 / max(c.secs)
                   ELSE sum(b.wait_secs) / max(c.secs) END)::numeric, 3)::float8 AS sessions
  FROM (SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / step.secs) * step.secs) AS bucket, s.*
          FROM s, step) b
  JOIN cover c USING (bucket)
 GROUP BY 1, 2
 ORDER BY 1, 2`

// sqlWaitsQueries: the statements that waited most, with the wait they spent most samples on (summed over the window,
// not the largest single read); text from the statements collection (by queryid) or the activity sampler (its hash).
const sqlWaitsQueries = sqlWaitsBase + `
, e AS (
  SELECT s.queryid, CASE WHEN s.queryid = 0 THEN s.query_hash END AS qh, max(s.query_hash) AS query_hash,
         CASE WHEN s.event_type = 'CPU' THEN 'CPU' ELSE s.event_type || ':' || s.event END AS wait,
         sum(s.samples) AS samples, sum(s.wait_secs) AS wait_secs
    FROM s
   WHERE s.queryid <> 0 OR s.query_hash IS NOT NULL
   GROUP BY 1, 2, 4
), q AS (
  SELECT queryid, max(query_hash) AS query_hash, sum(samples)::bigint AS samples, sum(wait_secs) AS wait_secs,
         (array_agg(wait ORDER BY samples DESC, wait))[1] AS top_wait
    FROM e
   GROUP BY queryid, qh
)
SELECT q.queryid, q.samples, q.wait_secs, q.top_wait,
       left(coalesce(st.query, qt.query), 2000) AS query
  FROM q
  LEFT JOIN pgvigil.statement_text st ON st.instance_id = $1 AND st.queryid = q.queryid AND q.queryid <> 0
  LEFT JOIN pgvigil.query_text qt ON qt.query_hash = q.query_hash
 ORDER BY q.samples DESC, q.queryid
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

// GET /api/mssql/waitfindings?instance=<id>&[from=&to=][&part=...] (Server.MSSQLWaitFindings, task 177 D03): the SQL
// Server Waits tab's findings over its range, in sp_PerfCheck's, sp_BlitzFirst's and sp_Blitz's thresholds and wording
// (0115, pgvigil.mssql_wait_findings_between): the findings, the shares the checks read (the signal ratio with its
// server-information label, SOS_SCHEDULER_YIELD and page latch time as shares of the range, the range's forced grants
// and grant timeouts), the real waits by category, and the grant semaphores of the range's newest memory read with
// each one's forced grants and timeouts over the range.

const sqlMssqlWaitFindings = `
SELECT f.severity, f.check_name, f.object, f.at, f.detail, f.source, f.source_check, f.source_priority, f.value
  FROM pgvigil.mssql_wait_findings_between($1, $2, $3) f
 ORDER BY f.source_priority, f.value DESC NULLS LAST, f.check_name`

const sqlMssqlWaitShares = `SELECT * FROM pgvigil.mssql_wait_shares_between($1, $2, $3)`

const sqlMssqlWaitRollup = `SELECT * FROM pgvigil.mssql_wait_rollup_between($1, $2, $3)`

const sqlMssqlGrantPools = `
SELECT p.snapshot_at, p.pool_id, p.pool_name, p.semaphore_id, p.target_kb, p.max_target_kb, p.total_kb, p.available_kb, p.granted_kb,
       p.used_kb, p.grantees, p.waiters, d.forced_grants, d.timeout_errors
  FROM pgvigil.mssql_memory_pools_at($1, $3) p
  LEFT JOIN pgvigil.mssql_grant_deltas($1, $2, $3) d ON d.pool_id = p.pool_id AND d.semaphore_id = p.semaphore_id
 WHERE p.snapshot_at > $2
 ORDER BY p.pool_id, p.semaphore_id`

// MSSQLWaitFindings serves /api/mssql/waitfindings.
func (s *Server) MSSQLWaitFindings(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"findings", sqlMssqlWaitFindings, []any{id, from, to}},
		{"shares", sqlMssqlWaitShares, []any{id, from, to}},
		{"rollup", sqlMssqlWaitRollup, []any{id, from, to}},
		{"pools", sqlMssqlGrantPools, []any{id, from, to}},
	})
}
