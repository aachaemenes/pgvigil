package web

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
)

// The Collection dates page (DBA Dash's Checks > Collection Dates, the page its Summary's Collection cell opens) and
// the Summary's Uptime dialog (DBA Dash's Instance Uptime threshold dialog), task 176b.

// sqlCollectionDates: one row per instance and collection: the last run (collection_dates keeps one per pair), how
// it ended, its age, the schedule (the collection's interval, as the daily checks read it: $1 = {"defaults":
// {collection: secs}, "instances": {name: {collection: secs}}}, 0 = disabled there), the age the daily check
// 'collection stale' calls stale (three intervals, at least 300 s; $2 when no interval is known), the next run, the
// last error kept in collection_log, and the status DBA Dash's page gives: critical (the last run failed), warning
// (stale), ok, or disabled. $3 the instance (0 = any), $4 the folder's instances.
const sqlCollectionDates = `
WITH c AS (
  SELECT c.instance_id, i.name AS instance, i.engine, c.collection, c.status AS last_status, c.snapshot_at, c.duration_ms, c.note,
         coalesce(($1::jsonb -> 'instances' -> i.name ->> c.collection)::int, ($1::jsonb -> 'defaults' ->> c.collection)::int) AS interval_secs
    FROM pgvigil.collection_dates c
    JOIN pgvigil.instances i ON i.instance_id = c.instance_id AND i.is_active
   WHERE ($3::int = 0 OR c.instance_id = $3) AND ($4::int[] IS NULL OR c.instance_id = ANY ($4))
)
SELECT c.instance_id, c.instance, c.engine, c.collection,
       CASE WHEN c.interval_secs = 0 THEN 'disabled'
            WHEN c.last_status = 'error' THEN 'critical'
            WHEN now() - c.snapshot_at > make_interval(secs => CASE WHEN c.interval_secs IS NULL THEN $2::int ELSE greatest(300, 3 * c.interval_secs) END) THEN 'warning'
            ELSE 'ok' END AS status,
       c.last_status, c.snapshot_at, greatest(0, extract(epoch FROM now() - c.snapshot_at))::bigint AS age_secs,
       c.interval_secs, CASE WHEN c.interval_secs IS NULL THEN $2::int ELSE greatest(300, 3 * c.interval_secs) END AS stale_secs,
       CASE WHEN c.interval_secs > 0 THEN c.snapshot_at + make_interval(secs => c.interval_secs) END AS next_run,
       CASE WHEN c.last_status = 'ok' THEN c.snapshot_at END AS last_success,
       e.last_error_at, c.duration_ms, c.note
  FROM c
  LEFT JOIN (SELECT l.instance_id, l.collection, max(l.snapshot_at) AS last_error_at
               FROM pgvigil.collection_log l
              WHERE l.status = 'error' AND ($3::int = 0 OR l.instance_id = $3) AND ($4::int[] IS NULL OR l.instance_id = ANY ($4))
              GROUP BY l.instance_id, l.collection) e ON e.instance_id = c.instance_id AND e.collection = c.collection
 ORDER BY CASE WHEN c.interval_secs = 0 THEN 4 WHEN c.last_status = 'error' THEN 1
               WHEN now() - c.snapshot_at > make_interval(secs => CASE WHEN c.interval_secs IS NULL THEN $2::int ELSE greatest(300, 3 * c.interval_secs) END) THEN 2
               ELSE 3 END, c.instance, c.collection`

// CollectionDates is GET /api/collectiondates[?instance=N|?instances=..].
func (s *Server) CollectionDates(w http.ResponseWriter, r *http.Request) {
	id, ids, err := storageScope(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	exp, err := json.Marshal(s.expected)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	s.multiPart(w, r, []part{
		{"collections", sqlCollectionDates, []any{string(exp), DefaultStaleSecs, id, ids}},
	})
}

// sqlUptime: what the Uptime dialog shows for one instance of either engine: its name, its start time (a PostgreSQL
// instance's postmaster start, a SQL Server instance's sqlserver_start_time), the uptime threshold in force
// (pg_threshold: the instance's own, a tag's, the root's, else DBA Dash's default) and where it was set, the
// instance's own row if it has one, and the key's built-in default and limit.
const sqlUptime = `
SELECT i.instance_id, i.name AS instance, i.engine,
       CASE WHEN i.engine = 'sqlserver' THEN (SELECT m.started_at FROM pgvigil.mssql_instance m WHERE m.instance_id = i.instance_id)
            ELSE (SELECT st.postmaster_start FROM pgvigil.instance_state st WHERE st.instance_id = i.instance_id) END AS started_at,
       t.warn, t.crit, t.level, t.tag,
       o.warn AS own_warn, o.crit AS own_crit, o.threshold_id AS own_id, o.created_by AS own_by, o.created_at AS own_at,
       k.warn_default, k.crit_default, k.max_value, k.unit, k.label
  FROM pgvigil.instances i
  CROSS JOIN LATERAL pgvigil.pg_threshold(i.instance_id, 'uptime') t
  JOIN pgvigil.pg_threshold_keys k ON k.key = 'uptime'
  LEFT JOIN pgvigil.pg_thresholds o ON o.ended_at IS NULL AND o.key = 'uptime' AND o.level = 'instance' AND o.instance_id = i.instance_id
 WHERE i.instance_id = $1 AND i.is_active`

// Uptime is GET /api/uptime?instance=N.
func (s *Server) Uptime(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.URL.Query().Get("instance"))
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
		return
	}
	s.multiPart(w, r, []part{{"uptime", sqlUptime, []any{id}}})
}
