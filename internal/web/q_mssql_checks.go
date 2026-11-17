package web

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/jackc/pgx/v5"
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
 WHERE d.instance_id = $1 AND ($2::text = '' OR d.database_name = $2::text)
 ORDER BY d.is_present DESC, d.is_system DESC, lower(d.database_name)`

// sqlMSSQLChecksScopedConfig / Changes: one database's scoped configuration (0391, P25 row 2a: DBA Dash's database
// DB Configuration) - each row as last read, and the changes the reads saw, the newest first. $2 the database's name.
const sqlMSSQLChecksScopedConfig = `
SELECT c.name, c.value, c.value_for_secondary, c.is_default, c.is_present, c.note, c.first_seen, c.snapshot_at
  FROM pgvigil.mssql_db_scoped_config c
 WHERE c.instance_id = $1 AND c.database_name = $2::text
 ORDER BY c.is_present DESC, c.name`

// the database's Service Broker (0392, P25 row 73: DBA Dash's database Service Broker tab). $2 the database's name;
// the depth and the counters over the window ($3 / $4).
const sqlMSSQLChecksBrokerQueues = `
SELECT q.schema_name, q.queue_name, q.is_receive_enabled, q.is_enqueue_enabled, q.is_retention_enabled, q.is_activation_enabled,
       q.is_poison_handling, q.activation_procedure, q.activation_procedure_exists, q.max_readers, q.message_count, q.activated_tasks,
       q.monitor_state, q.monitor_tasks_waiting, q.monitor_last_activated, q.monitor_last_empty, q.oldest_message_at,
       q.note, q.is_present, q.first_seen, q.snapshot_at
  FROM pgvigil.mssql_broker_queue q
 WHERE q.instance_id = $1 AND q.database_name = $2::text
 ORDER BY q.is_present DESC, q.schema_name, q.queue_name`

const sqlMSSQLChecksBrokerDepth = `
SELECT s.snapshot_at, s.schema_name, s.queue_name, s.message_count, s.activated_tasks
  FROM pgvigil.mssql_broker_queue_sample s
 WHERE s.instance_id = $1 AND s.database_name = $2::text AND s.snapshot_at > $3 AND s.snapshot_at <= $4
 ORDER BY s.snapshot_at, s.schema_name, s.queue_name
 LIMIT 20000`

const sqlMSSQLChecksBrokerTransmission = `
SELECT t.to_service_name, t.transmission_status, t.message_count, t.oldest_enqueue_at, t.snapshot_at
  FROM pgvigil.mssql_broker_transmission t
 WHERE t.instance_id = $1 AND t.database_name = $2::text
 ORDER BY t.message_count DESC NULLS LAST, t.to_service_name`

const sqlMSSQLChecksBrokerConversations = `
SELECT c.state, c.conversation_count, c.snapshot_at
  FROM pgvigil.mssql_broker_conversation c
 WHERE c.instance_id = $1 AND c.database_name = $2::text
 ORDER BY c.conversation_count DESC NULLS LAST, c.state`

const sqlMSSQLChecksBrokerEndpoint = `
SELECT e.endpoint_name, e.state_desc, e.port, e.connection_count, e.connected_count, e.login_failed_count, e.last_activity_at, e.snapshot_at
  FROM pgvigil.mssql_broker_endpoint e
 WHERE e.instance_id = $1
 ORDER BY e.endpoint_name`

// the counters as rates: each sample's difference from the sample before, over the seconds between them; none where
// the value fell (the instance restarted: the counters start again) or for the window's first sample
const sqlMSSQLChecksBrokerCounters = `
SELECT x.snapshot_at, x.object, x.instance_name, x.counter_name,
       round(((x.cntr_value - x.prev_value) / nullif(extract(epoch FROM x.snapshot_at - x.prev_at), 0))::numeric, 2)::float8 AS per_sec
  FROM (SELECT c.snapshot_at, c.object, c.instance_name, c.counter_name, c.cntr_value,
               lag(c.cntr_value) OVER w AS prev_value, lag(c.snapshot_at) OVER w AS prev_at
          FROM pgvigil.mssql_broker_counter_sample c
         WHERE c.instance_id = $1 AND c.snapshot_at > $3 AND c.snapshot_at <= $4
        WINDOW w AS (PARTITION BY c.object, c.instance_name, c.counter_name ORDER BY c.snapshot_at)) x
 WHERE x.prev_value IS NOT NULL AND x.cntr_value >= x.prev_value AND ($2::text = '' OR x.object = 'Broker Statistics' OR x.instance_name = $2::text)
 ORDER BY x.snapshot_at, x.object, x.counter_name, x.instance_name
 LIMIT 20000`

const sqlMSSQLChecksScopedChanges = `
SELECT x.name, x.changed_at, x.old_value, x.new_value
  FROM pgvigil.mssql_db_scoped_config_change x
 WHERE x.instance_id = $1 AND x.database_name = $2::text
 ORDER BY x.changed_at DESC, x.name
 LIMIT 500`

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

// sqlMSSQLChecksBuildDocs: the build's documentation links (task 412), made in Go from the binary's catalogue at serve
// time and handed in as one jsonb argument (as the columns part); one row, nulls when the catalogue cannot place it
const sqlMSSQLChecksBuildDocs = `
SELECT d.build_url, d.build_url_words, d.newest_build, d.newest_url, d.newest_url_words
  FROM jsonb_to_record($1::jsonb) AS d(build_url text, build_url_words text, newest_build text, newest_url text, newest_url_words text)`

// MSSQLChecks is GET /api/mssql/checks?instance=N[&part=...]: the state as last read; no window.
func (s *Server) MSSQLChecks(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// task 412: the version the instance last reported (the first line of @@VERSION), for its build's links (no row: no links)
	var ver string
	if err := s.pool.QueryRow(r.Context(), `SELECT coalesce(server_version, '') FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&ver); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	docs, err := json.Marshal(mssql.BuildDocsOf(ver))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
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
		{"build_docs", sqlMSSQLChecksBuildDocs, []any{string(docs)}},
		{"databases", sqlMSSQLChecksDatabases, []any{id, r.URL.Query().Get("db")}}, // db=: one database's row (P25 DB Options)
		{"columns", sqlMSSQLChecksColumns, []any{cols}},
		{"suspect", sqlMSSQLChecksSuspect, []any{id}},
		{"alerts", sqlMSSQLChecksAlerts, []any{id}},
		{"operators", sqlMSSQLChecksOperators, []any{id}},
		{"alerting", sqlMSSQLChecksAlerting, []any{id}},
		{"identity", sqlMSSQLChecksIdentity, []any{id}},
		{"identity_scan", sqlMSSQLChecksIdentityScan, []any{id}},
		// db=: one database's scoped configuration and its changes (P25 row 2a; none without db=)
		{"scoped_config", sqlMSSQLChecksScopedConfig, []any{id, r.URL.Query().Get("db")}},
		{"scoped_changes", sqlMSSQLChecksScopedChanges, []any{id, r.URL.Query().Get("db")}},
		// db=: one database's Service Broker (P25 row 73); the depth and the counters over the window
		{"broker_state", sqlMssqlRunningState, []any{id, []string{"mssql_service_broker"}}},
		{"broker_queues", sqlMSSQLChecksBrokerQueues, []any{id, r.URL.Query().Get("db")}},
		{"broker_depth", sqlMSSQLChecksBrokerDepth, []any{id, r.URL.Query().Get("db"), from, to}},
		{"broker_transmission", sqlMSSQLChecksBrokerTransmission, []any{id, r.URL.Query().Get("db")}},
		{"broker_conversations", sqlMSSQLChecksBrokerConversations, []any{id, r.URL.Query().Get("db")}},
		{"broker_endpoint", sqlMSSQLChecksBrokerEndpoint, []any{id}},
		{"broker_counters", sqlMSSQLChecksBrokerCounters, []any{id, r.URL.Query().Get("db"), from, to}},
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
