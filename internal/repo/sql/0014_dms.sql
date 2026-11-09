-- 0014_dms: AWS DMS replication tasks that feed or read a monitored instance (the instance's aws.dms block
-- names them): the current state of each task, a per-run sample for the latency and progress trend, the
-- latest table statistics per task, and the replication instances the tasks run on with their host metrics.
-- An object that left the API keeps its last row with is_present = false (the jobs pattern).

CREATE TABLE IF NOT EXISTS pgvigil.dms_instances (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  ri_arn              text NOT NULL,
  ri_id               text NOT NULL,          -- the replication instance identifier
  snapshot_at         timestamptz NOT NULL,
  status              text,
  class               text,
  engine_version      text,
  allocated_gb        int,
  multi_az            boolean,
  public              boolean,
  az                  text,
  created             timestamptz,
  free_until          timestamptz,
  pending             jsonb,                  -- pending modifications, when any
  cpu_pct             double precision,       -- CloudWatch AWS/DMS, the newest datapoint of the read window
  freeable_bytes      bigint,
  free_storage_bytes  bigint,
  swap_bytes          bigint,
  first_seen          timestamptz NOT NULL,
  is_present          boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, ri_arn)
);

CREATE TABLE IF NOT EXISTS pgvigil.dms_tasks (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  task_arn            text NOT NULL,
  task_id             text NOT NULL,          -- the user-assigned task identifier
  snapshot_at         timestamptz NOT NULL,
  ri_arn              text,
  migration_type      text,                   -- full-load, cdc, full-load-and-cdc
  status              text,                   -- lower case: ready, starting, running, stopping, stopped, failed, ...
  stop_reason         text,
  last_failure        text,
  progress_pct        int,
  tables_loaded       int,
  tables_loading      int,
  tables_queued       int,
  tables_errored      int,
  elapsed_ms          bigint,                 -- ReplicationTaskStats.ElapsedTimeMillis: the full load's duration, not the task's age
  created             timestamptz,
  started             timestamptz,            -- ReplicationTaskStartDate
  fresh_start         timestamptz,
  start_date          timestamptz,
  stop_date           timestamptz,
  full_load_start     timestamptz,
  full_load_finish    timestamptz,
  cdc_start_position  text,
  recovery_checkpoint text,
  source_endpoint_arn text,
  target_endpoint_arn text,
  latency_source_s    double precision,       -- CDCLatencySource, newest datapoint
  latency_target_s    double precision,       -- CDCLatencyTarget
  incoming_changes    double precision,       -- CDCIncomingChanges
  latency_at          timestamptz,
  latency_warn_secs   int NOT NULL DEFAULT 300,
  tables_partial      boolean NOT NULL DEFAULT false,   -- the table statistics were cut at the collector's cap this run
  first_seen          timestamptz NOT NULL,
  is_present          boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, task_arn)
);

CREATE TABLE IF NOT EXISTS pgvigil.dms_task_sample (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at         timestamptz NOT NULL,
  task_arn            text NOT NULL,
  status              text,
  progress_pct        int,
  tables_errored      int,
  latency_source_s    double precision,
  latency_target_s    double precision,
  incoming_changes    double precision
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.dms_table_stats (
  instance_id                 int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  task_arn                    text NOT NULL,
  schema_name                 text NOT NULL,
  table_name                  text NOT NULL,
  snapshot_at                 timestamptz NOT NULL,
  table_state                 text,
  inserts                     bigint,
  updates                     bigint,
  deletes                     bigint,
  ddls                        bigint,
  applied_inserts             bigint,
  applied_updates             bigint,
  applied_deletes             bigint,
  applied_ddls                bigint,
  full_load_rows              bigint,
  full_load_error_rows        bigint,
  full_load_cond_failed_rows  bigint,
  full_load_reloaded          boolean,
  full_load_start             timestamptz,
  full_load_end               timestamptz,
  last_update                 timestamptz,
  validation_state            text,
  validation_pending          bigint,
  validation_failed           bigint,
  validation_suspended        bigint,
  validation_detail           text,
  is_present                  boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, task_arn, schema_name, table_name)
);

-- payload: rows {kind:'ri', ...}, {kind:'task', ...}, {kind:'table', task_arn, schema_name, table_name, ...};
-- a {kind:'collector_error'} row (metrics unread) is ignored here and shows in the collection log.
CREATE OR REPLACE FUNCTION pgvigil.import_dms(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_dms'), p_instance_id);

  INSERT INTO pgvigil.dms_instances AS d (instance_id, ri_arn, ri_id, snapshot_at, status, class, engine_version, allocated_gb,
                                          multi_az, public, az, created, free_until, pending, cpu_pct, freeable_bytes,
                                          free_storage_bytes, swap_bytes, first_seen, is_present)
  SELECT p_instance_id, r->>'ri_arn', r->>'ri_id', p_snapshot_at, r->>'status', r->>'class', r->>'engine_version',
         (r->>'allocated_gb')::int, (r->>'multi_az')::boolean, (r->>'public')::boolean, r->>'az',
         (r->>'created')::timestamptz, (r->>'free_until')::timestamptz, NULLIF(r->'pending', 'null'::jsonb),
         (r->>'cpu_pct')::float8, (r->>'freeable_bytes')::float8::bigint, (r->>'free_storage_bytes')::float8::bigint,
         (r->>'swap_bytes')::float8::bigint, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'ri'
  ON CONFLICT (instance_id, ri_arn) DO UPDATE SET
    ri_id = EXCLUDED.ri_id, snapshot_at = EXCLUDED.snapshot_at, status = EXCLUDED.status, class = EXCLUDED.class,
    engine_version = EXCLUDED.engine_version, allocated_gb = EXCLUDED.allocated_gb, multi_az = EXCLUDED.multi_az,
    public = EXCLUDED.public, az = EXCLUDED.az, created = EXCLUDED.created, free_until = EXCLUDED.free_until,
    pending = EXCLUDED.pending, cpu_pct = EXCLUDED.cpu_pct, freeable_bytes = EXCLUDED.freeable_bytes,
    free_storage_bytes = EXCLUDED.free_storage_bytes, swap_bytes = EXCLUDED.swap_bytes, is_present = true;

  UPDATE pgvigil.dms_instances d SET is_present = false
   WHERE d.instance_id = p_instance_id AND d.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'ri' AND r->>'ri_arn' = d.ri_arn);

  INSERT INTO pgvigil.dms_tasks AS t (instance_id, task_arn, task_id, snapshot_at, ri_arn, migration_type, status, stop_reason,
                                      last_failure, progress_pct, tables_loaded, tables_loading, tables_queued, tables_errored,
                                      elapsed_ms, created, started, fresh_start, start_date, stop_date, full_load_start,
                                      full_load_finish, cdc_start_position, recovery_checkpoint, source_endpoint_arn,
                                      target_endpoint_arn, latency_source_s, latency_target_s, incoming_changes, latency_at,
                                      latency_warn_secs, tables_partial, first_seen, is_present)
  SELECT p_instance_id, r->>'task_arn', r->>'task_id', p_snapshot_at, r->>'ri_arn', r->>'migration_type', r->>'status',
         r->>'stop_reason', r->>'last_failure', (r->>'progress_pct')::int, (r->>'tables_loaded')::int,
         (r->>'tables_loading')::int, (r->>'tables_queued')::int, (r->>'tables_errored')::int, (r->>'elapsed_ms')::bigint,
         (r->>'created')::timestamptz, (r->>'started')::timestamptz, (r->>'fresh_start')::timestamptz,
         (r->>'start_date')::timestamptz, (r->>'stop_date')::timestamptz, (r->>'full_load_start')::timestamptz,
         (r->>'full_load_finish')::timestamptz, r->>'cdc_start_position', r->>'recovery_checkpoint',
         r->>'source_endpoint_arn', r->>'target_endpoint_arn', (r->>'latency_source_s')::float8,
         (r->>'latency_target_s')::float8, (r->>'incoming_changes')::float8, (r->>'latency_at')::timestamptz,
         coalesce((r->>'latency_warn_secs')::int, 300), coalesce((r->>'tables_partial')::boolean, false), p_snapshot_at, true
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
    latency_warn_secs = EXCLUDED.latency_warn_secs, tables_partial = EXCLUDED.tables_partial, is_present = true;

  UPDATE pgvigil.dms_tasks t SET is_present = false
   WHERE t.instance_id = p_instance_id AND t.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'task' AND r->>'task_arn' = t.task_arn);

  -- one sample per task per run: the trend the latency and progress charts read
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'task') THEN
    PERFORM pgvigil.ensure_month_partition('dms_task_sample', p_snapshot_at);
    INSERT INTO pgvigil.dms_task_sample (instance_id, snapshot_at, task_arn, status, progress_pct, tables_errored,
                                         latency_source_s, latency_target_s, incoming_changes)
    SELECT p_instance_id, p_snapshot_at, r->>'task_arn', r->>'status', (r->>'progress_pct')::int, (r->>'tables_errored')::int,
           (r->>'latency_source_s')::float8, (r->>'latency_target_s')::float8, (r->>'incoming_changes')::float8
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

  -- a table that left a task described in this run (the mapping changed); a task whose statistics were cut
  -- at the collector's cap keeps every row (the unread tail is not absent, only unread)
  UPDATE pgvigil.dms_table_stats s SET is_present = false
   WHERE s.instance_id = p_instance_id AND s.is_present
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                  WHERE r->>'kind' = 'task' AND r->>'task_arn' = s.task_arn AND NOT coalesce((r->>'tables_partial')::boolean, false))
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'table' AND r->>'task_arn' = s.task_arn
                        AND r->>'schema_name' = s.schema_name AND r->>'table_name' = s.table_name);
END $$;

-- The daily checks on DMS, one row per finding: instance_id, severity, check_name, object, at, detail.
-- A full-load task that stopped with FULL_LOAD_ONLY_FINISHED at 100 % reached its normal end; any other stop
-- (a CDC task stopped, a full-load task stopped early or for another reason) is a warning. A stop reason
-- naming a fatal error, memory, disk or a licence is critical whatever the status. The CDC latency check
-- waits for the full load of a full-load-and-cdc task to finish (cached changes apply after it by design).
-- A task stopped on purpose warns for as long as it is named in aws.dms.tasks: the snooze is taking it off
-- the list (its row then goes is_present = false and leaves every check).
CREATE OR REPLACE VIEW pgvigil.dms_checks AS
WITH t AS (SELECT * FROM pgvigil.dms_tasks WHERE is_present),
     v AS (SELECT instance_id, task_arn,
                  sum(coalesce(validation_failed, 0)) AS failed, sum(coalesce(full_load_error_rows, 0)) AS err_rows,
                  count(*) FILTER (WHERE table_state ILIKE '%error%') AS err_tables
             FROM pgvigil.dms_table_stats WHERE is_present GROUP BY instance_id, task_arn)
SELECT t.instance_id, 'critical' AS severity, 'DMS task failed' AS check_name, t.task_id AS object,
       coalesce(t.stop_date, t.snapshot_at) AS at,
       t.status || coalesce(': ' || t.stop_reason, '') || coalesce(' - ' || left(t.last_failure, 300), '') AS detail
  FROM t
 WHERE t.status IN ('failed', 'failed-move', 'error')
    OR (t.status = 'stopped' AND t.stop_reason ~* 'FATAL|LOW_MEMORY|LOW_DISK|LICENSE')
UNION ALL
SELECT t.instance_id, 'warning', 'DMS task stopped', t.task_id, coalesce(t.stop_date, t.snapshot_at),
       coalesce(t.stop_reason, 'no stop reason') || ' (' || coalesce(t.migration_type, '?') || ', full load ' || coalesce(t.progress_pct::text, '?') || ' %)'
  FROM t
 WHERE t.status = 'stopped'
   AND NOT (coalesce(t.migration_type, '') = 'full-load' AND coalesce(t.stop_reason, '') ~* 'FULL_LOAD_ONLY_FINISHED' AND coalesce(t.progress_pct, 100) = 100)
   AND NOT coalesce(t.stop_reason ~* 'FATAL|LOW_MEMORY|LOW_DISK|LICENSE', false)
UNION ALL
SELECT t.instance_id, 'warning', 'DMS CDC latency', t.task_id, coalesce(t.latency_at, t.snapshot_at),
       'source ' || round(coalesce(t.latency_source_s, 0))::text || ' s, target ' || round(coalesce(t.latency_target_s, 0))::text
       || ' s (threshold ' || t.latency_warn_secs::text || ' s)'
  FROM t
 WHERE t.status = 'running' AND greatest(coalesce(t.latency_source_s, 0), coalesce(t.latency_target_s, 0)) > t.latency_warn_secs
   AND (coalesce(t.migration_type, '') <> 'full-load-and-cdc' OR t.full_load_finish IS NOT NULL)
UNION ALL
SELECT t.instance_id, 'warning', 'DMS tables in error', t.task_id, t.snapshot_at,
       coalesce(v.err_tables, 0)::text || ' table(s) in error, ' || coalesce(t.tables_errored, 0)::text
       || ' errored per the task, ' || coalesce(v.err_rows, 0)::text || ' full-load error row(s)'
  FROM t LEFT JOIN v USING (instance_id, task_arn)
 WHERE coalesce(t.tables_errored, 0) > 0 OR coalesce(v.err_tables, 0) > 0 OR coalesce(v.err_rows, 0) > 0
UNION ALL
SELECT t.instance_id, 'warning', 'DMS validation failures', t.task_id, t.snapshot_at, v.failed::text || ' record(s) failed validation'
  FROM t JOIN v USING (instance_id, task_arn)
 WHERE v.failed > 0
UNION ALL
SELECT i.instance_id, 'warning', 'DMS instance status', i.ri_id, i.snapshot_at, i.status
  FROM pgvigil.dms_instances i
 WHERE i.is_present AND coalesce(i.status, '') <> 'available'
UNION ALL
SELECT i.instance_id, 'critical', 'DMS instance storage low', i.ri_id, i.snapshot_at,
       pg_size_pretty(i.free_storage_bytes) || ' free of ' || i.allocated_gb::text || ' GB'
  FROM pgvigil.dms_instances i
 WHERE i.is_present AND i.free_storage_bytes < 1073741824
UNION ALL
SELECT i.instance_id, 'warning', 'DMS instance memory low', i.ri_id, i.snapshot_at,
       pg_size_pretty(i.freeable_bytes) || ' freeable, ' || pg_size_pretty(i.swap_bytes) || ' swap in use'
  FROM pgvigil.dms_instances i
 WHERE i.is_present AND i.swap_bytes > 0 AND i.freeable_bytes < 268435456;

CREATE OR REPLACE FUNCTION pgvigil.purge(p_days int DEFAULT 30)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n       bigint := 0;
  v_rows  bigint;
  v_part  record;
BEGIN
  FOR v_part IN
    SELECT c.relname
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent
      JOIN pg_namespace ns ON ns.oid = p.relnamespace
     WHERE ns.nspname = 'pgvigil'
       AND p.relname IN ('activity_sample', 'statements_delta', 'dbstats', 'serverstats', 'iostats', 'replication_sample', 'database_sizes', 'log_events', 'dms_task_sample')
       AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    n := n + 1;
  END LOOP;
  DELETE FROM pgvigil.job_runs WHERE start_time < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.activity_summary WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statements_info WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statements_current WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.query_text t
   WHERE t.last_seen < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.activity_sample s WHERE s.query_hash = t.query_hash);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statement_text t
   WHERE t.last_seen < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.statements_delta d WHERE d.instance_id = t.instance_id AND d.queryid = t.queryid);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.collection_log WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- DMS objects gone from the API for longer than the retention
  DELETE FROM pgvigil.dms_table_stats WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.dms_tasks WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.dms_instances WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  RETURN n;
END $$;
