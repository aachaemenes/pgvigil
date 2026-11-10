-- 0054_compare: the baseline compare (task 57; DBADash's Object Execution Compare, pg_profile's differential report).
-- No collection: every function reads the statements collection's deltas (statements_delta, 0003); one table caches
-- the findings (compare_findings_cache), refreshed per instance once an hour.
--
--   statement_window(i, f, t)          per statement (queryid) of the window: calls, total time, pages (shared blocks
--                                      hit + read), the databases' and roles' names; each delta scaled by the share of
--                                      its span inside the window, as top_statements (0003) counts it; deltas_inside
--                                      counts the deltas that END inside the window, first_end is the first such end.
--   statement_baseline(i, f, t)        'ok' when the statements collection read the instance in the window (a delta
--                                      row, or an ok run in collection_log), else 'no baseline'.
--   statement_compare(i, f, t, n)      the window's statements against the same window one day and seven days earlier:
--                                      the three figures, mean time and pages per call of each, the ratios, and per
--                                      baseline a status, sorted by the largest ratio:
--                                        ok           figures and ratios;
--                                        partial      figures, no ratio: the statement began in that window's second
--                                                     half (no delta of it ends in the first half, and its text was
--                                                     first seen after it, when the text is kept): a whole window
--                                                     against a part of one reads as a rise that did not happen;
--                                        not run      the instance was read then and no delta of the statement ends
--                                                     inside that window (a baseline only crossed by the start of a
--                                                     delta that ends after it is a sliver of that delta: no figures);
--                                        no baseline  nothing was read then.
--   statement_history(i, q, f, t)      one statement's calls, time and pages per step over the window and the seven
--                                      days before it (the Compare tab's row opens it).
--   refresh_compare_findings(i, at)    computes the instance's regressions of the 24 hours to at into
--                                      compare_findings_cache: a statement whose calls, total time or pages per call
--                                      rose by a factor of 10 or more against either baseline, with at least 1,000 calls
--                                      in the window (a quiet statement never fires). The hourly compare collection
--                                      (internal/collect/compare.go, import_compare below) calls it for a current read:
--                                      a findings read never computes a compare (about 50 ms to 1 s an instance, more
--                                      with pg_stat_statements.max high).
--   import_compare(i, at, payload)     the compare collection's import: the refresh for a current read (at within the
--                                      last two hours; a backfilled read does not), and compare_state (the last refresh,
--                                      its findings count).
--   compare_findings                   the findings view's columns, from the cache rows of the last two hours (a stale
--                                      cache fires nothing). The UNION arm in pgvigil.findings is the wave's join.
--
-- A statement is its queryid across the instance's databases and roles (as top_statements groups it); the roles it ran
-- under ride along (usenames), so the session SETs of task 58 can be shown beside it.
--
-- The window reads use each monthly partition's (instance_id, snapshot_at) index (ensure_month_partition, 0002). A read
-- bounds the deltas it scans to those ending at most one hour after the window's end: a delta that spans a collection
-- gap reaching more than an hour past the window (the collector stopped, or the statement left pg_stat_statements' top
-- set and came back) is left out, and the window then reads a little low for that statement.

CREATE OR REPLACE FUNCTION pgvigil.statement_window(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (queryid bigint, datname text, usenames text[], calls float8, total_exec_ms float8, pages float8, deltas_inside bigint,
               first_end timestamptz)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT d.queryid, d.datname, d.usename, d.snapshot_at, d.calls, d.total_exec_ms,
           coalesce(d.shared_blks_hit, 0) + coalesce(d.shared_blks_read, 0) AS pages,
           greatest(0, extract(epoch FROM least(d.snapshot_at, p_to) - greatest(d.snapshot_at - make_interval(secs => d.interval_secs), p_from)))
             / d.interval_secs AS share
      FROM pgvigil.statements_delta d
     WHERE d.instance_id = p_instance_id
       AND d.snapshot_at > p_from
       AND d.snapshot_at < p_to + interval '1 hour'
       AND d.snapshot_at - make_interval(secs => d.interval_secs) < p_to
  )
  SELECT d.queryid, min(d.datname), array_agg(DISTINCT d.usename ORDER BY d.usename) FILTER (WHERE d.usename IS NOT NULL),
         sum(d.calls * d.share), sum(d.total_exec_ms * d.share), sum(d.pages * d.share),
         count(*) FILTER (WHERE d.snapshot_at <= p_to), min(d.snapshot_at) FILTER (WHERE d.snapshot_at <= p_to)
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
    SELECT (p_from - interval '1 day') + (p_to - p_from) / 2 AS d1_half, (p_from - interval '7 days') + (p_to - p_from) / 2 AS d7_half,
           pgvigil.statement_baseline(p_instance_id, p_from - interval '1 day', p_to - interval '1 day') AS d1,
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
           CASE WHEN b.d1 = 'no baseline' THEN b.d1 WHEN p1.queryid IS NULL THEN 'not run'
                WHEN p1.first_end > b.d1_half AND coalesce(t.first_seen > b.d1_half, true) THEN 'partial' ELSE 'ok' END AS d1_status,
           p1.calls AS d1_calls, p1.total_exec_ms AS d1_total, p1.total_exec_ms / nullif(p1.calls, 0) AS d1_mean,
           p1.pages / nullif(p1.calls, 0) AS d1_ppc,
           CASE WHEN b.d7 = 'no baseline' THEN b.d7 WHEN p7.queryid IS NULL THEN 'not run'
                WHEN p7.first_end > b.d7_half AND coalesce(t.first_seen > b.d7_half, true) THEN 'partial' ELSE 'ok' END AS d7_status,
           p7.calls AS d7_calls, p7.total_exec_ms AS d7_total, p7.total_exec_ms / nullif(p7.calls, 0) AS d7_mean,
           p7.pages / nullif(p7.calls, 0) AS d7_ppc
      FROM c CROSS JOIN b
      LEFT JOIN p1 ON p1.queryid = c.queryid
      LEFT JOIN p7 ON p7.queryid = c.queryid
      LEFT JOIN pgvigil.statement_text t ON t.instance_id = p_instance_id AND t.queryid = c.queryid
  ), x AS (
    -- a ratio only against an 'ok' baseline
    SELECT r.*,
           CASE WHEN r.d1_status = 'ok' THEN r.calls / nullif(r.d1_calls, 0) END AS d1_cr,
           CASE WHEN r.d1_status = 'ok' THEN r.total_exec_ms / nullif(r.d1_total, 0) END AS d1_tr,
           CASE WHEN r.d1_status = 'ok' THEN r.ppc / nullif(r.d1_ppc, 0) END AS d1_pr,
           CASE WHEN r.d7_status = 'ok' THEN r.calls / nullif(r.d7_calls, 0) END AS d7_cr,
           CASE WHEN r.d7_status = 'ok' THEN r.total_exec_ms / nullif(r.d7_total, 0) END AS d7_tr,
           CASE WHEN r.d7_status = 'ok' THEN r.ppc / nullif(r.d7_ppc, 0) END AS d7_pr
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
  -- the step's end that holds the delta (floor arithmetic on epoch seconds: date_bin is PostgreSQL 14+, 13 is supported)
  SELECT s.f + make_interval(secs => floor(extract(epoch FROM d.snapshot_at - interval '1 microsecond' - s.f) / extract(epoch FROM s.step)) * extract(epoch FROM s.step)) + s.step,
         sum(d.calls)::float8, sum(d.total_exec_ms), sum(d.total_exec_ms) / nullif(sum(d.calls), 0),
         sum(coalesce(d.shared_blks_hit, 0) + coalesce(d.shared_blks_read, 0))::float8 / nullif(sum(d.calls), 0)
    FROM pgvigil.statements_delta d CROSS JOIN s
   WHERE d.instance_id = p_instance_id AND d.queryid = p_queryid
     AND d.snapshot_at > s.f AND d.snapshot_at <= p_to
   GROUP BY 1
   ORDER BY 1
$$;

-- the cached regressions: one row per firing statement of the instance's last refresh
CREATE TABLE IF NOT EXISTS pgvigil.compare_findings_cache (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  queryid      bigint NOT NULL,
  computed_at  timestamptz NOT NULL,
  value        text NOT NULL,
  detail       text NOT NULL,
  PRIMARY KEY (instance_id, queryid)
);

-- a baseline's phrase in a finding's text: its figures, or its status alone
CREATE OR REPLACE FUNCTION pgvigil.compare_phrase(p_label text, p_status text, p_calls float8, p_ppc float8, p_total float8)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT p_label || ': ' || CASE WHEN p_calls IS NULL THEN p_status
    ELSE format('%s calls, %s pages a call, %s ms%s', round(p_calls::numeric), coalesce(round(p_ppc::numeric)::text, '-'),
                coalesce(round(p_total::numeric)::text, '-'), CASE WHEN p_status = 'ok' THEN '' ELSE ' (' || p_status || ': no ratio)' END) END
$$;

-- refresh_compare_findings: the instance's regressions of the 24 hours to p_at (10 or more on a ratio, 1,000 calls or
-- more in the window; 'partial', 'not run' and 'no baseline' never fire: no ratio); returns the rows kept
CREATE OR REPLACE FUNCTION pgvigil.refresh_compare_findings(p_instance_id int, p_at timestamptz DEFAULT now())
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.refresh_compare_findings'), p_instance_id);
  DELETE FROM pgvigil.compare_findings_cache WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.compare_findings_cache (instance_id, queryid, computed_at, value, detail)
  SELECT p_instance_id, c.queryid, p_at,
         'x' || round(c.max_ratio::numeric, 1)::text || ' ' || c.max_ratio_of,
         format('the statement ran %s calls in the 24 hours at %s pages a call and %s ms in all (%s; %s): %s',
                round(c.calls::numeric), coalesce(round(c.pages_per_call::numeric)::text, '-'), round(c.total_exec_ms::numeric),
                pgvigil.compare_phrase('1 day earlier', c.d1_status, c.d1_calls, c.d1_pages_per_call, c.d1_total_exec_ms),
                pgvigil.compare_phrase('7 days earlier', c.d7_status, c.d7_calls, c.d7_pages_per_call, c.d7_total_exec_ms),
                left(regexp_replace(coalesce(c.query, '(no text)'), '\s+', ' ', 'g'), 200))
    FROM pgvigil.statement_compare(p_instance_id, p_at - interval '1 day', p_at, 500) c
   WHERE c.calls >= 1000 AND c.max_ratio >= 10;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE TABLE IF NOT EXISTS pgvigil.compare_state (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  refreshed_at  timestamptz NOT NULL,
  findings      int NOT NULL
);

CREATE OR REPLACE FUNCTION pgvigil.import_compare(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  IF p_snapshot_at <= now() - interval '2 hours' THEN
    RETURN;   -- a backfilled read (the demo's history): the findings are about now
  END IF;
  n := pgvigil.refresh_compare_findings(p_instance_id, p_snapshot_at);
  INSERT INTO pgvigil.compare_state AS s (instance_id, refreshed_at, findings) VALUES (p_instance_id, p_snapshot_at, n)
  ON CONFLICT (instance_id) DO UPDATE SET refreshed_at = EXCLUDED.refreshed_at, findings = EXCLUDED.findings
  WHERE s.refreshed_at <= EXCLUDED.refreshed_at;
END $$;

-- compare_findings: the findings view's columns (instance_id, severity, setting, value, is_set, suggested, platforms,
-- detail, source, at), from the cache rows computed in the last two hours (an instance whose refresh stopped fires nothing)
CREATE OR REPLACE VIEW pgvigil.compare_findings AS
SELECT c.instance_id, 'warning'::text AS severity, 'statement ' || c.queryid::text AS setting, c.value, true AS is_set,
       'under x10 of its baseline'::text AS suggested, 'all'::text AS platforms, c.detail,
       'pgvigil compare'::text AS source, c.computed_at AS at
  FROM pgvigil.compare_findings_cache c
  JOIN pgvigil.instances i ON i.instance_id = c.instance_id AND i.is_active
 WHERE c.computed_at > now() - interval '2 hours';
