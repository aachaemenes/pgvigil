-- 0100_pg_audit: PostgreSQL audit monitoring, pgaudit (task 157): the pgaudit collection's import and its reads
-- (internal/collect/pgaudit.go: the audit settings from the catalog every minute and, on a server that preloads
-- pgaudit, the 'AUDIT:' lines of the server log through the log readers' doors).
--
--   pgaudit_state        one row per instance: the last read - whether the library is loaded, the preload list, where
--                        the server log goes, whether the audit lines were read ('ok' | 'off' | 'not read', with the
--                        reason), whether the instance keeps statement text (the opt-in), the newest entry seen.
--   pgaudit_settings     every pgaudit.* setting in force somewhere: at the server (pg_settings, with its source), on a
--                        database, on a role, on a role in a database (pg_db_role_setting). Replaced whole by each read.
--   pgaudit_events       one row per ROLE and DDL entry and per SET / RESET of a setting that matters to an audit
--                        (class MISC_SET: pgaudit.*, session_authorization, row_security, session_replication_role,
--                        the log_* settings that hide statements): who, when, database, client, command, object, the
--                        role a GRANT / REVOKE or a SET SESSION AUTHORIZATION names; the statement text and the
--                        parameters only where the instance opted in. Monthly partitions by the entry's own time
--                        (snapshot_at); a re-read entry is dropped by its key, as in log_events.
--   pgaudit_counts       every other entry as a count per hour (UTC), role, database, class, command and object:
--                        READ, WRITE, FUNCTION, MISC, and the other SETs by setting name (MISC_SET, object type
--                        SETTING; SET ROLE as 'role = <the role taken>'). Never a statement. Monthly partitions by
--                        the hour (snapshot_at).
--                        The class is pgaudit.log's: a SET is MISC_SET here though its log line says MISC.
--   pgaudit_count_secs   the duplicate guard of the counts: what each second of each log file or stream has counted
--                        so far. The collector counts per second and re-reads an overlap; the import adds to
--                        pgaudit_counts only what a second gained since the last read. Kept 30 minutes behind the
--                        cursor.
--   pgaudit_rules        the alert rules: a class of entry (or failed sign-ins, read from log_events), an optional
--                        command and object pattern, a count within a window, a severity. Rows of the repository:
--                        its owner changes them with UPDATE / INSERT (docs/audit.md).
--   import_pgaudit(i, at, payload)
--   pgaudit_logs(v)      true when a pgaudit.log value names a class (not none, not only -class entries).
--   pgaudit_health       per instance: the status cell (ok | warning | off), its text and the facts behind it.
--   pgaudit_rule_hits    per instance and enabled rule: the entries inside the rule's window, the newest, a sample.
--   pgaudit_findings     the findings view's columns (instance_id, severity, setting, value, is_set, suggested,
--                        platforms, detail, source, at): the health findings and the rules that fire. The UNION arm in
--                        pgvigil.findings and the purge lines (two monthly partition parents; pgaudit_count_secs and
--                        pgaudit_state by age) are the wave's join.

CREATE TABLE IF NOT EXISTS pgvigil.pgaudit_state (
  instance_id        int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at        timestamptz NOT NULL,
  loaded             boolean NOT NULL,          -- the library's own settings exist in a backend
  preload_libraries  text,                      -- shared_preload_libraries as read; NULL: the login may not read it
  log_where          text,                      -- where the server log goes, in words
  log_read           text NOT NULL CHECK (log_read IN ('ok', 'off', 'not read')),
  log_read_reason    text,
  log_source         text,                      -- the reader's source ('serverlog:<directory>', 'cloudwatch:<group>')
  keep_text          boolean NOT NULL DEFAULT false,
  entries_read       bigint,                    -- audit entries in the last read (the overlap's re-read included)
  last_entry_at      timestamptz,               -- the newest audit entry any read has seen
  forged_lines       bigint,                    -- lines in the last read that have pgaudit's form and are not pgaudit's
  forged_at          timestamptz,               -- the newest such line any read has met
  forged_by          text                       -- its user@database
);

CREATE TABLE IF NOT EXISTS pgvigil.pgaudit_settings (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  scope        text NOT NULL CHECK (scope IN ('server', 'database', 'role', 'role in database')),
  datname      text NOT NULL DEFAULT '',
  rolname      text NOT NULL DEFAULT '',
  name         text NOT NULL,
  value        text,
  source       text,                            -- server scope: pg_settings.source
  snapshot_at  timestamptz NOT NULL,
  PRIMARY KEY (instance_id, scope, datname, rolname, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.pgaudit_events (
  instance_id      int NOT NULL,
  snapshot_at      timestamptz NOT NULL,        -- the entry's own time from the log line
  audit_type       text NOT NULL,               -- SESSION | OBJECT
  class            text NOT NULL,
  command          text NOT NULL,
  object_type      text,
  object_name      text,
  target_role      text,
  usename          text,
  datname          text,
  client           text,
  pid              int,
  statement_id     bigint,
  substatement_id  bigint,
  row_count        bigint,                      -- pgaudit.log_rows
  statement        text,                        -- only with the instance's opt-in
  parameters       text,                        -- only with the instance's opt-in
  source           text NOT NULL,
  event_key        text NOT NULL
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.pgaudit_counts (
  instance_id  int NOT NULL,
  snapshot_at  timestamptz NOT NULL,            -- the hour, UTC
  usename      text NOT NULL DEFAULT '',
  datname      text NOT NULL DEFAULT '',
  class        text NOT NULL,
  command      text NOT NULL DEFAULT '',
  object_type  text NOT NULL DEFAULT '',
  object_name  text NOT NULL DEFAULT '',
  entries      bigint NOT NULL,
  PRIMARY KEY (instance_id, snapshot_at, usename, datname, class, command, object_type, object_name)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.pgaudit_count_secs (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  source       text NOT NULL,                   -- the log file or stream
  sec          timestamptz NOT NULL,
  usename      text NOT NULL DEFAULT '',
  datname      text NOT NULL DEFAULT '',
  class        text NOT NULL,
  command      text NOT NULL DEFAULT '',
  object_type  text NOT NULL DEFAULT '',
  object_name  text NOT NULL DEFAULT '',
  entries      bigint NOT NULL,
  PRIMARY KEY (instance_id, source, sec, usename, datname, class, command, object_type, object_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.pgaudit_rules (
  rule_id         int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name            text NOT NULL UNIQUE,
  what            text NOT NULL CHECK (what IN ('ROLE', 'DDL', 'MISC_SET', 'AUTH_FAIL')),
  command_like    text,                         -- NULL: any command (LIKE, case-blind)
  object_like     text,                         -- NULL: any object (LIKE, case-blind)
  min_count       int NOT NULL DEFAULT 1 CHECK (min_count >= 1),
  window_minutes  int NOT NULL DEFAULT 1440 CHECK (window_minutes BETWEEN 1 AND 44640),
  severity        text NOT NULL DEFAULT 'warning' CHECK (severity IN ('info', 'warning', 'critical')),
  CHECK (what <> 'AUTH_FAIL' OR command_like IS NULL),   -- a failed sign-in has no command
  is_enabled      boolean NOT NULL DEFAULT true,
  note            text
);

INSERT INTO pgvigil.pgaudit_rules (name, what, command_like, object_like, min_count, window_minutes, severity, is_enabled, note) VALUES
  ('role or privilege change', 'ROLE', NULL, NULL, 1, 1440, 'warning', true,
   'CREATE / ALTER / DROP ROLE, GRANT, REVOKE: any one in the last 24 hours'),
  ('audit setting changed by a session', 'MISC_SET', NULL, 'pgaudit.%', 1, 1440, 'warning', true,
   'a session SET or RESET a pgaudit.* setting (its own auditing): any one in the last 24 hours; needs misc_set in pgaudit.log'),
  ('session authorization changed', 'MISC_SET', NULL, 'session_authorization', 1, 1440, 'warning', true,
   'SET SESSION AUTHORIZATION (a superuser acting as another role): any one in the last 24 hours; needs misc_set in pgaudit.log'),
  ('failed sign-ins', 'AUTH_FAIL', NULL, NULL, 10, 60, 'warning', true,
   'ten or more failed sign-ins in an hour (the log readers'' auth_fail events; pgaudit is not needed)'),
  ('object dropped', 'DDL', 'DROP %', NULL, 1, 1440, 'warning', false,
   'off by default: a release drops objects'),
  ('schema change', 'DDL', NULL, NULL, 1, 1440, 'info', false,
   'off by default: every DDL statement of the last 24 hours')
ON CONFLICT (name) DO NOTHING;

-- pgaudit_logs: does a pgaudit.log value log anything? 'none', '' and a list of only -class entries do not.
CREATE OR REPLACE FUNCTION pgvigil.pgaudit_logs(p_value text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT EXISTS (SELECT 1 FROM regexp_split_to_table(lower(coalesce(p_value, '')), ',') c(x)
                  WHERE btrim(c.x) NOT IN ('', 'none') AND left(btrim(c.x), 1) <> '-')
$$;

-- payload: one {kind:'state', loaded, preload_libraries, log_where, log_read, log_read_reason, log_source, keep_text,
--   entries_read, last_entry_at, forged_lines, forged_at, forged_by}; {kind:'setting', scope, datname, rolname, name, value, source} rows;
--   {kind:'event', at, audit_type, class, command, object_type, object_name, target_role, usename, datname, client, pid,
--   statement_id, substatement_id, row_count, statement, parameters, source, event_key} rows;
--   {kind:'count', source, sec, usename, datname, class, command, object_type, object_name, entries} rows (one per
--   second and key: the entries of that second as this read counted them); at most one {kind:'cursor', source, read_to}.
CREATE OR REPLACE FUNCTION pgvigil.import_pgaudit(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_state jsonb;
  m       timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_pgaudit'), p_instance_id);
  SELECT r INTO v_state FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'state' LIMIT 1;
  IF v_state IS NULL THEN
    RAISE EXCEPTION 'import_pgaudit: the payload has no state row';
  END IF;

  -- the state and the settings: the newest read wins (a one-off collect beside the daemon may arrive late)
  IF NOT EXISTS (SELECT 1 FROM pgvigil.pgaudit_state s WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_snapshot_at) THEN
    INSERT INTO pgvigil.pgaudit_state AS s (instance_id, snapshot_at, loaded, preload_libraries, log_where, log_read, log_read_reason,
                                            log_source, keep_text, entries_read, last_entry_at, forged_lines, forged_at, forged_by)
    VALUES (p_instance_id, p_snapshot_at, coalesce((v_state->>'loaded')::boolean, false), v_state->>'preload_libraries',
            v_state->>'log_where', coalesce(v_state->>'log_read', 'not read'), v_state->>'log_read_reason', v_state->>'log_source',
            coalesce((v_state->>'keep_text')::boolean, false), (v_state->>'entries_read')::bigint, (v_state->>'last_entry_at')::timestamptz,
            (v_state->>'forged_lines')::bigint, (v_state->>'forged_at')::timestamptz, v_state->>'forged_by')
    ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, loaded = EXCLUDED.loaded,
      preload_libraries = EXCLUDED.preload_libraries, log_where = EXCLUDED.log_where, log_read = EXCLUDED.log_read,
      log_read_reason = EXCLUDED.log_read_reason, log_source = EXCLUDED.log_source, keep_text = EXCLUDED.keep_text,
      entries_read = EXCLUDED.entries_read,
      last_entry_at = CASE WHEN EXCLUDED.last_entry_at IS NULL THEN s.last_entry_at
                           ELSE greatest(coalesce(s.last_entry_at, EXCLUDED.last_entry_at), EXCLUDED.last_entry_at) END,
      forged_lines = EXCLUDED.forged_lines,
      forged_at = CASE WHEN EXCLUDED.forged_at IS NULL OR s.forged_at > EXCLUDED.forged_at THEN s.forged_at ELSE EXCLUDED.forged_at END,
      forged_by = CASE WHEN EXCLUDED.forged_at IS NULL OR s.forged_at > EXCLUDED.forged_at THEN s.forged_by ELSE EXCLUDED.forged_by END;
    DELETE FROM pgvigil.pgaudit_settings WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.pgaudit_settings (instance_id, scope, datname, rolname, name, value, source, snapshot_at)
    SELECT DISTINCT ON (r->>'scope', coalesce(r->>'datname', ''), coalesce(r->>'rolname', ''), r->>'name')
           p_instance_id, r->>'scope', coalesce(r->>'datname', ''), coalesce(r->>'rolname', ''), r->>'name', r->>'value', r->>'source', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'setting' AND r->>'name' IS NOT NULL
       AND r->>'scope' IN ('server', 'database', 'role', 'role in database');
  END IF;

  -- the rows: an entry already stored (same instance, time and key) is skipped; a re-read that brings more of it
  -- (the entry was cut by the first read's end) fills it in
  FOR m IN SELECT DISTINCT date_trunc('month', (r->>'at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
             FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'event'
  LOOP
    PERFORM pgvigil.ensure_month_partition('pgaudit_events', m);
  END LOOP;

  CREATE TEMP TABLE pgv_audit_ev ON COMMIT DROP AS
  SELECT DISTINCT ON (r->>'at', r->>'event_key')
         (r->>'at')::timestamptz AS at, coalesce(r->>'audit_type', 'SESSION') AS audit_type, r->>'class' AS class,
         coalesce(r->>'command', '') AS command, nullif(r->>'object_type', '') AS object_type, nullif(r->>'object_name', '') AS object_name,
         nullif(r->>'target_role', '') AS target_role, r->>'usename' AS usename, r->>'datname' AS datname, r->>'client' AS client,
         (r->>'pid')::int AS pid, (r->>'statement_id')::bigint AS statement_id, (r->>'substatement_id')::bigint AS substatement_id,
         (r->>'row_count')::bigint AS row_count, r->>'statement' AS statement, r->>'parameters' AS parameters,
         r->>'source' AS source, r->>'event_key' AS event_key
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'event' AND r->>'at' IS NOT NULL AND r->>'event_key' IS NOT NULL AND r->>'class' IS NOT NULL AND r->>'source' IS NOT NULL
   ORDER BY r->>'at', r->>'event_key', length(coalesce(r->>'statement', '')) DESC;

  UPDATE pgvigil.pgaudit_events e
     SET statement   = CASE WHEN length(coalesce(i.statement, '')) > length(coalesce(e.statement, '')) THEN i.statement ELSE e.statement END,
         parameters  = coalesce(e.parameters, i.parameters),
         object_type = coalesce(e.object_type, i.object_type),
         object_name = coalesce(e.object_name, i.object_name),
         target_role = coalesce(e.target_role, i.target_role),
         row_count   = coalesce(e.row_count, i.row_count)
    FROM pgv_audit_ev i
   WHERE e.instance_id = p_instance_id AND e.snapshot_at = i.at AND e.event_key = i.event_key
     AND (length(coalesce(i.statement, '')) > length(coalesce(e.statement, ''))
       OR (e.parameters IS NULL AND i.parameters IS NOT NULL)
       OR (e.object_type IS NULL AND i.object_type IS NOT NULL)
       OR (e.object_name IS NULL AND i.object_name IS NOT NULL)
       OR (e.target_role IS NULL AND i.target_role IS NOT NULL)
       OR (e.row_count IS NULL AND i.row_count IS NOT NULL));

  INSERT INTO pgvigil.pgaudit_events (instance_id, snapshot_at, audit_type, class, command, object_type, object_name, target_role,
                                      usename, datname, client, pid, statement_id, substatement_id, row_count, statement, parameters, source, event_key)
  SELECT p_instance_id, i.at, i.audit_type, i.class, i.command, i.object_type, i.object_name, i.target_role,
         i.usename, i.datname, i.client, i.pid, i.statement_id, i.substatement_id, i.row_count, i.statement, i.parameters, i.source, i.event_key
    FROM pgv_audit_ev i
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.pgaudit_events e
                      WHERE e.instance_id = p_instance_id AND e.snapshot_at = i.at AND e.event_key = i.event_key);
  DROP TABLE pgv_audit_ev;

  -- the counts: what each second gained over what it had counted (a re-read of a whole second counts it again and
  -- gains nothing; a second read from its middle counts less than is stored and changes nothing)
  CREATE TEMP TABLE pgv_audit_cnt ON COMMIT DROP AS
  SELECT i.source, i.sec, i.usename, i.datname, i.class, i.command, i.object_type, i.object_name, i.entries,
         i.entries - coalesce(s.entries, 0) AS gained
    FROM (SELECT r->>'source' AS source, (r->>'sec')::timestamptz AS sec, coalesce(r->>'usename', '') AS usename,
                 coalesce(r->>'datname', '') AS datname, r->>'class' AS class, coalesce(r->>'command', '') AS command,
                 coalesce(r->>'object_type', '') AS object_type, coalesce(r->>'object_name', '') AS object_name,
                 sum((r->>'entries')::bigint)::bigint AS entries
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'count' AND r->>'source' IS NOT NULL AND r->>'sec' IS NOT NULL AND r->>'class' IS NOT NULL
             AND (r->>'entries')::bigint > 0
           GROUP BY 1, 2, 3, 4, 5, 6, 7, 8) i
    LEFT JOIN pgvigil.pgaudit_count_secs s
      ON s.instance_id = p_instance_id AND s.source = i.source AND s.sec = i.sec AND s.usename = i.usename AND s.datname = i.datname
     AND s.class = i.class AND s.command = i.command AND s.object_type = i.object_type AND s.object_name = i.object_name
   WHERE i.entries > coalesce(s.entries, 0)
     -- a second the guard has already let go of (behind its source's cursor less 30 minutes) is never counted again:
     -- a late import (a one-off collect beside the daemon) would otherwise add it whole
     AND NOT EXISTS (SELECT 1 FROM pgvigil.log_cursor c
                      WHERE c.instance_id = p_instance_id AND c.source LIKE 'pgaudit:%'
                        AND 'pgaudit:' || i.source LIKE c.source || ':%' AND i.sec < c.read_to - interval '30 minutes');

  INSERT INTO pgvigil.pgaudit_count_secs AS s (instance_id, source, sec, usename, datname, class, command, object_type, object_name, entries)
  SELECT p_instance_id, c.source, c.sec, c.usename, c.datname, c.class, c.command, c.object_type, c.object_name, c.entries
    FROM pgv_audit_cnt c
  ON CONFLICT (instance_id, source, sec, usename, datname, class, command, object_type, object_name)
  DO UPDATE SET entries = EXCLUDED.entries;

  FOR m IN SELECT DISTINCT date_trunc('month', c.sec AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' FROM pgv_audit_cnt c
  LOOP
    PERFORM pgvigil.ensure_month_partition('pgaudit_counts', m);
  END LOOP;

  INSERT INTO pgvigil.pgaudit_counts AS t (instance_id, snapshot_at, usename, datname, class, command, object_type, object_name, entries)
  SELECT p_instance_id, date_trunc('hour', c.sec AT TIME ZONE 'UTC') AT TIME ZONE 'UTC', c.usename, c.datname, c.class, c.command,
         c.object_type, c.object_name, sum(c.gained)::bigint
    FROM pgv_audit_cnt c
   GROUP BY 2, 3, 4, 5, 6, 7, 8
  ON CONFLICT (instance_id, snapshot_at, usename, datname, class, command, object_type, object_name)
  DO UPDATE SET entries = t.entries + EXCLUDED.entries;
  DROP TABLE pgv_audit_cnt;

  -- the cursor, and the guard's seconds no read will come back to
  INSERT INTO pgvigil.log_cursor AS c (instance_id, source, read_to)
  SELECT p_instance_id, r->>'source', (r->>'read_to')::timestamptz
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cursor' AND r->>'source' LIKE 'pgaudit:%'
  ON CONFLICT (instance_id, source) DO UPDATE SET read_to = greatest(c.read_to, EXCLUDED.read_to), updated_at = now();

  -- per source: a source no longer read (log_directory changed) holds nothing back for the others
  DELETE FROM pgvigil.pgaudit_count_secs s
   USING pgvigil.log_cursor c
   WHERE s.instance_id = p_instance_id AND c.instance_id = p_instance_id AND c.source LIKE 'pgaudit:%'
     AND 'pgaudit:' || s.source LIKE c.source || ':%' AND s.sec < c.read_to - interval '30 minutes';
END $$;

-- pgaudit_health: the status cell of an instance and the facts behind it.
--   off      the library is not loaded and nothing sets a pgaudit.* value
--   warning  loaded and logging nothing (pgaudit.log names no class at the server, on any database or role, and
--            pgaudit.role names no role), or not loaded though something sets a pgaudit.* value
--   ok       loaded and logging: the cell names the server's classes and how many databases and roles set their own
CREATE OR REPLACE VIEW pgvigil.pgaudit_health AS
WITH s AS (
  SELECT st.instance_id,
         max(x.value) FILTER (WHERE x.scope = 'server' AND x.name = 'pgaudit.log') AS server_log,
         max(x.value) FILTER (WHERE x.scope = 'server' AND x.name = 'pgaudit.role') AS server_role,
         count(*) FILTER (WHERE x.scope <> 'server') AS scoped,
         count(*) FILTER (WHERE x.scope <> 'server' AND ((x.name = 'pgaudit.log' AND pgvigil.pgaudit_logs(x.value))
                                                      OR (x.name = 'pgaudit.role' AND btrim(coalesce(x.value, '')) <> ''))) AS scoped_logging,
         count(*) FILTER (WHERE x.name = 'pgaudit.log_parameter' AND lower(x.value) IN ('on', 'true', 'yes', '1')) AS parameter_on,
         count(x.name) AS settings
    FROM pgvigil.pgaudit_state st
    LEFT JOIN pgvigil.pgaudit_settings x ON x.instance_id = st.instance_id
   GROUP BY st.instance_id
)
SELECT st.instance_id, st.snapshot_at, st.loaded,
       CASE WHEN NOT st.loaded AND s.settings = 0 THEN 'off'
            WHEN NOT st.loaded THEN 'warning'
            WHEN pgvigil.pgaudit_logs(s.server_log) OR btrim(coalesce(s.server_role, '')) <> '' OR s.scoped_logging > 0 THEN 'ok'
            ELSE 'warning' END AS status,
       CASE WHEN NOT st.loaded AND s.settings = 0 THEN 'not loaded'
            WHEN NOT st.loaded THEN 'set, not loaded'
            WHEN pgvigil.pgaudit_logs(s.server_log) OR btrim(coalesce(s.server_role, '')) <> '' OR s.scoped_logging > 0 THEN
              concat_ws('; ',
                CASE WHEN pgvigil.pgaudit_logs(s.server_log) THEN lower(btrim(s.server_log)) END,
                CASE WHEN btrim(coalesce(s.server_role, '')) <> '' THEN 'objects of role ' || btrim(s.server_role) END,
                CASE WHEN s.scoped_logging > 0 THEN s.scoped_logging || ' database / role setting' || CASE WHEN s.scoped_logging = 1 THEN '' ELSE 's' END END)
            ELSE 'loaded, logging nothing' END AS cell,
       s.server_log, s.server_role, s.scoped, s.scoped_logging, s.parameter_on > 0 AS parameter_on,
       st.preload_libraries, st.log_where, st.log_read, st.log_read_reason, st.log_source, st.keep_text, st.entries_read, st.last_entry_at
  FROM pgvigil.pgaudit_state st
  JOIN s ON s.instance_id = st.instance_id;

-- pgaudit_rule_hits: per active instance and enabled rule, the entries inside the rule's window.
CREATE OR REPLACE VIEW pgvigil.pgaudit_rule_hits AS
SELECT i.instance_id, r.rule_id, r.name, r.what, r.severity, r.min_count, r.window_minutes, h.hits, h.last_at, h.sample
  FROM pgvigil.instances i
  CROSS JOIN pgvigil.pgaudit_rules r
  CROSS JOIN LATERAL (
    SELECT count(*)::bigint AS hits, max(e.at) AS last_at,
           (array_agg(e.line ORDER BY e.at DESC))[1:5] AS sample
      FROM (
        SELECT a.snapshot_at AS at,
               to_char(a.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC ' || coalesce(nullif(a.usename, ''), '?') || '@' || coalesce(nullif(a.datname, ''), '?')
                 || ' ' || a.command || coalesce(' ' || a.object_name, '') || coalesce(' -> ' || a.target_role, '') AS line
          FROM pgvigil.pgaudit_events a
         WHERE r.what <> 'AUTH_FAIL' AND a.instance_id = i.instance_id AND a.class = r.what
           AND a.snapshot_at > now() - make_interval(mins => r.window_minutes)
           AND (r.command_like IS NULL OR a.command ILIKE r.command_like)
           AND (r.object_like IS NULL OR a.object_name ILIKE r.object_like OR a.target_role ILIKE r.object_like
                OR EXISTS (SELECT 1 FROM unnest(string_to_array(a.target_role, ', ')) g(n) WHERE g.n ILIKE r.object_like))
        UNION ALL
        SELECT l.snapshot_at,
               to_char(l.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC ' || coalesce(nullif(l.usename, ''), '?') || '@' || coalesce(nullif(l.datname, ''), '?')
                 || coalesce(' from ' || nullif(l.client, ''), '')
          FROM pgvigil.log_events l
         WHERE r.what = 'AUTH_FAIL' AND l.instance_id = i.instance_id AND l.kind = 'auth_fail'
           AND l.snapshot_at > now() - make_interval(mins => r.window_minutes)
           AND (r.object_like IS NULL OR l.usename ILIKE r.object_like)
      ) e
  ) h
 WHERE i.is_active AND i.engine = 'postgres' AND r.is_enabled;

-- pgaudit_findings: the findings view's columns.
CREATE OR REPLACE VIEW pgvigil.pgaudit_findings AS
-- loaded, logging nothing
SELECT h.instance_id, 'warning'::text AS severity, 'pgaudit.log'::text AS setting, coalesce(nullif(btrim(h.server_log), ''), 'none') AS value,
       true AS is_set, 'the classes to audit (ddl, role), or pgaudit out of shared_preload_libraries'::text AS suggested, 'all'::text AS platforms,
       'pgaudit preloaded, logging nothing: pgaudit.log names no class at the server, on any database or on any role, and pgaudit.role names no role. Every backend loads the library and no statement is audited.'::text AS detail,
       'pgvigil pgaudit'::text AS source, h.snapshot_at AS at
  FROM pgvigil.pgaudit_health h JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
 WHERE h.loaded AND h.status = 'warning'
UNION ALL
-- set somewhere, the library not loaded
SELECT h.instance_id, 'warning', 'shared_preload_libraries', coalesce(h.preload_libraries, '(not readable)'), true,
       'pgaudit in shared_preload_libraries (a restart)', 'all',
       format('pgaudit settings without pgaudit: %s pgaudit.* value(s) are set (%s) and the library is not loaded, so nothing is audited.', x.n, x.list),
       'pgvigil pgaudit', h.snapshot_at
  FROM pgvigil.pgaudit_health h JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
  CROSS JOIN LATERAL (
    SELECT count(*) AS n,
           string_agg(s.name || CASE s.scope WHEN 'server' THEN '' WHEN 'database' THEN ' on database ' || s.datname
                                            WHEN 'role' THEN ' on role ' || s.rolname ELSE ' on role ' || s.rolname || ' in ' || s.datname END,
                      ', ' ORDER BY s.scope, s.datname, s.rolname, s.name) AS list
      FROM pgvigil.pgaudit_settings s WHERE s.instance_id = h.instance_id) x
 WHERE NOT h.loaded AND h.status = 'warning'
UNION ALL
-- log_parameter on, at any level
SELECT h.instance_id, 'warning', 'pgaudit.log_parameter', 'on' || CASE WHEN x.list = '' THEN '' ELSE ' (' || x.list || ')' END, true, 'off', 'all',
       'log_parameter on: statement parameters reach the log. Every bound value of an audited statement (a name, a card number, a password passed as a parameter) is written in clear to the server log and to every place the log is shipped.',
       'pgvigil pgaudit', h.snapshot_at
  FROM pgvigil.pgaudit_health h JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
  CROSS JOIN LATERAL (
    SELECT coalesce(string_agg(CASE s.scope WHEN 'server' THEN 'server' WHEN 'database' THEN 'database ' || s.datname
                                            WHEN 'role' THEN 'role ' || s.rolname ELSE 'role ' || s.rolname || ' in ' || s.datname END,
                               ', ' ORDER BY s.scope, s.datname, s.rolname), '') AS list
      FROM pgvigil.pgaudit_settings s
     WHERE s.instance_id = h.instance_id AND s.name = 'pgaudit.log_parameter' AND lower(s.value) IN ('on', 'true', 'yes', '1')) x
 WHERE h.loaded AND h.parameter_on
UNION ALL
-- DDL audited, the extension not created in a database the extensions collection has read
SELECT h.instance_id, 'info', 'pgaudit extension', 'not created in ' || x.list, true, 'CREATE EXTENSION pgaudit in each database', 'all',
       'pgaudit logs DDL here, and in these databases its extension is not created: their DDL entries carry no object type and no object name (the event triggers that supply them come with CREATE EXTENSION pgaudit).',
       'pgvigil pgaudit', h.snapshot_at
  FROM pgvigil.pgaudit_health h JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
  CROSS JOIN LATERAL (
    SELECT string_agg(d.datname, ', ' ORDER BY d.datname) AS list
      FROM (SELECT e.datname FROM pgvigil.database_extensions e
             WHERE e.instance_id = h.instance_id AND e.is_present
             GROUP BY e.datname HAVING NOT bool_or(e.name = 'pgaudit')) d) x
 WHERE h.loaded AND h.status = 'ok' AND x.list IS NOT NULL
   AND EXISTS (SELECT 1 FROM pgvigil.pgaudit_settings s CROSS JOIN LATERAL regexp_split_to_table(lower(coalesce(s.value, '')), ',') c(v)
                WHERE s.instance_id = h.instance_id AND s.name = 'pgaudit.log' AND btrim(c.v) IN ('ddl', 'all')
                  AND NOT EXISTS (SELECT 1 FROM regexp_split_to_table(lower(coalesce(s.value, '')), ',') x(v) WHERE btrim(x.v) = '-ddl'))
UNION ALL
-- no statement text: the names the rules match are not read
SELECT h.instance_id, 'info', 'pgaudit.log_statement', 'off', true, 'on', 'all',
       'pgaudit.log_statement off: the entries carry no statement, so no role, grantee or setting is named and the rules that need a name (the SET rules, any rule with an object pattern) cannot fire.',
       'pgvigil pgaudit', h.snapshot_at
  FROM pgvigil.pgaudit_health h JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
 WHERE h.loaded AND h.status = 'ok'
   AND EXISTS (SELECT 1 FROM pgvigil.pgaudit_settings s WHERE s.instance_id = h.instance_id AND s.scope = 'server'
                  AND s.name = 'pgaudit.log_statement' AND lower(s.value) IN ('off', 'false', 'no', '0'))
UNION ALL
-- a line that has pgaudit's form and is not pgaudit's (a session's own RAISE)
SELECT st.instance_id, 'warning', 'imitated audit line', coalesce(st.forged_by, '?'), true, 'find who raised it', 'all',
       format('A server-log line has the form of a pgaudit entry and is not one (it carries the CONTEXT of a session''s own RAISE): newest %s by %s. It is neither stored nor counted as an audit entry.',
              to_char(st.forged_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC', coalesce(st.forged_by, '?')),
       'pgvigil pgaudit', st.forged_at
  FROM pgvigil.pgaudit_state st JOIN pgvigil.instances i ON i.instance_id = st.instance_id AND i.is_active
 WHERE st.forged_at > now() - interval '1 day'
UNION ALL
-- the rules that fire
SELECT r.instance_id, r.severity, 'audit rule: ' || r.name,
       -- one wording whatever the count: an alert's key replaces the numbers, so the words must not change with them
       CASE r.what WHEN 'AUTH_FAIL' THEN 'failed sign-ins' ELSE r.what || ' entries' END || ': ' || r.hits
         || ' in the last ' || CASE WHEN r.window_minutes = 60 THEN 'hour'
                                    WHEN r.window_minutes % 1440 = 0 AND r.window_minutes > 1440 THEN (r.window_minutes / 1440) || ' days'
                                    WHEN r.window_minutes % 60 = 0 THEN (r.window_minutes / 60) || ' hours'
                                    WHEN r.window_minutes = 1 THEN 'minute'
                                    ELSE r.window_minutes || ' minutes' END,
       true, 'review them on the Audit page', 'all',
       'Newest first: ' || array_to_string(r.sample, '; ') || CASE WHEN r.hits > 5 THEN format(' ... and %s more', r.hits - 5) ELSE '' END,
       'pgvigil pgaudit', r.last_at
  FROM pgvigil.pgaudit_rule_hits r
 WHERE r.hits >= r.min_count;
