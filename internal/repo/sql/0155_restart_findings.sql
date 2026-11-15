-- 0155: restarts, failovers, crash restarts and build changes as events, findings and chart marks (task 404, B8:
-- Zabbix Z104 / Z105, SQLWATCH OFF#1, Prometheus WD38).
--
-- What was stored before: mssql_instance.started_at and product_version (0063) and instance_state.postmaster_start
-- (0001), each overwritten at every read, and PostgreSQL's version_history (0035). No restart history, no finding.
--
--   instance_events        one row per event an UPDATE of a read row shows, written by AFTER UPDATE triggers:
--     mssql_instance  the start moved by over 120 s (the start is SYSUTCDATETIME() less the ticks since the start, read
--                     by instance.go, so a host's clock step moves it too): another machine = 'failover' (the physical
--                     node, ComputerNamePhysicalNetBIOS, where both reads carry it: a failover cluster keeps its
--                     virtual MachineName; else machine_name: the AG listener's new replica); on the same machine a
--                     new start after the read before = 'restart', any other move no event (a clock step: the lead's
--                     11-14 22:5x, F16's clock rule (a)); product_version changed = 'build' (old and new with the
--                     update level).
--     instance_state  postmaster_start moved (exact: no tolerance), the read newer than the stored one: later on the
--                     same server_addr = 'restart'; earlier, or on another server_addr = 'failover' (a replica that
--                     started before it was promoted).
--     dbstats_last    0011's restart epoch rose with the postmaster start unchanged, the commits fell, and stats_reset
--                     unchanged or NULL = 'crash restart' (the postmaster stays up through crash recovery; a manual
--                     pg_stat_reset moves stats_reset to a time; PostgreSQL 15 and later drop every statistics entry
--                     at a crash, so it reads NULL; on 14 and older a crash moves it too and is missed here - the log's
--                     pg_crashes, 0103, still names it). One event per read: every database's row of that read has
--                     one key (instance, kind, at).
--     'at' is the new start when it is after the read before (a restart, a build that came with it), else the read
--     that saw it (a failover onto a node already up, a build through it, a crash restart: between that read and the
--     one before): the lead's 11-14 22:5x, F17 (a) - a node up for days is not dated days back. prev_at is the read
--     before, seen_at the read that saw it. A first read is an INSERT and
--     writes nothing: a new instance never reads as restarted. The events keep 365 days (the longest chart range):
--     purge()'s line is in the join file. A later migration that rewrites mssql_instance.started_at / product_version
--     or instance_state.postmaster_start disables these triggers first (ALTER TABLE ... DISABLE TRIGGER), or every
--     instance gets an event.
--   instance_event_list    instance_events and PostgreSQL's version_history (kind 'build', at its applied_at when that is
--                          within a day of the read that saw it, else that read; an engine version row of the AWS read
--                          left out beside the server's own row of the same change) as one list
--   instance_event_words(kind, engine, old, new)   the event's words, for the findings and the chart marks
--   restart_findings       info, 24 hours after the event: 'instance restarted', 'instance failed over', 'crash restart',
--                          'build changed' (both engines), in pgvigil.findings' columns (the arm is in the join file);
--                          a crash restart the server log's pg_crashes (0103) already reports between the two reads is
--                          left out (one finding, the log's, which the Summary acknowledges)
SET LOCAL lock_timeout = '20s';

CREATE TABLE IF NOT EXISTS pgvigil.instance_events (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  at           timestamptz NOT NULL,
  kind         text NOT NULL CHECK (kind IN ('restart', 'failover', 'crash restart', 'build')),
  old_value    text,
  new_value    text,
  source       text NOT NULL,
  seen_at      timestamptz NOT NULL,
  prev_at      timestamptz,
  PRIMARY KEY (instance_id, kind, at)
);
ALTER TABLE pgvigil.instance_events ADD COLUMN IF NOT EXISTS prev_at timestamptz;

-- the physical node of a failover cluster instance (SERVERPROPERTY('ComputerNamePhysicalNetBIOS'), instance.go: WIRING);
-- 0063's import below stores it
ALTER TABLE pgvigil.mssql_instance ADD COLUMN IF NOT EXISTS physical_machine text;

-- 0063's import, whole, with its two marked changes (the physical node)
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
      max_workers_count, scheduler_count, virtual_machine_type, started_at, physical_machine)
  VALUES (p_instance_id, p_snapshot_at, v_s->>'machine_name', v_s->>'server_name', v_s->>'instance_name', v_s->>'edition',
      (v_s->>'engine_edition')::int, v_s->>'product_version', v_s->>'product_level', v_s->>'product_update_level',
      v_s->>'product_update_reference', v_s->>'collation', (v_s->>'is_clustered')::int = 1, (v_s->>'is_hadr_enabled')::int = 1,
      (v_s->>'is_integrated_security_only')::int = 1, v_i IS NOT NULL, (v_i->>'cpu_count')::int, (v_i->>'hyperthread_ratio')::int,
      (v_i->>'physical_memory_kb')::bigint / 1024, (v_i->>'committed_target_kb')::bigint / 1024, (v_i->>'max_workers_count')::int,
      (v_i->>'scheduler_count')::int, v_i->>'virtual_machine_type', (v_i->>'started_at_utc')::timestamptz,
      nullif(v_s->>'physical_machine', ''))  -- task 404 change 1 of 2: the node the instance runs on (an FCI's)
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
      started_at = coalesce(EXCLUDED.started_at, m.started_at),
      physical_machine = coalesce(EXCLUDED.physical_machine, m.physical_machine)  -- task 404 change 2 of 2
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
CREATE INDEX IF NOT EXISTS instance_events_at_idx ON pgvigil.instance_events (at);

-- a start in words: '<host> started 2026-11-14 21:05:03 UTC'
CREATE OR REPLACE FUNCTION pgvigil.instance_event_start(p_host text, p_at timestamptz) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(nullif(p_host, '') || ' ', '') || 'started ' || to_char(p_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC'
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_instance_events() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_other boolean;
  v_kind  text;
BEGIN
  IF NEW.started_at IS NOT NULL AND OLD.started_at IS NOT NULL
     AND abs(extract(epoch FROM NEW.started_at - OLD.started_at)) > 120 THEN
    v_other := CASE WHEN NEW.physical_machine IS NOT NULL AND OLD.physical_machine IS NOT NULL
                      THEN upper(NEW.physical_machine) <> upper(OLD.physical_machine)
                    WHEN NEW.machine_name IS NOT NULL AND OLD.machine_name IS NOT NULL
                      THEN upper(NEW.machine_name) <> upper(OLD.machine_name)
                    ELSE false END;
    v_kind := CASE WHEN v_other THEN 'failover' WHEN NEW.started_at > OLD.snapshot_at THEN 'restart' END;
    IF v_kind IS NOT NULL THEN
      INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at, prev_at)
      VALUES (NEW.instance_id, CASE WHEN NEW.started_at > OLD.snapshot_at THEN NEW.started_at ELSE NEW.snapshot_at END, v_kind,
              pgvigil.instance_event_start(coalesce(OLD.physical_machine, OLD.machine_name), OLD.started_at),
              pgvigil.instance_event_start(coalesce(NEW.physical_machine, NEW.machine_name), NEW.started_at),
              'mssql_instance', NEW.snapshot_at, OLD.snapshot_at)
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;
  IF NEW.product_version IS NOT NULL AND OLD.product_version IS NOT NULL AND NEW.product_version <> OLD.product_version THEN
    INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at, prev_at)
    VALUES (NEW.instance_id,
            CASE WHEN NEW.started_at IS NOT NULL AND NEW.started_at IS DISTINCT FROM OLD.started_at AND NEW.started_at > OLD.snapshot_at
                 THEN NEW.started_at ELSE NEW.snapshot_at END,
            'build', OLD.product_version || coalesce(' ' || nullif(OLD.product_update_level, ''), ''),
            NEW.product_version || coalesce(' ' || nullif(NEW.product_update_level, ''), ''), 'mssql_instance', NEW.snapshot_at,
            OLD.snapshot_at)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS mssql_instance_events ON pgvigil.mssql_instance;
CREATE TRIGGER mssql_instance_events AFTER UPDATE ON pgvigil.mssql_instance
  FOR EACH ROW WHEN (OLD.started_at IS DISTINCT FROM NEW.started_at OR OLD.product_version IS DISTINCT FROM NEW.product_version)
  EXECUTE FUNCTION pgvigil.mssql_instance_events();

CREATE OR REPLACE FUNCTION pgvigil.pg_instance_events() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.postmaster_start IS NOT NULL AND OLD.postmaster_start IS NOT NULL THEN
    INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at, prev_at)
    VALUES (NEW.instance_id, CASE WHEN NEW.postmaster_start > OLD.snapshot_at THEN NEW.postmaster_start ELSE NEW.snapshot_at END,
            CASE WHEN NEW.postmaster_start < OLD.postmaster_start
                   OR (NEW.server_addr IS NOT NULL AND OLD.server_addr IS NOT NULL AND NEW.server_addr <> OLD.server_addr)
                 THEN 'failover' ELSE 'restart' END,
            pgvigil.instance_event_start(OLD.server_addr, OLD.postmaster_start), pgvigil.instance_event_start(NEW.server_addr, NEW.postmaster_start),
            'instance_state', NEW.snapshot_at, OLD.snapshot_at)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS pg_instance_events ON pgvigil.instance_state;
CREATE TRIGGER pg_instance_events AFTER UPDATE ON pgvigil.instance_state
  FOR EACH ROW WHEN (OLD.postmaster_start IS DISTINCT FROM NEW.postmaster_start AND NEW.snapshot_at > OLD.snapshot_at)
  EXECUTE FUNCTION pgvigil.pg_instance_events();

CREATE OR REPLACE FUNCTION pgvigil.pg_crash_events() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at, prev_at)
  VALUES (NEW.instance_id, NEW.snapshot_at, 'crash restart',
          to_char(OLD.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC',
          to_char(NEW.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC', 'dbstats_last', NEW.snapshot_at, OLD.snapshot_at)
  ON CONFLICT DO NOTHING;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS pg_crash_events ON pgvigil.dbstats_last;
CREATE TRIGGER pg_crash_events AFTER UPDATE ON pgvigil.dbstats_last
  FOR EACH ROW WHEN (NEW.epoch > OLD.epoch AND NEW.postmaster_start IS NOT NULL AND NEW.postmaster_start = OLD.postmaster_start
                     AND NEW.xact_commit < OLD.xact_commit
                     AND (NEW.stats_reset IS NULL OR NEW.stats_reset IS NOT DISTINCT FROM OLD.stats_reset))
  EXECUTE FUNCTION pgvigil.pg_crash_events();

CREATE OR REPLACE VIEW pgvigil.instance_event_list AS
SELECT e.instance_id, e.at, e.kind, e.old_value, e.new_value, e.source, e.seen_at, e.prev_at
  FROM pgvigil.instance_events e
UNION ALL
-- PostgreSQL's version changes (0035: a patch, a major upgrade, a downgrade, an Aurora patch, a rebuild, an engine
-- version), at the postmaster start the new version runs from when that is within a day of the read that saw it, else
-- that read (a build seen through a failover onto a node up for days: F17 (a)); the AWS read's 'engine version' row is
-- left out where the server's own row of the change lies within a day of it (one upgrade, one event: review finding 5)
SELECT v.instance_id, CASE WHEN v.applied_at IS NOT NULL AND v.applied_at >= v.changed_at - interval '1 day' THEN v.applied_at ELSE v.changed_at END,
       'build', v.old_value, v.new_value, 'version_history: ' || v.change, v.changed_at, NULL::timestamptz
  FROM pgvigil.version_history v
 WHERE NOT (v.change = 'engine version' AND EXISTS (
         SELECT 1 FROM pgvigil.version_history w
          WHERE w.instance_id = v.instance_id AND w.change <> 'engine version'
            AND w.changed_at BETWEEN v.changed_at - interval '1 day' AND v.changed_at + interval '1 day'));

CREATE OR REPLACE FUNCTION pgvigil.instance_event_words(p_kind text, p_engine text, p_old text, p_new text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_kind
    WHEN 'restart' THEN CASE WHEN p_engine = 'sqlserver' THEN 'SQL Server' ELSE 'PostgreSQL' END || ' restarted: ' || coalesce(p_new, '?')
                        || ' (before: ' || coalesce(p_old, '?') || ')'
    WHEN 'failover' THEN CASE WHEN p_engine = 'sqlserver' THEN 'SQL Server' ELSE 'PostgreSQL' END || ' failed over: ' || coalesce(p_new, '?')
                        || ' (before: ' || coalesce(p_old, '?') || ')'
    WHEN 'crash restart' THEN 'PostgreSQL crash restart (its statistics reset, the postmaster kept) between the reads at '
                        || coalesce(p_old, '?') || ' and ' || coalesce(p_new, '?')
    ELSE 'build changed from ' || coalesce(p_old, '?') || ' to ' || coalesce(p_new, '?')
  END
$$;

CREATE OR REPLACE VIEW pgvigil.restart_findings AS
SELECT e.instance_id, 'info'::text AS severity,
       CASE e.kind WHEN 'restart' THEN 'instance restarted' WHEN 'failover' THEN 'instance failed over'
                   WHEN 'crash restart' THEN 'crash restart' ELSE 'build changed' END AS setting,
       to_char(e.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC' AS value, true AS is_set, NULL::text AS suggested,
       'all'::text AS platforms,
       pgvigil.instance_event_words(e.kind, i.engine, e.old_value, e.new_value)
         || CASE e.kind WHEN 'build' THEN ': read the release notes of the new build; plans and settings may have changed'
                        WHEN 'crash restart' THEN ': a backend ended abnormally and the server ran crash recovery; read the server log'
                        ELSE ': caches were cold after it and every counter started again; if it was not planned, read the error log' END
         AS detail,
       'pgvigil'::text AS source, e.at
  FROM pgvigil.instance_event_list e
  JOIN pgvigil.instances i ON i.instance_id = e.instance_id AND i.is_active
 WHERE e.at > now() - interval '24 hours' AND e.at <= now() + interval '5 minutes'
   AND NOT (e.kind = 'crash restart' AND EXISTS (
         SELECT 1 FROM pgvigil.pg_crashes c
          WHERE c.instance_id = e.instance_id AND c.at > coalesce(e.prev_at, e.at - interval '1 hour') - interval '1 minute'
            AND c.at <= e.seen_at));
