-- 0167_mssql_azuredb_hour: the hourly rows of Azure SQL Database's resource minutes (task B2a-N2; DBA Dash 4.25.0's
-- AzureDBResourceStats_60MIN shape), so a window over a day reads hours, not minutes (the 24-hour Azure Summary took
-- 13.3 s at 1,819 databases on minutes). Read from the minutes the collector already stores; nothing is created,
-- changed or switched on on a monitored server.
--
--   the hour          the UTC hour of the minute's start (date_trunc on the UTC wall clock: never the session's zone)
--   totals, counts    per averaged figure its TOTAL (each minute's average x its 15-second samples) and its COUNTED
--                     samples (the minutes that carry the figure): a window's average over hours = sum(total) /
--                     sum(counted), the same number as over its minutes. A stated departure from DBA Dash, which keeps
--                     each hour's AVG and averages those (an hour of 20 samples weighing as one of 240). The maxima,
--                     the limits' minimum and maximum (DBA Dash keeps the MAX alone; the window's min limit is kept for
--                     the 'limit changed' reading), replica_role's maximum, and the 40 bucket counts summed.
--   filled            by a statement-level AFTER INSERT trigger with a transition table on mssql_azuredb_minute (its
--                     one writer, import_mssql_azuredb_resources, inserts with ON CONFLICT DO NOTHING: a minute read
--                     twice is not inserted again, so never counted again): per instance, its own lock key in its own
--                     statement, lock_timeout 5 s (a wait that would reach the collector's 30 s repository timeout is
--                     an error the body catches, never a cancel it cannot), the instance's dirty hours healed under a
--                     200 ms budget, then the touched hours RECOMPUTED from the stored minutes (never added to).
--   a failure         never fails the import: the body catches it, merges the hours into the instance's dirty range
--                     and writes one 'rollup failed' row in collection_log (collection 'mssql_azuredb_hour') at most once
--                     an hour; the next trigger call of the instance and 'pgvigil purge' heal it ('rollup healed').
--   the first build   none in this file and no row written by it (no migration writes a stored row, docs/upgrade.md):
--                     the first heal that meets an instance with minutes and no first_build row queues its whole range
--                     and writes the row; readers take 'minutes stored and no first_build row' and a dirty range as
--                     unbuilt and read those hours from the minutes. 'pgvigil purge' builds every pending instance, one
--                     per transaction (mssql_azuredb_hour_pending / _heal_one), with no budget.
--   partitions        by month, made by mssql_azuredb_hour_partition WITHOUT ensure_month_partition's second
--                     (instance_id, snapshot_at) index (here it is the primary key itself) and with fillfactor 80 (each
--                     import rewrites its current hour's row); the next month's is made ahead by each heal.
--   retention         pgvigil.hours_retention ('mssql_azuredb_hour', 730: DBA Dash's for AzureDBResourceStats_60MIN);
--                     mssql_azuredb_hour_purge drops older months for purge()'s last block (the join's 0190 line, as
--                     0139's job_stats_hourly_purge). The minutes keep purge's p_days.
--   size              about 31.9 million rows at 1,819 databases over 730 days, about 450 bytes each: about 14 GB of
--                     heap and 1-1.3 GB of key (an estimate, the design pass's; the scale test measures it).
SET LOCAL lock_timeout = '20s';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_azuredb_hour (
  instance_id  int NOT NULL,
  snapshot_at  timestamptz NOT NULL,   -- the UTC hour
  minutes      int NOT NULL,
  samples      int NOT NULL,
  cpu_total numeric(20,4),          -- the sum of each minute's avg_cpu_percent x its samples
  cpu_counted int,                   -- the samples of the minutes that carry avg_cpu_percent
  max_cpu_percent numeric(12,4),
  data_io_total numeric(20,4),          -- the sum of each minute's avg_data_io_percent x its samples
  data_io_counted int,                   -- the samples of the minutes that carry avg_data_io_percent
  max_data_io_percent numeric(12,4),
  log_write_total numeric(20,4),          -- the sum of each minute's avg_log_write_percent x its samples
  log_write_counted int,                   -- the samples of the minutes that carry avg_log_write_percent
  max_log_write_percent numeric(12,4),
  memory_usage_total numeric(20,4),          -- the sum of each minute's avg_memory_usage_percent x its samples
  memory_usage_counted int,                   -- the samples of the minutes that carry avg_memory_usage_percent
  max_memory_usage_percent numeric(12,4),
  xtp_storage_total numeric(20,4),          -- the sum of each minute's avg_xtp_storage_percent x its samples
  xtp_storage_counted int,                   -- the samples of the minutes that carry avg_xtp_storage_percent
  max_xtp_storage_percent numeric(12,4),
  instance_cpu_total numeric(20,4),          -- the sum of each minute's avg_instance_cpu_percent x its samples
  instance_cpu_counted int,                   -- the samples of the minutes that carry avg_instance_cpu_percent
  max_instance_cpu_percent numeric(12,4),
  instance_memory_total numeric(20,4),          -- the sum of each minute's avg_instance_memory_percent x its samples
  instance_memory_counted int,                   -- the samples of the minutes that carry avg_instance_memory_percent
  max_instance_memory_percent numeric(12,4),
  dtu_percent_total numeric(20,4),          -- the sum of each minute's avg_dtu_percent x its samples
  dtu_percent_counted int,                   -- the samples of the minutes that carry avg_dtu_percent
  max_dtu_percent numeric(12,4),
  dtu_total numeric(20,4),          -- the sum of each minute's avg_dtu x its samples
  dtu_counted int,                   -- the samples of the minutes that carry avg_dtu
  max_dtu numeric(12,4),
  max_worker_percent numeric(5,2),
  max_session_percent numeric(5,2),
  min_dtu_limit int, max_dtu_limit int,
  min_cpu_limit numeric(7,2), max_cpu_limit numeric(7,2),
  replica_role int,                     -- the hour's largest (DBA Dash's MAX)
  dtu_buckets smallint[] NOT NULL,       -- the minutes' counts summed per bucket (at most 240 an hour)
  cpu_buckets smallint[] NOT NULL,       -- the minutes' counts summed per bucket (at most 240 an hour)
  data_buckets smallint[] NOT NULL,       -- the minutes' counts summed per bucket (at most 240 an hour)
  log_buckets smallint[] NOT NULL,       -- the minutes' counts summed per bucket (at most 240 an hour)
  PRIMARY KEY (instance_id, snapshot_at)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_azuredb_hour_dirty (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  from_at      timestamptz NOT NULL,   -- whole UTC hours, or -infinity / infinity for the first build
  to_at        timestamptz NOT NULL,
  why          text,
  noted_at     timestamptz NOT NULL DEFAULT now(),
  logged_at    timestamptz             -- the last 'rollup failed' row of this range
);
CREATE TABLE IF NOT EXISTS pgvigil.mssql_azuredb_hour_first_build (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  queued_at    timestamptz NOT NULL DEFAULT now()
);
INSERT INTO pgvigil.hours_retention (table_name, days) VALUES ('mssql_azuredb_hour', 730) ON CONFLICT (table_name) DO NOTHING;

-- one month's partition of the hours (no second index; fillfactor 80); the name ensure_month_partition's
CREATE OR REPLACE FUNCTION pgvigil.mssql_azuredb_hour_partition(p_at timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_from timestamp := date_trunc('month', p_at AT TIME ZONE 'UTC');
  v_name text := 'mssql_azuredb_hour_' || to_char(v_from, 'YYYYMM');
BEGIN
  IF to_regclass('pgvigil.' || quote_ident(v_name)) IS NOT NULL THEN
    RETURN;
  END IF;
  BEGIN
    EXECUTE format('CREATE TABLE pgvigil.%I PARTITION OF pgvigil.mssql_azuredb_hour FOR VALUES FROM (%L) TO (%L) WITH (fillfactor = 80)',
                   v_name, v_from AT TIME ZONE 'UTC', (v_from + interval '1 month') AT TIME ZONE 'UTC');
  EXCEPTION WHEN duplicate_table THEN
    NULL;   -- another importer made it first
  END;
END $$;

-- the given UTC hours of one instance recomputed from its minutes (the caller holds the instance's lock)
CREATE OR REPLACE FUNCTION pgvigil.mssql_azuredb_hour_recompute(p_instance_id int, p_hours timestamptz[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  PERFORM pgvigil.mssql_azuredb_hour_partition(m)
     FROM (SELECT DISTINCT date_trunc('month', h AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS m FROM unnest(p_hours) h) x;
  INSERT INTO pgvigil.mssql_azuredb_hour AS s (instance_id, snapshot_at, minutes, samples, cpu_total, cpu_counted, max_cpu_percent, data_io_total, data_io_counted, max_data_io_percent, log_write_total, log_write_counted, max_log_write_percent, memory_usage_total, memory_usage_counted, max_memory_usage_percent, xtp_storage_total, xtp_storage_counted, max_xtp_storage_percent, instance_cpu_total, instance_cpu_counted, max_instance_cpu_percent, instance_memory_total, instance_memory_counted, max_instance_memory_percent, dtu_percent_total, dtu_percent_counted, max_dtu_percent, dtu_total, dtu_counted, max_dtu, max_worker_percent, max_session_percent, min_dtu_limit, max_dtu_limit, min_cpu_limit, max_cpu_limit, replica_role, dtu_buckets, cpu_buckets, data_buckets, log_buckets)
  SELECT p_instance_id,
         h.h,
         count(*),
         sum(a.samples),
         sum(a.avg_cpu_percent * a.samples),
         sum(a.samples) FILTER (WHERE a.avg_cpu_percent IS NOT NULL),
         max(a.max_cpu_percent),
         sum(a.avg_data_io_percent * a.samples),
         sum(a.samples) FILTER (WHERE a.avg_data_io_percent IS NOT NULL),
         max(a.max_data_io_percent),
         sum(a.avg_log_write_percent * a.samples),
         sum(a.samples) FILTER (WHERE a.avg_log_write_percent IS NOT NULL),
         max(a.max_log_write_percent),
         sum(a.avg_memory_usage_percent * a.samples),
         sum(a.samples) FILTER (WHERE a.avg_memory_usage_percent IS NOT NULL),
         max(a.max_memory_usage_percent),
         sum(a.avg_xtp_storage_percent * a.samples),
         sum(a.samples) FILTER (WHERE a.avg_xtp_storage_percent IS NOT NULL),
         max(a.max_xtp_storage_percent),
         sum(a.avg_instance_cpu_percent * a.samples),
         sum(a.samples) FILTER (WHERE a.avg_instance_cpu_percent IS NOT NULL),
         max(a.max_instance_cpu_percent),
         sum(a.avg_instance_memory_percent * a.samples),
         sum(a.samples) FILTER (WHERE a.avg_instance_memory_percent IS NOT NULL),
         max(a.max_instance_memory_percent),
         sum(a.avg_dtu_percent * a.samples),
         sum(a.samples) FILTER (WHERE a.avg_dtu_percent IS NOT NULL),
         max(a.max_dtu_percent),
         sum(a.avg_dtu * a.samples),
         sum(a.samples) FILTER (WHERE a.avg_dtu IS NOT NULL),
         max(a.max_dtu),
         max(a.max_worker_percent),
         max(a.max_session_percent),
         min(a.dtu_limit),
         max(a.dtu_limit),
         min(a.cpu_limit),
         max(a.cpu_limit),
         max(a.replica_role),
         ARRAY[coalesce(sum(a.dtu_buckets[1]), 0), coalesce(sum(a.dtu_buckets[2]), 0), coalesce(sum(a.dtu_buckets[3]), 0), coalesce(sum(a.dtu_buckets[4]), 0), coalesce(sum(a.dtu_buckets[5]), 0), coalesce(sum(a.dtu_buckets[6]), 0), coalesce(sum(a.dtu_buckets[7]), 0), coalesce(sum(a.dtu_buckets[8]), 0), coalesce(sum(a.dtu_buckets[9]), 0), coalesce(sum(a.dtu_buckets[10]), 0)]::smallint[],
         ARRAY[coalesce(sum(a.cpu_buckets[1]), 0), coalesce(sum(a.cpu_buckets[2]), 0), coalesce(sum(a.cpu_buckets[3]), 0), coalesce(sum(a.cpu_buckets[4]), 0), coalesce(sum(a.cpu_buckets[5]), 0), coalesce(sum(a.cpu_buckets[6]), 0), coalesce(sum(a.cpu_buckets[7]), 0), coalesce(sum(a.cpu_buckets[8]), 0), coalesce(sum(a.cpu_buckets[9]), 0), coalesce(sum(a.cpu_buckets[10]), 0)]::smallint[],
         ARRAY[coalesce(sum(a.data_buckets[1]), 0), coalesce(sum(a.data_buckets[2]), 0), coalesce(sum(a.data_buckets[3]), 0), coalesce(sum(a.data_buckets[4]), 0), coalesce(sum(a.data_buckets[5]), 0), coalesce(sum(a.data_buckets[6]), 0), coalesce(sum(a.data_buckets[7]), 0), coalesce(sum(a.data_buckets[8]), 0), coalesce(sum(a.data_buckets[9]), 0), coalesce(sum(a.data_buckets[10]), 0)]::smallint[],
         ARRAY[coalesce(sum(a.log_buckets[1]), 0), coalesce(sum(a.log_buckets[2]), 0), coalesce(sum(a.log_buckets[3]), 0), coalesce(sum(a.log_buckets[4]), 0), coalesce(sum(a.log_buckets[5]), 0), coalesce(sum(a.log_buckets[6]), 0), coalesce(sum(a.log_buckets[7]), 0), coalesce(sum(a.log_buckets[8]), 0), coalesce(sum(a.log_buckets[9]), 0), coalesce(sum(a.log_buckets[10]), 0)]::smallint[]
    FROM unnest(p_hours) h(h)
    JOIN pgvigil.mssql_azuredb_minute a ON a.instance_id = p_instance_id AND a.snapshot_at >= h.h AND a.snapshot_at < h.h + interval '1 hour'
   GROUP BY h.h
  ON CONFLICT (instance_id, snapshot_at) DO UPDATE SET minutes = EXCLUDED.minutes, samples = EXCLUDED.samples, cpu_total = EXCLUDED.cpu_total, cpu_counted = EXCLUDED.cpu_counted, max_cpu_percent = EXCLUDED.max_cpu_percent, data_io_total = EXCLUDED.data_io_total, data_io_counted = EXCLUDED.data_io_counted, max_data_io_percent = EXCLUDED.max_data_io_percent, log_write_total = EXCLUDED.log_write_total, log_write_counted = EXCLUDED.log_write_counted, max_log_write_percent = EXCLUDED.max_log_write_percent, memory_usage_total = EXCLUDED.memory_usage_total, memory_usage_counted = EXCLUDED.memory_usage_counted, max_memory_usage_percent = EXCLUDED.max_memory_usage_percent, xtp_storage_total = EXCLUDED.xtp_storage_total, xtp_storage_counted = EXCLUDED.xtp_storage_counted, max_xtp_storage_percent = EXCLUDED.max_xtp_storage_percent, instance_cpu_total = EXCLUDED.instance_cpu_total, instance_cpu_counted = EXCLUDED.instance_cpu_counted, max_instance_cpu_percent = EXCLUDED.max_instance_cpu_percent, instance_memory_total = EXCLUDED.instance_memory_total, instance_memory_counted = EXCLUDED.instance_memory_counted, max_instance_memory_percent = EXCLUDED.max_instance_memory_percent, dtu_percent_total = EXCLUDED.dtu_percent_total, dtu_percent_counted = EXCLUDED.dtu_percent_counted, max_dtu_percent = EXCLUDED.max_dtu_percent, dtu_total = EXCLUDED.dtu_total, dtu_counted = EXCLUDED.dtu_counted, max_dtu = EXCLUDED.max_dtu, max_worker_percent = EXCLUDED.max_worker_percent, max_session_percent = EXCLUDED.max_session_percent, min_dtu_limit = EXCLUDED.min_dtu_limit, max_dtu_limit = EXCLUDED.max_dtu_limit, min_cpu_limit = EXCLUDED.min_cpu_limit, max_cpu_limit = EXCLUDED.max_cpu_limit, replica_role = EXCLUDED.replica_role, dtu_buckets = EXCLUDED.dtu_buckets, cpu_buckets = EXCLUDED.cpu_buckets, data_buckets = EXCLUDED.data_buckets, log_buckets = EXCLUDED.log_buckets;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- every hour of one instance's stored minutes in [p_from, p_to) recomputed, ONE pass per month (newest month first is
-- the caller's order); bounds widened to whole UTC hours; idempotent
CREATE OR REPLACE FUNCTION pgvigil.mssql_azuredb_hour_rebuild(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_hours timestamptz[];
BEGIN
  SELECT array_agg(DISTINCT date_trunc('hour', a.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') INTO v_hours
    FROM pgvigil.mssql_azuredb_minute a
   WHERE a.instance_id = p_instance_id AND a.snapshot_at >= p_from AND a.snapshot_at < p_to;
  IF v_hours IS NULL THEN
    RETURN 0;
  END IF;
  RETURN pgvigil.mssql_azuredb_hour_recompute(p_instance_id, v_hours);
END $$;

-- one instance's dirty range rebuilt newest week first (the caller holds the instance's lock); an instance met for
-- the first time with minutes and no first_build row has its whole range queued first; with a budget (ms, NULL = none)
-- the heal stops once it is spent and keeps the rest of the range as it was read; next month's partition made ahead
CREATE OR REPLACE FUNCTION pgvigil.mssql_azuredb_hour_heal(p_instance_id int, p_budget_ms int DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v record; v_n int := 0; v_t0 timestamptz := clock_timestamp(); v_lo timestamptz; v_hi timestamptz; v_cut timestamptz;
BEGIN
  PERFORM pgvigil.mssql_azuredb_hour_partition(now() + interval '1 month');
  IF NOT EXISTS (SELECT 1 FROM pgvigil.mssql_azuredb_hour_first_build b WHERE b.instance_id = p_instance_id) THEN
    IF EXISTS (SELECT 1 FROM pgvigil.mssql_azuredb_minute a WHERE a.instance_id = p_instance_id) THEN
      INSERT INTO pgvigil.mssql_azuredb_hour_dirty AS d (instance_id, from_at, to_at, why)
      VALUES (p_instance_id, '-infinity', 'infinity', 'the first build')
      ON CONFLICT (instance_id) DO UPDATE SET from_at = '-infinity', to_at = 'infinity', noted_at = now();
    END IF;
    INSERT INTO pgvigil.mssql_azuredb_hour_first_build (instance_id) VALUES (p_instance_id) ON CONFLICT (instance_id) DO NOTHING;
  END IF;
  SELECT d.from_at, d.to_at, d.logged_at INTO v FROM pgvigil.mssql_azuredb_hour_dirty d WHERE d.instance_id = p_instance_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;
  SELECT min(a.snapshot_at), max(a.snapshot_at) INTO v_lo, v_hi FROM pgvigil.mssql_azuredb_minute a
   WHERE a.instance_id = p_instance_id AND a.snapshot_at >= v.from_at AND a.snapshot_at < v.to_at;
  v_lo := date_trunc('hour', v_lo AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_hi := (date_trunc('hour', v_hi AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC';   -- NULL when no minute
  WHILE v_lo IS NOT NULL AND v_hi > v_lo LOOP
    v_cut := greatest(v_lo, v_hi - interval '7 days');
    v_n := v_n + pgvigil.mssql_azuredb_hour_rebuild(p_instance_id, v_cut, v_hi);
    v_hi := v_cut;
    IF p_budget_ms IS NOT NULL AND v_hi > v_lo AND clock_timestamp() - v_t0 >= make_interval(secs => p_budget_ms / 1000.0) THEN
      UPDATE pgvigil.mssql_azuredb_hour_dirty d SET to_at = v_hi, noted_at = now()
       WHERE d.instance_id = p_instance_id AND d.from_at = v.from_at AND d.to_at = v.to_at;
      RETURN v_n;
    END IF;
  END LOOP;
  DELETE FROM pgvigil.mssql_azuredb_hour_dirty d WHERE d.instance_id = p_instance_id AND d.from_at = v.from_at AND d.to_at = v.to_at;
  IF FOUND AND v.logged_at IS NOT NULL THEN
    INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
    VALUES (p_instance_id, 'mssql_azuredb_hour', now(), 'ok',
            format('rollup healed: the hours %s to %s rebuilt', coalesce(to_char(v.from_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), v.from_at::text),
                   coalesce(to_char(v.to_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), v.to_at::text)));
  END IF;
  RETURN v_n;
END $$;

-- a trigger call that could not write its hours: merged into the instance's dirty range, and a 'rollup failed' row
-- when the range is new or its last such row is an hour old
CREATE OR REPLACE FUNCTION pgvigil.mssql_azuredb_hour_failed(p_instance_id int, p_from timestamptz, p_to timestamptz, p_why text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_prev timestamptz; v_had boolean; v_log boolean;
BEGIN
  SELECT true, d.logged_at INTO v_had, v_prev FROM pgvigil.mssql_azuredb_hour_dirty d WHERE d.instance_id = p_instance_id;
  v_log := v_had IS NULL OR v_prev IS NULL OR v_prev < now() - interval '1 hour';
  INSERT INTO pgvigil.mssql_azuredb_hour_dirty AS d (instance_id, from_at, to_at, why, logged_at)
  VALUES (p_instance_id, p_from, p_to, p_why, now())
  ON CONFLICT (instance_id) DO UPDATE
    SET from_at = least(d.from_at, excluded.from_at), to_at = greatest(d.to_at, excluded.to_at), noted_at = now(), why = excluded.why,
        logged_at = CASE WHEN v_log THEN now() ELSE d.logged_at END;
  IF v_log THEN
    INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
    VALUES (p_instance_id, 'mssql_azuredb_hour', now(), 'error',
            format('rollup failed for the hours %s to %s (the minutes are stored; the hours are rebuilt by the next import or purge): %s',
                   to_char(p_from AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), to_char(p_to AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), p_why));
  END IF;
END $$;

-- the instances 'pgvigil purge' builds: a dirty range, or minutes stored and no first build queued
CREATE OR REPLACE FUNCTION pgvigil.mssql_azuredb_hour_pending()
RETURNS SETOF int LANGUAGE sql STABLE AS $$
  SELECT u.instance_id
    FROM (SELECT d.instance_id FROM pgvigil.mssql_azuredb_hour_dirty d
          UNION
          SELECT r.instance_id FROM pgvigil.mssql_azuredb_read r
           WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_azuredb_hour_first_build b WHERE b.instance_id = r.instance_id)) u
   ORDER BY u.instance_id
$$;

-- one instance built whole under its lock (no budget), for 'pgvigil purge': one call, one transaction
CREATE OR REPLACE FUNCTION pgvigil.mssql_azuredb_hour_heal_one(p_instance_id int)
RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.mssql_azuredb_hour'), p_instance_id);
  RETURN pgvigil.mssql_azuredb_hour_heal(p_instance_id);
END $$;

-- the trigger's body: per instance in the statement's rows, lock_timeout 5 s, the lock in its own statement, the
-- dirty range healed under 200 ms, then the touched hours recomputed; any error caught per instance (a lock timeout
-- is one), its record guarded in turn
CREATE OR REPLACE FUNCTION pgvigil.mssql_azuredb_hour_tg()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM n) THEN RETURN NULL; END IF;   -- a statement trigger fires on every call: no rows, no lock
  PERFORM set_config('lock_timeout', '5s', true);
  FOR v IN SELECT x.instance_id, array_agg(DISTINCT date_trunc('hour', x.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') AS hours
             FROM n x GROUP BY x.instance_id ORDER BY x.instance_id LOOP
    BEGIN
      PERFORM pg_advisory_xact_lock(hashtext('pgvigil.mssql_azuredb_hour'), v.instance_id);
      PERFORM pgvigil.mssql_azuredb_hour_heal(v.instance_id, 200);
      PERFORM pgvigil.mssql_azuredb_hour_recompute(v.instance_id, v.hours);
    EXCEPTION WHEN OTHERS THEN
      BEGIN
        PERFORM pgvigil.mssql_azuredb_hour_failed(v.instance_id, (SELECT min(h) FROM unnest(v.hours) h),
                                                  (SELECT max(h) FROM unnest(v.hours) h) + interval '1 hour', SQLERRM);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'mssql_azuredb_hour: the rollup of instance % failed and could not be recorded: %', v.instance_id, SQLERRM;
      END;
    END;
  END LOOP;
  RETURN NULL;
END $$;

-- the months of mssql_azuredb_hour wholly older than its hours_retention row (730 days when absent) dropped; returns
-- their names (purge()'s last block adds them to the run's partitions_dropped: the join's 0190 line)
CREATE OR REPLACE FUNCTION pgvigil.mssql_azuredb_hour_purge()
RETURNS text[] LANGUAGE plpgsql AS $$
DECLARE v_days int; v_part record; v_names text[] := '{}';
BEGIN
  SELECT r.days INTO v_days FROM pgvigil.hours_retention r WHERE r.table_name = 'mssql_azuredb_hour';
  v_days := coalesce(v_days, 730);
  FOR v_part IN
    SELECT c.relname
      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent = 'pgvigil.mssql_azuredb_hour'::regclass
       AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => v_days)
     ORDER BY c.relname
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    v_names := v_names || v_part.relname::text;
  END LOOP;
  RETURN v_names;
END $$;

-- whether an instance's hour is built (readers take an unbuilt hour from the minutes)
CREATE OR REPLACE FUNCTION pgvigil.mssql_azuredb_hour_built(p_instance_id int, p_hour timestamptz)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pgvigil.mssql_azuredb_hour_first_build b WHERE b.instance_id = p_instance_id)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_azuredb_hour_dirty d
                      WHERE d.instance_id = p_instance_id AND d.from_at < p_hour + interval '1 hour' AND d.to_at > p_hour)
$$;

DROP TRIGGER IF EXISTS mssql_azuredb_hour_ins ON pgvigil.mssql_azuredb_minute;
CREATE TRIGGER mssql_azuredb_hour_ins AFTER INSERT ON pgvigil.mssql_azuredb_minute
  REFERENCING NEW TABLE AS n FOR EACH STATEMENT EXECUTE FUNCTION pgvigil.mssql_azuredb_hour_tg();
