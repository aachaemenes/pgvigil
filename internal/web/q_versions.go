package web

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/aachaemenes/pgvigil/internal/versions"
)

// sqlVersionsFleet is one row per active instance ($1 NULL) or one instance.
const sqlVersionsFleet = `
SELECT f.* FROM pgvigil.versions_fleet f
 WHERE $1::int IS NULL OR f.instance_id = $1
 ORDER BY f.instance`

const sqlVersionHistory = `
SELECT h.changed_at, h.applied_at, h.change, h.old_value, h.new_value
  FROM pgvigil.version_history h
 WHERE h.instance_id = $1
 ORDER BY h.changed_at DESC
 LIMIT 200`

const sqlVersionTargets = `
SELECT t.engine_version, t.is_major, t.auto_upgrade, t.description, t.snapshot_at
  FROM pgvigil.version_upgrade_targets t
 WHERE t.instance_id = $1
 ORDER BY t.is_major, ARRAY(SELECT m[1]::numeric FROM regexp_matches(t.engine_version, '([0-9]+)', 'g') m), t.engine_version`

const sqlVersionPending = `
SELECT p.resource, p.action, p.description, p.auto_applied_after, p.forced_apply, p.current_apply, p.opt_in_status,
       p.first_seen, p.is_present, p.snapshot_at
  FROM pgvigil.version_pending p
 WHERE p.instance_id = $1 AND (p.is_present OR p.snapshot_at > now() - interval '30 days')
 ORDER BY p.is_present DESC, least(p.forced_apply, p.auto_applied_after, p.current_apply) NULLS LAST, p.resource, p.action`

const sqlVersionCollations = `
SELECT c.datname, c.provider, c.locale, c.recorded_version, c.actual_version,
       c.recorded_version IS NOT NULL AND c.actual_version IS NOT NULL AND c.recorded_version <> c.actual_version AS mismatch,
       c.snapshot_at
  FROM pgvigil.database_collations c
 WHERE c.instance_id = $1 AND c.is_present
 ORDER BY c.datname`

const sqlVersionMembers = `
SELECT m->>'id' AS id, m->>'class' AS class, m->>'engine_version' AS engine_version,
       (m->>'auto_minor_version_upgrade')::boolean AS auto_minor_version_upgrade, m->>'maintenance_window' AS maintenance_window,
       (m->>'is_writer')::boolean AS is_writer
  FROM pgvigil.instance_versions v, jsonb_array_elements(coalesce(v.aws_members, '[]')) m
 WHERE v.instance_id = $1
 ORDER BY (m->>'is_writer')::boolean DESC, m->>'id'`

const sqlVersionFindings = `
SELECT f.severity, f.setting, f.value, f.suggested, f.detail, f.at
  FROM pgvigil.version_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.setting, f.value`

// releaseColumns are the columns withRelease adds to a row that carries server_version_num.
var releaseColumns = []string{"major", "minor", "latest_minor", "latest_released", "behind_by", "newer_than_table",
	"released_days_ago", "eol", "eol_in_months", "eol_passed", "release_table_as_of"}

// withRelease adds the release table's reading of each row's server_version_num (internal/versions).
func withRelease(t *table, now time.Time) {
	if t == nil {
		return
	}
	idx := -1
	for i, c := range t.Columns {
		if c == "server_version_num" {
			idx = i
		}
	}
	if idx < 0 {
		return
	}
	t.Columns = append(t.Columns, releaseColumns...)
	asOf := versions.AsOf.Format("2006-01-02")
	for i, r := range t.Rows {
		n, ok := 0, false
		switch v := r[idx].(type) {
		case int32:
			n, ok = int(v), true
		case int64:
			n, ok = int(v), true
		}
		s := versions.Lookup(n, now)
		if !ok || !s.Known {
			t.Rows[i] = append(r, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, asOf)
			continue
		}
		var rel any
		if s.ReleasedDaysAgo >= 0 {
			rel = s.ReleasedDaysAgo
		}
		t.Rows[i] = append(r, s.Major, s.Minor, s.Latest, s.LatestDate.Format("2006-01-02"), s.BehindBy, s.Newer,
			rel, s.EOL.Format("2006-01-02"), s.EOLInMonths, s.EOLPassed, asOf)
	}
}

// Versions serves /api/versions: without ?instance= the fleet rows (one per instance, the release table's
// columns added); with it that instance's row, version history, upgrade targets, pending maintenance, cluster
// members, collations and findings.
func (s *Server) Versions(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	now := time.Now()
	if q.Get("instance") == "" {
		t, err := s.query(r.Context(), sqlVersionsFleet, nil)
		withRelease(t, now)
		s.reply(w, r, struct {
			Fleet *table `json:"fleet"`
		}{t}, err)
		return
	}
	id, err := strconv.Atoi(q.Get("instance"))
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
		return
	}
	out := struct {
		State      *table `json:"state"`
		History    *table `json:"history"`
		Targets    *table `json:"targets"`
		Pending    *table `json:"pending"`
		Members    *table `json:"members"`
		Collations *table `json:"collations"`
		Findings   *table `json:"findings"`
	}{}
	for _, p := range []struct {
		dst **table
		sql string
	}{{&out.State, sqlVersionsFleet}, {&out.History, sqlVersionHistory}, {&out.Targets, sqlVersionTargets},
		{&out.Pending, sqlVersionPending}, {&out.Members, sqlVersionMembers}, {&out.Collations, sqlVersionCollations},
		{&out.Findings, sqlVersionFindings}} {
		if *p.dst, err = s.query(r.Context(), p.sql, id); err != nil {
			s.reply(w, r, nil, err)
			return
		}
	}
	withRelease(out.State, now)
	s.reply(w, r, out, nil)
}
