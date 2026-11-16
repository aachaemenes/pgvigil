-- 0151_georepl_cloud_replicas: task 390 (decision Q9: in v0.4.0). Part G (390a): Azure SQL Database's
-- active geo-replication links as each database sees them (mssql_georepl). Part P (390b, below the G2 section): the
-- provider replica metrics of RDS and Cloud SQL. DBA Dash reads none of this (4.25.0): the shape is its availability
-- group grid, as pgvigil's AG rows already follow it (0066).
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
-- import_pg_threshold refuses an instance level for a SQL Server instance, which 0142 teaches). 0143's ag_data_loss
-- (decision Q2) is not on this file's base; when 0142 / 0143 join, the key gains engines '{sqlserver}' and the instance
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

-- ---------------------------------------------------------------------------------------------------------------
-- Part P (390b): the provider replica metrics of Amazon RDS (P1: DescribeDBInstances, CloudWatch ReplicaLag) and Google
-- Cloud SQL (P2: Cloud SQL Admin instances.get, Cloud Monitoring replica_lag / replication state / replica_byte_lag),
-- read through the providers' APIs by internal/cloudrepl (collection cloud_replicas, both engines).
--   cloud_replicas         current; one row per provider resource (provider, resource_id = the RDS identifier or
--                          project:instance, lower case) WHOEVER reads it: a source and its replica both monitored read
--                          the same chain and store it once. source_id and replica_ids are the truth (each lag is to the
--                          DIRECT upstream); cascaded marks a replica that is also a source. A row moves only on a read
--                          newer than its own (an older read imported late changes nothing).
--   cloud_replica_reads    per reading instance its newest read: its own resource (the instance's aws: / gcp: block) and
--                          the door's failed reads in a row with the newest sentence (fold 15).
--   cloud_replica_sample   monthly partitions; one row per datapoint (provider, resource_id, metric, snapshot_at = the
--                          datapoint's time): a window read twice adds nothing, a newer read's value replaces an older
--                          read's (CloudWatch revises a minute's Maximum); instance_id is the instance whose read wrote it.
--   cloud_replica_events   a replica added to or removed from a known source, a replica promoted (it had a source and has
--                          none), a status change (the instance's own status, or its replication status once reported).
--   cloud_replica_findings (instance_id, severity, check_name, object, at, detail) on EVERY instance that reads the
--                          resource (its own, its replicas, its source); its arm in pgvigil.findings, alerting and the
--                          Summary's HA cell, and the purge lines (the partition parent cloud_replica_sample; the events
--                          past 24 hours' window), are the join's WIRING, as part G's.
-- The threshold: pg_threshold_keys 'provider_replica_lag' (minutes: the keys' units are minutes, hours and days; warning
-- 10 = 600 s, critical 30 = 1800 s, pgvigil's own, above AWS's idle 'up to five minutes'); root, tag and instance (an
-- instance level on a SQL Server instance is refused by this base's import_pg_threshold until 0142 joins: WIRING with
-- the engines '{postgres,sqlserver}').

CREATE TABLE IF NOT EXISTS pgvigil.cloud_replicas (
  provider       text NOT NULL CHECK (provider IN ('aws', 'gcp')),
  resource_id    text NOT NULL,
  engine         text,
  region         text,
  role           text NOT NULL CHECK (role IN ('source', 'replica', 'standalone')),
  source_id      text,                       -- a replica's direct upstream
  replica_ids    text[] NOT NULL DEFAULT '{}',
  cascaded       boolean NOT NULL DEFAULT false,
  status         text,                       -- DBInstanceStatus (available ...) or the Cloud SQL state (RUNNABLE ...)
  repl_status    text NOT NULL DEFAULT '',   -- replicating | error | stopped | terminated (RDS StatusInfos); Running | Stopped | Error (Cloud SQL); '' = not reported yet
  repl_note      text,                       -- the provider's words when it is not normal
  repl_since     timestamptz NOT NULL,       -- the read that first saw repl_status
  status_since   timestamptz NOT NULL,       -- the read that first saw status (part b finding 5: 'lag missing' counts from 'available')
  first_seen_at  timestamptz NOT NULL,
  snapshot_at    timestamptz NOT NULL,       -- the newest read that wrote the row
  read_by        int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL,
  PRIMARY KEY (provider, resource_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.cloud_replica_reads (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  provider      text NOT NULL,
  resource_id   text NOT NULL,              -- the instance's own resource
  snapshot_at   timestamptz NOT NULL,
  resources     int NOT NULL,               -- the resources this read named (0: the topology was refused)
  door_fails    int NOT NULL DEFAULT 0,     -- reads in a row with a refused or failed call
  door_error    text,                       -- the newest such read's sentence
  door_since    timestamptz                 -- the first of them
);

CREATE TABLE IF NOT EXISTS pgvigil.cloud_replica_sample (
  provider     text NOT NULL,
  resource_id  text NOT NULL,
  metric       text NOT NULL CHECK (metric IN ('replica_lag', 'replica_byte_lag')),
  snapshot_at  timestamptz NOT NULL,        -- the datapoint's time
  value        double precision NOT NULL,
  unit         text NOT NULL,               -- s | bytes
  instance_id  int,                         -- the instance whose read wrote it
  read_at      timestamptz NOT NULL,        -- that read's time: a newer read's value wins
  PRIMARY KEY (provider, resource_id, metric, snapshot_at)
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS cloud_replica_sample_at_idx ON pgvigil.cloud_replica_sample (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.cloud_replica_events (
  provider      text NOT NULL,
  resource_id   text NOT NULL,
  at            timestamptz NOT NULL,       -- the read that saw the change
  prev_read_at  timestamptz,                -- the resource's read before it: the change happened between the two
  kind          text NOT NULL CHECK (kind IN ('added', 'removed', 'promoted', 'status')),
  subject       text NOT NULL DEFAULT '',   -- added / removed: the replica; status: 'instance' | 'replication'
  old_value     text,
  new_value     text,
  instance_id   int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL,   -- the reading instance (the events are the resource's)
  PRIMARY KEY (provider, resource_id, at, kind, subject)
);
CREATE INDEX IF NOT EXISTS cloud_replica_events_at_idx ON pgvigil.cloud_replica_events (at);

-- P3 (task 14): the provider's own failover events of the reading instance's resource - RDS
-- DescribeEvents (category failover: RDS-EVENT-0013 started; 0015 / 0049 completed; 0050 / 0051 an activation) and
-- Cloud SQL FAILOVER operations (start; end when DONE) - each phase once. The import hands them to 404's
-- instance_events (0155) where that table exists: the provider's word wins (an RDS Multi-AZ DB instance's or a Cloud SQL
-- HA failover reads 'restart' in 0155, its standby running no engine until it takes over): a 0155 'restart' the
-- failover covers (pgvigil.cloud_failover_covers: inside [its start - 10 min, its completion + 10 min], or the completion
-- inside the read's window) becomes 'failover' (its starts kept, source '<the provider's source>: <its words>'); a 0155
-- 'failover' it covers (an RDS SQL Server Multi-AZ standby, dated at the hourly read) takes that source; a failover no
-- read saw is written at its first completion (old_value NULL, the provider's words), and a read's restart or
-- failover arriving later replaces that row. On a base without 0155 the events are stored and handed
-- over at the join's first read (WIRING: 0155 on the join; the instance_events arms of the findings and the chart marks
-- are 0155's). The events keep 14 days (RDS's own; purge's line is WIRING).
CREATE TABLE IF NOT EXISTS pgvigil.cloud_failover_events (
  provider       text NOT NULL,
  resource_id    text NOT NULL,
  at             timestamptz NOT NULL,
  phase          text NOT NULL CHECK (phase IN ('started', 'completed')),
  message        text NOT NULL,
  source         text NOT NULL,             -- rds events | cloud sql operations
  event_id       text,                      -- Cloud SQL: the operation's name
  first_read_at  timestamptz NOT NULL,
  instance_id    int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL,
  PRIMARY KEY (provider, resource_id, at, phase, message)
);
CREATE INDEX IF NOT EXISTS cloud_failover_events_at_idx ON pgvigil.cloud_failover_events (at);

INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('provider_replica_lag', 'Provider replicas: a read replica''s lag (RDS ReplicaLag, Cloud SQL replica_lag) for 10 minutes', 'minutes', 'over', 10, 30, '{root,tag,instance}', 1440)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

-- cloud_failover_covers (part b findings 2 and 6, one test for every P3 statement): a read's event at p_at, found
-- between the reads p_prev and p_seen, is the provider failover that started at p_start and completed at p_done when
-- it lies in [p_start - 10 minutes, p_done + 10 minutes] or the completion lies in its read window (p_prev, p_seen] (an
-- hourly read dating a failover onto an already-running node up to an hour after it)
CREATE OR REPLACE FUNCTION pgvigil.cloud_failover_covers(p_at timestamptz, p_prev timestamptz, p_seen timestamptz,
                                                         p_start timestamptz, p_done timestamptz)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_at BETWEEN p_start - interval '10 minutes' AND p_done + interval '10 minutes'
      OR (p_prev IS NOT NULL AND p_seen IS NOT NULL AND p_done > p_prev AND p_done <= p_seen)
$$;

-- cloud_failovers: a resource's provider failovers since p_since - one per first completion (a second completion
-- message within 15 minutes is the same one), its start the newest within 30 minutes before (started; else start is the
-- completion - 15 minutes)
CREATE OR REPLACE FUNCTION pgvigil.cloud_failovers(p_provider text, p_resource text, p_since timestamptz)
RETURNS TABLE (done timestamptz, start timestamptz, started timestamptz, message text, source text) LANGUAGE sql STABLE AS $$
  SELECT c.at, coalesce(x.started, c.at - interval '15 minutes'), x.started, c.message, c.source
    FROM pgvigil.cloud_failover_events c
   CROSS JOIN LATERAL (SELECT max(s.at) AS started FROM pgvigil.cloud_failover_events s
                        WHERE s.provider = c.provider AND s.resource_id = c.resource_id AND s.phase = 'started'
                          AND s.at <= c.at AND s.at > c.at - interval '30 minutes') x
   WHERE c.provider = p_provider AND c.resource_id = p_resource AND c.phase = 'completed' AND c.at > p_since
     AND NOT EXISTS (SELECT 1 FROM pgvigil.cloud_failover_events c2
                      WHERE c2.provider = c.provider AND c2.resource_id = c.resource_id AND c2.phase = 'completed'
                        AND c2.at < c.at AND c2.at > c.at - interval '15 minutes')
$$;

-- cloud_replica_rows: the payload's 'resource' rows, one per resource (ids lower case, replica_ids sorted)
CREATE OR REPLACE FUNCTION pgvigil.cloud_replica_rows(p_rows jsonb)
RETURNS TABLE (resource_id text, engine text, region text, role text, source_id text, replica_ids text[], cascaded boolean,
               status text, repl_status text, repl_note text) LANGUAGE sql IMMUTABLE AS $$
  SELECT DISTINCT ON (lower(r->>'resource_id')) lower(r->>'resource_id'), r->>'engine', r->>'region', r->>'role',
         nullif(lower(r->>'source_id'), ''),
         coalesce((SELECT array_agg(lower(e) ORDER BY lower(e)) FROM jsonb_array_elements_text(
                    CASE WHEN jsonb_typeof(r->'replica_ids') = 'array' THEN r->'replica_ids' ELSE '[]'::jsonb END) e), '{}'),
         coalesce((r->>'cascaded')::boolean, false), r->>'status', coalesce(r->>'repl_status', ''), nullif(r->>'repl_note', '')
    FROM jsonb_array_elements(p_rows) r
   WHERE r->>'kind' = 'resource' AND coalesce(r->>'resource_id', '') <> '' AND r->>'role' IN ('source', 'replica', 'standalone')
$$;

-- payload (internal/collect/cloud_replicas.go, internal/mssql/cloud_replicas.go): one 'read' row first (provider,
-- resource_id = the instance's own, notes = the refused calls' sentences), then 'resource' rows (provider,
-- resource_id, engine, region, role, source_id, replica_ids, cascaded, status, repl_status, repl_note), 'point'
-- rows (provider, resource_id, metric, unit, at, value) and 'failover' rows (P3: provider, resource_id, at, phase,
-- message, source, event_id). Each resource under its own advisory xact lock (in id order);
-- a resource row older than the stored one changes nothing; the datapoints are stored whatever the read's age.
CREATE OR REPLACE FUNCTION pgvigil.import_cloud_replicas(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows  jsonb := pgvigil.mssql_rows(p_payload);
  v_read  jsonb;
  v_prov  text;
  v_self  text;
  v_notes text;
  v_id    text;
  v_month timestamptz;
BEGIN
  SELECT r INTO v_read FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'read' LIMIT 1;
  v_prov := v_read->>'provider';
  v_self := lower(v_read->>'resource_id');
  IF v_prov IS NULL OR v_self IS NULL OR v_self = '' THEN
    RAISE EXCEPTION 'import_cloud_replicas: the payload has no read row with the provider and the instance''s resource';
  END IF;
  SELECT string_agg(n, '; ') INTO v_notes
    FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(v_read->'notes') = 'array' THEN v_read->'notes' ELSE '[]'::jsonb END) n
   WHERE n <> '';

  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.cloud_replica_reads'), p_instance_id);
  FOR v_id IN SELECT DISTINCT lower(r->>'resource_id') FROM jsonb_array_elements(v_rows) r
               WHERE r->>'kind' IN ('resource', 'point') AND coalesce(r->>'resource_id', '') <> '' ORDER BY 1 LOOP
    PERFORM pg_advisory_xact_lock(hashtext('pgvigil.cloud_replicas'), hashtext(v_prov || ':' || v_id));
  END LOOP;

  -- the datapoints: one row each, a newer read's value replacing an older read's
  FOR v_month IN SELECT DISTINCT date_trunc('month', (r->>'at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
                   FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'point' AND r->>'at' IS NOT NULL LOOP
    PERFORM pgvigil.ensure_month_partition('cloud_replica_sample', v_month);
  END LOOP;
  INSERT INTO pgvigil.cloud_replica_sample AS x (provider, resource_id, metric, snapshot_at, value, unit, instance_id, read_at)
  SELECT DISTINCT ON (lower(r->>'resource_id'), r->>'metric', (r->>'at')::timestamptz)
         v_prov, lower(r->>'resource_id'), r->>'metric', (r->>'at')::timestamptz, (r->>'value')::double precision,
         coalesce(r->>'unit', ''), p_instance_id, p_snapshot_at
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'point' AND coalesce(r->>'resource_id', '') <> '' AND r->>'at' IS NOT NULL AND r->>'value' IS NOT NULL
     AND r->>'metric' IN ('replica_lag', 'replica_byte_lag')
  ON CONFLICT (provider, resource_id, metric, snapshot_at) DO UPDATE
    SET value = EXCLUDED.value, unit = EXCLUDED.unit, instance_id = EXCLUDED.instance_id, read_at = EXCLUDED.read_at
    WHERE x.read_at < EXCLUDED.read_at;

  -- the changes since the resource's read before, each once (a resource row no newer than the stored one: none)
  INSERT INTO pgvigil.cloud_replica_events (provider, resource_id, at, prev_read_at, kind, subject, old_value, new_value, instance_id)
  SELECT v_prov, n.resource_id, p_snapshot_at, c.snapshot_at, e.kind, e.subject, e.old_value, e.new_value, p_instance_id
    FROM pgvigil.cloud_replica_rows(v_rows) n
    JOIN pgvigil.cloud_replicas c ON c.provider = v_prov AND c.resource_id = n.resource_id AND c.snapshot_at < p_snapshot_at
    CROSS JOIN LATERAL (
      SELECT 'added', a, NULL::text, a FROM unnest(n.replica_ids) a WHERE NOT a = ANY (c.replica_ids)
      UNION ALL
      SELECT 'removed', d, d, NULL FROM unnest(c.replica_ids) d WHERE NOT d = ANY (n.replica_ids)
      UNION ALL
      SELECT 'promoted', '', c.source_id, n.role WHERE c.role = 'replica' AND n.role <> 'replica'
      UNION ALL
      SELECT 'status', 'instance', c.status, n.status WHERE c.status IS DISTINCT FROM n.status AND n.status IS NOT NULL
      UNION ALL
      SELECT 'status', 'replication', nullif(c.repl_status, ''), n.repl_status WHERE n.repl_status <> '' AND c.repl_status IS DISTINCT FROM n.repl_status
    ) AS e(kind, subject, old_value, new_value)
  ON CONFLICT DO NOTHING;

  -- part b finding 10: a replica's blank replication status (Cloud SQL gives none without a replica_lag series) keeps
  -- the reported one, its time and words: a blank never clears 'stopped' or restarts its count
  INSERT INTO pgvigil.cloud_replicas AS c (provider, resource_id, engine, region, role, source_id, replica_ids, cascaded, status,
      repl_status, repl_note, repl_since, status_since, first_seen_at, snapshot_at, read_by)
  SELECT v_prov, n.resource_id, n.engine, n.region, n.role, n.source_id, n.replica_ids, n.role = 'replica' AND n.cascaded,
         n.status, n.repl_status, n.repl_note, p_snapshot_at, p_snapshot_at, p_snapshot_at, p_snapshot_at, p_instance_id
    FROM pgvigil.cloud_replica_rows(v_rows) n
  ON CONFLICT (provider, resource_id) DO UPDATE SET
      engine = EXCLUDED.engine, region = EXCLUDED.region, role = EXCLUDED.role, source_id = EXCLUDED.source_id,
      replica_ids = EXCLUDED.replica_ids, cascaded = EXCLUDED.cascaded, status = EXCLUDED.status,
      status_since = CASE WHEN c.status IS DISTINCT FROM EXCLUDED.status THEN EXCLUDED.status_since ELSE c.status_since END,
      repl_since = CASE WHEN EXCLUDED.repl_status = '' AND EXCLUDED.role = 'replica' THEN c.repl_since
                        WHEN c.repl_status IS DISTINCT FROM EXCLUDED.repl_status THEN EXCLUDED.repl_since ELSE c.repl_since END,
      repl_status = CASE WHEN EXCLUDED.repl_status = '' AND EXCLUDED.role = 'replica' THEN c.repl_status ELSE EXCLUDED.repl_status END,
      repl_note = CASE WHEN EXCLUDED.repl_status = '' AND EXCLUDED.role = 'replica' THEN c.repl_note ELSE EXCLUDED.repl_note END,
      snapshot_at = EXCLUDED.snapshot_at, read_by = EXCLUDED.read_by
    WHERE c.snapshot_at < EXCLUDED.snapshot_at;

  -- the instance's own read: the newest only; the door's failed reads in a row (a read with a note counts one)
  INSERT INTO pgvigil.cloud_replica_reads AS g (instance_id, provider, resource_id, snapshot_at, resources, door_fails, door_error, door_since)
  VALUES (p_instance_id, v_prov, v_self, p_snapshot_at,
          (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'resource'),
          CASE WHEN v_notes IS NULL THEN 0 ELSE 1 END, v_notes, CASE WHEN v_notes IS NOT NULL THEN p_snapshot_at END)
  ON CONFLICT (instance_id) DO UPDATE SET
      provider = EXCLUDED.provider, resource_id = EXCLUDED.resource_id, snapshot_at = EXCLUDED.snapshot_at, resources = EXCLUDED.resources,
      door_fails = CASE WHEN EXCLUDED.door_error IS NULL THEN 0 ELSE g.door_fails + 1 END,
      door_error = EXCLUDED.door_error,
      door_since = CASE WHEN EXCLUDED.door_error IS NULL THEN NULL ELSE coalesce(g.door_since, EXCLUDED.door_since) END
    WHERE g.snapshot_at < EXCLUDED.snapshot_at;

  -- P3: the instance's own provider failover phases, each once
  INSERT INTO pgvigil.cloud_failover_events (provider, resource_id, at, phase, message, source, event_id, first_read_at, instance_id)
  SELECT DISTINCT ON ((r->>'at')::timestamptz, r->>'phase', r->>'message')
         v_prov, v_self, (r->>'at')::timestamptz, r->>'phase', r->>'message', coalesce(nullif(r->>'source', ''), v_prov), nullif(r->>'event_id', ''),
         p_snapshot_at, p_instance_id
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'failover' AND lower(r->>'resource_id') = v_self AND r->>'at' IS NOT NULL AND r->>'phase' IN ('started', 'completed')
     AND coalesce(r->>'message', '') <> ''
  ON CONFLICT DO NOTHING;

  -- ... handed to 0155's instance_events, the provider's word winning (plpgsql reads instance_events only here: a base
  -- without 0155 never runs these statements). One failover per first completion (a second completion message within
  -- 15 minutes is the same one), from the newest start within 30 minutes before it (else the completion - 15 minutes);
  -- pgvigil.cloud_failover_covers decides, in every statement below, whether a read's event is that failover (part b
  -- findings 2 and 6). Look-back 14 days, the events' own keep: the join's first read hands over what is stored.
  IF to_regclass('pgvigil.instance_events') IS NOT NULL
     AND EXISTS (SELECT 1 FROM pgvigil.cloud_failover_events f
                  WHERE f.provider = v_prov AND f.resource_id = v_self AND f.at > p_snapshot_at - interval '14 days') THEN
    -- a read's restart that the failover covers becomes the failover (its starts kept; the source the provider's
    -- with the completion's words)
    WITH r AS (
      DELETE FROM pgvigil.instance_events e
       WHERE e.instance_id = p_instance_id AND e.kind = 'restart'
         AND EXISTS (SELECT 1 FROM pgvigil.cloud_failovers(v_prov, v_self, p_snapshot_at - interval '14 days') f WHERE pgvigil.cloud_failover_covers(e.at, e.prev_at, e.seen_at, f.start, f.done))
      RETURNING e.instance_id, e.at, e.old_value, e.new_value, e.seen_at, e.prev_at
    )
    INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at, prev_at)
    SELECT r.instance_id, r.at, 'failover', r.old_value, r.new_value,
           (SELECT f.source || ': ' || f.message FROM pgvigil.cloud_failovers(v_prov, v_self, p_snapshot_at - interval '14 days') f
             WHERE pgvigil.cloud_failover_covers(r.at, r.prev_at, r.seen_at, f.start, f.done)
             ORDER BY abs(extract(epoch FROM f.done - r.at)) LIMIT 1),
           r.seen_at, r.prev_at
      FROM r
    ON CONFLICT DO NOTHING;
    -- a read's own failover (0155 dates a failover onto a running node, an RDS SQL Server Multi-AZ standby, at the
    -- hourly read) the failover covers: the provider's words as its source
    UPDATE pgvigil.instance_events e
       SET source = (SELECT f.source || ': ' || f.message FROM pgvigil.cloud_failovers(v_prov, v_self, p_snapshot_at - interval '14 days') f
                      WHERE pgvigil.cloud_failover_covers(e.at, e.prev_at, e.seen_at, f.start, f.done)
                      ORDER BY abs(extract(epoch FROM f.done - e.at)) LIMIT 1)
     WHERE e.instance_id = p_instance_id AND e.kind = 'failover' AND e.old_value IS NOT NULL
       AND e.source NOT LIKE 'rds events%' AND e.source NOT LIKE 'cloud sql operations%'
       AND EXISTS (SELECT 1 FROM pgvigil.cloud_failovers(v_prov, v_self, p_snapshot_at - interval '14 days') f WHERE pgvigil.cloud_failover_covers(e.at, e.prev_at, e.seen_at, f.start, f.done));
    -- the provider's own row (no read saw that failover when it was written) goes once a read's event covers it
    DELETE FROM pgvigil.instance_events e
     WHERE e.instance_id = p_instance_id AND e.kind = 'failover' AND e.old_value IS NULL
       AND (e.source LIKE 'rds events%' OR e.source LIKE 'cloud sql operations%')
       AND EXISTS (SELECT 1 FROM pgvigil.cloud_failovers(v_prov, v_self, p_snapshot_at - interval '14 days') f JOIN pgvigil.instance_events o
                     ON o.instance_id = e.instance_id AND o.kind IN ('restart', 'failover') AND o.old_value IS NOT NULL
                    WHERE f.done = e.at AND pgvigil.cloud_failover_covers(o.at, o.prev_at, o.seen_at, f.start, f.done));
    -- a failover no read saw: at its first completion
    INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at, prev_at)
    SELECT p_instance_id, f.done, 'failover', NULL, 'the provider: ' || f.message, f.source, p_snapshot_at,
           f.started
      FROM pgvigil.cloud_failovers(v_prov, v_self, p_snapshot_at - interval '14 days') f
     WHERE NOT EXISTS (SELECT 1 FROM pgvigil.instance_events o
                        WHERE o.instance_id = p_instance_id AND o.kind IN ('restart', 'failover')
                          AND pgvigil.cloud_failover_covers(o.at, o.prev_at, o.seen_at, f.start, f.done))
    ON CONFLICT DO NOTHING;
  END IF;
END $$;

-- SQL Server's collection is mssql_cloud_replicas (every SQL Server collection's name starts mssql_): the same import
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_cloud_replicas(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  SELECT pgvigil.import_cloud_replicas(p_instance_id, p_snapshot_at, p_payload)
$$;

-- cloud_replica_readers: per active instance whose own read is fresh (part b finding 9: a door switched off, or a read
-- that stopped, reads nothing after 15 minutes) the resources its read covers - its own, its direct replicas and its
-- direct source (as the current rows name them)
CREATE OR REPLACE VIEW pgvigil.cloud_replica_readers AS
SELECT g.instance_id, g.provider, x.resource_id
  FROM pgvigil.cloud_replica_reads g
  JOIN pgvigil.instances i ON i.instance_id = g.instance_id AND i.is_active
  LEFT JOIN pgvigil.cloud_replicas c ON c.provider = g.provider AND c.resource_id = g.resource_id
 CROSS JOIN LATERAL (SELECT g.resource_id
                     UNION SELECT unnest(coalesce(c.replica_ids, '{}'))
                     UNION SELECT c.source_id WHERE coalesce(c.source_id, '') <> '') AS x(resource_id)
 WHERE g.snapshot_at > now() - interval '15 minutes';

-- the findings (their readers are the join's WIRING). A resource row older than 15 minutes (three reads missed) fires
-- nothing: the Collections page says the read is stale.
CREATE OR REPLACE VIEW pgvigil.cloud_replica_findings AS
WITH lagged AS (   -- each replica's newest lag datapoint and the 10 minutes up to it
  SELECT c.provider, c.resource_id, t.last_at, w.low, w.first_at
    FROM pgvigil.cloud_replicas c
   CROSS JOIN LATERAL (SELECT max(x.snapshot_at) AS last_at FROM pgvigil.cloud_replica_sample x
                        WHERE x.provider = c.provider AND x.resource_id = c.resource_id AND x.metric = 'replica_lag'
                          AND x.snapshot_at > now() - interval '15 minutes') t
   CROSS JOIN LATERAL (SELECT min(x.value) AS low, min(x.snapshot_at) AS first_at FROM pgvigil.cloud_replica_sample x
                        WHERE x.provider = c.provider AND x.resource_id = c.resource_id AND x.metric = 'replica_lag'
                          AND x.snapshot_at > t.last_at - interval '10 minutes' AND x.snapshot_at <= t.last_at) w
   WHERE c.role = 'replica' AND c.snapshot_at > now() - interval '15 minutes' AND t.last_at IS NOT NULL
     AND w.first_at <= t.last_at - interval '9 minutes'   -- the datapoints span the 10 minutes (one a minute)
), lim AS (
  SELECT r.instance_id, l.*, th.warn, th.crit
    FROM lagged l
    JOIN pgvigil.cloud_replica_readers r ON r.provider = l.provider AND r.resource_id = l.resource_id
   CROSS JOIN LATERAL pgvigil.pg_threshold(r.instance_id, 'provider_replica_lag') th
)
SELECT m.instance_id,
       CASE WHEN m.crit IS NOT NULL AND m.low > m.crit * 60 THEN 'critical' ELSE 'warning' END AS severity,
       'provider replica lag' AS check_name, m.resource_id AS object, m.last_at AS at,
       format('the replica %s has lagged its source by over %s minute(s) in every datapoint of the 10 minutes to %s (%s s at the lowest; the provider''s %s)',
              m.resource_id, CASE WHEN m.crit IS NOT NULL AND m.low > m.crit * 60 THEN m.crit ELSE m.warn END,
              to_char(m.last_at AT TIME ZONE 'UTC', 'HH24:MI "UTC"'), round(m.low::numeric),
              CASE m.provider WHEN 'aws' THEN 'CloudWatch ReplicaLag' ELSE 'Cloud Monitoring replica_lag' END) AS detail
  FROM lim m
 WHERE (m.warn IS NOT NULL AND m.low > m.warn * 60) OR (m.crit IS NOT NULL AND m.low > m.crit * 60)   -- part b finding 4: a critical-only tier
UNION ALL
-- stopped: only an available replica whose replication status is reported (fold 9: blank = not reported yet) and has
-- stood 5 minutes: a read at least 5 minutes after the one that first saw it (repl_since). By time, not by reads: RDS
-- itself reports 'Replication has stopped.' for about 2.5 minutes after a replica's reboot (its events, lab RP
-- 2026-11-15), and two reads a minute apart both fell inside it. A status that changes starts its 5 minutes again,
-- and so does the instance's own status: a read taken while it rebooted does not count (status_since, review 112616
-- finding 2).
SELECT r.instance_id, 'critical', 'provider replica stopped', c.resource_id, c.snapshot_at,
       format('the replica %s reports replication %s since %s%s', c.resource_id, c.repl_status,
              to_char(c.repl_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), coalesce(': ' || c.repl_note, ''))
  FROM pgvigil.cloud_replicas c
  JOIN pgvigil.cloud_replica_readers r ON r.provider = c.provider AND r.resource_id = c.resource_id
 WHERE c.role = 'replica' AND c.snapshot_at > now() - interval '15 minutes' AND c.snapshot_at >= greatest(c.repl_since, c.status_since) + interval '5 minutes'
   AND lower(c.status) IN ('available', 'runnable') AND c.repl_status <> '' AND lower(c.repl_status) NOT IN ('replicating', 'running')
UNION ALL
SELECT r.instance_id, 'warning', 'provider lag missing', c.resource_id, c.snapshot_at,
       format('the replica %s is %s since %s, and the provider has given no lag datapoint for 15 minutes (%s)', c.resource_id, c.status,
              to_char(greatest(c.first_seen_at, c.status_since) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
              CASE c.provider WHEN 'aws' THEN 'CloudWatch AWS/RDS ReplicaLag' ELSE 'Cloud Monitoring database/replication/replica_lag' END)
  FROM pgvigil.cloud_replicas c
  JOIN pgvigil.cloud_replica_readers r ON r.provider = c.provider AND r.resource_id = c.resource_id
 WHERE c.role = 'replica' AND c.snapshot_at > now() - interval '15 minutes'
   AND greatest(c.first_seen_at, c.status_since) < now() - interval '15 minutes'   -- part b finding 5: from 'available', not first sight
   AND lower(c.status) IN ('available', 'runnable')
   AND NOT EXISTS (SELECT 1 FROM pgvigil.cloud_replica_sample x WHERE x.provider = c.provider AND x.resource_id = c.resource_id
                      AND x.metric = 'replica_lag' AND x.snapshot_at > now() - interval '15 minutes')
UNION ALL
-- part b finding 8: one row per instance and object (a replica removed twice in 24 hours: its newest event)
(SELECT DISTINCT ON (r.instance_id, CASE e.kind WHEN 'promoted' THEN e.resource_id ELSE e.subject END)
       r.instance_id, 'warning', 'replica promoted or detached', CASE e.kind WHEN 'promoted' THEN e.resource_id ELSE e.subject END, e.at,
       CASE e.kind
         WHEN 'promoted' THEN format('%s was a replica of %s and has no source since the read at %s (promoted, or its source deleted). Shown for 24 hours.',
                                     e.resource_id, e.old_value, to_char(e.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
         ELSE format('%s no longer lists the replica %s since the read at %s (promoted, detached or deleted). Shown for 24 hours.',
                     e.resource_id, e.subject, to_char(e.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
       END
  FROM pgvigil.cloud_replica_events e
  JOIN pgvigil.cloud_replica_readers r ON r.provider = e.provider AND r.resource_id = e.resource_id
 WHERE e.kind IN ('promoted', 'removed') AND e.at > now() - interval '24 hours'
 ORDER BY r.instance_id, CASE e.kind WHEN 'promoted' THEN e.resource_id ELSE e.subject END, e.at DESC)
UNION ALL
-- fold 15: the door refused or failed in 3 reads in a row (a read refused whole is 0121's 'collection failing')
SELECT g.instance_id, 'warning', 'cloud door failing', CASE g.provider WHEN 'aws' THEN 'aws replicas' ELSE 'gcp replicas' END, g.snapshot_at,
       format('%s reads in a row since %s had a refused or failed call: %s', g.door_fails,
              to_char(g.door_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), g.door_error)
  FROM pgvigil.cloud_replica_reads g
  JOIN pgvigil.instances i ON i.instance_id = g.instance_id AND i.is_active
 WHERE g.door_fails >= 3 AND g.snapshot_at > now() - interval '15 minutes';

-- ---------------------------------------------------------------------------------------------------------------
-- The hours (task 390b task 7; the design's L51): cloud_replica_hour and mssql_georepl_hour in B2a-N2's settled shape
-- (0167): the UTC hour (date_trunc on the UTC wall clock); per hour the points (or reads), the TOTAL and the minimum and
-- maximum, so a window's average over hours = sum(total) / sum(points), the same as over the samples; filled by a
-- statement trigger with a transition table (cloud_replica_sample: INSERT and UPDATE, its import revising a datapoint
-- with a newer read's value; mssql_georepl_sample: INSERT, ON CONFLICT DO NOTHING) - per key its own lock in its own
-- statement under lock_timeout 5 s, the key's dirty range healed under 200 ms, then the touched hours RECOMPUTED from
-- the stored samples (never added to); a failure never fails the import (the hours merged into the key's dirty range,
-- one 'rollup failed' row in collection_log an hour at most, healed by the next trigger call of the key or by 'pgvigil
-- purge'); partitions by month without a second index (fillfactor 80), made by the trigger only when purge has not;
-- 730 days by their own hours_retention rows. Departure from 0167: no first build - 0151 makes the sample tables and the
-- hour tables together, so no stored sample predates the trigger. WIRING (as B2a-N2's patch): purge()'s last block
-- calls cloud_replica_hour_purge and mssql_georepl_hour_purge and heals each pending key; apply_roles()' owner-only
-- list gains the writers; purge's months ahead (AzureDBHourMonths' list) gains both tables.
INSERT INTO pgvigil.hours_retention (table_name, days) VALUES ('cloud_replica_hour', 730), ('mssql_georepl_hour', 730)
ON CONFLICT (table_name) DO NOTHING;

CREATE TABLE IF NOT EXISTS pgvigil.cloud_replica_hour (
  provider     text NOT NULL,
  resource_id  text NOT NULL,
  metric       text NOT NULL,
  snapshot_at  timestamptz NOT NULL,   -- the UTC hour
  points       int NOT NULL,
  total        double precision NOT NULL,
  min_value    double precision,
  max_value    double precision,
  PRIMARY KEY (provider, resource_id, metric, snapshot_at)
) PARTITION BY RANGE (snapshot_at);
CREATE TABLE IF NOT EXISTS pgvigil.cloud_replica_hour_dirty (
  provider     text NOT NULL,
  resource_id  text NOT NULL,
  from_at      timestamptz NOT NULL,
  to_at        timestamptz NOT NULL,
  why          text,
  noted_at     timestamptz NOT NULL DEFAULT now(),
  logged_at    timestamptz,
  instance_id  int REFERENCES pgvigil.instances (instance_id) ON DELETE SET NULL,   -- the import whose call failed (the log row's)
  PRIMARY KEY (provider, resource_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_georepl_hour (
  instance_id     int NOT NULL,
  link_guid       text NOT NULL,
  snapshot_at     timestamptz NOT NULL,   -- the UTC hour
  reads           int NOT NULL,
  lag_total       bigint,                 -- the sum of the reads' replication_lag_sec
  lag_counted     int,                    -- the reads that carry it (a secondary's carry none)
  lag_min         int,
  lag_max         int,
  unsent_total    numeric,
  unsent_counted  int,
  unsent_min      numeric,
  unsent_max      numeric,
  PRIMARY KEY (instance_id, link_guid, snapshot_at)
) PARTITION BY RANGE (snapshot_at);
CREATE TABLE IF NOT EXISTS pgvigil.mssql_georepl_hour_dirty (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  from_at      timestamptz NOT NULL,
  to_at        timestamptz NOT NULL,
  why          text,
  noted_at     timestamptz NOT NULL DEFAULT now(),
  logged_at    timestamptz
);

-- one month's partition of either hour table (no second index; fillfactor 80)
CREATE OR REPLACE FUNCTION pgvigil.hour_partition_0151(p_table text, p_at timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_from timestamp := date_trunc('month', p_at AT TIME ZONE 'UTC');
  v_name text := p_table || '_' || to_char(v_from, 'YYYYMM');
BEGIN
  IF p_table NOT IN ('cloud_replica_hour', 'mssql_georepl_hour') THEN
    RAISE EXCEPTION 'hour_partition_0151: % is not one of 0151''s hour tables', p_table;
  END IF;
  IF to_regclass('pgvigil.' || quote_ident(v_name)) IS NOT NULL THEN
    RETURN;
  END IF;
  BEGIN
    EXECUTE format('CREATE TABLE pgvigil.%I PARTITION OF pgvigil.%I FOR VALUES FROM (%L) TO (%L) WITH (fillfactor = 80)',
                   v_name, p_table, v_from AT TIME ZONE 'UTC', (v_from + interval '1 month') AT TIME ZONE 'UTC');
  EXCEPTION WHEN duplicate_table THEN
    NULL;   -- another importer made it first
  END;
END $$;

-- the given UTC hours of one resource recomputed from its samples, every metric (the caller holds the resource's lock)
CREATE OR REPLACE FUNCTION pgvigil.cloud_replica_hour_recompute(p_provider text, p_resource text, p_hours timestamptz[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  PERFORM pgvigil.hour_partition_0151('cloud_replica_hour', m)
     FROM (SELECT DISTINCT date_trunc('month', h AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS m FROM unnest(p_hours) h) x;
  INSERT INTO pgvigil.cloud_replica_hour AS s (provider, resource_id, metric, snapshot_at, points, total, min_value, max_value)
  SELECT p_provider, p_resource, x.metric, h.h, count(*), sum(x.value), min(x.value), max(x.value)
    FROM unnest(p_hours) h(h)
    JOIN pgvigil.cloud_replica_sample x ON x.provider = p_provider AND x.resource_id = p_resource
                                       AND x.snapshot_at >= h.h AND x.snapshot_at < h.h + interval '1 hour'
   GROUP BY x.metric, h.h
  ON CONFLICT (provider, resource_id, metric, snapshot_at) DO UPDATE SET points = EXCLUDED.points, total = EXCLUDED.total,
      min_value = EXCLUDED.min_value, max_value = EXCLUDED.max_value;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- the given UTC hours of one instance's links recomputed from its samples (the caller holds the instance's lock)
CREATE OR REPLACE FUNCTION pgvigil.mssql_georepl_hour_recompute(p_instance_id int, p_hours timestamptz[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  PERFORM pgvigil.hour_partition_0151('mssql_georepl_hour', m)
     FROM (SELECT DISTINCT date_trunc('month', h AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS m FROM unnest(p_hours) h) x;
  INSERT INTO pgvigil.mssql_georepl_hour AS s (instance_id, link_guid, snapshot_at, reads, lag_total, lag_counted, lag_min, lag_max,
      unsent_total, unsent_counted, unsent_min, unsent_max)
  SELECT p_instance_id, x.link_guid, h.h, count(*), sum(x.replication_lag_sec), count(x.replication_lag_sec), min(x.replication_lag_sec),
         max(x.replication_lag_sec), sum(x.unsent_s), count(x.unsent_s), min(x.unsent_s), max(x.unsent_s)
    FROM unnest(p_hours) h(h)
    JOIN pgvigil.mssql_georepl_sample x ON x.instance_id = p_instance_id AND x.snapshot_at >= h.h AND x.snapshot_at < h.h + interval '1 hour'
   GROUP BY x.link_guid, h.h
  ON CONFLICT (instance_id, link_guid, snapshot_at) DO UPDATE SET reads = EXCLUDED.reads, lag_total = EXCLUDED.lag_total,
      lag_counted = EXCLUDED.lag_counted, lag_min = EXCLUDED.lag_min, lag_max = EXCLUDED.lag_max, unsent_total = EXCLUDED.unsent_total,
      unsent_counted = EXCLUDED.unsent_counted, unsent_min = EXCLUDED.unsent_min, unsent_max = EXCLUDED.unsent_max;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- one key's dirty range rebuilt newest week first (the caller holds the key's lock); with a budget (ms, NULL = none)
-- the heal stops once it is spent and keeps the rest as it was read; the range is changed or removed only as it was
-- read (from, to, noted_at: a failure merged into it meanwhile keeps it whole)
CREATE OR REPLACE FUNCTION pgvigil.cloud_replica_hour_heal(p_provider text, p_resource text, p_budget_ms int DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v record; v_n int := 0; v_t0 timestamptz := clock_timestamp(); v_lo timestamptz; v_hi timestamptz; v_cut timestamptz; v_hours timestamptz[];
BEGIN
  SELECT d.from_at, d.to_at, d.noted_at, d.logged_at, d.instance_id INTO v FROM pgvigil.cloud_replica_hour_dirty d
   WHERE d.provider = p_provider AND d.resource_id = p_resource;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;
  SELECT min(x.snapshot_at), max(x.snapshot_at) INTO v_lo, v_hi FROM pgvigil.cloud_replica_sample x
   WHERE x.provider = p_provider AND x.resource_id = p_resource AND x.snapshot_at >= v.from_at AND x.snapshot_at < v.to_at;
  v_lo := date_trunc('hour', v_lo AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_hi := (date_trunc('hour', v_hi AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC';
  WHILE v_lo IS NOT NULL AND v_hi > v_lo LOOP
    v_cut := greatest(v_lo, v_hi - interval '7 days');
    SELECT array_agg(DISTINCT date_trunc('hour', x.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') INTO v_hours
      FROM pgvigil.cloud_replica_sample x
     WHERE x.provider = p_provider AND x.resource_id = p_resource AND x.snapshot_at >= v_cut AND x.snapshot_at < v_hi;
    IF v_hours IS NOT NULL THEN
      v_n := v_n + pgvigil.cloud_replica_hour_recompute(p_provider, p_resource, v_hours);
    END IF;
    v_hi := v_cut;
    IF p_budget_ms IS NOT NULL AND v_hi > v_lo AND clock_timestamp() - v_t0 >= make_interval(secs => p_budget_ms / 1000.0) THEN
      UPDATE pgvigil.cloud_replica_hour_dirty d SET to_at = v_hi, noted_at = clock_timestamp()
       WHERE d.provider = p_provider AND d.resource_id = p_resource AND d.from_at = v.from_at AND d.to_at = v.to_at AND d.noted_at = v.noted_at;
      RETURN v_n;
    END IF;
  END LOOP;
  DELETE FROM pgvigil.cloud_replica_hour_dirty d
   WHERE d.provider = p_provider AND d.resource_id = p_resource AND d.from_at = v.from_at AND d.to_at = v.to_at AND d.noted_at = v.noted_at;
  IF FOUND AND v.logged_at IS NOT NULL AND v.instance_id IS NOT NULL THEN
    INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
    VALUES (v.instance_id, 'cloud_replica_hour', now(), 'ok', format('rollup healed: %s:%s''s hours %s to %s rebuilt', p_provider, p_resource,
            to_char(v.from_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), to_char(v.to_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"')));
  END IF;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_georepl_hour_heal(p_instance_id int, p_budget_ms int DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v record; v_n int := 0; v_t0 timestamptz := clock_timestamp(); v_lo timestamptz; v_hi timestamptz; v_cut timestamptz; v_hours timestamptz[];
BEGIN
  SELECT d.from_at, d.to_at, d.noted_at, d.logged_at INTO v FROM pgvigil.mssql_georepl_hour_dirty d WHERE d.instance_id = p_instance_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;
  SELECT min(x.snapshot_at), max(x.snapshot_at) INTO v_lo, v_hi FROM pgvigil.mssql_georepl_sample x
   WHERE x.instance_id = p_instance_id AND x.snapshot_at >= v.from_at AND x.snapshot_at < v.to_at;
  v_lo := date_trunc('hour', v_lo AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_hi := (date_trunc('hour', v_hi AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC';
  WHILE v_lo IS NOT NULL AND v_hi > v_lo LOOP
    v_cut := greatest(v_lo, v_hi - interval '7 days');
    SELECT array_agg(DISTINCT date_trunc('hour', x.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') INTO v_hours
      FROM pgvigil.mssql_georepl_sample x WHERE x.instance_id = p_instance_id AND x.snapshot_at >= v_cut AND x.snapshot_at < v_hi;
    IF v_hours IS NOT NULL THEN
      v_n := v_n + pgvigil.mssql_georepl_hour_recompute(p_instance_id, v_hours);
    END IF;
    v_hi := v_cut;
    IF p_budget_ms IS NOT NULL AND v_hi > v_lo AND clock_timestamp() - v_t0 >= make_interval(secs => p_budget_ms / 1000.0) THEN
      UPDATE pgvigil.mssql_georepl_hour_dirty d SET to_at = v_hi, noted_at = clock_timestamp()
       WHERE d.instance_id = p_instance_id AND d.from_at = v.from_at AND d.to_at = v.to_at AND d.noted_at = v.noted_at;
      RETURN v_n;
    END IF;
  END LOOP;
  DELETE FROM pgvigil.mssql_georepl_hour_dirty d
   WHERE d.instance_id = p_instance_id AND d.from_at = v.from_at AND d.to_at = v.to_at AND d.noted_at = v.noted_at;
  IF FOUND AND v.logged_at IS NOT NULL THEN
    INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
    VALUES (p_instance_id, 'mssql_georepl_hour', now(), 'ok', format('rollup healed: the hours %s to %s rebuilt',
            to_char(v.from_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), to_char(v.to_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"')));
  END IF;
  RETURN v_n;
END $$;

-- a trigger call that could not write its hours: merged into the key's dirty range, one 'rollup failed' row when the
-- range is new or its last such row is an hour old
CREATE OR REPLACE FUNCTION pgvigil.cloud_replica_hour_failed(p_provider text, p_resource text, p_instance_id int, p_from timestamptz, p_to timestamptz, p_why text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_prev timestamptz; v_had boolean; v_log boolean;
BEGIN
  SELECT true, d.logged_at INTO v_had, v_prev FROM pgvigil.cloud_replica_hour_dirty d WHERE d.provider = p_provider AND d.resource_id = p_resource;
  v_log := v_had IS NULL OR v_prev IS NULL OR v_prev < now() - interval '1 hour';
  INSERT INTO pgvigil.cloud_replica_hour_dirty AS d (provider, resource_id, from_at, to_at, why, noted_at, logged_at, instance_id)
  VALUES (p_provider, p_resource, p_from, p_to, p_why, clock_timestamp(), now(), p_instance_id)
  ON CONFLICT (provider, resource_id) DO UPDATE
    SET from_at = least(d.from_at, excluded.from_at), to_at = greatest(d.to_at, excluded.to_at), noted_at = clock_timestamp(), why = excluded.why,
        logged_at = CASE WHEN v_log THEN now() ELSE d.logged_at END, instance_id = coalesce(excluded.instance_id, d.instance_id);
  IF v_log AND p_instance_id IS NOT NULL THEN
    INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
    VALUES (p_instance_id, 'cloud_replica_hour', now(), 'error',
            format('rollup failed for %s:%s''s hours %s to %s (the samples are stored; the hours are rebuilt by the next import or purge): %s',
                   p_provider, p_resource, to_char(p_from AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), to_char(p_to AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), p_why));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_georepl_hour_failed(p_instance_id int, p_from timestamptz, p_to timestamptz, p_why text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_prev timestamptz; v_had boolean; v_log boolean;
BEGIN
  SELECT true, d.logged_at INTO v_had, v_prev FROM pgvigil.mssql_georepl_hour_dirty d WHERE d.instance_id = p_instance_id;
  v_log := v_had IS NULL OR v_prev IS NULL OR v_prev < now() - interval '1 hour';
  INSERT INTO pgvigil.mssql_georepl_hour_dirty AS d (instance_id, from_at, to_at, why, noted_at, logged_at)
  VALUES (p_instance_id, p_from, p_to, p_why, clock_timestamp(), now())
  ON CONFLICT (instance_id) DO UPDATE
    SET from_at = least(d.from_at, excluded.from_at), to_at = greatest(d.to_at, excluded.to_at), noted_at = clock_timestamp(), why = excluded.why,
        logged_at = CASE WHEN v_log THEN now() ELSE d.logged_at END;
  IF v_log THEN
    INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
    VALUES (p_instance_id, 'mssql_georepl_hour', now(), 'error',
            format('rollup failed for the hours %s to %s (the samples are stored; the hours are rebuilt by the next import or purge): %s',
                   to_char(p_from AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), to_char(p_to AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), p_why));
  END IF;
END $$;

-- 'pgvigil purge' heals each pending key, one per transaction, with no budget
CREATE OR REPLACE FUNCTION pgvigil.cloud_replica_hour_heal_one(p_provider text, p_resource text)
RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.cloud_replica_hour'), hashtext(p_provider || ':' || p_resource));
  RETURN pgvigil.cloud_replica_hour_heal(p_provider, p_resource);
END $$;
CREATE OR REPLACE FUNCTION pgvigil.mssql_georepl_hour_heal_one(p_instance_id int)
RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.mssql_georepl_hour'), p_instance_id);
  RETURN pgvigil.mssql_georepl_hour_heal(p_instance_id);
END $$;

-- the triggers' bodies (0167's mssql_azuredb_hour_tg): per key in the statement's rows, lock_timeout 5 s inside that
-- key's block alone, the lock in its own statement, the dirty range healed under 200 ms, the touched hours recomputed,
-- the caller's lock_timeout back; any error caught per key and recorded under the caller's lock_timeout
CREATE OR REPLACE FUNCTION pgvigil.cloud_replica_hour_tg()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v record; v_lt text := current_setting('lock_timeout');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM n) THEN RETURN NULL; END IF;
  FOR v IN SELECT x.provider, x.resource_id, max(x.instance_id) AS instance_id,
                  array_agg(DISTINCT date_trunc('hour', x.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') AS hours
             FROM n x GROUP BY x.provider, x.resource_id ORDER BY x.provider, x.resource_id LOOP
    BEGIN
      PERFORM set_config('lock_timeout', '5s', true);
      PERFORM pg_advisory_xact_lock(hashtext('pgvigil.cloud_replica_hour'), hashtext(v.provider || ':' || v.resource_id));
      PERFORM pgvigil.cloud_replica_hour_heal(v.provider, v.resource_id, 200);
      PERFORM pgvigil.cloud_replica_hour_recompute(v.provider, v.resource_id, v.hours);
      PERFORM set_config('lock_timeout', v_lt, true);
    EXCEPTION WHEN OTHERS THEN
      BEGIN
        PERFORM set_config('lock_timeout', v_lt, true);
        PERFORM pgvigil.cloud_replica_hour_failed(v.provider, v.resource_id, v.instance_id, (SELECT min(h) FROM unnest(v.hours) h),
                                                  (SELECT max(h) FROM unnest(v.hours) h) + interval '1 hour', SQLERRM);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'cloud_replica_hour: the rollup of %:% failed and could not be recorded: %', v.provider, v.resource_id, SQLERRM;
      END;
    END;
  END LOOP;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_georepl_hour_tg()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v record; v_lt text := current_setting('lock_timeout');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM n) THEN RETURN NULL; END IF;
  FOR v IN SELECT x.instance_id, array_agg(DISTINCT date_trunc('hour', x.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') AS hours
             FROM n x GROUP BY x.instance_id ORDER BY x.instance_id LOOP
    BEGIN
      PERFORM set_config('lock_timeout', '5s', true);
      PERFORM pg_advisory_xact_lock(hashtext('pgvigil.mssql_georepl_hour'), v.instance_id);
      PERFORM pgvigil.mssql_georepl_hour_heal(v.instance_id, 200);
      PERFORM pgvigil.mssql_georepl_hour_recompute(v.instance_id, v.hours);
      PERFORM set_config('lock_timeout', v_lt, true);
    EXCEPTION WHEN OTHERS THEN
      BEGIN
        PERFORM set_config('lock_timeout', v_lt, true);
        PERFORM pgvigil.mssql_georepl_hour_failed(v.instance_id, (SELECT min(h) FROM unnest(v.hours) h),
                                                  (SELECT max(h) FROM unnest(v.hours) h) + interval '1 hour', SQLERRM);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'mssql_georepl_hour: the rollup of instance % failed and could not be recorded: %', v.instance_id, SQLERRM;
      END;
    END;
  END LOOP;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS cloud_replica_hour_ins ON pgvigil.cloud_replica_sample;
CREATE TRIGGER cloud_replica_hour_ins AFTER INSERT ON pgvigil.cloud_replica_sample
  REFERENCING NEW TABLE AS n FOR EACH STATEMENT EXECUTE FUNCTION pgvigil.cloud_replica_hour_tg();
DROP TRIGGER IF EXISTS cloud_replica_hour_upd ON pgvigil.cloud_replica_sample;
CREATE TRIGGER cloud_replica_hour_upd AFTER UPDATE ON pgvigil.cloud_replica_sample
  REFERENCING NEW TABLE AS n FOR EACH STATEMENT EXECUTE FUNCTION pgvigil.cloud_replica_hour_tg();
DROP TRIGGER IF EXISTS mssql_georepl_hour_ins ON pgvigil.mssql_georepl_sample;
CREATE TRIGGER mssql_georepl_hour_ins AFTER INSERT ON pgvigil.mssql_georepl_sample
  REFERENCING NEW TABLE AS n FOR EACH STATEMENT EXECUTE FUNCTION pgvigil.mssql_georepl_hour_tg();

-- the keys 'pgvigil purge' heals
CREATE OR REPLACE FUNCTION pgvigil.cloud_replica_hour_pending()
RETURNS TABLE (provider text, resource_id text) LANGUAGE sql STABLE AS $$
  SELECT d.provider, d.resource_id FROM pgvigil.cloud_replica_hour_dirty d ORDER BY 1, 2
$$;
CREATE OR REPLACE FUNCTION pgvigil.mssql_georepl_hour_pending()
RETURNS SETOF int LANGUAGE sql STABLE AS $$
  SELECT d.instance_id FROM pgvigil.mssql_georepl_hour_dirty d ORDER BY 1
$$;

-- the months of an hour table wholly older than its hours_retention row (730 days when absent) dropped; their names
-- returned (purge()'s last block adds them to the run's partitions_dropped: WIRING)
CREATE OR REPLACE FUNCTION pgvigil.hour_purge_0151(p_table text)
RETURNS text[] LANGUAGE plpgsql AS $$
DECLARE v_days int; v_part record; v_names text[] := '{}';
BEGIN
  IF p_table NOT IN ('cloud_replica_hour', 'mssql_georepl_hour') THEN
    RAISE EXCEPTION 'hour_purge_0151: % is not one of 0151''s hour tables', p_table;
  END IF;
  SELECT r.days INTO v_days FROM pgvigil.hours_retention r WHERE r.table_name = p_table;
  v_days := coalesce(v_days, 730);
  FOR v_part IN
    SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent = ('pgvigil.' || p_table)::regclass AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => v_days)
     ORDER BY c.relname
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    v_names := v_names || v_part.relname::text;
  END LOOP;
  RETURN v_names;
END $$;
CREATE OR REPLACE FUNCTION pgvigil.cloud_replica_hour_purge() RETURNS text[] LANGUAGE sql AS $$ SELECT pgvigil.hour_purge_0151('cloud_replica_hour') $$;
CREATE OR REPLACE FUNCTION pgvigil.mssql_georepl_hour_purge() RETURNS text[] LANGUAGE sql AS $$ SELECT pgvigil.hour_purge_0151('mssql_georepl_hour') $$;

-- cloud_replica_window: the window [p_from, p_to) of the provider's resources p_ids in the hour table's shape: the whole
-- hours [c, f) from the hours outside each resource's dirty range, the samples of the two edges [p_from, c) and
-- [max(f, c), p_to) and of each dirty range within [c, f) (a sample row: points 1, total = min = max = its value).
-- Summed, a window gives the same numbers as its samples.
CREATE OR REPLACE FUNCTION pgvigil.cloud_replica_window(p_provider text, p_ids text[], p_from timestamptz, p_to timestamptz)
RETURNS SETOF pgvigil.cloud_replica_hour LANGUAGE sql STABLE AS $$
  WITH b AS (SELECT CASE WHEN date_trunc('hour', p_from AT TIME ZONE 'UTC') = p_from AT TIME ZONE 'UTC' THEN p_from
                         ELSE (date_trunc('hour', p_from AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC' END AS c,
                    date_trunc('hour', p_to AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS f),
  dr AS (SELECT d.resource_id, date_trunc('hour', greatest(d.from_at, b.c) AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS lo,
                CASE WHEN date_trunc('hour', least(d.to_at, b.f) AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' = least(d.to_at, b.f) THEN least(d.to_at, b.f)
                     ELSE (date_trunc('hour', least(d.to_at, b.f) AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC' END AS hi
           FROM pgvigil.cloud_replica_hour_dirty d CROSS JOIN b
          WHERE d.provider = p_provider AND d.resource_id = ANY (p_ids) AND d.from_at < b.f AND d.to_at > b.c)
  SELECT h.* FROM pgvigil.cloud_replica_hour h CROSS JOIN b
   WHERE h.provider = p_provider AND h.resource_id = ANY (p_ids) AND h.snapshot_at >= b.c AND h.snapshot_at < b.f
     AND NOT EXISTS (SELECT 1 FROM dr WHERE dr.resource_id = h.resource_id AND dr.lo <= h.snapshot_at AND dr.hi > h.snapshot_at)
  UNION ALL
  SELECT x.provider, x.resource_id, x.metric, x.snapshot_at, 1, x.value, x.value, x.value FROM pgvigil.cloud_replica_sample x CROSS JOIN b
   WHERE x.provider = p_provider AND x.resource_id = ANY (p_ids)
     AND ((x.snapshot_at >= p_from AND x.snapshot_at < least(b.c, p_to)) OR (x.snapshot_at >= greatest(b.f, b.c) AND x.snapshot_at < p_to))
  UNION ALL
  SELECT x.provider, x.resource_id, x.metric, x.snapshot_at, 1, x.value, x.value, x.value FROM dr
    JOIN pgvigil.cloud_replica_sample x ON x.provider = p_provider AND x.resource_id = dr.resource_id AND x.snapshot_at >= dr.lo AND x.snapshot_at < dr.hi
$$;

-- mssql_georepl_window: the same for the instances p_ids' links (a sample row: reads 1, its values as total, min, max)
CREATE OR REPLACE FUNCTION pgvigil.mssql_georepl_window(p_ids int[], p_from timestamptz, p_to timestamptz)
RETURNS SETOF pgvigil.mssql_georepl_hour LANGUAGE sql STABLE AS $$
  WITH b AS (SELECT CASE WHEN date_trunc('hour', p_from AT TIME ZONE 'UTC') = p_from AT TIME ZONE 'UTC' THEN p_from
                         ELSE (date_trunc('hour', p_from AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC' END AS c,
                    date_trunc('hour', p_to AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS f),
  dr AS (SELECT d.instance_id, date_trunc('hour', greatest(d.from_at, b.c) AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS lo,
                CASE WHEN date_trunc('hour', least(d.to_at, b.f) AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' = least(d.to_at, b.f) THEN least(d.to_at, b.f)
                     ELSE (date_trunc('hour', least(d.to_at, b.f) AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC' END AS hi
           FROM pgvigil.mssql_georepl_hour_dirty d CROSS JOIN b
          WHERE d.instance_id = ANY (p_ids) AND d.from_at < b.f AND d.to_at > b.c)
  SELECT h.* FROM pgvigil.mssql_georepl_hour h CROSS JOIN b
   WHERE h.instance_id = ANY (p_ids) AND h.snapshot_at >= b.c AND h.snapshot_at < b.f
     AND NOT EXISTS (SELECT 1 FROM dr WHERE dr.instance_id = h.instance_id AND dr.lo <= h.snapshot_at AND dr.hi > h.snapshot_at)
  UNION ALL
  SELECT x.instance_id, x.link_guid, x.snapshot_at, 1, x.replication_lag_sec, CASE WHEN x.replication_lag_sec IS NOT NULL THEN 1 ELSE 0 END,
         x.replication_lag_sec, x.replication_lag_sec, x.unsent_s, CASE WHEN x.unsent_s IS NOT NULL THEN 1 ELSE 0 END, x.unsent_s, x.unsent_s
    FROM pgvigil.mssql_georepl_sample x CROSS JOIN b
   WHERE x.instance_id = ANY (p_ids)
     AND ((x.snapshot_at >= p_from AND x.snapshot_at < least(b.c, p_to)) OR (x.snapshot_at >= greatest(b.f, b.c) AND x.snapshot_at < p_to))
  UNION ALL
  SELECT x.instance_id, x.link_guid, x.snapshot_at, 1, x.replication_lag_sec, CASE WHEN x.replication_lag_sec IS NOT NULL THEN 1 ELSE 0 END,
         x.replication_lag_sec, x.replication_lag_sec, x.unsent_s, CASE WHEN x.unsent_s IS NOT NULL THEN 1 ELSE 0 END, x.unsent_s, x.unsent_s
    FROM dr JOIN pgvigil.mssql_georepl_sample x ON x.instance_id = dr.instance_id AND x.snapshot_at >= dr.lo AND x.snapshot_at < dr.hi
$$;
