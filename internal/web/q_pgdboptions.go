package web

import "net/http"

// PostgreSQL database options and setting overrides in DBA Dash's colours (task 163; migration 0104, the dbsettings
// collection beside databases, connections and versions). Routes, wired in Handler:
//
//	GET /api/pg/dboptions?instance=N[&part=...]   state (the last run of the collections the page reads), databases
//	        (pgvigil.pg_db_options: one row per database, each cell with its status, severity and words), overrides
//	        (pgvigil.pg_override_rules: every ALTER DATABASE / ALTER ROLE ... SET with its status by the server's own
//	        rule and the server's value beside it), findings (the overrides that break a rule and the database cells no
//	        other finding covers).
//	GET /api/pg/dboptions/fleet[?part=risks]      risks (pgvigil.pg_dboption_risks: per active PostgreSQL instance the
//	        databases behind each risk and the overrides that break a rule).
//
// Status words, as on the Configuration page: ok (green), warn (yellow: a warning or an advice rule broken), crit (red:
// a critical rule broken), none (grey: not judged here, or the version lacks it).

var pgDBOptionsCollections = []string{"databases", "connections", "versions", "dbsettings", "instance"}

const sqlPGDBOptionsDatabases = `
SELECT o.* FROM pgvigil.pg_db_options o
 WHERE o.instance_id = $1
 ORDER BY CASE o.worst WHEN 'crit' THEN 0 WHEN 'warn' THEN 1 ELSE 2 END, coalesce(o.is_template, false), lower(o.datname)`

const sqlPGDBOptionsOverrides = `SELECT r.* FROM pgvigil.pg_override_rules($1) r`

// the read time of the overrides beside the rows: an instance without any override still shows that it was read
const sqlPGDBOptionsOverridesRead = `
SELECT r.snapshot_at, r.overrides FROM pgvigil.pg_db_role_settings_read r WHERE r.instance_id = $1`

const sqlPGDBOptionsFindings = `
SELECT x.* FROM (
  SELECT f.severity, f.setting, f.value, f.suggested, f.detail, f.at, 'override' AS kind
    FROM pgvigil.pg_override_findings f WHERE f.instance_id = $1
  UNION ALL
  SELECT f.severity, f.setting, f.value, f.suggested, f.detail, f.at, 'database'
    FROM pgvigil.pg_dboption_findings f WHERE f.instance_id = $1) x
 ORDER BY CASE x.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, x.setting, x.value`

const sqlPGDBOptionsRisks = `SELECT r.* FROM pgvigil.pg_dboption_risks r ORDER BY lower(r.instance_name)`

// PGDBOptions is GET /api/pg/dboptions?instance=N[&part=...]: the state as last read; no window.
func (s *Server) PGDBOptions(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"state", sqlMssqlRunningState, []any{id, pgDBOptionsCollections}},
		{"databases", sqlPGDBOptionsDatabases, []any{id}},
		{"overrides", sqlPGDBOptionsOverrides, []any{id}},
		{"overrides_read", sqlPGDBOptionsOverridesRead, []any{id}},
		{"findings", sqlPGDBOptionsFindings, []any{id}},
	})
}

// PGDBOptionsFleet is GET /api/pg/dboptions/fleet[?part=risks].
func (s *Server) PGDBOptionsFleet(w http.ResponseWriter, r *http.Request) {
	s.multiPart(w, r, []part{
		{"risks", sqlPGDBOptionsRisks, nil},
	})
}
