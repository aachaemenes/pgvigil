-- 0123: cloud discovery (task 205; task 103 part 2). Three more kinds of sync source for Admin > Instances (0122):
-- aws (RDS and Aurora, PostgreSQL and SQL Server, in every region the credentials allow), azure (Azure SQL
-- Database, Managed Instance and PostgreSQL flexible server, through Resource Graph) and gcp (Cloud SQL and AlloyDB).
-- Each is read by serve (internal/discover) into 0122's proposals: a click approves, nothing is created in a cloud.
-- A cloud source's ref is the file serve wrote with its settings and its read-only credential (file: or dpapi:,
-- never in this database); what a read could not see (a region not enabled, an API not enabled, a missing right)
-- is kept as the source's notes beside its last error.

ALTER TABLE pgvigil.admin_sources DROP CONSTRAINT IF EXISTS admin_sources_kind_check;
ALTER TABLE pgvigil.admin_sources ADD CONSTRAINT admin_sources_kind_check
  CHECK (kind IN ('cms', 'dbadash', 'sqlserver_list', 'pg_service', 'pg_csv', 'aws', 'azure', 'gcp'));
ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS last_notes text;

-- task 205's design pass (2026-11-12): a claim per read (one read of a source at a time, the loop's or a request's)
-- and the start of the last read applied (an older read is never applied over a newer one); the regions a sweep
-- found readable (an AWS source reads only those after its add; editable); the resource tag keys a source takes in
-- (an allow-list, none by default) and those its reads saw; the Azure subscriptions of the last complete read.
ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS claim_until timestamptz;
ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS claimed_by text;
ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS last_read_start timestamptz;
ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS cloud_regions text[];
ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS regions_read_at timestamptz;
-- sweep_tried_at: the last sweep tried, whatever its outcome (task 205's review, part b): the loop's weekly sweep
-- waits 7 days from it too, so a sweep that fails is not tried again at every hourly tick
ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS sweep_tried_at timestamptz;
ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS tag_keys text[] NOT NULL DEFAULT '{}';
ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS seen_tag_keys text[] NOT NULL DEFAULT '{}';
ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS seen_scopes text[] NOT NULL DEFAULT '{}';

-- a cloud proposal's resource id (an RDS DbiResourceId, an Azure resource id, a Cloud SQL self link with its create
-- time, an AlloyDB uid): a new id under an old key is a new server - the old proposal is marked gone and a fresh one
-- made; the other address (the private one is host); the master user (information only, never the login); a note
-- (an Entra-only server's); Entra-only (a password or SQL login refused at the approve); serverless and auto-pause
ALTER TABLE pgvigil.admin_proposals ADD COLUMN IF NOT EXISTS resource_id text;
ALTER TABLE pgvigil.admin_proposals ADD COLUMN IF NOT EXISTS alt_host text;
ALTER TABLE pgvigil.admin_proposals ADD COLUMN IF NOT EXISTS master_user text;
ALTER TABLE pgvigil.admin_proposals ADD COLUMN IF NOT EXISTS note text;
ALTER TABLE pgvigil.admin_proposals ADD COLUMN IF NOT EXISTS entra_only boolean NOT NULL DEFAULT false;
ALTER TABLE pgvigil.admin_proposals ADD COLUMN IF NOT EXISTS serverless text;
ALTER TABLE pgvigil.admin_proposals ADD COLUMN IF NOT EXISTS auto_pause boolean NOT NULL DEFAULT false;
ALTER TABLE pgvigil.admin_proposals DROP CONSTRAINT IF EXISTS admin_proposals_source_server_key;
CREATE UNIQUE INDEX IF NOT EXISTS admin_proposals_key ON pgvigil.admin_proposals (source, server, (coalesce(resource_id, '')));

-- import_admin_source as 0122's, with the cloud kinds and their ref rule
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
                     WHERE k !~ '^[a-z0-9_.-]{1,40}$' OR k IN ('cloud', 'region', 'account', 'subscription', 'resource-group', 'project', 'cluster', 'role', 'source-instance', 'source-cluster', 'tag')) THEN
    v_why := 'a tag key is 1 to 40 lower-case letters, digits, _ . or -, and not one of pgvigil''s own (cloud, region, account, subscription, resource-group, project, cluster, role, source-instance, source-cluster)';
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'source ' || coalesce(v_op, '?'), v_name, 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_op = 'add' THEN
    INSERT INTO pgvigil.admin_sources (name, kind, ref, credential_ref, auth, every_s, created_at, created_by, cloud_regions)
    VALUES (v_name, v_kind, btrim(p_payload->>'ref'), v_cred,
            coalesce(nullif(p_payload->>'auth', ''), CASE WHEN v_kind IN ('pg_service', 'pg_csv') THEN 'password' ELSE 'sql' END),
            coalesce(nullif(p_payload->>'every_s', ''), '3600')::int, p_at, v_user,
            CASE WHEN jsonb_typeof(p_payload->'regions') = 'array' AND jsonb_array_length(p_payload->'regions') > 0
                 THEN ARRAY(SELECT DISTINCT r FROM jsonb_array_elements_text(p_payload->'regions') r ORDER BY r) END);
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
                           THEN ARRAY(SELECT DISTINCT k FROM jsonb_array_elements_text(p_payload->'tag_keys') k ORDER BY k) ELSE tag_keys END
     WHERE name = v_name;
    UPDATE pgvigil.admin_sources SET last_notes = pgvigil.admin_notes_text(note_items) WHERE name = v_name;
  ELSE
    UPDATE pgvigil.admin_sources SET enabled = (v_op = 'enable') WHERE name = v_name;
  END IF;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'source ' || v_op, v_name, 'done',
    CASE WHEN v_op = 'add' THEN format('%s from %s', v_kind, CASE WHEN v_kind IN ('cms', 'aws', 'azure', 'gcp') THEN 'its settings file' ELSE p_payload->>'ref' END)
         WHEN v_op = 'edit' THEN format('regions %s, tag keys %s%s', coalesce(p_payload->'regions', '"unchanged"'), coalesce(p_payload->'tag_keys', '"unchanged"'),
                                        CASE WHEN (p_payload->>'swept')::boolean IS TRUE THEN ' (a sweep)' ELSE '' END) END);
  RETURN jsonb_build_object('outcome', 'done', 'detail', v_op || ' ' || v_name);
END $$;

-- import_admin_decision as 0122's; an approve may name the login's kind for the proposal's engine (a cloud source
-- holds PostgreSQL and SQL Server servers: its login is a SQL login on one and a password login on the other)
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
      'name', p_payload->>'name', 'engine', v_p.engine, 'dsn_ref', p_payload->>'dsn_ref', 'auth', coalesce(nullif(p_payload->>'auth', ''), v_s.auth), 'host', v_p.host,
      'port', v_p.port, 'dbname', v_p.dbname, 'login', coalesce(nullif(p_payload->>'login_used', ''), v_p.login), 'tags', to_jsonb(v_p.tags), 'source', v_s.kind || ':' || v_s.name,
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

-- import_admin_source_notes (task 205 D4 / D5): what the reads of a source could not see, one item per note - its key
-- (an AWS region the note is about, else 'source'), its text, when it was first and last seen. A read replaces the
-- 'source' items and the items of every region it asked (p_asked: a region read clean drops its note); the item of a
-- region it did not ask (a sweep's refused or silent region the hourly read leaves out) is kept with its times, so
-- every read says what it could not read. An item seen again with the same text keeps its first time. last_notes is
-- the items as text (admin_notes_text), the page's 'not seen' cell. p_started is the read's start: the notes of a read
-- older than the last one applied are not written (task 205's review, part b: a newer read's notes stand). p_sweep:
-- the read was a sweep (sweep_tried_at, whatever its outcome).
ALTER TABLE pgvigil.admin_sources ADD COLUMN IF NOT EXISTS note_items jsonb NOT NULL DEFAULT '[]';

-- admin_notes_text: the note items as one text, a region's with '(since <first> UTC)', stopped at an item before
-- 4000 characters, the items left out counted ('; and N more')
CREATE OR REPLACE FUNCTION pgvigil.admin_notes_text(p_items jsonb)
RETURNS text LANGUAGE sql STABLE AS $$
  WITH t AS (SELECT CASE WHEN x->>'key' = 'source' THEN x->>'text'
                         ELSE (x->>'text') || ' (since ' || to_char(((x->>'first')::timestamptz) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC)' END AS s, o
               FROM jsonb_array_elements(coalesce(p_items, '[]')) WITH ORDINALITY AS t(x, o)),
       r AS (SELECT s, o, sum(length(s) + 2) OVER (ORDER BY o) AS run FROM t)
  SELECT nullif(coalesce(string_agg(s, '; ' ORDER BY o) FILTER (WHERE run <= 3970), '')
                || CASE WHEN count(*) FILTER (WHERE run > 3970) > 0 THEN '; and ' || count(*) FILTER (WHERE run > 3970) || ' more' ELSE '' END, '')
    FROM r
$$;

DROP FUNCTION IF EXISTS pgvigil.import_admin_source_notes(text, timestamptz, text);
DROP FUNCTION IF EXISTS pgvigil.import_admin_source_notes(text, timestamptz, jsonb, text[]);
CREATE OR REPLACE FUNCTION pgvigil.import_admin_source_notes(p_source text, p_at timestamptz, p_notes jsonb, p_asked text[],
                                                            p_started timestamptz, p_sweep boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_old  jsonb;
  v_new  jsonb;
  v_last timestamptz;
BEGIN
  SELECT note_items, last_read_start INTO v_old, v_last FROM pgvigil.admin_sources WHERE name = p_source FOR UPDATE;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF v_last IS NOT NULL AND p_started IS NOT NULL AND v_last > p_started THEN
    RETURN;   -- a newer read was applied after this one's: its notes stand
  END IF;
  WITH n AS (SELECT DISTINCT coalesce(nullif(x->>'key', ''), 'source') AS key, left(x->>'text', 1000) AS text
               FROM jsonb_array_elements(coalesce(p_notes, '[]')) x WHERE coalesce(x->>'text', '') <> ''),
       o AS (SELECT x->>'key' AS key, x->>'text' AS text, (x->>'first')::timestamptz AS first, (x->>'last')::timestamptz AS last
               FROM jsonb_array_elements(coalesce(v_old, '[]')) x),
       m AS (SELECT n.key, n.text, coalesce((SELECT min(o.first) FROM o WHERE o.key = n.key AND o.text = n.text), p_at) AS first, p_at AS last FROM n
             UNION ALL
             SELECT o.key, o.text, o.first, o.last FROM o
              WHERE o.key <> 'source' AND NOT o.key = ANY (coalesce(p_asked, '{}')) AND NOT EXISTS (SELECT 1 FROM n WHERE n.key = o.key))
  SELECT coalesce(jsonb_agg(jsonb_build_object('key', key, 'text', text, 'first', first, 'last', last) ORDER BY key <> 'source', key, text), '[]')
    INTO v_new FROM m;
  UPDATE pgvigil.admin_sources
     SET note_items = v_new,
         last_notes = pgvigil.admin_notes_text(v_new),
         sweep_tried_at = CASE WHEN p_sweep THEN p_at ELSE sweep_tried_at END
   WHERE name = p_source;
END $$;

-- admin_read_rows as 0122's with the cloud columns: a row per (server, resource id), the tags of a server listed
-- twice (a CMS server in two groups) unioned.
DROP FUNCTION IF EXISTS pgvigil.admin_read_rows(jsonb);
CREATE FUNCTION pgvigil.admin_read_rows(p_rows jsonb)
RETURNS TABLE (server text, engine text, host text, port int, dbname text, login text, display_name text, tags text[],
               resource_id text, alt_host text, master_user text, note text, entra_only boolean, serverless text, auto_pause boolean)
LANGUAGE sql IMMUTABLE AS $$
  SELECT left(r.server, 300), min(r.engine), min(left(r.host, 300)), min(r.port), min(r.dbname), min(r.login), min(r.display_name),
         coalesce(array_agg(DISTINCT t ORDER BY t) FILTER (WHERE btrim(t) <> ''), '{}'),
         nullif(left(r.resource_id, 500), ''), min(left(r.alt_host, 300)), min(r.master_user), min(left(r.note, 500)),
         coalesce(bool_or(r.entra_only), false), min(left(r.serverless, 200)), coalesce(bool_or(r.auto_pause), false)
    FROM jsonb_to_recordset(coalesce(p_rows, '[]')) AS r(server text, engine text, host text, port int, dbname text, login text, display_name text, tags jsonb,
                                                         resource_id text, alt_host text, master_user text, note text, entra_only boolean, serverless text, auto_pause boolean)
    LEFT JOIN LATERAL jsonb_array_elements_text(CASE WHEN jsonb_typeof(r.tags) = 'array' THEN r.tags ELSE '[]' END) t ON true
   WHERE coalesce(r.server, '') <> '' AND r.engine IN ('postgres', 'sqlserver') AND coalesce(r.host, '') <> ''
   GROUP BY left(r.server, 300), nullif(left(r.resource_id, 500), '')
$$;

-- import_admin_source_claim: one read of a source at a time (task 205's design pass): the claim is taken for
-- p_secs (the read's limit and a margin) when none is live; p_due_only = the hourly loop's (only a source that is
-- enabled and due). It answers the read's start on the repository's clock (the import compares starts: one clock
-- for every serve), or NULL: another read of the source is running (or it is not due).
DROP FUNCTION IF EXISTS pgvigil.import_admin_source_claim(text, text, int, boolean);
CREATE FUNCTION pgvigil.import_admin_source_claim(p_source text, p_holder text, p_secs int, p_due_only boolean)
RETURNS timestamptz LANGUAGE sql AS $$
  WITH c AS (
    UPDATE pgvigil.admin_sources SET claim_until = now() + make_interval(secs => greatest(p_secs, 10)), claimed_by = p_holder
     WHERE name = p_source AND (claim_until IS NULL OR claim_until < now())
       AND (NOT p_due_only OR (enabled AND (last_run IS NULL OR last_run + every_s * interval '1 second' <= now())))
    RETURNING 1)
  SELECT CASE WHEN EXISTS (SELECT 1 FROM c) THEN now() END
$$;

-- import_admin_source_release: a read that ends without an import (cut before it) frees its own claim
CREATE OR REPLACE FUNCTION pgvigil.import_admin_source_release(p_source text, p_holder text)
RETURNS void LANGUAGE sql AS $$
  UPDATE pgvigil.admin_sources SET claim_until = NULL, claimed_by = NULL WHERE name = p_source AND claimed_by = p_holder
$$;

-- import_admin_proposals: one read of a source (0122's, with the review of 205 and its design pass). p_rows is the
-- whole list the source holds now; a server not in it is marked gone (never removed), one back in it is no longer
-- gone; a server under one of p_unseen's key prefixes (a region, a subscription, a project's API the read could not
-- see) is kept as it is; a new resource id under an old key is a new server (the old proposal gone, a fresh one
-- made). p_started is the read's start: a read that started before the last applied one is refused (it could bring
-- back a server a newer read saw gone). p_error not null = the read failed: recorded, nothing marked gone. p_by is
-- who asked (a UI login, or 'the hourly read'): one admin_audit row per read. p_holder frees this read's claim.
-- p_scopes (the Azure subscriptions of a complete read) and p_tag_keys (the resource tag keys seen) are kept.
DROP FUNCTION IF EXISTS pgvigil.import_admin_proposals(text, timestamptz, jsonb, text);
DROP FUNCTION IF EXISTS pgvigil.import_admin_proposals(text, timestamptz, jsonb, text, text[]);
CREATE FUNCTION pgvigil.import_admin_proposals(p_source text, p_at timestamptz, p_rows jsonb, p_error text, p_unseen text[],
                                               p_started timestamptz, p_by text, p_holder text, p_scopes text[] DEFAULT NULL,
                                               p_tag_keys text[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_new int := 0; v_gone int := 0; v_back int := 0; v_n int; v_kept int;
  v_last timestamptz;
  v_unseen text := nullif(array_to_string(coalesce(p_unseen, '{}'), ' '), '');
BEGIN
  SELECT last_read_start INTO v_last FROM pgvigil.admin_sources WHERE name = p_source FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('no source %s', p_source));
  END IF;
  UPDATE pgvigil.admin_sources SET claim_until = NULL, claimed_by = NULL WHERE name = p_source AND claimed_by = p_holder;
  IF p_started IS NULL OR (v_last IS NOT NULL AND p_started <= v_last) THEN
    PERFORM pgvigil.admin_log(coalesce(p_by, '?'), NULL, 'source read', p_source, 'refused',
      format('a read that started %s, not after the last applied one (%s): not applied', p_started, v_last));
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('a newer read of %s was applied already: this one (started %s) is not', p_source, p_started));
  END IF;
  IF p_error IS NOT NULL THEN
    UPDATE pgvigil.admin_sources SET last_run = p_at, last_error = left(p_error, 1000), last_read_start = p_started WHERE name = p_source;
    -- admin_audit's outcome is done or refused (0122): a failed read is a done row that says so, as 'tested' does
    PERFORM pgvigil.admin_log(coalesce(p_by, '?'), NULL, 'source read', p_source, 'done', 'failed: ' || left(p_error, 1000));
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'the read failed: recorded, nothing marked gone');
  END IF;
  SELECT count(*) INTO v_new FROM pgvigil.admin_read_rows(p_rows) a
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.admin_proposals p WHERE p.source = p_source AND p.server = a.server AND coalesce(p.resource_id, '') = coalesce(a.resource_id, ''));
  SELECT count(*) INTO v_back FROM pgvigil.admin_proposals p JOIN pgvigil.admin_read_rows(p_rows) a ON a.server = p.server AND coalesce(p.resource_id, '') = coalesce(a.resource_id, '')
   WHERE p.source = p_source AND p.gone;
  INSERT INTO pgvigil.admin_proposals AS p (source, server, engine, host, port, dbname, login, display_name, tags, first_seen, last_seen,
                                           resource_id, alt_host, master_user, note, entra_only, serverless, auto_pause)
  SELECT p_source, a.server, a.engine, a.host, a.port, a.dbname, a.login, a.display_name, a.tags, p_at, p_at,
         a.resource_id, a.alt_host, a.master_user, a.note, a.entra_only, a.serverless, a.auto_pause FROM pgvigil.admin_read_rows(p_rows) a
  ON CONFLICT (source, server, (coalesce(resource_id, ''))) DO UPDATE
     SET engine = EXCLUDED.engine, host = EXCLUDED.host, port = EXCLUDED.port, dbname = EXCLUDED.dbname, login = EXCLUDED.login,
         display_name = EXCLUDED.display_name, tags = EXCLUDED.tags, last_seen = p_at, gone = false, gone_at = NULL,
         alt_host = EXCLUDED.alt_host, master_user = EXCLUDED.master_user, note = EXCLUDED.note, entra_only = EXCLUDED.entra_only,
         serverless = EXCLUDED.serverless, auto_pause = EXCLUDED.auto_pause;
  UPDATE pgvigil.admin_proposals p SET gone = true, gone_at = p_at
   WHERE p.source = p_source AND NOT p.gone
     AND NOT EXISTS (SELECT 1 FROM pgvigil.admin_read_rows(p_rows) a WHERE a.server = p.server AND coalesce(a.resource_id, '') = coalesce(p.resource_id, ''))
     AND (NOT EXISTS (SELECT 1 FROM unnest(coalesce(p_unseen, '{}')) u WHERE u <> '' AND starts_with(p.server, u))
          -- a new resource id under the key: the old one is gone even when its prefix was not seen in full
          OR EXISTS (SELECT 1 FROM pgvigil.admin_read_rows(p_rows) a WHERE a.server = p.server))
     -- an AWS region the source no longer reads (left out of a sweep that found it silent, or edited out) is not seen:
     -- its servers are kept as they were (aws:<account>:<region>:instance:<id>)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.admin_sources s WHERE s.name = p_source AND s.kind = 'aws' AND cardinality(s.cloud_regions) > 0
                       AND NOT (split_part(p.server, ':', 3) = ANY (s.cloud_regions)));
  GET DIAGNOSTICS v_gone = ROW_COUNT;
  SELECT count(*) INTO v_n FROM pgvigil.admin_read_rows(p_rows);
  SELECT count(*) INTO v_kept FROM pgvigil.admin_proposals p WHERE p.source = p_source AND NOT p.gone
     AND NOT EXISTS (SELECT 1 FROM pgvigil.admin_read_rows(p_rows) a WHERE a.server = p.server AND coalesce(a.resource_id, '') = coalesce(p.resource_id, ''));
  UPDATE pgvigil.admin_sources SET last_run = p_at, last_ok = p_at, last_error = NULL, last_count = v_n, last_read_start = p_started,
         seen_scopes = CASE WHEN cardinality(p_scopes) > 0 THEN p_scopes ELSE seen_scopes END,
         seen_tag_keys = CASE WHEN p_tag_keys IS NOT NULL THEN p_tag_keys ELSE seen_tag_keys END
   WHERE name = p_source;
  PERFORM pgvigil.admin_log(coalesce(p_by, '?'), NULL, 'source read', p_source, 'done',
    format('read %s, new %s, gone %s, back %s, kept unseen %s%s', v_n, v_new, v_gone, v_back, v_kept, coalesce('; not seen: ' || left(v_unseen, 1500), '')));
  RETURN jsonb_build_object('outcome', 'done', 'read', v_n, 'new', v_new, 'gone', v_gone, 'back', v_back, 'kept_unseen', v_kept);
END $$;

-- import_admin_proposal_test: the audit row of a proposal's Test (204's connection test before the approve; nothing
-- else is written). An import_ function as every page write is (apply_roles: SECURITY DEFINER, serve's login may run
-- it); admin_audit's outcome is done, the detail says connected or failed. Payload: ui_user, client, proposal_id,
-- ok, detail.
CREATE OR REPLACE FUNCTION pgvigil.import_admin_proposal_test(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_p    pgvigil.admin_proposals%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_proposal_test: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'proposal_id', '') ~ '^[0-9]{1,18}$' THEN
    SELECT * INTO v_p FROM pgvigil.admin_proposals WHERE proposal_id = (p_payload->>'proposal_id')::bigint;
  END IF;
  IF v_p.proposal_id IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('no proposal %s', coalesce(p_payload->>'proposal_id', '(none)')));
  END IF;
  PERFORM pgvigil.admin_log(v_user, p_payload->>'client', 'proposal test', v_p.source || '/' || v_p.server, 'done',
    CASE WHEN (p_payload->>'ok')::boolean IS TRUE THEN 'connected: ' ELSE 'failed: ' END || left(coalesce(p_payload->>'detail', ''), 1000));
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'tested ' || v_p.server);
END $$;

-- A row never read is one with no server_version (every read that connects writes it through ensure_instance; a page
-- add makes the row without one): the fleet query says 'not read yet' from this test; 0122's admin_first_read moves
-- first_seen at that first read whatever the platform (the join's fold 2).
