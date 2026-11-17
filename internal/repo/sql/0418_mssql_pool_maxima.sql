-- 0418 (control audit A3; the number and the shape the lead's 11-17 14:37: its own migration, not a join line - an
-- installed store gets new columns only through a migration): DBA Dash's Pool chart's Max Data %, Max Log Write % and
-- Max DTU % - each minute's largest sample of sys.dm_elastic_pool_resource_stats' avg_data_io_percent,
-- avg_log_write_percent and avg_edtu_percent (Microsoft Learn, read 2026-11-17: the view's only max_ columns are
-- max_worker_percent and max_session_percent; its rows come every few seconds and stay about 40 minutes), stored beside
-- the minute's averages as 0128 stores max_cpu_percent. The pool's DTUs used and its DTU limit are not columns: the view
-- holds no DTU limit, so the reads take it from 0395's limit history (the dbmanager opt-in's read).
--   mssql_pool_minute       gains max_data_io_percent, max_log_write_percent, max_edtu_percent (NULL on a minute read
--                           before 0418, and max_edtu_percent on a vCore pool); and (control audit A5) cpu_buckets,
--                           data_buckets, log_buckets, dtu_buckets - the minute's samples in ten 10 % buckets each
--                           (DBA Dash's AzureDBElasticPoolResourceStats_Raw), NULL before 0418 and dtu_buckets on a vCore pool
--   import_mssql_pool       re-made from its NEWEST text - 0128's on this branch - with the three columns; a NAMED CHECK
--                           of the join (j17): a newer text of import_mssql_pool at the join is the one re-made here.

ALTER TABLE pgvigil.mssql_pool_minute ADD COLUMN IF NOT EXISTS max_data_io_percent   numeric(5,2);
ALTER TABLE pgvigil.mssql_pool_minute ADD COLUMN IF NOT EXISTS max_log_write_percent numeric(5,2);
ALTER TABLE pgvigil.mssql_pool_minute ADD COLUMN IF NOT EXISTS max_edtu_percent      numeric(5,2);
ALTER TABLE pgvigil.mssql_pool_minute ADD COLUMN IF NOT EXISTS cpu_buckets           smallint[];
ALTER TABLE pgvigil.mssql_pool_minute ADD COLUMN IF NOT EXISTS data_buckets          smallint[];
ALTER TABLE pgvigil.mssql_pool_minute ADD COLUMN IF NOT EXISTS log_buckets           smallint[];
ALTER TABLE pgvigil.mssql_pool_minute ADD COLUMN IF NOT EXISTS dtu_buckets           smallint[];

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
  -- only the rows that carry a minute: a collector's note row (a stale pool tag) is the run's, not a minute; a read
  -- with no complete minute stores nothing
  IF jsonb_typeof(p_payload) <> 'array' OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r ? 'minute') THEN
    RETURN;
  END IF;
  SELECT min((r->>'minute')::timestamptz), max((r->>'minute')::timestamptz) INTO v_min, v_max FROM jsonb_array_elements(p_payload) r WHERE r ? 'minute';
  PERFORM pgvigil.ensure_month_partition('mssql_pool_minute', v_min);
  PERFORM pgvigil.ensure_month_partition('mssql_pool_minute', v_max);
  INSERT INTO pgvigil.mssql_pool_minute (server, pool, snapshot_at, samples, avg_cpu_percent, max_cpu_percent, avg_data_io_percent,
         avg_log_write_percent, max_worker_percent, max_session_percent, avg_instance_cpu_percent, avg_instance_memory_percent,
         avg_edtu_percent, instance_vcores, used_storage_mb, allocated_storage_mb, storage_limit_mb, used_storage_percent,
         allocated_storage_percent, instance_id, name_from, max_data_io_percent, max_log_write_percent, max_edtu_percent,
         cpu_buckets, data_buckets, log_buckets, dtu_buckets)
  SELECT r->>'server', r->>'pool', (r->>'minute')::timestamptz, (r->>'samples')::int,
         (r->>'avg_cpu_percent')::numeric, (r->>'max_cpu_percent')::numeric, (r->>'avg_data_io_percent')::numeric,
         (r->>'avg_log_write_percent')::numeric, (r->>'max_worker_percent')::numeric, (r->>'max_session_percent')::numeric,
         (r->>'avg_instance_cpu_percent')::numeric, (r->>'avg_instance_memory_percent')::numeric, (r->>'avg_edtu_percent')::numeric,
         (r->>'instance_vcores')::numeric, round((r->>'used_storage_mb')::numeric)::bigint, round((r->>'allocated_storage_mb')::numeric)::bigint,
         round((r->>'storage_limit_mb')::numeric)::bigint, (r->>'used_storage_percent')::numeric, (r->>'allocated_storage_percent')::numeric,
         p_instance_id, r->>'name_from',
         (r->>'max_data_io_percent')::numeric, (r->>'max_log_write_percent')::numeric, (r->>'max_edtu_percent')::numeric,
         -- a JSON null or a missing key (a collector before 0418) stores NULL, never an empty array
         CASE WHEN jsonb_typeof(r->'cpu_buckets') = 'array' THEN ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(r->'cpu_buckets') x) END,
         CASE WHEN jsonb_typeof(r->'data_buckets') = 'array' THEN ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(r->'data_buckets') x) END,
         CASE WHEN jsonb_typeof(r->'log_buckets') = 'array' THEN ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(r->'log_buckets') x) END,
         CASE WHEN jsonb_typeof(r->'dtu_buckets') = 'array' THEN ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(r->'dtu_buckets') x) END
    FROM jsonb_array_elements(p_payload) r WHERE r ? 'minute'
  ON CONFLICT (server, pool, snapshot_at) DO NOTHING;
  -- the database's pool as this read saw it (the newest minute's)
  SELECT r INTO v_r FROM jsonb_array_elements(p_payload) r WHERE r ? 'minute' ORDER BY (r->>'minute')::timestamptz DESC LIMIT 1;
  INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at)
  VALUES (p_instance_id, v_r->>'server', v_r->>'pool', p_snapshot_at)
  ON CONFLICT (instance_id) DO UPDATE SET server = EXCLUDED.server, pool = EXCLUDED.pool, seen_at = EXCLUDED.seen_at;
END $$;
