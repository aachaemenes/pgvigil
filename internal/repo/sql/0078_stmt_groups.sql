-- 0078_stmt_groups: Statements drilled (parity3 task 125; PMM QAN 20-21, pghero's Queries, pgwatch's Query ID drill).
--
--   1. pgvigil.stmt_window_rows(instance, from, to): the window's pg_stat_statements deltas per statement, database,
--      user and client host. A delta that straddles the window's edge counts by the share of its period inside the
--      window (as top_statements_by does, so the totals agree). pg_stat_statements keeps no client: a statement's
--      time is split over the client hosts the running-queries samples saw it from (activity_sample.query_id, PG 14+
--      with compute_query_id), in proportion to the samples; a statement never sampled keeps client NULL ("not
--      sampled"). A split is an estimate, and the page says so.
--   2. pgvigil.stmt_groups(instance, from, to, group, dbs, users, clients, limit): those rows filtered by the ticked
--      databases / users / client hosts (NULL = all; '(not sampled)' ticks the NULL client) and grouped by statement,
--      database, user or client, with each group's share of the filtered total and of the instance's whole total.
--   3. pgvigil.stmt_facets(instance, from, to, dbs, users, clients): each value of each of the three dimensions with
--      its share; a dimension's shares are over the rows the OTHER two dimensions' ticks leave (a faceted filter: a
--      ticked database still lists the other databases with their shares).
--   4. pgvigil.stmt_trend_detail(instance, queryid, datname, from, to, secs): stmt_trend (0076) with the buffers per
--      interval (shared hit / read, temp read / written); stmt_trend stays as it is.
--   5. pgvigil.stmt_lag(instance, queryid, datname, from, to, lags): one statement's figures over the window and over
--      the same window moved back by each lag (seconds; 0 = the window itself), each with the snapshots it read.
--   6. actions_log gains the action 'hypo_index' (a suggested index checked by the planner through hypopg: no pid;
--      the database and the index with its statement are kept), and import_actions_log stores its pid as NULL.
--
-- No table, no column, no index. Lock footprint: actions_log's two CHECK constraints are dropped and added again (an
-- ACCESS EXCLUSIVE lock on actions_log while the check scans its rows: the audit is small).
-- PostgreSQL 13: nothing here needs 14+ (no date_bin, no multirange); the client split simply finds no query_id on 13.

CREATE OR REPLACE FUNCTION pgvigil.stmt_window_rows(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (queryid bigint, datname text, usename text, client text, calls float8, total_ms float8, rows float8,
               shared_blks_hit float8, shared_blks_read float8, temp_blks_written float8, io_blks float8)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT d.*,
           greatest(0, extract(epoch FROM least(d.snapshot_at, p_to) - greatest(d.snapshot_at - make_interval(secs => d.interval_secs), p_from)))
             / d.interval_secs AS share
      FROM pgvigil.statements_delta d
     WHERE d.instance_id = p_instance_id
       AND d.snapshot_at > p_from
       AND d.snapshot_at - make_interval(secs => d.interval_secs) < p_to
  ), a AS (
    SELECT d.queryid, d.datname, d.usename,
           sum(d.calls * d.share) AS calls, sum(d.total_exec_ms * d.share) AS total_ms, sum(d.rows * d.share) AS rows,
           sum(d.shared_blks_hit * d.share) AS hit, sum(d.shared_blks_read * d.share) AS rd,
           sum(d.temp_blks_read * d.share) AS tr, sum(d.temp_blks_written * d.share) AS tw
      FROM d WHERE d.share > 0
     GROUP BY d.queryid, d.datname, d.usename
  ), c AS (
    SELECT s.query_id, s.datname, s.usename, nullif(s.client, '') AS client, count(*)::float8 AS n
      FROM pgvigil.activity_sample s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
       AND s.query_id IS NOT NULL AND s.state = 'active'
     GROUP BY 1, 2, 3, 4
  ), cw AS (
    SELECT c.*, c.n / sum(c.n) OVER (PARTITION BY c.query_id, c.datname, c.usename) AS w FROM c
  )
  SELECT a.queryid, a.datname, a.usename, cw.client,
         a.calls * coalesce(cw.w, 1), a.total_ms * coalesce(cw.w, 1), a.rows * coalesce(cw.w, 1),
         a.hit * coalesce(cw.w, 1), a.rd * coalesce(cw.w, 1), a.tw * coalesce(cw.w, 1),
         (coalesce(a.rd, 0) + coalesce(a.tr, 0) + coalesce(a.tw, 0)) * coalesce(cw.w, 1)
    FROM a
    LEFT JOIN cw ON cw.query_id = a.queryid AND cw.datname IS NOT DISTINCT FROM a.datname AND cw.usename IS NOT DISTINCT FROM a.usename
$$;

-- the client of a row as the filter names it: NULL (never sampled) is '(not sampled)'
CREATE OR REPLACE FUNCTION pgvigil.stmt_client_label(p_client text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT coalesce(p_client, '(not sampled)') $$;

CREATE OR REPLACE FUNCTION pgvigil.stmt_groups(p_instance_id int, p_from timestamptz, p_to timestamptz, p_group text DEFAULT 'query',
                                               p_dbs text[] DEFAULT NULL, p_users text[] DEFAULT NULL, p_clients text[] DEFAULT NULL,
                                               p_limit int DEFAULT 100)
RETURNS TABLE (grp text, queryid bigint, datname text, usename text, statements bigint, calls float8, total_ms float8,
               mean_ms float8, rows float8, io_blks float8, hit_pct numeric, share_pct numeric, share_all_pct numeric, query text)
LANGUAGE sql STABLE AS $$
  WITH r AS (SELECT * FROM pgvigil.stmt_window_rows(p_instance_id, p_from, p_to)),
  allt AS (SELECT sum(r.total_ms) AS t FROM r),
  f AS (
    SELECT r.*, CASE lower(coalesce(p_group, 'query'))
                  WHEN 'db' THEN coalesce(r.datname, '')
                  WHEN 'user' THEN coalesce(r.usename, '')
                  WHEN 'client' THEN pgvigil.stmt_client_label(r.client)
                  ELSE r.queryid::text END AS g
      FROM r
     WHERE (p_dbs IS NULL OR r.datname = ANY (p_dbs))
       AND (p_users IS NULL OR r.usename = ANY (p_users))
       AND (p_clients IS NULL OR pgvigil.stmt_client_label(r.client) = ANY (p_clients))
  ),
  ft AS (SELECT sum(f.total_ms) AS t FROM f),
  g AS (
    SELECT f.g, count(DISTINCT f.queryid) AS statements, min(f.queryid) AS queryid,
           CASE WHEN count(DISTINCT f.datname) = 1 THEN min(f.datname) END AS datname,
           CASE WHEN count(DISTINCT f.usename) = 1 THEN min(f.usename) END AS usename,
           sum(f.calls) AS calls, sum(f.total_ms) AS total_ms, sum(f.rows) AS rows, sum(f.io_blks) AS io_blks,
           sum(f.shared_blks_hit) AS hit, sum(f.shared_blks_read) AS rd
      FROM f GROUP BY f.g
  )
  SELECT g.g, CASE WHEN lower(coalesce(p_group, 'query')) NOT IN ('db', 'user', 'client') THEN g.queryid END,
         g.datname, g.usename, g.statements, g.calls, g.total_ms, g.total_ms / nullif(g.calls, 0), g.rows, g.io_blks,
         round((100 * g.hit / nullif(g.hit + g.rd, 0))::numeric, 1),
         round((100 * g.total_ms / nullif(ft.t, 0))::numeric, 2),
         round((100 * g.total_ms / nullif(allt.t, 0))::numeric, 2),
         CASE WHEN lower(coalesce(p_group, 'query')) NOT IN ('db', 'user', 'client') THEN
           (SELECT t.query FROM pgvigil.statement_text t WHERE t.instance_id = p_instance_id AND t.queryid = g.queryid) END
    FROM g CROSS JOIN ft CROSS JOIN allt
   ORDER BY g.total_ms DESC NULLS LAST, g.g
   LIMIT greatest(1, least(coalesce(p_limit, 100), 1000))
$$;

CREATE OR REPLACE FUNCTION pgvigil.stmt_facets(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                               p_dbs text[] DEFAULT NULL, p_users text[] DEFAULT NULL, p_clients text[] DEFAULT NULL)
RETURNS TABLE (dim text, value text, statements bigint, calls float8, total_ms float8, share_pct numeric, ticked boolean)
LANGUAGE sql STABLE AS $$
  WITH r AS (SELECT r.*, pgvigil.stmt_client_label(r.client) AS cl FROM pgvigil.stmt_window_rows(p_instance_id, p_from, p_to) r),
  x AS (
    SELECT 'db'::text AS dim, coalesce(r.datname, '') AS value, r.queryid, r.calls, r.total_ms FROM r
     WHERE (p_users IS NULL OR r.usename = ANY (p_users)) AND (p_clients IS NULL OR r.cl = ANY (p_clients))
    UNION ALL
    SELECT 'user', coalesce(r.usename, ''), r.queryid, r.calls, r.total_ms FROM r
     WHERE (p_dbs IS NULL OR r.datname = ANY (p_dbs)) AND (p_clients IS NULL OR r.cl = ANY (p_clients))
    UNION ALL
    SELECT 'client', r.cl, r.queryid, r.calls, r.total_ms FROM r
     WHERE (p_dbs IS NULL OR r.datname = ANY (p_dbs)) AND (p_users IS NULL OR r.usename = ANY (p_users))
  ), g AS (
    SELECT x.dim, x.value, count(DISTINCT x.queryid) AS statements, sum(x.calls) AS calls, sum(x.total_ms) AS total_ms
      FROM x GROUP BY x.dim, x.value
  )
  SELECT g.dim, g.value, g.statements, g.calls, g.total_ms,
         round((100 * g.total_ms / nullif(sum(g.total_ms) OVER (PARTITION BY g.dim), 0))::numeric, 2),
         (g.value = ANY (CASE g.dim WHEN 'db' THEN p_dbs WHEN 'user' THEN p_users ELSE p_clients END)) IS TRUE
    FROM g
   ORDER BY CASE g.dim WHEN 'db' THEN 1 WHEN 'user' THEN 2 ELSE 3 END, g.total_ms DESC NULLS LAST, g.value
$$;

-- stmt_trend_detail: stmt_trend's intervals (the same binning: a delta at the middle of its period, floor arithmetic
-- from p_from) with the buffers; a reset delta is left out.
CREATE OR REPLACE FUNCTION pgvigil.stmt_trend_detail(p_instance_id int, p_queryid bigint, p_datname text,
                                                     p_from timestamptz, p_to timestamptz, p_secs int)
RETURNS TABLE (snapshot_at timestamptz, calls bigint, rows bigint, total_ms float8, mean_ms float8,
               shared_blks_hit bigint, shared_blks_read bigint, temp_blks_read bigint, temp_blks_written bigint,
               log_max_ms float8, log_events bigint)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT p_from + make_interval(secs => floor(extract(epoch FROM d.snapshot_at - make_interval(secs => d.interval_secs / 2.0) - p_from) / p_secs) * p_secs) AS b,
           sum(d.calls)::bigint AS calls, sum(d.rows)::bigint AS rows, sum(d.total_exec_ms) AS total_ms,
           sum(d.shared_blks_hit)::bigint AS hit, sum(d.shared_blks_read)::bigint AS rd,
           sum(d.temp_blks_read)::bigint AS tr, sum(d.temp_blks_written)::bigint AS tw
      FROM pgvigil.statements_delta d
     WHERE d.instance_id = p_instance_id AND d.queryid = p_queryid AND NOT d.reset
       AND (p_datname IS NULL OR d.datname = p_datname)
       AND d.snapshot_at - make_interval(secs => d.interval_secs / 2.0) >= p_from AND d.snapshot_at <= p_to
     GROUP BY 1
  ), l AS (
    SELECT p_from + make_interval(secs => floor(extract(epoch FROM e.snapshot_at - p_from) / p_secs) * p_secs) AS b,
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
         CASE WHEN d.calls > 0 THEN d.total_ms / d.calls END,
         coalesce(d.hit, 0), coalesce(d.rd, 0), coalesce(d.tr, 0), coalesce(d.tw, 0),
         l.log_max_ms, coalesce(l.log_events, 0)
    FROM d FULL JOIN l ON l.b = d.b
   ORDER BY 1
$$;

-- stmt_lag: the window and the window moved back by each lag, with top_statements_by's edge shares; snapshots = the
-- deltas read in that window (0 = nothing collected then: the compare says "no data", never zero calls).
CREATE OR REPLACE FUNCTION pgvigil.stmt_lag(p_instance_id int, p_queryid bigint, p_datname text,
                                            p_from timestamptz, p_to timestamptz, p_lags float8[])
RETURNS TABLE (lag_secs float8, from_at timestamptz, to_at timestamptz, snapshots bigint, instance_snapshots bigint,
               calls float8, total_ms float8, mean_ms float8, rows float8, shared_blks_hit float8, shared_blks_read float8,
               temp_blks_written float8)
LANGUAGE sql STABLE AS $$
  WITH w AS (
    SELECT l.lag, p_from - make_interval(secs => l.lag) AS f, p_to - make_interval(secs => l.lag) AS t, l.o
      FROM unnest(p_lags) WITH ORDINALITY AS l(lag, o)
  ), d AS (
    SELECT w.lag, d.*,
           greatest(0, extract(epoch FROM least(d.snapshot_at, w.t) - greatest(d.snapshot_at - make_interval(secs => d.interval_secs), w.f)))
             / d.interval_secs AS share
      FROM w JOIN pgvigil.statements_delta d
        ON d.instance_id = p_instance_id AND d.queryid = p_queryid AND (p_datname IS NULL OR d.datname = p_datname)
       AND d.snapshot_at > w.f AND d.snapshot_at - make_interval(secs => d.interval_secs) < w.t
  ), a AS (
    SELECT d.lag, count(DISTINCT d.snapshot_at) AS snapshots, sum(d.calls * d.share) AS calls, sum(d.total_exec_ms * d.share) AS total_ms,
           sum(d.rows * d.share) AS rows, sum(d.shared_blks_hit * d.share) AS hit, sum(d.shared_blks_read * d.share) AS rd,
           sum(d.temp_blks_written * d.share) AS tw
      FROM d WHERE d.share > 0 GROUP BY d.lag
  )
  SELECT w.lag, w.f, w.t, coalesce(a.snapshots, 0),
         (SELECT count(*) FROM pgvigil.statements_info i WHERE i.instance_id = p_instance_id AND i.snapshot_at > w.f AND i.snapshot_at <= w.t),
         a.calls, a.total_ms, a.total_ms / nullif(a.calls, 0), a.rows, a.hit, a.rd, a.tw
    FROM w LEFT JOIN a ON a.lag = w.lag
   ORDER BY w.o
$$;

-- the actions door's hypothetical-index check (internal/web/q_plans.go Actions.HypoIndex)
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_action_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_action_check CHECK (
     (engine = 'postgres' AND action IN ('cancel', 'terminate', 'explain_analyze', 'hypo_index'))
  OR (engine = 'sqlserver' AND action IN ('kill', 'job_start', 'job_stop')));
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_pid_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_pid_check CHECK (pid IS NOT NULL OR action IN ('explain_analyze', 'hypo_index', 'job_start', 'job_stop'));

CREATE OR REPLACE FUNCTION pgvigil.import_actions_log(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.actions_log (instance_id, instance_name, at, ui_user, client, action, pid, backend_start,
                                   target_user, target_app, reason, outcome, detail, datname, statement)
  SELECT p_instance_id, x.instance_name, coalesce(x.at, p_snapshot_at), x.ui_user, nullif(x.client, ''), x.action,
         CASE WHEN x.action IN ('explain_analyze', 'hypo_index') THEN NULL ELSE x.pid END,   -- a refused cancel keeps its pid 0, as before
         x.backend_start, nullif(x.target_user, ''), nullif(x.target_app, ''), x.reason, x.outcome, nullif(x.detail, ''),
         nullif(x.datname, ''), nullif(x.statement, '')
    FROM jsonb_to_recordset(p_payload) AS x(instance_name text, at timestamptz, ui_user text, client text, action text,
                                            pid int, backend_start timestamptz, target_user text, target_app text,
                                            reason text, outcome text, detail text, datname text, statement text)
$$;

SELECT pgvigil.apply_roles();
