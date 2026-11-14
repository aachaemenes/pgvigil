package web

import (
	"net/http"
)

// The restore chain of a SQL Server database (task 304; migration 0147). GET /api/mssql/restore?instance=<id> answers
// per database the stored verdict (whole, broken, held while a replica's read is late, no full backup) with the read's
// counts; &db=<name> adds the steps a restore takes in order - each set's role, where it ran, its LSNs AS TEXT (an LSN
// has up to 25 digits: a JSON number would lose some in a browser) and pgvigil's marks - and every file of each step. The
// route is the lead's wiring in web.go. pgvigil writes no RESTORE statement and runs none.

// sqlMSSQLRestoreDatabases: $1 the instance.
const sqlMSSQLRestoreDatabases = `
SELECT v.database_name, v.state, v.verdict, v.restorable_to, v.steps, v.decided_at, r.read_at, r.logs_since, r.logs_sent,
       (r.logs_since > r.logs_sent) AS capped, r.server_gaps, b.recovery_model, b.ag_name, b.not_judged, b.replicas_unseen,
       i.platform
  FROM pgvigil.mssql_restore_verdicts v
  JOIN pgvigil.instances i ON i.instance_id = v.instance_id
  LEFT JOIN pgvigil.mssql_restore_reads r ON r.instance_id = v.instance_id AND r.database_name = v.database_name
  LEFT JOIN pgvigil.mssql_backup_judged b ON b.instance_id = v.instance_id AND b.database_name = v.database_name
 WHERE v.instance_id = $1
 ORDER BY CASE v.state WHEN 'broken' THEN 0 WHEN 'no full' THEN 1 WHEN 'held' THEN 2 ELSE 3 END, v.database_name`

// sqlMSSQLRestoreSteps: $1 the instance, $2 the database: the steps the last import decided (step 0 the verdict row).
const sqlMSSQLRestoreSteps = `
SELECT c.step, c.role, c.backup_set_uuid, c.from_instance, c.start_at, c.finish_at, c.first_lsn, c.last_lsn,
       c.family_count, c.mirror_count, c.media_position, c.user_name, c.marks, c.restorable_to
  FROM pgvigil.mssql_restore_steps c
 WHERE c.instance_id = $1 AND c.database_name = $2
 ORDER BY c.step = 0, c.step`

// sqlMSSQLRestoreFiles: $1 the instance, $2 the database. Every file of each set of the database's members (the page
// keeps those of the steps; mirror 0 is the copy a restore names).
const sqlMSSQLRestoreFiles = `
SELECT f.backup_set_uuid, f.family, f.mirror, f.device_kind, f.path, i.name AS from_instance
  FROM pgvigil.mssql_restore_files f
  JOIN pgvigil.mssql_restore_sets s ON s.instance_id = f.instance_id AND s.backup_set_uuid = f.backup_set_uuid
  JOIN pgvigil.mssql_restore_members($1, $2) m ON m.instance_id = f.instance_id
  JOIN pgvigil.instances i ON i.instance_id = f.instance_id
 WHERE s.database_name = $2
 ORDER BY s.last_lsn, f.backup_set_uuid, f.mirror, f.family`

// MSSQLRestore serves GET /api/mssql/restore.
func (s *Server) MSSQLRestore(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	parts := []part{{"databases", sqlMSSQLRestoreDatabases, []any{id}}}
	if db := r.URL.Query().Get("db"); db != "" {
		parts = append(parts, part{"steps", sqlMSSQLRestoreSteps, []any{id, db}}, part{"files", sqlMSSQLRestoreFiles, []any{id, db}})
	}
	s.multiPart(w, r, parts)
}
