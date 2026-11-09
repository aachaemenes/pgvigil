-- 0035_versions: the versions collection (phase 2, task 49).
--   instance_versions        the current version row per instance: server_version_num and strings, the postmaster
--                            start, and through the AWS door the engine version, auto minor upgrade and the window
--   version_history          a version change: a patch (minor), a major upgrade, a rebuild (same number, new
--                            version() text) or an engine version change on RDS / Aurora
--   version_upgrade_targets  RDS / Aurora's valid upgrade targets of the current engine version
--   version_pending          RDS / Aurora's pending maintenance actions (the patching tracker)
--   database_collations      per database the recorded collation version against the library's version now
--   version_findings         the collation rule and the pending-maintenance deadlines, in pgvigil.findings' columns
--   versions_fleet           one row per instance for the fleet Versions view (the release-table columns, behind
--                            by, EOL, are added by the server from its built-in table: internal/versions)

CREATE TABLE IF NOT EXISTS pgvigil.instance_versions (
  instance_id                 int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at                 timestamptz NOT NULL,
  server_version_num          int,
  server_version              text,
  version_string              text,
  aurora_version              text,
  postmaster_start            timestamptz,
  aws_resource                text,          -- cluster:<id> or instance:<id>
  engine                      text,
  engine_version              text,
  auto_minor_version_upgrade  boolean,       -- the cluster's flag, or every member instance's when the cluster has none
  maintenance_window          text,
  aws_members                 jsonb,         -- the cluster's instances: id, class, engine_version, auto minor upgrade, window, writer
  aws_read_at                 timestamptz    -- the last complete AWS read
);

CREATE TABLE IF NOT EXISTS pgvigil.version_history (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  changed_at       timestamptz NOT NULL,   -- the read that saw it
  applied_at       timestamptz,            -- the postmaster start the new version runs from (server changes)
  change           text NOT NULL,          -- patch | major upgrade | downgrade | rebuild | engine version
  old_value        text,
  new_value        text
);
CREATE INDEX IF NOT EXISTS version_history_idx ON pgvigil.version_history (instance_id, changed_at);

CREATE TABLE IF NOT EXISTS pgvigil.version_upgrade_targets (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  engine_version  text NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  is_major        boolean,
  auto_upgrade    boolean,
  description     text,
  PRIMARY KEY (instance_id, engine_version)
);

CREATE TABLE IF NOT EXISTS pgvigil.version_pending (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  resource            text NOT NULL,     -- the ARN the action is on (the cluster or one instance)
  action              text NOT NULL,     -- system-update, db-upgrade, os-upgrade, ...
  snapshot_at         timestamptz NOT NULL,
  first_seen          timestamptz NOT NULL,
  description         text,
  auto_applied_after  timestamptz,
  forced_apply        timestamptz,
  current_apply       timestamptz,       -- when it will be applied (the next window after a date, or the forced date)
  opt_in_status       text,
  is_present          boolean NOT NULL DEFAULT true,   -- false once AWS no longer lists it (applied or withdrawn)
  PRIMARY KEY (instance_id, resource, action)
);

CREATE TABLE IF NOT EXISTS pgvigil.database_collations (
  instance_id       int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid              bigint NOT NULL,
  datname           text NOT NULL,
  snapshot_at       timestamptz NOT NULL,
  provider          text,              -- c (libc), i (ICU), b (builtin)
  locale            text,
  recorded_version  text,              -- pg_database.datcollversion
  actual_version    text,              -- pg_database_collation_actual_version: the library's version now
  is_present        boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid)
);

CREATE OR REPLACE FUNCTION pgvigil.import_versions(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  s      jsonb;
  e      jsonb;
  v_old  pgvigil.instance_versions%ROWTYPE;
  v_aws  boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_versions'), p_instance_id);
  SELECT r INTO s FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'server' LIMIT 1;
  SELECT r INTO e FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'aws_engine' LIMIT 1;
  v_aws := EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'aws_read');
  SELECT * INTO v_old FROM pgvigil.instance_versions WHERE instance_id = p_instance_id;

  IF s IS NOT NULL AND v_old.instance_id IS NOT NULL THEN
    INSERT INTO pgvigil.version_history (instance_id, changed_at, applied_at, change, old_value, new_value)
    SELECT p_instance_id, p_snapshot_at, (s->>'postmaster_start')::timestamptz, c.change, c.old_value, c.new_value
      FROM (VALUES
        (CASE WHEN (s->>'server_version_num')::int / 10000 > v_old.server_version_num / 10000 THEN 'major upgrade'
              WHEN (s->>'server_version_num')::int < v_old.server_version_num THEN 'downgrade'
              ELSE 'patch' END,
         v_old.server_version, s->>'server_version',
         (s->>'server_version_num')::int IS DISTINCT FROM v_old.server_version_num),
        ('rebuild', coalesce(v_old.aurora_version, v_old.version_string), coalesce(s->>'aurora_version', s->>'version_string'),
         (s->>'server_version_num')::int IS NOT DISTINCT FROM v_old.server_version_num
         AND (s->>'version_string' IS DISTINCT FROM v_old.version_string OR s->>'aurora_version' IS DISTINCT FROM v_old.aurora_version))
      ) c(change, old_value, new_value, hit)
     WHERE c.hit;
  END IF;
  IF e IS NOT NULL AND v_old.engine_version IS NOT NULL AND e->>'engine_version' IS DISTINCT FROM v_old.engine_version THEN
    INSERT INTO pgvigil.version_history (instance_id, changed_at, applied_at, change, old_value, new_value)
    VALUES (p_instance_id, p_snapshot_at, NULL, 'engine version', v_old.engine_version, e->>'engine_version');
  END IF;

  IF s IS NOT NULL THEN
    INSERT INTO pgvigil.instance_versions AS v (instance_id, snapshot_at, server_version_num, server_version, version_string,
                                               aurora_version, postmaster_start)
    VALUES (p_instance_id, p_snapshot_at, (s->>'server_version_num')::int, s->>'server_version', s->>'version_string',
            s->>'aurora_version', (s->>'postmaster_start')::timestamptz)
    ON CONFLICT (instance_id) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, server_version_num = EXCLUDED.server_version_num,
      server_version = EXCLUDED.server_version, version_string = EXCLUDED.version_string,
      aurora_version = EXCLUDED.aurora_version, postmaster_start = EXCLUDED.postmaster_start;
  END IF;

  -- the AWS side: replaced only by a complete read (an AWS error keeps the last one)
  IF v_aws AND e IS NOT NULL THEN
    UPDATE pgvigil.instance_versions v SET
      aws_resource = e->>'resource', engine = e->>'engine', engine_version = e->>'engine_version',
      auto_minor_version_upgrade = coalesce((e->>'auto_minor_version_upgrade')::boolean,
        (SELECT bool_and((r->>'auto_minor_version_upgrade')::boolean) FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'aws_instance')),
      maintenance_window = e->>'maintenance_window',
      aws_members = (SELECT jsonb_agg(r - 'kind' ORDER BY r->>'id') FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'aws_instance'),
      aws_read_at = p_snapshot_at
     WHERE v.instance_id = p_instance_id;

    DELETE FROM pgvigil.version_upgrade_targets WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.version_upgrade_targets (instance_id, engine_version, snapshot_at, is_major, auto_upgrade, description)
    SELECT DISTINCT ON (r->>'engine_version') p_instance_id, r->>'engine_version', p_snapshot_at, (r->>'is_major')::boolean,
           (r->>'auto_upgrade')::boolean, r->>'description'
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'aws_target';

    INSERT INTO pgvigil.version_pending AS p (instance_id, resource, action, snapshot_at, first_seen, description,
                                              auto_applied_after, forced_apply, current_apply, opt_in_status, is_present)
    SELECT DISTINCT ON (r->>'resource', r->>'action') p_instance_id, r->>'resource', r->>'action', p_snapshot_at, p_snapshot_at,
           r->>'description', (r->>'auto_applied_after')::timestamptz, (r->>'forced_apply')::timestamptz,
           (r->>'current_apply')::timestamptz, r->>'opt_in_status', true
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'aws_pending'
    ON CONFLICT (instance_id, resource, action) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, description = EXCLUDED.description,
      auto_applied_after = EXCLUDED.auto_applied_after, forced_apply = EXCLUDED.forced_apply,
      current_apply = EXCLUDED.current_apply, opt_in_status = EXCLUDED.opt_in_status,
      first_seen = CASE WHEN p.is_present THEN p.first_seen ELSE EXCLUDED.first_seen END, is_present = true;
    UPDATE pgvigil.version_pending p SET is_present = false, snapshot_at = p_snapshot_at
     WHERE p.instance_id = p_instance_id AND p.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                        WHERE r->>'kind' = 'aws_pending' AND r->>'resource' = p.resource AND r->>'action' = p.action);
  END IF;

  -- collations: a read with collation rows replaces the set (PostgreSQL 14 and older send none: nothing changes)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'collation') THEN
    INSERT INTO pgvigil.database_collations AS c (instance_id, dbid, datname, snapshot_at, provider, locale,
                                                  recorded_version, actual_version, is_present)
    SELECT p_instance_id, (r->>'dbid')::bigint, r->>'datname', p_snapshot_at, r->>'provider', r->>'locale',
           r->>'recorded_version', r->>'actual_version', true
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'collation'
    ON CONFLICT (instance_id, dbid) DO UPDATE SET
      datname = EXCLUDED.datname, snapshot_at = EXCLUDED.snapshot_at, provider = EXCLUDED.provider, locale = EXCLUDED.locale,
      recorded_version = EXCLUDED.recorded_version, actual_version = EXCLUDED.actual_version, is_present = true;
    UPDATE pgvigil.database_collations c SET is_present = false, snapshot_at = p_snapshot_at
     WHERE c.instance_id = p_instance_id AND c.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                        WHERE r->>'kind' = 'collation' AND (r->>'dbid')::bigint = c.dbid);
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- the version rules, in pgvigil.findings' columns: instance_id, severity, setting, value, is_set, suggested,
-- platforms, detail, source, at. The release-table rules (behind by N minors, EOL) are the server's: the
-- table is in the binary (internal/versions), not in the repository.
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW pgvigil.version_findings AS
-- the operating system's collation library changed under a database: its text indexes may be out of order
SELECT c.instance_id, 'warning' AS severity, 'collation version' AS setting,
       c.datname || ': ' || c.recorded_version || ' -> ' || c.actual_version AS value, true AS is_set,
       'REINDEX the text indexes of ' || c.datname || ', then ALTER DATABASE ' || quote_ident(c.datname) || ' REFRESH COLLATION VERSION' AS suggested,
       'self-managed' AS platforms,
       'the database recorded collation version ' || c.recorded_version || ' (' || coalesce(c.locale, '?')
       || ') and the library now reports ' || c.actual_version
       || ': an OS or ICU update changed the sort rules, so indexes on text built under the old rules can miss rows or let duplicates past a unique index until they are rebuilt' AS detail,
       'pgvigil' AS source, c.snapshot_at AS at
  FROM pgvigil.database_collations c
 WHERE c.is_present AND c.recorded_version IS NOT NULL AND c.actual_version IS NOT NULL
   AND c.recorded_version <> c.actual_version
UNION ALL
-- RDS / Aurora pending maintenance: warning when AWS applies it on its own within 14 days, info beyond or undated
-- (an undated action waits for someone to apply or schedule it)
SELECT p.instance_id,
       CASE WHEN least(p.forced_apply, p.auto_applied_after, p.current_apply) < now() + interval '14 days' THEN 'warning' ELSE 'info' END,
       'pending maintenance', p.action || ' on ' || regexp_replace(p.resource, '^.*:', ''), true,
       coalesce('apply it in a planned window before ' || to_char(least(p.forced_apply, p.auto_applied_after, p.current_apply) AT TIME ZONE 'UTC', 'YYYY-MM-DD') || ' UTC',
                'apply it in a planned window (no date set: AWS does not apply it on its own yet)'),
       'managed',
       coalesce(p.description, p.action) || coalesce('; applied automatically after ' || to_char(p.auto_applied_after AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '')
       || coalesce('; forced on ' || to_char(p.forced_apply AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '')
       || coalesce('; scheduled ' || to_char(p.current_apply AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '')
       || coalesce(' (' || p.opt_in_status || ')', ''),
       'pgvigil', p.snapshot_at
  FROM pgvigil.version_pending p
 WHERE p.is_present;

-- one row per active instance: the version now, the last restart, the last version change, the AWS side, and
-- the extension versions beside (task 30: installed below the server's version)
CREATE OR REPLACE VIEW pgvigil.versions_fleet AS
SELECT i.instance_id, i.name AS instance, i.platform,
       coalesce(v.server_version_num, i.server_version_num) AS server_version_num,
       coalesce(v.server_version, st.server_version) AS server_version,
       v.aurora_version, coalesce(v.postmaster_start, st.postmaster_start) AS last_restart,
       v.engine, v.engine_version, v.auto_minor_version_upgrade, v.maintenance_window, v.aws_read_at,
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
                      ORDER BY x.changed_at DESC LIMIT 1) h ON true
 WHERE i.is_active;
