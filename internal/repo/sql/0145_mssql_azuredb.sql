-- 0145: Azure SQL Database's resource use and tier (B2a; DBA Dash's AzureDBResourceStats, AzureDBResourceGovernance
-- and AzureServiceObjectivesHistory).
--
--   mssql_azuredb_minute     monthly partitions; mssql_azuredb_resources (internal/mssql/azuredb_resources.go): a
--                            database's minute of sys.dm_db_resource_stats - the averages of its 15-second rows, the
--                            per-sample maxima of CPU, data IO, log write, memory, XTP storage, instance CPU and
--                            instance memory (AzureDBResourceStats_Raw's seven), DBA Dash's DTU % per sample and
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
  max_xtp_storage_percent     numeric(5,2),
  max_worker_percent          numeric(5,2),
  max_session_percent         numeric(5,2),
  avg_instance_cpu_percent    numeric(7,4),
  max_instance_cpu_percent    numeric(5,2),
  avg_instance_memory_percent numeric(7,4),
  max_instance_memory_percent numeric(5,2),
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
           max_memory_usage_percent, avg_xtp_storage_percent, max_xtp_storage_percent, max_worker_percent, max_session_percent,
           avg_instance_cpu_percent, max_instance_cpu_percent, avg_instance_memory_percent, max_instance_memory_percent,
           dtu_limit, cpu_limit, replica_role, avg_dtu_percent, max_dtu_percent, avg_dtu, max_dtu,
           dtu_buckets, cpu_buckets, data_buckets, log_buckets)
    SELECT p_instance_id, (r->>'minute')::timestamptz, (r->>'samples')::int,
           (r->>'avg_cpu_percent')::numeric, (r->>'max_cpu_percent')::numeric,
           (r->>'avg_data_io_percent')::numeric, (r->>'max_data_io_percent')::numeric,
           (r->>'avg_log_write_percent')::numeric, (r->>'max_log_write_percent')::numeric,
           (r->>'avg_memory_usage_percent')::numeric, (r->>'max_memory_usage_percent')::numeric,
           (r->>'avg_xtp_storage_percent')::numeric, (r->>'max_xtp_storage_percent')::numeric,
           (r->>'max_worker_percent')::numeric, (r->>'max_session_percent')::numeric,
           (r->>'avg_instance_cpu_percent')::numeric, (r->>'max_instance_cpu_percent')::numeric,
           (r->>'avg_instance_memory_percent')::numeric, (r->>'max_instance_memory_percent')::numeric,
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

-- mssql_storage_findings: 0111's view with one arm more (B2a: an Azure SQL Database's allocated share of its max
-- size, DBA Dash's '% Max Size'; its check name holds 'max size', so the Summary's '% Max Size' cell takes it), and
-- 0111's per-file 'max size' arm leaves Azure SQL Database out (DBA Dash's status there is the database's, not a file's)
CREATE OR REPLACE VIEW pgvigil.mssql_storage_findings AS
SELECT d.instance_id, d.status AS severity,
       'a volume under 10 % free'::text AS check_name, d.drive AS object, d.snapshot_at AS at,
       format('%s free of %s (%s %%); %s database file(s) sit on it; warning under %s %%, critical under %s %% (%s)',
              pg_size_pretty(d.free_bytes), pg_size_pretty(d.total_bytes), d.free_pct, d.files, d.warn_pct, d.crit_pct,
              CASE d.threshold_level WHEN 'default' THEN 'the default' WHEN 'tag' THEN 'set on the tag ' || d.threshold_tag ELSE 'set on the ' || d.threshold_level END) AS detail
  FROM pgvigil.drives_now d
 WHERE d.engine = 'sqlserver' AND d.status IN ('warning', 'critical') AND d.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT f.instance_id, CASE WHEN f.size_bytes >= f.max_size_bytes THEN 'critical' ELSE 'warning' END,
       CASE WHEN f.size_bytes >= f.max_size_bytes THEN 'a file at its max size' ELSE 'a file within one growth of its max size' END,
       f.database_name || ': ' || coalesce(f.file_name, f.file_id::text), f.snapshot_at,
       format('%s (%s) is %s of a maximum of %s; its growth step is %s%s', coalesce(f.physical_name, f.file_name), lower(coalesce(f.type_desc, 'file')),
              pg_size_pretty(f.size_bytes), pg_size_pretty(f.max_size_bytes),
              CASE WHEN f.growth_pct > 0 THEN f.growth_pct || ' %' ELSE pg_size_pretty(f.growth_bytes) END,
              CASE WHEN f.used_read THEN format('; %s used inside it', pg_size_pretty(f.used_bytes)) ELSE '; the space used inside it was not read' END)
  FROM pgvigil.mssql_files f
 WHERE f.is_present AND f.max_size_bytes IS NOT NULL AND f.size_bytes IS NOT NULL
   AND (coalesce(f.growth_bytes, 0) > 0 OR coalesce(f.growth_pct, 0) > 0)       -- a file set not to grow has no maximum to reach
   AND NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = f.instance_id AND i.platform = 'azuresqldb')  -- B2a: the arm below
   AND f.size_bytes + CASE WHEN f.growth_pct > 0 THEN f.size_bytes * f.growth_pct / 100 ELSE f.growth_bytes END >= f.max_size_bytes
   AND f.snapshot_at > now() - interval '3 hours'
UNION ALL
-- B2a: on Azure SQL Database, DBA Dash's '% Max Size' (AzureDBInfo L19, L27-31): the PRIMARY filegroup's data files'
-- allocated size against their summed max size, no status when a file is unlimited; over 0.9 critical, over 0.8
-- warning (a strict 'over'; DBA Dash's root DBFileThresholds, PctMaxSize 0.8 / 0.9); the used share beside it
SELECT a.instance_id, CASE WHEN a.pct > 90 THEN 'critical' ELSE 'warning' END,
       'the database allocated over 80 % of its max size', a.database_name, a.at,
       format('the data files hold %s allocated of a max size of %s (%s %%), %s used inside them (%s %%); warning over 80 %%, critical over 90 %% (DBA Dash''s %% Max Size)',
              pg_size_pretty(a.alloc), pg_size_pretty(a.maxsize), round(a.pct, 1),
              CASE WHEN a.used IS NULL THEN 'the space' ELSE pg_size_pretty(a.used) END,
              CASE WHEN a.used IS NULL THEN 'not read' ELSE round(100.0 * a.used / a.maxsize, 1)::text END)
  FROM (SELECT f.instance_id, f.database_name, max(f.snapshot_at) AS at, sum(f.size_bytes) AS alloc, sum(f.max_size_bytes) AS maxsize,
               CASE WHEN bool_and(f.used_read) THEN sum(f.used_bytes) END AS used,
               100.0 * sum(f.size_bytes) / nullif(sum(f.max_size_bytes), 0) AS pct
          FROM pgvigil.mssql_files f JOIN pgvigil.instances i ON i.instance_id = f.instance_id AND i.platform = 'azuresqldb'
         WHERE f.is_present AND f.type_desc = 'ROWS' AND f.filegroup = 'PRIMARY' AND f.snapshot_at > now() - interval '3 hours'
         GROUP BY f.instance_id, f.database_name
        HAVING bool_and(f.max_size_bytes IS NOT NULL)) a
 WHERE a.pct > 80
UNION ALL
SELECT f.instance_id, 'info', 'a percentage growth on a file over 10 GB', f.database_name || ': ' || coalesce(f.file_name, f.file_id::text), f.snapshot_at,
       format('%s (%s) is %s and grows by %s %%: its next growth is %s in one step', coalesce(f.physical_name, f.file_name),
              lower(coalesce(f.type_desc, 'file')), pg_size_pretty(f.size_bytes), f.growth_pct, pg_size_pretty(f.size_bytes * f.growth_pct / 100))
  FROM pgvigil.mssql_files f
 WHERE f.is_present AND f.growth_pct > 0 AND f.size_bytes > 10 * 1024::bigint * 1024 * 1024
   AND f.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT d.instance_id, 'info', 'a log file larger than its data files', d.database_name, d.at,
       format('the log files hold %s, the data files %s', pg_size_pretty(d.log_bytes), pg_size_pretty(d.data_bytes))
  FROM (SELECT f.instance_id, f.database_name, max(f.snapshot_at) AS at,
               coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc = 'LOG'), 0) AS log_bytes,
               coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc = 'ROWS'), 0) AS data_bytes
          FROM pgvigil.mssql_files f
         WHERE f.is_present AND f.snapshot_at > now() - interval '3 hours'
         GROUP BY f.instance_id, f.database_name) d
 WHERE d.log_bytes > d.data_bytes AND d.log_bytes >= 1024::bigint * 1024 * 1024
UNION ALL
SELECT l.instance_id, 'warning', 'the version store grows while cleanup is at zero', 'tempdb', l.snapshot_at,
       format('the version store grew from %s to %s in the ten minutes to this read and cleanup removed nothing in %s reads; ',
              pg_size_pretty(l.first_reserved_bytes), pg_size_pretty(l.reserved_bytes), l.reads_10m)
       || CASE WHEN l.holder_session_id IS NULL THEN 'no active snapshot transaction was found at the read (holder unknown: the oldest open transaction of any kind is the next read)'
               ELSE format('held by session %s (%s, %s), its transaction open for %s s since %s; last statement: %s', l.holder_session_id,
                           coalesce(l.holder_login, 'login not read'), coalesce(l.holder_program, 'program not read'), l.holder_elapsed_s,
                           to_char(l.holder_started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS "UTC"'), coalesce(left(l.holder_statement, 2000), 'not read')) END
  FROM pgvigil.mssql_versionstore_latest l
 WHERE l.snapshot_at > now() - interval '15 minutes'
   AND l.reads_10m >= 8 AND l.cleanup_zero_10m AND l.generated_10m
   AND l.first_at <= l.snapshot_at - interval '9 minutes 30 seconds' AND l.reserved_bytes > l.first_reserved_bytes
UNION ALL
SELECT l.instance_id, 'warning', 'the version store over a third of tempdb', 'tempdb', l.snapshot_at,
       format('the version store holds %s of tempdb''s %s of data files (%s %%)', pg_size_pretty(l.reserved_bytes), pg_size_pretty(l.tempdb_data_bytes),
              round(100.0 * l.reserved_bytes / l.tempdb_data_bytes, 1))
       || CASE WHEN l.holder_session_id IS NULL THEN ''
               ELSE format('; the oldest snapshot transaction is session %s (%s, %s), open for %s s; last statement: %s', l.holder_session_id,
                           coalesce(l.holder_login, 'login not read'), coalesce(l.holder_program, 'program not read'), l.holder_elapsed_s,
                           coalesce(left(l.holder_statement, 2000), 'not read')) END
  FROM pgvigil.mssql_versionstore_latest l
 WHERE l.snapshot_at > now() - interval '15 minutes' AND l.tempdb_data_bytes > 0 AND l.reserved_bytes * 3 > l.tempdb_data_bytes
UNION ALL
SELECT p.instance_id, 'warning', 'the persistent version store over its threshold with aborted transactions', p.database_name, p.snapshot_at,
       format('the persistent version store holds %s with %s aborted transaction(s) not yet cleaned', pg_size_pretty(p.pvs_bytes), p.aborted_tx_count)
       || CASE WHEN p.oldest_tx_session_id IS NULL THEN ''
               ELSE format('; the oldest active transaction is session %s, open since %s', p.oldest_tx_session_id,
                           to_char(p.oldest_tx_started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS "UTC"')) END
  FROM pgvigil.mssql_pvs p
 WHERE p.snapshot_at > now() - interval '15 minutes' AND p.aborted_tx_count > 0
   AND p.pvs_bytes > greatest(1024::bigint * 1024 * 1024,
         coalesce((SELECT sum(f.size_bytes) / 10 FROM pgvigil.mssql_files f
                    WHERE f.instance_id = p.instance_id AND f.database_name = p.database_name AND f.is_present AND f.type_desc = 'ROWS'), 0));
