-- 0160 SQL Server configuration checks (task 409, build B16 of the SQL Server tools audit, with B24i's linked
-- servers and the Agent expectations of B9): the instance configuration and database option checks dbachecks names,
-- judged against an expected value that a site sets at the root, on a tag or on one instance.
--
--   mssql_confcheck_part     which part of the hourly read (mssql_confcheck) was read, or why not
--   mssql_confcheck_fact     the instance's facts that read gives: @@SERVERNAME and the server's own name, the
--                            machine, the error log files kept, master's startup procedures, the advised MAXDOP
--   mssql_xe_session_state   every server event session: starts with the server or not, running or not
--   mssql_db_confcheck       per database: state, read-only, standby, recovery model, Query Store, a secondary's
--                            role, the database-scoped MAXDOP
--   mssql_linked_server      the linked servers and the shape of their login mappings (never a remote password:
--                            the catalog has none to read)
--   mssql_linked_server_test the last connection test of each (mssql_linkedserver_test, off until the instance
--                            carries the tag pgvigil:linkedserver-test)
--   mssql_config_expect      the expected values; a change ends the live row and writes its successor, so the
--                            history of who set what stays (import_mssql_config_expect only)
--   mssql_config_expect_in_force(instance), mssql_config_expect_now
--                            the value in force per kind and key, with where it was set
--   mssql_config_checks      EVERY rule of every SQL Server instance, met or not: value, expected, set at, source,
--                            status. mssql_config_check_findings: its warning and critical rows.
--
-- A rule whose source is a site's policy (dbachecks' policy values) is OFF until a scope sets it: status 'off',
-- 'set an expectation', no finding. A rule whose source is Microsoft's guidance or a dbatools formula is ON, and a
-- scope may set it 'off'. status: ok | info | warning | critical | off | not read | not applicable. 'info' is shown
-- amber and makes no finding row.
--
-- Read here, written elsewhere: mssql_config (0063), mssql_instance (0063), mssql_service (0070), mssql_trace_flags
-- (0094), mssql_agent_operator and mssql_agent_alerting (0090), mssql_jobs (0066), mssql_property (0084: the TCP
-- port, the enabled protocols and Win32PrioritySeparation once the properties collection reads them, as tcp_port,
-- protocols_enabled and win32_priority_separation).

CREATE TABLE IF NOT EXISTS pgvigil.mssql_confcheck_part (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  part         text NOT NULL,            -- names | machine | xe | errorlog | startup | databases | linked
  is_read      boolean NOT NULL,
  note         text,                     -- why not read, or what the read left out
  snapshot_at  timestamptz NOT NULL,     -- the last run that covered the part, read or not
  PRIMARY KEY (instance_id, part)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_confcheck_fact (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  key          text NOT NULL,            -- server_name, property_server_name, machine_name, netbios, host_platform,
                                         -- num_errorlogs, errorlog_files, startup_procs, advised_maxdop, cpu_count
  value        jsonb,                    -- a text, a number or a list; NULL = the server gave none
  snapshot_at  timestamptz NOT NULL,
  PRIMARY KEY (instance_id, key)
);
-- the instances that share a machine (max server memory divides by them): looked up by the machine's name
CREATE INDEX IF NOT EXISTS mssql_confcheck_fact_value_idx ON pgvigil.mssql_confcheck_fact (key, lower(value #>> '{}'));

CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_session_state (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  session_name  text NOT NULL,
  autostart     boolean,
  running       boolean NOT NULL DEFAULT false,
  snapshot_at   timestamptz NOT NULL,
  PRIMARY KEY (instance_id, session_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_db_confcheck (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name   text NOT NULL,
  state           text,
  read_only       boolean,
  in_standby      boolean,
  recovery_model  text,
  query_store     boolean,
  secondary_role  text,                  -- mirror | availability group secondary | log shipping secondary
  scoped_maxdop   int,
  scoped_note     text,                  -- why the database-scoped MAXDOP was not read
  snapshot_at     timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_linked_server (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name             text NOT NULL,
  product          text,
  provider         text,
  data_source      text,
  catalog          text,
  rpc_out          boolean,
  data_access      boolean,
  connect_timeout  int,
  query_timeout    int,
  modified_at      timestamptz,
  logins           jsonb NOT NULL DEFAULT '[]',   -- [{local: <login> | 'every login', self: true | false, remote: true | false}]
  logins_read      boolean NOT NULL DEFAULT false,
  snapshot_at      timestamptz NOT NULL,
  PRIMARY KEY (instance_id, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_linked_server_test (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name             text NOT NULL,
  outcome          text NOT NULL CHECK (outcome IN ('ok', 'failed', 'unmapped', 'not tested')),
  error_number     int,
  error_message    text,
  seconds          numeric,
  note             text,                 -- why it was not tested this run
  tested_at        timestamptz NOT NULL, -- the last run that tested it, or said why not
  first_failed_at  timestamptz,          -- the first of the run of failed tests that still lasts
  PRIMARY KEY (instance_id, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_config_expect (
  expect_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  level        text NOT NULL CHECK (level IN ('root', 'tag', 'instance')),
  instance_id  int REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  tag          text CHECK (length(tag) BETWEEN 1 AND 200),
  kind         text NOT NULL,
  key          text NOT NULL CHECK (length(key) BETWEEN 1 AND 128),
  value        jsonb NOT NULL,
  exclusions   jsonb NOT NULL DEFAULT '[]',
  created_by   text NOT NULL,
  created_at   timestamptz NOT NULL,
  client       text,
  replaces     bigint,
  ended_by     text,
  ended_at     timestamptz,
  CONSTRAINT "the root level names nothing" CHECK (level <> 'root' OR (instance_id IS NULL AND tag IS NULL)),
  CONSTRAINT "a tag level names its tag only" CHECK (level <> 'tag' OR (tag IS NOT NULL AND instance_id IS NULL)),
  CONSTRAINT "an instance level names its instance only" CHECK (level <> 'instance' OR (instance_id IS NOT NULL AND tag IS NULL))
);
-- the values in force for one instance, and for its tags (each read per rule evaluation)
CREATE INDEX IF NOT EXISTS mssql_config_expect_live_instance_idx ON pgvigil.mssql_config_expect (instance_id) WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS mssql_config_expect_live_tag_idx ON pgvigil.mssql_config_expect (tag) WHERE ended_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS mssql_config_expect_live_idx
  ON pgvigil.mssql_config_expect (level, coalesce(instance_id, 0), coalesce(tag, ''), kind, key) WHERE ended_at IS NULL;
COMMENT ON TABLE pgvigil.mssql_config_expect IS 'Expected SQL Server configuration values at the root, tag and instance level; written through import_mssql_config_expect only, a change ends the row and writes its successor.';

-- mssql_config_expect_keys: the kinds and keys an expectation can be set for. vtype: number | text | list | numlist |
-- choice (one of choices). default_on: the rule judges without an expectation (a scope may set it 'off'). The kind
-- 'config' takes any sys.configurations option name as its key and a number as its value: it is not listed.
CREATE OR REPLACE FUNCTION pgvigil.mssql_config_expect_keys()
RETURNS TABLE (kind text, key text, vtype text, choices text[], takes_exclusions boolean, default_exclusions jsonb,
               default_on boolean, source text, rule text, label text, vmin bigint, vmax bigint)
LANGUAGE sql IMMUTABLE AS $$
  SELECT v.*, r.vmin, r.vmax FROM (VALUES
    ('database', 'recovery_model', 'choice', ARRAY['FULL', 'SIMPLE', 'BULK_LOGGED'], true, '["master", "tempdb", "model", "msdb"]'::jsonb, false, 'dbachecks policy', 'Database#13', 'recovery model'),
    ('database', 'scoped_maxdop', 'number', NULL, true, '[]'::jsonb, false, 'dbachecks policy', 'Database#43', 'database-scoped MAXDOP'),
    ('database', 'state', 'choice', ARRAY['on'], true, '[]'::jsonb, false, 'dbachecks policy', 'Database#44', 'databases restoring, read-only or in standby'),
    ('database', 'expected', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Database#45', 'expected databases'),
    ('database', 'query_store', 'choice', ARRAY['on', 'off'], true, '["master", "tempdb", "model"]'::jsonb, false, 'dbachecks policy', 'Database#52', 'Query Store'),
    ('service', 'engine_start_mode', 'choice', ARRAY['Automatic', 'Manual', 'Disabled', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#6', 'engine start mode'),
    ('service', 'agent_start_mode', 'choice', ARRAY['Automatic', 'Manual', 'Disabled', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#6', 'SQL Server Agent start mode'),
    ('instance', 'server_name', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#22', 'server name'),
    ('instance', 'max_memory', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'dbatools formula', 'Instance#20', 'max server memory'),
    ('instance', 'maxdop', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'dbatools formula', 'Instance#47', 'max degree of parallelism'),
    ('instance', 'startup_procs', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#55', 'scan for startup procs'),
    ('instance', 'errorlog_files', 'number', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#46', 'error log files kept'),
    ('xe', 'stopped', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#31', 'event sessions expected stopped'),
    ('xe', 'running', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#32', 'event sessions expected running'),
    ('xe', 'allowed', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#33', 'event sessions allowed to run'),
    ('xe', 'exists', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instancev5#46', 'event sessions expected to exist'),
    ('traceflag', 'expected', 'numlist', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#49', 'trace flags expected'),
    ('traceflag', 'not_expected', 'numlist', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#50', 'trace flags not expected'),
    ('network', 'tcp_port', 'number', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Server#8', 'TCP port'),
    ('network', 'protocols', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Server#9', 'network protocols enabled'),
    ('network', 'cpu_priority', 'number', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Server#6', 'Windows processor scheduling (Win32PrioritySeparation)'),
    ('agent', 'operators', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'Agent operators expected'),
    ('agent', 'failsafe_operator', 'text', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'Agent fail-safe operator'),
    ('agent', 'job_owner_allow', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'job owners allowed'),
    ('agent', 'job_owner_deny', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'job owners not allowed')
  ) v (kind, key, vtype, choices, takes_exclusions, default_exclusions, default_on, source, rule, label)
  -- a number key's range: what the server itself takes for the setting (MAXDOP 0 to 32767, 6 to 99 error log files, a
  -- TCP port, the six bits of Win32PrioritySeparation)
  LEFT JOIN (VALUES ('database', 'scoped_maxdop', 0::bigint, 32767::bigint), ('instance', 'errorlog_files', 6, 99),
                    ('network', 'tcp_port', 1, 65535), ('network', 'cpu_priority', 0, 63)) r (kind, key, vmin, vmax)
    ON r.kind = v.kind AND r.key = v.key
$$;

-- import_mssql_config_expect: one attempt from the page's Expected values editor. p_payload: {op: set | inherit,
-- level: root | tag | instance, instance_id, tag, kind, key, value, exclusions, ui_user, client}. value: a number (or
-- its digits as text), a text, a list (a JSON array, or one text with commas), as the key's type asks. exclusions: a
-- list of database names, only for the keys that take them; left out = the key's default exclusions. An
-- operator's name holding '@' is refused: no e-mail address is ever stored (a login's name may hold one). Answers {outcome: done | refused, detail,
-- expect_id}; a refusal writes nothing.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_config_expect(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op    text := p_payload->>'op';
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_level text := p_payload->>'level';
  v_inst  int;
  v_tag   text := nullif(btrim(coalesce(p_payload->>'tag', '')), '');
  v_kind  text := lower(btrim(coalesce(p_payload->>'kind', '')));
  v_key   text := btrim(coalesce(p_payload->>'key', ''));
  v_raw   jsonb := p_payload->'value';
  v_excl  jsonb := p_payload->'exclusions';
  v_type  text;
  v_choices text[];
  v_min   bigint;       -- a number key's range (a server option: sys.configurations holds no value under 0 or over an int)
  v_max   bigint;
  v_takes boolean;      -- the key takes a list of databases left out
  v_defex jsonb;        -- ... and this list when the attempt names none
  v_val   jsonb;
  v_items text[];
  v_why   text;
  v_old   bigint;
  v_new   bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_mssql_config_expect: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN
    v_inst := (p_payload->>'instance_id')::int;
  END IF;
  IF v_kind = 'config' THEN
    v_key := lower(v_key);
    v_type := 'number';
    v_min := 0;
    v_max := 2147483647;
  ELSE
    -- plain variables, not a record: a record no row was read into has no fields to ask (a 'config' attempt reads none)
    SELECT k.vtype, k.choices, k.takes_exclusions, k.default_exclusions, k.vmin, k.vmax INTO v_type, v_choices, v_takes, v_defex, v_min, v_max
      FROM pgvigil.mssql_config_expect_keys() k WHERE k.kind = v_kind AND k.key = v_key;
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('set', 'inherit') THEN
    v_why := 'op must be set or inherit';
  ELSIF v_level IS NULL OR v_level NOT IN ('root', 'tag', 'instance') THEN
    v_why := 'level must be root, tag or instance';
  ELSIF v_level = 'instance' AND (v_inst IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = v_inst AND i.engine = 'sqlserver')) THEN
    v_why := 'an instance level names a SQL Server instance that exists';
  ELSIF v_level = 'tag' AND (v_tag IS NULL OR length(v_tag) > 200) THEN
    v_why := 'a tag level names its tag (200 characters at most)';
  ELSIF v_type IS NULL OR v_key = '' OR length(v_key) > 128 THEN
    v_why := 'no expectation can be set for this kind and key';
  ELSIF v_op = 'set' THEN
    IF v_raw IS NULL OR jsonb_typeof(v_raw) = 'null' THEN
      v_why := 'set takes a value';
    ELSIF v_kind = 'agent' AND v_key IN ('operators', 'failsafe_operator') AND v_raw::text LIKE '%@%' THEN
      -- an operator's name, never its address; a login's name may hold '@' (an Entra ID login owning a job)
      v_why := 'an e-mail address is never stored: name the operator, not its address';
    ELSIF v_type = 'number' THEN
      -- inside the key's range only: a value the server could never hold is refused here, not judged later
      IF (v_raw #>> '{}') ~ '^-?[0-9]{1,10}$' AND (v_raw #>> '{}')::bigint BETWEEN coalesce(v_min, 0) AND coalesce(v_max, 2147483647) THEN
        v_val := to_jsonb((v_raw #>> '{}')::bigint);
      ELSE
        v_why := format('the value must be a whole number from %s to %s', coalesce(v_min, 0), coalesce(v_max, 2147483647));
      END IF;
    ELSIF v_type = 'text' THEN
      IF jsonb_typeof(v_raw) = 'string' AND btrim(v_raw #>> '{}') <> '' AND length(v_raw #>> '{}') <= 200 THEN v_val := to_jsonb(btrim(v_raw #>> '{}'));
      ELSE v_why := 'the value must be a name (200 characters at most)'; END IF;
    ELSIF v_type = 'choice' THEN
      IF jsonb_typeof(v_raw) = 'string' AND (v_raw #>> '{}') = ANY (v_choices) THEN v_val := v_raw;
      ELSE v_why := 'the value must be one of: ' || array_to_string(v_choices, ', '); END IF;
    ELSE  -- list | numlist
      IF jsonb_typeof(v_raw) = 'array' THEN
        v_items := ARRAY(SELECT btrim(x) FROM jsonb_array_elements_text(v_raw) x WHERE btrim(x) <> '');
      ELSIF jsonb_typeof(v_raw) = 'string' THEN
        v_items := ARRAY(SELECT btrim(x) FROM unnest(string_to_array(v_raw #>> '{}', ',')) x WHERE btrim(x) <> '');
      END IF;
      IF v_items IS NULL OR cardinality(v_items) = 0 THEN
        v_why := 'the value must be a list with at least one name (inherit takes the expectation away)';
      ELSIF cardinality(v_items) > 500 OR EXISTS (SELECT 1 FROM unnest(v_items) x WHERE length(x) > 200) THEN
        v_why := 'a list holds 500 names at most, each 200 characters at most';
      ELSIF v_type = 'numlist' AND EXISTS (SELECT 1 FROM unnest(v_items) x WHERE x !~ '^[0-9]{1,9}$') THEN
        v_why := 'the value must be a list of whole numbers';
      ELSIF v_type = 'numlist' THEN
        v_val := (SELECT jsonb_agg(x::bigint ORDER BY x::bigint) FROM (SELECT DISTINCT x FROM unnest(v_items) x) s);
      ELSIF v_kind = 'network' AND v_key = 'protocols' AND EXISTS (SELECT 1 FROM unnest(v_items) x WHERE lower(x) NOT IN ('tcp', 'np', 'sm')) THEN
        v_why := 'the value must be a list of the protocols as SQL Server names them: Tcp, Np, Sm';
      ELSIF v_kind = 'network' AND v_key = 'protocols' THEN
        v_val := (SELECT jsonb_agg(DISTINCT CASE lower(x) WHEN 'tcp' THEN 'Tcp' WHEN 'np' THEN 'Np' ELSE 'Sm' END) FROM unnest(v_items) x);
      ELSE
        v_val := to_jsonb(v_items);
      END IF;
    END IF;
    IF v_why IS NULL THEN
      IF coalesce(v_takes, false) THEN
        IF v_excl IS NULL OR jsonb_typeof(v_excl) = 'null' THEN
          v_excl := coalesce(v_defex, '[]'::jsonb);
        ELSIF jsonb_typeof(v_excl) <> 'array' OR jsonb_array_length(v_excl) > 2000
              OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_excl) x WHERE jsonb_typeof(x) <> 'string' OR length(x #>> '{}') NOT BETWEEN 1 AND 128) THEN
          v_why := 'exclusions must be a list of database names';
        END IF;
      ELSIF v_excl IS NOT NULL AND jsonb_typeof(v_excl) = 'array' AND jsonb_array_length(v_excl) > 0 THEN
        v_why := 'this key takes no exclusions';
      ELSE
        v_excl := '[]'::jsonb;
      END IF;
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_level = 'root' THEN v_inst := NULL; v_tag := NULL;
  ELSIF v_level = 'tag' THEN v_inst := NULL;
  ELSE v_tag := NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.mssql_config_expect'), hashtext(v_level || '|' || coalesce(v_inst, 0) || '|' || coalesce(v_tag, '') || '|' || v_kind || '|' || v_key));
  SELECT t.expect_id INTO v_old FROM pgvigil.mssql_config_expect t
   WHERE t.ended_at IS NULL AND t.level = v_level AND coalesce(t.instance_id, 0) = coalesce(v_inst, 0)
     AND coalesce(t.tag, '') = coalesce(v_tag, '') AND t.kind = v_kind AND t.key = v_key;
  IF v_op = 'inherit' AND v_old IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'this level has no expectation of its own: it inherits already');
  END IF;
  UPDATE pgvigil.mssql_config_expect SET ended_by = v_user, ended_at = p_at WHERE expect_id = v_old;
  IF v_op = 'inherit' THEN
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'ended: the level above applies', 'expect_id', v_old);
  END IF;
  INSERT INTO pgvigil.mssql_config_expect (level, instance_id, tag, kind, key, value, exclusions, created_by, created_at, client, replaces)
  VALUES (v_level, v_inst, v_tag, v_kind, v_key, v_val, v_excl, v_user, p_at, nullif(p_payload->>'client', ''), v_old)
  RETURNING expect_id INTO v_new;
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'set', 'expect_id', v_new);
END $$;

-- mssql_config_expect_in_force: one row per kind and key that has an expectation in force for the instance - its
-- own, else a tag's (the first tag by name when two of the instance's tags set one), else the root's. No row = not
-- set: a policy rule is off, a rule that is on by default judges by its default.
CREATE OR REPLACE FUNCTION pgvigil.mssql_config_expect_in_force(p_instance_id integer)
RETURNS TABLE (kind text, key text, value jsonb, exclusions jsonb, set_at text, set_by text, set_when timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT DISTINCT ON (e.kind, e.key) e.kind, e.key, e.value, e.exclusions,
         CASE e.level WHEN 'tag' THEN 'tag:' || e.tag ELSE e.level END, e.created_by, e.created_at
    FROM pgvigil.mssql_config_expect e
   WHERE e.ended_at IS NULL
     AND (e.level = 'root'
          OR (e.level = 'instance' AND e.instance_id = p_instance_id)
          OR (e.level = 'tag' AND e.tag = ANY (coalesce((SELECT m.tags FROM pgvigil.instance_tags_merged m WHERE m.instance_id = p_instance_id), '{}'::text[]))))
   ORDER BY e.kind, e.key, CASE e.level WHEN 'instance' THEN 1 WHEN 'tag' THEN 2 ELSE 3 END, e.tag
$$;

CREATE OR REPLACE VIEW pgvigil.mssql_config_expect_now AS
SELECT i.instance_id, f.kind, f.key, f.value, f.exclusions, f.set_at, f.set_by, f.set_when
  FROM pgvigil.instances i
  CROSS JOIN LATERAL pgvigil.mssql_config_expect_in_force(i.instance_id) f
 WHERE i.is_active AND i.engine = 'sqlserver';

-- mssql_recommended_max_memory_mb: dbatools' Test-DbaMaxMemory (public/Test-DbaMaxMemory.ps1, its Jonathan Kehayias
-- rule) for one instance on the machine: under 4 GB half the memory; else the memory less 1 GB, less 1 GB per 4 GB up
-- to 16 GB, less 1 GB per 8 GB above it. The caller divides by the instances sharing the machine.
CREATE OR REPLACE FUNCTION pgvigil.mssql_recommended_max_memory_mb(p_total_mb bigint)
RETURNS bigint LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_reserve int := 1;
  v_left    bigint := p_total_mb;
BEGIN
  IF p_total_mb IS NULL OR p_total_mb <= 0 THEN
    RETURN NULL;
  ELSIF p_total_mb < 4096 THEN
    RETURN (p_total_mb / 2);
  END IF;
  WHILE v_left > 0 LOOP
    v_reserve := v_reserve + 1;
    IF v_left > 16384 THEN v_left := v_left - 8192; ELSE v_left := v_left - 4096; END IF;
  END LOOP;
  RETURN p_total_mb - v_reserve * 1024;
END $$;

-- payload: {kind:'part', part, read (0|1), note}, {kind:'fact', key, value},
--          {kind:'xe', name, autostart (0|1), running (0|1)},
--          {kind:'database', database_name, state, read_only, in_standby, recovery_model, query_store,
--           secondary_role, scoped_maxdop, scoped_note},
--          {kind:'linked', name, product, provider, data_source, catalog, rpc_out, data_access, connect_timeout,
--           query_timeout, modified_utc, logins_read (0|1), logins [...]}, {kind:'collector_error', source, message}.
-- A part that was read replaces its rows whole; a part not read keeps them and says why.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_confcheck(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_read text[];
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_confcheck: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_confcheck'), p_instance_id);
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_confcheck_part s WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_snapshot_at) THEN
    RETURN;  -- an older read arriving late
  END IF;
  INSERT INTO pgvigil.mssql_confcheck_part AS t (instance_id, part, is_read, note, snapshot_at)
  SELECT DISTINCT ON (r->>'part') p_instance_id, r->>'part', coalesce(r->>'read' = '1', false), r->>'note', p_snapshot_at
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'part' AND r->>'part' IS NOT NULL
  ON CONFLICT (instance_id, part) DO UPDATE SET is_read = EXCLUDED.is_read, note = EXCLUDED.note, snapshot_at = EXCLUDED.snapshot_at;
  v_read := ARRAY(SELECT r->>'part' FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'part' AND r->>'read' = '1');

  -- the facts: each belongs to a part (its 'part' field); a part read replaces its facts
  DELETE FROM pgvigil.mssql_confcheck_fact f
   WHERE f.instance_id = p_instance_id
     AND f.key IN (SELECT r->>'key' FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'fact');
  INSERT INTO pgvigil.mssql_confcheck_fact (instance_id, key, value, snapshot_at)
  SELECT DISTINCT ON (r->>'key') p_instance_id, r->>'key', nullif(r->'value', 'null'::jsonb), p_snapshot_at
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'fact' AND r->>'key' IS NOT NULL;

  IF 'xe' = ANY (v_read) THEN
    DELETE FROM pgvigil.mssql_xe_session_state x WHERE x.instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_xe_session_state (instance_id, session_name, autostart, running, snapshot_at)
    SELECT DISTINCT ON (r->>'name') p_instance_id, r->>'name', r->>'autostart' = '1', coalesce(r->>'running' = '1', false), p_snapshot_at
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'xe' AND r->>'name' IS NOT NULL;
  END IF;
  IF 'databases' = ANY (v_read) THEN
    DELETE FROM pgvigil.mssql_db_confcheck d WHERE d.instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_db_confcheck (instance_id, database_name, state, read_only, in_standby, recovery_model, query_store,
        secondary_role, scoped_maxdop, scoped_note, snapshot_at)
    SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', r->>'state', r->>'read_only' = '1', r->>'in_standby' = '1',
           r->>'recovery_model', r->>'query_store' = '1', nullif(r->>'secondary_role', ''), (r->>'scoped_maxdop')::int, r->>'scoped_note', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'database' AND r->>'database_name' IS NOT NULL;
  END IF;
  IF 'linked' = ANY (v_read) THEN
    -- a list the login may not see whole (linked_list_complete 0) replaces only the servers it lists: one it does not
    -- show is not taken as gone
    DELETE FROM pgvigil.mssql_linked_server l
     WHERE l.instance_id = p_instance_id
       AND (coalesce((SELECT (r->>'value')::int FROM jsonb_array_elements(p_payload) r
                       WHERE r->>'kind' = 'fact' AND r->>'key' = 'linked_list_complete' LIMIT 1), 1) = 1
            OR l.name IN (SELECT r->>'name' FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'linked'));
    INSERT INTO pgvigil.mssql_linked_server (instance_id, name, product, provider, data_source, catalog, rpc_out, data_access,
        connect_timeout, query_timeout, modified_at, logins, logins_read, snapshot_at)
    SELECT DISTINCT ON (r->>'name') p_instance_id, r->>'name', nullif(r->>'product', ''), nullif(r->>'provider', ''), nullif(r->>'data_source', ''),
           nullif(r->>'catalog', ''), r->>'rpc_out' = '1', r->>'data_access' = '1', (r->>'connect_timeout')::int, (r->>'query_timeout')::int,
           (r->>'modified_utc')::timestamptz, coalesce(r->'logins', '[]'::jsonb), coalesce(r->>'logins_read' = '1', false), p_snapshot_at
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'linked' AND r->>'name' IS NOT NULL;
    -- a linked server that is gone takes its last test with it
    DELETE FROM pgvigil.mssql_linked_server_test t
     WHERE t.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_linked_server l WHERE l.instance_id = t.instance_id AND l.name = t.name);
  END IF;
END $$;

-- payload: {kind:'test', name, outcome (ok | failed | unmapped | not tested), error_number, error_message, seconds,
--           note}, {kind:'cursor', source:'mssql_linkedserver_test', last_seq: where the next run starts},
--           {kind:'collector_error', source, message}. A server tested replaces its row; first_failed_at stays
-- while it keeps failing. A 'not tested' row never replaces a test's outcome: it only says why this run left it.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_linkedserver_test(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_linkedserver_test: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_linkedserver_test'), p_instance_id);
  INSERT INTO pgvigil.mssql_linked_server_test AS t (instance_id, name, outcome, error_number, error_message, seconds, note, tested_at, first_failed_at)
  SELECT DISTINCT ON (r->>'name') p_instance_id, r->>'name', r->>'outcome', (r->>'error_number')::int,
         -- never a remote login's name (the collector leaves it out already; the store does not rest on that)
         CASE WHEN (r->>'error_number')::int IN (18452, 18456, 18470, 18486, 18487, 18488)
              THEN 'the login mapped for the collector''s login was refused at the remote server'
              ELSE left(regexp_replace(r->>'error_message', $re$\m(user|login|principal)\s+['"].*['"]$re$, $rp$\1 '<not stored>'$rp$, 'gi'), 1000) END,
         (r->>'seconds')::numeric, r->>'note', p_snapshot_at, CASE WHEN r->>'outcome' = 'failed' THEN p_snapshot_at END
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'test' AND r->>'name' IS NOT NULL AND r->>'outcome' IN ('ok', 'failed', 'unmapped', 'not tested')
  ON CONFLICT (instance_id, name) DO UPDATE SET
      outcome = CASE WHEN EXCLUDED.outcome = 'not tested' AND t.outcome <> 'not tested' THEN t.outcome ELSE EXCLUDED.outcome END,
      error_number = CASE WHEN EXCLUDED.outcome = 'not tested' AND t.outcome <> 'not tested' THEN t.error_number ELSE EXCLUDED.error_number END,
      error_message = CASE WHEN EXCLUDED.outcome = 'not tested' AND t.outcome <> 'not tested' THEN t.error_message ELSE EXCLUDED.error_message END,
      seconds = CASE WHEN EXCLUDED.outcome = 'not tested' AND t.outcome <> 'not tested' THEN t.seconds ELSE EXCLUDED.seconds END,
      note = EXCLUDED.note,
      tested_at = CASE WHEN EXCLUDED.outcome = 'not tested' AND t.outcome <> 'not tested' THEN t.tested_at ELSE EXCLUDED.tested_at END,
      first_failed_at = CASE WHEN EXCLUDED.outcome = 'not tested' AND t.outcome <> 'not tested' THEN t.first_failed_at
                             WHEN EXCLUDED.outcome = 'failed' THEN coalesce(t.first_failed_at, EXCLUDED.first_failed_at) END
   WHERE t.tested_at <= EXCLUDED.tested_at;
  -- where the next run starts (0065's mssql_cursor)
  INSERT INTO pgvigil.mssql_cursor AS c (instance_id, source, last_seq, updated_at)
  SELECT DISTINCT ON (r->>'source') p_instance_id, r->>'source', (r->>'last_seq')::bigint, now()
    FROM jsonb_array_elements(p_payload) WITH ORDINALITY AS t(r, n)
   WHERE r->>'kind' = 'cursor' AND r->>'source' IS NOT NULL
   ORDER BY r->>'source', n DESC
  ON CONFLICT (instance_id, source) DO UPDATE SET last_seq = EXCLUDED.last_seq, updated_at = EXCLUDED.updated_at;
END $$;

-- mssql_cc_list: a JSON list's items as text; anything else gives no row (an expectation of another type never
-- breaks a rule's read of a list).
CREATE OR REPLACE FUNCTION pgvigil.mssql_cc_list(p_value jsonb)
RETURNS SETOF text LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_value) = 'array' THEN p_value ELSE '[]'::jsonb END)
$$;

-- mssql_cc_in: whether a name is on a JSON list, compared without case (SQL Server's names are, under the default
-- collation: a list's 'MSDB' leaves out msdb, 'System_Health' names system_health).
CREATE OR REPLACE FUNCTION pgvigil.mssql_cc_in(p_list jsonb, p_name text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pgvigil.mssql_cc_list(p_list) n WHERE lower(n) = lower(p_name))
$$;

-- mssql_cc_unread: whether a database rule's column was not read for one database the rule judges (scoped MAXDOP:
-- the login could not enter it; recovery model and Query Store: the server gave none; tempdb is never judged by the
-- recovery model, nor Query Store where it is not online or is a secondary).
CREATE OR REPLACE FUNCTION pgvigil.mssql_cc_unread(p_key text, p_database text, p_state text, p_scoped_maxdop int,
                                                   p_recovery_model text, p_query_store boolean, p_secondary_role text, p_in_standby boolean)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_key
           WHEN 'scoped_maxdop' THEN p_scoped_maxdop IS NULL
           WHEN 'recovery_model' THEN p_recovery_model IS NULL AND lower(p_database) <> 'tempdb'
           WHEN 'query_store' THEN p_query_store IS NULL AND p_state = 'ONLINE' AND p_secondary_role IS NULL AND NOT coalesce(p_in_standby, false)
           ELSE false END
$$;

-- mssql_config_checks_of: every rule of one SQL Server instance. A rule over a list (databases, event sessions,
-- trace flags, operators, job owners) gives one row per deviation, or one row of its own when nothing deviates: off,
-- not read, or ok.
CREATE OR REPLACE FUNCTION pgvigil.mssql_config_checks_of(p_instance_id integer)
RETURNS TABLE (rule text, check_name text, object text, value text, expected text, set_at text, source text, status text, detail text, at timestamptz)
LANGUAGE sql STABLE AS $$
WITH x AS (
  SELECT i.instance_id,
         CASE i.platform WHEN 'rdssqlserver' THEN 'Amazon RDS' WHEN 'azuresqlmi' THEN 'Azure SQL Managed Instance'
                         WHEN 'cloudsqlsqlserver' THEN 'Google Cloud SQL' END AS hosted,
         i.platform,
         (SELECT f.value #>> '{}' FROM pgvigil.mssql_confcheck_fact f WHERE f.instance_id = i.instance_id AND f.key = 'host_platform') AS host_platform,
         (SELECT max(p.snapshot_at) FROM pgvigil.mssql_confcheck_part p WHERE p.instance_id = i.instance_id) AS cc_at,
         mi.is_clustered, mi.engine_edition, mi.physical_memory_mb,
         -- the linked servers' test is on where the instance's configuration carries the tag: the runner reads that,
         -- not a tag set over it with 'pgvigil tag'
         EXISTS (SELECT 1 FROM unnest(i.tags) u(t) CROSS JOIN LATERAL pgvigil.tag_split(u.t) s
                  WHERE s.key = 'pgvigil' AND s.value = 'linkedserver-test') AS linked_test_on
    FROM pgvigil.instances i
    LEFT JOIN pgvigil.mssql_instance mi ON mi.instance_id = i.instance_id
   -- Azure SQL Database: one database is the instance and mssql_confcheck does not run there; no grid of rows that
   -- would never be read
   WHERE i.instance_id = p_instance_id AND i.engine = 'sqlserver' AND i.platform IS DISTINCT FROM 'azuresqldb'
), e AS (
  SELECT * FROM pgvigil.mssql_config_expect_in_force(p_instance_id)
), f AS (
  SELECT c.key, c.value FROM pgvigil.mssql_confcheck_fact c WHERE c.instance_id = p_instance_id
), p AS (
  SELECT c.part, c.is_read, c.note FROM pgvigil.mssql_confcheck_part c WHERE c.instance_id = p_instance_id
), cfg AS (
  SELECT c.name, c.value_in_use, c.snapshot_at FROM pgvigil.mssql_config c WHERE c.instance_id = p_instance_id AND c.is_present
), d AS (
  SELECT * FROM pgvigil.mssql_db_confcheck c WHERE c.instance_id = p_instance_id
), xe AS (
  SELECT * FROM pgvigil.mssql_xe_session_state c WHERE c.instance_id = p_instance_id
), tf AS (
  SELECT t.trace_flag FROM pgvigil.mssql_trace_flags t WHERE t.instance_id = p_instance_id AND t.is_global
), jobs AS (
  SELECT j.name, j.owner FROM pgvigil.mssql_jobs j WHERE j.instance_id = p_instance_id
), ops AS (
  SELECT o.name FROM pgvigil.mssql_agent_operator o WHERE o.instance_id = p_instance_id
), k AS (
  SELECT * FROM pgvigil.mssql_config_expect_keys()
),
-- the deviations of the rules over a list
devs AS (
  SELECT 'database'::text AS kind, 'recovery_model'::text AS key, d.database_name AS object, d.recovery_model AS value, 'warning'::text AS status,
         format('recovery model %s; %s is expected', d.recovery_model, ex.value #>> '{}') AS detail
    FROM d JOIN e ex ON ex.kind = 'database' AND ex.key = 'recovery_model'
   WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND lower(d.database_name) <> 'tempdb'
     AND d.recovery_model IS NOT NULL AND d.recovery_model <> (ex.value #>> '{}')
  UNION ALL
  SELECT 'database', 'scoped_maxdop', d.database_name, d.scoped_maxdop::text, 'warning',
         format('database-scoped MAXDOP %s; %s is expected', d.scoped_maxdop, ex.value #>> '{}')
    FROM d JOIN e ex ON ex.kind = 'database' AND ex.key = 'scoped_maxdop'
   WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND d.scoped_maxdop IS NOT NULL AND d.scoped_maxdop <> (ex.value #>> '{}')::bigint
  UNION ALL
  SELECT 'database', 'state', d.database_name,
         concat_ws(', ', CASE WHEN d.state = 'RESTORING' THEN 'RESTORING' END, CASE WHEN d.read_only THEN 'read-only' END, CASE WHEN d.in_standby THEN 'standby' END),
         CASE WHEN rn.note IS NOT NULL THEN 'not read' ELSE 'warning' END,
         CASE WHEN rn.note IS NOT NULL
              THEN format('the database is %s; whether it is a secondary was not read (%s)',
                          concat_ws(', ', CASE WHEN d.state = 'RESTORING' THEN 'RESTORING' END, CASE WHEN d.read_only THEN 'read-only' END, CASE WHEN d.in_standby THEN 'in standby' END), rn.note)
              ELSE format('the database is %s and is not a mirror, an availability group secondary or a log shipping secondary',
                          concat_ws(', ', CASE WHEN d.state = 'RESTORING' THEN 'RESTORING' END, CASE WHEN d.read_only THEN 'read-only' END, CASE WHEN d.in_standby THEN 'in standby' END)) END
    FROM d JOIN e ex ON ex.kind = 'database' AND ex.key = 'state'
    -- the collector's note when the mirrors, the availability group or the log shipping secondaries were not told apart
    CROSS JOIN (SELECT (SELECT f.value #>> '{}' FROM f WHERE f.key = 'secondary_roles_unread') AS note) rn
   WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND d.secondary_role IS NULL
     AND (d.state = 'RESTORING' OR coalesce(d.read_only, false) OR coalesce(d.in_standby, false))
  UNION ALL
  SELECT 'database', 'expected', n.name, 'missing', 'critical', 'the database is expected on this instance and the server lists none of that name'
    FROM e ex CROSS JOIN LATERAL pgvigil.mssql_cc_list(ex.value) n(name)
   WHERE ex.kind = 'database' AND ex.key = 'expected' AND EXISTS (SELECT 1 FROM p WHERE p.part = 'databases' AND p.is_read)
     AND NOT EXISTS (SELECT 1 FROM d WHERE lower(d.database_name) = lower(n.name))
  UNION ALL
  SELECT 'database', 'query_store', d.database_name, CASE WHEN d.query_store THEN 'on' ELSE 'off' END, 'warning',
         format('Query Store is %s; %s is expected', CASE WHEN d.query_store THEN 'on' ELSE 'off' END, ex.value #>> '{}')
    FROM d JOIN e ex ON ex.kind = 'database' AND ex.key = 'query_store'
   WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND d.state = 'ONLINE' AND d.secondary_role IS NULL AND NOT coalesce(d.in_standby, false)
     AND d.query_store IS NOT NULL AND d.query_store <> ((ex.value #>> '{}') = 'on')
  UNION ALL
  SELECT 'xe', 'stopped', xe.session_name, 'running', 'warning', 'the event session runs; it is expected stopped'
    FROM xe JOIN e ex ON ex.kind = 'xe' AND ex.key = 'stopped' AND pgvigil.mssql_cc_in(ex.value, xe.session_name) WHERE xe.running
  UNION ALL
  SELECT 'xe', 'running', n.name, CASE WHEN xe.session_name IS NULL THEN 'missing' ELSE 'stopped' END, 'warning',
         CASE WHEN xe.session_name IS NULL THEN 'the event session is expected running and the server has none of that name'
              ELSE 'the event session is stopped; it is expected running' END
    FROM e ex CROSS JOIN LATERAL pgvigil.mssql_cc_list(ex.value) n(name)
    LEFT JOIN xe ON lower(xe.session_name) = lower(n.name)
   WHERE ex.kind = 'xe' AND ex.key = 'running' AND EXISTS (SELECT 1 FROM p WHERE p.part = 'xe' AND p.is_read) AND NOT coalesce(xe.running, false)
  UNION ALL
  SELECT 'xe', 'allowed', xe.session_name, 'running', 'warning', 'the event session runs and is not on the list of sessions allowed to run'
    FROM xe JOIN e ex ON ex.kind = 'xe' AND ex.key = 'allowed' WHERE xe.running AND NOT pgvigil.mssql_cc_in(ex.value, xe.session_name)
  UNION ALL
  SELECT 'xe', 'exists', n.name, 'missing', 'warning', 'the event session is expected to exist and the server has none of that name'
    FROM e ex CROSS JOIN LATERAL pgvigil.mssql_cc_list(ex.value) n(name)
   WHERE ex.kind = 'xe' AND ex.key = 'exists' AND EXISTS (SELECT 1 FROM p WHERE p.part = 'xe' AND p.is_read)
     AND NOT EXISTS (SELECT 1 FROM xe WHERE lower(xe.session_name) = lower(n.name))
  UNION ALL
  SELECT 'traceflag', 'expected', n.flag, 'off', 'warning', format('trace flag %s is expected on for the whole server and is not', n.flag)
    FROM e ex CROSS JOIN LATERAL pgvigil.mssql_cc_list(ex.value) n(flag)
   WHERE ex.kind = 'traceflag' AND ex.key = 'expected' AND NOT EXISTS (SELECT 1 FROM tf WHERE tf.trace_flag::text = n.flag)
     AND EXISTS (SELECT 1 FROM pgvigil.collection_dates c WHERE c.instance_id = p_instance_id AND c.collection = 'mssql_traceflags' AND c.status = 'ok')
  UNION ALL
  SELECT 'traceflag', 'not_expected', tf.trace_flag::text, 'on', 'warning', format('trace flag %s is on for the whole server and is expected off', tf.trace_flag)
    FROM tf JOIN e ex ON ex.kind = 'traceflag' AND ex.key = 'not_expected' AND ex.value @> to_jsonb(tf.trace_flag)
  UNION ALL
  SELECT 'agent', 'operators', n.name, 'missing', 'warning', format('the operator %s is expected and the Agent has none of that name', n.name)
    FROM e ex CROSS JOIN LATERAL pgvigil.mssql_cc_list(ex.value) n(name)
   WHERE ex.kind = 'agent' AND ex.key = 'operators' AND NOT EXISTS (SELECT 1 FROM ops WHERE lower(ops.name) = lower(n.name))
     AND coalesce((SELECT a.is_read FROM pgvigil.mssql_check_area a WHERE a.instance_id = p_instance_id AND a.area = 'alerts'), false)
  UNION ALL
  SELECT 'agent', 'job_owner_deny', j.name, j.owner, 'warning', format('the job is owned by %s, a login on the list of owners not allowed', j.owner)
    FROM jobs j JOIN e ex ON ex.kind = 'agent' AND ex.key = 'job_owner_deny'
   WHERE EXISTS (SELECT 1 FROM pgvigil.mssql_cc_list(ex.value) n(name) WHERE lower(n.name) = lower(j.owner))
  UNION ALL
  SELECT 'agent', 'job_owner_allow', j.name, coalesce(j.owner, 'no owner read'), 'warning',
         format('the job is owned by %s, a login not on the list of owners allowed', coalesce(j.owner, 'a login that was not read'))
    FROM jobs j JOIN e ex ON ex.kind = 'agent' AND ex.key = 'job_owner_allow'
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_cc_list(ex.value) n(name) WHERE lower(n.name) = lower(j.owner))
),
-- whether each list rule's source was read, and why not
src AS (
  SELECT k.kind, k.key,
         CASE k.kind
           WHEN 'database' THEN coalesce((SELECT p.is_read FROM p WHERE p.part = 'databases'), false)
           WHEN 'xe' THEN coalesce((SELECT p.is_read FROM p WHERE p.part = 'xe'), false)
           WHEN 'traceflag' THEN EXISTS (SELECT 1 FROM pgvigil.collection_dates c WHERE c.instance_id = p_instance_id AND c.collection = 'mssql_traceflags' AND c.status = 'ok')
           WHEN 'agent' THEN CASE WHEN k.key = 'operators'
                                  THEN coalesce((SELECT a.is_read FROM pgvigil.mssql_check_area a WHERE a.instance_id = p_instance_id AND a.area = 'alerts'), false)
                                  ELSE EXISTS (SELECT 1 FROM pgvigil.collection_dates c WHERE c.instance_id = p_instance_id AND c.collection = 'mssql_jobs' AND c.status = 'ok') END
         END AS is_read,
         CASE k.kind
           WHEN 'database' THEN coalesce((SELECT p.note FROM p WHERE p.part = 'databases'), 'the databases were not read yet (mssql_confcheck)')
           WHEN 'xe' THEN coalesce((SELECT p.note FROM p WHERE p.part = 'xe'), 'the event sessions were not read yet (mssql_confcheck)')
           WHEN 'traceflag' THEN 'the trace flags were not read yet (mssql_traceflags)'
           WHEN 'agent' THEN CASE WHEN k.key = 'operators'
                                  THEN coalesce((SELECT a.note FROM pgvigil.mssql_check_area a WHERE a.instance_id = p_instance_id AND a.area = 'alerts'), 'the Agent''s operators were not read yet (mssql_checks)')
                                  ELSE 'the jobs were not read yet (mssql_jobs)' END
         END AS why,
         -- the time of the read the rule rests on: the trace flags and the job owners from their own collections, the
         -- operators from mssql_checks' alerts area, the rest from mssql_confcheck
         CASE k.kind
           WHEN 'traceflag' THEN (SELECT c.snapshot_at FROM pgvigil.collection_dates c WHERE c.instance_id = p_instance_id AND c.collection = 'mssql_traceflags')
           WHEN 'agent' THEN CASE WHEN k.key = 'operators'
                                  THEN (SELECT a.snapshot_at FROM pgvigil.mssql_check_area a WHERE a.instance_id = p_instance_id AND a.area = 'alerts')
                                  ELSE (SELECT c.snapshot_at FROM pgvigil.collection_dates c WHERE c.instance_id = p_instance_id AND c.collection = 'mssql_jobs') END
           ELSE (SELECT max(c.snapshot_at) FROM pgvigil.mssql_confcheck_part c WHERE c.instance_id = p_instance_id)
         END AS at
    FROM k
   WHERE k.vtype IN ('list', 'numlist') AND k.kind <> 'network' OR (k.kind = 'database')
)
-- 1. the rules over a list: the deviations
SELECT k.rule, k.label, v.object, v.value,
       CASE WHEN jsonb_typeof(ex.value) = 'array' THEN (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.value) n) ELSE ex.value #>> '{}' END,
       ex.set_at, k.source, v.status, v.detail || format(' (set at %s)', ex.set_at), s.at
  FROM devs v
  JOIN k ON k.kind = v.kind AND k.key = v.key
  JOIN e ex ON ex.kind = v.kind AND ex.key = v.key
  JOIN src s ON s.kind = v.kind AND s.key = v.key
  CROSS JOIN x
UNION ALL
-- 2. the rules over a list: the rule's own row when nothing deviates
SELECT k.rule, k.label, '', NULL,
       CASE WHEN jsonb_typeof(ex.value) = 'array' THEN (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.value) n) ELSE ex.value #>> '{}' END,
       ex.set_at, k.source,
       -- a database the rule did not read (outside the databases left out) is never 'met': the rule is not read
       CASE WHEN ex.key IS NULL THEN 'off' WHEN NOT coalesce(s.is_read, false) THEN 'not read'
            WHEN k.kind = 'database' AND EXISTS (SELECT 1 FROM d WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND pgvigil.mssql_cc_unread(k.key, d.database_name, d.state, d.scoped_maxdop, d.recovery_model, d.query_store, d.secondary_role, d.in_standby))
              THEN 'not read'
            ELSE 'ok' END,
       CASE WHEN ex.key IS NULL THEN 'set an expectation'
            WHEN NOT coalesce(s.is_read, false) THEN s.why
            WHEN k.kind = 'database' AND k.key = 'scoped_maxdop' AND EXISTS (SELECT 1 FROM d WHERE d.scoped_maxdop IS NULL AND NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name))
              THEN format('met where read; not read in %s database(s): %s',
                          (SELECT count(*) FROM d WHERE d.scoped_maxdop IS NULL AND NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name)),
                          (SELECT string_agg(DISTINCT d.scoped_note, '; ') FROM d WHERE d.scoped_maxdop IS NULL AND NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name)))
            WHEN k.kind = 'database' AND EXISTS (SELECT 1 FROM d WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND pgvigil.mssql_cc_unread(k.key, d.database_name, d.state, d.scoped_maxdop, d.recovery_model, d.query_store, d.secondary_role, d.in_standby))
              THEN format('met where read; not read in %s database(s): %s',
                          (SELECT count(*) FROM d WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND pgvigil.mssql_cc_unread(k.key, d.database_name, d.state, d.scoped_maxdop, d.recovery_model, d.query_store, d.secondary_role, d.in_standby)),
                          (SELECT string_agg(d.database_name, ', ' ORDER BY d.database_name) FROM d WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND pgvigil.mssql_cc_unread(k.key, d.database_name, d.state, d.scoped_maxdop, d.recovery_model, d.query_store, d.secondary_role, d.in_standby)))
            ELSE 'met' || CASE WHEN jsonb_array_length(ex.exclusions) > 0
                               THEN '; left out: ' || (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.exclusions) n) ELSE '' END END,
       s.at
  FROM x
  CROSS JOIN k
  JOIN src s ON s.kind = k.kind AND s.key = k.key
  LEFT JOIN e ex ON ex.kind = k.kind AND ex.key = k.key
 WHERE NOT EXISTS (SELECT 1 FROM devs v WHERE v.kind = k.kind AND v.key = k.key)
UNION ALL
-- 3. a server option's expected value (dbachecks' Agent#1 Database Mail XPs and Instance#58 remote access are shown
--    whether set or not; any other option once a scope sets it)
SELECT CASE o.name WHEN 'database mail xps' THEN 'Agent#1' WHEN 'remote access' THEN 'Instance#58' ELSE 'option' END,
       'server option', coalesce(c.name, CASE o.name WHEN 'database mail xps' THEN 'Database Mail XPs' ELSE o.name END), c.value_in_use::text, ex.value #>> '{}', ex.set_at, 'dbachecks policy',
       CASE WHEN ex.key IS NULL THEN 'off' WHEN c.name IS NULL THEN 'not read' WHEN c.value_in_use = (ex.value #>> '{}')::bigint THEN 'ok' ELSE 'warning' END,
       CASE WHEN ex.key IS NULL THEN 'set an expectation'
            WHEN c.name IS NULL THEN 'the server lists no option of that name (mssql_config)'
            WHEN c.value_in_use = (ex.value #>> '{}')::bigint THEN format('in use %s, as expected (set at %s)', c.value_in_use, ex.set_at)
            ELSE format('in use %s; %s is expected (set at %s)', c.value_in_use, ex.value #>> '{}', ex.set_at) END,
       coalesce(c.snapshot_at, x.cc_at)
  FROM x
  CROSS JOIN (SELECT e.key AS name FROM e WHERE e.kind = 'config' UNION SELECT 'database mail xps' UNION SELECT 'remote access') o
  LEFT JOIN e ex ON ex.kind = 'config' AND ex.key = o.name
  LEFT JOIN cfg c ON lower(c.name) = o.name
UNION ALL
-- 4. the engine's and the Agent's start mode: Automatic on a standalone instance, Manual on a failover cluster
--    instance (the cluster starts it), unless a scope names another
SELECT 'Instance#6', sm.label, '', s.startup_type, want.v, coalesce(ex.set_at, 'default'), 'Microsoft',
       CASE WHEN x.hosted IS NOT NULL THEN 'not applicable'
            WHEN sm.key = 'agent_start_mode' AND x.engine_edition = 4 THEN 'not applicable'
            WHEN ex.value #>> '{}' = 'off' THEN 'off'
            WHEN s.service_name IS NULL THEN 'not read'
            WHEN s.startup_type = want.v THEN 'ok' ELSE 'warning' END,
       CASE WHEN x.hosted IS NOT NULL THEN x.hosted || ' runs the host'
            WHEN sm.key = 'agent_start_mode' AND x.engine_edition = 4 THEN 'SQL Server Express has no SQL Server Agent'
            WHEN ex.value #>> '{}' = 'off' THEN format('switched off (set at %s)', ex.set_at)
            WHEN s.service_name IS NULL AND x.host_platform = 'Linux' AND sm.key = 'engine_start_mode' THEN 'sys.dm_server_services lists no engine row on Linux'
            WHEN s.service_name IS NULL THEN 'the services were not read (mssql_services)'
            WHEN s.startup_type = want.v THEN format('%s starts %s', s.service_name, s.startup_type)
            ELSE format('%s starts %s; %s is expected%s', s.service_name, coalesce(s.startup_type, 'in a mode that was not read'), want.v,
                        CASE WHEN ex.key IS NOT NULL THEN format(' (set at %s)', ex.set_at)
                             WHEN coalesce(s.is_clustered, x.is_clustered, false) THEN ' on a failover cluster instance (the cluster starts it)'
                             ELSE ' on a standalone instance (it must come back after a restart of the machine)' END) END,
       coalesce(s.snapshot_at, x.cc_at)
  FROM x
  CROSS JOIN (VALUES ('engine_start_mode', 'engine start mode', 'SQL Server (%'), ('agent_start_mode', 'SQL Server Agent start mode', 'SQL Server Agent (%')) sm(key, label, pat)
  LEFT JOIN e ex ON ex.kind = 'service' AND ex.key = sm.key
  LEFT JOIN LATERAL (SELECT sv.service_name, sv.startup_type, sv.is_clustered, sv.snapshot_at FROM pgvigil.mssql_service sv
                      WHERE sv.instance_id = x.instance_id AND sv.is_present AND sv.service_name LIKE sm.pat
                      ORDER BY sv.service_name LIMIT 1) s ON true
  CROSS JOIN LATERAL (SELECT CASE WHEN ex.key IS NOT NULL AND ex.value #>> '{}' <> 'off' THEN ex.value #>> '{}'
                                  WHEN coalesce(s.is_clustered, x.is_clustered, false) THEN 'Manual' ELSE 'Automatic' END AS v) want
UNION ALL
-- 5. @@SERVERNAME against the server's own name (a rename finishes with sp_dropserver, sp_addserver and a restart)
SELECT 'Instance#22', 'server name', '', sn.at_name, sn.prop_name, coalesce(ex.set_at, 'default'), 'Microsoft',
       CASE WHEN x.hosted IS NOT NULL THEN 'not applicable'
            WHEN ex.value #>> '{}' = 'off' THEN 'off'
            WHEN NOT coalesce(pt.is_read, false) THEN 'not read'
            WHEN sn.at_name IS NULL OR lower(sn.at_name) <> lower(sn.prop_name) THEN 'warning' ELSE 'ok' END,
       CASE WHEN x.hosted IS NOT NULL THEN x.hosted || ' runs the host'
            WHEN ex.value #>> '{}' = 'off' THEN format('switched off (set at %s)', ex.set_at)
            WHEN NOT coalesce(pt.is_read, false) THEN coalesce(pt.note, 'the names were not read yet (mssql_confcheck)')
            WHEN sn.at_name IS NULL THEN format('a rename not finished: @@SERVERNAME is NULL (no local server in sys.servers) and the server''s name is %s', sn.prop_name)
            WHEN lower(sn.at_name) <> lower(sn.prop_name) THEN format('a rename not finished: @@SERVERNAME is %s and the server''s name is %s (sp_dropserver, sp_addserver ''local'', then a restart)', sn.at_name, sn.prop_name)
            ELSE '@@SERVERNAME is the server''s name' END,
       x.cc_at
  FROM x
  LEFT JOIN e ex ON ex.kind = 'instance' AND ex.key = 'server_name'
  LEFT JOIN p pt ON pt.part = 'names'
  CROSS JOIN LATERAL (SELECT (SELECT f.value #>> '{}' FROM f WHERE f.key = 'server_name') AS at_name,
                             (SELECT f.value #>> '{}' FROM f WHERE f.key = 'property_server_name') AS prop_name) sn
UNION ALL
-- 6. max server memory against dbatools' recommendation for the machine, shared by the monitored instances of it; on
--    Linux only 'under the machine's memory' is judged (the formula's reserve is Windows')
SELECT 'Instance#20', 'max server memory', '', mm.max_mb::text, CASE WHEN x.host_platform = 'Linux' THEN 'under ' || x.physical_memory_mb ELSE mm.rec_mb::text END,
       coalesce(ex.set_at, 'default'), 'dbatools formula',
       CASE WHEN x.platform = 'azuresqlmi' THEN 'not applicable'
            WHEN ex.value #>> '{}' = 'off' THEN 'off'
            WHEN mm.max_mb IS NULL OR x.physical_memory_mb IS NULL OR x.host_platform IS NULL THEN 'not read'
            WHEN x.host_platform = 'Linux' AND mm.max_mb >= x.physical_memory_mb THEN 'info'
            WHEN x.host_platform <> 'Linux' AND mm.max_mb > mm.rec_mb THEN 'info' ELSE 'ok' END,
       CASE WHEN x.platform = 'azuresqlmi' THEN 'Azure SQL Managed Instance runs the host'
            WHEN ex.value #>> '{}' = 'off' THEN format('switched off (set at %s)', ex.set_at)
            WHEN mm.max_mb IS NULL THEN 'max server memory was not read (mssql_config)'
            WHEN x.physical_memory_mb IS NULL THEN 'the machine''s memory was not read (the login lacks VIEW SERVER STATE, or mssql_instance has not run)'
            WHEN x.host_platform IS NULL THEN 'the host''s platform was not read yet (mssql_confcheck)'
            WHEN x.host_platform = 'Linux'
              THEN format('max server memory %s MB; the machine has %s MB: %s. Linux is judged only on being under the machine''s memory',
                          mm.max_mb, x.physical_memory_mb, CASE WHEN mm.max_mb >= x.physical_memory_mb THEN 'the server may take all of it' ELSE 'under it' END)
            ELSE format('max server memory %s MB; dbatools'' Test-DbaMaxMemory recommends %s MB of the machine''s %s MB for each of the %s monitored instance(s) on it. Analysis, Reporting and Integration Services are not counted: pgvigil has no Windows host door yet',
                        mm.max_mb, mm.rec_mb, x.physical_memory_mb, mm.n) END,
       x.cc_at
  FROM x
  LEFT JOIN e ex ON ex.kind = 'instance' AND ex.key = 'max_memory'
  CROSS JOIN LATERAL (SELECT (SELECT c.value_in_use FROM cfg c WHERE lower(c.name) = 'max server memory (mb)') AS max_mb, n.n,
                             round(pgvigil.mssql_recommended_max_memory_mb(x.physical_memory_mb)::numeric / n.n)::bigint AS rec_mb
                        FROM (SELECT greatest(1, (SELECT count(*) FROM pgvigil.mssql_confcheck_fact o
                                                    JOIN pgvigil.instances oi ON oi.instance_id = o.instance_id AND oi.is_active AND oi.engine = 'sqlserver'
                                                   WHERE o.key = 'netbios' AND o.value IS NOT NULL
                                                     AND lower(o.value #>> '{}') = lower((SELECT f.value #>> '{}' FROM f WHERE f.key = 'netbios')))) AS n) n) mm
UNION ALL
-- 7. MAXDOP against dbatools' advised value: 1 up to it is in order, only above it (or 0 on a machine with more CPUs
--    than it) is a deviation
SELECT 'Instance#47', 'max degree of parallelism', '', md.maxdop::text, 'up to ' || md.advised, coalesce(ex.set_at, 'default'), 'dbatools formula',
       CASE WHEN ex.value #>> '{}' = 'off' THEN 'off'
            WHEN md.maxdop IS NULL OR md.advised IS NULL THEN 'not read'
            WHEN md.maxdop = 0 AND coalesce(md.cpus, 0) > md.advised THEN 'info'
            WHEN md.maxdop > md.advised THEN 'info' ELSE 'ok' END,
       CASE WHEN ex.value #>> '{}' = 'off' THEN format('switched off (set at %s)', ex.set_at)
            WHEN md.maxdop IS NULL THEN 'max degree of parallelism was not read (mssql_config)'
            WHEN md.advised IS NULL THEN coalesce((SELECT p.note FROM p WHERE p.part = 'machine'), 'the machine''s CPUs were not read yet (mssql_confcheck)')
            WHEN md.maxdop = 0 AND coalesce(md.cpus, 0) > md.advised THEN format('MAXDOP 0 lets one query use all %s CPUs; dbatools'' Test-DbaMaxDop advises %s', md.cpus, md.advised)
            WHEN md.maxdop > md.advised THEN format('MAXDOP %s is above the %s dbatools'' Test-DbaMaxDop advises for this machine', md.maxdop, md.advised)
            ELSE format('MAXDOP %s; dbatools'' Test-DbaMaxDop advises up to %s', md.maxdop, md.advised) END,
       x.cc_at
  FROM x
  LEFT JOIN e ex ON ex.kind = 'instance' AND ex.key = 'maxdop'
  CROSS JOIN LATERAL (SELECT (SELECT c.value_in_use FROM cfg c WHERE lower(c.name) = 'max degree of parallelism') AS maxdop,
                             (SELECT (f.value #>> '{}')::bigint FROM f WHERE f.key = 'advised_maxdop') AS advised,
                             (SELECT (f.value #>> '{}')::bigint FROM f WHERE f.key = 'cpu_count') AS cpus) md
UNION ALL
-- 8. 'scan for startup procs' on with no startup procedure (replication's own sp_MSrepl_startup is not one)
SELECT 'Instance#55', 'scan for startup procs', '', sp.scan::text, NULL, coalesce(ex.set_at, 'default'), 'Microsoft',
       CASE WHEN x.hosted IS NOT NULL THEN 'not applicable'
            WHEN ex.value #>> '{}' = 'off' THEN 'off'
            WHEN sp.scan IS NULL THEN 'not read'
            WHEN sp.scan = 0 THEN 'ok'
            WHEN NOT coalesce(pt.is_read, false) THEN 'not read'
            WHEN sp.procs IS NULL THEN 'warning' ELSE 'ok' END,
       CASE WHEN x.hosted IS NOT NULL THEN x.hosted || ' runs the host'
            WHEN ex.value #>> '{}' = 'off' THEN format('switched off (set at %s)', ex.set_at)
            WHEN sp.scan IS NULL THEN 'scan for startup procs was not read (mssql_config)'
            WHEN sp.scan = 0 THEN 'the server does not scan for startup procedures'
            WHEN NOT coalesce(pt.is_read, false) THEN coalesce(pt.note, 'the startup procedures were not read yet (mssql_confcheck)')
            WHEN sp.procs IS NULL THEN 'scan for startup procs is on and master holds no startup procedure: the option does nothing but scan at every start'
            ELSE 'the server runs at its start: ' || sp.procs END,
       x.cc_at
  FROM x
  LEFT JOIN e ex ON ex.kind = 'instance' AND ex.key = 'startup_procs'
  LEFT JOIN p pt ON pt.part = 'startup'
  CROSS JOIN LATERAL (SELECT (SELECT c.value_in_use FROM cfg c WHERE lower(c.name) = 'scan for startup procs') AS scan,
                             (SELECT string_agg(n, ', ' ORDER BY n) FROM f CROSS JOIN LATERAL pgvigil.mssql_cc_list(f.value) n
                               WHERE f.key = 'startup_procs' AND lower(n) <> 'sp_msrepl_startup') AS procs) sp
UNION ALL
-- 9. the error log files kept, at least the number a scope names
SELECT 'Instance#46', 'error log files kept', '', el.kept::text, 'at least ' || (ex.value #>> '{}'), ex.set_at, 'dbachecks policy',
       CASE WHEN x.hosted IS NOT NULL THEN 'not applicable'
            WHEN ex.key IS NULL THEN 'off'
            WHEN NOT coalesce(pt.is_read, false) OR el.kept IS NULL THEN 'not read'
            WHEN el.kept < (ex.value #>> '{}')::bigint THEN 'info' ELSE 'ok' END,
       CASE WHEN x.hosted IS NOT NULL THEN x.hosted || ' runs the host'
            WHEN ex.key IS NULL THEN 'set an expectation'
            WHEN NOT coalesce(pt.is_read, false) OR el.kept IS NULL THEN coalesce(pt.note, 'the error log files kept were not read yet (mssql_confcheck)')
            WHEN el.kept < (ex.value #>> '{}')::bigint THEN format('the server keeps %s error log files; at least %s are expected (set at %s)', el.kept, ex.value #>> '{}', ex.set_at)
            ELSE format('the server keeps %s error log files (set at %s)', el.kept, ex.set_at) END,
       x.cc_at
  FROM x
  LEFT JOIN e ex ON ex.kind = 'instance' AND ex.key = 'errorlog_files'
  LEFT JOIN p pt ON pt.part = 'errorlog'
  CROSS JOIN LATERAL (SELECT (SELECT (f.value #>> '{}')::bigint FROM f WHERE f.key = 'num_errorlogs') AS kept) el
UNION ALL
-- 10. the Agent's fail-safe operator
SELECT 'Agent', 'Agent fail-safe operator', '', al.failsafe_operator, ex.value #>> '{}', ex.set_at, 'dbachecks policy',
       CASE WHEN ex.key IS NULL THEN 'off'
            WHEN al.instance_id IS NULL OR NOT al.failsafe_read THEN 'not read'
            WHEN lower(coalesce(al.failsafe_operator, '')) = lower(ex.value #>> '{}') THEN 'ok' ELSE 'warning' END,
       CASE WHEN ex.key IS NULL THEN 'set an expectation'
            WHEN al.instance_id IS NULL THEN 'the Agent''s alert settings were not read yet (mssql_checks)'
            WHEN NOT al.failsafe_read THEN 'the fail-safe operator was not read: the login may not run master.dbo.sp_MSgetalertinfo'
            WHEN lower(coalesce(al.failsafe_operator, '')) = lower(ex.value #>> '{}') THEN format('the fail-safe operator is %s (set at %s)', al.failsafe_operator, ex.set_at)
            ELSE format('the fail-safe operator is %s; %s is expected (set at %s)', coalesce(al.failsafe_operator, 'not set'), ex.value #>> '{}', ex.set_at) END,
       coalesce(al.snapshot_at, x.cc_at)
  FROM x
  LEFT JOIN e ex ON ex.kind = 'agent' AND ex.key = 'failsafe_operator'
  LEFT JOIN pgvigil.mssql_agent_alerting al ON al.instance_id = x.instance_id
UNION ALL
-- 11. what the properties collection reads of the network and the host: the TCP port, the enabled protocols, the
--     Windows processor scheduling. Until it stores them the rule says so.
SELECT nk.rule, nk.label, '', pr.value,
       CASE WHEN jsonb_typeof(ex.value) = 'array' THEN (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.value) n) ELSE ex.value #>> '{}' END,
       ex.set_at, 'dbachecks policy',
       CASE WHEN x.hosted IS NOT NULL AND (nk.key <> 'tcp_port' OR x.platform = 'azuresqlmi') THEN 'not applicable'
            WHEN x.host_platform = 'Linux' AND nk.key = 'cpu_priority' THEN 'not applicable'
            WHEN ex.key IS NULL THEN 'off'
            WHEN x.host_platform = 'Linux' AND nk.key = 'protocols' THEN CASE WHEN pgvigil.mssql_cc_in(ex.value, 'Tcp') THEN 'ok' ELSE 'info' END
            WHEN pr.name IS NULL OR pr.value IS NULL THEN 'not read'
            WHEN nk.key = 'protocols' AND NOT EXISTS (SELECT 1 FROM unnest(string_to_array(pr.value, ',')) u(n)
                                                       WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_cc_list(ex.value) w(n) WHERE lower(btrim(w.n)) = lower(btrim(u.n)))) THEN 'ok'
            WHEN nk.key <> 'protocols' AND btrim(pr.value) = (ex.value #>> '{}') THEN 'ok'
            ELSE 'info' END,
       CASE WHEN x.hosted IS NOT NULL AND (nk.key <> 'tcp_port' OR x.platform = 'azuresqlmi') THEN x.hosted || ' runs the host'
            WHEN x.host_platform = 'Linux' AND nk.key = 'cpu_priority' THEN 'SQL Server on Linux has no Windows processor scheduling'
            WHEN ex.key IS NULL THEN 'set an expectation'
            WHEN x.host_platform = 'Linux' AND nk.key = 'protocols' AND pgvigil.mssql_cc_in(ex.value, 'Tcp') THEN 'met: Linux serves TCP only'
            WHEN x.host_platform = 'Linux' AND nk.key = 'protocols' THEN format('Linux serves TCP only; %s is expected (set at %s)', (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.value) n), ex.set_at)
            WHEN pr.name IS NULL OR pr.value IS NULL THEN coalesce(pr.note, 'waits on the properties collection: it does not read this value yet')
            ELSE format('%s; %s is expected (set at %s)', pr.value,
                        CASE WHEN jsonb_typeof(ex.value) = 'array' THEN (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.value) n) ELSE ex.value #>> '{}' END, ex.set_at) END,
       coalesce(pr.snapshot_at, x.cc_at)
  FROM x
  CROSS JOIN (VALUES ('tcp_port', 'Server#8', 'TCP port', 'tcp_port'), ('protocols', 'Server#9', 'network protocols enabled', 'protocols_enabled'),
                     ('cpu_priority', 'Server#6', 'Windows processor scheduling (Win32PrioritySeparation)', 'win32_priority_separation')) nk(key, rule, label, prop)
  LEFT JOIN e ex ON ex.kind = 'network' AND ex.key = nk.key
  LEFT JOIN pgvigil.mssql_property pr ON pr.instance_id = x.instance_id AND pr.name = nk.prop
UNION ALL
-- 12. the linked servers' connection test (Instance#19), on only where the instance carries the tag
SELECT 'Instance#19', 'linked server connection test', l.name, t.outcome, 'ok', NULL, 'dbachecks policy',
       CASE WHEN NOT x.linked_test_on THEN 'off'
            WHEN t.name IS NULL OR t.outcome IN ('unmapped', 'not tested') THEN 'not read'
            WHEN t.outcome = 'ok' THEN 'ok' ELSE 'warning' END,
       CASE WHEN NOT x.linked_test_on THEN 'not tested: set the tag pgvigil:linkedserver-test on the instance to have its linked servers tested'
            WHEN t.name IS NULL THEN 'not tested yet (mssql_linkedserver_test)'
            WHEN t.outcome = 'unmapped' AND t.error_number = 7416 THEN format('not tested: the collector''s login has no mapping there (error %s)', t.error_number)
            WHEN t.outcome = 'unmapped' THEN format('not tested: the login mapped for the collector''s login was refused at the remote server (error %s)', t.error_number)
            WHEN t.outcome = 'not tested' THEN 'not tested: ' || coalesce(t.note, 'left for a later run')
            WHEN t.outcome = 'ok' THEN format('the connection from the monitored server answered in %s s', t.seconds)
            ELSE format('the connection from the monitored server failed after %s s, failing since %s: error %s: %s. The test connects as the collector''s own login maps there: a failure can be that mapping, not the link',
                        t.seconds, to_char(t.first_failed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', t.error_number, t.error_message) END,
       -- a failure stands until its next test: two servers are tested a run, so its own time can be hours old while
       -- the hourly list read still shows the server
       CASE WHEN t.outcome = 'failed' THEN greatest(t.tested_at, l.snapshot_at) ELSE coalesce(t.tested_at, l.snapshot_at) END
  FROM x
  JOIN pgvigil.mssql_linked_server l ON l.instance_id = x.instance_id
  LEFT JOIN pgvigil.mssql_linked_server_test t ON t.instance_id = l.instance_id AND t.name = l.name
UNION ALL
SELECT 'Instance#19', 'linked server connection test', '', NULL, 'ok', NULL, 'dbachecks policy',
       CASE WHEN NOT coalesce(pt.is_read, false) THEN 'not read'
            WHEN (SELECT f.value #>> '{}' FROM f WHERE f.key = 'linked_list_complete') = '0' THEN 'not read'
            ELSE 'ok' END,
       CASE WHEN NOT coalesce(pt.is_read, false) THEN coalesce(pt.note, 'the linked servers were not read yet (mssql_confcheck)')
            WHEN (SELECT f.value #>> '{}' FROM f WHERE f.key = 'linked_list_complete') = '0'
              THEN 'no linked server is visible to the collector''s login: ' || coalesce(pt.note, 'it may not see them all')
            ELSE 'the instance has no linked server' END,
       x.cc_at
  FROM x LEFT JOIN p pt ON pt.part = 'linked'
 WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_linked_server l WHERE l.instance_id = x.instance_id)
UNION ALL
-- 13. the SQL Server Browser (Instance#75, #76): a Windows service SQL Server itself does not show
SELECT b.rule, b.label, '', NULL, NULL, NULL, 'dbachecks policy',
       CASE WHEN x.hosted IS NOT NULL OR x.host_platform = 'Linux' THEN 'not applicable' ELSE 'not read' END,
       CASE WHEN x.hosted IS NOT NULL THEN x.hosted || ' runs the host'
            WHEN x.host_platform = 'Linux' THEN 'SQL Server on Linux has no Browser service'
            ELSE 'pgvigil has no Windows host door yet' END,
       x.cc_at
  FROM x CROSS JOIN (VALUES ('Instance#75', 'SQL Server Browser state'), ('Instance#76', 'SQL Server Browser start mode')) b(rule, label)
$$;

CREATE OR REPLACE VIEW pgvigil.mssql_config_checks AS
SELECT i.instance_id, c.rule, c.check_name, c.object, c.value, c.expected, c.set_at, c.source, c.status, c.detail, c.at
  FROM pgvigil.instances i
  CROSS JOIN LATERAL pgvigil.mssql_config_checks_of(i.instance_id) c
 WHERE i.is_active AND i.engine = 'sqlserver';

-- the findings: the warning and critical rows read in the last three hours (info is shown amber and raises nothing)
CREATE OR REPLACE VIEW pgvigil.mssql_config_check_findings AS
SELECT c.instance_id, c.status AS severity, c.check_name, c.object, c.at, c.detail
  FROM pgvigil.mssql_config_checks c
 WHERE c.status IN ('warning', 'critical') AND c.at > now() - interval '3 hours';
