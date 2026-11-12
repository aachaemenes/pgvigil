-- 0105: the Reports tree (task 169): what the stock reports need that no collection kept. The reports themselves read
-- the repository (internal/web/q_reports.go); every report that an existing collection already answers reads that
-- collection's tables, and only the reads below are new.
--
-- SQL Server (the collection mssql_reports, internal/mssql/reports.go, hourly):
--   mssql_server_role_members  every member of every server role (sys.server_role_members with sys.server_principals)
--   mssql_sql_logins           every SQL login with LOGINPROPERTY's password last set time, days until expiration,
--                              expired, locked and bad password count (sys.sql_logins)
--   mssql_service_ext          the columns of sys.dm_server_services the services read (mssql_service, 0070) does not
--                              keep: the executable's file name and the cluster node name
--   mssql_table_size           each read's largest tables of each database (sys.dm_db_partition_stats): rows, reserved,
--                              used, data and index KB; one row per read, so the growth per day is a difference. Kept
--                              until purge() takes it: the line is the lead's (0110), an index on snapshot_at serves it
--   mssql_failed_logins        the error log's 'Login failed' lines (error 18456), read by this collection itself: the
--                              error log reader passes them over (sp_LogHunter's noise list), DBA Dash's FailedLogins
--                              collection reads them the same way; the login, the client and the reason taken apart
-- PostgreSQL (the collection reports, internal/collect/reports.go, hourly):
--   pg_role_passwords          the password method of each login role (scram-sha-256, md5, none) - read on a superuser
--                              login only, the method worked out on the server: the hash itself never leaves it
-- Both engines:
--   report_db_properties       the database-level properties: SQL Server's extended properties (sys.extended_properties
--                              class 0, in each database), PostgreSQL's COMMENT ON DATABASE; valid_from = the read that
--                              first saw the value, kept while the value stays
--   report_read_state          per instance and part: how the last read of it ended (read | no right | failed) and why
--
-- A part the login could not read leaves what an earlier read stored as it was (not read is not "gone"); its state row
-- says so. A part read is applied whole: a row the read no longer lists is marked not present (kept with its last values).

CREATE TABLE IF NOT EXISTS pgvigil.report_read_state (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  part         text NOT NULL,
  status       text NOT NULL CHECK (status IN ('read', 'no right', 'failed')),
  note         text,
  snapshot_at  timestamptz NOT NULL,
  PRIMARY KEY (instance_id, part)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_server_role_members (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  role_name     text NOT NULL,
  login_name    text NOT NULL,
  login_type    text,            -- S, U, G, R, C, K, E, X as sys.server_principals.type
  type_desc     text,
  is_disabled   boolean,
  created_at    timestamptz,
  modified_at   timestamptz,
  first_seen    timestamptz NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  is_present    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, role_name, login_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_sql_logins (
  instance_id            int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  login_name             text NOT NULL,
  is_disabled            boolean,
  created_at             timestamptz,
  modified_at            timestamptz,
  password_set_at        timestamptz,   -- LOGINPROPERTY(name, 'PasswordLastSetTime'); NULL = the server did not say
  is_policy_checked      boolean,
  is_expiration_checked  boolean,
  days_until_expiration  int,
  is_expired             boolean,
  is_locked              boolean,
  bad_password_count     int,
  snapshot_at            timestamptz NOT NULL,
  is_present             boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, login_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_service_ext (
  instance_id       int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  service_name      text NOT NULL,
  filename          text,
  cluster_nodename  text,
  snapshot_at       timestamptz NOT NULL,
  PRIMARY KEY (instance_id, service_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_table_size (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at    timestamptz NOT NULL,
  database_name  text NOT NULL,
  schema_name    text NOT NULL,
  table_name     text NOT NULL,
  row_count      bigint,
  reserved_kb    bigint,
  used_kb        bigint,
  data_kb        bigint,
  index_kb       bigint,
  PRIMARY KEY (instance_id, snapshot_at, database_name, schema_name, table_name)
);
CREATE INDEX IF NOT EXISTS mssql_table_size_name_idx ON pgvigil.mssql_table_size (instance_id, database_name, schema_name, table_name, snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_table_size_db_idx ON pgvigil.mssql_table_size (instance_id, database_name, snapshot_at DESC);
CREATE INDEX IF NOT EXISTS mssql_table_size_at_idx ON pgvigil.mssql_table_size (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_failed_logins (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  logged_at     timestamptz NOT NULL,   -- the line's time, from the server's clock and offset
  line_key      text NOT NULL,          -- md5 of the local time, the text and its place among identical lines of that time
  logged_local  timestamp NOT NULL,     -- the server's own clock, as the log wrote it
  login_name    text,
  client        text,
  reason        text,
  message       text NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  PRIMARY KEY (instance_id, logged_at, line_key)
);
CREATE INDEX IF NOT EXISTS mssql_failed_logins_at_idx ON pgvigil.mssql_failed_logins (logged_at);

CREATE TABLE IF NOT EXISTS pgvigil.pg_role_passwords (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  role_name    text NOT NULL,
  method       text NOT NULL CHECK (method IN ('scram-sha-256', 'md5', 'none', 'other')),
  snapshot_at  timestamptz NOT NULL,
  is_present   boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, role_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.report_db_properties (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  property       text NOT NULL,
  value          text,
  valid_from     timestamptz NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  is_present     boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, database_name, property)
);

-- report_state_apply: the part rows of a payload into report_read_state (an older read never overwrites a newer one)
CREATE OR REPLACE FUNCTION pgvigil.report_state_apply(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.report_read_state AS s (instance_id, part, status, note, snapshot_at)
  SELECT p_instance_id, r->>'part', r->>'status', nullif(left(r->>'note', 1000), ''), p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'part' AND r->>'part' IS NOT NULL AND r->>'status' IN ('read', 'no right', 'failed')
  ON CONFLICT (instance_id, part) DO UPDATE SET status = EXCLUDED.status, note = EXCLUDED.note, snapshot_at = EXCLUDED.snapshot_at
   WHERE s.snapshot_at <= EXCLUDED.snapshot_at
$$;

-- report_part_read: did this payload read the part (its part row says 'read'), and is it not older than the newest
-- state stored for the part (a late older read changes no row)
CREATE OR REPLACE FUNCTION pgvigil.report_part_read(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb, p_part text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'part' AND r->>'part' = p_part AND r->>'status' = 'read')
     AND NOT EXISTS (SELECT 1 FROM pgvigil.report_read_state s
                      WHERE s.instance_id = p_instance_id AND s.part = p_part AND s.snapshot_at > p_snapshot_at)
$$;

-- report_props_apply: the database properties of the databases this read entered (a 'dbread' row each); a database
-- not entered keeps its rows as they were
CREATE OR REPLACE FUNCTION pgvigil.report_props_apply(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.report_db_properties AS p (instance_id, database_name, property, value, valid_from, snapshot_at)
  SELECT DISTINCT ON (r->>'database_name', r->>'property') p_instance_id, r->>'database_name', r->>'property',
         left(r->>'value', 4000), p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'db_property' AND r->>'property' IS NOT NULL
     AND r->>'database_name' IN (SELECT x->>'database_name' FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'dbread')
  ON CONFLICT (instance_id, database_name, property) DO UPDATE SET
      -- the value's own start: kept while the value stays, the read's time when it changed or came back
      valid_from = CASE WHEN p.value IS NOT DISTINCT FROM EXCLUDED.value AND p.is_present THEN p.valid_from ELSE EXCLUDED.valid_from END,
      value = EXCLUDED.value, snapshot_at = EXCLUDED.snapshot_at, is_present = true
   WHERE p.snapshot_at <= EXCLUDED.snapshot_at;
  -- a property of an entered database that this read no longer lists is gone (kept, marked)
  UPDATE pgvigil.report_db_properties p SET is_present = false
   WHERE p.instance_id = p_instance_id AND p.is_present AND p.snapshot_at < p_snapshot_at
     AND p.database_name IN (SELECT x->>'database_name' FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'dbread');
  -- a database the server no longer lists at all (dropped, renamed): its properties are gone too. Only a read that
  -- sent the list (its 'dbname' rows: every database the server lists, entered or not) judges that
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'dbname') THEN
    UPDATE pgvigil.report_db_properties p SET is_present = false
     WHERE p.instance_id = p_instance_id AND p.is_present AND p.snapshot_at < p_snapshot_at
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'dbname' AND x->>'database_name' = p.database_name);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_reports(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_reports: instance % is not a SQL Server instance', p_instance_id;
  END IF;

  IF pgvigil.report_part_read(p_instance_id, p_snapshot_at, p_payload, 'role_members') THEN
    INSERT INTO pgvigil.mssql_server_role_members AS m (instance_id, role_name, login_name, login_type, type_desc, is_disabled,
        created_at, modified_at, first_seen, snapshot_at)
    SELECT DISTINCT ON (r->>'role_name', r->>'login_name') p_instance_id, r->>'role_name', r->>'login_name', r->>'login_type',
           r->>'type_desc', (r->>'is_disabled')::int = 1, (r->>'created_utc')::timestamptz, (r->>'modified_utc')::timestamptz,
           p_snapshot_at, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'role_member' AND r->>'role_name' IS NOT NULL AND r->>'login_name' IS NOT NULL
    ON CONFLICT (instance_id, role_name, login_name) DO UPDATE SET
        login_type = EXCLUDED.login_type, type_desc = EXCLUDED.type_desc, is_disabled = EXCLUDED.is_disabled,
        created_at = EXCLUDED.created_at, modified_at = EXCLUDED.modified_at, snapshot_at = EXCLUDED.snapshot_at,
        first_seen = CASE WHEN m.is_present THEN m.first_seen ELSE EXCLUDED.first_seen END, is_present = true;
    UPDATE pgvigil.mssql_server_role_members SET is_present = false
     WHERE instance_id = p_instance_id AND is_present AND snapshot_at < p_snapshot_at;
  END IF;

  IF pgvigil.report_part_read(p_instance_id, p_snapshot_at, p_payload, 'sql_logins') THEN
    INSERT INTO pgvigil.mssql_sql_logins AS l (instance_id, login_name, is_disabled, created_at, modified_at, password_set_at,
        is_policy_checked, is_expiration_checked, days_until_expiration, is_expired, is_locked, bad_password_count, snapshot_at)
    SELECT DISTINCT ON (r->>'login_name') p_instance_id, r->>'login_name', (r->>'is_disabled')::int = 1,
           (r->>'created_utc')::timestamptz, (r->>'modified_utc')::timestamptz, (r->>'password_set_utc')::timestamptz,
           (r->>'is_policy_checked')::int = 1, (r->>'is_expiration_checked')::int = 1, (r->>'days_until_expiration')::int,
           (r->>'is_expired')::int = 1, (r->>'is_locked')::int = 1, (r->>'bad_password_count')::int, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'sql_login' AND r->>'login_name' IS NOT NULL
    ON CONFLICT (instance_id, login_name) DO UPDATE SET
        is_disabled = EXCLUDED.is_disabled, created_at = EXCLUDED.created_at, modified_at = EXCLUDED.modified_at,
        password_set_at = EXCLUDED.password_set_at, is_policy_checked = EXCLUDED.is_policy_checked,
        is_expiration_checked = EXCLUDED.is_expiration_checked, days_until_expiration = EXCLUDED.days_until_expiration,
        is_expired = EXCLUDED.is_expired, is_locked = EXCLUDED.is_locked, bad_password_count = EXCLUDED.bad_password_count,
        snapshot_at = EXCLUDED.snapshot_at, is_present = true;
    UPDATE pgvigil.mssql_sql_logins SET is_present = false
     WHERE instance_id = p_instance_id AND is_present AND snapshot_at < p_snapshot_at;
  END IF;

  IF pgvigil.report_part_read(p_instance_id, p_snapshot_at, p_payload, 'services') THEN
    INSERT INTO pgvigil.mssql_service_ext AS e (instance_id, service_name, filename, cluster_nodename, snapshot_at)
    SELECT DISTINCT ON (r->>'service_name') p_instance_id, r->>'service_name', r->>'filename', nullif(r->>'cluster_nodename', ''), p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'service_ext' AND r->>'service_name' IS NOT NULL
    ON CONFLICT (instance_id, service_name) DO UPDATE SET
        filename = EXCLUDED.filename, cluster_nodename = EXCLUDED.cluster_nodename, snapshot_at = EXCLUDED.snapshot_at;
  END IF;

  IF pgvigil.report_part_read(p_instance_id, p_snapshot_at, p_payload, 'extended_properties') THEN
    PERFORM pgvigil.report_props_apply(p_instance_id, p_snapshot_at, p_payload);
  END IF;

  -- the table sizes are history: every read's rows are kept (purge() takes them past the retention once the lead's
  -- 0110 line is in)
  INSERT INTO pgvigil.mssql_table_size (instance_id, snapshot_at, database_name, schema_name, table_name, row_count,
      reserved_kb, used_kb, data_kb, index_kb)
  SELECT p_instance_id, p_snapshot_at, r->>'database_name', r->>'schema_name', r->>'table_name', (r->>'row_count')::bigint,
         (r->>'reserved_kb')::bigint, (r->>'used_kb')::bigint, (r->>'data_kb')::bigint, (r->>'index_kb')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'table_size' AND r->>'database_name' IS NOT NULL AND r->>'schema_name' IS NOT NULL AND r->>'table_name' IS NOT NULL
  ON CONFLICT DO NOTHING;

  -- failed logins: each line once (a later read that looks back over it again adds nothing)
  INSERT INTO pgvigil.mssql_failed_logins (instance_id, logged_at, line_key, logged_local, login_name, client, reason, message, snapshot_at)
  SELECT p_instance_id, (r->>'logged_utc')::timestamptz, md5(coalesce(r->>'logged_local', '') || '|' || coalesce(r->>'text', '') || '|' || coalesce(r->>'seq', '0')),
         (r->>'logged_local')::timestamp,
         substring(r->>'text' from 'for user ''([^'']*)'''), substring(r->>'text' from '\[CLIENT: ([^\]]*)\]'),
         nullif(trim(substring(r->>'text' from 'Reason: ([^\[]*)')), ''), left(r->>'text', 2000), p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'failed_login' AND r->>'logged_utc' IS NOT NULL AND r->>'logged_local' IS NOT NULL AND r->>'text' IS NOT NULL
  ON CONFLICT DO NOTHING;

  PERFORM pgvigil.report_state_apply(p_instance_id, p_snapshot_at, p_payload);
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_reports(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT coalesce(engine, 'postgres') FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'postgres' THEN
    RAISE EXCEPTION 'import_reports: instance % is not a PostgreSQL instance', p_instance_id;
  END IF;

  IF pgvigil.report_part_read(p_instance_id, p_snapshot_at, p_payload, 'passwords') THEN
    INSERT INTO pgvigil.pg_role_passwords AS p (instance_id, role_name, method, snapshot_at)
    SELECT DISTINCT ON (r->>'role_name') p_instance_id, r->>'role_name',
           CASE WHEN r->>'method' IN ('scram-sha-256', 'md5', 'none') THEN r->>'method' ELSE 'other' END, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'password' AND r->>'role_name' IS NOT NULL
    ON CONFLICT (instance_id, role_name) DO UPDATE SET method = EXCLUDED.method, snapshot_at = EXCLUDED.snapshot_at, is_present = true;
    UPDATE pgvigil.pg_role_passwords SET is_present = false
     WHERE instance_id = p_instance_id AND is_present AND snapshot_at < p_snapshot_at;
  END IF;

  IF pgvigil.report_part_read(p_instance_id, p_snapshot_at, p_payload, 'comments') THEN
    PERFORM pgvigil.report_props_apply(p_instance_id, p_snapshot_at, p_payload);
  END IF;

  PERFORM pgvigil.report_state_apply(p_instance_id, p_snapshot_at, p_payload);
END $$;

SELECT pgvigil.apply_roles();
