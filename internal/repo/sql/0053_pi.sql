-- 0053_pi: Performance Insights kept past its seven days and the Serverless v2 cache rule (phase 3 wave E, task 56).
--   1. the pi collection (hourly, RDS and Aurora with Performance Insights on): pi_state, one current row per
--      instance (on or off, the DbiResourceId, PI's own retention: an instance with PI off has no pi_load row and the
--      Load tab says so from this row); pi_load, the hourly DB load (db.load.avg) in total, by wait event and by SQL
--      digest, one row per hour and key (an hour read again replaces its value: PI revises the newest hour); pi_sql,
--      the top SQL digests with their text (the digest as GetResourceMetrics returns it, cut at 500 bytes by the API,
--      and the whole text of one of its statements from GetDimensionKeyDetails), both under the query_text policy
--      (the collector applies it before the import: normalized stores the literal-free form, none no text at all).
--   2. the serverless collection (every 5 minutes, Aurora): serverless_sample, the per-instance CloudWatch series the
--      cache rule reads (ServerlessDatabaseCapacity, ACUUtilization, BufferCacheHitRatio, ReadIOPS, CPUUtilization),
--      one row per metric and datapoint as cloud_io_sample keeps them; serverless_scaling, the instance's cluster and
--      its Serverless v2 range (DescribeDBClusters, read once an hour), one current row per instance.
--   3. pi_findings: "cache starved by the ACU floor" in the findings view's columns (the join puts it under
--      pgvigil.findings).
-- Retention: pi_load and serverless_sample are monthly partitions, dropped whole by pgvigil.purge with the statements'
-- retention (their names join purge's list in the wave's join migration); pi_sql rows not seen within the retention
-- are deleted there too (one DELETE line, the join's). pi_state and serverless_scaling hold one row per instance.

-- ---------------------------------------------------------------------------------------------------------
-- 1. Performance Insights
-- ---------------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.pi_state (
  instance_id     int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at     timestamptz NOT NULL,      -- the run that last wrote the row
  db_instance     text,                      -- the DB instance identifier PI was asked about
  resource_id     text,                      -- its DbiResourceId (the PI API's Identifier)
  enabled         boolean NOT NULL,          -- DescribeDBInstances PerformanceInsightsEnabled
  retention_days  int,                       -- PerformanceInsightsRetentionPeriod (7 = the free tier)
  hours_read      int,                       -- the hours of load this run stored
  note            text                       -- why nothing was read (PI off), or what failed in part
);

-- snapshot_at is the start of the PI hour (PeriodAlignment START_TIME, 3600 s); dim_group is 'total' (dim_key ''),
-- 'wait' (dim_key the event name, wait_type its type) or 'sql' (dim_key the db.sql_tokenized.id)
CREATE TABLE IF NOT EXISTS pgvigil.pi_load (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  dim_group     text NOT NULL CHECK (dim_group IN ('total', 'wait', 'sql')),
  dim_key       text NOT NULL,
  wait_type     text,
  load_avg      double precision,            -- db.load.avg over the hour: the average active sessions
  read_at       timestamptz NOT NULL
) PARTITION BY RANGE (snapshot_at);
CREATE UNIQUE INDEX IF NOT EXISTS pi_load_key ON pgvigil.pi_load (instance_id, dim_group, dim_key, snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.pi_sql (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  tokenized_id  text NOT NULL,               -- db.sql_tokenized.id (the console's Support ID)
  db_id         text,                        -- db.sql_tokenized.db_id: pg_stat_statements' queryid, or a pi- id
  digest        text,                        -- db.sql_tokenized.statement, at most 500 bytes (the API's cut)
  full_text     text,                        -- db.sql.statement of one statement of the digest, whole (GetDimensionKeyDetails)
  text_status   text,                        -- 'whole' (the digest is under the cut), AVAILABLE, PROCESSING (PI returned it
                                             -- cut), UNAVAILABLE, 'no statement id' (no db.sql row of the digest in the read)
  sql_id        text,                        -- the db.sql.id the whole text came from
  first_seen    timestamptz NOT NULL,
  last_seen     timestamptz NOT NULL,
  PRIMARY KEY (instance_id, tokenized_id)
);

-- payload: rows {kind:'state', db_instance, resource_id, enabled, retention_days, hours_read, note}
--               {kind:'load', at, group, key, wait_type, value}
--               {kind:'sql', tokenized_id, db_id, query (the digest), statement (the whole text), text_status, sql_id}
CREATE OR REPLACE FUNCTION pgvigil.import_pi(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_month timestamptz;
BEGIN
  INSERT INTO pgvigil.pi_state AS s (instance_id, snapshot_at, db_instance, resource_id, enabled, retention_days, hours_read, note)
  SELECT p_instance_id, p_snapshot_at, r->>'db_instance', r->>'resource_id', coalesce((r->>'enabled')::boolean, false),
         (r->>'retention_days')::int, (r->>'hours_read')::int, r->>'note'
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'state'
   LIMIT 1
  ON CONFLICT (instance_id) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, db_instance = EXCLUDED.db_instance, resource_id = EXCLUDED.resource_id,
    enabled = EXCLUDED.enabled, retention_days = EXCLUDED.retention_days, hours_read = EXCLUDED.hours_read, note = EXCLUDED.note;

  FOR v_month IN
    SELECT DISTINCT date_trunc('month', (r->>'at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'load' AND r->>'at' IS NOT NULL
  LOOP
    PERFORM pgvigil.ensure_month_partition('pi_load', v_month);
  END LOOP;
  INSERT INTO pgvigil.pi_load AS l (instance_id, snapshot_at, dim_group, dim_key, wait_type, load_avg, read_at)
  SELECT DISTINCT ON (r->>'group', coalesce(r->>'key', ''), (r->>'at')::timestamptz)
         p_instance_id, (r->>'at')::timestamptz, r->>'group', coalesce(r->>'key', ''), r->>'wait_type', (r->>'value')::float8, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'load' AND r->>'at' IS NOT NULL AND r->>'group' IN ('total', 'wait', 'sql')
  ON CONFLICT (instance_id, dim_group, dim_key, snapshot_at) DO UPDATE SET
    wait_type = EXCLUDED.wait_type, load_avg = EXCLUDED.load_avg, read_at = EXCLUDED.read_at;

  -- a text the policy emptied (none) empties the stored one, its status and its statement id too; a run that could
  -- not fetch the whole text keeps the one fetched before with its status and statement id
  INSERT INTO pgvigil.pi_sql AS t (instance_id, tokenized_id, db_id, digest, full_text, text_status, sql_id, first_seen, last_seen)
  SELECT DISTINCT ON (r->>'tokenized_id')
         p_instance_id, r->>'tokenized_id', r->>'db_id', r->>'query', r->>'statement',
         CASE WHEN r->>'query' IS NOT NULL THEN r->>'text_status' END, CASE WHEN r->>'query' IS NOT NULL THEN r->>'sql_id' END,
         p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'sql' AND r->>'tokenized_id' IS NOT NULL
  ON CONFLICT (instance_id, tokenized_id) DO UPDATE SET
    db_id = coalesce(EXCLUDED.db_id, t.db_id),
    digest = EXCLUDED.digest,
    full_text = CASE WHEN EXCLUDED.digest IS NULL THEN NULL ELSE coalesce(EXCLUDED.full_text, t.full_text) END,
    text_status = CASE WHEN EXCLUDED.digest IS NULL THEN NULL
                       WHEN EXCLUDED.full_text IS NULL AND t.full_text IS NOT NULL THEN t.text_status ELSE EXCLUDED.text_status END,
    sql_id = CASE WHEN EXCLUDED.digest IS NULL THEN NULL
                  WHEN EXCLUDED.full_text IS NULL AND t.full_text IS NOT NULL THEN t.sql_id ELSE EXCLUDED.sql_id END,
    last_seen = EXCLUDED.last_seen;
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- 2. Serverless v2 capacity and cache (CloudWatch, per DB instance)
-- ---------------------------------------------------------------------------------------------------------

-- snapshot_at is the DATAPOINT's time (the start of its 5-minute period); read_at the import that last wrote it
CREATE TABLE IF NOT EXISTS pgvigil.serverless_sample (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  metric        text NOT NULL,               -- ServerlessDatabaseCapacity, ACUUtilization, BufferCacheHitRatio, ReadIOPS, CPUUtilization
  value         double precision,
  stat          text,
  unit          text,                        -- ACU, percent, count/s
  dim           text,                        -- the DB instance identifier read
  read_at       timestamptz NOT NULL
) PARTITION BY RANGE (snapshot_at);
CREATE UNIQUE INDEX IF NOT EXISTS serverless_sample_key ON pgvigil.serverless_sample (instance_id, metric, snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.serverless_scaling (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  db_instance   text,
  cluster       text,
  class         text,                        -- db.serverless for a Serverless v2 instance
  min_acu       double precision,            -- ServerlessV2ScalingConfiguration MinCapacity (the floor)
  max_acu       double precision,            -- MaxCapacity (the ceiling)
  note          text
);

-- payload: rows {kind:'metric', dim, metric, stat, unit, at, value}
--               {kind:'scaling', db_instance, cluster, class, min_acu, max_acu, note}
CREATE OR REPLACE FUNCTION pgvigil.import_serverless(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_month timestamptz;
BEGIN
  FOR v_month IN
    SELECT DISTINCT date_trunc('month', (r->>'at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'metric' AND r->>'at' IS NOT NULL
  LOOP
    PERFORM pgvigil.ensure_month_partition('serverless_sample', v_month);
  END LOOP;
  INSERT INTO pgvigil.serverless_sample AS s (instance_id, snapshot_at, metric, value, stat, unit, dim, read_at)
  SELECT DISTINCT ON (r->>'metric', (r->>'at')::timestamptz)
         p_instance_id, (r->>'at')::timestamptz, r->>'metric', (r->>'value')::float8, r->>'stat', r->>'unit', r->>'dim', p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'metric' AND r->>'at' IS NOT NULL AND r->>'metric' IS NOT NULL
  ON CONFLICT (instance_id, metric, snapshot_at) DO UPDATE SET
    value = EXCLUDED.value, stat = EXCLUDED.stat, unit = EXCLUDED.unit, dim = EXCLUDED.dim, read_at = EXCLUDED.read_at;

  INSERT INTO pgvigil.serverless_scaling AS c (instance_id, snapshot_at, db_instance, cluster, class, min_acu, max_acu, note)
  SELECT p_instance_id, p_snapshot_at, r->>'db_instance', r->>'cluster', r->>'class', (r->>'min_acu')::float8,
         (r->>'max_acu')::float8, r->>'note'
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'scaling'
   LIMIT 1
  ON CONFLICT (instance_id) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, db_instance = EXCLUDED.db_instance, cluster = EXCLUDED.cluster, class = EXCLUDED.class,
    min_acu = EXCLUDED.min_acu, max_acu = EXCLUDED.max_acu, note = EXCLUDED.note;
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- 3. pi_findings: the findings view's columns (instance_id, severity, setting, value, is_set, suggested, platforms,
--    detail, source, at); the wave's join migration adds them to pgvigil.findings.
-- ---------------------------------------------------------------------------------------------------------

-- "cache starved by the ACU floor", over the last hour (the k row): the instance's capacity never left the cluster's
-- running floor (every ServerlessDatabaseCapacity datapoint, from above and from below, within 0.01 ACU of MinCapacity,
-- or of 0.5 ACU when MinCapacity is under it: 0.5 is the least an awake instance runs at, a 0 minimum only adds the
-- pause; at least 6 datapoints: half an hour of 5-minute periods awake), its BufferCacheHitRatio averaged under 95 %, and its storage reads high
-- (ReadIOPS at 200 a second or more) while the CPU stayed low (CPUUtilization under 30 %): Serverless v2 scales on CPU,
-- memory and network, never on storage waits, so a working set larger than the floor's buffer cache is read from
-- storage again and again while the capacity stays put. The three figures are in the value and the detail.
CREATE OR REPLACE VIEW pgvigil.pi_findings AS
WITH k AS (SELECT interval '1 hour' AS win, 0.01::float8 AS floor_slack, 6 AS cap_points_min, 95.0::float8 AS hit_min,
                  200.0::float8 AS read_iops_high, 30.0::float8 AS cpu_low,
                  0.5::float8 AS running_min),
m AS (
  SELECT s.instance_id, s.metric, avg(s.value) AS mean, max(s.value) AS high, min(s.value) AS low, count(*) AS points,
         max(s.snapshot_at) AS at
    FROM pgvigil.serverless_sample s JOIN pgvigil.instances i USING (instance_id), k
   WHERE i.is_active AND s.snapshot_at > now() - k.win AND s.value IS NOT NULL
   GROUP BY s.instance_id, s.metric
),
w AS (
  SELECT c.instance_id, c.min_acu, c.max_acu, c.cluster, greatest(c.min_acu, k.running_min) AS run_floor,
         cap.high AS cap_high, cap.low AS cap_low, cap.points AS cap_points, hit.mean AS hit, rd.mean AS read_iops, cpu.mean AS cpu,
         greatest(cap.at, hit.at, rd.at, cpu.at) AS at
    FROM k, pgvigil.serverless_scaling c
    JOIN m cap ON cap.instance_id = c.instance_id AND cap.metric = 'ServerlessDatabaseCapacity'
    JOIN m hit ON hit.instance_id = c.instance_id AND hit.metric = 'BufferCacheHitRatio'
    JOIN m rd  ON rd.instance_id  = c.instance_id AND rd.metric  = 'ReadIOPS'
    JOIN m cpu ON cpu.instance_id = c.instance_id AND cpu.metric = 'CPUUtilization'
   WHERE c.min_acu IS NOT NULL
)
SELECT w.instance_id, 'warning'::text AS severity, 'cache starved by the ACU floor'::text AS setting,
       trim(to_char(w.cap_high, 'FM9990.0')) || ' ACU (floor ' || trim(to_char(w.min_acu, 'FM9990.0'))
         || CASE WHEN w.run_floor > w.min_acu THEN ', running ' || trim(to_char(w.run_floor, 'FM9990.0')) ELSE '' END || '), hit ratio '
         || round(w.hit::numeric, 1)::text || ' %, ' || round(w.read_iops::numeric)::text || ' reads/s at '
         || round(w.cpu::numeric, 1)::text || ' % CPU' AS value,
       true AS is_set,
       'a minimum ACU above ' || trim(to_char(w.run_floor, 'FM9990.0')) || ' (the ceiling is '
         || coalesce(trim(to_char(w.max_acu, 'FM9990.0')), 'unknown') || ')' AS suggested,
       'aurora'::text AS platforms,
       'over the last hour the capacity sat on the cluster''s ' || CASE WHEN w.run_floor > w.min_acu
         THEN 'running floor of ' || trim(to_char(w.run_floor, 'FM9990.0')) || ' ACU (the minimum is ' || trim(to_char(w.min_acu, 'FM9990.0'))
              || ': a 0 minimum only adds the pause)' ELSE 'minimum of ' || trim(to_char(w.min_acu, 'FM9990.0')) || ' ACU' END
         || ', the buffer cache hit ratio averaged ' || round(w.hit::numeric, 1)::text || ' % (under ' || k.hit_min::text
         || ' %) and storage reads averaged ' || round(w.read_iops::numeric)::text || ' a second while the CPU averaged '
         || round(w.cpu::numeric, 1)::text || ' %: the working set does not fit the floor''s cache, and Serverless v2 '
         || 'scales on CPU, memory and network, never on storage waits, so the capacity stays at the floor'
         || coalesce(' (cluster ' || w.cluster || ')', '') AS detail,
       'pgvigil pi'::text AS source, w.at
  FROM w, k
 WHERE w.cap_points >= k.cap_points_min AND w.cap_high <= w.run_floor + k.floor_slack AND w.cap_low >= w.run_floor - k.floor_slack
   AND w.hit < k.hit_min AND w.read_iops >= k.read_iops_high AND w.cpu < k.cpu_low;
