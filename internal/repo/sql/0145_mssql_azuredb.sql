-- 0145: Azure SQL Database's resource use and tier (B2a; DBA Dash's AzureDBResourceStats, AzureDBResourceGovernance
-- and AzureServiceObjectivesHistory).
--
--   mssql_azuredb_minute     monthly partitions; mssql_azuredb_resources (internal/mssql/azuredb_resources.go): a
--                            database's minute of sys.dm_db_resource_stats - the averages of its 15-second rows, the
--                            per-sample maxima of CPU, data IO, log write and memory, DBA Dash's DTU % per sample and
--                            the DTUs it makes (avg and max; NULL on vCore), the sample count, and the ten bucket
--                            counts each of DTU, CPU, data IO and log write (AzureDBResourceStats_Raw: < 10, [10, 20),
--                            ... [80, 90), >= 90) that the Azure Summary sums. A minute is stored once.
--   mssql_azuredb_read       per database: the newest stored minute (the cursor 'azdb_since' of mssql_hadr_cursor:
--                            the next read asks the server for the rows ending after that minute) and the last read.
--   mssql_azuredb_gap        the minutes the store does not have because the view no longer held them (the
--                            collector down over the view's hour, a failover, a serverless resume): the tab's gap line.
--   mssql_azuredb_governance the database's tier as last read (mssql_azuredb_governance, hourly): the view
--                            sys.dm_user_db_resource_governance's row whole (jsonb), the edition, service objective,
--                            pool and max size; user_data_directory_space_usage_mb is kept here only.
--   mssql_azuredb_governance_history  a row per tier as it stood (valid_from, valid_to; 'infinity' = now): a new row
--                            when DBA Dash's 54 compared columns (AzureDBResourceGovernance_Upd: every column it
--                            reads but user_data_directory_space_usage_mb), the edition, the service objective or the
--                            pool differ from the open row, compared by name where present.
--
-- The tier's figures are also the instance's Properties rows (group 'Azure SQL Database', mssql_property; the
-- Properties page renders every row): the service objective, the elastic pool, the DTU limit and the vCore limit are
-- tracked (a change is a row of mssql_property_change, the page's change list: DBA Dash's AzureDBDTULimitChange).
-- mssql_properties itself does not run on Azure SQL Database, so nothing else writes these rows.
--
-- Retention: mssql_azuredb_minute is a monthly partition parent in purge()'s list (0190): purge's p_days applies
-- (DBA Dash keeps AzureDBResourceStats 120 days, its DataRetention seed); the history and the gaps are few rows
-- and kept (DBA Dash keeps no retention row for its governance or service objective histories).

CREATE TABLE IF NOT EXISTS pgvigil.mssql_azuredb_minute (
  instance_id                 int NOT NULL,
  snapshot_at                 timestamptz NOT NULL,   -- the minute (its start, UTC)
  samples                     int NOT NULL,
  avg_cpu_percent             numeric(7,4),
  max_cpu_percent             numeric(5,2),
  avg_data_io_percent         numeric(7,4),
  max_data_io_percent         numeric(5,2),
  avg_log_write_percent       numeric(7,4),
  max_log_write_percent       numeric(5,2),
  avg_memory_usage_percent    numeric(7,4),
  max_memory_usage_percent    numeric(5,2),
  avg_xtp_storage_percent     numeric(7,4),
  max_worker_percent          numeric(5,2),
  max_session_percent         numeric(5,2),
  avg_instance_cpu_percent    numeric(7,4),
  avg_instance_memory_percent numeric(7,4),
  dtu_limit                   int,                    -- NULL on vCore
  cpu_limit                   numeric(7,2),           -- vCores; NULL on DTU
  replica_role                int,                    -- 0 primary, 1 high availability secondary, 2 geo-replication forwarder, 3 named replica
  avg_dtu_percent             numeric(7,4),
  max_dtu_percent             numeric(5,2),
  avg_dtu                     numeric(12,4),
  max_dtu                     numeric(12,4),
  dtu_buckets                 smallint[] NOT NULL,
  cpu_buckets                 smallint[] NOT NULL,
  data_buckets                smallint[] NOT NULL,
  log_buckets                 smallint[] NOT NULL,
  PRIMARY KEY (instance_id, snapshot_at)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_azuredb_read (
  instance_id    int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  newest_minute  timestamptz,           -- NULL until a minute is stored
  read_at        timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_azuredb_gap (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  gap_from     timestamptz NOT NULL,    -- the end of the newest minute stored before it
  gap_to       timestamptz NOT NULL,    -- the start of the first minute stored after it
  oldest_end   timestamptz,             -- the view's oldest row's end at the read that saw it
  noted_at     timestamptz NOT NULL,
  PRIMARY KEY (instance_id, gap_from)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_azuredb_governance (
  instance_id        int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at        timestamptz NOT NULL,  -- the last read
  since              timestamptz NOT NULL,  -- the open history row's valid_from
  edition            text,
  service_objective  text,
  pool               text,
  pool_from          text CHECK (pool_from IN ('tag', 'service objectives')),
  pool_note          text,
  max_size_bytes     bigint,
  slo_name           text,
  dtu_limit          int,
  cpu_limit          numeric(7,2),
  usage_mb           bigint,               -- user_data_directory_space_usage_mb ('updated every five minutes')
  gov                jsonb NOT NULL        -- the view's row, every column it gave
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_azuredb_governance_history (
  instance_id        int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  valid_from         timestamptz NOT NULL,
  valid_to           timestamptz NOT NULL DEFAULT 'infinity',
  edition            text,
  service_objective  text,
  pool               text,
  slo_name           text,
  dtu_limit          int,
  cpu_limit          numeric(7,2),
  gov                jsonb NOT NULL,       -- the view's row without user_data_directory_space_usage_mb
  PRIMARY KEY (instance_id, valid_from)
);

-- the 54 columns DBA Dash's AzureDBResourceGovernance_Upd compares (L73-126 at 4.25.0)
CREATE OR REPLACE FUNCTION pgvigil.mssql_azuredb_gov_compared(p_gov jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb) FROM jsonb_each(p_gov) AS e(k, v)
   WHERE k IN ('database_id', 'logical_database_guid', 'physical_database_guid', 'server_name', 'database_name', 'slo_name',
               'dtu_limit', 'cpu_limit', 'min_cpu', 'max_cpu', 'cap_cpu', 'min_cores', 'max_dop', 'min_memory', 'max_memory',
               'max_sessions', 'max_memory_grant', 'max_db_memory', 'govern_background_io', 'min_db_max_size_in_mb',
               'max_db_max_size_in_mb', 'default_db_max_size_in_mb', 'db_file_growth_in_mb', 'initial_db_file_size_in_mb',
               'log_size_in_mb', 'instance_cap_cpu', 'instance_max_log_rate', 'instance_max_worker_threads', 'replica_type',
               'max_transaction_size', 'checkpoint_rate_mbps', 'checkpoint_rate_io', 'last_updated_date_utc', 'primary_group_id',
               'primary_group_max_workers', 'primary_min_log_rate', 'primary_max_log_rate', 'primary_group_min_io',
               'primary_group_max_io', 'primary_group_min_cpu', 'primary_group_max_cpu', 'primary_log_commit_fee',
               'primary_pool_max_workers', 'pool_max_io', 'govern_db_memory_in_resource_pool', 'volume_local_iops',
               'volume_managed_xstore_iops', 'volume_external_xstore_iops', 'volume_type_local_iops',
               'volume_type_managed_xstore_iops', 'volume_type_external_xstore_iops', 'volume_pfs_iops', 'volume_type_pfs_iops',
               'user_data_directory_space_quota_mb')
$$;

-- payload: 'minute' rows (a minute each), 'gap' rows {gap_from, gap_to, oldest_end}; the cursor moves to the newest
-- minute in this transaction
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_azuredb_resources(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_min timestamptz;
  v_max timestamptz;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_azuredb_resources: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  IF jsonb_typeof(p_payload) <> 'array' THEN
    RETURN;
  END IF;
  SELECT min((r->>'minute')::timestamptz), max((r->>'minute')::timestamptz) INTO v_min, v_max
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'minute';
  IF v_min IS NOT NULL THEN
    PERFORM pgvigil.ensure_month_partition('mssql_azuredb_minute', v_min);
    PERFORM pgvigil.ensure_month_partition('mssql_azuredb_minute', v_max);
    INSERT INTO pgvigil.mssql_azuredb_minute (instance_id, snapshot_at, samples, avg_cpu_percent, max_cpu_percent,
           avg_data_io_percent, max_data_io_percent, avg_log_write_percent, max_log_write_percent, avg_memory_usage_percent,
           max_memory_usage_percent, avg_xtp_storage_percent, max_worker_percent, max_session_percent, avg_instance_cpu_percent,
           avg_instance_memory_percent, dtu_limit, cpu_limit, replica_role, avg_dtu_percent, max_dtu_percent, avg_dtu, max_dtu,
           dtu_buckets, cpu_buckets, data_buckets, log_buckets)
    SELECT p_instance_id, (r->>'minute')::timestamptz, (r->>'samples')::int,
           (r->>'avg_cpu_percent')::numeric, (r->>'max_cpu_percent')::numeric,
           (r->>'avg_data_io_percent')::numeric, (r->>'max_data_io_percent')::numeric,
           (r->>'avg_log_write_percent')::numeric, (r->>'max_log_write_percent')::numeric,
           (r->>'avg_memory_usage_percent')::numeric, (r->>'max_memory_usage_percent')::numeric,
           (r->>'avg_xtp_storage_percent')::numeric, (r->>'max_worker_percent')::numeric, (r->>'max_session_percent')::numeric,
           (r->>'avg_instance_cpu_percent')::numeric, (r->>'avg_instance_memory_percent')::numeric,
           round((r->>'dtu_limit')::numeric)::int, (r->>'cpu_limit')::numeric, round((r->>'replica_role')::numeric)::int,
           (r->>'avg_dtu_percent')::numeric, (r->>'max_dtu_percent')::numeric, (r->>'avg_dtu')::numeric, (r->>'max_dtu')::numeric,
           ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(r->'dtu_buckets') x),
           ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(r->'cpu_buckets') x),
           ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(r->'data_buckets') x),
           ARRAY(SELECT x::smallint FROM jsonb_array_elements_text(r->'log_buckets') x)
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'minute'
    ON CONFLICT (instance_id, snapshot_at) DO NOTHING;
  END IF;
  INSERT INTO pgvigil.mssql_azuredb_gap (instance_id, gap_from, gap_to, oldest_end, noted_at)
  SELECT p_instance_id, (r->>'gap_from')::timestamptz, (r->>'gap_to')::timestamptz, (r->>'oldest_end')::timestamptz, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'gap'
  ON CONFLICT (instance_id, gap_from) DO NOTHING;
  INSERT INTO pgvigil.mssql_azuredb_read (instance_id, newest_minute, read_at) VALUES (p_instance_id, v_max, p_snapshot_at)
  ON CONFLICT (instance_id) DO UPDATE
    SET newest_minute = GREATEST(pgvigil.mssql_azuredb_read.newest_minute, EXCLUDED.newest_minute), read_at = EXCLUDED.read_at;
END $$;

-- payload: one 'governance' row {gov, edition, service_objective, max_size_bytes, pool, pool_from, pool_note}, or a
-- collector_error row (the view gave no row): then nothing changes
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_azuredb_governance(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  r        jsonb;
  v_old    pgvigil.mssql_azuredb_governance;
  v_gov    jsonb;
  v_hist   jsonb;
  v_since  timestamptz;
  v_props  jsonb;
  p        jsonb;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_azuredb_governance: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  SELECT x INTO r FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_payload) = 'array' THEN p_payload ELSE '[]'::jsonb END) x
   WHERE x->>'kind' = 'governance' LIMIT 1;
  IF r IS NULL THEN
    RETURN;
  END IF;
  v_gov := r->'gov';
  v_hist := v_gov - 'user_data_directory_space_usage_mb';
  SELECT * INTO v_old FROM pgvigil.mssql_azuredb_governance WHERE instance_id = p_instance_id;
  v_since := v_old.since;
  IF v_old.instance_id IS NULL
     OR pgvigil.mssql_azuredb_gov_compared(v_gov) IS DISTINCT FROM pgvigil.mssql_azuredb_gov_compared(v_old.gov)
     OR (r->>'edition', r->>'service_objective', r->>'pool') IS DISTINCT FROM (v_old.edition, v_old.service_objective, v_old.pool) THEN
    UPDATE pgvigil.mssql_azuredb_governance_history SET valid_to = p_snapshot_at
     WHERE instance_id = p_instance_id AND valid_to = 'infinity';
    INSERT INTO pgvigil.mssql_azuredb_governance_history (instance_id, valid_from, edition, service_objective, pool, slo_name, dtu_limit, cpu_limit, gov)
    VALUES (p_instance_id, p_snapshot_at, r->>'edition', r->>'service_objective', r->>'pool', v_gov->>'slo_name',
            round((v_gov->>'dtu_limit')::numeric)::int, (v_gov->>'cpu_limit')::numeric, v_hist)
    ON CONFLICT (instance_id, valid_from) DO NOTHING;
    v_since := p_snapshot_at;
  END IF;
  INSERT INTO pgvigil.mssql_azuredb_governance (instance_id, snapshot_at, since, edition, service_objective, pool, pool_from, pool_note,
         max_size_bytes, slo_name, dtu_limit, cpu_limit, usage_mb, gov)
  VALUES (p_instance_id, p_snapshot_at, v_since, r->>'edition', r->>'service_objective', r->>'pool', r->>'pool_from', r->>'pool_note',
          round((r->>'max_size_bytes')::numeric)::bigint, v_gov->>'slo_name', round((v_gov->>'dtu_limit')::numeric)::int,
          (v_gov->>'cpu_limit')::numeric, round((v_gov->>'user_data_directory_space_usage_mb')::numeric)::bigint, v_gov)
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, since = EXCLUDED.since, edition = EXCLUDED.edition,
    service_objective = EXCLUDED.service_objective, pool = EXCLUDED.pool, pool_from = EXCLUDED.pool_from, pool_note = EXCLUDED.pool_note,
    max_size_bytes = EXCLUDED.max_size_bytes, slo_name = EXCLUDED.slo_name, dtu_limit = EXCLUDED.dtu_limit, cpu_limit = EXCLUDED.cpu_limit,
    usage_mb = EXCLUDED.usage_mb, gov = EXCLUDED.gov;

  -- the Properties rows: {name, label, value, ord, tracked}; a NULL value shows the note
  v_props := jsonb_build_array(
    jsonb_build_object('name', 'azure_edition', 'label', 'Edition', 'value', r->>'edition', 'ord', 900, 'tracked', false),
    jsonb_build_object('name', 'azure_service_objective', 'label', 'Service objective', 'value', r->>'service_objective', 'ord', 901, 'tracked', true),
    jsonb_build_object('name', 'azure_slo_name', 'label', 'Service level objective (with hardware)', 'value', v_gov->>'slo_name', 'ord', 902, 'tracked', false),
    jsonb_build_object('name', 'azure_elastic_pool', 'label', 'Elastic pool', 'value',
      CASE WHEN r->>'service_objective' = 'ElasticPool' THEN r->>'pool' ELSE 'none' END, 'note', r->>'pool_note', 'ord', 903, 'tracked', true),
    jsonb_build_object('name', 'azure_dtu_limit', 'label', 'DTU limit', 'value', coalesce(v_gov->>'dtu_limit', 'none (vCore)'), 'ord', 904, 'tracked', true),
    jsonb_build_object('name', 'azure_cpu_limit', 'label', 'vCore limit', 'value', coalesce(v_gov->>'cpu_limit', 'none (DTU)'), 'ord', 905, 'tracked', true),
    jsonb_build_object('name', 'azure_max_size_mb', 'label', 'Max size (MB)', 'value', (round((r->>'max_size_bytes')::numeric / 1048576))::text, 'ord', 906, 'tracked', false),
    jsonb_build_object('name', 'azure_max_sessions', 'label', 'Max sessions', 'value', v_gov->>'max_sessions', 'ord', 907, 'tracked', false),
    jsonb_build_object('name', 'azure_max_workers', 'label', 'Max worker threads', 'value', v_gov->>'primary_group_max_workers', 'ord', 908, 'tracked', false),
    jsonb_build_object('name', 'azure_max_log_rate', 'label', 'Max log rate (MB/s)', 'value',
      to_char((v_gov->>'primary_max_log_rate')::numeric / 1048576, 'FM999999990.00'), 'ord', 909, 'tracked', false),
    jsonb_build_object('name', 'azure_max_dop', 'label', 'MAXDOP (user workload group)', 'value', v_gov->>'max_dop', 'ord', 910, 'tracked', false));
  FOR p IN SELECT * FROM jsonb_array_elements(v_props) LOOP
    IF (p->>'tracked')::boolean AND EXISTS (SELECT 1 FROM pgvigil.mssql_property mp WHERE mp.instance_id = p_instance_id AND mp.name = p->>'name'
                                              AND mp.value IS DISTINCT FROM p->>'value') THEN
      INSERT INTO pgvigil.mssql_property_change (instance_id, name, label, old_value, new_value, changed_at)
      SELECT p_instance_id, p->>'name', p->>'label', mp.value, p->>'value', p_snapshot_at
        FROM pgvigil.mssql_property mp WHERE mp.instance_id = p_instance_id AND mp.name = p->>'name';
    END IF;
    INSERT INTO pgvigil.mssql_property (instance_id, name, grp, label, value, note, ord, snapshot_at, since, seen_at)
    VALUES (p_instance_id, p->>'name', 'Azure SQL Database', p->>'label', p->>'value',
            CASE WHEN p->>'value' IS NULL THEN coalesce(p->>'note', 'not in the view''s row') ELSE p->>'note' END,
            (p->>'ord')::int, p_snapshot_at, p_snapshot_at, p_snapshot_at)
    ON CONFLICT (instance_id, name) DO UPDATE SET grp = EXCLUDED.grp, label = EXCLUDED.label, note = EXCLUDED.note, ord = EXCLUDED.ord,
      since = CASE WHEN pgvigil.mssql_property.value IS DISTINCT FROM EXCLUDED.value THEN EXCLUDED.since ELSE pgvigil.mssql_property.since END,
      value = EXCLUDED.value, snapshot_at = EXCLUDED.snapshot_at, seen_at = EXCLUDED.seen_at;
  END LOOP;
END $$;

-- mssql_hadr_cursor (0083's, its sources unchanged) gains 'azdb_since': the newest stored minute's start of
-- mssql_azuredb_minute, as epoch seconds (the next read asks for the rows ending after that minute's end)
CREATE OR REPLACE FUNCTION pgvigil.mssql_hadr_cursor(p_instance_id int, p_source text)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN p_source IN ('jobs', 'jobs_mark') THEN
      (SELECT CASE p_source WHEN 'jobs' THEN c.last_history_id ELSE c.mark END
         FROM pgvigil.mssql_jobs_cursor c WHERE c.instance_id = p_instance_id)
    WHEN left(p_source, 9) = 'qs_since:' THEN
      (SELECT floor(extract(epoch FROM s.newest_interval))::bigint
         FROM pgvigil.mssql_qs_store s
        WHERE s.instance_id = p_instance_id AND s.database_name = substr(p_source, 10))
    WHEN p_source ~ '^qs_plan:[0-9]{1,18}:' THEN
      (SELECT p.plan_hash_n
         FROM pgvigil.mssql_qs_plan p
        WHERE p.instance_id = p_instance_id AND p.plan_id = split_part(p_source, ':', 2)::bigint
          AND p.database_name = substr(p_source, length(split_part(p_source, ':', 2)) + 10)
          AND (p.xml_state = 'stored' OR (p.xml_state = 'policy' AND p.xml_checked_at > now() - interval '24 hours')))
    WHEN p_source = 'azdb_since' THEN
      (SELECT floor(extract(epoch FROM a.newest_minute))::bigint
         FROM pgvigil.mssql_azuredb_read a WHERE a.instance_id = p_instance_id)
  END
$$;
