-- 0155: restarts, failovers, crash restarts and build changes as events, findings and chart marks (task 404, B8:
-- Zabbix Z104 / Z105, SQLWATCH OFF#1, Prometheus WD38).
--
-- What was stored before: mssql_instance.started_at and product_version (0063) and instance_state.postmaster_start
-- (0001), each overwritten at every read, and PostgreSQL's version_history (0035). No restart history, no finding.
--
--   instance_events        one row per event an UPDATE of a read row shows, written by AFTER UPDATE triggers:
--     mssql_instance  the start moved by over 120 s (the start is SYSUTCDATETIME() less the ticks since the start, read
--                     by instance.go: a clock step or a read's jitter moves it by less): later on the same machine_name
--                     = 'restart'; earlier, or on another machine_name = 'failover' (the AG listener's or a cluster's new
--                     node); product_version changed = 'build' (old and new with the update level).
--     instance_state  postmaster_start moved (exact: no tolerance): later on the same server_addr = 'restart'; earlier,
--                     or on another server_addr = 'failover' (a replica that started before it was promoted).
--     dbstats_last    0011's restart epoch rose with the postmaster start unchanged, the commits fell, and stats_reset
--                     unchanged or NULL = 'crash restart' (the postmaster stays up through crash recovery; a manual
--                     pg_stat_reset moves stats_reset to a time; PostgreSQL 15 and later drop every statistics entry
--                     at a crash, so it reads NULL; on 14 and older a crash moves it too and is missed here - the log's
--                     pg_crashes, 0103, still names it). One event per read: every database's row of that read has
--                     one key (instance, kind, at).
--     'at' is the new start (a restart, a failover, a build whose start moved), else the read that saw it (a crash
--     restart: between that read and the one before; a build without a moved start). A first read is an INSERT and
--     writes nothing: a new instance never reads as restarted. The events keep 365 days (the longest chart range):
--     purge()'s line is in the join file. A later migration that rewrites mssql_instance.started_at / product_version
--     or instance_state.postmaster_start disables these triggers first (ALTER TABLE ... DISABLE TRIGGER), or every
--     instance gets an event.
--   instance_event_list    instance_events and PostgreSQL's version_history (kind 'build', at its applied_at) as one list
--   instance_event_words(kind, engine, old, new)   the event's words, for the findings and the chart marks
--   restart_findings       info, 24 hours after the event: 'instance restarted', 'instance failed over', 'crash restart',
--                          'build changed' (both engines), in pgvigil.findings' columns (the arm is in the join file)
SET LOCAL lock_timeout = '20s';

CREATE TABLE IF NOT EXISTS pgvigil.instance_events (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  at           timestamptz NOT NULL,
  kind         text NOT NULL CHECK (kind IN ('restart', 'failover', 'crash restart', 'build')),
  old_value    text,
  new_value    text,
  source       text NOT NULL,
  seen_at      timestamptz NOT NULL,
  PRIMARY KEY (instance_id, kind, at)
);
CREATE INDEX IF NOT EXISTS instance_events_at_idx ON pgvigil.instance_events (at);

-- a start in words: '<host> started 2026-11-14 21:05:03 UTC'
CREATE OR REPLACE FUNCTION pgvigil.instance_event_start(p_host text, p_at timestamptz) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(nullif(p_host, '') || ' ', '') || 'started ' || to_char(p_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC'
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_instance_events() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.started_at IS NOT NULL AND OLD.started_at IS NOT NULL
     AND abs(extract(epoch FROM NEW.started_at - OLD.started_at)) > 120 THEN
    INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at)
    VALUES (NEW.instance_id, NEW.started_at,
            CASE WHEN NEW.started_at < OLD.started_at
                   OR (NEW.machine_name IS NOT NULL AND OLD.machine_name IS NOT NULL AND upper(NEW.machine_name) <> upper(OLD.machine_name))
                 THEN 'failover' ELSE 'restart' END,
            pgvigil.instance_event_start(OLD.machine_name, OLD.started_at), pgvigil.instance_event_start(NEW.machine_name, NEW.started_at),
            'mssql_instance', NEW.snapshot_at)
    ON CONFLICT DO NOTHING;
  END IF;
  IF NEW.product_version IS NOT NULL AND OLD.product_version IS NOT NULL AND NEW.product_version <> OLD.product_version THEN
    INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at)
    VALUES (NEW.instance_id,
            CASE WHEN NEW.started_at IS NOT NULL AND NEW.started_at IS DISTINCT FROM OLD.started_at THEN NEW.started_at ELSE NEW.snapshot_at END,
            'build', OLD.product_version || coalesce(' ' || nullif(OLD.product_update_level, ''), ''),
            NEW.product_version || coalesce(' ' || nullif(NEW.product_update_level, ''), ''), 'mssql_instance', NEW.snapshot_at)
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
    INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at)
    VALUES (NEW.instance_id, NEW.postmaster_start,
            CASE WHEN NEW.postmaster_start < OLD.postmaster_start
                   OR (NEW.server_addr IS NOT NULL AND OLD.server_addr IS NOT NULL AND NEW.server_addr <> OLD.server_addr)
                 THEN 'failover' ELSE 'restart' END,
            pgvigil.instance_event_start(OLD.server_addr, OLD.postmaster_start), pgvigil.instance_event_start(NEW.server_addr, NEW.postmaster_start),
            'instance_state', NEW.snapshot_at)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS pg_instance_events ON pgvigil.instance_state;
CREATE TRIGGER pg_instance_events AFTER UPDATE ON pgvigil.instance_state
  FOR EACH ROW WHEN (OLD.postmaster_start IS DISTINCT FROM NEW.postmaster_start)
  EXECUTE FUNCTION pgvigil.pg_instance_events();

CREATE OR REPLACE FUNCTION pgvigil.pg_crash_events() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at)
  VALUES (NEW.instance_id, NEW.snapshot_at, 'crash restart',
          to_char(OLD.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC',
          to_char(NEW.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC', 'dbstats_last', NEW.snapshot_at)
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
SELECT e.instance_id, e.at, e.kind, e.old_value, e.new_value, e.source
  FROM pgvigil.instance_events e
UNION ALL
-- PostgreSQL's version changes (0035: a patch, a major upgrade, a downgrade, an Aurora patch, a rebuild, an engine
-- version), at the postmaster start the new version runs from, else the read that saw it
SELECT v.instance_id, coalesce(v.applied_at, v.changed_at), 'build', v.old_value, v.new_value, 'version_history: ' || v.change
  FROM pgvigil.version_history v;

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
 WHERE e.at > now() - interval '24 hours' AND e.at <= now() + interval '5 minutes';
