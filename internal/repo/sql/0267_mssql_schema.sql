-- 0267 SQL Server schema history (task A26, PerformanceMonitor 3.13's 'Added 26', DBA Dash's schema snapshots): the
-- SQL Server collection mssql_schema (internal/mssql/schema.go) keeps its databases' objects in 0058's own tables
-- (schema_databases / schema_objects / schema_changes, dbid = database_id) through 0058's own import_schema, so the
-- Schema tab, the schema findings, purge's schema lines and the Diff page's schema compares serve SQL Server as they
-- serve PostgreSQL. This file creates A26's own objects, and re-creates one joined function whole (import_schema):
--
--   mssql_schema_dbs            one row per database the collection has seen: its identity (database_id, name,
--                               create_date in the server's own clock as text, the newest restore it saw), its state
--                               and note as the collection last found it ('read', 'seen', 'secondary', 'offline',
--                               'restoring', 'not readable', 'no access', 'torn', 'hashes', 'partial', 'gone'; a
--                               'seen' keeps a stored 'torn' or 'partial'), read_at, the server's UTC clock taken
--                               before its last whole read, and partial_at, the same of its last read that ended
--                               'partial'.
--   mssql_schema_trace_gaps     per instance, the newest default-trace read whose note said events were not read, kept
--                               by a trigger on mssql_reader_state's row (whose note the next read replaces).
--   import_mssql_schema         the collection's import (the batch path calls import_<collection>): the 'mssql_db'
--                               rows first - a database whose create date moved with no restore under the same name
--                               since its last read is ANOTHER database on a reused database_id: its stored snapshot
--                               is marked gone (its snapshot_at kept, so this pass's read gets in), so this read is
--                               its baseline and no false 'dropped' row is written; a rename keeps the snapshot -
--                               then import_schema with the same payload, then, at 'end', a database named by no row
--                               is 'gone' here.
--   import_schema               0058's, RE-CREATED WHOLE here with one arm (the lead's 14:4x S10, both engines): at the
--                               run's 'end', the objects of every database it marks gone are marked gone too (0058
--                               marked the database row only: its objects stayed present on the page and purge's NOT
--                               is_present line never took them). scripts/a26-join-lines.sql records the arm for the
--                               next join's own file (03:3x), as 0194 did for 0102's import_pg_job_actions_log.
--   import_mssql_schema_due     the collection's question before a pass (a collector door by its import_ name: it
--                               writes nothing): which of the databases it lists are due a whole read, and why - 'new',
--                               'restore', 'ddl' (a committed CREATE / ALTER / DROP of the default trace's in that
--                               database since its read_at, trusted only while the default trace's reader is 'read'
--                               and recent), 'gap' (the reader said events were not read since that database's read),
--                               'retry' (a torn read), 'reconcile' (read_at over a day old); by reason, then oldest
--                               read first; a read-only or standby database at 'new' and the reconcile only; with the
--                               trace's state in words and the oldest read's age, for the tab.
--   mssql_schema_changes_window the changes of a window as 0058's schema_changes_window gives PostgreSQL's, with the
--                               default trace's rows that may have made each: the same database, the object's name or
--                               its parent table's, a type and an action that fit the change, between the two reads;
--                               one (login, host, program) is the change's 'who'; more than one are all listed, said
--                               'matched by name: the default trace keeps no schema'; none, 'not in the default trace'.
--
-- Rights: apply_roles makes both import_ functions SECURITY DEFINER for the collector; the window and the two tables
-- are the reader's (no payload and no credential in any). The gap trigger runs inside the reader import's own
-- SECURITY DEFINER call, as the owner.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_schema_dbs (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_id   bigint NOT NULL,
  name          text NOT NULL,
  create_date   timestamptz,      -- for the page: moved to UTC by the server's offset at the read
  create_local  text,             -- the identity: sys.databases.create_date in the server's own clock, as text (a
                                  -- daylight-saving change moves the UTC value an hour, never this)
  fork_guid     text,
  restored_at   timestamptz,      -- the newest restore over this database msdb's restorehistory held at the read
  state         text NOT NULL CHECK (state IN ('read', 'seen', 'secondary', 'offline', 'restoring', 'not readable',
                                               'no access', 'torn', 'hashes', 'partial', 'gone')),
  note          text,
  read_at       timestamptz,      -- the server's UTC clock before the last whole read (NULL: never read whole)
  partial_at    timestamptz,      -- the server's UTC clock before the last read that ended 'partial' (too large to
                                  -- store): the due measures from it while it is newer than read_at
  snapshot_at   timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_id)
);

-- mssql_schema_trace_gaps: the newest default-trace read whose note said events were not read, per instance. The
-- reader's state row keeps only its last read's note (replaced every 5 minutes), so the gap is kept here by a trigger
-- on that row; a database whose read_at is older than gap_at is due a whole read once.
CREATE TABLE IF NOT EXISTS pgvigil.mssql_schema_trace_gaps (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  gap_at        timestamptz NOT NULL,
  note          text
);

CREATE OR REPLACE FUNCTION pgvigil.mssql_schema_trace_gap()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.mssql_schema_trace_gaps AS g (instance_id, gap_at, note)
  VALUES (NEW.instance_id, NEW.snapshot_at, NEW.note)
  ON CONFLICT (instance_id) DO UPDATE SET gap_at = greatest(g.gap_at, EXCLUDED.gap_at),
    note = CASE WHEN EXCLUDED.gap_at >= g.gap_at THEN EXCLUDED.note ELSE g.note END;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS mssql_schema_trace_gap ON pgvigil.mssql_reader_state;
CREATE TRIGGER mssql_schema_trace_gap AFTER INSERT OR UPDATE ON pgvigil.mssql_reader_state
  FOR EACH ROW WHEN (NEW.reader = 'defaulttrace' AND NEW.note ~* '(were|could) not (be )?read')
  EXECUTE FUNCTION pgvigil.mssql_schema_trace_gap();

-- mssql_trace_type_fits: does a default-trace row's object type fit a schema kind? The type is
-- sys.trace_subclass_values' name for the ObjectType column; a type this list does not know fits every kind (the
-- match widens, it never hides a row).
CREATE OR REPLACE FUNCTION pgvigil.mssql_trace_type_fits(p_type text, p_kind text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_type IS NULL OR btrim(p_type) = '' THEN true
    WHEN upper(btrim(p_type)) NOT IN ('U', 'USER_TABLE', 'TABLE', 'V', 'VIEW', 'P', 'PC', 'X', 'RF', 'PROCEDURE',
                                      'FN', 'IF', 'TF', 'FS', 'FT', 'AF', 'FUNCTION', 'TR', 'TA', 'TRIGGER', 'IX', 'INDEX',
                                      'PK', 'UQ', 'F', 'C', 'D', 'CONSTRAINT', 'SN', 'SYNONYM', 'SO', 'SEQUENCE',
                                      'TT', 'TYPE', 'SCHEMA') THEN true
    ELSE upper(btrim(p_type)) = ANY (CASE p_kind
      WHEN 'table'      THEN ARRAY['U', 'USER_TABLE', 'TABLE']
      WHEN 'column'     THEN ARRAY['U', 'USER_TABLE', 'TABLE']
      WHEN 'view'       THEN ARRAY['V', 'VIEW']
      WHEN 'procedure'  THEN ARRAY['P', 'PC', 'X', 'RF', 'PROCEDURE']
      WHEN 'function'   THEN ARRAY['FN', 'IF', 'TF', 'FS', 'FT', 'AF', 'FUNCTION']
      WHEN 'trigger'    THEN ARRAY['TR', 'TA', 'TRIGGER']
      WHEN 'index'      THEN ARRAY['IX', 'INDEX', 'U', 'USER_TABLE', 'TABLE']
      WHEN 'constraint' THEN ARRAY['PK', 'UQ', 'F', 'C', 'D', 'CONSTRAINT', 'U', 'USER_TABLE', 'TABLE']
      WHEN 'synonym'    THEN ARRAY['SN', 'SYNONYM']
      WHEN 'sequence'   THEN ARRAY['SO', 'SEQUENCE']
      WHEN 'type'       THEN ARRAY['TT', 'TYPE']
      WHEN 'schema'     THEN ARRAY['SCHEMA']
      ELSE ARRAY[upper(btrim(p_type))] END)
  END
$$;

-- mssql_schema_last_name: the last part of an identity ('dbo.t' -> t, '"a.b"."c"' -> c, 'ix_a on dbo.t' -> t's
-- parent is given whole, so a parent identity's last part is its table's name). Quoted parts lose their quotes.
CREATE OR REPLACE FUNCTION pgvigil.mssql_schema_last_name(p_identity text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_identity IS NULL THEN NULL
              WHEN p_identity ~ '"$' THEN replace(substring(p_identity FROM '"((?:[^"]|"")*)"$'), '""', '"')
              ELSE regexp_replace(p_identity, '^.*[. ]', '') END
$$;

-- import_schema: 0058's, whole, with A26's arm at the end call (the header says why).
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
  SELECT p_instance_id, 'schema_ddl:' || (r->>'datname'),
         max(CASE r->>'kind' WHEN 'ddl' THEN (r->>'logged_at')::timestamptz ELSE (r->>'read_to')::timestamptz END)
    FROM jsonb_array_elements(p_payload) r
   WHERE ((r->>'kind' = 'ddl' AND r->>'logged_at' IS NOT NULL) OR (r->>'kind' = 'ddl_cursor' AND r->>'read_to' IS NOT NULL))
     AND r->>'datname' IS NOT NULL
   GROUP BY r->>'datname'
  ON CONFLICT (instance_id, source) DO UPDATE SET read_to = greatest(c.read_to, EXCLUDED.read_to), updated_at = now();

  CREATE TEMP TABLE pgv_schema_in ON COMMIT DROP AS
  SELECT DISTINCT ON (dbid, kind, identity)
         (r->>'dbid')::bigint AS dbid, r->>'datname' AS datname, r->>'object_kind' AS kind, r->>'identity' AS identity,
         r->>'schema_name' AS schema_name, r->>'object_name' AS object_name, r->>'parent' AS parent,
         r->>'definition' AS definition, r->>'owner' AS owner, r->>'acl' AS acl, r->>'hash' AS hash,
         r->>'def_hash' AS def_hash
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'obj' AND r->>'dbid' IS NOT NULL AND r->>'object_kind' IS NOT NULL AND r->>'identity' IS NOT NULL
     AND r->>'hash' IS NOT NULL
   ORDER BY dbid, kind, identity;
  -- a new database's objects are not in schema_objects' statistics yet: without these the diff's joins run as nested
  -- loops over the whole snapshot (minutes at the object cap)
  CREATE INDEX ON pgv_schema_in (dbid, kind, identity);
  ANALYZE pgv_schema_in;
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
      -- a definition past the cut changed beyond the stored text: its own hash differs, its text does not (whatever
      -- the owner and ACL did); a row stored without def_hash falls back to the whole hash with owner and ACL equal
      INSERT INTO pgv_schema_diff (instance_id, snapshot_at, prev_at, read_at, prev_read_at, dbid, datname, kind, identity, schema_name,
                                   object_name, parent, change, attribute, before, after)
      SELECT p_instance_id, p_snapshot_at, v_db.snapshot_at, d.read_at, v_db.read_at, i.dbid, i.datname, i.kind, i.identity, i.schema_name,
             i.object_name, i.parent, 'changed', 'definition', o.definition, i.definition
        FROM pgv_schema_in i
        JOIN pgvigil.schema_objects o
          ON o.instance_id = p_instance_id AND o.dbid = i.dbid AND o.kind = i.kind AND o.identity = i.identity AND o.is_present
       WHERE i.dbid = d.dbid AND o.hash <> i.hash AND o.definition IS NOT DISTINCT FROM i.definition
         AND CASE WHEN o.def_hash IS NOT NULL AND i.def_hash IS NOT NULL THEN o.def_hash <> i.def_hash
                  ELSE o.owner IS NOT DISTINCT FROM i.owner AND o.acl IS NOT DISTINCT FROM i.acl END;
      -- a table's columns, indexes, constraints, triggers and owned sequences, a view's triggers and a materialized
      -- view's indexes come and go with it: one row, the parent's
      DELETE FROM pgv_schema_diff c
       WHERE c.change IN ('added', 'dropped') AND c.parent IS NOT NULL
         AND EXISTS (SELECT 1 FROM pgv_schema_diff t WHERE t.kind IN ('table', 'view', 'materialized view')
                        AND t.identity = c.parent AND t.change = c.change);
      IF EXISTS (SELECT 1 FROM pgv_schema_diff) THEN
        PERFORM pgvigil.ensure_month_partition('schema_changes', p_snapshot_at);
        INSERT INTO pgvigil.schema_changes SELECT * FROM pgv_schema_diff;
      END IF;
    END IF;

    INSERT INTO pgvigil.schema_objects AS o (instance_id, dbid, kind, identity, datname, schema_name, object_name, parent,
                                             definition, owner, acl, hash, def_hash, first_seen, last_changed, snapshot_at, is_present)
    SELECT p_instance_id, i.dbid, i.kind, i.identity, i.datname, i.schema_name, i.object_name, i.parent, i.definition,
           i.owner, i.acl, i.hash, i.def_hash, p_snapshot_at, CASE WHEN v_base THEN NULL ELSE p_snapshot_at END, p_snapshot_at, true
      FROM pgv_schema_in i WHERE i.dbid = d.dbid
    ON CONFLICT (instance_id, dbid, kind, identity) DO UPDATE SET datname = EXCLUDED.datname,
      schema_name = EXCLUDED.schema_name, object_name = EXCLUDED.object_name, parent = EXCLUDED.parent,
      definition = EXCLUDED.definition, owner = EXCLUDED.owner, acl = EXCLUDED.acl,
      first_seen = CASE WHEN o.is_present AND NOT v_base THEN o.first_seen ELSE EXCLUDED.first_seen END,
      last_changed = CASE WHEN v_base THEN o.last_changed
                          WHEN NOT o.is_present OR o.hash <> EXCLUDED.hash THEN EXCLUDED.snapshot_at
                          ELSE o.last_changed END,
      hash = EXCLUDED.hash, def_hash = EXCLUDED.def_hash, snapshot_at = EXCLUDED.snapshot_at, is_present = true;
    UPDATE pgvigil.schema_objects o SET is_present = false, snapshot_at = p_snapshot_at
     WHERE o.instance_id = p_instance_id AND o.dbid = d.dbid AND o.is_present
       AND NOT EXISTS (SELECT 1 FROM pgv_schema_in i WHERE i.dbid = o.dbid AND i.kind = o.kind AND i.identity = o.identity);
  END LOOP;

  -- the run's last call ('end'): a database neither read nor in error is dropped, or no longer connectable; its next
  -- read is a new baseline (a database imported by this run's earlier call carries this snapshot_at already)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'end') THEN
    RETURN;
  END IF;
  UPDATE pgvigil.schema_databases s SET is_present = false, snapshot_at = p_snapshot_at
   WHERE s.instance_id = p_instance_id AND s.is_present AND s.snapshot_at < p_snapshot_at
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' IN ('db', 'seen') AND (r->>'dbid')::bigint = s.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'collector_error' AND r->>'source' = 'schema:' || s.datname);
  -- A26 (0267): the objects of a database gone from the read go with it (0058 marked the database row only, so its
  -- objects stayed present on the page and purge's NOT is_present line never took them)
  UPDATE pgvigil.schema_objects o SET is_present = false, snapshot_at = p_snapshot_at
    FROM pgvigil.schema_databases d
   WHERE d.instance_id = p_instance_id AND NOT d.is_present
     AND o.instance_id = d.instance_id AND o.dbid = d.dbid AND o.is_present;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_schema(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  r record;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_schema'), p_instance_id);

  -- another database on a reused database_id: its create date (the server's own clock, so a daylight-saving change
  -- never moves it) moved, and no restore under the same name since the stored read. The stored snapshot is marked
  -- not present WITHOUT moving its snapshot_at, so import_schema's late-read guard lets this pass's read of the new
  -- database in, as its baseline.
  FOR r IN SELECT (x->>'database_id')::bigint AS dbid, x->>'name' AS name, x->>'create_local' AS create_local,
                  (x->>'restored_at')::timestamptz AS restored_at
             FROM jsonb_array_elements(p_payload) x
            WHERE x->>'kind' = 'mssql_db' AND x->>'database_id' IS NOT NULL LOOP
    IF EXISTS (SELECT 1 FROM pgvigil.mssql_schema_dbs s
                WHERE s.instance_id = p_instance_id AND s.database_id = r.dbid AND s.state <> 'gone'
                  AND s.create_local IS DISTINCT FROM r.create_local
                  AND NOT (r.restored_at IS NOT NULL AND lower(s.name) = lower(r.name)
                           AND (s.read_at IS NULL OR r.restored_at > s.read_at))) THEN
      UPDATE pgvigil.schema_databases SET is_present = false
       WHERE instance_id = p_instance_id AND dbid = r.dbid AND is_present;
      UPDATE pgvigil.schema_objects SET is_present = false, snapshot_at = p_snapshot_at
       WHERE instance_id = p_instance_id AND dbid = r.dbid AND is_present;
      UPDATE pgvigil.mssql_schema_dbs SET partial_at = NULL, state = 'seen'
       WHERE instance_id = p_instance_id AND database_id = r.dbid;
    END IF;
  END LOOP;

  -- a 'seen' row (not read this pass) keeps a stored 'torn' or 'partial': the next pass's reasons rest on them
  INSERT INTO pgvigil.mssql_schema_dbs AS s (instance_id, database_id, name, create_date, create_local, fork_guid,
                                             restored_at, state, note, read_at, partial_at, snapshot_at)
  SELECT p_instance_id, (x->>'database_id')::bigint, x->>'name', (x->>'create_date')::timestamptz, x->>'create_local',
         x->>'fork_guid', (x->>'restored_at')::timestamptz, x->>'state', x->>'note', (x->>'read_at')::timestamptz,
         (x->>'partial_at')::timestamptz, p_snapshot_at
    FROM jsonb_array_elements(p_payload) x
   WHERE x->>'kind' = 'mssql_db' AND x->>'database_id' IS NOT NULL AND x->>'name' IS NOT NULL AND x->>'state' IS NOT NULL
  ON CONFLICT (instance_id, database_id) DO UPDATE SET name = EXCLUDED.name, create_date = EXCLUDED.create_date,
    create_local = EXCLUDED.create_local, fork_guid = EXCLUDED.fork_guid, restored_at = EXCLUDED.restored_at,
    state = CASE WHEN EXCLUDED.state = 'seen' AND s.state IN ('torn', 'partial') THEN s.state ELSE EXCLUDED.state END,
    note = CASE WHEN EXCLUDED.state = 'seen' AND s.state IN ('torn', 'partial') THEN coalesce(EXCLUDED.note, s.note)
                ELSE EXCLUDED.note END,
    read_at = coalesce(EXCLUDED.read_at, s.read_at), partial_at = coalesce(EXCLUDED.partial_at, s.partial_at),
    snapshot_at = EXCLUDED.snapshot_at;

  PERFORM pgvigil.import_schema(p_instance_id, p_snapshot_at, p_payload);

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'end') THEN
    UPDATE pgvigil.mssql_schema_dbs s SET state = 'gone', snapshot_at = p_snapshot_at
     WHERE s.instance_id = p_instance_id AND s.state <> 'gone' AND s.snapshot_at < p_snapshot_at;
  END IF;
END $$;

-- import_mssql_schema_due: p_payload {now: the server's UTC clock, no_trace: a reason the collector knows (Azure SQL
-- Database, 'default trace enabled' 0), dbs: [{database_id, name, create_local, fork_guid, restored_at, read_only}]}
-- - the databases in scope and readable now. Returns {trace_ok, trace_why, oldest_read_at, due: [{database_id,
-- reason}]} in the order a pass reads them: by reason (new, restore, ddl, gap, retry, reconcile), then oldest read
-- first. A restore counts only under the name the stored read had (another database restored onto a reused id is
-- 'new'). A read-only or standby database is read only when new and at the reconcile (a log-shipping standby's
-- every log restore is no reason). A database whose last read ended 'partial' (too large) is measured from that
-- attempt, never 'new' again for it: it is tried again at the reconcile, on a restore or on DDL after the attempt.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_schema_due(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_now   timestamptz := coalesce((p_payload->>'now')::timestamptz, p_snapshot_at);
  v_rd    pgvigil.mssql_reader_state%ROWTYPE;
  v_ok    boolean;
  v_why   text;
  v_due   jsonb;
  v_old   timestamptz;
  v_gap   timestamptz;
BEGIN
  SELECT * INTO v_rd FROM pgvigil.mssql_reader_state WHERE instance_id = p_instance_id AND reader = 'defaulttrace';
  v_ok := FOUND AND v_rd.state = 'read' AND v_rd.snapshot_at > p_snapshot_at - interval '15 minutes'
          AND nullif(p_payload->>'no_trace', '') IS NULL;
  v_why := CASE WHEN nullif(p_payload->>'no_trace', '') IS NOT NULL THEN p_payload->>'no_trace'
                WHEN NOT FOUND THEN 'the default trace has not been read on this instance'
                WHEN v_rd.state = 'no right' THEN 'the default trace cannot be read: the login lacks ALTER TRACE'
                WHEN v_rd.state = 'off' THEN 'the default trace is switched off on this server'
                WHEN v_rd.state = 'failed' THEN 'the default trace''s last read failed' || coalesce(': ' || v_rd.note, '')
                WHEN v_rd.snapshot_at <= p_snapshot_at - interval '15 minutes'
                  THEN format('the default trace was last read %s', to_char(v_rd.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
                END;

  SELECT g.gap_at INTO v_gap FROM pgvigil.mssql_schema_trace_gaps g WHERE g.instance_id = p_instance_id;

  WITH l AS (
    SELECT (x->>'database_id')::bigint AS dbid, x->>'name' AS name, x->>'create_local' AS create_local,
           x->>'fork_guid' AS fork_guid, (x->>'restored_at')::timestamptz AS restored_at,
           coalesce((x->>'read_only')::boolean, false) AS read_only
      FROM jsonb_array_elements(coalesce(p_payload->'dbs', '[]'::jsonb)) x
     WHERE x->>'database_id' IS NOT NULL),
  m AS (
    -- since: the read the reasons measure from - the last whole read, or a newer attempt that ended 'partial'
    SELECT l.*, s.database_id AS s_id, s.name AS s_name, s.create_local AS s_create_local, s.fork_guid AS s_fork_guid,
           s.state AS s_state, s.read_at,
           (s.partial_at IS NOT NULL AND (s.read_at IS NULL OR s.partial_at > s.read_at)) AS tried,
           CASE WHEN s.partial_at IS NOT NULL AND (s.read_at IS NULL OR s.partial_at > s.read_at) THEN s.partial_at
                ELSE s.read_at END AS since
      FROM l LEFT JOIN pgvigil.mssql_schema_dbs s ON s.instance_id = p_instance_id AND s.database_id = l.dbid),
  r AS (
    SELECT m.dbid, m.since,
           CASE
             WHEN m.s_id IS NULL OR m.s_state = 'gone' THEN 'new'
             -- another database on the id: the create date moved with no restore under the stored name since the read
             WHEN m.s_create_local IS DISTINCT FROM m.create_local
                  AND NOT (m.restored_at IS NOT NULL AND lower(m.s_name) = lower(m.name) AND m.read_at IS NOT NULL
                           AND m.restored_at > m.read_at) THEN 'new'
             -- never read whole, or its snapshot is not present (another database on the id, seen but not yet read)
             WHEN NOT m.tried AND (m.read_at IS NULL
                  OR NOT EXISTS (SELECT 1 FROM pgvigil.schema_databases sd
                                  WHERE sd.instance_id = p_instance_id AND sd.dbid = m.dbid AND sd.is_present)) THEN 'new'
             WHEN m.since IS NULL THEN 'new'
             WHEN m.read_only THEN CASE WHEN m.since < v_now - interval '1 day' THEN 'reconcile' END
             WHEN (m.restored_at IS NOT NULL AND lower(m.s_name) = lower(m.name) AND m.restored_at > m.since)
                  OR (m.fork_guid IS NOT NULL AND m.s_fork_guid IS DISTINCT FROM m.fork_guid) THEN 'restore'
             WHEN v_ok AND EXISTS (SELECT 1 FROM pgvigil.mssql_trace_events e
                                    WHERE e.instance_id = p_instance_id AND e.kind = 'ddl'
                                      AND e.database_name IN (m.name, m.s_name) AND e.event_at >= m.since) THEN 'ddl'
             WHEN v_gap > m.since THEN 'gap'
             WHEN m.s_state = 'torn' THEN 'retry'
             WHEN m.since < v_now - interval '1 day' THEN 'reconcile'
           END AS reason
      FROM m)
  SELECT coalesce(jsonb_agg(jsonb_build_object('database_id', r.dbid, 'reason', r.reason)
                            ORDER BY array_position(ARRAY['new', 'restore', 'ddl', 'gap', 'retry', 'reconcile'], r.reason),
                                     r.since NULLS FIRST, r.dbid), '[]'::jsonb)
    INTO v_due FROM r WHERE r.reason IS NOT NULL;

  SELECT min(s.read_at) INTO v_old FROM pgvigil.mssql_schema_dbs s
   WHERE s.instance_id = p_instance_id AND s.state <> 'gone' AND s.read_at IS NOT NULL;

  RETURN jsonb_build_object('trace_ok', v_ok, 'trace_why', v_why, 'oldest_read_at', v_old, 'due', v_due);
END $$;

-- mssql_schema_changes_window: 0058's schema_changes_window's columns for a SQL Server instance (the event-trigger
-- columns NULL), plus the default trace's candidates for each change.
CREATE OR REPLACE FUNCTION pgvigil.mssql_schema_changes_window(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                                               p_dbid bigint DEFAULT NULL)
RETURNS TABLE (snapshot_at timestamptz, prev_at timestamptz, dbid bigint, datname text, kind text, identity text,
               schema_name text, object_name text, parent text, change text, attribute text, before text, after text,
               who_login text, who_host text, who_program text, who_at timestamptz, who_n int, who_list jsonb, who_note text)
LANGUAGE sql STABLE AS $$
  SELECT c.snapshot_at, c.prev_at, c.dbid, c.datname, c.kind, c.identity, c.schema_name, c.object_name, c.parent,
         c.change, c.attribute, c.before, c.after,
         CASE WHEN w.n = 1 THEN w.list->0->>'login' END, CASE WHEN w.n = 1 THEN w.list->0->>'host' END,
         CASE WHEN w.n = 1 THEN w.list->0->>'program' END, CASE WHEN w.n = 1 THEN (w.list->0->>'at')::timestamptz END,
         coalesce(w.n, 0), CASE WHEN w.n > 1 THEN w.list END,
         CASE WHEN coalesce(w.n, 0) = 0 THEN 'not in the default trace (found at a whole read)'
              WHEN w.n > 1 THEN 'matched by name: the default trace keeps no schema' END
    FROM pgvigil.schema_changes c
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS n, jsonb_agg(jsonb_build_object('login', y.login_name, 'host', y.host_name,
                                                              'program', y.program_name, 'at', y.at) ORDER BY y.at DESC) AS list
        FROM (SELECT e.login_name, e.host_name, e.program_name, max(e.event_at) AS at
                FROM pgvigil.mssql_trace_events e
               WHERE e.instance_id = c.instance_id AND e.kind = 'ddl' AND e.database_name = c.datname
                 AND e.event_at > coalesce(c.prev_read_at, c.prev_at, c.snapshot_at - interval '1 day') - interval '1 minute'
                 AND e.event_at <= coalesce(c.read_at, c.snapshot_at) + interval '1 minute'
                 AND ((e.object_name = c.object_name AND pgvigil.mssql_trace_type_fits(e.object_type, c.kind)
                       AND e.sub = CASE c.change WHEN 'added' THEN 'create' WHEN 'dropped' THEN 'drop' ELSE e.sub END)
                      OR (c.parent IS NOT NULL AND e.object_name = pgvigil.mssql_schema_last_name(c.parent)
                          AND pgvigil.mssql_trace_type_fits(e.object_type, 'table') AND e.sub IN ('alter', 'create')))
               GROUP BY e.login_name, e.host_name, e.program_name) y) w ON true
   WHERE c.instance_id = p_instance_id AND c.snapshot_at > p_from AND c.snapshot_at <= p_to
     AND (p_dbid IS NULL OR c.dbid = p_dbid)
   ORDER BY c.snapshot_at DESC, c.datname, c.kind, c.identity, c.attribute
   LIMIT 2000
$$;
