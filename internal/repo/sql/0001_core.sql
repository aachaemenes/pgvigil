-- 0001_core: the pgvigil repository core - instances, the collection log, and the
-- instance collection's tables. Applied by `pgvigil migrate` inside one transaction.
-- Every import function takes (instance_id, snapshot_at, payload jsonb) where payload
-- is a JSON array of rows; the collector never knows the table shapes.

CREATE TABLE IF NOT EXISTS pgvigil.instances (
  instance_id        serial PRIMARY KEY,
  name               text NOT NULL UNIQUE,
  platform           text NOT NULL,
  server_version     text,
  server_version_num int,
  is_replica         boolean,
  tags               text[] NOT NULL DEFAULT '{}',
  first_seen         timestamptz NOT NULL DEFAULT now(),
  last_seen          timestamptz NOT NULL DEFAULT now(),
  is_active          boolean NOT NULL DEFAULT true
);

-- One row per instance and collection: the last run and how it ended. This is what a
-- "data is stale" check reads (the DBADash CollectionDates idea).
CREATE TABLE IF NOT EXISTS pgvigil.collection_dates (
  instance_id   int  NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  collection    text NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  duration_ms   int,
  status        text NOT NULL,          -- ok | skipped | error
  note          text,
  PRIMARY KEY (instance_id, collection)
);

-- Errors and skips, kept for a while so a flapping collection can be seen.
CREATE TABLE IF NOT EXISTS pgvigil.collection_log (
  log_id        bigserial PRIMARY KEY,
  instance_id   int  NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  collection    text NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  duration_ms   int,
  status        text NOT NULL,
  note          text
);
CREATE INDEX IF NOT EXISTS collection_log_snapshot_idx ON pgvigil.collection_log (snapshot_at);

CREATE OR REPLACE FUNCTION pgvigil.ensure_instance(
  p_name text, p_platform text, p_server_version text, p_version_num int, p_is_replica boolean, p_tags text[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_id int;
BEGIN
  INSERT INTO pgvigil.instances AS i (name, platform, server_version, server_version_num, is_replica, tags)
  VALUES (p_name, p_platform, p_server_version, p_version_num, p_is_replica, coalesce(p_tags, '{}'))
  ON CONFLICT (name) DO UPDATE
     SET platform = EXCLUDED.platform,
         server_version = EXCLUDED.server_version,
         server_version_num = EXCLUDED.server_version_num,
         is_replica = EXCLUDED.is_replica,
         tags = EXCLUDED.tags,
         last_seen = now(),
         is_active = true
  RETURNING instance_id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.log_collection(
  p_instance_id int, p_collection text, p_snapshot_at timestamptz, p_duration_ms int, p_status text, p_note text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, duration_ms, status, note)
  VALUES (p_instance_id, p_collection, p_snapshot_at, p_duration_ms, p_status, p_note)
  ON CONFLICT (instance_id, collection) DO UPDATE
     SET snapshot_at = EXCLUDED.snapshot_at, duration_ms = EXCLUDED.duration_ms,
         status = EXCLUDED.status, note = EXCLUDED.note;
  IF p_status <> 'ok' THEN
    INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, duration_ms, status, note)
    VALUES (p_instance_id, p_collection, p_snapshot_at, p_duration_ms, p_status, p_note);
  END IF;
END $$;

-- The instance collection: a current-state row per instance, plus a history of changes
-- to the settings and extension lists (the DBADash "track configuration" idea).
CREATE TABLE IF NOT EXISTS pgvigil.instance_state (
  instance_id                int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at                timestamptz NOT NULL,
  platform                   text,
  server_version             text,
  server_version_num         int,
  is_replica                 boolean,
  postmaster_start           timestamptz,
  server_now                 timestamptz,
  time_zone                  text,
  connected_database         text,
  connected_user             text,
  server_addr                text,
  server_port                int,
  data_checksums             text,
  shared_buffers             text,
  max_connections            int,
  work_mem                   text,
  wal_level                  text,
  track_io_timing            text,
  log_min_duration_statement text,
  database_count             int,
  has_pg_stat_statements     boolean,
  has_pg_cron                boolean,
  has_pgagent                boolean,
  has_wait_sampling          boolean,
  has_log_fdw                boolean,
  extensions                 jsonb,
  non_default_settings       jsonb
);

CREATE TABLE IF NOT EXISTS pgvigil.instance_setting_history (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  changed_at    timestamptz NOT NULL,
  name          text NOT NULL,
  old_value     text,
  new_value     text
);
CREATE INDEX IF NOT EXISTS instance_setting_history_idx ON pgvigil.instance_setting_history (instance_id, changed_at);

CREATE OR REPLACE FUNCTION pgvigil.import_instance(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  r      jsonb;
  v_old  jsonb;
BEGIN
  r := p_payload -> 0;           -- one row per instance
  IF r IS NULL THEN RETURN; END IF;
  -- two imports of the same instance at once (a one-off collect beside the scheduler)
  -- would both read the same old snapshot and write the same history rows: serialise them
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_instance'), p_instance_id);

  SELECT non_default_settings INTO v_old FROM pgvigil.instance_state WHERE instance_id = p_instance_id;

  -- settings that changed since the last snapshot (added, removed or a new value)
  IF v_old IS NOT NULL THEN
    INSERT INTO pgvigil.instance_setting_history (instance_id, changed_at, name, old_value, new_value)
    SELECT p_instance_id, p_snapshot_at, coalesce(o.name, n.name), o.value, n.value
      FROM (SELECT x->>'name' AS name, x->>'value' AS value FROM jsonb_array_elements(v_old) x) o
      FULL JOIN (SELECT x->>'name' AS name, x->>'value' AS value FROM jsonb_array_elements(r->'non_default_settings') x) n
        ON o.name = n.name
     WHERE o.value IS DISTINCT FROM n.value;
  END IF;

  INSERT INTO pgvigil.instance_state AS s (
    instance_id, snapshot_at, platform, server_version, server_version_num, is_replica, postmaster_start, server_now,
    time_zone, connected_database, connected_user, server_addr, server_port, data_checksums, shared_buffers,
    max_connections, work_mem, wal_level, track_io_timing, log_min_duration_statement, database_count,
    has_pg_stat_statements, has_pg_cron, has_pgagent, has_wait_sampling, has_log_fdw, extensions, non_default_settings)
  VALUES (
    p_instance_id, p_snapshot_at, r->>'platform', r->>'server_version', (r->>'server_version_num')::int,
    (r->>'is_replica')::boolean, (r->>'postmaster_start')::timestamptz, (r->>'server_now')::timestamptz,
    r->>'time_zone', r->>'connected_database', r->>'connected_user', r->>'server_addr', (r->>'server_port')::int,
    r->>'data_checksums', r->>'shared_buffers', (r->>'max_connections')::int, r->>'work_mem', r->>'wal_level',
    r->>'track_io_timing', r->>'log_min_duration_statement', (r->>'database_count')::int,
    (r->>'has_pg_stat_statements')::boolean, (r->>'has_pg_cron')::boolean, (r->>'has_pgagent')::boolean,
    (r->>'has_wait_sampling')::boolean, (r->>'has_log_fdw')::boolean, r->'extensions', r->'non_default_settings')
  ON CONFLICT (instance_id) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, platform = EXCLUDED.platform, server_version = EXCLUDED.server_version,
    server_version_num = EXCLUDED.server_version_num, is_replica = EXCLUDED.is_replica,
    postmaster_start = EXCLUDED.postmaster_start, server_now = EXCLUDED.server_now, time_zone = EXCLUDED.time_zone,
    connected_database = EXCLUDED.connected_database, connected_user = EXCLUDED.connected_user,
    server_addr = EXCLUDED.server_addr, server_port = EXCLUDED.server_port, data_checksums = EXCLUDED.data_checksums,
    shared_buffers = EXCLUDED.shared_buffers, max_connections = EXCLUDED.max_connections, work_mem = EXCLUDED.work_mem,
    wal_level = EXCLUDED.wal_level, track_io_timing = EXCLUDED.track_io_timing,
    log_min_duration_statement = EXCLUDED.log_min_duration_statement, database_count = EXCLUDED.database_count,
    has_pg_stat_statements = EXCLUDED.has_pg_stat_statements, has_pg_cron = EXCLUDED.has_pg_cron,
    has_pgagent = EXCLUDED.has_pgagent, has_wait_sampling = EXCLUDED.has_wait_sampling, has_log_fdw = EXCLUDED.has_log_fdw,
    extensions = EXCLUDED.extensions, non_default_settings = EXCLUDED.non_default_settings;
END $$;

-- Retention: collection_log older than p_days is removed; snapshot tables get their own
-- purge as they arrive (monthly partitions dropped by pgvigil.purge, added per migration).
CREATE OR REPLACE FUNCTION pgvigil.purge(p_days int DEFAULT 30)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  DELETE FROM pgvigil.collection_log WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
