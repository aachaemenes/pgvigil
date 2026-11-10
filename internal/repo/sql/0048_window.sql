-- 0048: long runs and idle transactions over a chosen window (the Running queries tab's window section).
-- pgvigil.long_runs_in_window is slow_in_window (0016) with three changes: an idle-in-transaction session is timed
-- from state_change (how long it has sat idle; its transaction age rides beside it as txn_secs, which is what
-- slow_in_window reports as the duration), the client address is returned, and the rows can be narrowed by state
-- ('active', 'idle' = idle in transaction and its aborted form; NULL = both), user, database and application (exact
-- matches). One row per phase of an execution seen in the window - a session (pid, backend_start), its statement
-- (query_start) and whether it was running or sitting idle - at the largest duration any sample saw, so a statement
-- that ran and whose session then sat idle in its transaction is two rows (the run, then the idle), each number
-- matching the state it shows. txn_secs is NULL for a session with no transaction (a plain idle blocker a waiter
-- named). Sampled once a minute, so a duration is a floor and a run shorter than the sampling interval can go unseen.
-- slow_in_window stays as it is for its older callers.
CREATE OR REPLACE FUNCTION pgvigil.long_runs_in_window(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                                       p_min_secs int DEFAULT 5, p_state text DEFAULT NULL,
                                                       p_usename text DEFAULT NULL, p_datname text DEFAULT NULL,
                                                       p_app text DEFAULT NULL, p_limit int DEFAULT 200)
RETURNS TABLE (pid int, backend_start timestamptz, query_start timestamptz, first_seen timestamptz, last_seen timestamptz,
               samples bigint, at_least_secs int, txn_secs int, state text, datname text, usename text,
               application_name text, client text, top_wait text, was_blocked boolean, was_blocker boolean,
               query_id bigint, query text)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT s.*,
           extract(epoch FROM s.snapshot_at - CASE WHEN s.state = 'active' THEN s.query_start
                                                   ELSE coalesce(s.state_change, s.xact_start, s.query_start) END) AS secs,
           extract(epoch FROM s.snapshot_at - s.xact_start) AS tsecs,
           (s.state = 'active') AS is_active,
           coalesce(s.wait_event_type || ':' || s.wait_event, 'CPU / not waiting') AS wait
      FROM pgvigil.activity_sample s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at >= p_from AND s.snapshot_at <= p_to
       AND s.backend_type IS DISTINCT FROM 'autovacuum worker'
       AND (p_state IS NULL OR (p_state = 'active' AND s.state = 'active')
                            OR (p_state = 'idle' AND s.state LIKE 'idle in transaction%'))
       AND (p_usename IS NULL OR s.usename = p_usename)
       AND (p_datname IS NULL OR s.datname = p_datname)
       AND (p_app IS NULL OR s.application_name = p_app)
  ), e AS (
    SELECT s.pid, s.backend_start, s.query_start, min(s.snapshot_at) AS first_seen, max(s.snapshot_at) AS last_seen,
           count(*) AS samples, max(s.secs)::int AS at_least_secs, max(s.tsecs)::int AS txn_secs,
           (array_agg(s.state ORDER BY s.snapshot_at DESC))[1] AS state,
           min(s.datname) AS datname, min(s.usename) AS usename, min(s.application_name) AS application_name,
           min(s.client) AS client,
           mode() WITHIN GROUP (ORDER BY s.wait) AS top_wait,
           bool_or(cardinality(s.blocking_pids) > 0) AS was_blocked, bool_or(s.is_blocker) AS was_blocker,
           max(s.query_id) AS query_id, (array_agg(s.query_hash ORDER BY s.snapshot_at DESC))[1] AS query_hash
      FROM s
     GROUP BY s.pid, s.backend_start, s.query_start, s.is_active
  )
  SELECT e.pid, e.backend_start, e.query_start, e.first_seen, e.last_seen, e.samples, e.at_least_secs, e.txn_secs, e.state,
         e.datname, e.usename, e.application_name, e.client, e.top_wait, e.was_blocked, e.was_blocker, e.query_id,
         (SELECT q.query FROM pgvigil.query_text q WHERE q.query_hash = e.query_hash)
    FROM e
   WHERE e.at_least_secs >= coalesce(p_min_secs, 0)
   ORDER BY e.at_least_secs DESC, e.first_seen
   LIMIT p_limit
$$;
