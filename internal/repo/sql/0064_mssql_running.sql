-- 0064: SQL Server running queries, blocking and waits (the collections mssql_requests and mssql_waits).
--
-- mssql_requests, every minute: one row per session that runs a request, holds an open transaction or blocks
-- another, as the collector read it (the DMVs, or sp_WhoIsActive where a DBA installed it: the source is on the
-- snapshot's summary row). Tables:
--   mssql_requests_summary  one row per snapshot, also for a minute in which nothing ran: the server's own UTC clock
--                           at the read, the source, the counts, the memory grants pending, how long the read took.
--   mssql_requests          the snapshot's rows, in DAILY partitions (a minute's rows of a busy server are the
--                           largest table of the engine; a day is dropped whole). A row carries text_id, never the
--                           text; the handles and hashes are bytea (half the size of their 0x text), and
--                           mssql_requests_v gives them back as the 0x text SQL Server prints.
--   mssql_statement_text    a statement's text once per instance, sql_handle and offsets. The offsets (-1, -1) are
--                           the input buffer of a sleeping session (its last batch) under its most recent handle.
--                           statement is NULL where the instance's query_text policy is none: the key is still kept.
--   mssql_blocking          per snapshot and head of a blocking chain: its victims, the longest wait behind it, the
--                           head's own row values and its statement's text_id (monthly partitions).
--   mssql_running_findings  the findings view's columns (instance_id, severity, check_name, object, at, detail); the
--                           UNION arm in pgvigil.findings is the wave's join. From the newest snapshot of an
--                           instance, when it is at most 5 minutes old:
--       'a blocking chain'        a head whose victims wait over 30 s (warning), over 5 min (critical)
--       'a session idle in a transaction over an hour holding locks'   a sleeping session whose transaction began
--                                 over an hour ago and that wrote to the log or heads a chain (warning)
--       'a request running over an hour'   a user request older than an hour that is not parked on an idle wait (info)
--       'memory grants pending'   requests waiting for a memory grant at the read (warning)
--
-- The chain (head_session_id, chain_depth, victims, longest_victim_wait_ms) is built by the collector from the
-- snapshot's own rows by one rule: the head is the session that blocks and does not itself wait behind a session;
-- a sleeping head with an open transaction is shown with its last batch. The root cause of a chain is the head's
-- transaction and its last statement, never the object its victims wait on.
--
-- mssql_waits, every minute: sys.dm_os_wait_stats is cumulative since the server started (or since someone cleared
-- it), so the import keeps the last counters (mssql_wait_last, mssql_wait_state) and stores the differences
-- (mssql_wait_sample, monthly partitions): what was waited in the interval between two reads. A restart or a
-- cleared counter (a counter that went down) stores no difference for that read. is_benign marks the waits of idle
-- background work, which are stored and kept out of the page's top list.
--
-- Retention: mssql_blocking and mssql_wait_sample are month partitions for purge()'s parent list;
-- pgvigil.mssql_running_purge(p_days) does the rest (the day partitions, the summary rows, the texts no longer
-- seen, the wait state of an instance not read past the window) and is called from purge().

CREATE TABLE IF NOT EXISTS pgvigil.mssql_statement_text (
  text_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  sql_handle   bytea NOT NULL,
  stmt_start   int NOT NULL,
  stmt_end     int NOT NULL,
  first_seen   timestamptz NOT NULL,
  last_seen    timestamptz NOT NULL,
  full_chars   int,                    -- the statement's length on the server; statement is cut at 16,000 characters
  statement    text,
  UNIQUE (instance_id, sql_handle, stmt_start, stmt_end)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_requests_summary (
  instance_id            int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at            timestamptz NOT NULL,
  server_utc             timestamptz,          -- the server's own clock at the read, in UTC
  source                 text NOT NULL CHECK (source IN ('dmv', 'sp_whoisactive')),
  source_note            text,                 -- why the DMV read ran where sp_WhoIsActive exists, or where it was found
  sessions               int NOT NULL DEFAULT 0,
  requests               int NOT NULL DEFAULT 0,
  blocked                int NOT NULL DEFAULT 0,
  heads                  int NOT NULL DEFAULT 0,
  longest_wait_ms        bigint,
  memory_grants_pending  int,
  read_ms                int,                  -- how long the read took on the SQL Server side
  PRIMARY KEY (instance_id, snapshot_at)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_requests (
  instance_id             int NOT NULL,
  snapshot_at             timestamptz NOT NULL,
  session_id              int NOT NULL,
  request_id              int,                 -- NULL: a session without a request (sleeping)
  status                  text,
  command                 text,
  wait_type               text,
  wait_ms                 bigint,
  wait_resource           text,
  wait_is_benign          boolean NOT NULL DEFAULT false,
  blocking_session_id     int,
  open_tran               int,
  transaction_id          bigint,
  tran_start              timestamptz,
  tran_log_bytes          bigint,
  is_implicit_tran        boolean,
  isolation_level         text,
  cpu_ms                  bigint,
  reads                   bigint,
  writes                  bigint,
  logical_reads           bigint,
  granted_memory_kb       bigint,
  tempdb_alloc_kb         bigint,
  tempdb_current_kb       bigint,
  dop                     int,
  task_count              int,
  tasks_cpu_ms            bigint,              -- summed over the request's tasks; cpu_ms, reads, writes and logical_reads
  tasks_physical_io       bigint,              -- of a parallel request are its coordinator's only
  percent_complete        real,
  elapsed_ms              bigint,
  start_time              timestamptz,
  last_request_start      timestamptz,
  last_request_end        timestamptz,
  login_time              timestamptz,
  login_name              text,
  host_name               text,
  program_name            text,
  database_name           text,
  text_id                 bigint,
  plan_handle             bytea,
  query_hash              bytea,
  query_plan_hash         bytea,
  session_waits           jsonb,               -- the session's own three largest waits since it logged in: [{wait, ms, tasks}]
  is_user_process         boolean,
  head_session_id         int,                 -- the chain's head; on the head's own row its own session
  chain_depth             int,                 -- 0 the head, 1 a session it blocks, 2 one behind that
  victims                 int,                 -- on a head: the sessions waiting behind it, at any depth
  longest_victim_wait_ms  bigint,
  in_cycle                boolean NOT NULL DEFAULT false,
  chain_note              text
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_blocking (
  instance_id        int NOT NULL,
  snapshot_at        timestamptz NOT NULL,
  head_session_id    int NOT NULL,
  victims            int NOT NULL,
  longest_wait_ms    bigint,
  in_snapshot        boolean NOT NULL,         -- false: the head's own row was not in the read (it left between two DMVs)
  head_status        text,
  head_wait_type     text,
  head_open_tran     int,
  head_tran_start    timestamptz,
  head_tran_age_ms   bigint,                   -- by the server's own clock at the read
  head_login         text,
  head_host          text,
  head_program       text,
  head_database      text,
  head_text_id       bigint,
  note               text
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_wait_state (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  server_utc    timestamptz NOT NULL,
  server_start  timestamptz,
  source        text
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_wait_last (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  wait_type      text NOT NULL,
  waiting_tasks  bigint NOT NULL,
  wait_ms        bigint NOT NULL,
  signal_ms      bigint NOT NULL,
  max_wait_ms    bigint,
  PRIMARY KEY (instance_id, wait_type)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_wait_sample (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  wait_type      text NOT NULL,
  category       text,
  is_benign      boolean NOT NULL DEFAULT false,
  waiting_tasks  bigint NOT NULL,              -- the interval's: waits that ended in it
  wait_ms        bigint NOT NULL,
  signal_ms      bigint NOT NULL,              -- the part of wait_ms spent runnable, waiting for a CPU
  max_wait_ms    bigint,                       -- the server's counter as read: the longest single wait since its start
  interval_secs  real NOT NULL                 -- between this read and the one before, by the server's own clock
) PARTITION BY RANGE (snapshot_at);

-- One daily partition of a table, UTC days (the month form is ensure_month_partition, 0002).
CREATE OR REPLACE FUNCTION pgvigil.mssql_ensure_day_partition(p_table text, p_at timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_from timestamp := date_trunc('day', p_at AT TIME ZONE 'UTC');
  v_to   timestamp := v_from + interval '1 day';
  v_name text := p_table || '_' || to_char(v_from, 'YYYYMMDD');
BEGIN
  IF to_regclass('pgvigil.' || quote_ident(v_name)) IS NOT NULL THEN
    RETURN;
  END IF;
  BEGIN
    EXECUTE format('CREATE TABLE pgvigil.%I PARTITION OF pgvigil.%I FOR VALUES FROM (%L) TO (%L)',
                   v_name, p_table, v_from AT TIME ZONE 'UTC', v_to AT TIME ZONE 'UTC');
    EXECUTE format('CREATE INDEX %I ON pgvigil.%I (instance_id, snapshot_at)', v_name || '_inst_idx', v_name);
  EXCEPTION WHEN duplicate_table THEN
    NULL;  -- another importer made it first
  END;
END $$;

-- 0x text of a handle or a hash, as SQL Server prints it; and back
CREATE OR REPLACE FUNCTION pgvigil.mssql_hex(p bytea) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT '0x' || upper(encode(p, 'hex'))
$$;
CREATE OR REPLACE FUNCTION pgvigil.mssql_unhex(p text) RETURNS bytea LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p ~ '^0[xX]([0-9A-Fa-f]{2})+$' THEN decode(substr(p, 3), 'hex') END
$$;

-- payload: one {kind:'summary', server_utc, source, source_note, memory_grants_pending, read_ms}; the 'request' rows;
-- the 'text' rows {sql_handle, stmt_start, stmt_end, statement, full_chars}; the 'blocking' rows {head_session_id,
-- victims, longest_wait_ms, note}. A handle or a hash is the collector's 0x text.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_requests(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s      jsonb;
  v_server timestamptz;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_requests: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  SELECT r INTO v_s FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'summary' LIMIT 1;
  IF v_s IS NULL THEN
    RAISE EXCEPTION 'import_mssql_requests: the payload has no summary row';
  END IF;
  v_server := (v_s->>'server_utc')::timestamptz;
  PERFORM pgvigil.mssql_ensure_day_partition('mssql_requests', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_blocking', p_snapshot_at);

  -- a re-run of one read replaces it
  DELETE FROM pgvigil.mssql_requests WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  DELETE FROM pgvigil.mssql_blocking WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;

  -- the text once per key; a key seen again within the hour is not rewritten (a long statement is read every minute)
  INSERT INTO pgvigil.mssql_statement_text AS t (instance_id, sql_handle, stmt_start, stmt_end, first_seen, last_seen, full_chars, statement)
  SELECT DISTINCT ON (pgvigil.mssql_unhex(r->>'sql_handle'), (r->>'stmt_start')::int, (r->>'stmt_end')::int)
         p_instance_id, pgvigil.mssql_unhex(r->>'sql_handle'), (r->>'stmt_start')::int, (r->>'stmt_end')::int,
         p_snapshot_at, p_snapshot_at, (r->>'full_chars')::int, r->>'statement'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'text' AND pgvigil.mssql_unhex(r->>'sql_handle') IS NOT NULL
     AND r->>'stmt_start' IS NOT NULL AND r->>'stmt_end' IS NOT NULL
   ORDER BY 2, 3, 4
  ON CONFLICT (instance_id, sql_handle, stmt_start, stmt_end) DO UPDATE
     SET last_seen = EXCLUDED.last_seen,
         statement = coalesce(t.statement, EXCLUDED.statement),
         full_chars = coalesce(t.full_chars, EXCLUDED.full_chars)
   WHERE t.last_seen < EXCLUDED.last_seen - interval '1 hour' OR (t.statement IS NULL AND EXCLUDED.statement IS NOT NULL);

  INSERT INTO pgvigil.mssql_requests (
    instance_id, snapshot_at, session_id, request_id, status, command, wait_type, wait_ms, wait_resource, wait_is_benign,
    blocking_session_id, open_tran, transaction_id, tran_start, tran_log_bytes, is_implicit_tran, isolation_level,
    cpu_ms, reads, writes, logical_reads, granted_memory_kb, tempdb_alloc_kb, tempdb_current_kb, dop, task_count,
    tasks_cpu_ms, tasks_physical_io, percent_complete, elapsed_ms, start_time, last_request_start, last_request_end,
    login_time, login_name, host_name, program_name, database_name, text_id, plan_handle, query_hash, query_plan_hash,
    session_waits, is_user_process, head_session_id, chain_depth, victims, longest_victim_wait_ms, in_cycle, chain_note)
  SELECT p_instance_id, p_snapshot_at, (r->>'session_id')::int, (r->>'request_id')::int, r->>'status', r->>'command',
         r->>'wait_type', (r->>'wait_ms')::bigint, r->>'wait_resource', coalesce((r->>'wait_is_benign')::boolean, false),
         (r->>'blocking_session_id')::int, (r->>'open_tran')::int, (r->>'transaction_id')::bigint,
         (r->>'tran_start')::timestamptz, (r->>'tran_log_bytes')::bigint, (r->>'is_implicit_tran')::int = 1,
         r->>'isolation_level', (r->>'cpu_ms')::bigint, (r->>'reads')::bigint, (r->>'writes')::bigint,
         (r->>'logical_reads')::bigint, (r->>'granted_memory_kb')::bigint, (r->>'tempdb_alloc_kb')::bigint,
         (r->>'tempdb_current_kb')::bigint, (r->>'dop')::int, (r->>'task_count')::int, (r->>'tasks_cpu_ms')::bigint,
         (r->>'tasks_physical_io')::bigint, (r->>'percent_complete')::real, (r->>'elapsed_ms')::bigint,
         (r->>'start_time')::timestamptz, (r->>'last_request_start')::timestamptz, (r->>'last_request_end')::timestamptz,
         (r->>'login_time')::timestamptz, r->>'login_name', r->>'host_name', r->>'program_name', r->>'database_name',
         t.text_id, pgvigil.mssql_unhex(r->>'plan_handle'), pgvigil.mssql_unhex(r->>'stmt_query_hash'),
         pgvigil.mssql_unhex(r->>'stmt_plan_hash'),
         CASE WHEN jsonb_typeof(r->'session_waits') = 'array' THEN r->'session_waits' END,
         (r->>'is_user_process')::int = 1, (r->>'head_session_id')::int, (r->>'chain_depth')::int, (r->>'victims')::int,
         (r->>'longest_victim_wait_ms')::bigint, coalesce((r->>'in_cycle')::boolean, false), r->>'chain_note'
    FROM jsonb_array_elements(p_payload) r
    LEFT JOIN pgvigil.mssql_statement_text t
           ON t.instance_id = p_instance_id AND t.sql_handle = pgvigil.mssql_unhex(r->>'sql_handle')
          AND t.stmt_start = (r->>'stmt_start')::int AND t.stmt_end = (r->>'stmt_end')::int
   WHERE r->>'kind' = 'request' AND r->>'session_id' IS NOT NULL;

  INSERT INTO pgvigil.mssql_blocking (
    instance_id, snapshot_at, head_session_id, victims, longest_wait_ms, in_snapshot, head_status, head_wait_type,
    head_open_tran, head_tran_start, head_tran_age_ms, head_login, head_host, head_program, head_database, head_text_id, note)
  SELECT p_instance_id, p_snapshot_at, (b->>'head_session_id')::int, (b->>'victims')::int, (b->>'longest_wait_ms')::bigint,
         h.session_id IS NOT NULL, h.status, h.wait_type, h.open_tran, h.tran_start,
         (extract(epoch FROM v_server - h.tran_start) * 1000)::bigint, h.login_name, h.host_name, h.program_name,
         h.database_name, h.text_id, b->>'note'
    FROM jsonb_array_elements(p_payload) b
    LEFT JOIN LATERAL (
      SELECT q.* FROM pgvigil.mssql_requests q
       WHERE q.instance_id = p_instance_id AND q.snapshot_at = p_snapshot_at AND q.session_id = (b->>'head_session_id')::int
       ORDER BY q.request_id NULLS LAST LIMIT 1) h ON true
   WHERE b->>'kind' = 'blocking' AND b->>'head_session_id' IS NOT NULL;

  INSERT INTO pgvigil.mssql_requests_summary AS s (instance_id, snapshot_at, server_utc, source, source_note, sessions, requests,
      blocked, heads, longest_wait_ms, memory_grants_pending, read_ms)
  SELECT p_instance_id, p_snapshot_at, v_server, v_s->>'source', v_s->>'source_note',
         (SELECT count(DISTINCT q.session_id) FROM pgvigil.mssql_requests q WHERE q.instance_id = p_instance_id AND q.snapshot_at = p_snapshot_at),
         (SELECT count(*) FROM pgvigil.mssql_requests q WHERE q.instance_id = p_instance_id AND q.snapshot_at = p_snapshot_at AND q.request_id IS NOT NULL),
         (SELECT count(DISTINCT q.session_id) FROM pgvigil.mssql_requests q WHERE q.instance_id = p_instance_id AND q.snapshot_at = p_snapshot_at AND q.chain_depth > 0),
         (SELECT count(*) FROM pgvigil.mssql_blocking b WHERE b.instance_id = p_instance_id AND b.snapshot_at = p_snapshot_at),
         (SELECT max(b.longest_wait_ms) FROM pgvigil.mssql_blocking b WHERE b.instance_id = p_instance_id AND b.snapshot_at = p_snapshot_at),
         (v_s->>'memory_grants_pending')::int, (v_s->>'read_ms')::int
  ON CONFLICT (instance_id, snapshot_at) DO UPDATE SET
      server_utc = EXCLUDED.server_utc, source = EXCLUDED.source, source_note = EXCLUDED.source_note, sessions = EXCLUDED.sessions,
      requests = EXCLUDED.requests, blocked = EXCLUDED.blocked, heads = EXCLUDED.heads, longest_wait_ms = EXCLUDED.longest_wait_ms,
      memory_grants_pending = EXCLUDED.memory_grants_pending, read_ms = EXCLUDED.read_ms;
END $$;

-- payload: one {kind:'state', server_utc, server_start, source}; the 'wait' rows {wait_type, waiting_tasks, wait_ms,
-- signal_ms, max_wait_ms, is_benign, category}: the server's cumulative counters, every wait type with a count
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_waits(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s     jsonb;
  v_prev  pgvigil.mssql_wait_state;
  v_now   timestamptz;
  v_start timestamptz;
  v_secs  real;
  v_delta boolean;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_waits: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  SELECT r INTO v_s FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'state' LIMIT 1;
  IF v_s IS NULL OR v_s->>'server_utc' IS NULL THEN
    RAISE EXCEPTION 'import_mssql_waits: the payload has no state row with the server''s time';
  END IF;
  v_now := (v_s->>'server_utc')::timestamptz;
  v_start := (v_s->>'server_start')::timestamptz;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_waits'), p_instance_id);
  SELECT * INTO v_prev FROM pgvigil.mssql_wait_state WHERE instance_id = p_instance_id;
  IF v_prev.instance_id IS NOT NULL AND (v_prev.snapshot_at >= p_snapshot_at OR v_prev.server_utc >= v_now) THEN
    RETURN;  -- an older read arriving late: the counters already stored are newer
  END IF;
  v_secs := extract(epoch FROM v_now - v_prev.server_utc);
  -- a difference needs a read before this one of the same run of the server (the start time moves by a minute's
  -- rounding at most) and counters that only grew: one that went down was cleared (DBCC SQLPERF) or the server restarted
  v_delta := v_prev.instance_id IS NOT NULL
         AND v_prev.source IS NOT DISTINCT FROM (v_s->>'source')
         AND (v_start IS NULL OR v_prev.server_start IS NULL OR abs(extract(epoch FROM v_start - v_prev.server_start)) < 120)
         AND NOT EXISTS (
               SELECT 1 FROM jsonb_array_elements(p_payload) r
                 JOIN pgvigil.mssql_wait_last l ON l.instance_id = p_instance_id AND l.wait_type = r->>'wait_type'
                WHERE r->>'kind' = 'wait'
                  AND ((r->>'waiting_tasks')::bigint < l.waiting_tasks OR (r->>'wait_ms')::bigint < l.wait_ms));
  IF v_delta THEN
    PERFORM pgvigil.ensure_month_partition('mssql_wait_sample', p_snapshot_at);
    INSERT INTO pgvigil.mssql_wait_sample (instance_id, snapshot_at, wait_type, category, is_benign, waiting_tasks, wait_ms,
                                           signal_ms, max_wait_ms, interval_secs)
    SELECT p_instance_id, p_snapshot_at, r->>'wait_type', r->>'category', coalesce((r->>'is_benign')::boolean, false),
           (r->>'waiting_tasks')::bigint - coalesce(l.waiting_tasks, 0), (r->>'wait_ms')::bigint - coalesce(l.wait_ms, 0),
           greatest((r->>'signal_ms')::bigint - coalesce(l.signal_ms, 0), 0), (r->>'max_wait_ms')::bigint, v_secs
      FROM jsonb_array_elements(p_payload) r
      LEFT JOIN pgvigil.mssql_wait_last l ON l.instance_id = p_instance_id AND l.wait_type = r->>'wait_type'
     WHERE r->>'kind' = 'wait' AND r->>'wait_type' IS NOT NULL
       AND ((r->>'waiting_tasks')::bigint > coalesce(l.waiting_tasks, 0) OR (r->>'wait_ms')::bigint > coalesce(l.wait_ms, 0));
  ELSE
    -- after a restart or a clear the old counters mean nothing: a wait type absent from this read starts from zero
    DELETE FROM pgvigil.mssql_wait_last WHERE instance_id = p_instance_id;
  END IF;

  -- only a counter that moved is rewritten
  INSERT INTO pgvigil.mssql_wait_last AS l (instance_id, wait_type, waiting_tasks, wait_ms, signal_ms, max_wait_ms)
  SELECT DISTINCT ON (r->>'wait_type') p_instance_id, r->>'wait_type', (r->>'waiting_tasks')::bigint, (r->>'wait_ms')::bigint,
         (r->>'signal_ms')::bigint, (r->>'max_wait_ms')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'wait' AND r->>'wait_type' IS NOT NULL
   ORDER BY r->>'wait_type'
  ON CONFLICT (instance_id, wait_type) DO UPDATE
     SET waiting_tasks = EXCLUDED.waiting_tasks, wait_ms = EXCLUDED.wait_ms, signal_ms = EXCLUDED.signal_ms, max_wait_ms = EXCLUDED.max_wait_ms
   WHERE (l.waiting_tasks, l.wait_ms, l.signal_ms) IS DISTINCT FROM (EXCLUDED.waiting_tasks, EXCLUDED.wait_ms, EXCLUDED.signal_ms);

  INSERT INTO pgvigil.mssql_wait_state AS s (instance_id, snapshot_at, server_utc, server_start, source)
  VALUES (p_instance_id, p_snapshot_at, v_now, v_start, v_s->>'source')
  ON CONFLICT (instance_id) DO UPDATE
     SET snapshot_at = EXCLUDED.snapshot_at, server_utc = EXCLUDED.server_utc, server_start = EXCLUDED.server_start, source = EXCLUDED.source;
END $$;

-- The snapshot's rows as a page reads them: the handles and hashes as 0x text, the statement, the source.
CREATE OR REPLACE VIEW pgvigil.mssql_requests_v AS
SELECT q.instance_id, q.snapshot_at, s.server_utc, s.source, q.session_id, q.request_id, q.status, q.command, q.wait_type, q.wait_ms,
       q.wait_resource, q.wait_is_benign, q.blocking_session_id, q.open_tran, q.transaction_id, q.tran_start,
       (extract(epoch FROM s.server_utc - q.tran_start) * 1000)::bigint AS tran_age_ms, q.tran_log_bytes, q.is_implicit_tran,
       q.isolation_level, q.cpu_ms, q.reads, q.writes, q.logical_reads, q.granted_memory_kb, q.tempdb_alloc_kb, q.tempdb_current_kb,
       q.dop, q.task_count, q.tasks_cpu_ms, q.tasks_physical_io, q.percent_complete, q.elapsed_ms, q.start_time,
       q.last_request_start, q.last_request_end, q.login_time, q.login_name, q.host_name, q.program_name, q.database_name,
       q.text_id, pgvigil.mssql_hex(t.sql_handle) AS sql_handle, t.stmt_start, t.stmt_end, t.statement, t.full_chars,
       pgvigil.mssql_hex(q.plan_handle) AS plan_handle, pgvigil.mssql_hex(q.query_hash) AS query_hash,
       pgvigil.mssql_hex(q.query_plan_hash) AS query_plan_hash, q.session_waits, q.is_user_process, q.head_session_id,
       q.chain_depth, q.victims, q.longest_victim_wait_ms, q.in_cycle, q.chain_note
  FROM pgvigil.mssql_requests q
  JOIN pgvigil.mssql_requests_summary s ON s.instance_id = q.instance_id AND s.snapshot_at = q.snapshot_at
  LEFT JOIN pgvigil.mssql_statement_text t ON t.text_id = q.text_id;

CREATE OR REPLACE VIEW pgvigil.mssql_running_findings AS
WITH latest AS (
  SELECT s.instance_id, max(s.snapshot_at) AS snapshot_at
    FROM pgvigil.mssql_requests_summary s
   WHERE s.snapshot_at > now() - interval '5 minutes'
   GROUP BY s.instance_id
), rows AS (
  SELECT q.* FROM pgvigil.mssql_requests_v q JOIN latest l ON l.instance_id = q.instance_id AND l.snapshot_at = q.snapshot_at
)
SELECT b.instance_id, CASE WHEN b.longest_wait_ms > 300000 THEN 'critical' ELSE 'warning' END AS severity,
       'a blocking chain'::text AS check_name, 'session ' || b.head_session_id AS object, b.snapshot_at AS at,
       format('Session %s heads a blocking chain: %s session(s) wait behind it, the longest for %s s. %s. Its last statement: %s. '
              || 'The cause is this session''s transaction and its last statement, not the object the others wait on.',
              b.head_session_id, b.victims, b.longest_wait_ms / 1000,
              CASE WHEN NOT b.in_snapshot THEN 'The head''s own row was not in the read'
                   ELSE format('Login %s, program %s, status %s, %s', coalesce(b.head_login, '(unknown)'), coalesce(nullif(b.head_program, ''), '(none)'),
                               coalesce(b.head_status, '(unknown)'),
                               CASE WHEN b.head_tran_start IS NULL THEN 'no open transaction read'
                                    ELSE 'its transaction open for ' || (b.head_tran_age_ms / 1000) || ' s' END) END,
              coalesce(left(t.statement, 500), '(text not stored)')) AS detail
  FROM pgvigil.mssql_blocking b
  JOIN latest l ON l.instance_id = b.instance_id AND l.snapshot_at = b.snapshot_at
  LEFT JOIN pgvigil.mssql_statement_text t ON t.text_id = b.head_text_id
 WHERE b.longest_wait_ms > 30000
UNION ALL
SELECT r.instance_id, 'warning', 'a session idle in a transaction over an hour holding locks', 'session ' || r.session_id, r.snapshot_at,
       format('Session %s (login %s, program %s) is sleeping with a transaction open for %s min%s%s. Its last batch: %s. The application '
              || 'left the transaction open: its locks stay held and the log cannot be truncated past it.',
              r.session_id, coalesce(r.login_name, '(unknown)'), coalesce(nullif(r.program_name, ''), '(none)'), r.tran_age_ms / 60000,
              CASE WHEN r.tran_log_bytes > 0 THEN ', ' || r.tran_log_bytes || ' bytes of log written' ELSE '' END,
              CASE WHEN r.victims > 0 THEN ', ' || r.victims || ' session(s) blocked behind it' ELSE '' END,
              coalesce(left(r.statement, 500), '(text not stored)'))
  FROM rows r
 WHERE r.request_id IS NULL AND r.open_tran > 0 AND r.tran_age_ms > 3600000 AND (r.tran_log_bytes > 0 OR r.victims > 0)
UNION ALL
SELECT r.instance_id, 'info', 'a request running over an hour', 'session ' || r.session_id, r.snapshot_at,
       format('Session %s (login %s, program %s, database %s) has run one request for %s min: %s, %s. Statement: %s',
              r.session_id, coalesce(r.login_name, '(unknown)'), coalesce(nullif(r.program_name, ''), '(none)'),
              coalesce(r.database_name, '(unknown)'), r.elapsed_ms / 60000, coalesce(r.command, '(command unknown)'),
              CASE WHEN r.wait_type IS NULL THEN 'not waiting' ELSE 'waiting on ' || r.wait_type END,
              coalesce(left(r.statement, 500), '(text not stored)'))
  FROM rows r
 WHERE r.request_id IS NOT NULL AND r.is_user_process AND r.elapsed_ms > 3600000 AND NOT r.wait_is_benign
UNION ALL
SELECT s.instance_id, 'warning', 'memory grants pending', 'server', s.snapshot_at,
       format('%s request(s) wait for a memory grant: the workspace memory is given out and a query that needs a sort or a hash cannot '
              || 'start. Read the granted memory of the running requests on the Running queries tab.', s.memory_grants_pending)
  FROM pgvigil.mssql_requests_summary s
  JOIN latest l ON l.instance_id = s.instance_id AND l.snapshot_at = s.snapshot_at
 WHERE s.memory_grants_pending > 0;

-- Retention of what purge()'s month-partition list does not cover (mssql_blocking and mssql_wait_sample are on it).
CREATE OR REPLACE FUNCTION pgvigil.mssql_running_purge(p_days int DEFAULT 30)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n       bigint := 0;
  v_rows  bigint;
  v_part  record;
BEGIN
  FOR v_part IN
    SELECT c.relname
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent
      JOIN pg_namespace ns ON ns.oid = p.relnamespace
     WHERE ns.nspname = 'pgvigil' AND p.relname = 'mssql_requests'
       AND c.relname ~ '^mssql_requests_[0-9]{8}$'
       AND (to_date(right(c.relname, 8), 'YYYYMMDD') + interval '1 day') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)   -- UTC days
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    n := n + 1;
  END LOOP;
  DELETE FROM pgvigil.mssql_requests_summary WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- a text not seen within the window plus the hour its last_seen may lag (the import rewrites it hourly at most)
  DELETE FROM pgvigil.mssql_statement_text t WHERE t.last_seen < now() - make_interval(days => p_days) - interval '2 hours';
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_wait_last l
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_wait_state s
                      WHERE s.instance_id = l.instance_id AND s.snapshot_at >= now() - make_interval(days => p_days));
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_wait_state WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  RETURN n;
END $$;
