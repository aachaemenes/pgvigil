-- 0112: waiting tasks now (task 177, darling-open D01; the collection mssql_waiting_tasks, internal/mssql/darling_waiting.go,
-- and the PostgreSQL twin over the running-queries samples of 0002). What every waiting task of a SQL Server is waiting
-- on, every minute: one row per task of sys.dm_os_waiting_tasks (a parallel request has one per exec context), the
-- session that blocks it, the resource it waits for decoded to database, object and index where the server can say,
-- and the statement of its request. Nothing is created, changed or switched on the monitored server.
--
--   mssql_waiting_summary   monthly partitions; one row per read, also for a minute in which nothing waited: the tasks
--                           seen (after the benign list), the rows kept (the longest waits first, at most 2000), the
--                           sessions, the THREADPOOL waiters, the longest wait, and why a resource was not decoded.
--   mssql_waiting_tasks     monthly partitions; the tasks of each read.
--   mssql_waiting_findings  instance_id, severity, check_name, object, at, detail: THREADPOOL now (a task waits for a
--                           worker thread in the newest read of the last 10 minutes), sp_PressureDetector's sign of
--                           worker starvation.
--
-- The read is PerformanceMonitor's waiting-tasks collector (PerformanceMonitor.Collectors/WaitingTasksCollector.cs, its
-- sessions 50 and up, the collector's own session left out, a blocker that is the collector itself dropped), widened by
-- the columns the audit asked for (the exec context, the resource, the request's statement; Get-DbaWaitingTask and
-- Get-DbaWaitResource read the same DMVs). PerformanceMonitor and sp_PressureDetector are Darling Data's:
--   Copyright (c) 2026 Erik Darling, Darling Data LLC. Permission is hereby granted, free of charge, to any person
--   obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software
--   without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute,
--   sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
--   subject to the following conditions: The above copyright notice and this permission notice shall be included in
--   all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
--   KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
--   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
--   OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
--   WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- The PostgreSQL twin reads what pgvigil already samples (0002's activity_sample: wait event, blockers, the leader of
-- a parallel worker); the lock's target relation is not sampled, and the page says so.
--
-- For the join: the arm in pgvigil.findings
--     SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_waiting', at
--       FROM pgvigil.mssql_waiting_findings
--   and 'mssql_waiting_summary', 'mssql_waiting_tasks' on purge()'s month-partition parents.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_waiting_summary (
  instance_id   int NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  server_utc    timestamptz,
  tasks         int NOT NULL,
  stored        int NOT NULL,
  sessions      int NOT NULL,
  threadpool    int NOT NULL,
  longest_ms    bigint,
  decode_note   text,
  read_ms       int,
  PRIMARY KEY (instance_id, snapshot_at)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_waiting_tasks (
  instance_id               int NOT NULL,
  snapshot_at               timestamptz NOT NULL,
  session_id                int NOT NULL,
  exec_context_id           int NOT NULL,
  wait_type                 text NOT NULL,
  wait_ms                   bigint,
  blocking_session_id       int,
  blocking_exec_context_id  int,
  resource_description      text,
  resource_kind             text,     -- key, page, rid, object, page latch, exchange, other
  database_name             text,
  object_name               text,     -- schema.object, decoded from the resource
  index_name                text,
  request_status            text,
  command                   text,
  statement                 text
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_waiting_tasks_at ON pgvigil.mssql_waiting_tasks (instance_id, snapshot_at);

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_waiting_tasks(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_waiting_tasks: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  -- the two parents in name order (purge() drops in that order; 0065's note)
  PERFORM pgvigil.ensure_month_partition('mssql_waiting_summary', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_waiting_tasks', p_snapshot_at);
  INSERT INTO pgvigil.mssql_waiting_summary (instance_id, snapshot_at, server_utc, tasks, stored, sessions, threadpool,
      longest_ms, decode_note, read_ms)
  SELECT p_instance_id, p_snapshot_at, (r->>'server_utc')::timestamptz, coalesce((r->>'tasks')::int, 0),
         coalesce((r->>'stored')::int, 0), coalesce((r->>'sessions')::int, 0), coalesce((r->>'threadpool')::int, 0),
         (r->>'longest_ms')::bigint, nullif(r->>'decode_note', ''), (r->>'read_ms')::int
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'summary'
  ON CONFLICT (instance_id, snapshot_at) DO NOTHING;
  INSERT INTO pgvigil.mssql_waiting_tasks (instance_id, snapshot_at, session_id, exec_context_id, wait_type, wait_ms,
      blocking_session_id, blocking_exec_context_id, resource_description, resource_kind, database_name, object_name,
      index_name, request_status, command, statement)
  SELECT p_instance_id, p_snapshot_at, (r->>'session_id')::int, coalesce((r->>'exec_context_id')::int, 0), r->>'wait_type',
         (r->>'wait_ms')::bigint, (r->>'blocking_session_id')::int, (r->>'blocking_exec_context_id')::int,
         nullif(r->>'resource_description', ''), nullif(r->>'resource_kind', ''), nullif(r->>'database_name', ''),
         nullif(r->>'object_name', ''), nullif(r->>'index_name', ''), nullif(r->>'request_status', ''),
         nullif(r->>'command', ''), nullif(r->>'statement', '')
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'task' AND r->>'session_id' IS NOT NULL AND r->>'wait_type' IS NOT NULL;
END $$;

-- the reads of the range: one row per read (the slider, the tiles' trend)
CREATE OR REPLACE FUNCTION pgvigil.mssql_waiting_snapshots(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, tasks int, stored int, sessions int, threadpool int, longest_ms bigint, decode_note text)
LANGUAGE sql STABLE AS $$
  SELECT s.snapshot_at, s.tasks, s.stored, s.sessions, s.threadpool, s.longest_ms, s.decode_note
    FROM pgvigil.mssql_waiting_summary s
   WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
   ORDER BY s.snapshot_at
$$;

-- one read's tasks: the newest read at or before p_at (NULL = the newest), one wait type when p_wait names it; the
-- longest waits first, the tasks of one session together
CREATE OR REPLACE FUNCTION pgvigil.mssql_waiting_at(p_instance_id int, p_at timestamptz, p_wait text)
RETURNS TABLE (snapshot_at timestamptz, session_id int, exec_context_id int, wait_type text, wait_ms bigint,
               blocking_session_id int, blocking_exec_context_id int, resource_kind text, database_name text,
               object_name text, index_name text, resource_description text, request_status text, command text,
               statement text, tasks_of_session bigint)
LANGUAGE sql STABLE AS $$
  WITH snap AS (
    SELECT max(s.snapshot_at) AS at FROM pgvigil.mssql_waiting_summary s
     WHERE s.instance_id = p_instance_id AND (p_at IS NULL OR s.snapshot_at <= p_at))
  SELECT t.snapshot_at, t.session_id, t.exec_context_id, t.wait_type, t.wait_ms, t.blocking_session_id,
         t.blocking_exec_context_id, t.resource_kind, t.database_name, t.object_name, t.index_name,
         t.resource_description, t.request_status, t.command, t.statement,
         count(*) OVER (PARTITION BY t.session_id) AS tasks_of_session
    FROM pgvigil.mssql_waiting_tasks t, snap
   WHERE t.instance_id = p_instance_id AND t.snapshot_at = snap.at AND (p_wait IS NULL OR t.wait_type = p_wait)
   ORDER BY t.wait_ms DESC NULLS LAST, t.session_id, t.exec_context_id
$$;

-- the range's wait types over the stored reads: tasks and sessions seen, the reads they were in, the longest wait
CREATE OR REPLACE FUNCTION pgvigil.mssql_waiting_by_type(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (wait_type text, tasks bigint, sessions bigint, reads bigint, longest_ms bigint, last_seen timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT t.wait_type, count(*), count(DISTINCT (t.snapshot_at, t.session_id)), count(DISTINCT t.snapshot_at),
         max(t.wait_ms), max(t.snapshot_at)
    FROM pgvigil.mssql_waiting_tasks t
   WHERE t.instance_id = p_instance_id AND t.snapshot_at > p_from AND t.snapshot_at <= p_to
   GROUP BY t.wait_type
   ORDER BY count(*) DESC, max(t.wait_ms) DESC NULLS LAST
$$;

-- THREADPOOL now: in the newest read of the last 10 minutes a task waits for a worker thread
CREATE OR REPLACE VIEW pgvigil.mssql_waiting_findings AS
WITH last AS (
  SELECT DISTINCT ON (s.instance_id) s.instance_id, s.snapshot_at, s.threadpool
    FROM pgvigil.mssql_waiting_summary s
   WHERE s.snapshot_at > now() - interval '10 minutes'
   ORDER BY s.instance_id, s.snapshot_at DESC)
SELECT l.instance_id, 'warning'::text AS severity, 'THREADPOOL waits now'::text AS check_name, NULL::text AS object,
       l.snapshot_at AS at,
       format('%s task(s) waiting for a worker thread at %s, the longest %s ms: the server is out of worker threads '
              '(blocking that holds workers, or many parallel requests); sp_PressureDetector''s sign of worker starvation',
              l.threadpool, to_char(l.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS "UTC"'),
              (SELECT max(t.wait_ms) FROM pgvigil.mssql_waiting_tasks t
                WHERE t.instance_id = l.instance_id AND t.snapshot_at = l.snapshot_at AND t.wait_type = 'THREADPOOL')) AS detail
  FROM last l
 WHERE l.threadpool > 0;

-- the PostgreSQL twin: the waiting backends of one running-queries sample (the newest at or before p_at; NULL = the
-- newest), one wait event when p_wait names it ('<type>:<event>' or the event alone). A backend waits when it is active
-- with a wait event that is not the client's or an idle background loop's (Activity, Client); a lock waiter always.
CREATE OR REPLACE FUNCTION pgvigil.pg_waiting_at(p_instance_id int, p_at timestamptz, p_wait text)
RETURNS TABLE (snapshot_at timestamptz, pid int, leader_pid int, datname text, usename text, application_name text,
               state text, wait_event_type text, wait_event text, waited_s numeric, blocking_pids int[],
               backend_type text, query_id bigint, query text)
LANGUAGE sql STABLE AS $$
  WITH snap AS (
    SELECT max(a.snapshot_at) AS at FROM pgvigil.activity_summary a
     WHERE a.instance_id = p_instance_id AND (p_at IS NULL OR a.snapshot_at <= p_at))
  SELECT s.snapshot_at, s.pid, s.leader_pid, s.datname, s.usename, s.application_name, s.state, s.wait_event_type,
         s.wait_event, round(extract(epoch FROM s.snapshot_at - s.state_change)::numeric, 1), s.blocking_pids,
         s.backend_type, s.query_id, left(q.query, 4000)
    FROM pgvigil.activity_sample s
    JOIN snap ON s.snapshot_at = snap.at
    LEFT JOIN pgvigil.query_text q ON q.query_hash = s.query_hash
   WHERE s.instance_id = p_instance_id AND s.wait_event IS NOT NULL
     AND (s.wait_event_type = 'Lock' OR (s.state = 'active' AND s.wait_event_type NOT IN ('Activity', 'Client')))
     AND (p_wait IS NULL OR p_wait = s.wait_event OR p_wait = s.wait_event_type || ':' || s.wait_event)
   ORDER BY s.state_change NULLS LAST, s.pid
$$;

-- the twin's range: per wait event over the stored samples
CREATE OR REPLACE FUNCTION pgvigil.pg_waiting_by_type(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (wait_event_type text, wait_event text, backends bigint, samples bigint, last_seen timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT s.wait_event_type, s.wait_event, count(DISTINCT (s.snapshot_at, s.pid)), count(DISTINCT s.snapshot_at), max(s.snapshot_at)
    FROM pgvigil.activity_sample s
   WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to AND s.wait_event IS NOT NULL
     AND (s.wait_event_type = 'Lock' OR (s.state = 'active' AND s.wait_event_type NOT IN ('Activity', 'Client')))
   GROUP BY 1, 2
   ORDER BY 3 DESC, 1, 2
$$;
