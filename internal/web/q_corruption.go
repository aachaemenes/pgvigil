package web

import (
	"errors"
	"net/http"
	"strconv"
)

// The Corruption column's API (task 34): one instance's Corruption tab (the three settings, the server log's
// corruption events of 30 days, amcheck's newest run per database and check and its last runs, the findings) and the
// fleet view (one summary row per instance). The route is wired in Handler (GET /api/corruption -> s.Corruption); the
// overview check below feeds the Summary column Corruption (check_group 'corruption'): the corruption findings of
// warning and critical severity.

func init() {
	overviewChecks = append(overviewChecks, struct{ name, sql string }{"corruption", `
SELECT f.instance_id, f.severity, 'corruption: ' || f.setting, f.value, f.at, f.detail
  FROM pgvigil.corruption_findings f JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND f.severity IN ('warning', 'critical')`})
}

// sqlCorruptionSummary is one instance's summary row (settings, event counts, amcheck's state).
const sqlCorruptionSummary = `
SELECT s.* FROM pgvigil.corruption_summary s WHERE s.instance_id = $1`

// sqlCorruptionEvents is the newest 500 corruption events of 30 days, newest first.
const sqlCorruptionEvents = `
SELECT e.at, e.class, e.message, e.relation_path, e.datname, e.usename, e.pid, e.statement, e.detail, e.source
  FROM pgvigil.corruption_events e
 WHERE e.instance_id = $1 AND e.at > now() - interval '30 days'
 ORDER BY e.at DESC
 LIMIT 500`

// sqlCorruptionAmcheck is amcheck's newest run per database and check.
const sqlCorruptionAmcheck = `
SELECT a.datname, a.check_name, a.status, a.checked, a.total, a.corrupt, a.errors, a.problems, a.note, a.duration_ms, a.snapshot_at
  FROM pgvigil.amcheck_latest a
 WHERE a.instance_id = $1
 ORDER BY a.corrupt DESC, a.status = 'skipped', a.datname, a.check_name`

// sqlCorruptionAmcheckRuns is the newest 100 amcheck runs (every database and check), newest first.
const sqlCorruptionAmcheckRuns = `
SELECT r.snapshot_at, r.datname, r.check_name, r.status, r.checked, r.total, r.corrupt, r.errors, r.duration_ms, r.note
  FROM pgvigil.amcheck_runs r
 WHERE r.instance_id = $1
 ORDER BY r.snapshot_at DESC, r.datname, r.check_name
 LIMIT 100`

// sqlCorruptionFindings is one instance's corruption findings, the most severe first.
const sqlCorruptionFindings = `
SELECT f.severity, f.setting, f.value, f.suggested, f.detail, f.at
  FROM pgvigil.corruption_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.setting, f.value`

// sqlCorruptionFleet is one row per active instance.
const sqlCorruptionFleet = `
SELECT s.* FROM pgvigil.corruption_summary s ORDER BY s.instance`

// Corruption serves /api/corruption: with ?instance= that instance's tab; without, the fleet summary.
func (s *Server) Corruption(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("instance") == "" {
		s.multi(w, r, []part{{"fleet", sqlCorruptionFleet, nil}})
		return
	}
	id, err := strconv.Atoi(q.Get("instance"))
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
		return
	}
	s.multi(w, r, []part{
		{"summary", sqlCorruptionSummary, []any{id}},
		{"findings", sqlCorruptionFindings, []any{id}},
		{"events", sqlCorruptionEvents, []any{id}},
		{"amcheck", sqlCorruptionAmcheck, []any{id}},
		{"runs", sqlCorruptionAmcheckRuns, []any{id}},
	})
}
