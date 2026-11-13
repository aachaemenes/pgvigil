-- 0127: auth entra-identity for an instance added on Admin > Instances (CLOUDSQL C1): a SQL Server signed in with the
-- collector host's own Azure managed identity (fedauth=ActiveDirectoryManagedIdentity, internal/mssqlopen), no secret
-- stored anywhere. admin_instances' auth CHECK and import_admin_instance's two auth lines take it; the function is
-- otherwise 0122's, line for line (internal/repo TestAdmin0127IsAdmin0122PlusEntraIdentity holds the two equal: an
-- edit of 0122's import_admin_instance is made here too). Sources keep their auth list (205's 0123 owns
-- import_admin_source).
ALTER TABLE pgvigil.admin_instances DROP CONSTRAINT IF EXISTS admin_instances_auth_check;
ALTER TABLE pgvigil.admin_instances ADD CONSTRAINT admin_instances_auth_check
  CHECK (auth IN ('sql', 'windows', 'entra', 'entra-identity', 'password', 'pgpass'));

CREATE OR REPLACE FUNCTION pgvigil.import_admin_instance(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op    text := p_payload->>'op';
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli   text := p_payload->>'client';
  v_name  text := btrim(coalesce(p_payload->>'name', ''));
  v_eng   text := coalesce(nullif(p_payload->>'engine', ''), 'postgres');
  v_ref   text := p_payload->>'dsn_ref';
  v_tags  text[];
  v_why   text;
  v_gen   bigint;
  v_have  pgvigil.admin_instances%ROWTYPE;
  v_n     int;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_instance: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_payload->'tags') = 'array' THEN
    SELECT coalesce(array_agg(DISTINCT btrim(t) ORDER BY btrim(t)) FILTER (WHERE btrim(t) <> ''), '{}') INTO v_tags
      FROM jsonb_array_elements_text(p_payload->'tags') t;
  END IF;
  SELECT * INTO v_have FROM pgvigil.admin_instances WHERE name = v_name;
  IF v_op IS NULL OR v_op NOT IN ('add', 'edit', 'disable', 'enable', 'remove', 'tested') THEN
    v_why := 'op must be add, edit, disable, enable, remove or tested';
  ELSIF v_name !~ '^[A-Za-z0-9][A-Za-z0-9_.@-]{0,62}$' THEN
    v_why := 'a name is 1 to 63 letters, digits, _ . @ or -, starting with a letter or digit';
  ELSIF jsonb_typeof(p_payload->'file_names') = 'array' AND p_payload->'file_names' ? v_name THEN
    v_why := format('%s is an instance of pgvigil.yaml: it is changed in the file, not here', v_name);
  ELSIF v_op = 'add' AND v_have.name IS NOT NULL THEN
    v_why := format('an instance %s exists already', v_name);
  ELSIF v_op <> 'add' AND v_have.name IS NULL THEN
    v_why := format('no instance %s was added in the page', v_name);
  ELSIF v_op IN ('add', 'edit') AND v_eng NOT IN ('postgres', 'sqlserver') THEN
    v_why := 'engine is postgres or sqlserver';
  ELSIF v_op = 'edit' AND v_eng <> v_have.engine THEN
    v_why := 'an instance keeps its engine: remove it and add it again';
  ELSIF v_op = 'add' AND EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.name = v_name AND i.engine <> v_eng) THEN
    v_why := format('%s is stored as a %s instance: give this server its own name', v_name, (SELECT engine FROM pgvigil.instances WHERE name = v_name));
  ELSIF v_op IN ('add', 'edit') AND (v_ref IS NULL OR NOT (v_ref ~ '^(file|dpapi):/' OR v_ref ~ '^(file|dpapi):[A-Za-z]:\\')) THEN
    v_why := 'dsn_ref is the file serve wrote (file:/path or dpapi:path), never a connection string';
  ELSIF v_op IN ('add', 'edit') AND coalesce(btrim(p_payload->>'host'), '') = '' THEN
    v_why := 'a host is required';
  ELSIF v_op IN ('add', 'edit') AND coalesce(p_payload->>'auth', '') NOT IN ('sql', 'windows', 'entra', 'entra-identity', 'password', 'pgpass') THEN
    v_why := 'auth is sql, windows, entra or entra-identity (SQL Server), password or pgpass (PostgreSQL)';
  ELSIF v_op IN ('add', 'edit') AND ((v_eng = 'sqlserver') <> (p_payload->>'auth' IN ('sql', 'windows', 'entra', 'entra-identity'))) THEN
    v_why := format('auth %s is not one of the %s engine''s', p_payload->>'auth', v_eng);
  ELSIF v_op IN ('add', 'edit') AND coalesce(p_payload->>'port', '') <> '' AND (p_payload->>'port' !~ '^[0-9]{1,5}$' OR (p_payload->>'port')::int NOT BETWEEN 1 AND 65535) THEN
    v_why := 'port is a number from 1 to 65535';
  ELSIF v_op IN ('add', 'edit') AND coalesce(p_payload->>'options', '') ~* '(password|pwd)' THEN
    v_why := 'the driver options hold no password (it goes in the password field, to its own file)';
  ELSIF v_tags IS NOT NULL AND EXISTS (SELECT 1 FROM unnest(v_tags) t WHERE length(t) > 141 OR t ~ '[,[:cntrl:]]'
                                         OR (strpos(t, ':') > 0 AND split_part(t, ':', 1) !~ '^[a-z0-9_.-]{1,40}$')) THEN
    -- config.ParseTag's rule: a key of lower-case letters, digits, _ . - (1..40), a value without a comma or a control character
    v_why := 'a tag is a word or key:value (the key lower-case letters, digits, _ . -; no comma or control character)';
  END IF;

  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'instance ' || coalesce(v_op, '?'), v_name, 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;

  IF v_op = 'add' THEN
    DELETE FROM pgvigil.admin_removed WHERE name = v_name;
    INSERT INTO pgvigil.admin_instances (name, engine, platform, dsn_ref, auth, host, port, dbname, login, options, tags, source, created_at, created_by, updated_at, updated_by)
    VALUES (v_name, v_eng, coalesce(nullif(p_payload->>'platform', ''), 'auto'), v_ref, p_payload->>'auth', btrim(p_payload->>'host'),
            nullif(p_payload->>'port', '')::int, nullif(p_payload->>'dbname', ''), nullif(p_payload->>'login', ''), nullif(p_payload->>'options', ''), coalesce(v_tags, '{}'),
            coalesce(nullif(p_payload->>'source', ''), 'page'), p_at, v_user, p_at, v_user);
    -- active from the add (the join's review, finding 1): a failed connect is recorded for an active row only
    -- (0118's import_connect_failure), and ensure_instance runs only after a connect that succeeded, so a name added
    -- again after a remove, or added while its server is down, would be silent until its server answers. A name
    -- never collected gets its row here (the page's platform, 'auto' until the first read that connects writes the
    -- detected one, its version and tags through ensure_instance), so its first failed connect is recorded too.
    -- admin_keep_removed holds nothing here: the admin_removed row is gone and the page row is not disabled.
    INSERT INTO pgvigil.instances AS i (name, platform, engine, tags)
    VALUES (v_name, coalesce(nullif(p_payload->>'platform', ''), 'auto'), v_eng, coalesce(v_tags, '{}'))
    ON CONFLICT (name) DO UPDATE SET is_active = true WHERE i.engine = EXCLUDED.engine;
  ELSIF v_op = 'edit' THEN
    UPDATE pgvigil.admin_instances SET platform = coalesce(nullif(p_payload->>'platform', ''), platform), dsn_ref = v_ref, auth = p_payload->>'auth',
           host = btrim(p_payload->>'host'), port = nullif(p_payload->>'port', '')::int, dbname = nullif(p_payload->>'dbname', ''),
           login = nullif(p_payload->>'login', ''), options = nullif(p_payload->>'options', ''), tags = coalesce(v_tags, tags), updated_at = p_at, updated_by = v_user
     WHERE name = v_name;
  ELSIF v_op IN ('disable', 'enable') THEN
    UPDATE pgvigil.admin_instances SET disabled = (v_op = 'disable'), updated_at = p_at, updated_by = v_user WHERE name = v_name;
    -- a disabled instance leaves the fleet pages' stale and failing checks (they read is_active); enable makes it
    -- active again at once (the join's review, finding 1: waiting for the next run's ensure_instance left an
    -- instance enabled while its server is down silent - no failed connect recorded, no 'server unreachable'); a
    -- row that is missing is made as the add makes it. admin_keep_removed holds nothing: the page row is not disabled.
    IF v_op = 'disable' THEN
      UPDATE pgvigil.instances SET is_active = false WHERE name = v_name;
    ELSE
      INSERT INTO pgvigil.instances AS i (name, platform, engine, tags)
      VALUES (v_name, coalesce(v_have.platform, 'auto'), v_have.engine, coalesce(v_have.tags, '{}'))
      ON CONFLICT (name) DO UPDATE SET is_active = true WHERE i.engine = EXCLUDED.engine;
    END IF;
  ELSIF v_op = 'remove' THEN
    -- the name's lock to the commit: an insert of the name (a read in flight) waits and then sees admin_removed
    PERFORM pg_advisory_xact_lock(hashtext('pgvigil.instance:' || v_name));
    DELETE FROM pgvigil.admin_instances WHERE name = v_name;
    -- its history stays; the fleet pages read is_active (kept false against a run in flight: admin_keep_removed)
    INSERT INTO pgvigil.admin_removed (name, removed_at, removed_by) VALUES (v_name, p_at, v_user)
      ON CONFLICT (name) DO UPDATE SET removed_at = EXCLUDED.removed_at, removed_by = EXCLUDED.removed_by;
    UPDATE pgvigil.instances SET is_active = false WHERE name = v_name;
    -- a row the add made and no read ever reached (no version, no SQL Server read, nothing but failed connects) goes
    -- with the page's row, so the name can be added again with the other engine (the join's w9e, finding 1); its
    -- 'connect:' rows go with it (ON DELETE CASCADE). A read in flight cannot make it again, active: admin_keep_removed
    -- holds an insert for 5 minutes.
    DELETE FROM pgvigil.instances i
     WHERE i.name = v_name AND i.server_version IS NULL
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_instance m WHERE m.instance_id = i.instance_id)
       AND NOT EXISTS (SELECT 1 FROM pgvigil.collection_dates d WHERE d.instance_id = i.instance_id
                        AND NOT (d.status = 'error' AND d.note LIKE 'connect: %'))
       AND NOT pgvigil.admin_imported(i.instance_id);
    UPDATE pgvigil.admin_proposals SET state = 'proposed', instance_name = NULL, decided_at = p_at, decided_by = v_user WHERE instance_name = v_name;
  ELSIF v_op = 'tested' THEN
    UPDATE pgvigil.admin_instances SET tested_at = p_at, tested_ok = (p_payload->>'ok')::boolean, tested_detail = left(p_payload->>'detail', 1000) WHERE name = v_name;
  END IF;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_op <> 'tested' THEN
    v_gen := pgvigil.admin_bump();
  END IF;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'instance ' || v_op, v_name, 'done',
    CASE v_op WHEN 'tested' THEN CASE WHEN (p_payload->>'ok')::boolean THEN 'connected' ELSE 'failed: ' || left(coalesce(p_payload->>'detail', ''), 500) END
              WHEN 'add' THEN format('%s %s at %s (auth %s)', v_eng, v_name, p_payload->>'host', p_payload->>'auth')
              WHEN 'edit' THEN format('host %s, auth %s, tags %s', p_payload->>'host', p_payload->>'auth', array_to_string(coalesce(v_tags, v_have.tags), ' '))
              ELSE NULL END);
  RETURN jsonb_build_object('outcome', 'done', 'detail', v_op || ' ' || v_name, 'generation', v_gen);
END $$;
