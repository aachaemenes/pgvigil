package web

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
)

// The fleet's SQL Server error stream (SQLMonitor's 'All Servers - Alert History' panels): every error of severity 17
// or more, and every number on its alert list at any severity, across the instances in scope - read from what pgvigil
// already stores, nothing on a monitored server. Two sources: the error log's kept lines (mssql_errorlog, 0091) and
// AlwaysOn_health's error_reported events (mssql_ag_events, 0065); an AlwaysOn_health row whose error-log twin (the same
// instance and number within 2 s, inside the window: a twin outside it is not in the stream) is there is left out, so one
// event is counted once. The noise is the DBA's own:
// acks kind 'noise' with check_key 'error log' (a text, any number) or 'error log:<n>' (that number), an instance or a
// tag optional, matched against the message only - a label with neither a number nor a text hides nothing. They never
// touch an alert: an alert's source and setting are never 'error log'.

// mssqlErrorFleetNumbers is SQLMonitor's alert list beyond the severities (its alert_categories): the Availability Group
// numbers, the corruption numbers and the two configuration changes. They are kept at any severity.
var mssqlErrorFleetNumbers = []int32{1480, 976, 983, 3402, 19406, 35206, 35250, 35264, 35273, 35274, 35275, 35276,
	41091, 41131, 41142, 41406, 41414, 823, 824, 825, 15457, 5084}

// mssqlErrorFleetCannot is a listed number pgvigil keeps no row of, and why (said on the page, not collected).
// Read on SQL Server 2022: an informational message (severity 10; 5084 and 15457 read) is written to the error log
// without its 'Error: n, Severity: s' line, so no stored line carries its number (the instance's Error log page shows
// its text when a search string matches); a message SQL Server does not log (sys.messages is_event_logged 0) is not
// in the error log at all. 1480, 35206, 35264 and 41142 come from the AlwaysOn_health capture (its error_reported
// list), so they are not here.
var mssqlErrorFleetCannot = func() map[int32]string {
	const noNumber = "an informational message (severity 10): SQL Server writes it to the error log without its 'Error: n' line, so no stored line carries the number (the instance's Error log page shows its text when one of the reader's search strings matches), and AlwaysOn_health does not capture it"
	const notLogged = "SQL Server does not write it to the error log (sys.messages is_event_logged 0) and AlwaysOn_health does not capture it"
	m := map[int32]string{}
	for _, n := range []int32{825, 3402, 5084, 15457, 19406, 35273, 35274, 41091, 41131} {
		m[n] = noNumber
	}
	for _, n := range []int32{976, 983, 35250, 41406, 41414} {
		m[n] = notLogged
	}
	return m
}()

// sqlErrorFleetBase is the rows y. $1 from, $2 to, $3 the instance (NULL = any), $4 a folder's instances, $5 a tag,
// $6 one error number (NULL = any), $7 the listed numbers.
const sqlErrorFleetBase = `
WITH scope AS (
  SELECT i.instance_id, i.name, i.tags
    FROM pgvigil.instances i
   WHERE i.engine = 'sqlserver' AND i.is_active
     AND ($3::int IS NULL OR i.instance_id = $3) AND ($4::int[] IS NULL OR i.instance_id = ANY ($4))
     AND ($5::text IS NULL OR $5 = ANY (i.tags))
), lbl AS MATERIALIZED (
  SELECT a.ack_id, a.check_key, a.match_text, a.instance_name, a.tag, a.note,
         coalesce(a.instance_id, (SELECT i.instance_id FROM pgvigil.instances i WHERE i.name = a.instance_name)) AS instance_id,
         CASE WHEN a.check_key ~ '^error log:[0-9]{1,10}$' THEN substring(a.check_key from 11)::bigint END AS num
    FROM pgvigil.acks a
   WHERE a.kind = 'noise' AND (a.check_key = 'error log' OR a.check_key ~ '^error log:[0-9]{1,10}$')
     AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, now())
), x AS (
  SELECT e.log_at AS at, e.instance_id, s.name AS instance, s.tags, e.error_number, e.severity, e.error_state AS state,
         e.class, e.message, 'error log'::text AS source
    FROM pgvigil.mssql_errorlog e
    JOIN scope s ON s.instance_id = e.instance_id
   WHERE e.log_at >= $1 AND e.log_at < $2 AND e.error_number IS NOT NULL AND (e.severity >= 17 OR e.error_number = ANY ($7))
  UNION ALL
  SELECT g.event_at, g.instance_id, s.name, s.tags, g.error_number, g.severity, NULL::int, g.family, g.message, 'AlwaysOn_health'
    FROM pgvigil.mssql_ag_events g
    JOIN scope s ON s.instance_id = g.instance_id
   WHERE g.event_name = 'error_reported' AND g.event_at >= $1 AND g.event_at < $2 AND g.error_number IS NOT NULL
     AND (g.severity >= 17 OR g.error_number = ANY ($7))
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_errorlog t
                      WHERE t.instance_id = g.instance_id AND t.error_number = g.error_number
                        AND t.log_at >= $1 AND t.log_at < $2
                        AND t.log_at BETWEEN g.event_at - interval '2 seconds' AND g.event_at + interval '2 seconds')
), y AS (
  SELECT x.*, n.ack_id AS noise_id, n.note AS noise
    FROM x
    LEFT JOIN LATERAL (
      SELECT l.ack_id, l.note FROM lbl l
       WHERE (l.num IS NOT NULL OR l.match_text IS NOT NULL)   -- a label with neither hides nothing
         AND (l.num IS NULL OR l.num = x.error_number)
         AND (l.instance_name IS NULL OR l.instance_name = x.instance) AND (l.tag IS NULL OR l.tag = ANY (x.tags))
         AND (l.match_text IS NULL OR strpos(lower(coalesce(x.message, '')), lower(l.match_text)) > 0)
       ORDER BY l.ack_id LIMIT 1) n ON true
   WHERE ($6::int IS NULL OR x.error_number = $6)
)`

// sqlErrorFleetByError: one row per number, its counts without the hidden lines (SQLMonitor's 175 leaves its noise
// out), the hidden beside; a number whose every line is hidden only when asked ($8). Severity 20 and more is critical.
const sqlErrorFleetByError = sqlErrorFleetBase + `
SELECT y.error_number, max(y.severity) AS severity,
       count(*) FILTER (WHERE y.noise_id IS NULL)::int AS occurrences,
       count(DISTINCT y.instance_id) FILTER (WHERE y.noise_id IS NULL)::int AS instances,
       min(y.at) FILTER (WHERE y.noise_id IS NULL) AS first_at, max(y.at) FILTER (WHERE y.noise_id IS NULL) AS last_at,
       (array_agg(y.message ORDER BY y.at DESC) FILTER (WHERE y.noise_id IS NULL))[1] AS message,
       nullif(count(*) FILTER (WHERE y.noise_id IS NOT NULL), 0)::int AS hidden
  FROM y
 GROUP BY y.error_number
HAVING $8 OR count(*) FILTER (WHERE y.noise_id IS NULL) > 0
 ORDER BY max(y.severity) DESC NULLS LAST, count(*) FILTER (WHERE y.noise_id IS NULL) DESC, y.error_number`

// sqlErrorFleetLines: every line, newest first; the database as the message names it (database '<name>' or
// "<name>", or database ID <n> with the name the instance's files give it today - an id is reused after a drop).
const sqlErrorFleetLines = sqlErrorFleetBase + `
SELECT y.at, y.instance_id, y.instance, y.error_number, y.severity, y.state, y.class,
       CASE WHEN y.message ~ 'database ''[^'']+''' THEN substring(y.message from 'database ''([^'']+)''')
            WHEN y.message ~ 'database "[^"]+"' THEN substring(y.message from 'database "([^"]+)"')
            WHEN y.message ~ 'database ID [0-9]{1,9}' THEN
              'database ID ' || substring(y.message from 'database ID ([0-9]{1,9})')
              || coalesce(' (now ' || (SELECT f.database_name FROM pgvigil.mssql_files f
                                        WHERE f.instance_id = y.instance_id AND f.database_id = substring(y.message from 'database ID ([0-9]{1,9})')::int
                                        ORDER BY f.is_present DESC, f.snapshot_at DESC LIMIT 1) || ')', '')
       END AS database,
       y.message, y.source, y.noise
  FROM y
 WHERE $8 OR y.noise_id IS NULL
 ORDER BY y.at DESC
 LIMIT 1000`

// sqlErrorFleetNoise: this page's labels and the lines each hides in the window (the stream read once); instance_id
// the instance a label names (its End is offered where a write for it can be made).
const sqlErrorFleetNoise = sqlErrorFleetBase + `
SELECT l.ack_id, l.check_key, l.match_text, l.instance_id, l.instance_name AS instance, l.tag, l.note, coalesce(h.hits, 0)::int AS hits
  FROM lbl l
  LEFT JOIN (SELECT y.noise_id, count(*) AS hits FROM y WHERE y.noise_id IS NOT NULL GROUP BY y.noise_id) h ON h.noise_id = l.ack_id
 ORDER BY l.check_key, l.ack_id`

// sqlErrorFleetAGState: an instance in scope whose AlwaysOn_health capture was not read (its state row, 0065).
const sqlErrorFleetAGState = `
SELECT i.instance_id, i.name AS instance, x.state, x.state_since AS since
  FROM pgvigil.mssql_xe_state x
  JOIN pgvigil.instances i ON i.instance_id = x.instance_id AND i.engine = 'sqlserver' AND i.is_active
 WHERE x.capture = 'ag' AND x.state <> 'running'
   AND ($1::int IS NULL OR i.instance_id = $1) AND ($2::int[] IS NULL OR i.instance_id = ANY ($2))
   AND ($3::text IS NULL OR $3 = ANY (i.tags))
 ORDER BY i.name`

// MSSQLErrorFleet is GET /api/mssql/errorfleet?[instance=|instances=][&tag=][&from=&to=][&n=][&noise=1]: parts
// byerror, lines, noise, agstate, cannot.
func (s *Server) MSSQLErrorFleet(w http.ResponseWriter, r *http.Request) {
	id, ids, err := storageScope(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	var inst, folder, tag, num any
	if id > 0 {
		inst = id
	}
	if ids != nil {
		folder = ids
	}
	if v := strings.TrimSpace(q.Get("tag")); v != "" {
		if len(v) > 200 {
			writeErr(w, http.StatusBadRequest, errors.New("tag is too long"))
			return
		}
		tag = v
	}
	if v := q.Get("n"); v != "" {
		n, perr := strconv.ParseInt(v, 10, 32)
		if perr != nil || n <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("n must be an error number"))
			return
		}
		num = int32(n)
	}
	noise := q.Get("noise") == "1"
	cannot := make([]string, 0, len(mssqlErrorFleetCannot))
	for n, why := range mssqlErrorFleetCannot {
		cannot = append(cannot, strconv.Itoa(int(n))+"\t"+why)
	}
	base := []any{from, to, inst, folder, tag, num, mssqlErrorFleetNumbers}
	s.multiPart(w, r, []part{
		{"byerror", sqlErrorFleetByError, append(base[:len(base):len(base)], noise)},
		{"lines", sqlErrorFleetLines, append(base[:len(base):len(base)], noise)},
		{"noise", sqlErrorFleetNoise, base},
		{"agstate", sqlErrorFleetAGState, []any{inst, folder, tag}},
		{"cannot", `SELECT split_part(c, E'\t', 1)::int AS error_number, split_part(c, E'\t', 2) AS why
                      FROM unnest($1::text[]) c ORDER BY 1`, []any{cannot}},
	})
}
