package web

import (
	"encoding/json"
	"net/http"

	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// The day-one checks of a SQL Server instance (task 148; migration 0090, collections mssql_checks and
// mssql_identity; the trace flags' area from mssql_traceflags, migration 0094) and their fleet view.
//
//	GET /api/mssql/checks?instance=N[&part=...]   state (the two collections' last runs), areas (per area: read or
//	        not, why, the Summary cell), findings, options (every server option with its default, advised value and
//	        verdict), flags (trace flags), build, databases (every database's options and the cells that deviate),
//	        columns (the database grid's columns in order, with the value each is held to), suspect, alerts,
//	        operators, alerting (the fail-safe operator), identity (the columns), identity_scan (per database).
//	GET /api/mssql/checks/fleet[?part=...]        risks (per instance the databases with each risky option, the
//	        largest VLF count, the server options that deviate: DBA Dash's DB Options summary), cells (every
//	        instance's area cells), options (the fleet pivot of the server options: one row per instance and
//	        option, the verdict beside the value).

const sqlMSSQLChecksAreas = `
SELECT s.key AS area, s.is_read, s.note, s.sampled, s.critical, s.warning, s.value, s.detail, s.snapshot_at, s.read_at
  FROM pgvigil.mssql_checks_status s
 WHERE s.instance_id = $1
 ORDER BY s.key`

const sqlMSSQLChecksFindings = `
SELECT f.area, f.severity, f.check_name, f.object, f.rule, f.value, f.detail, f.first_seen, f.at
  FROM pgvigil.mssql_checks_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.area, f.check_name, f.object`

// the worst first, then by name; an option no longer listed last
const sqlMSSQLChecksOptions = `
SELECT o.name, o.value_in_use, o.value_set, o.default_value, o.advised, o.status, o.severity, o.rule, o.detail,
       o.value_set IS DISTINCT FROM o.value_in_use
       -- the engine resolves a 0 in 'min server memory (MB)' to its own floor (16): not pending (q_mssql_config.go)
       AND NOT (o.name = 'min server memory (MB)' AND o.value_set = 0 AND o.value_in_use <= 16) AS pending, o.is_present, o.snapshot_at
  FROM pgvigil.mssql_server_option o
 WHERE o.instance_id = $1
 ORDER BY o.is_present DESC, CASE o.status WHEN 'crit' THEN 0 WHEN 'warn' THEN 1 WHEN 'ok' THEN 2 ELSE 3 END,
          CASE o.severity WHEN 'warning' THEN 0 ELSE 1 END, lower(o.name)`

const sqlMSSQLChecksFlags = `
SELECT t.flag, t.is_on, t.status, t.severity, t.rule, t.detail, t.first_seen, t.is_present, t.snapshot_at
  FROM pgvigil.mssql_trace_flag_checks t
 WHERE t.instance_id = $1
 ORDER BY t.is_present DESC, t.is_on DESC, t.flag`

const sqlMSSQLChecksBuild = `
SELECT b.*, i.server_version AS product_version
  FROM pgvigil.mssql_build b JOIN pgvigil.instances i USING (instance_id)
 WHERE b.instance_id = $1`

const sqlMSSQLChecksDatabases = `
SELECT d.database_name, d.database_id, d.state, d.is_system, d.is_snapshot, d.options, d.deviations, d.is_present, d.snapshot_at
  FROM pgvigil.mssql_database_option d
 WHERE d.instance_id = $1
 ORDER BY d.is_present DESC, d.is_system DESC, lower(d.database_name)`

const sqlMSSQLChecksColumns = `
SELECT c.ord, c.value->>'key' AS key, c.value->>'label' AS label, c.value->>'best' AS best
  FROM jsonb_array_elements($1::jsonb) WITH ORDINALITY c(value, ord)
 ORDER BY c.ord`

const sqlMSSQLChecksSuspect = `
SELECT s.database_name, s.file_id, s.page_id, s.event_type, s.event, s.error_count, s.last_update_at
  FROM pgvigil.mssql_suspect_page s
 WHERE s.instance_id = $1
 ORDER BY s.last_update_at DESC NULLS LAST
 LIMIT 1000`

const sqlMSSQLChecksAlerts = `
SELECT a.name, a.severity, a.message_id, a.enabled, a.notifies, a.has_job, a.include_event_description, a.delay_s,
       a.occurrence_count, a.last_occurrence_at
  FROM pgvigil.mssql_agent_alert a
 WHERE a.instance_id = $1
 ORDER BY coalesce(a.severity, 0) = 0, a.severity, a.message_id, a.name`

const sqlMSSQLChecksOperators = `
SELECT o.name, o.enabled, o.has_email, o.last_email_at
  FROM pgvigil.mssql_agent_operator o
 WHERE o.instance_id = $1
 ORDER BY o.name`

const sqlMSSQLChecksAlerting = `
SELECT g.failsafe_read, g.failsafe_operator, g.snapshot_at
  FROM pgvigil.mssql_agent_alerting g
 WHERE g.instance_id = $1`

const sqlMSSQLChecksIdentity = `
SELECT c.database_name, c.schema_name, c.table_name, c.column_name, c.type_name, c.last_value, c.max_value, c.pct_used,
       c.status, c.per_day, c.days_left, c.snapshot_at
  FROM pgvigil.mssql_identity_column c
 WHERE c.instance_id = $1
 ORDER BY c.pct_used DESC, c.database_name, c.schema_name, c.table_name
 LIMIT 500`

const sqlMSSQLChecksIdentityScan = `
SELECT s.database_name, s.scanned, s.columns_total, s.listed, s.note, s.scanned_at, s.snapshot_at
  FROM pgvigil.mssql_identity_scan s
 WHERE s.instance_id = $1
 ORDER BY s.scanned, s.database_name`

// databaseColumnsJSON is the collector package's grid columns as the one jsonb argument of sqlMSSQLChecksColumns.
func databaseColumnsJSON() (string, error) {
	b, err := json.Marshal(mssql.DatabaseOptions())
	return string(b), err
}

// MSSQLChecks is GET /api/mssql/checks?instance=N[&part=...]: the state as last read; no window.
func (s *Server) MSSQLChecks(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	cols, err := databaseColumnsJSON()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	s.multiPart(w, r, []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_checks", "mssql_identity", "mssql_traceflags"}}},
		{"areas", sqlMSSQLChecksAreas, []any{id}},
		{"findings", sqlMSSQLChecksFindings, []any{id}},
		{"options", sqlMSSQLChecksOptions, []any{id}},
		{"flags", sqlMSSQLChecksFlags, []any{id}},
		{"build", sqlMSSQLChecksBuild, []any{id}},
		{"databases", sqlMSSQLChecksDatabases, []any{id}},
		{"columns", sqlMSSQLChecksColumns, []any{cols}},
		{"suspect", sqlMSSQLChecksSuspect, []any{id}},
		{"alerts", sqlMSSQLChecksAlerts, []any{id}},
		{"operators", sqlMSSQLChecksOperators, []any{id}},
		{"alerting", sqlMSSQLChecksAlerting, []any{id}},
		{"identity", sqlMSSQLChecksIdentity, []any{id}},
		{"identity_scan", sqlMSSQLChecksIdentityScan, []any{id}},
	})
}

const sqlMSSQLChecksFleetRisks = `
SELECT r.* FROM pgvigil.mssql_option_risks r ORDER BY lower(r.instance_name)`

const sqlMSSQLChecksFleetCells = `
SELECT s.instance_id, s.key AS area, s.sampled, s.critical, s.warning, s.value, s.detail, s.read_at
  FROM pgvigil.mssql_checks_status s
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.engine = 'sqlserver' AND i.is_active
 ORDER BY s.instance_id, s.key`

// the pivot's rows: every present option of every active instance (a few hundred rows per instance at most)
const sqlMSSQLChecksFleetOptions = `
SELECT o.instance_id, o.name, o.value_in_use, o.default_value, o.status, o.severity, o.rule, o.detail
  FROM pgvigil.mssql_server_option o
  JOIN pgvigil.instances i ON i.instance_id = o.instance_id AND i.engine = 'sqlserver' AND i.is_active
 WHERE o.is_present
 ORDER BY lower(o.name), o.instance_id`

// MSSQLChecksFleet is GET /api/mssql/checks/fleet[?part=...].
func (s *Server) MSSQLChecksFleet(w http.ResponseWriter, r *http.Request) {
	s.multiPart(w, r, []part{
		{"risks", sqlMSSQLChecksFleetRisks, nil},
		{"cells", sqlMSSQLChecksFleetCells, nil},
		{"options", sqlMSSQLChecksFleetOptions, nil},
	})
}
