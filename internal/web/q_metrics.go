package web

// The Metrics page of one instance (task 131; DBA Dash's Metrics grid): GET /api/metrics is one row per metric of the
// instance's engine (pgvigil.metric_catalog, 0085) with the max, min, avg and newest value of the window, the sample
// count, the thresholds in force for the row (the most specific live alert rule: pgvigil.metric_rule) and each figure's
// status against them, and what the alert sender last made of the rule. GET /api/metrics/series is one metric's
// samples for a row's chart, with the same thresholds. Both read pgvigil.metric_points, the read the rules are judged
// on, so a row, its chart and its rule agree. No new collection: every figure is a series the repository already holds.

import (
	"errors"
	"fmt"
	"math"
	"net/http"
	"strings"
)

// sqlMetricGrid: $1 instance, $2 from, $3 to, $4 the rate lookback in seconds, $5 one database's series (NULL = the
// instance's). The state columns are the alert sender's last evaluation of the row's rule (NULL: not judged yet, or
// no sender runs).
const sqlMetricGrid = `
SELECT g.key, g.family, g.family_label, g.metric, g.label, g.unit, g.per_database, g.database,
       g.max_value, g.min_value, g.avg_value, g.current_value, g.current_at, g.samples,
       pgvigil.metric_status(g.op, g.max_value, g.warning, g.critical) AS max_status,
       pgvigil.metric_status(g.op, g.min_value, g.warning, g.critical) AS min_status,
       pgvigil.metric_status(g.op, g.avg_value, g.warning, g.critical) AS avg_status,
       pgvigil.metric_status(g.op, g.current_value, g.warning, g.critical) AS current_status,
       g.rule_id, g.rule_name, g.op, g.warning, g.critical, g.for_minutes, g.rule_scope, g.rule_target, g.rule_database,
       s.state AS rule_state, s.held AS rule_held, s.since AS rule_since, s.evaluated_at AS rule_evaluated_at
  FROM pgvigil.metric_grid($1, $2, $3, make_interval(secs => $4), $5) g
  LEFT JOIN pgvigil.alert_rule_state s
    ON s.instance_id = $1 AND s.metric = g.key AND s.database = coalesce(g.rule_database, '') AND s.rule_id = g.rule_id
 ORDER BY g.family_sort, g.sort`

// sqlMetricDatabases: the databases of the newest database-counter read at or before the window's end (the cut the
// Database family's grid offers)
const sqlMetricDatabases = `
SELECT d.datname
  FROM pgvigil.dbstats d
 WHERE d.instance_id = $1 AND d.datname IS NOT NULL
   AND d.snapshot_at = (SELECT max(x.snapshot_at) FROM pgvigil.dbstats x
                         WHERE x.instance_id = $1 AND x.snapshot_at <= $2 AND x.snapshot_at > $2::timestamptz - interval '1 day')
 ORDER BY d.datname`

// sqlMetricSeries: one metric's samples; $7 = the bucket in seconds (1 = every sample as stored), $8 the metric of
// its family. A bucket carries its average, its highest and its lowest sample.
const sqlMetricSeries = `
SELECT to_timestamp(floor(extract(epoch FROM p.at) / $7) * $7) AS snapshot_at,
       avg(p.value) AS value, max(p.value) AS max_value, min(p.value) AS min_value, count(*) AS samples
  FROM pgvigil.metric_points($1, $2, $3, $4, make_interval(secs => $5), $6) p
 WHERE p.metric = $8
 GROUP BY 1
 ORDER BY 1`

// metricDB reads ?db=: one database's series; "" = the instance's.
func metricDB(r *http.Request) (*string, error) {
	v := r.URL.Query().Get("db")
	if v == "" {
		return nil, nil
	}
	if len(v) > 200 || strings.ContainsFunc(v, func(c rune) bool { return c < ' ' || c == 0x7f }) {
		return nil, errors.New("db must be 1..200 printable characters")
	}
	return &v, nil
}

// metricLookback is how far before the window a counter's rate may reach for its first baseline: the longer of the
// database counters' and the IO counters' lookbacks (rateLookback), since one grid reads both.
func (s *Server) metricLookback(r *http.Request, id int) int {
	return max(s.rateLookback(r.Context(), id, "dbstats"), s.rateLookback(r.Context(), id, "iostats"))
}

// Metrics is GET /api/metrics?instance=&from=&to=[&db=]: the grid, the databases its Database family can be cut by,
// the instance's engine, and whether alert rules can be written here (and why not).
func (s *Server) Metrics(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	db, err := metricDB(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var engine string
	if err := s.pool.QueryRow(r.Context(), `SELECT engine FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&engine); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return
	}
	out := map[string]any{"engine": engine}
	s.alertRulesDoor(r, out)
	grid, err := s.query(r.Context(), sqlMetricGrid, id, from, to, s.metricLookback(r, id), db)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("grid: %w", err))
		return
	}
	out["grid"] = grid
	dbs, err := s.query(r.Context(), sqlMetricDatabases, id, to)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("databases: %w", err))
		return
	}
	out["databases"] = dbs
	s.reply(w, r, out, nil)
}

// metricSeriesPoints is about how many points a row's chart draws: a longer window is bucketed down to it.
const metricSeriesPoints = 600

// MetricSeries is GET /api/metrics/series?instance=&metric=<family.metric>&from=&to=[&db=]: the metric's samples
// (bucketed past about 600 points: step_secs says how), its label and unit, and the thresholds in force for it.
func (s *Server) MetricSeries(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	db, err := metricDB(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	key := r.URL.Query().Get("metric")
	if key == "" || len(key) > 100 {
		writeErr(w, http.StatusBadRequest, errors.New("metric must be a metric key (family.metric)"))
		return
	}
	ctx := r.Context()
	var family, metric, mEngine, iEngine string
	var perDB bool
	err = s.pool.QueryRow(ctx, `
SELECT c.family, c.metric, c.engine, c.per_database, i.engine
  FROM pgvigil.instances i LEFT JOIN pgvigil.metric_catalog c ON c.key = $2
 WHERE i.instance_id = $1`, id, key).Scan(&family, &metric, &mEngine, &perDB, &iEngine)
	if err != nil {
		// no instance, or no such metric (the catalogue's columns come back NULL and do not scan)
		writeErr(w, http.StatusBadRequest, fmt.Errorf("no metric %q for instance %d", key, id))
		return
	}
	if mEngine != "any" && mEngine != iEngine {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("%s is a %s metric and instance %d is %s", key, mEngine, id, iEngine))
		return
	}
	if db != nil && !perDB {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("%s has no per-database series", key))
		return
	}
	step := int(math.Ceil(to.Sub(from).Seconds() / metricSeriesPoints))
	if step < 120 {
		step = 1 // every sample as stored: the collections read once a minute at most
	}
	out := map[string]any{"step_secs": step}
	series, err := s.query(ctx, sqlMetricSeries, id, family, from, to, s.metricLookback(r, id), db, step, metric)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("series: %w", err))
		return
	}
	out["series"] = series
	meta, err := s.query(ctx, `
SELECT c.key, c.family_label, c.label, c.unit, c.per_database, $3::text AS database,
       t.rule_id, t.rule_name, t.op, t.warning, t.critical, t.for_minutes, t.rule_scope, t.rule_target, t.rule_database
  FROM pgvigil.metric_catalog c
  LEFT JOIN LATERAL pgvigil.metric_rule($1, c.key, $3) t ON true
 WHERE c.key = $2`, id, key, db)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("metric: %w", err))
		return
	}
	out["metric"] = meta
	s.reply(w, r, out, nil)
}
