package web

import (
	"errors"
	"net/http"
	"strconv"
)

// sqlExtAvailable is one instance's server-wide list: every extension the server can install or library it
// preloads, with where it is installed and how many of those databases run it below the default version.
const sqlExtAvailable = `
SELECT f.name, f.available, f.default_version, array_to_string(f.preloaded_via, ',') AS preloaded,
       f.installed_dbs, f.databases, f.versions, f.outdated_dbs, f.comment, f.snapshot_at
  FROM pgvigil.extension_fleet f
 WHERE f.instance_id = $1
 ORDER BY f.installed_dbs > 0 OR f.preloaded_via <> '{}' DESC, f.name`

// sqlExtInstalled is one instance's installed extensions per database, the outdated ones marked.
const sqlExtInstalled = `
SELECT d.datname, d.name, d.version, e.default_version, d.schema_name,
       e.available AND coalesce(pgvigil.ext_version_lt(d.version, e.default_version), d.version <> e.default_version) AS outdated,
       d.snapshot_at
  FROM pgvigil.database_extensions d
  LEFT JOIN pgvigil.instance_extensions e ON e.instance_id = d.instance_id AND e.name = d.name AND e.is_present
 WHERE d.instance_id = $1 AND d.is_present
 ORDER BY d.datname, d.name`

// sqlExtPreloaded is the preload lists and the libraries' own settings as the server reports them.
const sqlExtPreloaded = `
SELECT s.name, s.setting, s.unit, s.snapshot_at
  FROM pgvigil.instance_extension_settings s
 WHERE s.instance_id = $1 AND s.is_present
 ORDER BY s.name NOT LIKE '%preload_libraries', s.name`

// sqlExtHistory is the newest 200 extension changes of one instance.
const sqlExtHistory = `
SELECT h.changed_at, h.datname, h.name, h.change, h.old_value, h.new_value
  FROM pgvigil.extension_history h
 WHERE h.instance_id = $1
 ORDER BY h.changed_at DESC, h.datname NULLS FIRST, h.name
 LIMIT 200`

// sqlExtFindings is one instance's extension findings, the most severe first.
const sqlExtFindings = `
SELECT f.severity, f.setting, f.value, f.suggested, f.detail, f.at
  FROM pgvigil.extension_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.setting, f.value`

// sqlExtFleet is the fleet's "which servers have X": one row per active instance and extension that is
// preloaded or installed in at least one database (?all=1 adds the ones only available).
const sqlExtFleet = `
SELECT f.instance_id, i.name AS instance, i.platform, f.name AS extension, f.available, f.default_version,
       array_to_string(f.preloaded_via, ',') AS preloaded, f.installed_dbs, f.databases, f.versions, f.outdated_dbs,
       f.snapshot_at
  FROM pgvigil.extension_fleet f JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND ($1 OR f.installed_dbs > 0 OR f.preloaded_via <> '{}')
 ORDER BY f.name, i.name`

// Extensions serves /api/extensions: with ?instance= that instance's available list, installed set per
// database, preload lists and library settings, change history and findings; without, the fleet rows.
func (s *Server) Extensions(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("instance") == "" {
		t, err := s.query(r.Context(), sqlExtFleet, q.Get("all") == "1")
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
		Available *table `json:"available"`
		Installed *table `json:"installed"`
		Preloaded *table `json:"preloaded"`
		History   *table `json:"history"`
		Findings  *table `json:"findings"`
	}{}
	for _, p := range []struct {
		dst **table
		sql string
	}{{&out.Available, sqlExtAvailable}, {&out.Installed, sqlExtInstalled}, {&out.Preloaded, sqlExtPreloaded},
		{&out.History, sqlExtHistory}, {&out.Findings, sqlExtFindings}} {
		if *p.dst, err = s.query(r.Context(), p.sql, id); err != nil {
			s.reply(w, r, nil, err)
			return
		}
	}
	s.reply(w, r, out, nil)
}
