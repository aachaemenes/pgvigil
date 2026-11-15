-- 0165: blocking counted in WAITS, not in reports or samples (PerformanceMonitor 3.13's rule, BlockingWaits.cs).
--
-- A wait is one blocked session behind one blocking session over one stretch of time. SQL Server writes a
-- blocked-process report every threshold seconds while a session stays blocked (a 65 s wait at the 5 s threshold is
-- about 12 reports); a calendar or a chip that counts the reports counts one wait twelve times.
--
--   mssql_block_waits(instance, from, to)   one row per SQL Server wait whose last sight falls in (from, to] (read an
--                                           hour either side: a wait still seen after to belongs to a later window,
--                                           so each wait is in one window, an hour's or a day's, never two): the pair,
--                                           its start (the report's time less its wait), its last sight, its longest
--                                           wait, the reports or snapshots it was seen in, and the source. A report
--                                           belongs to the pair's current wait when its start is within 2 s of the
--                                           previous report's start and not past that report's own time by more than
--                                           150 ms (a wait that ended and a new one); a self-wait (a session blocked
--                                           by itself) is no wait. Hours with no report at all (the capture stopped,
--                                           none installed, or nothing over the threshold) are read from the requests
--                                           snapshots' lock waits at the server's blocked process threshold or longer
--                                           (5 s at least) by the same rule (source 'snapshot').
--   pg_block_waits(instance, from, to)      one row per PostgreSQL wait whose last sight falls in (from, to] (read as
--                                           above): a session's Lock waits in activity_sample under
--                                           one statement (pid, backend_start, query_start), split where a sample is
--                                           missed (a gap over 1.5 of the instance's sample intervals: the median gap
--                                           between its snapshots); its length the first to the last sample of the run.

CREATE OR REPLACE FUNCTION pgvigil.mssql_block_waits(p_instance int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (blocked_spid int, blocking_spid int, started_at timestamptz, last_seen_at timestamptz, wait_ms bigint, seen int, source text)
LANGUAGE sql STABLE AS $$
  WITH rep AS (
    -- the reports: from an hour before the window, so a wait that started before it is one wait, not a new one
    SELECT b.blocked_spid AS a, b.blocking_spid AS h, b.event_at AS at, coalesce(b.wait_ms, 0) AS w,
           b.event_at - make_interval(secs => coalesce(b.wait_ms, 0) / 1000.0) AS st
      FROM pgvigil.mssql_blocked_reports b
     WHERE b.instance_id = p_instance AND b.event_at > p_from - interval '1 hour' AND b.event_at <= p_to + interval '1 hour'
       AND b.blocked_spid IS NOT NULL AND b.blocking_spid IS NOT NULL AND b.blocked_spid <> b.blocking_spid
  ), hours AS (
    SELECT DISTINCT date_trunc('hour', r.at) AS hr FROM rep r
  ), thr AS (
    -- the server's blocked process threshold (sys.configurations as last read), never under 5 s (below it the deadlock
    -- monitor runs constantly: checks.go), 5 s where none is read
    SELECT greatest(5, coalesce(max(c.value_in_use), 0)) * 1000 AS ms FROM pgvigil.mssql_config c
     WHERE c.instance_id = p_instance AND c.name IN ('blocked process threshold (s)', 'blocked process threshold')
  ), snap AS (
    -- an hour with no report: the requests snapshots' blocked rows, the wait as the DMV gives it - only a lock wait
    -- (LCK_M_*) at the threshold or longer, what a report would have shown: an hour with no report may as well be one
    -- where nothing passed the threshold, and a short lock or a page latch with a blocking session is no wait here
    SELECT q.session_id AS a, q.blocking_session_id AS h, q.snapshot_at AS at, coalesce(q.wait_ms, 0) AS w,
           q.snapshot_at - make_interval(secs => coalesce(q.wait_ms, 0) / 1000.0) AS st
      FROM pgvigil.mssql_requests q
     WHERE q.instance_id = p_instance AND q.snapshot_at > p_from - interval '1 hour' AND q.snapshot_at <= p_to + interval '1 hour'
       AND q.blocking_session_id > 0 AND q.blocking_session_id <> q.session_id
       AND left(q.wait_type, 6) = 'LCK_M_' AND coalesce(q.wait_ms, 0) >= (SELECT ms FROM thr)
       AND date_trunc('hour', q.snapshot_at) NOT IN (SELECT hr FROM hours)
  ), seen AS (
    SELECT r.*, 'report'::text AS src FROM rep r
    UNION ALL
    SELECT s.*, 'snapshot'::text FROM snap s
  ), marked AS (
    SELECT x.*,
           CASE WHEN lag(x.st) OVER w IS NULL
                  OR abs(extract(epoch FROM x.st - lag(x.st) OVER w)) > 2
                  OR x.st > lag(x.at) OVER w + interval '150 milliseconds'
                THEN 1 ELSE 0 END AS fresh
      FROM seen x
    WINDOW w AS (PARTITION BY x.src, x.a, x.h ORDER BY x.at)
  ), numbered AS (
    SELECT m.*, sum(m.fresh) OVER (PARTITION BY m.src, m.a, m.h ORDER BY m.at ROWS UNBOUNDED PRECEDING) AS n FROM marked m
  )
  SELECT n.a, n.h, min(n.st), max(n.at), max(n.w)::bigint, count(*)::int, n.src
    FROM numbered n
   GROUP BY n.src, n.a, n.h, n.n
  HAVING max(n.at) > p_from AND max(n.at) <= p_to
$$;

CREATE OR REPLACE FUNCTION pgvigil.pg_block_waits(p_instance int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (pid int, started_at timestamptz, last_seen_at timestamptz, wait_ms bigint, seen int)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT a.pid AS p, a.backend_start AS bs, a.query_start AS qs, a.snapshot_at AS at
      FROM pgvigil.activity_sample a
     WHERE a.instance_id = p_instance AND a.wait_event_type = 'Lock'
       AND a.snapshot_at > p_from - interval '1 hour' AND a.snapshot_at <= p_to + interval '1 hour'
  ), step AS (
    -- the instance's sample interval: the median gap between two of its snapshots in the stretch read (one extra or
    -- near-duplicate snapshot does not move it; the activity collection runs once a minute by default)
    SELECT coalesce(percentile_disc(0.5) WITHIN GROUP (ORDER BY g), interval '60 seconds') AS iv FROM (
      SELECT t.at - lag(t.at) OVER (ORDER BY t.at) AS g
        FROM (SELECT DISTINCT a.snapshot_at AS at FROM pgvigil.activity_sample a
               WHERE a.instance_id = p_instance AND a.snapshot_at > p_from - interval '1 hour' AND a.snapshot_at <= p_to + interval '1 hour') t) x
     WHERE g > interval '0'
  ), marked AS (
    SELECT s.*, CASE WHEN lag(s.at) OVER w IS NULL OR s.at - lag(s.at) OVER w > 1.5 * (SELECT iv FROM step) THEN 1 ELSE 0 END AS fresh
      FROM s
    WINDOW w AS (PARTITION BY s.p, s.bs, s.qs ORDER BY s.at)
  ), numbered AS (
    SELECT m.*, sum(m.fresh) OVER (PARTITION BY m.p, m.bs, m.qs ORDER BY m.at ROWS UNBOUNDED PRECEDING) AS n FROM marked m
  )
  SELECT n.p, min(n.at), max(n.at), (extract(epoch FROM max(n.at) - min(n.at)) * 1000)::bigint, count(*)::int
    FROM numbered n
   GROUP BY n.p, n.bs, n.qs, n.n
  HAVING max(n.at) > p_from AND max(n.at) <= p_to
$$;


-- ---- the monitor's own deadlocks (PerformanceMonitor Changed 14) ----------------------------------------------------
-- the application name the collector connects with on each SQL Server instance, read once (SELECT APP_NAME()) and
-- stored: a deadlock whose EVERY victim ran under it was the monitor's own reads losing, not the workload's; it stays
-- stored and shown on the Deadlocks page and leaves the counts (the finding, the calendar, the live part)
CREATE TABLE IF NOT EXISTS pgvigil.mssql_monitor_app (
  instance_id int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  app_name    text NOT NULL,
  read_at     timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION pgvigil.mssql_deadlock_is_monitors(p_instance int, p_processes jsonb)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT coalesce((
    SELECT bool_and(coalesce(e->>'program', '') = m.app_name) FILTER (WHERE (e->>'victim')::boolean)
      FROM pgvigil.mssql_monitor_app m, jsonb_array_elements(CASE WHEN jsonb_typeof(p_processes) = 'array' THEN p_processes ELSE '[]'::jsonb END) e
     WHERE m.instance_id = p_instance), false)
$$;

-- the importer: the one before (0116's), renamed import_mssql_xe_pre0165 and called with the other rows; a
-- 'monitor_app' row stores the collector's application name. Renamed once: a rerun finds it.
DO $$
BEGIN
  IF to_regprocedure('pgvigil.import_mssql_xe_pre0165(integer, timestamp with time zone, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_xe(int, timestamptz, jsonb) RENAME TO import_mssql_xe_pre0165;
  END IF;
END $$;
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_xe(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.mssql_monitor_app (instance_id, app_name, read_at)
  SELECT p_instance_id, r->>'app_name', p_snapshot_at FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'monitor_app' AND coalesce(r->>'app_name', '') <> '' LIMIT 1
  ON CONFLICT (instance_id) DO UPDATE SET app_name = EXCLUDED.app_name, read_at = EXCLUDED.read_at;
  PERFORM pgvigil.import_mssql_xe_pre0165(p_instance_id, p_snapshot_at,
    (SELECT coalesce(jsonb_agg(r), '[]'::jsonb) FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' IS DISTINCT FROM 'monitor_app'));
  -- the hours that ended since the last import, rolled for the spike's usual (nothing to do most minutes)
  PERFORM pgvigil.rollup_block_hourly(p_snapshot_at);
END $$;

-- ---- 0065's findings: the head-statement finding's detail in waits; the monitor's own deadlocks not counted ------
CREATE OR REPLACE VIEW pgvigil.mssql_xe_findings AS
WITH dl AS (
  SELECT d.instance_id, count(*) AS n, max(d.event_at) AS last_at,
         (array_agg(d.object_names ORDER BY d.event_at DESC))[1] AS last_objects
    FROM pgvigil.mssql_deadlocks d
   WHERE d.event_at > now() - interval '1 hour'
     AND NOT pgvigil.mssql_deadlock_is_monitors(d.instance_id, d.processes)   -- (0165) the monitor's own: stored, shown, not counted
   GROUP BY d.instance_id
), heads AS (
  SELECT b.instance_id, b.head_key, count(*) AS reports, count(DISTINCT b.blocked_spid) AS blocked_sessions,
         max(b.wait_ms) AS worst_wait_ms, max(b.event_at) AS last_at,
         (array_agg(b.blocking_statement ORDER BY b.event_at DESC))[1] AS statement,
         (array_agg(b.blocking_spid ORDER BY b.event_at DESC))[1] AS spid,
         (array_agg(b.blocking_status ORDER BY b.event_at DESC))[1] AS status,
         -- (0165) the waits these reports belong to (a 65 s wait is one, however many reports it gave)
         (SELECT count(*) FROM pgvigil.mssql_block_waits(b.instance_id, now() - interval '1 hour', now()) w
           WHERE EXISTS (SELECT 1 FROM pgvigil.mssql_blocked_reports r
                          WHERE r.instance_id = b.instance_id AND r.head_key = b.head_key AND r.blocked_spid = w.blocked_spid
                            AND r.blocking_spid = w.blocking_spid AND r.event_at BETWEEN w.started_at AND w.last_seen_at)) AS waits
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
       h.waits || ' wait(s) in the last hour, ' || h.blocked_sessions || ' blocked session(s), the longest wait '
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

-- ---- the hourly rollup and the spike (PerformanceMonitor Fixed 25) -----------------------------------------------
-- one row per instance and finished hour: its waits and its deadlocks (the monitor's own left out; PostgreSQL's from
-- the log), written once: from the instance's first sight, at most 7 days back, each hour once it ended 15 minutes ago
-- (a deadlock imported a minute late and a log read minutes behind are in by then), at most 24 hours per instance per
-- call (a new store's 7 days fill over 7 calls), one caller at a time (an advisory lock; a second caller returns 0).
-- The Extended Events import calls it; any caller may (a repository without SQL Server needs one of its own). The
-- spike's usual reads it: a store kept under 28 days rides on the floor alone
CREATE TABLE IF NOT EXISTS pgvigil.mssql_block_hourly (
  instance_id int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  hour        timestamptz NOT NULL,
  waits       int NOT NULL,
  deadlocks   int NOT NULL,
  PRIMARY KEY (instance_id, hour)
);
CREATE OR REPLACE FUNCTION pgvigil.rollup_block_hourly(p_now timestamptz DEFAULT now())
RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int := 0; r record; v_last timestamptz := date_trunc('hour', p_now - interval '15 minutes') - interval '1 hour';
BEGIN
  -- one roller at a time: concurrent imports cannot see each other's new rows, so each would do the same work and
  -- queue on the key; the one that finds the lock taken leaves the hours to the holder
  IF NOT pg_try_advisory_xact_lock(hashtext('pgvigil.rollup_block_hourly')) THEN
    RETURN 0;
  END IF;
  FOR r IN
    SELECT i.instance_id, i.engine, h.hour
      FROM pgvigil.instances i
      CROSS JOIN LATERAL (SELECT greatest(date_trunc('hour', coalesce(i.first_seen, p_now)), date_trunc('hour', p_now) - interval '7 days',
             coalesce((SELECT max(b.hour) + interval '1 hour' FROM pgvigil.mssql_block_hourly b WHERE b.instance_id = i.instance_id), '-infinity'::timestamptz)) AS h0) f
      CROSS JOIN LATERAL generate_series(f.h0, least(v_last, f.h0 + interval '23 hours'), interval '1 hour') h(hour)
     WHERE i.is_active AND i.engine IN ('sqlserver', 'postgres')
  LOOP
    INSERT INTO pgvigil.mssql_block_hourly (instance_id, hour, waits, deadlocks)
    VALUES (r.instance_id, r.hour,
            CASE WHEN r.engine = 'sqlserver' THEN (SELECT count(*) FROM pgvigil.mssql_block_waits(r.instance_id, r.hour, r.hour + interval '1 hour'))
                 ELSE (SELECT count(*) FROM pgvigil.pg_block_waits(r.instance_id, r.hour, r.hour + interval '1 hour')) END,
            CASE WHEN r.engine = 'sqlserver' THEN
                   (SELECT count(*) FROM pgvigil.mssql_deadlocks d WHERE d.instance_id = r.instance_id AND d.event_at > r.hour
                       AND d.event_at <= r.hour + interval '1 hour' AND NOT pgvigil.mssql_deadlock_is_monitors(d.instance_id, d.processes))
                 ELSE (SELECT count(*) FROM pgvigil.log_events e WHERE e.instance_id = r.instance_id AND e.kind = 'deadlock'
                          AND e.snapshot_at > r.hour AND e.snapshot_at <= r.hour + interval '1 hour') END)
    ON CONFLICT DO NOTHING;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- ---- PostgreSQL deadlocks from the log -----------------------------------------------------------------------------
-- each deadlock's two statements as the log's DETAIL gives them ('Process 4242: UPDATE ...'), sorted, as one pair
CREATE OR REPLACE VIEW pgvigil.pg_deadlock_pairs AS
SELECT e.instance_id, e.snapshot_at AS at,
       (SELECT string_agg(m[1], ' | ' ORDER BY m[1]) FROM regexp_matches(coalesce(e.detail, ''), '^Process \d+: (.*)$', 'gn') m) AS pair
  FROM pgvigil.log_events e
 WHERE e.kind = 'deadlock' AND e.snapshot_at > now() - interval '31 days';

-- ---- the hour arm (PerformanceMonitor Changed 27, Release 6) ------------------------------------------------------
-- 'blocking events in the last hour' (warning): 3 or more waits with the longest 15 s or more, or one of 60 s or more,
-- SQL Server from mssql_block_waits, PostgreSQL from pg_block_waits; beside the snapshot rule 'a blocking chain'
-- (unchanged), and HELD while that one stands for the instance: one finding for one chain
CREATE OR REPLACE VIEW pgvigil.blocking_findings AS
SELECT i.instance_id, 'warning'::text AS severity, 'blocking events in the last hour'::text AS check_name, 'blocking'::text AS object,
       w.last_at AS at,
       w.n || CASE WHEN w.n = 1 THEN ' wait' ELSE ' waits' END || ' in the last hour, the longest ' || round(w.worst / 1000.0, 1) || ' s' AS detail
  FROM pgvigil.instances i
  CROSS JOIN LATERAL (
    SELECT count(*) AS n, max(x.wait_ms) AS worst, max(x.last_seen_at) AS last_at FROM (
      SELECT q.wait_ms, q.last_seen_at FROM pgvigil.mssql_block_waits(i.instance_id, now() - interval '1 hour', now()) q WHERE i.engine = 'sqlserver'
      UNION ALL
      SELECT p.wait_ms, p.last_seen_at FROM pgvigil.pg_block_waits(i.instance_id, now() - interval '1 hour', now()) p WHERE i.engine = 'postgres') x) w
 WHERE i.is_active
   AND (w.n >= 3 AND w.worst >= 15000 OR w.worst >= 60000)
   AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_running_findings f WHERE f.instance_id = i.instance_id AND f.check_name = 'a blocking chain')
UNION ALL
-- the spike: one of the last 4 finished hours at 3 times its usual (the same weekday and hour over the last 4 weeks),
-- the floors 5 waits / 3 deadlocks; under 4 weeks of that hour's history it fires on the floor alone, said so
(SELECT DISTINCT ON (s.instance_id, s.check_name) s.instance_id, 'warning', s.check_name, s.what, s.hour + interval '1 hour',
       s.n || ' ' || s.what || ' in the hour from ' || to_char(s.hour, 'YYYY-MM-DD HH24:00') || ', '
         || CASE WHEN s.samples >= 4 AND s.usual = 0 THEN 'none in this weekday and hour over the 4 weeks before'
                 WHEN s.samples >= 4 THEN round(s.n / s.usual, 1) || ' times its usual of ' || round(s.usual, 1) || ' (this weekday and hour over 4 weeks)'
                 ELSE 'no usual yet (' || s.samples || ' of 4 weeks of history for this hour): fired on the floor of ' || s.floor END
  FROM (
    SELECT h.instance_id, h.hour, k.what, k.check_name, k.floor, k.n,
           (SELECT avg(CASE k.what WHEN 'waits' THEN b.waits ELSE b.deadlocks END) FROM pgvigil.mssql_block_hourly b
             WHERE b.instance_id = h.instance_id AND b.hour IN (h.hour - interval '1 week', h.hour - interval '2 weeks', h.hour - interval '3 weeks', h.hour - interval '4 weeks')) AS usual,
           (SELECT count(*) FROM pgvigil.mssql_block_hourly b
             WHERE b.instance_id = h.instance_id AND b.hour IN (h.hour - interval '1 week', h.hour - interval '2 weeks', h.hour - interval '3 weeks', h.hour - interval '4 weeks')) AS samples
      FROM pgvigil.mssql_block_hourly h
     CROSS JOIN LATERAL (VALUES ('waits', 'blocking at 3x this hour''s usual', 5, h.waits), ('deadlocks', 'deadlocks at 3x this hour''s usual', 3, h.deadlocks)) k(what, check_name, floor, n)
     WHERE h.hour >= date_trunc('hour', now()) - interval '4 hours' AND h.hour < date_trunc('hour', now())) s
 WHERE s.n >= s.floor AND (s.samples < 4 OR s.n >= 3 * s.usual)
 ORDER BY s.instance_id, s.check_name, s.hour DESC)
UNION ALL
-- PostgreSQL deadlocks (from the log): a pair of statements not seen in the 30 days before, or 5 in an hour
SELECT n.instance_id, 'warning', 'a deadlock between a new pair of statements', left(n.pair, 200), n.at,
       'a deadlock between ' || replace(n.pair, ' | ', ' and ') || ', a pair not seen in the 30 days before'
  FROM (SELECT DISTINCT ON (d.instance_id, d.pair) d.* FROM pgvigil.pg_deadlock_pairs d
         WHERE d.at > now() - interval '1 hour' AND d.pair IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM pgvigil.pg_deadlock_pairs o WHERE o.instance_id = d.instance_id AND o.pair = d.pair
                              AND o.at < d.at AND o.at >= d.at - interval '30 days')
         ORDER BY d.instance_id, d.pair, d.at DESC) n
UNION ALL
SELECT d.instance_id, 'warning', 'deadlocks in the last hour', 'deadlocks', max(d.at), count(*) || ' deadlock(s) in the last hour'
  FROM pgvigil.pg_deadlock_pairs d
 WHERE d.at > now() - interval '1 hour'
 GROUP BY d.instance_id
HAVING count(*) >= 5;
