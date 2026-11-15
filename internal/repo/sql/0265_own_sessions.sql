-- 0265: pgvigil's own sessions marked by the collector (B24 OWN, PerformanceMonitor Fixed 12: hidden on running queries
-- and waiting tasks by default, with a switch, both engines; the server half - the pages wire own=1).
--
-- is_own is decided on the MONITORED server when the row is read, never matched later on a label any client may set:
--   SQL Server  (program_name = PROGRAM_NAME() OR program_name LIKE 'pgvigil%') AND login_name = SUSER_SNAME()
--   PostgreSQL  application_name LIKE 'pgvigil%' AND usename = session_user (not current_user: a login's SET ROLE)
-- and never for an actions-door session (pgvigil-actions*: it runs a customer's statement). NULL = read before 0265:
-- such a row is shown in both switch states.
-- A row stays shown (hide false) even when own when the operator needs it: it blocks or is blocked (a parallel exec
-- context waiting on its own session is not blocked), a request runs over 60 s, a transaction sits idle over 60 s or
-- holds the xmin horizon, a memory grant or tempdb use is over 100 MB.
--   mssql_requests / mssql_waiting_tasks / activity_sample  gain is_own (nullable)
--   import_mssql_requests / import_mssql_waiting_tasks / import_activity  renamed <name>_0265 and called whole by a new
--       <name> that then sets is_own true on the own sessions' rows only (a minute's few; every other row stays NULL,
--       which reads as shown, as false would) - 0163's pattern: no change to 0064 / 0108 / 0002
--   mssql_waiting_at / pg_waiting_at  return is_own and hide; mssql_waiting_by_type / pg_waiting_by_type take p_own
SET LOCAL lock_timeout = '20s';

ALTER TABLE pgvigil.mssql_requests ADD COLUMN IF NOT EXISTS is_own boolean;
ALTER TABLE pgvigil.mssql_waiting_tasks ADD COLUMN IF NOT EXISTS is_own boolean;
ALTER TABLE pgvigil.activity_sample ADD COLUMN IF NOT EXISTS is_own boolean;

DO $$
BEGIN
  IF to_regprocedure('pgvigil.import_mssql_requests_0265(int, timestamptz, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_requests(int, timestamptz, jsonb) RENAME TO import_mssql_requests_0265;
  END IF;
  IF to_regprocedure('pgvigil.import_mssql_waiting_tasks_0265(int, timestamptz, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_waiting_tasks(int, timestamptz, jsonb) RENAME TO import_mssql_waiting_tasks_0265;
  END IF;
  IF to_regprocedure('pgvigil.import_activity_0265(int, timestamptz, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_activity(int, timestamptz, jsonb) RENAME TO import_activity_0265;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_requests(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.import_mssql_requests_0265(p_instance_id, p_snapshot_at, p_payload);
  UPDATE pgvigil.mssql_requests q SET is_own = x.own
    FROM (SELECT DISTINCT ON ((r->>'session_id')::int) (r->>'session_id')::int AS sid, (r->>'is_own')::boolean AS own
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'session_id' IS NOT NULL AND r->>'is_own' = 'true') x
   WHERE q.instance_id = p_instance_id AND q.snapshot_at = p_snapshot_at AND q.session_id = x.sid;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_waiting_tasks(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.import_mssql_waiting_tasks_0265(p_instance_id, p_snapshot_at, p_payload);
  UPDATE pgvigil.mssql_waiting_tasks t SET is_own = x.own
    FROM (SELECT DISTINCT ON ((r->>'session_id')::int) (r->>'session_id')::int AS sid, (r->>'is_own')::boolean AS own
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'session_id' IS NOT NULL AND r->>'is_own' = 'true') x
   WHERE t.instance_id = p_instance_id AND t.snapshot_at = p_snapshot_at AND t.session_id = x.sid;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_activity(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.import_activity_0265(p_instance_id, p_snapshot_at, p_payload);
  UPDATE pgvigil.activity_sample a SET is_own = x.own
    FROM (SELECT DISTINCT ON ((r->>'pid')::int) (r->>'pid')::int AS pid, (r->>'is_own')::boolean AS own
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'pid' IS NOT NULL AND r->>'is_own' = 'true') x
   WHERE a.instance_id = p_instance_id AND a.snapshot_at = p_snapshot_at AND a.pid = x.pid;
END $$;

-- own_shown_pg / own_shown_mssql: a row shown even when it is pgvigil's own (the reasons above; a transaction over 60 s
-- on either engine, whatever its current statement's age, holds the xmin horizon or the log). The SQL Server row's
-- other half - another row names it as blocker - is the caller's (a set-level test).
CREATE OR REPLACE FUNCTION pgvigil.own_shown_pg(p_wait_type text, p_is_blocker boolean, p_state text, p_query_start timestamptz,
                                                p_state_change timestamptz, p_xact_start timestamptz, p_at timestamptz)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(p_wait_type = 'Lock', false) OR coalesce(p_is_blocker, false)
      OR (p_state = 'active' AND p_at - p_query_start > interval '60 seconds')
      OR (p_state LIKE 'idle in transaction%' AND p_at - p_state_change > interval '60 seconds')
      -- a transaction over 60 s holds the xmin horizon whatever its statements' length (the collector caps a statement at
      -- 30 s: a long REPEATABLE READ read of short statements is only seen here)
      OR p_at - p_xact_start > interval '60 seconds'
$$;

CREATE OR REPLACE FUNCTION pgvigil.own_shown_mssql(p_session_id int, p_blocking int, p_head int, p_in_cycle boolean,
                                                   p_elapsed_ms bigint, p_request_id int, p_open_tran int,
                                                   p_last_end timestamptz, p_grant_kb bigint, p_tempdb_kb bigint,
                                                   p_tran_age_ms bigint, p_at timestamptz)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(p_blocking, 0) NOT IN (0, p_session_id)        -- blocked by another session (a negative id too)
      OR p_head IS NOT NULL OR coalesce(p_in_cycle, false)        -- in a blocking chain
      OR coalesce(p_elapsed_ms, 0) > 60000
      OR (p_request_id IS NULL AND coalesce(p_open_tran, 0) > 0 AND p_at - p_last_end > interval '60 seconds')
      OR coalesce(p_grant_kb, 0) > 102400 OR coalesce(p_tempdb_kb, 0) > 102400
      OR coalesce(p_tran_age_ms, 0) > 60000                     -- a transaction over 60 s (the server's own clock)
$$;

-- the waiting tasks of one read, each with is_own and hide (own, and none of the reasons to show it)
DROP FUNCTION IF EXISTS pgvigil.mssql_waiting_at(int, timestamptz, text);
CREATE FUNCTION pgvigil.mssql_waiting_at(p_instance_id int, p_at timestamptz, p_wait text)
RETURNS TABLE (snapshot_at timestamptz, session_id int, exec_context_id int, wait_type text, wait_ms bigint,
               blocking_session_id int, blocking_exec_context_id int, resource_kind text, database_name text,
               object_name text, index_name text, resource_description text, request_status text, command text,
               statement text, tasks_of_session bigint, is_own boolean, hide boolean)
LANGUAGE sql STABLE AS $$
  WITH snap AS (
    SELECT max(s.snapshot_at) AS at FROM pgvigil.mssql_waiting_summary s
     WHERE s.instance_id = p_instance_id AND (p_at IS NULL OR s.snapshot_at <= p_at)),
  t AS (
    SELECT t.* FROM pgvigil.mssql_waiting_tasks t, snap
     WHERE t.instance_id = p_instance_id AND t.snapshot_at = snap.at)
  SELECT t.snapshot_at, t.session_id, t.exec_context_id, t.wait_type, t.wait_ms, t.blocking_session_id,
         t.blocking_exec_context_id, t.resource_kind, t.database_name, t.object_name, t.index_name,
         t.resource_description, t.request_status, t.command, t.statement,
         count(*) OVER (PARTITION BY t.session_id) AS tasks_of_session, t.is_own,
         coalesce(t.is_own, false)
           AND NOT (coalesce(t.blocking_session_id, t.session_id) <> t.session_id
                    OR EXISTS (SELECT 1 FROM t b WHERE b.blocking_session_id = t.session_id AND b.session_id <> t.session_id)
                    OR coalesce(t.wait_ms, 0) > 60000)
    FROM t
   WHERE p_wait IS NULL OR t.wait_type = p_wait
   ORDER BY t.wait_ms DESC NULLS LAST, t.session_id, t.exec_context_id
$$;

DROP FUNCTION IF EXISTS pgvigil.mssql_waiting_by_type(int, timestamptz, timestamptz);
-- p_own's default true keeps an older serve's three-argument call working (it shows every task, as before 0265)
CREATE FUNCTION pgvigil.mssql_waiting_by_type(p_instance_id int, p_from timestamptz, p_to timestamptz, p_own boolean DEFAULT true)
RETURNS TABLE (wait_type text, tasks bigint, sessions bigint, reads bigint, longest_ms bigint, last_seen timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT t.wait_type, count(*), count(DISTINCT (t.snapshot_at, t.session_id)), count(DISTINCT t.snapshot_at),
         max(t.wait_ms), max(t.snapshot_at)
    FROM pgvigil.mssql_waiting_tasks t
   WHERE t.instance_id = p_instance_id AND t.snapshot_at > p_from AND t.snapshot_at <= p_to
     AND (p_own OR NOT coalesce(t.is_own, false)
          OR coalesce(t.blocking_session_id, t.session_id) <> t.session_id OR coalesce(t.wait_ms, 0) > 60000
          OR EXISTS (SELECT 1 FROM pgvigil.mssql_waiting_tasks b WHERE b.instance_id = t.instance_id
                       AND b.snapshot_at = t.snapshot_at AND b.blocking_session_id = t.session_id AND b.session_id <> t.session_id))
   GROUP BY t.wait_type
   ORDER BY count(*) DESC, max(t.wait_ms) DESC NULLS LAST
$$;

DROP FUNCTION IF EXISTS pgvigil.pg_waiting_at(int, timestamptz, text);
CREATE FUNCTION pgvigil.pg_waiting_at(p_instance_id int, p_at timestamptz, p_wait text)
RETURNS TABLE (snapshot_at timestamptz, pid int, leader_pid int, datname text, usename text, application_name text,
               state text, wait_event_type text, wait_event text, in_state_s numeric, blocking_pids int[],
               backend_type text, query_id bigint, query text, is_own boolean, hide boolean)
LANGUAGE sql STABLE AS $$
  WITH snap AS (
    SELECT max(a.snapshot_at) AS at FROM pgvigil.activity_summary a
     WHERE a.instance_id = p_instance_id AND (p_at IS NULL OR a.snapshot_at <= p_at))
  SELECT s.snapshot_at, s.pid, s.leader_pid, s.datname, s.usename, s.application_name, s.state, s.wait_event_type,
         s.wait_event, round(extract(epoch FROM s.snapshot_at - s.state_change)::numeric, 1), s.blocking_pids,
         s.backend_type, s.query_id, left(q.query, 4000), s.is_own,
         coalesce(s.is_own, false) AND NOT pgvigil.own_shown_pg(s.wait_event_type, s.is_blocker, s.state, s.query_start,
                                                                 s.state_change, s.xact_start, s.snapshot_at)
    FROM pgvigil.activity_sample s
    JOIN snap ON s.snapshot_at = snap.at
    LEFT JOIN pgvigil.query_text q ON q.query_hash = s.query_hash
   WHERE s.instance_id = p_instance_id AND s.wait_event IS NOT NULL
     AND (s.wait_event_type = 'Lock' OR (s.state = 'active' AND s.wait_event_type NOT IN ('Activity', 'Client', 'Timeout')))
     AND (p_wait IS NULL OR p_wait = s.wait_event OR p_wait = s.wait_event_type || ':' || s.wait_event)
   ORDER BY s.state_change NULLS LAST, s.pid
$$;

DROP FUNCTION IF EXISTS pgvigil.pg_waiting_by_type(int, timestamptz, timestamptz);
CREATE FUNCTION pgvigil.pg_waiting_by_type(p_instance_id int, p_from timestamptz, p_to timestamptz, p_own boolean DEFAULT true)
RETURNS TABLE (wait_event_type text, wait_event text, backends bigint, samples bigint, last_seen timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT s.wait_event_type, s.wait_event, count(DISTINCT (s.snapshot_at, s.pid)), count(DISTINCT s.snapshot_at), max(s.snapshot_at)
    FROM pgvigil.activity_sample s
   WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to AND s.wait_event IS NOT NULL
     AND (s.wait_event_type = 'Lock' OR (s.state = 'active' AND s.wait_event_type NOT IN ('Activity', 'Client', 'Timeout')))
     AND (p_own OR NOT coalesce(s.is_own, false)
          OR pgvigil.own_shown_pg(s.wait_event_type, s.is_blocker, s.state, s.query_start, s.state_change, s.xact_start, s.snapshot_at))
   GROUP BY 1, 2
   ORDER BY 3 DESC, 1, 2
$$;

SELECT pgvigil.apply_roles();
