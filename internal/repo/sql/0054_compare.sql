-- 0054_compare: the baseline compare (task 57; DBADash's Object Execution Compare, pg_profile's differential report).
-- No collection and no table: every function reads the statements collection's deltas (statements_delta, 0003).
--
--   statement_window(i, f, t)          per statement (queryid) of the window: calls, total time, pages (shared blocks
--                                      hit + read), the databases' and roles' names; each delta scaled by the share of
--                                      its span inside the window, as top_statements (0003) counts it; deltas_inside
--                                      counts the deltas that END inside the window.
--   statement_baseline(i, f, t)        'ok' when the statements collection read the instance in the window (a delta
--                                      row, or an ok run in collection_log), else 'no baseline'.
--   statement_compare(i, f, t, n)      the window's statements against the same window one day and seven days earlier:
--                                      the three figures, mean time and pages per call of each, the ratios, and per
--                                      baseline a status ('ok'; 'not run': the instance was read then and no delta of the
--                                      statement ends inside that window; 'no baseline': nothing was read then), sorted
--                                      by the largest ratio. A baseline only crossed by the start of a delta that ends
--                                      after it is 'not run' with no figures: its share would be a sliver of a delta,
--                                      and a whole window against a sliver reads as a huge ratio (a statement that began
--                                      about one or seven days before the window's start).
--   statement_history(i, q, f, t)      one statement's calls, time and pages per step over the window and the seven
--                                      days before it (the Compare tab's row opens it).
--   compare_findings                   the findings view's columns: a statement of the last 24 hours whose calls, total
--                                      time or pages per call rose by a factor of 10 or more against either baseline,
--                                      with at least 1,000 calls in the window (a quiet statement never fires). The
--                                      UNION arm in pgvigil.findings is the wave's join.
--
-- A statement is its queryid across the instance's databases and roles (as top_statements groups it); the roles it ran
-- under ride along (usenames), so the session SETs of task 58 can be shown beside it.
--
-- The window reads use each monthly partition's (instance_id, snapshot_at) index (ensure_month_partition, 0002). A read
-- bounds the deltas it scans to those ending at most one day after the window's end: a delta that spans a collection gap of more than a day past the
-- window (the collector stopped, or the statement left pg_stat_statements' top set and came back) is left out, and
-- the window then reads a little low for that statement.

CREATE OR REPLACE FUNCTION pgvigil.statement_window(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (queryid bigint, datname text, usenames text[], calls float8, total_exec_ms float8, pages float8, deltas_inside bigint)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT d.queryid, d.datname, d.usename, d.snapshot_at, d.calls, d.total_exec_ms,
           coalesce(d.shared_blks_hit, 0) + coalesce(d.shared_blks_read, 0) AS pages,
           greatest(0, extract(epoch FROM least(d.snapshot_at, p_to) - greatest(d.snapshot_at - make_interval(secs => d.interval_secs), p_from)))
             / d.interval_secs AS share
      FROM pgvigil.statements_delta d
     WHERE d.instance_id = p_instance_id
       AND d.snapshot_at > p_from
       AND d.snapshot_at < p_to + interval '1 day'
       AND d.snapshot_at - make_interval(secs => d.interval_secs) < p_to
  )
  SELECT d.queryid, min(d.datname), array_agg(DISTINCT d.usename ORDER BY d.usename) FILTER (WHERE d.usename IS NOT NULL),
         sum(d.calls * d.share), sum(d.total_exec_ms * d.share), sum(d.pages * d.share),
         count(*) FILTER (WHERE d.snapshot_at <= p_to)
    FROM d
   WHERE d.share > 0
   GROUP BY d.queryid
$$;

CREATE OR REPLACE FUNCTION pgvigil.statement_baseline(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM pgvigil.statements_delta d
                            WHERE d.instance_id = p_instance_id AND d.snapshot_at > p_from AND d.snapshot_at <= p_to)
                OR EXISTS (SELECT 1 FROM pgvigil.collection_log l
                            WHERE l.instance_id = p_instance_id AND l.collection = 'statements' AND l.status = 'ok'
                              AND l.snapshot_at > p_from AND l.snapshot_at <= p_to)
              THEN 'ok' ELSE 'no baseline' END
$$;

CREATE OR REPLACE FUNCTION pgvigil.statement_compare(p_instance_id int, p_from timestamptz, p_to timestamptz, p_limit int DEFAULT 200)
RETURNS TABLE (queryid bigint, datname text, usenames text[],
               calls float8, total_exec_ms float8, mean_exec_ms float8, pages float8, pages_per_call float8,
               d1_status text, d1_calls float8, d1_total_exec_ms float8, d1_mean_exec_ms float8, d1_pages_per_call float8,
               d1_calls_ratio float8, d1_total_ratio float8, d1_ppc_ratio float8,
               d7_status text, d7_calls float8, d7_total_exec_ms float8, d7_mean_exec_ms float8, d7_pages_per_call float8,
               d7_calls_ratio float8, d7_total_ratio float8, d7_ppc_ratio float8,
               max_ratio float8, max_ratio_of text, query text)
LANGUAGE sql STABLE AS $$
  WITH b AS (
    SELECT pgvigil.statement_baseline(p_instance_id, p_from - interval '1 day', p_to - interval '1 day') AS d1,
           pgvigil.statement_baseline(p_instance_id, p_from - interval '7 days', p_to - interval '7 days') AS d7
  ), c AS MATERIALIZED (   -- each window aggregated once, then joined by hash (not re-read per statement)
    SELECT * FROM pgvigil.statement_window(p_instance_id, p_from, p_to)
  ), p1 AS MATERIALIZED (
    SELECT * FROM pgvigil.statement_window(p_instance_id, p_from - interval '1 day', p_to - interval '1 day') w WHERE w.deltas_inside > 0
  ), p7 AS MATERIALIZED (
    SELECT * FROM pgvigil.statement_window(p_instance_id, p_from - interval '7 days', p_to - interval '7 days') w WHERE w.deltas_inside > 0
  ), r AS (
    SELECT c.queryid, c.datname, c.usenames, c.calls, c.total_exec_ms,
           c.total_exec_ms / nullif(c.calls, 0) AS mean_exec_ms, c.pages, c.pages / nullif(c.calls, 0) AS ppc,
           CASE WHEN b.d1 = 'no baseline' THEN b.d1 WHEN p1.queryid IS NULL THEN 'not run' ELSE 'ok' END AS d1_status,
           p1.calls AS d1_calls, p1.total_exec_ms AS d1_total, p1.total_exec_ms / nullif(p1.calls, 0) AS d1_mean,
           p1.pages / nullif(p1.calls, 0) AS d1_ppc,
           CASE WHEN b.d7 = 'no baseline' THEN b.d7 WHEN p7.queryid IS NULL THEN 'not run' ELSE 'ok' END AS d7_status,
           p7.calls AS d7_calls, p7.total_exec_ms AS d7_total, p7.total_exec_ms / nullif(p7.calls, 0) AS d7_mean,
           p7.pages / nullif(p7.calls, 0) AS d7_ppc
      FROM c CROSS JOIN b
      LEFT JOIN p1 ON p1.queryid = c.queryid
      LEFT JOIN p7 ON p7.queryid = c.queryid
  ), x AS (
    SELECT r.*,
           r.calls / nullif(r.d1_calls, 0) AS d1_cr, r.total_exec_ms / nullif(r.d1_total, 0) AS d1_tr, r.ppc / nullif(r.d1_ppc, 0) AS d1_pr,
           r.calls / nullif(r.d7_calls, 0) AS d7_cr, r.total_exec_ms / nullif(r.d7_total, 0) AS d7_tr, r.ppc / nullif(r.d7_ppc, 0) AS d7_pr
      FROM r
  ), m AS (
    -- the largest of the six ratios and which one it is (the first of a tie, in this order)
    SELECT x.*, top.ratio AS max_ratio, top.what AS max_ratio_of
      FROM x
      LEFT JOIN LATERAL (
        SELECT v.ratio, v.what
          FROM (VALUES (1, x.d1_cr, 'calls vs 1 day earlier'), (2, x.d1_tr, 'total time vs 1 day earlier'),
                       (3, x.d1_pr, 'pages per call vs 1 day earlier'), (4, x.d7_cr, 'calls vs 7 days earlier'),
                       (5, x.d7_tr, 'total time vs 7 days earlier'), (6, x.d7_pr, 'pages per call vs 7 days earlier')) v(n, ratio, what)
         WHERE v.ratio IS NOT NULL
         ORDER BY v.ratio DESC, v.n
         LIMIT 1) top ON true
  )
  SELECT m.queryid, m.datname, m.usenames, m.calls, m.total_exec_ms, m.mean_exec_ms, m.pages, m.ppc,
         m.d1_status, m.d1_calls, m.d1_total, m.d1_mean, m.d1_ppc, m.d1_cr, m.d1_tr, m.d1_pr,
         m.d7_status, m.d7_calls, m.d7_total, m.d7_mean, m.d7_ppc, m.d7_cr, m.d7_tr, m.d7_pr,
         m.max_ratio, m.max_ratio_of,
         (SELECT t.query FROM pgvigil.statement_text t WHERE t.instance_id = p_instance_id AND t.queryid = m.queryid)
    FROM m
   ORDER BY m.max_ratio DESC NULLS LAST, m.total_exec_ms DESC NULLS LAST, m.queryid
   LIMIT p_limit
$$;

-- one statement over the window and the seven days before it, in steps of at least an hour (about 600 steps at most);
-- a delta lands whole in the step its span ends in; a step is named by its end (a delta ending exactly on a step's
-- end belongs to that step)
CREATE OR REPLACE FUNCTION pgvigil.statement_history(p_instance_id int, p_queryid bigint, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, calls float8, total_exec_ms float8, mean_exec_ms float8, pages_per_call float8)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT p_from - interval '7 days' AS f,
           make_interval(secs => greatest(3600, ceil(extract(epoch FROM p_to - (p_from - interval '7 days')) / 600))) AS step
  )
  SELECT date_bin(s.step, d.snapshot_at - interval '1 microsecond', s.f) + s.step,
         sum(d.calls)::float8, sum(d.total_exec_ms), sum(d.total_exec_ms) / nullif(sum(d.calls), 0),
         sum(coalesce(d.shared_blks_hit, 0) + coalesce(d.shared_blks_read, 0))::float8 / nullif(sum(d.calls), 0)
    FROM pgvigil.statements_delta d CROSS JOIN s
   WHERE d.instance_id = p_instance_id AND d.queryid = p_queryid
     AND d.snapshot_at > s.f AND d.snapshot_at <= p_to
   GROUP BY 1
   ORDER BY 1
$$;

-- compare_findings: the findings view's columns (instance_id, severity, setting, value, is_set, suggested, platforms,
-- detail, source, at). The window is the last 24 hours; a statement fires once, on its largest ratio of 10 or more,
-- with at least 1,000 calls in the window; 'not run' and 'no baseline' never fire (no ratio).
CREATE OR REPLACE VIEW pgvigil.compare_findings AS
WITH k AS (SELECT 10.0::float8 AS ratio_min, 1000.0::float8 AS calls_min),
c AS (
  SELECT i.instance_id, s.*
    FROM pgvigil.instances i
   CROSS JOIN LATERAL pgvigil.statement_compare(i.instance_id, now() - interval '1 day', now(), 500) s
   WHERE i.is_active
)
SELECT c.instance_id, 'warning'::text AS severity, 'statement ' || c.queryid::text AS setting,
       'x' || round(c.max_ratio::numeric, 1)::text || ' ' || c.max_ratio_of AS value, true AS is_set,
       'under x' || k.ratio_min::text || ' of its baseline' AS suggested, 'all'::text AS platforms,
       format('the statement ran %s calls in the last 24 hours at %s pages a call and %s ms in all (1 day earlier: %s calls, %s pages a call, %s ms; 7 days earlier: %s calls, %s pages a call, %s ms): %s',
              round(c.calls::numeric), round(c.pages_per_call::numeric), round(c.total_exec_ms::numeric),
              coalesce(round(c.d1_calls::numeric)::text, c.d1_status), coalesce(round(c.d1_pages_per_call::numeric)::text, '-'),
              coalesce(round(c.d1_total_exec_ms::numeric)::text, '-'),
              coalesce(round(c.d7_calls::numeric)::text, c.d7_status), coalesce(round(c.d7_pages_per_call::numeric)::text, '-'),
              coalesce(round(c.d7_total_exec_ms::numeric)::text, '-'),
              left(regexp_replace(coalesce(c.query, '(no text)'), '\s+', ' ', 'g'), 200)) AS detail,
       'pgvigil compare'::text AS source, now() AS at
  FROM c, k
 WHERE c.calls >= k.calls_min AND c.max_ratio >= k.ratio_min;
