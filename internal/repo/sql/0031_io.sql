-- 0031_io: storage IO (phase 2a, task 43).
--   1. the io collection: CloudWatch AWS/RDS volume metrics of an RDS instance or an Aurora cluster, one row per
--      metric and datapoint (cloud_io_sample; a datapoint read again replaces its value: CloudWatch revises the
--      newest period as late samples arrive), and cloud_io_latest, the newest datapoint per metric.
--   2. DMS: the replication instance's storage IO and network metrics on dms_instances, one sample per run
--      (dms_ri_sample) for the DMS page's IO panel, and import_dms as in 0016 plus those columns.
--   3. io_findings: the IO findings in the findings view's columns (the join puts them under pgvigil.findings).
-- Retention: cloud_io_sample and dms_ri_sample are monthly partitions; their names join pgvigil.purge's list in
-- the wave's join migration (one re-creation of purge for every slice's tables).

-- ---------------------------------------------------------------------------------------------------------
-- 1. platform IO (CloudWatch)
-- ---------------------------------------------------------------------------------------------------------

-- snapshot_at is the DATAPOINT's time (the start of its CloudWatch period), the column the monthly partitions and
-- the charts key on; read_at is the import that last wrote the row.
CREATE TABLE IF NOT EXISTS pgvigil.cloud_io_sample (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  metric        text NOT NULL,                 -- the CloudWatch metric name (ReadIOPS, EBSIOBalance%, VolumeReadIOPs, ...)
  value         double precision,
  stat          text,                          -- the statistic over the period: Average, Minimum, Maximum
  unit          text,                          -- count/s, s, bytes/s, count, percent, count/5min, bytes
  source        text,                          -- rds or aurora
  dim           text,                          -- the DB instance or cluster identifier read
  read_at       timestamptz NOT NULL
) PARTITION BY RANGE (snapshot_at);
CREATE UNIQUE INDEX IF NOT EXISTS cloud_io_sample_key ON pgvigil.cloud_io_sample (instance_id, metric, snapshot_at);

-- payload: rows {kind:'metric', source, dim, metric, stat, unit, at, value}
CREATE OR REPLACE FUNCTION pgvigil.import_io(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_month timestamptz;
BEGIN
  -- the read window can cross a month boundary: every month a datapoint falls in gets its partition
  FOR v_month IN
    SELECT DISTINCT date_trunc('month', (r->>'at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'metric' AND r->>'at' IS NOT NULL
  LOOP
    PERFORM pgvigil.ensure_month_partition('cloud_io_sample', v_month);
  END LOOP;
  INSERT INTO pgvigil.cloud_io_sample AS s (instance_id, snapshot_at, metric, value, stat, unit, source, dim, read_at)
  SELECT DISTINCT ON (r->>'metric', (r->>'at')::timestamptz)
         p_instance_id, (r->>'at')::timestamptz, r->>'metric', (r->>'value')::float8, r->>'stat', r->>'unit', r->>'source', r->>'dim', p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'metric' AND r->>'at' IS NOT NULL AND r->>'metric' IS NOT NULL
  ON CONFLICT (instance_id, metric, snapshot_at) DO UPDATE SET
    value = EXCLUDED.value, stat = EXCLUDED.stat, unit = EXCLUDED.unit, source = EXCLUDED.source, dim = EXCLUDED.dim,
    read_at = EXCLUDED.read_at;
END $$;

-- the newest datapoint of each metric per instance, over the last day (an older one is not "now")
CREATE OR REPLACE VIEW pgvigil.cloud_io_latest AS
SELECT DISTINCT ON (s.instance_id, s.metric) s.instance_id, s.metric, s.value, s.stat, s.unit, s.source, s.dim,
       s.snapshot_at AS at, s.read_at
  FROM pgvigil.cloud_io_sample s
 WHERE s.snapshot_at > now() - interval '1 day'
 ORDER BY s.instance_id, s.metric, s.snapshot_at DESC;

-- ---------------------------------------------------------------------------------------------------------
-- 2. DMS replication instance IO
-- ---------------------------------------------------------------------------------------------------------

-- CloudWatch AWS/DMS replication instance metrics added to the collector (the newest datapoint of the minute).
-- Latency is in MILLISECONDS here (AWS/DMS), where AWS/RDS reports seconds.
ALTER TABLE pgvigil.dms_instances
  ADD COLUMN IF NOT EXISTS read_iops        double precision,   -- ReadIOPS, count/s
  ADD COLUMN IF NOT EXISTS write_iops       double precision,   -- WriteIOPS
  ADD COLUMN IF NOT EXISTS read_latency_ms  double precision,   -- ReadLatency, ms per read
  ADD COLUMN IF NOT EXISTS write_latency_ms double precision,   -- WriteLatency
  ADD COLUMN IF NOT EXISTS read_bytes_s     double precision,   -- ReadThroughput
  ADD COLUMN IF NOT EXISTS write_bytes_s    double precision,   -- WriteThroughput
  ADD COLUMN IF NOT EXISTS queue_depth      double precision,   -- DiskQueueDepth, Maximum over the minute
  ADD COLUMN IF NOT EXISTS net_tx_bytes_s   double precision,   -- NetworkTransmitThroughput
  ADD COLUMN IF NOT EXISTS net_rx_bytes_s   double precision,   -- NetworkReceiveThroughput
  ADD COLUMN IF NOT EXISTS metrics_at       timestamptz;        -- the newest host datapoint these come from

-- one row per replication instance per run: the IO panel's trend (did the IO scale with the load)
CREATE TABLE IF NOT EXISTS pgvigil.dms_ri_sample (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at         timestamptz NOT NULL,
  ri_arn              text NOT NULL,
  ri_id               text,
  metrics_at          timestamptz,
  cpu_pct             double precision,
  freeable_bytes      bigint,
  free_storage_bytes  bigint,
  allocated_gb        int,
  read_iops           double precision,
  write_iops          double precision,
  read_latency_ms     double precision,
  write_latency_ms    double precision,
  read_bytes_s        double precision,
  write_bytes_s       double precision,
  queue_depth         double precision,
  net_tx_bytes_s      double precision,
  net_rx_bytes_s      double precision
) PARTITION BY RANGE (snapshot_at);

-- import_dms as in 0016, plus the ten IO columns on the replication instance and its per-run IO sample
CREATE OR REPLACE FUNCTION pgvigil.import_dms(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_dms'), p_instance_id);

  INSERT INTO pgvigil.dms_instances AS d (instance_id, ri_arn, ri_id, snapshot_at, status, class, engine_version, allocated_gb,
                                          multi_az, public, az, created, free_until, pending, cpu_pct, freeable_bytes,
                                          free_storage_bytes, swap_bytes, read_iops, write_iops, read_latency_ms, write_latency_ms,
                                          read_bytes_s, write_bytes_s, queue_depth, net_tx_bytes_s, net_rx_bytes_s, metrics_at,
                                          first_seen, is_present)
  SELECT p_instance_id, r->>'ri_arn', r->>'ri_id', p_snapshot_at, r->>'status', r->>'class', r->>'engine_version',
         (r->>'allocated_gb')::int, (r->>'multi_az')::boolean, (r->>'public')::boolean, r->>'az',
         (r->>'created')::timestamptz, (r->>'free_until')::timestamptz, NULLIF(r->'pending', 'null'::jsonb),
         (r->>'cpu_pct')::float8, (r->>'freeable_bytes')::float8::bigint, (r->>'free_storage_bytes')::float8::bigint,
         (r->>'swap_bytes')::float8::bigint, (r->>'read_iops')::float8, (r->>'write_iops')::float8,
         (r->>'read_latency_ms')::float8, (r->>'write_latency_ms')::float8, (r->>'read_bytes_s')::float8,
         (r->>'write_bytes_s')::float8, (r->>'queue_depth')::float8, (r->>'net_tx_bytes_s')::float8,
         (r->>'net_rx_bytes_s')::float8, (r->>'metrics_at')::timestamptz, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'ri'
  ON CONFLICT (instance_id, ri_arn) DO UPDATE SET
    ri_id = EXCLUDED.ri_id, snapshot_at = EXCLUDED.snapshot_at, status = EXCLUDED.status, class = EXCLUDED.class,
    engine_version = EXCLUDED.engine_version, allocated_gb = EXCLUDED.allocated_gb, multi_az = EXCLUDED.multi_az,
    public = EXCLUDED.public, az = EXCLUDED.az, created = EXCLUDED.created, free_until = EXCLUDED.free_until,
    pending = EXCLUDED.pending, cpu_pct = EXCLUDED.cpu_pct, freeable_bytes = EXCLUDED.freeable_bytes,
    free_storage_bytes = EXCLUDED.free_storage_bytes, swap_bytes = EXCLUDED.swap_bytes, read_iops = EXCLUDED.read_iops,
    write_iops = EXCLUDED.write_iops, read_latency_ms = EXCLUDED.read_latency_ms, write_latency_ms = EXCLUDED.write_latency_ms,
    read_bytes_s = EXCLUDED.read_bytes_s, write_bytes_s = EXCLUDED.write_bytes_s, queue_depth = EXCLUDED.queue_depth,
    net_tx_bytes_s = EXCLUDED.net_tx_bytes_s, net_rx_bytes_s = EXCLUDED.net_rx_bytes_s, metrics_at = EXCLUDED.metrics_at,
    is_present = true;

  -- one IO sample per replication instance per run that read its metrics (the IO panel's trend)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'ri' AND r->>'metrics_at' IS NOT NULL) THEN
    PERFORM pgvigil.ensure_month_partition('dms_ri_sample', p_snapshot_at);
    INSERT INTO pgvigil.dms_ri_sample (instance_id, snapshot_at, ri_arn, ri_id, metrics_at, cpu_pct, freeable_bytes, free_storage_bytes,
                                       allocated_gb, read_iops, write_iops, read_latency_ms, write_latency_ms, read_bytes_s,
                                       write_bytes_s, queue_depth, net_tx_bytes_s, net_rx_bytes_s)
    SELECT p_instance_id, p_snapshot_at, r->>'ri_arn', r->>'ri_id', (r->>'metrics_at')::timestamptz, (r->>'cpu_pct')::float8,
           (r->>'freeable_bytes')::float8::bigint, (r->>'free_storage_bytes')::float8::bigint, (r->>'allocated_gb')::int,
           (r->>'read_iops')::float8, (r->>'write_iops')::float8, (r->>'read_latency_ms')::float8, (r->>'write_latency_ms')::float8,
           (r->>'read_bytes_s')::float8, (r->>'write_bytes_s')::float8, (r->>'queue_depth')::float8, (r->>'net_tx_bytes_s')::float8,
           (r->>'net_rx_bytes_s')::float8
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'ri' AND r->>'metrics_at' IS NOT NULL;
  END IF;

  UPDATE pgvigil.dms_instances d SET is_present = false
   WHERE d.instance_id = p_instance_id AND d.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'ri' AND r->>'ri_arn' = d.ri_arn);

  INSERT INTO pgvigil.dms_tasks AS t (instance_id, task_arn, task_id, snapshot_at, ri_arn, migration_type, status, stop_reason,
                                      last_failure, progress_pct, tables_loaded, tables_loading, tables_queued, tables_errored,
                                      elapsed_ms, created, started, fresh_start, start_date, stop_date, full_load_start,
                                      full_load_finish, cdc_start_position, recovery_checkpoint, source_endpoint_arn,
                                      target_endpoint_arn, latency_source_s, latency_target_s, incoming_changes, latency_at,
                                      latency_warn_secs, tables_partial, rows_in_s, rows_out_s, disk_source, disk_target,
                                      memory_source, memory_target, first_seen, is_present)
  SELECT p_instance_id, r->>'task_arn', r->>'task_id', p_snapshot_at, r->>'ri_arn', r->>'migration_type', r->>'status',
         r->>'stop_reason', r->>'last_failure', (r->>'progress_pct')::int, (r->>'tables_loaded')::int,
         (r->>'tables_loading')::int, (r->>'tables_queued')::int, (r->>'tables_errored')::int, (r->>'elapsed_ms')::bigint,
         (r->>'created')::timestamptz, (r->>'started')::timestamptz, (r->>'fresh_start')::timestamptz,
         (r->>'start_date')::timestamptz, (r->>'stop_date')::timestamptz, (r->>'full_load_start')::timestamptz,
         (r->>'full_load_finish')::timestamptz, r->>'cdc_start_position', r->>'recovery_checkpoint',
         r->>'source_endpoint_arn', r->>'target_endpoint_arn', (r->>'latency_source_s')::float8,
         (r->>'latency_target_s')::float8, (r->>'incoming_changes')::float8, (r->>'latency_at')::timestamptz,
         coalesce((r->>'latency_warn_secs')::int, 300), coalesce((r->>'tables_partial')::boolean, false),
         (r->>'rows_in_s')::float8, (r->>'rows_out_s')::float8, (r->>'disk_source')::float8, (r->>'disk_target')::float8,
         (r->>'memory_source')::float8, (r->>'memory_target')::float8, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'task'
  ON CONFLICT (instance_id, task_arn) DO UPDATE SET
    task_id = EXCLUDED.task_id, snapshot_at = EXCLUDED.snapshot_at, ri_arn = EXCLUDED.ri_arn,
    migration_type = EXCLUDED.migration_type, status = EXCLUDED.status, stop_reason = EXCLUDED.stop_reason,
    last_failure = EXCLUDED.last_failure, progress_pct = EXCLUDED.progress_pct, tables_loaded = EXCLUDED.tables_loaded,
    tables_loading = EXCLUDED.tables_loading, tables_queued = EXCLUDED.tables_queued, tables_errored = EXCLUDED.tables_errored,
    elapsed_ms = EXCLUDED.elapsed_ms, created = EXCLUDED.created, started = EXCLUDED.started,
    fresh_start = EXCLUDED.fresh_start, start_date = EXCLUDED.start_date, stop_date = EXCLUDED.stop_date,
    full_load_start = EXCLUDED.full_load_start, full_load_finish = EXCLUDED.full_load_finish,
    cdc_start_position = EXCLUDED.cdc_start_position, recovery_checkpoint = EXCLUDED.recovery_checkpoint,
    source_endpoint_arn = EXCLUDED.source_endpoint_arn, target_endpoint_arn = EXCLUDED.target_endpoint_arn,
    latency_source_s = EXCLUDED.latency_source_s, latency_target_s = EXCLUDED.latency_target_s,
    incoming_changes = EXCLUDED.incoming_changes, latency_at = EXCLUDED.latency_at,
    latency_warn_secs = EXCLUDED.latency_warn_secs, tables_partial = EXCLUDED.tables_partial,
    rows_in_s = EXCLUDED.rows_in_s, rows_out_s = EXCLUDED.rows_out_s, disk_source = EXCLUDED.disk_source,
    disk_target = EXCLUDED.disk_target, memory_source = EXCLUDED.memory_source, memory_target = EXCLUDED.memory_target,
    is_present = true;

  UPDATE pgvigil.dms_tasks t SET is_present = false
   WHERE t.instance_id = p_instance_id AND t.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'task' AND r->>'task_arn' = t.task_arn);

  -- one sample per task per run: the trend the latency, progress and drain charts read
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'task') THEN
    PERFORM pgvigil.ensure_month_partition('dms_task_sample', p_snapshot_at);
    INSERT INTO pgvigil.dms_task_sample (instance_id, snapshot_at, task_arn, status, progress_pct, tables_errored,
                                         latency_source_s, latency_target_s, incoming_changes, latency_at, rows_in_s, rows_out_s,
                                         disk_source, disk_target)
    SELECT p_instance_id, p_snapshot_at, r->>'task_arn', r->>'status', (r->>'progress_pct')::int, (r->>'tables_errored')::int,
           (r->>'latency_source_s')::float8, (r->>'latency_target_s')::float8, (r->>'incoming_changes')::float8,
           (r->>'latency_at')::timestamptz, (r->>'rows_in_s')::float8, (r->>'rows_out_s')::float8, (r->>'disk_source')::float8, (r->>'disk_target')::float8
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'task';
  END IF;

  INSERT INTO pgvigil.dms_table_stats AS s (instance_id, task_arn, schema_name, table_name, snapshot_at, table_state, inserts, updates,
                                            deletes, ddls, applied_inserts, applied_updates, applied_deletes, applied_ddls,
                                            full_load_rows, full_load_error_rows, full_load_cond_failed_rows, full_load_reloaded,
                                            full_load_start, full_load_end, last_update, validation_state, validation_pending,
                                            validation_failed, validation_suspended, validation_detail, is_present)
  SELECT p_instance_id, r->>'task_arn', r->>'schema_name', r->>'table_name', p_snapshot_at, r->>'table_state',
         (r->>'inserts')::bigint, (r->>'updates')::bigint, (r->>'deletes')::bigint, (r->>'ddls')::bigint,
         (r->>'applied_inserts')::bigint, (r->>'applied_updates')::bigint, (r->>'applied_deletes')::bigint, (r->>'applied_ddls')::bigint,
         (r->>'full_load_rows')::bigint, (r->>'full_load_error_rows')::bigint, (r->>'full_load_cond_failed_rows')::bigint,
         (r->>'full_load_reloaded')::boolean, (r->>'full_load_start')::timestamptz, (r->>'full_load_end')::timestamptz,
         (r->>'last_update')::timestamptz, r->>'validation_state', (r->>'validation_pending')::bigint,
         (r->>'validation_failed')::bigint, (r->>'validation_suspended')::bigint, r->>'validation_detail', true
    FROM (SELECT DISTINCT ON (r->>'task_arn', r->>'schema_name', r->>'table_name') r
            FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'table') x
  ON CONFLICT (instance_id, task_arn, schema_name, table_name) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, table_state = EXCLUDED.table_state, inserts = EXCLUDED.inserts, updates = EXCLUDED.updates,
    deletes = EXCLUDED.deletes, ddls = EXCLUDED.ddls, applied_inserts = EXCLUDED.applied_inserts,
    applied_updates = EXCLUDED.applied_updates, applied_deletes = EXCLUDED.applied_deletes, applied_ddls = EXCLUDED.applied_ddls,
    full_load_rows = EXCLUDED.full_load_rows, full_load_error_rows = EXCLUDED.full_load_error_rows,
    full_load_cond_failed_rows = EXCLUDED.full_load_cond_failed_rows, full_load_reloaded = EXCLUDED.full_load_reloaded,
    full_load_start = EXCLUDED.full_load_start, full_load_end = EXCLUDED.full_load_end, last_update = EXCLUDED.last_update,
    validation_state = EXCLUDED.validation_state, validation_pending = EXCLUDED.validation_pending,
    validation_failed = EXCLUDED.validation_failed, validation_suspended = EXCLUDED.validation_suspended,
    validation_detail = EXCLUDED.validation_detail, is_present = true;

  UPDATE pgvigil.dms_table_stats s SET is_present = false
   WHERE s.instance_id = p_instance_id AND s.is_present
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                  WHERE r->>'kind' = 'task' AND r->>'task_arn' = s.task_arn AND NOT coalesce((r->>'tables_partial')::boolean, false))
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'table' AND r->>'task_arn' = s.task_arn
                        AND r->>'schema_name' = s.schema_name AND r->>'table_name' = s.table_name);
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- 3. io_findings: the findings view's columns (instance_id, severity, setting, value, is_set, suggested, platforms,
--    detail, source, at); the wave's join migration adds them to pgvigil.findings.
-- ---------------------------------------------------------------------------------------------------------

-- Thresholds (the k row): an EBS IO / byte balance or a gp2 burst balance under 20 % warns, under 5 % is critical
-- (the low point of the last hour: at 0 the volume or instance falls to its baseline IOPS or throughput).
-- Platform, as the last hour's means: a read latency over 20 ms warns only with at least 1 read a second (an idle
-- instance's few cold reads, or the first after a Serverless resume, are slow by nature); a queue depth over 10
-- warns only when the read or write latency is 5 ms or more, or unknown (a provisioned-IOPS volume runs a deep
-- queue at sub-millisecond latency by design). DMS replication instance, as the last 30 minutes' mean of at least
-- 3 samples (one minute's spike, or a first sample alone, is not a finding): queue over 10, read or write latency
-- over 20 ms. Checkpoints: at least 12 requested in 24 h and more than were timed, with at least 1 GB of WAL written
-- or the WAL volume unknown (PG13): an idle server skips its timed checkpoints, and a backup, a manual CHECKPOINT
-- or a restart counts as requested; not on Aurora (its storage has no checkpoint to tune). track_io_timing off is
-- pgvigil.findings' own rule (0016), not repeated here.
CREATE OR REPLACE VIEW pgvigil.io_findings AS
WITH k AS (SELECT 20.0::float8 AS balance_warn, 5.0::float8 AS balance_crit, 10.0::float8 AS queue_max,
                  20.0::float8 AS latency_ms_max, 1.0::float8 AS read_iops_min, 5.0::float8 AS queue_latency_ms_min,
                  3 AS dms_samples_min, 12 AS checkpoints_min, 1073741824::numeric AS checkpoint_wal_min),
h AS (
  SELECT s.instance_id, s.metric, avg(s.value) AS mean, min(s.value) AS low, max(s.snapshot_at) AS at
    FROM pgvigil.cloud_io_sample s JOIN pgvigil.instances i USING (instance_id)
   WHERE i.is_active AND s.snapshot_at > now() - interval '1 hour'
   GROUP BY s.instance_id, s.metric
),
d AS (
  SELECT r.instance_id, r.ri_arn, max(r.ri_id) AS ri_id, avg(r.queue_depth) AS queue_depth,
         avg(r.read_latency_ms) AS read_latency_ms, avg(r.write_latency_ms) AS write_latency_ms, max(r.snapshot_at) AS at
    FROM pgvigil.dms_ri_sample r
    JOIN pgvigil.dms_instances di ON di.instance_id = r.instance_id AND di.ri_arn = r.ri_arn AND di.is_present
   WHERE r.snapshot_at > now() - interval '30 minutes'
   GROUP BY r.instance_id, r.ri_arn
  HAVING count(*) >= (SELECT dms_samples_min FROM k)
),
ck AS (
  SELECT i.instance_id, sum(c.checkpoints_timed) AS timed, sum(c.checkpoints_req) AS req, sum(c.wal_bytes) AS wal,
         max(c.snapshot_at) AS at
    FROM pgvigil.instances i
    CROSS JOIN LATERAL pgvigil.serverstats_rate(i.instance_id, now() - interval '1 day', now()) c
   WHERE i.is_active AND i.platform <> 'aurora'
   GROUP BY i.instance_id
)
SELECT h.instance_id, CASE WHEN h.low < k.balance_crit THEN 'critical' ELSE 'warning' END AS severity, h.metric AS setting,
       round(h.low::numeric, 1)::text || ' %' AS value, true AS is_set, 'above ' || k.balance_warn::text || ' %' AS suggested,
       'rds' AS platforms,
       CASE h.metric
         WHEN 'EBSIOBalance%'   THEN 'the instance''s EBS IO burst bucket is draining: at 0 its IOPS fall to the instance class baseline'
         WHEN 'EBSByteBalance%' THEN 'the instance''s EBS throughput burst bucket is draining: at 0 its throughput falls to the instance class baseline'
         ELSE 'the gp2 volume''s IO credits are draining: at 0 its IOPS fall to the volume baseline (3 per GB)' END AS detail,
       'pgvigil io' AS source, h.at
  FROM h, k
 WHERE h.metric IN ('EBSIOBalance%', 'EBSByteBalance%', 'BurstBalance') AND h.low < k.balance_warn
UNION ALL
SELECT h.instance_id, 'warning', 'DiskQueueDepth', round(h.mean::numeric, 1)::text, true, 'under ' || k.queue_max::text, 'rds, aurora',
       'IOs waiting on the storage with slow IOs, the last hour''s mean: the volume is not keeping up (IOPS or throughput at the volume or instance limit)',
       'pgvigil io', h.at
  FROM h, k
 WHERE h.metric = 'DiskQueueDepth' AND h.mean > k.queue_max
   AND coalesce((SELECT max(l.mean) * 1000 FROM h l
                  WHERE l.instance_id = h.instance_id AND l.metric IN ('ReadLatency', 'WriteLatency')), k.queue_latency_ms_min)
       >= k.queue_latency_ms_min
UNION ALL
SELECT h.instance_id, 'warning', 'ReadLatency', round((h.mean * 1000)::numeric, 1)::text || ' ms', true,
       'under ' || k.latency_ms_max::text || ' ms', 'rds, aurora',
       'the storage takes over ' || k.latency_ms_max::text || ' ms per read, the last hour''s mean: queries that miss the cache wait on it',
       'pgvigil io', h.at
  FROM h, k
 WHERE h.metric = 'ReadLatency' AND h.mean * 1000 > k.latency_ms_max
   AND EXISTS (SELECT 1 FROM h r WHERE r.instance_id = h.instance_id AND r.metric = 'ReadIOPS' AND r.mean >= k.read_iops_min)
UNION ALL
SELECT d.instance_id, 'warning', 'DMS DiskQueueDepth', d.ri_id || ': ' || round(d.queue_depth::numeric, 1)::text, true,
       'under ' || k.queue_max::text, 'dms',
       'IOs waiting on the replication instance''s storage, the last 30 minutes'' mean: its volume limits the task (changes spilled to disk, sorting, logging)',
       'pgvigil io', d.at
  FROM d, k
 WHERE d.queue_depth > k.queue_max
UNION ALL
SELECT d.instance_id, 'warning', 'DMS ' || x.metric, d.ri_id || ': ' || round(x.ms::numeric, 1)::text || ' ms', true,
       'under ' || k.latency_ms_max::text || ' ms', 'dms',
       'the replication instance''s storage takes over ' || k.latency_ms_max::text || ' ms per ' || x.op || ', the last 30 minutes'' mean',
       'pgvigil io', d.at
  FROM d, k, LATERAL (VALUES ('ReadLatency', d.read_latency_ms, 'read'), ('WriteLatency', d.write_latency_ms, 'write')) x(metric, ms, op)
 WHERE x.ms > k.latency_ms_max
UNION ALL
SELECT ck.instance_id, 'warning', 'checkpoints requested', ck.req::text || ' requested, ' || ck.timed::text || ' timed (24 h)', true,
       'more timed than requested', 'not aurora',
       'more checkpoints requested than timed with WAL being written: most likely WAL volume forces them and max_wal_size is small for the write rate (more full-page writes, IO bursts); backups, manual CHECKPOINTs and restarts count as requested too',
       'pgvigil io', ck.at
  FROM ck, k
 WHERE ck.req > ck.timed AND ck.req >= k.checkpoints_min AND coalesce(ck.wal >= k.checkpoint_wal_min, true);
