-- 0138: the DBA Dash door's Collection Errors cell follows DBA Dash's version (DBA Dash 4.25.0).
--
-- DBA Dash 4.25.0's Summary_Upd (L279-280) fills dbo.Summary.CollectionErrorStatus from an instance's COLLECTION
-- HEALTH (dbo.CollectionHealthStatus over the runs its service records in dbo.CollectionRunStatus, new in 4.25.0) and
-- CollectionErrorCount with its collections at warning or critical, for every instance with run rows; an instance
-- without them (collected by a service older than 4.25.0) keeps the errors of 24 hours. DBA Dash's 4.25.0 Summary heads
-- the column 'Collection Health'. 0052 shipped the 4.24.1 words for every repository: the door now says
--   the header  'Collection Health' on a repository at 4.25.0 or later (its dbo.DBVersionHistory, as the door reads it),
--               'DBA Dash Errors (24hrs)' before; over several repositories of both kinds, both words;
--   the count   'n collection(s) at warning or critical' for an instance with run rows (the door's read adds the detail
--               CollectionHealth, internal/dbadash/read.go), 'n error(s) in 24 h' for any other - as Summary_Upd chose.
-- 0052's dbadash_checks() stays as it was (its words are 4.24.1's); the door's reads use dbadash_checks(p_repository).

-- whether a DBA Dash version string is 4.25.0 or later (a version that is not dot-separated digits: no)
CREATE OR REPLACE FUNCTION pgvigil.dbadash_health_version(p_version text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(p_version ~ '^[0-9]{1,9}(\.[0-9]{1,9})*$' AND string_to_array(p_version, '.')::int[] >= '{4,25}'::int[], false)
$$;

-- the Collection Errors column's header for one repository, or (NULL) for every configured repository the door read
CREATE OR REPLACE FUNCTION pgvigil.dbadash_errors_label(p_repository text)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN bool_and(pgvigil.dbadash_health_version(r.version)) THEN 'Collection Health'
              WHEN bool_or(pgvigil.dbadash_health_version(r.version)) THEN 'Collection Health / DBA Dash Errors (24hrs)'
              ELSE 'DBA Dash Errors (24hrs)' END
    FROM pgvigil.dbadash_repositories r
   WHERE r.is_configured AND (p_repository IS NULL OR r.repository = p_repository)
$$;

CREATE OR REPLACE FUNCTION pgvigil.dbadash_checks(p_repository text)
RETURNS TABLE (ord int, status_key text, label text)
LANGUAGE sql STABLE AS $$
  SELECT o::int, k, l FROM (VALUES
    (1, 'MemoryDumpStatus', 'Memory Dump'), (2, 'CorruptionStatus', 'Corruption'), (3, 'LastGoodCheckDBStatus', 'Last Good Check DB'),
    (4, 'AlertStatus', 'SQL Agent Alerts'), (5, 'FullBackupStatus', 'Backup FULL'), (6, 'DiffBackupStatus', 'Backup DIFF'),
    (7, 'LogBackupStatus', 'Backup LOG'), (8, 'DriveStatus', 'Drive Space'), (9, 'JobStatus', 'Agent Jobs'),
    (10, 'IsAgentRunningStatus', 'Is Agent Running'), (11, 'LogShippingStatus', 'Log Shipping'), (12, 'MirroringStatus', 'Mirroring'),
    (13, 'AGStatus', 'Availability Groups'), (14, 'LogFreeSpaceStatus', 'Log Space'), (15, 'FileFreeSpaceStatus', 'File Space'),
    (16, 'PctMaxSizeStatus', '% Max Size'), (17, 'ElasticPoolStorageStatus', 'Elastic Pool Storage'), (18, 'QueryStoreStatus', 'QS'),
    (19, 'CustomCheckStatus', 'Custom Checks'), (20, 'CollectionErrorStatus', pgvigil.dbadash_errors_label(p_repository)), (21, 'SnapshotAgeStatus', 'Snapshot Age'),
    (22, 'DBMailStatus', 'DB Mail'), (23, 'IdentityStatus', 'Identity Columns'), (24, 'DatabaseStateStatus', 'Database State'),
    (25, 'ServiceBrokerStatus', 'Service Broker'), (26, 'UptimeStatus', 'Instance Uptime')) v(o, k, l)
$$;

CREATE OR REPLACE FUNCTION pgvigil.dbadash_detail(p_key text, d jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(CASE p_key
    WHEN 'LastGoodCheckDBStatus' THEN coalesce((d->>'DaysSinceLastGoodCheckDB') || ' days', 'Never')
         || coalesce(' (critical ' || (d->>'LastGoodCheckDBCriticalCount') || ', warning ' || (d->>'LastGoodCheckDBWarningCount')
                     || ', healthy ' || (d->>'LastGoodCheckDBHealthyCount') || ')', '')
    WHEN 'CollectionErrorStatus' THEN coalesce((d->>'CollectionErrorCount') || CASE WHEN (d->>'CollectionHealth')::boolean
                                                                                     THEN ' collection(s) at warning or critical'
                                                                                     ELSE ' error(s) in 24 h' END, '')
    WHEN 'SnapshotAgeStatus' THEN CASE WHEN d->>'SnapshotAgeMin' IS NULL THEN ''
                                       WHEN d->>'SnapshotAgeMin' = d->>'SnapshotAgeMax' THEN (d->>'SnapshotAgeMax') || ' min'
                                       ELSE (d->>'SnapshotAgeMin') || ' to ' || (d->>'SnapshotAgeMax') || ' min' END
    WHEN 'UptimeStatus' THEN CASE WHEN d->>'OfflineSince' IS NOT NULL THEN 'offline since ' || (d->>'OfflineSince') || ' UTC'
                                  WHEN d->>'sqlserver_start_time_utc' IS NOT NULL THEN 'started ' || (d->>'sqlserver_start_time_utc') || ' UTC'
                                  ELSE '' END
    WHEN 'CorruptionStatus' THEN coalesce('detected ' || (d->>'DetectedCorruptionDateUtc') || ' UTC', '')
    WHEN 'IdentityStatus' THEN concat_ws(' / ', (d->>'MaxIdentityPctUsed') || ' % used', (d->>'MinIdentityEstimatedDays') || ' days left')
    WHEN 'AlertStatus' THEN concat_ws(', ', 'last alert ' || (d->>'LastAlert'), 'last critical ' || (d->>'LastCritical'), (d->>'TotalAlerts') || ' alert(s)')
    WHEN 'DBMailStatus' THEN coalesce(d->>'DBMailStatusDescription', '')
    WHEN 'ServiceBrokerStatus' THEN coalesce(d->>'ServiceBrokerStatusDescription', '')
    WHEN 'MemoryDumpStatus' THEN concat_ws(', ', (d->>'MemoryDumpCount') || ' dump(s)', 'last ' || (d->>'LastMemoryDumpUTC') || ' UTC')
    WHEN 'IsAgentRunningStatus' THEN CASE d->>'IsAgentRunning' WHEN 'true' THEN 'running' WHEN 'false' THEN 'not running' ELSE '' END
    ELSE '' END, '')
$$;

CREATE OR REPLACE FUNCTION pgvigil.dbadash_statuses(p_repository text, p_instance_id int)
RETURNS TABLE (ord int, status_key text, label text, code int, word text, detail text, refreshed_at timestamptz, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT c.ord, c.status_key, c.label, (s.statuses->>c.status_key)::int, pgvigil.dbadash_word((s.statuses->>c.status_key)::int),
         pgvigil.dbadash_detail(c.status_key, s.details), s.refreshed_at, s.snapshot_at
    FROM pgvigil.dbadash_checks(p_repository) c
    JOIN pgvigil.dbadash_summary s ON s.repository = p_repository AND s.instance_id = p_instance_id
    JOIN pgvigil.dbadash_repositories r ON r.repository = s.repository AND r.is_configured
   ORDER BY c.ord
$$;

CREATE OR REPLACE FUNCTION pgvigil.dbadash_changes(p_repository text, p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, status_key text, label text, old_code int, old_word text, new_code int, new_word text)
LANGUAGE sql STABLE AS $$
  WITH h AS (
    SELECT x.snapshot_at, x.statuses, lag(x.statuses) OVER (ORDER BY x.snapshot_at) AS prev
      FROM (SELECT * FROM pgvigil.dbadash_summary_history
             WHERE repository = p_repository AND instance_id = p_instance_id AND snapshot_at > p_from AND snapshot_at <= p_to
            UNION ALL
            (SELECT * FROM pgvigil.dbadash_summary_history
              WHERE repository = p_repository AND instance_id = p_instance_id AND snapshot_at <= p_from
              ORDER BY snapshot_at DESC LIMIT 1)) x)
  SELECT h.snapshot_at, c.status_key, c.label, (h.prev->>c.status_key)::int, pgvigil.dbadash_word((h.prev->>c.status_key)::int),
         (h.statuses->>c.status_key)::int, pgvigil.dbadash_word((h.statuses->>c.status_key)::int)
    FROM h CROSS JOIN pgvigil.dbadash_checks(p_repository) c
   WHERE h.prev IS NOT NULL AND h.snapshot_at > p_from
     AND EXISTS (SELECT 1 FROM pgvigil.dbadash_repositories r WHERE r.repository = p_repository AND r.is_configured)
     AND (h.prev->>c.status_key) IS DISTINCT FROM (h.statuses->>c.status_key)
   ORDER BY h.snapshot_at DESC, c.ord
$$;
