-- 0162: the optional Extended Events captures of SQL Server (task 411, B18; the collection mssql_xe_captures,
-- internal/mssql/xe_captures.go, every minute). The sessions are the DBA's to make from the printed script
-- (pgvigil mssql-xe -print -captures ...; Allen Q5); pgvigil never creates, alters or drops one.
--
--   mssql_xe_capture_state   per instance and capture (waits, warnings, warncounts, modules): not installed, stopped or
--                            running, the target, the events the last read found, the loss (0065's mssql_xe_lost rule)
--   mssql_xe_waits           monthly partitions by the event's time: a wait that ended over the threshold (wait_info,
--                            wait_info_external): its type and category, duration and signal in ms, who, the plan hash,
--                            the statement under the instance's text policy
--   mssql_xe_warning_hours   the eleven query warnings counted per hour, event, database and plan hash
--   mssql_xe_warning_samples the newest event of each of those keys per hour, with its detail and statement
--   mssql_xe_warning_counts  page_split and sp_cache_miss from the counts session's event_counter: per read, the total
--                            since the session started and the difference from the read before (a restart: from zero)
--   mssql_xe_modules         monthly partitions: a procedure, function or trigger whose whole run was over the threshold
--                            (module_end; microseconds on the event, milliseconds here)
--   mssql_xe_capture_config  the settings (wait_ms, module_ms, app_exclude, proc_exclude) at the fleet, a tag or an
--                            instance, in 0152's mssql_counter_config shape; written only through
--                            import_mssql_xe_capture_config; mssql_xe_capture_config_log every attempt
--   mssql_xe_capture_settings the value in force per instance and key; mssql_xe_capture_settings_json(i) the whole set
--                            as the script and the read take it
--   mssql_xe_captures_findings  'an optional capture is stopped' (info): the arm for pgvigil.findings is the join's
-- The exclusions also apply at the read: a list or a threshold changed after the session was made takes effect at the
-- next read (the import leaves the rows out), and the page says the session's own predicate is older. A SQL Server
-- LIKE pattern's [_] and [%] are read as the literal characters; another bracket class is not supported here.
-- Retention: the two partition parents and the warning tables go to the join's purge() lines (scripts' wiring patch).

CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_capture_state (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  capture          text NOT NULL CHECK (capture IN ('waits', 'warnings', 'warncounts', 'modules')),
  snapshot_at      timestamptz NOT NULL,
  state            text NOT NULL,
  state_since      timestamptz NOT NULL,
  session_name     text,
  target           text,
  buffer_kb        bigint,
  total_processed  bigint,
  new_events       bigint,
  dropped_events   bigint,
  lost_events      bigint,
  lost_at          timestamptz,
  note             text,
  PRIMARY KEY (instance_id, capture)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_waits (
  instance_id      int NOT NULL,
  event_at         timestamptz NOT NULL,
  event_key        text NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  session_name     text,
  event_name       text NOT NULL,
  wait_type        text,
  category         text,
  duration_ms      numeric,
  signal_ms        numeric,
  session_id       int,
  login_name       text,
  host_name        text,
  program_name     text,
  database_name    text,
  plan_handle      text,
  query_plan_hash  text,
  statement        text,
  PRIMARY KEY (instance_id, event_at, event_key)
) PARTITION BY RANGE (event_at);
CREATE INDEX IF NOT EXISTS mssql_xe_waits_type_idx ON pgvigil.mssql_xe_waits (instance_id, wait_type, event_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_modules (
  instance_id      int NOT NULL,
  event_at         timestamptz NOT NULL,
  event_key        text NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  session_name     text,
  object_name      text,
  object_type      text,
  duration_ms      numeric,
  row_count        bigint,
  session_id       int,
  login_name       text,
  host_name        text,
  program_name     text,
  database_name    text,              -- the caller's database (the database_name action)
  module_database  text,              -- the module's own database (DB_NAME(source_database_id), resolved by the reader)
  schema_name      text,              -- the module's schema (OBJECT_SCHEMA_NAME, NULL when the login may not see it)
  PRIMARY KEY (instance_id, event_at, event_key)
) PARTITION BY RANGE (event_at);
ALTER TABLE pgvigil.mssql_xe_modules ADD COLUMN IF NOT EXISTS module_database text, ADD COLUMN IF NOT EXISTS schema_name text;
CREATE INDEX IF NOT EXISTS mssql_xe_modules_obj_idx ON pgvigil.mssql_xe_modules (instance_id, database_name, object_name, event_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_warning_hours (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  hour_at          timestamptz NOT NULL,
  event_name       text NOT NULL,
  database_name    text NOT NULL DEFAULT '',
  query_plan_hash  text NOT NULL DEFAULT '',
  events           bigint NOT NULL,
  PRIMARY KEY (instance_id, hour_at, event_name, database_name, query_plan_hash)
);
CREATE INDEX IF NOT EXISTS mssql_xe_warning_hours_at_idx ON pgvigil.mssql_xe_warning_hours (hour_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_warning_samples (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  hour_at          timestamptz NOT NULL,
  event_name       text NOT NULL,
  database_name    text NOT NULL DEFAULT '',
  query_plan_hash  text NOT NULL DEFAULT '',
  event_at         timestamptz NOT NULL,
  detail           text,
  statement        text,
  login_name       text,
  host_name        text,
  program_name     text,
  session_id       int,
  PRIMARY KEY (instance_id, hour_at, event_name, database_name, query_plan_hash)
);
CREATE INDEX IF NOT EXISTS mssql_xe_warning_samples_at_idx ON pgvigil.mssql_xe_warning_samples (hour_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_warning_counts (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  event_name    text NOT NULL,
  session_name  text,
  total         bigint NOT NULL,
  delta         bigint,             -- NULL on the first read; a restart (a new start, or a smaller total): the total itself
  restarted     boolean NOT NULL DEFAULT false,
  session_created text,             -- dm_xe_sessions.create_time at the read (a restart that passed the old total is seen)
  PRIMARY KEY (instance_id, snapshot_at, event_name)
);
ALTER TABLE pgvigil.mssql_xe_warning_counts ADD COLUMN IF NOT EXISTS session_created text;

-- L7 of the 411 review: the events the warning hours have counted, by key, so a batch imported again (or an event the
-- file read takes again at its floor's timestamp) is never counted twice; deleted with the hours (hour_at)
CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_warning_keys (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  hour_at      timestamptz NOT NULL,
  event_key    text NOT NULL,
  PRIMARY KEY (instance_id, event_key, hour_at)
);
CREATE INDEX IF NOT EXISTS mssql_xe_warning_keys_at_idx ON pgvigil.mssql_xe_warning_keys (hour_at);
CREATE INDEX IF NOT EXISTS mssql_xe_warning_counts_at_idx ON pgvigil.mssql_xe_warning_counts (snapshot_at);

-- ---- the settings (0152's shape) ----------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_capture_keys (
  key          text PRIMARY KEY,
  label        text NOT NULL,
  value_kind   text NOT NULL CHECK (value_kind IN ('ms', 'list')),
  default_val  text NOT NULL
);
INSERT INTO pgvigil.mssql_xe_capture_keys (key, label, value_kind, default_val) VALUES
  ('wait_ms',      'a wait shorter than this is not captured (ms)', 'ms', '1000'),
  ('module_ms',    'a module run shorter than this is not captured (ms)', 'ms', '5000'),
  ('app_exclude',  'program names left out (an exact name, or a LIKE pattern with % or _)', 'list',
   '["pgvigil", "Microsoft SQL Server Management Studio", "Microsoft SQL Server Management Studio - Transact-SQL IntelliSense", "SQLAgent - Job Manager", "SQLAgent - Job invocation engine", "SQLAgent - Schedule Saver", "SQLServerCEIP", "DacFx Deploy", "DatabaseMail%", "SQLAgent - TSQL JobStep%"]'),
  ('proc_exclude', 'procedures left out (database.name or database.schema.name, the name a LIKE pattern)', 'list', '["master.sp[_]%", "msdb.sp[_]%"]')
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, value_kind = EXCLUDED.value_kind, default_val = EXCLUDED.default_val;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_capture_config (
  config_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope          text NOT NULL CHECK (scope IN ('fleet', 'tag', 'instance')),
  tag            text CHECK (length(tag) BETWEEN 1 AND 200),
  instance_name  text CHECK (length(instance_name) BETWEEN 1 AND 200),
  key            text NOT NULL REFERENCES pgvigil.mssql_xe_capture_keys(key),
  value          text NOT NULL CHECK (length(value) <= 8000),
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
CREATE UNIQUE INDEX IF NOT EXISTS mssql_xe_capture_config_live_uq ON pgvigil.mssql_xe_capture_config
  (key, scope, coalesce(tag, ''), coalesce(instance_name, '')) WHERE ended_at IS NULL;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_capture_config_log (
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

-- import_mssql_xe_capture_config: op 'add' (scope, tag | instance_name, key, value, note) or 'end' (config_id), as
-- import_mssql_counter_config (0152); ms values 100 to 3600000 (wait_ms at most 600000); a list is a JSON array of up to
-- 100 entries of 1 to 200 printable characters, a procedure entry database.name_pattern.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_xe_capture_config(p_at timestamptz, p_payload jsonb)
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
    RAISE EXCEPTION 'import_mssql_xe_capture_config: no ui_user' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.mssql_xe_capture_config'));
  IF v_op IS NULL OR v_op NOT IN ('add', 'end') THEN
    v_why := 'op must be add or end';
  ELSIF v_op = 'end' THEN
    IF coalesce(p_payload->>'config_id', '') ~ '^[0-9]{1,18}$' THEN
      v_id := (p_payload->>'config_id')::bigint;
    END IF;
    IF v_id IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.mssql_xe_capture_config WHERE config_id = v_id AND ended_at IS NULL) THEN
      v_why := format('no live row %s', coalesce(p_payload->>'config_id', '(none)'));
    END IF;
  ELSE
    SELECT k.value_kind INTO v_kind FROM pgvigil.mssql_xe_capture_keys k WHERE k.key = v_key;
    IF v_scope IS NULL OR v_scope NOT IN ('fleet', 'tag', 'instance') THEN
      v_why := 'scope must be fleet, tag or instance';
    ELSIF v_scope = 'tag' AND v_tag IS NULL THEN
      v_why := 'a tag row names its tag';
    ELSIF v_scope = 'instance' AND NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.name = v_inst AND i.is_active AND i.engine = 'sqlserver') THEN
      v_why := format('no active SQL Server instance %L', v_inst);
    ELSIF v_kind IS NULL THEN
      v_why := format('%s is not a setting of the captures', coalesce(v_key, '(none)'));
    ELSIF v_kind = 'ms' AND (v_value !~ '^[0-9]{3,7}$' OR v_value::int NOT BETWEEN 100 AND CASE v_key WHEN 'wait_ms' THEN 600000 ELSE 3600000 END) THEN
      v_why := CASE v_key WHEN 'wait_ms' THEN 'the wait threshold is 100 to 600000 ms' ELSE 'the module threshold is 100 to 3600000 ms' END;
    ELSIF v_kind = 'list' THEN
      BEGIN
        v_list := v_value::jsonb;
      EXCEPTION WHEN others THEN
        v_list := NULL;
      END;
      IF v_list IS NULL OR jsonb_typeof(v_list) <> 'array' OR jsonb_array_length(v_list) > 100
         OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_list) e WHERE jsonb_typeof(e) <> 'string' OR length(e #>> '{}') NOT BETWEEN 1 AND 200
                    OR (e #>> '{}') ~ '[\x01-\x1f]' OR position('/*' IN e #>> '{}') > 0 OR position('*/' IN e #>> '{}') > 0
                    OR (v_key = 'proc_exclude' AND ((e #>> '{}') !~ '^[^.]+\.[^.]+(\.[^.]+)?$'))) THEN
        v_why := CASE v_key WHEN 'proc_exclude' THEN 'a list of up to 100 database.name_pattern or database.schema.name_pattern entries, with no /* or */'
                 ELSE 'a list of up to 100 names of 1 to 200 printable characters, with no /* or */' END;
      ELSE
        v_value := (SELECT coalesce(jsonb_agg(e ORDER BY n), '[]'::jsonb)::text FROM jsonb_array_elements(v_list) WITH ORDINALITY AS t(e, n));
      END IF;
    END IF;
  END IF;
  -- the table's own limits, refused here with a log row (a CHECK would roll the attempt back, its log row too)
  IF v_why IS NULL AND v_op = 'add' AND length(v_value) > 8000 THEN
    v_why := 'a value is 8,000 characters at most (a list: fewer or shorter entries)';
  ELSIF v_why IS NULL AND v_op = 'add' AND v_scope = 'tag' AND length(v_tag) > 200 THEN
    v_why := 'a tag is 200 characters at most';
  ELSIF v_why IS NULL AND v_op = 'add' AND v_note IS NOT NULL AND length(v_note) > 500 THEN
    v_why := 'a note is 500 characters at most';
  END IF;
  IF v_why IS NOT NULL THEN
    INSERT INTO pgvigil.mssql_xe_capture_config_log (at, ui_user, client, op, config_id, outcome, detail, payload)
    VALUES (p_at, v_user, v_client, v_op, v_id, 'refused', v_why, p_payload);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_op = 'end' THEN
    UPDATE pgvigil.mssql_xe_capture_config SET ended_by = v_user, ended_at = p_at WHERE config_id = v_id;
    INSERT INTO pgvigil.mssql_xe_capture_config_log (at, ui_user, client, op, config_id, outcome, detail, payload)
    VALUES (p_at, v_user, v_client, 'end', v_id, 'done', 'ended: the scope inherits again', p_payload);
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'ended', 'config_id', v_id);
  END IF;
  IF v_scope <> 'tag' THEN v_tag := NULL; END IF;
  IF v_scope <> 'instance' THEN v_inst := NULL; END IF;
  SELECT c.config_id INTO v_old FROM pgvigil.mssql_xe_capture_config c
   WHERE c.key = v_key AND c.scope = v_scope AND coalesce(c.tag, '') = coalesce(v_tag, '') AND coalesce(c.instance_name, '') = coalesce(v_inst, '')
     AND c.ended_at IS NULL;
  IF v_old IS NOT NULL THEN
    UPDATE pgvigil.mssql_xe_capture_config SET ended_by = v_user, ended_at = p_at WHERE config_id = v_old;
  END IF;
  INSERT INTO pgvigil.mssql_xe_capture_config (scope, tag, instance_name, key, value, note, replaces, created_by, created_at, client)
  VALUES (v_scope, v_tag, v_inst, v_key, v_value, v_note, v_old, v_user, p_at, v_client)
  RETURNING config_id INTO v_new;
  INSERT INTO pgvigil.mssql_xe_capture_config_log (at, ui_user, client, op, config_id, outcome, detail, payload)
  VALUES (p_at, v_user, v_client, 'add', v_new, 'done', CASE WHEN v_old IS NULL THEN 'set' ELSE format('set (replaces %s)', v_old) END, p_payload);
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'set', 'config_id', v_new);
END $$;

CREATE OR REPLACE VIEW pgvigil.mssql_xe_capture_settings AS
WITH live AS (
  SELECT i.instance_id, c.key, c.value, c.scope, c.tag, c.config_id, c.created_by, c.created_at,
         CASE c.scope WHEN 'instance' THEN 3 WHEN 'tag' THEN 2 ELSE 1 END AS level
    FROM pgvigil.mssql_xe_capture_config c
    JOIN pgvigil.instances i ON i.is_active AND i.engine = 'sqlserver'
    LEFT JOIN pgvigil.instance_tags_merged t ON t.instance_id = i.instance_id
   WHERE c.ended_at IS NULL
     AND (c.scope = 'fleet' OR (c.scope = 'instance' AND c.instance_name = i.name)
          OR (c.scope = 'tag' AND c.tag = ANY (coalesce(t.tags, '{}'::text[]))))
), best AS (
  SELECT DISTINCT ON (l.instance_id, l.key) l.* FROM live l ORDER BY l.instance_id, l.key, l.level DESC, l.config_id DESC
)
SELECT i.instance_id, k.key, k.label, k.value_kind, coalesce(b.value, k.default_val) AS value, coalesce(b.scope, 'default') AS set_at,
       b.tag AS set_tag, b.config_id, b.created_by AS set_by, b.created_at AS set_on
  FROM pgvigil.instances i
  CROSS JOIN pgvigil.mssql_xe_capture_keys k
  LEFT JOIN best b ON b.instance_id = i.instance_id AND b.key = k.key
 WHERE i.is_active AND i.engine = 'sqlserver';

-- the whole set of one instance as the script (q_mssql_xe_captures.go) and the read take it
CREATE OR REPLACE FUNCTION pgvigil.mssql_xe_capture_settings_json(p_instance_id int) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
           'wait_ms', max(CASE WHEN key = 'wait_ms' THEN value::int END),
           'module_ms', max(CASE WHEN key = 'module_ms' THEN value::int END),
           'app_exclude', max(CASE WHEN key = 'app_exclude' THEN value END)::jsonb,
           'proc_exclude', max(CASE WHEN key = 'proc_exclude' THEN value END)::jsonb)
    FROM pgvigil.mssql_xe_capture_settings WHERE instance_id = p_instance_id
$$;

-- a SQL Server LIKE pattern as a PostgreSQL ILIKE pattern: [_] and [%] are the literal characters; a backslash escaped
CREATE OR REPLACE FUNCTION pgvigil.mssql_like_pattern(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT replace(replace(replace(p, '\', '\\'), '[_]', '\_'), '[%]', '\%')
$$;

-- whether a program name is left out by the instance's app list (exact, or LIKE when the entry holds % or _)
CREATE OR REPLACE FUNCTION pgvigil.mssql_xe_app_excluded(p_list jsonb, p_app text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_app IS NOT NULL AND EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(coalesce(p_list, '[]'::jsonb)) a(e)
     WHERE CASE WHEN a.e ~ '[%_\[]' THEN p_app ILIKE pgvigil.mssql_like_pattern(a.e) ELSE lower(p_app) = lower(a.e) END)  -- as XE's <> and LIKE: case-insensitive
$$;

-- ---- the import ----------------------------------------------------------------------------------------------------

-- payload rows by kind: xstate (one per capture and read), cursor (one per source and batch), xwait, xwarn, xmodule,
-- xcount; a collector_error row is the run's note and stores nothing. A batch is one call: its events and its cursor row
-- are stored together or not at all. The exclusions and thresholds in force leave rows out here too.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_xe_captures(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_m record;
  v_t record;
  v_s jsonb := pgvigil.mssql_xe_capture_settings_json(p_instance_id);
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_xe_captures: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  -- the partition parents in name order, each month first, then the parent locked for the writes (0065's order)
  FOR v_t IN SELECT * FROM (VALUES ('mssql_xe_modules', 'xmodule'), ('mssql_xe_waits', 'xwait')) x(tbl, kind) ORDER BY tbl
  LOOP
    FOR v_m IN
      SELECT DISTINCT date_trunc('month', (r->>'event_at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS month_at
        FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = v_t.kind AND r->>'event_at' IS NOT NULL ORDER BY 1
    LOOP
      PERFORM pgvigil.mssql_event_partition(v_t.tbl, v_m.month_at);
    END LOOP;
    EXECUTE format('LOCK TABLE ONLY pgvigil.%I IN ROW EXCLUSIVE MODE', v_t.tbl);
  END LOOP;

  INSERT INTO pgvigil.mssql_xe_waits (instance_id, event_at, event_key, snapshot_at, session_name, event_name, wait_type, category,
      duration_ms, signal_ms, session_id, login_name, host_name, program_name, database_name, plan_handle, query_plan_hash, statement)
  SELECT p_instance_id, (r->>'event_at')::timestamptz, r->>'event_key', p_snapshot_at, r->>'session_name', r->>'event_name',
         r->>'wait_type', r->>'category', (r->>'duration_ms')::numeric, (r->>'signal_ms')::numeric, (r->>'session_id')::int,
         r->>'login_name', r->>'host_name', r->>'program_name', r->>'database_name', r->>'plan_handle', r->>'query_plan_hash_hex',
         r->>'statement'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'xwait' AND r->>'event_at' IS NOT NULL AND r->>'event_key' IS NOT NULL AND r->>'event_name' IS NOT NULL
     AND coalesce((r->>'duration_ms')::numeric, 0) >= coalesce((v_s->>'wait_ms')::numeric, 0)
     AND NOT pgvigil.mssql_xe_app_excluded(v_s->'app_exclude', r->>'program_name')
  ON CONFLICT DO NOTHING;

  -- a procedure exclusion is the module's OWN database (module_database; the caller's database only when the reader
  -- could not name it), its schema when the entry has three parts (a module whose schema the login could not see is
  -- kept: it is not known to be the entry's), and the name as a LIKE pattern
  INSERT INTO pgvigil.mssql_xe_modules (instance_id, event_at, event_key, snapshot_at, session_name, object_name, object_type,
      duration_ms, row_count, session_id, login_name, host_name, program_name, database_name, module_database, schema_name)
  SELECT p_instance_id, (r->>'event_at')::timestamptz, r->>'event_key', p_snapshot_at, r->>'session_name', r->>'object_name',
         r->>'object_type', round((r->>'duration_us')::numeric / 1000, 3), (r->>'row_count')::bigint, (r->>'session_id')::int, r->>'login_name',
         r->>'host_name', r->>'program_name', r->>'database_name', r->>'module_database', r->>'schema_name'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'xmodule' AND r->>'event_at' IS NOT NULL AND r->>'event_key' IS NOT NULL
     AND coalesce((r->>'duration_us')::numeric, 0) >= coalesce((v_s->>'module_ms')::numeric, 0) * 1000
     AND NOT pgvigil.mssql_xe_app_excluded(v_s->'app_exclude', r->>'program_name')
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(v_s->'proc_exclude', '[]'::jsonb)) p(e)
                      CROSS JOIN LATERAL (SELECT string_to_array(p.e, '.') AS a) x
                      WHERE lower(x.a[1]) = lower(coalesce(r->>'module_database', r->>'database_name', ''))
                        AND (array_length(x.a, 1) = 2 OR lower(x.a[2]) = lower(r->>'schema_name'))
                        AND coalesce(r->>'object_name', '') ILIKE pgvigil.mssql_like_pattern(x.a[array_length(x.a, 1)]))
  ON CONFLICT DO NOTHING;

  -- the warnings: counted per hour and key, the newest event of each key kept as its sample
  -- (an event's key is kept per hour: a batch imported twice, or an event read again at the file's floor, counts once;
  -- a row without a key - an imported one - always counts)
  WITH w0 AS (
    SELECT date_trunc('hour', (r->>'event_at')::timestamptz) AS hour_at, r->>'event_name' AS event_name,
           coalesce(r->>'database_name', '') AS database_name, coalesce(r->>'query_plan_hash_hex', '') AS query_plan_hash, r
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'xwarn' AND r->>'event_at' IS NOT NULL AND r->>'event_name' IS NOT NULL
       AND NOT pgvigil.mssql_xe_app_excluded(v_s->'app_exclude', r->>'program_name')
  ), fresh AS (
    INSERT INTO pgvigil.mssql_xe_warning_keys (instance_id, hour_at, event_key)
    SELECT DISTINCT p_instance_id, hour_at, r->>'event_key' FROM w0 WHERE r->>'event_key' IS NOT NULL
    ON CONFLICT DO NOTHING
    RETURNING hour_at, event_key
  ), w AS (
    SELECT w0.* FROM w0
     WHERE w0.r->>'event_key' IS NULL OR EXISTS (SELECT 1 FROM fresh f WHERE f.hour_at = w0.hour_at AND f.event_key = w0.r->>'event_key')
  ), counted AS (
    INSERT INTO pgvigil.mssql_xe_warning_hours AS h (instance_id, hour_at, event_name, database_name, query_plan_hash, events)
    SELECT p_instance_id, hour_at, event_name, database_name, query_plan_hash, count(*) FROM w GROUP BY 2, 3, 4, 5
    ON CONFLICT (instance_id, hour_at, event_name, database_name, query_plan_hash) DO UPDATE SET events = h.events + EXCLUDED.events
    RETURNING 1
  )
  INSERT INTO pgvigil.mssql_xe_warning_samples AS s (instance_id, hour_at, event_name, database_name, query_plan_hash, event_at,
      detail, statement, login_name, host_name, program_name, session_id)
  SELECT DISTINCT ON (hour_at, event_name, database_name, query_plan_hash)
         p_instance_id, hour_at, event_name, database_name, query_plan_hash, (r->>'event_at')::timestamptz,
         nullif(concat_ws('; ', r->>'warning_detail', r->>'detail'), ''), r->>'statement',
         r->>'login_name', r->>'host_name', r->>'program_name', (r->>'session_id')::int
    FROM w ORDER BY hour_at, event_name, database_name, query_plan_hash, (r->>'event_at')::timestamptz DESC
  ON CONFLICT (instance_id, hour_at, event_name, database_name, query_plan_hash) DO UPDATE SET
      event_at = EXCLUDED.event_at, detail = EXCLUDED.detail, statement = EXCLUDED.statement, login_name = EXCLUDED.login_name,
      host_name = EXCLUDED.host_name, program_name = EXCLUDED.program_name, session_id = EXCLUDED.session_id
   WHERE s.event_at < EXCLUDED.event_at;

  -- the counts session: the total since the session started and the difference from this instance's read before
  -- a restart: the session's start (create_time) changed, or, where it was not read, a total lower than the last
  INSERT INTO pgvigil.mssql_xe_warning_counts (instance_id, snapshot_at, event_name, session_name, total, delta, restarted, session_created)
  SELECT p_instance_id, p_snapshot_at, r->>'event_name', r->>'session_name', (r->>'count')::bigint,
         CASE WHEN prev.total IS NULL OR prev.session_name IS DISTINCT FROM r->>'session_name' THEN NULL
              WHEN x.restarted THEN (r->>'count')::bigint
              ELSE (r->>'count')::bigint - prev.total END,
         prev.total IS NOT NULL AND prev.session_name IS NOT DISTINCT FROM r->>'session_name' AND x.restarted,
         r->>'session_created'
    FROM jsonb_array_elements(p_payload) r
    LEFT JOIN LATERAL (SELECT c.total, c.session_name, c.session_created FROM pgvigil.mssql_xe_warning_counts c
                        WHERE c.instance_id = p_instance_id AND c.event_name = r->>'event_name' AND c.snapshot_at < p_snapshot_at
                        ORDER BY c.snapshot_at DESC LIMIT 1) prev ON true
    CROSS JOIN LATERAL (SELECT CASE WHEN prev.session_created IS NOT NULL AND r->>'session_created' IS NOT NULL
                                    THEN prev.session_created IS DISTINCT FROM r->>'session_created'
                                    ELSE (r->>'count')::bigint < prev.total END AS restarted) x
   WHERE r->>'kind' = 'xcount' AND r->>'event_name' IS NOT NULL AND r->>'count' IS NOT NULL
  ON CONFLICT DO NOTHING;

  INSERT INTO pgvigil.mssql_xe_capture_state AS s (instance_id, capture, snapshot_at, state, state_since, session_name, target,
      buffer_kb, total_processed, new_events, dropped_events, note)
  SELECT p_instance_id, r->>'capture', p_snapshot_at, r->>'state', p_snapshot_at, r->>'session_name', r->>'target',
         (r->>'buffer_kb')::bigint, (r->>'total_processed')::bigint, (r->>'new_events')::bigint, (r->>'dropped_events')::bigint, r->>'note'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'xstate' AND r->>'capture' IN ('waits', 'warnings', 'warncounts', 'modules') AND r->>'state' IS NOT NULL
  ON CONFLICT (instance_id, capture) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, state = EXCLUDED.state,
      state_since = CASE WHEN s.state = EXCLUDED.state THEN s.state_since ELSE EXCLUDED.snapshot_at END,
      session_name = EXCLUDED.session_name, target = EXCLUDED.target, buffer_kb = EXCLUDED.buffer_kb,
      total_processed = EXCLUDED.total_processed, new_events = EXCLUDED.new_events, dropped_events = EXCLUDED.dropped_events,
      note = EXCLUDED.note,
      lost_events = CASE WHEN pgvigil.mssql_xe_lost(s.session_name, s.total_processed, s.dropped_events, EXCLUDED.session_name,
                              EXCLUDED.target, EXCLUDED.total_processed, EXCLUDED.new_events, EXCLUDED.dropped_events) > 0
                         THEN pgvigil.mssql_xe_lost(s.session_name, s.total_processed, s.dropped_events, EXCLUDED.session_name,
                              EXCLUDED.target, EXCLUDED.total_processed, EXCLUDED.new_events, EXCLUDED.dropped_events)
                         ELSE s.lost_events END,
      lost_at = CASE WHEN pgvigil.mssql_xe_lost(s.session_name, s.total_processed, s.dropped_events, EXCLUDED.session_name,
                              EXCLUDED.target, EXCLUDED.total_processed, EXCLUDED.new_events, EXCLUDED.dropped_events) > 0
                     THEN EXCLUDED.snapshot_at ELSE s.lost_at END
  WHERE s.snapshot_at < EXCLUDED.snapshot_at;

  INSERT INTO pgvigil.mssql_cursor AS c (instance_id, source, file_name, file_offset, last_event_at, last_seq, updated_at)
  SELECT DISTINCT ON (r->>'source') p_instance_id, r->>'source', r->>'file_name', (r->>'file_offset')::bigint,
         (r->>'last_event_at')::timestamptz, (r->>'last_seq')::bigint, now()
    FROM jsonb_array_elements(p_payload) WITH ORDINALITY AS t(r, n)
   WHERE r->>'kind' = 'cursor' AND r->>'source' IS NOT NULL
   ORDER BY r->>'source', n DESC
  ON CONFLICT (instance_id, source) DO UPDATE SET
      file_name = EXCLUDED.file_name, file_offset = EXCLUDED.file_offset, last_event_at = EXCLUDED.last_event_at,
      last_seq = EXCLUDED.last_seq, updated_at = EXCLUDED.updated_at;
END $$;

-- ---- the page's reads ----------------------------------------------------------------------------------------------

-- the slow capture's workload (0065's mssql_slow_events, the completions only: rpc_completed and sql_batch_completed, so
-- a statement is not counted twice) per hour or day, by login, program, host or database: SQLMonitor's XEvent Trend
CREATE OR REPLACE FUNCTION pgvigil.mssql_xe_slow_trend(p_instance_id int, p_from timestamptz, p_to timestamptz, p_bucket text, p_by text)
RETURNS TABLE (bucket_at timestamptz, grp text, events bigint, cpu_ms numeric, duration_ms numeric, logical_reads bigint)
LANGUAGE sql STABLE AS $$
  SELECT date_trunc(CASE WHEN p_bucket = 'day' THEN 'day' ELSE 'hour' END, e.event_at) AS bucket_at,
         coalesce(CASE p_by WHEN 'program' THEN e.program_name WHEN 'host' THEN e.host_name WHEN 'database' THEN e.database_name
                       ELSE e.login_name END, '(none)') AS grp,
         count(*), sum(e.cpu_ms), sum(e.duration_ms), sum(e.logical_reads)
    FROM pgvigil.mssql_slow_events e
   WHERE e.instance_id = p_instance_id AND e.event_at > p_from AND e.event_at <= p_to
     AND e.event_name IN ('rpc_completed', 'sql_batch_completed')
   GROUP BY 1, 2
   ORDER BY 1, 2
$$;

CREATE OR REPLACE VIEW pgvigil.mssql_xe_captures_findings AS
SELECT s.instance_id, 'info'::text AS severity, 'an optional capture is stopped'::text AS check_name, s.capture AS object,
       s.snapshot_at AS at,
       'the session ' || coalesce(s.session_name, s.capture) || ' is defined and not started since '
         || to_char(s.state_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC: ALTER EVENT SESSION ... STATE = START is the DBA''s step' AS detail
  FROM pgvigil.mssql_xe_capture_state s
 WHERE s.state = 'stopped' AND s.snapshot_at > now() - interval '10 minutes';
