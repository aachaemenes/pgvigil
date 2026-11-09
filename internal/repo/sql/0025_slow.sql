-- 0025_slow: slow queries (phase 2, task 36; DBADash's slow queries).
--   1. the serverlog collection (on-prem, every minute): the server's stderr log files read through
--      pg_ls_logdir() and pg_read_binary_file() (collect/serverlog.go). Its events go into log_events beside the
--      CloudWatch reader's, with the same event key and the same duplicate guard (import_logs); its cursor is
--      the log_cursor row of source 'serverlog:<log_directory>' (read_to: the newest line read; the next run
--      starts one overlap before it, as the CloudWatch reader does)
--   2. the slow views: every slow statement of the log with its shape (literals and parameters as ?, its md5
--      stored as shape_key on log_events by a trigger and on statement_text as a generated column), the per-day
--      histogram by duration band, the top shapes by count and by total time, each linked to the
--      pg_stat_statements row of the same shape where one exists, and the window's totals
-- No check and no findings: slow statements are a view (no Summary column). log_events keeps its own monthly
-- partitions and purge; this file adds no table (a column and an index on log_events and statement_text).

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

-- shape_key: md5 of the shape, stored where the statements are, so the top lists group and match on an indexed
-- column instead of running slow_shape over every event and every pg_stat_statements text of a window.
--   log_events: set by a trigger on insert (both log readers, through import_logs) and when a re-read fills the
--   statement in (0013); NULL for the other kinds. statement_text: a stored generated column.
ALTER TABLE pgvigil.log_events ADD COLUMN IF NOT EXISTS shape_key text;

CREATE OR REPLACE FUNCTION pgvigil.log_events_shape()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.shape_key := CASE WHEN NEW.kind = 'slow' THEN md5(pgvigil.slow_shape(coalesce(NEW.statement, ''))) END;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS log_events_shape ON pgvigil.log_events;
CREATE TRIGGER log_events_shape BEFORE INSERT OR UPDATE OF statement, kind ON pgvigil.log_events
  FOR EACH ROW EXECUTE FUNCTION pgvigil.log_events_shape();

UPDATE pgvigil.log_events SET shape_key = md5(pgvigil.slow_shape(coalesce(statement, '')))
 WHERE kind = 'slow' AND shape_key IS NULL;

CREATE INDEX IF NOT EXISTS log_events_slow_shape ON pgvigil.log_events (instance_id, shape_key, duration_ms DESC) WHERE kind = 'slow';

ALTER TABLE pgvigil.statement_text ADD COLUMN IF NOT EXISTS shape_key text GENERATED ALWAYS AS (md5(pgvigil.slow_shape(query))) STORED;
CREATE INDEX IF NOT EXISTS statement_text_shape ON pgvigil.statement_text (instance_id, shape_key);

-- slow_events: every slow statement read from a server log (the CloudWatch reader and the serverlog reader),
-- with its instance name and shape key.
CREATE OR REPLACE VIEW pgvigil.slow_events AS
SELECT e.instance_id, i.name AS instance, i.platform, e.snapshot_at AS at, e.duration_ms, e.pid, e.datname, e.usename, e.client,
       e.statement, e.shape_key,
       CASE WHEN e.source LIKE 'serverlog:%' THEN 'server log' ELSE 'CloudWatch' END AS reader, e.source
  FROM pgvigil.log_events e
  JOIN pgvigil.instances i USING (instance_id)
 WHERE e.kind = 'slow';

-- slow_histogram: slow statements per day (in p_tz, UTC when the server does not know the name) and duration
-- band, of one instance or the fleet (p_instance_id NULL, active instances), at or over p_min_ms.
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

-- slow_top: the slow statement shapes of the window of one instance or the fleet (p_instance_id NULL, active
-- instances), each with its rank by count and by total time (a tie broken by the other figure); the rows within
-- p_limit of either rank: how often, how long in total, on average and at most, when first and last, one example
-- (the slowest), and the queryid of the pg_stat_statements row of the same shape on that instance where there is
-- one (the link to the Statements tab). One call serves both top lists.
CREATE OR REPLACE FUNCTION pgvigil.slow_top(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                            p_min_ms float8 DEFAULT 0, p_limit int DEFAULT 50)
RETURNS TABLE (instance_id int, instance text, shape_key text, rank_count bigint, rank_total bigint, statements bigint,
               total_ms float8, mean_ms float8, max_ms float8, first_at timestamptz, last_at timestamptz,
               databases text, users text, example text, queryid bigint)
LANGUAGE sql STABLE AS $$
  WITH g AS (
    SELECT e.instance_id, e.shape_key, count(*) AS n, sum(e.duration_ms) AS total, avg(e.duration_ms) AS mean,
           max(e.duration_ms) AS mx, min(e.snapshot_at) AS first_at, max(e.snapshot_at) AS last_at,
           string_agg(DISTINCT e.datname, ', ') AS dbs, string_agg(DISTINCT e.usename, ', ') AS users
      FROM pgvigil.log_events e
      JOIN pgvigil.instances i USING (instance_id)
     WHERE e.kind = 'slow' AND e.snapshot_at > p_from AND e.snapshot_at <= p_to
       AND e.duration_ms >= coalesce(p_min_ms, 0)
       AND (e.instance_id = p_instance_id OR p_instance_id IS NULL AND i.is_active)
     GROUP BY e.instance_id, e.shape_key
  ), r AS (
    SELECT g.*, row_number() OVER (ORDER BY g.n DESC, g.total DESC, g.instance_id, g.shape_key) AS rank_count,
                row_number() OVER (ORDER BY g.total DESC, g.n DESC, g.instance_id, g.shape_key) AS rank_total
      FROM g
  )
  SELECT r.instance_id, i.name, r.shape_key, r.rank_count, r.rank_total, r.n, r.total, r.mean, r.mx, r.first_at, r.last_at,
         r.dbs, r.users, x.example,
         (SELECT max(t.queryid) FROM pgvigil.statement_text t WHERE t.instance_id = r.instance_id AND t.shape_key = r.shape_key)
    FROM r
    JOIN pgvigil.instances i ON i.instance_id = r.instance_id
    CROSS JOIN LATERAL (
      SELECT left(e.statement, 4000) AS example
        FROM pgvigil.log_events e
       WHERE e.instance_id = r.instance_id AND e.kind = 'slow' AND e.shape_key = r.shape_key
         AND e.snapshot_at > p_from AND e.snapshot_at <= p_to AND e.duration_ms >= coalesce(p_min_ms, 0)
       ORDER BY e.duration_ms DESC
       LIMIT 1) x
   WHERE r.rank_count <= greatest(1, least(coalesce(p_limit, 50), 500))
      OR r.rank_total <= greatest(1, least(coalesce(p_limit, 50), 500))
   ORDER BY r.rank_count
$$;

-- slow_totals: the window's slow statements of one instance or the fleet in one row: how many, how many shapes,
-- the total and the longest (the tiles; the top lists hold only their first rows).
CREATE OR REPLACE FUNCTION pgvigil.slow_totals(p_instance_id int, p_from timestamptz, p_to timestamptz, p_min_ms float8 DEFAULT 0)
RETURNS TABLE (statements bigint, shapes bigint, instances bigint, total_ms float8, max_ms float8)
LANGUAGE sql STABLE AS $$
  SELECT count(*), count(DISTINCT (e.instance_id, e.shape_key)), count(DISTINCT e.instance_id), coalesce(sum(e.duration_ms), 0), max(e.duration_ms)
    FROM pgvigil.log_events e
    JOIN pgvigil.instances i USING (instance_id)
   WHERE e.kind = 'slow' AND e.snapshot_at > p_from AND e.snapshot_at <= p_to
     AND e.duration_ms >= coalesce(p_min_ms, 0)
     AND (e.instance_id = p_instance_id OR p_instance_id IS NULL AND i.is_active)
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
