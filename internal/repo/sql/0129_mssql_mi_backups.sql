-- 0129: Azure SQL Managed Instance's system databases are not judged by their backups (CLOUDSQL C5). Microsoft's
-- 'Automated backups in Azure SQL Managed Instance': "The system databases are automatically backed up (excluding the
-- physical master database), but these backups aren't currently logged in msdb." - so a Managed Instance's master,
-- model and msdb would read 'never' backed up while the service keeps them. mssql_backup_judged is 0066's view with
-- one more not_judged reason, line for line otherwise (internal/repo TestBackupJudged0129Is0066PlusManagedInstance
-- holds the two equal: an edit of 0066's view is made here too). Its user databases stay judged: Microsoft's
-- 'Monitor backup activity' for Managed Instance says it stores backup information in msdb (whether each automatic
-- full, differential and log backup has its row there is checked on a live Managed Instance, not here).
CREATE OR REPLACE VIEW pgvigil.mssql_backup_judged AS
WITH own AS (
  SELECT s.*, i.name AS instance,
         l.full_backup_hours, l.diff_backup_hours, l.log_backup_minutes, l.new_database_hours, l.nul_backup_days,
         (SELECT p FROM unnest(l.backup_exclude) p WHERE s.database_name ILIKE p LIMIT 1) AS excluded_by
    FROM pgvigil.mssql_backup_state s
    JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
    JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = s.instance_id
   WHERE s.is_present
), merged AS (
  SELECT o.*,
         coalesce(f.full_at, o.full_at) AS eff_full_at, coalesce(f.instance, o.instance) AS full_from,
         coalesce(f.full_copy_only, o.full_copy_only) AS eff_full_copy_only,
         coalesce(d.diff_at, o.diff_at) AS eff_diff_at, coalesce(d.instance, o.instance) AS diff_from,
         coalesce(g.log_at, o.log_at) AS eff_log_at, coalesce(g.instance, o.instance) AS log_from,
         coalesce(n.nul_at, o.nul_at) AS eff_nul_at, coalesce(n.nul_type, o.nul_type) AS eff_nul_type, coalesce(n.instance, o.instance) AS nul_from,
         r.replicas_total, r.replicas_monitored
    FROM own o
    LEFT JOIN LATERAL (SELECT x.full_at, x.full_copy_only, xi.name AS instance FROM pgvigil.mssql_backup_state x JOIN pgvigil.instances xi ON xi.instance_id = x.instance_id AND xi.is_active
                        WHERE o.ag_group_id IS NOT NULL AND x.ag_group_id = o.ag_group_id AND x.database_name = o.database_name AND x.is_present AND x.full_at IS NOT NULL
                        ORDER BY x.full_at DESC LIMIT 1) f ON true
    LEFT JOIN LATERAL (SELECT x.diff_at, xi.name AS instance FROM pgvigil.mssql_backup_state x JOIN pgvigil.instances xi ON xi.instance_id = x.instance_id AND xi.is_active
                        WHERE o.ag_group_id IS NOT NULL AND x.ag_group_id = o.ag_group_id AND x.database_name = o.database_name AND x.is_present AND x.diff_at IS NOT NULL
                        ORDER BY x.diff_at DESC LIMIT 1) d ON true
    LEFT JOIN LATERAL (SELECT x.log_at, xi.name AS instance FROM pgvigil.mssql_backup_state x JOIN pgvigil.instances xi ON xi.instance_id = x.instance_id AND xi.is_active
                        WHERE o.ag_group_id IS NOT NULL AND x.ag_group_id = o.ag_group_id AND x.database_name = o.database_name AND x.is_present AND x.log_at IS NOT NULL
                        ORDER BY x.log_at DESC LIMIT 1) g ON true
    LEFT JOIN LATERAL (SELECT x.nul_at, x.nul_type, xi.name AS instance FROM pgvigil.mssql_backup_state x JOIN pgvigil.instances xi ON xi.instance_id = x.instance_id AND xi.is_active
                        WHERE o.ag_group_id IS NOT NULL AND x.ag_group_id = o.ag_group_id AND x.database_name = o.database_name AND x.is_present AND x.nul_at IS NOT NULL
                        ORDER BY x.nul_at DESC LIMIT 1) n ON true
    LEFT JOIN LATERAL (SELECT (SELECT count(*) FROM pgvigil.mssql_ag_state a WHERE a.instance_id = o.instance_id AND lower(a.group_id) = o.ag_group_id) AS replicas_total,
                              (SELECT count(DISTINCT lower(a.replica_server)) FROM pgvigil.mssql_ag_state a JOIN pgvigil.instances ai ON ai.instance_id = a.instance_id AND ai.is_active
                                WHERE lower(a.group_id) = o.ag_group_id AND a.is_local
                                  AND EXISTS (SELECT 1 FROM pgvigil.mssql_backup_state b WHERE b.instance_id = a.instance_id AND b.ag_group_id = o.ag_group_id)) AS replicas_monitored
                      ) r ON o.ag_group_id IS NOT NULL
), j AS (
  SELECT m.*,
         CASE WHEN m.excluded_by IS NOT NULL THEN 'excluded by the pattern ' || m.excluded_by
              WHEN m.database_name = 'tempdb' THEN 'tempdb is never backed up'
              WHEN m.database_name IN ('master', 'model', 'msdb')
                   AND EXISTS (SELECT 1 FROM pgvigil.instances x WHERE x.instance_id = m.instance_id AND x.platform = 'azuresqlmi')
                THEN 'Azure SQL Managed Instance backs up its system databases itself and does not record those backups in msdb'
              WHEN m.is_snapshot THEN 'a database snapshot'
              WHEN m.state IS DISTINCT FROM 'ONLINE' THEN 'the database is ' || coalesce(lower(m.state), 'in an unknown state')
              WHEN m.is_standby THEN 'a standby database (restoring logs)'
              WHEN m.created_at > m.snapshot_at - make_interval(secs => (m.new_database_hours * 3600)::float8) THEN 'a new database'
         END AS not_judged
    FROM merged m
)
SELECT j.instance_id, j.instance, j.database_name, j.snapshot_at, j.state, j.recovery_model, j.created_at, j.ag_name, j.ag_group_id,
       j.replicas_total, j.replicas_monitored,
       (j.ag_group_id IS NOT NULL AND coalesce(j.replicas_monitored, 0) < coalesce(j.replicas_total, 0)) AS replicas_unseen,
       j.not_judged,
       -- <type>_from: the instance whose msdb holds that backup (where it ran)
       j.eff_full_at AS full_at, CASE WHEN j.eff_full_at IS NOT NULL THEN j.full_from END AS full_from, j.eff_full_copy_only AS full_copy_only,
       j.eff_diff_at AS diff_at, CASE WHEN j.eff_diff_at IS NOT NULL THEN j.diff_from END AS diff_from,
       j.eff_log_at AS log_at, CASE WHEN j.eff_log_at IS NOT NULL THEN j.log_from END AS log_from,
       j.eff_nul_at AS nul_at, j.eff_nul_type AS nul_type, CASE WHEN j.eff_nul_at IS NOT NULL THEN j.nul_from END AS nul_from,
       j.history_from, j.full_backup_hours, j.diff_backup_hours, j.log_backup_minutes, j.nul_backup_days,
       -- the ages AT THE READ: a view opened 50 minutes after an hourly read must not add those minutes to a log backup's age
       extract(epoch FROM greatest(j.snapshot_at - j.eff_full_at, interval '0')) / 3600.0 AS full_age_hours,
       extract(epoch FROM greatest(j.snapshot_at - j.eff_diff_at, interval '0')) / 3600.0 AS diff_age_hours,
       extract(epoch FROM greatest(j.snapshot_at - j.eff_log_at, interval '0')) / 60.0 AS log_age_minutes,
       CASE WHEN j.not_judged IS NOT NULL OR j.full_backup_hours = 0 THEN 'not judged'
            WHEN j.eff_full_at IS NULL THEN 'never'
            WHEN j.snapshot_at - j.eff_full_at > make_interval(secs => (j.full_backup_hours * 3600)::float8) THEN 'late'
            ELSE 'ok' END AS full_status,
       CASE WHEN j.not_judged IS NOT NULL OR j.diff_backup_hours = 0 OR j.database_name = 'master' THEN 'not judged'
            WHEN j.eff_diff_at IS NULL AND j.eff_full_at IS NULL THEN 'never'
            -- a full backup newer than the threshold stands in for a differential one
            WHEN j.snapshot_at - greatest(j.eff_diff_at, j.eff_full_at) > make_interval(secs => (j.diff_backup_hours * 3600)::float8) THEN 'late'
            ELSE 'ok' END AS diff_status,
       CASE WHEN j.not_judged IS NOT NULL OR j.log_backup_minutes = 0 OR j.recovery_model IS DISTINCT FROM 'FULL' AND j.recovery_model IS DISTINCT FROM 'BULK_LOGGED'
                 OR j.is_read_only OR j.database_name = 'model' THEN 'not judged'
            -- under the full recovery model the log chain starts with the first full backup: before it there is nothing to back up
            WHEN j.eff_full_at IS NULL THEN 'not judged'
            WHEN j.eff_log_at IS NULL THEN 'never'
            WHEN j.snapshot_at - j.eff_log_at > make_interval(secs => (j.log_backup_minutes * 60)::float8) THEN 'late'
            ELSE 'ok' END AS log_status
  FROM j;
