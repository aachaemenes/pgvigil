-- 0149 (FLEET FOLLOW-UP): one judge of a failed job everywhere - 0066's finding 'a job failed' counts a cancelled SQL
-- Agent run as a failure, as 0137's job_status does (DBA Dash 4.24.1 JobHistory_Upd's LastFailed and JobStats_RAW's
-- FailedCount: run_status IN (0, 3)). Read from rows the collectors already store; nothing is created, changed or
-- switched on on a monitored server.
--
--   pgvigil.mssql_jobs_findings   replaced WHOLE (0066's text, its only definition on every branch read 11-14 13:0x),
--                        two changes: the newest failed run is the newest with run_status 0 OR 3, and its detail says
--                        'job X was cancelled at ...' for a 3 ('job X failed at ...' as before for a 0). The check name
--                        stays 'a job failed' (a mute or an alert rule keyed on it keeps working); the failed step's
--                        lookup stays at run_status 0 (a cancelled run has no failed step: its own message is the
--                        outcome row's). Every other arm (the long-running job, the backups, the empty reads) is 0066's,
--                        unchanged. Its columns are 0066's, so the views over it (pgvigil.findings) stand.
--
-- Locks: CREATE OR REPLACE VIEW takes ACCESS EXCLUSIVE on the view only, for the moment the file takes; no table is
-- read or written.
CREATE OR REPLACE VIEW pgvigil.mssql_jobs_findings AS
WITH failed AS (
  SELECT DISTINCT ON (r.instance_id, r.job_id) r.instance_id, r.job_id, r.job_name, r.snapshot_at, r.duration_s, r.message, r.history_id, r.run_status
    FROM pgvigil.mssql_job_runs r
    JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = r.instance_id
   WHERE r.step_id = 0 AND r.run_status IN (0, 3) AND l.job_failed_hours > 0
     AND r.snapshot_at > now() - interval '31 days'       -- lets the planner prune partitions; the threshold below decides
     AND r.snapshot_at > now() - make_interval(secs => (l.job_failed_hours * 3600)::float8)
   ORDER BY r.instance_id, r.job_id, r.snapshot_at DESC, r.history_id DESC
), bk AS (
  SELECT b.* FROM pgvigil.mssql_backup_judged b WHERE b.snapshot_at > now() - interval '130 minutes'
)
SELECT f.instance_id, 'warning'::text AS severity, 'a job failed'::text AS check_name, coalesce(j.name, f.job_name, f.job_id) AS object, f.snapshot_at AS at,
       format('job %s %s at %s%s%s%s',
              coalesce(j.name, f.job_name, f.job_id), CASE WHEN f.run_status = 3 THEN 'was cancelled' ELSE 'failed' END,
              to_char(f.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
              coalesce(' at step ' || s.step_id || ' (' || s.step_name || '): ' || left(s.message, 1500), ': ' || left(f.message, 1500), ''),
              CASE WHEN j.last_outcome = 1 AND j.last_run_at > f.snapshot_at THEN ' It has succeeded since.' ELSE '' END,
              coalesce(' Next run ' || to_char(j.next_run_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"') || '.', '')) AS detail
  FROM failed f
  LEFT JOIN pgvigil.mssql_jobs j ON j.instance_id = f.instance_id AND j.job_id = f.job_id
  LEFT JOIN LATERAL (SELECT x.step_id, x.step_name, x.message FROM pgvigil.mssql_job_runs x
                      WHERE x.instance_id = f.instance_id AND x.job_id = f.job_id AND x.step_id > 0 AND x.run_status = 0
                        AND x.snapshot_at >= f.snapshot_at - interval '1 second'
                        AND x.snapshot_at <= f.snapshot_at + make_interval(secs => coalesce(f.duration_s, 0) + 60) AND x.history_id < f.history_id
                      ORDER BY x.history_id DESC LIMIT 1) s ON true
UNION ALL
SELECT j.instance_id, 'info', 'a job runs far longer than its average', j.name, j.running_since,
       format('job %s has run for %s minutes; its %s successful runs of the last month took %s minutes on average.', j.name,
              round((extract(epoch FROM now() - j.running_since) / 60)::numeric, 1), a.runs, round((a.avg_s / 60)::numeric, 1))
  FROM pgvigil.mssql_jobs j
  JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = j.instance_id
  JOIN LATERAL (SELECT avg(r.duration_s) AS avg_s, count(*) AS runs FROM pgvigil.mssql_job_runs r
                 WHERE r.instance_id = j.instance_id AND r.job_id = j.job_id AND r.step_id = 0 AND r.run_status = 1
                   AND r.snapshot_at > now() - interval '31 days') a ON true
 WHERE j.running_since IS NOT NULL AND j.snapshot_at > now() - interval '15 minutes' AND a.runs >= 3 AND l.job_long_factor > 0
   AND extract(epoch FROM now() - j.running_since) > a.avg_s * l.job_long_factor
   AND extract(epoch FROM now() - j.running_since) > a.avg_s + l.job_long_min_seconds
UNION ALL
SELECT b.instance_id, CASE WHEN b.replicas_unseen THEN 'info' ELSE 'critical' END,
       CASE WHEN b.replicas_unseen THEN 'backups not judged: a replica of the group is not monitored'
            WHEN b.full_status = 'never' THEN 'no full backup ever' ELSE 'no recent full backup' END,
       b.database_name, b.snapshot_at,
       CASE WHEN b.replicas_unseen THEN
              format('database %s of the availability group %s has %s in the msdb of the %s of %s replicas pgvigil monitors; the backup may run on a replica that is not monitored. Add that replica as an instance to have it judged.',
                     b.database_name, b.ag_name, CASE WHEN b.full_status = 'never' THEN 'no full backup' ELSE 'no full backup newer than ' || to_char(b.full_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"') END,
                     b.replicas_monitored, b.replicas_total)
            WHEN b.full_status = 'never' THEN
              -- the creation time is also the time of a restore over the name: say so, so nobody hunts for a lost history
              format('database %s (%s): created or restored %s; no full backup since%s%s. A backup that finished before that time is of the database as it was before, and is not counted.',
                     b.database_name, lower(b.recovery_model),
                     coalesce(to_char(b.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'at an unknown time'),
                     CASE WHEN b.history_from IS NULL THEN ' (msdb holds no backup history at all: never backed up, or the history was deleted)'
                          WHEN b.history_from > b.created_at THEN ' that msdb still lists (its history reaches back only to ' || to_char(b.history_from AT TIME ZONE 'UTC', 'YYYY-MM-DD') || ')'
                          ELSE '' END,
                     CASE WHEN b.ag_name IS NOT NULL THEN ' on any monitored replica of the availability group ' || b.ag_name ELSE '' END)
            ELSE
              format('database %s: the last full backup finished %s%s, %s hours before the read; the threshold is %s hours.', b.database_name,
                     to_char(b.full_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
                     CASE WHEN b.ag_name IS NOT NULL THEN ' on ' || b.full_from ELSE '' END, round(b.full_age_hours::numeric, 1), b.full_backup_hours)
       END
  FROM bk b WHERE b.full_status IN ('never', 'late')
UNION ALL
SELECT b.instance_id, CASE WHEN b.replicas_unseen THEN 'info' ELSE 'warning' END,
       CASE WHEN b.replicas_unseen THEN 'backups not judged: a replica of the group is not monitored' ELSE 'no recent log backup' END,
       b.database_name, b.snapshot_at,
       format('database %s is in the %s recovery model and %s; the threshold is %s minutes.%s', b.database_name, lower(replace(b.recovery_model, '_', '-')),
              CASE WHEN b.log_status = 'never' THEN 'has no log backup in msdb: its log grows until one runs'
                   ELSE 'its last log backup finished ' || to_char(b.log_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"')
                        || CASE WHEN b.ag_name IS NOT NULL THEN ' on ' || b.log_from ELSE '' END || ', ' || round(b.log_age_minutes::numeric) || ' minutes before the read' END,
              b.log_backup_minutes,
              CASE WHEN b.replicas_unseen THEN format(' Only %s of the %s replicas of %s are monitored: the backup may run on another.', b.replicas_monitored, b.replicas_total, b.ag_name) ELSE '' END)
  FROM bk b WHERE b.log_status IN ('never', 'late')
UNION ALL
SELECT b.instance_id, 'warning', 'no recent differential backup', b.database_name, b.snapshot_at,
       format('database %s: no differential or full backup in the %s hours before the read (the last differential %s, the last full %s).', b.database_name, b.diff_backup_hours,
              coalesce(to_char(b.diff_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'never'), coalesce(to_char(b.full_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'never'))
  FROM bk b WHERE b.diff_status IN ('never', 'late') AND NOT b.replicas_unseen
UNION ALL
SELECT b.instance_id, 'warning', 'a backup went to NUL', b.database_name, b.nul_at,
       format('database %s: a %s backup finished %s%s to the NUL device. Nothing was kept%s.', b.database_name, b.nul_type,
              to_char(b.nul_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), CASE WHEN b.ag_name IS NOT NULL THEN ' on ' || b.nul_from ELSE '' END,
              CASE b.nul_type WHEN 'log' THEN ', and the log chain is broken at that point: the log backups after it cannot be restored past it'
                              WHEN 'full' THEN ', and unless it was copy-only the differential backups after it are based on it'
                              ELSE '' END)
  FROM bk b WHERE b.not_judged IS NULL AND b.nul_backup_days > 0 AND b.nul_at > b.snapshot_at - make_interval(secs => (b.nul_backup_days * 86400)::float8)
UNION ALL
SELECT r.instance_id, 'warning', 'a collection stores nothing where rows are expected', r.collection, r.snapshot_at,
       format('%s has read no database in its last %s reads; every server has at least master. Its login may not see sys.databases as it should.', r.collection, r.empty_reads)
  FROM pgvigil.mssql_hadr_reads r WHERE r.collection = 'mssql_backups' AND r.empty_reads >= 1 AND r.snapshot_at > now() - interval '130 minutes';
