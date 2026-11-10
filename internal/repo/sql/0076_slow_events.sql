-- 0076_slow_events: statements, slow queries and the jobs timeline (parity2 task 121; DBA Dash 04, 16, 71, 81, 90 and
-- Darling 13.8 shot 92).
--
--   1. pgvigil.slow_events_all: every slow event of both engines in one shape, so the Slow queries Group By, its
--      per-event drill and its database filter read one source:
--        PostgreSQL  the server log's slow statements (log_events kind 'slow', both log readers). The log writes a
--                    duration only for a statement that finished, so result is 'OK' and failed is false; the log
--                    line carries no application name (application NULL: the drill fills it from the activity
--                    sample of the same pid during the run, when one was taken); no CPU, reads, writes or rows.
--        SQL Server  the slow capture (mssql_slow_events: rpc_completed, sql_batch_completed and the statement
--                    events), with its CPU, reads, writes, rows, client host, application, login and result
--                    ('OK', 'Error', 'Abort'); failed = a result other than OK. is_statement marks the statement
--                    events (sql_statement_completed, sp_statement_completed): with the capture's statement
--                    events on, one slow procedure call stores its call and its slow statements, so the pages
--                    count the calls (rpc and batch completions) unless asked for every event.
--   2. pgvigil.slow_bucket(ms): DBA Dash's ten duration buckets as 0..9 (under 5 s, 5-10 s, 10-20 s, 20-30 s,
--      30-60 s, 1-5 min, 5-10 min, 10-30 min, 30-60 min, 1 h and over); the page names them.
--   3. pgvigil.stmt_trend(instance, queryid, datname, from, to, secs): one pg_stat_statements row's trend per
--      interval of secs (calls, rows, total and mean time from statements_delta; the longest run of the same shape
--      the log recorded in that interval, which is NULL when the log has none: pg_stat_statements keeps no
--      per-interval maximum).
--   4. pgvigil.slow_trend(instance, shape_key, from, to, secs, min_ms): one slow-event shape's trend per interval
--      (events, mean and longest duration, rows, mean CPU) on either engine.
--
-- No table, no column, no index: the view reads log_events and mssql_slow_events through their (instance_id, time)
-- keys; retention is theirs. Lock footprint: a view and three functions created (no lock on a stored table).

CREATE OR REPLACE VIEW pgvigil.slow_events_all AS
SELECT e.instance_id, i.name AS instance, i.platform, 'postgres'::text AS engine, e.snapshot_at AS at, e.event_key,
       e.duration_ms::numeric AS duration_ms, NULL::numeric AS cpu_ms, NULL::bigint AS logical_reads,
       NULL::bigint AS physical_reads, NULL::bigint AS writes, NULL::bigint AS row_count,
       e.datname AS database_name, e.usename AS user_name, e.client, NULL::text AS application,
       'OK'::text AS result, false AS failed, e.pid AS session_id,
       CASE WHEN e.source LIKE 'serverlog:%' THEN 'server log' ELSE 'CloudWatch' END AS event_type,
       NULL::text AS object_name, e.statement, e.shape_key, false AS is_statement
  FROM pgvigil.log_events e
  JOIN pgvigil.instances i USING (instance_id)
 WHERE e.kind = 'slow'
UNION ALL
SELECT s.instance_id, i.name, i.platform, 'sqlserver', s.event_at, s.event_key,
       s.duration_ms, s.cpu_ms, s.logical_reads, s.physical_reads, s.writes, s.row_count,
       s.database_name, s.login_name, s.host_name, s.program_name,
       s.result, coalesce(s.result <> 'OK', false), s.session_id,
       s.event_name, s.object_name, s.statement, s.shape_key, s.event_name IN ('sql_statement_completed', 'sp_statement_completed')
  FROM pgvigil.mssql_slow_events s
  JOIN pgvigil.instances i USING (instance_id);

-- slow_bucket: DBA Dash's duration buckets; a NULL duration is bucket 0 (it is counted, never dropped)
CREATE OR REPLACE FUNCTION pgvigil.slow_bucket(p_ms numeric)
RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN p_ms IS NULL OR p_ms < 5000 THEN 0
              WHEN p_ms < 10000 THEN 1
              WHEN p_ms < 20000 THEN 2
              WHEN p_ms < 30000 THEN 3
              WHEN p_ms < 60000 THEN 4
              WHEN p_ms < 300000 THEN 5
              WHEN p_ms < 600000 THEN 6
              WHEN p_ms < 1800000 THEN 7
              WHEN p_ms < 3600000 THEN 8
              ELSE 9 END
$$;

-- stmt_trend: snapshot_at is the start of each interval (date_bin from p_from); an interval with no delta has no row.
-- A delta is binned at the middle of the period it covers (its snapshot_at is that period's end), so its calls fall
-- in the same interval as the log events of the same runs.
-- A reset delta (the statistics were reset between two reads) is left out: its counters are not a difference.
CREATE OR REPLACE FUNCTION pgvigil.stmt_trend(p_instance_id int, p_queryid bigint, p_datname text,
                                              p_from timestamptz, p_to timestamptz, p_secs int)
RETURNS TABLE (snapshot_at timestamptz, calls bigint, rows bigint, total_ms float8, mean_ms float8,
               log_max_ms float8, log_events bigint)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT date_bin(make_interval(secs => p_secs), d.snapshot_at - make_interval(secs => d.interval_secs / 2.0), p_from) AS b,
           sum(d.calls)::bigint AS calls, sum(d.rows)::bigint AS rows, sum(d.total_exec_ms) AS total_ms
      FROM pgvigil.statements_delta d
     WHERE d.instance_id = p_instance_id AND d.queryid = p_queryid AND NOT d.reset
       AND (p_datname IS NULL OR d.datname = p_datname)
       AND d.snapshot_at - make_interval(secs => d.interval_secs / 2.0) >= p_from AND d.snapshot_at <= p_to
     GROUP BY 1
  ), l AS (
    SELECT date_bin(make_interval(secs => p_secs), e.snapshot_at, p_from) AS b,
           max(e.duration_ms) AS log_max_ms, count(*) AS log_events
      FROM pgvigil.log_events e
     WHERE e.instance_id = p_instance_id AND e.kind = 'slow'
       AND e.shape_key = (SELECT t.shape_key FROM pgvigil.statement_text t
                           WHERE t.instance_id = p_instance_id AND t.queryid = p_queryid)
       AND (p_datname IS NULL OR e.datname = p_datname)
       AND e.snapshot_at > p_from AND e.snapshot_at <= p_to
     GROUP BY 1
  )
  SELECT coalesce(d.b, l.b), coalesce(d.calls, 0), coalesce(d.rows, 0), coalesce(d.total_ms, 0),
         CASE WHEN d.calls > 0 THEN d.total_ms / d.calls END, l.log_max_ms, coalesce(l.log_events, 0)
    FROM d FULL JOIN l ON l.b = d.b
   ORDER BY 1
$$;

CREATE OR REPLACE FUNCTION pgvigil.slow_trend(p_instance_id int, p_shape_key text, p_from timestamptz, p_to timestamptz,
                                              p_secs int, p_min_ms numeric DEFAULT 0)
RETURNS TABLE (snapshot_at timestamptz, events bigint, failed bigint, mean_ms numeric, max_ms numeric, rows bigint,
               mean_cpu_ms numeric)
LANGUAGE sql STABLE AS $$
  SELECT date_bin(make_interval(secs => p_secs), e.at, p_from), count(*), count(*) FILTER (WHERE e.failed),
         round(avg(e.duration_ms), 3), max(e.duration_ms), sum(e.row_count)::bigint, round(avg(e.cpu_ms), 3)
    FROM pgvigil.slow_events_all e
   WHERE e.instance_id = p_instance_id AND e.shape_key = p_shape_key
     AND e.at > p_from AND e.at <= p_to AND coalesce(e.duration_ms, 0) >= p_min_ms
   GROUP BY 1
   ORDER BY 1
$$;

SELECT pgvigil.apply_roles();
