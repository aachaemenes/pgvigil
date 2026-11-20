-- 0157: Query Store and plans (task 406, B12; internal/mssql/plancache.go, querystore.go; internal/web/q_mssql_qs_plans.go).
--
-- mssql_running_plans (off by default; every minute once an instance's schedules: name it): the plans of running
-- queries that meet DBA Dash 4.25.0's plan threshold, keyed as DBA Dash keys them (query hash, plan hash, the
-- statement's offsets).
--   mssql_running_plan   one row per instance and key: when first and last seen, the most requests, CPU, grant and
--                        running time a read saw on it, the threshold(s) met, and its plan under the query_text policy
--                        (full only: a plan carries the statement's text and its compiled values).
-- mssql_live_plans (off by default, build-gated in the collector): the live plan of a long running request.
--   mssql_live_plan      one row per capture (instance, the key, the session and request, CPU and running time so
--                        far, the plan with its operator counters); the newest livePlanKeep per key are kept.
--   mssql_live_read      the last read per instance: requests asked, plans read, and why none when none.
--
-- The statistics a plan was compiled with (PerformanceMonitor 3.13 Added 1), read from the plan's OptimizerStatsUsage
-- by the collector (plancache.go PlanStatsUsed) as 'plan_stats' rows of the Query Store and running plan reads:
--   mssql_plan_stat        one row per plan (source 'qs' or 'running'), statement and statistic, as the plan saw it.
--   mssql_plan_stat_status each with the table's rows at the last index read (mssql_index), the auto-update line
--                          (500 rows up to 500; past that 500 + 20 %, or at compatibility 130 and later the smaller of
--                          that and sqrt(1000 x rows)), modified % and stale_at_compile.
-- A forced plan's failures (PerformanceMonitor 3.13 Changed 15): sys.query_store_plan.force_failure_count rises only
-- when the query is compiled and the forcing fails, and starts again at 0 when the plan is forced anew, so a trigger on
-- mssql_qs_plan keeps each change (mssql_qs_force_fail: the rise, or a reset when it went down). The finding 'a forced
-- plan fails' is a warning when, since the plan's last reset, one read saw 2 or more failures or two failures were
-- read within 24 h of each other; with one failure it is an info that says it is held.
-- import_mssql_querystore is 0126's, renamed import_mssql_querystore_0126 and called unchanged by a new one that then
-- stores the 'plan_stats' rows (0126 did the same to 0083's). mssql_querystore_findings is 0083's with the forced plan
-- arm changed as above and one arm more: 'a plan compiled on stale statistics' (info); its columns are unchanged, so
-- pgvigil.findings' arm is unchanged.
--
-- The running plans switch of a page instance (admin_instances.running_plans, false for every row; ticked on Admin >
-- Instances through import_admin_running_plans; admin_inventory() re-made with it) and the audit of a plan read by its
-- handle (custom_report_log op 'plan_read'; 0131's import_custom_report_run with the op) are at the end.
-- The actions_log constraints below start from 0102 and 0078: a later migration that adds an action merges the lists.
-- 0190 adds 'mssql_qs_plans_purge' and 'mssql_plan_stats_store' to apply_roles()' owner-only list (it deletes) and
-- n := n + pgvigil.mssql_qs_plans_purge(p_days) to purge(). No partitioned parent, no findings arm here.
SET LOCAL lock_timeout = '20s';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_running_plan (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  query_hash      text NOT NULL,           -- 0x text, as the collector reads it
  plan_hash       text NOT NULL,
  stmt_start      int NOT NULL,
  stmt_end        int NOT NULL,
  database_name   text,
  plan_handle     text,                    -- the handle the last read saw it under
  first_seen      timestamptz NOT NULL,
  last_seen       timestamptz NOT NULL,
  reads           int NOT NULL DEFAULT 1,  -- the reads that saw it meet the threshold
  max_requests    int,
  max_cpu_ms      bigint,
  max_grant_kb    bigint,
  max_longest_ms  bigint,
  reasons         text,                    -- the thresholds the last read saw met: cpu, grant, count, duration
  compatibility_level int,                 -- the database's, as the last read saw it (the statistics' auto-update line)
  plan_xml        text,
  plan_state      text,                    -- read | policy | too large | encrypted | gone | no plan | error; NULL = not asked yet
  plan_note       text,
  plan_bytes      bigint,
  plan_read_at    timestamptz,
  PRIMARY KEY (instance_id, query_hash, plan_hash, stmt_start, stmt_end)
);
CREATE INDEX IF NOT EXISTS mssql_running_plan_seen_idx ON pgvigil.mssql_running_plan (instance_id, last_seen);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_live_plan (
  live_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  captured_at    timestamptz NOT NULL,
  query_hash     text NOT NULL,
  plan_hash      text NOT NULL,
  stmt_start     int NOT NULL,
  stmt_end       int NOT NULL,
  session_id     int,
  request_id     int,
  cpu_ms         bigint,
  running_ms     bigint,
  database_name  text,
  live_xml       text,                     -- NULL under a query_text policy other than full, or over the size cap
  plan_bytes     bigint,
  plan_state     text NOT NULL             -- read | policy | too large
);
CREATE INDEX IF NOT EXISTS mssql_live_plan_key_idx ON pgvigil.mssql_live_plan (instance_id, query_hash, plan_hash, stmt_start, stmt_end, captured_at);
CREATE INDEX IF NOT EXISTS mssql_live_plan_at_idx ON pgvigil.mssql_live_plan (instance_id, captured_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_live_read (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at  timestamptz NOT NULL,
  asked        int NOT NULL,
  read         int NOT NULL,
  note         text
);

-- payload: 'running' rows {query_hash_hex, plan_hash_hex, stmt_start, stmt_end, plan_handle, database_name, requests,
-- cpu_ms, grant_kb, longest_ms, reasons[, plan_state, plan_note, plan_bytes][, kind_of 'plan', statement = the plan]}.
-- A row without plan_state carries its figures only (its plan was sent within the hour). A row whose kind_of is
-- 'plan' and whose statement the policy emptied stores no plan and drops one a wider policy stored. Every read sends
-- one 'plan_policy' row {kind_of 'plan', statement 'kept'}: emptied by the policy, the instance's stored plans and live
-- captures are dropped whole (mssql_plans_policy_drop), as 0083 drops a database's Query Store XML.
CREATE OR REPLACE FUNCTION pgvigil.mssql_plans_policy_drop(p_instance_id int, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(pgvigil.mssql_rows(p_payload)) r
              WHERE r->>'kind' = 'plan_policy' AND coalesce(r->>'statement', '') = '') THEN
    -- the running plans first, then the live captures: both imports take them in this order
    UPDATE pgvigil.mssql_running_plan SET plan_xml = NULL, plan_state = 'policy', plan_note = NULL
     WHERE instance_id = p_instance_id AND plan_xml IS NOT NULL;
    UPDATE pgvigil.mssql_live_plan SET live_xml = NULL, plan_state = 'policy'
     WHERE instance_id = p_instance_id AND live_xml IS NOT NULL;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_running_plans(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_running_plans'), p_instance_id);
  PERFORM pgvigil.mssql_plans_policy_drop(p_instance_id, p_payload);
  INSERT INTO pgvigil.mssql_running_plan AS t (instance_id, query_hash, plan_hash, stmt_start, stmt_end, database_name, plan_handle,
      first_seen, last_seen, reads, max_requests, max_cpu_ms, max_grant_kb, max_longest_ms, reasons, compatibility_level,
      plan_xml, plan_state, plan_note, plan_bytes, plan_read_at)
  SELECT DISTINCT ON (r->>'query_hash_hex', r->>'plan_hash_hex', (r->>'stmt_start')::int, (r->>'stmt_end')::int)
         p_instance_id, r->>'query_hash_hex', r->>'plan_hash_hex', (r->>'stmt_start')::int, (r->>'stmt_end')::int, r->>'database_name',
         r->>'plan_handle', p_snapshot_at, p_snapshot_at, 1, (r->>'requests')::int, (r->>'cpu_ms')::bigint, (r->>'grant_kb')::bigint,
         (r->>'longest_ms')::bigint, r->>'reasons', (r->>'compatibility_level')::int,
         CASE WHEN r->>'kind_of' = 'plan' THEN r->>'statement' END,
         CASE WHEN r->>'kind_of' = 'plan' AND coalesce(r->>'statement', '') = '' THEN 'policy' ELSE r->>'plan_state' END,
         r->>'plan_note', (r->>'plan_bytes')::bigint, CASE WHEN r ? 'plan_state' THEN p_snapshot_at END
    FROM jsonb_array_elements(pgvigil.mssql_rows(p_payload)) r
   WHERE r->>'kind' = 'running' AND r->>'query_hash_hex' IS NOT NULL AND r->>'plan_hash_hex' IS NOT NULL
     AND r->>'stmt_start' IS NOT NULL AND r->>'stmt_end' IS NOT NULL
   ORDER BY r->>'query_hash_hex', r->>'plan_hash_hex', (r->>'stmt_start')::int, (r->>'stmt_end')::int, (r->>'cpu_ms')::bigint DESC
  ON CONFLICT (instance_id, query_hash, plan_hash, stmt_start, stmt_end) DO UPDATE SET
    database_name  = coalesce(EXCLUDED.database_name, t.database_name),
    plan_handle    = coalesce(EXCLUDED.plan_handle, t.plan_handle),
    last_seen      = greatest(t.last_seen, EXCLUDED.last_seen),
    reads          = t.reads + CASE WHEN EXCLUDED.last_seen > t.last_seen THEN 1 ELSE 0 END,
    max_requests   = greatest(t.max_requests, EXCLUDED.max_requests),
    max_cpu_ms     = greatest(t.max_cpu_ms, EXCLUDED.max_cpu_ms),
    max_grant_kb   = greatest(t.max_grant_kb, EXCLUDED.max_grant_kb),
    max_longest_ms = greatest(t.max_longest_ms, EXCLUDED.max_longest_ms),
    reasons        = EXCLUDED.reasons,
    compatibility_level = coalesce(EXCLUDED.compatibility_level, t.compatibility_level),
    -- a plan read replaces the stored one; a policy row drops it; a failed read keeps what was stored
    plan_xml       = CASE WHEN EXCLUDED.plan_state = 'read' THEN EXCLUDED.plan_xml WHEN EXCLUDED.plan_state = 'policy' THEN NULL ELSE t.plan_xml END,
    plan_state     = CASE WHEN EXCLUDED.plan_state IS NULL THEN t.plan_state
                          WHEN EXCLUDED.plan_state IN ('read', 'policy', 'too large', 'encrypted') OR t.plan_xml IS NULL THEN EXCLUDED.plan_state
                          ELSE t.plan_state END,
    plan_note      = CASE WHEN EXCLUDED.plan_state IS NULL THEN t.plan_note ELSE EXCLUDED.plan_note END,
    plan_bytes     = coalesce(EXCLUDED.plan_bytes, t.plan_bytes),
    plan_read_at   = coalesce(EXCLUDED.plan_read_at, t.plan_read_at);
  PERFORM pgvigil.mssql_plan_stats_store(p_instance_id, p_snapshot_at, p_payload, 'running');
END $$;

-- payload: 'live' rows {query_hash_hex, plan_hash_hex, stmt_start, stmt_end, session_id, request_id, cpu_ms, running_ms,
-- database_name, plan_bytes, kind_of 'plan', statement = the live plan} (over the size cap: plan_state 'too large', no
-- statement); one 'live_read' row {asked, read[, note]}; one 'plan_policy' row (above).
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_live_plans(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  livePlanKeep CONSTANT int := 5;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_live_plans'), p_instance_id);
  PERFORM pgvigil.mssql_plans_policy_drop(p_instance_id, p_payload);
  INSERT INTO pgvigil.mssql_live_plan (instance_id, captured_at, query_hash, plan_hash, stmt_start, stmt_end, session_id, request_id,
      cpu_ms, running_ms, database_name, live_xml, plan_bytes, plan_state)
  SELECT p_instance_id, p_snapshot_at, r->>'query_hash_hex', r->>'plan_hash_hex', (r->>'stmt_start')::int, (r->>'stmt_end')::int,
         (r->>'session_id')::int, (r->>'request_id')::int, (r->>'cpu_ms')::bigint, (r->>'running_ms')::bigint, r->>'database_name',
         CASE WHEN r->>'kind_of' = 'plan' THEN nullif(r->>'statement', '') END, (r->>'plan_bytes')::bigint,
         CASE WHEN r->>'plan_state' = 'too large' THEN 'too large' WHEN coalesce(r->>'statement', '') = '' THEN 'policy' ELSE 'read' END
    FROM jsonb_array_elements(pgvigil.mssql_rows(p_payload)) r
   WHERE r->>'kind' = 'live' AND r->>'query_hash_hex' IS NOT NULL AND r->>'plan_hash_hex' IS NOT NULL
     AND r->>'stmt_start' IS NOT NULL AND r->>'stmt_end' IS NOT NULL;
  -- the newest captures per key are kept
  DELETE FROM pgvigil.mssql_live_plan l
   USING (SELECT live_id, row_number() OVER (PARTITION BY query_hash, plan_hash, stmt_start, stmt_end ORDER BY captured_at DESC, live_id DESC) AS rn
            FROM pgvigil.mssql_live_plan WHERE instance_id = p_instance_id) x
   WHERE l.live_id = x.live_id AND x.rn > livePlanKeep;
  INSERT INTO pgvigil.mssql_live_read AS t (instance_id, snapshot_at, asked, read, note)
  SELECT p_instance_id, p_snapshot_at, coalesce((r->>'asked')::int, 0), coalesce((r->>'read')::int, 0), r->>'note'
    FROM jsonb_array_elements(pgvigil.mssql_rows(p_payload)) r WHERE r->>'kind' = 'live_read' LIMIT 1
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, asked = EXCLUDED.asked, read = EXCLUDED.read, note = EXCLUDED.note
   WHERE t.snapshot_at <= EXCLUDED.snapshot_at;
END $$;

-- purge: plans not seen for p_days, live captures older than p_days.
CREATE OR REPLACE FUNCTION pgvigil.mssql_qs_plans_purge(p_days int)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n bigint := 0;
  c bigint;
BEGIN
  DELETE FROM pgvigil.mssql_live_plan WHERE captured_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  DELETE FROM pgvigil.mssql_running_plan WHERE last_seen < now() - make_interval(days => p_days);
  GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  DELETE FROM pgvigil.mssql_plan_stat WHERE captured_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  DELETE FROM pgvigil.mssql_qs_force_fail WHERE seen_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  RETURN n;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- the statistics a plan was compiled with
-- ---------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.mssql_plan_stat (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  source              text NOT NULL CHECK (source IN ('qs', 'running')),
  plan_key            text NOT NULL,          -- qs: <database>:<plan_id>; running: <query hash>|<plan hash>|<start>|<end>
  database_name       text,                   -- the plan's database (qs: the store's)
  plan_id             bigint,                 -- qs only
  stmt                int NOT NULL,
  stat_database       text NOT NULL,
  stat_schema         text NOT NULL,
  stat_table          text NOT NULL,
  stat_name           text NOT NULL,
  modification_count  bigint,
  sampling_pct        real,
  last_update         text,
  captured_at         timestamptz NOT NULL,
  PRIMARY KEY (instance_id, source, plan_key, stmt, stat_database, stat_schema, stat_table, stat_name)
);

-- the 'plan_stats' rows of one read into mssql_plan_stat: a plan's rows replace what it had
CREATE OR REPLACE FUNCTION pgvigil.mssql_plan_stats_store(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb, p_source text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS pgv_plan_stat_in (plan_key text, database_name text, plan_id bigint, stmt int, stat_database text,
    stat_schema text, stat_table text, stat_name text, modification_count bigint, sampling_pct real, last_update text) ON COMMIT DROP;
  TRUNCATE pgv_plan_stat_in;
  INSERT INTO pgv_plan_stat_in
  SELECT DISTINCT ON (k, (r->>'stmt')::int, r->>'stat_database', r->>'stat_schema', r->>'stat_table', r->>'stat_name')
         k, r->>'database_name', (r->>'plan_id')::bigint, (r->>'stmt')::int, r->>'stat_database', r->>'stat_schema', r->>'stat_table',
         r->>'stat_name', (r->>'modification_count')::bigint, (r->>'sampling_pct')::real, r->>'last_update'
    FROM jsonb_array_elements(pgvigil.mssql_rows(p_payload)) r
    CROSS JOIN LATERAL (SELECT CASE WHEN p_source = 'qs' THEN (r->>'database_name') || ':' || (r->>'plan_id')
                                    ELSE concat_ws('|', r->>'query_hash_hex', r->>'plan_hash_hex', r->>'stmt_start', r->>'stmt_end') END AS k) x
   WHERE r->>'kind' = 'plan_stats' AND r->>'stmt' IS NOT NULL AND r->>'stat_name' IS NOT NULL AND x.k IS NOT NULL
     AND coalesce(r->>'stat_database', '') <> '' AND r->>'stat_schema' IS NOT NULL AND r->>'stat_table' IS NOT NULL;
  DELETE FROM pgvigil.mssql_plan_stat s
   WHERE s.instance_id = p_instance_id AND s.source = p_source AND s.plan_key IN (SELECT DISTINCT plan_key FROM pgv_plan_stat_in);
  INSERT INTO pgvigil.mssql_plan_stat (instance_id, source, plan_key, database_name, plan_id, stmt, stat_database, stat_schema, stat_table,
      stat_name, modification_count, sampling_pct, last_update, captured_at)
  SELECT p_instance_id, p_source, plan_key, database_name, plan_id, stmt, stat_database, stat_schema, stat_table, stat_name,
         modification_count, sampling_pct, last_update, p_snapshot_at
    FROM pgv_plan_stat_in;
END $$;

-- the auto-update line of a statistic on a table of p_rows rows at compatibility p_compat (NULL = 130 or later)
CREATE OR REPLACE FUNCTION pgvigil.mssql_stats_update_line(p_rows bigint, p_compat int)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_rows IS NULL THEN NULL
              WHEN p_rows <= 500 THEN 500
              WHEN coalesce(p_compat, 130) >= 130 THEN least(500 + 0.2 * p_rows, sqrt(1000.0 * p_rows))::numeric
              ELSE (500 + 0.2 * p_rows)::numeric END
$$;

CREATE OR REPLACE VIEW pgvigil.mssql_plan_stat_status AS
SELECT s.instance_id, s.source, s.plan_key, s.database_name, s.plan_id, s.stmt, s.stat_database, s.stat_schema, s.stat_table, s.stat_name,
       s.modification_count, s.sampling_pct, s.last_update, s.captured_at, t.row_count AS table_rows, t.read_at AS rows_read_at,
       c.compatibility_level,
       round(100.0 * s.modification_count / nullif(t.row_count, 0), 1) AS modified_pct,
       round(pgvigil.mssql_stats_update_line(t.row_count, c.compatibility_level)) AS update_line,
       (s.modification_count >= pgvigil.mssql_stats_update_line(t.row_count, c.compatibility_level)) AS stale_at_compile,
       CASE WHEN t.row_count IS NULL THEN 'rows not read'
            WHEN c.compatibility_level IS NULL THEN 'not judged: the database''s compatibility level is not known' END AS not_judged
  FROM pgvigil.mssql_plan_stat s
  LEFT JOIN LATERAL (SELECT max(i.row_count) AS row_count, max(i.snapshot_at) AS read_at FROM pgvigil.mssql_index i
                      WHERE i.instance_id = s.instance_id AND i.database_name = s.stat_database AND i.schema_name = s.stat_schema
                        AND i.table_name = s.stat_table AND i.index_id IN (0, 1)) t ON true
  LEFT JOIN pgvigil.mssql_qs_plan qp ON s.source = 'qs' AND qp.instance_id = s.instance_id AND qp.database_name = s.database_name AND qp.plan_id = s.plan_id
  LEFT JOIN pgvigil.mssql_running_plan rp ON s.source = 'running' AND rp.instance_id = s.instance_id
        AND s.plan_key = concat_ws('|', rp.query_hash, rp.plan_hash, rp.stmt_start, rp.stmt_end)
  CROSS JOIN LATERAL (SELECT coalesce(qp.compatibility_level, rp.compatibility_level) AS compatibility_level) c;

-- 0126's import, renamed and called unchanged; then the statistics of the plans this read stored
DO $$ BEGIN
  IF to_regprocedure('pgvigil.import_mssql_querystore_0126(int, timestamptz, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_querystore(int, timestamptz, jsonb) RENAME TO import_mssql_querystore_0126;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_querystore(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.import_mssql_querystore_0126(p_instance_id, p_snapshot_at, p_payload);
  PERFORM pgvigil.mssql_plan_stats_store(p_instance_id, p_snapshot_at, p_payload, 'qs');
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- a forced plan's failures
-- ---------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.mssql_qs_force_fail (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  plan_id        bigint NOT NULL,
  seen_at        timestamptz NOT NULL,      -- the read that saw the change
  count_before   bigint,                    -- NULL: the first read of the plan
  count_after    bigint NOT NULL,
  rise           bigint NOT NULL,           -- failures this read saw (0 on a reset)
  reset          boolean NOT NULL DEFAULT false,  -- the count went down: the plan was forced anew, a new window starts
  PRIMARY KEY (instance_id, database_name, plan_id, seen_at)
);

CREATE OR REPLACE FUNCTION pgvigil.mssql_qs_force_fail_track()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_old bigint := CASE WHEN TG_OP = 'UPDATE' THEN OLD.force_failure_count END;
  v_new bigint := NEW.force_failure_count;
BEGIN
  IF v_new IS NULL OR v_new IS NOT DISTINCT FROM v_old OR (v_old IS NULL AND v_new = 0) THEN
    RETURN NULL;
  END IF;
  INSERT INTO pgvigil.mssql_qs_force_fail (instance_id, database_name, plan_id, seen_at, count_before, count_after, rise, reset)
  VALUES (NEW.instance_id, NEW.database_name, NEW.plan_id, NEW.snapshot_at, v_old, v_new,
          CASE WHEN v_old IS NULL THEN v_new WHEN v_new > v_old THEN v_new - v_old ELSE v_new END, v_old IS NOT NULL AND v_new < v_old)
  ON CONFLICT (instance_id, database_name, plan_id, seen_at) DO UPDATE SET count_after = EXCLUDED.count_after,
    rise = pgvigil.mssql_qs_force_fail.rise + EXCLUDED.rise, reset = pgvigil.mssql_qs_force_fail.reset OR EXCLUDED.reset;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS mssql_qs_force_fail_track ON pgvigil.mssql_qs_plan;
CREATE TRIGGER mssql_qs_force_fail_track AFTER INSERT OR UPDATE OF force_failure_count ON pgvigil.mssql_qs_plan
  FOR EACH ROW EXECUTE FUNCTION pgvigil.mssql_qs_force_fail_track();

-- each forced plan's failures since its last reset: paged = one read saw 2 or more, or two failure reads lie within
-- 24 h of each other; held = one failure only
CREATE OR REPLACE VIEW pgvigil.mssql_qs_force_fail_status AS
WITH w AS (
  SELECT f.*, max(f.seen_at) FILTER (WHERE f.reset) OVER (PARTITION BY f.instance_id, f.database_name, f.plan_id) AS last_reset
    FROM pgvigil.mssql_qs_force_fail f
), cur AS (
  SELECT * FROM w WHERE last_reset IS NULL OR seen_at >= last_reset
), j AS (
  SELECT c.instance_id, c.database_name, c.plan_id, count(*) FILTER (WHERE c.rise > 0) AS failure_reads, sum(c.rise) AS failures,
         min(c.seen_at) FILTER (WHERE c.rise > 0) AS first_failure, max(c.seen_at) FILTER (WHERE c.rise > 0) AS last_failure,
         bool_or(c.rise >= 2) AS two_in_one_read,
         bool_or(EXISTS (SELECT 1 FROM cur c2 WHERE c2.instance_id = c.instance_id AND c2.database_name = c.database_name AND c2.plan_id = c.plan_id
                          AND c2.rise > 0 AND c.rise > 0 AND c2.seen_at > c.seen_at AND c2.seen_at <= c.seen_at + interval '24 hours')) AS two_in_24h
    FROM cur c GROUP BY c.instance_id, c.database_name, c.plan_id
)
SELECT j.*, (j.two_in_one_read OR j.two_in_24h) AS paged FROM j WHERE j.failure_reads > 0;

CREATE OR REPLACE VIEW pgvigil.mssql_querystore_findings AS
SELECT s.instance_id, s.severity,
       CASE WHEN s.actual_state = 'ERROR' THEN 'Query Store in the ERROR state'
            WHEN s.actual_state = 'READ_ONLY' THEN 'Query Store is read-only'
            WHEN s.actual_state = 'OFF' THEN 'Query Store is off though asked for'
            ELSE 'Query Store near its max size' END::text AS check_name,
       s.database_name AS object, s.snapshot_at AS at, s.verdict AS detail
  FROM pgvigil.mssql_qs_store_status s
 WHERE s.severity IS NOT NULL AND s.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT p.instance_id, CASE WHEN coalesce(ff.paged, true) THEN 'warning' ELSE 'info' END, 'a forced plan fails',
       p.database_name || ': query ' || p.query_id || ', plan ' || p.plan_id, p.snapshot_at,
       format('plan %s is forced (%s) for query %s%s and SQL Server could not use it %s time(s) since it was forced; the last reason: %s. '
              || 'The query last ran %s and the forced plan %s: the query runs with another plan.%s',
              p.plan_id, lower(coalesce(p.forcing_type, 'manual')), p.query_id, coalesce(' in ' || q.object_name, ''),
              p.force_failure_count, coalesce(p.force_failure_reason, 'not given'),
              coalesce(to_char(q.last_execution AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC', 'at a time that was not read'),
              coalesce('last ran ' || to_char(p.last_execution AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC', 'has no execution on record'),
              CASE WHEN ff.paged IS NULL THEN ''
                   WHEN ff.paged THEN format(' Since it was last forced: %s failure(s) in %s read(s); %s.', ff.failures, ff.failure_reads,
                                             CASE WHEN ff.two_in_one_read THEN 'one read saw 2 or more' ELSE 'two within 24 hours' END)
                   -- held: the newest failure starts the 24 h a second one pages within
                   ELSE format(' Held: %s (read %s UTC); it pages on a second failure within 24 hours of that one.',
                               CASE WHEN ff.failure_reads = 1 THEN 'it failed once'
                                    ELSE format('no two of its %s failures since it was forced lie within 24 hours of each other', ff.failures) END,
                               to_char(ff.last_failure AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')) END)
  FROM pgvigil.mssql_qs_plan p
  LEFT JOIN pgvigil.mssql_qs_query q ON q.instance_id = p.instance_id AND q.database_name = p.database_name AND q.query_id = p.query_id
                                    AND q.query_hash IS NOT DISTINCT FROM p.query_hash
  LEFT JOIN pgvigil.mssql_qs_force_fail_status ff ON ff.instance_id = p.instance_id AND ff.database_name = p.database_name AND ff.plan_id = p.plan_id
 WHERE p.is_forced AND p.force_failure_count > 0 AND p.snapshot_at > now() - interval '3 hours'
   AND (p.last_execution IS NULL OR q.last_execution IS NULL OR p.last_execution < q.last_execution - interval '10 seconds')
UNION ALL
SELECT p.instance_id, 'info', 'a plan compiled on stale statistics',
       p.database_name || ': query ' || p.query_id || ', plan ' || p.plan_id, p.snapshot_at,
       format('plan %s of query %s was compiled with %s statistic(s) past their auto-update line: %s. '
              || 'AUTO_UPDATE_STATISTICS off, asynchronous updates or NORECOMPUTE leave a statistic stale at compile.',
              p.plan_id, p.query_id, count(*), string_agg(format('%s.%s.%s (%s rows changed, line %s)', st.stat_schema, st.stat_table, st.stat_name,
                st.modification_count, st.update_line), ', ' ORDER BY st.modification_count DESC))
  FROM pgvigil.mssql_qs_plan p
  JOIN pgvigil.mssql_plan_stat_status st ON st.instance_id = p.instance_id AND st.source = 'qs' AND st.database_name = p.database_name AND st.plan_id = p.plan_id
 WHERE st.stale_at_compile AND p.snapshot_at > now() - interval '3 hours'
 GROUP BY p.instance_id, p.database_name, p.query_id, p.plan_id, p.snapshot_at;

-- ---------------------------------------------------------------------------------------------------------------
-- one statement on every instance (PerformanceMonitor 3.13 Added 14); statements containing a text (Added 15)
-- ---------------------------------------------------------------------------------------------------------------
-- SQL Server's query hash is computed from the statement's shape, so the same statement carries the same hash on every
-- server: the plan cache's samples (query_key = the hash) and the Query Store's intervals (query_hash) of the window,
-- per instance, database and source, the most CPU first. A plan cache read cut at the collector's lists, or a store
-- interval kept only for its top plans, makes a figure a floor: capped_reads says how many plan cache reads were cut.
CREATE OR REPLACE FUNCTION pgvigil.mssql_statement_everywhere(p_hash text, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (instance_id int, instance text, source text, database text, executions numeric, cpu_ms numeric, duration_ms numeric,
               logical_reads numeric, first_seen timestamptz, last_seen timestamptz, capped_reads bigint)
LANGUAGE sql STABLE AS $$
  SELECT x.instance_id, i.name, x.source, x.database_name, x.executions, x.cpu_ms, x.duration_ms, x.logical_reads, x.first_seen, x.last_seen, x.capped_reads
    FROM (
      SELECT s.instance_id, 'plan cache'::text AS source, max(s.database_name) AS database_name, sum(s.executions)::numeric AS executions,
             round(sum(s.cpu_us) / 1000.0, 3) AS cpu_ms, round(sum(s.duration_us) / 1000.0, 3) AS duration_ms, sum(s.logical_reads)::numeric AS logical_reads,
             min(s.snapshot_at) AS first_seen, max(s.snapshot_at) AS last_seen,
             (SELECT count(*) FROM pgvigil.mssql_pc_read r WHERE r.instance_id = s.instance_id AND r.snapshot_at > p_from AND r.snapshot_at <= p_to AND r.capped) AS capped_reads
        FROM pgvigil.mssql_pc_sample s
       WHERE s.query_key = p_hash AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
       GROUP BY s.instance_id, s.database_id
      UNION ALL
      SELECT r.instance_id, 'Query Store', r.database_name, sum(r.executions), round(sum(r.cpu_us) / 1000.0, 3), round(sum(r.duration_us) / 1000.0, 3),
             sum(r.logical_reads), min(r.snapshot_at), max(r.interval_end), NULL::bigint
        FROM pgvigil.mssql_qs_runtime r
       WHERE r.query_hash = p_hash AND r.interval_end > p_from AND r.snapshot_at <= p_to
       GROUP BY r.instance_id, r.database_name
    ) x JOIN pgvigil.instances i ON i.instance_id = x.instance_id
   ORDER BY x.cpu_ms DESC NULLS LAST, i.name, x.source
$$;

-- the stored statement texts of SQL Server instances holding p_pattern (an ILIKE pattern the caller escaped, ESCAPE
-- '\'), from the plan cache's texts or the Query Store's; p_instance NULL = every instance. p_skip: the instances whose
-- query_text policy is 'none' NOW (serve's configuration): a policy change clears no stored text (a plan cache text goes
-- only when its key is sent again, a Query Store text when a later read returns its query), so their stored texts are
-- never returned. The caller bounds the time.
DROP FUNCTION IF EXISTS pgvigil.mssql_statement_search(text, text, int, int);
CREATE OR REPLACE FUNCTION pgvigil.mssql_statement_search(p_pattern text, p_source text, p_instance int, p_limit int, p_skip int[])
RETURNS TABLE (instance_id int, instance text, source text, database text, statement_key text, object_name text, statement text, seen_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT t.instance_id, i.name, 'plan cache'::text, d.database_name, t.query_key, t.object_name, left(t.query, 400), t.seen_at
    FROM pgvigil.mssql_pc_text t JOIN pgvigil.instances i ON i.instance_id = t.instance_id
    LEFT JOIN pgvigil.mssql_pc_database d ON d.instance_id = t.instance_id AND d.database_id = t.database_id
   WHERE p_source = 'plan cache' AND (p_instance IS NULL OR t.instance_id = p_instance) AND t.instance_id <> ALL (coalesce(p_skip, '{}'))
     AND t.query ILIKE p_pattern ESCAPE '\'
  UNION ALL
  SELECT q.instance_id, i.name, 'Query Store', q.database_name, q.query_hash, q.object_name, left(q.query_text, 400), q.last_execution
    FROM pgvigil.mssql_qs_query q JOIN pgvigil.instances i ON i.instance_id = q.instance_id
   WHERE p_source = 'Query Store' AND (p_instance IS NULL OR q.instance_id = p_instance) AND q.instance_id <> ALL (coalesce(p_skip, '{}'))
     AND q.query_text ILIKE p_pattern ESCAPE '\'
   LIMIT p_limit
$$;

-- whether the optional trigram indexes over the stored texts exist and can be used (docs/sqlserver-querystore.md has
-- the DBA's statements; pgvigil never builds them): a failed CREATE INDEX CONCURRENTLY leaves an invalid one behind
CREATE OR REPLACE FUNCTION pgvigil.mssql_text_index_state()
RETURNS TABLE (index_name text, on_table text, present boolean, valid boolean, ready boolean, size_bytes bigint)
LANGUAGE sql STABLE AS $$
  SELECT w.index_name, w.on_table, c.oid IS NOT NULL, coalesce(x.indisvalid, false), coalesce(x.indisready, false),
         CASE WHEN c.oid IS NOT NULL THEN pg_relation_size(c.oid) END
    FROM (VALUES ('mssql_pc_text_query_trgm', 'mssql_pc_text'), ('mssql_qs_query_text_trgm', 'mssql_qs_query')) w(index_name, on_table)
    LEFT JOIN pg_class c ON c.relname = w.index_name AND c.relnamespace = 'pgvigil'::regnamespace
    LEFT JOIN pg_index x ON x.indexrelid = c.oid
$$;

-- ---------------------------------------------------------------------------------------------------------------
-- the actions door's plan_evict (Opserver's remove-plan): the audit's two constraints with the action added (the
-- list of 0102 and 0078; a later file that changes the list starts from this one's)
-- ---------------------------------------------------------------------------------------------------------------
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_action_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_action_check CHECK (
     (engine = 'postgres' AND action IN ('cancel', 'terminate', 'explain_analyze', 'hypo_index', 'job_stop', 'job_start'))
  OR (engine = 'sqlserver' AND action IN ('kill', 'job_start', 'job_stop', 'plan_evict')));
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_pid_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_pid_check CHECK (pid IS NOT NULL OR action IN ('explain_analyze', 'hypo_index', 'job_start', 'job_stop', 'plan_evict'));

-- ---------------------------------------------------------------------------------------------------------------
-- the plans pgvigil holds or can read for one statement's hashes (SQLWATCH COL#27: a slow or long-wait event's plan),
-- by instance, database, query hash and plan hash (the event's own, as xe_shred.go's hashHex writes them): a Query
-- Store plan with its XML, a running query's kept plan, and the plan cache's entries read on demand by handle
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgvigil.mssql_plan_sources(p_instance int, p_database text, p_query_hash text, p_plan_hash text)
RETURNS TABLE (source text, database text, plan_id bigint, plan_handle text, stmt_start int, stmt_end int, has_plan boolean, seen_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT 'Query Store', p.database_name, p.plan_id, NULL::text, NULL::int, NULL::int, p.xml_state = 'stored', p.last_execution
    FROM pgvigil.mssql_qs_plan p
   WHERE p.instance_id = p_instance AND p.database_name = p_database AND p.query_hash = p_query_hash AND p.plan_hash = p_plan_hash
  UNION ALL
  SELECT 'running', r.database_name, NULL, r.plan_handle, r.stmt_start, r.stmt_end, r.plan_xml IS NOT NULL, r.last_seen
    FROM pgvigil.mssql_running_plan r
   WHERE r.instance_id = p_instance AND r.query_hash = p_query_hash AND r.plan_hash = p_plan_hash
     AND (r.database_name IS NULL OR r.database_name = p_database)
  UNION ALL
  SELECT 'plan cache', d.database_name, NULL, l.plan_handle, l.stmt_start, l.stmt_end, true, s.snapshot_at
    FROM pgvigil.mssql_pc_last l
    JOIN pgvigil.mssql_pc_handles h ON h.instance_id = l.instance_id AND h.plan_handle = l.plan_handle AND h.stmt_start = l.stmt_start
                                   AND h.stmt_end = l.stmt_end AND h.creation_time = l.creation_time
    LEFT JOIN pgvigil.mssql_pc_database d ON d.instance_id = l.instance_id AND d.database_id = l.database_id
    LEFT JOIN pgvigil.mssql_pc_state s ON s.instance_id = l.instance_id
   WHERE l.instance_id = p_instance AND l.query_key = p_query_hash AND h.plan_hash = p_plan_hash
     AND (d.database_name IS NULL OR d.database_name = p_database)
$$;

-- ---------------------------------------------------------------------------------------------------------------
-- a plan read by its handle is audited (a plan carries the statement's literals): op 'plan_read' in
-- custom_report_log, written by serve through the actions door's audit login before the plan is answered (who, the
-- client, the instance, the handle and offsets, the state read; never the plan). 0131's CHECK and function, the op
-- added; a join that adds another op (0164's 'histogram') merges the lists.
-- ---------------------------------------------------------------------------------------------------------------
ALTER TABLE pgvigil.custom_report_log DROP CONSTRAINT IF EXISTS custom_report_log_op_check;
ALTER TABLE pgvigil.custom_report_log ADD CONSTRAINT custom_report_log_op_check
  CHECK (op IN ('add', 'edit', 'delete', 'move', 'folder_add', 'folder_rename', 'folder_delete',
                'run', 'community_run', 'community_help', 'community_form', 'plan_read'));

CREATE OR REPLACE FUNCTION pgvigil.import_custom_report_run(p_at timestamptz, p_payload jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_op   text := p_payload->>'op';
  v_out  text := p_payload->>'outcome';
  v_door text := nullif(p_payload->>'door', '');
  v_id   bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_custom_report_run: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('run', 'community_run', 'community_help', 'community_form', 'plan_read') THEN
    RAISE EXCEPTION 'import_custom_report_run: op % is not run, community_run, community_help, community_form or plan_read', v_op USING ERRCODE = '22023';
  END IF;
  IF v_out IS NULL OR v_out NOT IN ('done', 'refused', 'failed') THEN
    RAISE EXCEPTION 'import_custom_report_run: outcome % is not done, refused or failed', v_out USING ERRCODE = '22023';
  END IF;
  IF v_door IS NOT NULL AND v_door NOT IN ('file', 'page', 'store') THEN
    RAISE EXCEPTION 'import_custom_report_run: door % is not file, page or store', v_door USING ERRCODE = '22023';
  END IF;
  INSERT INTO pgvigil.custom_report_log (at, ui_user, client, op, report_id, report_name, tool, instance_id, instance, outcome,
                                         detail, rows, duration_ms, statement, payload, door, door_generation)
  VALUES (p_at, v_user, nullif(p_payload->>'client', ''), v_op,
          CASE WHEN coalesce(p_payload->>'report_id', '') ~ '^[0-9]{1,18}$' THEN (p_payload->>'report_id')::bigint END,
          nullif(p_payload->>'report_name', ''), nullif(p_payload->>'tool', ''),
          CASE WHEN coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'instance_id')::int END,
          nullif(p_payload->>'instance', ''), v_out, left(p_payload->>'detail', 4000),
          CASE WHEN coalesce(p_payload->>'rows', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'rows')::int END,
          CASE WHEN coalesce(p_payload->>'duration_ms', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'duration_ms')::int END,
          left(p_payload->>'statement', 200000), p_payload->'params', v_door,
          CASE WHEN coalesce(p_payload->>'door_generation', '') ~ '^-?[0-9]{1,18}$' THEN (p_payload->>'door_generation')::bigint END)
  RETURNING log_id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- the running plans switch of an instance added in Admin > Instances (task 406: the locked-
-- down default). admin_instances.running_plans is false for every row, those there at the upgrade and those added
-- after; an admin ticks it on the page (import_admin_running_plans, audited as the page's other changes). The collector
-- reads it through admin_inventory() (0131's, one column more) and runs mssql_running_plans each minute for a ticked
-- instance unless pgvigil.yaml's schedules: say otherwise (config.Interval reads the page's default after the file's
-- schedules:). An instance of pgvigil.yaml keeps its own schedules: as before.
-- ---------------------------------------------------------------------------------------------------------------
ALTER TABLE pgvigil.admin_instances ADD COLUMN IF NOT EXISTS running_plans boolean NOT NULL DEFAULT false;

-- payload {op 'running_plans', ui_user, client, name, on, file_names}: the answer as import_admin_instance's
CREATE OR REPLACE FUNCTION pgvigil.import_admin_running_plans(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli  text := p_payload->>'client';
  v_name text := btrim(coalesce(p_payload->>'name', ''));
  v_on   text := p_payload->>'on';
  v_have pgvigil.admin_instances%ROWTYPE;
  v_why  text;
  v_gen  bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_running_plans: no ui_user' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_have FROM pgvigil.admin_instances WHERE name = v_name;
  IF coalesce(p_payload->>'op', '') <> 'running_plans' THEN
    v_why := 'op must be running_plans';
  ELSIF v_on IS NULL OR v_on NOT IN ('true', 'false') THEN
    v_why := 'on must be true or false';
  ELSIF jsonb_typeof(p_payload->'file_names') = 'array' AND p_payload->'file_names' ? v_name THEN
    v_why := format('%s is an instance of pgvigil.yaml: its schedules: in the file switch its running plans (mssql_running_plans: 1m)', v_name);
  ELSIF v_have.name IS NULL THEN
    v_why := format('no instance %s was added here', v_name);
  ELSIF v_have.engine <> 'sqlserver' THEN
    v_why := format('%s is not a SQL Server instance: the plans of running queries are read on SQL Server only', v_name);
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'instance running_plans', v_name, 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  UPDATE pgvigil.admin_instances SET running_plans = (v_on = 'true'), updated_at = p_at, updated_by = v_user WHERE name = v_name;
  v_gen := pgvigil.admin_bump();
  PERFORM pgvigil.admin_log(v_user, v_cli, 'instance running_plans', v_name, 'done',
    CASE WHEN v_on = 'true' THEN 'on: the plans of its running queries are read each minute (their statement text and literals, masked, kept under the query_text policy)'
         ELSE 'off: the plans of its running queries are no longer read' END);
  RETURN jsonb_build_object('outcome', 'done', 'detail', format('running plans %s for %s', CASE WHEN v_on = 'true' THEN 'on' ELSE 'off' END, v_name), 'generation', v_gen);
END $$;

DROP FUNCTION IF EXISTS pgvigil.admin_inventory();
CREATE FUNCTION pgvigil.admin_inventory()
RETURNS TABLE (name text, engine text, platform text, dsn_ref text, tags text[], disabled boolean, auth text, options text, generation bigint,
               running_plans boolean)
LANGUAGE sql STABLE AS $$
  SELECT a.name, a.engine, a.platform, a.dsn_ref, a.tags, a.disabled, a.auth, a.options, s.generation, a.running_plans
    FROM pgvigil.admin_inventory_state s LEFT JOIN pgvigil.admin_instances a ON true
   WHERE s.one
   ORDER BY a.name
$$;
ALTER FUNCTION pgvigil.admin_inventory() SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_collector') THEN
    GRANT EXECUTE ON FUNCTION pgvigil.admin_inventory() TO pgvigil_collector;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_reader') THEN
    GRANT EXECUTE ON FUNCTION pgvigil.admin_inventory() TO pgvigil_reader;
  END IF;
END $$;
