-- 0163: sessions and connections (task 413, B22; internal/mssql/sessions.go, the activity.go WIRING patch;
-- internal/web/q_mssql_sessions.go; web/src/mssql_sessions.ts).
--
-- ONE user / system rule across the Connections page (the lead 11-15 09:4x): a session is a user session when
-- sys.dm_exec_sessions.is_user_process = 1 and a system session when it is 0, over ALL sessions (not 'session_id > 50',
-- PerformanceMonitor's rule, which the activity read's total used before 413: its WIRING patch moves the total too).
--
--   mssql_session_count   one row per minute (mssql_sessions, sessions.go; monthly partitions): sessions by user /
--                         system x status (a session's status: running, sleeping, dormant, preconnect; 'background'
--                         is a request's status only), requests by user / system x status, the waiting tasks of user sessions (the
--                         benign waits of waits.go left out) and the longest of their waits; pgvigil's own reading
--                         session left out and counted apart (own_sessions).
--   mssql_session_by      one row per dimension and name per 5-minute activity read (monthly partitions): the sessions
--                         grouped by login, by status x user / system, by network interface, by client address and by
--                         isolation level, the 50 largest names of each and one 'other' row for the rest (is_other).
--                         Its own table, not more rows of 0124's mssql_session_group: that table's groups are user
--                         sessions with a program name (PerformanceMonitor's), these are every session, and a reader of
--                         either must never sum across the two rules.
--
-- import_mssql_activity is 0124's, renamed import_mssql_activity_0124 and called unchanged by a new one, which then writes
-- the 'session_by' rows of the same payload (no change to 0124's file; a payload without them stores what it stored).
-- For the join: 0190's purge() adds mssql_session_count and mssql_session_by to the monthly partition parents (the
-- WIRING patch); apply_roles() needs no line: the imports are import_% (the collector's door by name, SECURITY DEFINER), the
-- page's reads go to the reader by default, and none of them is owner-only.
SET LOCAL lock_timeout = '20s';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_session_count (
  instance_id         int NOT NULL,
  snapshot_at         timestamptz NOT NULL,
  user_running        int, user_sleeping int, user_dormant int, user_preconnect int, user_other int,
  system_running      int, system_sleeping int, system_dormant int, system_preconnect int, system_other int,
  req_user_running    int, req_user_runnable int, req_user_suspended int, req_user_sleeping int, req_user_background int, req_user_other int,
  req_system_running  int, req_system_runnable int, req_system_suspended int, req_system_sleeping int, req_system_background int, req_system_other int,
  waiting_tasks       int,          -- the waiting tasks of user sessions, the benign waits left out
  waiting_longest_ms  bigint,
  own_sessions        int,          -- pgvigil's own sessions, left out of every count above
  PRIMARY KEY (instance_id, snapshot_at)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_session_by (
  instance_id      int NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  dimension        text NOT NULL CHECK (dimension IN ('login', 'status', 'interface', 'address', 'isolation')),
  name             text,                       -- NULL = the sessions with no value (a system session has no connection)
  is_other         boolean NOT NULL DEFAULT false,   -- the names past the 50 largest of the dimension, as one row
  sessions         int, user_sessions int, system_sessions int, running int, sleeping int,
  cpu_ms           bigint, reads bigint, writes bigint,
  newest_login     timestamptz
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_session_by_key_idx ON pgvigil.mssql_session_by (instance_id, snapshot_at, dimension);

-- payload: one 'counts' row {user_running, ..., waiting_tasks, waiting_longest_ms, own_sessions}; a second import at
-- one snapshot time replaces the first.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_sessions(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_c jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_sessions'), p_instance_id);
  PERFORM pgvigil.ensure_month_partition('mssql_session_count', p_snapshot_at);
  SELECT r INTO v_c FROM jsonb_array_elements(pgvigil.mssql_rows(p_payload)) r WHERE r->>'kind' = 'counts' LIMIT 1;
  DELETE FROM pgvigil.mssql_session_count WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  IF v_c IS NULL THEN
    RETURN;
  END IF;
  INSERT INTO pgvigil.mssql_session_count (instance_id, snapshot_at,
      user_running, user_sleeping, user_dormant, user_preconnect, user_other,
      system_running, system_sleeping, system_dormant, system_preconnect, system_other,
      req_user_running, req_user_runnable, req_user_suspended, req_user_sleeping, req_user_background, req_user_other,
      req_system_running, req_system_runnable, req_system_suspended, req_system_sleeping, req_system_background, req_system_other,
      waiting_tasks, waiting_longest_ms, own_sessions)
  VALUES (p_instance_id, p_snapshot_at,
      (v_c->>'user_running')::int, (v_c->>'user_sleeping')::int, (v_c->>'user_dormant')::int, (v_c->>'user_preconnect')::int, (v_c->>'user_other')::int,
      (v_c->>'system_running')::int, (v_c->>'system_sleeping')::int, (v_c->>'system_dormant')::int, (v_c->>'system_preconnect')::int,
      (v_c->>'system_other')::int,
      (v_c->>'req_user_running')::int, (v_c->>'req_user_runnable')::int, (v_c->>'req_user_suspended')::int, (v_c->>'req_user_sleeping')::int,
      (v_c->>'req_user_background')::int, (v_c->>'req_user_other')::int,
      (v_c->>'req_system_running')::int, (v_c->>'req_system_runnable')::int, (v_c->>'req_system_suspended')::int, (v_c->>'req_system_sleeping')::int,
      (v_c->>'req_system_background')::int, (v_c->>'req_system_other')::int,
      (v_c->>'waiting_tasks')::int, (v_c->>'waiting_longest_ms')::bigint, (v_c->>'own_sessions')::int);
END $$;

DO $$ BEGIN
  IF to_regprocedure('pgvigil.import_mssql_activity_0124(int, timestamptz, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_activity(int, timestamptz, jsonb) RENAME TO import_mssql_activity_0124;
  END IF;
END $$;

-- payload: 0124's rows, and 'session_by' rows {dimension, name, is_other 0 | 1, sessions, user_sessions, system_sessions,
-- running, sleeping, cpu_ms, reads, writes, newest_login}. Lock order: 0124's parents (in its name order), then
-- mssql_session_by.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_activity(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.import_mssql_activity_0124(p_instance_id, p_snapshot_at, p_payload);
  PERFORM pgvigil.ensure_month_partition('mssql_session_by', p_snapshot_at);
  DELETE FROM pgvigil.mssql_session_by WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_session_by (instance_id, snapshot_at, dimension, name, is_other, sessions, user_sessions,
      system_sessions, running, sleeping, cpu_ms, reads, writes, newest_login)
  SELECT p_instance_id, p_snapshot_at, r->>'dimension', r->>'name', coalesce((r->>'is_other')::int, 0) = 1,
         (r->>'sessions')::int, (r->>'user_sessions')::int, (r->>'system_sessions')::int, (r->>'running')::int,
         (r->>'sleeping')::int, (r->>'cpu_ms')::bigint, (r->>'reads')::bigint, (r->>'writes')::bigint,
         (r->>'newest_login')::timestamptz
    FROM jsonb_array_elements(pgvigil.mssql_rows(p_payload)) r
   WHERE r->>'kind' = 'session_by' AND r->>'dimension' IN ('login', 'status', 'interface', 'address', 'isolation');
END $$;

-- ---- the page's reads (internal/web/q_mssql_sessions.go) --------------------------------------------------------------

-- the per-minute counts over the range
CREATE OR REPLACE FUNCTION pgvigil.mssql_session_counts_between(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS SETOF pgvigil.mssql_session_count LANGUAGE sql STABLE AS $$
  SELECT * FROM pgvigil.mssql_session_count
   WHERE instance_id = p_instance_id AND snapshot_at > p_from AND snapshot_at <= p_to
   ORDER BY snapshot_at
$$;

-- the group reads' times over the range, newest first (the page's 'at' picker)
CREATE OR REPLACE FUNCTION pgvigil.mssql_session_by_reads(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz) LANGUAGE sql STABLE AS $$
  SELECT DISTINCT b.snapshot_at FROM pgvigil.mssql_session_by b
   WHERE b.instance_id = p_instance_id AND b.snapshot_at > p_from AND b.snapshot_at <= p_to
   ORDER BY 1 DESC
$$;

-- one dimension's rows at a read: p_at, else the newest read in the range; the 'other' row last
CREATE OR REPLACE FUNCTION pgvigil.mssql_session_by_at(p_instance_id int, p_from timestamptz, p_to timestamptz, p_dimension text,
                                                       p_at timestamptz DEFAULT NULL)
RETURNS TABLE (snapshot_at timestamptz, name text, is_other boolean, sessions int, user_sessions int, system_sessions int,
               running int, sleeping int, cpu_ms bigint, reads bigint, writes bigint, newest_login timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT b.snapshot_at, b.name, b.is_other, b.sessions, b.user_sessions, b.system_sessions, b.running, b.sleeping,
         b.cpu_ms, b.reads, b.writes, b.newest_login
    FROM pgvigil.mssql_session_by b
   WHERE b.instance_id = p_instance_id AND b.dimension = p_dimension
     AND b.snapshot_at = coalesce(p_at, (SELECT max(x.snapshot_at) FROM pgvigil.mssql_session_by x
                                          WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to))
   ORDER BY b.is_other, b.sessions DESC, b.name NULLS LAST
$$;

-- the top requests over the range (SQLWATCH PBI#10): each request (session, request id, start time) at its largest
-- figure, the p_n largest per measure; from mssql_requests, which keeps user requests and sessions with an open
-- transaction only. The statement text is the caller's to show under the query_text policy (text_id).
CREATE OR REPLACE FUNCTION pgvigil.mssql_requests_top(p_instance_id int, p_from timestamptz, p_to timestamptz, p_n int)
RETURNS TABLE (measure text, rank int, value bigint, session_id int, request_id int, start_time timestamptz,
               first_seen timestamptz, last_seen timestamptz, login_name text, program_name text, host_name text,
               database_name text, text_id bigint)
LANGUAGE sql STABLE AS $$
  WITH r AS (
    SELECT q.session_id, q.request_id, q.start_time, min(q.snapshot_at) AS first_seen, max(q.snapshot_at) AS last_seen,
           max(q.cpu_ms) AS cpu_ms, max(q.logical_reads) AS logical_reads, max(q.tempdb_alloc_kb) AS tempdb_alloc_kb,
           max(q.granted_memory_kb) AS granted_memory_kb, max(q.elapsed_ms) AS elapsed_ms
      FROM pgvigil.mssql_requests q
     WHERE q.instance_id = p_instance_id AND q.snapshot_at > p_from AND q.snapshot_at <= p_to
       AND q.request_id IS NOT NULL AND q.start_time IS NOT NULL
     GROUP BY q.session_id, q.request_id, q.start_time),
  m AS (
    SELECT x.measure, x.value, r.*, row_number() OVER (PARTITION BY x.measure ORDER BY x.value DESC, r.start_time, r.session_id) AS rk
      FROM r CROSS JOIN LATERAL (VALUES ('cpu_ms', r.cpu_ms), ('logical_reads', r.logical_reads), ('tempdb_alloc_kb', r.tempdb_alloc_kb),
                                        ('granted_memory_kb', r.granted_memory_kb), ('elapsed_ms', r.elapsed_ms)) x(measure, value)
     WHERE x.value > 0)
  -- only the ranked requests are looked up (at most 5 x 25): the login, program, host and database of the request's newest
  -- row (its last_seen) and its newest statement text within its own lifetime; each lookup an (instance_id, snapshot_at)
  -- index range of the request's day partitions (review 413a finding 2: no sorted array_agg per request of the window)
  SELECT m.measure, m.rk::int, m.value, m.session_id, m.request_id, m.start_time, m.first_seen, m.last_seen, d.login_name,
         d.program_name, d.host_name, d.database_name, tx.text_id
    FROM m
    LEFT JOIN LATERAL (SELECT q.login_name, q.program_name, q.host_name, q.database_name FROM pgvigil.mssql_requests q
                        WHERE q.instance_id = p_instance_id AND q.snapshot_at = m.last_seen AND q.session_id = m.session_id
                          AND q.request_id = m.request_id AND q.start_time = m.start_time
                        LIMIT 1) d ON true
    LEFT JOIN LATERAL (SELECT q.text_id FROM pgvigil.mssql_requests q
                        WHERE q.instance_id = p_instance_id AND q.snapshot_at >= m.first_seen AND q.snapshot_at <= m.last_seen
                          AND q.session_id = m.session_id AND q.request_id = m.request_id AND q.start_time = m.start_time
                          AND q.text_id IS NOT NULL
                        ORDER BY q.snapshot_at DESC LIMIT 1) tx ON true
   WHERE m.rk <= greatest(1, least(p_n, 25))
   ORDER BY m.measure, m.rk
$$;
