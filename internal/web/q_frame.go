package web

import (
	"encoding/json"
	"net/http"
)

// The frame's own reads (task 152, K09.01 and K09.03): the footer's status line on every page, and the marks and limits
// a chart of one instance draws over its time axis. Routes, wired in Handler:
//   GET /api/frame/status -> s.FrameStatus: one row - the active instances by engine; the collections' last runs as
//       healthy, failing, stale, not collected (skipped) and no permission (a failure or a skip that names a missing
//       right, counted apart from the rest); the repository database's size; whether this server writes the UI's own
//       rows (acknowledgements, through the actions door's audit login) and whether the actions door is on; the newest
//       healthy read; the repository's clock.
//   GET /api/frame/events?instance=<id>[&from=..&to=..] -> s.FrameEvents: events, the moments a chart marks inside the
//       window (newest first, at most frameEventCap of each kind): 'setting' (a setting's value changed: PostgreSQL's
//       instance_setting_history, SQL Server's mssql_config_history past its first read), 'restart' (the instance's
//       start as its newest read names it: postmaster_start, SQL Server's started_at), 'failover' (an availability
//       group's new primary, mssql_ag_failovers), task 404's events (0155's instance_event_list: every 'restart',
//       'failover', 'crash restart' and 'build' change seen between two reads) and 'deadlock' (PostgreSQL's server log, SQL Server's deadlock
//       events); each with the tab of the page that holds its rows and of_kind, the window's count of its kind (above
//       the cap the page says 'the newest 200 of n'). limits: the server limits a chart may draw as a line, by name
//       (max_connections), as the newest read before the window's end holds them.

// frameEventCap bounds each kind of mark a window returns (a 31-day window of a deadlock storm would draw a wall).
const frameEventCap = 200

// noPermission is the case-insensitive pattern of a collection note that names a missing right: such a collection is
// counted apart (it needs a grant, not a fix).
const noPermission = `permission denied|must be superuser|must be a member|insufficient privilege|not authorized|VIEW SERVER STATE|VIEW DATABASE STATE|denied`

// FrameStatus is the footer's one row.
func (s *Server) FrameStatus(w http.ResponseWriter, r *http.Request) {
	exp, err := json.Marshal(s.expectedNow())
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	actions := "on"
	if s.actions == nil || s.actions.off != "" {
		actions = "off"
	}
	// the UI's own writes (acknowledgements, alert rules' edits) go through the actions door's audit login: the serve
	// pool itself is read only (default_transaction_read_only), so the seat is the door's state, never the pool's
	// the demo's write door (demodoor.go): its user where one stands, empty on every serve - the footer says once whose
	// door this is; repository_writes stays the serve's own seat
	door := ""
	if s.demo != nil {
		door = doorUser
	}
	t, err := s.query(r.Context(), sqlFrameStatus, string(exp), DefaultStaleSecs, noPermission, actions, s.ackOff() == "", door)
	s.reply(w, r, t, err)
}

// sqlFrameStatus: $1 the stale check's expectations (a collection disabled or gated off for an instance, 0, is
// counted nowhere), $2 the default stale age, $3 the no-permission pattern, $4 the actions door ('on' | 'off'), $6 the demo door's user (empty on a serve), $5
// whether this server writes the UI's own rows (ackOff: the login on, the door's audit login connected).
// A collection is one of: no_permission (an error or skip whose note names a missing right), failing (another
// error), not_collected (another skip: the collection does not apply there), stale (ok but older than its interval
// allows, the overview's rule), healthy (ok and fresh).
const sqlFrameStatus = `
WITH c AS (
  SELECT c.status, c.note, c.snapshot_at,
         coalesce(($1::jsonb -> 'instances' -> i.name ->> c.collection)::int, ($1::jsonb -> 'defaults' ->> c.collection)::int) AS iv
    FROM pgvigil.collection_dates c JOIN pgvigil.instances i USING (instance_id)
   WHERE i.is_active
), k AS (
  SELECT CASE WHEN status <> 'ok' AND coalesce(note, '') ~* $3 THEN 'no_permission'
              WHEN status = 'error' THEN 'failing'
              WHEN status <> 'ok' THEN 'not_collected'
              WHEN now() - snapshot_at > make_interval(secs => CASE WHEN iv IS NULL THEN $2::int ELSE greatest(300, 3 * iv) END) THEN 'stale'
              ELSE 'healthy' END AS state, snapshot_at, status
    FROM c WHERE coalesce(iv, -1) <> 0
)
SELECT (SELECT count(*) FROM pgvigil.instances WHERE is_active) AS instances,
       (SELECT count(*) FROM pgvigil.instances WHERE is_active AND engine = 'postgres') AS postgres,
       (SELECT count(*) FROM pgvigil.instances WHERE is_active AND engine = 'sqlserver') AS sqlserver,
       count(*) FILTER (WHERE state = 'healthy') AS healthy,
       count(*) FILTER (WHERE state = 'failing') AS failing,
       count(*) FILTER (WHERE state = 'stale') AS stale,
       count(*) FILTER (WHERE state = 'not_collected') AS not_collected,
       count(*) FILTER (WHERE state = 'no_permission') AS no_permission,
       max(snapshot_at) FILTER (WHERE status = 'ok') AS newest_read,
       pg_database_size(current_database()) AS repository_bytes,
       $5::boolean AS repository_writes,
       $4::text AS actions,
       $6::text AS door,
       now() AS server_now
  FROM k`

// FrameEvents is one instance's marks and limits over the window.
func (s *Server) FrameEvents(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{
		{"events", sqlFrameEvents, []any{id, from, to, frameEventCap}},
		{"limits", sqlFrameLimits, []any{id, to}},
	})
}

// sqlFrameEvents: $1 the instance, $2 / $3 the window (from exclusive, to inclusive, as every page reads), $4 the cap
// per kind. label is the mark's words; tab the page of its rows (router.ts tab keys of the instance's engine).
const sqlFrameEvents = `
SELECT at, kind, label, tab, of_kind FROM (
  SELECT at, kind, label, tab, row_number() OVER (PARTITION BY kind ORDER BY at DESC) AS n, count(*) OVER (PARTITION BY kind) AS of_kind FROM (
    SELECT h.changed_at AS at, 'setting' AS kind,
           h.name || ': ' || coalesce(h.old_value, '(default)') || ' -> ' || coalesce(h.new_value, '(default)') AS label, 'config' AS tab
      FROM pgvigil.instance_setting_history h
     WHERE h.instance_id = $1 AND h.changed_at > $2 AND h.changed_at <= $3
    UNION ALL
    SELECT h.valid_from, 'setting',
           h.name || ': ' || coalesce(p.value_in_use::text, '?') || ' -> ' || coalesce(h.value_in_use::text, '?'), 'mssqlconfig'
      FROM pgvigil.mssql_config_history h
      LEFT JOIN pgvigil.mssql_config_history p ON p.instance_id = h.instance_id AND p.name = h.name AND p.valid_to = h.valid_from
     WHERE h.instance_id = $1 AND NOT h.first_read AND h.valid_from > $2 AND h.valid_from <= $3
    UNION ALL
    -- the newest start where no restart or failover of 0155 was seen since it (an instance first read after it started;
    -- a failover onto a node up for days is dated at the read, its node's start is not marked again: 404 review A, 1 and 3;
    -- 120 s below the start, as 0155's tolerance, so a clock step after a quick read does not mark it again: review B, 10)
    SELECT st.postmaster_start, 'restart', 'PostgreSQL started', 'summary'
      FROM pgvigil.instance_state st
     WHERE st.instance_id = $1 AND st.postmaster_start > $2 AND st.postmaster_start <= $3
       AND NOT EXISTS (SELECT 1 FROM pgvigil.instance_events e WHERE e.instance_id = $1 AND e.kind IN ('restart', 'failover') AND e.seen_at >= st.postmaster_start - interval '120 seconds')
    UNION ALL
    SELECT m.started_at, 'restart', 'SQL Server started', 'summary'
      FROM pgvigil.mssql_instance m
     WHERE m.instance_id = $1 AND m.started_at > $2 AND m.started_at <= $3
       AND NOT EXISTS (SELECT 1 FROM pgvigil.instance_events e WHERE e.instance_id = $1 AND e.kind IN ('restart', 'failover') AND e.seen_at >= m.started_at - interval '120 seconds')
    UNION ALL
    -- task 404 (0155): each restart, failover, crash restart and build change seen between two reads
    -- a PostgreSQL build is the Versions tab's (version_history); an availability group's failover is marked once, by
    -- mssql_ag_failovers (its hadr read may come up to 15 minutes after the instance read that saw the new node)
    SELECT e.at, e.kind, pgvigil.instance_event_words(e.kind, i.engine, e.old_value, e.new_value),
           CASE WHEN e.kind = 'build' AND i.engine = 'postgres' THEN 'versions' ELSE 'summary' END
      FROM pgvigil.instance_event_list e
      JOIN pgvigil.instances i ON i.instance_id = e.instance_id
     WHERE e.instance_id = $1 AND e.at > $2 AND e.at <= $3
       AND NOT (e.kind = 'failover' AND EXISTS (SELECT 1 FROM pgvigil.mssql_ag_failovers f WHERE f.instance_id = $1
                  AND f.at > coalesce(e.prev_at, e.seen_at - interval '1 hour') AND f.at <= e.seen_at + interval '15 minutes'))
    UNION ALL
    SELECT f.at, 'failover', f.group_name || ': ' || f.old_primary || ' -> ' || f.new_primary, 'availability'
      FROM pgvigil.mssql_ag_failovers f
     WHERE f.instance_id = $1 AND f.at > $2 AND f.at <= $3
    UNION ALL
    SELECT e.snapshot_at, 'deadlock', 'deadlock' || coalesce(' in ' || e.datname, ''), 'logs'
      FROM pgvigil.log_events e
     WHERE e.instance_id = $1 AND e.kind = 'deadlock' AND e.snapshot_at > $2 AND e.snapshot_at <= $3
    UNION ALL
    SELECT d.event_at, 'deadlock', 'deadlock, ' || coalesce(d.process_count::text || ' processes', 'processes not read'), 'mssql_deadlocks'
      FROM pgvigil.mssql_deadlocks d
     WHERE d.instance_id = $1 AND d.event_at > $2 AND d.event_at <= $3
  ) x
) y WHERE n <= $4
 ORDER BY at`

// sqlFrameLimits: $1 the instance, $2 the window's end. One row per limit the newest read before the end holds.
const sqlFrameLimits = `
SELECT 'max_connections' AS name, a.max_connections::float8 AS value
  FROM (SELECT max_connections FROM pgvigil.activity_summary
         WHERE instance_id = $1 AND snapshot_at <= $2 AND max_connections IS NOT NULL
         ORDER BY snapshot_at DESC LIMIT 1) a`
