-- 0020_roles: the roles collection (phase 2, task 31): who can log in, who is superuser, who is a member of what,
-- and what each role was granted on the databases, the schemas and through default privileges; the server's
-- pg_hba.conf rules where the login may read them. (0008_roles.sql is the repository's own access contract,
-- pgvigil_collector and pgvigil_reader; this file is about the monitored servers' roles.)
--   role_state              per instance: the collector's login, whether it holds pg_monitor, the hba read state and checksum
--   role_attributes         one row per role: its attributes (pg_roles; a password is never read)
--   role_members            one row per membership grant: role, member, grantor, admin / inherit / set options
--   role_databases          the databases whose schema and default ACLs a read completed
--   acl_databases           each database's ACL, one row per grantee and grantor
--   acl_schemas             each schema's ACL, per database
--   acl_default_privileges  ALTER DEFAULT PRIVILEGES entries, per database
--   hba_rules               the pg_hba.conf rules as pg_hba_file_rules shows them
--   role_history            what changed between two reads: a role added, removed or altered (its attributes, its
--                           ALTER ROLE ... SET list), a membership or a privilege granted, revoked or changed, an hba
--                           rule added or removed, the hba checksum. Rows are keyed by name: a role renamed reads as
--                           removed and added (pg_roles keeps no rename history; the oid is stored, not compared)
--   role_member_closure     every membership through any depth, per instance (rebuilt by the import)
--   role_flags              a role's attributes as one comparable text (the history's value)
--   role_is_platform        whether a role is the server's or the platform's own (not an application role)
--   role_findings           the role rules, in pgvigil.findings' columns (the join unions it in)
--   role_fleet              per instance: the superusers and login roles, with what they are members of

CREATE TABLE IF NOT EXISTS pgvigil.role_state (
  instance_id           int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at           timestamptz NOT NULL,
  login_name            text,
  login_is_super        boolean,
  login_has_pg_monitor  boolean,
  hba_status            text,          -- read | skipped (the last read's)
  hba_note              text,          -- why it was skipped
  hba_checksum          text,          -- md5 of the rules at the last read that could read them
  hba_rules             int,
  hba_read_at           timestamptz,   -- the last read that could read them
  unreadable_dbs        text[]         -- databases the login may not connect to: their schema and default ACLs are the last read's
);

CREATE TABLE IF NOT EXISTS pgvigil.role_attributes (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  rolname      text NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  role_oid     bigint,
  super        boolean NOT NULL,
  inherit      boolean NOT NULL,
  createrole   boolean NOT NULL,
  createdb     boolean NOT NULL,
  canlogin     boolean NOT NULL,
  replication  boolean NOT NULL,
  bypassrls    boolean NOT NULL,
  connlimit    int,
  valid_until  timestamptz,
  config       text[],                 -- ALTER ROLE ... SET, a password-like value masked by the collector
  is_present   boolean NOT NULL DEFAULT true,   -- false once a read no longer lists it (dropped)
  PRIMARY KEY (instance_id, rolname)
);

CREATE TABLE IF NOT EXISTS pgvigil.role_members (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  role_name       text NOT NULL,
  member_name     text NOT NULL,
  grantor_name    text NOT NULL DEFAULT '',
  snapshot_at     timestamptz NOT NULL,
  admin_option    boolean NOT NULL,
  inherit_option  boolean,             -- PostgreSQL 16+; NULL before
  set_option      boolean,             -- PostgreSQL 16+; NULL before
  is_present      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, role_name, member_name, grantor_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.role_databases (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  datname      text NOT NULL,
  dbid         bigint,
  read_at      timestamptz NOT NULL,
  is_present   boolean NOT NULL DEFAULT true,   -- false once the database leaves the connectable list
  PRIMARY KEY (instance_id, datname)
);

CREATE TABLE IF NOT EXISTS pgvigil.acl_databases (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  datname      text NOT NULL,
  grantee      text NOT NULL,          -- a role name, or PUBLIC
  grantor      text NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  owner        text,
  privileges   text NOT NULL,          -- CONNECT,CREATE,TEMPORARY (sorted)
  grantable    text NOT NULL DEFAULT '',   -- the ones held WITH GRANT OPTION
  is_default   boolean NOT NULL DEFAULT false, -- datacl NULL: the built-in default (owner all, PUBLIC CONNECT and TEMPORARY)
  is_present   boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, datname, grantee, grantor)
);

CREATE TABLE IF NOT EXISTS pgvigil.acl_schemas (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  datname      text NOT NULL,
  schema_name  text NOT NULL,
  grantee      text NOT NULL,
  grantor      text NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  owner        text,
  privileges   text NOT NULL,
  grantable    text NOT NULL DEFAULT '',
  is_default   boolean NOT NULL DEFAULT false,
  is_present   boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, datname, schema_name, grantee, grantor)
);

CREATE TABLE IF NOT EXISTS pgvigil.acl_default_privileges (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  datname      text NOT NULL,
  owner        text NOT NULL,          -- whose new objects
  schema_name  text NOT NULL DEFAULT '',   -- '': every schema
  objtype      text NOT NULL,          -- table | sequence | function | type | schema | large object
  grantee      text NOT NULL,
  grantor      text NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  privileges   text NOT NULL,
  grantable    text NOT NULL DEFAULT '',
  is_present   boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, datname, owner, schema_name, objtype, grantee, grantor)
);

CREATE TABLE IF NOT EXISTS pgvigil.hba_rules (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  file_name    text NOT NULL DEFAULT '',   -- PostgreSQL 15+ (an included file); '' before
  line_number  int NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  rule_number  int,
  type         text,
  databases    text[],
  users        text[],
  address      text,
  netmask      text,
  auth_method  text,
  options      text[],
  error        text,                   -- a line the server could not parse
  is_present   boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, file_name, line_number)
);

CREATE TABLE IF NOT EXISTS pgvigil.role_history (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  changed_at   timestamptz NOT NULL,
  object_kind  text NOT NULL,          -- role | role setting | member | database acl | schema acl | default privileges | hba rule | hba checksum
  datname      text,                   -- NULL: a server-wide change
  object       text NOT NULL,
  change       text NOT NULL,          -- added | removed | changed | granted | revoked
  old_value    text,
  new_value    text
);
-- every membership through any depth, per instance, rebuilt by each import that reads the memberships: (member, role)
-- for each role the member reaches by a chain of grants (an hba +group names its members through it)
CREATE TABLE IF NOT EXISTS pgvigil.role_member_closure (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  member_name  text NOT NULL,
  role_name    text NOT NULL,
  depth        int NOT NULL,
  PRIMARY KEY (instance_id, member_name, role_name)
);
CREATE INDEX IF NOT EXISTS role_members_member_idx ON pgvigil.role_members (instance_id, member_name) WHERE is_present;
CREATE INDEX IF NOT EXISTS role_history_idx ON pgvigil.role_history (instance_id, changed_at);

CREATE OR REPLACE FUNCTION pgvigil.role_flags(p_super boolean, p_inherit boolean, p_createrole boolean, p_createdb boolean,
                                              p_canlogin boolean, p_replication boolean, p_bypassrls boolean,
                                              p_connlimit int, p_valid_until timestamptz)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT concat_ws(',', CASE WHEN p_super THEN 'superuser' END, CASE WHEN p_canlogin THEN 'login' END,
                   CASE WHEN p_createrole THEN 'createrole' END, CASE WHEN p_createdb THEN 'createdb' END,
                   CASE WHEN p_replication THEN 'replication' END, CASE WHEN p_bypassrls THEN 'bypassrls' END,
                   CASE WHEN NOT p_inherit THEN 'noinherit' END,
                   CASE WHEN p_connlimit IS NOT NULL AND p_connlimit <> -1 THEN 'connection limit ' || p_connlimit END,
                   CASE WHEN p_valid_until IS NOT NULL THEN 'valid until ' || to_char(p_valid_until AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC' END)
$$;

-- the server's and the platform's own roles: the predefined and bootstrap roles (an oid under 16384, the first
-- normal object id) and the roles a managed platform creates (rdsadmin, rds_superuser, azuresu, azure_pg_admin,
-- cloudsqladmin, cloudsqlsuperuser, alloydbadmin, ...)
CREATE OR REPLACE FUNCTION pgvigil.role_is_platform(p_platform text, p_name text, p_oid bigint)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(p_oid < 16384, false) OR p_name LIKE 'pg\_%'
      OR (p_platform IN ('rds', 'aurora') AND p_name ~ '^rds')
      OR (p_platform = 'azure' AND p_name ~ '^azure')
      OR (p_platform = 'cloudsql' AND p_name ~ '^cloudsql')
      OR (p_platform = 'alloydb' AND p_name ~ '^alloydb')
$$;

-- a JSON array of strings as text[]; NULL for a JSON null or anything that is not an array
CREATE OR REPLACE FUNCTION pgvigil.role_text_array(p jsonb)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN jsonb_typeof(p) = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(p)) END
$$;

-- an hba rule as one line, the way pg_hba.conf spells it (the history's object: a rule moved to another line is
-- the same rule)
CREATE OR REPLACE FUNCTION pgvigil.role_hba_text(p_type text, p_databases text[], p_users text[], p_address text, p_netmask text,
                                                 p_auth_method text, p_options text[], p_error text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_error IS NOT NULL THEN 'error: ' || p_error
              ELSE concat_ws(' ', p_type, array_to_string(p_databases, ','), array_to_string(p_users, ','),
                             p_address || coalesce('/' || p_netmask, ''), p_auth_method, array_to_string(p_options, ' ')) END
$$;

-- whether a role name matches a pg_hba.conf regular expression (a user entry /^...); a pattern the repository cannot
-- compile counts as a match (the rule is then not held against the role)
CREATE OR REPLACE FUNCTION pgvigil.role_regex_match(p_name text, p_pattern text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN p_name ~ p_pattern;
EXCEPTION WHEN invalid_regular_expression THEN
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_roles(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_first     boolean;
  v_cluster   boolean;   -- the cluster-wide read happened (a login row)
  v_aclnames  text[];    -- every database in pg_database (allowconn, not a template): one not listed is gone
  v_dbs       text[];    -- the databases whose schema and default ACLs this read completed
  v_hba       jsonb;     -- this read's hba_state
  v_sum_prev  text;      -- the checksum of the last read that could read the hba rules (NULL: never)
  v_login     jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_roles'), p_instance_id);
  v_first := NOT EXISTS (SELECT 1 FROM pgvigil.role_state WHERE instance_id = p_instance_id);
  SELECT r INTO v_login FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'login' LIMIT 1;
  v_cluster := v_login IS NOT NULL;
  SELECT ARRAY(SELECT jsonb_array_elements_text(r->'names')) INTO v_aclnames
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'dbacls' LIMIT 1;
  v_dbs := ARRAY(SELECT r->>'datname' FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db');
  SELECT r INTO v_hba FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'hba_state' LIMIT 1;
  SELECT hba_checksum INTO v_sum_prev FROM pgvigil.role_state WHERE instance_id = p_instance_id;

  -- ---- the history: this read against the stored rows, over what both cover --------------------------------
  -- Every row becomes (kind, datname, object, value); a kind is compared only where this read covers it and an
  -- earlier read did too: a database seen for the first time (new, or never read before) writes no history, a
  -- database or an hba file this read could not read keeps its rows and writes none.
  IF NOT v_first THEN
    INSERT INTO pgvigil.role_history (instance_id, changed_at, object_kind, datname, object, change, old_value, new_value)
    SELECT p_instance_id, p_snapshot_at, coalesce(n.kind, o.kind), coalesce(n.datname, o.datname), coalesce(n.object, o.object),
           CASE WHEN coalesce(n.kind, o.kind) IN ('role', 'role setting', 'hba rule')
                THEN CASE WHEN o.object IS NULL THEN 'added' WHEN n.object IS NULL THEN 'removed' ELSE 'changed' END
                ELSE CASE WHEN o.object IS NULL THEN 'granted' WHEN n.object IS NULL THEN 'revoked' ELSE 'changed' END END,
           o.value, n.value
      FROM (
        -- this read
        SELECT 'role' AS kind, NULL::text AS datname, r->>'name' AS object,
               pgvigil.role_flags((r->>'super')::boolean, (r->>'inherit')::boolean, (r->>'createrole')::boolean, (r->>'createdb')::boolean,
                                  (r->>'canlogin')::boolean, (r->>'replication')::boolean, (r->>'bypassrls')::boolean,
                                  (r->>'connlimit')::int, (r->>'valid_until')::timestamptz) AS value
          FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'role'
        UNION ALL
        SELECT 'role setting', NULL, r->>'name', array_to_string(pgvigil.role_text_array(r->'config'), '; ')
          FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'role' AND jsonb_array_length(coalesce(nullif(r->'config', 'null'), '[]')) > 0
        UNION ALL
        SELECT 'member', NULL, (r->>'role') || ' <- ' || (r->>'member') || coalesce(' (by ' || nullif(r->>'grantor', '') || ')', ''),
               concat_ws(',', CASE WHEN (r->>'admin_option')::boolean THEN 'admin' END,
                         CASE WHEN (r->>'inherit_option')::boolean IS FALSE THEN 'noinherit' END,
                         CASE WHEN (r->>'set_option')::boolean IS FALSE THEN 'noset' END)
          FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'member'
        UNION ALL
        SELECT 'database acl', r->>'datname', (r->>'grantee') || ' (by ' || (r->>'grantor') || ')',
               (r->>'privileges') || coalesce(' (grant option: ' || nullif(r->>'grantable', '') || ')', '')
          FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'dbacl'
           AND EXISTS (SELECT 1 FROM pgvigil.acl_databases x WHERE x.instance_id = p_instance_id AND x.is_present AND x.datname = r->>'datname')
        UNION ALL
        SELECT 'schema acl', r->>'datname', (r->>'schema_name') || ': ' || (r->>'grantee') || ' (by ' || (r->>'grantor') || ')',
               (r->>'privileges') || coalesce(' (grant option: ' || nullif(r->>'grantable', '') || ')', '')
          FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'schemaacl'
           AND EXISTS (SELECT 1 FROM pgvigil.role_databases x WHERE x.instance_id = p_instance_id AND x.is_present AND x.datname = r->>'datname')
        UNION ALL
        SELECT 'default privileges', r->>'datname',
               'for ' || (r->>'owner') || ' in ' || coalesce(nullif(r->>'schema_name', ''), 'every schema') || ' on ' || (r->>'objtype')
               || ': ' || (r->>'grantee') || ' (by ' || (r->>'grantor') || ')',
               (r->>'privileges') || coalesce(' (grant option: ' || nullif(r->>'grantable', '') || ')', '')
          FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'defacl'
           AND EXISTS (SELECT 1 FROM pgvigil.role_databases x WHERE x.instance_id = p_instance_id AND x.is_present AND x.datname = r->>'datname')
        UNION ALL
        SELECT DISTINCT 'hba rule', NULL, pgvigil.role_hba_text(r->>'type', pgvigil.role_text_array(r->'databases'),
                                                       pgvigil.role_text_array(r->'users'), r->>'address', r->>'netmask',
                                                       r->>'auth_method', pgvigil.role_text_array(r->'options'), r->>'error'), ''
          FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'hba'
           AND v_hba->>'status' = 'read' AND v_sum_prev IS NOT NULL
      ) n
      FULL JOIN (
        -- the stored rows this read covers
        SELECT 'role' AS kind, NULL::text AS datname, a.rolname AS object,
               pgvigil.role_flags(a.super, a.inherit, a.createrole, a.createdb, a.canlogin, a.replication, a.bypassrls, a.connlimit, a.valid_until) AS value
          FROM pgvigil.role_attributes a WHERE a.instance_id = p_instance_id AND a.is_present AND v_cluster
        UNION ALL
        SELECT 'role setting', NULL, a.rolname, array_to_string(a.config, '; ')
          FROM pgvigil.role_attributes a WHERE a.instance_id = p_instance_id AND a.is_present AND v_cluster AND cardinality(a.config) > 0
        UNION ALL
        SELECT 'member', NULL, m.role_name || ' <- ' || m.member_name || coalesce(' (by ' || nullif(m.grantor_name, '') || ')', ''),
               concat_ws(',', CASE WHEN m.admin_option THEN 'admin' END, CASE WHEN m.inherit_option IS FALSE THEN 'noinherit' END,
                         CASE WHEN m.set_option IS FALSE THEN 'noset' END)
          FROM pgvigil.role_members m WHERE m.instance_id = p_instance_id AND m.is_present AND v_cluster
        UNION ALL
        SELECT 'database acl', d.datname, d.grantee || ' (by ' || d.grantor || ')',
               d.privileges || coalesce(' (grant option: ' || nullif(d.grantable, '') || ')', '')
          FROM pgvigil.acl_databases d WHERE d.instance_id = p_instance_id AND d.is_present AND d.datname = ANY (v_aclnames)
        UNION ALL
        SELECT 'schema acl', s.datname, s.schema_name || ': ' || s.grantee || ' (by ' || s.grantor || ')',
               s.privileges || coalesce(' (grant option: ' || nullif(s.grantable, '') || ')', '')
          FROM pgvigil.acl_schemas s WHERE s.instance_id = p_instance_id AND s.is_present AND s.datname = ANY (v_dbs)
        UNION ALL
        SELECT 'default privileges', p.datname,
               'for ' || p.owner || ' in ' || coalesce(nullif(p.schema_name, ''), 'every schema') || ' on ' || p.objtype
               || ': ' || p.grantee || ' (by ' || p.grantor || ')',
               p.privileges || coalesce(' (grant option: ' || nullif(p.grantable, '') || ')', '')
          FROM pgvigil.acl_default_privileges p WHERE p.instance_id = p_instance_id AND p.is_present AND p.datname = ANY (v_dbs)
        UNION ALL
        SELECT DISTINCT 'hba rule', NULL, pgvigil.role_hba_text(h.type, h.databases, h.users, h.address, h.netmask, h.auth_method, h.options, h.error), ''
          FROM pgvigil.hba_rules h WHERE h.instance_id = p_instance_id AND h.is_present
           AND v_hba->>'status' = 'read' AND v_sum_prev IS NOT NULL
      ) o ON o.kind = n.kind AND o.datname IS NOT DISTINCT FROM n.datname AND o.object = n.object
     WHERE o.value IS DISTINCT FROM n.value OR o.object IS NULL OR n.object IS NULL;

    IF v_hba->>'status' = 'read' AND v_sum_prev IS NOT NULL AND v_sum_prev IS DISTINCT FROM v_hba->>'checksum' THEN
      INSERT INTO pgvigil.role_history (instance_id, changed_at, object_kind, datname, object, change, old_value, new_value)
      VALUES (p_instance_id, p_snapshot_at, 'hba checksum', NULL, 'pg_hba.conf', 'changed', v_sum_prev, v_hba->>'checksum');
    END IF;
  END IF;

  -- ---- the state row ----------------------------------------------------------------------------------------
  INSERT INTO pgvigil.role_state AS s (instance_id, snapshot_at, login_name, login_is_super, login_has_pg_monitor,
                                       hba_status, hba_note, hba_checksum, hba_rules, hba_read_at, unreadable_dbs)
  VALUES (p_instance_id, p_snapshot_at, v_login->>'name', (v_login->>'is_super')::boolean, (v_login->>'has_pg_monitor')::boolean,
          v_hba->>'status', nullif(v_hba->>'note', ''), v_hba->>'checksum', (v_hba->>'rules')::int,
          CASE WHEN v_hba->>'status' = 'read' THEN p_snapshot_at END,
          (SELECT pgvigil.role_text_array(r->'names') FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'noconnect' LIMIT 1))
  ON CONFLICT (instance_id) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at,
    login_name = coalesce(EXCLUDED.login_name, s.login_name),
    login_is_super = coalesce(EXCLUDED.login_is_super, s.login_is_super),
    login_has_pg_monitor = coalesce(EXCLUDED.login_has_pg_monitor, s.login_has_pg_monitor),
    hba_status = coalesce(EXCLUDED.hba_status, s.hba_status),
    hba_note = CASE WHEN EXCLUDED.hba_status IS NULL THEN s.hba_note ELSE EXCLUDED.hba_note END,
    -- a skipped read keeps the last checksum, its rule count and when it was read
    hba_checksum = CASE WHEN EXCLUDED.hba_status = 'read' THEN EXCLUDED.hba_checksum ELSE s.hba_checksum END,
    hba_rules = CASE WHEN EXCLUDED.hba_status = 'read' THEN EXCLUDED.hba_rules ELSE s.hba_rules END,
    hba_read_at = CASE WHEN EXCLUDED.hba_status = 'read' THEN EXCLUDED.hba_read_at ELSE s.hba_read_at END,
    unreadable_dbs = EXCLUDED.unreadable_dbs;

  -- ---- roles and memberships (cluster-wide) ------------------------------------------------------------------
  IF v_cluster THEN
    INSERT INTO pgvigil.role_attributes AS a (instance_id, rolname, snapshot_at, role_oid, super, inherit, createrole, createdb,
                                              canlogin, replication, bypassrls, connlimit, valid_until, config, is_present)
    SELECT p_instance_id, r->>'name', p_snapshot_at, (r->>'oid')::bigint, (r->>'super')::boolean, (r->>'inherit')::boolean,
           (r->>'createrole')::boolean, (r->>'createdb')::boolean, (r->>'canlogin')::boolean, (r->>'replication')::boolean,
           (r->>'bypassrls')::boolean, (r->>'connlimit')::int, (r->>'valid_until')::timestamptz,
           pgvigil.role_text_array(r->'config'), true
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'role'
    ON CONFLICT (instance_id, rolname) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, role_oid = EXCLUDED.role_oid, super = EXCLUDED.super, inherit = EXCLUDED.inherit,
      createrole = EXCLUDED.createrole, createdb = EXCLUDED.createdb, canlogin = EXCLUDED.canlogin,
      replication = EXCLUDED.replication, bypassrls = EXCLUDED.bypassrls, connlimit = EXCLUDED.connlimit,
      valid_until = EXCLUDED.valid_until, config = EXCLUDED.config, is_present = true;
    UPDATE pgvigil.role_attributes a SET is_present = false, snapshot_at = p_snapshot_at
     WHERE a.instance_id = p_instance_id AND a.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'role' AND r->>'name' = a.rolname);

    INSERT INTO pgvigil.role_members AS m (instance_id, role_name, member_name, grantor_name, snapshot_at, admin_option,
                                           inherit_option, set_option, is_present)
    SELECT p_instance_id, r->>'role', r->>'member', coalesce(r->>'grantor', ''), p_snapshot_at, (r->>'admin_option')::boolean,
           (r->>'inherit_option')::boolean, (r->>'set_option')::boolean, true
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'member'
    ON CONFLICT (instance_id, role_name, member_name, grantor_name) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, admin_option = EXCLUDED.admin_option, inherit_option = EXCLUDED.inherit_option,
      set_option = EXCLUDED.set_option, is_present = true;
    UPDATE pgvigil.role_members m SET is_present = false, snapshot_at = p_snapshot_at
     WHERE m.instance_id = p_instance_id AND m.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                        WHERE r->>'kind' = 'member' AND r->>'role' = m.role_name AND r->>'member' = m.member_name
                          AND coalesce(r->>'grantor', '') = m.grantor_name);

    DELETE FROM pgvigil.role_member_closure WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.role_member_closure (instance_id, member_name, role_name, depth)
    WITH RECURSIVE c(member_name, role_name, depth) AS (
      SELECT member_name, role_name, 1 FROM pgvigil.role_members WHERE instance_id = p_instance_id AND is_present
      UNION
      SELECT c.member_name, m.role_name, c.depth + 1
        FROM c JOIN pgvigil.role_members m ON m.instance_id = p_instance_id AND m.member_name = c.role_name AND m.is_present
       WHERE c.depth < 20
    )
    SELECT p_instance_id, member_name, role_name, min(depth) FROM c GROUP BY member_name, role_name;
  END IF;

  -- ---- database ACLs (one shared catalog, every database at once) --------------------------------------------
  IF v_aclnames IS NOT NULL THEN
    INSERT INTO pgvigil.acl_databases AS d (instance_id, datname, grantee, grantor, snapshot_at, owner, privileges, grantable, is_default, is_present)
    SELECT p_instance_id, r->>'datname', r->>'grantee', r->>'grantor', p_snapshot_at, r->>'owner', r->>'privileges',
           coalesce(r->>'grantable', ''), coalesce((r->>'is_default')::boolean, false), true
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'dbacl'
    ON CONFLICT (instance_id, datname, grantee, grantor) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, owner = EXCLUDED.owner, privileges = EXCLUDED.privileges,
      grantable = EXCLUDED.grantable, is_default = EXCLUDED.is_default, is_present = true;
    UPDATE pgvigil.acl_databases d SET is_present = false, snapshot_at = p_snapshot_at
     WHERE d.instance_id = p_instance_id AND d.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                        WHERE r->>'kind' = 'dbacl' AND r->>'datname' = d.datname AND r->>'grantee' = d.grantee AND r->>'grantor' = d.grantor);
  END IF;

  -- ---- schema ACLs and default privileges: the databases this read completed are replaced, the others kept ---
  INSERT INTO pgvigil.acl_schemas AS s (instance_id, datname, schema_name, grantee, grantor, snapshot_at, owner, privileges, grantable, is_default, is_present)
  SELECT p_instance_id, r->>'datname', r->>'schema_name', r->>'grantee', r->>'grantor', p_snapshot_at, r->>'owner', r->>'privileges',
         coalesce(r->>'grantable', ''), coalesce((r->>'is_default')::boolean, false), true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'schemaacl'
  ON CONFLICT (instance_id, datname, schema_name, grantee, grantor) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, owner = EXCLUDED.owner, privileges = EXCLUDED.privileges,
    grantable = EXCLUDED.grantable, is_default = EXCLUDED.is_default, is_present = true;
  UPDATE pgvigil.acl_schemas s SET is_present = false, snapshot_at = p_snapshot_at
   WHERE s.instance_id = p_instance_id AND s.is_present
     AND ((s.datname = ANY (v_dbs)
           AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                            WHERE r->>'kind' = 'schemaacl' AND r->>'datname' = s.datname AND r->>'schema_name' = s.schema_name
                              AND r->>'grantee' = s.grantee AND r->>'grantor' = s.grantor))
          OR s.datname <> ALL (coalesce(v_aclnames, ARRAY[s.datname])));

  INSERT INTO pgvigil.acl_default_privileges AS p (instance_id, datname, owner, schema_name, objtype, grantee, grantor, snapshot_at,
                                                   privileges, grantable, is_present)
  SELECT p_instance_id, r->>'datname', r->>'owner', coalesce(r->>'schema_name', ''), r->>'objtype', r->>'grantee', r->>'grantor',
         p_snapshot_at, r->>'privileges', coalesce(r->>'grantable', ''), true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'defacl'
  ON CONFLICT (instance_id, datname, owner, schema_name, objtype, grantee, grantor) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, privileges = EXCLUDED.privileges, grantable = EXCLUDED.grantable, is_present = true;
  UPDATE pgvigil.acl_default_privileges p SET is_present = false, snapshot_at = p_snapshot_at
   WHERE p.instance_id = p_instance_id AND p.is_present
     AND ((p.datname = ANY (v_dbs)
           AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                            WHERE r->>'kind' = 'defacl' AND r->>'datname' = p.datname AND r->>'owner' = p.owner
                              AND coalesce(r->>'schema_name', '') = p.schema_name AND r->>'objtype' = p.objtype
                              AND r->>'grantee' = p.grantee AND r->>'grantor' = p.grantor))
          OR p.datname <> ALL (coalesce(v_aclnames, ARRAY[p.datname])));

  INSERT INTO pgvigil.role_databases AS d (instance_id, datname, dbid, read_at, is_present)
  SELECT p_instance_id, r->>'datname', (r->>'dbid')::bigint, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db'
  ON CONFLICT (instance_id, datname) DO UPDATE SET dbid = EXCLUDED.dbid, read_at = EXCLUDED.read_at, is_present = true;
  IF v_aclnames IS NOT NULL THEN   -- a database dropped (gone from pg_database); one only unreadable keeps its rows
    UPDATE pgvigil.role_databases d SET is_present = false
     WHERE d.instance_id = p_instance_id AND d.is_present AND d.datname <> ALL (v_aclnames);
  END IF;

  -- ---- the hba rules: a read replaces them, a skip keeps the last ones -----------------------------------------
  IF v_hba->>'status' = 'read' THEN
    INSERT INTO pgvigil.hba_rules AS h (instance_id, file_name, line_number, snapshot_at, rule_number, type, databases, users,
                                        address, netmask, auth_method, options, error, is_present)
    SELECT p_instance_id, coalesce(r->>'file_name', ''), (r->>'line_number')::int, p_snapshot_at, (r->>'rule_number')::int, r->>'type',
           pgvigil.role_text_array(r->'databases'),
           pgvigil.role_text_array(r->'users'),
           r->>'address', r->>'netmask', r->>'auth_method',
           pgvigil.role_text_array(r->'options'),
           r->>'error', true
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'hba'
    ON CONFLICT (instance_id, file_name, line_number) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, rule_number = EXCLUDED.rule_number, type = EXCLUDED.type, databases = EXCLUDED.databases,
      users = EXCLUDED.users, address = EXCLUDED.address, netmask = EXCLUDED.netmask, auth_method = EXCLUDED.auth_method,
      options = EXCLUDED.options, error = EXCLUDED.error, is_present = true;
    UPDATE pgvigil.hba_rules h SET is_present = false, snapshot_at = p_snapshot_at
     WHERE h.instance_id = p_instance_id AND h.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                        WHERE r->>'kind' = 'hba' AND coalesce(r->>'file_name', '') = h.file_name AND (r->>'line_number')::int = h.line_number);
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- the role rules, one row per finding in pgvigil.findings' columns: instance_id, severity, setting, value,
-- is_set, suggested, platforms, detail, source, at. Only instances with a roles read take part.
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW pgvigil.role_findings AS
WITH st AS (
  SELECT s.*, i.platform FROM pgvigil.role_state s JOIN pgvigil.instances i USING (instance_id)
), a AS (
  SELECT a.*, st.platform, pgvigil.role_is_platform(st.platform, a.rolname, a.role_oid) AS is_platform
    FROM pgvigil.role_attributes a JOIN st USING (instance_id)
   WHERE a.is_present
), m AS (
  SELECT * FROM pgvigil.role_members WHERE is_present
), admins AS (   -- the platform's administrator logins: members of its admin role (the RDS master user and the like)
  SELECT DISTINCT m.instance_id, m.member_name AS rolname
    FROM m WHERE m.role_name IN ('rds_superuser', 'azure_pg_admin', 'cloudsqlsuperuser', 'alloydbsuperuser')
), app AS (      -- application roles: not a superuser, not the server's or the platform's own, not a platform admin
  SELECT a.* FROM a
   WHERE NOT a.super AND NOT a.is_platform
     AND NOT EXISTS (SELECT 1 FROM admins x WHERE x.instance_id = a.instance_id AND x.rolname = a.rolname)
), dbs AS (
  SELECT instance_id, count(DISTINCT datname) AS n FROM pgvigil.acl_databases WHERE is_present GROUP BY instance_id
), hst AS (      -- the instances whose stored hba rules can be judged: read at least once, and no line in error (with a
                 -- syntax error the server keeps the rules it loaded before, so the file shown is not the one in effect)
  SELECT st.instance_id FROM st
   WHERE st.hba_rules IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pgvigil.hba_rules e WHERE e.instance_id = st.instance_id AND e.is_present AND e.error IS NOT NULL)
), hu AS (       -- each user entry of each rule that admits a normal connection (replication-only rules left out)
  SELECT h.instance_id, h.auth_method, u
    FROM pgvigil.hba_rules h JOIN hst USING (instance_id) CROSS JOIN LATERAL unnest(h.users) u
   WHERE h.is_present AND h.error IS NULL
     AND EXISTS (SELECT 1 FROM unnest(h.databases) d WHERE d <> 'replication')
), lg AS (
  SELECT a.instance_id, a.rolname, a.valid_until, a.snapshot_at FROM a JOIN hst USING (instance_id) WHERE a.canlogin
), hit AS (      -- (login role, method) for every entry that names it: all or an @file, itself or +itself, a +group it
                 -- is a member of at any depth, a /regex that matches it
  SELECT lg.instance_id, lg.rolname, hu.auth_method FROM lg JOIN hu ON hu.instance_id = lg.instance_id AND (hu.u = 'all' OR hu.u LIKE '@%')
  UNION
  SELECT lg.instance_id, lg.rolname, hu.auth_method FROM lg JOIN hu ON hu.instance_id = lg.instance_id AND hu.u IN (lg.rolname, '+' || lg.rolname)
  UNION
  SELECT lg.instance_id, lg.rolname, hu.auth_method
    FROM lg JOIN pgvigil.role_member_closure c ON c.instance_id = lg.instance_id AND c.member_name = lg.rolname
    JOIN hu ON hu.instance_id = lg.instance_id AND hu.u = '+' || c.role_name
  UNION
  SELECT lg.instance_id, lg.rolname, hu.auth_method
    FROM lg JOIN hu ON hu.instance_id = lg.instance_id AND hu.u LIKE '/%' AND pgvigil.role_regex_match(lg.rolname, substr(hu.u, 2))
), way AS (      -- per login role: the auth methods that let it in (reject aside)
  SELECT lg.instance_id, lg.rolname, lg.valid_until, lg.snapshot_at,
         array_agg(DISTINCT hit.auth_method) FILTER (WHERE hit.auth_method IS NOT NULL AND hit.auth_method <> 'reject') AS methods
    FROM lg LEFT JOIN hit ON hit.instance_id = lg.instance_id AND hit.rolname = lg.rolname
   GROUP BY lg.instance_id, lg.rolname, lg.valid_until, lg.snapshot_at
)
-- a superuser beyond the server's bootstrap role and the platform's own
SELECT a.instance_id, 'warning' AS severity, 'superuser' AS setting, a.rolname AS value, true AS is_set,
       'ALTER ROLE ' || quote_ident(a.rolname) || ' NOSUPERUSER (or keep it for a named DBA and say so)' AS suggested, 'all' AS platforms,
       a.rolname || ' is a superuser' || CASE WHEN a.canlogin THEN ' and can log in' ELSE ' (NOLOGIN, reachable by SET ROLE from its members)' END
       || ': it bypasses every privilege check, reads every file the server can and can run programs as the server''s OS user; '
       || 'on a managed platform only the platform''s own role is superuser' AS detail,
       'pgvigil' AS source, a.snapshot_at AS at
  FROM a WHERE a.super AND NOT a.is_platform
UNION ALL
-- CREATEROLE or BYPASSRLS on an application role
SELECT app.instance_id, 'warning', x.attr, app.rolname, true,
       'ALTER ROLE ' || quote_ident(app.rolname) || ' NO' || x.attr, 'all',
       CASE x.attr
         WHEN 'CREATEROLE' THEN app.rolname || ' has CREATEROLE: it can create roles and grant itself any role it administers (before PostgreSQL 16 any non-superuser role); an application seldom needs it'
         ELSE app.rolname || ' has BYPASSRLS: every row-level security policy is skipped for it' END,
       'pgvigil', app.snapshot_at
  FROM app CROSS JOIN LATERAL (VALUES ('CREATEROLE', app.createrole), ('BYPASSRLS', app.bypassrls)) x(attr, hit)
 WHERE x.hit
UNION ALL
-- the monitoring login without pg_monitor
SELECT st.instance_id, 'warning', 'pg_monitor', st.login_name, true,
       'GRANT pg_monitor TO ' || quote_ident(st.login_name), 'all',
       'the monitoring login ' || st.login_name || ' is not a member of pg_monitor: other sessions'' queries, the statement history, '
       || 'the preload lists and several settings read empty or fail',
       'pgvigil', st.snapshot_at
  FROM st WHERE st.login_has_pg_monitor IS FALSE
UNION ALL
-- a role (not PUBLIC, not the owner, not a superuser or the platform's own) granted on every database
SELECT g.instance_id, 'info', 'granted on every database', g.grantee, true,
       'grant per database, where the role is needed', 'all',
       g.grantee || ' holds ' || g.privs || ' on every one of the ' || g.n || ' databases: a grant made everywhere by habit, or a role that needs no per-database limit',
       'pgvigil', g.at
  FROM (SELECT d.instance_id, d.grantee, dbs.n, string_agg(DISTINCT d.privileges, ' / ') AS privs, max(d.snapshot_at) AS at
          FROM pgvigil.acl_databases d JOIN dbs USING (instance_id)
          LEFT JOIN a ON a.instance_id = d.instance_id AND a.rolname = d.grantee
         WHERE d.is_present AND d.grantee <> 'PUBLIC' AND d.grantee IS DISTINCT FROM d.owner
           AND NOT coalesce(a.super OR a.is_platform, false)
         GROUP BY d.instance_id, d.grantee, dbs.n
        HAVING count(DISTINCT d.datname) = dbs.n AND dbs.n >= 2) g
UNION ALL
-- a login role with no way in: no hba rule names it (reject aside), or only password rules do and its password has
-- expired (VALID UNTIL). Whether a role has a password at all is not visible: pg_roles masks it and pg_authid is
-- never read; the rule needs the hba rules read (a superuser login, or SELECT granted on pg_hba_file_rules) and none
-- of them in error.
SELECT w.instance_id, 'info', 'login without a way in', w.rolname, true,
       'ALTER ROLE ' || quote_ident(w.rolname) || ' NOLOGIN if it is unused, or a pg_hba.conf line for it', 'all',
       CASE WHEN w.methods IS NULL
            THEN w.rolname || ' can log in (LOGIN) but no pg_hba.conf rule admits it: every connection is refused'
            ELSE w.rolname || ' is admitted only by password (' || array_to_string(w.methods, ', ') || ') and its password expired '
                 || to_char(w.valid_until AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC: no other method lets it in' END,
       'pgvigil', w.snapshot_at
  FROM way w
 WHERE w.methods IS NULL
    OR (w.valid_until < now() AND w.methods <@ ARRAY['md5', 'scram-sha-256', 'password']);

-- per instance: the superusers and the login roles, with the roles each is a member of (directly)
CREATE OR REPLACE VIEW pgvigil.role_fleet AS
SELECT a.instance_id, a.rolname, a.super, a.canlogin, a.createrole, a.createdb, a.replication, a.bypassrls, a.valid_until,
       pgvigil.role_is_platform(i.platform, a.rolname, a.role_oid) AS is_platform,
       (SELECT string_agg(DISTINCT m.role_name, ', ') FROM pgvigil.role_members m
         WHERE m.instance_id = a.instance_id AND m.member_name = a.rolname AND m.is_present) AS member_of,
       a.snapshot_at
  FROM pgvigil.role_attributes a JOIN pgvigil.instances i USING (instance_id)
 WHERE a.is_present AND (a.super OR a.canlogin);
