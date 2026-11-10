-- 0063: the engine of an instance, and the first SQL Server collection (mssql_instance).
--
-- pgvigil.instances.engine says which engine a row is: 'postgres' (every row so far) or 'sqlserver'. A collection
-- belongs to one engine; the collector runs only an engine's own collections on an instance, so a SQL Server
-- instance never has a row in a PostgreSQL collection's tables and the other way round. The platform column of a
-- SQL Server instance is one of sqlserver (a server someone runs), rdssqlserver, azuresqldb or azuresqlmi.
-- server_version_num on a SQL Server instance is major * 10000 + minor (16.0 = 160000), the same shape as
-- PostgreSQL's; the full build is in mssql_instance.product_version.
--
-- ensure_instance gains the engine as its seventh argument; the six-argument form stays and means 'postgres'.
-- An instance name that already exists under the other engine is refused: a name is one server, and its history
-- belongs to that engine's tables.
--
-- mssql_instance: one row per SQL Server instance, the server's own description (SERVERPROPERTY and, where the
-- login may read it, sys.dm_os_sys_info); sysinfo_read says whether the second part was readable.
-- mssql_config: sys.configurations as last read, with the previous value and the time a value in use changed;
-- is_present false = the server no longer lists the value.
--
-- The three fleet views that list EVERY active instance (versions_fleet, corruption_summary, slow_sources) are
-- re-created to list PostgreSQL instances only: versions_fleet read a SQL Server's server_version_num (160000 for
-- SQL Server 2022) as a PostgreSQL release. Every other view and page starts from a PostgreSQL collection's own
-- rows, which a SQL Server instance never has.

ALTER TABLE pgvigil.instances ADD COLUMN IF NOT EXISTS engine text NOT NULL DEFAULT 'postgres';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'instances_engine_chk' AND conrelid = 'pgvigil.instances'::regclass) THEN
    ALTER TABLE pgvigil.instances ADD CONSTRAINT instances_engine_chk CHECK (engine IN ('postgres', 'sqlserver'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.ensure_instance(
  p_name text, p_platform text, p_server_version text, p_version_num int, p_is_replica boolean, p_tags text[], p_engine text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_id int; v_have text;
BEGIN
  IF p_engine IS NULL OR p_engine NOT IN ('postgres', 'sqlserver') THEN
    RAISE EXCEPTION 'ensure_instance: unknown engine %', coalesce(p_engine, '(null)');
  END IF;
  SELECT engine INTO v_have FROM pgvigil.instances WHERE name = p_name;
  IF v_have IS NOT NULL AND v_have <> p_engine THEN
    RAISE EXCEPTION 'ensure_instance: instance % is already stored as engine %, not %; give the other server its own name', p_name, v_have, p_engine;
  END IF;
  INSERT INTO pgvigil.instances AS i (name, platform, server_version, server_version_num, is_replica, tags, engine)
  VALUES (p_name, p_platform, p_server_version, p_version_num, p_is_replica, coalesce(p_tags, '{}'), p_engine)
  ON CONFLICT (name) DO UPDATE
     SET platform = EXCLUDED.platform,
         server_version = EXCLUDED.server_version,
         server_version_num = EXCLUDED.server_version_num,
         is_replica = EXCLUDED.is_replica,
         tags = EXCLUDED.tags,
         last_seen = now(),
         is_active = true
   -- the read above is for the clear message; this is the guard: two first calls of one new name under two
   -- engines both pass the read, and the second one's update then matches no row instead of the other engine's
   WHERE i.engine = p_engine
  RETURNING instance_id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'ensure_instance: instance % is already stored as engine %, not %; give the other server its own name',
      p_name, (SELECT engine FROM pgvigil.instances WHERE name = p_name), p_engine;
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.ensure_instance(
  p_name text, p_platform text, p_server_version text, p_version_num int, p_is_replica boolean, p_tags text[])
RETURNS int LANGUAGE sql AS $$
  SELECT pgvigil.ensure_instance(p_name, p_platform, p_server_version, p_version_num, p_is_replica, p_tags, 'postgres')
$$;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_instance (
  instance_id                  int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at                  timestamptz NOT NULL,
  machine_name                 text,
  server_name                  text,
  instance_name                text,
  edition                      text,
  engine_edition               int,
  product_version              text,
  product_level                text,
  product_update_level         text,
  product_update_reference     text,
  server_collation             text,
  is_clustered                 boolean,
  is_hadr_enabled              boolean,
  is_integrated_security_only  boolean,
  sysinfo_read                 boolean NOT NULL DEFAULT false,
  cpu_count                    int,
  hyperthread_ratio            int,
  physical_memory_mb           bigint,
  committed_target_mb          bigint,
  max_workers_count            int,
  scheduler_count              int,
  virtual_machine_type         text,
  started_at                   timestamptz
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_config (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name            text NOT NULL,
  value           bigint,
  value_in_use    bigint,
  minimum         bigint,
  maximum         bigint,
  is_dynamic      boolean,
  is_advanced     boolean,
  snapshot_at     timestamptz NOT NULL,
  previous_in_use bigint,
  changed_at      timestamptz,
  is_present      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, name)
);

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_instance(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s jsonb;
  v_i jsonb;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_instance: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  SELECT r INTO v_s FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'server' LIMIT 1;
  IF v_s IS NULL THEN
    RAISE EXCEPTION 'import_mssql_instance: the payload has no server row';
  END IF;
  SELECT r INTO v_i FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'sysinfo' LIMIT 1;
  INSERT INTO pgvigil.mssql_instance AS m (instance_id, snapshot_at, machine_name, server_name, instance_name, edition, engine_edition,
      product_version, product_level, product_update_level, product_update_reference, server_collation, is_clustered, is_hadr_enabled,
      is_integrated_security_only, sysinfo_read, cpu_count, hyperthread_ratio, physical_memory_mb, committed_target_mb,
      max_workers_count, scheduler_count, virtual_machine_type, started_at)
  VALUES (p_instance_id, p_snapshot_at, v_s->>'machine_name', v_s->>'server_name', v_s->>'instance_name', v_s->>'edition',
      (v_s->>'engine_edition')::int, v_s->>'product_version', v_s->>'product_level', v_s->>'product_update_level',
      v_s->>'product_update_reference', v_s->>'collation', (v_s->>'is_clustered')::int = 1, (v_s->>'is_hadr_enabled')::int = 1,
      (v_s->>'is_integrated_security_only')::int = 1, v_i IS NOT NULL, (v_i->>'cpu_count')::int, (v_i->>'hyperthread_ratio')::int,
      (v_i->>'physical_memory_kb')::bigint / 1024, (v_i->>'committed_target_kb')::bigint / 1024, (v_i->>'max_workers_count')::int,
      (v_i->>'scheduler_count')::int, v_i->>'virtual_machine_type', (v_i->>'started_at_utc')::timestamptz)
  ON CONFLICT (instance_id) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, machine_name = EXCLUDED.machine_name, server_name = EXCLUDED.server_name,
      instance_name = EXCLUDED.instance_name, edition = EXCLUDED.edition, engine_edition = EXCLUDED.engine_edition,
      product_version = EXCLUDED.product_version, product_level = EXCLUDED.product_level,
      product_update_level = EXCLUDED.product_update_level, product_update_reference = EXCLUDED.product_update_reference,
      server_collation = EXCLUDED.server_collation, is_clustered = EXCLUDED.is_clustered, is_hadr_enabled = EXCLUDED.is_hadr_enabled,
      is_integrated_security_only = EXCLUDED.is_integrated_security_only, sysinfo_read = EXCLUDED.sysinfo_read,
      -- a read without the right to sys.dm_os_sys_info keeps what an earlier read with it stored
      cpu_count = coalesce(EXCLUDED.cpu_count, m.cpu_count), hyperthread_ratio = coalesce(EXCLUDED.hyperthread_ratio, m.hyperthread_ratio),
      physical_memory_mb = coalesce(EXCLUDED.physical_memory_mb, m.physical_memory_mb),
      committed_target_mb = coalesce(EXCLUDED.committed_target_mb, m.committed_target_mb),
      max_workers_count = coalesce(EXCLUDED.max_workers_count, m.max_workers_count),
      scheduler_count = coalesce(EXCLUDED.scheduler_count, m.scheduler_count),
      virtual_machine_type = coalesce(EXCLUDED.virtual_machine_type, m.virtual_machine_type),
      started_at = coalesce(EXCLUDED.started_at, m.started_at)
  WHERE m.snapshot_at <= EXCLUDED.snapshot_at;

  INSERT INTO pgvigil.mssql_config AS c (instance_id, name, value, value_in_use, minimum, maximum, is_dynamic, is_advanced, snapshot_at)
  SELECT p_instance_id, r->>'name', (r->>'value')::bigint, (r->>'value_in_use')::bigint, (r->>'minimum')::bigint,
         (r->>'maximum')::bigint, (r->>'is_dynamic')::int = 1, (r->>'is_advanced')::int = 1, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'config' AND r->>'name' IS NOT NULL
  ON CONFLICT (instance_id, name) DO UPDATE SET
      previous_in_use = CASE WHEN c.value_in_use IS DISTINCT FROM EXCLUDED.value_in_use THEN c.value_in_use ELSE c.previous_in_use END,
      changed_at = CASE WHEN c.value_in_use IS DISTINCT FROM EXCLUDED.value_in_use THEN EXCLUDED.snapshot_at ELSE c.changed_at END,
      value = EXCLUDED.value, value_in_use = EXCLUDED.value_in_use, minimum = EXCLUDED.minimum, maximum = EXCLUDED.maximum,
      is_dynamic = EXCLUDED.is_dynamic, is_advanced = EXCLUDED.is_advanced, snapshot_at = EXCLUDED.snapshot_at,
      is_present = true
  WHERE c.snapshot_at <= EXCLUDED.snapshot_at;

  -- a value the server no longer lists (an upgrade or a downgrade removed it) stays as last read, marked gone
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'config') THEN
    UPDATE pgvigil.mssql_config c SET is_present = false
     WHERE c.instance_id = p_instance_id AND c.is_present AND c.snapshot_at < p_snapshot_at;
  END IF;
END $$;

-- PostgreSQL instances only (the bodies of 0035, 0023 and 0025 with the engine in the WHERE)
CREATE OR REPLACE VIEW pgvigil.versions_fleet AS
SELECT i.instance_id, i.name AS instance, i.platform,
       coalesce(v.server_version_num, i.server_version_num) AS server_version_num,
       coalesce(v.server_version, st.server_version) AS server_version,
       v.aurora_version, coalesce(v.postmaster_start, st.postmaster_start) AS last_restart,
       v.engine, v.engine_version, v.engine_status, v.auto_minor_version_upgrade, v.maintenance_window, v.aws_read_at,
       (SELECT count(*) FROM pgvigil.version_pending p WHERE p.instance_id = i.instance_id AND p.is_present) AS pending_actions,
       (SELECT min(least(p.forced_apply, p.auto_applied_after, p.current_apply)) FROM pgvigil.version_pending p
         WHERE p.instance_id = i.instance_id AND p.is_present) AS next_maintenance,
       (SELECT string_agg(t.engine_version, ', ' ORDER BY t.is_major,
                                                 ARRAY(SELECT m[1]::numeric FROM regexp_matches(t.engine_version, '([0-9]+)', 'g') m), t.engine_version)
          FROM pgvigil.version_upgrade_targets t WHERE t.instance_id = i.instance_id) AS upgrade_targets,
       h.changed_at AS last_change_at, h.change AS last_change, h.old_value AS last_change_from, h.new_value AS last_change_to,
       (SELECT count(*) FROM pgvigil.database_collations c WHERE c.instance_id = i.instance_id AND c.is_present
           AND c.recorded_version <> c.actual_version) AS collation_mismatches,
       (SELECT coalesce(sum(f.outdated_dbs), 0) FROM pgvigil.extension_fleet f WHERE f.instance_id = i.instance_id) AS extensions_outdated,
       v.snapshot_at
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.instance_versions v ON v.instance_id = i.instance_id
  LEFT JOIN pgvigil.instance_state st ON st.instance_id = i.instance_id
  LEFT JOIN LATERAL (SELECT * FROM pgvigil.version_history x WHERE x.instance_id = i.instance_id
                      ORDER BY x.changed_at DESC,
                               CASE x.change WHEN 'major upgrade' THEN 0 WHEN 'downgrade' THEN 1 WHEN 'patch' THEN 2
                                             WHEN 'aurora patch' THEN 3 WHEN 'engine version' THEN 4 ELSE 5 END
                      LIMIT 1) h ON true
 WHERE i.is_active AND i.engine = 'postgres';

CREATE OR REPLACE VIEW pgvigil.corruption_summary AS
SELECT i.instance_id, i.name AS instance, i.platform, c.data_checksums, c.ignore_checksum_failure, c.zero_damaged_pages,
       (SELECT count(*) FROM pgvigil.log_events e WHERE e.instance_id = i.instance_id AND e.kind = 'corruption'
           AND e.snapshot_at > now() - interval '24 hours') AS events_24h,
       (SELECT count(*) FROM pgvigil.log_events e WHERE e.instance_id = i.instance_id AND e.kind = 'corruption'
           AND e.snapshot_at > now() - interval '7 days') AS events_7d,
       (SELECT max(e.snapshot_at) FROM pgvigil.log_events e WHERE e.instance_id = i.instance_id AND e.kind = 'corruption') AS last_event,
       (SELECT max(a.snapshot_at) FROM pgvigil.amcheck_latest a WHERE a.instance_id = i.instance_id AND a.status <> 'skipped') AS amcheck_last_run,
       (SELECT coalesce(sum(a.corrupt), 0) FROM pgvigil.amcheck_state a WHERE a.instance_id = i.instance_id) AS amcheck_corrupt,
       (SELECT coalesce(sum(a.checked), 0) FROM pgvigil.amcheck_latest a WHERE a.instance_id = i.instance_id) AS amcheck_checked,
       (SELECT count(*) FROM pgvigil.amcheck_latest a WHERE a.instance_id = i.instance_id AND a.status = 'skipped') AS amcheck_skipped,
       c.snapshot_at
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.corruption_settings c ON c.instance_id = i.instance_id
 WHERE i.is_active AND i.engine = 'postgres';

CREATE OR REPLACE VIEW pgvigil.slow_sources AS
SELECT i.instance_id, i.name AS instance, i.platform, c.collection AS reader, c.status, c.note, c.snapshot_at AS last_run,
       st.log_min_duration_statement,
       (SELECT max(e.snapshot_at) FROM pgvigil.log_events e WHERE e.instance_id = i.instance_id AND e.kind = 'slow'
           AND e.snapshot_at > now() - interval '31 days') AS last_slow_at
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.collection_dates c ON c.instance_id = i.instance_id AND c.collection IN ('logs', 'serverlog')
  LEFT JOIN pgvigil.instance_state st ON st.instance_id = i.instance_id
 WHERE i.is_active AND i.engine = 'postgres';
