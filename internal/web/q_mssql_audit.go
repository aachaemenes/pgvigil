package web

import (
	"errors"
	"fmt"
	"net/http"
)

// The Audit tab of a SQL Server instance (task 158). It reads only the tables and views of migration 0101 (the
// mssql_audit collection): the audits a DBA defined on the server, their specifications, and the events read from
// the audits that write to a file. pgvigil never creates, changes, starts or stops an audit.
//
// GET /api/mssql/audit?instance=<id>&[from=&to=][&category=][&part=] (Server.MSSQLAudit):
//
//	state     the mssql_audit collection's last run (ok, partial, skipped or error, with its note)
//	read      what the last read could read (the audit list, the state view, the events and the right they ask for)
//	status    the Summary cell 'audit'
//	findings  the instance's audit findings
//	audits    every audit with its state, target, on-failure action, file, last event and what became of its events
//	specs     the server and database audit specifications with their actions
//	by_category  the window's events per kept category: listed (rows), counted_over (events of that category a read
//	          counted because it was over its row cap) and events, their sum
//	events    the newest 1,000 listed events of the window (category= one of them)
//	counted   the counted events of the hours the window touches, per action, login and object (the 500 largest)
//	counted_by_category  the same hours' totals per category
//	series    per hour of the window: failed sign-ins, changes, counted reads, writes and the rest
//
// An hourly count belongs to the hour it happened in, so "the hours the window touches" starts at the full hour at
// or before the window's start and ends before the window's end (a window that ends on the hour does not take the
// next hour). A listed event is in the window by its own time, in every part.

const sqlMSSQLAuditRead = `
SELECT r.snapshot_at, r.defs_read, r.state_read, r.specs_read, r.db_specs_right, r.events_right, r.events_readable,
       r.text_stored, r.databases_read, r.databases_skipped, r.skipped_names, r.note
  FROM pgvigil.mssql_audit_read r
 WHERE r.instance_id = $1`

const sqlMSSQLAuditStatus = `
SELECT s.sampled, s.critical, s.warning, s.value, s.detail FROM pgvigil.mssql_audit_status s WHERE s.instance_id = $1`

const sqlMSSQLAuditFindings = `
SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_audit_findings
 WHERE instance_id = $1
 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, at DESC`

const sqlMSSQLAuditAudits = `
SELECT a.name, a.state, a.state_since, a.is_enabled, a.status, a.status_at, a.target, a.on_failure, a.queue_delay_ms,
       a.predicate, a.log_file_path, a.current_file, a.file_size_bytes, a.max_file_size_mb, a.max_rollover_files, a.max_files,
       a.reserve_disk_space, a.created_at, a.modified_at, a.read_state, a.read_note, a.new_events, a.counted_events,
       a.last_event_at, a.snapshot_at,
       (SELECT count(*) FROM pgvigil.mssql_audit_spec s
         WHERE s.instance_id = a.instance_id AND s.is_present AND s.audit_guid = a.audit_guid) AS specifications
  FROM pgvigil.mssql_audit a
 WHERE a.instance_id = $1 AND a.is_present
 ORDER BY a.name`

// one row per specification; its actions as one text, each with the object and principal a database action names
const sqlMSSQLAuditSpecs = `
SELECT s.scope, nullif(s.database_name, '') AS database_name, s.name, a.name AS audit_name, a.state AS audit_state,
       s.is_enabled, cardinality(s.action_names) AS action_count,
       (SELECT string_agg(x.txt, ', ' ORDER BY x.txt)
          FROM (SELECT (e->>'action') || coalesce(' on ' || nullif(e->>'object', ''), '') || coalesce(' by ' || nullif(e->>'principal', ''), '')
                       || CASE WHEN e->>'result' IN ('SUCCESS', 'FAILURE') THEN ' (' || lower(e->>'result') || ' only)' ELSE '' END AS txt
                  FROM jsonb_array_elements(s.actions) e) x) AS actions,
       s.modified, s.snapshot_at
  FROM pgvigil.mssql_audit_spec s
  LEFT JOIN pgvigil.mssql_audit a ON a.instance_id = s.instance_id AND a.audit_guid = s.audit_guid AND a.is_present
 WHERE s.instance_id = $1 AND s.is_present
 ORDER BY s.scope DESC, s.database_name, s.name`

// A read lists at most its row cap of one audit's events and counts the rest under their own category: a sign-in
// storm's failed sign-ins are then partly rows and partly a count, and both are this category's events. (DDL is
// also counted by design - tempdb, statistics - so a counted 'ddl' is not added to the listed DDL.)
const sqlMSSQLAuditByCategory = `
WITH e AS (
  SELECT e.category, count(*) AS listed, count(*) FILTER (WHERE NOT e.succeeded) AS not_succeeded,
         count(DISTINCT e.login_name) AS logins, max(e.event_at) AS last_at
    FROM pgvigil.mssql_audit_events e
   WHERE e.instance_id = $1 AND e.event_at > $2 AND e.event_at <= $3
   GROUP BY e.category
), c AS (
  SELECT c.category, sum(c.n) AS counted_over
    FROM pgvigil.mssql_audit_counts c
   WHERE c.instance_id = $1 AND c.category IN ('failed sign-in', 'audit', 'role', 'permission', 'principal')
     AND c.hour_at >= date_trunc('hour', $2::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AND c.hour_at < $3
   GROUP BY c.category
)
SELECT category, coalesce(e.listed, 0) AS listed, coalesce(c.counted_over, 0) AS counted_over,
       coalesce(e.listed, 0) + coalesce(c.counted_over, 0) AS events, coalesce(e.not_succeeded, 0) AS not_succeeded,
       coalesce(e.logins, 0) AS logins, e.last_at
  FROM e FULL JOIN c USING (category)
 ORDER BY CASE category WHEN 'failed sign-in' THEN 0 WHEN 'audit' THEN 1 WHEN 'role' THEN 2 WHEN 'permission' THEN 3
                        WHEN 'principal' THEN 4 ELSE 5 END`

// the two forms of the list: a statement of its own for one category, so that the planner's generic plan of the
// form without one never serves a filtered read (it could not use the category index)
const sqlMSSQLAuditEventsFmt = `
SELECT e.event_at, e.event_key, e.category, e.action, e.action_id, e.class_name, e.succeeded, e.login_name, e.session_login,
       e.target_login, e.target_user, e.database_name, e.schema_name, e.object_name, e.client_ip, e.application, e.host,
       e.session_id, e.reason, e.error_number, e.error_state, e.statement, e.audit_name
  FROM pgvigil.mssql_audit_events e
 WHERE e.instance_id = $1 AND e.event_at > $2 AND e.event_at <= $3%s
 ORDER BY e.event_at DESC, e.event_key
 LIMIT 1000`

var (
	sqlMSSQLAuditEvents           = fmt.Sprintf(sqlMSSQLAuditEventsFmt, "")
	sqlMSSQLAuditEventsOfCategory = fmt.Sprintf(sqlMSSQLAuditEventsFmt, " AND e.category = $4")
)

const sqlMSSQLAuditCounted = `
SELECT c.category, coalesce(nullif(c.action, ''), c.action_id) AS action, c.action_id, nullif(c.login_name, '') AS login_name,
       nullif(c.database_name, '') AS database_name, nullif(c.schema_name, '') AS schema_name,
       nullif(c.object_name, '') AS object_name, sum(c.n) AS events,
       coalesce(sum(c.n) FILTER (WHERE NOT c.succeeded), 0) AS not_succeeded,
       count(DISTINCT c.hour_at) AS hours, max(c.hour_at) AS last_hour
  FROM pgvigil.mssql_audit_counts c
 WHERE c.instance_id = $1
   AND c.hour_at >= date_trunc('hour', $2::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AND c.hour_at < $3
 GROUP BY c.category, c.action_id, c.action, c.login_name, c.database_name, c.schema_name, c.object_name
 ORDER BY sum(c.n) DESC, c.category, c.action_id, c.action, c.login_name, c.database_name, c.schema_name, c.object_name
 LIMIT 500`

const sqlMSSQLAuditCountedByCategory = `
SELECT c.category, sum(c.n) AS events, coalesce(sum(c.n) FILTER (WHERE NOT c.succeeded), 0) AS not_succeeded,
       count(DISTINCT nullif(c.login_name, '')) AS logins, count(DISTINCT (c.database_name, c.schema_name, c.object_name)) AS objects
  FROM pgvigil.mssql_audit_counts c
 WHERE c.instance_id = $1
   AND c.hour_at >= date_trunc('hour', $2::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AND c.hour_at < $3
 GROUP BY c.category
 ORDER BY sum(c.n) DESC, c.category`

// every hour the window touches (an empty hour is 0, so the chart's lines fall to the floor between two bursts).
// Failed sign-ins and changes are the listed events of the window plus what a read counted over its row cap.
const sqlMSSQLAuditSeries = `
WITH h AS (
  SELECT generate_series(date_trunc('hour', $2::timestamptz AT TIME ZONE 'UTC'),
                         date_trunc('hour', ($3::timestamptz - interval '1 microsecond') AT TIME ZONE 'UTC'),
                         interval '1 hour') AT TIME ZONE 'UTC' AS snapshot_at
), c AS (
  SELECT c.hour_at AS snapshot_at, sum(c.n) FILTER (WHERE c.category = 'read') AS reads,
         sum(c.n) FILTER (WHERE c.category = 'write') AS writes,
         sum(c.n) FILTER (WHERE c.category = 'failed sign-in') AS failed_over,
         sum(c.n) FILTER (WHERE c.category IN ('audit', 'role', 'permission', 'principal')) AS changes_over,
         sum(c.n) FILTER (WHERE c.category NOT IN ('read', 'write', 'failed sign-in', 'audit', 'role', 'permission', 'principal')) AS other_counted
    FROM pgvigil.mssql_audit_counts c
   WHERE c.instance_id = $1
     AND c.hour_at >= date_trunc('hour', $2::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AND c.hour_at < $3
   GROUP BY 1
), e AS (
  SELECT date_trunc('hour', e.event_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS snapshot_at,
         count(*) FILTER (WHERE e.category = 'failed sign-in') AS failed_signins,
         count(*) FILTER (WHERE e.category <> 'failed sign-in') AS changes
    FROM pgvigil.mssql_audit_events e
   WHERE e.instance_id = $1 AND e.event_at > $2 AND e.event_at <= $3
   GROUP BY 1
)
SELECT h.snapshot_at, coalesce(e.failed_signins, 0) + coalesce(c.failed_over, 0) AS failed_signins,
       coalesce(e.changes, 0) + coalesce(c.changes_over, 0) AS changes,
       coalesce(c.reads, 0) AS reads, coalesce(c.writes, 0) AS writes, coalesce(c.other_counted, 0) AS other_counted
  FROM h LEFT JOIN c USING (snapshot_at) LEFT JOIN e USING (snapshot_at)
 ORDER BY h.snapshot_at`

// mssqlAuditCategories are the categories of the listed events (internal/mssql/audit.go).
var mssqlAuditCategories = map[string]bool{"failed sign-in": true, "role": true, "permission": true, "principal": true, "ddl": true, "audit": true}

// MSSQLAudit serves the Audit tab of one SQL Server instance (?part= one of its parts, ?category= one category of
// the listed events).
func (s *Server) MSSQLAudit(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	events := part{"events", sqlMSSQLAuditEvents, []any{id, from, to}}
	if c := r.URL.Query().Get("category"); c != "" {
		if !mssqlAuditCategories[c] {
			writeErr(w, http.StatusBadRequest, errors.New("category must be one of failed sign-in, role, permission, principal, ddl, audit"))
			return
		}
		events = part{"events", sqlMSSQLAuditEventsOfCategory, []any{id, from, to, c}}
	}
	s.multiPart(w, r, []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_audit"}}},
		{"read", sqlMSSQLAuditRead, []any{id}},
		{"status", sqlMSSQLAuditStatus, []any{id}},
		{"findings", sqlMSSQLAuditFindings, []any{id}},
		{"audits", sqlMSSQLAuditAudits, []any{id}},
		{"specs", sqlMSSQLAuditSpecs, []any{id}},
		{"by_category", sqlMSSQLAuditByCategory, []any{id, from, to}},
		events,
		{"counted", sqlMSSQLAuditCounted, []any{id, from, to}},
		{"counted_by_category", sqlMSSQLAuditCountedByCategory, []any{id, from, to}},
		{"series", sqlMSSQLAuditSeries, []any{id, from, to}},
	})
}
