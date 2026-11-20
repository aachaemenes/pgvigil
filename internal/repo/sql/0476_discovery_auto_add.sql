-- 0476_discovery_auto_add: RELNOTES L237 - a cloud discovery source that adds the servers it finds by itself (the
-- lead's 05:32: every rec of the design 3c2bb2562; the migration number the lead's).
--
-- Two keys, both off: pgvigil.yaml's doors.discovery_auto_add (serve passes it as auto_add_door - a migration cannot
-- read the file) and each cloud source's own auto_add, ticked by an admin in the source's form and audited as the
-- source's add or edit is. Serve's auto step after a read (internal/web/autoadd.go) takes each proposed server of such
-- a source through the page's own approve as auto:<source>, never with a tick: the approve tried and rolled back first
-- (what import_admin_decision refuses - the master user as the login, a server that pauses when idle, a server already
-- an instance, a taken name, an Entra-only server - is never connected to), then the page's Test, then the approve.
-- Those, a failed Test (tried again an hour later, doubling to a day: auto_fails, auto_tested_at) and the servers past
-- one read's bounds stay proposals, each with its words in auto_note; import_admin_auto_add keeps those notes and the
-- Tests' counts and writes one 'source read' audit row that counts them - and refuses, clearing the notes, when the
-- source no longer adds by itself. A gone server is never removed by itself (task 205's rule, unchanged).
--
-- Above 0300, so this file makes its own objects (the join-file rule) - its columns and import_admin_auto_add - and
-- RE-MAKES import_admin_source whole from its NEWEST text (0123_discovery.sql) with the switch, and import_admin_decision
-- whole from its NEWEST text (0123's) with its proposal read FOR UPDATE: two j17 named checks (a later re-make of either
-- on another branch carries these lines). apply_roles gives both import_
-- functions SECURITY DEFINER and serve's login, as every page write.

ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS auto_add boolean NOT NULL DEFAULT false;
ALTER TABLE pgvigil.admin_proposals ADD COLUMN IF NOT EXISTS auto_note text;
ALTER TABLE pgvigil.admin_proposals ADD COLUMN IF NOT EXISTS auto_fails int NOT NULL DEFAULT 0;
ALTER TABLE pgvigil.admin_proposals ADD COLUMN IF NOT EXISTS auto_tested_at timestamptz;

-- import_admin_source as 0123's, with auto_add on add and edit: on only on a cloud source and, when it is turned on,
-- with the door open (in words otherwise; turning it off needs no door); off clears the source's auto notes and its
-- Tests' counts; the audit's detail names the switch only when it changes.
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
  -- L237: the source's switch (null = not named) and pgvigil.yaml's doors.discovery_auto_add as serve read it; a payload
  -- without the door is the door shut (coalesce: jsonb_typeof of an absent key is NULL, and NOT NULL would skip the
  -- refusal below - l237-1b's red)
  v_auto boolean := CASE WHEN jsonb_typeof(p_payload->'auto_add') = 'boolean' THEN (p_payload->>'auto_add')::boolean END;
  v_door boolean := coalesce(jsonb_typeof(p_payload->'auto_add_door') = 'boolean' AND (p_payload->>'auto_add_door')::boolean, false);
  v_was  boolean;   -- the switch as the row holds it (null: no such source yet)
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_source: no ui_user' USING ERRCODE = '22023';
  END IF;
  v_have := EXISTS (SELECT 1 FROM pgvigil.admin_sources WHERE name = v_name);
  v_was := (SELECT auto_add FROM pgvigil.admin_sources WHERE name = v_name);
  IF v_op IS NULL OR v_op NOT IN ('add', 'remove', 'enable', 'disable', 'edit') THEN
    v_why := 'op must be add, remove, enable, disable or edit';
  ELSIF v_name !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$' THEN
    v_why := 'a source name is 1 to 63 letters, digits, _ . or -';
  ELSIF v_op = 'add' AND v_have THEN
    v_why := format('a source %s exists already', v_name);
  ELSIF v_op <> 'add' AND NOT v_have THEN
    v_why := format('no source %s', v_name);
  ELSIF v_op = 'add' AND coalesce(v_kind, '') NOT IN ('cms', 'dbadash', 'sqlserver_list', 'pg_service', 'pg_csv', 'aws', 'azure', 'gcp') THEN
    v_why := 'kind is cms, dbadash, sqlserver_list, pg_service, pg_csv, aws, azure or gcp';
  ELSIF v_op = 'add' AND coalesce(btrim(p_payload->>'ref'), '') = '' THEN
    v_why := 'ref is required (the CMS login''s file, the DBA Dash repository''s name, or the list file''s path)';
  ELSIF v_op = 'add' AND v_kind = 'cms' AND NOT (p_payload->>'ref' ~ '^(file|dpapi):') THEN
    v_why := 'a CMS source''s ref is the file serve wrote for its login (file: or dpapi:), never a connection string';
  ELSIF v_op = 'add' AND v_kind IN ('aws', 'azure', 'gcp') AND NOT (p_payload->>'ref' ~ '^(file|dpapi):') THEN
    v_why := 'a cloud source''s ref is the file serve wrote for its settings and credential (file: or dpapi:)';
  ELSIF v_op = 'add' AND v_cred IS NOT NULL AND v_cred !~ '^(file|dpapi):' THEN
    v_why := 'credential_ref is a file serve wrote (file: or dpapi:)';
  ELSIF v_op = 'add' AND v_kind IN ('cms', 'dbadash', 'sqlserver_list') AND v_cred IS NULL AND coalesce(p_payload->>'auth', 'sql') NOT IN ('windows', 'entra-identity') THEN
    v_why := 'a SQL Server source needs the login its approved servers are read with (credential_ref), or auth windows or entra-identity (no secret: the service''s own account, or this host''s managed identity)';
  ELSIF v_op = 'add' AND coalesce(p_payload->>'every_s', '3600') !~ '^[0-9]{2,6}$' THEN
    v_why := 'every_s is a number of seconds from 60 to 604800';
  ELSIF v_op = 'add' AND (coalesce(p_payload->>'every_s', '3600'))::int NOT BETWEEN 60 AND 604800 THEN
    v_why := 'every_s is a number of seconds from 60 to 604800';
  ELSIF v_op IN ('add', 'edit') AND jsonb_typeof(p_payload->'regions') = 'array'
        AND coalesce(CASE WHEN v_op = 'add' THEN v_kind END, (SELECT kind FROM pgvigil.admin_sources WHERE name = v_name)) <> 'aws' THEN
    v_why := 'only an AWS source keeps regions';
  ELSIF v_op IN ('add', 'edit') AND jsonb_typeof(p_payload->'regions') = 'array'
        AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_payload->'regions') r WHERE r !~ '^[a-z0-9]+(-[a-z0-9]+)+$' OR length(r) > 40) THEN
    -- the shape only (a host name's): which partition a region is in is the credentials' answer at the read, never a
    -- name table here (the join's TestNoHardCodedAWSPartition scans this file too)
    v_why := 'a region is lower-case letters and digits in parts joined by hyphens, 40 characters at most';
  ELSIF v_op = 'edit' AND jsonb_typeof(p_payload->'tag_keys') = 'array'
        AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_payload->'tag_keys') k
                     WHERE k !~ '^[a-z0-9_.-]{1,40}$' OR k IN ('cloud', 'region', 'account', 'subscription', 'resource-group', 'project', 'cluster', 'role', 'source-instance', 'source-cluster', 'pool', 'tag')) THEN
    v_why := 'a tag key is 1 to 40 lower-case letters, digits, _ . or -, and not one of pgvigil''s own (cloud, region, account, subscription, resource-group, project, cluster, role, source-instance, source-cluster, pool)';
  ELSIF v_op IN ('add', 'edit') AND v_auto IS TRUE
        AND coalesce(CASE WHEN v_op = 'add' THEN v_kind END, (SELECT kind FROM pgvigil.admin_sources WHERE name = v_name)) NOT IN ('aws', 'azure', 'gcp') THEN
    v_why := 'only a cloud source (aws, azure or gcp) adds the servers it finds by itself';
  ELSIF v_op IN ('add', 'edit') AND v_auto IS TRUE AND v_was IS NOT TRUE AND NOT v_door THEN
    v_why := 'off on this install: doors.discovery_auto_add in pgvigil.yaml lets a cloud source add the servers it finds by itself';
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'source ' || coalesce(v_op, '?'), v_name, 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_op = 'add' THEN
    INSERT INTO pgvigil.admin_sources (name, kind, ref, credential_ref, auth, every_s, created_at, created_by, cloud_regions, auto_add)
    VALUES (v_name, v_kind, btrim(p_payload->>'ref'), v_cred,
            coalesce(nullif(p_payload->>'auth', ''), CASE WHEN v_kind IN ('pg_service', 'pg_csv') THEN 'password' ELSE 'sql' END),
            coalesce(nullif(p_payload->>'every_s', ''), '3600')::int, p_at, v_user,
            CASE WHEN jsonb_typeof(p_payload->'regions') = 'array' AND jsonb_array_length(p_payload->'regions') > 0
                 THEN ARRAY(SELECT DISTINCT r FROM jsonb_array_elements_text(p_payload->'regions') r ORDER BY r) END,
            coalesce(v_auto, false));
  ELSIF v_op = 'remove' THEN
    DELETE FROM pgvigil.admin_sources WHERE name = v_name;   -- its proposals with it; approved instances stay
  ELSIF v_op = 'edit' THEN
    UPDATE pgvigil.admin_sources
       SET cloud_regions = CASE WHEN jsonb_typeof(p_payload->'regions') = 'array'
                                THEN ARRAY(SELECT DISTINCT r FROM jsonb_array_elements_text(p_payload->'regions') r ORDER BY r) ELSE cloud_regions END,
           regions_read_at = CASE WHEN (p_payload->>'swept')::boolean IS TRUE THEN p_at ELSE regions_read_at END,
           -- an admin's edit that removes a kept region drops that region's notes (no read asks it again); a region
           -- never kept (refused at a sweep) keeps its note, and a sweep's own edit drops none (its notes are newer)
           note_items = CASE WHEN jsonb_typeof(p_payload->'regions') = 'array' AND (p_payload->>'swept')::boolean IS NOT TRUE
                             THEN coalesce((SELECT jsonb_agg(x ORDER BY o) FROM jsonb_array_elements(note_items) WITH ORDINALITY AS t(x, o)
                                             WHERE NOT (x->>'key' = ANY (coalesce(cloud_regions, '{}'))
                                                        AND NOT x->>'key' IN (SELECT jsonb_array_elements_text(p_payload->'regions')))), '[]')
                             ELSE note_items END,
           tag_keys = CASE WHEN jsonb_typeof(p_payload->'tag_keys') = 'array'
                           THEN ARRAY(SELECT DISTINCT k FROM jsonb_array_elements_text(p_payload->'tag_keys') k ORDER BY k) ELSE tag_keys END,
           auto_add = coalesce(v_auto, auto_add)
     WHERE name = v_name;
    IF v_auto IS FALSE THEN
      UPDATE pgvigil.admin_proposals SET auto_note = NULL, auto_fails = 0, auto_tested_at = NULL
       WHERE source = v_name AND (auto_note IS NOT NULL OR auto_fails <> 0 OR auto_tested_at IS NOT NULL);
    END IF;
    UPDATE pgvigil.admin_sources SET last_notes = pgvigil.admin_notes_text(note_items) WHERE name = v_name;
  ELSE
    UPDATE pgvigil.admin_sources SET enabled = (v_op = 'enable') WHERE name = v_name;
  END IF;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'source ' || v_op, v_name, 'done',
    CASE WHEN v_op = 'add' THEN format('%s from %s', v_kind, CASE WHEN v_kind IN ('cms', 'aws', 'azure', 'gcp') THEN 'its settings file' ELSE p_payload->>'ref' END)
         WHEN v_op = 'edit' THEN format('regions %s, tag keys %s%s', coalesce(p_payload->'regions', '"unchanged"'), coalesce(p_payload->'tag_keys', '"unchanged"'),
                                        CASE WHEN (p_payload->>'swept')::boolean IS TRUE THEN ' (a sweep)' ELSE '' END) END
    || CASE WHEN v_auto IS NOT DISTINCT FROM coalesce(v_was, false) OR v_auto IS NULL THEN ''
            WHEN v_auto THEN '; adds what it finds by itself' ELSE '; no longer adds what it finds' END);
  RETURN jsonb_build_object('outcome', 'done', 'detail', v_op || ' ' || v_name);
END $$;

-- import_admin_decision as 0123's (its NEWEST text), its proposal read FOR UPDATE: the auto step and a person - or two
-- people - may approve one proposal at one moment under two names, and both used to pass 'already an instance' (a
-- plain EXISTS) and add two instances; now the second waits and is refused 'the proposal is approved, not proposed'.
-- A j17 named check like import_admin_source's: a later re-make of import_admin_decision on another branch carries the
-- FOR UPDATE.
CREATE OR REPLACE FUNCTION pgvigil.import_admin_decision(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op   text := p_payload->>'op';
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli  text := p_payload->>'client';
  v_p    pgvigil.admin_proposals%ROWTYPE;
  v_s    pgvigil.admin_sources%ROWTYPE;
  v_why  text;
  v_need text;
  v_res  jsonb;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_decision: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'proposal_id', '') ~ '^[0-9]{1,18}$' THEN
    -- the proposal's row held until this decision ends: a second decision of it waits, then reads it decided and is
    -- refused below in these words, so two approves at one moment never add two instances of one server
    SELECT * INTO v_p FROM pgvigil.admin_proposals WHERE proposal_id = (p_payload->>'proposal_id')::bigint FOR UPDATE;
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
  -- the design pass of task 205: a cloud server's login is never the master user without a tick; an Entra-only
  -- server takes an Entra login only; an auto-pausing server, or one already an instance (its host and port, or
  -- its resource id), needs a tick. 'needs' names the tick the page asks for.
  ELSIF v_op = 'approve' AND v_p.entra_only AND v_p.engine = 'postgres' THEN
    v_why := 'the server takes Microsoft Entra sign-ins only (' || coalesce(v_p.note, 'Entra only') || '), and pgvigil signs in to PostgreSQL with a password: it cannot be monitored until its password authentication is on';
  ELSIF v_op = 'approve' AND v_p.entra_only AND coalesce(p_payload->>'auth', v_s.auth) NOT IN ('entra', 'entra-identity') THEN
    v_why := 'the server takes Microsoft Entra sign-ins only (' || coalesce(v_p.note, 'Entra only') || '): approve it with an Entra login (a service principal, or this host''s managed identity)';
  ELSIF v_op = 'approve' AND v_p.master_user IS NOT NULL AND lower(coalesce(p_payload->>'login_used', '')) = lower(v_p.master_user)
        AND (p_payload->>'confirm_master')::boolean IS NOT TRUE THEN
    v_need := 'confirm_master';
    v_why := format('the login %s is the server''s master user (every right on it): tick to monitor through it anyway, or give the source a least-privilege login', v_p.master_user);
  ELSIF v_op = 'approve' AND v_p.auto_pause AND (p_payload->>'confirm_autopause')::boolean IS NOT TRUE THEN
    v_need := 'confirm_autopause';
    v_why := format('%s: a collector reading it every minute keeps it from pausing (and billing as running): tick to approve anyway', coalesce(v_p.serverless, 'the server pauses when idle'));
  -- one server: the same host (or the proposal's other address) and the same port, each its engine's default when
  -- blank, and for SQL Server the same database when both name one (each Azure SQL database is its own instance on
  -- one host:1433); or the resource id of a proposal approved already. pgvigil.yaml's instances are not checked (the
  -- repository does not hold their hosts).
  ELSIF v_op = 'approve' AND (p_payload->>'confirm_duplicate')::boolean IS NOT TRUE
        AND (EXISTS (SELECT 1 FROM pgvigil.admin_instances i
                      WHERE lower(i.host) IN (lower(v_p.host), lower(coalesce(v_p.alt_host, v_p.host)))
                        AND coalesce(i.port, CASE i.engine WHEN 'postgres' THEN 5432 ELSE 1433 END) = coalesce(v_p.port, CASE v_p.engine WHEN 'postgres' THEN 5432 ELSE 1433 END)
                        AND NOT (v_p.engine = 'sqlserver' AND nullif(i.dbname, '') IS NOT NULL AND nullif(v_p.dbname, '') IS NOT NULL
                                 AND lower(i.dbname) <> lower(v_p.dbname)))
             OR EXISTS (SELECT 1 FROM pgvigil.admin_proposals q WHERE q.state = 'approved' AND q.proposal_id <> v_p.proposal_id
                          AND q.resource_id IS NOT NULL AND q.resource_id = v_p.resource_id)) THEN
    v_need := 'confirm_duplicate';
    v_why := format('%s%s is already an instance of the page (by its host and port, or its resource id): tick to add it again',
                    v_p.host, coalesce(':' || v_p.port, ''));
  END IF;
  IF v_why IS NULL AND v_op = 'approve' THEN
    v_res := pgvigil.import_admin_instance(p_at, jsonb_build_object('op', 'add', 'ui_user', v_user, 'client', v_cli,
      'name', p_payload->>'name', 'engine', v_p.engine, 'platform', v_p.platform, 'dsn_ref', p_payload->>'dsn_ref', 'auth', coalesce(nullif(p_payload->>'auth', ''), v_s.auth), 'host', v_p.host,
      'port', v_p.port, 'dbname', v_p.dbname,
      -- a managed identity's login is the client id the approve used, or none (the host's own identity): never the
      -- proposal's SQL login, which a later Edit would put into the identity's DSN (the wire review's blocker 2)
      'login', CASE WHEN coalesce(nullif(p_payload->>'auth', ''), v_s.auth) = 'entra-identity' THEN nullif(p_payload->>'login_used', '')
                    ELSE coalesce(nullif(p_payload->>'login_used', ''), v_p.login) END, 'tags', to_jsonb(v_p.tags), 'source', v_s.kind || ':' || v_s.name,
      'file_names', p_payload->'file_names'));
    IF v_res->>'outcome' <> 'done' THEN
      v_why := v_res->>'detail';
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'proposal ' || coalesce(v_op, '?'), coalesce(v_p.source || '/' || v_p.server, p_payload->>'proposal_id'), 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why, 'needs', v_need);
  END IF;
  UPDATE pgvigil.admin_proposals SET state = CASE v_op WHEN 'approve' THEN 'approved' WHEN 'ignore' THEN 'ignored' ELSE 'proposed' END,
         decided_at = p_at, decided_by = v_user, instance_name = CASE WHEN v_op = 'approve' THEN p_payload->>'name' END
   WHERE proposal_id = v_p.proposal_id;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'proposal ' || v_op, v_p.source || '/' || v_p.server, 'done',
    CASE WHEN v_op = 'approve' THEN 'as instance ' || (p_payload->>'name')
           || CASE WHEN (p_payload->>'confirm_master')::boolean IS TRUE AND lower(coalesce(p_payload->>'login_used', '')) = lower(v_p.master_user)
                   THEN ' through the master user ' || v_p.master_user || ' (ticked)' ELSE '' END
           || CASE WHEN v_p.auto_pause THEN ' (auto-pause ticked)' ELSE '' END
           || CASE WHEN (p_payload->>'confirm_duplicate')::boolean IS TRUE THEN ' (already an instance: ticked)' ELSE '' END END);
  RETURN jsonb_build_object('outcome', 'done', 'detail', v_op || ' ' || v_p.server, 'generation', v_res->'generation');
END $$;

-- import_admin_auto_add: the end of one auto step of a source (payload: source, notes [{proposal_id, note}], tested
-- [{proposal_id, ok}], added, person, failed, waiting, errors, stopped). The step's notes replace the source's last
-- ones (a server added, or no longer held back, has none); a Test that failed counts one more in a row, one that passed
-- clears the count; one 'source read' audit row as auto:<source>, beside the read's own. A source that no longer adds
-- by itself (its switch off, or not a cloud source) keeps no note and no count: they are cleared, the audit row says
-- so, and the answer is refused. Each count is digits.
CREATE OR REPLACE FUNCTION pgvigil.import_admin_auto_add(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_src  text := p_payload->>'source';
  v_s    pgvigil.admin_sources%ROWTYPE;
  v_k    text;
  v_n    text;
  v_cnt  text := '';
  v_stop text := left(btrim(coalesce(p_payload->>'stopped', '')), 200);
BEGIN
  SELECT * INTO v_s FROM pgvigil.admin_sources WHERE name = v_src;
  IF v_s.name IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('no source %s', coalesce(v_src, '(none)')));
  END IF;
  FOREACH v_k IN ARRAY ARRAY['added', 'person', 'failed', 'waiting', 'errors'] LOOP
    v_n := coalesce(p_payload->>v_k, '0');
    IF v_n !~ '^[0-9]{1,6}$' THEN
      RETURN jsonb_build_object('outcome', 'refused', 'detail', format('%s is a count (digits), not %s', v_k, left(v_n, 40)));
    END IF;
  END LOOP;
  v_cnt := format('added %s by itself; needs a person %s; the test failed %s; waits for the next read %s; a read failed %s',
                  coalesce(p_payload->>'added', '0'), coalesce(p_payload->>'person', '0'), coalesce(p_payload->>'failed', '0'),
                  coalesce(p_payload->>'waiting', '0'), coalesce(p_payload->>'errors', '0'))
           || CASE WHEN v_stop <> '' THEN '; stopped: ' || v_stop ELSE '' END;
  IF NOT v_s.auto_add OR v_s.kind NOT IN ('aws', 'azure', 'gcp') THEN
    UPDATE pgvigil.admin_proposals SET auto_note = NULL, auto_fails = 0, auto_tested_at = NULL
     WHERE source = v_src AND (auto_note IS NOT NULL OR auto_fails <> 0 OR auto_tested_at IS NOT NULL);
    PERFORM pgvigil.admin_log('auto:' || v_src, NULL, 'source read', v_src, 'refused',
      'the source no longer adds what it finds (its switch is off, or it is not a cloud source): its notes cleared; ' || v_cnt);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('%s no longer adds what it finds: its notes cleared', v_src));
  END IF;
  UPDATE pgvigil.admin_proposals SET auto_note = NULL WHERE source = v_src AND auto_note IS NOT NULL;
  UPDATE pgvigil.admin_proposals p SET auto_note = left(n->>'note', 2000)
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_payload->'notes') = 'array' THEN p_payload->'notes' ELSE '[]' END) n
   WHERE p.source = v_src AND coalesce(n->>'proposal_id', '') ~ '^[0-9]{1,18}$' AND p.proposal_id = (n->>'proposal_id')::bigint;
  UPDATE pgvigil.admin_proposals p
     SET auto_fails = CASE WHEN (t->>'ok')::boolean IS TRUE THEN 0 ELSE p.auto_fails + 1 END, auto_tested_at = p_at
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_payload->'tested') = 'array' THEN p_payload->'tested' ELSE '[]' END) t
   WHERE p.source = v_src AND coalesce(t->>'proposal_id', '') ~ '^[0-9]{1,18}$' AND p.proposal_id = (t->>'proposal_id')::bigint
     AND jsonb_typeof(t->'ok') = 'boolean';
  PERFORM pgvigil.admin_log('auto:' || v_src, NULL, 'source read', v_src, 'done', v_cnt);
  RETURN jsonb_build_object('outcome', 'done', 'detail', format('auto step of %s recorded', v_src));
END $$;
