-- 0075_blocking_history: the PostgreSQL blocking chain history from the activity samples (task 120), with its
-- denominator, and which session pinned the xmin horizon over a window. Read only: functions, no table, no data.
--
--   blocking_history_chains(instance, from, to)   one row per chain head per capture of the window: the head's pid,
--                                                 its session (backend_start) and transaction (xact_start), its state,
--                                                 the sessions behind it at any depth (victims), directly (direct),
--                                                 the depth, the longest-blocked waiter's statement age. Waiters that
--                                                 wait on each other with no head (a cycle caught before
--                                                 deadlock_timeout fired) are one row with head_pid NULL.
--   blocking_history_summary(instance, from, to)  the denominator: captures in the window, captures with blocking, the
--                                                 share, the worst chain's victims and its root's state, captures with
--                                                 a cycle, the first and last capture.
--   blocking_history_episodes(instance, from, to) one row per head TRANSACTION (pid, backend_start, xact_start): first
--                                                 and last capture it headed a chain, the captures it did (samples as
--                                                 root), the states it was seen in, how many of them idle in
--                                                 transaction, the peak victims, direct victims and depth, the longest
--                                                 blocked and its transaction's age at the last capture, its last
--                                                 statement. 500 at most, the most captures first.
--   blocking_history_trend(instance, from, to, step_secs)  per step: captures, captures with blocking, the most
--                                                 sessions blocked in one capture (each once), the longest blocked, the oldest
--                                                 root transaction.
--   xmin_pins(instance, from, to)                 one row per session (pid, backend_start) seen with a backend_xmin in
--                                                 the window: captures with an xmin, captures where it held the OLDEST
--                                                 xmin of its capture (it pinned the horizon), the peak xmin age and the
--                                                 state, transaction age and statement at that peak. 50 at most.
--   xmin_pins_summary(instance, from, to)         captures, captures with any session xmin, the idle-in-transaction
--                                                 sessions, and those none of whose idle samples had an xmin (READ
--                                                 COMMITTED between statements: they hold locks but pin nothing).
--
-- The chain rules are blocking_chains' (0002): only a Lock wait that names a blocker is blocked; a head is a blocker
-- that is not itself such a waiter; the root cause of a chain is the head's transaction and its last statement.
-- Depth is a victim's SHORTEST distance from its head, the largest over the chain. On a lock queue, where each waiter
-- names the holder and every waiter ahead of it, every victim is at distance 1; blocking_chains (a breadth-first walk
-- per waiter that counts the levels it visits) can say 2 there. Heads and victims are the same.
-- The blocked sessions of a capture (blocked_in_capture) count each waiter once, however many heads it is behind.
-- The samples are pg_stat_activity once a minute (active and idle-in-transaction sessions and every named blocker):
-- a chain shorter than a minute can fall between two captures, so every count here is a floor. A waiter's wait is
-- the age of its statement (snapshot_at - query_start): the lock wait itself (pg_locks.waitstart) is not sampled.
-- The history needs only the samples the activity collection already keeps; it goes with their retention (purge).
-- Cost: one pass over the window's activity samples of the instance per call (the sample tables carry no index;
-- monthly partitions prune the range); the page caps the window at seven days.

CREATE OR REPLACE FUNCTION pgvigil.blocking_history_chains(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, head_pid int, head_in_sample boolean, head_backend_start timestamptz,
               head_xact_start timestamptz, head_state text, head_backend_type text, head_usename text, head_datname text,
               head_application text, head_query_hash bigint, head_xact_secs int, head_idle_secs int,
               victims int, direct int, depth int, longest_blocked_secs int, blocked_in_capture int)
LANGUAGE sql STABLE AS $$
WITH RECURSIVE s AS MATERIALIZED (   -- the samples of the captures that hold a Lock waiter (read from the samples
                                     -- themselves: the summary's waiting_lock is a separate read of client backends)
  SELECT y.* FROM (
    SELECT x.snapshot_at, x.pid, x.state, x.wait_event_type, x.blocking_pids, x.backend_start, x.xact_start, x.query_start,
           x.state_change, x.backend_type, x.usename, x.datname, x.application_name, x.query_hash,
           (x.wait_event_type = 'Lock' AND coalesce(cardinality(x.blocking_pids), 0) > 0) AS is_waiter,
           bool_or(x.wait_event_type = 'Lock' AND coalesce(cardinality(x.blocking_pids), 0) > 0) OVER (PARTITION BY x.snapshot_at) AS blocked_capture
      FROM pgvigil.activity_sample x
     WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to) y
   WHERE y.blocked_capture
), e AS MATERIALIZED (           -- waiter -> blocker, a self-reference dropped
  SELECT DISTINCT s.snapshot_at, s.pid AS waiter, b AS blocker
    FROM s, unnest(s.blocking_pids) b
   WHERE s.is_waiter AND b <> s.pid
), heads AS (                    -- a blocker that does not itself wait on a lock behind someone
  SELECT DISTINCT e.snapshot_at, e.blocker AS head
    FROM e
   WHERE NOT EXISTS (SELECT 1 FROM s w WHERE w.snapshot_at = e.snapshot_at AND w.pid = e.blocker AND w.is_waiter)
), reach AS (                    -- (head, waiter, distance): UNION keeps each once, so a lock queue (each waiter names the
                                 -- holder and every waiter ahead of it) grows with n x depth, never with the paths (2^n)
  SELECT h.snapshot_at, h.head, e.waiter AS pid, 1 AS depth
    FROM heads h JOIN e ON e.snapshot_at = h.snapshot_at AND e.blocker = h.head
  UNION
  SELECT r.snapshot_at, r.head, e.waiter, r.depth + 1
    FROM reach r JOIN e ON e.snapshot_at = r.snapshot_at AND e.blocker = r.pid
   WHERE e.waiter <> r.head AND r.depth < 64
), dist AS (                     -- each victim's shortest distance from its head
  SELECT r.snapshot_at, r.head, r.pid, min(r.depth) AS depth FROM reach r GROUP BY 1, 2, 3
), per_head AS (
  SELECT d.snapshot_at, d.head, count(*)::int AS victims, count(*) FILTER (WHERE d.depth = 1)::int AS direct,
         max(d.depth)::int AS depth, max(extract(epoch FROM d.snapshot_at - w.query_start))::int AS longest_blocked_secs
    FROM dist d
    LEFT JOIN s w ON w.snapshot_at = d.snapshot_at AND w.pid = d.pid
   GROUP BY d.snapshot_at, d.head
), cyc AS (                      -- waiters no head reaches: they wait on each other
  SELECT w.snapshot_at, count(*)::int AS victims, max(extract(epoch FROM w.snapshot_at - w.query_start))::int AS longest_blocked_secs
    FROM s w
   WHERE w.is_waiter AND NOT EXISTS (SELECT 1 FROM dist r WHERE r.snapshot_at = w.snapshot_at AND r.pid = w.pid)
   GROUP BY w.snapshot_at
), nb AS (                       -- the sessions blocked in each capture, each once however many heads it is behind
  SELECT s.snapshot_at, count(*) FILTER (WHERE s.is_waiter)::int AS blocked FROM s GROUP BY s.snapshot_at
)
SELECT p.snapshot_at, p.head, hs.pid IS NOT NULL, hs.backend_start, hs.xact_start, hs.state, hs.backend_type, hs.usename,
       hs.datname, hs.application_name, hs.query_hash,
       extract(epoch FROM p.snapshot_at - hs.xact_start)::int,
       CASE WHEN hs.state LIKE 'idle%' THEN extract(epoch FROM p.snapshot_at - hs.state_change)::int END,
       p.victims, p.direct, p.depth, p.longest_blocked_secs, nb.blocked
  FROM per_head p
  JOIN nb ON nb.snapshot_at = p.snapshot_at
  LEFT JOIN s hs ON hs.snapshot_at = p.snapshot_at AND hs.pid = p.head
UNION ALL
SELECT c.snapshot_at, NULL, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       c.victims, NULL, NULL, c.longest_blocked_secs, nb.blocked
  FROM cyc c
  JOIN nb ON nb.snapshot_at = c.snapshot_at
$$;

CREATE OR REPLACE FUNCTION pgvigil.blocking_history_summary(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (captures int, with_blocking int, pct_with_blocking numeric, worst_victims int, worst_root_state text,
               worst_root_pid int, worst_at timestamptz, with_cycle int, first_capture timestamptz, last_capture timestamptz)
LANGUAGE sql STABLE AS $$
WITH c AS (SELECT * FROM pgvigil.blocking_history_chains(p_instance_id, p_from, p_to)),
cap AS (
  SELECT count(*)::int AS n, min(a.snapshot_at) AS first_at, max(a.snapshot_at) AS last_at
    FROM pgvigil.activity_summary a
   WHERE a.instance_id = p_instance_id AND a.snapshot_at > p_from AND a.snapshot_at <= p_to
), worst AS (
  SELECT c.victims, c.head_state, c.head_pid, c.snapshot_at FROM c WHERE c.head_pid IS NOT NULL
   ORDER BY c.victims DESC, c.snapshot_at DESC LIMIT 1
)
SELECT cap.n, (SELECT count(DISTINCT c.snapshot_at)::int FROM c),
       round(100.0 * (SELECT count(DISTINCT c.snapshot_at) FROM c) / nullif(cap.n, 0), 1),
       (SELECT worst.victims FROM worst),
       (SELECT coalesce(worst.head_state, CASE WHEN worst.head_pid IS NOT NULL THEN 'not in the sample' END) FROM worst),
       (SELECT worst.head_pid FROM worst), (SELECT worst.snapshot_at FROM worst),
       (SELECT count(DISTINCT c.snapshot_at)::int FROM c WHERE c.head_pid IS NULL),
       cap.first_at, cap.last_at
  FROM cap
$$;

CREATE OR REPLACE FUNCTION pgvigil.blocking_history_episodes(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (head_pid int, head_backend_start timestamptz, head_xact_start timestamptz, first_at timestamptz,
               last_at timestamptz, samples int, states text, idle_in_txn_samples int, last_state text, head_backend_type text,
               head_usename text, head_datname text, head_application text, victims int, direct int, depth int,
               longest_blocked_secs int, xact_secs int, head_query text)
LANGUAGE sql STABLE AS $$
SELECT c.head_pid, c.head_backend_start, c.head_xact_start, min(c.snapshot_at), max(c.snapshot_at), count(*)::int,
       string_agg(DISTINCT coalesce(c.head_state, 'not in the sample'), ', '),
       count(*) FILTER (WHERE c.head_state LIKE 'idle in transaction%')::int,
       (array_agg(coalesce(c.head_state, 'not in the sample') ORDER BY c.snapshot_at DESC))[1],
       (array_agg(c.head_backend_type ORDER BY c.snapshot_at DESC))[1],
       (array_agg(c.head_usename ORDER BY c.snapshot_at DESC))[1],
       (array_agg(c.head_datname ORDER BY c.snapshot_at DESC))[1],
       (array_agg(c.head_application ORDER BY c.snapshot_at DESC))[1],
       max(c.victims), max(c.direct), max(c.depth), max(c.longest_blocked_secs),
       (array_agg(c.head_xact_secs ORDER BY c.snapshot_at DESC))[1],
       (SELECT q.query FROM pgvigil.query_text q
         WHERE q.query_hash = (array_agg(c.head_query_hash ORDER BY c.snapshot_at DESC))[1])
  FROM pgvigil.blocking_history_chains(p_instance_id, p_from, p_to) c
 WHERE c.head_pid IS NOT NULL
 GROUP BY c.head_pid, c.head_backend_start, c.head_xact_start
 ORDER BY count(*) DESC, max(c.victims) DESC, max(c.snapshot_at) DESC
 LIMIT 500
$$;

CREATE OR REPLACE FUNCTION pgvigil.blocking_history_trend(p_instance_id int, p_from timestamptz, p_to timestamptz, p_step_secs int)
RETURNS TABLE (snapshot_at timestamptz, captures int, with_blocking int, blocked_max int, longest_blocked_secs int,
               oldest_root_xact_secs int)
LANGUAGE sql STABLE AS $$
WITH step AS (SELECT greatest(60, coalesce(p_step_secs, 60)) AS secs),
per_snap AS (
  SELECT c.snapshot_at, max(c.blocked_in_capture) AS blocked, max(c.longest_blocked_secs) AS longest, max(c.head_xact_secs) AS root_xact
    FROM pgvigil.blocking_history_chains(p_instance_id, p_from, p_to) c
   GROUP BY c.snapshot_at
)
SELECT to_timestamp(floor(extract(epoch FROM a.snapshot_at) / step.secs) * step.secs), count(*)::int,
       count(p.snapshot_at)::int, coalesce(max(p.blocked), 0), max(p.longest), max(p.root_xact)
  FROM pgvigil.activity_summary a
  CROSS JOIN step
  LEFT JOIN per_snap p ON p.snapshot_at = a.snapshot_at
 WHERE a.instance_id = p_instance_id AND a.snapshot_at > p_from AND a.snapshot_at <= p_to
 GROUP BY 1
 ORDER BY 1
$$;

CREATE OR REPLACE FUNCTION pgvigil.xmin_pins(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (pid int, backend_start timestamptz, samples int, pinned_samples int, peak_xmin_age int, peak_at timestamptz,
               state_at_peak text, xact_secs_at_peak int, backend_type text, usename text, datname text,
               application_name text, client text, first_at timestamptz, last_at timestamptz, query_at_peak text)
LANGUAGE sql STABLE AS $$
WITH s AS MATERIALIZED (
  SELECT x.snapshot_at, x.pid, x.backend_start, x.backend_xmin_age, x.state, x.xact_start, x.backend_type, x.usename,
         x.datname, x.application_name, x.client, x.query_hash,
         x.backend_xmin_age = max(x.backend_xmin_age) OVER (PARTITION BY x.snapshot_at) AS is_oldest
    FROM pgvigil.activity_sample x
   WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to AND x.backend_xmin_age IS NOT NULL
), g AS (
  SELECT s.pid, s.backend_start, count(*)::int AS samples, count(*) FILTER (WHERE s.is_oldest)::int AS pinned,
         max(s.backend_xmin_age) AS peak, min(s.snapshot_at) AS first_at, max(s.snapshot_at) AS last_at
    FROM s
   GROUP BY s.pid, s.backend_start
), p AS (                        -- the capture of each session's peak xmin age (the newest of a tie)
  SELECT DISTINCT ON (s.pid, s.backend_start) s.*
    FROM s
   ORDER BY s.pid, s.backend_start, s.backend_xmin_age DESC, s.snapshot_at DESC
)
SELECT g.pid, g.backend_start, g.samples, g.pinned, g.peak, p.snapshot_at, p.state,
       extract(epoch FROM p.snapshot_at - p.xact_start)::int, p.backend_type, p.usename, p.datname,
       p.application_name, p.client, g.first_at, g.last_at,
       (SELECT q.query FROM pgvigil.query_text q WHERE q.query_hash = p.query_hash)
  FROM g
  JOIN p ON p.pid = g.pid AND p.backend_start IS NOT DISTINCT FROM g.backend_start
 ORDER BY g.pinned DESC, g.peak DESC, g.last_at DESC
 LIMIT 50
$$;

CREATE OR REPLACE FUNCTION pgvigil.xmin_pins_summary(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (captures int, with_xmin int, idle_in_txn_sessions int, idle_in_txn_no_xmin int)
LANGUAGE sql STABLE AS $$
WITH x AS (
  SELECT x.snapshot_at, x.pid, x.backend_start, x.state, x.backend_xmin_age
    FROM pgvigil.activity_sample x
   WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
), per_session AS (              -- an idle-in-transaction session none of whose IDLE samples showed an xmin pinned
                                 -- nothing while it sat idle (an active sample's xmin is its running statement's)
  SELECT bool_or(x.state LIKE 'idle in transaction%') AS idle_txn,
         bool_or(x.state LIKE 'idle in transaction%' AND x.backend_xmin_age IS NOT NULL) AS pinned_idle
    FROM x GROUP BY x.pid, x.backend_start
)
SELECT (SELECT count(*)::int FROM pgvigil.activity_summary a
         WHERE a.instance_id = p_instance_id AND a.snapshot_at > p_from AND a.snapshot_at <= p_to),
       (SELECT count(DISTINCT x.snapshot_at)::int FROM x WHERE x.backend_xmin_age IS NOT NULL),
       (SELECT count(*)::int FROM per_session WHERE idle_txn),
       (SELECT count(*)::int FROM per_session WHERE idle_txn AND NOT pinned_idle)
$$;
