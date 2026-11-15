-- 0151_georepl_cloud_replicas: task 390 (Allen's Q9, 2026-11-14 13:12: in v0.4.0). Part G (390a): Azure SQL Database's
-- active geo-replication links as each database sees them (mssql_georepl). Part P (390b, the provider replica metrics of
-- RDS and Cloud SQL) is added to this file before its first join. DBA Dash reads none of this (4.25.0): the shape is its
-- availability group grid, as pgvigil's AG rows already follow it (0066).
--
--   mssql_georepl_read    per instance the last read: the logical server and the database it reached (behind a failover
--                         group's listener the server changes at a failover while the configured name does not) and the
--                         number of links; a database with no link has its row with links = 0.
--   mssql_georepl_state   current; one row per link the database sees (both ends of a link, when both are monitored,
--                         share its link_guid), the view's columns in UTC, the unsent window (a primary's last_commit -
--                         last_replication, both on the primary's clock) and the acknowledgement's age on the server's
--                         clock, and since when the link has been in its replication state.
--   mssql_georepl_sample  monthly partitions; per read and link the role, the state, the lag, the unsent window.
--   mssql_georepl_events  one row per change seen between two reads: a link added or removed, a role change (a failover),
--                         a partner change on the same link (a failover seen through the group's listener), a replication
--                         state change; with the read that saw it and the read before (the window it happened in: the
--                         view cannot tell a planned failover from a forced one).
--   mssql_failover_groups  current; one row per logical server (its key: subscription/resource group/server) and failover
--                         group, read from Azure Resource Manager by mssql_failover_groups (no T-SQL view shows a group),
--                         whichever of the server's databases read it; mssql_failover_group_reads per server the newest read
--                         (an older one, through another database and imported late, changes nothing).
--   mssql_failover_group_events  a group added or removed, its primary moved (role), its policy or grace changed, its partners
--                         changed, and each failover operation of the Activity Log once (planned or forced, its status).
--   mssql_georepl_findings (instance_id, severity, check_name, object, at, detail), the engine's own view (0143 redefines
--                         mssql_hadr_findings, so an arm there would collide; 0143's mssql_repl_findings is the precedent).
--                         Its arm in pgvigil.findings, alerting and the Summary's HA cell, and the purge lines (the
--                         partition parent mssql_georepl_sample; events past the window) are the join's WIRING.
--
-- The threshold: pg_threshold_keys 'georepl_data_loss' (minutes; warning 1 = sp_Blitz check 268's 60 s for an AG
-- secondary, critical 5 = pgvigil's own, the numbers 0143 gives ag_data_loss; root and tag: on this base
-- import_pg_threshold refuses an instance level for a SQL Server instance, which 0142 teaches). 0143's ag_data_loss (the
-- lead's Q2) is not on this file's base; when 0142 / 0143 join, the key gains engines '{sqlserver}' and the instance
-- level (WIRING).
-- "For 5 minutes" is 0066's rule: in every read of the last 5.5 minutes, the first at least 4 minutes old and the last
-- at most 2 minutes old. A state row older than 5 minutes fires nothing (the Collections page says the read is stale).

CREATE TABLE IF NOT EXISTS pgvigil.mssql_georepl_read (
  instance_id    int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at    timestamptz NOT NULL,
  server_read    text,
  database_name  text,
  links          int NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_georepl_state (
  instance_id                      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  link_guid                        text NOT NULL,
  partner_server                   text,
  partner_database                 text,
  role                             int,       -- 0 primary, 1 secondary
  role_desc                        text,
  replication_state                int,       -- 1 seeding, 2 catch-up, 4 suspended (Microsoft)
  replication_state_desc           text,      -- PENDING, SEEDING, CATCH_UP, SUSPENDED
  state_since                      timestamptz NOT NULL,
  replication_lag_sec              int,       -- the primary's only
  unsent_s                         numeric,   -- the primary's last_commit - last_replication
  ack_age_s                        int,       -- now - last_replication on the server's clock
  last_replication                 timestamptz,
  last_commit                      timestamptz,
  secondary_allow_connections      int,       -- 0 no, 2 all (read-only)
  secondary_allow_connections_desc text,
  server_read                      text,
  first_seen_at                    timestamptz NOT NULL,
  snapshot_at                      timestamptz NOT NULL,
  PRIMARY KEY (instance_id, link_guid)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_georepl_sample (
  instance_id          int NOT NULL,
  link_guid            text NOT NULL,
  snapshot_at          timestamptz NOT NULL,
  role                 int,
  replication_state    int,
  replication_lag_sec  int,
  unsent_s             numeric,
  ack_age_s            int,
  last_replication     timestamptz,
  last_commit          timestamptz,
  PRIMARY KEY (instance_id, link_guid, snapshot_at)
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_georepl_sample_at_idx ON pgvigil.mssql_georepl_sample (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_georepl_events (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  link_guid     text NOT NULL,
  at            timestamptz NOT NULL,   -- the read that saw the change
  prev_read_at  timestamptz,            -- the read before it: the change happened between the two
  kind          text NOT NULL CHECK (kind IN ('added', 'removed', 'role', 'partner', 'state')),
  old_value     text,
  new_value     text,
  partner       text,                   -- server/database at the read
  PRIMARY KEY (instance_id, link_guid, at, kind)
);
CREATE INDEX IF NOT EXISTS mssql_georepl_events_at_idx ON pgvigil.mssql_georepl_events (at);

INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('georepl_data_loss', 'Geo-replication: a primary''s replication lag or unsent window', 'minutes', 'over', 1, 5, '{root,tag}', 1440)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

-- payload (internal/mssql/georepl.go): one 'read' row first (server_read, database_name, links), then one 'link' row
-- per link (the view's twelve columns, unsent_s, ack_age_s). An older read imported late stores its samples only.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_georepl(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows   jsonb := pgvigil.mssql_rows(p_payload);
  v_read   jsonb;
  v_newest boolean;
  v_prev   timestamptz;
BEGIN
  SELECT r INTO v_read FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'read' LIMIT 1;
  IF v_read IS NULL THEN
    RAISE EXCEPTION 'import_mssql_georepl: the payload has no read row';
  END IF;
  v_newest := pgvigil.mssql_hadr_read(p_instance_id, 'mssql_georepl', p_snapshot_at,
                (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'link'));

  PERFORM pgvigil.ensure_month_partition('mssql_georepl_sample', p_snapshot_at);
  INSERT INTO pgvigil.mssql_georepl_sample (instance_id, link_guid, snapshot_at, role, replication_state, replication_lag_sec,
      unsent_s, ack_age_s, last_replication, last_commit)
  SELECT p_instance_id, r->>'link_guid', p_snapshot_at, (r->>'role')::int, (r->>'replication_state')::int,
         (r->>'replication_lag_sec')::int, (r->>'unsent_s')::numeric, (r->>'ack_age_s')::int,
         (r->>'last_replication')::timestamptz, (r->>'last_commit')::timestamptz
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'link' AND r->>'link_guid' IS NOT NULL
  ON CONFLICT (instance_id, link_guid, snapshot_at) DO NOTHING;   -- a re-run of one read

  IF NOT v_newest THEN
    RETURN;   -- an older read imported late: its samples are history, the current state stays the newer read's
  END IF;
  SELECT g.snapshot_at INTO v_prev FROM pgvigil.mssql_georepl_read g WHERE g.instance_id = p_instance_id;

  -- the changes since the read before, each once (a re-run of one read finds the state already its own)
  INSERT INTO pgvigil.mssql_georepl_events (instance_id, link_guid, at, prev_read_at, kind, old_value, new_value, partner)
  SELECT p_instance_id, r->>'link_guid', p_snapshot_at, v_prev, e.kind, e.old_value, e.new_value,
         concat_ws('/', r->>'partner_server', r->>'partner_database')
    FROM jsonb_array_elements(v_rows) r
    LEFT JOIN pgvigil.mssql_georepl_state s ON s.instance_id = p_instance_id AND s.link_guid = r->>'link_guid'
    CROSS JOIN LATERAL (VALUES
      ('added',   NULL::text, r->>'role_desc', s.link_guid IS NULL),
      ('role',    s.role_desc, r->>'role_desc', s.link_guid IS NOT NULL AND s.role IS DISTINCT FROM (r->>'role')::int),
      ('partner', concat_ws('/', s.partner_server, s.partner_database), concat_ws('/', r->>'partner_server', r->>'partner_database'),
                  s.link_guid IS NOT NULL AND (lower(s.partner_server) IS DISTINCT FROM lower(r->>'partner_server')
                                               OR lower(s.partner_database) IS DISTINCT FROM lower(r->>'partner_database'))),
      ('state',   s.replication_state_desc, r->>'replication_state_desc',
                  s.link_guid IS NOT NULL AND s.replication_state IS DISTINCT FROM (r->>'replication_state')::int)
    ) AS e(kind, old_value, new_value, happened)
   WHERE r->>'kind' = 'link' AND r->>'link_guid' IS NOT NULL AND e.happened AND s.snapshot_at IS DISTINCT FROM p_snapshot_at
  ON CONFLICT DO NOTHING;
  INSERT INTO pgvigil.mssql_georepl_events (instance_id, link_guid, at, prev_read_at, kind, old_value, partner)
  SELECT p_instance_id, s.link_guid, p_snapshot_at, v_prev, 'removed', s.role_desc, concat_ws('/', s.partner_server, s.partner_database)
    FROM pgvigil.mssql_georepl_state s
   WHERE s.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'link' AND r->>'link_guid' = s.link_guid)
  ON CONFLICT DO NOTHING;

  DELETE FROM pgvigil.mssql_georepl_state s
   WHERE s.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'link' AND r->>'link_guid' = s.link_guid);
  INSERT INTO pgvigil.mssql_georepl_state AS s (instance_id, link_guid, partner_server, partner_database, role, role_desc,
      replication_state, replication_state_desc, state_since, replication_lag_sec, unsent_s, ack_age_s, last_replication,
      last_commit, secondary_allow_connections, secondary_allow_connections_desc, server_read, first_seen_at, snapshot_at)
  SELECT p_instance_id, r->>'link_guid', r->>'partner_server', r->>'partner_database', (r->>'role')::int, r->>'role_desc',
         (r->>'replication_state')::int, r->>'replication_state_desc', p_snapshot_at, (r->>'replication_lag_sec')::int,
         (r->>'unsent_s')::numeric, (r->>'ack_age_s')::int, (r->>'last_replication')::timestamptz, (r->>'last_commit')::timestamptz,
         (r->>'secondary_allow_connections')::int, r->>'secondary_allow_connections_desc', v_read->>'server_read', p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'link' AND r->>'link_guid' IS NOT NULL
  ON CONFLICT (instance_id, link_guid) DO UPDATE SET
      partner_server = EXCLUDED.partner_server, partner_database = EXCLUDED.partner_database, role = EXCLUDED.role,
      role_desc = EXCLUDED.role_desc, replication_state = EXCLUDED.replication_state,
      replication_state_desc = EXCLUDED.replication_state_desc,
      state_since = CASE WHEN s.replication_state IS DISTINCT FROM EXCLUDED.replication_state THEN EXCLUDED.state_since ELSE s.state_since END,
      replication_lag_sec = EXCLUDED.replication_lag_sec, unsent_s = EXCLUDED.unsent_s, ack_age_s = EXCLUDED.ack_age_s,
      last_replication = EXCLUDED.last_replication, last_commit = EXCLUDED.last_commit,
      secondary_allow_connections = EXCLUDED.secondary_allow_connections,
      secondary_allow_connections_desc = EXCLUDED.secondary_allow_connections_desc,
      server_read = EXCLUDED.server_read, snapshot_at = EXCLUDED.snapshot_at;

  INSERT INTO pgvigil.mssql_georepl_read AS g (instance_id, snapshot_at, server_read, database_name, links)
  VALUES (p_instance_id, p_snapshot_at, v_read->>'server_read', v_read->>'database_name', coalesce((v_read->>'links')::int, 0))
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, server_read = EXCLUDED.server_read,
      database_name = EXCLUDED.database_name, links = EXCLUDED.links;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- G2: failover groups (Azure Resource Manager)
CREATE TABLE IF NOT EXISTS pgvigil.mssql_failover_groups (
  server_key         text NOT NULL,          -- subscription/resource group/server, lower case
  group_name         text NOT NULL,
  role               text,                   -- Primary | Secondary (this server's)
  replication_state  text,
  secondary_type     text,                   -- Geo | Standby (a Standby secondary takes no reads)
  rw_policy          text,                   -- Manual | Automatic
  grace_minutes      numeric,                -- failoverWithDataLossGracePeriodMinutes (Automatic only)
  ro_policy          text,                   -- Disabled | Enabled
  ro_target          text,
  partners           jsonb NOT NULL DEFAULT '[]',   -- [{server, location, role}]
  databases          jsonb NOT NULL DEFAULT '[]',   -- the databases' names
  cloud              text,
  read_by            int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL,
  snapshot_at        timestamptz NOT NULL,
  PRIMARY KEY (server_key, group_name)
);
CREATE TABLE IF NOT EXISTS pgvigil.mssql_failover_group_reads (
  server_key   text PRIMARY KEY,
  snapshot_at  timestamptz NOT NULL,
  read_by      int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL
);
CREATE TABLE IF NOT EXISTS pgvigil.mssql_failover_group_events (
  server_key    text NOT NULL,
  group_name    text NOT NULL,
  at            timestamptz NOT NULL,   -- the read that saw the change; an operation's own time for an Activity Log row
  kind          text NOT NULL CHECK (kind IN ('added', 'removed', 'role', 'policy', 'partner', 'operation')),
  -- the database whose read saw it: the events are the SERVER's, so removing that instance keeps them (SET NULL)
  instance_id   int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL,
  prev_read_at  timestamptz,
  old_value     text,                   -- an operation: its newest status
  new_value     text,
  event_id      text,                   -- an operation: its correlationId (one row per operation, however many events)
  last_at       timestamptz             -- an operation: its newest event's time (at = its first event's)
);
-- a change seen by a read once; an operation once per correlationId
CREATE UNIQUE INDEX IF NOT EXISTS mssql_failover_group_events_seen ON pgvigil.mssql_failover_group_events (server_key, group_name, at, kind)
  WHERE kind <> 'operation';
CREATE UNIQUE INDEX IF NOT EXISTS mssql_failover_group_events_op ON pgvigil.mssql_failover_group_events (server_key, event_id)
  WHERE kind = 'operation';
CREATE INDEX IF NOT EXISTS mssql_failover_group_events_at_idx ON pgvigil.mssql_failover_group_events (at);

-- payload (internal/mssql/failovergroups.go): one 'read' row (server_key, cloud), 'group' rows, 'operation' rows (the
-- Activity Log's failovers: event_id, at, operation, status, group_name) and maybe one 'collector_error' row (the
-- Activity Log refused: the groups were read). The server's own lock; an older read of the server stores its
-- operations only.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_failover_groups(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := pgvigil.mssql_rows(p_payload);
  v_key  text;
  v_last timestamptz;
BEGIN
  SELECT lower(r->>'server_key') INTO v_key FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'read' LIMIT 1;
  IF v_key IS NULL OR v_key = '' THEN
    RAISE EXCEPTION 'import_mssql_failover_groups: the payload has no read row with the server';
  END IF;
  PERFORM pgvigil.mssql_hadr_read(p_instance_id, 'mssql_failover_groups', p_snapshot_at,
            (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'group'));
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.mssql_failover_groups'), hashtext(v_key));

  -- the Activity Log's operations: one row per correlationId (its Started, Accepted and Succeeded events are one
  -- operation), at its first event's time, with its newest status; a later read that sees more of its events moves the
  -- first time back and the status forward (the log's two-hour window is read every 5 minutes)
  INSERT INTO pgvigil.mssql_failover_group_events AS e (server_key, group_name, at, kind, instance_id, new_value, old_value, event_id, last_at)
  SELECT v_key, o.group_name, o.first_at, 'operation', p_instance_id, o.operation, o.status, o.corr, o.last_at
    FROM (SELECT coalesce(r->>'correlation_id', r->>'event_id') AS corr,
                 min((r->>'at')::timestamptz) AS first_at, max((r->>'at')::timestamptz) AS last_at,
                 (array_agg(coalesce(r->>'group_name', '') ORDER BY (r->>'at')::timestamptz))[1] AS group_name,
                 (array_agg(r->>'operation' ORDER BY (r->>'at')::timestamptz))[1] AS operation,
                 (array_agg(r->>'status' ORDER BY (r->>'at')::timestamptz DESC))[1] AS status
            FROM jsonb_array_elements(v_rows) r
           WHERE r->>'kind' = 'operation' AND r->>'at' IS NOT NULL AND coalesce(r->>'correlation_id', r->>'event_id') IS NOT NULL
           GROUP BY 1) o
  ON CONFLICT (server_key, event_id) WHERE kind = 'operation' DO UPDATE
    SET at = least(e.at, EXCLUDED.at),
        old_value = CASE WHEN EXCLUDED.last_at >= e.last_at THEN EXCLUDED.old_value ELSE e.old_value END,
        last_at = greatest(e.last_at, EXCLUDED.last_at);

  SELECT g.snapshot_at INTO v_last FROM pgvigil.mssql_failover_group_reads g WHERE g.server_key = v_key;
  IF v_last IS NOT NULL AND v_last >= p_snapshot_at THEN
    RETURN;   -- an older (or the same) read of the server: the newer one stands
  END IF;

  INSERT INTO pgvigil.mssql_failover_group_events (server_key, group_name, at, kind, instance_id, prev_read_at, old_value, new_value)
  SELECT v_key, r->>'group_name', p_snapshot_at, e.kind, p_instance_id, v_last, e.old_value, e.new_value
    FROM jsonb_array_elements(v_rows) r
    LEFT JOIN pgvigil.mssql_failover_groups g ON g.server_key = v_key AND g.group_name = r->>'group_name'
    CROSS JOIN LATERAL (VALUES
      ('added',   NULL::text, r->>'role', g.group_name IS NULL),
      ('role',    g.role, r->>'role', g.group_name IS NOT NULL AND g.role IS DISTINCT FROM r->>'role'),
      ('policy',  concat_ws(' ', g.rw_policy, g.grace_minutes::text), concat_ws(' ', r->>'rw_policy', (r->>'grace_minutes')::numeric::text),
                  g.group_name IS NOT NULL AND (g.rw_policy IS DISTINCT FROM r->>'rw_policy' OR g.grace_minutes IS DISTINCT FROM (r->>'grace_minutes')::numeric)),
      -- the partners without their roles (a failover flips both ends' roles: the 'role' event says it)
      ('partner', g.partners::text, r->>'partners', g.group_name IS NOT NULL AND
                  (SELECT coalesce(jsonb_agg(x - 'role' ORDER BY x->>'server'), '[]') FROM jsonb_array_elements(g.partners) x) IS DISTINCT FROM
                  (SELECT coalesce(jsonb_agg(x - 'role' ORDER BY x->>'server'), '[]') FROM jsonb_array_elements(coalesce((r->>'partners')::jsonb, '[]')) x))
    ) AS e(kind, old_value, new_value, happened)
   WHERE r->>'kind' = 'group' AND e.happened
  ON CONFLICT DO NOTHING;
  INSERT INTO pgvigil.mssql_failover_group_events (server_key, group_name, at, kind, instance_id, prev_read_at, old_value)
  SELECT v_key, g.group_name, p_snapshot_at, 'removed', p_instance_id, v_last, g.role
    FROM pgvigil.mssql_failover_groups g
   WHERE g.server_key = v_key
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'group' AND r->>'group_name' = g.group_name)
  ON CONFLICT DO NOTHING;

  DELETE FROM pgvigil.mssql_failover_groups g
   WHERE g.server_key = v_key
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'group' AND r->>'group_name' = g.group_name);
  INSERT INTO pgvigil.mssql_failover_groups AS g (server_key, group_name, role, replication_state, secondary_type, rw_policy,
      grace_minutes, ro_policy, ro_target, partners, databases, cloud, read_by, snapshot_at)
  SELECT v_key, r->>'group_name', r->>'role', r->>'replication_state', r->>'secondary_type', r->>'rw_policy',
         (r->>'grace_minutes')::numeric, r->>'ro_policy', nullif(r->>'ro_target', ''), coalesce((r->>'partners')::jsonb, '[]'),
         coalesce((r->>'databases')::jsonb, '[]'), (SELECT x->>'cloud' FROM jsonb_array_elements(v_rows) x WHERE x->>'kind' = 'read' LIMIT 1),
         p_instance_id, p_snapshot_at
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'group' AND r->>'group_name' IS NOT NULL
  ON CONFLICT (server_key, group_name) DO UPDATE SET role = EXCLUDED.role, replication_state = EXCLUDED.replication_state,
      secondary_type = EXCLUDED.secondary_type, rw_policy = EXCLUDED.rw_policy, grace_minutes = EXCLUDED.grace_minutes,
      ro_policy = EXCLUDED.ro_policy, ro_target = EXCLUDED.ro_target, partners = EXCLUDED.partners, databases = EXCLUDED.databases,
      cloud = EXCLUDED.cloud, read_by = EXCLUDED.read_by, snapshot_at = EXCLUDED.snapshot_at;
  INSERT INTO pgvigil.mssql_failover_group_reads AS x (server_key, snapshot_at, read_by) VALUES (v_key, p_snapshot_at, p_instance_id)
  ON CONFLICT (server_key) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, read_by = EXCLUDED.read_by;
END $$;

-- the findings (the engine's own view; its readers are the join's WIRING)
CREATE OR REPLACE VIEW pgvigil.mssql_georepl_findings AS
WITH lim AS (
  SELECT s.instance_id, s.link_guid, t.warn, t.crit
    FROM pgvigil.mssql_georepl_state s
    CROSS JOIN LATERAL pgvigil.pg_threshold(s.instance_id, 'georepl_data_loss') t
   WHERE s.role = 0 AND s.snapshot_at > now() - interval '5 minutes'
), held AS (   -- 0066's "for 5 minutes": every read of the last 5.5 minutes over the tier, the first 4+ minutes old, the last 2- old
  SELECT l.instance_id, l.link_guid, l.warn, l.crit,
         min(greatest(coalesce(x.replication_lag_sec, 0), coalesce(x.unsent_s, 0))) AS low_s,
         max(x.snapshot_at) AS last_at
    FROM lim l
    JOIN pgvigil.mssql_georepl_sample x ON x.instance_id = l.instance_id AND x.link_guid = l.link_guid
                                       AND x.snapshot_at > now() - interval '330 seconds'
   GROUP BY l.instance_id, l.link_guid, l.warn, l.crit
  HAVING min(x.snapshot_at) <= now() - interval '4 minutes' AND max(x.snapshot_at) >= now() - interval '2 minutes'
)
SELECT h.instance_id,
       CASE WHEN h.crit IS NOT NULL AND h.low_s > h.crit * 60 THEN 'critical' ELSE 'warning' END AS severity,
       'geo-replication data loss' AS check_name, concat_ws('/', s.partner_server, s.partner_database) AS object, h.last_at AS at,
       format('the primary''s replication lag or unsent window to %s has been over %s minute(s) for 5 minutes (%s s in the lowest read)',
              concat_ws('/', s.partner_server, s.partner_database),
              CASE WHEN h.crit IS NOT NULL AND h.low_s > h.crit * 60 THEN h.crit ELSE h.warn END, round(h.low_s)) AS detail
  FROM held h
  JOIN pgvigil.mssql_georepl_state s USING (instance_id, link_guid)
 WHERE h.warn IS NOT NULL AND h.low_s > h.warn * 60
UNION ALL
SELECT s.instance_id, 'critical', 'geo-replication suspended', concat_ws('/', s.partner_server, s.partner_database), s.snapshot_at,
       format('the link to %s is SUSPENDED (replication_state 4) in the last two reads', concat_ws('/', s.partner_server, s.partner_database))
  FROM pgvigil.mssql_georepl_state s
 WHERE s.replication_state = 4 AND s.snapshot_at > now() - interval '5 minutes'
   AND (SELECT x.replication_state FROM pgvigil.mssql_georepl_sample x
         WHERE x.instance_id = s.instance_id AND x.link_guid = s.link_guid AND x.snapshot_at < s.snapshot_at
         ORDER BY x.snapshot_at DESC LIMIT 1) = 4
UNION ALL
SELECT s.instance_id, 'warning', 'geo-replication seeding', concat_ws('/', s.partner_server, s.partner_database), s.snapshot_at,
       format('the link to %s has been %s since %s (over 60 minutes)', concat_ws('/', s.partner_server, s.partner_database),
              s.replication_state_desc, to_char(s.state_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
  FROM pgvigil.mssql_georepl_state s
 WHERE s.replication_state_desc IN ('PENDING', 'SEEDING') AND s.state_since < now() - interval '60 minutes'
   AND s.snapshot_at > now() - interval '5 minutes'
UNION ALL
SELECT e.instance_id, 'critical',
       CASE e.kind WHEN 'role' THEN 'geo-replication role changed' ELSE 'geo-replication partner changed' END,
       e.partner, e.at,
       CASE e.kind
         WHEN 'role' THEN format('the database went from %s to %s between %s and %s (a failover; planned or forced is not told by the view). Shown for an hour.',
                                 e.old_value, e.new_value, to_char(e.prev_read_at AT TIME ZONE 'UTC', 'HH24:MI'), to_char(e.at AT TIME ZONE 'UTC', 'HH24:MI "UTC"'))
         ELSE format('the link''s partner went from %s to %s between %s and %s (a failover seen through a failover group''s listener). Shown for an hour.',
                     e.old_value, e.new_value, to_char(e.prev_read_at AT TIME ZONE 'UTC', 'HH24:MI'), to_char(e.at AT TIME ZONE 'UTC', 'HH24:MI "UTC"'))
       END
  FROM pgvigil.mssql_georepl_events e
 WHERE e.kind IN ('role', 'partner') AND e.at > now() - interval '1 hour'
UNION ALL
SELECT e.instance_id, 'warning', 'geo-replication link removed', e.partner, e.at,
       format('the link to %s (this database was %s) is gone since the read at %s. Shown for 24 hours.', e.partner, e.old_value,
              to_char(e.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
  FROM pgvigil.mssql_georepl_events e
  JOIN pgvigil.mssql_georepl_read g ON g.instance_id = e.instance_id AND g.snapshot_at >= e.at
 WHERE e.kind = 'removed' AND e.at > now() - interval '24 hours'
   AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_georepl_state s WHERE s.instance_id = e.instance_id AND s.link_guid = e.link_guid)
UNION ALL
SELECT e.instance_id, 'critical', 'failover group primary moved', e.group_name, e.at,
       format('failover group %s: this server went from %s to %s between %s and %s (a failover of the group). Shown for an hour.',
              e.group_name, e.old_value, e.new_value, to_char(e.prev_read_at AT TIME ZONE 'UTC', 'HH24:MI'), to_char(e.at AT TIME ZONE 'UTC', 'HH24:MI "UTC"'))
  FROM pgvigil.mssql_failover_group_events e
 WHERE e.kind = 'role' AND e.at > now() - interval '1 hour' AND e.instance_id IS NOT NULL;
