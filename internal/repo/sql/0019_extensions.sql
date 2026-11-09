-- 0019_extensions: the extensions collection (phase 2, task 30).
--   instance_extensions          one row per extension the server can install or library it preloads
--   instance_extension_settings  the preload lists and the libraries' own settings, as the server reports them
--   database_extensions          one row per extension installed in a database
--   extension_history            what changed between two reads, like instance_setting_history
--   ext_version_lt               a version comparison that reads 1.10 above 1.9
--   extension_findings           the extension rules, in pgvigil.findings' columns (the join unions it in)
--   extension_fleet              per instance and extension: available, preloaded, installed where, outdated where

CREATE TABLE IF NOT EXISTS pgvigil.instance_extensions (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name             text NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  available        boolean NOT NULL,          -- in pg_available_extensions (its control file is on the server)
  default_version  text,
  comment          text,
  preloaded_via    text[] NOT NULL DEFAULT '{}',   -- shared / session / local: the preload lists naming it
  is_present       boolean NOT NULL DEFAULT true,  -- false once a read no longer lists it (package removed, unloaded)
  PRIMARY KEY (instance_id, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.instance_extension_settings (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name         text NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  setting      text,
  unit         text,
  is_present   boolean NOT NULL DEFAULT true,   -- false: the library is no longer loaded (or the list no longer readable)
  PRIMARY KEY (instance_id, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.database_extensions (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid         bigint NOT NULL,
  name         text NOT NULL,
  datname      text NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  version      text,
  schema_name  text,
  is_present   boolean NOT NULL DEFAULT true,   -- false once a read of the database no longer lists it, or the database is gone
  PRIMARY KEY (instance_id, dbid, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.extension_history (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  changed_at   timestamptz NOT NULL,
  datname      text,                 -- NULL: a server-wide change
  name         text NOT NULL,
  change       text NOT NULL,        -- installed | removed | updated | available | unavailable | default version | preload | setting
  old_value    text,
  new_value    text
);
CREATE INDEX IF NOT EXISTS extension_history_idx ON pgvigil.extension_history (instance_id, changed_at);

-- a < b for extension versions: the digit groups compared as numbers (1.9 < 1.10, 1.4 < 1.4.1); NULL when
-- either has no digits (a version name like 'unpackaged'), so a caller can fall back to a plain inequality
CREATE OR REPLACE FUNCTION pgvigil.ext_version_lt(a text, b text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN x = '{}' OR y = '{}' THEN NULL ELSE x < y END
    FROM (SELECT ARRAY(SELECT m[1]::numeric FROM regexp_matches(coalesce(a, ''), '([0-9]+)', 'g') m) AS x,
                 ARRAY(SELECT m[1]::numeric FROM regexp_matches(coalesce(b, ''), '([0-9]+)', 'g') m) AS y) v
$$;

CREATE OR REPLACE FUNCTION pgvigil.import_extensions(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_first  boolean;
  v_vias   text[];   -- the preload lists this read could see (the login reads them through pg_read_all_settings)
  v_names  text[];   -- every connectable database, when the read listed them
  v_new    jsonb;    -- the server-wide rows of this read
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_extensions'), p_instance_id);
  v_first := NOT EXISTS (SELECT 1 FROM pgvigil.instance_extensions WHERE instance_id = p_instance_id)
         AND NOT EXISTS (SELECT 1 FROM pgvigil.database_extensions WHERE instance_id = p_instance_id);

  SELECT coalesce(array_agg(CASE r->>'name' WHEN 'shared_preload_libraries' THEN 'shared'
                                            WHEN 'session_preload_libraries' THEN 'session' ELSE 'local' END), '{}')
    INTO v_vias
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'setting' AND r->>'name' IN ('shared_preload_libraries', 'session_preload_libraries', 'local_preload_libraries');

  -- ---- server-wide: available extensions and preloaded libraries ----------------------------------------
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'available') THEN
    SELECT coalesce(jsonb_agg(to_jsonb(x)), '[]') INTO v_new FROM (
      SELECT coalesce(a.name, l.name) AS name, a.name IS NOT NULL AS available, a.default_version, a.comment,
             -- the lists read now, plus what the last read saw in a list this read could not see
             coalesce(l.vias, '{}') || coalesce(ARRAY(SELECT v FROM unnest(o.preloaded_via) v WHERE v <> ALL (v_vias)), '{}') AS preloaded_via
        FROM (SELECT r->>'name' AS name, r->>'default_version' AS default_version, r->>'comment' AS comment
                FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'available') a
        FULL JOIN (SELECT r->>'name' AS name, array_agg(DISTINCT r->>'via' ORDER BY r->>'via') AS vias
                     FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'library' GROUP BY r->>'name') l
          ON l.name = a.name
        LEFT JOIN pgvigil.instance_extensions o ON o.instance_id = p_instance_id AND o.name = coalesce(a.name, l.name) AND o.is_present
      UNION ALL
      -- a library only a list this read could not see named last time keeps its row
      SELECT o.name, false, NULL, NULL, ARRAY(SELECT v FROM unnest(o.preloaded_via) v WHERE v <> ALL (v_vias))
        FROM pgvigil.instance_extensions o
       WHERE o.instance_id = p_instance_id AND o.is_present AND NOT o.available
         AND EXISTS (SELECT 1 FROM unnest(o.preloaded_via) v WHERE v <> ALL (v_vias))
         AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' IN ('available', 'library') AND r->>'name' = o.name)
    ) x;

    IF NOT v_first THEN
      INSERT INTO pgvigil.extension_history (instance_id, changed_at, datname, name, change, old_value, new_value)
      SELECT p_instance_id, p_snapshot_at, NULL, coalesce(n.name, o.name), c.change, c.old_value, c.new_value
        FROM jsonb_to_recordset(v_new) n(name text, available boolean, default_version text, comment text, preloaded_via text[])
        FULL JOIN (SELECT * FROM pgvigil.instance_extensions WHERE instance_id = p_instance_id AND is_present) o ON o.name = n.name
        CROSS JOIN LATERAL (VALUES
          ('available', NULL, n.default_version,
             coalesce(n.available, false) AND NOT coalesce(o.available, false)),
          ('unavailable', o.default_version, NULL,
             coalesce(o.available, false) AND NOT coalesce(n.available, false)),
          ('default version', o.default_version, n.default_version,
             n.available AND o.available AND n.default_version IS DISTINCT FROM o.default_version),
          ('preload', nullif(array_to_string(o.preloaded_via, ','), ''), nullif(array_to_string(n.preloaded_via, ','), ''),
             coalesce(o.preloaded_via, '{}') IS DISTINCT FROM coalesce(n.preloaded_via, '{}'))
        ) c(change, old_value, new_value, hit)
       WHERE c.hit;
    END IF;

    INSERT INTO pgvigil.instance_extensions AS e (instance_id, name, snapshot_at, available, default_version, comment, preloaded_via, is_present)
    SELECT p_instance_id, n.name, p_snapshot_at, n.available, n.default_version, n.comment, n.preloaded_via, true
      FROM jsonb_to_recordset(v_new) n(name text, available boolean, default_version text, comment text, preloaded_via text[])
    ON CONFLICT (instance_id, name) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, available = EXCLUDED.available, default_version = EXCLUDED.default_version,
      comment = EXCLUDED.comment, preloaded_via = EXCLUDED.preloaded_via, is_present = true;
    UPDATE pgvigil.instance_extensions e SET is_present = false, snapshot_at = p_snapshot_at
     WHERE e.instance_id = p_instance_id AND e.is_present AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_new) n WHERE n->>'name' = e.name);

    -- ---- the preload lists and the libraries' settings --------------------------------------------------
    IF NOT v_first THEN
      INSERT INTO pgvigil.extension_history (instance_id, changed_at, datname, name, change, old_value, new_value)
      SELECT p_instance_id, p_snapshot_at, NULL, coalesce(n.name, o.name), 'setting', o.setting, n.setting
        FROM (SELECT r->>'name' AS name, r->>'setting' AS setting FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'setting') n
        FULL JOIN (SELECT name, setting FROM pgvigil.instance_extension_settings WHERE instance_id = p_instance_id AND is_present) o
          ON o.name = n.name
       WHERE o.setting IS DISTINCT FROM n.setting;
    END IF;
    INSERT INTO pgvigil.instance_extension_settings AS s (instance_id, name, snapshot_at, setting, unit, is_present)
    SELECT p_instance_id, r->>'name', p_snapshot_at, r->>'setting', r->>'unit', true
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'setting'
    ON CONFLICT (instance_id, name) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, setting = EXCLUDED.setting, unit = EXCLUDED.unit, is_present = true;
    UPDATE pgvigil.instance_extension_settings s SET is_present = false, snapshot_at = p_snapshot_at
     WHERE s.instance_id = p_instance_id AND s.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'setting' AND r->>'name' = s.name);
  END IF;

  -- ---- per database: the databases this read completed (a db row) are replaced; the others keep their rows
  IF NOT v_first THEN
    INSERT INTO pgvigil.extension_history (instance_id, changed_at, datname, name, change, old_value, new_value)
    SELECT p_instance_id, p_snapshot_at, coalesce(n.datname, o.datname), coalesce(n.name, o.name),
           CASE WHEN o.name IS NULL THEN 'installed' WHEN n.name IS NULL THEN 'removed' ELSE 'updated' END,
           o.version, n.version
      FROM (SELECT (r->>'dbid')::bigint AS dbid, r->>'datname' AS datname, r->>'name' AS name, r->>'version' AS version
              FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'installed') n
      FULL JOIN (SELECT d.* FROM pgvigil.database_extensions d
                  WHERE d.instance_id = p_instance_id AND d.is_present
                    AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                                 WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = d.dbid)) o
        ON o.dbid = n.dbid AND o.name = n.name
     WHERE o.version IS DISTINCT FROM n.version;
  END IF;

  INSERT INTO pgvigil.database_extensions AS d (instance_id, dbid, name, datname, snapshot_at, version, schema_name, is_present)
  SELECT p_instance_id, (r->>'dbid')::bigint, r->>'name', r->>'datname', p_snapshot_at, r->>'version', r->>'schema_name', true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'installed'
  ON CONFLICT (instance_id, dbid, name) DO UPDATE SET
    datname = EXCLUDED.datname, snapshot_at = EXCLUDED.snapshot_at, version = EXCLUDED.version,
    schema_name = EXCLUDED.schema_name, is_present = true;
  UPDATE pgvigil.database_extensions d SET is_present = false, snapshot_at = p_snapshot_at
   WHERE d.instance_id = p_instance_id AND d.is_present
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = d.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'installed' AND (r->>'dbid')::bigint = d.dbid AND r->>'name' = d.name);

  -- a database no longer connectable (dropped, CONNECT revoked, made a template) leaves the list: its rows go
  SELECT ARRAY(SELECT jsonb_array_elements_text(r->'names')) INTO v_names
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'databases' LIMIT 1;
  IF v_names IS NOT NULL THEN
    UPDATE pgvigil.database_extensions d SET is_present = false, snapshot_at = p_snapshot_at
     WHERE d.instance_id = p_instance_id AND d.is_present AND d.datname <> ALL (v_names);
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- the extension rules, one row per finding in pgvigil.findings' columns: instance_id, severity, setting, value,
-- is_set, suggested, platforms, detail, source, at. Only instances with an extensions read take part.
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW pgvigil.extension_findings AS
WITH i AS (
  SELECT instance_id, max(snapshot_at) AS at FROM pgvigil.instance_extensions GROUP BY instance_id
), e AS (
  SELECT * FROM pgvigil.instance_extensions WHERE is_present
), s AS (
  SELECT * FROM pgvigil.instance_extension_settings WHERE is_present
), d AS (
  SELECT * FROM pgvigil.database_extensions WHERE is_present
), shared_read AS (   -- the instances whose shared_preload_libraries the login could read
  SELECT instance_id FROM s WHERE name = 'shared_preload_libraries'
), any_read AS (      -- ... and those whose shared or session list it could read
  SELECT DISTINCT instance_id FROM s WHERE name IN ('shared_preload_libraries', 'session_preload_libraries')
)
-- pg_stat_statements: the statement history pgvigil and every DBA tool reads
SELECT i.instance_id, 'warning' AS severity, 'pg_stat_statements' AS setting, 'not available' AS value, false AS is_set,
       'install the contrib package' AS suggested, 'all' AS platforms,
       'pg_stat_statements is not in pg_available_extensions: the server keeps no statement history (no top statements, no history of a slow query)' AS detail,
       'pgvigil' AS source, i.at
  FROM i
 WHERE NOT EXISTS (SELECT 1 FROM e WHERE e.instance_id = i.instance_id AND e.name = 'pg_stat_statements' AND e.available)
UNION ALL
SELECT e.instance_id, 'warning', 'pg_stat_statements', 'not in shared_preload_libraries', true,
       'add pg_stat_statements to shared_preload_libraries (a restart)', 'all',
       'pg_stat_statements is available but not preloaded: its view errors or stays empty and no statement history is kept',
       'pgvigil', e.snapshot_at
  FROM e JOIN shared_read USING (instance_id)
 WHERE e.name = 'pg_stat_statements' AND e.available AND NOT ('shared' = ANY (e.preloaded_via))
UNION ALL
SELECT e.instance_id, 'info', 'pg_stat_statements', 'preloaded, created in no database read', true,
       'CREATE EXTENSION pg_stat_statements in the database the monitoring login connects to', 'all',
       'the library collects, but no database read has the extension: its view cannot be queried',
       'pgvigil', e.snapshot_at
  FROM e
 WHERE e.name = 'pg_stat_statements' AND 'shared' = ANY (e.preloaded_via)
   AND NOT EXISTS (SELECT 1 FROM d WHERE d.instance_id = e.instance_id AND d.name = 'pg_stat_statements')
UNION ALL
SELECT s.instance_id, 'warning', s.name, s.setting, true, 'top', 'all',
       'pg_stat_statements.track = none: the library is loaded but records nothing',
       'pgvigil', s.snapshot_at
  FROM s WHERE s.name = 'pg_stat_statements.track' AND s.setting = 'none'
UNION ALL
-- an extension installed below the version the server's package offers
SELECT d.instance_id, 'warning', d.name, d.datname || ': ' || d.version, true,
       'ALTER EXTENSION ' || quote_ident(d.name) || ' UPDATE (to ' || e.default_version || ')', 'all',
       'installed at ' || d.version || ' in ' || d.datname || ', the server offers ' || e.default_version
       || ': the package was upgraded and the extension objects were not (fixes and new functions are missing until ALTER EXTENSION ... UPDATE)',
       'pgvigil', d.snapshot_at
  FROM d JOIN e ON e.instance_id = d.instance_id AND e.name = d.name AND e.available
 WHERE coalesce(pgvigil.ext_version_lt(d.version, e.default_version), d.version <> e.default_version)
UNION ALL
-- pg_hint_plan: loaded with hints switched off, or created where it is never loaded (hints silently ignored)
SELECT s.instance_id, 'warning', s.name, s.setting, true, 'on', 'all',
       'pg_hint_plan is loaded but pg_hint_plan.enable_hint is off: every hint comment is ignored',
       'pgvigil', s.snapshot_at
  FROM s WHERE s.name = 'pg_hint_plan.enable_hint' AND s.setting = 'off'
UNION ALL
SELECT d.instance_id, 'warning', 'pg_hint_plan', d.datname || ': created, not preloaded', true,
       'add pg_hint_plan to shared_preload_libraries (or session_preload_libraries)', 'all',
       'CREATE EXTENSION pg_hint_plan only makes its hint table; the hints work only where the library is loaded. It is in no preload list, so unless the application LOADs it per session every hint comment is silently ignored',
       'pgvigil', d.snapshot_at
  FROM d JOIN any_read USING (instance_id)
 WHERE d.name = 'pg_hint_plan'
   AND NOT EXISTS (SELECT 1 FROM e WHERE e.instance_id = d.instance_id AND e.name = 'pg_hint_plan' AND e.preloaded_via <> '{}')
UNION ALL
-- auto_explain: preloaded, and at what threshold
SELECT e.instance_id,
       CASE WHEN s.setting = '0' THEN 'warning' ELSE 'info' END, 'auto_explain', coalesce(s.setting, '?') || coalesce(' ' || s.unit, ''), true,
       CASE WHEN s.setting = '0' THEN 'a threshold from measurement (1000 ms or more)' WHEN s.setting = '-1' THEN 'a threshold, or drop it from the list' ELSE 'keep' END,
       'all',
       CASE WHEN s.setting = '0' THEN 'auto_explain.log_min_duration = 0 logs the plan of every statement: log volume and planning overhead'
            WHEN s.setting = '-1' THEN 'auto_explain is preloaded but log_min_duration = -1: it logs nothing'
            WHEN s.setting IS NULL THEN 'auto_explain is preloaded; its threshold could not be read'
            ELSE 'auto_explain logs the plan of each statement over ' || s.setting || coalesce(' ' || s.unit, '')
                 || coalesce(' (log_analyze ' || a.setting || ')', '') END,
       'pgvigil', e.snapshot_at
  FROM e
  LEFT JOIN s ON s.instance_id = e.instance_id AND s.name = 'auto_explain.log_min_duration'
  LEFT JOIN s a ON a.instance_id = e.instance_id AND a.name = 'auto_explain.log_analyze'
 WHERE e.name = 'auto_explain' AND e.preloaded_via <> '{}'
UNION ALL
-- the extensions pgvigil and a DBA can use when they are there
SELECT x.instance_id, 'info', x.name, x.how, true, 'keep', 'all',
       CASE x.name
         WHEN 'pg_wait_sampling' THEN 'pg_wait_sampling is present: a wait-event history per statement is available'
         WHEN 'pg_stat_monitor' THEN 'pg_stat_monitor is present: statement histograms and plans per time bucket are available'
         WHEN 'system_stats' THEN 'system_stats is present: host CPU, memory, load and disks can be read through SQL'
         ELSE 'amcheck is present: B-tree and heap corruption checks (bt_index_check, verify_heapam) can run' END,
       'pgvigil', x.at
  FROM (SELECT e.instance_id, e.name, e.snapshot_at AS at,
               concat_ws('; ', CASE WHEN e.preloaded_via <> '{}' THEN 'preloaded (' || array_to_string(e.preloaded_via, ',') || ')' END,
                         (SELECT 'installed in ' || string_agg(d.datname, ', ' ORDER BY d.datname) FROM d
                           WHERE d.instance_id = e.instance_id AND d.name = e.name)) AS how
          FROM e WHERE e.name IN ('pg_wait_sampling', 'pg_stat_monitor', 'system_stats', 'amcheck')) x
 WHERE x.how <> '';

-- per instance and extension (available or preloaded or installed anywhere): the fleet's "which servers have X"
CREATE OR REPLACE VIEW pgvigil.extension_fleet AS
SELECT e.instance_id, e.name, e.available, e.default_version, e.preloaded_via, e.comment, e.snapshot_at,
       coalesce(d.dbs, 0) AS installed_dbs, d.databases, d.versions, coalesce(d.outdated_dbs, 0) AS outdated_dbs
  FROM pgvigil.instance_extensions e
  LEFT JOIN LATERAL (
    SELECT count(*) AS dbs, string_agg(x.datname, ', ' ORDER BY x.datname) AS databases,
           string_agg(DISTINCT x.version, ', ') AS versions,
           count(*) FILTER (WHERE e.available AND coalesce(pgvigil.ext_version_lt(x.version, e.default_version), x.version <> e.default_version)) AS outdated_dbs
      FROM pgvigil.database_extensions x
     WHERE x.instance_id = e.instance_id AND x.name = e.name AND x.is_present) d ON true
 WHERE e.is_present;
