-- 0143_hadr_mssql: SQL Server HA depth (tasks 381, 382, 384, 387): database mirroring's history and DBA Dash's
-- states, the availability group gaps, log shipping from restore history, the failover cluster instance.
--
--   1. Threshold keys (pg_thresholds: root, tag, instance, and database for log shipping):
--        ag_data_loss             minutes  warning 1 (sp_Blitz 20260708 check 268: a secondary 60 s behind the
--                                          primary's last commit), critical 5 (pgvigil's own default)
--        logship_restore_age      minutes  1440 / 2880 (DBA Dash 4.24.1 LogShippingStatus: time since the last
--                                          log restore)
--        logship_restore_latency  minutes  1440 / 2880 (DBA Dash: the last restore's latency, the log backup's start
--                                          to its restore)
--        restoring_days           days     warning 2 (sp_Blitz check 111: restoring with no restore in two days)
--      The queue thresholds of mirroring are the availability groups' own (mssql_hadr_limits: log_send_queue_kb,
--      redo_queue_kb), so one setting judges both features; a new database is exempt from the log shipping tiers
--      for new_database_hours (24 = DBA Dash's 1440 minutes).
--   2. Availability groups: per replica the join state, the read-only routing URL and list and the endpoint; the
--      group's failure condition level and health check timeout; the AlwaysOn_health session's state; per database
--      and replica whether it joined and is ready for a failover (mssql_ag_database_cluster); automatic seeding
--      (mssql_ag_seeding); the data loss's basis (commit, or the hardened time sp_Blitz falls back to); per read the
--      flow control and resent messages per replica (mssql_ag_replica_sample) and the flow control and blocked redo
--      per local database (mssql_ag_dbcounter_sample), as rates over two reads of the cumulative counters.
--   3. Mirroring: the state code, the role sequence, the database state, the endpoint; mssql_mirroring_sample (per
--      read: the queues, the cumulative counters and the send rate, redo rate and transaction delay they give over
--      two reads); mssql_mirroring_role_changes (a role swap, seen by the role or by the role sequence).
--   4. Log shipping from restore history: mssql_logrestore_state (current) and mssql_logrestore_sample.
--   5. The failover cluster instance: mssql_fci_nodes (current), mssql_fci_owner_changes (a node change).
--   6. mssql_hadr_findings again (0066's view; its replication arms move to pgvigil.mssql_repl_findings, which
--      0142 (replication depth) owns: this file creates that view only where it does not exist yet, as 0066's two
--      arms). Every availability group and mirroring arm leaves out an Amazon RDS instance (platform rdssqlserver):
--      RDS runs Multi-AZ on its own mirroring or availability group, which the user cannot act on; the rows are read
--      and shown, never judged.
-- The purge lines (the partition parents mssql_mirroring_sample and mssql_logrestore_sample; the role change, owner
-- change and seeding rows past the window) are the join's.

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Threshold keys. pg_threshold_keys.engines (the engines whose instances take a key at the instance and database
-- level) is 0142's (replication depth), which also teaches import_pg_threshold to read it; the line below is 0142's
-- own, so a tree without 0142 has the column too (it is a no-op after 0142).
ALTER TABLE pgvigil.pg_threshold_keys ADD COLUMN IF NOT EXISTS engines text[] NOT NULL DEFAULT '{postgres}';
INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value, engines) VALUES
  ('ag_data_loss',            'Availability groups: a secondary''s estimated data loss',                    'minutes', 'over', 1,    5,    '{root,tag,instance}', 1440, '{sqlserver}'),
  ('logship_restore_age',     'Log shipping: time since the last log restore',                             'minutes', 'over', 1440, 2880, '{root,tag,instance,database}', 525600, '{sqlserver}'),
  ('logship_restore_latency', 'Log shipping: the last log restore''s latency (backup start to restore)',     'minutes', 'over', 1440, 2880, '{root,tag,instance,database}', 525600, '{sqlserver}'),
  ('restoring_days',          'Restoring: a database restoring with no restore applied',                    'days',    'over', 2,    NULL, '{root,tag,instance,database}', 3650, '{sqlserver}')
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value,
  engines = EXCLUDED.engines;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Availability groups
-- mssql_counter_delta: a rate per second from two reads of a cumulative counter (cntr_type 272696576); NULL when the
-- counter is not cumulative, either read is missing, it went back (a restart cleared it) or the reads are not 1 s
-- to 15 minutes apart
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_delta(p_now bigint, p_before bigint, p_type int, p_seconds float8)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_type = 272696576 AND p_now IS NOT NULL AND p_before IS NOT NULL AND p_now >= p_before
               AND p_seconds BETWEEN 1 AND 900 THEN round(((p_now - p_before) / p_seconds)::numeric, 3) END
$$;

ALTER TABLE pgvigil.mssql_ag_state ADD COLUMN IF NOT EXISTS read_only_routing_url text;
ALTER TABLE pgvigil.mssql_ag_state ADD COLUMN IF NOT EXISTS join_state text;          -- NOT_JOINED | JOINED_STANDALONE_INSTANCE | JOINED_FCI
ALTER TABLE pgvigil.mssql_ag_state ADD COLUMN IF NOT EXISTS routing_list jsonb;       -- [{priority, replica}] in order
ALTER TABLE pgvigil.mssql_ag_state ADD COLUMN IF NOT EXISTS endpoint jsonb;           -- the instance's endpoint, the same on each row
ALTER TABLE pgvigil.mssql_ag_state ADD COLUMN IF NOT EXISTS failure_condition_level int;
ALTER TABLE pgvigil.mssql_ag_state ADD COLUMN IF NOT EXISTS health_check_timeout_ms int;
ALTER TABLE pgvigil.mssql_ag_state ADD COLUMN IF NOT EXISTS health_session jsonb;     -- AlwaysOn_health: exists, running, autostart
ALTER TABLE pgvigil.mssql_ag_database_state ADD COLUMN IF NOT EXISTS data_loss_basis text;   -- commit | hardened

CREATE TABLE IF NOT EXISTS pgvigil.mssql_ag_database_cluster (
  instance_id                   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  group_id                      text NOT NULL,
  replica_server                text NOT NULL,
  database_name                 text NOT NULL,
  snapshot_at                   timestamptz NOT NULL,
  group_name                    text NOT NULL,
  is_failover_ready             boolean,
  is_database_joined            boolean,
  is_pending_secondary_suspend  boolean,
  PRIMARY KEY (instance_id, group_id, replica_server, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_ag_replica_sample (
  instance_id              int NOT NULL,
  snapshot_at              timestamptz NOT NULL,
  replica_server           text NOT NULL,     -- the replica this server talks to (the counter's instance)
  flow_control_ms_total    bigint,            -- cumulative counters as read (NULL where the type is not cumulative)
  flow_controls_total      bigint,
  resent_messages_total    bigint,
  flow_control_ms_per_s    numeric,           -- from this read and the one before it
  flow_controls_per_s      numeric,
  resent_messages_per_s    numeric
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_ag_replica_sample_at_idx ON pgvigil.mssql_ag_replica_sample (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_ag_replica_sample_key_idx ON pgvigil.mssql_ag_replica_sample (instance_id, replica_server, snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_ag_dbcounter_sample (
  instance_id                  int NOT NULL,
  snapshot_at                  timestamptz NOT NULL,
  database_name                text NOT NULL,  -- a database of this server in a group (the counter's instance)
  db_flow_control_delay_total  bigint,
  db_flow_controls_total       bigint,
  redo_blocked_total           bigint,
  db_flow_control_ms_per_s     numeric,
  db_flow_controls_per_s       numeric,
  redo_blocked_per_s           numeric
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_ag_dbcounter_sample_at_idx ON pgvigil.mssql_ag_dbcounter_sample (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_ag_dbcounter_sample_key_idx ON pgvigil.mssql_ag_dbcounter_sample (instance_id, database_name, snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_ag_seeding (
  instance_id           int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  group_id              text NOT NULL,
  database_name         text NOT NULL,
  remote_replica        text NOT NULL DEFAULT '',
  snapshot_at           timestamptz NOT NULL,
  group_name            text NOT NULL,
  is_source             boolean,
  seeding_state         text,        -- COMPLETED | FAILED | SEEDING | ... as sys.dm_hadr_automatic_seeding names it
  failure_state         text,
  error_code            int,
  attempts              int,
  started_at            timestamptz,
  completed_at          timestamptz,
  transferred_bytes     bigint,
  database_bytes        bigint,
  estimate_complete_at  timestamptz,
  PRIMARY KEY (instance_id, group_id, database_name, remote_replica)
);

-- mssql_ag_loss_hardened: sp_Blitz check 268's fallback for a secondary that has redone no commit yet (its
-- last_commit_utc NULL, so the collector gave no estimate): the primary's last commit (its own row of the same
-- database and group in the same read: only a primary's read has it) less the secondary's last hardened time, in
-- seconds, 0 when it is ahead; NULL otherwise. A distributed group's link is left to the collector's estimate.
CREATE OR REPLACE FUNCTION pgvigil.mssql_ag_loss_hardened(p_row jsonb, p_rows jsonb)
RETURNS bigint LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_row->>'est_data_loss_s' IS NOT NULL OR (p_row->>'is_primary_replica')::int = 1
               OR p_row->>'last_commit_utc' IS NOT NULL OR p_row->>'last_hardened_utc' IS NULL THEN NULL
              ELSE (SELECT greatest(0, floor(extract(epoch FROM (x->>'last_commit_utc')::timestamptz - (p_row->>'last_hardened_utc')::timestamptz)))::bigint
                      FROM jsonb_array_elements(p_rows) x
                     WHERE x->>'kind' = 'database' AND x->>'group_id' = p_row->>'group_id' AND x->>'database_name' = p_row->>'database_name'
                       AND (x->>'is_primary_replica')::int = 1 AND x->>'last_commit_utc' IS NOT NULL
                     LIMIT 1) END
$$;

-- payload: 0066's kinds, and 'db_cluster', 'routing', 'seeding', 'endpoint', 'replica_counters', 'db_counters' and
-- 'health_session' rows; 'collector_error' rows are notes
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_ag(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := pgvigil.mssql_rows(p_payload);
  v_newest boolean;
  v_cluster jsonb;
  v_known jsonb;
  v_endpoint jsonb;
  v_health jsonb;
BEGIN
  v_newest := pgvigil.mssql_hadr_read(p_instance_id, 'mssql_ag', p_snapshot_at,
                (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'replica'));

  PERFORM pgvigil.ensure_month_partition('mssql_ag_sample', p_snapshot_at);
  DELETE FROM pgvigil.mssql_ag_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;   -- a re-run of one read
  INSERT INTO pgvigil.mssql_ag_sample (instance_id, snapshot_at, group_name, replica_server, database_name, synchronization_state,
      is_suspended, log_send_queue_kb, log_send_rate_kb_s, redo_queue_kb, redo_rate_kb_s, est_data_loss_s, est_recovery_s)
  SELECT p_instance_id, p_snapshot_at, r->>'group_name', r->>'replica_server', r->>'database_name', r->>'synchronization_state',
         (r->>'is_suspended')::int = 1, (r->>'log_send_queue_kb')::bigint, (r->>'log_send_rate_kb_s')::bigint,
         (r->>'redo_queue_kb')::bigint, (r->>'redo_rate_kb_s')::bigint,
         coalesce((r->>'est_data_loss_s')::bigint, pgvigil.mssql_ag_loss_hardened(r, v_rows)), (r->>'est_recovery_s')::float8
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'database' AND r->>'group_name' IS NOT NULL AND r->>'replica_server' IS NOT NULL AND r->>'database_name' IS NOT NULL;

  PERFORM pgvigil.ensure_month_partition('mssql_ag_replica_sample', p_snapshot_at);
  DELETE FROM pgvigil.mssql_ag_replica_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_ag_replica_sample (instance_id, snapshot_at, replica_server, flow_control_ms_total, flow_controls_total,
      resent_messages_total, flow_control_ms_per_s, flow_controls_per_s, resent_messages_per_s)
  SELECT DISTINCT ON (r->>'counter_instance') p_instance_id, p_snapshot_at, r->>'counter_instance',
         CASE WHEN (r->>'flow_control_type')::int = 272696576 THEN (r->>'flow_control_ms_total')::bigint END,
         CASE WHEN (r->>'flow_controls_type')::int = 272696576 THEN (r->>'flow_controls_total')::bigint END,
         CASE WHEN (r->>'third_type')::int = 272696576 THEN (r->>'resent_messages_total')::bigint END,
         pgvigil.mssql_counter_delta((r->>'flow_control_ms_total')::bigint, p.flow_control_ms_total, (r->>'flow_control_type')::int, extract(epoch FROM p_snapshot_at - p.snapshot_at)),
         pgvigil.mssql_counter_delta((r->>'flow_controls_total')::bigint, p.flow_controls_total, (r->>'flow_controls_type')::int, extract(epoch FROM p_snapshot_at - p.snapshot_at)),
         pgvigil.mssql_counter_delta((r->>'resent_messages_total')::bigint, p.resent_messages_total, (r->>'third_type')::int, extract(epoch FROM p_snapshot_at - p.snapshot_at))
    FROM jsonb_array_elements(v_rows) r
    LEFT JOIN LATERAL (SELECT s.* FROM pgvigil.mssql_ag_replica_sample s
                        WHERE s.instance_id = p_instance_id AND s.replica_server = r->>'counter_instance'
                          AND s.snapshot_at < p_snapshot_at AND s.snapshot_at > p_snapshot_at - interval '15 minutes'
                        ORDER BY s.snapshot_at DESC LIMIT 1) p ON true
   WHERE r->>'kind' = 'replica_counters' AND r->>'counter_instance' IS NOT NULL;

  PERFORM pgvigil.ensure_month_partition('mssql_ag_dbcounter_sample', p_snapshot_at);
  DELETE FROM pgvigil.mssql_ag_dbcounter_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_ag_dbcounter_sample (instance_id, snapshot_at, database_name, db_flow_control_delay_total, db_flow_controls_total,
      redo_blocked_total, db_flow_control_ms_per_s, db_flow_controls_per_s, redo_blocked_per_s)
  SELECT DISTINCT ON (r->>'counter_instance') p_instance_id, p_snapshot_at, r->>'counter_instance',
         CASE WHEN (r->>'flow_control_type')::int = 272696576 THEN (r->>'db_flow_control_delay_total')::bigint END,
         CASE WHEN (r->>'flow_controls_type')::int = 272696576 THEN (r->>'db_flow_controls_total')::bigint END,
         CASE WHEN (r->>'third_type')::int = 272696576 THEN (r->>'redo_blocked_total')::bigint END,
         pgvigil.mssql_counter_delta((r->>'db_flow_control_delay_total')::bigint, p.db_flow_control_delay_total, (r->>'flow_control_type')::int, extract(epoch FROM p_snapshot_at - p.snapshot_at)),
         pgvigil.mssql_counter_delta((r->>'db_flow_controls_total')::bigint, p.db_flow_controls_total, (r->>'flow_controls_type')::int, extract(epoch FROM p_snapshot_at - p.snapshot_at)),
         pgvigil.mssql_counter_delta((r->>'redo_blocked_total')::bigint, p.redo_blocked_total, (r->>'third_type')::int, extract(epoch FROM p_snapshot_at - p.snapshot_at))
    FROM jsonb_array_elements(v_rows) r
    LEFT JOIN LATERAL (SELECT s.* FROM pgvigil.mssql_ag_dbcounter_sample s
                        WHERE s.instance_id = p_instance_id AND s.database_name = r->>'counter_instance'
                          AND s.snapshot_at < p_snapshot_at AND s.snapshot_at > p_snapshot_at - interval '15 minutes'
                        ORDER BY s.snapshot_at DESC LIMIT 1) p ON true
   WHERE r->>'kind' = 'db_counters' AND r->>'counter_instance' IS NOT NULL;

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
  SELECT r - 'kind' INTO v_endpoint FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'endpoint' ORDER BY r->>'endpoint_name' LIMIT 1;
  SELECT jsonb_build_object('exists', (r->>'session_exists')::int = 1, 'running', (r->>'session_running')::int = 1,
                            'autostart', (r->>'session_autostart')::int = 1)
    INTO v_health FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'health_session' LIMIT 1;

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
      last_connect_error, last_connect_error_text, last_connect_error_at, read_only_routing_url, join_state, routing_list, endpoint,
      failure_condition_level, health_check_timeout_ms, health_session)
  SELECT DISTINCT ON (r->>'group_id', r->>'replica_server')
         p_instance_id, r->>'group_id', r->>'replica_server', p_snapshot_at, r->>'group_name', r->>'cluster_type',
         (r->>'is_distributed')::int = 1, (r->>'is_contained')::int = 1, r->>'backup_preference', (r->>'db_failover')::int = 1,
         (r->>'required_sync_secondaries')::int, coalesce(nullif(r->>'primary_replica', ''), v_known->>(r->>'group_id')), r->>'group_health',
         (SELECT jsonb_agg(l - 'kind' - 'group_id' ORDER BY l->>'dns_name') FROM jsonb_array_elements(v_rows) l
           WHERE l->>'kind' = 'listener' AND l->>'group_id' = r->>'group_id'),
         v_cluster, r->>'replica_id', r->>'endpoint_url', r->>'availability_mode', r->>'failover_mode', r->>'seeding_mode',
         r->>'secondary_connections', (r->>'backup_priority')::int, (r->>'session_timeout')::int, (r->>'is_local')::int = 1,
         r->>'role', r->>'operational_state', r->>'connected_state', r->>'recovery_health', r->>'synchronization_health',
         (r->>'last_connect_error')::int, r->>'last_connect_error_text', (r->>'last_connect_error_utc')::timestamptz,
         r->>'read_only_routing_url', r->>'join_state',
         (SELECT jsonb_agg(jsonb_build_object('priority', (x->>'routing_priority')::int, 'replica', x->>'read_only_replica')
                           ORDER BY (x->>'routing_priority')::int, x->>'read_only_replica')
            FROM jsonb_array_elements(v_rows) x
           WHERE x->>'kind' = 'routing' AND x->>'group_id' = r->>'group_id' AND x->>'replica_server' = r->>'replica_server'),
         v_endpoint, (r->>'failure_condition_level')::int, (r->>'health_check_timeout_ms')::int, v_health
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'replica' AND r->>'group_id' IS NOT NULL AND r->>'replica_server' IS NOT NULL AND r->>'group_name' IS NOT NULL;

  DELETE FROM pgvigil.mssql_ag_database_state WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_ag_database_state (instance_id, group_id, replica_server, database_name, snapshot_at, group_name, is_local,
      is_primary_replica, synchronization_state, synchronization_health, database_state, is_suspended, suspend_reason,
      log_send_queue_kb, log_send_rate_kb_s, redo_queue_kb, redo_rate_kb_s, est_data_loss_s, est_recovery_s, secondary_lag_s,
      last_sent_at, last_received_at, last_hardened_at, last_redone_at, last_commit_at, data_loss_basis)
  SELECT DISTINCT ON (r->>'group_id', r->>'replica_server', r->>'database_name')
         p_instance_id, r->>'group_id', r->>'replica_server', r->>'database_name', p_snapshot_at, r->>'group_name',
         (r->>'is_local')::int = 1, (r->>'is_primary_replica')::int = 1, r->>'synchronization_state', r->>'synchronization_health',
         r->>'database_state', (r->>'is_suspended')::int = 1, r->>'suspend_reason', (r->>'log_send_queue_kb')::bigint,
         (r->>'log_send_rate_kb_s')::bigint, (r->>'redo_queue_kb')::bigint, (r->>'redo_rate_kb_s')::bigint,
         coalesce((r->>'est_data_loss_s')::bigint, pgvigil.mssql_ag_loss_hardened(r, v_rows)), (r->>'est_recovery_s')::float8,
         (r->>'secondary_lag_s')::bigint,
         (r->>'last_sent_utc')::timestamptz, (r->>'last_received_utc')::timestamptz, (r->>'last_hardened_utc')::timestamptz,
         (r->>'last_redone_utc')::timestamptz, (r->>'last_commit_utc')::timestamptz,
         CASE WHEN r->>'est_data_loss_s' IS NOT NULL THEN 'commit' WHEN pgvigil.mssql_ag_loss_hardened(r, v_rows) IS NOT NULL THEN 'hardened' END
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'database' AND r->>'group_id' IS NOT NULL AND r->>'replica_server' IS NOT NULL
     AND r->>'database_name' IS NOT NULL AND r->>'group_name' IS NOT NULL;

  DELETE FROM pgvigil.mssql_ag_database_cluster WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_ag_database_cluster (instance_id, group_id, replica_server, database_name, snapshot_at, group_name,
      is_failover_ready, is_database_joined, is_pending_secondary_suspend)
  SELECT DISTINCT ON (r->>'group_id', r->>'replica_server', r->>'database_name')
         p_instance_id, r->>'group_id', r->>'replica_server', r->>'database_name', p_snapshot_at, r->>'group_name',
         (r->>'is_failover_ready')::int = 1, (r->>'is_database_joined')::int = 1, (r->>'is_pending_secondary_suspend')::int = 1
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'db_cluster' AND r->>'group_id' IS NOT NULL AND r->>'replica_server' IS NOT NULL
     AND r->>'database_name' IS NOT NULL AND r->>'group_name' IS NOT NULL;

  DELETE FROM pgvigil.mssql_ag_seeding WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_ag_seeding (instance_id, group_id, database_name, remote_replica, snapshot_at, group_name, is_source,
      seeding_state, failure_state, error_code, attempts, started_at, completed_at, transferred_bytes, database_bytes, estimate_complete_at)
  SELECT DISTINCT ON (r->>'group_id', r->>'database_name', coalesce(r->>'remote_replica', ''))
         p_instance_id, r->>'group_id', r->>'database_name', coalesce(r->>'remote_replica', ''), p_snapshot_at, r->>'group_name',
         (r->>'is_source')::int = 1, r->>'seeding_state', r->>'failure_state', (r->>'error_code')::int, (r->>'number_of_attempts')::int,
         (r->>'start_utc')::timestamptz, (r->>'completion_utc')::timestamptz, (r->>'transferred_size_bytes')::bigint,
         (r->>'database_size_bytes')::bigint, (r->>'estimate_complete_utc')::timestamptz
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'seeding' AND r->>'group_id' IS NOT NULL AND r->>'database_name' IS NOT NULL AND r->>'group_name' IS NOT NULL
   ORDER BY r->>'group_id', r->>'database_name', coalesce(r->>'remote_replica', ''), (r->>'start_utc')::timestamptz DESC NULLS LAST;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. Mirroring
ALTER TABLE pgvigil.mssql_mirroring_state ADD COLUMN IF NOT EXISTS state_code int;          -- sys.database_mirroring.mirroring_state: 5 = UNSYNCHRONIZED
ALTER TABLE pgvigil.mssql_mirroring_state ADD COLUMN IF NOT EXISTS role_sequence int;       -- the role swaps of the session so far
ALTER TABLE pgvigil.mssql_mirroring_state ADD COLUMN IF NOT EXISTS database_state text;
ALTER TABLE pgvigil.mssql_mirroring_state ADD COLUMN IF NOT EXISTS send_rate_kb_s numeric;  -- over the last two reads
ALTER TABLE pgvigil.mssql_mirroring_state ADD COLUMN IF NOT EXISTS redo_rate_kb_s numeric;
ALTER TABLE pgvigil.mssql_mirroring_state ADD COLUMN IF NOT EXISTS txn_delay_ms numeric;    -- per mirrored write transaction
ALTER TABLE pgvigil.mssql_mirroring_state ADD COLUMN IF NOT EXISTS endpoint jsonb;          -- the instance's endpoint, the same on each row

CREATE TABLE IF NOT EXISTS pgvigil.mssql_mirroring_sample (
  instance_id                int NOT NULL,
  snapshot_at                timestamptz NOT NULL,
  database_name              text NOT NULL,
  role                       text,
  state                      text,
  witness_state              text,
  log_send_queue_kb          bigint,
  redo_queue_kb              bigint,
  log_bytes_sent_total       bigint,      -- the cumulative counters as read (NULL where the type is not cumulative)
  redo_bytes_total           bigint,
  txn_delay_ms_total         bigint,
  mirrored_write_txns_total  bigint,
  send_rate_kb_s             numeric,     -- from this read and the one before it on the same instance, role and database
  redo_rate_kb_s             numeric,
  txn_delay_ms               numeric
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_mirroring_sample_at_idx ON pgvigil.mssql_mirroring_sample (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_mirroring_sample_db_idx ON pgvigil.mssql_mirroring_sample (instance_id, database_name, snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_mirroring_role_changes (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  at             timestamptz NOT NULL,   -- the read that first saw the new role or sequence: the swap was in the minute before
  old_role       text,
  new_role       text,
  old_sequence   int,
  new_sequence   int,
  partner        text,                   -- the partner instance as this side names it after the swap
  state_after    text,
  witness_after  text,
  PRIMARY KEY (instance_id, database_name, at)
);
CREATE INDEX IF NOT EXISTS mssql_mirroring_role_changes_at_idx ON pgvigil.mssql_mirroring_role_changes (at);


-- payload: 'mirror' rows, at most one 'endpoint' row, 'collector_error' notes; an empty array = no mirrored database
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_mirroring(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := pgvigil.mssql_rows(p_payload);
  v_newest boolean;
  v_endpoint jsonb;
BEGIN
  v_newest := pgvigil.mssql_hadr_read(p_instance_id, 'mssql_mirroring', p_snapshot_at,
                (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'mirror'));

  PERFORM pgvigil.ensure_month_partition('mssql_mirroring_sample', p_snapshot_at);
  DELETE FROM pgvigil.mssql_mirroring_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;   -- a re-run of one read
  INSERT INTO pgvigil.mssql_mirroring_sample (instance_id, snapshot_at, database_name, role, state, witness_state, log_send_queue_kb,
      redo_queue_kb, log_bytes_sent_total, redo_bytes_total, txn_delay_ms_total, mirrored_write_txns_total, send_rate_kb_s,
      redo_rate_kb_s, txn_delay_ms)
  SELECT DISTINCT ON (r->>'database_name') p_instance_id, p_snapshot_at, r->>'database_name', r->>'role', r->>'state', r->>'witness_state',
         (r->>'log_send_queue_kb')::bigint, (r->>'redo_queue_kb')::bigint,
         CASE WHEN (r->>'log_bytes_sent_type')::int = 272696576 THEN (r->>'log_bytes_sent_total')::bigint END,
         CASE WHEN (r->>'redo_bytes_type')::int = 272696576 THEN (r->>'redo_bytes_total')::bigint END,
         CASE WHEN (r->>'txn_delay_type')::int = 272696576 THEN (r->>'txn_delay_ms_total')::bigint END,
         CASE WHEN (r->>'mirrored_write_txns_type')::int = 272696576 THEN (r->>'mirrored_write_txns_total')::bigint END,
         round(pgvigil.mssql_counter_delta((r->>'log_bytes_sent_total')::bigint, p.log_bytes_sent_total, (r->>'log_bytes_sent_type')::int,
               extract(epoch FROM p_snapshot_at - p.snapshot_at)) / 1024, 3),
         round(pgvigil.mssql_counter_delta((r->>'redo_bytes_total')::bigint, p.redo_bytes_total, (r->>'redo_bytes_type')::int,
               extract(epoch FROM p_snapshot_at - p.snapshot_at)) / 1024, 3),
         CASE WHEN pgvigil.mssql_counter_delta((r->>'mirrored_write_txns_total')::bigint, p.mirrored_write_txns_total,
                     (r->>'mirrored_write_txns_type')::int, extract(epoch FROM p_snapshot_at - p.snapshot_at)) > 0
              THEN round(pgvigil.mssql_counter_delta((r->>'txn_delay_ms_total')::bigint, p.txn_delay_ms_total, (r->>'txn_delay_type')::int,
                           extract(epoch FROM p_snapshot_at - p.snapshot_at))
                         / pgvigil.mssql_counter_delta((r->>'mirrored_write_txns_total')::bigint, p.mirrored_write_txns_total,
                           (r->>'mirrored_write_txns_type')::int, extract(epoch FROM p_snapshot_at - p.snapshot_at)), 3) END
    FROM jsonb_array_elements(v_rows) r
    LEFT JOIN LATERAL (SELECT s.* FROM pgvigil.mssql_mirroring_sample s
                        WHERE s.instance_id = p_instance_id AND s.database_name = r->>'database_name'
                          AND s.snapshot_at < p_snapshot_at AND s.snapshot_at > p_snapshot_at - interval '15 minutes'
                          AND s.role IS NOT DISTINCT FROM r->>'role'
                        ORDER BY s.snapshot_at DESC LIMIT 1) p ON true
   WHERE r->>'kind' = 'mirror' AND r->>'database_name' IS NOT NULL;

  IF NOT v_newest THEN
    RETURN;   -- an older read imported late: its samples are history, the current state stays the newer read's
  END IF;

  -- a role swap: the role changed, or the role sequence moved on (two swaps between reads leave the role as it was)
  INSERT INTO pgvigil.mssql_mirroring_role_changes (instance_id, database_name, at, old_role, new_role, old_sequence, new_sequence,
      partner, state_after, witness_after)
  SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', p_snapshot_at, m.role, r->>'role', m.role_sequence,
         (r->>'role_sequence')::int, coalesce(r->>'partner_instance', r->>'partner'), r->>'state', r->>'witness_state'
    FROM jsonb_array_elements(v_rows) r
    JOIN pgvigil.mssql_mirroring_state m ON m.instance_id = p_instance_id AND m.database_name = r->>'database_name'
   WHERE r->>'kind' = 'mirror'
     AND ((m.role IS NOT NULL AND r->>'role' IS NOT NULL AND m.role <> r->>'role')
          OR (m.role_sequence IS NOT NULL AND r->>'role_sequence' IS NOT NULL AND m.role_sequence <> (r->>'role_sequence')::int))
  ON CONFLICT DO NOTHING;

  SELECT r - 'kind' INTO v_endpoint FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'endpoint' ORDER BY r->>'endpoint_name' LIMIT 1;
  DELETE FROM pgvigil.mssql_mirroring_state WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_mirroring_state (instance_id, database_name, snapshot_at, role, state, safety_level, partner,
      partner_instance, witness, witness_state, connection_timeout_s, log_send_queue_kb, redo_queue_kb, state_code, role_sequence,
      database_state, send_rate_kb_s, redo_rate_kb_s, txn_delay_ms, endpoint)
  SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', p_snapshot_at, r->>'role', r->>'state',
         r->>'safety_level', r->>'partner', r->>'partner_instance', r->>'witness', r->>'witness_state',
         (r->>'connection_timeout_s')::int, (r->>'log_send_queue_kb')::bigint, (r->>'redo_queue_kb')::bigint,
         (r->>'state_code')::int, (r->>'role_sequence')::int, r->>'database_state',
         s.send_rate_kb_s, s.redo_rate_kb_s, s.txn_delay_ms, v_endpoint
    FROM jsonb_array_elements(v_rows) r
    LEFT JOIN pgvigil.mssql_mirroring_sample s
           ON s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at AND s.database_name = r->>'database_name'
   WHERE r->>'kind' = 'mirror' AND r->>'database_name' IS NOT NULL;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Log shipping from restore history
CREATE TABLE IF NOT EXISTS pgvigil.mssql_logrestore_state (
  instance_id                int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name              text NOT NULL,
  snapshot_at                timestamptz NOT NULL,
  kind                       text NOT NULL CHECK (kind IN ('restore', 'pair')),   -- pair: the destination no longer exists
  database_state             text,
  is_in_standby              boolean,
  recovery_model             text,
  created_at                 timestamptz,
  is_mirrored                boolean,
  in_availability_group      boolean,
  last_log_restore_at        timestamptz,    -- the newest log restore of the last 14 days
  last_log_backup_start_at   timestamptz,    -- the start of the log backup it restored, in UTC by backupset.time_zone
  backup_time_zone           int,
  source_server              text,           -- the pair: the server and database the restored log backup came from
  source_database            text,
  last_file                  text,
  last_restore_at            timestamptz,    -- the newest restore of any kind
  last_restore_type          text,
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_logrestore_sample (
  instance_id            int NOT NULL,
  snapshot_at            timestamptz NOT NULL,
  database_name          text NOT NULL,
  minutes_since_restore  numeric,
  latency_minutes        numeric
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_logrestore_sample_at_idx ON pgvigil.mssql_logrestore_sample (snapshot_at);

-- payload: 0066's 'primary' and 'secondary' rows (msdb's monitor tables), 'restore' and 'pair' rows (restore history)
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_logshipping(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_rows jsonb := pgvigil.mssql_rows(p_payload);
BEGIN
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_logshipping', p_snapshot_at,
           (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' IN ('primary', 'secondary', 'restore', 'pair'))) THEN
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

  DELETE FROM pgvigil.mssql_logrestore_state WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_logrestore_state (instance_id, database_name, snapshot_at, kind, database_state, is_in_standby,
      recovery_model, created_at, is_mirrored, in_availability_group, last_log_restore_at, last_log_backup_start_at,
      backup_time_zone, source_server, source_database, last_file, last_restore_at, last_restore_type)
  SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', p_snapshot_at, r->>'kind', r->>'database_state',
         (r->>'is_in_standby')::int = 1, r->>'recovery_model', (r->>'created_utc')::timestamptz, (r->>'is_mirrored')::int = 1,
         (r->>'in_availability_group')::int = 1, (r->>'last_log_restore_utc')::timestamptz,
         (r->>'last_log_backup_start_utc')::timestamptz, (r->>'backup_time_zone')::int, r->>'source_server', r->>'source_database',
         r->>'last_file', (r->>'last_restore_utc')::timestamptz, r->>'last_restore_type'
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' IN ('restore', 'pair') AND r->>'database_name' IS NOT NULL
   ORDER BY r->>'database_name', (r->>'kind' = 'restore') DESC;   -- a database that exists wins over a gone one of its name

  PERFORM pgvigil.ensure_month_partition('mssql_logrestore_sample', p_snapshot_at);
  DELETE FROM pgvigil.mssql_logrestore_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_logrestore_sample (instance_id, snapshot_at, database_name, minutes_since_restore, latency_minutes)
  SELECT s.instance_id, p_snapshot_at, s.database_name,
         round((extract(epoch FROM p_snapshot_at - s.last_log_restore_at) / 60)::numeric, 1),
         round((extract(epoch FROM s.last_log_restore_at - s.last_log_backup_start_at) / 60)::numeric, 1)
    FROM pgvigil.mssql_logrestore_state s
   WHERE s.instance_id = p_instance_id AND s.kind = 'restore' AND s.last_log_restore_at IS NOT NULL;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. The failover cluster instance
CREATE TABLE IF NOT EXISTS pgvigil.mssql_fci_nodes (
  instance_id       int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  node_name         text NOT NULL,
  snapshot_at       timestamptz NOT NULL,
  node_status       int,          -- sys.dm_os_cluster_nodes.status: 0 up, 1 down, 2 paused, 3 joining, -1 unknown
  node_state        text,
  is_current_owner  boolean,
  physical_node     text,         -- SERVERPROPERTY('ComputerNamePhysicalNetBIOS') at the read: where the instance runs
  virtual_name      text,
  PRIMARY KEY (instance_id, node_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_fci_owner_changes (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  at           timestamptz NOT NULL,   -- the read that first saw the new owner
  old_node     text NOT NULL,
  new_node     text NOT NULL,
  PRIMARY KEY (instance_id, at)
);
CREATE INDEX IF NOT EXISTS mssql_fci_owner_changes_at_idx ON pgvigil.mssql_fci_owner_changes (at);

-- payload: 'node' rows; an empty array = not a failover cluster instance (the state is cleared)
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_fci(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := pgvigil.mssql_rows(p_payload);
  v_old text;
  v_new text;
BEGIN
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_fci', p_snapshot_at,
           (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'node')) THEN
    RETURN;
  END IF;
  SELECT coalesce(max(n.physical_node), max(n.node_name) FILTER (WHERE n.is_current_owner)) INTO v_old
    FROM pgvigil.mssql_fci_nodes n WHERE n.instance_id = p_instance_id;
  SELECT coalesce(max(r->>'physical_node'), max(r->>'node_name') FILTER (WHERE (r->>'is_current_owner')::int = 1)) INTO v_new
    FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'node';
  IF v_old IS NOT NULL AND v_new IS NOT NULL AND lower(v_old) <> lower(v_new) THEN
    INSERT INTO pgvigil.mssql_fci_owner_changes (instance_id, at, old_node, new_node) VALUES (p_instance_id, p_snapshot_at, v_old, v_new)
    ON CONFLICT DO NOTHING;
  END IF;
  DELETE FROM pgvigil.mssql_fci_nodes WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_fci_nodes (instance_id, node_name, snapshot_at, node_status, node_state, is_current_owner, physical_node, virtual_name)
  SELECT DISTINCT ON (r->>'node_name') p_instance_id, r->>'node_name', p_snapshot_at, (r->>'node_status')::int, r->>'node_state',
         (r->>'is_current_owner')::int = 1, r->>'physical_node', r->>'virtual_name'
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'node' AND r->>'node_name' IS NOT NULL;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Findings
-- pgvigil.mssql_repl_findings is 0142's (replication depth); on a tree without 0142 it is made here with 0066's two
-- replication arms as they were, so the union below always has it
DO $$
BEGIN
  IF to_regclass('pgvigil.mssql_repl_findings') IS NULL THEN
    EXECUTE $v$
CREATE VIEW pgvigil.mssql_repl_findings AS
SELECT p.instance_id, 'warning'::text AS severity, 'a replication agent failed'::text AS check_name,
       p.agent_type || ' / ' || coalesce(p.agent_name, '?') AS object, p.snapshot_at AS at,
       format('the %s agent %s (publisher %s, database %s%s) failed at %s: %s', p.agent_type, coalesce(p.agent_name, '?'), coalesce(p.publisher, '?'),
              coalesce(p.publisher_db, '?'), coalesce(', subscriber ' || p.subscriber || '.' || p.subscriber_db, ''),
              coalesce(to_char(p.last_run_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), '?'), coalesce(p.status_text, 'no message')) AS detail
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
   AND l.repl_undistributed_commands > 0 AND p.undistributed > l.repl_undistributed_commands
$v$;
  END IF;
END $$;

-- The availability group and mirroring arms leave out Amazon RDS (see the header). "For 5 minutes" and the staleness
-- rules are 0066's.
CREATE OR REPLACE VIEW pgvigil.mssql_hadr_findings AS
WITH judged AS (
  SELECT i.instance_id FROM pgvigil.instances i WHERE i.engine = 'sqlserver' AND i.platform IS DISTINCT FROM 'rdssqlserver'
), rep AS (
  SELECT a.* FROM pgvigil.mssql_ag_state a JOIN judged j USING (instance_id) WHERE a.snapshot_at > now() - interval '5 minutes'
), dbs AS (
  SELECT d.*, r.availability_mode
    FROM pgvigil.mssql_ag_database_state d
    JOIN judged j USING (instance_id)
    LEFT JOIN pgvigil.mssql_ag_state r ON r.instance_id = d.instance_id AND r.group_id = d.group_id AND r.replica_server = d.replica_server
   WHERE d.snapshot_at > now() - interval '5 minutes'
), q5 AS (
  SELECT s.instance_id, s.group_name, s.replica_server, s.database_name,
         min(coalesce(s.log_send_queue_kb, 0)) AS min_send, max(s.log_send_queue_kb) AS max_send,
         min(coalesce(s.redo_queue_kb, 0)) AS min_redo, max(s.redo_queue_kb) AS max_redo, max(s.snapshot_at) AS last_at
    FROM pgvigil.mssql_ag_sample s JOIN judged j USING (instance_id)
   WHERE s.snapshot_at > now() - interval '5 minutes 30 seconds'
   GROUP BY 1, 2, 3, 4
  HAVING min(s.snapshot_at) <= now() - interval '4 minutes' AND max(s.snapshot_at) > now() - interval '2 minutes'
), loss AS (
  -- the estimated data loss of a secondary in its last two reads (both within 3 minutes): the smaller one is judged,
  -- so one read's spike raises nothing; the tiers are the threshold key ag_data_loss's (minutes)
  SELECT x.instance_id, x.group_name, x.replica_server, x.database_name, min(x.est_data_loss_s) AS min_loss,
         max(x.est_data_loss_s) AS max_loss, max(x.snapshot_at) AS last_at, count(*) AS reads
    FROM (SELECT s.*, row_number() OVER (PARTITION BY s.instance_id, s.group_name, s.replica_server, s.database_name ORDER BY s.snapshot_at DESC) AS k
            FROM pgvigil.mssql_ag_sample s JOIN judged j USING (instance_id)
           WHERE s.snapshot_at > now() - interval '3 minutes' AND s.est_data_loss_s IS NOT NULL) x
   WHERE x.k <= 2
   GROUP BY 1, 2, 3, 4
  HAVING count(*) = 2
), mir AS (
  SELECT m.* FROM pgvigil.mssql_mirroring_state m JOIN judged j USING (instance_id) WHERE m.snapshot_at > now() - interval '5 minutes'
), mq5 AS (
  SELECT s.instance_id, s.database_name, s.role,
         min(coalesce(s.log_send_queue_kb, 0)) AS min_send, max(s.log_send_queue_kb) AS max_send,
         min(coalesce(s.redo_queue_kb, 0)) AS min_redo, max(s.redo_queue_kb) AS max_redo, max(s.snapshot_at) AS last_at
    FROM pgvigil.mssql_mirroring_sample s JOIN judged j USING (instance_id)
   WHERE s.snapshot_at > now() - interval '5 minutes 30 seconds'
   GROUP BY 1, 2, 3
  HAVING min(s.snapshot_at) <= now() - interval '4 minutes' AND max(s.snapshot_at) > now() - interval '2 minutes'
), lr AS (
  SELECT s.*, l.new_database_hours,
         extract(epoch FROM s.snapshot_at - s.last_log_restore_at) / 60 AS age_min,
         extract(epoch FROM s.last_log_restore_at - s.last_log_backup_start_at) / 60 AS latency_min,
         ta.warn AS age_warn, ta.crit AS age_crit, tl.warn AS lat_warn, tl.crit AS lat_crit,
         EXISTS (SELECT 1 FROM pgvigil.mssql_logshipping_state m WHERE m.instance_id = s.instance_id AND m.role = 'secondary'
                    AND m.database_name = s.database_name AND m.threshold_minutes > 0
                    AND m.snapshot_at > now() - interval '15 minutes') AS msdb_judged
    FROM pgvigil.mssql_logrestore_state s
    JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = s.instance_id
    CROSS JOIN LATERAL pgvigil.pg_threshold(s.instance_id, 'logship_restore_age', s.database_name) ta
    CROSS JOIN LATERAL pgvigil.pg_threshold(s.instance_id, 'logship_restore_latency', s.database_name) tl
   WHERE s.snapshot_at > now() - interval '15 minutes' AND s.kind = 'restore' AND s.last_log_restore_at IS NOT NULL
     AND NOT coalesce(s.is_mirrored, false) AND NOT coalesce(s.in_availability_group, false)
     AND coalesce(s.recovery_model, '') <> 'SIMPLE'
     AND (s.created_at IS NULL OR s.created_at <= s.snapshot_at - make_interval(secs => (l.new_database_hours * 3600)::float8))
)
-- availability groups: 0066's arms (a replica or database that is not joined is said once, by its own arm below)
SELECT r.instance_id, 'critical'::text AS severity, 'a replica is not connected'::text AS check_name,
       r.group_name || ' / ' || r.replica_server AS object, r.snapshot_at AS at,
       format('replica %s of the availability group %s is %s%s. Its databases receive nothing until it connects again.',
              r.replica_server, r.group_name, lower(r.connected_state),
              coalesce(' (last connect error ' || r.last_connect_error || ': ' || r.last_connect_error_text || ')', '')) AS detail
  FROM rep r WHERE r.connected_state IS NOT NULL AND r.connected_state <> 'CONNECTED'
               AND r.join_state IS DISTINCT FROM 'NOT_JOINED'                          -- a replica never joined has its own finding
UNION ALL
SELECT r.instance_id, 'critical', 'a replica is not healthy', r.group_name || ' / ' || r.replica_server, r.snapshot_at,
       format('replica %s of the availability group %s: synchronization health %s, role %s, operational state %s.',
              r.replica_server, r.group_name, lower(replace(r.synchronization_health, '_', ' ')), coalesce(lower(r.role), 'unknown'),
              coalesce(lower(replace(r.operational_state, '_', ' ')), 'unknown'))
  FROM rep r WHERE r.synchronization_health IS NOT NULL AND r.synchronization_health <> 'HEALTHY'
               AND (r.connected_state IS NULL OR r.connected_state = 'CONNECTED')     -- a disconnected replica has its own finding
               AND r.join_state IS DISTINCT FROM 'NOT_JOINED'                          -- a replica never joined has its own finding
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
               AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_ag_database_cluster c       -- not joined there: its own finding
                                WHERE c.instance_id = d.instance_id AND c.group_id = d.group_id AND c.replica_server = d.replica_server
                                  AND c.database_name = d.database_name AND c.is_database_joined IS FALSE)
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
  FROM pgvigil.mssql_ag_failovers f JOIN judged j USING (instance_id) WHERE f.at > now() - interval '1 hour'
UNION ALL
SELECT r.instance_id, 'info', 'a collection stores nothing where rows are expected', 'mssql_ag', r.snapshot_at,
       format('Always On is enabled on this server and mssql_ag has read no availability group in its last %s reads: no group exists yet, or the login does not see it.', r.empty_reads)
  FROM pgvigil.mssql_hadr_reads r WHERE r.collection = 'mssql_ag' AND r.empty_reads >= 60 AND r.snapshot_at > now() - interval '5 minutes'
-- availability groups: the gaps (item 5)
UNION ALL
SELECT x.instance_id, CASE WHEN x.min_loss >= t.crit * 60 THEN 'critical' ELSE 'warning' END,
       'a secondary would lose data in a failover', x.group_name || ' / ' || x.replica_server || ' / ' || x.database_name, x.last_at,
       format('database %s on replica %s (group %s): a failover to it now would lose about %s s of committed work (the primary''s last commit less the secondary''s%s), at least %s s in each of its last 2 reads; warning from %s s, critical from %s s.',
              x.database_name, x.replica_server, x.group_name, x.max_loss,
              CASE WHEN d.data_loss_basis = 'hardened' THEN ' last hardened log: it has redone no commit yet' ELSE '' END,
              x.min_loss, round(t.warn * 60), round(t.crit * 60))
  FROM loss x
  CROSS JOIN LATERAL pgvigil.pg_threshold(x.instance_id, 'ag_data_loss') t
  LEFT JOIN pgvigil.mssql_ag_database_state d
         ON d.instance_id = x.instance_id AND d.group_name = x.group_name AND d.replica_server = x.replica_server AND d.database_name = x.database_name
 WHERE t.warn IS NOT NULL AND t.warn > 0 AND x.min_loss >= t.warn * 60
UNION ALL
SELECT r.instance_id, 'warning', 'a replica is not joined', r.group_name || ' / ' || r.replica_server, r.snapshot_at,
       format('replica %s is in the availability group %s but its server has not joined the group (ALTER AVAILABILITY GROUP %s JOIN on that server): it receives nothing and cannot take over.',
              r.replica_server, r.group_name, r.group_name)
  FROM rep r WHERE r.join_state = 'NOT_JOINED' AND NOT coalesce(r.is_distributed, false)
UNION ALL
SELECT c.instance_id, 'warning', 'a database is not joined', c.group_name || ' / ' || c.replica_server || ' / ' || c.database_name, c.snapshot_at,
       format('database %s of the availability group %s is not joined on replica %s: that replica holds no copy that is kept up to date (ALTER DATABASE %s SET HADR AVAILABILITY GROUP = %s on it, or automatic seeding).',
              c.database_name, c.group_name, c.replica_server, c.database_name, c.group_name)
  FROM pgvigil.mssql_ag_database_cluster c JOIN judged j USING (instance_id)
  JOIN rep r ON r.instance_id = c.instance_id AND r.group_id = c.group_id AND r.replica_server = c.replica_server
 WHERE c.snapshot_at > now() - interval '5 minutes' AND c.is_database_joined IS FALSE
   AND r.join_state IS DISTINCT FROM 'NOT_JOINED'                                   -- the replica's own finding says it
   AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_ag_seeding s                         -- automatic seeding is joining it now
                    WHERE s.instance_id = c.instance_id AND s.group_id = c.group_id AND s.database_name = c.database_name
                      AND lower(s.remote_replica) = lower(c.replica_server) AND s.seeding_state NOT IN ('COMPLETED', 'FAILED'))
UNION ALL
SELECT c.instance_id, 'critical', 'a database is not ready for automatic failover', c.group_name || ' / ' || c.replica_server || ' / ' || c.database_name, c.snapshot_at,
       format('database %s on the automatic-failover replica %s (group %s) is not failover-ready: an automatic failover to it would not happen, or would lose data.',
              c.database_name, c.replica_server, c.group_name)
  FROM pgvigil.mssql_ag_database_cluster c JOIN judged j USING (instance_id)
  JOIN rep r ON r.instance_id = c.instance_id AND r.group_id = c.group_id AND r.replica_server = c.replica_server
 WHERE c.snapshot_at > now() - interval '5 minutes' AND c.is_failover_ready IS FALSE AND c.is_database_joined IS TRUE
   AND r.failover_mode = 'AUTOMATIC' AND lower(r.replica_server) IS DISTINCT FROM lower(r.primary_replica)
UNION ALL
SELECT DISTINCT ON (r.instance_id) r.instance_id, 'critical', 'the cluster has no normal quorum', coalesce(nullif(m.member->>'cluster_name', ''), 'cluster'), r.snapshot_at,
       format('the Windows cluster %s under the availability group %s reports %s: the groups on it may not fail over, or run on forced quorum.',
              coalesce(nullif(m.member->>'cluster_name', ''), '?'), r.group_name, lower(replace(m.member->>'quorum_state', '_', ' ')))
  FROM rep r CROSS JOIN LATERAL (SELECT e AS member FROM jsonb_array_elements(CASE WHEN jsonb_typeof(r.cluster) = 'array' THEN r.cluster ELSE '[]'::jsonb END) e LIMIT 1) m
 WHERE r.cluster_type = 'WSFC' AND m.member->>'quorum_state' IS NOT NULL AND m.member->>'quorum_state' <> 'NORMAL_QUORUM'
UNION ALL
SELECT x.instance_id, 'warning', 'a cluster member is down', x.member_name, x.snapshot_at,
       format('member %s (%s) of the Windows cluster under the availability groups of this server is %s; quorum %s.',
              x.member_name, lower(replace(x.member_type, '_', ' ')), lower(x.member_state), lower(replace(coalesce(x.quorum_state, 'unknown'), '_', ' ')))
  FROM (SELECT DISTINCT ON (r.instance_id, e->>'member_name') r.instance_id, r.snapshot_at, e->>'member_name' AS member_name,
               e->>'member_type' AS member_type, e->>'member_state' AS member_state, e->>'quorum_state' AS quorum_state
          FROM rep r CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(r.cluster) = 'array' THEN r.cluster ELSE '[]'::jsonb END) e
         WHERE r.cluster_type = 'WSFC') x
 WHERE x.member_state IS NOT NULL AND x.member_state <> 'UP'
UNION ALL
SELECT DISTINCT ON (r.instance_id) r.instance_id, 'critical', 'the availability group endpoint is not started', coalesce(r.endpoint->>'endpoint_name', 'endpoint'), r.snapshot_at,
       format('the database mirroring endpoint %s of this server (port %s) is %s: the replicas of its availability groups cannot connect to it (ALTER ENDPOINT %s STATE = STARTED).',
              r.endpoint->>'endpoint_name', coalesce(r.endpoint->>'endpoint_port', '?'), lower(r.endpoint->>'endpoint_state'), r.endpoint->>'endpoint_name')
  FROM rep r WHERE r.is_local AND r.endpoint->>'endpoint_state' IS NOT NULL AND r.endpoint->>'endpoint_state' <> 'STARTED'
UNION ALL
SELECT DISTINCT ON (r.instance_id) r.instance_id, 'warning', 'the AlwaysOn_health session is not running', 'AlwaysOn_health', r.snapshot_at,
       format('this server holds a replica of an availability group and its AlwaysOn_health event session %s: the group''s state changes, failovers and errors are not recorded (ALTER EVENT SESSION AlwaysOn_health ON SERVER WITH (STARTUP_STATE = ON); ... STATE = START).',
              CASE WHEN NOT (r.health_session->>'exists')::boolean THEN 'does not exist'
                   WHEN NOT (r.health_session->>'running')::boolean AND NOT coalesce((r.health_session->>'autostart')::boolean, false) THEN 'is stopped and does not start with the server'
                   WHEN NOT (r.health_session->>'running')::boolean THEN 'is stopped'
                   ELSE 'runs but does not start with the server' END)
  FROM rep r
 WHERE r.health_session IS NOT NULL AND NOT coalesce(r.is_distributed, false)
   AND (NOT (r.health_session->>'exists')::boolean OR NOT (r.health_session->>'running')::boolean
        OR NOT coalesce((r.health_session->>'autostart')::boolean, false))
UNION ALL
SELECT s.instance_id, 'warning', 'automatic seeding failed', s.group_name || ' / ' || s.database_name || coalesce(' -> ' || nullif(s.remote_replica, ''), ''), s.snapshot_at,
       format('automatic seeding of database %s (group %s) %s replica %s failed at its attempt %s, started %s: %s%s.',
              s.database_name, s.group_name, CASE WHEN s.is_source THEN 'to' ELSE 'from' END, coalesce(nullif(s.remote_replica, ''), '?'),
              coalesce(s.attempts::text, '?'), coalesce(to_char(s.started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), '?'),
              coalesce(lower(replace(s.failure_state, '_', ' ')), 'no failure state'), coalesce(' (error ' || nullif(s.error_code, 0) || ')', ''))
  FROM pgvigil.mssql_ag_seeding s JOIN judged j USING (instance_id)
 WHERE s.snapshot_at > now() - interval '5 minutes' AND s.seeding_state = 'FAILED'
   AND coalesce(s.completed_at, s.started_at) > now() - interval '24 hours'
UNION ALL
SELECT r.instance_id, 'warning', 'read-only routing names a replica that takes no reads',
       r.group_name || ' / ' || r.replica_server || ' -> ' || (e->>'replica'), r.snapshot_at,
       format('replica %s of the availability group %s routes read-intent connections (when it is primary) to %s, which %s: those connections fail or fall back.',
              r.replica_server, r.group_name, e->>'replica',
              CASE WHEN t.replica_server IS NULL THEN 'is not a replica of the group'
                   WHEN t.secondary_connections = 'NO' THEN 'allows no connections in the secondary role'
                   ELSE 'has no read-only routing URL' END)
  FROM rep r CROSS JOIN LATERAL jsonb_array_elements(coalesce(r.routing_list, '[]'::jsonb)) e
  LEFT JOIN rep t ON t.instance_id = r.instance_id AND t.group_id = r.group_id AND lower(t.replica_server) = lower(e->>'replica')
 WHERE lower(e->>'replica') IS DISTINCT FROM lower(r.primary_replica)
   AND (t.replica_server IS NULL OR t.secondary_connections = 'NO' OR t.read_only_routing_url IS NULL)
-- database mirroring: DBA Dash's states (DatabaseMirroringSummary_Get: OK synchronized with the witness unknown or
-- connected; warning synchronizing, or a named witness disconnected; critical everything else); one finding per row
UNION ALL
SELECT m.instance_id,
       CASE WHEN m.state IN ('SYNCHRONIZED', 'SYNCHRONIZING') THEN 'warning' ELSE 'critical' END,
       CASE WHEN m.state IN ('DISCONNECTED', 'SUSPENDED') THEN 'mirroring is disconnected or suspended'
            WHEN m.state NOT IN ('SYNCHRONIZED', 'SYNCHRONIZING') THEN 'mirroring is not synchronized'
            WHEN m.state = 'SYNCHRONIZING' THEN 'mirroring is synchronizing'
            ELSE 'the mirroring witness is disconnected' END,
       m.database_name, m.snapshot_at,
       format('database %s (%s, partner %s) is %s%s%s.', m.database_name, coalesce(lower(m.role), 'role unknown'), coalesce(m.partner_instance, m.partner, '?'),
              lower(replace(m.state, '_', ' ')),
              coalesce('; witness ' || m.witness || ' ' || lower(m.witness_state), ''),
              CASE WHEN m.state = 'PENDING_FAILOVER' THEN ': a failover has begun and the partners have not settled their roles'
                   WHEN m.state = 'UNSYNCHRONIZED' THEN ': the mirror is not caught up, so no failover is possible now'
                   WHEN m.state = 'SYNCHRONIZING' THEN ': the mirror is catching up; a failover now would lose data'
                   WHEN m.state = 'SYNCHRONIZED' THEN ': without the witness an automatic failover cannot happen'
                   ELSE '' END)
  FROM mir m
 WHERE m.state IS NOT NULL
   AND (m.state NOT IN ('SYNCHRONIZED', 'SYNCHRONIZING') OR m.state = 'SYNCHRONIZING'
        OR (m.witness IS NOT NULL AND m.witness_state = 'DISCONNECTED'))
UNION ALL
SELECT q.instance_id, 'warning', 'the mirroring send queue is over its threshold', q.database_name, q.last_at,
       format('database %s (principal): between %s and %s of log waited to be sent to the mirror in every read of the last 5 minutes (threshold %s). That log is what a failover now would lose.',
              q.database_name, pg_size_pretty(q.min_send * 1024), pg_size_pretty(q.max_send * 1024), pg_size_pretty((l.log_send_queue_kb * 1024)::bigint))
  FROM mq5 q JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = q.instance_id
 WHERE q.role = 'PRINCIPAL' AND l.log_send_queue_kb > 0 AND q.min_send > l.log_send_queue_kb
UNION ALL
SELECT q.instance_id, 'warning', 'the mirroring redo queue is over its threshold', q.database_name, q.last_at,
       format('database %s (mirror): between %s and %s of log waited to be restored in every read of the last 5 minutes (threshold %s). A failover to this mirror waits for that restore.',
              q.database_name, pg_size_pretty(q.min_redo * 1024), pg_size_pretty(q.max_redo * 1024), pg_size_pretty((l.redo_queue_kb * 1024)::bigint))
  FROM mq5 q JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = q.instance_id
 WHERE q.role = 'MIRROR' AND l.redo_queue_kb > 0 AND q.min_redo > l.redo_queue_kb
UNION ALL
SELECT c.instance_id, 'critical', 'the principal of a mirrored database changed', c.database_name, c.at,
       format('database %s: this server''s role went from %s to %s in the minute before %s (a mirroring failover%s); it is now %s with %s. Shown for an hour.',
              c.database_name, coalesce(lower(c.old_role), '?'), coalesce(lower(c.new_role), '?'),
              to_char(c.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
              CASE WHEN c.old_role IS NOT DISTINCT FROM c.new_role THEN format(', and back: the role sequence went from %s to %s', c.old_sequence, c.new_sequence) ELSE '' END,
              coalesce(lower(replace(c.state_after, '_', ' ')), '?'), coalesce('partner ' || c.partner, 'its partner'))
  FROM pgvigil.mssql_mirroring_role_changes c JOIN judged j USING (instance_id) WHERE c.at > now() - interval '1 hour'
UNION ALL
SELECT DISTINCT ON (m.instance_id) m.instance_id, 'critical', 'the mirroring endpoint is not started', coalesce(m.endpoint->>'endpoint_name', 'endpoint'), m.snapshot_at,
       format('the database mirroring endpoint %s of this server (port %s) is %s: its mirrored databases cannot reach their partners (ALTER ENDPOINT %s STATE = STARTED).',
              m.endpoint->>'endpoint_name', coalesce(m.endpoint->>'endpoint_port', '?'), lower(m.endpoint->>'endpoint_state'), m.endpoint->>'endpoint_name')
  FROM mir m WHERE m.endpoint->>'endpoint_state' IS NOT NULL AND m.endpoint->>'endpoint_state' <> 'STARTED'
-- log shipping: msdb's monitor (0066's arm)
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
-- log shipping from restore history (DBA Dash's two measures; a database msdb's monitor judges gets the critical tier
-- only: the monitor's own threshold is its warning)
UNION ALL
SELECT x.instance_id, x.sev, 'log restores are behind', x.database_name || coalesce(' (from ' || x.source_server || '.' || x.source_database || ')', ''), x.snapshot_at,
       format('database %s (log backups of %s.%s): the last log restore ran %s, %s minutes before the read, and restored a log backup started %s minutes before it ran; warning from %s / %s minutes, critical from %s / %s minutes (time since the restore / its latency). The last file: %s.',
              x.database_name, coalesce(x.source_server, '?'), coalesce(x.source_database, '?'),
              to_char(x.last_log_restore_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), round(x.age_min::numeric),
              coalesce(round(x.latency_min::numeric)::text, '?'), coalesce(x.age_warn::text, '-'), coalesce(x.lat_warn::text, '-'),
              coalesce(x.age_crit::text, '-'), coalesce(x.lat_crit::text, '-'), coalesce(x.last_file, '?'))
  FROM (SELECT lr.*, CASE WHEN lr.age_min > lr.age_crit OR lr.latency_min > lr.lat_crit THEN 'critical'
                          WHEN NOT lr.msdb_judged AND (lr.age_min > lr.age_warn OR lr.latency_min > lr.lat_warn) THEN 'warning' END AS sev
          FROM lr) x
 WHERE x.sev IS NOT NULL
UNION ALL
SELECT s.instance_id, 'warning', 'a database has been restoring for days', s.database_name, s.snapshot_at,
       format('database %s is %s and no restore has been applied to it in %s day(s)%s: log shipping to it may be broken (sp_Blitz check 111).',
              s.database_name, CASE WHEN s.is_in_standby THEN 'in standby' ELSE lower(s.database_state) END, t.warn,
              CASE WHEN s.last_restore_at IS NULL THEN ' (msdb lists no restore of it at all)'
                   ELSE ' (the last one, ' || CASE s.last_restore_type WHEN 'L' THEN 'a log' WHEN 'D' THEN 'a full' WHEN 'I' THEN 'a differential' ELSE 'a' END
                        || ' restore, ran ' || to_char(s.last_restore_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"') || ')' END)
  FROM pgvigil.mssql_logrestore_state s
  CROSS JOIN LATERAL pgvigil.pg_threshold(s.instance_id, 'restoring_days', s.database_name) t
 WHERE s.snapshot_at > now() - interval '15 minutes' AND s.kind = 'restore' AND s.last_log_restore_at IS NULL
   AND NOT coalesce(s.is_mirrored, false) AND NOT coalesce(s.in_availability_group, false)
   AND t.warn IS NOT NULL AND t.warn > 0
   AND coalesce(s.last_restore_at, s.created_at, '-infinity'::timestamptz) < s.snapshot_at - make_interval(secs => (t.warn * 86400)::float8)
   AND (s.created_at IS NULL OR s.created_at < s.snapshot_at - make_interval(secs => (t.warn * 86400)::float8))
UNION ALL
SELECT s.instance_id, 'warning', 'a log shipping copy is missing', s.database_name || coalesce(' (from ' || s.source_server || '.' || s.source_database || ')', ''), s.snapshot_at,
       format('database %s received log restores from %s.%s until %s, and no longer exists on this server: the copy was dropped or renamed.',
              s.database_name, coalesce(s.source_server, '?'), coalesce(s.source_database, '?'),
              to_char(s.last_log_restore_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
  FROM pgvigil.mssql_logrestore_state s
 WHERE s.snapshot_at > now() - interval '15 minutes' AND s.kind = 'pair'
-- the failover cluster instance (behind the clustered flag: an instance that is not one has no node row)
UNION ALL
SELECT c.instance_id, 'critical', 'the failover cluster instance moved to another node', c.new_node, c.at,
       format('the instance moved from node %s to node %s in the minute before %s (a failover: the instance restarted there). Shown for an hour.',
              c.old_node, c.new_node, to_char(c.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
  FROM pgvigil.mssql_fci_owner_changes c WHERE c.at > now() - interval '1 hour'
UNION ALL
SELECT n.instance_id, 'warning', 'a cluster node is not up', n.node_name, n.snapshot_at,
       format('node %s of the failover cluster instance %s is %s: the instance cannot fail over to it.', n.node_name, coalesce(n.virtual_name, '?'), coalesce(n.node_state, 'in an unknown state'))
  FROM pgvigil.mssql_fci_nodes n
 WHERE n.snapshot_at > now() - interval '5 minutes' AND n.node_status IS DISTINCT FROM 0 AND NOT coalesce(n.is_current_owner, false)
UNION ALL
SELECT n.instance_id, 'warning', 'no spare cluster node', min(n.virtual_name), max(n.snapshot_at),
       format('the failover cluster instance %s runs on %s and no other node of its %s is up: if that node fails, the instance stops (sp_Blitz check 184).',
              coalesce(min(n.virtual_name), '?'), coalesce(min(n.node_name) FILTER (WHERE n.is_current_owner), min(n.physical_node), '?'),
              count(*) || ' node(s)')
  FROM pgvigil.mssql_fci_nodes n
 WHERE n.snapshot_at > now() - interval '5 minutes'
 GROUP BY n.instance_id
HAVING count(*) FILTER (WHERE n.node_status = 0 AND NOT coalesce(n.is_current_owner, false)) = 0
-- replication: 0142's view (or 0066's two arms, above)
UNION ALL
SELECT rf.instance_id, rf.severity, rf.check_name, rf.object, rf.at, rf.detail FROM pgvigil.mssql_repl_findings rf;
