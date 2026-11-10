-- 0058_schema: schema snapshots (phase 3, task 59; DBADash's DDL change tracking). The schema collection
-- (internal/collect/schema.go) reads hourly, per connectable database, one row per object of the database's own schemas
-- (schemas, tables, columns, indexes, constraints, triggers, functions and procedures, views, materialized views,
-- sequences) with its definition as text, its owner, its ACL and a hash of the four; import_schema diffs each read
-- against the stored snapshot.
--
--   schema_databases     one row per database read: its object count, the event trigger's state ('installed',
--                        'not installed', 'no event trigger', 'not readable') and its table, first_read (the read the
--                        snapshot starts from: no change is recorded for it), is_present (false: the database was
--                        neither read nor in error: dropped, or no longer connectable).
--   schema_objects       the current snapshot, one row per object (instance, dbid, kind, identity): the identity is
--                        pg_identify_object()'s text, the event trigger's too; is_present false = dropped (kept until
--                        the join's purge removes it past the window).
--   schema_changes       the diff history, monthly partitions: 'added' (after = the definition), 'dropped' (before =
--                        the definition), 'changed' (one row per changed attribute: definition, owner or acl, with the
--                        before and after text); prev_at is the read the change is measured from. A column, index,
--                        constraint or trigger added or dropped with its own table is folded into the table's row.
--   schema_ddl_log       the opt-in event trigger's rows (pgvigil_ddl_log in the monitored database, read since the
--                        cursor 'schema_ddl:<datname>' of log_cursor), monthly partitions on the statement's time.
--   import_schema(i, at, payload)
--   schema_changes_window(i, f, t, dbid)   the changes of the window, each with the captured statement that made it
--                        (matched by identity or the parent table's, within the change's read interval; a GRANT or
--                        REVOKE, which the event trigger logs without an identity, by the object's name in its text).
--   schema_findings      the findings view's columns: 'an object dropped' (warning) and 'a definition changed'
--                        (info), one row each per database with changes in the last 24 hours, with the counts and the
--                        newest change. The UNION arm in pgvigil.findings and the purge lines are the wave's join.
--
-- Rights: the reads stay pg_monitor (the catalogs, pg_get_*def, pg_identify_object); the event trigger is the server
-- DBA's opt-in (a superuser creates it; 'pgvigil roles' prints it).

CREATE TABLE IF NOT EXISTS pgvigil.schema_databases (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid           bigint NOT NULL,
  datname        text NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  read_at        timestamptz,      -- the monitored server's clock at the read (the event trigger's clock)
  first_read     timestamptz NOT NULL,
  objects        int,
  ddl_log        text NOT NULL DEFAULT 'not installed'
                 CHECK (ddl_log IN ('installed', 'not installed', 'no event trigger', 'not readable')),
  ddl_log_table  text,
  ddl_log_note   text,
  is_present     boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid)
);

CREATE TABLE IF NOT EXISTS pgvigil.schema_objects (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid           bigint NOT NULL,
  kind           text NOT NULL,
  identity       text NOT NULL,
  datname        text,
  schema_name    text,
  object_name    text,
  parent         text,             -- the table's identity, for a column, index, constraint or trigger
  definition     text,
  owner          text,
  acl            text,
  hash           text NOT NULL,
  first_seen     timestamptz NOT NULL,
  last_changed   timestamptz,      -- the read that last saw it added or changed
  snapshot_at    timestamptz NOT NULL,
  is_present     boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid, kind, identity)
);

CREATE TABLE IF NOT EXISTS pgvigil.schema_changes (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,     -- the read that found the change
  prev_at        timestamptz,              -- the read before it: the change happened in between
  read_at        timestamptz,              -- the two reads on the monitored server's clock
  prev_read_at   timestamptz,
  dbid           bigint NOT NULL,
  datname        text,
  kind           text NOT NULL,
  identity       text NOT NULL,
  schema_name    text,
  object_name    text,
  parent         text,
  change         text NOT NULL CHECK (change IN ('added', 'dropped', 'changed')),
  attribute      text CHECK (attribute IN ('definition', 'owner', 'acl')),
  before         text,
  after          text
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS schema_changes_db ON pgvigil.schema_changes (instance_id, dbid, snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.schema_ddl_log (
  instance_id     int NOT NULL,
  snapshot_at     timestamptz NOT NULL,    -- the statement's logged_at (the partition helper's column name)
  dbid            bigint NOT NULL,
  log_id          bigint NOT NULL,
  datname         text,
  event           text,
  command_tag     text,
  object_type     text,
  schema_name     text,
  object_identity text,
  role_name       text,
  statement       text
) PARTITION BY RANGE (snapshot_at);
CREATE UNIQUE INDEX IF NOT EXISTS schema_ddl_log_key ON pgvigil.schema_ddl_log (instance_id, dbid, log_id, snapshot_at);

-- payload: {kind:'db', dbid, datname, read_at, objects, ddl_log, ddl_log_table, ddl_log_note} per database read;
-- {kind:'obj', dbid, datname, object_kind, identity, schema_name, object_name, parent, definition, owner, acl, hash} per
-- object of a database read; {kind:'ddl', dbid, datname, log_id, logged_at, event, command_tag, object_type,
-- schema_name, object_identity, role_name, statement} per event-trigger row; {kind:'collector_error',
-- source:'schema:<datname>'} per database that could not be read (its snapshot stays as it was).
-- A database's first read (or its first after it was not present) is the baseline: its objects are stored, no change
-- is recorded. A read older than the database's stored one (a one-off collect beside the daemon) changes nothing.
CREATE OR REPLACE FUNCTION pgvigil.import_schema(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  d        record;
  v_db     pgvigil.schema_databases%ROWTYPE;
  v_found  boolean;
  v_base   boolean;
  m        timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_schema'), p_instance_id);

  -- the event trigger's rows: kept once (the read overlaps by an hour); the cursor moves forward only
  FOR m IN SELECT DISTINCT date_trunc('month', (r->>'logged_at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
             FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'ddl' AND r->>'logged_at' IS NOT NULL LOOP
    PERFORM pgvigil.ensure_month_partition('schema_ddl_log', m);
  END LOOP;
  INSERT INTO pgvigil.schema_ddl_log (instance_id, snapshot_at, dbid, log_id, datname, event, command_tag, object_type,
                                      schema_name, object_identity, role_name, statement)
  SELECT p_instance_id, (r->>'logged_at')::timestamptz, (r->>'dbid')::bigint, (r->>'log_id')::bigint, r->>'datname',
         r->>'event', r->>'command_tag', r->>'object_type', r->>'schema_name', r->>'object_identity', r->>'role_name',
         r->>'statement'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'ddl' AND r->>'logged_at' IS NOT NULL AND r->>'log_id' IS NOT NULL AND r->>'dbid' IS NOT NULL
  ON CONFLICT DO NOTHING;
  INSERT INTO pgvigil.log_cursor AS c (instance_id, source, read_to)
  SELECT p_instance_id, 'schema_ddl:' || (r->>'datname'), max((r->>'logged_at')::timestamptz)
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'ddl' AND r->>'logged_at' IS NOT NULL AND r->>'datname' IS NOT NULL
   GROUP BY r->>'datname'
  ON CONFLICT (instance_id, source) DO UPDATE SET read_to = greatest(c.read_to, EXCLUDED.read_to), updated_at = now();

  CREATE TEMP TABLE pgv_schema_in ON COMMIT DROP AS
  SELECT DISTINCT ON (dbid, kind, identity)
         (r->>'dbid')::bigint AS dbid, r->>'datname' AS datname, r->>'object_kind' AS kind, r->>'identity' AS identity,
         r->>'schema_name' AS schema_name, r->>'object_name' AS object_name, r->>'parent' AS parent,
         r->>'definition' AS definition, r->>'owner' AS owner, r->>'acl' AS acl, r->>'hash' AS hash
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'obj' AND r->>'dbid' IS NOT NULL AND r->>'object_kind' IS NOT NULL AND r->>'identity' IS NOT NULL
     AND r->>'hash' IS NOT NULL
   ORDER BY dbid, kind, identity;
  CREATE TEMP TABLE pgv_schema_diff (LIKE pgvigil.schema_changes) ON COMMIT DROP;

  FOR d IN SELECT (r->>'dbid')::bigint AS dbid, r->>'datname' AS datname, (r->>'read_at')::timestamptz AS read_at,
                  (r->>'objects')::int AS objects,
                  coalesce(r->>'ddl_log', 'not installed') AS ddl_log, r->>'ddl_log_table' AS ddl_log_table,
                  r->>'ddl_log_note' AS ddl_log_note
             FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND r->>'dbid' IS NOT NULL LOOP
    SELECT * INTO v_db FROM pgvigil.schema_databases s WHERE s.instance_id = p_instance_id AND s.dbid = d.dbid;
    v_found := FOUND;
    IF v_found AND v_db.snapshot_at >= p_snapshot_at THEN
      CONTINUE;   -- a late or repeated read: the snapshot is newer already
    END IF;
    v_base := NOT v_found OR NOT v_db.is_present;
    INSERT INTO pgvigil.schema_databases AS s (instance_id, dbid, datname, snapshot_at, read_at, first_read, objects,
                                               ddl_log, ddl_log_table, ddl_log_note, is_present)
    VALUES (p_instance_id, d.dbid, d.datname, p_snapshot_at, d.read_at, p_snapshot_at, d.objects, d.ddl_log,
            d.ddl_log_table, d.ddl_log_note, true)
    ON CONFLICT (instance_id, dbid) DO UPDATE SET datname = EXCLUDED.datname, snapshot_at = EXCLUDED.snapshot_at,
      read_at = EXCLUDED.read_at,
      first_read = CASE WHEN v_base THEN EXCLUDED.first_read ELSE s.first_read END, objects = EXCLUDED.objects,
      ddl_log = EXCLUDED.ddl_log, ddl_log_table = EXCLUDED.ddl_log_table, ddl_log_note = EXCLUDED.ddl_log_note,
      is_present = true;

    IF NOT v_base THEN
      TRUNCATE pgv_schema_diff;
      -- added: not in the stored snapshot, or stored as dropped
      INSERT INTO pgv_schema_diff (instance_id, snapshot_at, prev_at, read_at, prev_read_at, dbid, datname, kind, identity, schema_name,
                                   object_name, parent, change, attribute, before, after)
      SELECT p_instance_id, p_snapshot_at, v_db.snapshot_at, d.read_at, v_db.read_at, i.dbid, i.datname, i.kind, i.identity, i.schema_name,
             i.object_name, i.parent, 'added', NULL, NULL, i.definition
        FROM pgv_schema_in i
        LEFT JOIN pgvigil.schema_objects o
          ON o.instance_id = p_instance_id AND o.dbid = i.dbid AND o.kind = i.kind AND o.identity = i.identity
       WHERE i.dbid = d.dbid AND (o.identity IS NULL OR NOT o.is_present);
      -- dropped: present in the stored snapshot, not in this read
      INSERT INTO pgv_schema_diff (instance_id, snapshot_at, prev_at, read_at, prev_read_at, dbid, datname, kind, identity, schema_name,
                                   object_name, parent, change, attribute, before, after)
      SELECT p_instance_id, p_snapshot_at, v_db.snapshot_at, d.read_at, v_db.read_at, o.dbid, coalesce(d.datname, o.datname), o.kind, o.identity,
             o.schema_name, o.object_name, o.parent, 'dropped', NULL, o.definition, NULL
        FROM pgvigil.schema_objects o
       WHERE o.instance_id = p_instance_id AND o.dbid = d.dbid AND o.is_present
         AND NOT EXISTS (SELECT 1 FROM pgv_schema_in i WHERE i.dbid = o.dbid AND i.kind = o.kind AND i.identity = o.identity);
      -- changed: one row per attribute that differs
      INSERT INTO pgv_schema_diff (instance_id, snapshot_at, prev_at, read_at, prev_read_at, dbid, datname, kind, identity, schema_name,
                                   object_name, parent, change, attribute, before, after)
      SELECT p_instance_id, p_snapshot_at, v_db.snapshot_at, d.read_at, v_db.read_at, i.dbid, i.datname, i.kind, i.identity, i.schema_name,
             i.object_name, i.parent, 'changed', a.attribute, a.before, a.after
        FROM pgv_schema_in i
        JOIN pgvigil.schema_objects o
          ON o.instance_id = p_instance_id AND o.dbid = i.dbid AND o.kind = i.kind AND o.identity = i.identity AND o.is_present
        CROSS JOIN LATERAL (VALUES ('definition', o.definition, i.definition), ('owner', o.owner, i.owner),
                                   ('acl', o.acl, i.acl)) a(attribute, before, after)
       WHERE i.dbid = d.dbid AND o.hash <> i.hash AND a.before IS DISTINCT FROM a.after;
      -- a definition past the cut changed beyond the stored text: the hash differs, the texts do not
      INSERT INTO pgv_schema_diff (instance_id, snapshot_at, prev_at, read_at, prev_read_at, dbid, datname, kind, identity, schema_name,
                                   object_name, parent, change, attribute, before, after)
      SELECT p_instance_id, p_snapshot_at, v_db.snapshot_at, d.read_at, v_db.read_at, i.dbid, i.datname, i.kind, i.identity, i.schema_name,
             i.object_name, i.parent, 'changed', 'definition', o.definition, i.definition
        FROM pgv_schema_in i
        JOIN pgvigil.schema_objects o
          ON o.instance_id = p_instance_id AND o.dbid = i.dbid AND o.kind = i.kind AND o.identity = i.identity AND o.is_present
       WHERE i.dbid = d.dbid AND o.hash <> i.hash AND o.definition IS NOT DISTINCT FROM i.definition
         AND o.owner IS NOT DISTINCT FROM i.owner AND o.acl IS NOT DISTINCT FROM i.acl;
      -- a table's columns, indexes, constraints and triggers come and go with it: one row, the table's
      DELETE FROM pgv_schema_diff c
       WHERE c.change IN ('added', 'dropped') AND c.parent IS NOT NULL
         AND EXISTS (SELECT 1 FROM pgv_schema_diff t WHERE t.kind = 'table' AND t.identity = c.parent AND t.change = c.change);
      IF EXISTS (SELECT 1 FROM pgv_schema_diff) THEN
        PERFORM pgvigil.ensure_month_partition('schema_changes', p_snapshot_at);
        INSERT INTO pgvigil.schema_changes SELECT * FROM pgv_schema_diff;
      END IF;
    END IF;

    INSERT INTO pgvigil.schema_objects AS o (instance_id, dbid, kind, identity, datname, schema_name, object_name, parent,
                                             definition, owner, acl, hash, first_seen, last_changed, snapshot_at, is_present)
    SELECT p_instance_id, i.dbid, i.kind, i.identity, i.datname, i.schema_name, i.object_name, i.parent, i.definition,
           i.owner, i.acl, i.hash, p_snapshot_at, CASE WHEN v_base THEN NULL ELSE p_snapshot_at END, p_snapshot_at, true
      FROM pgv_schema_in i WHERE i.dbid = d.dbid
    ON CONFLICT (instance_id, dbid, kind, identity) DO UPDATE SET datname = EXCLUDED.datname,
      schema_name = EXCLUDED.schema_name, object_name = EXCLUDED.object_name, parent = EXCLUDED.parent,
      definition = EXCLUDED.definition, owner = EXCLUDED.owner, acl = EXCLUDED.acl,
      first_seen = CASE WHEN o.is_present AND NOT v_base THEN o.first_seen ELSE EXCLUDED.first_seen END,
      last_changed = CASE WHEN v_base THEN o.last_changed
                          WHEN NOT o.is_present OR o.hash <> EXCLUDED.hash THEN EXCLUDED.snapshot_at
                          ELSE o.last_changed END,
      hash = EXCLUDED.hash, snapshot_at = EXCLUDED.snapshot_at, is_present = true;
    UPDATE pgvigil.schema_objects o SET is_present = false, snapshot_at = p_snapshot_at
     WHERE o.instance_id = p_instance_id AND o.dbid = d.dbid AND o.is_present
       AND NOT EXISTS (SELECT 1 FROM pgv_schema_in i WHERE i.dbid = o.dbid AND i.kind = o.kind AND i.identity = o.identity);
  END LOOP;

  -- a database neither read nor in error: dropped, or no longer connectable; its next read is a new baseline
  UPDATE pgvigil.schema_databases s SET is_present = false, snapshot_at = p_snapshot_at
   WHERE s.instance_id = p_instance_id AND s.is_present AND s.snapshot_at < p_snapshot_at
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = s.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'collector_error' AND r->>'source' = 'schema:' || s.datname);
END $$;

-- schema_changes_window: the changes of the window (newest first, 2,000 at most), of one database or all (p_dbid NULL),
-- each with the event trigger's statement that made it: a logged row of the same database whose identity is the
-- object's or its table's (for an ACL change, a GRANT or REVOKE, which the trigger logs without an identity, whose text
-- names the object as a whole word), logged between the read before the change and the read that found it, both on
-- the monitored server's clock (read_at; the collector's snapshot times, with a minute of slack, for a read without
-- it). A row inside that interval wins; one logged up to a minute before it is taken only when none is inside (a
-- statement whose transaction committed after the earlier read began). The newest of them is shown.
-- ddl_log is the database's event-trigger state, so the tab can say 'not installed' beside a change.
CREATE OR REPLACE FUNCTION pgvigil.schema_changes_window(p_instance_id int, p_from timestamptz, p_to timestamptz, p_dbid bigint DEFAULT NULL)
RETURNS TABLE (snapshot_at timestamptz, prev_at timestamptz, dbid bigint, datname text, kind text, identity text,
               schema_name text, object_name text, parent text, change text, attribute text, before text, after text,
               statement text, statement_role text, statement_at timestamptz, statement_tag text, ddl_log text)
LANGUAGE sql STABLE AS $$
  SELECT c.snapshot_at, c.prev_at, c.dbid, c.datname, c.kind, c.identity, c.schema_name, c.object_name, c.parent,
         c.change, c.attribute, c.before, c.after, l.statement, l.role_name, l.snapshot_at, l.command_tag, d.ddl_log
    FROM pgvigil.schema_changes c
    LEFT JOIN pgvigil.schema_databases d ON d.instance_id = c.instance_id AND d.dbid = c.dbid
    LEFT JOIN LATERAL (
      SELECT x.statement, x.role_name, x.snapshot_at, x.command_tag
        FROM pgvigil.schema_ddl_log x
       WHERE x.instance_id = c.instance_id AND x.dbid = c.dbid
         AND x.snapshot_at > coalesce(c.prev_read_at, c.prev_at - interval '1 minute', c.snapshot_at - interval '1 day') - interval '1 minute'
         AND x.snapshot_at <= coalesce(c.read_at, c.snapshot_at + interval '1 minute')
         AND (x.object_identity = c.identity OR x.object_identity = c.parent
              OR (c.attribute = 'acl' AND x.object_identity IS NULL AND x.command_tag IN ('GRANT', 'REVOKE')
                  AND x.statement ~* ('(^|[^[:alnum:]_$])"?' || regexp_replace(c.object_name, '([^[:alnum:]_])', '\\\1', 'g') || '"?($|[^[:alnum:]_$])')))
       ORDER BY x.snapshot_at > coalesce(c.prev_read_at, c.prev_at - interval '1 minute', c.snapshot_at - interval '1 day') DESC,
                (x.object_identity IS NOT NULL) DESC, x.snapshot_at DESC, x.log_id DESC
       LIMIT 1) l ON true
   WHERE c.instance_id = p_instance_id AND c.snapshot_at > p_from AND c.snapshot_at <= p_to
     AND (p_dbid IS NULL OR c.dbid = p_dbid)
   ORDER BY c.snapshot_at DESC, c.datname, c.kind, c.identity, c.attribute
   LIMIT 2000
$$;

-- schema_findings: the findings view's columns (instance_id, severity, setting, value, is_set, suggested, platforms,
-- detail, source, at): per database of an active instance with changes found in the last 24 hours, 'an object dropped'
-- (warning) with the drop count, and 'a definition changed' (info) with the added and changed counts; each names the
-- newest change of its kind.
CREATE OR REPLACE VIEW pgvigil.schema_findings AS
WITH c AS (
  SELECT x.instance_id, x.dbid, x.change = 'dropped' AS dropped,
         count(DISTINCT (x.kind, x.identity)) FILTER (WHERE x.change = 'dropped') AS n_dropped,
         count(DISTINCT (x.kind, x.identity)) FILTER (WHERE x.change = 'added') AS n_added,
         count(DISTINCT (x.kind, x.identity)) FILTER (WHERE x.change = 'changed') AS n_changed,
         max(x.snapshot_at) AS newest
    FROM pgvigil.schema_changes x
   WHERE x.snapshot_at > now() - interval '1 day'
   GROUP BY x.instance_id, x.dbid, x.change = 'dropped')
SELECT c.instance_id,
       CASE WHEN c.dropped THEN 'warning' ELSE 'info' END::text AS severity,
       CASE WHEN c.dropped THEN 'schema: an object dropped' ELSE 'schema: a definition changed' END::text AS setting,
       d.datname AS value, true AS is_set,
       CASE WHEN c.dropped THEN 'confirm the drop was planned: the Schema tab has the definition it had'
            ELSE 'confirm the change was planned: the Schema tab has the before and after' END::text AS suggested,
       'all'::text AS platforms,
       CASE WHEN c.dropped
            THEN format('database %s: %s object(s) dropped in the last 24 hours; the newest: %s %s (found %s).',
                        d.datname, c.n_dropped, n.kind, n.identity, to_char(c.newest AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
            ELSE format('database %s: %s added, %s changed in the last 24 hours; the newest: %s %s %s (found %s).',
                        d.datname, c.n_added, c.n_changed, n.kind, n.identity,
                        CASE WHEN n.change = 'changed' THEN n.attribute || ' changed' ELSE n.change END,
                        to_char(c.newest AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"')) END AS detail,
       'pgvigil schema'::text AS source, c.newest AS at
  FROM c
  JOIN pgvigil.instances i ON i.instance_id = c.instance_id AND i.is_active
  JOIN pgvigil.schema_databases d ON d.instance_id = c.instance_id AND d.dbid = c.dbid AND d.is_present
  CROSS JOIN LATERAL (
    SELECT y.kind, y.identity, y.change, y.attribute FROM pgvigil.schema_changes y
     WHERE y.instance_id = c.instance_id AND y.dbid = c.dbid AND y.snapshot_at = c.newest
       AND (y.change = 'dropped') = c.dropped
     ORDER BY y.kind = 'table' DESC, y.identity, y.attribute LIMIT 1) n;
