-- 0159: SQL Server security checks (task 408, B15; the collection mssql_security, internal/mssql/security.go, hourly).
-- dbachecks 3.0.2's security checks (MIT, Copyright (c) 2017 Chrissy LeMaire; read from its source at the v3.0.2 tag:
-- source/internal/assertions/Database.Assertions.ps1, Instance.Assertions.ps1, configuration.ps1's skip flags) and
-- SQLMonitor's login password expiry notice (de87d37, MIT), judged here over what the collection read. pgvigil's own
-- text and SQL; no code of either is copied.
--
--   mssql_security_read        per instance and part (logins, server_perms, registry, auth, proxies, databases): how the
--                              last run left it (read | no right | failed | off | n/a) and why; read_at = the last read
--   mssql_security_context     per instance: the machine name, the collector's login, Linux or not, its rights
--   mssql_security_logins      every login (sys.server_principals S U G E X C K): type, the original sa (sid 0x01),
--                              disabled, sysadmin, RDS's master-user roles, signed in now; a SQL login's must-change,
--                              days until expiration, CHECK_POLICY and CHECK_EXPIRATION
--   mssql_security_server_perms  public's server permissions (replaced by each read)
--   mssql_security_registry    AuditLevel and HideInstance with where each was read (n/a rows on Linux)
--   mssql_security_auth        the collector's own connection; mssql_security_auth_counts every connection by scheme
--   mssql_security_proxies     the Agent proxies and whether msdb's public role may use each
--   mssql_security_db          every database the server lists: containment, entered by the last run or not, its last read
--   mssql_security_db_objects  per database read: users, guest's CONNECT, user assemblies, certificates (expiry, use),
--                              asymmetric and symmetric keys. A database not read in a run keeps its rows (absence is
--                              judged only for the databases read: 408 pass F9)
--   mssql_security_rule_defs   the rules: key, label, source check, part, severity, on or off by default
--   mssql_security_config      the settings (a rule on or off, the owner lists, the day thresholds, the expected scheme) at
--                              the fleet, a tag or an instance - 0152's mssql_counter_config shape: one live row per key
--                              and scope, an edit ends the row and writes its successor; written only through
--                              import_mssql_security_config; mssql_security_config_log every attempt
--   mssql_security_settings    the value in force per instance and key (instance > tag > fleet > the default)
--   import_mssql_security_parts(i)   the parts an instance's rules in force need: the collector reads no part all of whose
--                              rules are off (pass F6; the runner's settings hook is the join's wiring)
--   mssql_security_rule_state  every rule x SQL Server instance: on / off and where set, its verdict (ok | hit | not read
--                              | n/a | not enabled) and hits, so the page shows what an off rule would say
--   mssql_security_findings    instance_id, severity, check_name, object, at, detail of the rules in force that hit (the
--                              arm for pgvigil.findings is the join's)
-- Nothing here grows by the month: each table holds the current state; a row no longer present is kept marked 30 days
-- and then deleted by the import itself, so purge() has nothing to do.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_read (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  part         text NOT NULL,
  status       text NOT NULL CHECK (status IN ('read', 'no right', 'failed', 'off', 'n/a')),
  note         text,
  snapshot_at  timestamptz NOT NULL,
  read_at      timestamptz,
  PRIMARY KEY (instance_id, part)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_context (
  instance_id          int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  machine_name         text,
  login_name           text,
  linux                boolean,
  view_any_definition  boolean,
  alter_any_login      boolean,
  view_server_state    boolean,
  snapshot_at          timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_logins (
  instance_id            int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  login_name             text NOT NULL,
  login_type             text,
  principal_id           int,
  is_original_sa         boolean,
  is_disabled            boolean,
  created_at             timestamptz,
  modified_at            timestamptz,
  must_change            boolean,
  days_until_expiration  int,
  is_policy_checked      boolean,
  is_expiration_checked  boolean,
  is_sysadmin            boolean,
  rds_master_roles       boolean,
  has_session            boolean,      -- NULL: not read (no VIEW SERVER STATE)
  snapshot_at            timestamptz NOT NULL,
  is_present             boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, login_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_server_perms (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  class_desc       text NOT NULL,
  permission_name  text NOT NULL,
  state_desc       text NOT NULL,
  major_id         int NOT NULL,
  object_name      text,
  snapshot_at      timestamptz NOT NULL,
  PRIMARY KEY (instance_id, class_desc, permission_name, state_desc, major_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_registry (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  value_name   text NOT NULL CHECK (value_name IN ('AuditLevel', 'HideInstance')),
  value        text,
  applies      boolean NOT NULL DEFAULT true,
  source       text,
  note         text,
  snapshot_at  timestamptz NOT NULL,
  PRIMARY KEY (instance_id, value_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_auth (
  instance_id     int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  auth_scheme     text,
  net_transport   text,
  client_address  text,
  local_address   text,
  snapshot_at     timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_auth_counts (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  auth_scheme    text NOT NULL,
  net_transport  text NOT NULL,
  connections    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  PRIMARY KEY (instance_id, auth_scheme, net_transport)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_proxies (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  proxy_name       text NOT NULL,
  enabled          boolean,
  credential_name  text,
  public_granted   boolean,
  snapshot_at      timestamptz NOT NULL,
  is_present       boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, proxy_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_db (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  containment    int,
  entered        boolean NOT NULL,      -- the last run entered it
  read_at        timestamptz,           -- the last run that read its objects
  note           text,
  snapshot_at    timestamptz NOT NULL,
  is_present     boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_db_objects (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name        text NOT NULL,
  object_kind          text NOT NULL CHECK (object_kind IN ('user', 'guest_connect', 'assembly', 'certificate', 'asym_key', 'sym_key')),
  object_name          text NOT NULL,
  object_type          text,          -- a user's type (S U G C K E X)
  authentication_type  int,           -- a user's: 0 none, 1 instance, 2 database, 3 Windows
  sid_length           int,
  principal_id         int,
  has_login            boolean,       -- a server principal has the user's SID (NULL: not testable here)
  has_connect          boolean,
  detail               text,          -- a permission set, an algorithm, a private key's protection, guest's grant state
  thumbprint           text,
  key_length           int,
  expires_at           timestamptz,
  cert_use             text,          -- master's certificates: TDE, backup encryption, an endpoint
  snapshot_at          timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, object_kind, object_name)
);

-- ---- the import --------------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_security(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_read text[];
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_security: instance % is not a SQL Server instance', p_instance_id;
  END IF;

  -- the parts' states; a part read is applied whole below, any other keeps what an earlier read stored
  INSERT INTO pgvigil.mssql_security_read AS s (instance_id, part, status, note, snapshot_at, read_at)
  SELECT DISTINCT ON (r->>'part') p_instance_id, r->>'part', r->>'status', nullif(r->>'note', ''), p_snapshot_at,
         CASE WHEN r->>'status' = 'read' THEN p_snapshot_at END
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'part' AND r->>'part' IS NOT NULL
  ON CONFLICT (instance_id, part) DO UPDATE SET status = EXCLUDED.status, note = EXCLUDED.note,
     snapshot_at = EXCLUDED.snapshot_at, read_at = coalesce(EXCLUDED.read_at, s.read_at);
  SELECT coalesce(array_agg(r->>'part'), '{}') INTO v_read
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'part' AND r->>'status' = 'read';

  INSERT INTO pgvigil.mssql_security_context AS c (instance_id, machine_name, login_name, linux, view_any_definition, alter_any_login,
      view_server_state, snapshot_at)
  SELECT p_instance_id, r->>'machine_name', r->>'login_name', (r->>'linux')::boolean, (r->>'view_any_definition')::boolean,
         (r->>'alter_any_login')::boolean, (r->>'view_server_state')::boolean, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'context' LIMIT 1
  ON CONFLICT (instance_id) DO UPDATE SET machine_name = EXCLUDED.machine_name, login_name = EXCLUDED.login_name, linux = EXCLUDED.linux,
     view_any_definition = EXCLUDED.view_any_definition, alter_any_login = EXCLUDED.alter_any_login,
     view_server_state = EXCLUDED.view_server_state, snapshot_at = EXCLUDED.snapshot_at;

  IF 'logins' = ANY (v_read) THEN
    INSERT INTO pgvigil.mssql_security_logins AS l (instance_id, login_name, login_type, principal_id, is_original_sa, is_disabled,
        created_at, modified_at, must_change, days_until_expiration, is_policy_checked, is_expiration_checked, is_sysadmin,
        rds_master_roles, has_session, snapshot_at)
    SELECT DISTINCT ON (r->>'login_name') p_instance_id, r->>'login_name', r->>'login_type', (r->>'principal_id')::int,
           (r->>'is_original_sa')::int = 1, (r->>'is_disabled')::int = 1, (r->>'created_utc')::timestamptz,
           (r->>'modified_utc')::timestamptz, (r->>'must_change')::int = 1, (r->>'days_until_expiration')::int,
           (r->>'is_policy_checked')::int = 1, (r->>'is_expiration_checked')::int = 1, (r->>'is_sysadmin')::int = 1,
           (r->>'rds_master_roles')::int = 1, (r->>'has_session')::int = 1, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'login' AND r->>'login_name' IS NOT NULL
    ON CONFLICT (instance_id, login_name) DO UPDATE SET login_type = EXCLUDED.login_type, principal_id = EXCLUDED.principal_id,
       is_original_sa = EXCLUDED.is_original_sa, is_disabled = EXCLUDED.is_disabled, created_at = EXCLUDED.created_at,
       modified_at = EXCLUDED.modified_at, must_change = EXCLUDED.must_change, days_until_expiration = EXCLUDED.days_until_expiration,
       is_policy_checked = EXCLUDED.is_policy_checked, is_expiration_checked = EXCLUDED.is_expiration_checked,
       is_sysadmin = EXCLUDED.is_sysadmin, rds_master_roles = EXCLUDED.rds_master_roles, has_session = EXCLUDED.has_session,
       snapshot_at = EXCLUDED.snapshot_at, is_present = true;
    UPDATE pgvigil.mssql_security_logins SET is_present = false
     WHERE instance_id = p_instance_id AND is_present AND snapshot_at < p_snapshot_at;
    DELETE FROM pgvigil.mssql_security_logins
     WHERE instance_id = p_instance_id AND NOT is_present AND snapshot_at < p_snapshot_at - interval '30 days';
  END IF;

  IF 'server_perms' = ANY (v_read) THEN
    DELETE FROM pgvigil.mssql_security_server_perms WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_security_server_perms (instance_id, class_desc, permission_name, state_desc, major_id, object_name, snapshot_at)
    SELECT DISTINCT ON (r->>'class_desc', r->>'permission_name', r->>'state_desc', (r->>'major_id')::int)
           p_instance_id, r->>'class_desc', r->>'permission_name', r->>'state_desc', (r->>'major_id')::int, r->>'object_name', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'server_perm' AND r->>'permission_name' IS NOT NULL;
  END IF;

  IF 'registry' = ANY (v_read) THEN
    INSERT INTO pgvigil.mssql_security_registry AS g (instance_id, value_name, value, applies, source, note, snapshot_at)
    SELECT DISTINCT ON (r->>'value_name') p_instance_id, r->>'value_name', r->>'value', r->>'kind' = 'registry', r->>'source',
           r->>'note', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' IN ('registry', 'registry_na') AND r->>'value_name' IN ('AuditLevel', 'HideInstance')
    ON CONFLICT (instance_id, value_name) DO UPDATE SET value = EXCLUDED.value, applies = EXCLUDED.applies, source = EXCLUDED.source,
       note = EXCLUDED.note, snapshot_at = EXCLUDED.snapshot_at;
  END IF;

  IF 'auth' = ANY (v_read) THEN
    INSERT INTO pgvigil.mssql_security_auth AS a (instance_id, auth_scheme, net_transport, client_address, local_address, snapshot_at)
    SELECT p_instance_id, r->>'auth_scheme', r->>'net_transport', r->>'client_address', r->>'local_address', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'auth_own' LIMIT 1
    ON CONFLICT (instance_id) DO UPDATE SET auth_scheme = EXCLUDED.auth_scheme, net_transport = EXCLUDED.net_transport,
       client_address = EXCLUDED.client_address, local_address = EXCLUDED.local_address, snapshot_at = EXCLUDED.snapshot_at;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'auth_count') THEN
      DELETE FROM pgvigil.mssql_security_auth_counts WHERE instance_id = p_instance_id;
      INSERT INTO pgvigil.mssql_security_auth_counts (instance_id, auth_scheme, net_transport, connections, snapshot_at)
      SELECT p_instance_id, coalesce(r->>'auth_scheme', ''), coalesce(r->>'net_transport', ''), sum((r->>'connections')::int), p_snapshot_at
        FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'auth_count'
       GROUP BY 2, 3;
    END IF;
  END IF;

  IF 'proxies' = ANY (v_read) THEN
    INSERT INTO pgvigil.mssql_security_proxies AS x (instance_id, proxy_name, enabled, credential_name, public_granted, snapshot_at)
    SELECT DISTINCT ON (r->>'proxy_name') p_instance_id, r->>'proxy_name', (r->>'enabled')::int = 1, r->>'credential_name',
           (r->>'public_granted')::int = 1, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'proxy' AND r->>'proxy_name' IS NOT NULL
    ON CONFLICT (instance_id, proxy_name) DO UPDATE SET enabled = EXCLUDED.enabled, credential_name = EXCLUDED.credential_name,
       public_granted = EXCLUDED.public_granted, snapshot_at = EXCLUDED.snapshot_at, is_present = true;
    UPDATE pgvigil.mssql_security_proxies SET is_present = false WHERE instance_id = p_instance_id AND is_present AND snapshot_at < p_snapshot_at;
    DELETE FROM pgvigil.mssql_security_proxies WHERE instance_id = p_instance_id AND NOT is_present AND snapshot_at < p_snapshot_at - interval '30 days';
  END IF;

  IF 'databases' = ANY (v_read) THEN
    INSERT INTO pgvigil.mssql_security_db AS d (instance_id, database_name, containment, entered, read_at, note, snapshot_at)
    SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', (r->>'containment')::int,
           EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'dbread' AND x->>'database_name' = r->>'database_name'),
           CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'dbread' AND x->>'database_name' = r->>'database_name')
                THEN p_snapshot_at END,
           r->>'note', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'database' AND r->>'database_name' IS NOT NULL
    ON CONFLICT (instance_id, database_name) DO UPDATE SET containment = coalesce(EXCLUDED.containment, d.containment),
       entered = EXCLUDED.entered, read_at = coalesce(EXCLUDED.read_at, d.read_at), note = EXCLUDED.note,
       snapshot_at = EXCLUDED.snapshot_at, is_present = true;
    UPDATE pgvigil.mssql_security_db SET is_present = false WHERE instance_id = p_instance_id AND is_present AND snapshot_at < p_snapshot_at;
    DELETE FROM pgvigil.mssql_security_db WHERE instance_id = p_instance_id AND NOT is_present AND snapshot_at < p_snapshot_at - interval '30 days';
    DELETE FROM pgvigil.mssql_security_db_objects o
     WHERE o.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_security_db d WHERE d.instance_id = o.instance_id AND d.database_name = o.database_name);
    -- each database read this run: its objects replaced whole; a database not read keeps its rows (pass F9)
    DELETE FROM pgvigil.mssql_security_db_objects o
     WHERE o.instance_id = p_instance_id
       AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'dbread' AND x->>'database_name' = o.database_name);
    INSERT INTO pgvigil.mssql_security_db_objects (instance_id, database_name, object_kind, object_name, object_type, authentication_type,
        sid_length, principal_id, has_login, has_connect, detail, thumbprint, key_length, expires_at, cert_use, snapshot_at)
    SELECT DISTINCT ON (r->>'database_name', r->>'object_kind', r->>'object_name')
           p_instance_id, r->>'database_name', r->>'object_kind', r->>'object_name', r->>'object_type',
           CASE WHEN r->>'object_kind' = 'user' THEN (r->>'num1')::int END,
           CASE WHEN r->>'object_kind' = 'user' THEN (r->>'num2')::int END,
           CASE WHEN r->>'object_kind' = 'user' THEN (r->>'num3')::int END,
           CASE WHEN r->>'object_kind' = 'user' AND r->>'flag1' IS NOT NULL THEN (r->>'flag1')::int = 1 END,
           CASE WHEN r->>'object_kind' = 'user' THEN (r->>'flag2')::int = 1 END,
           r->>'text1',
           CASE WHEN r->>'object_kind' = 'certificate' THEN r->>'text2' END,
           CASE WHEN r->>'object_kind' IN ('asym_key', 'sym_key') THEN (r->>'num1')::int END,
           CASE WHEN r->>'object_kind' = 'certificate' THEN (r->>'at_utc')::timestamptz END,
           r->>'use', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'dbobject' AND r->>'database_name' IS NOT NULL AND r->>'object_name' IS NOT NULL
       AND r->>'object_kind' IN ('user', 'guest_connect', 'assembly', 'certificate', 'asym_key', 'sym_key')
       AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'dbread' AND x->>'database_name' = r->>'database_name')
    ON CONFLICT DO NOTHING;
  END IF;
END $$;

-- ---- the rules and the settings ----------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_rule_defs (
  rule_key    text PRIMARY KEY,
  label       text NOT NULL,       -- the check_name of its findings
  source      text NOT NULL,       -- the source tool and its check
  part        text,                -- the collection's part it needs (NULL: not readable through SQL - 'not enabled')
  severity    text NOT NULL CHECK (severity IN ('critical', 'warning', 'info')),
  default_on  boolean NOT NULL,
  departure   text,                -- where pgvigil departs from the source (shown with a *)
  sort        int NOT NULL
);
INSERT INTO pgvigil.mssql_security_rule_defs (rule_key, label, source, part, severity, default_on, departure, sort) VALUES
  ('owner_allow',         'database owner not in the allow-list',         'dbachecks ValidDatabaseOwner (Database#8)',      'databases', 'warning', true,
   'the allow-list defaults to the original sa login (principal 1, whatever its name), on RDS the master user; a database whose owner maps to no login is the existing ''database owner unknown''', 10),
  ('owner_deny',          'database owner in the deny-list',              'dbachecks InvalidDatabaseOwner (Database#9)',    'databases', 'warning', true,
   'the deny-list starts empty (dbachecks names sa in both lists, so a stock server fails one of them)', 20),
  ('cert_expired',        'a certificate has expired',                    'dbachecks CertificateExpiration (Database#30)',  'databases', 'critical', true,
   'graded by use: backup encryption and Service Broker critical, TDE and endpoints warning; master''s certificates read', 30),
  ('cert_expiring',       'a certificate expires soon',                   'dbachecks CertificateExpiration (Database#31)',  'databases', 'warning', true,
   'the window in days (default 30: dbachecks'' one month); master''s certificates read', 40),
  ('orphaned_user',       'an orphaned database user',                    'dbachecks OrphanedUser (Database#38)',           'databases', 'warning', true,
   'judged only where the logins were read with VIEW ANY DEFINITION; a Windows user is info (access may come through a group login)', 50),
  ('clr_not_safe',        'a user CLR assembly is not SAFE',              'dbachecks CLRAssembliesSafe (Database#47)',      'databases', 'warning', false, NULL, 60),
  ('guest_connect',       'guest holds CONNECT in a user database',       'dbachecks GuestUserConnect (Database#48)',       'databases', 'warning', false, NULL, 70),
  ('asym_key_size',       'an asymmetric key under 2048 bits',            'dbachecks AsymmetricKeySize (Database#49)',      'databases', 'warning', false, NULL, 80),
  ('sym_key_algorithm',   'a symmetric key not AES',                      'dbachecks SymmetricKeyEncryptionLevel (Database#50)', 'databases', 'warning', false, NULL, 90),
  ('contained_sql_auth',  'a contained database has SQL users',           'dbachecks ContainedDBSQLAuth (Database#51)',     'databases', 'warning', false, NULL, 100),
  ('auth_scheme',         'the collector signed in with NTLM',            'dbachecks InstanceConnection (Instance#2)',      'auth', 'info', true,
   'judged on a Windows-authenticated collector over the network only; the NTLM connections count is the SPN symptom SQL can see', 110),
  ('sa_exists',           'a login named sa exists',                      'dbachecks SaRenamed (Instance#27)',              'logins', 'info', true,
   'info, not a failure: most servers keep sa', 120),
  ('sa_enabled',          'the original sa login is enabled',             'dbachecks SaDisabled (Instance#28)',             'logins', 'warning', false, NULL, 130),
  ('windows_login_disabled', 'a Windows login is disabled',               'dbachecks ADUser (Instance#42)',                 'logins', 'info', true,
   'every Windows login read, not only role members; info: a disabled login is often meant', 140),
  ('windows_group_disabled', 'a Windows group login is disabled',         'dbachecks ADUser (Instance#44)',                 'logins', 'info', true, NULL, 150),
  ('builtin_admin',       'BUILTIN\Administrators is a login',            'dbachecks BuiltInAdmin (Instance#60)',           'logins', 'warning', false, NULL, 160),
  ('local_windows_group', 'a local Windows group is a login',             'dbachecks LocalWindowsGroup (Instance#61)',      'logins', 'warning', false,
   'n/a on Linux', 170),
  ('login_audit_failed',  'failed logins are not audited',                'dbachecks LoginAuditFailed (Instance#62)',       'registry', 'warning', false, NULL, 180),
  ('login_audit_all',     'successful logins are not audited',            'dbachecks LoginAuditSuccessful (Instance#63)',   'registry', 'info', false, NULL, 190),
  ('proxy_public',        'an Agent proxy is granted to msdb''s public',  'dbachecks SqlAgentProxiesNoPublicRole (Instance#64)', 'proxies', 'warning', false, NULL, 200),
  ('hide_instance',       'the instance is not hidden',                   'dbachecks HideInstance (Instance#65)',           'registry', 'info', false, 'n/a on Linux', 210),
  ('check_policy_off',    'an enabled SQL login has CHECK_POLICY off',    'dbachecks LoginCheckPolicy (Instance#69)',       'logins', 'warning', false, NULL, 220),
  ('sysadmin_expiration_off', 'a sysadmin SQL login has CHECK_EXPIRATION off', 'dbachecks LoginPasswordExpiration (Instance#70)', 'logins', 'warning', false, NULL, 230),
  ('sysadmin_must_change', 'a new sysadmin SQL login need not change its password', 'dbachecks LoginMustChange (Instance#71)', 'logins', 'info', false,
   '''never signed in'' as dbatools reads it: no session now (needs VIEW SERVER STATE)', 240),
  ('public_server_perm',  'public holds a server permission beyond the defaults', 'dbachecks PublicPermission (Instance#74)',   'server_perms', 'warning', false, NULL, 250),
  ('password_expiry',     'a SQL login''s password expires soon',         'SQLMonitor usp_send_login_expiry_emails (C63, A61)', 'logins', 'warning', true,
   'warning within 20 days, critical within 10 or expired (the days are settings); never-expiring and unknown not judged', 260),
  ('ad_user_found',       'a Windows login''s account is not in Active Directory', 'dbachecks ADUser (Instance#38)', NULL, 'warning', false, 'needs the site-profile D5 door (Active Directory)', 300),
  ('ad_password_expired', 'a Windows login''s account password has expired', 'dbachecks ADUser (Instance#39)',      NULL, 'warning', false, 'needs the site-profile D5 door (Active Directory)', 310),
  ('ad_locked',           'a Windows login''s account is locked out',     'dbachecks ADUser (Instance#40)',                 NULL, 'warning', false, 'needs the site-profile D5 door (Active Directory)', 320),
  ('ad_enabled',          'a Windows login''s account is disabled in AD', 'dbachecks ADUser (Instance#41)',                 NULL, 'warning', false, 'needs the site-profile D5 door (Active Directory)', 330),
  ('ad_group_found',      'a Windows group login is not in Active Directory', 'dbachecks ADUser (Instance#43)',             NULL, 'warning', false, 'needs the site-profile D5 door (Active Directory)', 340),
  ('engine_service_admin', 'the SQL Server service account is a local administrator', 'dbachecks EngineServiceAdmin (Instance#66)', NULL, 'warning', false, 'needs the site-profile D5 door (Windows host)', 350),
  ('agent_service_admin', 'the Agent service account is a local administrator', 'dbachecks AgentServiceAdmin (Instance#67)', NULL, 'warning', false, 'needs the site-profile D5 door (Windows host)', 360),
  ('fulltext_service_admin', 'the Full-Text service account is a local administrator', 'dbachecks FullTextServiceAdmin (Instance#68)', NULL, 'warning', false, 'needs the site-profile D5 door (Windows host)', 370),
  ('spn',                 'an SPN of the service account is missing',     'dbachecks SPN (Server#2)',                       NULL, 'warning', false, 'needs the site-profile D5 door (Active Directory); the NTLM count is its symptom', 380)
ON CONFLICT (rule_key) DO UPDATE SET label = EXCLUDED.label, source = EXCLUDED.source, part = EXCLUDED.part, severity = EXCLUDED.severity,
  default_on = EXCLUDED.default_on, departure = EXCLUDED.departure, sort = EXCLUDED.sort;

-- the settings' keys besides rule:<rule_key> (on | off)
CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_setting_keys (
  key          text PRIMARY KEY,
  label        text NOT NULL,
  value_kind   text NOT NULL CHECK (value_kind IN ('list', 'days', 'scheme')),
  default_val  text            -- NULL: the rule's own default (owner_allow: the original sa / RDS's master user)
);
INSERT INTO pgvigil.mssql_security_setting_keys (key, label, value_kind, default_val) VALUES
  ('owner_allow',    'logins allowed to own a database',                'list',   NULL),
  ('owner_deny',     'logins that may not own a database',              'list',   '[]'),
  ('cert_warn_days', 'days before a certificate''s expiry to warn',     'days',   '30'),
  ('pwd_warn_days',  'days before a password''s expiry to warn',        'days',   '20'),
  ('pwd_crit_days',  'days before a password''s expiry to raise critical', 'days', '10'),
  ('auth_expected',  'the scheme a Windows-authenticated collector should use', 'scheme', 'KERBEROS')
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, value_kind = EXCLUDED.value_kind, default_val = EXCLUDED.default_val;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_config (
  config_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope          text NOT NULL CHECK (scope IN ('fleet', 'tag', 'instance')),
  tag            text CHECK (length(tag) BETWEEN 1 AND 200),
  instance_name  text CHECK (length(instance_name) BETWEEN 1 AND 200),
  key            text NOT NULL CHECK (length(key) BETWEEN 1 AND 80),
  value          text NOT NULL CHECK (length(value) <= 4000),
  note           text CHECK (length(note) BETWEEN 1 AND 500),
  replaces       bigint,
  created_by     text NOT NULL,
  created_at     timestamptz NOT NULL,
  client         text,
  ended_by       text,
  ended_at       timestamptz,
  CONSTRAINT "a tag row names its tag, an instance row its instance" CHECK (
    (scope = 'fleet' AND tag IS NULL AND instance_name IS NULL) OR (scope = 'tag' AND tag IS NOT NULL AND instance_name IS NULL)
    OR (scope = 'instance' AND tag IS NULL AND instance_name IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS mssql_security_config_live_uq ON pgvigil.mssql_security_config
  (key, scope, coalesce(tag, ''), coalesce(instance_name, '')) WHERE ended_at IS NULL;
COMMENT ON TABLE pgvigil.mssql_security_config IS 'SQL Server security rule settings at the fleet, a tag or an instance; written through import_mssql_security_config only.';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_security_config_log (
  log_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at         timestamptz NOT NULL,
  ui_user    text NOT NULL,
  client     text,
  op         text,
  config_id  bigint,
  outcome    text NOT NULL CHECK (outcome IN ('done', 'refused')),
  detail     text,
  payload    jsonb
);
CREATE INDEX IF NOT EXISTS mssql_security_config_log_at_idx ON pgvigil.mssql_security_config_log (at DESC);

-- import_mssql_security_config: one edit from the Security page (the actions door's audit login, behind the UI login):
-- op 'add' (scope, tag | instance_name, key, value, note) writes the live row of that key and scope (a second add is an
-- edit: the old row ends, the new one names it), op 'end' (config_id) ends a row so the scope inherits again. key is
-- rule:<rule_key> (value on | off) or a setting key (a list: a JSON array of login names; days: 0-3650; scheme:
-- KERBEROS | NTLM). Answers {outcome: done | refused, detail, config_id}; a refusal writes nothing but its log row.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_security_config(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op     text := p_payload->>'op';
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client text := nullif(p_payload->>'client', '');
  v_scope  text := p_payload->>'scope';
  v_tag    text := nullif(btrim(coalesce(p_payload->>'tag', '')), '');
  v_inst   text := nullif(p_payload->>'instance_name', '');
  v_key    text := nullif(btrim(coalesce(p_payload->>'key', '')), '');
  v_value  text := btrim(coalesce(p_payload->>'value', ''));
  v_note   text := nullif(btrim(coalesce(p_payload->>'note', '')), '');
  v_kind   text;
  v_id     bigint;
  v_old    bigint;
  v_new    bigint;
  v_why    text;
  v_list   jsonb;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_mssql_security_config: no ui_user' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.mssql_security_config'));
  IF v_op IS NULL OR v_op NOT IN ('add', 'end') THEN
    v_why := 'op must be add or end';
  ELSIF v_op = 'end' THEN
    IF coalesce(p_payload->>'config_id', '') ~ '^[0-9]{1,18}$' THEN
      v_id := (p_payload->>'config_id')::bigint;
    END IF;
    IF v_id IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.mssql_security_config WHERE config_id = v_id AND ended_at IS NULL) THEN
      v_why := format('no live row %s', coalesce(p_payload->>'config_id', '(none)'));
    END IF;
  ELSE
    IF v_scope IS NULL OR v_scope NOT IN ('fleet', 'tag', 'instance') THEN
      v_why := 'scope must be fleet, tag or instance';
    ELSIF v_scope = 'tag' AND v_tag IS NULL THEN
      v_why := 'a tag row names its tag';
    ELSIF v_scope = 'instance' AND NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.name = v_inst AND i.is_active AND i.engine = 'sqlserver') THEN
      v_why := format('no active SQL Server instance %L', v_inst);
    ELSIF v_key IS NULL THEN
      v_why := 'a row names its key';
    ELSIF v_key LIKE 'rule:%' THEN
      IF NOT EXISTS (SELECT 1 FROM pgvigil.mssql_security_rule_defs d WHERE d.rule_key = substr(v_key, 6) AND d.part IS NOT NULL) THEN
        v_why := format('%s is not a rule pgvigil can judge (a ''not enabled'' rule needs its door)', v_key);
      ELSIF v_value NOT IN ('on', 'off') THEN
        v_why := 'a rule is on or off';
      END IF;
    ELSE
      SELECT k.value_kind INTO v_kind FROM pgvigil.mssql_security_setting_keys k WHERE k.key = v_key;
      IF v_kind IS NULL THEN
        v_why := format('%s is not a setting', v_key);
      ELSIF v_kind = 'list' THEN
        BEGIN
          v_list := v_value::jsonb;
        EXCEPTION WHEN others THEN
          v_list := NULL;
        END;
        IF v_list IS NULL OR jsonb_typeof(v_list) <> 'array' OR jsonb_array_length(v_list) > 100
           OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) e WHERE jsonb_typeof(e) <> 'string' OR length(e #>> '{}') NOT BETWEEN 1 AND 128) THEN
          v_why := 'a list is a JSON array of up to 100 login names (1-128 characters each)';
        ELSE
          v_value := (SELECT coalesce(jsonb_agg(DISTINCT btrim(e #>> '{}')), '[]'::jsonb)::text FROM jsonb_array_elements(v_list) e);
        END IF;
      ELSIF v_kind = 'days' AND (v_value !~ '^[0-9]{1,4}$' OR v_value::int > 3650) THEN
        v_why := 'days are a whole number from 0 to 3650';
      ELSIF v_kind = 'scheme' AND upper(v_value) NOT IN ('KERBEROS', 'NTLM') THEN
        v_why := 'the expected scheme is KERBEROS or NTLM';
      ELSIF v_kind = 'scheme' THEN
        v_value := upper(v_value);
      END IF;
    END IF;
    IF v_why IS NULL AND v_key IN ('pwd_warn_days', 'pwd_crit_days') THEN
      -- critical at or under warning, judged against the value in force at the same scope
      IF v_key = 'pwd_crit_days' AND v_value::int > coalesce((SELECT c.value::int FROM pgvigil.mssql_security_config c
            WHERE c.key = 'pwd_warn_days' AND c.ended_at IS NULL AND c.scope = v_scope AND coalesce(c.tag, '') = coalesce(v_tag, '')
              AND coalesce(c.instance_name, '') = coalesce(v_inst, '')), 20) THEN
        v_why := 'the critical days are at or under the warning days';
      ELSIF v_key = 'pwd_warn_days' AND v_value::int < coalesce((SELECT c.value::int FROM pgvigil.mssql_security_config c
            WHERE c.key = 'pwd_crit_days' AND c.ended_at IS NULL AND c.scope = v_scope AND coalesce(c.tag, '') = coalesce(v_tag, '')
              AND coalesce(c.instance_name, '') = coalesce(v_inst, '')), 10) THEN
        v_why := 'the warning days are at or over the critical days';
      END IF;
    END IF;
  END IF;
  IF v_why IS NULL AND v_op = 'add' AND v_note IS NOT NULL AND length(v_note) > 500 THEN
    v_why := 'a note is 500 characters at most';
  END IF;
  IF v_why IS NOT NULL THEN
    INSERT INTO pgvigil.mssql_security_config_log (at, ui_user, client, op, config_id, outcome, detail, payload)
    VALUES (p_at, v_user, v_client, v_op, v_id, 'refused', v_why, p_payload);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_op = 'end' THEN
    UPDATE pgvigil.mssql_security_config SET ended_by = v_user, ended_at = p_at WHERE config_id = v_id;
    INSERT INTO pgvigil.mssql_security_config_log (at, ui_user, client, op, config_id, outcome, detail, payload)
    VALUES (p_at, v_user, v_client, 'end', v_id, 'done', 'ended: the scope inherits again', p_payload);
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'ended', 'config_id', v_id);
  END IF;
  IF v_scope <> 'tag' THEN v_tag := NULL; END IF;
  IF v_scope <> 'instance' THEN v_inst := NULL; END IF;
  SELECT c.config_id INTO v_old FROM pgvigil.mssql_security_config c
   WHERE c.key = v_key AND c.scope = v_scope AND coalesce(c.tag, '') = coalesce(v_tag, '') AND coalesce(c.instance_name, '') = coalesce(v_inst, '')
     AND c.ended_at IS NULL;
  IF v_old IS NOT NULL THEN
    UPDATE pgvigil.mssql_security_config SET ended_by = v_user, ended_at = p_at WHERE config_id = v_old;
  END IF;
  INSERT INTO pgvigil.mssql_security_config (scope, tag, instance_name, key, value, note, replaces, created_by, created_at, client)
  VALUES (v_scope, v_tag, v_inst, v_key, v_value, v_note, v_old, v_user, p_at, v_client)
  RETURNING config_id INTO v_new;
  INSERT INTO pgvigil.mssql_security_config_log (at, ui_user, client, op, config_id, outcome, detail, payload)
  VALUES (p_at, v_user, v_client, 'add', v_new, 'done', CASE WHEN v_old IS NULL THEN 'set' ELSE format('set (replaces %s)', v_old) END, p_payload);
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'set', 'config_id', v_new);
END $$;

-- the value in force per SQL Server instance and key: the instance's own row, else a tag's (two tags with rows: the
-- newer row), else the fleet's, else the default (a rule's default_on; a setting key's default_val)
CREATE OR REPLACE VIEW pgvigil.mssql_security_settings AS
WITH keys AS (
  SELECT 'rule:' || d.rule_key AS key, CASE WHEN d.default_on THEN 'on' ELSE 'off' END AS default_val FROM pgvigil.mssql_security_rule_defs d WHERE d.part IS NOT NULL
  UNION ALL
  SELECT k.key, k.default_val FROM pgvigil.mssql_security_setting_keys k
), live AS (
  SELECT i.instance_id, c.key, c.value, c.scope, c.tag, c.config_id, c.created_by, c.created_at,
         CASE c.scope WHEN 'instance' THEN 3 WHEN 'tag' THEN 2 ELSE 1 END AS level
    FROM pgvigil.mssql_security_config c
    JOIN pgvigil.instances i ON i.is_active AND i.engine = 'sqlserver'
    LEFT JOIN pgvigil.instance_tags_merged t ON t.instance_id = i.instance_id
   WHERE c.ended_at IS NULL
     AND (c.scope = 'fleet' OR (c.scope = 'instance' AND c.instance_name = i.name)
          OR (c.scope = 'tag' AND c.tag = ANY (coalesce(t.tags, '{}'::text[]))))
), best AS (
  SELECT DISTINCT ON (l.instance_id, l.key) l.* FROM live l ORDER BY l.instance_id, l.key, l.level DESC, l.config_id DESC
)
SELECT i.instance_id, k.key, coalesce(b.value, k.default_val) AS value, coalesce(b.scope, 'default') AS set_at, b.tag AS set_tag,
       b.config_id, b.created_by AS set_by, b.created_at AS set_on
  FROM pgvigil.instances i
  CROSS JOIN keys k
  LEFT JOIN best b ON b.instance_id = i.instance_id AND b.key = k.key
 WHERE i.is_active AND i.engine = 'sqlserver';

-- the parts an instance's rules in force need (the collector's settings hook): a part is read when any of its rules is on;
-- Inst#2's auth part is cheap and always read
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_security_parts(p_instance_id int) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('parts', coalesce(jsonb_object_agg(x.part, x.wanted), '{}'::jsonb))
    FROM (SELECT d.part, bool_or(s.value = 'on') OR d.part = 'auth' AS wanted
            FROM pgvigil.mssql_security_rule_defs d
            JOIN pgvigil.mssql_security_settings s ON s.instance_id = p_instance_id AND s.key = 'rule:' || d.rule_key
           WHERE d.part IS NOT NULL
           GROUP BY d.part) x
$$;

-- ---- the hits ----------------------------------------------------------------------------------------------------

-- every hit of every rule (on or off), with its object and detail; a rule's own conditions only (on / off and the
-- part's state are the rule_state view's)
CREATE OR REPLACE VIEW pgvigil.mssql_security_hits AS
WITH inst AS (
  SELECT i.instance_id, i.platform, coalesce(c.linux, false) AS linux, c.machine_name,
         coalesce(c.view_any_definition, false) OR coalesce(c.alter_any_login, false) AS logins_full
    FROM pgvigil.instances i
    LEFT JOIN pgvigil.mssql_security_context c ON c.instance_id = i.instance_id
   WHERE i.is_active AND i.engine = 'sqlserver'
), setting AS (
  SELECT s.instance_id, s.key, s.value FROM pgvigil.mssql_security_settings s
), allow AS (
  -- the owner allow-list: the setting, else the original sa (and on RDS the master user's two roles)
  SELECT i.instance_id, lower(n) AS login
    FROM inst i
    JOIN setting s ON s.instance_id = i.instance_id AND s.key = 'owner_allow' AND s.value IS NOT NULL
    CROSS JOIN LATERAL jsonb_array_elements_text(s.value::jsonb) n
  UNION
  SELECT i.instance_id, lower(l.login_name)
    FROM inst i
    JOIN setting s ON s.instance_id = i.instance_id AND s.key = 'owner_allow' AND s.value IS NULL
    JOIN pgvigil.mssql_security_logins l ON l.instance_id = i.instance_id AND l.is_present
         AND (l.is_original_sa OR (i.platform = 'rdssqlserver' AND l.rds_master_roles AND l.login_name <> 'rdsa'))
), deny AS (
  SELECT s.instance_id, lower(n) AS login
    FROM setting s CROSS JOIN LATERAL jsonb_array_elements_text(s.value::jsonb) n
   WHERE s.key = 'owner_deny' AND s.value IS NOT NULL
), days AS (
  SELECT s.instance_id,
         max(CASE WHEN s.key = 'cert_warn_days' THEN s.value::int END) AS cert_warn,
         max(CASE WHEN s.key = 'pwd_warn_days' THEN s.value::int END) AS pwd_warn,
         max(CASE WHEN s.key = 'pwd_crit_days' THEN s.value::int END) AS pwd_crit,
         max(CASE WHEN s.key = 'auth_expected' THEN s.value END) AS auth_expected
    FROM setting s GROUP BY s.instance_id
), dbs AS (   -- the database options' owner (the mssql_checks collection, 0090) for user databases
  SELECT o.instance_id, o.database_name, o.options->>'owner' AS owner, o.snapshot_at
    FROM pgvigil.mssql_database_option o
   WHERE o.is_present AND NOT o.is_system AND NOT o.is_snapshot AND o.database_name NOT IN ('master', 'msdb', 'model', 'tempdb')
), objs AS (
  SELECT o.*, d.containment FROM pgvigil.mssql_security_db_objects o
    JOIN pgvigil.mssql_security_db d ON d.instance_id = o.instance_id AND d.database_name = o.database_name AND d.is_present
)
-- DB#8, DB#9: the owner against the lists (an owner that maps to no login is 'database owner unknown', 0090)
SELECT b.instance_id, 'owner_allow'::text AS rule_key, NULL::text AS severity, b.database_name AS object,
       format('%s is owned by %s, which is not in the allow-list (%s)', b.database_name, b.owner,
              coalesce((SELECT string_agg(a.login, ', ' ORDER BY a.login) FROM allow a WHERE a.instance_id = b.instance_id), 'empty')) AS detail,
       b.snapshot_at AS at
  FROM dbs b JOIN inst i ON i.instance_id = b.instance_id
 WHERE i.platform <> 'azuresqldb' AND b.owner IS NOT NULL
   AND EXISTS (SELECT 1 FROM allow a WHERE a.instance_id = b.instance_id)
   AND NOT EXISTS (SELECT 1 FROM allow a WHERE a.instance_id = b.instance_id AND a.login = lower(b.owner))
UNION ALL
SELECT b.instance_id, 'owner_deny', NULL, b.database_name, format('%s is owned by %s, which is in the deny-list', b.database_name, b.owner), b.snapshot_at
  FROM dbs b JOIN inst i ON i.instance_id = b.instance_id
 WHERE i.platform <> 'azuresqldb' AND b.owner IS NOT NULL
   AND EXISTS (SELECT 1 FROM deny n WHERE n.instance_id = b.instance_id AND n.login = lower(b.owner))
UNION ALL
-- DB#30 / DB#31: a certificate by its use (pass F4); master's certificates included (a departure)
SELECT o.instance_id, CASE WHEN o.expires_at <= now() THEN 'cert_expired' ELSE 'cert_expiring' END,
       CASE WHEN o.expires_at > now() THEN 'warning'
            WHEN o.cert_use ~ 'backup encryption|Service Broker' THEN 'critical'
            WHEN o.cert_use ~ 'TDE|endpoint' THEN 'warning'
            ELSE 'critical' END,
       o.database_name || '.' || o.object_name,
       CASE WHEN o.expires_at <= now() THEN format('the certificate %s in %s expired %s', o.object_name, o.database_name, to_char(o.expires_at, 'YYYY-MM-DD'))
            ELSE format('the certificate %s in %s expires %s (%s days)', o.object_name, o.database_name, to_char(o.expires_at, 'YYYY-MM-DD'),
                        ceil(extract(epoch FROM o.expires_at - now()) / 86400)::int) END
       || coalesce('; used for ' || o.cert_use, '')
       || CASE WHEN o.expires_at <= now() AND o.cert_use ~ 'TDE' THEN '; expiry is not enforced for TDE: rotate it per policy'
               WHEN o.expires_at <= now() AND o.cert_use ~ 'mirroring' THEN '; an endpoint certificate''s expiry: rotate it before a reconnect needs it'
               ELSE '' END,
       o.snapshot_at
  FROM objs o JOIN days d ON d.instance_id = o.instance_id
 WHERE o.object_kind = 'certificate' AND o.expires_at IS NOT NULL
   AND o.expires_at <= now() + make_interval(days => coalesce(d.cert_warn, 30))
UNION ALL
-- DB#38: an orphaned user (dbatools' rule): a SQL user with a 16-byte SID in a database that is not contained, or a
-- Windows user / group (info), with no login of its SID; only where the logins were read in full (pass F3)
SELECT o.instance_id, 'orphaned_user', CASE WHEN o.object_type IN ('U', 'G') THEN 'info' END,
       o.database_name || '.' || o.object_name,
       format('the user %s in %s has no login with its SID', o.object_name, o.database_name)
       || CASE WHEN o.object_type IN ('U', 'G') THEN ' (a Windows user: access may come through a group login)' ELSE '' END,
       o.snapshot_at
  FROM objs o JOIN inst i ON i.instance_id = o.instance_id
 WHERE o.object_kind = 'user' AND i.logins_full AND i.platform <> 'azuresqldb' AND o.has_login = false
   AND ((o.object_type = 'S' AND o.sid_length = 16 AND coalesce(o.containment, 0) = 0) OR o.object_type IN ('U', 'G'))
UNION ALL
SELECT o.instance_id, 'clr_not_safe', NULL, o.database_name || '.' || o.object_name,
       format('the assembly %s in %s is %s', o.object_name, o.database_name, o.detail), o.snapshot_at
  FROM objs o
 WHERE o.object_kind = 'assembly' AND o.detail <> 'SAFE_ACCESS' AND o.database_name <> 'SSISDB' AND o.object_name <> 'ISSERVER'
UNION ALL
SELECT o.instance_id, 'guest_connect', NULL, o.database_name, format('guest holds CONNECT in %s (%s)', o.database_name, o.detail), o.snapshot_at
  FROM objs o
 WHERE o.object_kind = 'guest_connect' AND o.database_name NOT IN ('master', 'tempdb', 'msdb')
UNION ALL
SELECT o.instance_id, 'asym_key_size', NULL, o.database_name || '.' || o.object_name,
       format('the asymmetric key %s in %s is %s bits', o.object_name, o.database_name, o.key_length), o.snapshot_at
  FROM objs o WHERE o.object_kind = 'asym_key' AND o.key_length < 2048
UNION ALL
SELECT o.instance_id, 'sym_key_algorithm', NULL, o.database_name || '.' || o.object_name,
       format('the symmetric key %s in %s uses %s', o.object_name, o.database_name, o.detail), o.snapshot_at
  FROM objs o
 WHERE o.object_kind = 'sym_key' AND coalesce(o.detail, '') NOT IN ('AES_128', 'AES_192', 'AES_256')
   AND o.database_name NOT IN ('master', 'tempdb', 'msdb')
UNION ALL
SELECT o.instance_id, 'contained_sql_auth', NULL, o.database_name || '.' || o.object_name,
       format('%s is a SQL-authenticated user with access in the contained database %s', o.object_name, o.database_name), o.snapshot_at
  FROM objs o
 WHERE o.object_kind = 'user' AND coalesce(o.containment, 0) > 0 AND o.object_type = 'S' AND o.authentication_type IN (1, 2) AND o.has_connect
UNION ALL
-- Inst#2: the collector's own sign-in; only a Windows-authenticated collector over the network (not shared memory or
-- the host's own address: pass F7) is judged
SELECT a.instance_id, 'auth_scheme', NULL, 'collector',
       format('the collector signed in with %s where %s is expected (%s from %s)', a.auth_scheme, d.auth_expected, a.net_transport, a.client_address)
       || coalesce('; NTLM connections now: ' || (SELECT sum(c.connections) FROM pgvigil.mssql_security_auth_counts c
                                                   WHERE c.instance_id = a.instance_id AND c.auth_scheme = 'NTLM' AND c.net_transport = 'TCP'), ''),
       a.snapshot_at
  FROM pgvigil.mssql_security_auth a JOIN days d ON d.instance_id = a.instance_id
 WHERE a.auth_scheme IN ('NTLM', 'KERBEROS') AND a.auth_scheme <> d.auth_expected
   AND a.net_transport = 'TCP' AND coalesce(a.client_address, '') NOT IN ('<local machine>', '127.0.0.1', '::1')
   AND coalesce(a.client_address, '') <> coalesce(a.local_address, '-')
UNION ALL
SELECT l.instance_id, 'sa_exists', NULL, l.login_name, 'a login named sa exists' || CASE WHEN l.is_disabled THEN ' (disabled)' ELSE '' END, l.snapshot_at
  FROM pgvigil.mssql_security_logins l WHERE l.is_present AND lower(l.login_name) = 'sa'
UNION ALL
SELECT l.instance_id, 'sa_enabled', NULL, l.login_name, format('the original sa login (principal 1) %s is enabled', l.login_name), l.snapshot_at
  FROM pgvigil.mssql_security_logins l WHERE l.is_present AND l.is_original_sa AND NOT l.is_disabled
UNION ALL
SELECT l.instance_id, CASE l.login_type WHEN 'U' THEN 'windows_login_disabled' ELSE 'windows_group_disabled' END, NULL, l.login_name,
       format('the Windows %s login %s is disabled', CASE l.login_type WHEN 'U' THEN 'user' ELSE 'group' END, l.login_name), l.snapshot_at
  FROM pgvigil.mssql_security_logins l WHERE l.is_present AND l.login_type IN ('U', 'G') AND l.is_disabled
UNION ALL
SELECT l.instance_id, 'builtin_admin', NULL, l.login_name, 'BUILTIN\Administrators is a login: every local administrator can sign in', l.snapshot_at
  FROM pgvigil.mssql_security_logins l WHERE l.is_present AND upper(l.login_name) = 'BUILTIN\ADMINISTRATORS'
UNION ALL
SELECT l.instance_id, 'local_windows_group', NULL, l.login_name, format('%s is a group of the local machine %s', l.login_name, i.machine_name), l.snapshot_at
  FROM pgvigil.mssql_security_logins l JOIN inst i ON i.instance_id = l.instance_id
 WHERE l.is_present AND l.login_type = 'G' AND NOT i.linux AND i.machine_name IS NOT NULL
   AND upper(split_part(l.login_name, '\', 1)) = upper(i.machine_name)
UNION ALL
SELECT g.instance_id, 'login_audit_failed', NULL, 'login auditing',
       format('login auditing is %s: failed logins are not written to the error log',
              CASE g.value WHEN '0' THEN 'None' WHEN '1' THEN 'successful logins only' ELSE g.value END), g.snapshot_at
  FROM pgvigil.mssql_security_registry g WHERE g.value_name = 'AuditLevel' AND g.applies AND g.value IN ('0', '1')
UNION ALL
SELECT g.instance_id, 'login_audit_all', NULL, 'login auditing',
       format('login auditing is %s, not both failed and successful logins',
              CASE g.value WHEN '0' THEN 'None' WHEN '1' THEN 'successful logins only' WHEN '2' THEN 'failed logins only' ELSE g.value END), g.snapshot_at
  FROM pgvigil.mssql_security_registry g WHERE g.value_name = 'AuditLevel' AND g.applies AND g.value IN ('0', '1', '2')
UNION ALL
SELECT x.instance_id, 'proxy_public', NULL, x.proxy_name, format('msdb''s public role may use the Agent proxy %s (credential %s)', x.proxy_name, x.credential_name), x.snapshot_at
  FROM pgvigil.mssql_security_proxies x WHERE x.is_present AND x.public_granted
UNION ALL
SELECT g.instance_id, 'hide_instance', NULL, 'HideInstance', 'the instance is not hidden from SQL Server Browser''s list', g.snapshot_at
  FROM pgvigil.mssql_security_registry g WHERE g.value_name = 'HideInstance' AND g.applies AND coalesce(g.value, '0') <> '1'
UNION ALL
SELECT l.instance_id, 'check_policy_off', NULL, l.login_name, format('the SQL login %s is enabled with CHECK_POLICY off', l.login_name), l.snapshot_at
  FROM pgvigil.mssql_security_logins l WHERE l.is_present AND l.login_type = 'S' AND NOT l.is_disabled AND l.is_policy_checked = false
UNION ALL
SELECT l.instance_id, 'sysadmin_expiration_off', NULL, l.login_name, format('the sysadmin SQL login %s is enabled with CHECK_EXPIRATION off', l.login_name), l.snapshot_at
  FROM pgvigil.mssql_security_logins l
 WHERE l.is_present AND l.login_type = 'S' AND NOT l.is_disabled AND l.is_sysadmin AND l.is_expiration_checked = false
UNION ALL
SELECT l.instance_id, 'sysadmin_must_change', NULL, l.login_name,
       format('the sysadmin SQL login %s has no session and need not change its password at its first sign-in', l.login_name), l.snapshot_at
  FROM pgvigil.mssql_security_logins l
 WHERE l.is_present AND l.login_type = 'S' AND NOT l.is_disabled AND l.is_sysadmin AND l.must_change = false AND l.has_session = false
UNION ALL
SELECT p.instance_id, 'public_server_perm', NULL, p.permission_name || coalesce(' ON ' || p.object_name, ''),
       format('public holds %s %s%s', p.state_desc, p.permission_name, coalesce(' on ' || p.class_desc || ' ' || p.object_name, '')), p.snapshot_at
  FROM pgvigil.mssql_security_server_perms p
 WHERE p.state_desc LIKE 'GRANT%'
   AND NOT (p.state_desc = 'GRANT' AND p.permission_name = 'VIEW ANY DATABASE' AND p.class_desc = 'SERVER')
   AND NOT (p.state_desc = 'GRANT' AND p.permission_name = 'CONNECT' AND p.class_desc = 'ENDPOINT' AND p.major_id BETWEEN 2 AND 5)
UNION ALL
-- C63 / A61: password expiry (pass F5): -1 never expires, NULL unknown: not judged; 0 or less expired: critical
SELECT l.instance_id, 'password_expiry',
       CASE WHEN l.days_until_expiration <= d.pwd_crit THEN 'critical' ELSE 'warning' END, l.login_name,
       CASE WHEN l.days_until_expiration = 0 THEN format('the password of the SQL login %s has expired', l.login_name)
            ELSE format('the password of the SQL login %s expires in %s day(s)', l.login_name, l.days_until_expiration) END,
       l.snapshot_at
  FROM pgvigil.mssql_security_logins l JOIN days d ON d.instance_id = l.instance_id
 WHERE l.is_present AND l.login_type = 'S' AND NOT l.is_disabled AND l.is_expiration_checked
   AND l.days_until_expiration IS NOT NULL AND l.days_until_expiration >= 0 AND l.days_until_expiration <= d.pwd_warn;

-- every rule x SQL Server instance: on / off and where set, the part's state, the verdict and the hits
CREATE OR REPLACE VIEW pgvigil.mssql_security_rule_state AS
SELECT i.instance_id, d.rule_key, d.label, d.source, d.part, d.severity AS default_severity, d.departure, d.sort,
       coalesce(s.value = 'on', false) AS is_on, coalesce(s.set_at, 'default') AS set_at, s.set_tag, s.config_id,
       r.status AS part_status, r.note AS part_note, r.read_at,
       CASE WHEN d.part IS NULL THEN 'not enabled'
            WHEN i.platform = 'azuresqldb' AND d.rule_key NOT IN ('cert_expired', 'cert_expiring', 'guest_connect', 'asym_key_size', 'sym_key_algorithm', 'auth_scheme') THEN 'n/a'
            WHEN d.rule_key IN ('hide_instance', 'local_windows_group') AND coalesce(c.linux, false) THEN 'n/a'
            WHEN d.rule_key = 'orphaned_user' AND NOT (coalesce(c.view_any_definition, false) OR coalesce(c.alter_any_login, false)) THEN 'not read'
            WHEN r.status IS NULL OR r.read_at IS NULL THEN 'not read'
            WHEN EXISTS (SELECT 1 FROM pgvigil.mssql_security_hits h WHERE h.instance_id = i.instance_id AND h.rule_key = d.rule_key) THEN 'hit'
            ELSE 'ok' END AS verdict,
       (SELECT count(*) FROM pgvigil.mssql_security_hits h WHERE h.instance_id = i.instance_id AND h.rule_key = d.rule_key)::int AS hits
  FROM pgvigil.instances i
  CROSS JOIN pgvigil.mssql_security_rule_defs d
  LEFT JOIN pgvigil.mssql_security_settings s ON s.instance_id = i.instance_id AND s.key = 'rule:' || d.rule_key
  LEFT JOIN pgvigil.mssql_security_read r ON r.instance_id = i.instance_id AND r.part = d.part
  LEFT JOIN pgvigil.mssql_security_context c ON c.instance_id = i.instance_id
 WHERE i.is_active AND i.engine = 'sqlserver';

-- the findings: the hits of the rules in force whose verdict is a hit (the arm for pgvigil.findings is the join's)
CREATE OR REPLACE VIEW pgvigil.mssql_security_findings AS
SELECT h.instance_id, coalesce(h.severity, d.severity) AS severity, d.label AS check_name, h.object, h.at,
       h.detail || ' [' || d.source || ']' AS detail
  FROM pgvigil.mssql_security_hits h
  JOIN pgvigil.mssql_security_rule_defs d ON d.rule_key = h.rule_key
  JOIN pgvigil.mssql_security_rule_state st ON st.instance_id = h.instance_id AND st.rule_key = h.rule_key
 WHERE st.is_on AND st.verdict = 'hit';
