-- 0016_tables: the checks and views borrowed from the DBA toolkits (phase 1b, task 21).
--   1. the tables collection: the hourly table health read (size, dead rows, visibility map, last vacuum and
--      analyze, transaction-id age, a bloat estimate), a current row per table in the latest top N of its
--      database, a per-database summary row, and a size history; table_checks for the overview.
--   2. DMS: the drain readout (rows behind / rate, latency trend -> time to caught up), the spill columns and
--      the validation summary per task (dms_drain); dms_checks gains a spill and a suspended-validation check.
--   3. findings: server parameters off their recommended range, per platform, from instance_state.
--   4. statements: the top statements over a window by a chosen order (time, calls, IO, mean, rows, temp,
--      WAL), and the statements seen running long between two times from the activity samples.

-- ---------------------------------------------------------------------------------------------------------
-- 1. tables
-- ---------------------------------------------------------------------------------------------------------

-- the latest read of each table that was in its database's top N; is_present = false once a read of that
-- database no longer lists it (it left the top N, or was dropped)
CREATE TABLE IF NOT EXISTS pgvigil.tables (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid                 bigint NOT NULL,
  relid                bigint NOT NULL,
  datname              text NOT NULL,
  schema_name          text NOT NULL,
  table_name           text NOT NULL,
  snapshot_at          timestamptz NOT NULL,
  relkind              text,
  total_bytes          bigint,                 -- heap + TOAST + indexes + free space and visibility maps
  heap_bytes           bigint,                 -- the main fork
  toast_bytes          bigint,                 -- the TOAST table with its index
  index_bytes          bigint,
  relpages             bigint,                 -- pg_class: as of the last vacuum / analyze / index build
  reltuples            double precision,
  relallvisible        bigint,
  n_live_tup           bigint,
  n_dead_tup           bigint,
  n_mod_since_analyze  bigint,
  n_ins_since_vacuum   bigint,                 -- PG13+
  last_vacuum          timestamptz,            -- manual or auto, the later
  last_autovacuum      timestamptz,
  last_analyze         timestamptz,            -- manual or auto, the later
  last_autoanalyze     timestamptz,
  vacuums              bigint,                 -- manual + auto since the statistics reset
  analyzes             bigint,
  seq_scan             bigint,
  idx_scan             bigint,
  autovacuum_off       boolean,                -- reloptions autovacuum_enabled = false on the table
  xid_age              bigint,                 -- age(relfrozenxid)
  mxid_age             bigint,
  stats_readable       boolean,                -- the login may read the table's pg_stats rows (SELECT on it)
  stats_columns        int,                    -- columns with planner statistics (0 = never analyzed, or unreadable)
  est_pages            bigint,                 -- pg_gather's expected heap pages for the live rows at the fillfactor, + the TOAST pages as they are
  bloat_bytes          bigint,
  bloat_pct            numeric,
  first_seen           timestamptz NOT NULL,
  is_present           boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid, relid)
);

-- one row per database read: the whole-database counts behind "has vacuum reached the tables after a load"
CREATE TABLE IF NOT EXISTS pgvigil.table_databases (
  instance_id            int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid                   bigint NOT NULL,
  datname                text NOT NULL,
  snapshot_at            timestamptz NOT NULL,
  stats_reset            timestamptz,          -- pg_stat_database.stats_reset: "never" means "not since then"
  user_tables            bigint,
  never_vacuumed         bigint,
  never_analyzed         bigint,
  big_tables             bigint,               -- 1,000 pages (8 MB) or more
  big_never_vacuumed     bigint,
  big_under_half_visible bigint,
  big_pages              bigint,
  big_visible_pages      bigint,
  is_present             boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid)
);

CREATE TABLE IF NOT EXISTS pgvigil.table_sizes (
  instance_id   int NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  dbid          bigint NOT NULL,
  relid         bigint NOT NULL,
  total_bytes   bigint,
  n_live_tup    bigint,
  n_dead_tup    bigint,
  bloat_bytes   bigint,
  xid_age       bigint
) PARTITION BY RANGE (snapshot_at);

-- payload: {kind:'db', dbid, datname, stats_reset, user_tables, ...} per database read, {kind:'table', dbid,
-- relid, ...} per table, {kind:'table_skipped', dbid, relid} per table left out for a lock (its row is kept as
-- it was), {kind:'collector_error', source:'tables:<datname>' | 'tables', message}. Absence is
-- judged only inside a database this payload read (its 'db' row is there); a database that failed this run
-- keeps its rows as they were.
CREATE OR REPLACE FUNCTION pgvigil.import_tables(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_tables'), p_instance_id);

  INSERT INTO pgvigil.table_databases AS d (instance_id, dbid, datname, snapshot_at, stats_reset, user_tables, never_vacuumed,
                                            never_analyzed, big_tables, big_never_vacuumed, big_under_half_visible, big_pages,
                                            big_visible_pages, is_present)
  SELECT p_instance_id, (r->>'dbid')::bigint, r->>'datname', p_snapshot_at, (r->>'stats_reset')::timestamptz,
         (r->>'user_tables')::bigint, (r->>'never_vacuumed')::bigint, (r->>'never_analyzed')::bigint, (r->>'big_tables')::bigint,
         (r->>'big_never_vacuumed')::bigint, (r->>'big_under_half_visible')::bigint, (r->>'big_pages')::bigint,
         (r->>'big_visible_pages')::bigint, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db'
  ON CONFLICT (instance_id, dbid) DO UPDATE SET
    datname = EXCLUDED.datname, snapshot_at = EXCLUDED.snapshot_at, stats_reset = EXCLUDED.stats_reset,
    user_tables = EXCLUDED.user_tables, never_vacuumed = EXCLUDED.never_vacuumed, never_analyzed = EXCLUDED.never_analyzed,
    big_tables = EXCLUDED.big_tables, big_never_vacuumed = EXCLUDED.big_never_vacuumed,
    big_under_half_visible = EXCLUDED.big_under_half_visible, big_pages = EXCLUDED.big_pages,
    big_visible_pages = EXCLUDED.big_visible_pages, is_present = true;

  -- a database neither read nor reported failing was dropped (or lost CONNECT); a capped run says nothing
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'collector_error' AND r->>'source' = 'tables') THEN
    UPDATE pgvigil.table_databases d SET is_present = false
     WHERE d.instance_id = p_instance_id AND d.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                        WHERE (r->>'kind' = 'db' AND (r->>'dbid')::bigint = d.dbid)
                           OR (r->>'kind' = 'collector_error' AND r->>'source' = 'tables:' || d.datname));
    UPDATE pgvigil.tables t SET is_present = false
     WHERE t.instance_id = p_instance_id AND t.is_present
       AND NOT EXISTS (SELECT 1 FROM pgvigil.table_databases d
                        WHERE d.instance_id = t.instance_id AND d.dbid = t.dbid AND d.is_present);
  END IF;

  INSERT INTO pgvigil.tables AS t (instance_id, dbid, relid, datname, schema_name, table_name, snapshot_at, relkind, total_bytes,
                                   heap_bytes, toast_bytes, index_bytes, relpages, reltuples, relallvisible, n_live_tup, n_dead_tup,
                                   n_mod_since_analyze, n_ins_since_vacuum, last_vacuum, last_autovacuum, last_analyze,
                                   last_autoanalyze, vacuums, analyzes, seq_scan, idx_scan, autovacuum_off, xid_age, mxid_age, stats_readable,
                                   stats_columns, est_pages, bloat_bytes, bloat_pct, first_seen, is_present)
  SELECT p_instance_id, (r->>'dbid')::bigint, (r->>'relid')::bigint, r->>'datname', r->>'schema_name', r->>'table_name', p_snapshot_at,
         r->>'relkind', (r->>'total_bytes')::bigint, (r->>'heap_bytes')::bigint, (r->>'toast_bytes')::bigint,
         (r->>'index_bytes')::bigint, (r->>'relpages')::bigint, (r->>'reltuples')::float8, (r->>'relallvisible')::bigint,
         (r->>'n_live_tup')::bigint, (r->>'n_dead_tup')::bigint, (r->>'n_mod_since_analyze')::bigint,
         (r->>'n_ins_since_vacuum')::bigint, (r->>'last_vacuum')::timestamptz, (r->>'last_autovacuum')::timestamptz,
         (r->>'last_analyze')::timestamptz, (r->>'last_autoanalyze')::timestamptz, (r->>'vacuums')::bigint,
         (r->>'analyzes')::bigint, (r->>'seq_scan')::bigint, (r->>'idx_scan')::bigint, (r->>'autovacuum_off')::boolean,
         (r->>'xid_age')::bigint,
         (r->>'mxid_age')::bigint, (r->>'stats_readable')::boolean, (r->>'stats_columns')::int, (r->>'est_pages')::bigint,
         (r->>'bloat_bytes')::bigint, (r->>'bloat_pct')::numeric, p_snapshot_at, true
    FROM (SELECT DISTINCT ON ((r->>'dbid')::bigint, (r->>'relid')::bigint) r
            FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'table') x
  ON CONFLICT (instance_id, dbid, relid) DO UPDATE SET
    datname = EXCLUDED.datname, schema_name = EXCLUDED.schema_name, table_name = EXCLUDED.table_name,
    snapshot_at = EXCLUDED.snapshot_at, relkind = EXCLUDED.relkind, total_bytes = EXCLUDED.total_bytes,
    heap_bytes = EXCLUDED.heap_bytes, toast_bytes = EXCLUDED.toast_bytes, index_bytes = EXCLUDED.index_bytes,
    relpages = EXCLUDED.relpages, reltuples = EXCLUDED.reltuples, relallvisible = EXCLUDED.relallvisible,
    n_live_tup = EXCLUDED.n_live_tup, n_dead_tup = EXCLUDED.n_dead_tup, n_mod_since_analyze = EXCLUDED.n_mod_since_analyze,
    n_ins_since_vacuum = EXCLUDED.n_ins_since_vacuum, last_vacuum = EXCLUDED.last_vacuum,
    last_autovacuum = EXCLUDED.last_autovacuum, last_analyze = EXCLUDED.last_analyze,
    last_autoanalyze = EXCLUDED.last_autoanalyze, vacuums = EXCLUDED.vacuums, analyzes = EXCLUDED.analyzes,
    seq_scan = EXCLUDED.seq_scan, idx_scan = EXCLUDED.idx_scan, autovacuum_off = EXCLUDED.autovacuum_off, xid_age = EXCLUDED.xid_age, mxid_age = EXCLUDED.mxid_age,
    stats_readable = EXCLUDED.stats_readable, stats_columns = EXCLUDED.stats_columns, est_pages = EXCLUDED.est_pages,
    bloat_bytes = EXCLUDED.bloat_bytes, bloat_pct = EXCLUDED.bloat_pct, is_present = true;

  -- inside a database read this run, a table not listed left the top N (or was dropped); a table the
  -- collector skipped for a lock ({kind:'table_skipped', dbid, relid}) was not read, so its row stays
  UPDATE pgvigil.tables t SET is_present = false
   WHERE t.instance_id = p_instance_id AND t.is_present
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = t.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' IN ('table', 'table_skipped') AND (r->>'dbid')::bigint = t.dbid AND (r->>'relid')::bigint = t.relid);

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'table') THEN
    PERFORM pgvigil.ensure_month_partition('table_sizes', p_snapshot_at);
    INSERT INTO pgvigil.table_sizes (instance_id, snapshot_at, dbid, relid, total_bytes, n_live_tup, n_dead_tup, bloat_bytes, xid_age)
    SELECT p_instance_id, p_snapshot_at, (r->>'dbid')::bigint, (r->>'relid')::bigint, (r->>'total_bytes')::bigint,
           (r->>'n_live_tup')::bigint, (r->>'n_dead_tup')::bigint, (r->>'bloat_bytes')::bigint, (r->>'xid_age')::bigint
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'table';
  END IF;
END $$;

-- The daily checks on tables (one row per finding: instance_id, severity, check_name, object, at, detail), from
-- the after-load section of a slow-read diagnostic and pg_gather's table list. A table counts from 1,000 pages (8 MB) on, the
-- toolkit's "big table" mark: smaller ones are cheap to scan whatever their state.
--   never vacuumed  - no vacuum recorded since the statistics reset: after a load the visibility map is empty,
--                     an index-only scan still visits the heap, the first readers rewrite hint bits
--   never analyzed  - the planner is guessing (missing statistics after a load)
--   statistics stale- over 20 % of the live rows changed since the last analyze (autoanalyze is behind)
--   bloat           - pg_gather's mark (over 20 % of the pages are not needed for the live rows), and at least
--                     100 MB of them (pg_gather's 5 MB floor is per report; a fleet page needs a higher one)
--   xid age         - age(relfrozenxid) or mxid_age(relminmxid) past 1,000,000,000 (warning) or 1,500,000,000
--                     (critical) of the 2^31 horizon: the forced anti-wraparound vacuum is not keeping up
-- and two of awslabs pg-collector's observations (any size):
--   dead rows       - over 20 % of the rows dead, with over 1,000 rows in the table
--   autovacuum off  - autovacuum_enabled = false in the table's own options
CREATE OR REPLACE VIEW pgvigil.table_checks AS
WITH t AS (SELECT t.*, t.datname || '.' || t.schema_name || '.' || t.table_name AS obj,
                  pg_size_pretty(t.total_bytes) AS size_txt
             FROM pgvigil.tables t WHERE t.is_present),
     d AS (SELECT instance_id, dbid, stats_reset FROM pgvigil.table_databases)
SELECT t.instance_id, 'warning' AS severity, 'table never vacuumed' AS check_name, t.obj AS object, t.snapshot_at AS at,
       t.size_txt || ', ' || coalesce(round(100.0 * t.relallvisible / nullif(t.relpages, 0))::text, '?') || ' % all-visible, '
       || coalesce(t.n_ins_since_vacuum::text, '?') || ' rows inserted since vacuum; no vacuum recorded'
       || coalesce(' since the statistics reset ' || to_char(d.stats_reset AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '') AS detail
  FROM t LEFT JOIN d USING (instance_id, dbid)
 WHERE t.last_vacuum IS NULL AND greatest(t.relpages, t.heap_bytes / 8192) >= 1000
UNION ALL
SELECT t.instance_id, 'warning', 'table never analyzed', t.obj, t.snapshot_at,
       t.size_txt || ', ' || coalesce(t.n_live_tup::text, '?') || ' live rows; no analyze recorded'
       || coalesce(' since the statistics reset ' || to_char(d.stats_reset AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '')
       || ': the planner is guessing'
  FROM t LEFT JOIN d USING (instance_id, dbid)
 WHERE t.last_analyze IS NULL AND greatest(t.relpages, t.heap_bytes / 8192) >= 1000
UNION ALL
SELECT t.instance_id, 'warning', 'table statistics stale', t.obj, t.snapshot_at,
       t.n_mod_since_analyze::text || ' rows changed since the last analyze ('
       || to_char(t.last_analyze AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC), ' || t.n_live_tup::text || ' live'
  FROM t
 WHERE t.last_analyze IS NOT NULL AND t.n_live_tup > 0 AND t.n_mod_since_analyze > 0.2 * t.n_live_tup
   AND greatest(t.relpages, t.heap_bytes / 8192) >= 1000
UNION ALL
SELECT t.instance_id, 'warning', 'table bloat', t.obj, t.snapshot_at,
       'about ' || pg_size_pretty(t.bloat_bytes) || ' (' || t.bloat_pct::text || ' %) of ' || t.size_txt
       || ' not needed for its ' || coalesce(t.n_live_tup::text, '?') || ' live rows; ' || coalesce(t.n_dead_tup::text, '?') || ' dead'
  FROM t
 WHERE t.bloat_pct > 20 AND t.bloat_bytes >= 104857600
UNION ALL
SELECT t.instance_id, CASE WHEN greatest(t.xid_age, t.mxid_age) >= 1500000000 THEN 'critical' ELSE 'warning' END,
       'table xid age', t.obj, t.snapshot_at,
       'xid age ' || t.xid_age::text || ', multixact age ' || coalesce(t.mxid_age::text, '?')
       || '; last vacuum ' || coalesce(to_char(t.last_vacuum AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'never recorded')
  FROM t
 WHERE greatest(t.xid_age, coalesce(t.mxid_age, 0)) >= 1000000000
UNION ALL
SELECT t.instance_id, 'warning', 'table dead rows', t.obj, t.snapshot_at,
       t.n_dead_tup::text || ' dead of ' || (t.n_live_tup + t.n_dead_tup)::text || ' rows ('
       || round(100.0 * t.n_dead_tup / (t.n_live_tup + t.n_dead_tup))::text || ' %); last vacuum '
       || coalesce(to_char(t.last_vacuum AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'never recorded')
  FROM t
 WHERE t.n_live_tup + t.n_dead_tup > 1000 AND t.n_dead_tup > 0.2 * (t.n_live_tup + t.n_dead_tup)
UNION ALL
SELECT t.instance_id, 'warning', 'table autovacuum off', t.obj, t.snapshot_at,
       'autovacuum_enabled = false on the table: no automatic vacuum or analyze, only the forced anti-wraparound one; '
       || t.size_txt || ', ' || coalesce(t.n_dead_tup::text, '?') || ' dead rows'
  FROM t
 WHERE t.autovacuum_off;

-- ---------------------------------------------------------------------------------------------------------
-- 2. DMS: drain readout, spill, validation summary
-- ---------------------------------------------------------------------------------------------------------

-- CloudWatch AWS/DMS task metrics added to the collector (newest datapoint, Maximum over the minute)
ALTER TABLE pgvigil.dms_tasks
  ADD COLUMN IF NOT EXISTS rows_in_s      double precision,   -- CDCThroughputRowsSource: rows read from the source per second
  ADD COLUMN IF NOT EXISTS rows_out_s     double precision,   -- CDCThroughputRowsTarget: rows applied to the target per second
  ADD COLUMN IF NOT EXISTS disk_source    double precision,   -- CDCChangesDiskSource: changes waiting on disk for commit on the source side
  ADD COLUMN IF NOT EXISTS disk_target    double precision,   -- CDCChangesDiskTarget: changes waiting on disk to be applied
  ADD COLUMN IF NOT EXISTS memory_source  double precision,   -- CDCChangesMemorySource
  ADD COLUMN IF NOT EXISTS memory_target  double precision;   -- CDCChangesMemoryTarget
ALTER TABLE pgvigil.dms_task_sample
  ADD COLUMN IF NOT EXISTS latency_at     timestamptz,        -- the CloudWatch datapoint the latencies come from
  ADD COLUMN IF NOT EXISTS rows_in_s      double precision,
  ADD COLUMN IF NOT EXISTS rows_out_s     double precision,
  ADD COLUMN IF NOT EXISTS disk_source    double precision,
  ADD COLUMN IF NOT EXISTS disk_target    double precision;

-- import_dms as in 0014, plus the six metric columns on the task and four on the sample
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

-- The drain readout per present task (the line of a DMS operations watch, without the chain-end anchor a fleet
-- monitor does not have: "caught up" means the target latency reaches zero).
--   reader_at      the source position the task has read to: the latency's timestamp minus the source latency
--   target latency now against the newest sample whose datapoint is 10-30 minutes older (the toolkit's
--   ~10-minute baseline, so one stale CloudWatch datapoint does not swing it); times are the datapoints'
--   (latency_at), not the imports', so a datapoint read twice adds no false "keeping pace":
--     speed_x      target-position advance per wall-clock second (1 = keeping pace, > 1 = catching up)
--     eta_secs     latency now / the rate it falls; NULL when it is not falling
--   rows_behind    CDCIncomingChanges; eta_rows_secs = rows behind / (rows out - rows in) per second, NULL when
--                  the apply is not outrunning the read
--   spill          changes on disk on either side (the toolkit: never stop or restart a task mid-spill)
--   validation     tables per validation bucket (the toolkit's val[pending failed suspended] summary) and the
--                  pending / failed record counts
CREATE OR REPLACE VIEW pgvigil.dms_drain AS
SELECT t.instance_id, t.task_arn, t.task_id, t.status, t.migration_type, t.snapshot_at,
       t.latency_source_s, t.latency_target_s, t.latency_at,
       t.latency_at - make_interval(secs => t.latency_source_s) AS reader_at,
       b.at AS baseline_at, b.latency_target_s AS baseline_latency_s,
       round((1 - (t.latency_target_s - b.latency_target_s) / nullif(extract(epoch FROM coalesce(t.latency_at, t.snapshot_at) - b.at), 0))::numeric, 3) AS speed_x,
       CASE WHEN t.latency_target_s > 0 AND b.latency_target_s > t.latency_target_s AND coalesce(t.latency_at, t.snapshot_at) > b.at
            THEN round((t.latency_target_s * extract(epoch FROM coalesce(t.latency_at, t.snapshot_at) - b.at)
                        / (b.latency_target_s - t.latency_target_s))::numeric) END AS eta_secs,
       t.incoming_changes AS rows_behind, t.rows_in_s, t.rows_out_s,
       CASE WHEN t.incoming_changes > 0 AND t.rows_out_s > coalesce(t.rows_in_s, 0)
            THEN round((t.incoming_changes / (t.rows_out_s - coalesce(t.rows_in_s, 0)))::numeric) END AS eta_rows_secs,
       t.disk_source, t.disk_target, t.memory_source, t.memory_target,
       coalesce(t.disk_source, 0) + coalesce(t.disk_target, 0) > 0 AS spilling,
       v.tables, v.validated, v.pending, v.never_validated, v.failed, v.suspended,
       v.tables - v.validated - v.pending - v.failed - v.suspended - v.not_validating AS other_state,
       v.pending_records, v.failed_records
  FROM pgvigil.dms_tasks t
  LEFT JOIN LATERAL (
    SELECT coalesce(s.latency_at, s.snapshot_at) AS at, s.latency_target_s
      FROM pgvigil.dms_task_sample s
     WHERE s.instance_id = t.instance_id AND s.task_arn = t.task_arn AND s.latency_target_s IS NOT NULL
       AND coalesce(s.latency_at, s.snapshot_at) <= coalesce(t.latency_at, t.snapshot_at) - interval '10 minutes'
       AND coalesce(s.latency_at, s.snapshot_at) >= coalesce(t.latency_at, t.snapshot_at) - interval '30 minutes'
     ORDER BY coalesce(s.latency_at, s.snapshot_at) DESC LIMIT 1) b ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS tables,
           count(*) FILTER (WHERE s.validation_state = 'Validated') AS validated,
           count(*) FILTER (WHERE s.validation_state ILIKE 'Pending%') AS pending,
           count(*) FILTER (WHERE s.validation_state = 'Pending validation') AS never_validated,
           count(*) FILTER (WHERE s.validation_state ILIKE '%ailed%' OR s.validation_state ILIKE 'Mismatched%') AS failed,
           count(*) FILTER (WHERE (s.validation_state ILIKE 'Suspended%' OR s.validation_state ILIKE '%error%')
                              AND NOT (s.validation_state ILIKE '%ailed%' OR s.validation_state ILIKE 'Mismatched%')) AS suspended,
           count(*) FILTER (WHERE s.validation_state IS NULL OR s.validation_state ILIKE 'Not enabled'
                              OR s.validation_state ILIKE 'No primary key') AS not_validating,
           coalesce(sum(s.validation_pending), 0) AS pending_records, coalesce(sum(s.validation_failed), 0) AS failed_records
      FROM pgvigil.dms_table_stats s
     WHERE s.instance_id = t.instance_id AND s.task_arn = t.task_arn AND s.is_present) v ON true
 WHERE t.is_present;

-- dms_checks as in 0014 (the eight checks, unchanged in name, severity and rule; the latency detail adds the
-- drain estimate), plus two from the same DMS operations watch:
--   DMS changes on disk       - a running task with changes spilled to disk: a stop or restart now throws the
--                               spilled transactions away (warning; it is the "do not bounce" line)
--   DMS validation suspended  - tables whose validation is suspended or in error (failed / mismatched records
--                               stay the existing validation-failures check)
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
       || CASE WHEN dr.eta_secs IS NOT NULL THEN '; draining, caught up in about ' || ceil(dr.eta_secs / 60.0)::text || ' min'
               WHEN dr.speed_x IS NOT NULL THEN '; not draining (' || dr.speed_x::text || 'x real time)'
               ELSE '' END
  FROM t LEFT JOIN pgvigil.dms_drain dr USING (instance_id, task_arn)
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
SELECT dr.instance_id, 'warning', 'DMS validation suspended', dr.task_id, dr.snapshot_at,
       dr.suspended::text || ' table(s) with validation suspended or in error'
  FROM pgvigil.dms_drain dr
 WHERE dr.suspended > 0
UNION ALL
SELECT t.instance_id, 'warning', 'DMS changes on disk', t.task_id, coalesce(t.latency_at, t.snapshot_at),
       round(coalesce(t.disk_source, 0))::text || ' change(s) on disk on the source side, ' || round(coalesce(t.disk_target, 0))::text
       || ' on the target side: a stop or restart now throws the spilled transactions away'
  FROM t
 WHERE t.status = 'running' AND coalesce(t.disk_source, 0) + coalesce(t.disk_target, 0) > 0
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

-- ---------------------------------------------------------------------------------------------------------
-- 3. findings: parameters off their recommended range (pg_gather's Parameter Recommendations)
-- ---------------------------------------------------------------------------------------------------------

-- The value of a setting on an instance: the stored non-default value (source configuration file, command
-- line, environment, global or database - a managed platform's parameter group lands here) or the built-in
-- default of that major version. Values are pg_settings.setting: in the setting's base unit (ms, s, kB, MB,
-- 8 kB pages), the units pg_gather's rules compare in.
CREATE OR REPLACE VIEW pgvigil.instance_settings AS
SELECT s.instance_id, s.snapshot_at, s.platform, s.server_version_num, s.is_replica, d.name,
       coalesce(nd.value, d.def) AS value, nd.value IS NOT NULL AS is_set
  FROM pgvigil.instance_state s
  CROSS JOIN LATERAL (VALUES
    ('autovacuum', 'on'), ('autovacuum_vacuum_cost_delay', '2'), ('autovacuum_max_workers', '3'),
    ('autovacuum_freeze_max_age', '200000000'),
    ('checkpoint_completion_target', CASE WHEN s.server_version_num >= 140000 THEN '0.9' ELSE '0.5' END),
    ('checkpoint_timeout', '300'), ('default_toast_compression', 'pglz'), ('huge_pages', 'try'),
    ('idle_session_timeout', '0'), ('idle_in_transaction_session_timeout', '0'), ('jit', 'on'), ('log_hostname', 'off'),
    ('log_lock_waits', 'off'),
    ('max_connections', coalesce(s.max_connections::text, '100')),
    ('max_standby_streaming_delay', '30000'), ('max_standby_archive_delay', '30000'),
    ('max_wal_size', '1024'), ('min_wal_size', '80'), ('random_page_cost', '4'), ('seq_page_cost', '1'),
    ('synchronous_standby_names', ''), ('synchronous_commit', 'on'), ('track_io_timing', 'off'),
    ('wal_compression', 'off'), ('wal_sync_method', 'fdatasync'), ('wal_sender_timeout', '60000'),
    ('work_mem', '4096'), ('zero_damaged_pages', 'off'),
    ('track_counts', 'on'), ('enable_indexscan', 'on'), ('enable_indexonlyscan', 'on'), ('log_statement', 'none'),
    ('log_min_duration_statement', '-1'), ('log_min_messages', 'warning'), ('log_parser_stats', 'off'),
    ('log_planner_stats', 'off'), ('log_executor_stats', 'off'), ('log_statement_stats', 'off'),
    ('debug_print_parse', 'off'), ('debug_print_rewritten', 'off'), ('debug_print_plan', 'off')) d(name, def)
  LEFT JOIN LATERAL (SELECT x->>'value' AS value FROM jsonb_array_elements(coalesce(s.non_default_settings, '[]'::jsonb)) x
                      WHERE x->>'name' = d.name LIMIT 1) nd ON true;

-- One row per finding: instance_id, severity (critical / warning / info), setting, value, is_set, suggested,
-- platforms (where the rule applies: 'all', 'self-managed', 'not aurora', 'managed', 'replica'), detail, source
-- (pg_gather or pg-collector), at.
-- Two rule sets: pg_gather gather_report.sql's parameter recommendations, and awslabs pg-collector's observations
-- whose data pgvigil already collects (settings, database xid age, inactive slots). From pg_gather, the ones it ties to the host's memory, CPU, file system or the
-- workload it captured (shared_buffers, max_connections per CPU, max_wal_size against the WAL rate,
-- max_locks_per_transaction, bgwriter, log_temp_files, wal_init_zero / wal_recycle) are not here, and neither
-- are its global statement_timeout / lock_timeout / transaction_timeout suggestions (a global timeout is
-- set from measurement, never by default).
CREATE OR REPLACE VIEW pgvigil.findings AS
WITH v AS (
  SELECT instance_id, snapshot_at, platform, server_version_num, is_replica, name, value, is_set,
         CASE WHEN value ~ '^-?[0-9]+(\.[0-9]+)?$' THEN value::numeric END AS num
    FROM pgvigil.instance_settings
), r(instance_id, name, severity, suggested, platforms, detail, hit) AS (
  SELECT instance_id, name, 'critical', 'on', 'all', 'autovacuum is off: no dead-row cleanup and no anti-wraparound vacuum beyond the forced one',
         value <> 'on' FROM v WHERE name = 'autovacuum'
  UNION ALL SELECT instance_id, name, 'warning', '2', 'all', 'autovacuum_vacuum_cost_delay outside 2-20 ms: 0 (or -1, which takes vacuum_cost_delay, 0 by default) lets autovacuum saturate I/O, above 20 it crawls',
         num > 20 OR num = 0 OR num = -1 FROM v WHERE name = 'autovacuum_vacuum_cost_delay'
  UNION ALL SELECT instance_id, name, 'info', '3', 'self-managed', 'more autovacuum workers share one cost limit, so each runs slower',
         num > 3 AND platform = 'onprem' FROM v WHERE name = 'autovacuum_max_workers'
  UNION ALL SELECT instance_id, name, 'warning', '200000000', 'all', 'autovacuum_freeze_max_age above 800 million leaves little room before wraparound',
         num > 800000000 FROM v WHERE name = 'autovacuum_freeze_max_age'
  UNION ALL SELECT instance_id, name, 'warning', '0.9', 'not aurora', 'a low checkpoint_completion_target writes each checkpoint in a burst (I/O spikes)',
         num < 0.7 AND platform <> 'aurora' FROM v WHERE name = 'checkpoint_completion_target'
  UNION ALL SELECT instance_id, name, 'info', '1800', 'not aurora', 'checkpoints closer than 20 minutes apart: more full-page writes and WAL',
         num < 1200 AND platform <> 'aurora' FROM v WHERE name = 'checkpoint_timeout'
  UNION ALL SELECT instance_id, name, 'info', 'lz4', 'all', 'lz4 compresses TOAST faster than pglz',
         value <> 'lz4' AND server_version_num >= 140000 FROM v WHERE name = 'default_toast_compression'
  UNION ALL SELECT instance_id, name, 'info', 'on', 'self-managed', 'huge pages are not required: a large shared_buffers pays for its page tables in memory and TLB misses',
         value <> 'on' AND platform = 'onprem' FROM v WHERE name = 'huge_pages'
  UNION ALL SELECT instance_id, name, 'warning', '0', 'all', 'idle_session_timeout ends idle pooled connections the application still holds',
         num > 0 FROM v WHERE name = 'idle_session_timeout'
  UNION ALL SELECT instance_id, name, 'info', '5min', 'all', 'no limit on idle-in-transaction sessions: one forgotten transaction holds its locks and pins vacuum',
         num = 0 FROM v WHERE name = 'idle_in_transaction_session_timeout'
  UNION ALL SELECT instance_id, name, 'info', 'off', 'all', 'JIT on globally: short OLTP statements pay compile time; enable it per session for analytics',
         value = 'on' FROM v WHERE name = 'jit'
  UNION ALL SELECT instance_id, name, 'info', 'off', 'all', 'log_hostname makes a DNS lookup per connection',
         value = 'on' FROM v WHERE name = 'log_hostname'
  UNION ALL SELECT instance_id, name, 'info', 'on', 'all', 'lock waits past deadlock_timeout are not logged: blocking leaves no trace in the log',
         value = 'off' FROM v WHERE name = 'log_lock_waits'
  UNION ALL SELECT instance_id, name, 'info', '500', 'self-managed', 'more than 500 connections: use a pooler; every backend costs memory and snapshot work',
         num > 500 AND platform = 'onprem' FROM v WHERE name = 'max_connections'
  UNION ALL SELECT instance_id, name, 'warning', '30000', 'replica', 'under 30 s: queries on the standby are cancelled by replay conflicts',
         num >= 0 AND num < 30000 AND is_replica FROM v WHERE name IN ('max_standby_streaming_delay', 'max_standby_archive_delay')
  UNION ALL SELECT instance_id, name, 'info', '30000', 'replica', 'over 5 min (or -1, unlimited): a long standby query holds replay back and the standby lags',
         (num > 300000 OR num = -1) AND is_replica FROM v WHERE name IN ('max_standby_streaming_delay', 'max_standby_archive_delay')
  UNION ALL SELECT instance_id, name, 'info', '8192', 'not aurora', 'max_wal_size under 8 GB: checkpoints forced by WAL volume under load',
         num < 8192 AND platform <> 'aurora' FROM v WHERE name = 'max_wal_size'
  UNION ALL SELECT instance_id, name, 'info', '2048', 'not aurora', 'min_wal_size under 2 GB: WAL segments removed and re-created between bursts',
         num < 2048 AND platform <> 'aurora' FROM v WHERE name = 'min_wal_size'
  UNION ALL SELECT instance_id, name, 'info', '1.1', 'managed', 'managed storage is SSD-backed: random reads cost about what sequential ones do',
         num > 1.2 AND platform <> 'onprem' FROM v WHERE name = 'random_page_cost'
  UNION ALL SELECT instance_id, name, 'warning', '1', 'all', 'seq_page_cost is the unit every other cost is relative to; change random_page_cost instead',
         num <> 1 FROM v WHERE name = 'seq_page_cost'
  UNION ALL SELECT v.instance_id, v.name, 'warning', 'local', 'all', 'synchronous_standby_names is set with synchronous_commit on / remote_write / remote_apply: every commit waits for a standby (hangs when it is gone)',
         v.value <> '' AND c.value IN ('on', 'remote_write', 'remote_apply') FROM v JOIN v c ON c.instance_id = v.instance_id AND c.name = 'synchronous_commit'
   WHERE v.name = 'synchronous_standby_names'
  UNION ALL SELECT instance_id, name, 'info', 'on', 'all', 'without I/O timing, statement and database read times are not measured',
         value = 'off' FROM v WHERE name = 'track_io_timing'
  UNION ALL SELECT instance_id, name, 'info', CASE WHEN server_version_num >= 150000 THEN 'lz4' ELSE 'on' END, 'not aurora',
         'full-page images go to WAL uncompressed', value = 'off' AND platform <> 'aurora' FROM v WHERE name = 'wal_compression'
  UNION ALL SELECT instance_id, name, 'info', 'fdatasync', 'self-managed', 'fdatasync or open_datasync is the safe and fast choice on Linux',
         value NOT IN ('fdatasync', 'open_datasync') AND platform = 'onprem' FROM v WHERE name = 'wal_sync_method'
  UNION ALL SELECT instance_id, name, 'warning', '60000', 'all', 'wal_sender_timeout 0: a dead standby connection is never noticed',
         num = 0 FROM v WHERE name = 'wal_sender_timeout'
  UNION ALL SELECT instance_id, name, 'warning', '65536', 'all', 'a global work_mem above 96 MB is multiplied by every sort and hash of every session',
         num > 98304 FROM v WHERE name = 'work_mem'
  UNION ALL SELECT instance_id, name, 'critical', 'off', 'all', 'zero_damaged_pages hides corruption by zeroing the damaged page (silent data loss)',
         value = 'on' FROM v WHERE name = 'zero_damaged_pages'
), c(instance_id, name, severity, suggested, platforms, detail, hit) AS (
  -- pg-collector's observations on settings (its autovacuum-off one is pg_gather's above)
  SELECT instance_id, name, 'critical', 'on', 'all', 'track_counts is off: autovacuum cannot see which tables need it and pg_stat_* stay empty',
         value <> 'on' FROM v WHERE name = 'track_counts'
  UNION ALL SELECT instance_id, name, 'warning', 'on', 'all', 'a planner method is switched off for every session: plans that need it degrade',
         value <> 'on' FROM v WHERE name IN ('enable_indexscan', 'enable_indexonlyscan')
  UNION ALL SELECT instance_id, name, 'warning', 'on', 'all', 'synchronous_commit off: the last commits are lost on a crash',
         value = 'off' FROM v WHERE name = 'synchronous_commit'
  UNION ALL SELECT instance_id, name, 'warning', 'none', 'all', 'log_statement all / mod logs every statement or every write: log volume and I/O',
         value IN ('all', 'mod') FROM v WHERE name = 'log_statement'
  UNION ALL SELECT instance_id, name, 'warning', '-1', 'all', 'log_min_duration_statement 0 logs every statement with its duration',
         num = 0 FROM v WHERE name = 'log_min_duration_statement'
  UNION ALL SELECT instance_id, name, 'warning', 'warning', 'all', 'a debug log level writes internal detail for every operation',
         value LIKE 'debug%' FROM v WHERE name = 'log_min_messages'
  UNION ALL SELECT instance_id, name, 'warning', 'off', 'all', 'per-statement parser / planner / executor statistics or parse-tree dumps go to the log',
         value = 'on' FROM v WHERE name IN ('log_parser_stats', 'log_planner_stats', 'log_executor_stats', 'log_statement_stats',
                                            'debug_print_parse', 'debug_print_rewritten', 'debug_print_plan')
  UNION ALL SELECT instance_id, name, 'info', '200000000', 'all', 'autovacuum_freeze_max_age above the 200 million default: anti-wraparound vacuums start later and do more at once',
         num > 200000000 AND num <= 800000000 FROM v WHERE name = 'autovacuum_freeze_max_age'
)
SELECT DISTINCT ON (x.instance_id, x.setting, x.value, x.detail) x.*
  FROM (
    SELECT v.instance_id, r.severity, r.name AS setting, v.value, v.is_set, r.suggested, r.platforms, r.detail,
           'pg_gather' AS source, v.snapshot_at AS at
      FROM r JOIN v ON v.instance_id = r.instance_id AND v.name = r.name AND r.hit
    UNION ALL
    SELECT v.instance_id, c.severity, c.name, v.value, v.is_set, c.suggested, c.platforms, c.detail, 'pg-collector', v.snapshot_at
      FROM c JOIN v ON v.instance_id = c.instance_id AND v.name = c.name AND c.hit
    UNION ALL
    -- pg-collector: a database's frozen-xid age past 300 million (the databases collection's xid_age)
    SELECT d.instance_id, CASE WHEN d.xid_age >= 1000000000 THEN 'critical' ELSE 'warning' END, 'database xid age',
           d.datname || ': ' || d.xid_age::text, true, 'under 300000000', 'all',
           'the oldest unfrozen transaction in the database is over 300 million old: find what holds vacuum back (a long transaction, a slot, a prepared transaction)',
           'pg-collector', d.snapshot_at
      FROM pgvigil.databases d
     WHERE d.is_present AND NOT coalesce(d.is_template, false) AND d.xid_age >= 300000000
    UNION ALL
    -- pg-collector: an inactive replication slot (the replication collection's latest read)
    SELECT s.instance_id, 'warning', 'inactive replication slot', s.key, true, 'drop it or reconnect its consumer', 'all',
           'an inactive slot keeps WAL and, for a logical slot, the catalog xmin: disk fills and vacuum is held back',
           'pg-collector', s.snapshot_at
      FROM pgvigil.replication_latest s
     WHERE s.kind = 'slot' AND NOT coalesce(s.active, false) AND NOT coalesce((s.detail->>'synced')::boolean, false)
  ) x
 ORDER BY x.instance_id, x.setting, x.value, x.detail;

-- ---------------------------------------------------------------------------------------------------------
-- 4. statements
-- ---------------------------------------------------------------------------------------------------------

-- Top statements over a window by a chosen order (a pg_stat_statements top script: by time, by calls, by IO). Same window
-- scaling as top_statements. p_order: time (total execution), calls, io (shared blocks read + temp blocks read
-- and written), mean, rows, temp (temp blocks written), wal; anything else = time.
CREATE OR REPLACE FUNCTION pgvigil.top_statements_by(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                                     p_order text DEFAULT 'time', p_limit int DEFAULT 50)
RETURNS TABLE (queryid bigint, datname text, usename text, calls double precision, total_exec_ms double precision,
               mean_exec_ms double precision, rows double precision, shared_blks_read double precision,
               shared_blks_hit double precision, shared_blks_dirtied double precision, shared_blks_written double precision,
               temp_blks_read double precision, temp_blks_written double precision, io_blks double precision,
               blk_read_ms double precision, wal_bytes numeric, hit_pct numeric, query text)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT d.*,
           greatest(0, extract(epoch FROM least(d.snapshot_at, p_to) - greatest(d.snapshot_at - make_interval(secs => d.interval_secs), p_from)))
             / d.interval_secs AS share
      FROM pgvigil.statements_delta d
     WHERE d.instance_id = p_instance_id
       AND d.snapshot_at > p_from
       AND d.snapshot_at - make_interval(secs => d.interval_secs) < p_to
  ), a AS (
    SELECT d.queryid, min(d.datname) AS datname, min(d.usename) AS usename,
           sum(d.calls * d.share) AS calls, sum(d.total_exec_ms * d.share) AS total_exec_ms,
           sum(d.rows * d.share) AS rows, sum(d.shared_blks_read * d.share) AS shared_blks_read,
           sum(d.shared_blks_hit * d.share) AS shared_blks_hit, sum(d.shared_blks_dirtied * d.share) AS shared_blks_dirtied,
           sum(d.shared_blks_written * d.share) AS shared_blks_written, sum(d.temp_blks_read * d.share) AS temp_blks_read,
           sum(d.temp_blks_written * d.share) AS temp_blks_written, sum(d.blk_read_ms * d.share) AS blk_read_ms,
           sum(d.wal_bytes * d.share::numeric) AS wal_bytes
      FROM d WHERE d.share > 0
     GROUP BY d.queryid
  )
  SELECT a.queryid, a.datname, a.usename, a.calls, a.total_exec_ms, a.total_exec_ms / nullif(a.calls, 0), a.rows,
         a.shared_blks_read, a.shared_blks_hit, a.shared_blks_dirtied, a.shared_blks_written, a.temp_blks_read,
         a.temp_blks_written,
         coalesce(a.shared_blks_read, 0) + coalesce(a.temp_blks_read, 0) + coalesce(a.temp_blks_written, 0),
         a.blk_read_ms, a.wal_bytes,
         round((100 * a.shared_blks_hit / nullif(a.shared_blks_hit + a.shared_blks_read, 0))::numeric, 1),
         (SELECT t.query FROM pgvigil.statement_text t WHERE t.instance_id = p_instance_id AND t.queryid = a.queryid)
    FROM a
   ORDER BY CASE lower(coalesce(p_order, 'time'))
              WHEN 'calls' THEN a.calls
              WHEN 'io'    THEN coalesce(a.shared_blks_read, 0) + coalesce(a.temp_blks_read, 0) + coalesce(a.temp_blks_written, 0)
              WHEN 'mean'  THEN a.total_exec_ms / nullif(a.calls, 0)
              WHEN 'rows'  THEN a.rows
              WHEN 'temp'  THEN a.temp_blks_written
              WHEN 'wal'   THEN a.wal_bytes::float8
              ELSE a.total_exec_ms END DESC NULLS LAST, a.queryid
   LIMIT p_limit
$$;

-- "What ran long between 14:00 and 15:00" from the activity samples (an activity-history sampler's
-- activity_report): one row per execution seen in the window - a session (pid, backend_start) and its
-- statement (query_start) - with how long it had been running at the last sample that saw it. Sampled, so
-- the duration is a floor ("at least"): the statement ended between its last sample and the next. An idle-in-
-- transaction session is timed from its transaction start. p_min_secs drops the short ones.
CREATE OR REPLACE FUNCTION pgvigil.slow_in_window(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                                  p_min_secs int DEFAULT 5, p_limit int DEFAULT 100)
RETURNS TABLE (pid int, backend_start timestamptz, query_start timestamptz, first_seen timestamptz, last_seen timestamptz,
               samples bigint, at_least_secs int, state text, datname text, usename text, application_name text,
               top_wait text, was_blocked boolean, was_blocker boolean, query_id bigint, query text)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT s.*,
           extract(epoch FROM s.snapshot_at - CASE WHEN s.state = 'active' THEN s.query_start ELSE coalesce(s.xact_start, s.query_start) END) AS secs,
           coalesce(s.wait_event_type || ':' || s.wait_event, 'CPU / not waiting') AS wait
      FROM pgvigil.activity_sample s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at >= p_from AND s.snapshot_at <= p_to
       AND s.backend_type IS DISTINCT FROM 'autovacuum worker'
  ), e AS (
    SELECT s.pid, s.backend_start, s.query_start, min(s.snapshot_at) AS first_seen, max(s.snapshot_at) AS last_seen,
           count(*) AS samples, max(s.secs)::int AS at_least_secs,
           (array_agg(s.state ORDER BY s.snapshot_at DESC))[1] AS state,
           min(s.datname) AS datname, min(s.usename) AS usename, min(s.application_name) AS application_name,
           mode() WITHIN GROUP (ORDER BY s.wait) AS top_wait,
           bool_or(cardinality(s.blocking_pids) > 0) AS was_blocked, bool_or(s.is_blocker) AS was_blocker,
           max(s.query_id) AS query_id, (array_agg(s.query_hash ORDER BY s.snapshot_at DESC))[1] AS query_hash
      FROM s
     GROUP BY s.pid, s.backend_start, s.query_start
  )
  SELECT e.pid, e.backend_start, e.query_start, e.first_seen, e.last_seen, e.samples, e.at_least_secs, e.state, e.datname,
         e.usename, e.application_name, e.top_wait, e.was_blocked, e.was_blocker, e.query_id,
         (SELECT q.query FROM pgvigil.query_text q WHERE q.query_hash = e.query_hash)
    FROM e
   WHERE e.at_least_secs >= coalesce(p_min_secs, 0)
   ORDER BY e.at_least_secs DESC, e.first_seen
   LIMIT p_limit
$$;

-- ---------------------------------------------------------------------------------------------------------
-- retention: table_sizes partitions, and tables / table databases gone longer than the retention
-- ---------------------------------------------------------------------------------------------------------
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
       AND p.relname IN ('activity_sample', 'statements_delta', 'dbstats', 'serverstats', 'iostats', 'replication_sample', 'database_sizes',
                         'log_events', 'dms_task_sample', 'table_sizes')
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
  DELETE FROM pgvigil.dms_table_stats WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.dms_tasks WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.dms_instances WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- tables out of the top N (or dropped) and databases gone, for longer than the retention
  DELETE FROM pgvigil.tables WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.table_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  RETURN n;
END $$;
