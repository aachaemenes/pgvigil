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
-- For the join: add 'mssql_qs_plans_purge' to apply_roles()' owner-only list (it deletes) and
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
  live_xml       text,                     -- NULL under a query_text policy other than full
  plan_state     text NOT NULL             -- read | policy
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
-- 'plan' and whose statement the policy emptied stores no plan and drops one a wider policy stored.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_running_plans(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_running_plans'), p_instance_id);
  INSERT INTO pgvigil.mssql_running_plan AS t (instance_id, query_hash, plan_hash, stmt_start, stmt_end, database_name, plan_handle,
      first_seen, last_seen, reads, max_requests, max_cpu_ms, max_grant_kb, max_longest_ms, reasons,
      plan_xml, plan_state, plan_note, plan_bytes, plan_read_at)
  SELECT DISTINCT ON (r->>'query_hash_hex', r->>'plan_hash_hex', (r->>'stmt_start')::int, (r->>'stmt_end')::int)
         p_instance_id, r->>'query_hash_hex', r->>'plan_hash_hex', (r->>'stmt_start')::int, (r->>'stmt_end')::int, r->>'database_name',
         r->>'plan_handle', p_snapshot_at, p_snapshot_at, 1, (r->>'requests')::int, (r->>'cpu_ms')::bigint, (r->>'grant_kb')::bigint,
         (r->>'longest_ms')::bigint, r->>'reasons',
         CASE WHEN r->>'kind_of' = 'plan' THEN r->>'statement' END,
         CASE WHEN r->>'kind_of' = 'plan' AND coalesce(r->>'statement', '') = '' THEN 'policy' ELSE r->>'plan_state' END,
         r->>'plan_note', (r->>'plan_bytes')::bigint, CASE WHEN r ? 'plan_state' THEN p_snapshot_at END
    FROM jsonb_array_elements(p_payload) r
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
    -- a plan read replaces the stored one; a policy row drops it; a failed read keeps what was stored
    plan_xml       = CASE WHEN EXCLUDED.plan_state = 'read' THEN EXCLUDED.plan_xml WHEN EXCLUDED.plan_state = 'policy' THEN NULL ELSE t.plan_xml END,
    plan_state     = CASE WHEN EXCLUDED.plan_state IS NULL THEN t.plan_state
                          WHEN EXCLUDED.plan_state IN ('read', 'policy', 'too large', 'encrypted') OR t.plan_xml IS NULL THEN EXCLUDED.plan_state
                          ELSE t.plan_state END,
    plan_note      = CASE WHEN EXCLUDED.plan_state IS NULL THEN t.plan_note ELSE EXCLUDED.plan_note END,
    plan_bytes     = coalesce(EXCLUDED.plan_bytes, t.plan_bytes),
    plan_read_at   = coalesce(EXCLUDED.plan_read_at, t.plan_read_at);
END $$;

-- payload: 'live' rows {query_hash_hex, plan_hash_hex, stmt_start, stmt_end, session_id, request_id, cpu_ms, running_ms,
-- database_name, kind_of 'plan', statement = the live plan}; one 'live_read' row {asked, read[, note]}.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_live_plans(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  livePlanKeep CONSTANT int := 5;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_live_plans'), p_instance_id);
  INSERT INTO pgvigil.mssql_live_plan (instance_id, captured_at, query_hash, plan_hash, stmt_start, stmt_end, session_id, request_id,
      cpu_ms, running_ms, database_name, live_xml, plan_state)
  SELECT p_instance_id, p_snapshot_at, r->>'query_hash_hex', r->>'plan_hash_hex', (r->>'stmt_start')::int, (r->>'stmt_end')::int,
         (r->>'session_id')::int, (r->>'request_id')::int, (r->>'cpu_ms')::bigint, (r->>'running_ms')::bigint, r->>'database_name',
         nullif(r->>'statement', ''), CASE WHEN coalesce(r->>'statement', '') = '' THEN 'policy' ELSE 'read' END
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'live' AND r->>'query_hash_hex' IS NOT NULL AND r->>'plan_hash_hex' IS NOT NULL
     AND r->>'stmt_start' IS NOT NULL AND r->>'stmt_end' IS NOT NULL;
  -- the newest captures per key are kept
  DELETE FROM pgvigil.mssql_live_plan l
   USING (SELECT live_id, row_number() OVER (PARTITION BY query_hash, plan_hash, stmt_start, stmt_end ORDER BY captured_at DESC, live_id DESC) AS rn
            FROM pgvigil.mssql_live_plan WHERE instance_id = p_instance_id) x
   WHERE l.live_id = x.live_id AND x.rn > livePlanKeep;
  INSERT INTO pgvigil.mssql_live_read AS t (instance_id, snapshot_at, asked, read, note)
  SELECT p_instance_id, p_snapshot_at, coalesce((r->>'asked')::int, 0), coalesce((r->>'read')::int, 0), r->>'note'
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'live_read' LIMIT 1
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
  RETURN n;
END $$;
