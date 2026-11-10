-- 0066_mssql_hadr: SQL Server HA/DR, Agent jobs and backups (task 98): the imports of mssql_ag, mssql_mirroring,
-- mssql_logshipping, mssql_replication, mssql_jobs and mssql_backups, their thresholds, and the findings they feed.
--
--   mssql_hadr_thresholds   one row per instance whose configuration sets a threshold; a NULL column = the default.
--   mssql_hadr_limits       the thresholds in force per SQL Server instance: THE ONE PLACE THE DEFAULTS LIVE.
--   mssql_hadr_reads        per instance and collection the last read's time and row count and how many reads in a
--                           row stored nothing where rows are expected.
--   mssql_ag_state          current; one row per replica of a group as the instance sees it, the group's own columns
--                           (cluster type, distributed, contained, the primary, the listeners, the cluster) on each.
--                           A distributed group's replicas are its two member groups, by name.
--   mssql_ag_database_state current; one row per database replica the instance sees (a primary sees all, a secondary
--                           its own), with the queues, rates, estimates and the last times in UTC.
--   mssql_ag_sample         monthly partitions; the queues, rates and estimates of every database replica per read.
--   mssql_ag_failovers      one row per change of a group's primary the minute read saw: the time, from, to.
--   mssql_mirroring_state, mssql_logshipping_state, mssql_replication_state
--                           current; replaced by each read (a server without the feature holds no row).
--   mssql_jobs              current; one row per Agent job (the steps as jsonb), replaced by each read.
--   mssql_job_runs          monthly partitions BY THE RUN'S OWN TIME (snapshot_at = when the step or job ran, UTC);
--                           sysjobhistory rows, each stored once (history_id = sysjobhistory.instance_id).
--   mssql_jobs_cursor       how far sysjobhistory was read per instance; advanced by the import, in its transaction.
--   mssql_backup_state      current; per database of an instance its state and recovery model and the last full,
--                           differential and log backup the instance's own msdb knows. A backup once seen is kept
--                           when msdb's history is trimmed.
--   mssql_backup_judged     per database the backups judged: merged over every monitored replica of its availability
--                           group (by group id and database name), each age taken AT THE READ against the threshold
--                           of its type, and why a database is not judged.
--   mssql_hadr_findings, mssql_jobs_findings
--                           the findings views (instance_id, severity, check_name, object, at, detail). The UNION arms
--                           in pgvigil.findings and the purge lines (the two partition parents mssql_ag_sample and
--                           mssql_job_runs; mssql_ag_failovers past the window) are the wave's join.
--
-- "For 5 minutes" means: in every read of the last 5.5 minutes, the first at least 4 minutes old and the last at most
-- 2 minutes old (an instance not read lately fires nothing). A state row older than 5 minutes (15 for the
-- five-minute collections, 130 for the hourly one) fires nothing either: the Collections page says the read is stale.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_hadr_thresholds (
  instance_id                  int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  log_send_queue_kb            numeric,
  redo_queue_kb                numeric,
  repl_undistributed_commands  numeric,
  job_failed_hours             numeric,
  job_long_factor              numeric,
  job_long_min_seconds         numeric,
  full_backup_hours            numeric,
  diff_backup_hours            numeric,
  log_backup_minutes           numeric,
  new_database_hours           numeric,
  nul_backup_days              numeric,
  backup_exclude               text[],
  updated_at                   timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE VIEW pgvigil.mssql_hadr_limits AS
SELECT i.instance_id,
       coalesce(t.log_send_queue_kb, 102400) AS log_send_queue_kb,
       coalesce(t.redo_queue_kb, 512000) AS redo_queue_kb,
       coalesce(t.repl_undistributed_commands, 100000) AS repl_undistributed_commands,
       coalesce(t.job_failed_hours, 24) AS job_failed_hours,
       coalesce(t.job_long_factor, 3) AS job_long_factor,
       coalesce(t.job_long_min_seconds, 300) AS job_long_min_seconds,
       coalesce(t.full_backup_hours, 168) AS full_backup_hours,
       coalesce(t.diff_backup_hours, 0) AS diff_backup_hours,
       coalesce(t.log_backup_minutes, 60) AS log_backup_minutes,
       coalesce(t.new_database_hours, 24) AS new_database_hours,
       coalesce(t.nul_backup_days, 7) AS nul_backup_days,
       coalesce(t.backup_exclude, '{}') AS backup_exclude
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.mssql_hadr_thresholds t ON t.instance_id = i.instance_id
 WHERE i.engine = 'sqlserver';

-- payload: one object {name: number, ..., backup_exclude: [pattern, ...]}; a name left out goes back to its default
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_hadr_thresholds(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v jsonb;
  v_bad text;
  v_known text[] := ARRAY['log_send_queue_kb', 'redo_queue_kb', 'repl_undistributed_commands', 'job_failed_hours', 'job_long_factor',
                          'job_long_min_seconds', 'full_backup_hours', 'diff_backup_hours', 'log_backup_minutes', 'new_database_hours',
                          'nul_backup_days', 'backup_exclude'];
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_hadr_thresholds: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  v := CASE WHEN jsonb_typeof(p_payload) = 'array' THEN coalesce(p_payload->0, '{}') ELSE '{}' END;
  IF jsonb_typeof(v) <> 'object' THEN
    RAISE EXCEPTION 'import_mssql_hadr_thresholds: the payload is not one object';
  END IF;
  SELECT string_agg(k, ', ') INTO v_bad FROM jsonb_object_keys(v) k WHERE k <> ALL (v_known);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'import_mssql_hadr_thresholds: unknown threshold(s) %; known: %', v_bad, array_to_string(v_known, ', ');
  END IF;
  SELECT string_agg(e.key, ', ') INTO v_bad FROM jsonb_each(v) e
   WHERE e.key <> 'backup_exclude' AND (jsonb_typeof(e.value) <> 'number' OR (e.value #>> '{}')::numeric < 0);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'import_mssql_hadr_thresholds: % must be a number of 0 or more', v_bad;
  END IF;
  IF v ? 'backup_exclude' AND jsonb_typeof(v->'backup_exclude') <> 'array' THEN
    RAISE EXCEPTION 'import_mssql_hadr_thresholds: backup_exclude must be a list of patterns';
  END IF;
  IF v = '{}' THEN
    DELETE FROM pgvigil.mssql_hadr_thresholds WHERE instance_id = p_instance_id;
    RETURN;
  END IF;
  INSERT INTO pgvigil.mssql_hadr_thresholds AS t (instance_id, log_send_queue_kb, redo_queue_kb, repl_undistributed_commands,
      job_failed_hours, job_long_factor, job_long_min_seconds, full_backup_hours, diff_backup_hours, log_backup_minutes,
      new_database_hours, nul_backup_days, backup_exclude, updated_at)
  VALUES (p_instance_id, (v->>'log_send_queue_kb')::numeric, (v->>'redo_queue_kb')::numeric, (v->>'repl_undistributed_commands')::numeric,
      (v->>'job_failed_hours')::numeric, (v->>'job_long_factor')::numeric, (v->>'job_long_min_seconds')::numeric,
      (v->>'full_backup_hours')::numeric, (v->>'diff_backup_hours')::numeric, (v->>'log_backup_minutes')::numeric,
      (v->>'new_database_hours')::numeric, (v->>'nul_backup_days')::numeric,
      CASE WHEN v ? 'backup_exclude' THEN ARRAY(SELECT jsonb_array_elements_text(v->'backup_exclude')) END, p_snapshot_at)
  ON CONFLICT (instance_id) DO UPDATE SET
      log_send_queue_kb = EXCLUDED.log_send_queue_kb, redo_queue_kb = EXCLUDED.redo_queue_kb,
      repl_undistributed_commands = EXCLUDED.repl_undistributed_commands, job_failed_hours = EXCLUDED.job_failed_hours,
      job_long_factor = EXCLUDED.job_long_factor, job_long_min_seconds = EXCLUDED.job_long_min_seconds,
      full_backup_hours = EXCLUDED.full_backup_hours, diff_backup_hours = EXCLUDED.diff_backup_hours,
      log_backup_minutes = EXCLUDED.log_backup_minutes, new_database_hours = EXCLUDED.new_database_hours,
      nul_backup_days = EXCLUDED.nul_backup_days, backup_exclude = EXCLUDED.backup_exclude, updated_at = EXCLUDED.updated_at
  WHERE t.updated_at <= EXCLUDED.updated_at;
END $$;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_hadr_reads (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  collection   text NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  row_count    int NOT NULL,
  empty_reads  int NOT NULL DEFAULT 0,
  PRIMARY KEY (instance_id, collection)
);

-- mssql_hadr_read: the first statement of every import of this file. It refuses an instance of another engine,
-- takes the instance's lock for the collection (two imports of one collection never interleave), records the read
-- and answers whether this read is the newest so far (an older one, imported late, must not replace current state).
CREATE OR REPLACE FUNCTION pgvigil.mssql_hadr_read(p_instance_id int, p_collection text, p_snapshot_at timestamptz, p_rows int)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_last timestamptz;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_%: instance % is not a SQL Server instance', p_collection, p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.' || p_collection), p_instance_id);
  SELECT snapshot_at INTO v_last FROM pgvigil.mssql_hadr_reads WHERE instance_id = p_instance_id AND collection = p_collection;
  IF v_last IS NOT NULL AND v_last > p_snapshot_at THEN
    RETURN false;
  END IF;
  INSERT INTO pgvigil.mssql_hadr_reads AS r (instance_id, collection, snapshot_at, row_count, empty_reads)
  VALUES (p_instance_id, p_collection, p_snapshot_at, p_rows, CASE WHEN p_rows = 0 THEN 1 ELSE 0 END)
  ON CONFLICT (instance_id, collection) DO UPDATE SET
      empty_reads = CASE WHEN EXCLUDED.row_count > 0 THEN 0
                         WHEN r.snapshot_at = EXCLUDED.snapshot_at THEN r.empty_reads   -- a re-run of one read
                         ELSE r.empty_reads + 1 END,
      snapshot_at = EXCLUDED.snapshot_at, row_count = EXCLUDED.row_count;
  RETURN true;
END $$;

-- a payload that is no array (a collector that read nothing may hand over null) is an empty one
CREATE OR REPLACE FUNCTION pgvigil.mssql_rows(p_payload jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN jsonb_typeof(p_payload) = 'array' THEN p_payload ELSE '[]'::jsonb END
$$;

-- ---------------------------------------------------------------------------------------------------------------
-- Always On availability groups

CREATE TABLE IF NOT EXISTS pgvigil.mssql_ag_state (
  instance_id               int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  group_id                  text NOT NULL,
  replica_server            text NOT NULL,       -- a distributed group: the member group's name
  snapshot_at               timestamptz NOT NULL,
  group_name                text NOT NULL,
  cluster_type              text,                -- WSFC | EXTERNAL | NONE; NULL before SQL Server 2017
  is_distributed            boolean,
  is_contained              boolean,             -- NULL before SQL Server 2022
  backup_preference         text,
  db_failover               boolean,
  required_sync_secondaries int,
  primary_replica           text,                -- as the group's state names it, on a secondary too; the last one known while it names none
  group_health              text,
  listeners                 jsonb,
  cluster                   jsonb,               -- the cluster's members where readable; {"unread": reason} where not
  replica_id                text,
  endpoint_url              text,
  availability_mode         text,
  failover_mode             text,
  seeding_mode              text,
  secondary_connections     text,
  backup_priority           int,
  session_timeout           int,
  is_local                  boolean,
  role                      text,                -- as the replica reports it; NULL for a replica a secondary cannot see
  operational_state         text,
  connected_state           text,
  recovery_health           text,
  synchronization_health    text,
  last_connect_error        int,
  last_connect_error_text   text,
  last_connect_error_at     timestamptz,
  PRIMARY KEY (instance_id, group_id, replica_server)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_ag_database_state (
  instance_id             int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  group_id                text NOT NULL,
  replica_server          text NOT NULL,
  database_name           text NOT NULL,
  snapshot_at             timestamptz NOT NULL,
  group_name              text NOT NULL,
  is_local                boolean,
  is_primary_replica      boolean,
  synchronization_state   text,
  synchronization_health  text,
  database_state          text,
  is_suspended            boolean,
  suspend_reason          text,
  log_send_queue_kb       bigint,
  log_send_rate_kb_s      bigint,
  redo_queue_kb           bigint,
  redo_rate_kb_s          bigint,
  est_data_loss_s         bigint,                -- the primary's last commit less this replica's; only a primary knows
  est_recovery_s          double precision,      -- the redo queue over the redo rate
  secondary_lag_s         bigint,
  last_sent_at            timestamptz,
  last_received_at        timestamptz,
  last_hardened_at        timestamptz,
  last_redone_at          timestamptz,
  last_commit_at          timestamptz,
  PRIMARY KEY (instance_id, group_id, replica_server, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_ag_sample (
  instance_id            int NOT NULL,
  snapshot_at            timestamptz NOT NULL,
  group_name             text NOT NULL,
  replica_server         text NOT NULL,
  database_name          text NOT NULL,
  synchronization_state  text,
  is_suspended           boolean,
  log_send_queue_kb      bigint,
  log_send_rate_kb_s     bigint,
  redo_queue_kb          bigint,
  redo_rate_kb_s         bigint,
  est_data_loss_s        bigint,
  est_recovery_s         double precision
) PARTITION BY RANGE (snapshot_at);
-- mssql_hadr_findings reads the last minutes of every instance by snapshot_at alone
CREATE INDEX IF NOT EXISTS mssql_ag_sample_at_idx ON pgvigil.mssql_ag_sample (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_ag_failovers (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  group_id     text NOT NULL,
  at           timestamptz NOT NULL,   -- the read that first saw the new primary: the change happened in the minute before
  group_name   text NOT NULL,
  old_primary  text NOT NULL,
  new_primary  text NOT NULL,
  PRIMARY KEY (instance_id, group_id, at)
);
CREATE INDEX IF NOT EXISTS mssql_ag_failovers_at_idx ON pgvigil.mssql_ag_failovers (at);

-- payload: 'replica' rows (the group's columns on each), 'database' rows, 'listener' rows, 'cluster_member' rows or
-- one 'cluster_unread' row; an empty array = the server has no group (the state is cleared)
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_ag(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := pgvigil.mssql_rows(p_payload);
  v_newest boolean;
  v_cluster jsonb;
  v_known jsonb;
BEGIN
  v_newest := pgvigil.mssql_hadr_read(p_instance_id, 'mssql_ag', p_snapshot_at,
                (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'replica'));

  PERFORM pgvigil.ensure_month_partition('mssql_ag_sample', p_snapshot_at);
  DELETE FROM pgvigil.mssql_ag_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;   -- a re-run of one read
  INSERT INTO pgvigil.mssql_ag_sample (instance_id, snapshot_at, group_name, replica_server, database_name, synchronization_state,
      is_suspended, log_send_queue_kb, log_send_rate_kb_s, redo_queue_kb, redo_rate_kb_s, est_data_loss_s, est_recovery_s)
  SELECT p_instance_id, p_snapshot_at, r->>'group_name', r->>'replica_server', r->>'database_name', r->>'synchronization_state',
         (r->>'is_suspended')::int = 1, (r->>'log_send_queue_kb')::bigint, (r->>'log_send_rate_kb_s')::bigint,
         (r->>'redo_queue_kb')::bigint, (r->>'redo_rate_kb_s')::bigint, (r->>'est_data_loss_s')::bigint, (r->>'est_recovery_s')::float8
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'database' AND r->>'group_name' IS NOT NULL AND r->>'replica_server' IS NOT NULL AND r->>'database_name' IS NOT NULL;

  IF NOT v_newest THEN
    RETURN;   -- an older read imported late: its samples are history, the current state stays the newer read's
  END IF;

  -- a failover is the group's primary changing between two reads; kept with its time so a chart can mark it
  INSERT INTO pgvigil.mssql_ag_failovers (instance_id, group_id, at, group_name, old_primary, new_primary)
  SELECT DISTINCT ON (r->>'group_id') p_instance_id, r->>'group_id', p_snapshot_at, r->>'group_name', s.primary_replica, r->>'primary_replica'
    FROM jsonb_array_elements(v_rows) r
    JOIN LATERAL (SELECT x.primary_replica FROM pgvigil.mssql_ag_state x
                   WHERE x.instance_id = p_instance_id AND x.group_id = r->>'group_id' AND x.primary_replica IS NOT NULL
                   LIMIT 1) s ON true
   WHERE r->>'kind' = 'replica' AND nullif(r->>'primary_replica', '') IS NOT NULL
     AND lower(r->>'primary_replica') <> lower(s.primary_replica)
  ON CONFLICT DO NOTHING;

  SELECT CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'cluster_unread')
              THEN jsonb_build_object('unread', (SELECT r->>'message' FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'cluster_unread' LIMIT 1))
              ELSE (SELECT jsonb_agg(r - 'kind' ORDER BY r->>'member_name') FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'cluster_member') END
    INTO v_cluster;

  -- a group in the middle of a failover names no primary (RESOLVING): the last one known is kept through such a
  -- read, so the change is still seen when the new primary appears
  SELECT coalesce(jsonb_object_agg(g.group_id, g.primary_replica), '{}') INTO v_known
    FROM (SELECT DISTINCT ON (x.group_id) x.group_id, x.primary_replica FROM pgvigil.mssql_ag_state x
           WHERE x.instance_id = p_instance_id AND x.primary_replica IS NOT NULL) g;
  DELETE FROM pgvigil.mssql_ag_state WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_ag_state (instance_id, group_id, replica_server, snapshot_at, group_name, cluster_type, is_distributed,
      is_contained, backup_preference, db_failover, required_sync_secondaries, primary_replica, group_health, listeners, cluster,
      replica_id, endpoint_url, availability_mode, failover_mode, seeding_mode, secondary_connections, backup_priority,
      session_timeout, is_local, role, operational_state, connected_state, recovery_health, synchronization_health,
      last_connect_error, last_connect_error_text, last_connect_error_at)
  SELECT DISTINCT ON (r->>'group_id', r->>'replica_server')
         p_instance_id, r->>'group_id', r->>'replica_server', p_snapshot_at, r->>'group_name', r->>'cluster_type',
         (r->>'is_distributed')::int = 1, (r->>'is_contained')::int = 1, r->>'backup_preference', (r->>'db_failover')::int = 1,
         (r->>'required_sync_secondaries')::int, coalesce(nullif(r->>'primary_replica', ''), v_known->>(r->>'group_id')), r->>'group_health',
         (SELECT jsonb_agg(l - 'kind' - 'group_id' ORDER BY l->>'dns_name') FROM jsonb_array_elements(v_rows) l
           WHERE l->>'kind' = 'listener' AND l->>'group_id' = r->>'group_id'),
         v_cluster, r->>'replica_id', r->>'endpoint_url', r->>'availability_mode', r->>'failover_mode', r->>'seeding_mode',
         r->>'secondary_connections', (r->>'backup_priority')::int, (r->>'session_timeout')::int, (r->>'is_local')::int = 1,
         r->>'role', r->>'operational_state', r->>'connected_state', r->>'recovery_health', r->>'synchronization_health',
         (r->>'last_connect_error')::int, r->>'last_connect_error_text', (r->>'last_connect_error_utc')::timestamptz
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'replica' AND r->>'group_id' IS NOT NULL AND r->>'replica_server' IS NOT NULL AND r->>'group_name' IS NOT NULL;

  DELETE FROM pgvigil.mssql_ag_database_state WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_ag_database_state (instance_id, group_id, replica_server, database_name, snapshot_at, group_name, is_local,
      is_primary_replica, synchronization_state, synchronization_health, database_state, is_suspended, suspend_reason,
      log_send_queue_kb, log_send_rate_kb_s, redo_queue_kb, redo_rate_kb_s, est_data_loss_s, est_recovery_s, secondary_lag_s,
      last_sent_at, last_received_at, last_hardened_at, last_redone_at, last_commit_at)
  SELECT DISTINCT ON (r->>'group_id', r->>'replica_server', r->>'database_name')
         p_instance_id, r->>'group_id', r->>'replica_server', r->>'database_name', p_snapshot_at, r->>'group_name',
         (r->>'is_local')::int = 1, (r->>'is_primary_replica')::int = 1, r->>'synchronization_state', r->>'synchronization_health',
         r->>'database_state', (r->>'is_suspended')::int = 1, r->>'suspend_reason', (r->>'log_send_queue_kb')::bigint,
         (r->>'log_send_rate_kb_s')::bigint, (r->>'redo_queue_kb')::bigint, (r->>'redo_rate_kb_s')::bigint,
         (r->>'est_data_loss_s')::bigint, (r->>'est_recovery_s')::float8, (r->>'secondary_lag_s')::bigint,
         (r->>'last_sent_utc')::timestamptz, (r->>'last_received_utc')::timestamptz, (r->>'last_hardened_utc')::timestamptz,
         (r->>'last_redone_utc')::timestamptz, (r->>'last_commit_utc')::timestamptz
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'database' AND r->>'group_id' IS NOT NULL AND r->>'replica_server' IS NOT NULL
     AND r->>'database_name' IS NOT NULL AND r->>'group_name' IS NOT NULL;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- mirroring, log shipping, replication: current state, replaced by each read

CREATE TABLE IF NOT EXISTS pgvigil.mssql_mirroring_state (
  instance_id           int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name         text NOT NULL,
  snapshot_at           timestamptz NOT NULL,
  role                  text,     -- PRINCIPAL | MIRROR
  state                 text,     -- SYNCHRONIZED | SYNCHRONIZING | SUSPENDED | DISCONNECTED | PENDING_FAILOVER
  safety_level          text,     -- FULL | OFF
  partner               text,
  partner_instance      text,
  witness               text,
  witness_state         text,
  connection_timeout_s  int,
  log_send_queue_kb     bigint,
  redo_queue_kb         bigint,
  PRIMARY KEY (instance_id, database_name)
);

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_mirroring(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_rows jsonb := pgvigil.mssql_rows(p_payload);
BEGIN
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_mirroring', p_snapshot_at,
           (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'mirror')) THEN
    RETURN;
  END IF;
  DELETE FROM pgvigil.mssql_mirroring_state WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_mirroring_state (instance_id, database_name, snapshot_at, role, state, safety_level, partner,
      partner_instance, witness, witness_state, connection_timeout_s, log_send_queue_kb, redo_queue_kb)
  SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', p_snapshot_at, r->>'role', r->>'state',
         r->>'safety_level', r->>'partner', r->>'partner_instance', r->>'witness', r->>'witness_state',
         (r->>'connection_timeout_s')::int, (r->>'log_send_queue_kb')::bigint, (r->>'redo_queue_kb')::bigint
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'mirror' AND r->>'database_name' IS NOT NULL;
END $$;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_logshipping_state (
  instance_id                int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  role                       text NOT NULL CHECK (role IN ('primary', 'secondary')),
  database_name              text NOT NULL,
  snapshot_at                timestamptz NOT NULL,
  primary_server             text,
  primary_database           text,
  secondary_server           text NOT NULL DEFAULT '',   -- '' on a primary row
  threshold_minutes          int,       -- the configuration's own backup_threshold or restore_threshold
  alert_enabled              boolean,
  last_backup_file           text,
  last_backup_at             timestamptz,
  last_copied_file           text,
  last_copied_at             timestamptz,
  last_restored_file         text,
  last_restored_at           timestamptz,
  last_restored_latency_min  int,
  -- a monitor server lists every secondary, and two secondaries usually carry the same database name
  PRIMARY KEY (instance_id, role, database_name, secondary_server)
);

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_logshipping(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_rows jsonb := pgvigil.mssql_rows(p_payload);
BEGIN
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_logshipping', p_snapshot_at,
           (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' IN ('primary', 'secondary'))) THEN
    RETURN;
  END IF;
  DELETE FROM pgvigil.mssql_logshipping_state WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_logshipping_state (instance_id, role, database_name, snapshot_at, primary_server, primary_database,
      secondary_server, threshold_minutes, alert_enabled, last_backup_file, last_backup_at, last_copied_file, last_copied_at,
      last_restored_file, last_restored_at, last_restored_latency_min)
  SELECT DISTINCT ON (r->>'kind', r->>'database_name', coalesce(r->>'secondary_server', ''))
         p_instance_id, r->>'kind', r->>'database_name', p_snapshot_at,
         r->>'primary_server', coalesce(r->>'primary_database', CASE WHEN r->>'kind' = 'primary' THEN r->>'database_name' END),
         coalesce(r->>'secondary_server', ''), (r->>'threshold_minutes')::int, (r->>'alert_enabled')::int = 1, r->>'last_backup_file',
         (r->>'last_backup_utc')::timestamptz, r->>'last_copied_file', (r->>'last_copied_utc')::timestamptz,
         r->>'last_restored_file', (r->>'last_restored_utc')::timestamptz, (r->>'last_restored_latency_min')::int
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' IN ('primary', 'secondary') AND r->>'database_name' IS NOT NULL;
END $$;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_replication_state (
  instance_id        int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at        timestamptz NOT NULL,
  kind               text NOT NULL CHECK (kind IN ('publication', 'subscription', 'agent')),
  distribution_db    text NOT NULL,
  publisher          text,
  publisher_db       text,
  publication        text,
  publication_type   text,        -- publication: transactional | snapshot | merge
  articles           int,
  subscriber         text,        -- subscription
  subscriber_db      text,
  subscription_type  text,        -- push | pull | anonymous
  agent_type         text,        -- subscription: distribution; agent: logreader | snapshot | merge
  agent_name         text,
  runstatus          int,         -- 1 start, 2 succeed, 3 in progress, 4 idle, 5 retry, 6 fail
  status_text        text,
  last_run_at        timestamptz,
  latency_ms         bigint,
  delivery_rate      double precision,   -- commands per second, the agent's last history row
  undistributed      bigint,             -- commands in the distribution database not yet delivered
  est_catchup_s      double precision    -- undistributed over the delivery rate
);
CREATE INDEX IF NOT EXISTS mssql_replication_state_inst_idx ON pgvigil.mssql_replication_state (instance_id);

-- which kind of row a table of the distribution database feeds (the collector's three reads)
CREATE OR REPLACE FUNCTION pgvigil.mssql_repl_kind(p_table text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_table WHEN 'MSpublications' THEN 'publication' WHEN 'MSdistribution_agents' THEN 'subscription'
                      WHEN 'MSlogreader_agents' THEN 'agent' END
$$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_replication(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_rows jsonb := pgvigil.mssql_rows(p_payload);
BEGIN
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_replication', p_snapshot_at,
           (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' IN ('publication', 'subscription', 'agent'))) THEN
    RETURN;
  END IF;
  -- a read that failed (a collector_error row names its source: <database>.dbo.<table>, or the database alone when
  -- the login cannot enter it) keeps the last rows of ITS kind for that database; the kinds that were read are replaced
  DELETE FROM pgvigil.mssql_replication_state s
   WHERE s.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) e
                      WHERE e->>'kind' = 'collector_error' AND split_part(e->>'source', '.dbo.', 1) = s.distribution_db
                        AND coalesce(pgvigil.mssql_repl_kind(split_part(e->>'source', '.dbo.', 2)), s.kind) = s.kind);
  INSERT INTO pgvigil.mssql_replication_state (instance_id, snapshot_at, kind, distribution_db, publisher, publisher_db, publication,
      publication_type, articles, subscriber, subscriber_db, subscription_type, agent_type, agent_name, runstatus, status_text,
      last_run_at, latency_ms, delivery_rate, undistributed, est_catchup_s)
  SELECT p_instance_id, p_snapshot_at, r->>'kind', r->>'distribution_db', r->>'publisher', r->>'publisher_db', r->>'publication',
         r->>'publication_type', (r->>'articles')::int, r->>'subscriber', r->>'subscriber_db', r->>'subscription_type',
         r->>'agent_type', r->>'agent_name', (r->>'runstatus')::int, r->>'status_text', (r->>'last_run_utc')::timestamptz,
         (r->>'latency_ms')::bigint, (r->>'delivery_rate')::float8, (r->>'undistributed')::bigint, (r->>'est_catchup_s')::float8
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' IN ('publication', 'subscription', 'agent') AND r->>'distribution_db' IS NOT NULL;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Agent jobs

CREATE TABLE IF NOT EXISTS pgvigil.mssql_jobs (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  job_id              text NOT NULL,
  snapshot_at         timestamptz NOT NULL,
  name                text NOT NULL,
  enabled             boolean,
  description         text,
  category            text,
  owner               text,
  created_at          timestamptz,
  modified_at         timestamptz,
  schedules           int,
  enabled_schedules   int,
  schedule_names      text,
  next_run_at         timestamptz,
  last_outcome        int,          -- 0 failed, 1 succeeded, 3 cancelled, 5 unknown (never run)
  last_run_at         timestamptz,
  last_duration_s     bigint,
  last_message        text,
  running_since       timestamptz,  -- not NULL = the job runs now
  running_after_step  int,          -- the last step that finished in this run
  steps               jsonb,        -- [{step_id, step_name, subsystem, database_name, last_outcome, last_run_utc, last_duration_s}]
  PRIMARY KEY (instance_id, job_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_job_runs (
  instance_id     int NOT NULL,
  snapshot_at     timestamptz NOT NULL,   -- when the step (or, for step 0, the job) started: the run's own time
  history_id      bigint NOT NULL,        -- msdb.dbo.sysjobhistory.instance_id
  job_id          text NOT NULL,
  job_name        text,
  step_id         int NOT NULL,           -- 0 = the job's own outcome row
  step_name       text,
  run_date        int,                    -- msdb's own integers (yyyymmdd, hhmmss, the server's local clock): with
  run_time        int,                    -- history_id, job_id and step_id they say which row this is, whatever the offset
  run_status      int,                    -- 0 failed, 1 succeeded, 2 retry, 3 cancelled
  duration_s      bigint,
  sql_message_id  int,
  sql_severity    int,
  retries         int,
  message         text
) PARTITION BY RANGE (snapshot_at);
-- mssql_jobs_findings reads the last day of every instance by snapshot_at alone
CREATE INDEX IF NOT EXISTS mssql_job_runs_at_idx ON pgvigil.mssql_job_runs (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_jobs_cursor (
  instance_id      int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  last_history_id  bigint NOT NULL,
  mark             bigint,              -- a checksum of the row at last_history_id as it was read
  updated_at       timestamptz NOT NULL
);

-- mssql_hadr_cursor: how far a source of an instance was read (NULL: never). Sources: 'jobs' (the newest
-- sysjobhistory row read) and 'jobs_mark' (that row's mark: msdb replaced under the cursor shows as another mark).
CREATE OR REPLACE FUNCTION pgvigil.mssql_hadr_cursor(p_instance_id int, p_source text)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT CASE p_source WHEN 'jobs' THEN c.last_history_id WHEN 'jobs_mark' THEN c.mark END
    FROM pgvigil.mssql_jobs_cursor c WHERE c.instance_id = p_instance_id
$$;

-- payload: 'job' rows, 'step' rows, 'run' rows (sysjobhistory, each stored once), one 'read' row, and from a cursor
-- read one 'cursor' row {last_history_id, mark}: the cursor moves to it in this transaction
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_jobs(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := pgvigil.mssql_rows(p_payload);
  v_newest boolean;
  v_month timestamptz;
  v_cursor bigint;
  v_mark bigint;
BEGIN
  v_newest := pgvigil.mssql_hadr_read(p_instance_id, 'mssql_jobs', p_snapshot_at,
                (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'job'));

  FOR v_month IN SELECT DISTINCT date_trunc('month', (r->>'run_utc')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
                   FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'run' AND r->>'run_utc' IS NOT NULL LOOP
    PERFORM pgvigil.ensure_month_partition('mssql_job_runs', v_month);
  END LOOP;
  -- a row is stored once: the same number, job, step and msdb date and time, within three hours of the instant
  -- (the instant itself moves by an hour when the server's offset changes between two reads of one row)
  INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, step_name, run_date, run_time,
      run_status, duration_s, sql_message_id, sql_severity, retries, message)
  SELECT DISTINCT ON ((r->>'history_id')::bigint)
         p_instance_id, (r->>'run_utc')::timestamptz, (r->>'history_id')::bigint, r->>'job_id', r->>'job_name', (r->>'step_id')::int,
         r->>'step_name', (r->>'run_date')::int, (r->>'run_time')::int, (r->>'run_status')::int, (r->>'duration_s')::bigint, (r->>'sql_message_id')::int,
         (r->>'sql_severity')::int, (r->>'retries')::int, r->>'message'
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'run' AND r->>'run_utc' IS NOT NULL AND r->>'history_id' IS NOT NULL AND r->>'job_id' IS NOT NULL
     AND r->>'step_id' IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_job_runs x
                      WHERE x.instance_id = p_instance_id
                        AND x.snapshot_at BETWEEN (r->>'run_utc')::timestamptz - interval '3 hours' AND (r->>'run_utc')::timestamptz + interval '3 hours'
                        AND x.history_id = (r->>'history_id')::bigint AND x.job_id = r->>'job_id' AND x.step_id = (r->>'step_id')::int
                        AND x.run_date IS NOT DISTINCT FROM (r->>'run_date')::int AND x.run_time IS NOT DISTINCT FROM (r->>'run_time')::int);

  SELECT (r->>'last_history_id')::bigint, (r->>'mark')::bigint INTO v_cursor, v_mark
    FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'cursor' LIMIT 1;
  IF v_cursor IS NOT NULL AND v_newest THEN
    INSERT INTO pgvigil.mssql_jobs_cursor (instance_id, last_history_id, mark, updated_at) VALUES (p_instance_id, v_cursor, v_mark, p_snapshot_at)
    ON CONFLICT (instance_id) DO UPDATE SET last_history_id = EXCLUDED.last_history_id, mark = EXCLUDED.mark, updated_at = EXCLUDED.updated_at;
  END IF;

  IF NOT v_newest THEN
    RETURN;
  END IF;
  DELETE FROM pgvigil.mssql_jobs WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, description, category, owner, created_at,
      modified_at, schedules, enabled_schedules, schedule_names, next_run_at, last_outcome, last_run_at, last_duration_s,
      last_message, running_since, running_after_step, steps)
  SELECT DISTINCT ON (r->>'job_id') p_instance_id, r->>'job_id', p_snapshot_at, r->>'name', (r->>'enabled')::int = 1, r->>'description',
         r->>'category', r->>'owner', (r->>'created_utc')::timestamptz, (r->>'modified_utc')::timestamptz, (r->>'schedules')::int,
         (r->>'enabled_schedules')::int, r->>'schedule_names', (r->>'next_run_utc')::timestamptz, (r->>'last_outcome')::int,
         (r->>'last_run_utc')::timestamptz, (r->>'last_duration_s')::bigint, r->>'last_message',
         (r->>'running_since_utc')::timestamptz, (r->>'running_after_step')::int,
         (SELECT jsonb_agg(s - 'kind' - 'job_id' ORDER BY (s->>'step_id')::int) FROM jsonb_array_elements(v_rows) s
           WHERE s->>'kind' = 'step' AND s->>'job_id' = r->>'job_id')
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'job' AND r->>'job_id' IS NOT NULL AND r->>'name' IS NOT NULL;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- backups

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_state (
  instance_id            int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name          text NOT NULL,
  snapshot_at            timestamptz NOT NULL,
  is_present             boolean NOT NULL DEFAULT true,   -- false: the server no longer lists the database
  state                  text,
  recovery_model         text,
  created_at             timestamptz,
  is_snapshot            boolean,       -- a database snapshot
  is_read_only           boolean,
  is_standby             boolean,
  ag_group_id            text,
  ag_name                text,
  full_at                timestamptz,
  full_bytes             bigint,
  full_compressed_bytes  bigint,
  full_duration_s        bigint,
  full_device            text,
  full_device_name       text,
  full_copy_only         boolean,
  full_snapshot          boolean,       -- a snapshot (VSS / storage) backup
  diff_at                timestamptz,
  diff_bytes             bigint,
  diff_compressed_bytes  bigint,
  diff_duration_s        bigint,
  diff_device            text,
  diff_device_name       text,
  log_at                 timestamptz,
  log_bytes              bigint,
  log_compressed_bytes   bigint,
  log_duration_s         bigint,
  log_device             text,
  log_device_name        text,
  log_copy_only          boolean,
  nul_at                 timestamptz,   -- the newest backup that went to the NUL device: no backup at all
  nul_type               text,
  history_from           timestamptz,   -- how far back this server's msdb backup history reaches
  PRIMARY KEY (instance_id, database_name)
);
CREATE INDEX IF NOT EXISTS mssql_backup_state_ag_idx ON pgvigil.mssql_backup_state (ag_group_id, database_name) WHERE ag_group_id IS NOT NULL;

-- mssql_recreated: whether a database's creation time changed between two reads. The collector converts the
-- server's local create_date by the offset at the read, so a daylight-saving change moves it by an hour: only a
-- larger change is another database.
CREATE OR REPLACE FUNCTION pgvigil.mssql_recreated(p_old timestamptz, p_new timestamptz)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT (p_old IS NULL) <> (p_new IS NULL) OR abs(extract(epoch FROM p_new - p_old)) > 3900
$$;

-- payload: 'database' rows (every database of the server), 'backup' rows (the newest per database, type and sink:
-- 'backup', 'nul', or 'seeding' = an availability group's automatic seeding stream, which is not stored), one
-- 'history' row. A backup the repository has seen stays when msdb no longer lists it (a trimmed history).
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_backups(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := pgvigil.mssql_rows(p_payload);
  v_from timestamptz;
BEGIN
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_backups', p_snapshot_at,
           (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'database')) THEN
    RETURN;
  END IF;
  SELECT (r->>'oldest_utc')::timestamptz INTO v_from FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'history' LIMIT 1;

  INSERT INTO pgvigil.mssql_backup_state AS s (instance_id, database_name, snapshot_at, is_present, state, recovery_model, created_at,
      is_snapshot, is_read_only, is_standby, ag_group_id, ag_name, history_from,
      full_at, full_bytes, full_compressed_bytes, full_duration_s, full_device, full_device_name, full_copy_only, full_snapshot,
      diff_at, diff_bytes, diff_compressed_bytes, diff_duration_s, diff_device, diff_device_name,
      log_at, log_bytes, log_compressed_bytes, log_duration_s, log_device, log_device_name, log_copy_only, nul_at, nul_type)
  SELECT p_instance_id, d->>'database_name', p_snapshot_at, true, d->>'state', d->>'recovery_model', (d->>'created_utc')::timestamptz,
         (d->>'is_snapshot')::int = 1, (d->>'is_read_only')::int = 1, (d->>'is_standby')::int = 1, lower(d->>'ag_group_id'), d->>'ag_name', v_from,
         (f->>'finish_utc')::timestamptz, (f->>'size_bytes')::bigint, (f->>'compressed_bytes')::bigint, (f->>'duration_s')::bigint,
         f->>'device', f->>'device_name', (f->>'is_copy_only')::int = 1, (f->>'is_snapshot')::int = 1,
         (i->>'finish_utc')::timestamptz, (i->>'size_bytes')::bigint, (i->>'compressed_bytes')::bigint, (i->>'duration_s')::bigint,
         i->>'device', i->>'device_name',
         (l->>'finish_utc')::timestamptz, (l->>'size_bytes')::bigint, (l->>'compressed_bytes')::bigint, (l->>'duration_s')::bigint,
         l->>'device', l->>'device_name', (l->>'is_copy_only')::int = 1,
         (n->>'finish_utc')::timestamptz, n->>'backup_type'
    FROM (SELECT DISTINCT ON (r->>'database_name') r AS d FROM jsonb_array_elements(v_rows) r
           WHERE r->>'kind' = 'database' AND r->>'database_name' IS NOT NULL) dbs
    LEFT JOIN LATERAL (SELECT b FROM jsonb_array_elements(v_rows) b WHERE b->>'kind' = 'backup' AND b->>'database_name' = d->>'database_name'
                          AND b->>'backup_type' = 'full' AND b->>'sink' = 'backup'
                          AND (d->>'created_utc' IS NULL OR (b->>'finish_utc')::timestamptz >= (d->>'created_utc')::timestamptz - interval '1 hour') LIMIT 1) ff(f) ON true
    LEFT JOIN LATERAL (SELECT b FROM jsonb_array_elements(v_rows) b WHERE b->>'kind' = 'backup' AND b->>'database_name' = d->>'database_name'
                          AND b->>'backup_type' = 'diff' AND b->>'sink' = 'backup'
                          AND (d->>'created_utc' IS NULL OR (b->>'finish_utc')::timestamptz >= (d->>'created_utc')::timestamptz - interval '1 hour') LIMIT 1) fi(i) ON true
    LEFT JOIN LATERAL (SELECT b FROM jsonb_array_elements(v_rows) b WHERE b->>'kind' = 'backup' AND b->>'database_name' = d->>'database_name'
                          AND b->>'backup_type' = 'log' AND b->>'sink' = 'backup'
                          AND (d->>'created_utc' IS NULL OR (b->>'finish_utc')::timestamptz >= (d->>'created_utc')::timestamptz - interval '1 hour') LIMIT 1) fl(l) ON true
    LEFT JOIN LATERAL (SELECT b FROM jsonb_array_elements(v_rows) b WHERE b->>'kind' = 'backup' AND b->>'database_name' = d->>'database_name'
                          AND b->>'sink' = 'nul' ORDER BY (b->>'finish_utc')::timestamptz DESC LIMIT 1) fn(n) ON true
  ON CONFLICT (instance_id, database_name) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, is_present = true, state = EXCLUDED.state, recovery_model = EXCLUDED.recovery_model,
      is_snapshot = EXCLUDED.is_snapshot, is_read_only = EXCLUDED.is_read_only, is_standby = EXCLUDED.is_standby,
      ag_group_id = EXCLUDED.ag_group_id, ag_name = EXCLUDED.ag_name, history_from = EXCLUDED.history_from,
      created_at = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) THEN EXCLUDED.created_at ELSE s.created_at END,
      -- a database created anew under an old name starts without the old one's backups (msdb keys its history by
      -- name: a backup that finished before the database was created is the old one's and is not taken above);
      -- otherwise the newer of what msdb lists now and what the repository saw before is kept, type by type
      full_at = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.full_at, '-infinity') >= coalesce(s.full_at, '-infinity') THEN EXCLUDED.full_at ELSE s.full_at END,
      full_bytes = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.full_at, '-infinity') >= coalesce(s.full_at, '-infinity') THEN EXCLUDED.full_bytes ELSE s.full_bytes END,
      full_compressed_bytes = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.full_at, '-infinity') >= coalesce(s.full_at, '-infinity') THEN EXCLUDED.full_compressed_bytes ELSE s.full_compressed_bytes END,
      full_duration_s = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.full_at, '-infinity') >= coalesce(s.full_at, '-infinity') THEN EXCLUDED.full_duration_s ELSE s.full_duration_s END,
      full_device = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.full_at, '-infinity') >= coalesce(s.full_at, '-infinity') THEN EXCLUDED.full_device ELSE s.full_device END,
      full_device_name = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.full_at, '-infinity') >= coalesce(s.full_at, '-infinity') THEN EXCLUDED.full_device_name ELSE s.full_device_name END,
      full_copy_only = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.full_at, '-infinity') >= coalesce(s.full_at, '-infinity') THEN EXCLUDED.full_copy_only ELSE s.full_copy_only END,
      full_snapshot = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.full_at, '-infinity') >= coalesce(s.full_at, '-infinity') THEN EXCLUDED.full_snapshot ELSE s.full_snapshot END,
      diff_at = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.diff_at, '-infinity') >= coalesce(s.diff_at, '-infinity') THEN EXCLUDED.diff_at ELSE s.diff_at END,
      diff_bytes = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.diff_at, '-infinity') >= coalesce(s.diff_at, '-infinity') THEN EXCLUDED.diff_bytes ELSE s.diff_bytes END,
      diff_compressed_bytes = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.diff_at, '-infinity') >= coalesce(s.diff_at, '-infinity') THEN EXCLUDED.diff_compressed_bytes ELSE s.diff_compressed_bytes END,
      diff_duration_s = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.diff_at, '-infinity') >= coalesce(s.diff_at, '-infinity') THEN EXCLUDED.diff_duration_s ELSE s.diff_duration_s END,
      diff_device = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.diff_at, '-infinity') >= coalesce(s.diff_at, '-infinity') THEN EXCLUDED.diff_device ELSE s.diff_device END,
      diff_device_name = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.diff_at, '-infinity') >= coalesce(s.diff_at, '-infinity') THEN EXCLUDED.diff_device_name ELSE s.diff_device_name END,
      log_at = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.log_at, '-infinity') >= coalesce(s.log_at, '-infinity') THEN EXCLUDED.log_at ELSE s.log_at END,
      log_bytes = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.log_at, '-infinity') >= coalesce(s.log_at, '-infinity') THEN EXCLUDED.log_bytes ELSE s.log_bytes END,
      log_compressed_bytes = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.log_at, '-infinity') >= coalesce(s.log_at, '-infinity') THEN EXCLUDED.log_compressed_bytes ELSE s.log_compressed_bytes END,
      log_duration_s = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.log_at, '-infinity') >= coalesce(s.log_at, '-infinity') THEN EXCLUDED.log_duration_s ELSE s.log_duration_s END,
      log_device = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.log_at, '-infinity') >= coalesce(s.log_at, '-infinity') THEN EXCLUDED.log_device ELSE s.log_device END,
      log_device_name = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.log_at, '-infinity') >= coalesce(s.log_at, '-infinity') THEN EXCLUDED.log_device_name ELSE s.log_device_name END,
      log_copy_only = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.log_at, '-infinity') >= coalesce(s.log_at, '-infinity') THEN EXCLUDED.log_copy_only ELSE s.log_copy_only END,
      nul_at = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.nul_at, '-infinity') >= coalesce(s.nul_at, '-infinity') THEN EXCLUDED.nul_at ELSE s.nul_at END,
      nul_type = CASE WHEN pgvigil.mssql_recreated(s.created_at, EXCLUDED.created_at) OR coalesce(EXCLUDED.nul_at, '-infinity') >= coalesce(s.nul_at, '-infinity') THEN EXCLUDED.nul_type ELSE s.nul_type END;

  UPDATE pgvigil.mssql_backup_state s SET is_present = false
   WHERE s.instance_id = p_instance_id AND s.is_present AND s.snapshot_at < p_snapshot_at;
END $$;

-- mssql_backup_judged: see the header. A database in an availability group takes the newest backup of each type any
-- monitored replica's msdb holds; replicas_monitored < replicas_total says a replica's msdb is not read, so a
-- missing backup may only be unseen. A replica's ROLE decides nothing here: the backup is judged wherever it ran.
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

-- ---------------------------------------------------------------------------------------------------------------
-- findings

CREATE OR REPLACE VIEW pgvigil.mssql_hadr_findings AS
WITH rep AS (
  SELECT a.* FROM pgvigil.mssql_ag_state a WHERE a.snapshot_at > now() - interval '5 minutes'
), dbs AS (
  SELECT d.*, r.availability_mode
    FROM pgvigil.mssql_ag_database_state d
    LEFT JOIN pgvigil.mssql_ag_state r ON r.instance_id = d.instance_id AND r.group_id = d.group_id AND r.replica_server = d.replica_server
   WHERE d.snapshot_at > now() - interval '5 minutes'
), q5 AS (
  SELECT s.instance_id, s.group_name, s.replica_server, s.database_name,
         min(coalesce(s.log_send_queue_kb, 0)) AS min_send, max(s.log_send_queue_kb) AS max_send,
         min(coalesce(s.redo_queue_kb, 0)) AS min_redo, max(s.redo_queue_kb) AS max_redo, max(s.snapshot_at) AS last_at
    FROM pgvigil.mssql_ag_sample s
   WHERE s.snapshot_at > now() - interval '5 minutes 30 seconds'
   GROUP BY 1, 2, 3, 4
  HAVING min(s.snapshot_at) <= now() - interval '4 minutes' AND max(s.snapshot_at) > now() - interval '2 minutes'
)
SELECT r.instance_id, 'critical'::text AS severity, 'a replica is not connected'::text AS check_name,
       r.group_name || ' / ' || r.replica_server AS object, r.snapshot_at AS at,
       format('replica %s of the availability group %s is %s%s. Its databases receive nothing until it connects again.',
              r.replica_server, r.group_name, lower(r.connected_state),
              coalesce(' (last connect error ' || r.last_connect_error || ': ' || r.last_connect_error_text || ')', '')) AS detail
  FROM rep r WHERE r.connected_state IS NOT NULL AND r.connected_state <> 'CONNECTED'
UNION ALL
SELECT r.instance_id, 'critical', 'a replica is not healthy', r.group_name || ' / ' || r.replica_server, r.snapshot_at,
       format('replica %s of the availability group %s: synchronization health %s, role %s, operational state %s.',
              r.replica_server, r.group_name, lower(replace(r.synchronization_health, '_', ' ')), coalesce(lower(r.role), 'unknown'),
              coalesce(lower(replace(r.operational_state, '_', ' ')), 'unknown'))
  FROM rep r WHERE r.synchronization_health IS NOT NULL AND r.synchronization_health <> 'HEALTHY'
               AND (r.connected_state IS NULL OR r.connected_state = 'CONNECTED')     -- a disconnected replica has its own finding
UNION ALL
SELECT d.instance_id, 'critical', 'a database is suspended', d.group_name || ' / ' || d.replica_server || ' / ' || d.database_name, d.snapshot_at,
       format('database %s on replica %s (group %s): data movement is suspended%s. The log of the primary grows until it is resumed (ALTER DATABASE ... SET HADR RESUME).',
              d.database_name, d.replica_server, d.group_name, coalesce(', reason ' || lower(replace(d.suspend_reason, '_', ' ')), ''))
  FROM dbs d WHERE d.is_suspended
UNION ALL
SELECT d.instance_id, 'critical', 'a database is not synchronizing', d.group_name || ' / ' || d.replica_server || ' / ' || d.database_name, d.snapshot_at,
       format('database %s on replica %s (group %s) is %s (database state %s).',
              d.database_name, d.replica_server, d.group_name, lower(replace(d.synchronization_state, '_', ' ')),
              coalesce(lower(replace(d.database_state, '_', ' ')), 'unknown'))
  FROM dbs d WHERE NOT coalesce(d.is_suspended, false) AND d.synchronization_state IS NOT NULL
               AND d.synchronization_state NOT IN ('SYNCHRONIZED', 'SYNCHRONIZING')
UNION ALL
SELECT d.instance_id, 'warning', 'a synchronous replica is not synchronized', d.group_name || ' / ' || d.replica_server || ' / ' || d.database_name, d.snapshot_at,
       format('database %s on the synchronous-commit replica %s (group %s) is synchronizing, not synchronized: a failover to it now would lose data.',
              d.database_name, d.replica_server, d.group_name)
  FROM dbs d WHERE NOT coalesce(d.is_suspended, false) AND d.availability_mode = 'SYNCHRONOUS_COMMIT' AND d.synchronization_state = 'SYNCHRONIZING'
UNION ALL
SELECT q.instance_id, 'warning', 'the log send queue is over its threshold', q.group_name || ' / ' || q.replica_server || ' / ' || q.database_name, q.last_at,
       format('database %s to replica %s (group %s): between %s and %s of log waited to be sent in every read of the last 5 minutes (threshold %s). That log is what a failover to this replica would lose.',
              q.database_name, q.replica_server, q.group_name, pg_size_pretty(q.min_send * 1024), pg_size_pretty(q.max_send * 1024),
              pg_size_pretty((l.log_send_queue_kb * 1024)::bigint))
  FROM q5 q JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = q.instance_id
 WHERE l.log_send_queue_kb > 0 AND q.min_send > l.log_send_queue_kb
UNION ALL
SELECT q.instance_id, 'warning', 'the redo queue is over its threshold', q.group_name || ' / ' || q.replica_server || ' / ' || q.database_name, q.last_at,
       format('database %s on replica %s (group %s): between %s and %s of log waited to be redone in every read of the last 5 minutes (threshold %s). A failover to this replica waits for that redo.',
              q.database_name, q.replica_server, q.group_name, pg_size_pretty(q.min_redo * 1024), pg_size_pretty(q.max_redo * 1024),
              pg_size_pretty((l.redo_queue_kb * 1024)::bigint))
  FROM q5 q JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = q.instance_id
 WHERE l.redo_queue_kb > 0 AND q.min_redo > l.redo_queue_kb
UNION ALL
SELECT f.instance_id, 'critical', 'the primary of a group changed', f.group_name, f.at,
       format('availability group %s: the primary moved from %s to %s in the minute before %s (a failover). Shown for an hour.',
              f.group_name, f.old_primary, f.new_primary, to_char(f.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
  FROM pgvigil.mssql_ag_failovers f WHERE f.at > now() - interval '1 hour'
UNION ALL
SELECT r.instance_id, 'info', 'a collection stores nothing where rows are expected', 'mssql_ag', r.snapshot_at,
       format('Always On is enabled on this server and mssql_ag has read no availability group in its last %s reads: no group exists yet, or the login does not see it.', r.empty_reads)
  FROM pgvigil.mssql_hadr_reads r WHERE r.collection = 'mssql_ag' AND r.empty_reads >= 60 AND r.snapshot_at > now() - interval '5 minutes'
UNION ALL
SELECT m.instance_id, 'critical', 'mirroring is disconnected or suspended', m.database_name, m.snapshot_at,
       format('database %s (%s, partner %s) is %s%s.', m.database_name, coalesce(lower(m.role), 'role unknown'), coalesce(m.partner_instance, m.partner, '?'),
              lower(m.state), coalesce('; witness ' || m.witness || ' ' || lower(m.witness_state), ''))
  FROM pgvigil.mssql_mirroring_state m
 WHERE m.snapshot_at > now() - interval '5 minutes' AND m.state IN ('DISCONNECTED', 'SUSPENDED')
UNION ALL
SELECT s.instance_id, 'warning', 'log shipping is behind its threshold',
       s.role || ' / ' || s.database_name || CASE WHEN s.secondary_server <> '' THEN ' on ' || s.secondary_server ELSE '' END, s.snapshot_at,
       CASE s.role WHEN 'primary' THEN
         format('primary database %s: the last log backup is from %s, %s minutes before the read; its threshold is %s minutes.', s.database_name,
                coalesce(to_char(s.last_backup_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'never'),
                coalesce(round(extract(epoch FROM s.snapshot_at - s.last_backup_at) / 60)::text, '?'), s.threshold_minutes)
       ELSE
         format('secondary database %s (from %s.%s): the last restore is from %s, %s minutes before the read; its threshold is %s minutes. The last file copied: %s.', s.database_name,
                coalesce(s.primary_server, '?'), coalesce(s.primary_database, '?'),
                coalesce(to_char(s.last_restored_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'never'),
                coalesce(round(extract(epoch FROM s.snapshot_at - s.last_restored_at) / 60)::text, '?'), s.threshold_minutes,
                coalesce(to_char(s.last_copied_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'never'))
       END
  FROM pgvigil.mssql_logshipping_state s
 WHERE s.snapshot_at > now() - interval '15 minutes' AND s.threshold_minutes > 0
   AND coalesce(s.snapshot_at - CASE s.role WHEN 'primary' THEN s.last_backup_at ELSE s.last_restored_at END, interval '1000 years')
       > make_interval(mins => s.threshold_minutes)
UNION ALL
SELECT p.instance_id, 'warning', 'a replication agent failed',
       p.agent_type || ' / ' || coalesce(p.agent_name, '?'), p.snapshot_at,
       format('the %s agent %s (publisher %s, database %s%s) failed at %s: %s', p.agent_type, coalesce(p.agent_name, '?'), coalesce(p.publisher, '?'),
              coalesce(p.publisher_db, '?'), coalesce(', subscriber ' || p.subscriber || '.' || p.subscriber_db, ''),
              coalesce(to_char(p.last_run_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), '?'), coalesce(p.status_text, 'no message'))
  FROM pgvigil.mssql_replication_state p
 WHERE p.snapshot_at > now() - interval '15 minutes' AND p.kind IN ('subscription', 'agent') AND p.runstatus = 6
UNION ALL
SELECT p.instance_id, 'warning', 'undistributed commands over the threshold',
       coalesce(p.publication, '?') || ' -> ' || coalesce(p.subscriber, '?') || '.' || coalesce(p.subscriber_db, '?'), p.snapshot_at,
       format('subscription of %s.%s (publication %s) at %s.%s: %s commands wait in the distribution database (threshold %s)%s.',
              coalesce(p.publisher, '?'), coalesce(p.publisher_db, '?'), coalesce(p.publication, '?'), coalesce(p.subscriber, '?'), coalesce(p.subscriber_db, '?'),
              p.undistributed, l.repl_undistributed_commands,
              coalesce(', about ' || round(p.est_catchup_s::numeric) || ' s at the agent''s last delivery rate', ''))
  FROM pgvigil.mssql_replication_state p JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = p.instance_id
 WHERE p.snapshot_at > now() - interval '15 minutes' AND p.kind = 'subscription'
   AND l.repl_undistributed_commands > 0 AND p.undistributed > l.repl_undistributed_commands;

CREATE OR REPLACE VIEW pgvigil.mssql_jobs_findings AS
WITH failed AS (
  SELECT DISTINCT ON (r.instance_id, r.job_id) r.instance_id, r.job_id, r.job_name, r.snapshot_at, r.duration_s, r.message, r.history_id
    FROM pgvigil.mssql_job_runs r
    JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = r.instance_id
   WHERE r.step_id = 0 AND r.run_status = 0 AND l.job_failed_hours > 0
     AND r.snapshot_at > now() - interval '31 days'       -- lets the planner prune partitions; the threshold below decides
     AND r.snapshot_at > now() - make_interval(secs => (l.job_failed_hours * 3600)::float8)
   ORDER BY r.instance_id, r.job_id, r.snapshot_at DESC, r.history_id DESC
), bk AS (
  SELECT b.* FROM pgvigil.mssql_backup_judged b WHERE b.snapshot_at > now() - interval '130 minutes'
)
SELECT f.instance_id, 'warning'::text AS severity, 'a job failed'::text AS check_name, coalesce(j.name, f.job_name, f.job_id) AS object, f.snapshot_at AS at,
       format('job %s failed at %s%s%s%s',
              coalesce(j.name, f.job_name, f.job_id), to_char(f.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
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
