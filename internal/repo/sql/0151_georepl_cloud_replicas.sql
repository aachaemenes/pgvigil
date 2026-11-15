-- 0151_georepl_cloud_replicas: task 390 (Allen's Q9, 2026-11-14 13:12: in v0.4.0). Part G (390a): Azure SQL Database's
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

INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('provider_replica_lag', 'Provider replicas: a read replica''s lag (RDS ReplicaLag, Cloud SQL replica_lag) for 10 minutes', 'minutes', 'over', 10, 30, '{root,tag,instance}', 1440)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

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
-- resource_id, engine, region, role, source_id, replica_ids, cascaded, status, repl_status, repl_note) and 'point'
-- rows (provider, resource_id, metric, unit, at, value). Each resource under its own advisory xact lock (in id order);
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

  INSERT INTO pgvigil.cloud_replicas AS c (provider, resource_id, engine, region, role, source_id, replica_ids, cascaded, status,
      repl_status, repl_note, repl_since, first_seen_at, snapshot_at, read_by)
  SELECT v_prov, n.resource_id, n.engine, n.region, n.role, n.source_id, n.replica_ids, n.role = 'replica' AND n.cascaded,
         n.status, n.repl_status, n.repl_note, p_snapshot_at, p_snapshot_at, p_snapshot_at, p_instance_id
    FROM pgvigil.cloud_replica_rows(v_rows) n
  ON CONFLICT (provider, resource_id) DO UPDATE SET
      engine = EXCLUDED.engine, region = EXCLUDED.region, role = EXCLUDED.role, source_id = EXCLUDED.source_id,
      replica_ids = EXCLUDED.replica_ids, cascaded = EXCLUDED.cascaded, status = EXCLUDED.status,
      repl_since = CASE WHEN c.repl_status IS DISTINCT FROM EXCLUDED.repl_status THEN EXCLUDED.repl_since ELSE c.repl_since END,
      repl_status = EXCLUDED.repl_status, repl_note = EXCLUDED.repl_note, snapshot_at = EXCLUDED.snapshot_at, read_by = EXCLUDED.read_by
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
END $$;

-- cloud_replica_readers: per active instance the resources its read covers - its own, its direct replicas and its
-- direct source (as the current rows name them)
CREATE OR REPLACE VIEW pgvigil.cloud_replica_readers AS
SELECT g.instance_id, g.provider, x.resource_id
  FROM pgvigil.cloud_replica_reads g
  JOIN pgvigil.instances i ON i.instance_id = g.instance_id AND i.is_active
  LEFT JOIN pgvigil.cloud_replicas c ON c.provider = g.provider AND c.resource_id = g.resource_id
 CROSS JOIN LATERAL (SELECT g.resource_id
                     UNION SELECT unnest(coalesce(c.replica_ids, '{}'))
                     UNION SELECT c.source_id WHERE coalesce(c.source_id, '') <> '') AS x(resource_id);

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
 WHERE m.warn IS NOT NULL AND m.low > m.warn * 60
UNION ALL
-- stopped: only an available replica whose replication status is reported (fold 9: blank = not reported yet), in two
-- reads (the read that saw the status and one after it)
SELECT r.instance_id, 'critical', 'provider replica stopped', c.resource_id, c.snapshot_at,
       format('the replica %s reports replication %s since %s%s', c.resource_id, c.repl_status,
              to_char(c.repl_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), coalesce(': ' || c.repl_note, ''))
  FROM pgvigil.cloud_replicas c
  JOIN pgvigil.cloud_replica_readers r ON r.provider = c.provider AND r.resource_id = c.resource_id
 WHERE c.role = 'replica' AND c.snapshot_at > now() - interval '15 minutes' AND c.snapshot_at > c.repl_since
   AND lower(c.status) IN ('available', 'runnable') AND c.repl_status <> '' AND lower(c.repl_status) NOT IN ('replicating', 'running')
UNION ALL
SELECT r.instance_id, 'warning', 'provider lag missing', c.resource_id, c.snapshot_at,
       format('the replica %s is %s and seen since %s, and the provider has given no lag datapoint for 15 minutes (%s)', c.resource_id, c.status,
              to_char(c.first_seen_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
              CASE c.provider WHEN 'aws' THEN 'CloudWatch AWS/RDS ReplicaLag' ELSE 'Cloud Monitoring database/replication/replica_lag' END)
  FROM pgvigil.cloud_replicas c
  JOIN pgvigil.cloud_replica_readers r ON r.provider = c.provider AND r.resource_id = c.resource_id
 WHERE c.role = 'replica' AND c.snapshot_at > now() - interval '15 minutes' AND c.first_seen_at < now() - interval '15 minutes'
   AND lower(c.status) IN ('available', 'runnable')
   AND NOT EXISTS (SELECT 1 FROM pgvigil.cloud_replica_sample x WHERE x.provider = c.provider AND x.resource_id = c.resource_id
                      AND x.metric = 'replica_lag' AND x.snapshot_at > now() - interval '15 minutes')
UNION ALL
SELECT r.instance_id, 'warning', 'replica promoted or detached', CASE e.kind WHEN 'promoted' THEN e.resource_id ELSE e.subject END, e.at,
       CASE e.kind
         WHEN 'promoted' THEN format('%s was a replica of %s and has no source since the read at %s (promoted, or its source deleted). Shown for 24 hours.',
                                     e.resource_id, e.old_value, to_char(e.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
         ELSE format('%s no longer lists the replica %s since the read at %s (promoted, detached or deleted). Shown for 24 hours.',
                     e.resource_id, e.subject, to_char(e.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
       END
  FROM pgvigil.cloud_replica_events e
  JOIN pgvigil.cloud_replica_readers r ON r.provider = e.provider AND r.resource_id = e.resource_id
 WHERE e.kind IN ('promoted', 'removed') AND e.at > now() - interval '24 hours'
UNION ALL
-- fold 15: the door refused or failed in 3 reads in a row (a read refused whole is 0121's 'collection failing')
SELECT g.instance_id, 'warning', 'cloud door failing', CASE g.provider WHEN 'aws' THEN 'aws replicas' ELSE 'gcp replicas' END, g.snapshot_at,
       format('%s reads in a row since %s had a refused or failed call: %s', g.door_fails,
              to_char(g.door_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), g.door_error)
  FROM pgvigil.cloud_replica_reads g
  JOIN pgvigil.instances i ON i.instance_id = g.instance_id AND i.is_active
 WHERE g.door_fails >= 3 AND g.snapshot_at > now() - interval '15 minutes';
