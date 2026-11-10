-- 0074: SQL Server CPU, memory, file IO and the tempdb layout (the collections mssql_cpu, mssql_memory, mssql_fileio
-- and mssql_tempdb; internal/mssql/cpu.go, memory.go, fileio.go, tempdb.go).
--
-- mssql_cpu (every minute):
--   mssql_cpu_sample      one row per scheduler monitor record of the ring buffer (one a minute; snapshot_at = the
--                         record's own time in UTC): the SQL Server process's CPU %, the other processes', idle (both
--                         NULL on a Linux host, where the record's idle figure is always 0). A
--                         record is stored once (by its id and time: every run sends the whole buffer).
--   mssql_sched_sample    the schedulers at each read (runnable tasks, work queue, pending IO, workers against the
--                         limit) and the throughput counters' rates per second over the interval since the read
--                         before (batch requests, compilations, recompilations, transactions); a rate is NULL on the
--                         first read after a restart or a cleared counter.
-- mssql_memory (every minute):
--   mssql_memory_sample   the machine's and the process's memory, target / total / stolen server memory, the buffer
--                         pool, the plan cache, Page life expectancy, memory grants (granted, waiting, the largest and
--                         the summed grant), the memory model.
--   mssql_memory_clerk    the 25 largest memory clerk types at each read, and the rest as '(other)'.
-- mssql_fileio (every minute):
--   mssql_fileio_sample   per database file: the reads, bytes and read stall, the writes, bytes and write stall over
--                         the interval since the read before (the differences of sys.dm_io_virtual_file_stats).
--   mssql_fileio_last     the counters of the last read per file (where the next difference starts).
--   mssql_perf_counter_last  the same for mssql_cpu's cumulative counters.
-- mssql_tempdb (hourly):
--   mssql_tempdb          the current layout per instance: data and log files, sizes, growth, the CPU count, the
--                         recommended minimum of data files, the trace flags, memory-optimized metadata.
--   mssql_tempdb_files    tempdb's files as last read.
-- mssql_perf_findings     the slice's findings in the findings columns (the join adds the arm to pgvigil.findings).
--
-- Partition parents for purge() (the join adds them): mssql_cpu_sample, mssql_sched_sample, mssql_memory_sample,
-- mssql_memory_clerk, mssql_fileio_sample. Until that migration these tables are not purged.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_cpu_sample (
  instance_id  int NOT NULL,
  snapshot_at  timestamptz NOT NULL,          -- the record's time, UTC
  record_id    bigint NOT NULL,               -- the record's number since the server started
  sql_pct      smallint NOT NULL,
  other_pct    smallint,                      -- NULL = not read: SQL Server on Linux writes no idle figure (always 0)
  idle_pct     smallint
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_sched_sample (
  instance_id      int NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  schedulers       int,
  cpu_count        int,
  runnable_tasks   int,
  work_queue       int,
  pending_io       int,
  current_workers  int,
  active_workers   int,
  max_workers      int,
  batch_s          real,                      -- Batch Requests/sec over the interval
  compiles_s       real,
  recompiles_s     real,
  transactions_s   real,                      -- Databases _Total Transactions/sec
  interval_secs    real                       -- by the server's clock; NULL = no rate this read
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_perf_counter_last (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  counter       text NOT NULL,
  value         bigint NOT NULL,
  server_utc    timestamptz NOT NULL,
  server_start  timestamptz,
  PRIMARY KEY (instance_id, counter)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_memory_sample (
  instance_id          int NOT NULL,
  snapshot_at          timestamptz NOT NULL,
  physical_kb          bigint,
  available_kb         bigint,
  system_state         text,                  -- 'Available physical memory is high' ...
  process_kb           bigint,                -- the SQL Server process's working set
  process_low          boolean,
  committed_kb         bigint,
  committed_target_kb  bigint,
  target_kb            bigint,                -- Target Server Memory (KB)
  total_kb             bigint,                -- Total Server Memory (KB)
  stolen_kb            bigint,
  buffer_pool_kb       bigint,                -- Database Cache Memory (KB)
  plan_cache_kb        bigint,
  clerks_kb            bigint,
  ple                  bigint,                -- Page life expectancy, seconds
  grants_pending       int,                   -- Memory Grants Pending
  grants_outstanding   int,
  sem_granted          int,
  sem_waiting          int,
  sem_granted_kb       bigint,
  sem_target_kb        bigint,
  grants               int,
  grants_waiting       int,
  max_grant_kb         bigint,
  sum_grant_kb         bigint,
  max_requested_kb     bigint,
  memory_model         text
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_memory_clerk (
  instance_id      int NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  clerk_type       text NOT NULL,
  pages_kb         bigint NOT NULL,
  vm_committed_kb  bigint
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_fileio_sample (
  instance_id     int NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  database_id     int NOT NULL,
  file_id         int NOT NULL,
  database_name   text,
  file_name       text,
  type_desc       text,                       -- ROWS | LOG | FILESTREAM ...; NULL = not read (no VIEW ANY DEFINITION)
  reads           bigint NOT NULL,
  read_bytes      bigint NOT NULL,
  read_stall_ms   bigint NOT NULL,
  writes          bigint NOT NULL,
  write_bytes     bigint NOT NULL,
  write_stall_ms  bigint NOT NULL,
  interval_secs   real NOT NULL
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_fileio_last (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_id     int NOT NULL,
  file_id         int NOT NULL,
  database_name   text,
  file_name       text,
  type_desc       text,
  physical_name   text,
  reads           bigint NOT NULL,
  read_bytes      bigint NOT NULL,
  read_stall_ms   bigint NOT NULL,
  writes          bigint NOT NULL,
  write_bytes     bigint NOT NULL,
  write_stall_ms  bigint NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  server_utc      timestamptz NOT NULL,
  server_start    timestamptz,
  PRIMARY KEY (instance_id, database_id, file_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_tempdb (
  instance_id          int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at          timestamptz NOT NULL,
  major                int,
  cpu_count            int,                   -- NULL = not read (no VIEW SERVER STATE)
  data_files           int NOT NULL,
  log_files            int NOT NULL,
  recommended_files    int,                   -- Microsoft's starting point: the logical processors, eight at most
  insufficient_files   boolean,               -- NULL = the CPU count was not read
  even_size            boolean NOT NULL,
  even_growth          boolean NOT NULL,
  data_bytes           bigint,
  log_bytes            bigint,
  min_file_bytes       bigint,
  max_file_bytes       bigint,
  max_growth_bytes     bigint,
  max_growth_pct       int,
  max_log_growth_bytes bigint,
  max_log_growth_pct   int,
  volumes              text,
  tf1117               boolean,
  tf1118               boolean,
  flags_required       boolean NOT NULL,      -- before SQL Server 2016 (13.x) trace flags 1117 and 1118 shape tempdb (the collector says)
  memopt_metadata      boolean                -- NULL = the feature does not exist there (before SQL Server 2019; Managed Instance)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_tempdb_files (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  file_id         int NOT NULL,
  file_name       text,
  type_desc       text,
  physical_name   text,
  size_bytes      bigint,
  max_size_bytes  bigint,
  growth_bytes    bigint,
  growth_pct      int,
  volume          text,
  snapshot_at     timestamptz NOT NULL,
  PRIMARY KEY (instance_id, file_id)
);

-- the server's clock and start time of a payload's state row, and whether a read before it of the same run of the
-- server lets a difference be taken (the start time moves by a minute's rounding at most, or by an hour at a
-- daylight-saving change: the start time is moved to UTC by the server's offset at the read)
CREATE OR REPLACE FUNCTION pgvigil.mssql_same_run(p_prev_start timestamptz, p_start timestamptz)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_prev_start IS NULL OR p_start IS NULL OR abs(extract(epoch FROM p_start - p_prev_start)) < 120
         OR abs(abs(extract(epoch FROM p_start - p_prev_start)) - 3600) < 120
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_perf_check(p_fn text, p_instance_id int, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_s jsonb;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION '%: instance % is not a SQL Server instance', p_fn, p_instance_id;
  END IF;
  SELECT r INTO v_s FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'state' LIMIT 1;
  IF v_s IS NULL OR v_s->>'server_utc' IS NULL THEN
    RAISE EXCEPTION '%: the payload has no state row with the server''s time', p_fn;
  END IF;
  RETURN v_s;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_cpu(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s      jsonb := pgvigil.mssql_perf_check('import_mssql_cpu', p_instance_id, p_payload);
  v_now    timestamptz := (v_s->>'server_utc')::timestamptz;
  v_start  timestamptz := (v_s->>'server_start')::timestamptz;
  v_month  timestamptz;
  v_secs   real;
  v_rates  jsonb := '{}';
  v_late   boolean;
  v_sched  jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_cpu'), p_instance_id);
  -- the parents in name order, the order purge() drops in (0067's lock-order note), before anything is written
  FOR v_month IN SELECT DISTINCT date_trunc('month', (r->>'sample_at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
                   FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cpu' AND r->>'sample_at' IS NOT NULL LOOP
    PERFORM pgvigil.ensure_month_partition('mssql_cpu_sample', v_month);
  END LOOP;
  PERFORM pgvigil.ensure_month_partition('mssql_sched_sample', p_snapshot_at);
  LOCK TABLE ONLY pgvigil.mssql_cpu_sample, ONLY pgvigil.mssql_sched_sample IN ROW EXCLUSIVE MODE;

  -- a record is stored once: the same id within two minutes of a stored one is that record read again (its time is
  -- computed from the tick count at each read and moves by milliseconds); a restart starts the ids again, hours apart
  INSERT INTO pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct, other_pct, idle_pct)
  SELECT p_instance_id, x.at, x.record_id, x.sql_pct, x.other_pct, x.idle_pct
    FROM (SELECT DISTINCT ON ((r->>'record_id')::bigint) (r->>'sample_at')::timestamptz AS at, (r->>'record_id')::bigint AS record_id,
                 -- clamped to 0..100; least() and greatest() skip a NULL, so a figure not read stays NULL by the CASE
                 least(greatest((r->>'sql_pct')::int, 0), 100) AS sql_pct,
                 CASE WHEN r->>'other_pct' IS NOT NULL THEN least(greatest((r->>'other_pct')::int, 0), 100) END AS other_pct,
                 CASE WHEN r->>'idle_pct' IS NOT NULL THEN least(greatest((r->>'idle_pct')::int, 0), 100) END AS idle_pct
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'cpu' AND r->>'record_id' IS NOT NULL AND r->>'sample_at' IS NOT NULL
             AND r->>'sql_pct' IS NOT NULL
           ORDER BY (r->>'record_id')::bigint) x
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_cpu_sample c
                      WHERE c.instance_id = p_instance_id AND c.record_id = x.record_id
                        AND c.snapshot_at BETWEEN x.at - interval '2 minutes' AND x.at + interval '2 minutes');

  -- the counters' rates: a read before this one of the same run of the server, every counter grown or equal
  SELECT bool_or(l.server_utc >= v_now) INTO v_late FROM pgvigil.mssql_perf_counter_last l WHERE l.instance_id = p_instance_id;
  IF coalesce(v_late, false) THEN
    RETURN;  -- an older read arriving late: the counters stored are newer, and its schedulers row would be out of order
  END IF;
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_perf_counter_last l WHERE l.instance_id = p_instance_id)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_perf_counter_last l WHERE l.instance_id = p_instance_id AND NOT pgvigil.mssql_same_run(l.server_start, v_start))
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                       JOIN pgvigil.mssql_perf_counter_last l ON l.instance_id = p_instance_id AND l.counter = r->>'counter'
                      WHERE r->>'kind' = 'counter' AND (r->>'value')::bigint < l.value) THEN
    SELECT extract(epoch FROM v_now - max(l.server_utc)) INTO v_secs FROM pgvigil.mssql_perf_counter_last l WHERE l.instance_id = p_instance_id;
    IF v_secs > 0 THEN
      SELECT coalesce(jsonb_object_agg(r->>'counter', round((((r->>'value')::bigint - l.value) / v_secs)::numeric, 3)), '{}')
        INTO v_rates
        FROM jsonb_array_elements(p_payload) r
        JOIN pgvigil.mssql_perf_counter_last l ON l.instance_id = p_instance_id AND l.counter = r->>'counter'
       WHERE r->>'kind' = 'counter';
    ELSE
      v_secs := NULL;
    END IF;
  ELSE
    DELETE FROM pgvigil.mssql_perf_counter_last WHERE instance_id = p_instance_id;
  END IF;
  INSERT INTO pgvigil.mssql_perf_counter_last AS l (instance_id, counter, value, server_utc, server_start)
  SELECT DISTINCT ON (r->>'counter') p_instance_id, r->>'counter', (r->>'value')::bigint, v_now, v_start
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'counter' AND r->>'counter' IS NOT NULL AND r->>'value' IS NOT NULL
  ON CONFLICT (instance_id, counter) DO UPDATE SET value = EXCLUDED.value, server_utc = EXCLUDED.server_utc, server_start = EXCLUDED.server_start;

  SELECT r INTO v_sched FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'sched' LIMIT 1;
  -- a payload imported twice at one snapshot time leaves one row
  DELETE FROM pgvigil.mssql_sched_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_sched_sample (instance_id, snapshot_at, schedulers, cpu_count, runnable_tasks, work_queue, pending_io,
      current_workers, active_workers, max_workers, batch_s, compiles_s, recompiles_s, transactions_s, interval_secs)
  VALUES (p_instance_id, p_snapshot_at, (v_sched->>'schedulers')::int, (v_sched->>'cpu_count')::int, (v_sched->>'runnable_tasks')::int,
          (v_sched->>'work_queue')::int, (v_sched->>'pending_io')::int, (v_sched->>'current_workers')::int,
          (v_sched->>'active_workers')::int, (v_sched->>'max_workers')::int,
          (v_rates->>'Batch Requests/sec')::real, (v_rates->>'SQL Compilations/sec')::real,
          (v_rates->>'SQL Re-Compilations/sec')::real, (v_rates->>'Transactions/sec')::real, v_secs);
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_memory(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_m  jsonb;
  v_g  jsonb;
  v_t  jsonb;
  v_c  jsonb;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_memory: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  SELECT r INTO v_m FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'memory' LIMIT 1;
  IF v_m IS NULL THEN
    RAISE EXCEPTION 'import_mssql_memory: the payload has no memory row';
  END IF;
  SELECT r INTO v_g FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'grants' LIMIT 1;
  SELECT r INTO v_t FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'clerks' LIMIT 1;
  SELECT coalesce(jsonb_object_agg(r->>'counter', (r->>'value')::bigint), '{}') INTO v_c
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'counter' AND r->>'counter' IS NOT NULL;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_memory'), p_instance_id);
  PERFORM pgvigil.ensure_month_partition('mssql_memory_clerk', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_memory_sample', p_snapshot_at);
  LOCK TABLE ONLY pgvigil.mssql_memory_clerk, ONLY pgvigil.mssql_memory_sample IN ROW EXCLUSIVE MODE;

  DELETE FROM pgvigil.mssql_memory_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_memory_sample (instance_id, snapshot_at, physical_kb, available_kb, system_state, process_kb, process_low,
      committed_kb, committed_target_kb, target_kb, total_kb, stolen_kb, buffer_pool_kb, plan_cache_kb, clerks_kb, ple,
      grants_pending, grants_outstanding, sem_granted, sem_waiting, sem_granted_kb, sem_target_kb, grants, grants_waiting,
      max_grant_kb, sum_grant_kb, max_requested_kb, memory_model)
  VALUES (p_instance_id, p_snapshot_at, (v_m->>'physical_kb')::bigint, (v_m->>'available_kb')::bigint, v_m->>'system_state',
          (v_m->>'process_kb')::bigint, ((v_m->>'process_low')::int = 1), (v_m->>'committed_kb')::bigint, (v_m->>'committed_target_kb')::bigint,
          (v_c->>'Target Server Memory (KB)')::bigint, (v_c->>'Total Server Memory (KB)')::bigint, (v_c->>'Stolen Server Memory (KB)')::bigint,
          (v_c->>'Database Cache Memory (KB)')::bigint, (v_t->>'plan_cache_kb')::bigint, (v_t->>'clerks_kb')::bigint,
          (v_c->>'Page life expectancy')::bigint, (v_c->>'Memory Grants Pending')::int, (v_c->>'Memory Grants Outstanding')::int,
          (v_g->>'sem_granted')::int, (v_g->>'sem_waiting')::int, (v_g->>'sem_granted_kb')::bigint, (v_g->>'sem_target_kb')::bigint,
          (v_g->>'grants')::int, (v_g->>'grants_waiting')::int, (v_g->>'max_grant_kb')::bigint, (v_g->>'sum_grant_kb')::bigint,
          (v_g->>'max_requested_kb')::bigint, v_m->>'memory_model');

  DELETE FROM pgvigil.mssql_memory_clerk WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  INSERT INTO pgvigil.mssql_memory_clerk (instance_id, snapshot_at, clerk_type, pages_kb, vm_committed_kb)
  SELECT p_instance_id, p_snapshot_at, x.clerk_type, x.pages_kb, x.vm_committed_kb
    FROM (SELECT DISTINCT ON (r->>'clerk_type') r->>'clerk_type' AS clerk_type, (r->>'pages_kb')::bigint AS pages_kb,
                 (r->>'vm_committed_kb')::bigint AS vm_committed_kb
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'clerk' AND r->>'clerk_type' IS NOT NULL AND r->>'pages_kb' IS NOT NULL) x;
  -- the clerks past the 25 listed, as one row: the listed ones and this add up to the total
  INSERT INTO pgvigil.mssql_memory_clerk (instance_id, snapshot_at, clerk_type, pages_kb)
  SELECT p_instance_id, p_snapshot_at, '(other)', (v_t->>'clerks_kb')::bigint - sum(c.pages_kb)
    FROM pgvigil.mssql_memory_clerk c
   WHERE c.instance_id = p_instance_id AND c.snapshot_at = p_snapshot_at AND v_t->>'clerks_kb' IS NOT NULL
  HAVING (v_t->>'clerks_kb')::bigint - sum(c.pages_kb) > 0;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_fileio(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s      jsonb := pgvigil.mssql_perf_check('import_mssql_fileio', p_instance_id, p_payload);
  v_now    timestamptz := (v_s->>'server_utc')::timestamptz;
  v_start  timestamptz := (v_s->>'server_start')::timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_fileio'), p_instance_id);
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_fileio_last l WHERE l.instance_id = p_instance_id AND (l.server_utc >= v_now OR l.snapshot_at >= p_snapshot_at)) THEN
    RETURN;  -- an older read arriving late (or the same read again): the counters stored are newer
  END IF;
  -- a restart: the old counters mean nothing
  DELETE FROM pgvigil.mssql_fileio_last l WHERE l.instance_id = p_instance_id AND NOT pgvigil.mssql_same_run(l.server_start, v_start);
  PERFORM pgvigil.ensure_month_partition('mssql_fileio_sample', p_snapshot_at);
  -- a file's difference: a read of it before this one, every counter grown or equal, and some IO in the interval
  INSERT INTO pgvigil.mssql_fileio_sample (instance_id, snapshot_at, database_id, file_id, database_name, file_name, type_desc,
      reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, interval_secs)
  SELECT p_instance_id, p_snapshot_at, f.database_id, f.file_id, f.database_name, f.file_name, f.type_desc,
         f.reads - l.reads, f.read_bytes - l.read_bytes, f.read_stall_ms - l.read_stall_ms,
         f.writes - l.writes, f.write_bytes - l.write_bytes, f.write_stall_ms - l.write_stall_ms,
         extract(epoch FROM v_now - l.server_utc)
    FROM (SELECT DISTINCT ON ((r->>'database_id')::int, (r->>'file_id')::int)
                 (r->>'database_id')::int AS database_id, (r->>'file_id')::int AS file_id, r->>'database_name' AS database_name,
                 r->>'file_name' AS file_name, r->>'type_desc' AS type_desc,
                 (r->>'reads')::bigint AS reads, (r->>'read_bytes')::bigint AS read_bytes, (r->>'read_stall_ms')::bigint AS read_stall_ms,
                 (r->>'writes')::bigint AS writes, (r->>'write_bytes')::bigint AS write_bytes, (r->>'write_stall_ms')::bigint AS write_stall_ms
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'file' AND r->>'database_id' IS NOT NULL AND r->>'file_id' IS NOT NULL AND r->>'reads' IS NOT NULL) f
    JOIN pgvigil.mssql_fileio_last l ON l.instance_id = p_instance_id AND l.database_id = f.database_id AND l.file_id = f.file_id
   WHERE f.reads >= l.reads AND f.read_bytes >= l.read_bytes AND f.read_stall_ms >= l.read_stall_ms
     AND f.writes >= l.writes AND f.write_bytes >= l.write_bytes AND f.write_stall_ms >= l.write_stall_ms
     AND (f.reads > l.reads OR f.writes > l.writes)
     AND v_now > l.server_utc;

  INSERT INTO pgvigil.mssql_fileio_last AS l (instance_id, database_id, file_id, database_name, file_name, type_desc, physical_name,
      reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, snapshot_at, server_utc, server_start)
  SELECT DISTINCT ON ((r->>'database_id')::int, (r->>'file_id')::int) p_instance_id, (r->>'database_id')::int, (r->>'file_id')::int,
         r->>'database_name', r->>'file_name', r->>'type_desc', r->>'physical_name',
         (r->>'reads')::bigint, (r->>'read_bytes')::bigint, (r->>'read_stall_ms')::bigint,
         (r->>'writes')::bigint, (r->>'write_bytes')::bigint, (r->>'write_stall_ms')::bigint, p_snapshot_at, v_now, v_start
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'file' AND r->>'database_id' IS NOT NULL AND r->>'file_id' IS NOT NULL AND r->>'reads' IS NOT NULL
  ON CONFLICT (instance_id, database_id, file_id) DO UPDATE SET
      database_name = EXCLUDED.database_name, file_name = EXCLUDED.file_name, type_desc = EXCLUDED.type_desc,
      physical_name = EXCLUDED.physical_name, reads = EXCLUDED.reads, read_bytes = EXCLUDED.read_bytes,
      read_stall_ms = EXCLUDED.read_stall_ms, writes = EXCLUDED.writes, write_bytes = EXCLUDED.write_bytes,
      write_stall_ms = EXCLUDED.write_stall_ms, snapshot_at = EXCLUDED.snapshot_at, server_utc = EXCLUDED.server_utc,
      server_start = EXCLUDED.server_start;
  -- a file the server no longer lists (a dropped database) leaves the state
  DELETE FROM pgvigil.mssql_fileio_last l WHERE l.instance_id = p_instance_id AND l.snapshot_at < p_snapshot_at;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_tempdb(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s jsonb;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_tempdb: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  SELECT r INTO v_s FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'server' LIMIT 1;
  IF v_s IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'file' AND r->>'type_desc' = 'ROWS') THEN
    RAISE EXCEPTION 'import_mssql_tempdb: the payload has no server row or no data file';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_tempdb'), p_instance_id);
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_tempdb t WHERE t.instance_id = p_instance_id AND t.snapshot_at > p_snapshot_at) THEN
    RETURN;  -- an older read arriving late
  END IF;
  DELETE FROM pgvigil.mssql_tempdb_files WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_tempdb_files (instance_id, file_id, file_name, type_desc, physical_name, size_bytes, max_size_bytes,
      growth_bytes, growth_pct, volume, snapshot_at)
  SELECT DISTINCT ON ((r->>'file_id')::int) p_instance_id, (r->>'file_id')::int, r->>'file_name', r->>'type_desc', r->>'physical_name',
         (r->>'size_bytes')::bigint, (r->>'max_size_bytes')::bigint, (r->>'growth_bytes')::bigint, (r->>'growth_pct')::int,
         r->>'volume', p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'file' AND r->>'file_id' IS NOT NULL;

  INSERT INTO pgvigil.mssql_tempdb AS t (instance_id, snapshot_at, major, cpu_count, data_files, log_files, recommended_files,
      insufficient_files, even_size, even_growth, data_bytes, log_bytes, min_file_bytes, max_file_bytes, max_growth_bytes,
      max_growth_pct, max_log_growth_bytes, max_log_growth_pct, volumes, tf1117, tf1118, flags_required, memopt_metadata)
  SELECT p_instance_id, p_snapshot_at, (v_s->>'major')::int, (v_s->>'cpu_count')::int,
         count(*) FILTER (WHERE f.type_desc = 'ROWS'), count(*) FILTER (WHERE f.type_desc = 'LOG'),
         -- least() skips a NULL: an unread CPU count must give no recommendation, not eight
         CASE WHEN v_s->>'cpu_count' IS NOT NULL THEN least((v_s->>'cpu_count')::int, 8) END,
         CASE WHEN v_s->>'cpu_count' IS NOT NULL THEN count(*) FILTER (WHERE f.type_desc = 'ROWS') < least((v_s->>'cpu_count')::int, 8) END,
         coalesce(min(f.size_bytes) FILTER (WHERE f.type_desc = 'ROWS') = max(f.size_bytes) FILTER (WHERE f.type_desc = 'ROWS'), true),
         coalesce(count(DISTINCT (f.growth_bytes, f.growth_pct)) FILTER (WHERE f.type_desc = 'ROWS') <= 1, true),
         sum(f.size_bytes) FILTER (WHERE f.type_desc = 'ROWS'), sum(f.size_bytes) FILTER (WHERE f.type_desc = 'LOG'),
         min(f.size_bytes) FILTER (WHERE f.type_desc = 'ROWS'), max(f.size_bytes) FILTER (WHERE f.type_desc = 'ROWS'),
         max(f.growth_bytes) FILTER (WHERE f.type_desc = 'ROWS'), max(f.growth_pct) FILTER (WHERE f.type_desc = 'ROWS'),
         max(f.growth_bytes) FILTER (WHERE f.type_desc = 'LOG'), max(f.growth_pct) FILTER (WHERE f.type_desc = 'LOG'),
         string_agg(DISTINCT f.volume, ', '),
         (v_s->>'tf1117')::int = 1, (v_s->>'tf1118')::int = 1,
         coalesce((v_s->>'flags_required')::int = 1, false),
         (v_s->>'memopt_metadata')::int = 1
    FROM pgvigil.mssql_tempdb_files f
   WHERE f.instance_id = p_instance_id
  ON CONFLICT (instance_id) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, major = EXCLUDED.major, cpu_count = EXCLUDED.cpu_count, data_files = EXCLUDED.data_files,
      log_files = EXCLUDED.log_files, recommended_files = EXCLUDED.recommended_files, insufficient_files = EXCLUDED.insufficient_files,
      even_size = EXCLUDED.even_size, even_growth = EXCLUDED.even_growth, data_bytes = EXCLUDED.data_bytes, log_bytes = EXCLUDED.log_bytes,
      min_file_bytes = EXCLUDED.min_file_bytes, max_file_bytes = EXCLUDED.max_file_bytes, max_growth_bytes = EXCLUDED.max_growth_bytes,
      max_growth_pct = EXCLUDED.max_growth_pct, max_log_growth_bytes = EXCLUDED.max_log_growth_bytes,
      max_log_growth_pct = EXCLUDED.max_log_growth_pct, volumes = EXCLUDED.volumes, tf1117 = EXCLUDED.tf1117, tf1118 = EXCLUDED.tf1118,
      flags_required = EXCLUDED.flags_required, memopt_metadata = EXCLUDED.memopt_metadata;
END $$;

-- The findings of the slice. A read older than three hours (tempdb) or fifteen minutes (the others) raises nothing:
-- the Collections page says the collection is stale.
--   tempdb: fewer data files than the recommended minimum (warning; Microsoft: as many as the logical processors up
--     to eight, then eight); data files of different sizes (warning: the proportional fill sends most allocations to
--     the largest); of different growth steps (warning: one growth makes them uneven); a data file growing by per
--     cent (info); before SQL Server 2016, trace flag 1117 or 1118 off (warning).
--   CPU: the machine's CPU at 90 % or more on average over the last 15 minutes of records, at least ten of them
--     (warning; 95 %: critical), with the SQL Server process's share named; on a Linux host (no idle figure) the
--     SQL Server process's own CPU.
--   Scheduler pressure: over the last 15 minutes of reads, at least ten, one runnable task or more per scheduler on
--     average (warning: work waits for a CPU), or tasks in the work queue in at least half the reads (warning:
--     tasks wait for a worker, the road to THREADPOOL).
--   Memory: the OS says available physical memory is low in the newest read (warning); memory grants waiting in
--     at least three of the last fifteen minutes' reads (warning).
--   File IO: over the last hour, a data file's reads at 50 ms or more on average with at least 1,000 reads
--     (warning; 100 ms: critical); a log file's writes at 20 ms or more with at least 1,000 writes (warning).
CREATE OR REPLACE VIEW pgvigil.mssql_perf_findings AS
SELECT t.instance_id, 'warning'::text AS severity, 'tempdb has fewer data files than recommended'::text AS check_name,
       'tempdb'::text AS object, t.snapshot_at AS at,
       format('%s data file(s) on %s logical processors: Microsoft''s starting point is %s (as many as the processors, eight at most; '
              || 'more by fours only while allocation contention stays).', t.data_files, t.cpu_count, t.recommended_files) AS detail
  FROM pgvigil.mssql_tempdb t
 WHERE t.insufficient_files AND t.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT t.instance_id, 'warning', 'tempdb data files differ in size', 'tempdb', t.snapshot_at,
       format('the data files run from %s to %s: SQL Server fills them in proportion to their free space, so the largest takes most '
              || 'allocations and the contention more files were meant to spread comes back.', pg_size_pretty(t.min_file_bytes), pg_size_pretty(t.max_file_bytes))
  FROM pgvigil.mssql_tempdb t
 WHERE NOT t.even_size AND t.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT t.instance_id, 'warning', 'tempdb data files differ in growth', 'tempdb', t.snapshot_at,
       'the data files grow by different steps: the next growth leaves them of different sizes.'
  FROM pgvigil.mssql_tempdb t
 WHERE NOT t.even_growth AND t.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT t.instance_id, 'info', 'a tempdb data file grows by per cent', 'tempdb: ' || coalesce(f.file_name, f.file_id::text), t.snapshot_at,
       format('%s grows by %s %% of its size (%s now): each growth is larger than the last; a fixed size is the usual choice.',
              coalesce(f.file_name, f.file_id::text), f.growth_pct, pg_size_pretty(f.size_bytes))
  FROM pgvigil.mssql_tempdb t
  JOIN pgvigil.mssql_tempdb_files f ON f.instance_id = t.instance_id
 WHERE f.type_desc = 'ROWS' AND f.growth_pct > 0 AND t.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT t.instance_id, 'warning', 'tempdb trace flags 1117 / 1118 off before SQL Server 2016', 'tempdb', t.snapshot_at,
       format('SQL Server %s: trace flag 1117 is %s and 1118 is %s. Before 2016 they make the data files grow together and allocate '
              || 'full extents; from 2016 this is tempdb''s default and the flags are no longer required.', t.major,
              CASE WHEN t.tf1117 THEN 'on' ELSE 'off' END, CASE WHEN t.tf1118 THEN 'on' ELSE 'off' END)
  FROM pgvigil.mssql_tempdb t
 WHERE t.flags_required AND (t.tf1117 IS FALSE OR t.tf1118 IS FALSE) AND t.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT c.instance_id, CASE WHEN c.cpu_avg >= 95 THEN 'critical' ELSE 'warning' END, 'CPU at 90 % or more', 'cpu', c.at,
       CASE WHEN c.machine
            THEN format('the machine''s CPU averaged %s %% over the last %s minute(s) (SQL Server %s %%, other processes %s %%, peak %s %%).',
                        round(c.cpu_avg, 1), c.n, round(c.sql_avg, 1), round(c.cpu_avg - c.sql_avg, 1), c.cpu_max)
            ELSE format('the SQL Server process''s CPU averaged %s %% over the last %s minute(s), peak %s %% (a Linux host: the other processes are not read).',
                        round(c.cpu_avg, 1), c.n, c.cpu_max) END
  FROM (SELECT s.instance_id, count(*) AS n, avg(coalesce(100 - s.idle_pct, s.sql_pct)) AS cpu_avg, avg(s.sql_pct) AS sql_avg,
               max(coalesce(100 - s.idle_pct, s.sql_pct)) AS cpu_max, bool_and(s.idle_pct IS NOT NULL) AS machine,
               max(s.snapshot_at) AS at
          FROM pgvigil.mssql_cpu_sample s
         WHERE s.snapshot_at > now() - interval '15 minutes'
         GROUP BY s.instance_id) c
 WHERE c.n >= 10 AND c.cpu_avg >= 90
UNION ALL
SELECT p.instance_id, 'warning', 'scheduler pressure', 'schedulers', p.at,
       CASE WHEN p.runnable_per_sched >= 1
            THEN format('%s runnable task(s) per scheduler on average over the last %s reads (%s schedulers): work is ready and waits for a CPU '
                        || '(SOS_SCHEDULER_YIELD and signal wait follow).', round(p.runnable_per_sched, 2), p.n, p.schedulers)
            ELSE format('tasks waited in the work queue in %s of the last %s reads (at most %s): they wait for a worker thread (%s of %s in use '
                        || 'at the newest read); THREADPOOL waits follow.', p.queued_reads, p.n, p.max_queue, p.workers, p.max_workers) END
  FROM (SELECT s.instance_id, count(*) AS n, avg(s.runnable_tasks::numeric / nullif(s.schedulers, 0)) AS runnable_per_sched,
               count(*) FILTER (WHERE s.work_queue > 0) AS queued_reads, max(s.work_queue) AS max_queue, max(s.snapshot_at) AS at,
               (array_agg(s.schedulers ORDER BY s.snapshot_at DESC))[1] AS schedulers,
               (array_agg(s.current_workers ORDER BY s.snapshot_at DESC))[1] AS workers,
               (array_agg(s.max_workers ORDER BY s.snapshot_at DESC))[1] AS max_workers
          FROM pgvigil.mssql_sched_sample s
         WHERE s.snapshot_at > now() - interval '15 minutes'
         GROUP BY s.instance_id) p
 WHERE p.n >= 10 AND (p.runnable_per_sched >= 1 OR p.queued_reads * 2 >= p.n)
UNION ALL
SELECT m.instance_id, 'warning', 'available physical memory is low', 'memory', m.snapshot_at,
       format('the OS says "%s": %s available of %s; the SQL Server process uses %s%s.', m.system_state, pg_size_pretty(m.available_kb * 1024),
              pg_size_pretty(m.physical_kb * 1024), pg_size_pretty(m.process_kb * 1024),
              CASE WHEN m.process_low THEN ' and has had a low-memory notification' ELSE '' END)
  FROM (SELECT DISTINCT ON (s.instance_id) s.* FROM pgvigil.mssql_memory_sample s
         WHERE s.snapshot_at > now() - interval '15 minutes' ORDER BY s.instance_id, s.snapshot_at DESC) m
 WHERE m.system_state ILIKE '%memory is low%'
UNION ALL
SELECT g.instance_id, 'warning', 'queries wait for memory grants', 'memory grants', g.at,
       format('queries waited for a memory grant in %s of the last %s reads (at most %s at once): RESOURCE_SEMAPHORE waits; '
              || 'the largest grant granted was %s.', g.waiting_reads, g.n, g.max_waiting, pg_size_pretty(g.max_grant_kb * 1024))
  FROM (SELECT s.instance_id, count(*) AS n, count(*) FILTER (WHERE greatest(s.grants_pending, s.grants_waiting, s.sem_waiting) > 0) AS waiting_reads,
               max(greatest(s.grants_pending, s.grants_waiting, s.sem_waiting)) AS max_waiting, max(s.max_grant_kb) AS max_grant_kb,
               max(s.snapshot_at) AS at
          FROM pgvigil.mssql_memory_sample s
         WHERE s.snapshot_at > now() - interval '15 minutes'
         GROUP BY s.instance_id) g
 WHERE g.waiting_reads >= 3
UNION ALL
SELECT f.instance_id, CASE WHEN f.type_desc = 'LOG' THEN 'warning' WHEN f.read_ms >= 100 THEN 'critical' ELSE 'warning' END,
       CASE WHEN f.type_desc = 'LOG' THEN 'slow log writes' ELSE 'slow data file reads' END,
       coalesce(f.database_name, 'database ' || f.database_id) || ': ' || coalesce(f.file_name, 'file ' || f.file_id), f.at,
       CASE WHEN f.type_desc = 'LOG'
            THEN format('the log file''s writes took %s ms on average over the last hour (%s writes): every commit waits for them (WRITELOG).',
                        round(f.write_ms, 1), f.writes)
            ELSE format('the data file''s reads took %s ms on average over the last hour (%s reads): PAGEIOLATCH waits follow.',
                        round(f.read_ms, 1), f.reads) END
  FROM (SELECT s.instance_id, s.database_id, s.file_id, max(s.database_name) AS database_name, max(s.file_name) AS file_name,
               max(s.type_desc) AS type_desc, sum(s.reads) AS reads, sum(s.writes) AS writes, max(s.snapshot_at) AS at,
               sum(s.read_stall_ms)::numeric / nullif(sum(s.reads), 0) AS read_ms,
               sum(s.write_stall_ms)::numeric / nullif(sum(s.writes), 0) AS write_ms
          FROM pgvigil.mssql_fileio_sample s
         WHERE s.snapshot_at > now() - interval '1 hour'
         GROUP BY s.instance_id, s.database_id, s.file_id) f
 WHERE (f.type_desc = 'LOG' AND f.writes >= 1000 AND f.write_ms >= 20)
    OR (f.type_desc IS DISTINCT FROM 'LOG' AND f.reads >= 1000 AND f.read_ms >= 50);
