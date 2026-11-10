-- 0052_dbadash: the DBADash door (task 55). pgvigil reads DBADash repositories (SQL Server databases named in the
-- configuration's dbadash: list, a read-only login) every 5 minutes: DBADash's instance list and the statuses of its
-- Summary screen per instance. pgvigil collects nothing from SQL Server itself; these rows are DBADash's own.
--
-- What is read on the DBADash side (docs/dbadash.md lists the columns): dbo.Instances (active instances), dbo.Summary
-- (the cache DBADash's Summary screen reads through dbo.Summary_Get; the non-Azure rows), dbo.CollectionDates (the
-- newest collection per instance) and dbo.DBVersionHistory (the repository's version). dbo.Summary_Get itself is never
-- executed: it may run dbo.Summary_Upd, a write on the DBADash repository.
--
-- Tables:
--   dbadash_repositories     one row per configured repository: the last read, ok or 'not read' with the reason.
--   dbadash_instances        one current row per DBADash instance (is_present false once DBADash no longer lists it).
--   dbadash_summary          one current row per instance: the status codes (DBADash's numbers) and the detail values.
--   dbadash_summary_history  the change points: an instance's first read and every read whose statuses changed, kept
--                            under the retention (purge() deletes by snapshot_at: the wave's join re-creates purge()).
-- A status code is DBADash's own (DBADashStatusEnum): 1 Critical, 2 Warning, 3 N/A, 4 OK, 5 Acknowledged, 6 Warning
-- (low), 7 Information, 8 Disabled.
--
-- Import (the collector's door, SECURITY DEFINER by apply_roles):
--   import_dbadash(repository, snapshot_at, payload)   payload {status: ok | not read, reason, version, refreshed_at,
--                                                      instances: [{instance_id, instance, connection_id, display_name,
--                                                      ..., statuses: {key: code}, details: {...}}]}; 'not read' keeps
--                                                      the last rows and records the reason.
--   import_dbadash_configured(names)                   the repositories in the configuration now; the rest are hidden.
-- Read functions (the API reads only these):
--   dbadash_checks()                     the Summary's statuses in DBADash's column order, with its header words.
--   dbadash_word(code)                   DBADash's word for a status code.
--   dbadash_repositories()               every configured repository and its last read.
--   dbadash_fleet(repository)            every present instance (one repository or all), its worst status and counts.
--   dbadash_instance(repository, id)     one instance's facts.
--   dbadash_statuses(repository, id)     one instance's Summary: a row per status, DBADash's header, code, word, detail.
--   dbadash_changes(repository, id, f, t) the status changes of the window, with the old and new code.

CREATE TABLE IF NOT EXISTS pgvigil.dbadash_repositories (
  repository      text PRIMARY KEY,
  is_configured   boolean NOT NULL DEFAULT true,
  status          text NOT NULL CHECK (status IN ('ok', 'not read')),
  reason          text,
  read_at         timestamptz NOT NULL,        -- the last attempt
  ok_at           timestamptz,                 -- the last read that answered
  version         text,                        -- dbo.DBVersionHistory's newest Version
  refreshed_at    timestamptz,                 -- dbo.Summary's newest RefreshDate (UTC): when DBADash last refreshed its cache
  instance_count  int
);

CREATE TABLE IF NOT EXISTS pgvigil.dbadash_instances (
  repository      text NOT NULL REFERENCES pgvigil.dbadash_repositories (repository) ON DELETE CASCADE,
  instance_id     int NOT NULL,                -- DBADash's InstanceID (not a pgvigil instance)
  instance        text NOT NULL,               -- @@SERVERNAME as DBADash recorded it
  connection_id   text,
  display_name    text NOT NULL,               -- DBADash's InstanceDisplayName: the alias, else the ConnectionID
  show_in_summary boolean,
  product_version text,
  edition         text,
  paused_until    timestamptz,                 -- collections paused by DBADash until (UTC), while in the future
  last_collection timestamptz,                 -- the newest dbo.CollectionDates.SnapshotDate (UTC)
  first_seen      timestamptz NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  is_present      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (repository, instance_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.dbadash_summary (
  repository      text NOT NULL,
  instance_id     int NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  refreshed_at    timestamptz,                 -- this row's RefreshDate on the DBADash side (UTC)
  statuses        jsonb NOT NULL,              -- {"FullBackupStatus": 4, ...}: DBADash's codes
  details         jsonb NOT NULL,              -- the Summary's other columns (counts, ages, dates, descriptions)
  PRIMARY KEY (repository, instance_id),
  FOREIGN KEY (repository, instance_id) REFERENCES pgvigil.dbadash_instances (repository, instance_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS pgvigil.dbadash_summary_history (
  repository      text NOT NULL,
  instance_id     int NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  refreshed_at    timestamptz,
  statuses        jsonb NOT NULL,
  details         jsonb NOT NULL,
  PRIMARY KEY (repository, instance_id, snapshot_at)
);
CREATE INDEX IF NOT EXISTS dbadash_summary_history_at ON pgvigil.dbadash_summary_history (snapshot_at);

-- the Summary's statuses in the column order of DBADash's Summary screen, its header text for each
CREATE OR REPLACE FUNCTION pgvigil.dbadash_checks()
RETURNS TABLE (ord int, status_key text, label text)
LANGUAGE sql IMMUTABLE AS $$
  SELECT o::int, k, l FROM (VALUES
    (1, 'MemoryDumpStatus', 'Memory Dump'), (2, 'CorruptionStatus', 'Corruption'), (3, 'LastGoodCheckDBStatus', 'Last Good Check DB'),
    (4, 'AlertStatus', 'SQL Agent Alerts'), (5, 'FullBackupStatus', 'Backup FULL'), (6, 'DiffBackupStatus', 'Backup DIFF'),
    (7, 'LogBackupStatus', 'Backup LOG'), (8, 'DriveStatus', 'Drive Space'), (9, 'JobStatus', 'Agent Jobs'),
    (10, 'IsAgentRunningStatus', 'Is Agent Running'), (11, 'LogShippingStatus', 'Log Shipping'), (12, 'MirroringStatus', 'Mirroring'),
    (13, 'AGStatus', 'Availability Groups'), (14, 'LogFreeSpaceStatus', 'Log Space'), (15, 'FileFreeSpaceStatus', 'File Space'),
    (16, 'PctMaxSizeStatus', '% Max Size'), (17, 'ElasticPoolStorageStatus', 'Elastic Pool Storage'), (18, 'QueryStoreStatus', 'QS'),
    (19, 'CustomCheckStatus', 'Custom Checks'), (20, 'CollectionErrorStatus', 'DBA Dash Errors (24hrs)'), (21, 'SnapshotAgeStatus', 'Snapshot Age'),
    (22, 'DBMailStatus', 'DB Mail'), (23, 'IdentityStatus', 'Identity Columns'), (24, 'DatabaseStateStatus', 'Database State'),
    (25, 'ServiceBrokerStatus', 'Service Broker'), (26, 'UptimeStatus', 'Instance Uptime')) v(o, k, l)
$$;

CREATE OR REPLACE FUNCTION pgvigil.dbadash_word(p_code int)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_code WHEN 1 THEN 'Critical' WHEN 2 THEN 'Warning' WHEN 3 THEN 'N/A' WHEN 4 THEN 'OK' WHEN 5 THEN 'Acknowledged'
                     WHEN 6 THEN 'Warning (low)' WHEN 7 THEN 'Information' WHEN 8 THEN 'Disabled' END
$$;

CREATE OR REPLACE FUNCTION pgvigil.import_dbadash_configured(p_names text[])
RETURNS void LANGUAGE sql AS $$
  UPDATE pgvigil.dbadash_repositories SET is_configured = (repository = ANY (p_names))
   WHERE is_configured IS DISTINCT FROM (repository = ANY (p_names))
$$;

CREATE OR REPLACE FUNCTION pgvigil.import_dbadash(p_repository text, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_ok boolean := coalesce(p_payload->>'status', 'not read') = 'ok';
BEGIN
  INSERT INTO pgvigil.dbadash_repositories AS r (repository, is_configured, status, reason, read_at, ok_at, version, refreshed_at, instance_count)
  VALUES (p_repository, true, CASE WHEN v_ok THEN 'ok' ELSE 'not read' END, nullif(p_payload->>'reason', ''), p_snapshot_at,
          CASE WHEN v_ok THEN p_snapshot_at END, p_payload->>'version', (p_payload->>'refreshed_at')::timestamptz,
          CASE WHEN v_ok THEN CASE WHEN jsonb_typeof(p_payload->'instances') = 'array' THEN jsonb_array_length(p_payload->'instances') ELSE 0 END END)
  ON CONFLICT (repository) DO UPDATE SET
    is_configured = true, status = EXCLUDED.status, reason = EXCLUDED.reason, read_at = EXCLUDED.read_at,
    ok_at = coalesce(EXCLUDED.ok_at, r.ok_at),
    version = CASE WHEN v_ok THEN EXCLUDED.version ELSE r.version END,
    refreshed_at = CASE WHEN v_ok THEN EXCLUDED.refreshed_at ELSE r.refreshed_at END,
    instance_count = CASE WHEN v_ok THEN EXCLUDED.instance_count ELSE r.instance_count END;

  IF NOT v_ok OR jsonb_typeof(p_payload->'instances') IS DISTINCT FROM 'array' THEN
    RETURN;   -- the last rows stay as they were; the repository row says when and why the read failed
  END IF;

  INSERT INTO pgvigil.dbadash_instances AS d (repository, instance_id, instance, connection_id, display_name, show_in_summary,
                                              product_version, edition, paused_until, last_collection, first_seen, snapshot_at, is_present)
  SELECT p_repository, (x->>'instance_id')::int, x->>'instance', x->>'connection_id',
         coalesce(nullif(x->>'display_name', ''), x->>'connection_id', x->>'instance'), (x->>'show_in_summary')::boolean,
         x->>'product_version', x->>'edition', (x->>'paused_until')::timestamptz, (x->>'last_collection')::timestamptz,
         p_snapshot_at, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload->'instances') x
  ON CONFLICT (repository, instance_id) DO UPDATE SET
    instance = EXCLUDED.instance, connection_id = EXCLUDED.connection_id, display_name = EXCLUDED.display_name,
    show_in_summary = EXCLUDED.show_in_summary, product_version = EXCLUDED.product_version, edition = EXCLUDED.edition,
    paused_until = EXCLUDED.paused_until, last_collection = EXCLUDED.last_collection, snapshot_at = EXCLUDED.snapshot_at, is_present = true;

  -- an instance DBADash no longer lists as active (removed, or marked deleted there)
  UPDATE pgvigil.dbadash_instances d SET is_present = false
   WHERE d.repository = p_repository AND d.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload->'instances') x WHERE (x->>'instance_id')::int = d.instance_id);

  -- the Summary: an instance with no dbo.Summary row yet (DBADash has not refreshed its cache since it was added) has none
  INSERT INTO pgvigil.dbadash_summary AS s (repository, instance_id, snapshot_at, refreshed_at, statuses, details)
  SELECT p_repository, (x->>'instance_id')::int, p_snapshot_at, (x->>'refreshed_at')::timestamptz, x->'statuses', coalesce(x->'details', '{}')
    FROM jsonb_array_elements(p_payload->'instances') x
   WHERE jsonb_typeof(x->'statuses') = 'object'
  ON CONFLICT (repository, instance_id) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, refreshed_at = EXCLUDED.refreshed_at, statuses = EXCLUDED.statuses, details = EXCLUDED.details;
  DELETE FROM pgvigil.dbadash_summary s
   WHERE s.repository = p_repository
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload->'instances') x
                      WHERE (x->>'instance_id')::int = s.instance_id AND jsonb_typeof(x->'statuses') = 'object');

  -- the history keeps change points only: an instance's first read, and a read whose statuses differ from its newest
  -- history row (288 identical rows a day per instance would say nothing dbadash_changes() needs)
  INSERT INTO pgvigil.dbadash_summary_history (repository, instance_id, snapshot_at, refreshed_at, statuses, details)
  SELECT p_repository, (x->>'instance_id')::int, p_snapshot_at, (x->>'refreshed_at')::timestamptz, x->'statuses', coalesce(x->'details', '{}')
    FROM jsonb_array_elements(p_payload->'instances') x
   WHERE jsonb_typeof(x->'statuses') = 'object'
     AND (SELECT h.statuses FROM pgvigil.dbadash_summary_history h
           WHERE h.repository = p_repository AND h.instance_id = (x->>'instance_id')::int
           ORDER BY h.snapshot_at DESC LIMIT 1) IS DISTINCT FROM x->'statuses'
  ON CONFLICT DO NOTHING;
END $$;

-- the worst of a row's codes: 1 critical, 2 warning (2 and 6), else 0 (OK, N/A, acknowledged, information, disabled)
CREATE OR REPLACE FUNCTION pgvigil.dbadash_level(p_statuses jsonb)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(max(CASE WHEN e.value::int = 1 THEN 2 WHEN e.value::int IN (2, 6) THEN 1 ELSE 0 END), 0)
    FROM jsonb_each_text(coalesce(p_statuses, '{}')) e
   WHERE e.value ~ '^[0-9]+$'
$$;

CREATE OR REPLACE FUNCTION pgvigil.dbadash_repositories()
RETURNS TABLE (repository text, status text, reason text, read_at timestamptz, ok_at timestamptz, version text,
               refreshed_at timestamptz, instance_count int, critical int, warning int)
LANGUAGE sql STABLE AS $$
  SELECT r.repository, r.status, r.reason, r.read_at, r.ok_at, r.version, r.refreshed_at, r.instance_count,
         (SELECT count(*)::int FROM pgvigil.dbadash_summary s JOIN pgvigil.dbadash_instances i USING (repository, instance_id)
           WHERE s.repository = r.repository AND i.is_present AND pgvigil.dbadash_level(s.statuses) = 2),
         (SELECT count(*)::int FROM pgvigil.dbadash_summary s JOIN pgvigil.dbadash_instances i USING (repository, instance_id)
           WHERE s.repository = r.repository AND i.is_present AND pgvigil.dbadash_level(s.statuses) = 1)
    FROM pgvigil.dbadash_repositories r
   WHERE r.is_configured
   ORDER BY r.repository
$$;

-- every present instance of one repository (NULL = all configured), with its worst level, the count of its critical
-- and warning statuses, and its codes (the fleet grid draws one cell per status from them)
CREATE OR REPLACE FUNCTION pgvigil.dbadash_fleet(p_repository text DEFAULT NULL)
RETURNS TABLE (repository text, instance_id int, display_name text, instance text, level int, critical int, warning int,
               last_collection timestamptz, refreshed_at timestamptz, paused_until timestamptz, show_in_summary boolean,
               repository_status text, statuses jsonb, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT i.repository, i.instance_id, i.display_name, i.instance, pgvigil.dbadash_level(s.statuses),
         (SELECT count(*)::int FROM jsonb_each_text(s.statuses) e WHERE e.value = '1'),
         (SELECT count(*)::int FROM jsonb_each_text(s.statuses) e WHERE e.value IN ('2', '6')),
         i.last_collection, s.refreshed_at, CASE WHEN i.paused_until > now() THEN i.paused_until END, i.show_in_summary,
         r.status, s.statuses, i.snapshot_at
    FROM pgvigil.dbadash_instances i
    JOIN pgvigil.dbadash_repositories r ON r.repository = i.repository AND r.is_configured
    LEFT JOIN pgvigil.dbadash_summary s ON s.repository = i.repository AND s.instance_id = i.instance_id
   WHERE i.is_present AND (p_repository IS NULL OR i.repository = p_repository)
   ORDER BY i.repository, i.display_name
$$;

CREATE OR REPLACE FUNCTION pgvigil.dbadash_instance(p_repository text, p_instance_id int)
RETURNS TABLE (repository text, instance_id int, display_name text, instance text, connection_id text, product_version text,
               edition text, show_in_summary boolean, paused_until timestamptz, last_collection timestamptz, first_seen timestamptz,
               snapshot_at timestamptz, is_present boolean, refreshed_at timestamptz, summary_read_at timestamptz, level int,
               repository_status text, repository_reason text, repository_read_at timestamptz, repository_ok_at timestamptz,
               repository_version text)
LANGUAGE sql STABLE AS $$
  SELECT i.repository, i.instance_id, i.display_name, i.instance, i.connection_id, i.product_version, i.edition, i.show_in_summary,
         CASE WHEN i.paused_until > now() THEN i.paused_until END, i.last_collection, i.first_seen, i.snapshot_at, i.is_present,
         s.refreshed_at, s.snapshot_at, pgvigil.dbadash_level(s.statuses),
         r.status, r.reason, r.read_at, r.ok_at, r.version
    FROM pgvigil.dbadash_instances i
    JOIN pgvigil.dbadash_repositories r ON r.repository = i.repository
    LEFT JOIN pgvigil.dbadash_summary s ON s.repository = i.repository AND s.instance_id = i.instance_id
   WHERE i.repository = p_repository AND i.instance_id = p_instance_id
$$;

-- the detail DBADash's Summary shows (or puts in its tooltip) beside a status, from the row's detail values
CREATE OR REPLACE FUNCTION pgvigil.dbadash_detail(p_key text, d jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(CASE p_key
    WHEN 'LastGoodCheckDBStatus' THEN coalesce((d->>'DaysSinceLastGoodCheckDB') || ' days', 'Never')
         || coalesce(' (critical ' || (d->>'LastGoodCheckDBCriticalCount') || ', warning ' || (d->>'LastGoodCheckDBWarningCount')
                     || ', healthy ' || (d->>'LastGoodCheckDBHealthyCount') || ')', '')
    WHEN 'CollectionErrorStatus' THEN coalesce((d->>'CollectionErrorCount') || ' error(s) in 24 h', '')
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
    FROM pgvigil.dbadash_checks() c
    JOIN pgvigil.dbadash_summary s ON s.repository = p_repository AND s.instance_id = p_instance_id
   ORDER BY c.ord
$$;

-- the reads of the window where at least one status differs from the read before it (the first read of the window is
-- compared with the newest one before the window), one row per changed status
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
    FROM h CROSS JOIN pgvigil.dbadash_checks() c
   WHERE h.prev IS NOT NULL AND h.snapshot_at > p_from
     AND (h.prev->>c.status_key) IS DISTINCT FROM (h.statuses->>c.status_key)
   ORDER BY h.snapshot_at DESC, c.ord
$$;
