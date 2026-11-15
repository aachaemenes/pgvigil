-- 0165: blocking counted in WAITS, not in reports or samples (PerformanceMonitor 3.13's rule, BlockingWaits.cs).
--
-- A wait is one blocked session behind one blocking session over one stretch of time. SQL Server writes a
-- blocked-process report every threshold seconds while a session stays blocked (a 65 s wait at the 5 s threshold is
-- about 12 reports); a calendar or a chip that counts the reports counts one wait twelve times.
--
--   mssql_block_waits(instance, from, to)   one row per SQL Server wait whose last sight falls in (from, to]: the pair,
--                                           its start (the report's time less its wait), its last sight, its longest
--                                           wait, the reports or snapshots it was seen in, and the source. A report
--                                           belongs to the pair's current wait when its start is within 2 s of the
--                                           previous report's start and not past that report's own time by more than
--                                           150 ms (a wait that ended and a new one); a self-wait (a session blocked
--                                           by itself) is no wait. Hours with no report at all (the capture stopped,
--                                           or none installed) are read from the blocked rows of the requests
--                                           snapshots by the same rule (source 'snapshot').
--   pg_block_waits(instance, from, to)      one row per PostgreSQL wait: a session's Lock waits in activity_sample under
--                                           one statement (pid, backend_start, query_start), split where the samples
--                                           leave a gap longer than two of the instance's sample intervals.

CREATE OR REPLACE FUNCTION pgvigil.mssql_block_waits(p_instance int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (blocked_spid int, blocking_spid int, started_at timestamptz, last_seen_at timestamptz, wait_ms bigint, seen int, source text)
LANGUAGE sql STABLE AS $$
  WITH rep AS (
    -- the reports: from an hour before the window, so a wait that started before it is one wait, not a new one
    SELECT b.blocked_spid AS a, b.blocking_spid AS h, b.event_at AS at, coalesce(b.wait_ms, 0) AS w,
           b.event_at - make_interval(secs => coalesce(b.wait_ms, 0) / 1000.0) AS st
      FROM pgvigil.mssql_blocked_reports b
     WHERE b.instance_id = p_instance AND b.event_at > p_from - interval '1 hour' AND b.event_at <= p_to
       AND b.blocked_spid IS NOT NULL AND b.blocking_spid IS NOT NULL AND b.blocked_spid <> b.blocking_spid
  ), hours AS (
    SELECT DISTINCT date_trunc('hour', r.at) AS hr FROM rep r
  ), snap AS (
    -- an hour with no report: the requests snapshots' blocked rows, the wait as the DMV gives it
    SELECT q.session_id AS a, q.blocking_session_id AS h, q.snapshot_at AS at, coalesce(q.wait_ms, 0) AS w,
           q.snapshot_at - make_interval(secs => coalesce(q.wait_ms, 0) / 1000.0) AS st
      FROM pgvigil.mssql_requests q
     WHERE q.instance_id = p_instance AND q.snapshot_at > p_from - interval '1 hour' AND q.snapshot_at <= p_to
       AND q.blocking_session_id > 0 AND q.blocking_session_id <> q.session_id
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
  HAVING max(n.at) > p_from
$$;

CREATE OR REPLACE FUNCTION pgvigil.pg_block_waits(p_instance int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (pid int, started_at timestamptz, last_seen_at timestamptz, wait_ms bigint, seen int)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT a.pid AS p, a.backend_start AS bs, a.query_start AS qs, a.snapshot_at AS at
      FROM pgvigil.activity_sample a
     WHERE a.instance_id = p_instance AND a.wait_event_type = 'Lock'
       AND a.snapshot_at > p_from - interval '1 hour' AND a.snapshot_at <= p_to
  ), step AS (
    -- the instance's sample interval: the smallest gap between two of its snapshots in the stretch read (15 s by default)
    SELECT coalesce(min(g), interval '15 seconds') AS iv FROM (
      SELECT t.at - lag(t.at) OVER (ORDER BY t.at) AS g
        FROM (SELECT DISTINCT a.snapshot_at AS at FROM pgvigil.activity_sample a
               WHERE a.instance_id = p_instance AND a.snapshot_at > p_from - interval '1 hour' AND a.snapshot_at <= p_to) t) x
     WHERE g > interval '0'
  ), marked AS (
    SELECT s.*, CASE WHEN lag(s.at) OVER w IS NULL OR s.at - lag(s.at) OVER w > 2 * (SELECT iv FROM step) THEN 1 ELSE 0 END AS fresh
      FROM s
    WINDOW w AS (PARTITION BY s.p, s.bs, s.qs ORDER BY s.at)
  ), numbered AS (
    SELECT m.*, sum(m.fresh) OVER (PARTITION BY m.p, m.bs, m.qs ORDER BY m.at ROWS UNBOUNDED PRECEDING) AS n FROM marked m
  )
  SELECT n.p, min(n.at), max(n.at), (extract(epoch FROM max(n.at) - min(n.at)) * 1000)::bigint, count(*)::int
    FROM numbered n
   GROUP BY n.p, n.bs, n.qs, n.n
  HAVING max(n.at) > p_from
$$;
