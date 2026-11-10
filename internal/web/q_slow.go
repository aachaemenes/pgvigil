package web

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
)

// Slow queries in DBA Dash's shape (parity2 task 121; DBA Dash 04, 16, 81): the slow events of both engines
// (pgvigil.slow_events_all, 0076) grouped by a free Group By into DBA Dash's ten duration buckets, and the events
// behind any count.
//
// GET /api/slow/groups?[instance=<id>]&[from=&to=]&[min=<ms>]&[db=<name>]&[group=<key>]&[tz=<IANA>]&[top=<n>]
// &[events=calls|all] (Server.SlowGroups); without instance the fleet (active instances). events=calls (the default)
// leaves out SQL Server's statement events (sql_statement_completed, sp_statement_completed), which repeat a slow
// call's time inside it, so a count is DBA Dash's count of calls; events=all counts every event:
//   groups  one row per value of the group (the most events first, at most top): value, instance_id (when the group
//           is the instance), b0..b9 (the buckets), total, failed, total_duration_s, total_cpu_s, logical_reads,
//           physical_reads, writes, and for the text group an example statement; time groups (hour, day) in time
//           order, the others the most events first; an hour's label carries its UTC offset, so the repeated hour
//           of a clock change is two rows
//   totals  the same counts over every event of the filter (the Total row)
//   dbs     the databases with slow events in the window (the database filter's choices)
//
// GET /api/slow/events?<the same>&[value=<v>|blank=1|null=1]&[bucket=0..9]&[failed=1] (Server.SlowEvents): the
// events of one count (blank=1: the group whose value is the empty string, which a query string cannot carry as
// value=; none of the three: the Total row, every group), the longest first (at most 500), with the total count of the cell:
//   events  instance, engine, database, event type, object, time, duration, CPU, reads, writes, rows, user, client,
//           application, result, session, statement (4,000 characters), shape_key; a PostgreSQL event's
//           application comes from the activity sample of the same pid taken during the run (application_from
//           'sample'), as the log line carries none
//   meta    matched (the cell's count), shown
//
// The routes are the lead's lines in web.go.

// slowGroupExpr: the Group By keys (DBA Dash 04's menu, Time - Custom aside) and the SQL text of each; only these
// texts reach the query (the key picks one), never the request's own text.
var slowGroupExpr = map[string]string{
	"instance":   `e.instance`,
	"database":   `e.database_name`,
	"app":        `e.application`,
	"user":       `e.user_name`,
	"client":     `regexp_replace(e.client, '\(\d+\)$', '')`, // the PostgreSQL log's client carries its port: grouped without it
	"event_type": `e.event_type`,
	"object":     `e.object_name`,
	"result":     `e.result`,
	"session":    `e.session_id::text`,
	"text":       `e.shape_key`,
	// the hour with its UTC offset: the two passes of the hour a clock goes back stay two rows
	"hour": `to_char(date_trunc('hour', e.at AT TIME ZONE z.tz), 'YYYY-MM-DD HH24:00') || ' UTC' ||
	         rtrim(to_char(extract(epoch FROM (e.at AT TIME ZONE z.tz) - (e.at AT TIME ZONE 'UTC')) / 3600, 'FMS990.99'), '.')`,
	"day":    `to_char(date_trunc('day', e.at AT TIME ZONE z.tz), 'YYYY-MM-DD')`,
	"engine": `e.engine`,
}

// sqlSlowFilter: the events of the filter; $1 instance (NULL = the fleet's active instances), $2 from, $3 to,
// $4 min ms, $5 database (NULL = all), $6 the time zone name (UTC when the server does not know it), $7 every event
// (false = the calls: SQL Server's statement events left out).
const sqlSlowFilter = `
WITH z AS (SELECT coalesce((SELECT name FROM pg_timezone_names WHERE name = $6::text), 'UTC') AS tz),
e AS (
  SELECT e.*, %s AS grp
    FROM pgvigil.slow_events_all e
    JOIN pgvigil.instances i USING (instance_id)
    CROSS JOIN z
   WHERE ($1::int IS NULL OR e.instance_id = $1) AND ($1::int IS NOT NULL OR i.is_active)
     AND e.at > $2 AND e.at <= $3 AND coalesce(e.duration_ms, 0) >= $4
     AND ($5::text IS NULL OR e.database_name = $5) AND ($7::bool OR NOT e.is_statement)
)`

const slowCounts = `
       count(*) FILTER (WHERE pgvigil.slow_bucket(e.duration_ms) = 0) AS b0, count(*) FILTER (WHERE pgvigil.slow_bucket(e.duration_ms) = 1) AS b1,
       count(*) FILTER (WHERE pgvigil.slow_bucket(e.duration_ms) = 2) AS b2, count(*) FILTER (WHERE pgvigil.slow_bucket(e.duration_ms) = 3) AS b3,
       count(*) FILTER (WHERE pgvigil.slow_bucket(e.duration_ms) = 4) AS b4, count(*) FILTER (WHERE pgvigil.slow_bucket(e.duration_ms) = 5) AS b5,
       count(*) FILTER (WHERE pgvigil.slow_bucket(e.duration_ms) = 6) AS b6, count(*) FILTER (WHERE pgvigil.slow_bucket(e.duration_ms) = 7) AS b7,
       count(*) FILTER (WHERE pgvigil.slow_bucket(e.duration_ms) = 8) AS b8, count(*) FILTER (WHERE pgvigil.slow_bucket(e.duration_ms) = 9) AS b9,
       count(*) AS total, count(*) FILTER (WHERE e.failed) AS failed,
       round(sum(e.duration_ms) / 1000, 3) AS total_duration_s, round(sum(e.cpu_ms) / 1000, 3) AS total_cpu_s,
       sum(e.logical_reads) AS logical_reads, sum(e.physical_reads) AS physical_reads, sum(e.writes) AS writes`

// $8 top; the second %s is the order (time groups by their label, the others the most events first)
const sqlSlowGroups = sqlSlowFilter + `
SELECT e.grp AS value, CASE WHEN count(DISTINCT e.instance_id) = 1 THEN min(e.instance_id) END AS instance_id,
       CASE WHEN count(DISTINCT e.engine) = 1 THEN min(e.engine) END AS engine,
       left(min(e.statement) FILTER (WHERE e.grp IS NOT NULL), 400) AS example,` + slowCounts + `
  FROM e
 GROUP BY e.grp
 ORDER BY %s
 LIMIT $8`

const sqlSlowGroupTotals = sqlSlowFilter + `
SELECT count(DISTINCT e.grp) + CASE WHEN bool_or(e.grp IS NULL) THEN 1 ELSE 0 END AS groups,` + slowCounts + `
  FROM e`

// the databases of the window (the filter's choices), the filter on the database itself left out
const sqlSlowDBs = `
SELECT e.database_name AS database, count(*) AS events
  FROM pgvigil.slow_events_all e
  JOIN pgvigil.instances i USING (instance_id)
 WHERE ($1::int IS NULL OR e.instance_id = $1) AND ($1::int IS NOT NULL OR i.is_active)
   AND e.at > $2 AND e.at <= $3 AND coalesce(e.duration_ms, 0) >= $4 AND e.database_name IS NOT NULL
   AND ($5::bool OR NOT e.is_statement)
 GROUP BY 1
 ORDER BY 2 DESC, 1
 LIMIT 200`

// $8 the group's value (NULL = the events whose value is NULL), $9 bucket (NULL = every bucket), $10 failed only,
// $11 every group (the Total row: $8 is not read)
const sqlSlowCell = sqlSlowFilter + `,
cell AS (
  SELECT * FROM e
   WHERE ($11::bool OR e.grp IS NOT DISTINCT FROM $8::text)
     AND ($9::int IS NULL OR pgvigil.slow_bucket(e.duration_ms) = $9)
     AND (NOT $10::bool OR e.failed)
)`

const sqlSlowEvents = sqlSlowCell + `,
top AS (SELECT * FROM cell ORDER BY duration_ms DESC NULLS LAST, at DESC LIMIT 500)
SELECT t.instance_id, t.instance, t.engine, t.database_name, t.event_type, t.object_name, t.at, t.duration_ms, t.cpu_ms,
       t.logical_reads, t.physical_reads, t.writes, t.row_count, t.user_name, t.client,
       coalesce(t.application, a.application_name) AS application,
       CASE WHEN t.application IS NULL AND a.application_name IS NOT NULL THEN 'sample' END AS application_from,
       t.result, t.failed, t.session_id, left(t.statement, 4000) AS statement, t.shape_key
  FROM top t
  LEFT JOIN LATERAL (
    SELECT s.application_name
      FROM pgvigil.activity_sample s
     WHERE t.engine = 'postgres' AND s.instance_id = t.instance_id AND s.pid = t.session_id
       AND s.snapshot_at >= t.at - make_interval(secs => coalesce(t.duration_ms, 0)::float8 / 1000) - interval '1 second'
       AND s.snapshot_at <= t.at
     ORDER BY s.snapshot_at DESC
     LIMIT 1) a ON true
 ORDER BY t.duration_ms DESC NULLS LAST, t.at DESC`

const sqlSlowCellCount = sqlSlowCell + `
SELECT count(*) AS matched, least(count(*), 500) AS shown FROM cell`

// slowFilter is the shared parameters of both routes: the instance (nil = the fleet), the window, the threshold,
// the database, the group key, the time zone and whether statement events count.
type slowFilter struct {
	inst     any
	from, to any
	minMS    float64
	db       any
	group    string
	tz       string
	all      bool
}

func (f slowFilter) args() []any { return []any{f.inst, f.from, f.to, f.minMS, f.db, f.tz, f.all} }

func slowFilterOf(r *http.Request) (slowFilter, error) {
	q := r.URL.Query()
	fleet := q.Get("instance") == ""
	id, from, to, err := params(r, !fleet)
	if err != nil {
		return slowFilter{}, err
	}
	f := slowFilter{from: from, to: to, minMS: slowDefaultMinMS, group: "instance", tz: "UTC"}
	if !fleet {
		f.inst = id
		f.group = "database"
	}
	if v := q.Get("min"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 || n > 86400000 {
			return f, errors.New("min must be 0..86400000 milliseconds")
		}
		f.minMS = float64(n)
	}
	if v := q.Get("db"); v != "" {
		if len(v) > 128 {
			return f, errors.New("db must be a database name of at most 128 characters")
		}
		f.db = v
	}
	if v := q.Get("group"); v != "" {
		if _, ok := slowGroupExpr[v]; !ok {
			return f, errors.New("group must be one of instance, database, app, user, client, event_type, object, result, session, text, hour, day, engine")
		}
		f.group = v
	}
	if v := q.Get("tz"); v != "" {
		if !tzName.MatchString(v) {
			return f, errors.New("tz must be a time zone name such as Europe/Berlin")
		}
		f.tz = v
	}
	switch q.Get("events") {
	case "", "calls":
	case "all":
		f.all = true
	default:
		return f, errors.New("events must be calls or all")
	}
	return f, nil
}

// SlowGroups serves the Group By grid of the Slow queries pages (an instance, or the fleet without ?instance=).
func (s *Server) SlowGroups(w http.ResponseWriter, r *http.Request) {
	f, err := slowFilterOf(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	top := 50
	if v := r.URL.Query().Get("top"); v != "" {
		if top, err = strconv.Atoi(v); err != nil || top < 1 || top > 500 {
			writeErr(w, http.StatusBadRequest, errors.New("top must be 1..500"))
			return
		}
	}
	expr, order := slowGroupExpr[f.group], "total DESC, e.grp NULLS LAST"
	if f.group == "hour" || f.group == "day" {
		order = "e.grp NULLS LAST"
	}
	s.multi(w, r, []part{
		{"groups", fmt.Sprintf(sqlSlowGroups, expr, order), append(f.args(), top)},
		{"totals", fmt.Sprintf(sqlSlowGroupTotals, expr), f.args()},
		{"dbs", sqlSlowDBs, []any{f.inst, f.from, f.to, f.minMS, f.all}},
	})
}

// SlowEvents serves the events behind one count of the Group By grid.
func (s *Server) SlowEvents(w http.ResponseWriter, r *http.Request) {
	f, err := slowFilterOf(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	var value any // nil = the events whose group value is NULL
	all := false  // no value, blank=1 or null=1: every event of the filter (the Total row)
	named := 0
	for _, k := range []string{"value", "blank", "null"} {
		if q.Has(k) {
			named++
		}
	}
	switch {
	case named > 1:
		writeErr(w, http.StatusBadRequest, errors.New("value, blank=1 and null=1 do not go together"))
		return
	case q.Has("blank"):
		if q.Get("blank") != "1" {
			writeErr(w, http.StatusBadRequest, errors.New("blank must be 1"))
			return
		}
		value = ""
	case q.Has("null"):
		if q.Get("null") != "1" {
			writeErr(w, http.StatusBadRequest, errors.New("null must be 1"))
			return
		}
	case q.Has("value"):
		v := q.Get("value")
		if len(v) > 512 {
			writeErr(w, http.StatusBadRequest, errors.New("value must be at most 512 characters"))
			return
		}
		value = v
	default:
		all = true
	}
	var bucket any
	if v := q.Get("bucket"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 || n > 9 {
			writeErr(w, http.StatusBadRequest, errors.New("bucket must be 0..9"))
			return
		}
		bucket = n
	}
	failed := false
	switch q.Get("failed") {
	case "", "0":
	case "1":
		failed = true
	default:
		writeErr(w, http.StatusBadRequest, errors.New("failed must be 0 or 1"))
		return
	}
	expr := slowGroupExpr[f.group]
	args := append(f.args(), value, bucket, failed, all)
	s.multi(w, r, []part{
		{"events", fmt.Sprintf(sqlSlowEvents, expr), args},
		{"meta", fmt.Sprintf(sqlSlowCellCount, expr), args},
	})
}
