-- 0022_backups: whether the backups keep up (phase 2c, task 33; the Backups tab and the Summary column Backups).
--   backup_state     the current row per instance and object the backups collection reads: the WAL archiver
--                    (pg_stat_archiver: counts, the last archived and failed WAL and times, the archive lag), the
--                    cloud side of RDS / Aurora (retention days, LatestRestorableTime) and the newest snapshots.
--   backup_sample    the archiver's counts and lag and the restorable time's age over time (partitioned by month).
--   backup_status    one row per instance: the archiver, the cloud retention and restore point, the newest
--                    automated and manual snapshot and their ages.
--   backup_checks    the overview's rows (check group 'backups': the Summary column Backups).
--   backup_findings  the four rules in the findings columns (the join adds them to pgvigil.findings).
-- pgBackRest and barman are not read: their repositories and catalogs live outside the server.

CREATE TABLE IF NOT EXISTS pgvigil.backup_state (
  instance_id               int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  kind                      text NOT NULL,          -- archiver | cloud | snapshot
  name                      text NOT NULL,          -- pg_stat_archiver, the DB instance or cluster, the snapshot identifier
  snapshot_at               timestamptz NOT NULL,
  -- archiver
  archive_mode              text,                   -- off | on | always
  archive_timeout           text,
  archive_set               boolean,                -- archive_command or archive_library is set
  archived_count            bigint,
  last_archived_wal         text,
  last_archived_time        timestamptz,
  failed_count              bigint,
  last_failed_wal           text,
  last_failed_time          timestamptz,
  stats_reset               timestamptz,
  is_replica                boolean,
  wal_segment_bytes         bigint,
  current_lsn               text,
  archive_lag_bytes         bigint,                 -- WAL written since the end of the last archived segment
  archive_warn_minutes      int,                    -- the instance's threshold for the archive-age rule
  -- cloud
  resource_kind             text,                   -- instance | cluster
  retention_days            int,
  latest_restorable_time    timestamptz,
  earliest_restorable_time  timestamptz,
  backup_window             text,
  -- snapshot
  snapshot_type             text,                   -- automated | manual | awsbackup | ...
  status                    text,                   -- available | creating | ...
  created_at                timestamptz,
  allocated_gib             int,
  encrypted                 boolean,
  first_seen                timestamptz NOT NULL,
  is_present                boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, kind, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.backup_sample (
  instance_id          int NOT NULL,
  snapshot_at          timestamptz NOT NULL,
  archived_count       bigint,
  failed_count         bigint,
  archive_lag_bytes    bigint,
  last_archived_time   timestamptz,
  restorable_age_s     numeric               -- the cloud restore point's age at the read
) PARTITION BY RANGE (snapshot_at);

-- payload: {kind:'archiver', ...}, {kind:'cloud', name, ...}, {kind:'snapshot', name, ...}, {kind:'snapshots_read'}
-- and {kind:'collector_error', source:'backups:<part>', message}. A kind absent from the payload keeps its rows (a
-- failed AWS read); a snapshot no longer listed is marked absent only when the payload carries 'snapshots_read'.
CREATE OR REPLACE FUNCTION pgvigil.import_backups(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_backups'), p_instance_id);
  PERFORM pgvigil.ensure_month_partition('backup_sample', p_snapshot_at);

  INSERT INTO pgvigil.backup_state AS s (instance_id, kind, name, snapshot_at, archive_mode, archive_timeout, archive_set, archived_count,
                                         last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time, stats_reset,
                                         is_replica, wal_segment_bytes, current_lsn, archive_lag_bytes, archive_warn_minutes, resource_kind,
                                         retention_days, latest_restorable_time, earliest_restorable_time, backup_window, snapshot_type,
                                         status, created_at, allocated_gib, encrypted, first_seen, is_present)
  SELECT p_instance_id, r->>'kind', r->>'name', p_snapshot_at, r->>'archive_mode', r->>'archive_timeout', (r->>'archive_set')::boolean,
         (r->>'archived_count')::bigint, r->>'last_archived_wal', (r->>'last_archived_time')::timestamptz, (r->>'failed_count')::bigint,
         r->>'last_failed_wal', (r->>'last_failed_time')::timestamptz, (r->>'stats_reset')::timestamptz, (r->>'is_replica')::boolean,
         (r->>'wal_segment_bytes')::bigint, r->>'current_lsn', (r->>'archive_lag_bytes')::bigint,
         coalesce((r->>'archive_warn_minutes')::int, CASE WHEN r->>'kind' = 'archiver' THEN 60 END), r->>'resource_kind',
         (r->>'retention_days')::int, (r->>'latest_restorable_time')::timestamptz, (r->>'earliest_restorable_time')::timestamptz,
         r->>'backup_window', r->>'snapshot_type', r->>'status', (r->>'created_at')::timestamptz, (r->>'allocated_gib')::int,
         (r->>'encrypted')::boolean, p_snapshot_at, true
    FROM (SELECT DISTINCT ON (r->>'kind', r->>'name') r FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' IN ('archiver', 'cloud', 'snapshot') AND r->>'name' IS NOT NULL) x
  ON CONFLICT (instance_id, kind, name) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, archive_mode = EXCLUDED.archive_mode, archive_timeout = EXCLUDED.archive_timeout,
    archive_set = EXCLUDED.archive_set, archived_count = EXCLUDED.archived_count, last_archived_wal = EXCLUDED.last_archived_wal,
    last_archived_time = EXCLUDED.last_archived_time, failed_count = EXCLUDED.failed_count, last_failed_wal = EXCLUDED.last_failed_wal,
    last_failed_time = EXCLUDED.last_failed_time, stats_reset = EXCLUDED.stats_reset, is_replica = EXCLUDED.is_replica,
    wal_segment_bytes = EXCLUDED.wal_segment_bytes, current_lsn = EXCLUDED.current_lsn, archive_lag_bytes = EXCLUDED.archive_lag_bytes,
    archive_warn_minutes = EXCLUDED.archive_warn_minutes, resource_kind = EXCLUDED.resource_kind, retention_days = EXCLUDED.retention_days,
    latest_restorable_time = EXCLUDED.latest_restorable_time, earliest_restorable_time = EXCLUDED.earliest_restorable_time,
    backup_window = EXCLUDED.backup_window, snapshot_type = EXCLUDED.snapshot_type, status = EXCLUDED.status,
    created_at = EXCLUDED.created_at, allocated_gib = EXCLUDED.allocated_gib, encrypted = EXCLUDED.encrypted, is_present = true;

  -- absence: a cloud resource no longer named (the config moved to another), a snapshot no longer listed by a
  -- list that was read in full this run
  UPDATE pgvigil.backup_state s SET is_present = false
   WHERE s.instance_id = p_instance_id AND s.is_present AND s.kind IN ('cloud', 'archiver')
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = s.kind)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = s.kind AND r->>'name' = s.name);
  UPDATE pgvigil.backup_state s SET is_present = false
   WHERE s.instance_id = p_instance_id AND s.is_present AND s.kind = 'snapshot'
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'snapshots_read')
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'snapshot' AND r->>'name' = s.name);

  INSERT INTO pgvigil.backup_sample (instance_id, snapshot_at, archived_count, failed_count, archive_lag_bytes, last_archived_time, restorable_age_s)
  SELECT p_instance_id, p_snapshot_at, (a->>'archived_count')::bigint, (a->>'failed_count')::bigint, (a->>'archive_lag_bytes')::bigint,
         (a->>'last_archived_time')::timestamptz,
         round(extract(epoch FROM p_snapshot_at - (c->>'latest_restorable_time')::timestamptz)::numeric, 0)
    FROM (SELECT (SELECT r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'archiver' LIMIT 1) AS a,
                 (SELECT r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cloud' LIMIT 1) AS c) x
   WHERE x.a IS NOT NULL OR x.c IS NOT NULL;
END $$;

-- One row per active instance with a backups read: the archiver, the cloud side and the newest snapshots.
--   archiver_failing: a failed archive after the last success (or no success at all).
--   archive_age_s: the last archived file's age at the read; wal_waiting: more than one segment of WAL is waiting
--   to be archived (the current segment is archived only when it is full or archive_timeout switches it, so an
--   idle server can have an old last archive and nothing to archive).
--   archiving: archive_mode is on (or always) with a command or a library set, and the server archives (a standby
--   archives only with archive_mode = always).
CREATE OR REPLACE VIEW pgvigil.backup_status AS
WITH snap AS (
  SELECT instance_id,
         max(created_at) FILTER (WHERE snapshot_type = 'automated' AND status = 'available') AS newest_automated_at,
         max(created_at) FILTER (WHERE snapshot_type = 'manual' AND status = 'available') AS newest_manual_at,
         max(created_at) FILTER (WHERE status = 'available') AS newest_snapshot_at,
         count(*) FILTER (WHERE snapshot_type = 'automated') AS automated_count,
         count(*) FILTER (WHERE snapshot_type = 'manual') AS manual_count
    FROM pgvigil.backup_state WHERE kind = 'snapshot' AND is_present GROUP BY instance_id
)
SELECT i.instance_id, i.name AS instance, i.platform,
       a.archive_mode, a.archive_set, a.is_replica,
       (a.archive_set AND (a.archive_mode = 'always' OR (a.archive_mode = 'on' AND NOT a.is_replica))) AS archiving,
       a.archived_count, a.failed_count, a.last_archived_wal, a.last_archived_time, a.last_failed_wal, a.last_failed_time,
       a.stats_reset, a.archive_lag_bytes, a.wal_segment_bytes, a.archive_warn_minutes,
       round(extract(epoch FROM a.snapshot_at - a.last_archived_time)::numeric, 0) AS archive_age_s,
       (a.last_failed_time IS NOT NULL AND (a.last_archived_time IS NULL OR a.last_failed_time > a.last_archived_time)) AS archiver_failing,
       (a.archive_lag_bytes > a.wal_segment_bytes) AS wal_waiting,
       a.snapshot_at AS archiver_read_at,
       c.name AS cloud_resource, c.resource_kind, c.retention_days, c.latest_restorable_time, c.earliest_restorable_time, c.backup_window,
       round(extract(epoch FROM c.snapshot_at - c.latest_restorable_time)::numeric, 0) AS restorable_age_s,
       c.snapshot_at AS cloud_read_at,
       s.newest_automated_at, s.newest_manual_at, s.newest_snapshot_at,
       round(extract(epoch FROM c.snapshot_at - s.newest_snapshot_at)::numeric, 0) AS newest_snapshot_age_s,
       coalesce(s.automated_count, 0) AS automated_count, coalesce(s.manual_count, 0) AS manual_count
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.backup_state a ON a.instance_id = i.instance_id AND a.kind = 'archiver' AND a.is_present
  LEFT JOIN pgvigil.backup_state c ON c.instance_id = i.instance_id AND c.kind = 'cloud' AND c.is_present
  LEFT JOIN snap s ON s.instance_id = i.instance_id
 WHERE i.is_active AND (a.instance_id IS NOT NULL OR c.instance_id IS NOT NULL);

-- The four rules on the stored reads (instance_id, severity, check_name, object, at, detail):
--   archiver failing            critical: a failed archive after the last success; WAL piles up in pg_wal until it works
--   last archive older than N   warning: archiving is on, WAL is waiting and the last archive is older than the instance's
--                               threshold (archive_warn_minutes, 60 by default); not on Aurora (its storage keeps no
--                               WAL archive)
--   retention under 7 days      warning (critical at 0: automated backups are off)
--   no snapshot in 24 h         warning: the newest available snapshot (any type) is older than a day, or there is none
CREATE OR REPLACE VIEW pgvigil.backup_rule_hits AS
SELECT b.instance_id, 'critical' AS severity, 'archiver failing' AS check_name, coalesce(b.last_failed_wal, 'pg_stat_archiver') AS object,
       b.archiver_read_at AS at,
       'archive of ' || coalesce(b.last_failed_wal, '?') || ' failed at ' || to_char(b.last_failed_time AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC'
       || coalesce(', after the last success at ' || to_char(b.last_archived_time AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC', ', no success since the stats reset')
       || ' (' || b.failed_count || ' failed, ' || b.archived_count || ' archived)' AS detail
  FROM pgvigil.backup_status b
 WHERE b.archiver_failing AND b.platform <> 'aurora'
UNION ALL
SELECT b.instance_id, 'warning', 'last archive older than ' || b.archive_warn_minutes || ' min', coalesce(b.last_archived_wal, 'pg_stat_archiver'), b.archiver_read_at,
       coalesce('last archived ' || round(b.archive_age_s / 60) || ' min before the read', 'nothing archived since the stats reset')
       || '; ' || pg_size_pretty(b.archive_lag_bytes) || ' of WAL waiting'
  FROM pgvigil.backup_status b
 WHERE b.archiving AND b.wal_waiting AND b.platform <> 'aurora'
   AND (b.last_archived_time IS NULL OR b.archive_age_s > b.archive_warn_minutes * 60)
UNION ALL
SELECT b.instance_id, CASE WHEN b.retention_days = 0 THEN 'critical' ELSE 'warning' END, 'retention under 7 days', b.cloud_resource, b.cloud_read_at,
       CASE WHEN b.retention_days = 0 THEN 'automated backups are off (retention 0 days)'
            ELSE 'backup retention ' || b.retention_days || ' days' END
  FROM pgvigil.backup_status b
 WHERE b.retention_days < 7
UNION ALL
SELECT b.instance_id, 'warning', 'no snapshot in 24 h', b.cloud_resource, b.cloud_read_at,
       coalesce('newest snapshot ' || to_char(b.newest_snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC, '
                || round(b.newest_snapshot_age_s / 3600) || ' h before the read', 'no available snapshot listed')
  FROM pgvigil.backup_status b
 WHERE b.cloud_resource IS NOT NULL AND (b.newest_snapshot_at IS NULL OR b.newest_snapshot_age_s > 86400);

-- The overview's backup checks: the rule hits on reads of the last hour (a stale read is the stale check's).
CREATE OR REPLACE VIEW pgvigil.backup_checks AS
SELECT h.instance_id, h.severity, h.check_name, h.object, h.at, h.detail
  FROM pgvigil.backup_rule_hits h
 WHERE h.at > now() - interval '1 hour';

-- The rules in the findings columns; the join UNION ALLs this into pgvigil.findings.
CREATE OR REPLACE VIEW pgvigil.backup_findings AS
SELECT h.instance_id, h.severity, h.check_name AS setting, h.object || ': ' || h.detail AS value, true AS is_set,
       CASE h.check_name
         WHEN 'archiver failing' THEN 'read the server log for the archive_command error and fix the destination; WAL stays in pg_wal until it succeeds'
         WHEN 'retention under 7 days' THEN 'raise the backup retention period to 7 days or more'
         WHEN 'no snapshot in 24 h' THEN 'check the backup window and the automated backups; take a manual snapshot'
         ELSE 'check archive_command and its destination; set archive_timeout so a quiet server still archives'
       END AS suggested,
       CASE WHEN h.check_name IN ('retention under 7 days', 'no snapshot in 24 h') THEN 'managed' ELSE 'not aurora' END AS platforms,
       CASE h.check_name
         WHEN 'archiver failing' THEN 'a failing archiver leaves no point-in-time recovery past the last archived file and fills pg_wal'
         WHEN 'retention under 7 days' THEN 'a short retention leaves a narrow window to restore from (0 = no automated backups and no point-in-time restore)'
         WHEN 'no snapshot in 24 h' THEN 'a missed daily snapshot widens the replay a restore needs, or there is nothing to restore from'
         ELSE 'WAL waits to be archived: a point-in-time recovery would lose what is not yet archived'
       END AS detail,
       'pgvigil backups' AS source, h.at
  FROM pgvigil.backup_rule_hits h;
