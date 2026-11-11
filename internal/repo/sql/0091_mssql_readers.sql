-- 0091: the SQL Server readers (the collections mssql_errorlog, mssql_defaulttrace and mssql_syshealth;
-- internal/mssql/errorlog.go, defaulttrace.go, syshealth.go). Each reads a source the server keeps by itself, forward
-- from a cursor, and stores what a DBA looks for in it. Nothing is created, changed or switched on the monitored server.
--
--   mssql_reader_state       per instance and reader (errorlog, defaulttrace, syshealth): how the last read ended.
--                            read      the source was read
--                            no right  the login lacks the right the source asks for. It is a state of its own and
--                                      never a failure: the run is recorded as ok, the page and the API count it
--                                      apart, and the one finding it raises is an info row
--                            off       the source is switched off on the server (the default trace, system_health)
--                            failed    the read failed for another reason (the note says which): a warning finding
--                            with since when, the scope (the error log: 'all archives' or 'current log only'), what
--                            the read passed over and stored, the oldest event the default trace still holds, and a note.
--   mssql_errorlog           monthly partitions by the line's time; one row per error-log line that matched: a line
--                            of the match list (sp_LogHunter's search strings, see the notice below), an error of
--                            severity 17 or higher, or one of the instance's own strings. An 'Error: n, Severity: s,
--                            State: t.' line and the message line the server writes under it are ONE row. A line is
--                            stored once whatever strings it matched (matched holds them all).
--   mssql_trace_events       monthly partitions by the event's time; the default trace's file growths and shrinks
--                            (event classes 92 to 95), DBCC commands (116) and committed DDL outside tempdb (46, 47,
--                            164), with who ran them.
--   mssql_health_components  monthly partitions by the event's time; one row per sp_server_diagnostics component
--                            result system_health recorded (SYSTEM, RESOURCE, QUERY_PROCESSING, IO_SUBSYSTEM, every
--                            five minutes): its state and its figures as the server wrote them (detail).
--   mssql_readers_findings   instance_id, severity, check_name, object, at, detail.
--
-- Times. The error log and the default trace write the server's LOCAL clock without a zone. The collector stores the
-- instant (the local time less the server's offset at the read) and the local time as written (logged_local). A row's
-- key is made of the local time and the row's own text, so a row read a second time is the same row whatever the
-- offset was at each read: the insert leaves out a key already stored within 26 hours of the new row's instant (the
-- hour a clock is set back reads again, and is stored once). system_health's events carry UTC themselves.
--
-- The instance's own search strings (K04.02) ride the cursor table, because the cursor's door is the one read of the
-- repository a batch collector has: the row of source 'errorlog:search' holds them as a JSON array in file_name, and
-- file_offset 1 means 'search only these'. pgvigil.mssql_errorlog_search_set writes it (the repository owner's call).
--
-- The match list of the error log is the list of search strings of sp_LogHunter (DarlingData, MIT), used as data;
-- the statements here and in errorlog.go are pgvigil's own:
--   Copyright (c) 2021 Darling Data, LLC. Permission is hereby granted, free of charge, to any person obtaining a copy
--   of this software and associated documentation files (the "Software"), to deal in the Software without
--   restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute,
--   sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
--   subject to the following conditions: The above copyright notice and this permission notice shall be included in
--   all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
--   KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
--   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
--   OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
--   WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- For the join: the arm in pgvigil.findings
--     SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_readers', at
--       FROM pgvigil.mssql_readers_findings
--   'mssql_errorlog', 'mssql_health_components' and 'mssql_trace_events' on purge()'s month-partition parents, and
--   'mssql_errorlog_search_set' on apply_roles()' owner-only list (it writes; as a reader's function it would only
--   fail on the table's rights, and the list says so outright).

CREATE TABLE IF NOT EXISTS pgvigil.mssql_reader_state (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  reader        text NOT NULL CHECK (reader IN ('errorlog', 'defaulttrace', 'syshealth')),
  snapshot_at   timestamptz NOT NULL,
  state         text NOT NULL CHECK (state IN ('read', 'no right', 'off', 'failed')),
  state_since   timestamptz NOT NULL,
  scope         text,              -- errorlog: all archives | current log only; syshealth: event_file | ring_buffer
  scanned       bigint,            -- lines or events this read passed over
  stored        bigint,            -- of them, the ones it kept
  oldest_at     timestamptz,       -- defaulttrace: the oldest event the trace files still hold
  newest_at     timestamptz,       -- the newest line or event read so far
  search_count  int,               -- errorlog: the instance's own search strings in force
  search_only   boolean,           -- errorlog: only the instance's own strings were searched
  note          text,
  PRIMARY KEY (instance_id, reader)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_errorlog (
  instance_id   int NOT NULL,
  log_at        timestamptz NOT NULL,
  line_key      text NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  logged_local  timestamp NOT NULL,   -- the server's own clock, as the log wrote it
  process       text,
  error_number  int,
  severity      int,
  error_state   int,
  class         text NOT NULL DEFAULT 'general',  -- corruption | memory | io | scheduler | availability | startup | config | general
  matched       text[] NOT NULL DEFAULT '{}',     -- every search string the line matched
  custom        boolean NOT NULL DEFAULT false,   -- one of the instance's own strings is among them
  archive       int,                               -- the archive it was read from (0: the current log)
  message       text,
  PRIMARY KEY (instance_id, log_at, line_key)
) PARTITION BY RANGE (log_at);
CREATE INDEX IF NOT EXISTS mssql_errorlog_key_idx ON pgvigil.mssql_errorlog (instance_id, line_key, log_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_trace_events (
  instance_id     int NOT NULL,
  event_at        timestamptz NOT NULL,
  event_key       text NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  logged_local    timestamp NOT NULL,
  event_class     int NOT NULL,
  kind            text NOT NULL CHECK (kind IN ('data growth', 'log growth', 'data shrink', 'log shrink', 'dbcc', 'ddl')),
  sub             text,              -- dbcc: the command (DBCC SHRINKFILE); ddl: create | drop | alter
  database_name   text,
  file_name       text,              -- a growth or shrink: the file's logical name
  duration_ms     numeric,
  size_change_mb  numeric,           -- a growth or shrink: the pages the file changed by, in MB
  login_name      text,
  host_name       text,
  program_name    text,
  session_id      int,
  object_name     text,
  object_type     text,              -- ddl: U, V, P, IX ... as sys.trace_subclass_values names it
  statement       text,              -- dbcc: the command's text, under the instance's query-text policy
  PRIMARY KEY (instance_id, event_at, event_key)
) PARTITION BY RANGE (event_at);
CREATE INDEX IF NOT EXISTS mssql_trace_events_key_idx ON pgvigil.mssql_trace_events (instance_id, event_key, event_at);
CREATE INDEX IF NOT EXISTS mssql_trace_events_kind_idx ON pgvigil.mssql_trace_events (instance_id, kind, event_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_health_components (
  instance_id   int NOT NULL,
  event_at      timestamptz NOT NULL,
  event_key     text NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  component     text NOT NULL,       -- SYSTEM | RESOURCE | QUERY_PROCESSING | IO_SUBSYSTEM
  state         text NOT NULL,       -- CLEAN | WARNING | ERROR | UNKNOWN
  detail        jsonb NOT NULL DEFAULT '{}'::jsonb,   -- the component's figures under the server's own names
  PRIMARY KEY (instance_id, event_at, event_key)
) PARTITION BY RANGE (event_at);
CREATE INDEX IF NOT EXISTS mssql_health_components_comp_idx ON pgvigil.mssql_health_components (instance_id, component, event_at);

-- a figure of a component's detail as a number; anything that is not a JSON number is no value (a view over the
-- table must never fail on one odd event)
CREATE OR REPLACE FUNCTION pgvigil.mssql_health_num(p_detail jsonb, p_name text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN jsonb_typeof(p_detail -> p_name) = 'number' THEN (p_detail ->> p_name)::numeric END
$$;

-- payload rows by kind: line (an error-log line), trace (a default trace event), component (a system_health
-- component result), state (one per reader and read), cursor (one per source and batch). A batch is one call: its
-- rows and its cursor are stored together or not at all. A collector_error row is the run's note and stores nothing.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_readers(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_m record;
  v_t record;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_readers: instance % is not a SQL Server instance', p_instance_id;
  END IF;

  -- the three partitioned parents one after the other in name order (the order purge() drops in; 0065's note): the
  -- months this payload needs are opened, then the parent is locked for the writes below
  FOR v_t IN
    SELECT * FROM (VALUES ('mssql_errorlog', 'line', 'log_at'), ('mssql_health_components', 'component', 'event_at'),
                          ('mssql_trace_events', 'trace', 'event_at')) x(tbl, kind, col) ORDER BY tbl
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

  INSERT INTO pgvigil.mssql_errorlog (instance_id, log_at, line_key, snapshot_at, logged_local, process, error_number,
      severity, error_state, class, matched, custom, archive, message)
  SELECT p_instance_id, x.log_at, x.line_key, p_snapshot_at, (r->>'logged_local')::timestamp, r->>'process',
         (r->>'error_number')::int, (r->>'severity')::int, (r->>'error_state')::int, coalesce(r->>'class', 'general'),
         coalesce((SELECT array_agg(m) FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(r->'matched') = 'array' THEN r->'matched' ELSE '[]'::jsonb END) m), '{}'),
         coalesce((r->>'custom')::boolean, false), (r->>'archive')::int, r->>'message'
    FROM jsonb_array_elements(p_payload) r
    CROSS JOIN LATERAL (SELECT (r->>'log_at')::timestamptz AS log_at, r->>'line_key' AS line_key) x
   WHERE r->>'kind' = 'line' AND x.log_at IS NOT NULL AND x.line_key IS NOT NULL AND r->>'logged_local' IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_errorlog e
                      WHERE e.instance_id = p_instance_id AND e.line_key = x.line_key
                        AND e.log_at > x.log_at - interval '26 hours' AND e.log_at < x.log_at + interval '26 hours')
  ON CONFLICT DO NOTHING;

  INSERT INTO pgvigil.mssql_trace_events (instance_id, event_at, event_key, snapshot_at, logged_local, event_class, kind, sub,
      database_name, file_name, duration_ms, size_change_mb, login_name, host_name, program_name, session_id, object_name,
      object_type, statement)
  SELECT p_instance_id, x.event_at, x.event_key, p_snapshot_at, (r->>'logged_local')::timestamp, (r->>'event_class')::int,
         r->>'trace_kind', r->>'sub', r->>'database_name', r->>'file_name', (r->>'duration_us')::numeric / 1000,
         round((r->>'pages')::numeric * 8 / 1024, 2), r->>'login_name', r->>'host_name', r->>'program_name',
         (r->>'session_id')::int, r->>'object_name', r->>'object_type', r->>'statement'
    FROM jsonb_array_elements(p_payload) r
    CROSS JOIN LATERAL (SELECT (r->>'event_at')::timestamptz AS event_at, r->>'event_key' AS event_key) x
   WHERE r->>'kind' = 'trace' AND x.event_at IS NOT NULL AND x.event_key IS NOT NULL AND r->>'logged_local' IS NOT NULL
     AND r->>'event_class' IS NOT NULL
     AND r->>'trace_kind' IN ('data growth', 'log growth', 'data shrink', 'log shrink', 'dbcc', 'ddl')
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_trace_events e
                      WHERE e.instance_id = p_instance_id AND e.event_key = x.event_key
                        AND e.event_at > x.event_at - interval '26 hours' AND e.event_at < x.event_at + interval '26 hours')
  ON CONFLICT DO NOTHING;

  INSERT INTO pgvigil.mssql_health_components (instance_id, event_at, event_key, snapshot_at, component, state, detail)
  SELECT p_instance_id, (r->>'event_at')::timestamptz, r->>'event_key', p_snapshot_at, r->>'component',
         coalesce(r->>'state', 'UNKNOWN'), CASE WHEN jsonb_typeof(r->'detail') = 'object' THEN r->'detail' ELSE '{}'::jsonb END
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'component' AND r->>'event_at' IS NOT NULL AND r->>'event_key' IS NOT NULL AND r->>'component' IS NOT NULL
  ON CONFLICT DO NOTHING;

  -- the state of each reader; a second import of one read's state row changes nothing
  INSERT INTO pgvigil.mssql_reader_state AS s (instance_id, reader, snapshot_at, state, state_since, scope, scanned, stored,
      oldest_at, newest_at, search_count, search_only, note)
  SELECT p_instance_id, r->>'reader', p_snapshot_at, r->>'state', p_snapshot_at, r->>'scope', (r->>'scanned')::bigint,
         (r->>'stored')::bigint, (r->>'oldest_at')::timestamptz, (r->>'newest_at')::timestamptz, (r->>'search_count')::int,
         (r->>'search_only')::boolean, r->>'note'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'state' AND r->>'reader' IN ('errorlog', 'defaulttrace', 'syshealth')
     AND r->>'state' IN ('read', 'no right', 'off', 'failed')
  ON CONFLICT (instance_id, reader) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, state = EXCLUDED.state,
      state_since = CASE WHEN s.state = EXCLUDED.state THEN s.state_since ELSE EXCLUDED.snapshot_at END,
      scope = EXCLUDED.scope, scanned = EXCLUDED.scanned, stored = EXCLUDED.stored,
      -- a read that could not reach its source keeps what the last good read knew
      oldest_at = coalesce(EXCLUDED.oldest_at, s.oldest_at), newest_at = coalesce(EXCLUDED.newest_at, s.newest_at),
      search_count = EXCLUDED.search_count, search_only = EXCLUDED.search_only, note = EXCLUDED.note
  WHERE s.snapshot_at < EXCLUDED.snapshot_at;

  -- the cursors; the instance's own search strings live under 'errorlog:search' and are never a batch's to move
  INSERT INTO pgvigil.mssql_cursor AS c (instance_id, source, file_name, file_offset, last_event_at, last_seq, updated_at)
  SELECT DISTINCT ON (r->>'source') p_instance_id, r->>'source', r->>'file_name', (r->>'file_offset')::bigint,
         (r->>'last_event_at')::timestamptz, (r->>'last_seq')::bigint, now()
    FROM jsonb_array_elements(p_payload) WITH ORDINALITY AS t(r, n)
   WHERE r->>'kind' = 'cursor' AND r->>'source' IN ('errorlog', 'defaulttrace', 'syshealth')
   ORDER BY r->>'source', n DESC
  ON CONFLICT (instance_id, source) DO UPDATE SET
      file_name = EXCLUDED.file_name, file_offset = EXCLUDED.file_offset, last_event_at = EXCLUDED.last_event_at,
      last_seq = EXCLUDED.last_seq, updated_at = EXCLUDED.updated_at;
END $$;

-- every collection has its own import function (the collector calls import_<collection>); the three share one body
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_errorlog(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$ SELECT pgvigil.import_mssql_readers(p_instance_id, p_snapshot_at, p_payload) $$;
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_defaulttrace(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$ SELECT pgvigil.import_mssql_readers(p_instance_id, p_snapshot_at, p_payload) $$;
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_syshealth(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$ SELECT pgvigil.import_mssql_readers(p_instance_id, p_snapshot_at, p_payload) $$;

-- The instance's own error-log search strings (K04.02): up to 50 strings of 1 to 200 characters, matched without
-- regard to case as the shipped list is; p_only true searches only these (errors of severity 17 or higher are kept
-- all the same). An empty list removes them. Returns how many are in force. The next read of the error log uses them.
CREATE OR REPLACE FUNCTION pgvigil.mssql_errorlog_search_set(p_instance text, p_strings text[], p_only boolean DEFAULT false)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_id   int;
  v_list text[];
BEGIN
  SELECT instance_id INTO v_id FROM pgvigil.instances WHERE name = p_instance AND engine = 'sqlserver';
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'mssql_errorlog_search_set: no SQL Server instance named %', p_instance;
  END IF;
  -- one string per spelling without regard to case, as the match is made: the first one given is kept
  SELECT coalesce(array_agg(d.s ORDER BY d.n), '{}') INTO v_list
    FROM (SELECT DISTINCT ON (lower(btrim(x))) btrim(x) AS s, n FROM unnest(coalesce(p_strings, '{}')) WITH ORDINALITY u(x, n)
           WHERE btrim(x) <> '' ORDER BY lower(btrim(x)), n) d;
  IF EXISTS (SELECT 1 FROM unnest(v_list) s WHERE length(s) > 200) THEN
    RAISE EXCEPTION 'mssql_errorlog_search_set: a search string is 200 characters at most';
  END IF;
  IF cardinality(v_list) > 50 THEN
    RAISE EXCEPTION 'mssql_errorlog_search_set: 50 search strings at most (% given)', cardinality(v_list);
  END IF;
  IF cardinality(v_list) = 0 THEN
    DELETE FROM pgvigil.mssql_cursor WHERE instance_id = v_id AND source = 'errorlog:search';
    RETURN 0;
  END IF;
  INSERT INTO pgvigil.mssql_cursor AS c (instance_id, source, file_name, file_offset, updated_at)
  VALUES (v_id, 'errorlog:search', to_jsonb(v_list)::text, CASE WHEN p_only THEN 1 ELSE 0 END, now())
  ON CONFLICT (instance_id, source) DO UPDATE SET file_name = EXCLUDED.file_name, file_offset = EXCLUDED.file_offset,
      updated_at = EXCLUDED.updated_at;
  RETURN cardinality(v_list);
END $$;

-- The findings. Windows: an error-log line and a trace event count for 24 hours; a component's state and its pending
-- tasks for one hour (the server writes a result every five minutes, so a state that cleared leaves within the hour);
-- the SYSTEM component's counters are read from the newest result of the last hour (they count since the server
-- started, so a non-zero one stays until someone has looked and the server restarts); a reader's own state needs a
-- read in the last 30 minutes.
CREATE OR REPLACE VIEW pgvigil.mssql_readers_findings AS
WITH el AS (
  SELECT e.instance_id, e.log_at, e.severity, e.error_number, e.class, e.message
    FROM pgvigil.mssql_errorlog e
   WHERE e.log_at > now() - interval '24 hours'
), sev AS (
  SELECT el.instance_id, max(el.severity) AS worst, bool_or(el.class = 'corruption') AS corruption, count(*) AS n, max(el.log_at) AS last_at,
         (array_agg('error ' || coalesce(el.error_number::text, '?') || ', severity ' || el.severity || ': ' || left(coalesce(el.message, ''), 300)
                    ORDER BY el.severity DESC, el.log_at DESC))[1] AS worst_line
    FROM el
   WHERE el.severity >= 17
   GROUP BY el.instance_id
), cls AS (
  -- a line counts once: one of severity 17 or higher is the row above's
  SELECT el.instance_id, el.class, count(*) AS n, max(el.log_at) AS last_at,
         (array_agg(left(coalesce(el.message, ''), 300) ORDER BY el.log_at DESC))[1] AS last_line
    FROM el
   WHERE el.class IN ('corruption', 'memory', 'io', 'scheduler') AND coalesce(el.severity, 0) < 17
   GROUP BY el.instance_id, el.class
), tr AS (
  SELECT t.* FROM pgvigil.mssql_trace_events t WHERE t.event_at > now() - interval '24 hours'
), grow AS (
  SELECT tr.instance_id, coalesce(tr.database_name, '(database)') AS database_name, tr.kind, count(*) AS n, max(tr.event_at) AS last_at,
         round(max(tr.duration_ms)) AS worst_ms,
         (array_agg(coalesce(tr.file_name, '?') || ', ' || coalesce(tr.size_change_mb::text, '?') || ' MB' ORDER BY tr.duration_ms DESC))[1] AS worst_file
    FROM tr
   WHERE tr.kind IN ('data growth', 'log growth') AND tr.duration_ms > 1000
   GROUP BY tr.instance_id, coalesce(tr.database_name, '(database)'), tr.kind
), shrink AS (
  SELECT tr.instance_id, coalesce(tr.database_name, '(database)') AS database_name, count(*) AS n, max(tr.event_at) AS last_at
    FROM tr
   WHERE tr.kind IN ('data shrink', 'log shrink')
   GROUP BY tr.instance_id, coalesce(tr.database_name, '(database)')
), dbcc AS (
  SELECT tr.instance_id, tr.sub, count(*) AS n, max(tr.event_at) AS last_at,
         string_agg(DISTINCT coalesce(tr.login_name, '(login unknown)'), ', ') AS logins,
         string_agg(DISTINCT tr.database_name, ', ') AS databases
    FROM tr
   WHERE tr.kind = 'dbcc' AND tr.sub IN ('DBCC FREEPROCCACHE', 'DBCC FREESYSTEMCACHE', 'DBCC DROPCLEANBUFFERS', 'DBCC WRITEPAGE',
                                       'DBCC SHRINKFILE', 'DBCC SHRINKDATABASE', 'DBCC SQLPERF (CLEAR)')
   GROUP BY tr.instance_id, tr.sub
), hc AS (
  SELECT h.* FROM pgvigil.mssql_health_components h WHERE h.event_at > now() - interval '24 hours'
), comp AS (
  SELECT hc.instance_id, hc.component, count(*) AS n, max(hc.event_at) AS last_at,
         CASE WHEN bool_or(hc.state = 'ERROR') THEN 'critical' ELSE 'warning' END AS severity,
         (array_agg(hc.state ORDER BY hc.event_at DESC))[1] AS last_state,
         (array_agg(hc.detail->>'lastNotification' ORDER BY hc.event_at DESC))[1] AS last_notification
    FROM hc
   WHERE hc.event_at > now() - interval '1 hour' AND hc.state IN ('WARNING', 'ERROR')
   GROUP BY hc.instance_id, hc.component
), sysnow AS (
  SELECT DISTINCT ON (hc.instance_id) hc.instance_id, hc.event_at, hc.detail
    FROM hc
   WHERE hc.component = 'SYSTEM' AND hc.event_at > now() - interval '1 hour'
   ORDER BY hc.instance_id, hc.event_at DESC
), sysc AS (
  SELECT s.instance_id, s.event_at, c.label, c.n, c.word
    FROM sysnow s
    CROSS JOIN LATERAL (VALUES
      ('bad pages detected', pgvigil.mssql_health_num(s.detail, 'BadPagesDetected'), NULL::text),
      ('access violations', greatest(pgvigil.mssql_health_num(s.detail, 'isAccessViolationOccurred'), pgvigil.mssql_health_num(s.detail, 'writeAccessViolationCount')), NULL),
      ('non-yielding tasks', pgvigil.mssql_health_num(s.detail, 'nonYieldingTasksReported'), NULL),
      ('latch warnings', pgvigil.mssql_health_num(s.detail, 'latchWarnings'), NULL),
      ('a sick spinlock', CASE WHEN coalesce(nullif(s.detail->>'sickSpinlockType', ''), 'none') <> 'none' THEN 1 END, s.detail->>'sickSpinlockType')
    ) c(label, n, word)
   WHERE c.n > 0
), dumps AS (
  SELECT hc.instance_id, sum(pgvigil.mssql_health_num(hc.detail, 'intervalDumpRequests')) AS n, max(hc.event_at) AS last_at
    FROM hc
   WHERE hc.component = 'SYSTEM' AND pgvigil.mssql_health_num(hc.detail, 'intervalDumpRequests') > 0
   GROUP BY hc.instance_id
), qp AS (
  SELECT hc.instance_id,
         count(*) FILTER (WHERE pgvigil.mssql_health_num(hc.detail, 'hasUnresolvableDeadlockOccurred') > 0) AS unresolvable,
         max(hc.event_at) FILTER (WHERE pgvigil.mssql_health_num(hc.detail, 'hasUnresolvableDeadlockOccurred') > 0) AS unresolvable_at,
         count(*) FILTER (WHERE pgvigil.mssql_health_num(hc.detail, 'hasDeadlockedSchedulersOccurred') > 0) AS deadlocked,
         max(hc.event_at) FILTER (WHERE pgvigil.mssql_health_num(hc.detail, 'hasDeadlockedSchedulersOccurred') > 0) AS deadlocked_at,
         max(pgvigil.mssql_health_num(hc.detail, 'pendingTasks')) FILTER (WHERE hc.event_at > now() - interval '1 hour') AS pending,
         max(pgvigil.mssql_health_num(hc.detail, 'oldestPendingTaskWaitingTime')) FILTER (WHERE hc.event_at > now() - interval '1 hour') AS oldest_ms,
         max(hc.event_at) FILTER (WHERE hc.event_at > now() - interval '1 hour' AND pgvigil.mssql_health_num(hc.detail, 'pendingTasks') >= 10) AS pending_at
    FROM hc
   WHERE hc.component = 'QUERY_PROCESSING'
   GROUP BY hc.instance_id
), grown AS (
  -- ioLatchTimeouts and outOfMemoryExceptions count from the server's start (they carry no 'interval' in their
  -- name, as intervalLongIos does): what a window saw is the newest less the oldest of it, and a server restarted
  -- inside it (the newest lower) counts the newest whole
  SELECT hc.instance_id, hc.component,
         (array_agg(coalesce(pgvigil.mssql_health_num(hc.detail, c.name), 0) ORDER BY hc.event_at))[1] AS first_n,
         (array_agg(coalesce(pgvigil.mssql_health_num(hc.detail, c.name), 0) ORDER BY hc.event_at DESC))[1] AS last_n,
         max(hc.event_at) AS last_at
    FROM hc
    JOIN (VALUES ('IO_SUBSYSTEM', 'ioLatchTimeouts'), ('RESOURCE', 'outOfMemoryExceptions')) c(component, name) ON c.component = hc.component
   GROUP BY hc.instance_id, hc.component
), io AS (
  SELECT hc.instance_id, sum(pgvigil.mssql_health_num(hc.detail, 'intervalLongIos')) AS long_ios,
         max(g.n) AS latch_timeouts, max(hc.event_at) AS last_at
    FROM hc
    LEFT JOIN (SELECT instance_id, CASE WHEN last_n < first_n THEN last_n ELSE last_n - first_n END AS n
                 FROM grown WHERE component = 'IO_SUBSYSTEM') g ON g.instance_id = hc.instance_id
   WHERE hc.component = 'IO_SUBSYSTEM'
   GROUP BY hc.instance_id
  HAVING coalesce(sum(pgvigil.mssql_health_num(hc.detail, 'intervalLongIos')), 0) > 0 OR coalesce(max(g.n), 0) > 0
), oom AS (
  SELECT hc.instance_id, max(g.n) AS exceptions,
         bool_or(pgvigil.mssql_health_num(hc.detail, 'isAnyPoolOutOfMemory') > 0) AS pool, max(hc.event_at) AS last_at
    FROM hc
    LEFT JOIN (SELECT instance_id, CASE WHEN last_n < first_n THEN last_n ELSE last_n - first_n END AS n
                 FROM grown WHERE component = 'RESOURCE') g ON g.instance_id = hc.instance_id
   WHERE hc.component = 'RESOURCE'
   GROUP BY hc.instance_id
  HAVING coalesce(max(g.n), 0) > 0 OR bool_or(pgvigil.mssql_health_num(hc.detail, 'isAnyPoolOutOfMemory') > 0)
), st AS (
  SELECT s.* FROM pgvigil.mssql_reader_state s WHERE s.snapshot_at > now() - interval '30 minutes'
)
SELECT sev.instance_id, CASE WHEN sev.worst >= 20 OR sev.corruption THEN 'critical' ELSE 'warning' END AS severity,
       'error log: errors of severity 17 or higher'::text AS check_name, ('severity ' || sev.worst)::text AS object, sev.last_at AS at,
       sev.n || ' error(s) of severity 17 or higher in the error log in the last 24 hours; the worst: ' || sev.worst_line AS detail
  FROM sev
UNION ALL
SELECT cls.instance_id, CASE WHEN cls.class = 'corruption' THEN 'critical' ELSE 'warning' END,
       CASE cls.class WHEN 'corruption' THEN 'error log: corruption reported' WHEN 'memory' THEN 'error log: memory pressure reported'
                      WHEN 'io' THEN 'error log: slow or failed IO reported' ELSE 'error log: scheduler or worker thread trouble reported' END,
       cls.class, cls.last_at,
       cls.n || ' line(s) in the last 24 hours; the last: ' || cls.last_line
  FROM cls
UNION ALL
SELECT grow.instance_id, 'warning', 'default trace: slow file growth', grow.database_name || ' (' || grow.kind || ')', grow.last_at,
       grow.n || ' growth(s) over 1 s in the last 24 hours, the slowest ' || grow.worst_ms || ' ms (' || grow.worst_file
         || '); a growth that waits is a session that waits: size the file ahead, and for a data file check instant file initialization'
  FROM grow
UNION ALL
SELECT shrink.instance_id, 'warning', 'default trace: auto-shrink ran', shrink.database_name, shrink.last_at,
       shrink.n || ' auto-shrink event(s) in the last 24 hours; ALTER DATABASE ... SET AUTO_SHRINK OFF is the DBA''s step'
  FROM shrink
UNION ALL
SELECT dbcc.instance_id,
       CASE WHEN dbcc.sub IN ('DBCC SHRINKFILE', 'DBCC SHRINKDATABASE', 'DBCC SQLPERF (CLEAR)') THEN 'info' ELSE 'warning' END,
       CASE WHEN dbcc.sub IN ('DBCC SHRINKFILE', 'DBCC SHRINKDATABASE') THEN 'default trace: a DBCC SHRINK command ran'
            WHEN dbcc.sub = 'DBCC SQLPERF (CLEAR)' THEN 'default trace: the wait or latch statistics were cleared'
            ELSE 'default trace: a disruptive DBCC command ran' END,
       dbcc.sub, dbcc.last_at,
       dbcc.n || ' time(s) in the last 24 hours, by ' || dbcc.logins || coalesce(' in ' || dbcc.databases, '')
  FROM dbcc
UNION ALL
SELECT comp.instance_id, comp.severity, 'system_health: a component is not clean', comp.component, comp.last_at,
       comp.n || ' result(s) in the last hour not CLEAN; the last: ' || comp.last_state
         || coalesce(', last notification ' || comp.last_notification, '')
  FROM comp
UNION ALL
SELECT sysc.instance_id, 'critical', 'system_health: ' || sysc.label, 'SYSTEM', sysc.event_at,
       sysc.label || ': ' || coalesce(sysc.word, sysc.n::text) || ' in the newest SYSTEM result (counted since the server started)'
  FROM sysc
UNION ALL
SELECT dumps.instance_id, 'critical', 'system_health: dump requests', 'SYSTEM', dumps.last_at,
       dumps.n || ' dump request(s) in the last 24 hours'
  FROM dumps
UNION ALL
SELECT qp.instance_id, 'critical', 'system_health: an unresolvable deadlock occurred', 'QUERY_PROCESSING', qp.unresolvable_at,
       qp.unresolvable || ' result(s) in the last 24 hours carry the flag'
  FROM qp WHERE qp.unresolvable > 0
UNION ALL
SELECT qp.instance_id, 'critical', 'system_health: deadlocked schedulers', 'QUERY_PROCESSING', qp.deadlocked_at,
       qp.deadlocked || ' result(s) in the last 24 hours carry the flag'
  FROM qp WHERE qp.deadlocked > 0
UNION ALL
SELECT qp.instance_id, 'warning', 'system_health: tasks waiting for a worker', 'QUERY_PROCESSING', qp.pending_at,
       qp.pending || ' pending task(s) in a result of the last hour, the oldest waiting ' || coalesce(qp.oldest_ms::text, '?') || ' ms'
  FROM qp WHERE qp.pending >= 10
UNION ALL
SELECT io.instance_id, 'warning', 'system_health: long IO or IO latch timeouts', 'IO_SUBSYSTEM', io.last_at,
       coalesce(io.long_ios, 0) || ' long IO(s) and ' || coalesce(io.latch_timeouts, 0) || ' IO latch timeout(s) in the last 24 hours'
  FROM io
UNION ALL
SELECT oom.instance_id, 'critical', 'system_health: out of memory', 'RESOURCE', oom.last_at,
       coalesce(oom.exceptions, 0) || ' out-of-memory exception(s)' || CASE WHEN oom.pool THEN ', a resource pool out of memory' ELSE '' END
         || ' in the last 24 hours'
  FROM oom
UNION ALL
SELECT st.instance_id, 'warning', 'a SQL Server reader could not read its source', st.reader, st.snapshot_at,
       coalesce(st.note, 'the read failed')
  FROM st WHERE st.state = 'failed'
UNION ALL
SELECT st.instance_id, 'info', 'a SQL Server reader''s source is switched off', st.reader, st.snapshot_at,
       coalesce(st.note, 'the source is off')
  FROM st WHERE st.state = 'off'
UNION ALL
SELECT st.instance_id, 'info', 'a SQL Server reader lacks its right', string_agg(st.reader, ', ' ORDER BY st.reader), max(st.snapshot_at),
       'not read, for lack of a right (not a failure): ' || string_agg(st.reader || ' - ' || coalesce(st.note, 'no right'), '; ' ORDER BY st.reader)
  FROM st WHERE st.state = 'no right'
 GROUP BY st.instance_id;
