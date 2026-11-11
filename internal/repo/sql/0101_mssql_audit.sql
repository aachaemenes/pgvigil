-- 0101: SQL Server Audit (the mssql_audit collection, internal/mssql/audit.go, docs/sqlserver-audit.md).
--
-- The collector reads the server audits a DBA defined and never creates, alters, starts, stops or drops one. It
-- stores the audit HEALTH (every audit with its state and target, the server and database audit specifications
-- with their actions) and the audit EVENTS of every audit that writes to a file, read forward from a cursor
-- (pgvigil.mssql_cursor of 0065, source 'audit:<audit GUID>').
--
--   mssql_audit_read     per instance: what the last read could read - the audit list, the state view, the
--                        specifications, how many databases were asked for theirs, whether the login may read the
--                        audit files and the right the server asks for it, whether statement text is stored.
--   mssql_audit          per instance and audit: state (started, stopped, failed, shutting down, enabled = switched
--                        on with the state view not readable, unknown), since when, the target (file, application
--                        log, security log, url, external monitor), on-failure action, queue delay, the file
--                        settings, the file written now and its size; read_state says what became of its events
--                        (read | no right | not readable | not read | error) with read_note, and last_event_at is
--                        the newest event read. An audit gone from the server is kept, is_present false, 30 days.
--   mssql_audit_spec     per instance, scope (server | database), database and name: the audit it belongs to (by
--                        GUID), switched on or off, its actions as JSON (action, class, object, principal, result,
--                        is_group) and their names as an array.
--   mssql_audit_events   monthly partitions by the event's time; one row per event that is kept: failed sign-ins,
--                        role membership, permission, login and password (principal), DDL and audit changes - who,
--                        when, from where, on what. statement holds text only on the instance's opt-in (audit_text)
--                        and then under its query_text policy; reason is the server's own message of a failed
--                        sign-in or the action of an audit session change, never statement text.
--   mssql_audit_counts   monthly partitions by the hour; everything else (reads, writes, executions, sign-ins,
--                        batches, transactions, DDL in tempdb, events over a read's row cap) counted per hour,
--                        audit, action, login, database, schema, object and outcome.
--   mssql_audit_status   the Summary cell 'audit' (the columns of mssql_health_status).
--   mssql_audit_findings instance_id, severity, check_name, object, at, detail (the arm for pgvigil.findings and
--                        the two partition parents for purge() are the join's):
--     'an audit is defined and not started'           warning, per audit
--     'an audit failed'                               critical, per audit (a runtime or target failure, or switched
--                                                     on and not among the audits the server runs)
--     'an audit specification is switched off'        warning, per specification whose audit is started
--     'an audit specification has no audit on this server'   warning (a restored or failed-over database: its
--                                                     specification names an audit GUID the server does not have)
--     'no audit covers sign-in failures'              info, per instance
--     'failed sign-ins in the last hour'              10 or more: warning; 100 or more: critical
--     'an audit or its specification was changed'     in the last hour: warning; an audit shut down on failure: critical
--     'a server role gained a member'                 in the last hour: warning
--     'security changes in the last hour'             role, permission and principal events: info
--   The health findings need a read in the last 20 minutes: a server not read lately fires none of them.
--
-- An event is stored once: its key is the audit file's name, the buffer's offset and the record's place in the
-- buffer, and a second import of the same record does nothing. A batch is one call: its events, its counts and its
-- cursor row are stored together or not at all, so a count is never added twice.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_audit_read (
  instance_id        int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at        timestamptz NOT NULL,
  defs_read          boolean NOT NULL,   -- sys.server_audits was readable: the list of audits is complete
  state_read         boolean NOT NULL,   -- sys.dm_server_audit_status answered
  specs_read         boolean NOT NULL,
  db_specs_right     boolean NOT NULL,   -- the login may list every database's specification
  events_right       text,               -- the right the server asks for the audit files
  events_readable    boolean NOT NULL,
  text_stored        boolean NOT NULL,   -- audit_text is on and query_text is not none
  databases_read     int NOT NULL DEFAULT 0,
  databases_skipped  int NOT NULL DEFAULT 0,
  skipped_names      text,               -- the first databases not asked (no access, or the run's time was up)
  note               text
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_audit (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name                text NOT NULL,
  audit_guid          text,
  audit_id            int,
  snapshot_at         timestamptz NOT NULL,
  is_present          boolean NOT NULL DEFAULT true,
  state               text NOT NULL CHECK (state IN ('started', 'stopped', 'failed', 'shutting down', 'enabled', 'unknown')),
  state_since         timestamptz NOT NULL,
  is_enabled          boolean,
  status              text,              -- sys.dm_server_audit_status' status_desc; NULL: no row there
  status_at           timestamptz,
  target              text,              -- file | application log | security log | url | external monitor
  type                text,              -- FL | AL | SL | UL | EM
  on_failure          text,
  queue_delay_ms      bigint,
  predicate           text,
  created_at          timestamptz,
  modified_at         timestamptz,
  max_file_size_mb    bigint,
  max_rollover_files  bigint,
  max_files           bigint,
  reserve_disk_space  boolean,
  log_file_path       text,
  log_file_name       text,
  current_file        text,
  file_size_bytes     bigint,
  read_state          text,              -- read | no right | not readable | not read | error
  read_note           text,
  new_events          bigint,            -- events the last read stored as rows
  counted_events      bigint,            -- events the last read counted
  last_event_at       timestamptz,
  PRIMARY KEY (instance_id, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_audit_spec (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  scope          text NOT NULL CHECK (scope IN ('server', 'database')),
  database_name  text NOT NULL DEFAULT '',   -- '' for a server specification
  name           text NOT NULL,
  audit_guid     text,
  is_enabled     boolean NOT NULL,
  created        text,                       -- the server's own clock, no zone
  modified       text,
  actions        jsonb NOT NULL DEFAULT '[]',
  action_names   text[] NOT NULL DEFAULT '{}',
  snapshot_at    timestamptz NOT NULL,
  is_present     boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, scope, database_name, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_audit_events (
  instance_id    int NOT NULL,
  event_at       timestamptz NOT NULL,
  event_key      text NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  audit_name     text,
  audit_guid     text,
  category       text NOT NULL,     -- failed sign-in | role | permission | principal | ddl | audit
  action_id      text NOT NULL,
  action         text,
  class_type     text,
  class_name     text,
  succeeded      boolean,
  login_name     text,
  session_login  text,              -- the session's login where it differs (EXECUTE AS)
  database_user  text,
  target_login   text,
  target_user    text,
  database_name  text,
  schema_name    text,
  object_name    text,
  client_ip      text,
  application    text,
  host           text,
  session_id     int,
  reason         text,
  error_number   int,
  error_state    int,
  statement      text,
  PRIMARY KEY (instance_id, event_at, event_key)
) PARTITION BY RANGE (event_at);
CREATE INDEX IF NOT EXISTS mssql_audit_events_cat_idx ON pgvigil.mssql_audit_events (instance_id, category, event_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_audit_counts (
  instance_id    int NOT NULL,
  hour_at        timestamptz NOT NULL,
  count_key      text NOT NULL,     -- md5 of the columns below it: one row per hour and combination
  audit_name     text NOT NULL,
  category       text NOT NULL,     -- read | write | execute | sign-in | sign-out | batch | transaction | other, or a kept category
  action_id      text NOT NULL,
  action         text,
  login_name     text NOT NULL DEFAULT '',
  database_name  text NOT NULL DEFAULT '',
  schema_name    text NOT NULL DEFAULT '',
  object_name    text NOT NULL DEFAULT '',
  succeeded      boolean NOT NULL,
  n              bigint NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  PRIMARY KEY (instance_id, hour_at, count_key)
) PARTITION BY RANGE (hour_at);

-- payload rows by kind: audit_event and audit_count with the batch's cursor row (one call per batch), then once
-- per run: read (what the run could read), audit (one per audit), spec (one per specification). A collector_error
-- row is the run's note and stores nothing.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_audit(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_m      record;
  v_t      record;
  v_read   jsonb;
  v_defs   boolean;
  v_state  boolean;
  v_dbs    text[];
  v_skip   text[];
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_audit: instance % is not a SQL Server instance', p_instance_id;
  END IF;

  -- the two partitioned parents in name order (the order purge() drops in): the months this payload needs are
  -- opened, then the parent is locked for the writes below (0065's rule)
  FOR v_t IN
    SELECT * FROM (VALUES ('mssql_audit_counts', 'audit_count', 'hour_at'), ('mssql_audit_events', 'audit_event', 'event_at')) x(tbl, kind, col)
     ORDER BY tbl
  LOOP
    FOR v_m IN
      SELECT DISTINCT date_trunc('month', (r->>v_t.col)::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS month_at
        FROM jsonb_array_elements(p_payload) r
       WHERE r->>'kind' = v_t.kind AND r->>v_t.col IS NOT NULL
       ORDER BY 1
    LOOP
      PERFORM pgvigil.mssql_event_partition(v_t.tbl, v_m.month_at);
    END LOOP;
    EXECUTE format('LOCK TABLE ONLY pgvigil.%I IN ROW EXCLUSIVE MODE', v_t.tbl);
  END LOOP;

  INSERT INTO pgvigil.mssql_audit_events (instance_id, event_at, event_key, snapshot_at, audit_name, audit_guid, category,
      action_id, action, class_type, class_name, succeeded, login_name, session_login, database_user, target_login,
      target_user, database_name, schema_name, object_name, client_ip, application, host, session_id, reason,
      error_number, error_state, statement)
  SELECT p_instance_id, (r->>'event_at')::timestamptz, r->>'event_key', p_snapshot_at, r->>'audit_name', r->>'audit_guid',
         r->>'category', r->>'action_id', r->>'action', r->>'class_type', r->>'class_name', (r->>'succeeded')::boolean,
         r->>'login_name', r->>'session_login', r->>'database_user', r->>'target_login', r->>'target_user',
         r->>'database_name', r->>'schema_name', r->>'object_name', r->>'client_ip', r->>'application', r->>'host',
         (r->>'session_id')::int, r->>'reason', (r->>'error_number')::int, (r->>'error_state')::int, r->>'statement'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'audit_event' AND r->>'event_at' IS NOT NULL AND r->>'event_key' IS NOT NULL
     AND r->>'category' IS NOT NULL AND r->>'action_id' IS NOT NULL
  ON CONFLICT DO NOTHING;

  -- the counts add up: a batch is imported once (its cursor moves in this same call)
  INSERT INTO pgvigil.mssql_audit_counts AS c (instance_id, hour_at, count_key, audit_name, category, action_id, action,
      login_name, database_name, schema_name, object_name, succeeded, n, snapshot_at)
  SELECT p_instance_id, x.hour_at,
         md5(concat_ws(E'\x1f', x.audit_name, x.category, x.action_id, x.login_name, x.database_name, x.schema_name, x.object_name, x.succeeded::text)),
         x.audit_name, x.category, x.action_id, max(x.action), x.login_name, x.database_name, x.schema_name, x.object_name,
         x.succeeded, sum(x.n), p_snapshot_at
    FROM (SELECT date_trunc('hour', (r->>'hour_at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS hour_at,
                 coalesce(r->>'audit_name', '') AS audit_name, coalesce(r->>'category', 'other') AS category,
                 r->>'action_id' AS action_id, r->>'action' AS action, coalesce(r->>'login_name', '') AS login_name,
                 coalesce(r->>'database_name', '') AS database_name, coalesce(r->>'schema_name', '') AS schema_name,
                 coalesce(r->>'object_name', '') AS object_name, coalesce((r->>'succeeded')::boolean, true) AS succeeded,
                 (r->>'n')::bigint AS n
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'audit_count' AND r->>'hour_at' IS NOT NULL AND r->>'action_id' IS NOT NULL
             AND (r->>'n')::bigint > 0) x
   GROUP BY x.hour_at, x.audit_name, x.category, x.action_id, x.login_name, x.database_name, x.schema_name, x.object_name, x.succeeded
  ON CONFLICT (instance_id, hour_at, count_key) DO UPDATE SET n = c.n + EXCLUDED.n, snapshot_at = EXCLUDED.snapshot_at;

  INSERT INTO pgvigil.mssql_cursor AS c (instance_id, source, file_name, file_offset, last_event_at, last_seq, updated_at)
  SELECT DISTINCT ON (r->>'source') p_instance_id, r->>'source', r->>'file_name', (r->>'file_offset')::bigint,
         (r->>'last_event_at')::timestamptz, (r->>'last_seq')::bigint, now()
    FROM jsonb_array_elements(p_payload) WITH ORDINALITY AS t(r, n)
   WHERE r->>'kind' = 'cursor' AND r->>'source' IS NOT NULL
   ORDER BY r->>'source', n DESC
  ON CONFLICT (instance_id, source) DO UPDATE SET
      file_name = EXCLUDED.file_name, file_offset = EXCLUDED.file_offset, last_event_at = EXCLUDED.last_event_at,
      last_seq = EXCLUDED.last_seq, updated_at = EXCLUDED.updated_at;

  -- the health: only the run's last call carries it, and a read older than the one stored changes nothing
  SELECT r INTO v_read FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'read' LIMIT 1;
  IF v_read IS NULL THEN
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_audit_read x WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_snapshot_at) THEN
    RETURN;
  END IF;
  v_defs  := coalesce((v_read->>'defs_read')::boolean, false);
  v_state := coalesce((v_read->>'state_read')::boolean, false);
  v_dbs   := ARRAY(SELECT jsonb_array_elements_text(coalesce(nullif(v_read->'databases_read', 'null'::jsonb), '[]'::jsonb)));
  v_skip  := ARRAY(SELECT jsonb_array_elements_text(coalesce(nullif(v_read->'databases_skipped', 'null'::jsonb), '[]'::jsonb)));

  INSERT INTO pgvigil.mssql_audit_read AS x (instance_id, snapshot_at, defs_read, state_read, specs_read, db_specs_right,
      events_right, events_readable, text_stored, databases_read, databases_skipped, skipped_names, note)
  VALUES (p_instance_id, p_snapshot_at, v_defs, v_state, coalesce((v_read->>'specs_read')::boolean, false),
          coalesce((v_read->>'db_specs_right')::boolean, false), v_read->>'events_right',
          coalesce((v_read->>'events_readable')::boolean, false), coalesce((v_read->>'text_stored')::boolean, false),
          coalesce(cardinality(v_dbs), 0), coalesce(cardinality(v_skip), 0),
          nullif(array_to_string(v_skip[1:10], ', '), ''), v_read->>'note')
  ON CONFLICT (instance_id) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, defs_read = EXCLUDED.defs_read, state_read = EXCLUDED.state_read,
      specs_read = EXCLUDED.specs_read, db_specs_right = EXCLUDED.db_specs_right, events_right = EXCLUDED.events_right,
      events_readable = EXCLUDED.events_readable, text_stored = EXCLUDED.text_stored,
      databases_read = EXCLUDED.databases_read, databases_skipped = EXCLUDED.databases_skipped,
      skipped_names = EXCLUDED.skipped_names, note = EXCLUDED.note;

  -- the audits. A read that could not list them (no VIEW ANY DEFINITION) knows the started ones by the state view
  -- alone: it keeps the definition an earlier read stored and marks nothing absent. A read without the state view
  -- keeps the stored status columns.
  INSERT INTO pgvigil.mssql_audit AS a (instance_id, name, audit_guid, audit_id, snapshot_at, is_present, state, state_since,
      is_enabled, status, status_at, target, type, on_failure, queue_delay_ms, predicate, created_at, modified_at,
      max_file_size_mb, max_rollover_files, max_files, reserve_disk_space, log_file_path, log_file_name, current_file,
      file_size_bytes, read_state, read_note, new_events, counted_events, last_event_at)
  SELECT p_instance_id, r->>'name', r->>'audit_guid', (r->>'audit_id')::int, p_snapshot_at, true, r->>'state', p_snapshot_at,
         (r->>'is_enabled')::boolean, r->>'status', (r->>'status_at')::timestamptz, r->>'target', r->>'type', r->>'on_failure',
         (r->>'queue_delay_ms')::bigint, r->>'predicate', (r->>'created_at')::timestamptz, (r->>'modified_at')::timestamptz,
         (r->>'max_file_size_mb')::bigint, (r->>'max_rollover_files')::bigint, (r->>'max_files')::bigint,
         (r->>'reserve_disk_space')::int::boolean, r->>'log_file_path', r->>'log_file_name', r->>'current_file',
         (r->>'file_size_bytes')::bigint, r->>'read_state', r->>'read_note', (r->>'new_events')::bigint,
         (r->>'counted_events')::bigint, (r->>'last_event_at')::timestamptz
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'audit' AND r->>'name' IS NOT NULL AND r->>'state' IS NOT NULL
  ON CONFLICT (instance_id, name) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, is_present = true, state = EXCLUDED.state,
      state_since = CASE WHEN a.state = EXCLUDED.state AND a.is_present THEN a.state_since ELSE EXCLUDED.snapshot_at END,
      audit_id = EXCLUDED.audit_id,
      audit_guid = CASE WHEN v_defs THEN EXCLUDED.audit_guid ELSE a.audit_guid END,
      is_enabled = CASE WHEN v_defs THEN EXCLUDED.is_enabled ELSE a.is_enabled END,
      target = CASE WHEN v_defs THEN EXCLUDED.target ELSE a.target END,
      type = CASE WHEN v_defs THEN EXCLUDED.type ELSE a.type END,
      on_failure = CASE WHEN v_defs THEN EXCLUDED.on_failure ELSE a.on_failure END,
      queue_delay_ms = CASE WHEN v_defs THEN EXCLUDED.queue_delay_ms ELSE a.queue_delay_ms END,
      predicate = CASE WHEN v_defs THEN EXCLUDED.predicate ELSE a.predicate END,
      created_at = CASE WHEN v_defs THEN EXCLUDED.created_at ELSE a.created_at END,
      modified_at = CASE WHEN v_defs THEN EXCLUDED.modified_at ELSE a.modified_at END,
      max_file_size_mb = CASE WHEN v_defs THEN EXCLUDED.max_file_size_mb ELSE a.max_file_size_mb END,
      max_rollover_files = CASE WHEN v_defs THEN EXCLUDED.max_rollover_files ELSE a.max_rollover_files END,
      max_files = CASE WHEN v_defs THEN EXCLUDED.max_files ELSE a.max_files END,
      reserve_disk_space = CASE WHEN v_defs THEN EXCLUDED.reserve_disk_space ELSE a.reserve_disk_space END,
      log_file_path = CASE WHEN v_defs THEN EXCLUDED.log_file_path ELSE a.log_file_path END,
      log_file_name = CASE WHEN v_defs THEN EXCLUDED.log_file_name ELSE a.log_file_name END,
      status = CASE WHEN v_state THEN EXCLUDED.status ELSE a.status END,
      status_at = CASE WHEN v_state THEN EXCLUDED.status_at ELSE a.status_at END,
      current_file = CASE WHEN v_state THEN EXCLUDED.current_file ELSE a.current_file END,
      file_size_bytes = CASE WHEN v_state THEN EXCLUDED.file_size_bytes ELSE a.file_size_bytes END,
      read_state = EXCLUDED.read_state, read_note = EXCLUDED.read_note, new_events = EXCLUDED.new_events,
      counted_events = EXCLUDED.counted_events,
      last_event_at = greatest(a.last_event_at, EXCLUDED.last_event_at);

  IF v_defs THEN
    UPDATE pgvigil.mssql_audit a SET is_present = false, snapshot_at = p_snapshot_at
     WHERE a.instance_id = p_instance_id AND a.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'audit' AND r->>'name' = a.name);
  END IF;

  -- the specifications: the server's when they were read; a database's when that database was asked in this run. A
  -- database neither asked nor skipped is gone (dropped, offline): its specification goes absent.
  INSERT INTO pgvigil.mssql_audit_spec AS s (instance_id, scope, database_name, name, audit_guid, is_enabled, created, modified,
      actions, action_names, snapshot_at, is_present)
  SELECT p_instance_id, r->>'scope', coalesce(r->>'database_name', ''), r->>'name', r->>'audit_guid',
         coalesce((r->>'is_enabled')::boolean, false), r->>'created', r->>'modified',
         coalesce(nullif(r->'actions', 'null'::jsonb), '[]'::jsonb),
         ARRAY(SELECT x->>'action' FROM jsonb_array_elements(coalesce(nullif(r->'actions', 'null'::jsonb), '[]'::jsonb)) x
                WHERE x->>'action' IS NOT NULL ORDER BY 1),
         p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'spec' AND r->>'scope' IN ('server', 'database') AND r->>'name' IS NOT NULL
  ON CONFLICT (instance_id, scope, database_name, name) DO UPDATE SET
      audit_guid = EXCLUDED.audit_guid, is_enabled = EXCLUDED.is_enabled, created = EXCLUDED.created,
      modified = EXCLUDED.modified, actions = EXCLUDED.actions, action_names = EXCLUDED.action_names,
      snapshot_at = EXCLUDED.snapshot_at, is_present = true;

  IF coalesce((v_read->>'specs_read')::boolean, false) THEN
    UPDATE pgvigil.mssql_audit_spec s SET is_present = false, snapshot_at = p_snapshot_at
     WHERE s.instance_id = p_instance_id AND s.is_present AND s.scope = 'server'
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                        WHERE r->>'kind' = 'spec' AND r->>'scope' = 'server' AND r->>'name' = s.name);
  END IF;
  IF coalesce((v_read->>'databases_listed')::boolean, false) THEN
    UPDATE pgvigil.mssql_audit_spec s SET is_present = false, snapshot_at = p_snapshot_at
     WHERE s.instance_id = p_instance_id AND s.is_present AND s.scope = 'database'
       AND NOT (s.database_name = ANY (v_skip))
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                        WHERE r->>'kind' = 'spec' AND r->>'scope' = 'database'
                          AND coalesce(r->>'database_name', '') = s.database_name AND r->>'name' = s.name);
  END IF;

  -- what is gone from the server for 30 days leaves the two small tables (the event and count partitions go with
  -- purge())
  DELETE FROM pgvigil.mssql_audit a
   WHERE a.instance_id = p_instance_id AND NOT a.is_present AND a.snapshot_at < p_snapshot_at - interval '30 days';
  DELETE FROM pgvigil.mssql_audit_spec s
   WHERE s.instance_id = p_instance_id AND NOT s.is_present AND s.snapshot_at < p_snapshot_at - interval '30 days';
END $$;

-- The Summary cell 'audit', one row per instance that was read: critical = an audit failed, warning = an audit is
-- defined and not started; value the cell's words; detail one sentence per audit and what the login could not read.
CREATE OR REPLACE VIEW pgvigil.mssql_audit_status AS
SELECT r.instance_id, 'audit'::text AS key, true AS sampled,
       (coalesce(a.failed, 0) > 0)::int AS critical,
       (coalesce(a.failed, 0) = 0 AND coalesce(a.stopped, 0) > 0)::int AS warning,
       CASE WHEN coalesce(a.n, 0) = 0 THEN CASE WHEN r.defs_read THEN 'none' ELSE 'not listed' END
            WHEN a.started = a.n THEN a.n || ' started'
            ELSE a.started || ' of ' || a.n || ' started' END
         || CASE WHEN coalesce(a.unread, 0) > 0 THEN ', events not read' ELSE '' END AS value,
       coalesce(a.lines, '{}'::text[])
         || CASE WHEN NOT r.defs_read THEN ARRAY['the login cannot list the audits (VIEW ANY DEFINITION): only the audits the server runs now are known'] ELSE '{}'::text[] END
         || CASE WHEN coalesce(a.n, 0) = 0 AND r.defs_read THEN ARRAY['no server audit is defined on this server'] ELSE '{}'::text[] END
         || CASE WHEN coalesce(a.unread, 0) > 0
                 THEN ARRAY['the events of ' || a.unread || ' file audit(s) are not read: the login lacks ' || coalesce(r.events_right, 'the right')
                            || '. The health above is read; this is not a failure of the collection']
                 ELSE '{}'::text[] END
         || ARRAY['read ' || to_char(r.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'] AS detail
  FROM pgvigil.mssql_audit_read r
  LEFT JOIN (
    SELECT x.instance_id, count(*) AS n, count(*) FILTER (WHERE x.state = 'started') AS started,
           count(*) FILTER (WHERE x.state = 'stopped') AS stopped, count(*) FILTER (WHERE x.state = 'failed') AS failed,
           count(*) FILTER (WHERE x.read_state = 'no right') AS unread,
           array_agg(x.name || ': ' || x.state || coalesce(', ' || x.target, '') || coalesce(', on failure ' || lower(x.on_failure), '')
                     || coalesce(', last event ' || to_char(x.last_event_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '')
                     ORDER BY x.name) AS lines
      FROM pgvigil.mssql_audit x
     WHERE x.is_present
     GROUP BY x.instance_id
  ) a USING (instance_id);

CREATE OR REPLACE VIEW pgvigil.mssql_audit_findings AS
WITH fresh AS (
  SELECT r.* FROM pgvigil.mssql_audit_read r WHERE r.snapshot_at > now() - interval '20 minutes'
), au AS (
  SELECT a.* FROM pgvigil.mssql_audit a JOIN fresh f USING (instance_id) WHERE a.is_present
), sp AS (
  SELECT s.* FROM pgvigil.mssql_audit_spec s JOIN fresh f USING (instance_id) WHERE s.is_present
), ev AS (
  SELECT e.* FROM pgvigil.mssql_audit_events e WHERE e.event_at > now() - interval '1 hour'
), failed AS (
  SELECT e.instance_id, count(*) AS n, count(DISTINCT e.login_name) AS logins, max(e.event_at) AS last_at,
         (array_agg(e.login_name ORDER BY e.event_at DESC))[1] AS last_login,
         (array_agg(e.client_ip ORDER BY e.event_at DESC))[1] AS last_ip,
         (SELECT x.login_name || ' (' || count(*) || ')'
            FROM ev x WHERE x.instance_id = e.instance_id AND x.category = 'failed sign-in'
           GROUP BY x.login_name ORDER BY count(*) DESC, x.login_name LIMIT 1) AS top_login
    FROM ev e
   WHERE e.category = 'failed sign-in'
   GROUP BY e.instance_id
), changed AS (
  SELECT e.instance_id, count(*) AS n, max(e.event_at) AS last_at, bool_or(e.action_id = 'AUSF') AS shut,
         string_agg(DISTINCT coalesce(nullif(e.object_name, ''), e.audit_name), ', ') AS objects,
         (array_agg(coalesce(e.login_name, '?') || ': ' || coalesce(e.action, e.action_id) || ' ' || lower(coalesce(e.class_name, ''))
                    || coalesce(' ' || nullif(e.object_name, ''), '') || coalesce(' (' || e.reason || ')', '')
                    ORDER BY e.event_at DESC))[1] AS last_change
    FROM ev e
   WHERE e.category = 'audit'
     AND (e.action_id IN ('CR', 'AL', 'DR', 'AUSF') OR (e.action_id = 'AUSC' AND e.reason ILIKE '%disabled%'))
   GROUP BY e.instance_id
), sec AS (
  SELECT e.instance_id, count(*) AS n, max(e.event_at) AS last_at,
         count(*) FILTER (WHERE e.category = 'role') AS roles, count(*) FILTER (WHERE e.category = 'permission') AS perms,
         count(*) FILTER (WHERE e.category = 'principal') AS principals
    FROM ev e
   WHERE e.category IN ('role', 'permission', 'principal')
   GROUP BY e.instance_id
)
SELECT au.instance_id, 'warning'::text AS severity, 'an audit is defined and not started'::text AS check_name,
       au.name AS object, au.snapshot_at AS at,
       'the server audit ' || au.name || ' is defined and switched off since ' || to_char(au.state_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI')
         || ' UTC: nothing its specifications name is recorded. ALTER SERVER AUDIT ' || quote_ident(au.name) || ' WITH (STATE = ON) is the DBA''s step' AS detail
  FROM au WHERE au.state = 'stopped'
UNION ALL
SELECT au.instance_id, 'critical', 'an audit failed', au.name, au.snapshot_at,
       'the server audit ' || au.name || ' is switched on and not recording: '
         || coalesce('its state is ' || au.status, 'it is not among the audits the server runs')
         || coalesce(' (target: ' || au.target || coalesce(', ' || au.log_file_path, '') || ')', '')
         || coalesce('; on failure the server is set to ' || lower(au.on_failure), '')
  FROM au WHERE au.state = 'failed'
UNION ALL
SELECT sp.instance_id, 'warning', 'an audit specification is switched off',
       CASE WHEN sp.scope = 'database' THEN sp.database_name || ': ' ELSE '' END || sp.name, sp.snapshot_at,
       'the ' || sp.scope || ' audit specification ' || sp.name || CASE WHEN sp.scope = 'database' THEN ' of ' || sp.database_name ELSE '' END
         || ' is defined and switched off while its audit ' || au.name || ' is started: its ' || cardinality(sp.action_names)
         || ' action(s) are not recorded'
  FROM sp JOIN au ON au.instance_id = sp.instance_id AND au.audit_guid = sp.audit_guid AND au.state = 'started'
 WHERE NOT sp.is_enabled
UNION ALL
SELECT sp.instance_id, 'warning', 'an audit specification has no audit on this server',
       CASE WHEN sp.scope = 'database' THEN sp.database_name || ': ' ELSE '' END || sp.name, sp.snapshot_at,
       'the ' || sp.scope || ' audit specification ' || sp.name || CASE WHEN sp.scope = 'database' THEN ' of ' || sp.database_name ELSE '' END
         || ' names the audit ' || coalesce(sp.audit_guid, '(none)') || ', which this server does not have (a restored or failed-over database): '
         || 'nothing it names is recorded here until an audit is created with that AUDIT_GUID'
  FROM sp JOIN fresh f USING (instance_id)
 WHERE f.defs_read AND NOT EXISTS (SELECT 1 FROM au WHERE au.instance_id = sp.instance_id AND au.audit_guid = sp.audit_guid)
UNION ALL
SELECT f.instance_id, 'info', 'no audit covers sign-in failures', 'FAILED_LOGIN_GROUP', f.snapshot_at,
       'no started server audit has an enabled specification with FAILED_LOGIN_GROUP: a failed sign-in is recorded '
         || 'only in the error log, and only while the server''s login auditing writes failures there'
  FROM fresh f
 WHERE f.defs_read AND f.specs_read
   AND NOT EXISTS (SELECT 1 FROM sp JOIN au ON au.instance_id = sp.instance_id AND au.audit_guid = sp.audit_guid AND au.state = 'started'
                    WHERE sp.instance_id = f.instance_id AND sp.scope = 'server' AND sp.is_enabled
                      AND 'FAILED_LOGIN_GROUP' = ANY (sp.action_names))
UNION ALL
SELECT x.instance_id, CASE WHEN x.n >= 100 THEN 'critical' ELSE 'warning' END, 'failed sign-ins in the last hour',
       coalesce(x.top_login, 'sign-ins'), x.last_at,
       x.n || ' failed sign-in(s) in the last hour for ' || x.logins || ' login name(s); most for ' || coalesce(x.top_login, '?')
         || '; the last one ' || coalesce(x.last_login, '?') || coalesce(' from ' || x.last_ip, '')
  FROM failed x WHERE x.n >= 10
UNION ALL
SELECT c.instance_id, CASE WHEN c.shut THEN 'critical' ELSE 'warning' END, 'an audit or its specification was changed',
       coalesce(c.objects, 'audit'), c.last_at,
       c.n || ' change(s) of an audit or an audit specification in the last hour' || CASE WHEN c.shut THEN ', an audit shut down on failure among them' ELSE '' END
         || coalesce('; the last one ' || c.last_change, '')
  FROM changed c
UNION ALL
SELECT e.instance_id, 'warning', 'a server role gained a member', coalesce(e.object_name, 'server role'), max(e.event_at),
       count(*) || ' member(s) added to the server role ' || coalesce(e.object_name, '?') || ' in the last hour: '
         || string_agg(DISTINCT coalesce(e.target_login, '?') || ' (by ' || coalesce(e.login_name, '?') || ')', ', ')
  FROM ev e
 WHERE e.category = 'role' AND e.action_id = 'APRL' AND e.class_type = 'SG' AND e.succeeded
 GROUP BY e.instance_id, e.object_name
UNION ALL
SELECT s.instance_id, 'info', 'security changes in the last hour', 'role, permission, principal', s.last_at,
       s.n || ' security change(s) in the last hour: ' || s.roles || ' role membership, ' || s.perms || ' permission, '
         || s.principals || ' login or password'
  FROM sec s;
