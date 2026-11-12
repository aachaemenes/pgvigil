package web

import (
	"net/http"
)

// The Jobs and Backups tabs of a SQL Server instance (task 98).
//
// GET /api/mssql/jobs?instance=<id>&[from=&to=] (Server.MSSQLJobs): the Agent jobs as last read (owner, enabled,
// schedules, next run, the last outcome with its duration and message, the steps), the jobs running now, the failed
// runs of the window (each failed job outcome with the step that failed and its message), the runs per job over the
// window, and the job findings.
//
// GET /api/mssql/backups?instance=<id> (Server.MSSQLBackups): per database the last full, differential and log
// backup with where it ran (its size, duration and device where it ran on this server: msdb is each server's own
// record), the three ages at the read against the thresholds in force, why a database is not judged, and the
// backup findings. The window does not apply: the tab is the state at the last read.

const sqlMSSQLJobs = `
SELECT j.name, j.enabled, j.category, j.owner, j.schedule_names, j.schedules, j.enabled_schedules, j.next_run_at,
       j.last_outcome,
       CASE j.last_outcome WHEN 0 THEN 'failed' WHEN 1 THEN 'succeeded' WHEN 2 THEN 'retry' WHEN 3 THEN 'cancelled'
                           WHEN 4 THEN 'in progress' WHEN 5 THEN 'never run' END AS last_outcome_text,
       j.last_run_at, j.last_duration_s, j.last_message, j.running_since, j.description, j.modified_at, j.steps, j.job_id, j.snapshot_at
  FROM pgvigil.mssql_jobs j
 WHERE j.instance_id = $1
 ORDER BY (j.last_outcome = 0) DESC NULLS LAST, j.name`

// sqlMSSQLJobsRunning: the jobs running at the read with the average and the 95th percentile of their good runs (the
// job outcome rows, step 0, of the last 31 days) and the run so far as a percentage of the average (task 177 D14,
// PerformanceMonitor's Running Jobs: PERCENTILE_CONT(0.95) over the job's successful outcome rows, percent of average)
const sqlMSSQLJobsRunning = `
SELECT j.name, j.running_since, extract(epoch FROM j.snapshot_at - j.running_since)::bigint AS running_s, j.running_after_step,
       g.avg_duration_s, g.p95_duration_s, g.good_runs,
       round(100.0 * extract(epoch FROM j.snapshot_at - j.running_since) / nullif(g.avg_duration_s, 0), 1) AS pct_of_avg,
       j.snapshot_at
  FROM pgvigil.mssql_jobs j
  LEFT JOIN LATERAL (SELECT round(avg(r.duration_s)) AS avg_duration_s,
                            round(percentile_cont(0.95) WITHIN GROUP (ORDER BY r.duration_s)::numeric) AS p95_duration_s,
                            count(*) AS good_runs
                       FROM pgvigil.mssql_job_runs r
                      WHERE r.instance_id = j.instance_id AND r.job_id = j.job_id AND r.step_id = 0 AND r.run_status = 1
                        AND r.snapshot_at > now() - interval '31 days') g ON true
 WHERE j.instance_id = $1 AND j.running_since IS NOT NULL
 ORDER BY j.running_since`

// a failed job outcome (step 0) of the window with the step that failed in that run; a step that failed in a run
// whose outcome row is not read yet is listed by itself
const sqlMSSQLJobsFailed = `
SELECT r.snapshot_at AS run_at, coalesce(r.job_name, r.job_id) AS job, s.step_id, s.step_name,
       coalesce(s.message, r.message) AS message, r.duration_s, s.sql_message_id, s.sql_severity, r.message AS outcome_message
  FROM pgvigil.mssql_job_runs r
  LEFT JOIN LATERAL (SELECT x.step_id, x.step_name, x.message, x.sql_message_id, x.sql_severity FROM pgvigil.mssql_job_runs x
                      WHERE x.instance_id = r.instance_id AND x.job_id = r.job_id AND x.step_id > 0 AND x.run_status = 0
                        AND x.snapshot_at >= r.snapshot_at - interval '1 second'
                        AND x.snapshot_at <= r.snapshot_at + make_interval(secs => coalesce(r.duration_s, 0) + 60)
                        AND x.history_id < r.history_id
                      ORDER BY x.history_id DESC LIMIT 1) s ON true
 WHERE r.instance_id = $1 AND r.step_id = 0 AND r.run_status = 0 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
 ORDER BY r.snapshot_at DESC
 LIMIT 500`

const sqlMSSQLJobsRuns = `
SELECT coalesce(max(r.job_name), r.job_id) AS job, count(*) AS runs, count(*) FILTER (WHERE r.run_status = 1) AS succeeded,
       count(*) FILTER (WHERE r.run_status = 0) AS failed, count(*) FILTER (WHERE r.run_status = 3) AS cancelled,
       round(avg(r.duration_s) FILTER (WHERE r.run_status = 1)) AS avg_duration_s, max(r.duration_s) AS max_duration_s,
       max(r.snapshot_at) AS last_run_at
  FROM pgvigil.mssql_job_runs r
 WHERE r.instance_id = $1 AND r.step_id = 0 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
 GROUP BY r.job_id
 ORDER BY count(*) FILTER (WHERE r.run_status = 0) DESC, 1`

const sqlMSSQLJobsFindings = `
SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_jobs_findings
 WHERE instance_id = $1 AND check_name IN ('a job failed', 'a job runs far longer than its average')
 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, at DESC`

// the collection's last run (a skipped run stores no read: its reason is the note) with the last read beside it
const sqlMSSQLJobsRead = `
SELECT c.snapshot_at AS run_at, c.status, c.note, r.snapshot_at, r.row_count,
       (SELECT last_history_id FROM pgvigil.mssql_jobs_cursor x WHERE x.instance_id = c.instance_id) AS history_cursor
  FROM pgvigil.collection_dates c
  LEFT JOIN pgvigil.mssql_hadr_reads r ON r.instance_id = c.instance_id AND r.collection = c.collection
 WHERE c.instance_id = $1 AND c.collection = 'mssql_jobs'`

// MSSQLJobs serves the Jobs tab of one SQL Server instance.
func (s *Server) MSSQLJobs(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"jobs", sqlMSSQLJobs, []any{id}},
		{"running", sqlMSSQLJobsRunning, []any{id}},
		{"failed", sqlMSSQLJobsFailed, []any{id, from, to}},
		{"runs", sqlMSSQLJobsRuns, []any{id, from, to}},
		{"findings", sqlMSSQLJobsFindings, []any{id}},
		{"read", sqlMSSQLJobsRead, []any{id}},
	})
}

const sqlMSSQLBackups = `
SELECT b.database_name, b.state, b.recovery_model, b.ag_name, b.replicas_total, b.replicas_monitored, b.replicas_unseen, b.not_judged,
       b.full_at, b.full_from, b.full_age_hours, b.full_status, b.full_copy_only,
       b.diff_at, b.diff_from, b.diff_age_hours, b.diff_status,
       b.log_at, b.log_from, b.log_age_minutes, b.log_status,
       b.nul_at, b.nul_type, b.nul_from, b.created_at, b.snapshot_at,
       -- the size, duration and device are this server's own record: shown only where the backup shown ran here
       CASE WHEN b.full_from = b.instance THEN s.full_bytes END AS full_bytes,
       CASE WHEN b.full_from = b.instance THEN s.full_compressed_bytes END AS full_compressed_bytes,
       CASE WHEN b.full_from = b.instance THEN s.full_duration_s END AS full_duration_s,
       CASE WHEN b.full_from = b.instance THEN s.full_device END AS full_device,
       CASE WHEN b.full_from = b.instance THEN s.full_device_name END AS full_device_name,
       CASE WHEN b.full_from = b.instance THEN s.full_snapshot END AS full_snapshot,
       CASE WHEN b.diff_from = b.instance THEN s.diff_bytes END AS diff_bytes,
       CASE WHEN b.diff_from = b.instance THEN s.diff_duration_s END AS diff_duration_s,
       CASE WHEN b.log_from = b.instance THEN s.log_bytes END AS log_bytes,
       CASE WHEN b.log_from = b.instance THEN s.log_duration_s END AS log_duration_s,
       CASE WHEN b.log_from = b.instance THEN s.log_device END AS log_device
  FROM pgvigil.mssql_backup_judged b
  JOIN pgvigil.mssql_backup_state s ON s.instance_id = b.instance_id AND s.database_name = b.database_name
 WHERE b.instance_id = $1
 ORDER BY CASE WHEN 'never' IN (b.full_status, b.log_status) OR 'late' IN (b.full_status, b.log_status, b.diff_status) THEN 0 ELSE 1 END,
          (b.not_judged IS NOT NULL), b.database_name`

const sqlMSSQLBackupFindings = `
SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_jobs_findings
 WHERE instance_id = $1 AND check_name NOT IN ('a job failed', 'a job runs far longer than its average')
 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, at DESC`

const sqlMSSQLBackupLimits = `
SELECT l.full_backup_hours, l.diff_backup_hours, l.log_backup_minutes, l.new_database_hours, l.nul_backup_days,
       array_to_string(l.backup_exclude, ', ') AS backup_exclude,
       (SELECT min(s.history_from) FROM pgvigil.mssql_backup_state s WHERE s.instance_id = l.instance_id) AS history_from,
       r.snapshot_at, r.row_count, c.status, c.note, c.snapshot_at AS run_at
  FROM pgvigil.mssql_hadr_limits l
  LEFT JOIN pgvigil.mssql_hadr_reads r ON r.instance_id = l.instance_id AND r.collection = 'mssql_backups'
  LEFT JOIN pgvigil.collection_dates c ON c.instance_id = l.instance_id AND c.collection = 'mssql_backups'
 WHERE l.instance_id = $1`

// MSSQLBackups serves the Backups tab of one SQL Server instance.
func (s *Server) MSSQLBackups(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"databases", sqlMSSQLBackups, []any{id}},
		{"findings", sqlMSSQLBackupFindings, []any{id}},
		{"limits", sqlMSSQLBackupLimits, []any{id}},
	})
}
