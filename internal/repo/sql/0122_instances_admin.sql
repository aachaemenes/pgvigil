-- 0122: instances added, removed and synced in the tool (task 204; task 103 part 1).
--
-- Admin > Instances adds, edits, disables, removes and tests an instance; the instances of pgvigil.yaml stay
-- where they are and the page shows them read-only ('from the file'). A credential never enters this database:
-- serve writes it to a file of its own under the config folder (mode 0600 on Linux, a DPAPI machine-scope blob on
-- Windows) and the row keeps only the reference (file:<path> or dpapi:<path>), which the collector resolves on
-- every run. Every write goes through an import_ function (SECURITY DEFINER by apply_roles, called on the actions
-- door's audit login as the thresholds are) and is audited, refused attempts included.
--
-- The collector takes a change without a restart: each write that changes what it collects bumps
-- admin_inventory_state.generation in the same transaction; the collector reads admin_inventory_generation()
-- every 15 s and, when it moved, admin_inventory() (both SECURITY DEFINER and granted to pgvigil_collector here:
-- the collector's login has no SELECT on tables).
--
-- Sync sources (a SQL Server Central Management Server, a DBA Dash repository's instance list, a server list
-- file; PostgreSQL: a pg_service.conf file, a CSV) are read by serve on their interval into admin_proposals: a
-- source never adds or removes by itself. A new server is proposed; a click approves (an instance is made with
-- the source's credential reference) or ignores it; a server gone from its source is marked gone, never removed.
-- A CMS's groups come in as tags group:<name>.

CREATE TABLE IF NOT EXISTS pgvigil.admin_inventory_state (
  one         boolean PRIMARY KEY DEFAULT true CHECK (one),
  generation  bigint NOT NULL DEFAULT 0,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO pgvigil.admin_inventory_state (one) VALUES (true) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS pgvigil.admin_instances (
  name          text PRIMARY KEY CHECK (name ~ '^[A-Za-z0-9][A-Za-z0-9_.@-]{0,62}$'),
  engine        text NOT NULL CHECK (engine IN ('postgres', 'sqlserver')),
  platform      text NOT NULL DEFAULT 'auto',
  -- the reference only: a file serve wrote (0600) or a DPAPI blob; never a connection string
  dsn_ref       text NOT NULL CHECK (dsn_ref ~ '^(file|dpapi):/' OR dsn_ref ~ '^(file|dpapi):[A-Za-z]:\\'),
  auth          text NOT NULL CHECK (auth IN ('sql', 'windows', 'entra', 'password', 'pgpass')),
  host          text NOT NULL,
  port          int CHECK (port BETWEEN 1 AND 65535),
  dbname        text,
  login         text,
  -- the driver options as given (TrustServerCertificate=true, sslmode=require): never a password (refused on write)
  options       text CHECK (options IS NULL OR options !~* '(password|pwd)'),
  tags          text[] NOT NULL DEFAULT '{}',
  disabled      boolean NOT NULL DEFAULT false,
  source        text NOT NULL DEFAULT 'page',
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text NOT NULL,
  tested_at     timestamptz,
  tested_ok     boolean,
  tested_detail text
);
COMMENT ON TABLE pgvigil.admin_instances IS 'Instances added in Admin > Instances (task 204); dsn_ref names the credential file, never its content.';

-- a removed instance stays inactive although a collection that was already running when it was removed calls
-- ensure_instance (which sets is_active) once more: the collector stops its loops at its next read of the list
-- (15 s) and a run in flight ends within minutes; past 5 minutes a name collected again (added to pgvigil.yaml)
-- is active as before
CREATE TABLE IF NOT EXISTS pgvigil.admin_removed (
  name        text PRIMARY KEY,
  removed_at  timestamptz NOT NULL DEFAULT now(),
  removed_by  text NOT NULL
);
CREATE OR REPLACE FUNCTION pgvigil.admin_keep_removed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_active AND NOT OLD.is_active
     AND (EXISTS (SELECT 1 FROM pgvigil.admin_removed r WHERE r.name = NEW.name AND r.removed_at > now() - interval '5 minutes')
          -- a disabled page instance stays inactive against a run in flight (enable: the next run sets it active)
          OR EXISTS (SELECT 1 FROM pgvigil.admin_instances a WHERE a.name = NEW.name AND a.disabled)) THEN
    NEW.is_active := false;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS admin_keep_removed ON pgvigil.instances;
CREATE TRIGGER admin_keep_removed BEFORE UPDATE OF is_active ON pgvigil.instances
  FOR EACH ROW EXECUTE FUNCTION pgvigil.admin_keep_removed();

CREATE TABLE IF NOT EXISTS pgvigil.admin_audit (
  audit_id  bigserial PRIMARY KEY,
  at        timestamptz NOT NULL DEFAULT now(),
  ui_user   text NOT NULL,
  client    text,
  op        text NOT NULL,
  target    text,
  outcome   text NOT NULL CHECK (outcome IN ('done', 'refused')),
  detail    text
);
CREATE INDEX IF NOT EXISTS admin_audit_at ON pgvigil.admin_audit (at);

CREATE TABLE IF NOT EXISTS pgvigil.admin_sources (
  name          text PRIMARY KEY CHECK (name ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$'),
  kind          text NOT NULL CHECK (kind IN ('cms', 'dbadash', 'sqlserver_list', 'pg_service', 'pg_csv')),
  -- cms: the CMS login's reference (file:/dpapi:); dbadash: a dbadash: repository name of pgvigil.yaml;
  -- the file kinds: the file's path on the serve host
  ref           text NOT NULL,
  -- the credential an approved server gets (its own file is written from it): file:/dpapi:, or null for a
  -- source whose entries carry their own (pg_service.conf, a CSV with user and password_file)
  credential_ref text CHECK (credential_ref IS NULL OR credential_ref ~ '^(file|dpapi):'),
  auth          text NOT NULL DEFAULT 'sql' CHECK (auth IN ('sql', 'windows', 'entra', 'password', 'pgpass')),
  every_s       int NOT NULL DEFAULT 3600 CHECK (every_s BETWEEN 60 AND 604800),
  enabled       boolean NOT NULL DEFAULT true,
  last_run      timestamptz,
  last_ok       timestamptz,
  last_error    text,
  last_count    int,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.admin_proposals (
  proposal_id   bigserial PRIMARY KEY,
  source        text NOT NULL REFERENCES pgvigil.admin_sources(name) ON DELETE CASCADE,
  server        text NOT NULL,             -- the source's own key: a CMS server_name, a list line's host, a service name
  engine        text NOT NULL CHECK (engine IN ('postgres', 'sqlserver')),
  host          text NOT NULL,
  port          int,
  dbname        text,
  login         text,
  display_name  text,
  tags          text[] NOT NULL DEFAULT '{}',
  state         text NOT NULL DEFAULT 'proposed' CHECK (state IN ('proposed', 'approved', 'ignored')),
  gone          boolean NOT NULL DEFAULT false,
  first_seen    timestamptz NOT NULL DEFAULT now(),
  last_seen     timestamptz NOT NULL DEFAULT now(),
  gone_at       timestamptz,
  decided_at    timestamptz,
  decided_by    text,
  instance_name text,
  UNIQUE (source, server)
);

CREATE OR REPLACE FUNCTION pgvigil.admin_bump() RETURNS bigint LANGUAGE sql AS $$
  UPDATE pgvigil.admin_inventory_state SET generation = generation + 1, changed_at = now() WHERE one RETURNING generation
$$;

CREATE OR REPLACE FUNCTION pgvigil.admin_log(p_user text, p_client text, p_op text, p_target text, p_outcome text, p_detail text)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.admin_audit (ui_user, client, op, target, outcome, detail)
  VALUES (p_user, left(p_client, 100), p_op, left(p_target, 200), p_outcome, left(p_detail, 2000))
$$;

-- the collector's two reads
CREATE OR REPLACE FUNCTION pgvigil.admin_inventory_generation() RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT generation FROM pgvigil.admin_inventory_state WHERE one
$$;
-- one statement: the generation and the list it stands for (one row of NULLs beside it when the list is empty)
CREATE OR REPLACE FUNCTION pgvigil.admin_inventory()
RETURNS TABLE (name text, engine text, platform text, dsn_ref text, tags text[], disabled boolean, generation bigint)
LANGUAGE sql STABLE AS $$
  SELECT a.name, a.engine, a.platform, a.dsn_ref, a.tags, a.disabled, s.generation
    FROM pgvigil.admin_inventory_state s LEFT JOIN pgvigil.admin_instances a ON true
   WHERE s.one
   ORDER BY a.name
$$;

-- admin_read_rows: a source's read as rows, one per server (a server listed twice, e.g. a CMS registration in two
-- groups, carries the tags of both); a plain function over its argument, no table: the SECURITY DEFINER caller
-- below reads it with its search_path pinned, so nothing of the caller's session can stand in for it
CREATE OR REPLACE FUNCTION pgvigil.admin_read_rows(p_rows jsonb)
RETURNS TABLE (server text, engine text, host text, port int, dbname text, login text, display_name text, tags text[])
LANGUAGE sql IMMUTABLE AS $$
  SELECT left(r.server, 300), min(r.engine), min(left(r.host, 300)), min(r.port), min(r.dbname), min(r.login), min(r.display_name),
         coalesce(array_agg(DISTINCT t ORDER BY t) FILTER (WHERE btrim(t) <> ''), '{}')
    FROM jsonb_to_recordset(coalesce(p_rows, '[]')) AS r(server text, engine text, host text, port int, dbname text, login text, display_name text, tags jsonb)
    LEFT JOIN LATERAL jsonb_array_elements_text(CASE WHEN jsonb_typeof(r.tags) = 'array' THEN r.tags ELSE '[]' END) t ON true
   WHERE coalesce(r.server, '') <> '' AND r.engine IN ('postgres', 'sqlserver') AND coalesce(r.host, '') <> ''
   GROUP BY left(r.server, 300)
$$;

-- import_admin_instance: op add | edit | disable | enable | remove | tested. The payload's keys: ui_user, client
-- (serve's), name, engine, platform, dsn_ref, auth, host, port, dbname, login, tags (array), file_names (the
-- names pgvigil.yaml holds: refused), ok and detail (tested). Answers {outcome, detail, generation}.
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
  ELSIF v_op IN ('add', 'edit') AND coalesce(p_payload->>'auth', '') NOT IN ('sql', 'windows', 'entra', 'password', 'pgpass') THEN
    v_why := 'auth is sql, windows or entra (SQL Server), password or pgpass (PostgreSQL)';
  ELSIF v_op IN ('add', 'edit') AND ((v_eng = 'sqlserver') <> (p_payload->>'auth' IN ('sql', 'windows', 'entra'))) THEN
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
  ELSIF v_op = 'edit' THEN
    UPDATE pgvigil.admin_instances SET platform = coalesce(nullif(p_payload->>'platform', ''), platform), dsn_ref = v_ref, auth = p_payload->>'auth',
           host = btrim(p_payload->>'host'), port = nullif(p_payload->>'port', '')::int, dbname = nullif(p_payload->>'dbname', ''),
           login = nullif(p_payload->>'login', ''), options = nullif(p_payload->>'options', ''), tags = coalesce(v_tags, tags), updated_at = p_at, updated_by = v_user
     WHERE name = v_name;
  ELSIF v_op IN ('disable', 'enable') THEN
    UPDATE pgvigil.admin_instances SET disabled = (v_op = 'disable'), updated_at = p_at, updated_by = v_user WHERE name = v_name;
    -- a disabled instance leaves the fleet pages' stale and failing checks (they read is_active); enable needs
    -- nothing: the next run's ensure_instance sets it active again
    IF v_op = 'disable' THEN
      UPDATE pgvigil.instances SET is_active = false WHERE name = v_name;
    END IF;
  ELSIF v_op = 'remove' THEN
    DELETE FROM pgvigil.admin_instances WHERE name = v_name;
    -- its history stays; the fleet pages read is_active (kept false against a run in flight: admin_keep_removed)
    INSERT INTO pgvigil.admin_removed (name, removed_at, removed_by) VALUES (v_name, p_at, v_user)
      ON CONFLICT (name) DO UPDATE SET removed_at = EXCLUDED.removed_at, removed_by = EXCLUDED.removed_by;
    UPDATE pgvigil.instances SET is_active = false WHERE name = v_name;
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

-- import_admin_source: op add | remove | enable | disable; payload: ui_user, client, name, kind, ref,
-- credential_ref, auth, every_s.
CREATE OR REPLACE FUNCTION pgvigil.import_admin_source(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op   text := p_payload->>'op';
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli  text := p_payload->>'client';
  v_name text := btrim(coalesce(p_payload->>'name', ''));
  v_kind text := p_payload->>'kind';
  v_cred text := nullif(p_payload->>'credential_ref', '');
  v_why  text;
  v_have boolean;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_source: no ui_user' USING ERRCODE = '22023';
  END IF;
  v_have := EXISTS (SELECT 1 FROM pgvigil.admin_sources WHERE name = v_name);
  IF v_op IS NULL OR v_op NOT IN ('add', 'remove', 'enable', 'disable') THEN
    v_why := 'op must be add, remove, enable or disable';
  ELSIF v_name !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$' THEN
    v_why := 'a source name is 1 to 63 letters, digits, _ . or -';
  ELSIF v_op = 'add' AND v_have THEN
    v_why := format('a source %s exists already', v_name);
  ELSIF v_op <> 'add' AND NOT v_have THEN
    v_why := format('no source %s', v_name);
  ELSIF v_op = 'add' AND coalesce(v_kind, '') NOT IN ('cms', 'dbadash', 'sqlserver_list', 'pg_service', 'pg_csv') THEN
    v_why := 'kind is cms, dbadash, sqlserver_list, pg_service or pg_csv';
  ELSIF v_op = 'add' AND coalesce(btrim(p_payload->>'ref'), '') = '' THEN
    v_why := 'ref is required (the CMS login''s file, the DBA Dash repository''s name, or the list file''s path)';
  ELSIF v_op = 'add' AND v_kind = 'cms' AND NOT (p_payload->>'ref' ~ '^(file|dpapi):') THEN
    v_why := 'a CMS source''s ref is the file serve wrote for its login (file: or dpapi:), never a connection string';
  ELSIF v_op = 'add' AND v_cred IS NOT NULL AND v_cred !~ '^(file|dpapi):' THEN
    v_why := 'credential_ref is a file serve wrote (file: or dpapi:)';
  ELSIF v_op = 'add' AND v_kind IN ('cms', 'dbadash', 'sqlserver_list') AND v_cred IS NULL AND coalesce(p_payload->>'auth', 'sql') <> 'windows' THEN
    v_why := 'a SQL Server source needs the login its approved servers are read with (credential_ref), or auth windows';
  ELSIF v_op = 'add' AND coalesce(p_payload->>'every_s', '3600') !~ '^[0-9]{2,6}$' THEN
    v_why := 'every_s is a number of seconds from 60 to 604800';
  ELSIF v_op = 'add' AND (coalesce(p_payload->>'every_s', '3600'))::int NOT BETWEEN 60 AND 604800 THEN
    v_why := 'every_s is a number of seconds from 60 to 604800';
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'source ' || coalesce(v_op, '?'), v_name, 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_op = 'add' THEN
    INSERT INTO pgvigil.admin_sources (name, kind, ref, credential_ref, auth, every_s, created_at, created_by)
    VALUES (v_name, v_kind, btrim(p_payload->>'ref'), v_cred,
            coalesce(nullif(p_payload->>'auth', ''), CASE WHEN v_kind IN ('pg_service', 'pg_csv') THEN 'password' ELSE 'sql' END),
            coalesce(nullif(p_payload->>'every_s', ''), '3600')::int, p_at, v_user);
  ELSIF v_op = 'remove' THEN
    DELETE FROM pgvigil.admin_sources WHERE name = v_name;   -- its proposals with it; approved instances stay
  ELSE
    UPDATE pgvigil.admin_sources SET enabled = (v_op = 'enable') WHERE name = v_name;
  END IF;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'source ' || v_op, v_name, 'done',
    CASE WHEN v_op = 'add' THEN format('%s from %s', v_kind, CASE WHEN v_kind = 'cms' THEN 'its login file' ELSE p_payload->>'ref' END) END);
  RETURN jsonb_build_object('outcome', 'done', 'detail', v_op || ' ' || v_name);
END $$;

-- import_admin_proposals: one read of a source. p_rows is the whole list the source holds now (server, engine,
-- host, port, dbname, login, display_name, tags); a server not in it is marked gone (never removed), one back in
-- it is no longer gone. p_error not null = the read failed: recorded, nothing marked gone. Answers the counts.
CREATE OR REPLACE FUNCTION pgvigil.import_admin_proposals(p_source text, p_at timestamptz, p_rows jsonb, p_error text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_new int := 0; v_gone int := 0; v_back int := 0; v_n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pgvigil.admin_sources WHERE name = p_source) THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('no source %s', p_source));
  END IF;
  IF p_error IS NOT NULL THEN
    UPDATE pgvigil.admin_sources SET last_run = p_at, last_error = left(p_error, 1000) WHERE name = p_source;
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'the read failed: recorded, nothing marked gone');
  END IF;
  SELECT count(*) INTO v_new FROM pgvigil.admin_read_rows(p_rows) a
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.admin_proposals p WHERE p.source = p_source AND p.server = a.server);
  SELECT count(*) INTO v_back FROM pgvigil.admin_proposals p JOIN pgvigil.admin_read_rows(p_rows) a ON a.server = p.server WHERE p.source = p_source AND p.gone;
  INSERT INTO pgvigil.admin_proposals AS p (source, server, engine, host, port, dbname, login, display_name, tags, first_seen, last_seen)
  SELECT p_source, a.server, a.engine, a.host, a.port, a.dbname, a.login, a.display_name, a.tags, p_at, p_at FROM pgvigil.admin_read_rows(p_rows) a
  ON CONFLICT (source, server) DO UPDATE
     SET engine = EXCLUDED.engine, host = EXCLUDED.host, port = EXCLUDED.port, dbname = EXCLUDED.dbname, login = EXCLUDED.login,
         display_name = EXCLUDED.display_name, tags = EXCLUDED.tags, last_seen = p_at, gone = false, gone_at = NULL;
  UPDATE pgvigil.admin_proposals p SET gone = true, gone_at = p_at
   WHERE p.source = p_source AND NOT p.gone AND NOT EXISTS (SELECT 1 FROM pgvigil.admin_read_rows(p_rows) a WHERE a.server = p.server);
  GET DIAGNOSTICS v_gone = ROW_COUNT;
  SELECT count(*) INTO v_n FROM pgvigil.admin_read_rows(p_rows);
  UPDATE pgvigil.admin_sources SET last_run = p_at, last_ok = p_at, last_error = NULL, last_count = v_n WHERE name = p_source;
  RETURN jsonb_build_object('outcome', 'done', 'read', v_n, 'new', v_new, 'gone', v_gone, 'back', v_back);
END $$;

-- import_admin_decision: op approve | ignore | unignore on a proposal; approve carries the instance's name and
-- the dsn_ref serve wrote for it from the source's credential, and makes the instance (source '<kind>:<source>').
CREATE OR REPLACE FUNCTION pgvigil.import_admin_decision(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op   text := p_payload->>'op';
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli  text := p_payload->>'client';
  v_p    pgvigil.admin_proposals%ROWTYPE;
  v_s    pgvigil.admin_sources%ROWTYPE;
  v_why  text;
  v_res  jsonb;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_decision: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'proposal_id', '') ~ '^[0-9]{1,18}$' THEN
    SELECT * INTO v_p FROM pgvigil.admin_proposals WHERE proposal_id = (p_payload->>'proposal_id')::bigint;
  END IF;
  SELECT * INTO v_s FROM pgvigil.admin_sources WHERE name = v_p.source;
  IF v_op IS NULL OR v_op NOT IN ('approve', 'ignore', 'unignore') THEN
    v_why := 'op must be approve, ignore or unignore';
  ELSIF v_p.proposal_id IS NULL THEN
    v_why := format('no proposal %s', coalesce(p_payload->>'proposal_id', '(none)'));
  ELSIF v_op = 'approve' AND v_p.state <> 'proposed' THEN
    v_why := format('the proposal is %s, not proposed', v_p.state);
  ELSIF v_op = 'approve' AND v_p.gone THEN
    v_why := 'the server is gone from its source: it is not approved';
  ELSIF v_op = 'ignore' AND v_p.state <> 'proposed' THEN
    v_why := format('the proposal is %s, not proposed', v_p.state);
  ELSIF v_op = 'unignore' AND v_p.state <> 'ignored' THEN
    v_why := 'the proposal is not ignored';
  END IF;
  IF v_why IS NULL AND v_op = 'approve' THEN
    v_res := pgvigil.import_admin_instance(p_at, jsonb_build_object('op', 'add', 'ui_user', v_user, 'client', v_cli,
      'name', p_payload->>'name', 'engine', v_p.engine, 'dsn_ref', p_payload->>'dsn_ref', 'auth', v_s.auth, 'host', v_p.host,
      'port', v_p.port, 'dbname', v_p.dbname, 'login', v_p.login, 'tags', to_jsonb(v_p.tags), 'source', v_s.kind || ':' || v_s.name,
      'file_names', p_payload->'file_names'));
    IF v_res->>'outcome' <> 'done' THEN
      v_why := v_res->>'detail';
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'proposal ' || coalesce(v_op, '?'), coalesce(v_p.source || '/' || v_p.server, p_payload->>'proposal_id'), 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  UPDATE pgvigil.admin_proposals SET state = CASE v_op WHEN 'approve' THEN 'approved' WHEN 'ignore' THEN 'ignored' ELSE 'proposed' END,
         decided_at = p_at, decided_by = v_user, instance_name = CASE WHEN v_op = 'approve' THEN p_payload->>'name' END
   WHERE proposal_id = v_p.proposal_id;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'proposal ' || v_op, v_p.source || '/' || v_p.server, 'done',
    CASE WHEN v_op = 'approve' THEN 'as instance ' || (p_payload->>'name') END);
  RETURN jsonb_build_object('outcome', 'done', 'detail', v_op || ' ' || v_p.server, 'generation', v_res->'generation');
END $$;

-- the collector's two reads run as the owner (its login holds no SELECT on tables); apply_roles keeps these grants
-- (it revokes from PUBLIC only and adds the reader's)
ALTER FUNCTION pgvigil.admin_inventory_generation() SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp;
ALTER FUNCTION pgvigil.admin_inventory() SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_collector') THEN
    GRANT EXECUTE ON FUNCTION pgvigil.admin_inventory_generation() TO pgvigil_collector;
    GRANT EXECUTE ON FUNCTION pgvigil.admin_inventory() TO pgvigil_collector;
  END IF;
END $$;
