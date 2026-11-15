-- 0136: applications (task 310) - which application each server and database serves, its owners and contacts.
--
--   app_applications       one application: a name that is also a tag value (1 to 100 bytes, no comma or control
--                          character), tier 1-4, environment, a CMDB link, a version (a stale edit is refused)
--   ui_app_contacts        its contacts by role (business owner, technical owner, support, escalation), a team or a
--                          person: personal data, so the ui_ prefix keeps the reader out (apply_roles, 0110); the page
--                          reads them through a ui_ function, nothing else returns them
--   app_assignments        an application per instance (database_name NULL) and per database (keyed by its NAME, the
--                          engine's id kept so a rename is offered, never taken silently); a database's own beats its
--                          instance's; the environment per assignment (the application's is the default)
--   app_not_application    a database marked 'not an application' (it leaves Unassigned)
--   app_field_source       every field's source (entered | import:<name>) and when: an import never overwrites an
--                          entered field unless forced ('conflict' otherwise)
-- The tag: instance_tag_pairs gains an 'application' arm - application:<name> on an instance assigned at its own level or
-- through a database still present - and the key 'application' leaves the config and override arms, so every reader of
-- instance_tags_merged sees the application without a write to instances.tags, and a rename follows at the next read.
-- The writes (import_app_application, import_app_contact, import_app_assign, import_app_contact_route) answer {outcome
-- done | refused, detail} and write admin_audit rows naming ids, never a contact's name, e-mail or phone; one advisory
-- lock orders them.
--   ui_app_contact_routes  a contact's route: its alerts through a configured smtp channel (owner-routed alerts); the
--                          alerter reads the live ones through alert_contact_routes() (its session or the owner's only)

CREATE TABLE IF NOT EXISTS pgvigil.app_applications (
  app_id       int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name         text NOT NULL,
  description  text CHECK (length(description) <= 2000),
  tier         smallint CHECK (tier BETWEEN 1 AND 4),
  environment  text CHECK (environment IN ('production', 'staging', 'test', 'development', 'DR')),
  cmdb_url     text,
  version      int NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   text
);
CREATE UNIQUE INDEX IF NOT EXISTS app_applications_name ON pgvigil.app_applications (lower(name));

CREATE TABLE IF NOT EXISTS pgvigil.ui_app_contacts (
  contact_id   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  app_id       int NOT NULL REFERENCES pgvigil.app_applications (app_id) ON DELETE CASCADE,
  role         text NOT NULL CHECK (role IN ('business owner', 'technical owner', 'support', 'escalation')),
  kind         text NOT NULL CHECK (kind IN ('team', 'person')),
  name         text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  email        text CHECK (length(email) <= 254),
  phone        text CHECK (length(phone) <= 40),
  cmdb_url     text,
  ord          int NOT NULL DEFAULT 0,
  CHECK (phone IS NULL OR kind = 'person')
);
CREATE INDEX IF NOT EXISTS ui_app_contacts_app ON pgvigil.ui_app_contacts (app_id, ord);

CREATE TABLE IF NOT EXISTS pgvigil.app_assignments (
  assignment_id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id   int NOT NULL REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  database_name text,
  app_id        int NOT NULL REFERENCES pgvigil.app_applications (app_id) ON DELETE CASCADE,
  environment   text CHECK (environment IN ('production', 'staging', 'test', 'development', 'DR')),
  engine_db_id  bigint,
  last_seen     timestamptz,
  source        text NOT NULL DEFAULT 'entered',
  set_at        timestamptz NOT NULL DEFAULT now(),
  set_by        text
);
CREATE UNIQUE INDEX IF NOT EXISTS app_assignments_target ON pgvigil.app_assignments (instance_id, coalesce(database_name, ''));
CREATE INDEX IF NOT EXISTS app_assignments_app ON pgvigil.app_assignments (app_id);

CREATE TABLE IF NOT EXISTS pgvigil.app_not_application (
  instance_id   int NOT NULL REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  database_name text NOT NULL,
  set_at        timestamptz NOT NULL DEFAULT now(),
  set_by        text,
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.app_field_source (
  object_kind  text NOT NULL CHECK (object_kind IN ('application', 'contact', 'assignment')),
  object_id    int NOT NULL,
  field        text NOT NULL,
  source       text NOT NULL,
  set_at       timestamptz NOT NULL DEFAULT now(),
  set_by       text,
  PRIMARY KEY (object_kind, object_id, field)
);

-- the key 'application' is the applications page's: no override of it (pgvigil tag refuses it too); NOT VALID keeps an
-- older store's rows, which the view below leaves out
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'instance_tag_overrides_no_application') THEN
    ALTER TABLE pgvigil.instance_tag_overrides
      ADD CONSTRAINT instance_tag_overrides_no_application CHECK (key <> 'application') NOT VALID;
  END IF;
END $$;

-- a database on an instance's current list: PostgreSQL's pgvigil.databases (0007 / 0046) or SQL Server's
-- mssql_database_option (0090), by name
CREATE OR REPLACE FUNCTION pgvigil.app_db_present(p_instance_id int, p_database text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pgvigil.databases d WHERE d.instance_id = p_instance_id AND d.datname = p_database AND d.is_present)
      OR EXISTS (SELECT 1 FROM pgvigil.mssql_database_option o
                  WHERE o.instance_id = p_instance_id AND o.database_name = p_database AND o.is_present)
$$;

-- the engine's id of a present database (dbid / database_id), NULL when none
CREATE OR REPLACE FUNCTION pgvigil.app_db_id(p_instance_id int, p_database text)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT d.dbid FROM pgvigil.databases d WHERE d.instance_id = p_instance_id AND d.datname = p_database AND d.is_present LIMIT 1),
    (SELECT o.database_id::bigint FROM pgvigil.mssql_database_option o
      WHERE o.instance_id = p_instance_id AND o.database_name = p_database AND o.is_present LIMIT 1))
$$;

-- a system database never needs an application: template0 / template1 and rdsadmin, SQL Server's own four
CREATE OR REPLACE FUNCTION pgvigil.app_system_db(p_database text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_database IN ('template0', 'template1', 'rdsadmin', 'master', 'model', 'msdb', 'tempdb')
$$;

-- an application name is a tag's value: 1 to 100 bytes, no comma or control character, no space at either end
CREATE OR REPLACE FUNCTION pgvigil.app_name_ok(p_name text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_name IS NOT NULL AND octet_length(p_name) BETWEEN 1 AND 100 AND p_name !~ '[,[:cntrl:]]' AND p_name = btrim(p_name)
$$;

-- a CMDB link: http(s), no user or password before the host
CREATE OR REPLACE FUNCTION pgvigil.app_url_ok(p_url text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_url IS NULL OR (length(p_url) <= 500 AND p_url ~ '^https?://[^/@[:space:]]+(/[^[:space:]]*)?$')
$$;

-- the tag view: 0032's arms with the key 'application' left out, and the application arm
CREATE OR REPLACE VIEW pgvigil.instance_tag_pairs AS
SELECT i.instance_id, p.key, p.value, 'config'::text AS source
  FROM pgvigil.instances i
  CROSS JOIN LATERAL unnest(i.tags) AS u(t)
  CROSS JOIN LATERAL pgvigil.tag_split(u.t) AS p
 WHERE p.key <> '' AND p.value <> '' AND p.key <> 'application'
   AND NOT EXISTS (SELECT 1 FROM pgvigil.instance_tag_overrides o WHERE o.instance_id = i.instance_id AND o.key = p.key)
UNION ALL
SELECT o.instance_id, o.key, v.value, 'override'
  FROM pgvigil.instance_tag_overrides o
  CROSS JOIN LATERAL unnest(o.vals) AS v(value)
 WHERE o.vals IS NOT NULL AND v.value <> '' AND o.key <> 'application'
UNION ALL
SELECT DISTINCT a.instance_id, 'application', ap.name, 'application'
  FROM pgvigil.app_assignments a
  JOIN pgvigil.app_applications ap ON ap.app_id = a.app_id
 WHERE a.database_name IS NULL OR pgvigil.app_db_present(a.instance_id, a.database_name);

-- the application a database (or, with p_database NULL, the instance) answers to: its own assignment, else its instance's
CREATE OR REPLACE FUNCTION pgvigil.app_effective(p_instance_id int, p_database text)
RETURNS TABLE (app_id int, name text, src text) LANGUAGE sql STABLE AS $$
  SELECT ap.app_id, ap.name, CASE WHEN a.database_name IS NULL THEN 'instance' ELSE 'database' END
    FROM pgvigil.app_assignments a
    JOIN pgvigil.app_applications ap ON ap.app_id = a.app_id
   WHERE a.instance_id = p_instance_id AND (a.database_name = p_database OR a.database_name IS NULL)
   ORDER BY a.database_name IS NULL
   LIMIT 1
$$;

-- one application's targets: the instance-level rows, its own databases (absent since, renamed to), and the present
-- databases that inherit it from their instance
CREATE OR REPLACE FUNCTION pgvigil.app_databases(p_app_id int)
RETURNS TABLE (instance_id int, database_name text, own boolean, absent_since timestamptz, renamed_to text) LANGUAGE sql STABLE AS $$
  SELECT a.instance_id, a.database_name, true,
         CASE WHEN a.database_name IS NULL OR pgvigil.app_db_present(a.instance_id, a.database_name) THEN NULL
              ELSE coalesce((SELECT max(d.snapshot_at) FROM pgvigil.databases d
                              WHERE d.instance_id = a.instance_id AND d.datname = a.database_name AND NOT d.is_present),
                            (SELECT max(o.snapshot_at) FROM pgvigil.mssql_database_option o
                              WHERE o.instance_id = a.instance_id AND o.database_name = a.database_name AND NOT o.is_present),
                            a.last_seen, a.set_at) END,
         -- renamed to: the present database with the old one's engine id, unless that name has an application of its own
         -- (the page's 'Assign instead' would move it silently: review C, MINOR 5)
         CASE WHEN a.database_name IS NOT NULL AND a.engine_db_id IS NOT NULL
                   AND NOT pgvigil.app_db_present(a.instance_id, a.database_name) THEN
              (SELECT x.n FROM (SELECT coalesce((SELECT d.datname FROM pgvigil.databases d
                                                  WHERE d.instance_id = a.instance_id AND d.dbid = a.engine_db_id AND d.is_present LIMIT 1),
                                                (SELECT o.database_name FROM pgvigil.mssql_database_option o
                                                  WHERE o.instance_id = a.instance_id AND o.database_id = a.engine_db_id AND o.is_present LIMIT 1)) AS n) x
                WHERE NOT EXISTS (SELECT 1 FROM pgvigil.app_assignments b WHERE b.instance_id = a.instance_id AND b.database_name = x.n)) END
    FROM pgvigil.app_assignments a
   WHERE a.app_id = p_app_id
  UNION ALL
  SELECT a.instance_id, x.name, false, NULL::timestamptz, NULL::text
    FROM pgvigil.app_assignments a
    CROSS JOIN LATERAL (
      SELECT d.datname AS name FROM pgvigil.databases d
       WHERE d.instance_id = a.instance_id AND d.is_present AND NOT coalesce(d.is_template, false)
      UNION
      SELECT o.database_name FROM pgvigil.mssql_database_option o WHERE o.instance_id = a.instance_id AND o.is_present AND NOT o.is_snapshot) x   -- review A, m6
   WHERE a.app_id = p_app_id AND a.database_name IS NULL AND NOT pgvigil.app_system_db(x.name)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.app_assignments b
                      WHERE b.instance_id = a.instance_id AND b.database_name = x.name)
$$;

-- every present database with no application, its own or its instance's, not a system database and not marked
CREATE OR REPLACE FUNCTION pgvigil.app_unassigned()
RETURNS TABLE (instance_id int, engine text, database_name text) LANGUAGE sql STABLE AS $$
  SELECT x.instance_id, i.engine, x.name
    FROM (SELECT d.instance_id, d.datname AS name FROM pgvigil.databases d WHERE d.is_present AND NOT coalesce(d.is_template, false)
          UNION
          SELECT o.instance_id, o.database_name FROM pgvigil.mssql_database_option o WHERE o.is_present AND NOT o.is_snapshot) x
    JOIN pgvigil.instances i ON i.instance_id = x.instance_id
   WHERE NOT pgvigil.app_system_db(x.name)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.app_assignments a
                      WHERE a.instance_id = x.instance_id AND (a.database_name = x.name OR a.database_name IS NULL))
     AND NOT EXISTS (SELECT 1 FROM pgvigil.app_not_application m WHERE m.instance_id = x.instance_id AND m.database_name = x.name)
   ORDER BY i.name, x.name
$$;

-- a field's write by a source: false when the field was entered by hand and the writer is an import that is not forced
CREATE OR REPLACE FUNCTION pgvigil.app_src_ok(p_kind text, p_id int, p_field text, p_source text, p_force boolean)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p_source = 'entered' OR p_force
      OR coalesce((SELECT s.source FROM pgvigil.app_field_source s
                    WHERE s.object_kind = p_kind AND s.object_id = p_id AND s.field = p_field), '') <> 'entered'
$$;

CREATE OR REPLACE FUNCTION pgvigil.app_src_set(p_kind text, p_id int, p_field text, p_source text, p_user text)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.app_field_source (object_kind, object_id, field, source, set_at, set_by)
  VALUES (p_kind, p_id, p_field, p_source, now(), p_user)
  ON CONFLICT (object_kind, object_id, field) DO UPDATE SET source = EXCLUDED.source, set_at = now(), set_by = EXCLUDED.set_by
$$;

-- a JSON value as an int, NULL when it is not a whole number in range
CREATE OR REPLACE FUNCTION pgvigil.app_int(p jsonb)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN jsonb_typeof(p) = 'number' AND p::text ~ '^-?[0-9]{1,9}$' THEN p::text::int
              WHEN jsonb_typeof(p) = 'string' AND (p #>> '{}') ~ '^-?[0-9]{1,9}$' THEN (p #>> '{}')::int END
$$;

-- an assign's targets as rows, read straight from the payload: no temp table (a caller's own temp table of that name,
-- with a trigger, would run inside the owner's function: review A, M1)
CREATE OR REPLACE FUNCTION pgvigil.app_targets_of(p jsonb)
RETURNS TABLE (n bigint, instance_id int, database_name text, raw jsonb) LANGUAGE sql IMMUTABLE AS $$
  SELECT e.n, pgvigil.app_int(e.v->'instance_id'), CASE WHEN jsonb_typeof(e.v->'database') = 'string' THEN e.v->>'database' END, e.v
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p) = 'array' THEN p ELSE '[]'::jsonb END) WITH ORDINALITY AS e(v, n)
$$;

-- the live thresholds, acknowledgements and alert rules scoped by one tag (their written form, 'application:<name>')
CREATE OR REPLACE FUNCTION pgvigil.app_tag_scoped(p_tag text)
RETURNS TABLE (kind text, id bigint) LANGUAGE sql STABLE AS $$
  SELECT 'pg threshold', t.threshold_id FROM pgvigil.pg_thresholds t WHERE t.ended_at IS NULL AND t.tag = p_tag
  UNION ALL
  SELECT 'drive threshold', d.threshold_id FROM pgvigil.drive_thresholds d WHERE d.ended_at IS NULL AND d.tag = p_tag
  UNION ALL
  SELECT 'acknowledgement', a.ack_id FROM pgvigil.acks a WHERE a.ended_at IS NULL AND a.tag = p_tag
     AND (a.until IS NULL OR a.until > now())   -- an expired one is not live (review A, m7)
  UNION ALL
  SELECT 'alert rule', r.rule_id FROM pgvigil.alert_rules r WHERE r.ended_at IS NULL AND r.tag = p_tag
$$;

CREATE OR REPLACE FUNCTION pgvigil.import_app_application(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op     text := p_payload->>'op';
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli    text := p_payload->>'client';
  v_id     int := pgvigil.app_int(p_payload->'app_id');
  v_src    text := coalesce(nullif(p_payload->>'source', ''), 'entered');
  v_force  boolean := coalesce(p_payload->>'force', '') = 'true';
  v_name   text := btrim(coalesce(p_payload->>'name', ''));
  v_have   pgvigil.app_applications%ROWTYPE;
  v_fields CONSTANT text[] := ARRAY['description', 'tier', 'environment', 'cmdb_url'];
  v_given  text[] := '{}';
  v_conf   text[] := '{}';
  v_why    text;
  v_detail text;
  v_f      text;
  v_n      int;
  v_old    text;
  v_scoped int := 0;
  v_retag  boolean := coalesce(p_payload->>'retag', '') = 'true';
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_app_application: no ui_user' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.app_writes'));
  IF v_id IS NOT NULL THEN
    SELECT * INTO v_have FROM pgvigil.app_applications WHERE app_id = v_id;
  END IF;
  FOREACH v_f IN ARRAY v_fields LOOP
    IF p_payload ? v_f THEN v_given := v_given || v_f; END IF;
  END LOOP;
  IF v_op IS NULL OR v_op NOT IN ('add', 'edit', 'rename', 'remove') THEN
    v_why := 'op must be add, edit, rename or remove';
  ELSIF v_src <> 'entered' AND v_src !~ '^import:[a-z0-9_.-]{1,40}$' THEN
    v_why := 'source is entered or import:<name>';
  ELSIF v_op <> 'add' AND v_have.app_id IS NULL THEN
    v_why := format('no application %s', coalesce(p_payload->>'app_id', '(none given)'));
  ELSIF v_op <> 'add' AND pgvigil.app_int(p_payload->'version') IS DISTINCT FROM v_have.version THEN
    v_why := format('stale: application %s changed since it was read (version %s now)', v_id, v_have.version);
  ELSIF v_op IN ('add', 'rename') AND NOT pgvigil.app_name_ok(v_name) THEN
    v_why := 'a name is 1 to 100 bytes with no comma or control character and no space at either end (it is a tag value)';
  ELSIF v_op IN ('add', 'rename') AND EXISTS (SELECT 1 FROM pgvigil.app_applications a
                                               WHERE lower(a.name) = lower(v_name) AND NOT (v_op = 'rename' AND a.app_id = v_id)) THEN   -- review A, m2
    v_why := format('an application %s exists already', v_name);
  ELSIF v_op IN ('add', 'edit') AND p_payload ? 'tier' AND jsonb_typeof(p_payload->'tier') <> 'null'
        AND coalesce(pgvigil.app_int(p_payload->'tier'), 0) NOT BETWEEN 1 AND 4 THEN
    v_why := 'tier is 1, 2, 3 or 4';
  ELSIF v_op IN ('add', 'edit') AND nullif(p_payload->>'environment', '') IS NOT NULL
        AND p_payload->>'environment' NOT IN ('production', 'staging', 'test', 'development', 'DR') THEN
    v_why := 'environment is production, staging, test, development or DR';
  ELSIF v_op IN ('add', 'edit') AND NOT pgvigil.app_url_ok(nullif(p_payload->>'cmdb_url', '')) THEN
    v_why := 'cmdb_url is an http(s) link of at most 500 characters with no user or password in it';
  ELSIF v_op IN ('add', 'edit') AND length(p_payload->>'description') > 2000 THEN
    v_why := 'a description is at most 2000 characters';
  ELSIF v_op = 'remove' AND coalesce(p_payload->>'with_assignments', '') <> 'true'
        AND EXISTS (SELECT 1 FROM pgvigil.app_assignments a WHERE a.app_id = v_id) THEN
    SELECT count(*) INTO v_n FROM pgvigil.app_assignments a WHERE a.app_id = v_id;
    v_why := format('%s is assigned to %s server(s) or database(s): remove it with its assignments, or unassign them first', v_have.name, v_n);
  END IF;
  -- a rename or a remove moves the tag a threshold, an acknowledgement or an alert rule may be scoped by: listed and
  -- refused unless ticked (retag), then rewritten to the new name (rename) or ended (remove)
  IF v_why IS NULL AND v_op IN ('rename', 'remove') THEN
    v_old := 'application:' || v_have.name;
    SELECT count(*) INTO v_scoped FROM pgvigil.app_tag_scoped(v_old);
    IF v_scoped > 0 AND NOT v_retag THEN
      SELECT format('%s %s scoped by the tag %s (%s): tick to %s them', v_scoped,
                    CASE WHEN v_scoped = 1 THEN 'threshold, acknowledgement or alert rule is' ELSE 'thresholds, acknowledgements or alert rules are' END,
                    v_old, string_agg(x.kind || ' ' || x.id, ', ' ORDER BY x.kind, x.id),
                    CASE v_op WHEN 'rename' THEN 'rewrite' ELSE 'end' END)
        INTO v_why FROM pgvigil.app_tag_scoped(v_old) x;
    END IF;
  END IF;
  IF v_why IS NULL AND v_op IN ('edit', 'rename') THEN
    FOREACH v_f IN ARRAY (CASE WHEN v_op = 'rename' THEN ARRAY['name'] ELSE v_given END) LOOP
      IF NOT pgvigil.app_src_ok('application', v_id, v_f, v_src, v_force) THEN v_conf := v_conf || v_f; END IF;
    END LOOP;
    IF cardinality(v_conf) > 0 THEN
      v_why := format('conflict: %s entered by hand; %s does not change it unless forced', array_to_string(v_conf, ', '), v_src);
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'app_' || coalesce(v_op, 'unknown'), 'application ' || coalesce(v_id::text, v_name), 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;

  IF v_op = 'add' THEN
    INSERT INTO pgvigil.app_applications (name, description, tier, environment, cmdb_url, created_by)
    VALUES (v_name, nullif(p_payload->>'description', ''), pgvigil.app_int(p_payload->'tier'), nullif(p_payload->>'environment', ''),
            nullif(p_payload->>'cmdb_url', ''), v_user)
    RETURNING app_id INTO v_id;
    PERFORM pgvigil.app_src_set('application', v_id, f, v_src, v_user) FROM unnest(v_given || 'name'::text) f;
    v_detail := format('added application %s (%s)', v_id, v_name);
  ELSIF v_op = 'edit' THEN
    UPDATE pgvigil.app_applications a SET
      description = CASE WHEN p_payload ? 'description' THEN nullif(p_payload->>'description', '') ELSE a.description END,
      tier        = CASE WHEN p_payload ? 'tier' THEN pgvigil.app_int(p_payload->'tier')::smallint ELSE a.tier END,
      environment = CASE WHEN p_payload ? 'environment' THEN nullif(p_payload->>'environment', '') ELSE a.environment END,
      cmdb_url    = CASE WHEN p_payload ? 'cmdb_url' THEN nullif(p_payload->>'cmdb_url', '') ELSE a.cmdb_url END,
      version     = a.version + 1
     WHERE a.app_id = v_id;
    PERFORM pgvigil.app_src_set('application', v_id, f, v_src, v_user) FROM unnest(v_given) f;
    v_detail := format('application %s: %s changed (%s)', v_id, coalesce(nullif(array_to_string(v_given, ', '), ''), 'nothing'), v_src);
  ELSIF v_op = 'rename' THEN
    UPDATE pgvigil.app_applications SET name = v_name, version = version + 1 WHERE app_id = v_id;
    PERFORM pgvigil.app_src_set('application', v_id, 'name', v_src, v_user);
    IF v_scoped > 0 THEN
      UPDATE pgvigil.pg_thresholds SET tag = 'application:' || v_name WHERE ended_at IS NULL AND tag = v_old;
      UPDATE pgvigil.drive_thresholds SET tag = 'application:' || v_name WHERE ended_at IS NULL AND tag = v_old;
      UPDATE pgvigil.acks SET tag = 'application:' || v_name WHERE ended_at IS NULL AND tag = v_old AND (until IS NULL OR until > now());
      UPDATE pgvigil.alert_rules SET tag = 'application:' || v_name WHERE ended_at IS NULL AND tag = v_old;
    END IF;
    v_detail := format('application %s renamed from %s to %s%s', v_id, v_have.name, v_name,
                       CASE WHEN v_scoped > 0 THEN format(' (%s tag-scoped row(s) rewritten)', v_scoped) ELSE '' END);
  ELSE
    SELECT count(*) INTO v_n FROM pgvigil.app_assignments a WHERE a.app_id = v_id;
    DELETE FROM pgvigil.app_field_source s
     WHERE (s.object_kind = 'application' AND s.object_id = v_id)
        OR (s.object_kind = 'contact' AND s.object_id IN (SELECT c.contact_id FROM pgvigil.ui_app_contacts c WHERE c.app_id = v_id));
    DELETE FROM pgvigil.app_applications WHERE app_id = v_id;   -- its contacts and assignments cascade
    IF v_scoped > 0 THEN
      UPDATE pgvigil.pg_thresholds SET ended_at = now(), ended_by = v_user WHERE ended_at IS NULL AND tag = v_old;
      UPDATE pgvigil.drive_thresholds SET ended_at = now(), ended_by = v_user WHERE ended_at IS NULL AND tag = v_old;
      UPDATE pgvigil.acks SET ended_at = now(), ended_by = v_user WHERE ended_at IS NULL AND tag = v_old AND (until IS NULL OR until > now());
      UPDATE pgvigil.alert_rules SET ended_at = now(), ended_by = v_user WHERE ended_at IS NULL AND tag = v_old;
    END IF;
    v_detail := format('removed application %s (%s) with %s assignment(s)%s', v_id, v_have.name, v_n,
                       CASE WHEN v_scoped > 0 THEN format(', %s tag-scoped row(s) ended', v_scoped) ELSE '' END);
  END IF;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'app_' || v_op, 'application ' || v_id, 'done', v_detail);
  RETURN jsonb_build_object('outcome', 'done', 'detail', v_detail, 'app_id', v_id,
                            'version', (SELECT a.version FROM pgvigil.app_applications a WHERE a.app_id = v_id));
END $$;

-- a contact's write; the answer and the audit row carry its id and role, never its name, e-mail or phone
CREATE OR REPLACE FUNCTION pgvigil.import_app_contact(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op     text := p_payload->>'op';
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli    text := p_payload->>'client';
  v_app    int := pgvigil.app_int(p_payload->'app_id');
  v_id     int := pgvigil.app_int(p_payload->'contact_id');
  v_src    text := coalesce(nullif(p_payload->>'source', ''), 'entered');
  v_force  boolean := coalesce(p_payload->>'force', '') = 'true';
  v_have   pgvigil.ui_app_contacts%ROWTYPE;
  v_fields CONSTANT text[] := ARRAY['role', 'kind', 'name', 'email', 'phone', 'cmdb_url'];
  v_given  text[] := '{}';
  v_conf   text[] := '{}';
  v_kind   text;
  v_why    text;
  v_detail text;
  v_f      text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_app_contact: no ui_user' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.app_writes'));
  IF v_id IS NOT NULL THEN
    SELECT * INTO v_have FROM pgvigil.ui_app_contacts WHERE contact_id = v_id;
  END IF;
  FOREACH v_f IN ARRAY v_fields LOOP
    IF p_payload ? v_f THEN v_given := v_given || v_f; END IF;
  END LOOP;
  v_kind := coalesce(CASE WHEN p_payload ? 'kind' THEN p_payload->>'kind' END, v_have.kind);
  IF v_op IS NULL OR v_op NOT IN ('add', 'edit', 'remove') THEN
    v_why := 'op must be add, edit or remove';
  ELSIF v_src <> 'entered' AND v_src !~ '^import:[a-z0-9_.-]{1,40}$' THEN
    v_why := 'source is entered or import:<name>';
  ELSIF v_op = 'add' AND NOT EXISTS (SELECT 1 FROM pgvigil.app_applications a WHERE a.app_id = v_app) THEN
    v_why := format('no application %s', coalesce(p_payload->>'app_id', '(none given)'));
  ELSIF v_op <> 'add' AND v_have.contact_id IS NULL THEN
    v_why := format('no contact %s', coalesce(p_payload->>'contact_id', '(none given)'));
  ELSIF v_op IN ('add', 'edit') AND (v_op = 'add' OR p_payload ? 'role')
        AND coalesce(p_payload->>'role', '') NOT IN ('business owner', 'technical owner', 'support', 'escalation') THEN
    v_why := 'role is business owner, technical owner, support or escalation';
  ELSIF v_op IN ('add', 'edit') AND coalesce(v_kind, '') NOT IN ('team', 'person') THEN
    v_why := 'kind is team or person';
  ELSIF v_op IN ('add', 'edit') AND (v_op = 'add' OR p_payload ? 'name')
        AND coalesce(length(btrim(p_payload->>'name')), 0) NOT BETWEEN 1 AND 200 THEN
    v_why := 'a name is 1 to 200 characters';
  ELSIF v_op IN ('add', 'edit') AND nullif(p_payload->>'email', '') IS NOT NULL
        AND (length(p_payload->>'email') > 254 OR p_payload->>'email' ~ '[[:cntrl:]]'   -- report_mail_why's pattern (review A, m11)
             OR p_payload->>'email' !~ '^[^@\s<>,;"()\[\]\\]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$') THEN
    v_why := 'an e-mail is one address (name@domain), at most 254 characters';
  ELSIF v_op IN ('add', 'edit') AND v_kind <> 'person'   -- the phone the row ends with (an edit to a team keeps a stored one: review A, M2)
        AND coalesce(CASE WHEN p_payload ? 'phone' THEN nullif(p_payload->>'phone', '') ELSE v_have.phone END, '') <> '' THEN
    v_why := 'a phone belongs to a person, not to a team (a team has its group address)';
  ELSIF v_op IN ('add', 'edit') AND nullif(p_payload->>'phone', '') IS NOT NULL AND p_payload->>'phone' !~ '^[+0-9 ().-]{3,40}$' THEN
    v_why := 'a phone is 3 to 40 of + 0-9 space ( ) . -';
  ELSIF v_op IN ('add', 'edit') AND NOT pgvigil.app_url_ok(nullif(p_payload->>'cmdb_url', '')) THEN
    v_why := 'cmdb_url is an http(s) link of at most 500 characters with no user or password in it';
  END IF;
  IF v_why IS NULL AND v_op = 'edit' THEN
    FOREACH v_f IN ARRAY v_given LOOP
      IF NOT pgvigil.app_src_ok('contact', v_id, v_f, v_src, v_force) THEN v_conf := v_conf || v_f; END IF;
    END LOOP;
    IF cardinality(v_conf) > 0 THEN
      v_why := format('conflict: %s entered by hand; %s does not change it unless forced', array_to_string(v_conf, ', '), v_src);
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'app_contact_' || coalesce(v_op, 'unknown'),
                              'contact ' || coalesce(v_id::text, 'new of application ' || coalesce(v_app::text, '?')), 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;

  IF v_op = 'add' THEN
    INSERT INTO pgvigil.ui_app_contacts (app_id, role, kind, name, email, phone, cmdb_url, ord)
    VALUES (v_app, p_payload->>'role', v_kind, btrim(p_payload->>'name'), nullif(p_payload->>'email', ''), nullif(p_payload->>'phone', ''),
            nullif(p_payload->>'cmdb_url', ''),
            coalesce(pgvigil.app_int(p_payload->'ord'), (SELECT coalesce(max(c.ord), 0) + 1 FROM pgvigil.ui_app_contacts c WHERE c.app_id = v_app)))
    RETURNING contact_id, app_id INTO v_id, v_app;
    PERFORM pgvigil.app_src_set('contact', v_id, f, v_src, v_user) FROM unnest(v_given) f;
    v_detail := format('contact %s (%s, %s) added to application %s', v_id, p_payload->>'role', v_kind, v_app);
  ELSIF v_op = 'edit' THEN
    UPDATE pgvigil.ui_app_contacts c SET
      role     = CASE WHEN p_payload ? 'role' THEN p_payload->>'role' ELSE c.role END,
      kind     = v_kind,
      name     = CASE WHEN p_payload ? 'name' THEN btrim(p_payload->>'name') ELSE c.name END,
      email    = CASE WHEN p_payload ? 'email' THEN nullif(p_payload->>'email', '') ELSE c.email END,
      phone    = CASE WHEN p_payload ? 'phone' THEN nullif(p_payload->>'phone', '') ELSE c.phone END,
      cmdb_url = CASE WHEN p_payload ? 'cmdb_url' THEN nullif(p_payload->>'cmdb_url', '') ELSE c.cmdb_url END,
      ord      = coalesce(pgvigil.app_int(p_payload->'ord'), c.ord)
     WHERE c.contact_id = v_id;
    PERFORM pgvigil.app_src_set('contact', v_id, f, v_src, v_user) FROM unnest(v_given) f;
    v_detail := format('contact %s of application %s: %s changed', v_id, v_have.app_id, coalesce(nullif(array_to_string(v_given, ', '), ''), 'nothing'));
  ELSE
    DELETE FROM pgvigil.app_field_source s WHERE s.object_kind = 'contact' AND s.object_id = v_id;
    DELETE FROM pgvigil.ui_app_contacts WHERE contact_id = v_id;
    v_detail := format('contact %s (%s) removed from application %s', v_id, v_have.role, v_have.app_id);
  END IF;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'app_contact_' || v_op, 'contact ' || v_id, 'done', v_detail);
  RETURN jsonb_build_object('outcome', 'done', 'detail', v_detail, 'contact_id', v_id);
END $$;

-- assign / unassign an application over a list of targets {instance_id, database (NULL = the instance)}, or mark /
-- unmark databases 'not an application': one call, one transaction, one audit row per target (one for a refusal)
CREATE OR REPLACE FUNCTION pgvigil.import_app_assign(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op    text := p_payload->>'op';
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli   text := p_payload->>'client';
  v_app   int := pgvigil.app_int(p_payload->'app_id');
  v_src   text := coalesce(nullif(p_payload->>'source', ''), 'entered');
  v_force boolean := coalesce(p_payload->>'force', '') = 'true';
  v_env   text := nullif(p_payload->>'environment', '');
  v_t     jsonb := p_payload->'targets';
  v_n     int;
  v_why   text;
  v_name  text;
  t       record;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_app_assign: no ui_user' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.app_writes'));
  SELECT count(*) INTO v_n FROM pgvigil.app_targets_of(v_t);
  SELECT a.name INTO v_name FROM pgvigil.app_applications a WHERE a.app_id = v_app;
  IF v_op IS NULL OR v_op NOT IN ('assign', 'unassign', 'mark', 'unmark') THEN
    v_why := 'op must be assign, unassign, mark or unmark';
  ELSIF v_src <> 'entered' AND v_src !~ '^import:[a-z0-9_.-]{1,40}$' THEN
    v_why := 'source is entered or import:<name>';
  ELSIF v_n = 0 THEN
    v_why := 'targets: a list of {instance_id, database} (database null for the instance itself)';
  ELSIF v_n > 500 THEN
    v_why := format('%s targets: at most 500 in one request', v_n);
  ELSIF v_op IN ('assign', 'unassign') AND v_name IS NULL THEN
    v_why := format('no application %s', coalesce(p_payload->>'app_id', '(none given)'));
  ELSIF v_env IS NOT NULL AND v_env NOT IN ('production', 'staging', 'test', 'development', 'DR') THEN
    v_why := 'environment is production, staging, test, development or DR';
  ELSIF EXISTS (SELECT 1 FROM pgvigil.app_targets_of(v_t) x WHERE x.instance_id IS NULL
                   OR (x.raw ? 'database' AND jsonb_typeof(x.raw->'database') NOT IN ('string', 'null'))
                   OR x.database_name = '') THEN   -- "" is no database (null names the instance itself): review A, m4
    v_why := 'each target is {instance_id: a number, database: a name or null}';
  ELSIF EXISTS (SELECT 1 FROM pgvigil.app_targets_of(v_t) x GROUP BY x.instance_id, coalesce(x.database_name, '') HAVING count(*) > 1) THEN
    v_why := 'a target is named twice in one request';
  ELSIF EXISTS (SELECT 1 FROM pgvigil.app_targets_of(v_t) x WHERE NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = x.instance_id)) THEN
    SELECT format('no instance %s', min(x.instance_id)) INTO v_why FROM pgvigil.app_targets_of(v_t) x
     WHERE NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = x.instance_id);
  ELSIF v_op IN ('mark', 'unmark') AND EXISTS (SELECT 1 FROM pgvigil.app_targets_of(v_t) x WHERE x.database_name IS NULL) THEN
    v_why := 'only a database is marked ''not an application'', never a whole instance';
  ELSIF v_op IN ('assign', 'mark') AND EXISTS (SELECT 1 FROM pgvigil.app_targets_of(v_t) x
                                                WHERE x.database_name IS NOT NULL AND NOT pgvigil.app_db_present(x.instance_id, x.database_name)) THEN
    SELECT format('%s is not a database of instance %s as last read', x.database_name, x.instance_id) INTO v_why   -- one target's pair (review A, m5)
      FROM pgvigil.app_targets_of(v_t) x WHERE x.database_name IS NOT NULL AND NOT pgvigil.app_db_present(x.instance_id, x.database_name)
     ORDER BY x.n LIMIT 1;
  ELSIF v_op = 'unassign' AND EXISTS (SELECT 1 FROM pgvigil.app_targets_of(v_t) x WHERE NOT EXISTS (
          SELECT 1 FROM pgvigil.app_assignments a WHERE a.instance_id = x.instance_id
             AND coalesce(a.database_name, '') = coalesce(x.database_name, '') AND a.app_id = v_app)) THEN
    v_why := format('a target is not assigned to application %s', v_app);
  ELSIF v_op = 'assign' AND NOT v_force AND v_src <> 'entered' AND EXISTS (
          SELECT 1 FROM pgvigil.app_targets_of(v_t) x JOIN pgvigil.app_assignments a
            ON a.instance_id = x.instance_id AND coalesce(a.database_name, '') = coalesce(x.database_name, '')
           WHERE a.source = 'entered' AND a.app_id <> v_app) THEN
    v_why := format('conflict: a target''s application was entered by hand; %s does not change it unless forced', v_src);
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'app_' || coalesce(v_op, 'unknown'), 'application ' || coalesce(v_app::text, '-'), 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;

  FOR t IN SELECT * FROM pgvigil.app_targets_of(v_t) ORDER BY n LOOP
    IF v_op = 'assign' THEN
      INSERT INTO pgvigil.app_assignments AS a (instance_id, database_name, app_id, environment, engine_db_id, last_seen, source, set_at, set_by)
      VALUES (t.instance_id, t.database_name, v_app, v_env,
              CASE WHEN t.database_name IS NOT NULL THEN pgvigil.app_db_id(t.instance_id, t.database_name) END,
              CASE WHEN t.database_name IS NOT NULL THEN now() END, v_src, now(), v_user)
      ON CONFLICT (instance_id, coalesce(database_name, '')) DO UPDATE SET
        app_id = EXCLUDED.app_id, environment = EXCLUDED.environment, engine_db_id = EXCLUDED.engine_db_id,
        last_seen = EXCLUDED.last_seen, source = EXCLUDED.source, set_at = now(), set_by = EXCLUDED.set_by;
    ELSIF v_op = 'unassign' THEN
      DELETE FROM pgvigil.app_assignments a
       WHERE a.instance_id = t.instance_id AND coalesce(a.database_name, '') = coalesce(t.database_name, '') AND a.app_id = v_app;
    ELSIF v_op = 'mark' THEN
      INSERT INTO pgvigil.app_not_application (instance_id, database_name, set_by) VALUES (t.instance_id, t.database_name, v_user)
      ON CONFLICT DO NOTHING;
    ELSE
      DELETE FROM pgvigil.app_not_application m WHERE m.instance_id = t.instance_id AND m.database_name = t.database_name;
    END IF;
    PERFORM pgvigil.admin_log(v_user, v_cli, 'app_' || v_op,
      format('instance %s%s', t.instance_id, CASE WHEN t.database_name IS NOT NULL THEN ' database ' || t.database_name ELSE '' END), 'done',
      CASE WHEN v_op IN ('assign', 'unassign') THEN format('application %s (%s) %s', v_app, v_name, v_op || 'ed')
           ELSE v_op || 'ed not an application' END);
  END LOOP;
  RETURN jsonb_build_object('outcome', 'done', 'detail', format('%s target(s) %s', v_n, v_op || 'ed'), 'targets', v_n);
END $$;

-- a present database's last time seen and engine id kept on its assignment, so 'absent since' and a rename outlive the
-- list row (SQL Server's absent rows are deleted after 30 days, 0090)
-- (one function per table: plpgsql evaluates every NEW.<field> a statement names, so a field the other table lacks fails)
CREATE OR REPLACE FUNCTION pgvigil.app_seen_pg() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_present THEN
    UPDATE pgvigil.app_assignments a SET last_seen = NEW.snapshot_at, engine_db_id = NEW.dbid
     WHERE a.instance_id = NEW.instance_id AND a.database_name = NEW.datname;
  END IF;
  RETURN NULL;
END $$;
CREATE OR REPLACE FUNCTION pgvigil.app_seen_ms() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_present THEN
    UPDATE pgvigil.app_assignments a SET last_seen = NEW.snapshot_at, engine_db_id = NEW.database_id
     WHERE a.instance_id = NEW.instance_id AND a.database_name = NEW.database_name;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS app_seen ON pgvigil.databases;
CREATE TRIGGER app_seen AFTER INSERT OR UPDATE ON pgvigil.databases FOR EACH ROW EXECUTE FUNCTION pgvigil.app_seen_pg();
DROP TRIGGER IF EXISTS app_seen ON pgvigil.mssql_database_option;
CREATE TRIGGER app_seen AFTER INSERT OR UPDATE ON pgvigil.mssql_database_option FOR EACH ROW EXECUTE FUNCTION pgvigil.app_seen_ms();

-- Admin > Instances' write refuses the tag key 'application' (the applications page sets it); 0122's function renamed
-- import_admin_instance_base (once: a rerun finds the base) and called after the check
DO $$
BEGIN
  IF to_regprocedure('pgvigil.import_admin_instance_base(timestamp with time zone, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_admin_instance(timestamptz, jsonb) RENAME TO import_admin_instance_base;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION pgvigil.import_admin_instance(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_why  text := 'the tag key application is set on Admin > Applications (an application assigned to the server or its databases), not on an instance';
BEGIN
  IF v_user IS NOT NULL AND jsonb_typeof(p_payload->'tags') = 'array'
     AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_payload->'tags') t
                  WHERE strpos(t, ':') > 0 AND lower(btrim(split_part(t, ':', 1))) = 'application') THEN
    PERFORM pgvigil.admin_log(v_user, p_payload->>'client', 'instance ' || coalesce(p_payload->>'op', '?'), p_payload->>'name', 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  RETURN pgvigil.import_admin_instance_base(p_at, p_payload);
END $$;

-- the page's reads of contacts (ui_: SECURITY DEFINER, executable by pgvigil_auth only - apply_roles, 0110), on a click
CREATE OR REPLACE FUNCTION pgvigil.ui_app_contacts_of(p_app_id int)
RETURNS TABLE (contact_id int, role text, kind text, name text, email text, phone text, cmdb_url text, ord int) LANGUAGE sql STABLE AS $$
  SELECT c.contact_id, c.role, c.kind, c.name, c.email, c.phone, c.cmdb_url, c.ord
    FROM pgvigil.ui_app_contacts c WHERE c.app_id = p_app_id
   ORDER BY CASE c.role WHEN 'business owner' THEN 1 WHEN 'technical owner' THEN 2 WHEN 'support' THEN 3 ELSE 4 END, c.ord, c.contact_id
$$;

-- an application's owner team for the lists: the first team contact, business owner before technical owner
CREATE OR REPLACE FUNCTION pgvigil.ui_app_owner_team(p_app_id int)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT c.name FROM pgvigil.ui_app_contacts c
   WHERE c.app_id = p_app_id AND c.kind = 'team' AND c.role IN ('business owner', 'technical owner')
   ORDER BY CASE c.role WHEN 'business owner' THEN 1 ELSE 2 END, c.ord, c.contact_id
   LIMIT 1
$$;

-- ---- owner-routed alerts (an application's contacts receive its instances' alerts) ----------------------------------
-- A route sends one contact the alerts of its application's instances through a CONFIGURED smtp channel (its relay and
-- secrets stay in the configuration file): the alerter makes one derived channel per live route, 'contact-<route_id>',
-- a copy of the base's built channel with to: the contact's address and scope the application's tag; the base's
-- repeat, clear_after, quiet hours and max_per_hour hold it as its own channel. min_severity NULL = the base's. The
-- table is ui_ so apply_roles (0110) keeps the reader out; the alerter reads it through alert_contact_routes() only.
CREATE TABLE IF NOT EXISTS pgvigil.ui_app_contact_routes (
  route_id     int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contact_id   int NOT NULL REFERENCES pgvigil.ui_app_contacts (contact_id) ON DELETE CASCADE,
  channel_name text NOT NULL CHECK (channel_name ~ '^[a-z0-9][a-z0-9_.-]{0,62}$' AND channel_name !~ '^contact-'),
  min_severity text CHECK (min_severity IN ('info', 'warning', 'critical')),
  enabled      boolean NOT NULL DEFAULT true,
  set_at       timestamptz NOT NULL DEFAULT now(),
  set_by       text,
  UNIQUE (contact_id, channel_name)
);

-- import_app_contact_route: op set (a contact and a channel: added, or its severity / on-off changed) | remove; refused
-- in words; one admin_audit row per attempt naming the contact and the channel, never the address
CREATE OR REPLACE FUNCTION pgvigil.import_app_contact_route(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op     text := p_payload->>'op';
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli    text := p_payload->>'client';
  v_cid    int := pgvigil.app_int(p_payload->'contact_id');
  v_rid    int := pgvigil.app_int(p_payload->'route_id');
  v_chan   text := btrim(coalesce(p_payload->>'channel', ''));
  v_sev    text := nullif(p_payload->>'min_severity', '');
  v_en     boolean;
  v_c      pgvigil.ui_app_contacts%ROWTYPE;
  v_r      pgvigil.ui_app_contact_routes%ROWTYPE;
  v_why    text;
  v_detail text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_app_contact_route: no ui_user' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.app_writes'));
  IF v_rid IS NOT NULL THEN
    SELECT * INTO v_r FROM pgvigil.ui_app_contact_routes r WHERE r.route_id = v_rid;
    IF v_cid IS NOT NULL AND v_r.route_id IS NOT NULL AND v_cid <> v_r.contact_id THEN   -- review A, m1
      v_why := format('route %s belongs to contact %s, not to contact %s', v_rid, v_r.contact_id, v_cid);
    END IF;
    v_cid := coalesce(v_cid, v_r.contact_id);
    IF v_chan = '' THEN v_chan := coalesce(v_r.channel_name, ''); END IF;
  ELSIF v_cid IS NOT NULL AND v_chan <> '' THEN
    SELECT * INTO v_r FROM pgvigil.ui_app_contact_routes r WHERE r.contact_id = v_cid AND r.channel_name = v_chan;
  END IF;
  IF v_cid IS NOT NULL THEN
    SELECT * INTO v_c FROM pgvigil.ui_app_contacts c WHERE c.contact_id = v_cid;
  END IF;
  IF jsonb_typeof(p_payload->'enabled') = 'boolean' THEN
    v_en := (p_payload->>'enabled')::boolean;
  END IF;
  IF v_why IS NOT NULL THEN
    NULL;   -- the route and the contact disagree (above)
  ELSIF v_op IS NULL OR v_op NOT IN ('set', 'remove') THEN
    v_why := 'op must be set or remove';
  ELSIF p_payload ? 'enabled' AND jsonb_typeof(p_payload->'enabled') <> 'boolean' THEN
    v_why := 'enabled is true or false';
  ELSIF v_rid IS NOT NULL AND v_r.route_id IS NULL THEN
    v_why := format('no route %s', v_rid);
  ELSIF v_c.contact_id IS NULL THEN
    v_why := format('no contact %s', coalesce(p_payload->>'contact_id', '(none given)'));
  ELSIF v_op = 'remove' AND v_r.route_id IS NULL THEN
    v_why := format('contact %s has no route through %s', v_cid, coalesce(nullif(v_chan, ''), '(no channel named)'));
  ELSIF v_op = 'set' AND v_chan !~ '^[a-z0-9][a-z0-9_.-]{0,62}$' THEN
    v_why := 'a channel is named as in the alerts: list of the configuration (lower-case letters, digits, ''_'', ''.'' or ''-'', at most 63)';
  ELSIF v_op = 'set' AND v_chan ~ '^contact-' THEN
    v_why := 'a route goes through a channel of the configuration, never through another route';
  ELSIF v_op = 'set' AND v_sev IS NOT NULL AND v_sev NOT IN ('info', 'warning', 'critical') THEN
    v_why := 'min_severity is info, warning or critical (empty: the channel''s own)';
  ELSIF v_op = 'set' AND nullif(btrim(coalesce(v_c.email, '')), '') IS NULL THEN
    v_why := format('contact %s has no e-mail address: a route mails its contact', v_cid);
  ELSIF v_op = 'set' AND EXISTS (SELECT 1 FROM pgvigil.alert_channels ch WHERE ch.name = v_chan AND ch.is_configured AND ch.kind <> 'smtp') THEN
    v_why := format('channel %s is not an smtp channel: a route mails its contact', v_chan);
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'app_route', 'contact ' || coalesce(v_cid::text, '-'), 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;

  IF v_op = 'set' THEN
    INSERT INTO pgvigil.ui_app_contact_routes AS r (contact_id, channel_name, min_severity, enabled, set_at, set_by)
    VALUES (v_cid, v_chan, v_sev, coalesce(v_en, true), now(), v_user)
    ON CONFLICT (contact_id, channel_name) DO UPDATE SET
      min_severity = CASE WHEN p_payload ? 'min_severity' THEN EXCLUDED.min_severity ELSE r.min_severity END,
      enabled = coalesce(v_en, r.enabled), set_at = now(), set_by = EXCLUDED.set_by
    RETURNING * INTO v_r;
    v_detail := format('route %s: contact %s (%s of application %s) via %s from %s, %s', v_r.route_id, v_cid, v_c.role, v_c.app_id,
                       v_chan, coalesce(v_r.min_severity, 'the channel''s severity'), CASE WHEN v_r.enabled THEN 'on' ELSE 'off' END);
  ELSE
    DELETE FROM pgvigil.ui_app_contact_routes r WHERE r.route_id = v_r.route_id;
    v_detail := format('route %s removed: contact %s via %s', v_r.route_id, v_cid, v_r.channel_name);
  END IF;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'app_route', 'contact ' || v_cid, 'done', v_detail);
  RETURN jsonb_build_object('outcome', 'done', 'detail', v_detail, 'route_id', v_r.route_id);
END $$;

-- alert_contact_routes: the alerter's one read of the live routes and their addresses (an enabled route of a contact
-- with an e-mail), for the alert sender's session (pgvigil_alerter) or the owner only, as alert_log_partition (0059)
CREATE OR REPLACE FUNCTION pgvigil.alert_contact_routes()
RETURNS TABLE (route_id int, contact_id int, role text, application text, channel_name text, min_severity text, email text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
#variable_conflict use_column
BEGIN
  -- pg_temp last and the catalog named: a caller's temp table pg_namespace never answers the owner test (review A, B1)
  IF NOT (pg_catalog.pg_has_role(session_user, 'pgvigil_alerter', 'MEMBER')
          OR pg_catalog.pg_has_role(session_user, (SELECT n.nspowner FROM pg_catalog.pg_namespace n WHERE n.nspname = 'pgvigil'), 'MEMBER')) THEN
    RAISE EXCEPTION 'alert_contact_routes: % is not the alert sender', session_user USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT r.route_id, c.contact_id, c.role, a.name, r.channel_name, r.min_severity, btrim(c.email)
    FROM pgvigil.ui_app_contact_routes r
    JOIN pgvigil.ui_app_contacts c ON c.contact_id = r.contact_id
    JOIN pgvigil.app_applications a ON a.app_id = c.app_id
   WHERE r.enabled AND nullif(btrim(coalesce(c.email, '')), '') IS NOT NULL
   ORDER BY r.route_id;
END $$;
GRANT EXECUTE ON FUNCTION pgvigil.alert_contact_routes() TO pgvigil_alerter;

-- ui_app_contact_routes_of: one application's routes for the page (ui_: SECURITY DEFINER for pgvigil_auth only, apply_roles)
CREATE OR REPLACE FUNCTION pgvigil.ui_app_contact_routes_of(p_app_id int)
RETURNS TABLE (route_id int, contact_id int, contact text, channel_name text, min_severity text, enabled boolean, set_at timestamptz, set_by text)
LANGUAGE sql STABLE AS $$
  SELECT r.route_id, c.contact_id, c.name, r.channel_name, r.min_severity, r.enabled, r.set_at, r.set_by
    FROM pgvigil.ui_app_contact_routes r JOIN pgvigil.ui_app_contacts c ON c.contact_id = r.contact_id
   WHERE c.app_id = p_app_id
   ORDER BY c.ord, c.contact_id, r.channel_name
$$;

-- import_alert_test is 0093's with one refusal more (O-D9): a route's derived channel 'contact-<id>' takes no Send test
CREATE OR REPLACE FUNCTION pgvigil.import_alert_test(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client text := nullif(p_payload->>'client', '');
  v_chan   text := nullif(btrim(coalesce(p_payload->>'channel', '')), '');
  v_why    text;
  v_wait   pgvigil.alert_tests;
  v_id     bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_alert_test: no ui_user' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('pgvigil.alert_tests:' || coalesce(v_chan, ''), 0));
  SELECT * INTO v_wait FROM pgvigil.alert_tests t
   WHERE t.channel = v_chan AND t.done_at IS NULL AND t.requested_at > p_at - pgvigil.alert_test_window()
   ORDER BY t.requested_at DESC LIMIT 1;
  IF v_chan IS NULL OR length(v_chan) > 63 THEN
    v_why := 'no channel named';
  ELSIF v_chan LIKE 'contact-%' THEN
    v_why := format('channel %s is an application contact''s route: a Send test goes to a channel of the configuration (its route mails through it)', v_chan);
  ELSIF NOT EXISTS (SELECT 1 FROM pgvigil.alert_channels c WHERE c.name = v_chan AND c.is_configured) THEN
    v_why := format('channel %s is not configured (the sender''s last record of its alerts: list)', v_chan);
  ELSIF v_wait.test_id IS NOT NULL THEN
    v_why := format('a test of %s asked by %s at %s still waits for the sender', v_chan, v_wait.requested_by, v_wait.requested_at);
  ELSIF EXISTS (SELECT 1 FROM pgvigil.alert_tests t WHERE t.channel = v_chan AND t.outcome IS DISTINCT FROM 'refused'
                   AND t.requested_at > p_at - pgvigil.alert_test_gap()) THEN
    v_why := format('%s had a test in the last %s: one test per channel in that time', v_chan, pgvigil.alert_test_gap());
  END IF;
  INSERT INTO pgvigil.alert_tests (channel, requested_by, requested_at, client, done_at, outcome, error)
  VALUES (left(coalesce(v_chan, ''), 63), left(v_user, 200), p_at, left(v_client, 100), CASE WHEN v_why IS NOT NULL THEN p_at END,
          CASE WHEN v_why IS NOT NULL THEN 'refused' END, v_why)
  RETURNING test_id INTO v_id;
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, format('test %s of %s asked: the sender''s next pass sends it (within a minute while pgvigil run is up)', v_id, v_chan)),
                            'test_id', v_id);
END $$;

-- report_mail_why is 0107's with two refusals more (task 310, row A14): the Applications page (contacts are personal
-- data) is never mailed, and a route's derived channel is no report's channel
CREATE OR REPLACE FUNCTION pgvigil.report_mail_why(p_name text, p_route text, p_recipients text[], p_channel text, p_tz text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_bad text;
BEGIN
  IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 120 THEN
    RETURN 'a name of 1 to 120 characters is required';
  END IF;
  IF p_route IS NULL OR length(p_route) > 500 OR p_route !~ '^#/[A-Za-z0-9_]+(\?[A-Za-z0-9_.~%=&:+,-]*)?$' THEN
    RETURN 'the page is the address of a page of this UI (#/<tab>?...)';
  END IF;
  IF p_route ~ '^#/admin_applications([?]|$)' THEN
    RETURN 'Admin > Applications carries contacts (personal data): it is never mailed';
  END IF;
  IF p_recipients IS NULL OR cardinality(p_recipients) NOT BETWEEN 1 AND 50 THEN
    RETURN 'one to 50 addresses are required';
  END IF;
  SELECT r INTO v_bad FROM unnest(p_recipients) r
   WHERE r IS NULL OR length(r) > 254 OR r !~ '^[^@\s<>,;"()\[\]\\]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
   LIMIT 1;
  IF FOUND THEN
    RETURN format('%s is not a mail address', coalesce(v_bad, 'an empty entry'));
  END IF;
  IF p_channel LIKE 'contact-%' THEN
    RETURN format('%s is an application contact''s route: a report goes through a channel of the alerts: block', p_channel);
  END IF;
  IF p_channel IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.alert_channels c WHERE c.name = p_channel AND c.kind = 'smtp' AND c.is_configured) THEN
    RETURN format('%s is not an smtp channel of the alerts: block (the sender''s last record of its channels)', coalesce(p_channel, 'no channel'));
  END IF;
  IF p_tz IS NOT NULL THEN
    BEGIN
      PERFORM now() AT TIME ZONE p_tz;
    EXCEPTION WHEN invalid_parameter_value THEN
      RETURN format('%s is not a time zone', p_tz);
    END;
    IF p_tz !~ '^[A-Za-z][A-Za-z0-9_+/-]{0,63}$' THEN
      RETURN format('%s is not a time zone name (an IANA name, America/Los_Angeles, or UTC)', p_tz);
    END IF;
  END IF;
  RETURN NULL;
END $$;
