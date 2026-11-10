package web

import (
	"math"
	"net/http"
)

// The custom checks' API (task 61; DBADash's custom collections and report): GET /api/custom?instance=<id>&from=&to=
// is one instance's Custom tab (each present check with its definition and its latest run: status, value, row count,
// columns, rows, error; the chart's series over the window, one point per check and step; the instance's custom
// findings); without instance it is the Custom report at the root (every present check of every active instance with
// its latest run, the worst first: pgvigil.custom_report, 0060). The join wires the route in Handler
// (GET /api/custom -> s.Custom). The overview check below feeds a Summary column Custom (check_group 'custom').

func init() {
	overviewChecks = append(overviewChecks, struct{ name, sql string }{"custom", `
SELECT f.instance_id, f.severity, 'custom' AS check_name, substr(f.setting, 14) AS object, f.at, f.detail
  FROM pgvigil.custom_findings f`})
}

// sqlCustomChecks is the instance's present checks with their latest run, the worst first.
const sqlCustomChecks = `
SELECT check_name, description, sql, every_secs, rule, value_column, compare, warning, critical, targets, first_seen,
       last_run, status, value, row_count, columns, rows, rows_kept, error, note, duration_ms, overdue
  FROM pgvigil.custom_status
 WHERE instance_id = $1
 ORDER BY CASE WHEN status = 'critical' THEN 0 WHEN status = 'error' THEN 1 WHEN status = 'warning' THEN 2
               WHEN overdue THEN 3 ELSE 4 END, check_name`

const sqlCustomSeries = `SELECT snapshot_at, check_name, value, status, runs FROM pgvigil.custom_series($1, $2, $3, $4)`

const sqlCustomFindings = `
SELECT severity, setting, value, detail, at FROM pgvigil.custom_findings WHERE instance_id = $1
 ORDER BY CASE severity WHEN 'critical' THEN 0 ELSE 1 END, setting`

// sqlCustomGone is the instance's checks no longer on its list (kept until the purge), the latest first.
const sqlCustomGone = `
SELECT check_name, targets, snapshot_at AS gone_at FROM pgvigil.custom_checks WHERE instance_id = $1 AND NOT is_present
 ORDER BY snapshot_at DESC, check_name LIMIT 50`

const sqlCustomReport = `SELECT * FROM pgvigil.custom_report()`

// Custom serves one instance's Custom tab, or the fleet's Custom report without instance.
func (s *Server) Custom(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("instance") == "" {
		s.multi(w, r, []part{{"report", sqlCustomReport, nil}})
		return
	}
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// about 600 points per check over any window, never finer than the one-minute collection
	step := int(math.Ceil(to.Sub(from).Seconds() / 600))
	if step < 60 {
		step = 60
	}
	s.multi(w, r, []part{
		{"checks", sqlCustomChecks, []any{id}},
		{"series", sqlCustomSeries, []any{id, from, to, step}},
		{"findings", sqlCustomFindings, []any{id}},
		{"gone", sqlCustomGone, []any{id}},
	})
}
