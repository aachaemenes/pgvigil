package web

import (
	"net/http"
)

// The maintenance of a SQL Server instance (task 410, migration 0161): GET /api/mssql/maintenance is the Maintenance
// tab - every rule of Ola Hallengren's solution and of data purity, met or not; where the solution is, its objects and
// versions, each database's purity flag; the jobs that run it with their schedules and outcomes; the last maintenance
// of each database; the CommandLog over the window, failures first; and whether the collections it rests on ran.
// A PostgreSQL instance has no row in 0161's tables and gets empty parts.

// sqlMaintChecks: every rule of the instance; the deviations first.
const sqlMaintChecks = `
SELECT rule, check_name, object, value, expected, set_at, source, status, detail, at
  FROM pgvigil.mssql_maintenance_checks_of($1)
 ORDER BY CASE status WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 WHEN 'info' THEN 3 WHEN 'ok' THEN 4
                      WHEN 'not read' THEN 5 WHEN 'not applicable' THEN 6 ELSE 7 END, check_name, object`

const sqlMaintParts = `SELECT part, is_read, note, snapshot_at FROM pgvigil.mssql_maint_part WHERE instance_id = $1 ORDER BY part`

// sqlMaintDatabases: each database the read looked into (or could not), the solution's objects there, its purity.
const sqlMaintDatabases = `
SELECT database_name, install_read, note, objects, versions, commandlog_note, purity_read, purity_note, create_version, dbcc_flags,
       purity_on, snapshot_at
  FROM pgvigil.mssql_maint_database WHERE instance_id = $1 ORDER BY database_name`

// sqlMaintJobs: the jobs that run the solution as 0161's rules match them (mssql_ola_matched_jobs: by what a step
// calls, else Ola's description and the role's name), each with its role, its schedules, its last run and the
// clean-up age its role's steps name.
const sqlMaintJobs = `
SELECT m.role, j.job_id, j.name, j.enabled, j.enabled_schedules, j.schedule_text, j.next_run_at, j.last_outcome, j.last_run_at, j.last_duration_s,
       j.running_since, j.description = 'Source: https://ola.hallengren.com' AS ola_made,
       (SELECT CASE WHEN a.age = -1 THEN 'never removed' WHEN a.age IS NOT NULL THEN a.age || ' ' || r.age_kind END
          FROM pgvigil.mssql_ola_roles() r CROSS JOIN LATERAL (SELECT pgvigil.mssql_ola_age(m.command, r.age_kind) AS age) a
         WHERE r.role = m.role AND r.age_kind IS NOT NULL) AS cleanup_age,
       j.snapshot_at
  FROM pgvigil.mssql_ola_matched_jobs($1) m
  JOIN pgvigil.mssql_jobs j ON j.instance_id = $1 AND j.job_id = m.job_id
 ORDER BY j.name, m.role`

// sqlMaintLast: each database's last maintenance - the newest successful command of each kind, as the import keeps it
// in mssql_maint_last (a row per database and kind: never a scan of the CommandLog rows). A backup's kind is told by
// the collector on the server from the whole command; the integrity check is the CHECKDB family (CHECKDB, CHECKALLOC,
// CHECKTABLE, CHECKCATALOG, CHECKFILEGROUP); the newest index or statistics command with its duration; the failed
// commands stored.
const sqlMaintLast = `
WITH l AS (
  SELECT l.db,
         max(l.last_at) FILTER (WHERE l.kind = 'full') AS last_full, max(l.last_at) FILTER (WHERE l.kind = 'diff') AS last_diff,
         max(l.last_at) FILTER (WHERE l.kind = 'log') AS last_log, max(l.last_at) FILTER (WHERE l.kind = 'integrity') AS last_integrity,
         max(l.last_at) FILTER (WHERE l.kind = 'index') AS last_index,
         (array_agg(l.seconds ORDER BY l.last_at DESC) FILTER (WHERE l.kind = 'index'))[1] AS index_seconds
    FROM pgvigil.mssql_maint_last l WHERE l.instance_id = $1 GROUP BY l.db
), f AS (
  SELECT c.db, count(*) AS failed FROM pgvigil.mssql_ola_commandlog c
   WHERE c.instance_id = $1 AND c.status = 'failed' AND c.db IS NOT NULL GROUP BY c.db
)
SELECT coalesce(l.db, f.db) AS database_name, l.last_full, l.last_diff, l.last_log, l.last_integrity, l.last_index, l.index_seconds,
       coalesce(f.failed, 0) AS failed
  FROM l FULL JOIN f ON f.db = l.db
 ORDER BY 1`

// sqlMaintCommandLog: the CommandLog over the window, failures first, at most 2,000 rows.
const sqlMaintCommandLog = `
SELECT c.database_name AS log_database, c.id, c.db AS database_name, c.schema_name, c.object_name, c.index_name, c.statistics_name,
       c.command_type, c.start_at, c.end_at, extract(epoch FROM c.end_at - c.start_at)::numeric(12, 1) AS seconds, c.error_number,
       c.error_message, c.status
  FROM pgvigil.mssql_ola_commandlog c
 WHERE c.instance_id = $1 AND c.start_at >= $2 AND c.start_at < $3
 ORDER BY (c.status = 'failed') DESC, c.start_at DESC
 LIMIT 2000`

// sqlMaintRuns: each collection the tab rests on, with its newest run.
const sqlMaintRuns = `
SELECT w.collection, d.snapshot_at, d.status, d.note
  FROM (VALUES ('mssql_maintenance'), ('mssql_jobs'), ('mssql_confcheck')) w (collection)
  LEFT JOIN pgvigil.collection_dates d ON d.instance_id = $1 AND d.collection = w.collection`

// MSSQLMaintenance is GET /api/mssql/maintenance?instance=N[&from=&to=][&part=...].
func (s *Server) MSSQLMaintenance(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"checks", sqlMaintChecks, []any{id}},
		{"parts", sqlMaintParts, []any{id}},
		{"databases", sqlMaintDatabases, []any{id}},
		{"jobs", sqlMaintJobs, []any{id}},
		{"last", sqlMaintLast, []any{id}},
		{"commandlog", sqlMaintCommandLog, []any{id, from, to}},
		{"runs", sqlMaintRuns, []any{id}},
	})
}
