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
-- mssql_config: sys.configurations as last read, with the previous value and the time a value in use changed.

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
  RETURNING instance_id INTO v_id;
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
      is_dynamic = EXCLUDED.is_dynamic, is_advanced = EXCLUDED.is_advanced, snapshot_at = EXCLUDED.snapshot_at
  WHERE c.snapshot_at <= EXCLUDED.snapshot_at;
END $$;
