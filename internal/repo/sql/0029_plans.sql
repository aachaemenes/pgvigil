-- 0029_plans: execution plans (phase 2, task 40), read the way a plan analyser reads them: what the plan did, and
-- where it went wrong with the reason it matters, never "a scan is bad".
--   plans            one row per captured plan: from pg_store_plans where installed (the plans collection), from
--                    auto_explain output in the server log (the log readers' kind 'plan', imported through
--                    import_plans), from an on-demand EXPLAIN (FORMAT JSON) without execution through the
--                    monitoring login, and from EXPLAIN ANALYZE through the actions door. plan_text is the plan
--                    as captured (what the viewer draws); plan is its JSON form (EXPLAIN's own, or the text plan
--                    parsed by internal/plans), what the rules read. A current table: one row per plan_key,
--                    updated in place; purge() deletes the rows not seen for the retention days (the join adds the
--                    line).
--   plan_nodes(p)    every node of a JSON plan with its path ('0', '0.1', ...) and its parent's node type
--   plan_rules(p)    the plan rules over one JSON plan: estimates off by 10x, a spill to disk (sort, hash, hash
--                    aggregate), a nested loop over a large outer, a filter removing most rows of a large table,
--                    a lossy bitmap heap scan, an index-only scan with heap fetches, JIT's share, trigger time,
--                    parallel workers planned but not launched, a CTE scanned twice; each row with why it matters
--   plan_rule_hits   the rules of every stored plan (the Plan page reads one plan's)
--   plan_findings    the rules of the last 7 days' plans per instance and rule, in pgvigil.findings' ten columns
--                    (the join unions it in)
--   actions_log      gains the action 'explain_analyze' (no pid: the statement and the database instead), and
--                    import_actions_log reads the two new columns
-- Rules that need actual numbers (rows, loops, spills, heap fetches, JIT and trigger times, launched workers) are
-- silent on a plan captured without ANALYZE; the nested loop rule falls back to the outer's estimate and says so.

CREATE TABLE IF NOT EXISTS pgvigil.plans (
  plan_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  plan_key     text NOT NULL,          -- the source's identity of the plan: psp:<queryid>:<planid>, or a digest
  source       text NOT NULL CHECK (source IN ('pg_store_plans', 'auto_explain', 'explain', 'explain_analyze')),
  first_seen   timestamptz NOT NULL,
  captured_at  timestamptz NOT NULL,   -- the last capture (pg_store_plans: the last read that listed it)
  queryid      bigint,                 -- pg_stat_statements' queryid where the source knows it
  planid       bigint,                 -- pg_store_plans' planid
  datname      text,
  usename      text,
  query        text,
  duration_ms  float8,                 -- auto_explain / EXPLAIN ANALYZE: the statement's duration
  calls        bigint,                 -- pg_store_plans: executions of this plan (cumulative)
  total_ms     float8,                 -- pg_store_plans: their total time (cumulative)
  analyzed     boolean NOT NULL DEFAULT false,   -- the plan carries actual rows and times
  format       text NOT NULL CHECK (format IN ('json', 'text')),
  plan_text    text NOT NULL,
  plan         jsonb,                  -- the JSON form; NULL when a text plan could not be parsed (plan_note says why)
  plan_note    text,
  shape_key    text GENERATED ALWAYS AS (md5(pgvigil.slow_shape(coalesce(query, '')))) STORED,
  UNIQUE (instance_id, plan_key)
);
CREATE INDEX IF NOT EXISTS plans_inst_at_idx ON pgvigil.plans (instance_id, captured_at DESC);
CREATE INDEX IF NOT EXISTS plans_queryid_idx ON pgvigil.plans (instance_id, queryid) WHERE queryid IS NOT NULL;
CREATE INDEX IF NOT EXISTS plans_shape_idx ON pgvigil.plans (instance_id, shape_key);
COMMENT ON TABLE pgvigil.plans IS 'Captured execution plans (pg_store_plans, auto_explain, on-demand EXPLAIN, EXPLAIN ANALYZE through the actions door); written through import_plans only.';

-- payload: [{plan_key, source, captured_at, queryid, planid, datname, usename, query, duration_ms, calls, total_ms,
--            analyzed, format, plan_text, plan, plan_note}]; a row whose plan_key is stored updates it.
CREATE OR REPLACE FUNCTION pgvigil.import_plans(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.plans AS p (instance_id, plan_key, source, first_seen, captured_at, queryid, planid, datname, usename, query,
                                  duration_ms, calls, total_ms, analyzed, format, plan_text, plan, plan_note)
  SELECT DISTINCT ON (x.plan_key)
         p_instance_id, x.plan_key, x.source, coalesce(x.captured_at, p_snapshot_at), coalesce(x.captured_at, p_snapshot_at),
         x.queryid, x.planid, nullif(x.datname, ''), nullif(x.usename, ''), x.query, x.duration_ms, x.calls, x.total_ms,
         coalesce(x.analyzed, false), x.format, x.plan_text, CASE WHEN jsonb_typeof(x.plan) = 'object' THEN x.plan END, nullif(x.plan_note, '')
    FROM jsonb_to_recordset(p_payload) AS x(plan_key text, source text, captured_at timestamptz, queryid bigint, planid bigint,
                                            datname text, usename text, query text, duration_ms float8, calls bigint,
                                            total_ms float8, analyzed boolean, format text, plan_text text, plan jsonb, plan_note text)
   WHERE x.plan_key IS NOT NULL AND x.plan_text IS NOT NULL
   ORDER BY x.plan_key, x.captured_at DESC NULLS LAST
  ON CONFLICT (instance_id, plan_key) DO UPDATE
     SET captured_at = greatest(p.captured_at, EXCLUDED.captured_at),
         queryid = coalesce(EXCLUDED.queryid, p.queryid), datname = coalesce(EXCLUDED.datname, p.datname),
         usename = coalesce(EXCLUDED.usename, p.usename), query = coalesce(EXCLUDED.query, p.query),
         duration_ms = coalesce(EXCLUDED.duration_ms, p.duration_ms), calls = coalesce(EXCLUDED.calls, p.calls),
         total_ms = coalesce(EXCLUDED.total_ms, p.total_ms), analyzed = EXCLUDED.analyzed, format = EXCLUDED.format,
         plan_text = EXCLUDED.plan_text, plan = EXCLUDED.plan, plan_note = EXCLUDED.plan_note
$$;

-- every node of a JSON plan (the object EXPLAIN (FORMAT JSON) returns per statement, or auto_explain's): its
-- path, the node, its parent's node type and the node's own relationship to the parent
CREATE OR REPLACE FUNCTION pgvigil.plan_nodes(p jsonb)
RETURNS TABLE (node_path text, node jsonb, parent_type text, depth int)
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  WITH RECURSIVE n(node_path, node, parent_type, depth) AS (
    SELECT '0', p->'Plan', NULL::text, 0 WHERE jsonb_typeof(p->'Plan') = 'object'
    UNION ALL
    SELECT n.node_path || '.' || (c.ord - 1), c.child, n.node->>'Node Type', n.depth + 1
      FROM n CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(n.node->'Plans') = 'array' THEN n.node->'Plans' ELSE '[]'::jsonb END)
                                WITH ORDINALITY AS c(child, ord)
  )
  SELECT * FROM n
$$;

-- a JSON number (or numeric string) as numeric; NULL for anything else
CREATE OR REPLACE FUNCTION pgvigil.plan_num(v jsonb)
RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN jsonb_typeof(v) = 'number' THEN v::text::numeric
              WHEN jsonb_typeof(v) = 'string' AND v #>> '{}' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v #>> '{}')::numeric END
$$;

-- the object a node reads: its relation (with the alias when it differs), its index, its CTE or function
CREATE OR REPLACE FUNCTION pgvigil.plan_object(n jsonb)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT coalesce(nullif(concat_ws('.', n->>'Schema', n->>'Relation Name'), ''), n->>'CTE Name', n->>'Function Name', n->>'Index Name', n->>'Alias')
$$;

CREATE OR REPLACE FUNCTION pgvigil.plan_rules(p jsonb)
RETURNS TABLE (rule text, severity text, node_path text, node_type text, object text, value text, why text, suggested text)
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
WITH n AS (
  SELECT x.node_path, x.node, x.parent_type, x.node->>'Node Type' AS t, pgvigil.plan_object(x.node) AS obj,
         pgvigil.plan_num(x.node->'Plan Rows') AS est,
         pgvigil.plan_num(x.node->'Actual Rows') AS act,
         pgvigil.plan_num(x.node->'Actual Loops') AS loops,
         x.node ? 'Actual Loops' AS analyzed
    FROM pgvigil.plan_nodes(p) x
), est AS (      -- the nodes whose estimate is 10x off the actual rows (per loop), on at least 100 rows either way
  SELECT n.*, greatest(n.est, 1) / greatest(n.act, 1) AS over, greatest(n.act, 1) / greatest(n.est, 1) AS under
    FROM n
   WHERE n.analyzed AND n.loops > 0 AND greatest(n.est, n.act) >= 100
     AND (greatest(n.est, 1) / greatest(n.act, 1) >= 10 OR greatest(n.act, 1) / greatest(n.est, 1) >= 10)
), est_ok AS (   -- an overestimate under a Limit, a semi or anti join or a subplan is execution stopping early, not a
                 -- misestimate: those are left out; an underestimate always counts
  SELECT e.* FROM est e
   WHERE e.under >= 10
      OR NOT EXISTS (SELECT 1 FROM n a WHERE e.node_path LIKE a.node_path || '.%'
                       AND (a.t = 'Limit' OR a.node->>'Join Type' IN ('Semi', 'Anti', 'Right Semi', 'Right Anti')
                            OR a.node->>'Parent Relationship' IN ('SubPlan', 'InitPlan')))
                   AND e.node->>'Parent Relationship' IS DISTINCT FROM 'SubPlan'
)
-- 1. estimates off by 10x: the first node (from the leaves up) where the estimate goes wrong
SELECT 'estimate off by 10x', 'warning', e.node_path, e.t, e.obj,
       format('estimated %s rows, got %s (per loop%s): %sx %s', round(e.est), round(e.act, 1),
              CASE WHEN e.loops > 1 THEN ', ' || e.loops || ' loops' ELSE '' END,
              round(greatest(e.over, e.under)), CASE WHEN e.under >= 10 THEN 'more than estimated' ELSE 'fewer than estimated' END),
       'the planner chose the join method, the join order and the memory for this node and every node above it from its estimate; '
       || 'a 10x miss means those choices were made for a different amount of data. The plan may still be right: this is where to look first',
       'ANALYZE ' || coalesce(e.node->>'Relation Name', 'the table') || ' if its statistics are stale; for columns that depend on each other, '
       || 'CREATE STATISTICS on them; for a skewed column, a higher statistics target (ALTER TABLE .. ALTER COLUMN .. SET STATISTICS)'
  FROM est_ok e
 WHERE NOT EXISTS (SELECT 1 FROM est_ok d WHERE d.node_path LIKE e.node_path || '.%')
UNION ALL
-- 2. spills: a sort, a hash or a hash aggregate that wrote to disk
SELECT 'spill to disk', 'warning', n.node_path, n.t, n.obj,
       CASE WHEN n.t IN ('Sort', 'Incremental Sort')
            THEN format('%s: %s kB on disk', coalesce(n.node->>'Sort Method', 'external sort'),
                        coalesce(pgvigil.plan_num(n.node->'Sort Space Used')::text,
                                 (SELECT max(pgvigil.plan_num(w->'Sort Space Used'))::text FROM jsonb_array_elements(CASE WHEN jsonb_typeof(n.node->'Workers') = 'array' THEN n.node->'Workers' ELSE '[]' END) w), '?'))
            WHEN n.t = 'Hash'
            THEN format('hash table in %s batches (planned %s): %s kB in memory per batch', n.node->>'Hash Batches',
                        coalesce(n.node->>'Original Hash Batches', '?'), coalesce(n.node->>'Peak Memory Usage', '?'))
            ELSE format('hash aggregate in %s batches, %s kB on disk', coalesce(n.node->>'HashAgg Batches', '?'), coalesce(n.node->>'Disk Usage', '?')) END,
       'the operation needed more memory than work_mem (times hash_mem_multiplier for a hash) and wrote the overflow to temporary files: '
       || 'its rows went to disk and back. Not a fault by itself: the cure is memory where it is needed, or fewer rows reaching the node',
       'SET work_mem for this role or session (work_mem is per node per session: a global raise multiplies), or filter earlier so fewer rows reach the node'
  FROM n
 WHERE (n.t IN ('Sort', 'Incremental Sort')
        AND (n.node->>'Sort Space Type' = 'Disk'
             OR EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(n.node->'Workers') = 'array' THEN n.node->'Workers' ELSE '[]' END) w
                         WHERE w->>'Sort Space Type' = 'Disk')))
    OR (n.t = 'Hash' AND pgvigil.plan_num(n.node->'Hash Batches') > 1)
    OR (n.t = 'Aggregate' AND (pgvigil.plan_num(n.node->'HashAgg Batches') > 1 OR pgvigil.plan_num(n.node->'Disk Usage') > 0))
UNION ALL
-- 3. a nested loop over a large outer: the inner side runs once per outer row
SELECT 'nested loop over a large outer', CASE WHEN o.analyzed THEN 'warning' ELSE 'info' END, n.node_path, n.t, o.obj,
       CASE WHEN o.analyzed
            THEN format('the inner side ran %s times (outer %s rows, estimated %s)', round(o.act * o.loops), coalesce(o.obj, o.t), round(o.est * o.loops))
            ELSE format('the inner side is planned to run %s times (outer %s rows, an estimate: no ANALYZE)', round(o.est), coalesce(o.obj, o.t)) END,
       'a nested loop runs its inner side once per outer row: that many index probes or rescans. With few outer rows it is the cheapest join; '
       || 'with many, a hash or merge join reads the inner side once. The planner picks it when it expects few outer rows, so the cause is usually the outer estimate',
       'compare the outer''s estimate with its actual rows (rule "estimate off by 10x"); where the inner side is a scan, an index on its join key'
  FROM n JOIN LATERAL (
         SELECT c.* FROM n c
          WHERE c.node_path LIKE n.node_path || '.%' AND c.node_path NOT LIKE n.node_path || '.%.%'
            AND coalesce(c.node->>'Parent Relationship', 'Outer') = 'Outer'
          ORDER BY c.node_path LIMIT 1) o ON true
 WHERE n.t = 'Nested Loop'
   AND CASE WHEN o.analyzed THEN o.act * o.loops ELSE o.est END >= 10000
UNION ALL
-- 4. a filter removing most rows of a large table
SELECT 'filter removes most rows', 'warning', n.node_path, n.t, n.obj,
       format('read %s rows to return %s (%s%% removed by Filter: %s)', round((n.act + rm) * n.loops), round(n.act * n.loops),
              round(100 * rm / (n.act + rm)), left(n.node->>'Filter', 200)),
       'the node read every one of those rows and threw most of them away: the work is in the rows removed, not in the kind of scan. '
       || 'An index whose leading columns match the filter (or a partial index on the condition) reads only the rows kept; '
       || 'where the same table serves queries that need most of its rows, a scan stays the right plan for them',
       'an index matching the filter on ' || coalesce(n.obj, 'the table') || ', checked in the planner first (a hypothetical index with HypoPG where installed)'
  FROM n CROSS JOIN LATERAL (SELECT pgvigil.plan_num(n.node->'Rows Removed by Filter') AS rm) r
 WHERE n.analyzed AND n.loops > 0 AND r.rm IS NOT NULL
   AND n.t IN ('Seq Scan', 'Index Scan', 'Index Only Scan', 'Bitmap Heap Scan', 'Tid Range Scan')
   AND (n.act + r.rm) * n.loops >= 100000 AND r.rm / greatest(n.act + r.rm, 1) >= 0.9
UNION ALL
-- 5. a lossy bitmap heap scan
SELECT 'lossy bitmap heap scan', 'info', n.node_path, n.t, n.obj,
       format('%s lossy heap blocks (%s exact); %s rows removed by the index recheck', n.node->>'Lossy Heap Blocks',
              coalesce(n.node->>'Exact Heap Blocks', '0'), coalesce(n.node->>'Rows Removed by Index Recheck', '0')),
       'the bitmap outgrew work_mem and kept whole pages instead of rows: every row on a lossy page was read and checked against the condition again',
       'SET work_mem higher for this role or session, or a more selective condition or index so the bitmap stays exact'
  FROM n WHERE n.t = 'Bitmap Heap Scan' AND pgvigil.plan_num(n.node->'Lossy Heap Blocks') > 0
UNION ALL
-- 6. an index-only scan with heap fetches
SELECT 'index-only scan with heap fetches', 'info', n.node_path, n.t, n.obj,
       format('%s heap fetches for %s rows returned', h.f, round(n.act * n.loops)),
       'an index-only scan skips the table only for pages the visibility map marks all-visible; each heap fetch is a table page read the plan '
       || 'was costed to avoid, because the table changed since its last vacuum',
       'VACUUM ' || coalesce(n.node->>'Relation Name', 'the table') || '; if it changes often, a lower autovacuum_vacuum_scale_factor '
       || '(or autovacuum_vacuum_insert_scale_factor for an insert-only table) on it'
  FROM n CROSS JOIN LATERAL (SELECT pgvigil.plan_num(n.node->'Heap Fetches') AS f) h
 WHERE n.t = 'Index Only Scan' AND n.analyzed AND h.f >= 1000 AND h.f >= 0.1 * greatest(n.act * n.loops, 1)
UNION ALL
-- 7. JIT's share of the execution
SELECT 'JIT share', 'warning', '0', 'JIT', NULL,
       format('JIT took %s ms of %s ms (%s%%), %s functions', round(j.total, 1), round(j.exec, 1), round(100 * j.total / j.exec), coalesce(p#>>'{JIT,Functions}', '?')),
       'JIT compiles the query on every execution; here the compiling cost more than it saved. jit_above_cost compares with the planner''s '
       || 'cost estimate, so a short query with a large (or misestimated) cost crosses it',
       'raise jit_above_cost (and jit_inline_above_cost, jit_optimize_above_cost), or SET jit = off for the role or the application that runs it'
  FROM (SELECT pgvigil.plan_num(p#>'{JIT,Timing,Total}') AS total, pgvigil.plan_num(p->'Execution Time') AS exec) j
 WHERE j.total >= 10 AND j.exec > 0 AND j.total >= 0.2 * j.exec
UNION ALL
-- 8. trigger time
SELECT 'trigger time', 'warning', '0', 'Trigger', tr.name,
       format('%s: %s ms in %s calls (%s%% of %s ms)', tr.name, round(tr.ms, 1), tr.calls, round(100 * tr.ms / tr.exec), round(tr.exec, 1)),
       'trigger time is spent outside the plan''s nodes, which do not show it. A foreign key''s RI_ConstraintTrigger checks the other table once per row: '
       || 'on the referenced side (a DELETE or a key UPDATE) that is a search of the referencing table per row, a scan without an index on its column',
       CASE WHEN tr.name LIKE 'RI_ConstraintTrigger%' OR tr.cons IS NOT NULL
            THEN 'an index on the referencing columns of ' || coalesce(tr.cons, 'the foreign key')
            ELSE 'the trigger''s function: what it does per row' END
  FROM (SELECT coalesce(t->>'Trigger Name', 'for constraint ' || (t->>'Constraint Name'), '?') AS name, t->>'Constraint Name' AS cons, pgvigil.plan_num(t->'Time') AS ms,
               t->>'Calls' AS calls, pgvigil.plan_num(p->'Execution Time') AS exec
          FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p->'Triggers') = 'array' THEN p->'Triggers' ELSE '[]' END) t) tr
 WHERE tr.ms >= 10 AND tr.exec > 0 AND tr.ms >= 0.2 * tr.exec
UNION ALL
-- 9. parallel workers planned but not launched
SELECT 'parallel workers not launched', 'warning', n.node_path, n.t, NULL,
       format('%s workers planned, %s launched', n.node->>'Workers Planned', n.node->>'Workers Launched'),
       'the plan was costed for its workers and ran with fewer: the leader and the launched workers did the rest. Workers come from '
       || 'max_parallel_workers (within max_worker_processes) at run time, shared by every parallel query on the server',
       'compare max_parallel_workers with the parallel queries running at once; lower max_parallel_workers_per_gather for a busy role rather than raise the pool blindly'
  FROM n
 WHERE n.t IN ('Gather', 'Gather Merge') AND n.node ? 'Workers Launched'
   AND pgvigil.plan_num(n.node->'Workers Launched') < pgvigil.plan_num(n.node->'Workers Planned')
UNION ALL
-- 10. a CTE scanned twice (or more)
SELECT 'CTE scanned twice', 'info', min(n.node_path), 'CTE Scan', n.node->>'CTE Name',
       format('CTE %s is read by %s CTE Scan nodes', n.node->>'CTE Name', count(*)),
       'a CTE referenced more than once is computed once and kept: each reference reads the stored rows, and the outer query''s conditions '
       || 'cannot be pushed into it, so it is computed whole even where a reference needs a few of its rows; a large one goes to a temp file',
       'where each reference filters it differently, NOT MATERIALIZED (PostgreSQL 12+) plans each reference inline, at the cost of computing it per reference'
  FROM n WHERE n.t = 'CTE Scan' AND n.node ? 'CTE Name'
 GROUP BY n.node->>'CTE Name'
HAVING count(*) >= 2
$$;

CREATE OR REPLACE VIEW pgvigil.plan_rule_hits AS
SELECT p.plan_id, p.instance_id, p.source, p.captured_at, p.queryid, p.datname, r.*
  FROM pgvigil.plans p CROSS JOIN LATERAL pgvigil.plan_rules(p.plan) r
 WHERE p.plan IS NOT NULL;

-- the last 7 days' plans per instance and rule: the plans it hit, the worst example (by the statement's duration or
-- total time), in pgvigil.findings' ten columns
CREATE OR REPLACE VIEW pgvigil.plan_findings AS
WITH h AS (
  SELECT r.*, p.duration_ms, p.total_ms, left(regexp_replace(coalesce(p.query, ''), '\s+', ' ', 'g'), 120) AS q
    FROM pgvigil.plan_rule_hits r JOIN pgvigil.plans p USING (plan_id)
   WHERE p.captured_at > now() - interval '7 days'
), agg AS (
  SELECT h.instance_id, h.rule, count(DISTINCT h.plan_id) AS plans, max(h.captured_at) AS last_at FROM h GROUP BY 1, 2
), w AS (
  SELECT DISTINCT ON (h.instance_id, h.rule) h.*, agg.plans, agg.last_at
    FROM h JOIN agg USING (instance_id, rule)
   ORDER BY h.instance_id, h.rule, (h.severity = 'warning') DESC, coalesce(h.duration_ms, h.total_ms, 0) DESC, h.captured_at DESC
)
SELECT w.instance_id, w.severity, 'plan: ' || w.rule AS setting,
       w.value || coalesce(' on ' || w.object, '') AS value, true AS is_set, w.suggested, 'all' AS platforms,
       w.why || '. ' || w.plans || CASE WHEN w.plans = 1 THEN ' plan' ELSE ' plans' END || ' in 7 days; the worst: plan ' || w.plan_id
       || ' (' || w.source || coalesce(', queryid ' || w.queryid, '') || '): ' || w.q AS detail,
       'pgvigil' AS source, w.last_at AS at
  FROM w;

-- the actions door's EXPLAIN ANALYZE: a third action, with no pid; the statement and the database it ran in
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_action_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_action_check CHECK (action IN ('cancel', 'terminate', 'explain_analyze'));
ALTER TABLE pgvigil.actions_log ALTER COLUMN pid DROP NOT NULL;
ALTER TABLE pgvigil.actions_log ADD COLUMN IF NOT EXISTS datname text;
ALTER TABLE pgvigil.actions_log ADD COLUMN IF NOT EXISTS statement text;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_pid_check CHECK (pid IS NOT NULL OR action = 'explain_analyze');

CREATE OR REPLACE FUNCTION pgvigil.import_actions_log(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.actions_log (instance_id, instance_name, at, ui_user, client, action, pid, backend_start,
                                   target_user, target_app, reason, outcome, detail, datname, statement)
  SELECT p_instance_id, x.instance_name, coalesce(x.at, p_snapshot_at), x.ui_user, nullif(x.client, ''), x.action, nullif(x.pid, 0),
         x.backend_start, nullif(x.target_user, ''), nullif(x.target_app, ''), x.reason, x.outcome, nullif(x.detail, ''),
         nullif(x.datname, ''), nullif(x.statement, '')
    FROM jsonb_to_recordset(p_payload) AS x(instance_name text, at timestamptz, ui_user text, client text, action text,
                                            pid int, backend_start timestamptz, target_user text, target_app text,
                                            reason text, outcome text, detail text, datname text, statement text)
$$;
