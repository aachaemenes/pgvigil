package web

import (
	"net/http"
)

// Where a SQL Server database's newest backups went (task 301; migration 0140, the collection mssql_backup_files).
// GET /api/mssql/backup_files?instance=<id>[&db=<name>] serves the Backups tab's panel - DBA Dash's Last Backup grid
// (its drill from a database) with pgvigil's own columns after DBA Dash's - and its Files, writers and destinations;
// with no instance, the fleet's per-instance texts (DBA Dash's Summary 'n/m' and 'NAME(count)') and the findings of
// every active SQL Server instance. The Detail grid's added cells come with /api/mssql/backups itself (the lead's
// join of mssql_backup_loc_db into sqlMSSQLBackups).

// sqlMSSQLBackupSets: $1 the instance, $2 a database (NULL = all). One row per set mssql_backup_locations keeps: the
// newest of each type (shown) and, beside a copy-only full, the newest full that is not copy-only (judged); DBA Dash's
// Last Backup columns in its order, then pgvigil's own. Is Partner Backup / Partner = the set ran on another replica of
// the database's availability group.
const sqlMSSQLBackupSets = `
SELECT l.database_name, l.recovery_model, l.backup_type, l.start_at, l.finish_at, l.duration_s, l.size_bytes,
       round(l.size_bytes / nullif(l.duration_s, 0) / 1048576.0, 1) AS mb_s, l.compressed_bytes,
       round((1 - l.compressed_bytes::numeric / nullif(l.size_bytes, 0)) * 100, 1) AS saving_pct,
       round(l.compressed_bytes / nullif(l.duration_s, 0) / 1048576.0, 1) AS write_mb_s,
       (l.from_instance_id <> l.instance_id) AS is_partner, CASE WHEN l.from_instance_id <> l.instance_id THEN l.from_instance END AS partner,
       l.is_damaged, l.has_checksums, l.is_compressed, l.is_password_protected, l.is_encrypted, l.is_snapshot, l.has_bulk_logged_data,
       l.is_readonly, l.is_force_offline, l.is_single_user, l.key_algorithm, l.encryptor_type, l.compression_algorithm,
       l.folder, l.family_count, l.mirror_count, l.device_kind, l.user_name, l.machine_name, l.set_name, l.description,
       l.software_name, l.is_copy_only, l.has_incomplete_metadata, l.diff_base, l.media_password, l.last_valid_restore_at,
       l.roots, l.shown, l.judged, l.same_volume, l.not_judged, l.replicas_unseen, l.ag_name, l.from_instance, l.from_instance_id,
       l.backup_set_id, l.instance_id
  FROM pgvigil.mssql_backup_locations l
 WHERE l.instance_id = $1 AND ($2::text IS NULL OR l.database_name = $2)
 ORDER BY l.database_name, CASE l.backup_type WHEN 'full' THEN 0 WHEN 'diff' THEN 1 ELSE 2 END, l.shown DESC, l.finish_at DESC`

// sqlMSSQLBackupFileRows: $1 the instance, $2 a database (NULL = all). Every media family and mirror of each set of
// sqlMSSQLBackupSets, the path whole (the export's Files sheet carries every one of them).
const sqlMSSQLBackupFileRows = `
SELECT l.database_name, l.backup_type, l.is_copy_only, l.shown, f.family, l.family_count, f.mirror, l.mirror_count, f.device_kind,
       f.logical_name, f.path, f.root, l.finish_at, l.from_instance
  FROM pgvigil.mssql_backup_locations l
  JOIN pgvigil.mssql_backup_files f ON f.instance_id = l.from_instance_id AND f.database_name = l.database_name
       AND f.backup_type = l.backup_type AND f.is_copy_only = l.is_copy_only AND f.backup_set_id = l.backup_set_id
 WHERE l.instance_id = $1 AND ($2::text IS NULL OR l.database_name = $2)
 ORDER BY l.database_name, CASE l.backup_type WHEN 'full' THEN 0 WHEN 'diff' THEN 1 ELSE 2 END, l.shown DESC, f.family, f.mirror`

// sqlMSSQLBackupWriterRows: $1, $2 as above. The log backups of the last 7 days by destination; 'note' = two logins or
// more writing to one destination (no finding: one job run by hand, or a service account changed, keeps one chain).
const sqlMSSQLBackupWriterRows = `
SELECT w.database_name, w.device_kind, w.root, array_to_string(w.users, ', ') AS users, w.sets, w.first_at, w.last_at,
       CASE WHEN cardinality(w.users) > 1 THEN cardinality(w.users) || ' logins write log backups to this destination' END AS note,
       (SELECT count(*) FROM pgvigil.mssql_backup_writers x WHERE x.instance_id = w.instance_id AND x.database_name = w.database_name) AS destinations,
       w.snapshot_at
  FROM pgvigil.mssql_backup_writers w
 WHERE w.instance_id = $1 AND ($2::text IS NULL OR w.database_name = $2)
 ORDER BY w.database_name, w.last_at DESC`

// sqlMSSQLBackupRootRows: $1, $2 as above. Every destination root a database's backups (not copy-only) were seen at.
const sqlMSSQLBackupRootRows = `
SELECT r.database_name, r.backup_type, r.root, r.first_seen, r.last_seen
  FROM pgvigil.mssql_backup_roots_seen r
 WHERE r.instance_id = $1 AND ($2::text IS NULL OR r.database_name = $2)
 ORDER BY r.database_name, CASE r.backup_type WHEN 'full' THEN 0 WHEN 'diff' THEN 1 ELSE 2 END, r.last_seen DESC`

// sqlMSSQLBackupLocFindings: $1 the instance (NULL = every active SQL Server instance).
const sqlMSSQLBackupLocFindings = `
SELECT f.severity, f.check_name, f.object, f.at, f.detail, f.instance_id, i.name AS instance
  FROM pgvigil.mssql_backup_loc_findings f
  JOIN pgvigil.instances i ON i.instance_id = f.instance_id AND i.is_active
 WHERE ($1::int IS NULL OR f.instance_id = $1)
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.at DESC, i.name, f.object`

// sqlMSSQLBackupFilesRead: $1 the instance. The collection's last read and last run.
const sqlMSSQLBackupFilesRead = `
SELECT r.snapshot_at, r.row_count, c.status, c.note, c.snapshot_at AS run_at, cur.last_set_id, cur.updated_at AS cursor_at
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.mssql_hadr_reads r ON r.instance_id = i.instance_id AND r.collection = 'mssql_backup_files'
  LEFT JOIN pgvigil.collection_dates c ON c.instance_id = i.instance_id AND c.collection = 'mssql_backup_files'
  LEFT JOIN pgvigil.mssql_backup_files_cursor cur ON cur.instance_id = i.instance_id
 WHERE i.instance_id = $1`

// sqlMSSQLBackupLocByInstance: every active SQL Server instance's DBA Dash Summary texts (mssql_backup_loc_inst).
const sqlMSSQLBackupLocByInstance = `
SELECT i.instance_id, i.name AS instance, x.full_checksums, x.diff_checksums, x.log_checksums, x.full_compressed, x.diff_compressed,
       x.log_compressed, x.full_password, x.diff_password, x.log_password, x.full_encrypted, x.diff_encrypted, x.log_encrypted,
       x.full_algorithms, x.diff_algorithms, x.log_algorithms
  FROM pgvigil.instances i
  JOIN pgvigil.mssql_backup_loc_inst x ON x.instance_id = i.instance_id
 WHERE i.is_active AND i.engine = 'sqlserver'
 ORDER BY i.name`

// MSSQLBackupFiles serves GET /api/mssql/backup_files (the route is the lead's wiring in web.go).
func (s *Server) MSSQLBackupFiles(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("instance") == "" {
		s.multiPart(w, r, []part{
			{"by_instance", sqlMSSQLBackupLocByInstance, nil},
			{"findings", sqlMSSQLBackupLocFindings, []any{nil}},
		})
		return
	}
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var db any
	if v := q.Get("db"); v != "" {
		db = v
	}
	s.multiPart(w, r, []part{
		{"sets", sqlMSSQLBackupSets, []any{id, db}},
		{"files", sqlMSSQLBackupFileRows, []any{id, db}},
		{"writers", sqlMSSQLBackupWriterRows, []any{id, db}},
		{"roots", sqlMSSQLBackupRootRows, []any{id, db}},
		{"findings", sqlMSSQLBackupLocFindings, []any{id}},
		{"read", sqlMSSQLBackupFilesRead, []any{id}},
	})
}
