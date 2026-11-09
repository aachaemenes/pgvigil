package web

import (
	"errors"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"time"
)

// The Slow queries tab and its fleet root (task 36): GET /api/slowqueries?[instance=<id>]&[from=&to=]&[min=<ms>]
// &[tz=<IANA name>]&[limit=<n>] (Server.SlowQueries). Without instance it is the fleet root. The statements
// come from the server log (the CloudWatch reader on RDS and Aurora, the serverlog reader on-prem: log_events
// kind slow, through the 0025 views); the instance tab adds the activity sampler's long runs
// (slow_in_window). The per-day histogram covers the window, never less than the 7 days to its end; the top
// lists and the recent list cover the window. No Summary column: slow statements are a view, not a check.
// The sampler's own grid stays on /api/slow (Server.slow).

// slowDefaultMinMS is the threshold when the picker sends none.
const slowDefaultMinMS = 1000

var tzName = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_+/-]{0,63}$`)

const sqlSlowSources = `
SELECT instance_id, instance, platform, reader, status, note, last_run, log_min_duration_statement, last_slow_at
  FROM pgvigil.slow_sources
 WHERE $1::int IS NULL OR instance_id = $1
 ORDER BY instance, reader NULLS LAST`

// the day as text: a date column would reach the page as a UTC midnight timestamp
const sqlSlowHistogram = `
SELECT day::text AS day, statements, under_1s, s1_to_10, s10_to_60, over_60s, total_ms, max_ms
  FROM pgvigil.slow_histogram($1, $2, $3, $4, $5)`

// sqlSlowTop serves both top lists in one call: the page sorts by rank_count or rank_total.
const sqlSlowTop = `SELECT * FROM pgvigil.slow_top($1, $2, $3, $4, $5)`

const sqlSlowTotals = `SELECT * FROM pgvigil.slow_totals($1, $2, $3, $4)`

// sqlSlowMeta: the threshold, the histogram's start and the zone its days are in (UTC when the server does not
// know the name the page sent).
const sqlSlowMeta = `
SELECT $1::int AS min_ms, $2::timestamptz AS histogram_from,
       coalesce((SELECT name FROM pg_timezone_names WHERE name = $3::text), 'UTC') AS tz`

// sqlSlowRecent is the window's slow statements of one instance, newest first.
const sqlSlowRecent = `
SELECT at, duration_ms, pid, datname, usename, client, left(statement, 4000) AS statement, shape_key, reader
  FROM pgvigil.slow_events
 WHERE instance_id = $1 AND at > $2 AND at <= $3 AND duration_ms >= $4
 ORDER BY at DESC
 LIMIT 500`

// sqlSlowByInstance is the fleet's slow statements per instance over the window, the most total time first.
const sqlSlowByInstance = `
SELECT e.instance_id, e.instance, e.platform, count(*) AS statements, sum(e.duration_ms) AS total_ms,
       max(e.duration_ms) AS max_ms, max(e.at) AS last_at
  FROM pgvigil.slow_events e JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND e.at > $1 AND e.at <= $2 AND e.duration_ms >= $3
 GROUP BY 1, 2, 3
 ORDER BY total_ms DESC`

// SlowQueries serves the Slow queries tab of one instance, or the fleet root without ?instance=.
func (s *Server) SlowQueries(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	fleet := q.Get("instance") == ""
	id, from, to, err := params(r, !fleet)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	minMS := slowDefaultMinMS
	if v := q.Get("min"); v != "" {
		if minMS, err = strconv.Atoi(v); err != nil || minMS < 0 || minMS > 86400000 {
			writeErr(w, http.StatusBadRequest, errors.New("min must be 0..86400000 milliseconds"))
			return
		}
	}
	tz := "UTC"
	if v := q.Get("tz"); v != "" {
		if !tzName.MatchString(v) {
			writeErr(w, http.StatusBadRequest, errors.New("tz must be a time zone name such as Europe/Berlin"))
			return
		}
		tz = v
	}
	limit := 50
	if v := q.Get("limit"); v != "" {
		if limit, err = strconv.Atoi(v); err != nil || limit < 1 || limit > 500 {
			writeErr(w, http.StatusBadRequest, errors.New("limit must be 1..500"))
			return
		}
	}
	histFrom := from
	if week := to.Add(-7 * 24 * time.Hour); week.Before(histFrom) {
		histFrom = week
	}
	var inst any // NULL = the fleet
	if !fleet {
		inst = id
	}
	ms := float64(minMS)
	parts := []part{
		{"meta", sqlSlowMeta, []any{minMS, histFrom, tz}},
		{"sources", sqlSlowSources, []any{inst}},
		{"totals", sqlSlowTotals, []any{inst, from, to, ms}},
		{"histogram", sqlSlowHistogram, []any{inst, histFrom, to, ms, tz}},
		{"top", sqlSlowTop, []any{inst, from, to, ms, limit}},
	}
	if fleet {
		parts = append(parts, part{"instances", sqlSlowByInstance, []any{from, to, ms}})
	} else {
		// the sampler sees whole seconds: its floor is the threshold rounded up, at least one second
		secs := max(1, int(math.Ceil(float64(minMS)/1000)))
		parts = append(parts,
			part{"recent", sqlSlowRecent, []any{id, from, to, ms}},
			part{"sampled", `SELECT * FROM pgvigil.slow_in_window($1, $2, $3, $4, 200)`, []any{id, from, to, secs}})
	}
	s.multi(w, r, parts)
}
