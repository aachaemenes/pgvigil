package web

import "net/http"

// The backups API (task 33): one instance's Backups tab and the fleet Backups root. The join wires the routes in
// Handler (GET /api/backups -> s.Backups, GET /api/backups/fleet -> s.BackupsFleet); the overview check below
// feeds the Summary column Backups (check_group 'backups').

func init() {
	overviewChecks = append(overviewChecks, struct{ name, sql string }{"backups", `
SELECT c.instance_id, c.severity, c.check_name, c.object, c.at, c.detail
  FROM pgvigil.backup_checks c JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active`})
}

// sqlBackupsStatus is the instance's one status row: the archiver, the cloud side, the newest snapshots.
const sqlBackupsStatus = `
SELECT archive_mode, archive_set, is_replica, archiving, archived_count, failed_count, last_archived_wal, last_archived_time,
       last_failed_wal, last_failed_time, stats_reset, archive_lag_bytes, wal_segment_bytes, archive_warn_minutes, archive_age_s,
       archiver_failing, wal_waiting, archiver_read_at, cloud_resource, resource_kind, retention_days, latest_restorable_time,
       earliest_restorable_time, backup_window, restorable_age_s, cloud_read_at, newest_automated_at, newest_manual_at,
       newest_snapshot_at, newest_snapshot_age_s, automated_count, manual_count
  FROM pgvigil.backup_status
 WHERE instance_id = $1`

// sqlBackupsSnapshots is the instance's listed snapshots, the newest first.
const sqlBackupsSnapshots = `
SELECT name AS snapshot, snapshot_type, status, created_at, allocated_gib, encrypted, snapshot_at
  FROM pgvigil.backup_state
 WHERE instance_id = $1 AND kind = 'snapshot' AND is_present
 ORDER BY created_at DESC NULLS LAST, name`

// sqlBackupsSeries is the archiver over the window per $4-second bucket: the files archived and failed in the
// bucket (the counter's rise; a fall is a stats reset and counts from zero), the archive lag at its largest and
// the cloud restore point's age.
const sqlBackupsSeries = `
WITH s AS (
  SELECT snapshot_at, archive_lag_bytes, restorable_age_s,
         CASE WHEN archived_count >= lag(archived_count) OVER w THEN archived_count - lag(archived_count) OVER w ELSE archived_count END AS archived,
         CASE WHEN failed_count >= lag(failed_count) OVER w THEN failed_count - lag(failed_count) OVER w ELSE failed_count END AS failed,
         lag(snapshot_at) OVER w AS prev_at
    FROM pgvigil.backup_sample
   WHERE instance_id = $1 AND snapshot_at > $2::timestamptz - interval '1 hour' AND snapshot_at <= $3
  WINDOW w AS (ORDER BY snapshot_at)
)
SELECT to_timestamp(floor(extract(epoch FROM snapshot_at) / $4) * $4) AS snapshot_at,
       sum(archived)::bigint AS archived, sum(failed)::bigint AS failed, max(archive_lag_bytes) AS archive_lag_bytes, max(restorable_age_s) AS restorable_age_s
  FROM s
 WHERE snapshot_at > $2 AND prev_at IS NOT NULL
 GROUP BY 1 ORDER BY 1`

// sqlBackupsFindings is the instance's rule hits on reads of the last hour, the most severe first.
const sqlBackupsFindings = `
SELECT severity, setting, value, suggested, detail, at
  FROM pgvigil.backup_findings
 WHERE instance_id = $1
 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, setting`

// sqlBackupsFleet is every active instance's status row with its count of rule hits, the failing first.
const sqlBackupsFleet = `
SELECT b.instance_id, b.instance, b.platform, b.archive_mode, b.is_replica, b.archiving, b.wal_waiting, b.archive_warn_minutes, b.archived_count, b.failed_count, b.last_archived_time, b.archive_age_s,
       b.archive_lag_bytes, b.archiver_failing, b.retention_days, b.restorable_age_s, b.newest_snapshot_at, b.newest_snapshot_age_s,
       (SELECT count(*) FROM pgvigil.backup_checks h WHERE h.instance_id = b.instance_id) AS findings,
       (SELECT CASE WHEN bool_or(h.severity = 'critical') THEN 'critical' WHEN count(*) > 0 THEN 'warning' END
          FROM pgvigil.backup_checks h WHERE h.instance_id = b.instance_id) AS worst,
       greatest(b.archiver_read_at, b.cloud_read_at) AS snapshot_at
  FROM pgvigil.backup_status b
 ORDER BY b.archiver_failing DESC NULLS LAST, findings DESC, b.instance`

// Backups is one instance's Backups tab.
func (s *Server) Backups(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	bucket := int(to.Sub(from).Seconds()) / 300
	if bucket < 300 {
		bucket = 300
	}
	s.multi(w, r, []part{
		{"status", sqlBackupsStatus, []any{id}},
		{"snapshots", sqlBackupsSnapshots, []any{id}},
		{"series", sqlBackupsSeries, []any{id, from, to, bucket}},
		{"findings", sqlBackupsFindings, []any{id}},
	})
}

// BackupsFleet is the fleet Backups root: every instance's archiver and cloud backups, the failing first.
func (s *Server) BackupsFleet(w http.ResponseWriter, r *http.Request) {
	s.multi(w, r, []part{{"instances", sqlBackupsFleet, nil}})
}
