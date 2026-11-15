-- 0146: the applications inventory's file round trip (task 312) - and the import-never-overwrites rule made whole.
--
--   app_not_application.source   a mark's source (entered | import:<name>), so an import never unmarks a person's mark
--   app_name_ok                  '(none)' is the file's unassign token, never an application's name
--   app_conflict                 THE conflict rule, one helper for every write (the lead's call (a)): an import that
--                                is not forced never changes what a person entered - a field, a contact (its ord too),
--                                an assignment (another application, or the same one with another environment), a
--                                database under a server a person assigned to another application, a mark, or a
--                                remove of an application holding anything a person entered
--   import_app_application / import_app_contact / import_app_assign
--                                0136's writes made again (from rel-310 6a3b56b) through app_conflict; an import's
--                                re-assign that changes nothing writes nothing (no audit row) and keeps its source
--   app_inventory()              the round trip's rows: every active server and its databases (present, or absent
--                                and still named by an assignment or a mark), assigned or not
--   import_app_file(at, payload) the ONE planner: one import at a time, matched, planned, digested, and - when not a
--                                dry run and the digest is the preview's - written through the three writes above

ALTER TABLE pgvigil.app_not_application ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'entered';

-- an application name is a tag's value: 1 to 100 bytes, no comma or control character, no space at either end; never
-- '(none)' in any case, the file's unassign token (an older store's application of that name is kept; in a file the
-- token wins: review A, m2)
CREATE OR REPLACE FUNCTION pgvigil.app_name_ok(p_name text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_name IS NOT NULL AND octet_length(p_name) BETWEEN 1 AND 100 AND p_name !~ '[,[:cntrl:]]' AND p_name = btrim(p_name)
     AND lower(p_name) <> '(none)'
$$;

-- THE conflict rule (task 312). p_what:
--   'field'      an application's or a contact's field (p_kind application | contact, p_id, p_field; NULL = any field)
--   'assignment' the target's own assignment (p_id the instance, p_db the database or NULL for the server itself)
--   'server'     the server-level assignment of instance p_id
--   'mark'       the 'not an application' mark of (p_id, p_db)
--   'remove'     application p_id holds anything a person entered: a field, a contact, an assignment, a route (routes
--                carry no source: every route is a person's), a threshold / acknowledgement / rule on its tag
-- true = a conflict: the writer is an import (not 'entered'), not forced, and a person entered the thing it would change
CREATE OR REPLACE FUNCTION pgvigil.app_conflict(p_src text, p_force boolean, p_what text, p_kind text, p_id int, p_field text, p_db text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT coalesce(p_src, 'entered') <> 'entered' AND NOT coalesce(p_force, false) AND CASE p_what
    WHEN 'field' THEN EXISTS (SELECT 1 FROM pgvigil.app_field_source s
                               WHERE s.object_kind = p_kind AND s.object_id = p_id AND (p_field IS NULL OR s.field = p_field)
                                 AND s.source = 'entered')
    WHEN 'assignment' THEN EXISTS (SELECT 1 FROM pgvigil.app_assignments a
                                    WHERE a.instance_id = p_id AND coalesce(a.database_name, '') = coalesce(p_db, '') AND a.source = 'entered')
    WHEN 'server' THEN EXISTS (SELECT 1 FROM pgvigil.app_assignments a
                                WHERE a.instance_id = p_id AND a.database_name IS NULL AND a.source = 'entered')
    WHEN 'mark' THEN EXISTS (SELECT 1 FROM pgvigil.app_not_application m
                              WHERE m.instance_id = p_id AND m.database_name = p_db AND m.source = 'entered')
    WHEN 'remove' THEN
         EXISTS (SELECT 1 FROM pgvigil.app_field_source s WHERE s.object_kind = 'application' AND s.object_id = p_id AND s.source = 'entered')
      OR EXISTS (SELECT 1 FROM pgvigil.ui_app_contacts c JOIN pgvigil.app_field_source s ON s.object_kind = 'contact' AND s.object_id = c.contact_id
                  WHERE c.app_id = p_id AND s.source = 'entered')
      OR EXISTS (SELECT 1 FROM pgvigil.app_assignments a WHERE a.app_id = p_id AND a.source = 'entered')
      OR EXISTS (SELECT 1 FROM pgvigil.ui_app_contact_routes r JOIN pgvigil.ui_app_contacts c ON c.contact_id = r.contact_id WHERE c.app_id = p_id)
      OR EXISTS (SELECT 1 FROM pgvigil.app_applications ap CROSS JOIN LATERAL pgvigil.app_tag_scoped('application:' || ap.name) x
                  WHERE ap.app_id = p_id)
    ELSE true END
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
    v_why := 'a name is 1 to 100 bytes with no comma or control character and no space at either end (it is a tag value), and never (none)';
  ELSIF v_op IN ('add', 'rename') AND EXISTS (SELECT 1 FROM pgvigil.app_applications a
                                               WHERE lower(a.name) = lower(v_name) AND NOT (v_op = 'rename' AND a.app_id = v_id)) THEN
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
  ELSIF v_op = 'remove' AND pgvigil.app_conflict(v_src, v_force, 'remove', NULL, v_id, NULL, NULL) THEN   -- task 312, m3
    v_why := format('conflict: application %s holds what a person entered (a field, a contact, an assignment, a route or a tag-scoped row); %s does not remove it unless forced', v_id, v_src);
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
      IF pgvigil.app_conflict(v_src, v_force, 'field', 'application', v_id, v_f, NULL) THEN v_conf := v_conf || v_f; END IF;
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

-- a contact's write; the answer and the audit row carry its id and role, never its name, e-mail or phone. 'ord' is a
-- field with its source now (task 312: an import never reorders a person's contact)
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
  v_fields CONSTANT text[] := ARRAY['role', 'kind', 'name', 'email', 'phone', 'cmdb_url', 'ord'];
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
        AND (length(p_payload->>'email') > 254 OR p_payload->>'email' ~ '[[:cntrl:]]'
             OR p_payload->>'email' !~ '^[^@\s<>,;"()\[\]\\]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$') THEN
    v_why := 'an e-mail is one address (name@domain), at most 254 characters';
  ELSIF v_op IN ('add', 'edit') AND v_kind <> 'person'
        AND coalesce(CASE WHEN p_payload ? 'phone' THEN nullif(p_payload->>'phone', '') ELSE v_have.phone END, '') <> '' THEN
    v_why := 'a phone belongs to a person, not to a team (a team has its group address)';
  ELSIF v_op IN ('add', 'edit') AND nullif(p_payload->>'phone', '') IS NOT NULL AND p_payload->>'phone' !~ '^[+0-9 ().-]{3,40}$' THEN
    v_why := 'a phone is 3 to 40 of + 0-9 space ( ) . -';
  ELSIF v_op IN ('add', 'edit') AND NOT pgvigil.app_url_ok(nullif(p_payload->>'cmdb_url', '')) THEN
    v_why := 'cmdb_url is an http(s) link of at most 500 characters with no user or password in it';
  ELSIF v_op = 'remove' AND pgvigil.app_conflict(v_src, v_force, 'field', 'contact', v_id, NULL, NULL) THEN   -- task 312
    v_why := format('conflict: contact %s was entered by hand; %s does not remove it unless forced', v_id, v_src);
  END IF;
  IF v_why IS NULL AND v_op = 'edit' THEN
    FOREACH v_f IN ARRAY v_given LOOP
      -- ord: a contact a person entered (any field of it) keeps its place against an import (task 312, the pass's m3)
      IF pgvigil.app_conflict(v_src, v_force, 'field', 'contact', v_id, CASE WHEN v_f = 'ord' THEN NULL ELSE v_f END, NULL) THEN
        v_conf := v_conf || v_f;
      END IF;
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
-- unmark databases 'not an application': one call, one transaction, one audit row per target written (one for a
-- refusal). Task 312: an import (source import:<name>, not forced) never unassigns, re-assigns (another application,
-- or another environment), unmarks or assigns a database under a server a person entered; its re-assign that changes
-- nothing writes nothing. environment absent = kept on a re-assign (NULL on a new row); given empty = the default.
CREATE OR REPLACE FUNCTION pgvigil.import_app_assign(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op    text := p_payload->>'op';
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli   text := p_payload->>'client';
  v_app   int := pgvigil.app_int(p_payload->'app_id');
  v_src   text := coalesce(nullif(p_payload->>'source', ''), 'entered');
  v_force boolean := coalesce(p_payload->>'force', '') = 'true';
  v_envg  boolean := p_payload ? 'environment';
  v_env   text := nullif(p_payload->>'environment', '');
  v_t     jsonb := p_payload->'targets';
  v_n     int;
  v_done  int := 0;
  v_why   text;
  v_name  text;
  t       record;
  v_cur   record;
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
                   OR x.database_name = '') THEN
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
    SELECT format('%s is not a database of instance %s as last read', x.database_name, x.instance_id) INTO v_why
      FROM pgvigil.app_targets_of(v_t) x WHERE x.database_name IS NOT NULL AND NOT pgvigil.app_db_present(x.instance_id, x.database_name)
     ORDER BY x.n LIMIT 1;
  ELSIF v_op = 'unassign' AND EXISTS (SELECT 1 FROM pgvigil.app_targets_of(v_t) x WHERE NOT EXISTS (
          SELECT 1 FROM pgvigil.app_assignments a WHERE a.instance_id = x.instance_id
             AND coalesce(a.database_name, '') = coalesce(x.database_name, '') AND a.app_id = v_app)) THEN
    v_why := format('a target is not assigned to application %s', v_app);
  -- task 312, the conflict rule (app_conflict): what a person entered stays against an unforced import
  ELSIF v_op = 'assign' AND EXISTS (
          SELECT 1 FROM pgvigil.app_targets_of(v_t) x JOIN pgvigil.app_assignments a
            ON a.instance_id = x.instance_id AND coalesce(a.database_name, '') = coalesce(x.database_name, '')
           WHERE (a.app_id <> v_app OR (v_envg AND a.environment IS DISTINCT FROM v_env))
             AND pgvigil.app_conflict(v_src, v_force, 'assignment', NULL, x.instance_id, NULL, x.database_name)) THEN
    v_why := format('conflict: a target''s application or environment was entered by hand; %s does not change it unless forced', v_src);
  ELSIF v_op = 'assign' AND EXISTS (
          SELECT 1 FROM pgvigil.app_targets_of(v_t) x JOIN pgvigil.app_assignments s ON s.instance_id = x.instance_id AND s.database_name IS NULL
           WHERE x.database_name IS NOT NULL AND s.app_id <> v_app
             AND NOT EXISTS (SELECT 1 FROM pgvigil.app_assignments a WHERE a.instance_id = x.instance_id AND a.database_name = x.database_name)
             AND pgvigil.app_conflict(v_src, v_force, 'server', NULL, x.instance_id, NULL, NULL)) THEN
    v_why := format('conflict: a target database''s server was assigned another application by hand; %s does not assign the database unless forced', v_src);
  ELSIF v_op = 'unassign' AND EXISTS (SELECT 1 FROM pgvigil.app_targets_of(v_t) x
           WHERE pgvigil.app_conflict(v_src, v_force, 'assignment', NULL, x.instance_id, NULL, x.database_name)) THEN
    v_why := format('conflict: a target''s assignment was entered by hand; %s does not unassign it unless forced', v_src);
  ELSIF v_op = 'unmark' AND EXISTS (SELECT 1 FROM pgvigil.app_targets_of(v_t) x
           WHERE pgvigil.app_conflict(v_src, v_force, 'mark', NULL, x.instance_id, NULL, x.database_name)) THEN
    v_why := format('conflict: a target''s ''not an application'' mark was set by hand; %s does not unmark it unless forced', v_src);
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'app_' || coalesce(v_op, 'unknown'), 'application ' || coalesce(v_app::text, '-'), 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;

  FOR t IN SELECT * FROM pgvigil.app_targets_of(v_t) ORDER BY n LOOP
    IF v_op = 'assign' THEN
      SELECT a.app_id, a.environment INTO v_cur FROM pgvigil.app_assignments a
       WHERE a.instance_id = t.instance_id AND coalesce(a.database_name, '') = coalesce(t.database_name, '');
      -- an import's re-assign that changes nothing: no write, no audit row, its source kept (task 312, D4)
      CONTINUE WHEN v_src <> 'entered' AND FOUND AND v_cur.app_id = v_app AND (NOT v_envg OR v_cur.environment IS NOT DISTINCT FROM v_env);
      INSERT INTO pgvigil.app_assignments AS a (instance_id, database_name, app_id, environment, engine_db_id, last_seen, source, set_at, set_by)
      VALUES (t.instance_id, t.database_name, v_app, v_env,
              CASE WHEN t.database_name IS NOT NULL THEN pgvigil.app_db_id(t.instance_id, t.database_name) END,
              CASE WHEN t.database_name IS NOT NULL THEN now() END, v_src, now(), v_user)
      ON CONFLICT (instance_id, coalesce(database_name, '')) DO UPDATE SET
        app_id = EXCLUDED.app_id, environment = CASE WHEN v_envg THEN EXCLUDED.environment ELSE a.environment END,
        engine_db_id = EXCLUDED.engine_db_id, last_seen = EXCLUDED.last_seen, source = EXCLUDED.source, set_at = now(), set_by = EXCLUDED.set_by;
    ELSIF v_op = 'unassign' THEN
      DELETE FROM pgvigil.app_assignments a
       WHERE a.instance_id = t.instance_id AND coalesce(a.database_name, '') = coalesce(t.database_name, '') AND a.app_id = v_app;
    ELSIF v_op = 'mark' THEN
      CONTINUE WHEN v_src <> 'entered' AND EXISTS (SELECT 1 FROM pgvigil.app_not_application m
                                                   WHERE m.instance_id = t.instance_id AND m.database_name = t.database_name);
      INSERT INTO pgvigil.app_not_application AS m (instance_id, database_name, set_by, source) VALUES (t.instance_id, t.database_name, v_user, v_src)
      ON CONFLICT (instance_id, database_name) DO UPDATE SET source = EXCLUDED.source, set_at = now(), set_by = EXCLUDED.set_by;
    ELSE
      DELETE FROM pgvigil.app_not_application m WHERE m.instance_id = t.instance_id AND m.database_name = t.database_name;
    END IF;
    v_done := v_done + 1;
    PERFORM pgvigil.admin_log(v_user, v_cli, 'app_' || v_op,
      format('instance %s%s', t.instance_id, CASE WHEN t.database_name IS NOT NULL THEN ' database ' || t.database_name ELSE '' END), 'done',
      CASE WHEN v_op IN ('assign', 'unassign') THEN format('application %s (%s) %s', v_app, v_name, v_op || 'ed')
           ELSE v_op || 'ed not an application' END);
  END LOOP;
  RETURN jsonb_build_object('outcome', 'done', 'detail',
                            format('%s target(s) %s', v_done, v_op || 'ed') || CASE WHEN v_done < v_n THEN format(', %s unchanged', v_n - v_done) ELSE '' END,
                            'targets', v_n, 'written', v_done);
END $$;

-- a cell that looks like a credential: a password / secret / token / key assignment, a URL with user:password@, a
-- query parameter named for a secret, an Azure account or shared access key, a PEM private key, a bearer token (task
-- 312, D5: such a line is refused and its text never echoed; review A, m3: one cell at a time - import_app_file)
CREATE OR REPLACE FUNCTION pgvigil.app_secret_shaped(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(p, '') ~* '(password|passwd|pwd|secret|token|api[_ -]?key|access[_ -]?key|private[_ -]?key|accountkey|sharedaccesskey)[[:space:]]*[=:]'
      OR coalesce(p, '') ~ '://[^/@[:space:]:]+:[^/@[:space:]]*@'
      OR coalesce(p, '') ~* '[?&;](token|key|sig|signature|secret|password|pwd|auth|access_token|api_key|apikey)='
      OR coalesce(p, '') ~* '-----BEGIN [A-Z ]*PRIVATE KEY-----'
      OR coalesce(p, '') ~* 'bearer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}'
$$;

-- the round trip's rows (task 312, D1): every active server (level server) and its databases - present ones (no
-- template, no SQL Server snapshot, no system database) and absent ones an assignment or a mark still names - with
-- the own application, its environment, the application's tier / description / CMDB link, the mark, and export-only
-- the inherited application, absent since, the source and when it was set. Contacts never (A14).
CREATE OR REPLACE FUNCTION pgvigil.app_inventory()
RETURNS TABLE (level text, instance text, engine text, database text, application text, environment text, tier text,
               description text, cmdb_url text, not_an_application text, inherited_from text, absent_since timestamptz,
               source text, set_at timestamptz, instance_id int) LANGUAGE sql STABLE AS $$
  WITH present AS (
    SELECT d.instance_id, d.datname AS name FROM pgvigil.databases d WHERE d.is_present AND NOT coalesce(d.is_template, false)
    UNION
    SELECT o.instance_id, o.database_name FROM pgvigil.mssql_database_option o WHERE o.is_present AND NOT o.is_snapshot
  ), named AS (
    SELECT a.instance_id, a.database_name AS name FROM pgvigil.app_assignments a WHERE a.database_name IS NOT NULL
    UNION
    SELECT m.instance_id, m.database_name FROM pgvigil.app_not_application m
  ), dbs AS (
    SELECT p.instance_id, p.name, true AS present FROM present p
    UNION ALL
    SELECT n.instance_id, n.name, false FROM named n
     WHERE NOT EXISTS (SELECT 1 FROM present p WHERE p.instance_id = n.instance_id AND p.name = n.name)
  )
  SELECT 'server', i.name, i.engine, '', coalesce(ap.name, ''), coalesce(a.environment, ''), coalesce(ap.tier::text, ''),
         coalesce(ap.description, ''), coalesce(ap.cmdb_url, ''), '', '', NULL::timestamptz, coalesce(a.source, ''), a.set_at, i.instance_id
    FROM pgvigil.instances i
    LEFT JOIN pgvigil.app_assignments a ON a.instance_id = i.instance_id AND a.database_name IS NULL
    LEFT JOIN pgvigil.app_applications ap ON ap.app_id = a.app_id
   WHERE i.is_active
  UNION ALL
  SELECT 'database', i.name, i.engine, d.name, coalesce(ap.name, ''), coalesce(a.environment, ''), coalesce(ap.tier::text, ''),
         coalesce(ap.description, ''), coalesce(ap.cmdb_url, ''),
         CASE WHEN m.instance_id IS NOT NULL THEN 'yes' ELSE '' END,
         CASE WHEN a.app_id IS NULL THEN coalesce(sp.name, '') ELSE '' END,
         CASE WHEN NOT d.present THEN coalesce(
           (SELECT max(x.snapshot_at) FROM pgvigil.databases x WHERE x.instance_id = d.instance_id AND x.datname = d.name AND NOT x.is_present),
           (SELECT max(x.snapshot_at) FROM pgvigil.mssql_database_option x WHERE x.instance_id = d.instance_id AND x.database_name = d.name AND NOT x.is_present),
           a.last_seen, a.set_at, m.set_at) END,
         coalesce(a.source, m.source, ''), coalesce(a.set_at, m.set_at), i.instance_id
    FROM dbs d
    JOIN pgvigil.instances i ON i.instance_id = d.instance_id AND i.is_active
    LEFT JOIN pgvigil.app_assignments a ON a.instance_id = d.instance_id AND a.database_name = d.name
    LEFT JOIN pgvigil.app_applications ap ON ap.app_id = a.app_id
    LEFT JOIN pgvigil.app_assignments s ON s.instance_id = d.instance_id AND s.database_name IS NULL
    LEFT JOIN pgvigil.app_applications sp ON sp.app_id = s.app_id
    LEFT JOIN pgvigil.app_not_application m ON m.instance_id = d.instance_id AND m.database_name = d.name
   WHERE NOT pgvigil.app_system_db(d.name)
   ORDER BY 2, 1 DESC, 4
$$;

-- THE planner of a file import (task 312, D3): one import at a time (a second is refused in words, never queued), under
-- 0136's write lock; every line matched and judged set-based in two temp tables this call makes (never a caller's: a
-- table of that name already there fails the call); a digest over the plan and the matched state (never last_seen or
-- engine_db_id, which the collector's list reads move); dry = the preview, nothing written and no audit row; else the
-- digest must be the preview's, the ticked items (force) a subset of its conflicts, and the writes go through
-- import_app_application / import_app_assign in a fixed order (applications by name, then targets by instance and
-- database), every one checked before the next; one summary audit row. payload: {ui_user, client, source_name, dry,
-- digest, force: [item ids], file_kind, rows: [{line, why (a refusal the parser made: a formula cell, a NUL), level,
-- instance, engine, database, application, environment, tier, description, cmdb_url, not_an_application}]}.
CREATE OR REPLACE FUNCTION pgvigil.import_app_file(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli   text := p_payload->>'client';
  v_sname text := lower(btrim(coalesce(nullif(p_payload->>'source_name', ''), 'file')));
  v_src   text;
  v_dry   boolean := coalesce(p_payload->>'dry', 'true') <> 'false';
  v_dig   text := nullif(p_payload->>'digest', '');
  v_kind  text := left(coalesce(nullif(p_payload->>'file_kind', ''), 'file'), 20);
  v_rows  jsonb := CASE WHEN jsonb_typeof(p_payload->'rows') = 'array' THEN p_payload->'rows' ELSE '[]'::jsonb END;
  v_force text[];
  v_bad   text;
  v_plan  jsonb;
  v_hash  text;
  v_items jsonb;
  v_cnt   jsonb;
  v_tags  int;
  v_res   jsonb;
  v_pay   jsonb;
  v_ra    record;
  v_rb    record;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_app_file: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF NOT pg_try_advisory_xact_lock(hashtext('pgvigil.app_import')) THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'another import is running now: try again when it has ended (an import never waits behind another)');
  END IF;
  -- the page's writes wait only for an apply, never for a preview (review B, m3): an apply plans under the write lock
  IF NOT v_dry THEN
    PERFORM pg_advisory_xact_lock(hashtext('pgvigil.app_writes'));
  END IF;
  IF v_sname !~ '^[a-z0-9_.-]{1,40}$' THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'a source name is 1 to 40 of a-z, 0-9, _ . - (it is written as import:<name> on every field it sets)');
  END IF;
  v_src := 'import:' || v_sname;
  IF jsonb_array_length(v_rows) = 0 THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'the file holds no line to read');
  ELSIF jsonb_array_length(v_rows) > 20000 THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('%s lines: at most 20000 in one file', jsonb_array_length(v_rows)));
  END IF;
  SELECT coalesce(array_agg(x), '{}') INTO v_force
    FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_payload->'force') = 'array' THEN p_payload->'force' ELSE '[]'::jsonb END) x;

  -- the lines (Go has parsed the file: CSV's formula guard undone, line ends made LF)
  CREATE TEMP TABLE app_imp_r (
    line int, lvl text, inst text, eng text, db text, app text, env text, tier text, descr text, url text, naa text,
    iid int, iname text, iengine text, iactive boolean, dbname text, dbpresent boolean, unk text, why text, note text,
    own_app int, own_env text, own_src text, own_set timestamptz, srv_app int, srv_name text, srv_src text, mark_src text,
    akey text, tapp int, op1 text, op2 text, c1 boolean DEFAULT false, c2 boolean DEFAULT false, outcome text, words text,
    sec boolean DEFAULT false
  ) ON COMMIT DROP;
  INSERT INTO pg_temp.app_imp_r (line, why, lvl, inst, eng, db, app, env, tier, descr, url, naa)
  SELECT x.line, nullif(x.why, ''), lower(btrim(coalesce(x.level, ''))), btrim(coalesce(x.instance, '')), lower(btrim(coalesce(x.engine, ''))),
         coalesce(x.database, ''), btrim(coalesce(x.application, '')), btrim(coalesce(x.environment, '')), btrim(coalesce(x.tier, '')),
         coalesce(x.description, ''), btrim(coalesce(x.cmdb_url, '')), lower(btrim(coalesce(x.not_an_application, '')))
    FROM jsonb_to_recordset(v_rows) AS x(line int, why text, level text, instance text, engine text, database text, application text,
                                         environment text, tier text, description text, cmdb_url text, not_an_application text);
  -- every join keys on the line: a line number given twice (or none) refuses the request (review A, M4)
  SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_temp.app_imp_r WHERE line IS NULL) THEN 'a line has no number in the request'
              ELSE format('line %s comes twice in the request', min(x.line)) END INTO v_bad
    FROM (SELECT line FROM pg_temp.app_imp_r WHERE line IS NOT NULL GROUP BY line HAVING count(*) > 1) x
  HAVING count(*) > 0 OR EXISTS (SELECT 1 FROM pg_temp.app_imp_r WHERE line IS NULL);
  IF v_bad IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_bad || ': each line is numbered once (save the file again; nothing was written)');
  END IF;
  -- '(none)' in any case is the unassign token (review A, m2)
  UPDATE pg_temp.app_imp_r r SET app = '(none)' WHERE lower(r.app) = '(none)' AND r.app <> '(none)';
  -- statistics at each stage (t-im-g2 F13: 20000 lines previewed in 79 s): a fresh temp table has none and autovacuum
  -- never reaches one, so the joins below were planned blind; analyzed again once a stage fills the columns the next
  -- stage joins on (the server match fills iid, the database match dbname, the planning op1 / outcome)
  ANALYZE pg_temp.app_imp_r;

  -- a credential-shaped cell: the line refused, its text never echoed (D5)
  UPDATE pg_temp.app_imp_r r SET why = 'a cell looks like a credential (a password, a token or a key): nothing of this line is read', sec = true
   WHERE EXISTS (SELECT 1 FROM unnest(ARRAY[r.inst, r.eng, r.db, r.app, r.env, r.tier, r.descr, r.url, r.naa]) c WHERE pgvigil.app_secret_shaped(c));
  UPDATE pg_temp.app_imp_r r SET lvl = CASE WHEN r.db = '' THEN 'server' ELSE 'database' END WHERE r.lvl = '';
  UPDATE pg_temp.app_imp_r r SET why = 'level is server or database' WHERE r.why IS NULL AND r.lvl NOT IN ('server', 'database');
  UPDATE pg_temp.app_imp_r r SET why = 'a line names its server (instance)' WHERE r.why IS NULL AND r.inst = '';
  UPDATE pg_temp.app_imp_r r SET why = 'a server line (level server) names no database' WHERE r.why IS NULL AND r.lvl = 'server' AND r.db <> '';
  UPDATE pg_temp.app_imp_r r SET why = 'a database line (level database) names its database' WHERE r.why IS NULL AND r.lvl = 'database' AND r.db = '';

  -- the server: its exact name, else the one name equal ignoring case (F4); never made
  UPDATE pg_temp.app_imp_r r SET iid = i.instance_id, iname = i.name, iengine = i.engine, iactive = i.is_active
    FROM pgvigil.instances i WHERE r.inst <> '' AND i.name = r.inst;
  UPDATE pg_temp.app_imp_r r SET iid = i.instance_id, iname = i.name, iengine = i.engine, iactive = i.is_active
    FROM pgvigil.instances i
   WHERE r.iid IS NULL AND r.inst <> '' AND lower(i.name) = lower(r.inst)
     AND (SELECT count(*) FROM pgvigil.instances j WHERE lower(j.name) = lower(r.inst)) = 1;
  UPDATE pg_temp.app_imp_r r SET why = CASE WHEN (SELECT count(*) FROM pgvigil.instances j WHERE lower(j.name) = lower(r.inst)) > 1
                                            THEN format('%s matches more than one server ignoring case: write it exactly', r.inst)
                                            ELSE format('no server named %s in pgvigil: an import never makes a server', r.inst) END,
                                 unk = 'server'
   WHERE r.why IS NULL AND r.iid IS NULL;
  UPDATE pg_temp.app_imp_r r SET why = format('%s is not an active server', r.iname) WHERE r.why IS NULL AND NOT r.iactive;
  UPDATE pg_temp.app_imp_r r SET eng = CASE WHEN r.eng IN ('postgresql', 'pg') THEN 'postgres'
                                            WHEN r.eng IN ('mssql', 'sql server', 'sql_server') THEN 'sqlserver' ELSE r.eng END;
  UPDATE pg_temp.app_imp_r r SET why = format('engine %s is not the server''s (%s)', r.eng, r.iengine)
   WHERE r.why IS NULL AND r.eng <> '' AND r.eng <> r.iengine;
  ANALYZE pg_temp.app_imp_r;

  -- the database: among the server's present databases and the absent ones still named; exact, else the one equal
  -- ignoring case; else unknown (listed, never made)
  WITH cand AS (   -- every name the server holds now (present) or still names (absent), set-based: joins, no per-line scan
    SELECT x.instance_id, x.name, bool_or(x.present) AS present FROM (
      SELECT d.instance_id, d.datname AS name, true AS present FROM pgvigil.databases d WHERE d.is_present AND NOT coalesce(d.is_template, false)
      UNION ALL SELECT o.instance_id, o.database_name, true FROM pgvigil.mssql_database_option o WHERE o.is_present AND NOT o.is_snapshot
      UNION ALL SELECT a.instance_id, a.database_name, false FROM pgvigil.app_assignments a WHERE a.database_name IS NOT NULL
      UNION ALL SELECT m.instance_id, m.database_name, false FROM pgvigil.app_not_application m) x
     WHERE x.instance_id IN (SELECT r.iid FROM pg_temp.app_imp_r r WHERE r.why IS NULL AND r.lvl = 'database')
     GROUP BY x.instance_id, x.name
  ), ex AS (
    SELECT r.line, c.name, c.present FROM pg_temp.app_imp_r r JOIN cand c ON c.instance_id = r.iid AND c.name = r.db
     WHERE r.why IS NULL AND r.lvl = 'database'
  ), ci AS (
    SELECT r.line, min(c.name) AS name, bool_or(c.present) AS present
      FROM pg_temp.app_imp_r r JOIN cand c ON c.instance_id = r.iid AND lower(c.name) = lower(r.db)
     WHERE r.why IS NULL AND r.lvl = 'database' AND NOT EXISTS (SELECT 1 FROM ex WHERE ex.line = r.line)
     GROUP BY r.line HAVING count(*) = 1
  ), pick AS (SELECT * FROM ex UNION ALL SELECT * FROM ci)
  UPDATE pg_temp.app_imp_r r SET dbname = p.name, dbpresent = p.present
    FROM pick p WHERE p.line = r.line;
  UPDATE pg_temp.app_imp_r r SET unk = 'database', note = format('no database %s on %s as last read: listed, never made', r.db, r.iname)
   WHERE r.why IS NULL AND r.lvl = 'database' AND r.dbname IS NULL;
  UPDATE pg_temp.app_imp_r r SET why = 'a system database never takes an application'
   WHERE r.why IS NULL AND pgvigil.app_system_db(coalesce(r.dbname, r.db));

  -- the cells
  UPDATE pg_temp.app_imp_r r SET env = CASE lower(r.env) WHEN 'dr' THEN 'DR' ELSE lower(r.env) END
   WHERE lower(r.env) IN ('production', 'staging', 'test', 'development', 'dr');
  UPDATE pg_temp.app_imp_r r SET why = CASE
      WHEN r.app NOT IN ('', '(none)') AND NOT pgvigil.app_name_ok(r.app)
        THEN 'an application name is 1 to 100 bytes with no comma or control character and no space at either end'
      WHEN r.env <> '' AND r.env NOT IN ('production', 'staging', 'test', 'development', 'DR')
        THEN 'environment is production, staging, test, development or DR'
      WHEN r.tier <> '' AND r.tier !~ '^[1-4]$' THEN 'tier is 1, 2, 3 or 4'
      WHEN r.url <> '' AND NOT pgvigil.app_url_ok(r.url) THEN 'cmdb_url is an http(s) link of at most 500 characters with no user or password in it'
      WHEN length(r.descr) > 2000 THEN 'a description is at most 2000 characters'
      WHEN r.naa NOT IN ('', 'yes', 'no') THEN 'not_an_application is yes, no or blank'
      WHEN r.naa <> '' AND r.lvl = 'server' THEN 'only a database is marked not an application, never a whole server'
      WHEN r.app <> '' AND r.naa = 'yes' THEN 'an application and not_an_application yes on one line: say one of them'
    END
   WHERE r.why IS NULL;
  UPDATE pg_temp.app_imp_r r SET note = concat_ws('; ', r.note, 'environment, tier, description and cmdb_url are read only with an application')
   WHERE r.why IS NULL AND r.app IN ('', '(none)') AND (r.env <> '' OR r.tier <> '' OR r.descr <> '' OR r.url <> '');
  -- one line per target
  UPDATE pg_temp.app_imp_r r SET why = format('the same %s as line %s', CASE WHEN r.lvl = 'server' THEN 'server' ELSE 'database' END, d.first)
    FROM (SELECT x.iid, coalesce(x.dbname, x.db) AS k, min(x.line) AS first FROM pg_temp.app_imp_r x
           WHERE x.why IS NULL GROUP BY 1, 2 HAVING count(*) > 1) d
   WHERE r.why IS NULL AND r.iid = d.iid AND coalesce(r.dbname, r.db) = d.k AND r.line > d.first;

  -- the matched state (the digest holds it): the own assignment, the server's, the mark
  UPDATE pg_temp.app_imp_r r SET own_app = x.app_id, own_env = x.environment, own_src = x.source, own_set = x.set_at
    FROM pgvigil.app_assignments x
   WHERE r.why IS NULL AND r.unk IS NULL AND x.instance_id = r.iid
     AND coalesce(x.database_name, '') = CASE WHEN r.lvl = 'server' THEN '' ELSE r.dbname END;
  UPDATE pg_temp.app_imp_r r SET srv_app = x.app_id, srv_src = x.source, srv_name = ap.name
    FROM pgvigil.app_assignments x JOIN pgvigil.app_applications ap ON ap.app_id = x.app_id
   WHERE r.why IS NULL AND r.unk IS NULL AND r.lvl = 'database' AND x.instance_id = r.iid AND x.database_name IS NULL;
  UPDATE pg_temp.app_imp_r r SET mark_src = m.source
    FROM pgvigil.app_not_application m
   WHERE r.why IS NULL AND r.unk IS NULL AND r.lvl = 'database' AND m.instance_id = r.iid AND m.database_name = r.dbname;
  -- an absent database is assigned, re-assigned or marked on the page only: such a line is refused before it names an
  -- application item, so a line refused later neither adds an application nor feeds its fields (review A, M3)
  UPDATE pg_temp.app_imp_r r SET why = format('%s is absent (gone since its last read): only the page changes it', r.dbname)
   WHERE r.why IS NULL AND r.unk IS NULL AND r.lvl = 'database' AND NOT r.dbpresent
     AND ((r.app NOT IN ('', '(none)') AND (r.own_app IS NULL OR (r.env <> '' AND r.env IS DISTINCT FROM r.own_env)
                                             OR NOT EXISTS (SELECT 1 FROM pgvigil.app_applications ap WHERE ap.app_id = r.own_app AND lower(ap.name) = lower(r.app))))
          OR (r.naa = 'yes' AND r.mark_src IS NULL));
  UPDATE pg_temp.app_imp_r r SET akey = lower(r.app) WHERE r.why IS NULL AND r.unk IS NULL AND r.app NOT IN ('', '(none)');
  ANALYZE pg_temp.app_imp_r;

  -- the application items: one per name; a field two lines give differently refuses the item
  CREATE TEMP TABLE app_imp_a (
    akey text, id text, name text, lines int[], tiers text[], descrs text[], urls text[], app_id int, version int,
    cur_tier text, cur_descr text, cur_url text, chg text[] DEFAULT '{}', conf text[] DEFAULT '{}', outcome text, words text
  ) ON COMMIT DROP;
  INSERT INTO pg_temp.app_imp_a (akey, name, lines, tiers, descrs, urls)
  SELECT r.akey, (array_agg(r.app ORDER BY r.line))[1], array_agg(r.line ORDER BY r.line),
         coalesce(array_agg(DISTINCT r.tier) FILTER (WHERE r.tier <> ''), '{}'),
         coalesce(array_agg(DISTINCT r.descr) FILTER (WHERE r.descr <> ''), '{}'),
         coalesce(array_agg(DISTINCT r.url) FILTER (WHERE r.url <> ''), '{}')
    FROM pg_temp.app_imp_r r WHERE r.akey IS NOT NULL GROUP BY r.akey;
  UPDATE pg_temp.app_imp_a a SET id = 'a' || x.n FROM (SELECT akey, row_number() OVER (ORDER BY akey) n FROM pg_temp.app_imp_a) x WHERE x.akey = a.akey;
  UPDATE pg_temp.app_imp_a a SET app_id = ap.app_id, version = ap.version, name = ap.name, cur_tier = coalesce(ap.tier::text, ''),
         cur_descr = coalesce(ap.description, ''), cur_url = coalesce(ap.cmdb_url, '')
    FROM pgvigil.app_applications ap WHERE lower(ap.name) = a.akey;
  ANALYZE pg_temp.app_imp_a;
  UPDATE pg_temp.app_imp_a a SET outcome = 'refused', words = format('%s differ between its lines (%s): one value per application',
           array_to_string(ARRAY[CASE WHEN cardinality(a.tiers) > 1 THEN 'tier' END, CASE WHEN cardinality(a.descrs) > 1 THEN 'description' END,
                                 CASE WHEN cardinality(a.urls) > 1 THEN 'cmdb_url' END], ', '),
           array_to_string(a.lines, ', '))
   WHERE cardinality(a.tiers) > 1 OR cardinality(a.descrs) > 1 OR cardinality(a.urls) > 1;
  UPDATE pg_temp.app_imp_a a SET outcome = 'add', words = format('a new application %s', a.name)
   WHERE a.outcome IS NULL AND a.app_id IS NULL;
  UPDATE pg_temp.app_imp_a a SET chg = array_remove(ARRAY[
           CASE WHEN cardinality(a.tiers) = 1 AND a.tiers[1] <> a.cur_tier THEN 'tier' END,
           CASE WHEN cardinality(a.descrs) = 1 AND a.descrs[1] <> a.cur_descr THEN 'description' END,
           CASE WHEN cardinality(a.urls) = 1 AND a.urls[1] <> a.cur_url THEN 'cmdb_url' END], NULL)
   WHERE a.outcome IS NULL;
  UPDATE pg_temp.app_imp_a a SET conf = coalesce((SELECT array_agg(f) FROM unnest(a.chg) f
                                                  WHERE pgvigil.app_conflict(v_src, false, 'field', 'application', a.app_id, f, NULL)), '{}')
   WHERE a.outcome IS NULL;
  UPDATE pg_temp.app_imp_a a SET
    outcome = CASE WHEN cardinality(a.conf) > 0 THEN 'conflict' WHEN cardinality(a.chg) > 0 THEN 'change' ELSE 'unchanged' END,
    words = CASE WHEN cardinality(a.conf) > 0 THEN format('%s: %s entered by hand%s (changed only when ticked)', a.name, array_to_string(a.conf, ', '),
                                                          CASE WHEN cardinality(a.chg) > cardinality(a.conf)
                                                               THEN '; also changed when ticked: ' || array_to_string(ARRAY(SELECT f FROM unnest(a.chg) f WHERE f <> ALL (a.conf)), ', ')
                                                               ELSE '' END)
                 WHEN cardinality(a.chg) > 0 THEN format('%s: %s changed', a.name, array_to_string(a.chg, ', '))
                 ELSE format('%s: as stored', a.name) END
   WHERE a.outcome IS NULL;
  UPDATE pg_temp.app_imp_r r SET tapp = a.app_id FROM pg_temp.app_imp_a a WHERE a.akey = r.akey;

  -- the target items: the application cell (op1) and the mark (op2)
  UPDATE pg_temp.app_imp_r r SET why = format('its application %s is refused (see its item)', r.app)
    FROM pg_temp.app_imp_a a WHERE r.why IS NULL AND a.akey = r.akey AND a.outcome = 'refused' AND a.app_id IS NULL;
  UPDATE pg_temp.app_imp_r r SET
    op1 = CASE WHEN r.app = '(none)' AND r.own_app IS NOT NULL THEN 'unassign'
               WHEN r.akey IS NULL THEN NULL
               WHEN r.own_app IS NULL THEN 'assign'
               WHEN r.own_app IS DISTINCT FROM r.tapp OR (r.env <> '' AND r.env IS DISTINCT FROM r.own_env) THEN 'reassign' END,
    op2 = CASE WHEN r.naa = 'yes' AND r.mark_src IS NULL THEN 'mark' WHEN r.naa = 'no' AND r.mark_src IS NOT NULL THEN 'unmark' END
   WHERE r.why IS NULL AND r.unk IS NULL;
  UPDATE pg_temp.app_imp_r r SET why = format('%s is absent (gone since its last read): only the page changes it', r.dbname)
   WHERE r.why IS NULL AND r.lvl = 'database' AND NOT r.dbpresent AND (r.op1 IN ('assign', 'reassign') OR r.op2 = 'mark');
  UPDATE pg_temp.app_imp_r r SET
    c1 = (r.op1 IN ('unassign', 'reassign') AND r.own_src = 'entered')
         OR (r.op1 = 'assign' AND r.lvl = 'database' AND r.srv_app IS NOT NULL AND r.srv_app IS DISTINCT FROM r.tapp AND r.srv_src = 'entered'),
    c2 = (r.op2 = 'unmark' AND r.mark_src = 'entered')
   WHERE r.why IS NULL AND r.unk IS NULL;
  UPDATE pg_temp.app_imp_r r SET
    outcome = CASE WHEN r.why IS NOT NULL THEN 'refused' WHEN r.unk IS NOT NULL THEN 'unknown'
                   WHEN r.c1 OR r.c2 THEN 'conflict' WHEN r.op1 IS NOT NULL OR r.op2 IS NOT NULL THEN 'change' ELSE 'unchanged' END,
    words = CASE WHEN r.why IS NOT NULL THEN r.why WHEN r.unk IS NOT NULL THEN r.note ELSE concat_ws('; ',
      CASE r.op1 WHEN 'assign' THEN format('assign %s', r.app) || CASE WHEN r.c1 THEN format(' (its server''s application %s was entered by hand: only when ticked)', r.srv_name) ELSE '' END
                 WHEN 'reassign' THEN format('%s to %s%s', CASE WHEN r.own_app IS DISTINCT FROM r.tapp THEN 'reassign' ELSE 'environment' END, r.app,
                                             CASE WHEN r.env <> '' THEN ' (' || r.env || ')' ELSE '' END)
                                      || CASE WHEN r.c1 THEN ' (entered by hand: only when ticked)' ELSE '' END
                 WHEN 'unassign' THEN 'unassign' || CASE WHEN r.c1 THEN ' (entered by hand: only when ticked)' ELSE '' END END,
      CASE WHEN r.app = '(none)' AND r.op1 IS NULL THEN
             CASE WHEN r.srv_name IS NOT NULL THEN format('inherits %s from its server: (none) changes nothing', r.srv_name)
                  ELSE 'has no application of its own: (none) changes nothing' END END,
      CASE r.op2 WHEN 'mark' THEN 'mark not an application' WHEN 'unmark' THEN 'unmark' || CASE WHEN r.c2 THEN ' (marked by hand: only when ticked)' ELSE '' END END,
      CASE WHEN (r.c1 OR r.c2) AND r.op1 IS NOT NULL AND r.op2 IS NOT NULL THEN 'the whole line only when ticked' END,
      r.note) END;
  ANALYZE pg_temp.app_imp_r;

  -- the plan and its digest: the lines as read, what each matched and its state, the applications, the outcomes
  SELECT jsonb_build_object('source', v_src,
           'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('line', r.line, 'lvl', r.lvl, 'inst', r.inst, 'eng', r.eng, 'db', r.db, 'app', r.app,
                      'env', r.env, 'tier', r.tier, 'descr', r.descr, 'url', r.url, 'naa', r.naa, 'iid', r.iid, 'dbname', r.dbname, 'present', r.dbpresent,
                      'own', jsonb_build_array(r.own_app, r.own_env, r.own_src, r.own_set), 'srv', jsonb_build_array(r.srv_app, r.srv_src),
                      'mark', r.mark_src, 'out', r.outcome, 'ops', jsonb_build_array(r.op1, r.op2, r.c1, r.c2)) ORDER BY r.line) FROM pg_temp.app_imp_r r), '[]'),
           'apps', coalesce((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'app_id', a.app_id, 'version', a.version,
                      'cur', jsonb_build_array(a.cur_tier, a.cur_descr, a.cur_url),
                      'src', (SELECT jsonb_object_agg(s.field, s.source) FROM pgvigil.app_field_source s WHERE s.object_kind = 'application' AND s.object_id = a.app_id),
                      'out', a.outcome, 'chg', a.chg, 'conf', a.conf) ORDER BY a.akey) FROM pg_temp.app_imp_a a), '[]'))
    INTO v_plan;
  v_hash := md5(v_plan::text);

  -- the ticks: a subset of this plan's conflicts
  SELECT min(f) INTO v_bad FROM unnest(v_force) f
   WHERE f NOT IN (SELECT a.id FROM pg_temp.app_imp_a a WHERE a.outcome = 'conflict'
                   UNION ALL SELECT 't' || r.line FROM pg_temp.app_imp_r r WHERE r.outcome = 'conflict');
  -- the items the page lists (every item but the unchanged ones) and the counts
  SELECT coalesce(jsonb_agg(i ORDER BY i->>'kind', (i->>'line')::int, i->>'id'), '[]') INTO v_items FROM (
    SELECT jsonb_build_object('id', a.id, 'kind', 'application', 'line', a.lines[1], 'lines', a.lines, 'application', a.name,
                              'outcome', a.outcome, 'words', a.words) AS i
      FROM pg_temp.app_imp_a a WHERE a.outcome <> 'unchanged'
    UNION ALL
    SELECT jsonb_build_object('id', 't' || r.line, 'kind', 'target', 'line', r.line, 'level', CASE WHEN r.sec THEN '' ELSE r.lvl END,
                              'instance', CASE WHEN r.sec THEN '' ELSE coalesce(r.iname, r.inst) END,
                              'database', CASE WHEN r.sec THEN '' ELSE coalesce(r.dbname, r.db) END,
                              'application', CASE WHEN r.sec THEN '' ELSE r.app END, 'outcome', r.outcome, 'words', r.words)
      FROM pg_temp.app_imp_r r
     WHERE r.outcome <> 'unchanged' OR (r.app = '(none)' AND r.op1 IS NULL)) z;   -- '(none) changes nothing' said (review P, P-3)
  SELECT jsonb_build_object(
           'lines', (SELECT count(*) FROM pg_temp.app_imp_r),
           'applications_added', (SELECT count(*) FROM pg_temp.app_imp_a WHERE outcome = 'add'),
           'applications_changed', (SELECT count(*) FROM pg_temp.app_imp_a WHERE outcome = 'change'),
           'targets_changed', (SELECT count(*) FROM pg_temp.app_imp_r WHERE outcome = 'change'),
           'conflicts', (SELECT count(*) FROM pg_temp.app_imp_a WHERE outcome = 'conflict') + (SELECT count(*) FROM pg_temp.app_imp_r WHERE outcome = 'conflict'),
           'unknown_servers', (SELECT count(*) FROM pg_temp.app_imp_r WHERE unk = 'server'),
           'unknown_databases', (SELECT count(*) FROM pg_temp.app_imp_r WHERE unk = 'database' AND outcome = 'unknown'),
           'refused', (SELECT count(*) FROM pg_temp.app_imp_r WHERE outcome = 'refused' AND unk IS DISTINCT FROM 'server')
                    + (SELECT count(*) FROM pg_temp.app_imp_a WHERE outcome = 'refused'),
           'unchanged', (SELECT count(*) FROM pg_temp.app_imp_r WHERE outcome = 'unchanged')) INTO v_cnt;
  -- the servers whose application: tag moves with the changes (conflicts not counted): their tag-scoped thresholds,
  -- acknowledgements, rules and contacts' routes cover them differently after
  WITH chg AS (
    SELECT r.iid, CASE WHEN r.lvl = 'server' THEN NULL ELSE r.dbname END AS db, CASE WHEN r.op1 = 'unassign' THEN NULL ELSE r.akey END AS akey, r.dbpresent
      FROM pg_temp.app_imp_r r WHERE r.outcome = 'change' AND r.op1 IS NOT NULL
  ), cur AS (
    SELECT x.instance_id AS iid, x.database_name AS db, lower(ap.name) AS akey FROM pgvigil.app_assignments x JOIN pgvigil.app_applications ap ON ap.app_id = x.app_id
     WHERE x.instance_id IN (SELECT iid FROM chg) AND (x.database_name IS NULL OR pgvigil.app_db_present(x.instance_id, x.database_name))
  ), aft AS (
    SELECT c.iid, c.db, c.akey FROM cur c WHERE NOT EXISTS (SELECT 1 FROM chg g WHERE g.iid = c.iid AND coalesce(g.db, '') = coalesce(c.db, ''))
    UNION ALL SELECT g.iid, g.db, g.akey FROM chg g WHERE g.akey IS NOT NULL AND (g.db IS NULL OR g.dbpresent)
  )
  SELECT count(*) INTO v_tags FROM (SELECT DISTINCT iid FROM chg) s
   WHERE (SELECT array_agg(DISTINCT akey ORDER BY akey) FROM cur WHERE cur.iid = s.iid) IS DISTINCT FROM
         (SELECT array_agg(DISTINCT akey ORDER BY akey) FROM aft WHERE aft.iid = s.iid);
  v_cnt := v_cnt || jsonb_build_object('servers_whose_tag_moves', v_tags);

  IF v_bad IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('item %s is ticked but is not a conflict of this file now: preview again (nothing was written)', v_bad),
                              'digest', v_hash, 'counts', v_cnt, 'items', v_items);
  END IF;
  IF v_dry THEN
    DROP TABLE pg_temp.app_imp_r; DROP TABLE pg_temp.app_imp_a;
    RETURN jsonb_build_object('outcome', 'preview', 'source', v_src, 'digest', v_hash, 'counts', v_cnt, 'items', v_items);
  END IF;
  IF v_dig IS DISTINCT FROM v_hash THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'the repository (or the file) changed since the preview: preview again (nothing was written)',
                              'digest', v_hash, 'counts', v_cnt);
  END IF;

  -- the writes, in a fixed order; each answer checked before the next (a refusal here stops the whole import)
  FOR v_ra IN SELECT * FROM pg_temp.app_imp_a x WHERE x.outcome IN ('add', 'change') OR (x.outcome = 'conflict' AND x.id = ANY (v_force)) ORDER BY x.akey LOOP
    v_pay := jsonb_build_object('ui_user', v_user, 'client', v_cli, 'source', v_src);
    IF cardinality(v_ra.tiers) = 1 AND (v_ra.outcome = 'add' OR 'tier' = ANY (v_ra.chg)) THEN v_pay := v_pay || jsonb_build_object('tier', v_ra.tiers[1]::int); END IF;
    IF cardinality(v_ra.descrs) = 1 AND (v_ra.outcome = 'add' OR 'description' = ANY (v_ra.chg)) THEN v_pay := v_pay || jsonb_build_object('description', v_ra.descrs[1]); END IF;
    IF cardinality(v_ra.urls) = 1 AND (v_ra.outcome = 'add' OR 'cmdb_url' = ANY (v_ra.chg)) THEN v_pay := v_pay || jsonb_build_object('cmdb_url', v_ra.urls[1]); END IF;
    IF v_ra.outcome = 'add' THEN
      v_res := pgvigil.import_app_application(p_at, v_pay || jsonb_build_object('op', 'add', 'name', v_ra.name));
      IF v_res->>'outcome' IS DISTINCT FROM 'done' THEN
        RAISE EXCEPTION 'the import stopped at application %: % (nothing was written)', v_ra.name, v_res->>'detail' USING ERRCODE = 'P0001';
      END IF;
      UPDATE pg_temp.app_imp_a x SET app_id = (v_res->>'app_id')::int WHERE x.akey = v_ra.akey;
      UPDATE pg_temp.app_imp_r r SET tapp = (v_res->>'app_id')::int WHERE r.akey = v_ra.akey;
    ELSE
      v_res := pgvigil.import_app_application(p_at, v_pay || jsonb_build_object('op', 'edit', 'app_id', v_ra.app_id, 'version', v_ra.version,
                                                                              'force', v_ra.outcome = 'conflict'));
      IF v_res->>'outcome' IS DISTINCT FROM 'done' THEN
        RAISE EXCEPTION 'the import stopped at application %: % (nothing was written)', v_ra.name, v_res->>'detail' USING ERRCODE = 'P0001';
      END IF;
    END IF;
  END LOOP;
  -- the targets: batches of at most 500 per (operation, application, environment, ticked), in instance and database order
  FOR v_rb IN
    WITH t AS (
      SELECT r.*, 't' || r.line = ANY (v_force) AS forced FROM pg_temp.app_imp_r r
       WHERE r.outcome = 'change' OR (r.outcome = 'conflict' AND 't' || r.line = ANY (v_force))
    ), ops AS (
      SELECT 1 AS k, 'assign' AS op, t.tapp AS app, t.env, t.forced, t.iid, CASE WHEN t.lvl = 'server' THEN NULL ELSE t.dbname END AS db
        FROM t WHERE t.op1 IN ('assign', 'reassign')
      UNION ALL SELECT 2, 'unassign', t.own_app, '', t.forced, t.iid, CASE WHEN t.lvl = 'server' THEN NULL ELSE t.dbname END FROM t WHERE t.op1 = 'unassign'
      UNION ALL SELECT 3, 'mark', NULL, '', false, t.iid, t.dbname FROM t WHERE t.op2 = 'mark'
      UNION ALL SELECT 4, 'unmark', NULL, '', t.forced, t.iid, t.dbname FROM t WHERE t.op2 = 'unmark'
    ), numbered AS (
      SELECT o.*, (row_number() OVER (PARTITION BY o.k, o.app, o.env, o.forced ORDER BY o.iid, o.db NULLS FIRST) - 1) / 500 AS chunk FROM ops o
    )
    SELECT n.k, n.op, n.app, n.env, n.forced, n.chunk,
           jsonb_agg(jsonb_build_object('instance_id', n.iid, 'database', n.db) ORDER BY n.iid, n.db NULLS FIRST) AS targets
      FROM numbered n GROUP BY n.k, n.op, n.app, n.env, n.forced, n.chunk
     ORDER BY n.k, n.app NULLS FIRST, n.env, n.forced, n.chunk
  LOOP
    v_pay := jsonb_build_object('ui_user', v_user, 'client', v_cli, 'source', v_src, 'op', v_rb.op, 'targets', v_rb.targets, 'force', v_rb.forced);
    IF v_rb.app IS NOT NULL THEN v_pay := v_pay || jsonb_build_object('app_id', v_rb.app); END IF;
    IF v_rb.op = 'assign' AND v_rb.env <> '' THEN v_pay := v_pay || jsonb_build_object('environment', v_rb.env); END IF;
    v_res := pgvigil.import_app_assign(p_at, v_pay);
    IF v_res->>'outcome' IS DISTINCT FROM 'done' THEN
      RAISE EXCEPTION 'the import stopped at a % of % target(s): % (nothing was written)', v_rb.op, jsonb_array_length(v_rb.targets), v_res->>'detail' USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'app_import', format('a %s file of %s line(s)', v_kind, v_cnt->>'lines'), 'done',
    format('%s: %s application(s) added, %s changed; %s target(s) changed; %s conflict(s) taken of %s; %s unknown server(s), %s unknown database(s), %s refused',
           v_src, v_cnt->>'applications_added', v_cnt->>'applications_changed', v_cnt->>'targets_changed', cardinality(v_force),
           v_cnt->>'conflicts', v_cnt->>'unknown_servers', v_cnt->>'unknown_databases', v_cnt->>'refused'));
  DROP TABLE pg_temp.app_imp_r; DROP TABLE pg_temp.app_imp_a;
  RETURN jsonb_build_object('outcome', 'done', 'source', v_src, 'digest', v_hash, 'counts', v_cnt,
                            'detail', format('imported: %s application(s) added, %s changed, %s target(s) changed, %s conflict(s) taken',
                                             v_cnt->>'applications_added', v_cnt->>'applications_changed', v_cnt->>'targets_changed', cardinality(v_force)));
END $$;
