-- 0025_slow: slow queries (phase 2, task 36; DBADash's slow queries).
--   1. the serverlog collection (on-prem, every minute): the server's stderr log files read through
--      pg_ls_logdir() and pg_read_binary_file() (collect/serverlog.go). Its events go into log_events beside the
--      CloudWatch reader's, with the same event key and the same duplicate guard (import_logs); its cursor is
--      the log_cursor row of source 'serverlog:<log_directory>' (read_to: the newest line read; the next run
--      starts one overlap before it, as the CloudWatch reader does)
--   2. the slow views: every slow statement of the log with its shape (literals and parameters as ?), the
--      per-day histogram by duration band, the top shapes by count and by total time, each linked to the
--      pg_stat_statements row of the same shape where one exists
-- No check and no findings: slow statements are a view (no Summary column). log_events keeps its own monthly
-- partitions and purge; this file adds no table.

-- ---------------------------------------------------------------------------------------------------------
-- 1. the serverlog collection
-- ---------------------------------------------------------------------------------------------------------
-- payload: the logs collection's rows ({kind:'event', ...} and one {kind:'cursor', source, read_to});
-- the same import, so a re-read event is dropped and a longer re-read fills the stored row in (0013).
CREATE OR REPLACE FUNCTION pgvigil.import_serverlog(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.import_logs(p_instance_id, p_snapshot_at, p_payload);
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- 2. the slow views
-- ---------------------------------------------------------------------------------------------------------
-- slow_shape: a statement with its string and number literals and its $n parameters as ?, and its white space
-- folded, so "WHERE id = 5" and "WHERE id = 6" and pg_stat_statements' "WHERE id = $1" are one shape.
CREATE OR REPLACE FUNCTION pgvigil.slow_shape(p_text text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT btrim(regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(p_text, $re$E?'(?:[^']|'')*'$re$, '?', 'g'),
             '\$[0-9]+', '?', 'g'),
           '(^|[^[:alnum:]_.])-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?(?![[:alnum:]_])', '\1?', 'g'),
         '\s+', ' ', 'g'))
$$;

-- slow_events: every slow statement read from a server log (the CloudWatch reader and the serverlog reader),
-- with its instance name and shape key.
CREATE OR REPLACE VIEW pgvigil.slow_events AS
SELECT e.instance_id, i.name AS instance, i.platform, e.snapshot_at AS at, e.duration_ms, e.pid, e.datname, e.usename, e.client,
       e.statement, md5(pgvigil.slow_shape(coalesce(e.statement, ''))) AS shape_key,
       CASE WHEN e.source LIKE 'serverlog:%' THEN 'server log' ELSE 'CloudWatch' END AS reader, e.source
  FROM pgvigil.log_events e
  JOIN pgvigil.instances i USING (instance_id)
 WHERE e.kind = 'slow';

-- slow_histogram: slow statements per day (in p_tz, UTC when the name is unknown) and duration band, of one
-- instance or the fleet (p_instance_id NULL, active instances), at or over p_min_ms.
CREATE OR REPLACE FUNCTION pgvigil.slow_histogram(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                                  p_min_ms float8 DEFAULT 0, p_tz text DEFAULT 'UTC')
RETURNS TABLE (day date, statements bigint, under_1s bigint, s1_to_10 bigint, s10_to_60 bigint, over_60s bigint,
               total_ms float8, max_ms float8)
LANGUAGE sql STABLE AS $$
  WITH z AS (
    SELECT coalesce((SELECT name FROM pg_timezone_names WHERE name = p_tz), 'UTC') AS tz
  )
  SELECT (e.snapshot_at AT TIME ZONE z.tz)::date AS day, count(*),
         count(*) FILTER (WHERE e.duration_ms < 1000),
         count(*) FILTER (WHERE e.duration_ms >= 1000 AND e.duration_ms < 10000),
         count(*) FILTER (WHERE e.duration_ms >= 10000 AND e.duration_ms < 60000),
         count(*) FILTER (WHERE e.duration_ms >= 60000),
         sum(e.duration_ms), max(e.duration_ms)
    FROM pgvigil.log_events e
    JOIN pgvigil.instances i USING (instance_id)
   CROSS JOIN z
   WHERE e.kind = 'slow' AND e.snapshot_at > p_from AND e.snapshot_at <= p_to
     AND e.duration_ms >= coalesce(p_min_ms, 0)
     AND (e.instance_id = p_instance_id OR p_instance_id IS NULL AND i.is_active)
   GROUP BY 1
   ORDER BY 1
$$;

-- slow_top: the slow statement shapes of the window, by count ('count') or by total time ('total'), of one
-- instance or the fleet (p_instance_id NULL, active instances): how often, how long in total, on average and at
-- most, when first and last, one example (the slowest), and the queryid of the pg_stat_statements row of the
-- same shape on that instance where there is one (the link to the Statements tab).
CREATE OR REPLACE FUNCTION pgvigil.slow_top(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                            p_min_ms float8 DEFAULT 0, p_order text DEFAULT 'count', p_limit int DEFAULT 50)
RETURNS TABLE (instance_id int, instance text, shape_key text, statements bigint, total_ms float8, mean_ms float8, max_ms float8,
               first_at timestamptz, last_at timestamptz, databases text, users text, example text, queryid bigint)
LANGUAGE sql STABLE AS $$
  WITH e AS (
    SELECT e.instance_id, e.snapshot_at, e.duration_ms, e.datname, e.usename, e.statement,
           pgvigil.slow_shape(coalesce(e.statement, '')) AS shape
      FROM pgvigil.log_events e
      JOIN pgvigil.instances i USING (instance_id)
     WHERE e.kind = 'slow' AND e.snapshot_at > p_from AND e.snapshot_at <= p_to
       AND e.duration_ms >= coalesce(p_min_ms, 0)
       AND (e.instance_id = p_instance_id OR p_instance_id IS NULL AND i.is_active)
  ), g AS (
    SELECT e.instance_id, e.shape, count(*) AS n, sum(e.duration_ms) AS total, avg(e.duration_ms) AS mean, max(e.duration_ms) AS mx,
           min(e.snapshot_at) AS first_at, max(e.snapshot_at) AS last_at,
           string_agg(DISTINCT e.datname, ', ') AS dbs, string_agg(DISTINCT e.usename, ', ') AS users,
           (array_agg(e.statement ORDER BY e.duration_ms DESC))[1] AS example
      FROM e
     GROUP BY e.instance_id, e.shape
     ORDER BY CASE WHEN p_order = 'total' THEN sum(e.duration_ms) ELSE count(*) END DESC, sum(e.duration_ms) DESC
     LIMIT greatest(1, least(coalesce(p_limit, 50), 500))
  ), st AS (
    SELECT t.instance_id, pgvigil.slow_shape(t.query) AS shape, max(t.queryid) AS queryid
      FROM pgvigil.statement_text t
     WHERE t.instance_id IN (SELECT DISTINCT g.instance_id FROM g)
     GROUP BY 1, 2
  )
  SELECT g.instance_id, i.name, md5(g.shape), g.n, g.total, g.mean, g.mx, g.first_at, g.last_at, g.dbs, g.users,
         left(g.example, 4000), st.queryid
    FROM g
    JOIN pgvigil.instances i ON i.instance_id = g.instance_id
    LEFT JOIN st ON st.instance_id = g.instance_id AND st.shape = g.shape
   ORDER BY CASE WHEN p_order = 'total' THEN g.total ELSE g.n END DESC, g.total DESC
$$;

-- slow_sources: per instance, the log readers that feed the slow statements and how their last run ended
-- (a skipped serverlog run names its reason: logging_collector off, the read grant missing), the server's
-- log_min_duration_statement (the floor below which nothing is logged) and the newest slow statement.
CREATE OR REPLACE VIEW pgvigil.slow_sources AS
SELECT i.instance_id, i.name AS instance, i.platform, c.collection AS reader, c.status, c.note, c.snapshot_at AS last_run,
       st.log_min_duration_statement,
       (SELECT max(e.snapshot_at) FROM pgvigil.log_events e WHERE e.instance_id = i.instance_id AND e.kind = 'slow'
           AND e.snapshot_at > now() - interval '31 days') AS last_slow_at
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.collection_dates c ON c.instance_id = i.instance_id AND c.collection IN ('logs', 'serverlog')
  LEFT JOIN pgvigil.instance_state st ON st.instance_id = i.instance_id
 WHERE i.is_active;
