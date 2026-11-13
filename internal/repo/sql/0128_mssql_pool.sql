-- 0128: Azure SQL Database elastic pools (CLOUDSQL C4). mssql_pool (internal/mssql/pool.go) reads
-- sys.dm_elastic_pool_resource_stats from every pooled database it collects, each minute, and sends the complete
-- minutes it saw (about 40 of them: the view keeps about 40 minutes); a pool's minute is stored once, by the first
-- reader (the key: logical server, pool, minute).
--
--   mssql_pool_minute      monthly partitions; a pool's minute (snapshot_at: the minute's start, UTC): the average of
--                          the view's few-second averages, the largest of its maxima, the largest average CPU
--                          (max_cpu_percent), the storage figures as the minute ended; instance_id: the database
--                          whose read stored it (ensure_month_partition indexes instance_id, snapshot_at); where the
--                          pool's name came from.
--   mssql_pool_member      which pool each pooled database was last read in (the Summary's cell sits on each
--                          pooled database's row: DBA Dash's 'Elastic Pool Storage').
--   mssql_pool_thresholds  DBA Dash's ElasticPoolStorageThresholds: warning and critical as fractions of the pool's
--                          maximum data size; the row ('', '') is the default (DBA Dash's PoolID -1: 0.8 / 0.9),
--                          a pool's own row wins; a NULL threshold makes the status N/A.
--
-- mssql_pool_storage_status(instance_id): DBA Dash's AzureDBElasticPoolStorageStatus on the instance's pool's newest
-- minute - allocated_storage_percent > critical x 100 Critical, else > warning x 100 Warning (a strict '>': 80 is
-- OK at 0.8), else a NULL WARNING threshold N/A, else OK (DBA Dash's view line for line: a NULL critical threshold or
-- percentage compares as false); pgvigil's own: N/A when the pool has no minute in the last 5 minutes, and no row
-- at all for a database not read in a pool for over 10 minutes (it left the pool: its member row stays behind).
-- The partition parent for purge() (the join adds it): mssql_pool_minute.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pool_minute (
  server                      text NOT NULL,     -- the logical server (@@SERVERNAME)
  pool                        text NOT NULL,
  snapshot_at                 timestamptz NOT NULL,  -- the minute (its start, UTC)
  samples                     int NOT NULL,
  avg_cpu_percent             numeric(5,2),
  max_cpu_percent             numeric(5,2),
  avg_data_io_percent         numeric(5,2),
  avg_log_write_percent       numeric(5,2),
  max_worker_percent          numeric(5,2),
  max_session_percent         numeric(5,2),
  avg_instance_cpu_percent    numeric(5,2),
  avg_instance_memory_percent numeric(5,2),
  avg_edtu_percent            numeric(5,2),     -- DTU pools only
  instance_vcores             numeric(5,2),
  used_storage_mb             bigint,
  allocated_storage_mb        bigint,
  storage_limit_mb            bigint,
  used_storage_percent        numeric(5,2),
  allocated_storage_percent   numeric(5,2),
  instance_id                 int NOT NULL,      -- the database whose read stored the minute
  name_from                   text NOT NULL CHECK (name_from IN ('tag', 'service objectives')),
  PRIMARY KEY (server, pool, snapshot_at)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pool_member (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  server       text NOT NULL,
  pool         text NOT NULL,
  seen_at      timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pool_thresholds (
  server    text NOT NULL,
  pool      text NOT NULL,
  warning   numeric(5,4) CHECK (warning > 0 AND warning <= 1),
  critical  numeric(5,4) CHECK (critical > 0 AND critical <= 1),
  PRIMARY KEY (server, pool)
);
INSERT INTO pgvigil.mssql_pool_thresholds (server, pool, warning, critical) VALUES ('', '', 0.8, 0.9) ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_pool(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_min timestamptz;
  v_max timestamptz;
  v_r   jsonb;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_pool: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  IF jsonb_typeof(p_payload) <> 'array' OR jsonb_array_length(p_payload) = 0 THEN
    RETURN;
  END IF;
  SELECT min((r->>'minute')::timestamptz), max((r->>'minute')::timestamptz) INTO v_min, v_max FROM jsonb_array_elements(p_payload) r;
  PERFORM pgvigil.ensure_month_partition('mssql_pool_minute', v_min);
  PERFORM pgvigil.ensure_month_partition('mssql_pool_minute', v_max);
  INSERT INTO pgvigil.mssql_pool_minute (server, pool, snapshot_at, samples, avg_cpu_percent, max_cpu_percent, avg_data_io_percent,
         avg_log_write_percent, max_worker_percent, max_session_percent, avg_instance_cpu_percent, avg_instance_memory_percent,
         avg_edtu_percent, instance_vcores, used_storage_mb, allocated_storage_mb, storage_limit_mb, used_storage_percent,
         allocated_storage_percent, instance_id, name_from)
  SELECT r->>'server', r->>'pool', (r->>'minute')::timestamptz, (r->>'samples')::int,
         (r->>'avg_cpu_percent')::numeric, (r->>'max_cpu_percent')::numeric, (r->>'avg_data_io_percent')::numeric,
         (r->>'avg_log_write_percent')::numeric, (r->>'max_worker_percent')::numeric, (r->>'max_session_percent')::numeric,
         (r->>'avg_instance_cpu_percent')::numeric, (r->>'avg_instance_memory_percent')::numeric, (r->>'avg_edtu_percent')::numeric,
         (r->>'instance_vcores')::numeric, round((r->>'used_storage_mb')::numeric)::bigint, round((r->>'allocated_storage_mb')::numeric)::bigint,
         round((r->>'storage_limit_mb')::numeric)::bigint, (r->>'used_storage_percent')::numeric, (r->>'allocated_storage_percent')::numeric,
         p_instance_id, r->>'name_from'
    FROM jsonb_array_elements(p_payload) r
  ON CONFLICT (server, pool, snapshot_at) DO NOTHING;
  -- the database's pool as this read saw it (the newest minute's)
  SELECT r INTO v_r FROM jsonb_array_elements(p_payload) r ORDER BY (r->>'minute')::timestamptz DESC LIMIT 1;
  INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at)
  VALUES (p_instance_id, v_r->>'server', v_r->>'pool', p_snapshot_at)
  ON CONFLICT (instance_id) DO UPDATE SET server = EXCLUDED.server, pool = EXCLUDED.pool, seen_at = EXCLUDED.seen_at;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_pool_storage_status(p_instance_id int, p_now timestamptz DEFAULT now())
RETURNS TABLE (status text, allocated_storage_percent numeric, minute timestamptz, server text, pool text, warning numeric, critical numeric)
LANGUAGE sql STABLE AS $$
  WITH m AS (SELECT mb.server, mb.pool FROM pgvigil.mssql_pool_member mb
              WHERE mb.instance_id = p_instance_id AND mb.seen_at > p_now - interval '10 minutes'),
  t AS (SELECT th.warning, th.critical FROM m JOIN pgvigil.mssql_pool_thresholds th
          ON (th.server, th.pool) = (m.server, m.pool) OR (th.server, th.pool) = ('', '')
        ORDER BY th.server = '' LIMIT 1),
  n AS (SELECT pm.allocated_storage_percent, pm.snapshot_at AS minute FROM m JOIN pgvigil.mssql_pool_minute pm ON pm.server = m.server AND pm.pool = m.pool
        ORDER BY pm.snapshot_at DESC LIMIT 1)
  SELECT CASE WHEN n.minute IS NULL OR n.minute < p_now - interval '5 minutes' THEN 'N/A'
              WHEN n.allocated_storage_percent > t.critical * 100 THEN 'Critical'
              WHEN n.allocated_storage_percent > t.warning * 100 THEN 'Warning'
              WHEN t.warning IS NULL THEN 'N/A'
              ELSE 'OK' END,
         n.allocated_storage_percent, n.minute, m.server, m.pool, t.warning, t.critical
    FROM m LEFT JOIN t ON true LEFT JOIN n ON true
$$;
