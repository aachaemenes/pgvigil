-- 0476_discovery_auto_add: RELNOTES L237 - a cloud discovery source that adds the servers it finds by itself (the
-- lead's 05:32: every rec of the design 3c2bb2562; the migration number the lead's).
--
-- Two keys, both off: pgvigil.yaml's doors.discovery_auto_add (serve passes it as auto_add_door - a migration cannot
-- read the file) and each cloud source's own auto_add, ticked by an admin in the source's form and audited as the
-- source's add or edit is. Serve's auto step after a read (internal/web/autoadd.go) gives each proposed server of such
-- a source the page's Test and then the page's own approve as auto:<source>, never with a tick: what import_admin_decision
-- refuses (the master user as the login, a server that pauses when idle, a server already an instance, a taken name,
-- an Entra-only server), a failed Test and the servers past the 25 of one read stay proposals, each with its words in
-- auto_note; import_admin_auto_add keeps those notes and writes one 'source read' audit row that counts them. A gone
-- server is never removed by itself (task 205's rule, unchanged).
--
-- Above 0300, so this file makes its own objects (the join-file rule) - two columns and import_admin_auto_add - and
-- RE-MAKES import_admin_source whole from its NEWEST text (0123_discovery.sql) with the switch: a j17 named check (a
-- later re-make of import_admin_source on another branch carries the auto_add lines). apply_roles gives both import_
-- functions SECURITY DEFINER and serve's login, as every page write.

ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS auto_add boolean NOT NULL DEFAULT false;
ALTER TABLE pgvigil.admin_proposals ADD COLUMN IF NOT EXISTS auto_note text;

-- import_admin_source as 0123's, with auto_add on add and edit: on only with the door open and on a cloud source (in
-- words otherwise); off clears the source's auto notes; the audit's detail names a change of it.
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
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_source: no ui_user' USING ERRCODE = '22023';
  END IF;
  v_have := EXISTS (SELECT 1 FROM pgvigil.admin_sources WHERE name = v_name);
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
  ELSIF v_op IN ('add', 'edit') AND v_auto IS TRUE AND NOT v_door THEN
    v_why := 'off on this install: doors.discovery_auto_add in pgvigil.yaml lets a cloud source add the servers it finds by itself';
  ELSIF v_op IN ('add', 'edit') AND v_auto IS TRUE
        AND coalesce(CASE WHEN v_op = 'add' THEN v_kind END, (SELECT kind FROM pgvigil.admin_sources WHERE name = v_name)) NOT IN ('aws', 'azure', 'gcp') THEN
    v_why := 'only a cloud source (aws, azure or gcp) adds the servers it finds by itself';
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
      UPDATE pgvigil.admin_proposals SET auto_note = NULL WHERE source = v_name AND auto_note IS NOT NULL;
    END IF;
    UPDATE pgvigil.admin_sources SET last_notes = pgvigil.admin_notes_text(note_items) WHERE name = v_name;
  ELSE
    UPDATE pgvigil.admin_sources SET enabled = (v_op = 'enable') WHERE name = v_name;
  END IF;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'source ' || v_op, v_name, 'done',
    CASE WHEN v_op = 'add' THEN format('%s from %s', v_kind, CASE WHEN v_kind IN ('cms', 'aws', 'azure', 'gcp') THEN 'its settings file' ELSE p_payload->>'ref' END)
         WHEN v_op = 'edit' THEN format('regions %s, tag keys %s%s', coalesce(p_payload->'regions', '"unchanged"'), coalesce(p_payload->'tag_keys', '"unchanged"'),
                                        CASE WHEN (p_payload->>'swept')::boolean IS TRUE THEN ' (a sweep)' ELSE '' END) END
    || CASE WHEN v_auto IS TRUE THEN '; adds what it finds by itself' WHEN v_auto IS FALSE AND v_op = 'edit' THEN '; no longer adds what it finds' ELSE '' END);
  RETURN jsonb_build_object('outcome', 'done', 'detail', v_op || ' ' || v_name);
END $$;

-- import_admin_auto_add: the end of one auto step of a source (payload: source, notes [{proposal_id, note}], added,
-- person, failed, waiting). The step's notes replace the source's last ones (a server added, or no longer held back,
-- has none); one 'source read' audit row as auto:<source>, beside the read's own.
CREATE OR REPLACE FUNCTION pgvigil.import_admin_auto_add(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_src text := p_payload->>'source';
BEGIN
  IF v_src IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.admin_sources WHERE name = v_src) THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('no source %s', coalesce(v_src, '(none)')));
  END IF;
  UPDATE pgvigil.admin_proposals SET auto_note = NULL WHERE source = v_src AND auto_note IS NOT NULL;
  UPDATE pgvigil.admin_proposals p SET auto_note = left(n->>'note', 2000)
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_payload->'notes') = 'array' THEN p_payload->'notes' ELSE '[]' END) n
   WHERE p.source = v_src AND coalesce(n->>'proposal_id', '') ~ '^[0-9]{1,18}$' AND p.proposal_id = (n->>'proposal_id')::bigint;
  PERFORM pgvigil.admin_log('auto:' || v_src, NULL, 'source read', v_src, 'done',
    format('added %s by itself; needs a person %s; the test failed %s; waits for the next read %s',
           coalesce(p_payload->>'added', '0'), coalesce(p_payload->>'person', '0'), coalesce(p_payload->>'failed', '0'), coalesce(p_payload->>'waiting', '0')));
  RETURN jsonb_build_object('outcome', 'done', 'detail', format('auto step of %s recorded', v_src));
END $$;
