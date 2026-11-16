-- 0275 a PostgreSQL 14+ SQL-standard function body (BEGIN ATOMIC ... END, RETURN expr) diffed (task A26-PG, the
-- finding of A26): the schema collection (internal/collect/schema.go) took a function's body from pg_proc.prosrc,
-- which is empty for such a body, so a change of one was never recorded; it now reads pg_get_function_sqlbody's text,
-- and beside each such body sends hash_prev - the row's hash as the code before it computed it (the body = prosrc,
-- empty). This file creates nothing of its own, and re-creates one joined function whole:
--
--   import_schema   0267's (0058's with A26's 'end' arm), RE-CREATED WHOLE here with one arm: inside NOT v_base, before
--                   the diff, a present stored row whose hash is the read's hash_prev (and not its hash) takes the
--                   read's definition, hash and def_hash with no schema_changes row and its last_changed kept - the
--                   upgrade's first read records the newly read body as its baseline, never one false 'changed' row
--                   per such function. pgv_schema_in carries hash_prev from the payload.
--
-- Inert for SQL Server: import_mssql_schema calls this function with rows that carry no hash_prev (o.hash = NULL is
-- never true), and for a PostgreSQL collector before A26-PG (no hash_prev): import_schema behaves as 0267's.
-- What is lost, said in docs/schema.md: a real change of such a body between the old code's last read and the new
-- code's first read is taken as the baseline (the old code could not see it either); so, at any time, is one contrived
-- change: a LANGUAGE sql AS '' function (an empty string body) replaced by an SQL-standard body with the same
-- signature and settings. The way back is not silent: an older collector's read after this one records one 'changed'
-- row per such function (the body goes back to empty).
--
-- The join: scripts/a26pg-join-lines.sql records the arm and the payload column for the next join's own file;
-- A26-PG joins in the SAME join file as A26's 0267 (or above the newest join), or two import_schema bodies reach the
-- field. Rights: unchanged (apply_roles keeps import_schema SECURITY DEFINER for the collector).

-- import_schema: 0267's, whole, with A26-PG's arm inside NOT v_base (the header says why).
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
         r->>'def_hash' AS def_hash, r->>'hash_prev' AS hash_prev
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
      -- A26-PG (0275): a PostgreSQL 14+ SQL-standard body read for the first time (the code before it hashed the
      -- function's empty prosrc): a present stored row whose hash is the read's hash_prev, and not the read's hash,
      -- takes the read's definition, hash and def_hash here, so the diff below records no change for it and the
      -- upsert keeps its last_changed - the upgrade's first read is the body's baseline. Any other difference of the
      -- row (owner, ACL, settings) leaves hash_prev unequal: its change rows are recorded as before.
      UPDATE pgvigil.schema_objects o SET definition = i.definition, hash = i.hash, def_hash = i.def_hash
        FROM pgv_schema_in i
       WHERE o.instance_id = p_instance_id AND o.dbid = d.dbid AND o.is_present
         AND i.dbid = o.dbid AND i.kind = o.kind AND i.identity = o.identity
         AND i.hash_prev IS NOT NULL AND o.hash = i.hash_prev AND o.hash <> i.hash;
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
    FROM pgvigil.schema_databases sd
   WHERE sd.instance_id = p_instance_id AND NOT sd.is_present
     AND o.instance_id = sd.instance_id AND o.dbid = sd.dbid AND o.is_present;
END $$;
