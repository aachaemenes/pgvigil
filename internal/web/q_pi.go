package web

import (
	"net/http"
)

// The Performance Insights and Serverless capacity API (phase 3 wave E, task 56): an instance's Load tab
// (GET /api/pi -> s.PILoad) and the Capacity section of its Host tab (GET /api/capacity -> s.Capacity). The routes
// are wired in Handler at the wave's join; PIOverviewCheck is the line the join adds to overviewChecks for a Summary
// cell (check_group "pi").

// PIOverviewCheck is the Summary check over every row of pi_findings ("cache starved by the ACU floor").
var PIOverviewCheck = struct{ name, sql string }{"pi", `
SELECT f.instance_id, f.severity, f.setting, f.value, f.at, f.detail
  FROM pgvigil.pi_findings f JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND f.severity IN ('critical', 'warning')`}

// sqlPIState is whether PI is on for the instance and what the last run read (no row: the collection never ran).
const sqlPIState = `
SELECT db_instance, resource_id, enabled, retention_days, hours_read, note, snapshot_at,
       (SELECT min(snapshot_at) FROM pgvigil.pi_load l WHERE l.instance_id = s.instance_id) AS kept_from,
       (SELECT max(snapshot_at) FROM pgvigil.pi_load l WHERE l.instance_id = s.instance_id) AS kept_to
  FROM pgvigil.pi_state s
 WHERE instance_id = $1`

// piHours: the PI hours that overlap the window [$2, $3) (an hour row is keyed by its start).
const piHours = `l.instance_id = $1 AND l.snapshot_at + interval '1 hour' > $2 AND l.snapshot_at < $3`

// sqlPITotal is the hourly DB load (average active sessions) over the window.
const sqlPITotal = `
SELECT l.snapshot_at, l.load_avg
  FROM pgvigil.pi_load l
 WHERE ` + piHours + ` AND l.dim_group = 'total'
 ORDER BY l.snapshot_at`

// sqlPIWaits is the hourly load by wait event over the window, long form for the stacked chart: the 8 heaviest
// events of the window by name, the rest summed as 'other'.
const sqlPIWaits = `
WITH w AS (
  SELECT l.snapshot_at, l.dim_key AS event, l.wait_type, l.load_avg
    FROM pgvigil.pi_load l
   WHERE ` + piHours + ` AND l.dim_group = 'wait'
),
top AS (
  SELECT event FROM w GROUP BY event ORDER BY sum(load_avg) DESC NULLS LAST, event LIMIT 8
)
SELECT w.snapshot_at,
       CASE WHEN t.event IS NULL THEN 'other' ELSE coalesce(w.wait_type || ':', '') || w.event END AS wait,
       round(sum(w.load_avg)::numeric, 3)::float8 AS load_avg
  FROM w LEFT JOIN top t USING (event)
 GROUP BY 1, 2
 ORDER BY 1, 2`

// sqlPISQL is the window's top SQL digests by load: the session-hours over the window (the sum of the hourly
// averages), the average sessions over the hours read, the share of the total, and the text (the digest, cut at 500
// bytes by the API, and the whole text when it was fetched), as the query_text policy stored them.
const sqlPISQL = `
WITH s AS (
  SELECT l.dim_key AS tokenized_id, sum(l.load_avg) AS load_hours, count(*) AS hours
    FROM pgvigil.pi_load l
   WHERE ` + piHours + ` AND l.dim_group = 'sql'
   GROUP BY l.dim_key
),
t AS (
  SELECT sum(l.load_avg) AS load_hours, count(*) AS hours
    FROM pgvigil.pi_load l
   WHERE ` + piHours + ` AND l.dim_group = 'total'
)
SELECT s.tokenized_id, q.db_id, round(s.load_hours::numeric, 3)::float8 AS load_hours,
       round((s.load_hours / nullif(t.hours, 0))::numeric, 3)::float8 AS avg_sessions,
       round((100 * s.load_hours / nullif(t.load_hours, 0))::numeric, 1)::float8 AS share_pct, s.hours,
       q.digest, q.full_text, q.text_status, q.last_seen
  FROM s CROSS JOIN t
  LEFT JOIN pgvigil.pi_sql q ON q.instance_id = $1 AND q.tokenized_id = s.tokenized_id
 ORDER BY s.load_hours DESC, s.tokenized_id
 LIMIT 25`

// sqlPIFindings are the instance's pi_findings now.
const sqlPIFindings = `
SELECT severity, setting, value, suggested, detail, at FROM pgvigil.pi_findings WHERE instance_id = $1 ORDER BY setting`

// PILoad is one instance's Load tab: PI's state, the hourly load in total and by wait, the top SQL, the findings.
func (s *Server) PILoad(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{
		{"state", sqlPIState, []any{id}},
		{"total", sqlPITotal, []any{id, from, to}},
		{"waits", sqlPIWaits, []any{id, from, to}},
		{"sql", sqlPISQL, []any{id, from, to}},
		{"findings", sqlPIFindings, []any{id}},
	})
}

// sqlCapacityScaling is the instance's cluster and its Serverless v2 range.
const sqlCapacityScaling = `
SELECT db_instance, cluster, class, min_acu, max_acu, note, snapshot_at FROM pgvigil.serverless_scaling WHERE instance_id = $1`

// sqlCapacitySeries is the capacity (the highest), the ACU utilization, the hit ratio, the reads and the CPU (the
// means) per $4-second bucket over the window, one row per bucket.
const sqlCapacitySeries = `
SELECT to_timestamp(floor(extract(epoch FROM snapshot_at) / $4) * $4) AS snapshot_at,
       max(value) FILTER (WHERE metric = 'ServerlessDatabaseCapacity') AS acu,
       round(avg(value) FILTER (WHERE metric = 'ACUUtilization')::numeric, 2)::float8 AS acu_pct,
       round(avg(value) FILTER (WHERE metric = 'BufferCacheHitRatio')::numeric, 2)::float8 AS hit_pct,
       round(avg(value) FILTER (WHERE metric = 'ReadIOPS')::numeric, 1)::float8 AS read_iops,
       round(avg(value) FILTER (WHERE metric = 'CPUUtilization')::numeric, 2)::float8 AS cpu_pct
  FROM pgvigil.serverless_sample
 WHERE instance_id = $1 AND snapshot_at > $2 AND snapshot_at <= $3
 GROUP BY 1 ORDER BY 1`

// sqlCapacityLatest is the newest datapoint of each series, over the last day.
const sqlCapacityLatest = `
SELECT DISTINCT ON (metric) metric, value, unit, stat, snapshot_at AS at
  FROM pgvigil.serverless_sample
 WHERE instance_id = $1 AND snapshot_at > now() - interval '1 day'
 ORDER BY metric, snapshot_at DESC`

// Capacity is the Host tab's Capacity section: the range, the series of the window, the newest values, the findings.
func (s *Server) Capacity(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{
		{"scaling", sqlCapacityScaling, []any{id}},
		{"series", sqlCapacitySeries, []any{id, from, to, ioBucket(from, to, 300)}},
		{"latest", sqlCapacityLatest, []any{id}},
		{"findings", sqlPIFindings, []any{id}},
	})
}
