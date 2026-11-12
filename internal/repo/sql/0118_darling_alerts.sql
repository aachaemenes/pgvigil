-- 0118: task 177 D30 - PerformanceMonitor's alert defaults as pgvigil findings. Each threshold and measure below is
-- PerformanceMonitor 3.12.0's (MIT License, Copyright (c) Erik Darling, Darling Data, LLC): its custom alert templates
-- (Darling/PerformanceMonitor.Darling.Storage/CustomAlertTemplates.cs) and its built-in alert settings (DarlingConfig.cs),
-- named per finding. Once the release's join puts this view's arm in pgvigil.findings (see the end), the alert sender
-- sends them like every finding (alert_findings reads pgvigil.findings): a finding that stops standing resolves its
-- alert, which is the recovery message.
--   dead tuples piling up           a table's n_dead_tup at 1,000,000 (warning) / 10,000,000 (critical): template
--                                   pg-autovacuum-dead-tuples (CustomAlertTemplates.cs L46-55)
--   replay lag                      a sender's replay lag at 30 s (warning) / 5 min (critical): template pg-replication-lag
--                                   (L57-65)
--   replication slot retaining WAL  a slot's retained WAL at 10 GB (warning) / 50 GB (critical): template
--                                   pg-replication-slot-wal (L87-96)
--   a volume under 5 GB free        a SQL Server volume's free space under 5 GB (warning) / at or under 2 GB (critical):
--                                   LowDiskThresholdGb 5, DiskCriticalFreeGb 2 (DarlingConfig.cs); one alert per volume as
--                                   PerformanceMonitor sends one ('10% / 5 GB'): raised only where the volume's own percent
--                                   threshold (drives_now: the drive, instance, tag or root setting, else 20 % / 10 %)
--                                   raises nothing, and only on a volume over 10 GB (on a smaller one the floor would stand
--                                   for good: its percent rule judges it). With the default 20 % that is a volume of 10 to
--                                   25 GB; the critical tier needs a percent threshold set lower (under 20 % on 10 GB)
--   AG secondary behind             an Availability Group database 300 s or more behind its primary (warning):
--                                   agLagAlertSeconds 300 (DarlingConfig.cs L796-799)
--   runnable queue per scheduler    SQL Server's runnable tasks per scheduler averaged over the last 5 minutes (3 reads
--                                   at least) at 8 (warning) / 16 (critical): RunnableQueueWarningPerScheduler /
--                                   RunnableQueueCriticalPerScheduler (RunnableQueueEvaluator.cs L117-120); the
--                                   'scheduler pressure' warning of 0074 (one per scheduler, 15 minutes) stays beside it
--   long-running requests           SQL Server requests running 30 minutes or more at the newest read (warning, one per
--                                   instance: how many and the longest), BACKUP and RESTORE left out (by their command
--                                   and by their BACKUPTHREAD / BACKUPIO waits), as the other waits and programs
--                                   PerformanceMonitor leaves out (WAITFOR, BROKER_RECEIVE_WAITFOR, sp_server_diagnostics,
--                                   the XE live target, Agent T-SQL job steps, system logins); the newest read is the
--                                   newest mssql_requests_summary row (one per read, a read with no request too):
--                                   LongRunningQueryThresholdMinutes 30,
--                                   LongRunningQueryExcludeBackups (DarlingConfig.cs L935, L1198; DarlingAlertReadAdapter.cs
--                                   L1087-1135; LongRunningQueryExclusions.cs L96-109). 0064's 'a request running over an
--                                   hour' (info) stays beside it
--   server unreachable              an instance whose newest collection attempt failed to connect (critical), as
--                                   PerformanceMonitor's 'Server Unreachable' fires on any failed connection
--                                   (ConnectionAlertPolicy.cs L74-98): no answer, a timeout or a TLS failure, and also a
--                                   server that answered and refused the collector (a login or password refused, a
--                                   pg_hba rule, a missing database, no CONNECT right, too many clients) - the detail is
--                                   the driver's own words, which say which. The next read that connects ends it, and the
--                                   alert's resolution is the 'connection restored' message. A failed connect is
--                                   recorded through import_connect_failure (the collectors call it, not when pgvigil's
--                                   own shutdown cut the connect: a WIRING BLOCK of internal/collect, internal/mssql and
--                                   internal/repo), its note marked 'connect: '. PostgreSQL's Connect includes the
--                                   session's setup after the server accepted it, so a failure there is raised too; an
--                                   error of a collection's statements (a lock or statement timeout, a per-database
--                                   connect of one collection) is not read as unreachable
-- A read older than its collection's freshness raises nothing (the Collections page says the collection is stale).

CREATE OR REPLACE VIEW pgvigil.darling_alert_findings AS
SELECT t.instance_id, CASE WHEN t.n_dead_tup >= 10000000 THEN 'critical' ELSE 'warning' END AS severity,
       'dead tuples piling up'::text AS setting, t.datname || '.' || t.schema_name || '.' || t.table_name AS value, true AS is_set,
       'under 1000000 dead tuples'::text AS suggested, 'all'::text AS platforms,
       format('%s dead tuples beside %s live ones at the last read; the last autovacuum %s: autovacuum is behind on this table (a long transaction, an idle-in-transaction session or a slot can hold its cleanup back)',
              t.n_dead_tup, coalesce(t.n_live_tup, 0), coalesce(to_char(t.last_autovacuum, 'YYYY-MM-DD HH24:MI'), 'never')) AS detail,
       'pg-collector'::text AS source, t.snapshot_at AS at
  FROM pgvigil.tables t
 WHERE t.is_present AND t.n_dead_tup >= 1000000 AND t.snapshot_at > now() - interval '1 day'
UNION ALL
SELECT r.instance_id, CASE WHEN r.lag_secs >= 300 THEN 'critical' ELSE 'warning' END, 'replay lag', r.key, true,
       'under 30 s', 'all', format('the standby %s replays %s s behind the primary', r.key, round(r.lag_secs::numeric, 1)),
       'pg-collector', r.snapshot_at
  FROM pgvigil.replication_latest r
 WHERE r.kind = 'sender' AND r.lag_secs >= 30 AND r.snapshot_at > now() - interval '15 minutes'
UNION ALL
SELECT s.instance_id, CASE WHEN s.lag_bytes >= 50 * 1073741824::bigint THEN 'critical' ELSE 'warning' END, 'replication slot retaining WAL', s.key, true,
       'under 10 GB', 'all',
       format('the slot %s retains %s of WAL and %s: WAL a slot keeps is unbounded unless max_slot_wal_keep_size is set, so it fills the volume; a slot whose consumer is gone is dropped',
              s.key, pg_size_pretty(s.lag_bytes), CASE WHEN coalesce(s.active, false) THEN 'its consumer is connected' ELSE 'its consumer is not connected' END),
       'pg-collector', s.snapshot_at
  FROM pgvigil.replication_latest s
 WHERE s.kind = 'slot' AND s.lag_bytes >= 10 * 1073741824::bigint AND s.snapshot_at > now() - interval '15 minutes'
UNION ALL
SELECT v.instance_id, CASE WHEN v.free_bytes <= 2 * 1073741824::bigint THEN 'critical' ELSE 'warning' END, 'a volume under 5 GB free', v.drive, true,
       'over 5 GB free', 'all',
       format('%s free of %s (%s %%); %s database file(s) sit on it; its percent threshold (warning under %s %%, critical under %s %%) raises nothing, so the 5 GB floor judges it',
              pg_size_pretty(v.free_bytes), pg_size_pretty(v.total_bytes), v.free_pct, v.files, v.warn_pct, v.crit_pct),
       'mssql_storage', v.snapshot_at
  FROM pgvigil.drives_now v
 WHERE v.source = 'dm_os_volume_stats' AND v.status = 'ok' AND v.free_bytes < 5 * 1073741824::bigint
   AND v.snapshot_at > now() - interval '3 hours' AND v.total_bytes > 10 * 1073741824::bigint
UNION ALL
SELECT d.instance_id, 'warning', 'AG secondary behind', d.group_name || ': ' || d.database_name || ' on ' || d.replica_server, true,
       'under 300 s', 'all',
       format('Availability Group %s: database %s on replica %s is %s seconds behind the primary (threshold 300)', d.group_name, d.database_name, d.replica_server, d.secondary_lag_s),
       'mssql_hadr', d.snapshot_at
  FROM pgvigil.mssql_ag_database_state d
 WHERE d.secondary_lag_s >= 300 AND d.snapshot_at > now() - interval '30 minutes'
UNION ALL
SELECT q.instance_id, CASE WHEN q.per_sched >= 16 THEN 'critical' ELSE 'warning' END, 'runnable queue per scheduler', 'schedulers', true,
       'under 8 per scheduler', 'all',
       format('runnable tasks averaged %s per scheduler over the last %s reads (%s minutes, %s schedulers): work waits for a CPU',
              round(q.per_sched, 1), q.n, round(extract(epoch FROM q.at - q.first_at) / 60), q.schedulers),
       'mssql_perf', q.at
  FROM (SELECT s.instance_id, count(*) AS n, avg(s.runnable_tasks::numeric / nullif(s.schedulers, 0)) AS per_sched,
               max(s.snapshot_at) AS at, min(s.snapshot_at) AS first_at, (array_agg(s.schedulers ORDER BY s.snapshot_at DESC))[1] AS schedulers
          FROM pgvigil.mssql_sched_sample s
         WHERE s.snapshot_at > now() - interval '5 minutes' AND s.schedulers > 0
         GROUP BY s.instance_id) q
 WHERE q.n >= 3 AND q.per_sched >= 8
UNION ALL
SELECT l.instance_id, 'warning', 'long-running requests', 'requests', true, 'under 30 minutes', 'all',
       format('%s request(s) running 30 minutes or more, the longest %s min: session %s (%s, login %s, program %s)', l.n, l.longest_min, l.session_id,
              coalesce(l.command, 'command unknown'), coalesce(l.login_name, '(unknown)'), coalesce(nullif(l.program_name, ''), '(none)')),
       'mssql_running', l.snapshot_at
  FROM (SELECT r.instance_id, r.snapshot_at, count(*) OVER (PARTITION BY r.instance_id) AS n, r.elapsed_ms / 60000 AS longest_min,
               r.session_id, r.command, r.login_name, r.program_name,
               row_number() OVER (PARTITION BY r.instance_id ORDER BY r.elapsed_ms DESC) AS k
          FROM pgvigil.mssql_requests r
          JOIN (SELECT instance_id, max(snapshot_at) AS at FROM pgvigil.mssql_requests_summary WHERE snapshot_at > now() - interval '10 minutes' GROUP BY instance_id) m
            ON m.instance_id = r.instance_id AND m.at = r.snapshot_at
         WHERE r.snapshot_at > now() - interval '10 minutes'      -- the day partitions pruned whatever the join's plan
           AND r.request_id IS NOT NULL AND r.session_id > 50 AND r.elapsed_ms >= 1800000
           AND coalesce(upper(r.command), '') NOT LIKE 'BACKUP%' AND coalesce(upper(r.command), '') NOT LIKE 'RESTORE%'
           AND coalesce(upper(r.wait_type), '') NOT IN ('BACKUPTHREAD', 'BACKUPIO', 'SP_SERVER_DIAGNOSTICS_SLEEP', 'WAITFOR', 'BROKER_RECEIVE_WAITFOR', 'XE_LIVE_TARGET_TVF')
           AND coalesce(upper(r.wait_type), '') NOT LIKE '%SP_SERVER_DIAGNOSTICS%'
           AND coalesce(r.program_name, '') NOT LIKE 'SQLAgent - TSQL JobStep%'
           AND coalesce(upper(r.login_name), '') NOT IN ('NT AUTHORITY\SYSTEM', 'NT AUTHORITY\NETWORK SERVICE')) l
 WHERE l.k = 1
UNION ALL
SELECT c.instance_id, 'critical', 'server unreachable', i.name, true, 'answering and accepting the collector''s login', 'all',
       format('the newest read of %s (%s, %s) could not connect: %s', i.name, c.collection, to_char(c.snapshot_at, 'YYYY-MM-DD HH24:MI:SS'), substr(c.note, 10)),
       'collector', c.snapshot_at
  FROM (SELECT DISTINCT ON (d.instance_id) d.* FROM pgvigil.collection_dates d ORDER BY d.instance_id, d.snapshot_at DESC) c
  JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND c.status = 'error' AND c.snapshot_at > now() - interval '30 minutes'
   AND c.note LIKE 'connect: %';

-- import_connect_failure: a collection that could not connect to its instance, recorded as that collection's error with
-- the note 'connect: <the driver's error>' (an instance never collected, or retired, is left alone). The collector's door
-- (an import_ function: apply_roles makes it SECURITY DEFINER and the collector's).
CREATE OR REPLACE FUNCTION pgvigil.import_connect_failure(p_name text, p_collection text, p_at timestamptz, p_duration_ms int, p_error text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id int;
BEGIN
  SELECT i.instance_id INTO v_id FROM pgvigil.instances i WHERE i.name = p_name AND i.is_active;
  IF v_id IS NULL THEN RETURN; END IF;
  PERFORM pgvigil.log_collection(v_id, p_collection, p_at, p_duration_ms, 'error', 'connect: ' || left(coalesce(nullif(p_error, ''), 'no reason given'), 2000));
END $$;

COMMENT ON VIEW pgvigil.darling_alert_findings IS 'PerformanceMonitor''s alert defaults as findings (task 177 D30): dead tuples, replay lag, slot WAL, a volume under 5 GB free, an AG secondary behind, the runnable queue per scheduler, long-running requests, a server unreachable.';

-- pgvigil.findings takes them in the release's join (0190_join_release2.sql writes its arm in the view:
--   SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.darling_alert_findings
-- ); until then this view stands alone. scripts/proof-darling-alerts-findings.sql splices it for the proof only.

SELECT pgvigil.apply_roles();
