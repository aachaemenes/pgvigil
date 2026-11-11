package web

import (
	"net/http"
)

// The Audit page of a PostgreSQL instance (task 157, pgaudit; migration 0100).
//
// GET /api/pgaudit?instance=<id>&[from=&to=] (Server.PgAudit):
//
//	health    one row: the status cell (ok | warning | off) and its text, whether the library is loaded, the server's
//	          pgaudit.log and pgaudit.role, how many databases and roles set their own values, whether parameters reach
//	          the log, where the log goes, whether the audit lines are read (and why not), whether the instance keeps
//	          statement text, the newest entry seen; no row: the pgaudit collection has not read the instance
//	settings  every pgaudit.* setting in force somewhere (server, database, role, role in database)
//	databases the databases the extensions collection has read, each with whether the pgaudit extension is created
//	findings  the audit findings of the instance (pgvigil.pgaudit_findings: the health findings and the rules firing)
//	rules     the alert rules with the entries inside each one's own window
//	events    the entries kept as rows in the window (ROLE, DDL, the SETs that matter), newest first, 1,000 at most
//	signins   the failed sign-ins of the window (the log readers' auth_fail events), newest first, 500 at most
//	counts    the counted entries of the window (READ, WRITE, FUNCTION, MISC, the other SETs) per role, database, class,
//	          command and object, the 2,000 largest. The counts are per UTC hour, a row stamped with its hour's start:
//	          every hour that overlaps the window is taken whole (the hour the window starts in and the one it ends in)
//	hours     the same entries per hour (snapshot_at) and class (a chart's series)
//
// ?part= reads one part. GET /api/pgaudit with no instance is the fleet's cell (part instances): one row per active
// PostgreSQL instance the collection has read.

const sqlPgAuditHealth = `SELECT * FROM pgvigil.pgaudit_health WHERE instance_id = $1`

const sqlPgAuditSettings = `
SELECT scope, nullif(datname, '') AS datname, nullif(rolname, '') AS rolname, name, value, source, snapshot_at
  FROM pgvigil.pgaudit_settings
 WHERE instance_id = $1
 ORDER BY CASE scope WHEN 'server' THEN 0 WHEN 'database' THEN 1 WHEN 'role' THEN 2 ELSE 3 END, datname, rolname, name`

const sqlPgAuditDatabases = `
SELECT e.datname, bool_or(e.name = 'pgaudit') AS created, max(e.version) FILTER (WHERE e.name = 'pgaudit') AS version,
       max(e.snapshot_at) AS read_at
  FROM pgvigil.database_extensions e
 WHERE e.instance_id = $1 AND e.is_present
 GROUP BY e.datname
 ORDER BY e.datname`

const sqlPgAuditFindings = `
SELECT severity, setting, value, suggested, detail, at
  FROM pgvigil.pgaudit_findings
 WHERE instance_id = $1
 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, setting`

// every rule, enabled or not: a rule switched off shows as off with no count
const sqlPgAuditRules = `
SELECT r.rule_id, r.name, r.what, r.command_like, r.object_like, r.min_count, r.window_minutes, r.severity, r.is_enabled, r.note,
       h.hits, h.last_at, coalesce(h.hits >= r.min_count, false) AS fires
  FROM pgvigil.pgaudit_rules r
  LEFT JOIN pgvigil.pgaudit_rule_hits h ON h.rule_id = r.rule_id AND h.instance_id = $1
 ORDER BY r.is_enabled DESC, r.rule_id`

const sqlPgAuditEvents = `
SELECT snapshot_at AS at, usename, datname, client, class, command, object_type, object_name, target_role, audit_type,
       row_count, statement, parameters, pid
  FROM pgvigil.pgaudit_events
 WHERE instance_id = $1 AND snapshot_at > $2 AND snapshot_at <= $3
 ORDER BY snapshot_at DESC, pid, statement_id DESC, substatement_id DESC, event_key
 LIMIT 1000`

const sqlPgAuditSignins = `
SELECT snapshot_at AS at, usename, datname, client, detail
  FROM pgvigil.log_events
 WHERE instance_id = $1 AND kind = 'auth_fail' AND snapshot_at > $2 AND snapshot_at <= $3
 ORDER BY snapshot_at DESC
 LIMIT 500`

const sqlPgAuditCounts = `
SELECT nullif(usename, '') AS usename, nullif(datname, '') AS datname, class, command, nullif(object_type, '') AS object_type,
       nullif(object_name, '') AS object_name, sum(entries)::bigint AS entries, min(snapshot_at) AS first_hour, max(snapshot_at) AS last_hour
  FROM pgvigil.pgaudit_counts
 WHERE instance_id = $1 AND snapshot_at > $2::timestamptz - interval '1 hour' AND snapshot_at < $3
 GROUP BY usename, datname, class, command, object_type, object_name
 ORDER BY sum(entries) DESC, usename, datname, class, command, object_type, object_name
 LIMIT 2000`

const sqlPgAuditHours = `
SELECT snapshot_at, class, sum(entries)::bigint AS entries
  FROM pgvigil.pgaudit_counts
 WHERE instance_id = $1 AND snapshot_at > $2::timestamptz - interval '1 hour' AND snapshot_at < $3
 GROUP BY snapshot_at, class
 ORDER BY snapshot_at, class`

const sqlPgAuditFleet = `
SELECT i.instance_id, i.name AS instance, h.status, h.cell, h.loaded, h.log_read, h.log_read_reason, h.keep_text,
       h.last_entry_at, h.snapshot_at,
       (SELECT count(*) FROM pgvigil.pgaudit_findings f WHERE f.instance_id = i.instance_id) AS findings
  FROM pgvigil.instances i
  JOIN pgvigil.pgaudit_health h ON h.instance_id = i.instance_id
 WHERE i.is_active AND i.engine = 'postgres'
 ORDER BY i.name`

// PgAudit serves the audit page of one instance, or the fleet's cells when no instance is named.
func (s *Server) PgAudit(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("instance") == "" {
		s.multi(w, r, []part{{"instances", sqlPgAuditFleet, nil}})
		return
	}
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"health", sqlPgAuditHealth, []any{id}},
		{"settings", sqlPgAuditSettings, []any{id}},
		{"databases", sqlPgAuditDatabases, []any{id}},
		{"findings", sqlPgAuditFindings, []any{id}},
		{"rules", sqlPgAuditRules, []any{id}},
		{"events", sqlPgAuditEvents, []any{id, from, to}},
		{"signins", sqlPgAuditSignins, []any{id, from, to}},
		{"counts", sqlPgAuditCounts, []any{id, from, to}},
		{"hours", sqlPgAuditHours, []any{id, from, to}},
	})
}
