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

// ---- task 301b (migration 0191, the collections mssql_backup_history and mssql_backup_checks): the database's backup
// history and restore history (the drill's two grids), the three checks' cells and findings, the default backup path.

// sqlMSSQLBackupHistory: $1 the instance, $2 the database. The newest 10 sets per type and copy-only that
// mssql_backup_history keeps, newest first: DBA Dash's Last Backup columns that msdb's history holds, in its order,
// then pgvigil's own; last_verify = the newest verify_backup of the set in the actions log that was sent (target_id =
// its uuid; a 'refused' row sent nothing and never hides a run's row; 0191's actions_log_verify_idx).
// mb_s and write_mb_s are cast to numeric before round: PostgreSQL 13's extract() is double precision, and 13 has no
// round(double precision, integer)
const sqlMSSQLBackupHistory = `
SELECT h.database_name, h.recovery_model, CASE h.backup_type WHEN 'D' THEN 'full' WHEN 'I' THEN 'diff' ELSE 'log' END AS backup_type,
       h.start_at, h.finish_at, extract(epoch FROM h.finish_at - h.start_at)::bigint AS duration_s, h.size_bytes,
       round((h.size_bytes / nullif(extract(epoch FROM h.finish_at - h.start_at), 0) / 1048576.0)::numeric, 1) AS mb_s, h.compressed_bytes,
       round((1 - h.compressed_bytes::numeric / nullif(h.size_bytes, 0)) * 100, 1) AS saving_pct,
       round((h.compressed_bytes / nullif(extract(epoch FROM h.finish_at - h.start_at), 0) / 1048576.0)::numeric, 1) AS write_mb_s,
       h.is_damaged, h.has_checksums,
       (h.compressed_bytes IS NOT NULL AND h.size_bytes IS NOT NULL AND h.compressed_bytes < h.size_bytes) AS is_compressed,
       h.is_password_protected, (h.key_algorithm IS NOT NULL AND h.key_algorithm <> 'NO_Encryption') AS is_encrypted,
       h.is_snapshot, h.has_bulk_logged_data, h.is_readonly, h.is_force_offline, h.is_single_user,
       h.key_algorithm, h.encryptor_type, h.compression_algorithm,
       h.path, h.family_count, h.position, h.device_kind, h.user_name, h.machine_name, h.server_name, h.set_name, h.is_copy_only,
       h.first_lsn, h.last_lsn, h.checkpoint_lsn, h.database_backup_lsn, h.differential_base_guid::text AS differential_base_guid,
       h.backup_set_uuid::text AS backup_set_uuid, h.backup_set_id,
       v.outcome AS verify_outcome, v.at AS verify_at, v.detail AS verify_detail, v.ui_user AS verify_user, h.read_at
  FROM pgvigil.mssql_backup_history h
  LEFT JOIN LATERAL (
       SELECT a.outcome, a.at, a.detail, a.ui_user FROM pgvigil.actions_log a
        WHERE a.instance_id = h.instance_id AND a.action = 'verify_backup' AND a.target_id = upper(h.backup_set_uuid::text)
          AND a.outcome <> 'refused'
        ORDER BY a.at DESC LIMIT 1) v ON true
 WHERE h.instance_id = $1 AND h.database_name = $2
 ORDER BY h.finish_at DESC, h.backup_set_id DESC`

// sqlMSSQLRestoreHistory: $1 the instance, $2 the destination database. The newest 20 restores per restore type
// mssql_restore_history keeps, newest first, with the backup set each restored.
const sqlMSSQLRestoreHistory = `
SELECT r.restore_at, r.destination_database_name, r.restore_type, r.user_name, r.is_replace, r.is_recovery, r.stop_at,
       r.source_server, r.source_database,
       CASE r.source_type WHEN 'D' THEN 'full' WHEN 'I' THEN 'diff' WHEN 'L' THEN 'log' ELSE r.source_type END AS source_type,
       r.source_finish_at, r.source_path, r.source_backup_set_uuid::text AS source_backup_set_uuid, r.restore_history_id, r.read_at
  FROM pgvigil.mssql_restore_history r
 WHERE r.instance_id = $1 AND r.destination_database_name = $2
 ORDER BY r.restore_at DESC, r.restore_history_id DESC`

// sqlMSSQLBackupCheckCells: $1 the instance, $2 a database (NULL = all). Per database of the last mssql_backup_checks
// read: pseudo-simple (Database#39) and the newest full / differential / log backup's file (Database#7), in words.
const sqlMSSQLBackupCheckCells = `
SELECT c.database_name, c.recovery_model, c.pseudo_simple, c.file_full, c.file_diff, c.file_log, c.read_at
  FROM pgvigil.mssql_backup_check_cells c
 WHERE c.instance_id = $1 AND ($2::text IS NULL OR c.database_name = $2)
 ORDER BY c.database_name`

// sqlMSSQLBackupPathCell: $1 the instance. The default backup path (Instance#14) and its words, the file check's state,
// and the two collections' last reads and runs.
const sqlMSSQLBackupPathCell = `
SELECT p.default_backup_path, p.default_backup_path_state, p.reachable, p.files_state, p.read_at AS checks_at,
       cur.restore_state, cur.read_at AS history_at,
       ch.status AS checks_status, ch.note AS checks_note, hh.status AS history_status, hh.note AS history_note
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.mssql_backup_path_cells p ON p.instance_id = i.instance_id
  LEFT JOIN pgvigil.mssql_backup_history_cursor cur ON cur.instance_id = i.instance_id
  LEFT JOIN pgvigil.collection_dates ch ON ch.instance_id = i.instance_id AND ch.collection = 'mssql_backup_checks'
  LEFT JOIN pgvigil.collection_dates hh ON hh.instance_id = i.instance_id AND hh.collection = 'mssql_backup_history'
 WHERE i.instance_id = $1`

// sqlMSSQLBackupCheckFindings: $1 the instance (NULL = every active SQL Server instance). The three findings of
// mssql_backup_check_findings (the Summary and pgvigil.findings take them through the join lines).
const sqlMSSQLBackupCheckFindings = `
SELECT f.severity, f.check_name, f.object, f.at, f.detail, f.instance_id, i.name AS instance
  FROM pgvigil.mssql_backup_check_findings f
  JOIN pgvigil.instances i ON i.instance_id = f.instance_id AND i.is_active
 WHERE ($1::int IS NULL OR f.instance_id = $1)
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.at DESC, i.name, f.object`

// MSSQLBackupFiles serves GET /api/mssql/backup_files (the route is the lead's wiring in web.go). Task 301b's parts
// ride it: checks, path and check_findings with an instance; history and restores only with a database too (a
// server's whole history is never one answer); check_findings with no instance for the fleet.
func (s *Server) MSSQLBackupFiles(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("instance") == "" {
		s.multiPart(w, r, []part{
			{"by_instance", sqlMSSQLBackupLocByInstance, nil},
			{"findings", sqlMSSQLBackupLocFindings, []any{nil}},
			{"check_findings", sqlMSSQLBackupCheckFindings, []any{nil}},
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
	parts := []part{
		{"sets", sqlMSSQLBackupSets, []any{id, db}},
		{"files", sqlMSSQLBackupFileRows, []any{id, db}},
		{"writers", sqlMSSQLBackupWriterRows, []any{id, db}},
		{"roots", sqlMSSQLBackupRootRows, []any{id, db}},
		{"findings", sqlMSSQLBackupLocFindings, []any{id}},
		{"read", sqlMSSQLBackupFilesRead, []any{id}},
		{"checks", sqlMSSQLBackupCheckCells, []any{id, db}},
		{"path", sqlMSSQLBackupPathCell, []any{id}},
		{"check_findings", sqlMSSQLBackupCheckFindings, []any{id}},
	}
	if db != nil {
		parts = append(parts, part{"history", sqlMSSQLBackupHistory, []any{id, db}}, part{"restores", sqlMSSQLRestoreHistory, []any{id, db}})
	}
	s.multiPart(w, r, parts)
}
