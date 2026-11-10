-- 0065: SQL Server Extended Events (the mssql_xe collection).
--
-- The collector reads Extended Events sessions that the server's DBA created from the script `pgvigil mssql-xe
-- -print` writes (docs/sqlserver-xe.md): pgvigil_<install id>_deadlocks, _blocked, _slow and _attention. It never
-- creates, alters, starts, stops or drops a session. It also reads, without touching them, system_health's deadlock
-- reports on a server that has no deadlock session of the product, and AlwaysOn_health where Always On is enabled.
--
--   mssql_cursor           how far each source of an instance was read: the event file and the offset of the last block
--                          read (an event_file target), or the time and sequence of the newest event read (a ring
--                          buffer). One import call stores a batch of events AND moves the cursor, so a batch is stored
--                          once or not at all. Any collection that reads a SQL Server source from a cursor may use it.
--   mssql_xe_state         per instance and capture (deadlocks, blocked, slow, attention, ag): the state as last read
--                          - running (the session is defined and started), stopped (defined, not started) or
--                          not installed (no definition) - with the time the state began and how many reads in a row
--                          have seen it; the session, its target, the buffer's size and use, the events the session
--                          dropped and the events that left a ring buffer before a read (lost_at / lost_events: the
--                          last read that saw a loss); for 'blocked' the server's blocked process threshold.
--   mssql_deadlocks        monthly partitions by the event's time; one row per deadlock: the graph XML whole, the
--                          victim, the processes (session, login, host, program, statement, the object and lock mode
--                          waited on) and the resources as JSON. source says which session it was read from.
--   mssql_blocked_reports  monthly partitions; one row per blocked-process report: the blocked and the blocking
--                          process, the wait resource and time, the blocking process's status and input buffer.
--   mssql_slow_events      monthly partitions; one row per completion over the session's threshold (rpc_completed,
--                          sql_batch_completed) and per statement over it (sql_statement_completed,
--                          sp_statement_completed: SQL Server gives a completion no query hash, so a completion's
--                          hashes are filled from its longest statement). shape_key groups by statement shape.
--   mssql_attentions       monthly partitions; one row per attention (a client cancelled a request or timed out).
--   mssql_ag_events        monthly partitions; AlwaysOn_health's state changes, failover DDL, lease events and
--                          reported errors, each with its time; is_failover marks a role change by failover.
--   mssql_xe_findings      instance_id, severity, check_name, object, at, detail (the UNION arm in pgvigil.findings and
--                          the purge lines for the five partition parents are the wave's join):
--     'deadlocks in the last hour'                 1 to 10: warning; over 10: critical
--     'blocked-process reports naming the same head statement'   2 or more reports in the last hour (warning)
--     'a capture is not installed'                 info, one row per instance, after two reads in a row
--     'a capture is stopped'                       warning, one row per instance, after two reads in a row (the first
--                                                  read after a restart or a failover does not fire it)
--     'the ring buffer dropped events'             a loss seen in the last hour (warning)
--     'an availability replica changed role or state'   in the last hour (warning; a failover: critical)
--   The two capture findings need a state read in the last ten minutes: a server not read lately fires neither.
--
-- An event is stored once: the key is (instance_id, event_at, event_key), event_key being the collector's hash of the
-- event's own XML with a counter for identical events of one block, and a second import of the same event does nothing.
-- A deadlock's key is its time and its graph alone, so the same deadlock read from pgvigil's session and from
-- system_health (the product's session stopped or dropped later) is one row, under the source that stored it first.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_cursor (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  source         text NOT NULL,
  file_name      text,
  file_offset    bigint,
  last_event_at  timestamptz,
  last_seq       bigint,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (instance_id, source)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_state (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  capture          text NOT NULL CHECK (capture IN ('deadlocks', 'blocked', 'slow', 'attention', 'ag')),
  snapshot_at      timestamptz NOT NULL,
  state            text NOT NULL CHECK (state IN ('running', 'stopped', 'not installed')),
  state_since      timestamptz NOT NULL,
  reads_in_state   int NOT NULL DEFAULT 1,
  source           text,              -- product | system_health | AlwaysOn_health: where the capture's events were read
  session_name     text,
  target           text,              -- ring_buffer | event_file
  buffer_kb        bigint,            -- a ring buffer's max_memory, an event file's max_file_size, in KB
  buffer_used_kb   bigint,
  event_count      bigint,            -- events in the ring buffer at the read
  total_processed  bigint,            -- events the ring buffer has taken since the session started
  new_events       bigint,            -- events this read found past the cursor
  dropped_events   bigint,            -- the session's own dropped_event_count plus the ring buffer's droppedCount
  dropped_buffers  bigint,
  truncated        boolean,           -- the ring buffer's XML came back cut
  missed_events    bigint,            -- events that entered and left a ring buffer between two reads
  unknown_events   bigint,            -- events of a name the reader has no parser for (counted, not stored)
  counter          bigint,            -- attention: the event_counter target's count since the session started
  threshold_s      int,               -- blocked: the server's 'blocked process threshold (s)' in use
  lost_at          timestamptz,       -- the last read that saw dropped or missed events
  lost_events      bigint,
  note             text,
  PRIMARY KEY (instance_id, capture)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_deadlocks (
  instance_id       int NOT NULL,
  event_at          timestamptz NOT NULL,
  event_key         text NOT NULL,
  snapshot_at       timestamptz NOT NULL,
  source            text NOT NULL,     -- product | system_health
  session_name      text,
  process_count     int,
  victim_count      int,
  victim_spid       int,
  victim_login      text,
  victim_program    text,
  victim_statement  text,
  database_names    text,
  object_names      text,
  processes         jsonb,
  resources         jsonb,
  graph             text,
  PRIMARY KEY (instance_id, event_at, event_key)
) PARTITION BY RANGE (event_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_blocked_reports (
  instance_id          int NOT NULL,
  event_at             timestamptz NOT NULL,
  event_key            text NOT NULL,
  snapshot_at          timestamptz NOT NULL,
  session_name         text,
  database_name        text,
  wait_resource        text,
  wait_ms              bigint,
  lock_mode            text,
  blocked_spid         int,
  blocked_login        text,
  blocked_host         text,
  blocked_program      text,
  blocked_statement    text,
  blocking_spid        int,
  blocking_status      text,
  blocking_trancount   int,
  blocking_login       text,
  blocking_host        text,
  blocking_program     text,
  blocking_statement   text,          -- the blocking process's input buffer: the head's last statement
  blocking_last_batch  text,          -- lastbatchstarted as the report gives it: the server's own clock, no zone
  head_key             text,          -- a hash of the blocking statement: the group of the Blocked reports tab
  report               text,
  PRIMARY KEY (instance_id, event_at, event_key)
) PARTITION BY RANGE (event_at);
CREATE INDEX IF NOT EXISTS mssql_blocked_reports_head_idx ON pgvigil.mssql_blocked_reports (instance_id, head_key, event_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_slow_events (
  instance_id      int NOT NULL,
  event_at         timestamptz NOT NULL,
  event_key        text NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  session_name     text,
  event_name       text NOT NULL,     -- rpc_completed | sql_batch_completed | sql_statement_completed | sp_statement_completed
  duration_ms      numeric,
  cpu_ms           numeric,
  logical_reads    bigint,
  physical_reads   bigint,
  writes           bigint,
  row_count        bigint,
  result           text,
  statement        text,
  object_name      text,
  login_name       text,
  host_name        text,
  program_name     text,
  database_name    text,
  session_id       int,
  query_hash       text,              -- 0x and 16 hex digits, as sys.dm_exec_query_stats and Query Store print it
  query_plan_hash  text,
  shape_key        text,
  shape            text,
  PRIMARY KEY (instance_id, event_at, event_key)
) PARTITION BY RANGE (event_at);
CREATE INDEX IF NOT EXISTS mssql_slow_events_shape_idx ON pgvigil.mssql_slow_events (instance_id, shape_key, event_at);
CREATE INDEX IF NOT EXISTS mssql_slow_events_session_idx ON pgvigil.mssql_slow_events (instance_id, session_id, event_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_attentions (
  instance_id     int NOT NULL,
  event_at        timestamptz NOT NULL,
  event_key       text NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  session_name    text,
  session_id      int,
  request_id      int,
  interrupt_us    bigint,             -- the event's duration: the time the interrupt itself took, not the request's
  statement       text,
  login_name      text,
  host_name       text,
  program_name    text,
  database_name   text,
  PRIMARY KEY (instance_id, event_at, event_key)
) PARTITION BY RANGE (event_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_ag_events (
  instance_id     int NOT NULL,
  event_at        timestamptz NOT NULL,
  event_key       text NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  event_name      text NOT NULL,
  ag_name         text,
  replica_name    text,
  previous_state  text,
  current_state   text,
  error_number    int,
  severity        int,
  family          text,               -- an error's family: lease | connection | role | data movement | other
  message         text,
  ddl_action      text,
  ddl_phase       text,
  statement       text,
  is_failover     boolean NOT NULL DEFAULT false,
  PRIMARY KEY (instance_id, event_at, event_key)
) PARTITION BY RANGE (event_at);

-- the cursor of one source (no row: never read). Named import_*: the role contract (apply_roles) makes every import_*
-- function the collector's door (it runs as the owner and pgvigil_collector may call it), so the collector reads its
-- cursor through it without any right on the table.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_cursor(p_instance_id int, p_source text,
  OUT file_name text, OUT file_offset bigint, OUT last_event_at timestamptz, OUT last_seq bigint)
RETURNS SETOF record LANGUAGE sql STABLE AS $$
  SELECT c.file_name, c.file_offset, c.last_event_at, c.last_seq
    FROM pgvigil.mssql_cursor c WHERE c.instance_id = p_instance_id AND c.source = p_source
$$;

-- One monthly partition of an event table, by the EVENT's month (ensure_month_partition's naming, so purge() drops it
-- by its name; the parent's primary key and indexes come with the partition). Month boundaries are UTC.
CREATE OR REPLACE FUNCTION pgvigil.mssql_event_partition(p_table text, p_at timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_from timestamp := date_trunc('month', p_at AT TIME ZONE 'UTC');
  v_to   timestamp := v_from + interval '1 month';
  v_name text := p_table || '_' || to_char(v_from, 'YYYYMM');
BEGIN
  IF to_regclass('pgvigil.' || quote_ident(v_name)) IS NOT NULL THEN
    RETURN;
  END IF;
  BEGIN
    EXECUTE format('CREATE TABLE pgvigil.%I PARTITION OF pgvigil.%I FOR VALUES FROM (%L) TO (%L)',
                   v_name, p_table, v_from AT TIME ZONE 'UTC', v_to AT TIME ZONE 'UTC');
  EXCEPTION WHEN duplicate_table THEN
    NULL;  -- another importer made it first
  END;
END $$;

-- payload rows by kind: state (one per capture and read), cursor (one per source and batch), deadlock, blocked, slow,
-- attention, ag_event; a collector_error row is the run's note and stores nothing. A batch is one call: its events
-- and its cursor row are stored together or not at all.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_xe(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_m record;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_xe: instance % is not a SQL Server instance', p_instance_id;
  END IF;

  FOR v_m IN
    SELECT DISTINCT CASE r->>'kind' WHEN 'deadlock' THEN 'mssql_deadlocks' WHEN 'blocked' THEN 'mssql_blocked_reports'
                                    WHEN 'slow' THEN 'mssql_slow_events' WHEN 'attention' THEN 'mssql_attentions'
                                    ELSE 'mssql_ag_events' END AS tbl,
           date_trunc('month', (r->>'event_at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS month_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' IN ('deadlock', 'blocked', 'slow', 'attention', 'ag_event') AND r->>'event_at' IS NOT NULL
     ORDER BY 1, 2
  LOOP
    PERFORM pgvigil.mssql_event_partition(v_m.tbl, v_m.month_at);
  END LOOP;
  -- The five parents are taken here in the order the loop opens their months (by name). Opening a month takes
  -- ACCESS EXCLUSIVE on a parent; the inserts below go in another order, and two instances' imports could each
  -- hold one parent and ask for the other at a month's first event (seen on import_mssql_storage, same shape).
  LOCK TABLE pgvigil.mssql_ag_events, pgvigil.mssql_attentions, pgvigil.mssql_blocked_reports, pgvigil.mssql_deadlocks,
             pgvigil.mssql_slow_events IN ROW EXCLUSIVE MODE;

  INSERT INTO pgvigil.mssql_deadlocks (instance_id, event_at, event_key, snapshot_at, source, session_name, process_count,
      victim_count, victim_spid, victim_login, victim_program, victim_statement, database_names, object_names, processes,
      resources, graph)
  SELECT p_instance_id, (r->>'event_at')::timestamptz, r->>'event_key', p_snapshot_at, coalesce(r->>'source', 'product'),
         r->>'session_name', (r->>'process_count')::int, (r->>'victim_count')::int, (r->>'victim_spid')::int, r->>'victim_login',
         r->>'victim_program', r->>'statement', r->>'database_names', r->>'object_names', r->'processes', r->'resources', r->>'graph'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'deadlock' AND r->>'event_at' IS NOT NULL AND r->>'event_key' IS NOT NULL
  ON CONFLICT DO NOTHING;

  INSERT INTO pgvigil.mssql_blocked_reports (instance_id, event_at, event_key, snapshot_at, session_name, database_name,
      wait_resource, wait_ms, lock_mode, blocked_spid, blocked_login, blocked_host, blocked_program, blocked_statement,
      blocking_spid, blocking_status, blocking_trancount, blocking_login, blocking_host, blocking_program,
      blocking_statement, blocking_last_batch, head_key, report)
  SELECT p_instance_id, (r->>'event_at')::timestamptz, r->>'event_key', p_snapshot_at, r->>'session_name', r->>'database_name',
         r->>'wait_resource', (r->>'wait_ms')::bigint, r->>'lock_mode', (r->>'blocked_spid')::int, r->>'blocked_login',
         r->>'blocked_host', r->>'blocked_program', r->>'blocked_statement', (r->>'blocking_spid')::int, r->>'blocking_status',
         (r->>'blocking_trancount')::int, r->>'blocking_login', r->>'blocking_host', r->>'blocking_program', r->>'statement',
         r->>'blocking_last_batch', r->>'head_key', r->>'report'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'blocked' AND r->>'event_at' IS NOT NULL AND r->>'event_key' IS NOT NULL
  ON CONFLICT DO NOTHING;

  INSERT INTO pgvigil.mssql_slow_events (instance_id, event_at, event_key, snapshot_at, session_name, event_name, duration_ms,
      cpu_ms, logical_reads, physical_reads, writes, row_count, result, statement, object_name, login_name, host_name,
      program_name, database_name, session_id, query_hash, query_plan_hash, shape_key, shape)
  SELECT p_instance_id, (r->>'event_at')::timestamptz, r->>'event_key', p_snapshot_at, r->>'session_name', r->>'event_name',
         (r->>'duration_us')::numeric / 1000, (r->>'cpu_us')::numeric / 1000, (r->>'logical_reads')::bigint,
         (r->>'physical_reads')::bigint, (r->>'writes')::bigint, (r->>'row_count')::bigint, r->>'result', r->>'statement',
         r->>'object_name', r->>'login_name', r->>'host_name', r->>'program_name', r->>'database_name', (r->>'session_id')::int,
         r->>'query_hash_hex', r->>'query_plan_hash_hex', r->>'shape_key', r->>'shape'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'slow' AND r->>'event_at' IS NOT NULL AND r->>'event_key' IS NOT NULL AND r->>'event_name' IS NOT NULL
  ON CONFLICT DO NOTHING;

  -- a completion carries no query hash of its own: it takes those of the longest statement its session completed
  -- while it ran (the statement's event is written before the completion's, so it is in this batch or an earlier one)
  UPDATE pgvigil.mssql_slow_events c
     SET (query_hash, query_plan_hash) =
         (SELECT x.query_hash, x.query_plan_hash
            FROM pgvigil.mssql_slow_events x
           WHERE x.instance_id = c.instance_id AND x.session_id = c.session_id
             AND x.event_name IN ('sql_statement_completed', 'sp_statement_completed') AND x.query_hash IS NOT NULL
             AND x.event_at <= c.event_at + interval '10 milliseconds'
             -- the statement STARTED inside the request: the last statement of the session's previous request, which
             -- ended a few milliseconds before this one began, is not this request's
             AND x.event_at - make_interval(secs => (coalesce(x.duration_ms, 0) / 1000.0)::float8)
                 >= c.event_at - make_interval(secs => (coalesce(c.duration_ms, 0) / 1000.0)::float8) - interval '5 milliseconds'
           ORDER BY x.duration_ms DESC NULLS LAST, x.event_at DESC
           LIMIT 1)
   WHERE c.instance_id = p_instance_id AND c.query_hash IS NULL AND c.session_id IS NOT NULL
     AND c.event_name IN ('rpc_completed', 'sql_batch_completed')
     AND (c.event_at, c.event_key) IN (SELECT (r->>'event_at')::timestamptz, r->>'event_key'
                                         FROM jsonb_array_elements(p_payload) r
                                        WHERE r->>'kind' = 'slow' AND r->>'event_at' IS NOT NULL);

  INSERT INTO pgvigil.mssql_attentions (instance_id, event_at, event_key, snapshot_at, session_name, session_id, request_id,
      interrupt_us, statement, login_name, host_name, program_name, database_name)
  SELECT p_instance_id, (r->>'event_at')::timestamptz, r->>'event_key', p_snapshot_at, r->>'session_name', (r->>'session_id')::int,
         (r->>'request_id')::int, (r->>'interrupt_us')::bigint, r->>'statement', r->>'login_name', r->>'host_name',
         r->>'program_name', r->>'database_name'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'attention' AND r->>'event_at' IS NOT NULL AND r->>'event_key' IS NOT NULL
  ON CONFLICT DO NOTHING;

  INSERT INTO pgvigil.mssql_ag_events (instance_id, event_at, event_key, snapshot_at, event_name, ag_name, replica_name,
      previous_state, current_state, error_number, severity, family, message, ddl_action, ddl_phase, statement, is_failover)
  SELECT p_instance_id, (r->>'event_at')::timestamptz, r->>'event_key', p_snapshot_at, r->>'event_name', r->>'ag_name',
         r->>'replica_name', r->>'previous_state', r->>'current_state', (r->>'error_number')::int, (r->>'severity')::int,
         r->>'family', r->>'message', r->>'ddl_action', r->>'ddl_phase', r->>'statement', coalesce((r->>'is_failover')::boolean, false)
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'ag_event' AND r->>'event_at' IS NOT NULL AND r->>'event_key' IS NOT NULL AND r->>'event_name' IS NOT NULL
  ON CONFLICT DO NOTHING;

  -- the state of each capture; a second import of one read's state row changes nothing (the count of reads in a row
  -- and the loss are per read)
  INSERT INTO pgvigil.mssql_xe_state AS s (instance_id, capture, snapshot_at, state, state_since, reads_in_state, source,
      session_name, target, buffer_kb, buffer_used_kb, event_count, total_processed, new_events, dropped_events,
      dropped_buffers, truncated, missed_events, unknown_events, counter, threshold_s, note)
  SELECT p_instance_id, r->>'capture', p_snapshot_at, r->>'state', p_snapshot_at, 1, r->>'source', r->>'session_name',
         r->>'target', (r->>'buffer_kb')::bigint, (r->>'buffer_used_kb')::bigint, (r->>'event_count')::bigint,
         (r->>'total_processed')::bigint, (r->>'new_events')::bigint, (r->>'dropped_events')::bigint,
         (r->>'dropped_buffers')::bigint, (r->>'truncated')::boolean, 0, (r->>'unknown_events')::bigint,
         (r->>'counter')::bigint, (r->>'threshold_s')::int, r->>'note'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'state' AND r->>'capture' IS NOT NULL AND r->>'state' IS NOT NULL
  ON CONFLICT (instance_id, capture) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, state = EXCLUDED.state,
      state_since = CASE WHEN s.state = EXCLUDED.state THEN s.state_since ELSE EXCLUDED.snapshot_at END,
      reads_in_state = CASE WHEN s.state = EXCLUDED.state THEN s.reads_in_state + 1 ELSE 1 END,
      source = EXCLUDED.source, session_name = EXCLUDED.session_name, target = EXCLUDED.target,
      buffer_kb = EXCLUDED.buffer_kb, buffer_used_kb = EXCLUDED.buffer_used_kb, event_count = EXCLUDED.event_count,
      total_processed = EXCLUDED.total_processed, new_events = EXCLUDED.new_events, dropped_events = EXCLUDED.dropped_events,
      dropped_buffers = EXCLUDED.dropped_buffers, truncated = EXCLUDED.truncated, unknown_events = EXCLUDED.unknown_events,
      counter = EXCLUDED.counter, threshold_s = EXCLUDED.threshold_s, note = EXCLUDED.note,
      missed_events = pgvigil.mssql_xe_missed(s.session_name, s.total_processed, EXCLUDED.session_name, EXCLUDED.target,
                                              EXCLUDED.total_processed, EXCLUDED.new_events),
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

-- events that entered and left a ring buffer between two reads of the SAME session: what the buffer took since the
-- last read, less what this read found past the cursor. A restarted session counts from zero again and says nothing.
CREATE OR REPLACE FUNCTION pgvigil.mssql_xe_missed(p_old_session text, p_old_total bigint, p_session text, p_target text,
                                                   p_total bigint, p_new bigint)
RETURNS bigint LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_target = 'ring_buffer' AND p_old_session IS NOT DISTINCT FROM p_session AND p_old_total IS NOT NULL
                   AND p_total >= p_old_total
              THEN greatest(0, p_total - p_old_total - coalesce(p_new, 0)) ELSE 0 END
$$;

-- the loss one read saw: the missed events plus the growth of the session's own dropped count
CREATE OR REPLACE FUNCTION pgvigil.mssql_xe_lost(p_old_session text, p_old_total bigint, p_old_dropped bigint, p_session text,
                                                 p_target text, p_total bigint, p_new bigint, p_dropped bigint)
RETURNS bigint LANGUAGE sql IMMUTABLE AS $$
  SELECT pgvigil.mssql_xe_missed(p_old_session, p_old_total, p_session, p_target, p_total, p_new)
       + CASE WHEN p_old_session IS NOT DISTINCT FROM p_session AND p_dropped > coalesce(p_old_dropped, 0)
              THEN p_dropped - coalesce(p_old_dropped, 0) ELSE 0 END
$$;

CREATE OR REPLACE VIEW pgvigil.mssql_xe_findings AS
WITH dl AS (
  SELECT d.instance_id, count(*) AS n, max(d.event_at) AS last_at,
         (array_agg(d.object_names ORDER BY d.event_at DESC))[1] AS last_objects
    FROM pgvigil.mssql_deadlocks d
   WHERE d.event_at > now() - interval '1 hour'
   GROUP BY d.instance_id
), heads AS (
  SELECT b.instance_id, b.head_key, count(*) AS reports, count(DISTINCT b.blocked_spid) AS blocked_sessions,
         max(b.wait_ms) AS worst_wait_ms, max(b.event_at) AS last_at,
         (array_agg(b.blocking_statement ORDER BY b.event_at DESC))[1] AS statement,
         (array_agg(b.blocking_spid ORDER BY b.event_at DESC))[1] AS spid,
         (array_agg(b.blocking_status ORDER BY b.event_at DESC))[1] AS status
    FROM pgvigil.mssql_blocked_reports b
   WHERE b.event_at > now() - interval '1 hour' AND b.head_key IS NOT NULL
   GROUP BY b.instance_id, b.head_key
  HAVING count(*) >= 2
), st AS (
  SELECT s.* FROM pgvigil.mssql_xe_state s
   WHERE s.capture <> 'ag' AND s.snapshot_at > now() - interval '10 minutes' AND s.reads_in_state >= 2
), ag AS (
  SELECT e.instance_id, coalesce(e.ag_name, '(availability group)') AS ag_name, count(*) AS n, bool_or(e.is_failover) AS failover,
         max(e.event_at) AS last_at,
         (array_agg(coalesce(e.replica_name || ': ', '') || coalesce(e.previous_state || ' to ', '') || coalesce(e.current_state, e.statement, e.event_name)
                    ORDER BY e.is_failover DESC, e.event_at DESC))[1] AS last_change
    FROM pgvigil.mssql_ag_events e
   WHERE e.event_at > now() - interval '1 hour'
     AND (e.is_failover OR e.event_name IN ('availability_replica_state_change', 'availability_group_lease_expired'))
   GROUP BY e.instance_id, coalesce(e.ag_name, '(availability group)')
)
SELECT dl.instance_id, CASE WHEN dl.n > 10 THEN 'critical' ELSE 'warning' END AS severity,
       'deadlocks in the last hour'::text AS check_name, 'deadlocks'::text AS object, dl.last_at AS at,
       dl.n || ' deadlock(s) in the last hour' || coalesce('; the last one on ' || nullif(dl.last_objects, ''), '') AS detail
  FROM dl
UNION ALL
SELECT h.instance_id, 'warning', 'blocked-process reports naming the same head statement',
       left(coalesce(nullif(btrim(h.statement), ''), '(no input buffer)'), 200), h.last_at,
       h.reports || ' report(s) in the last hour, ' || h.blocked_sessions || ' blocked session(s), the longest wait '
         || coalesce(round(h.worst_wait_ms / 1000.0, 1)::text, '?') || ' s; the blocking session ' || coalesce(h.spid::text, '?') || ' was ' || coalesce(h.status, 'of unknown status')
  FROM heads h
UNION ALL
SELECT st.instance_id, 'info', 'a capture is not installed', string_agg(st.capture, ', ' ORDER BY st.capture), max(st.snapshot_at),
       'no Extended Events session of pgvigil for: ' || string_agg(st.capture, ', ' ORDER BY st.capture)
         || '; the script is what `pgvigil mssql-xe -print` writes, for the server''s DBA to run (docs/sqlserver-xe.md)'
  FROM st WHERE st.state = 'not installed'
 GROUP BY st.instance_id
UNION ALL
SELECT st.instance_id, 'warning', 'a capture is stopped', string_agg(st.capture, ', ' ORDER BY st.capture), max(st.snapshot_at),
       'the session is defined and not started: ' || string_agg(st.session_name, ', ' ORDER BY st.capture)
         || '; stopped since ' || to_char(min(st.state_since) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC. '
         || 'ALTER EVENT SESSION ... ON SERVER STATE = START is the DBA''s step'
  FROM st WHERE st.state = 'stopped'
 GROUP BY st.instance_id
UNION ALL
SELECT s.instance_id, 'warning', 'the ring buffer dropped events', s.capture, s.lost_at,
       s.lost_events || ' event(s) of ' || coalesce(s.session_name, s.capture) || ' were dropped or left the buffer before they were read'
         || coalesce(' (the buffer holds ' || s.buffer_kb || ' KB)', '')
  FROM pgvigil.mssql_xe_state s
 WHERE s.lost_at > now() - interval '1 hour' AND s.lost_events > 0
UNION ALL
SELECT ag.instance_id, CASE WHEN ag.failover THEN 'critical' ELSE 'warning' END,
       'an availability replica changed role or state', ag.ag_name, ag.last_at,
       ag.n || ' change(s) in the last hour' || CASE WHEN ag.failover THEN ', a failover among them' ELSE '' END
         || coalesce('; ' || ag.last_change, '')
  FROM ag;
