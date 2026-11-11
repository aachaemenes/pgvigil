-- 0084: the SQL Server reads the pages still lacked (the collections mssql_properties, mssql_procstats and
-- mssql_indexlocks; internal/mssql/properties.go, procstats.go, indexlocks.go).
--
-- mssql_properties (hourly): what the instance is, one row per property, with the history of its changes.
--   mssql_property          the property as last read: its group, label, value and since when it has that value.
--   mssql_property_change   one row per change of a value between two reads (the first read sets, it changes nothing;
--                           a property the collector marks track = false, a size that moves by itself, is never logged).
--
-- mssql_procstats (every 5 minutes): sys.dm_exec_procedure_stats counts per cached plan since the plan was cached, so
-- the import keeps the last counters per plan (mssql_proc_last: the plan's handle and cached time; mssql_proc_state)
-- and stores what one interval added (mssql_proc_sample, summed per procedure; mssql_proc_read: every read's
-- seconds, an idle one too).
--
-- mssql_indexlocks (every 5 minutes): sys.dm_db_index_operational_stats counts per rowset of a partition since the
-- index's metadata entered the cache, so the import keeps the last counters per rowset (mssql_indexlock_last,
-- mssql_indexlock_state) and stores what one interval added, summed per index (mssql_indexlock_sample;
-- mssql_indexlock_read: every read's seconds).
--
-- The rule both differences follow, so no interval is ever negative: the first read of an instance only sets the
-- counters. After it, a counter set seen before and not lower than before gives now minus before; a set that went
-- DOWN (the cache dropped it and it counts again from zero) gives its whole count; a set the read before did not
-- list (a plan cached after it, an index that had no wait then, anything after a restart of the server) gives its
-- whole count: all of it happened after the read before. A set the server no longer lists leaves the state.
-- Two things keep 'the read before did not list it' honest:
--   capped   the collector cuts a very long list at its largest rows and says so in the state row. After a cut
--            read a set that is new to the state may only have been past the cut: an index then sets its counters
--            and gives nothing; a procedure plan gives its whole count only when it was cached at or after the cut
--            read's clock (cached_time and server_local are the server's own clock without a zone, as the DMV writes
--            the cached time), else nothing.
--   skipped  the index lock read goes database by database, and a database whose read failed (a schema change held
--            a lock) is named in the state row: its rowsets keep their state, so its next read takes the difference
--            from the last read that reached it and no wait is lost or counted twice.
-- Only counters that moved are rewritten in the state.
--
-- mssql_tempdb_page_kind names a tempdb page a request waits for a latch on: the fleet Running queries row counts
-- the tempdb page latch waits of a snapshot with it.
--
-- For the join: add mssql_indexlock_read, mssql_indexlock_sample, mssql_proc_read and mssql_proc_sample to purge()'s
-- month-partition parents and n := n + pgvigil.mssql_reads_purge(p_days) for the rest; put 'mssql_reads_purge' on
-- apply_roles()' owner-only list beside mssql_running_purge (it deletes; mssql_tempdb_page_kind stays with the
-- reader, the fleet Running queries page calls it).

CREATE TABLE IF NOT EXISTS pgvigil.mssql_property (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name         text NOT NULL,            -- the property's key: cpu_count, power_plan, max_memory_pct ...
  grp          text NOT NULL,            -- Server | Processor | Memory | TempDB | Host
  label        text NOT NULL,
  value        text,                     -- as read; a number is plain digits
  note         text,                     -- why the value was not read, or what it means
  ord          int NOT NULL DEFAULT 0,
  snapshot_at  timestamptz NOT NULL,     -- the last read that gave a value
  since        timestamptz NOT NULL,     -- the read that first saw this value
  seen_at      timestamptz NOT NULL,     -- the last read that listed the property, with a value or without
  PRIMARY KEY (instance_id, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_property_change (
  change_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name         text NOT NULL,
  label        text NOT NULL,
  old_value    text,
  new_value    text,
  changed_at   timestamptz NOT NULL      -- the read that saw the new value; the change happened since the read before
);
CREATE INDEX IF NOT EXISTS mssql_property_change_inst_idx ON pgvigil.mssql_property_change (instance_id, changed_at DESC);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_proc_state (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  server_utc    timestamptz NOT NULL,
  server_start  timestamptz,
  server_local  timestamp,               -- the server's own clock at the read, as the DMV's cached_time is written
  capped        boolean NOT NULL DEFAULT false   -- the read was cut at the collector's row limit: the state is not every plan
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_proc_last (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  plan_handle      text NOT NULL,          -- the cached plan, as 0x text: the server counts per plan
  cached_time      timestamp NOT NULL,     -- when the plan entered the cache, the server's own clock: a recompile is a new plan
  database_id      int NOT NULL,
  object_id        bigint NOT NULL,
  execution_count  bigint NOT NULL,
  worker_us        bigint NOT NULL,
  elapsed_us       bigint NOT NULL,
  logical_reads    bigint NOT NULL,
  physical_reads   bigint NOT NULL,
  logical_writes   bigint NOT NULL,
  PRIMARY KEY (instance_id, plan_handle, cached_time)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_proc_sample (
  instance_id     int NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  database_id     int NOT NULL,
  object_id       bigint NOT NULL,
  database_name   text,
  schema_name     text,                    -- NULL: the name was not read (the object is gone, or the read gave up on a lock)
  object_name     text,
  type_desc       text,
  executions      bigint NOT NULL,
  cpu_us          bigint NOT NULL,
  duration_us     bigint NOT NULL,
  logical_reads   bigint NOT NULL,
  physical_reads  bigint NOT NULL,
  logical_writes  bigint NOT NULL,
  interval_secs   real NOT NULL            -- between this read and the one before, by the server's own clock
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_proc_read (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  interval_secs  real NOT NULL,
  procs          int NOT NULL              -- the procedures that ran in the interval
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_indexlock_state (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  server_utc    timestamptz NOT NULL,
  server_start  timestamptz,
  capped        boolean NOT NULL DEFAULT false   -- the read was cut at the collector's row limit: the state is not every partition
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_indexlock_last (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_id          int NOT NULL,
  object_id            bigint NOT NULL,
  index_id             int NOT NULL,
  partition_number     int NOT NULL,
  hobt_id              bigint NOT NULL,    -- the rowset: a columnstore partition has several, and one can go while the others stay
  row_lock_waits       bigint NOT NULL,
  row_lock_wait_ms     bigint NOT NULL,
  page_lock_waits      bigint NOT NULL,
  page_lock_wait_ms    bigint NOT NULL,
  escalation_attempts  bigint NOT NULL,
  escalations          bigint NOT NULL,
  PRIMARY KEY (instance_id, database_id, object_id, index_id, partition_number, hobt_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_indexlock_sample (
  instance_id          int NOT NULL,
  snapshot_at          timestamptz NOT NULL,
  database_id          int NOT NULL,
  object_id            bigint NOT NULL,
  index_id             int NOT NULL,
  database_name        text,
  schema_name          text,               -- NULL with table_name and index_name: the database's catalog was not read
  table_name           text,
  index_name           text,               -- NULL on a heap
  index_type           text,               -- HEAP | CLUSTERED | NONCLUSTERED ...
  row_lock_waits       bigint NOT NULL,
  row_lock_wait_ms     bigint NOT NULL,
  page_lock_waits      bigint NOT NULL,
  page_lock_wait_ms    bigint NOT NULL,
  escalation_attempts  bigint NOT NULL,
  escalations          bigint NOT NULL,
  interval_secs        real NOT NULL
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_indexlock_read (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  interval_secs  real NOT NULL,
  indexes        int NOT NULL              -- the indexes with a lock wait or an escalation attempt in the interval
) PARTITION BY RANGE (snapshot_at);

-- payload: the 'property' rows {name, grp, label, value, note, ord, track}. A row without a value (not read this
-- time) keeps the stored value and takes the note; a value that differs from the stored VALUE writes a change row
-- (a property stored without a value yet is set, not changed), unless the row says track = false.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_properties(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_properties: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_properties'), p_instance_id);
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_property p WHERE p.instance_id = p_instance_id AND p.seen_at >= p_snapshot_at) THEN
    RETURN;  -- an older read arriving late, or the same read again (a read that gave no value counts too)
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_prop_in (name text PRIMARY KEY, grp text, label text, value text, note text, ord int, track boolean) ON COMMIT DROP;
  TRUNCATE pgv_mssql_prop_in;
  INSERT INTO pgv_mssql_prop_in
  SELECT DISTINCT ON (r->>'name') r->>'name', coalesce(r->>'grp', 'Server'), coalesce(r->>'label', r->>'name'),
         nullif(r->>'value', ''), r->>'note', coalesce((r->>'ord')::int, 0), coalesce((r->>'track')::boolean, true)
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'property' AND r->>'name' IS NOT NULL
   ORDER BY r->>'name';

  INSERT INTO pgvigil.mssql_property_change (instance_id, name, label, old_value, new_value, changed_at)
  SELECT p_instance_id, n.name, n.label, p.value, n.value, p_snapshot_at
    FROM pgv_mssql_prop_in n
    JOIN pgvigil.mssql_property p ON p.instance_id = p_instance_id AND p.name = n.name
   WHERE n.track AND n.value IS NOT NULL AND p.value IS NOT NULL AND p.value IS DISTINCT FROM n.value;

  INSERT INTO pgvigil.mssql_property AS p (instance_id, name, grp, label, value, note, ord, snapshot_at, since, seen_at)
  SELECT p_instance_id, n.name, n.grp, n.label, n.value, n.note, n.ord, p_snapshot_at, p_snapshot_at, p_snapshot_at
    FROM pgv_mssql_prop_in n
  ON CONFLICT (instance_id, name) DO UPDATE SET
      grp = EXCLUDED.grp, label = EXCLUDED.label, ord = EXCLUDED.ord, note = EXCLUDED.note, seen_at = EXCLUDED.seen_at,
      value = coalesce(EXCLUDED.value, p.value),
      snapshot_at = CASE WHEN EXCLUDED.value IS NULL THEN p.snapshot_at ELSE EXCLUDED.snapshot_at END,
      since = CASE WHEN EXCLUDED.value IS NULL OR p.value IS NOT DISTINCT FROM EXCLUDED.value THEN p.since ELSE EXCLUDED.since END;
END $$;

-- payload: one {kind:'state', server_utc, server_start, server_local, capped}; the 'proc' rows {plan_handle,
-- cached_time, database_id, object_id, database_name, schema_name, object_name, type_desc, execution_count, worker_us,
-- elapsed_us, logical_reads, physical_reads, logical_writes}: the server's cumulative counters per cached plan
-- (cached_time and server_local without a zone, in the server's own clock; capped: the list was cut at the
-- collector's row limit).
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_procstats(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s        jsonb := pgvigil.mssql_perf_check('import_mssql_procstats', p_instance_id, p_payload);
  v_now      timestamptz := (v_s->>'server_utc')::timestamptz;
  v_start    timestamptz := (v_s->>'server_start')::timestamptz;
  v_local    timestamp := (v_s->>'server_local')::timestamp;
  v_capped   boolean := coalesce((v_s->>'capped')::boolean, false);
  v_prev     pgvigil.mssql_proc_state;
  v_secs     real;
  v_restart  boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_procstats'), p_instance_id);
  SELECT * INTO v_prev FROM pgvigil.mssql_proc_state WHERE instance_id = p_instance_id;
  IF FOUND AND (v_prev.server_utc >= v_now OR v_prev.snapshot_at >= p_snapshot_at) THEN
    RETURN;  -- an older read arriving late (or the same read again): the counters stored are newer
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_proc_in (
    plan_handle text, cached_time timestamp, database_id int, object_id bigint, database_name text, schema_name text, object_name text,
    type_desc text, execution_count bigint, worker_us bigint, elapsed_us bigint, logical_reads bigint, physical_reads bigint,
    logical_writes bigint, PRIMARY KEY (plan_handle, cached_time)) ON COMMIT DROP;
  TRUNCATE pgv_mssql_proc_in;
  INSERT INTO pgv_mssql_proc_in
  SELECT DISTINCT ON (r->>'plan_handle', (r->>'cached_time')::timestamp)
         r->>'plan_handle', (r->>'cached_time')::timestamp, (r->>'database_id')::int, (r->>'object_id')::bigint, r->>'database_name',
         r->>'schema_name', r->>'object_name', r->>'type_desc', (r->>'execution_count')::bigint, coalesce((r->>'worker_us')::bigint, 0),
         coalesce((r->>'elapsed_us')::bigint, 0), coalesce((r->>'logical_reads')::bigint, 0), coalesce((r->>'physical_reads')::bigint, 0),
         coalesce((r->>'logical_writes')::bigint, 0)
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'proc' AND r->>'plan_handle' IS NOT NULL AND r->>'cached_time' IS NOT NULL AND r->>'database_id' IS NOT NULL
     AND r->>'object_id' IS NOT NULL AND r->>'execution_count' IS NOT NULL
   ORDER BY 1, 2;

  IF v_prev.instance_id IS NOT NULL AND v_now > v_prev.server_utc THEN
    v_secs := extract(epoch FROM v_now - v_prev.server_utc);
    v_restart := NOT pgvigil.mssql_same_run(v_prev.server_start, v_start);
    -- the parents in name order, the order purge() drops in (0067's lock-order note), before anything of this
    -- instance is written: purge() holds them while mssql_reads_purge deletes a stale instance's counters
    PERFORM pgvigil.ensure_month_partition('mssql_proc_read', p_snapshot_at);
    PERFORM pgvigil.ensure_month_partition('mssql_proc_sample', p_snapshot_at);
    LOCK TABLE ONLY pgvigil.mssql_proc_read, ONLY pgvigil.mssql_proc_sample IN ROW EXCLUSIVE MODE;
    -- a restart since the read before: every plan in the cache was cached after it, and the old counters mean nothing
    IF v_restart THEN
      DELETE FROM pgvigil.mssql_proc_last WHERE instance_id = p_instance_id;
    END IF;
    DELETE FROM pgvigil.mssql_proc_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    DELETE FROM pgvigil.mssql_proc_read WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name,
        type_desc, executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
    SELECT p_instance_id, p_snapshot_at, d.database_id, d.object_id, max(d.database_name), max(d.schema_name), max(d.object_name),
           max(d.type_desc), sum(d.executions), sum(d.cpu_us), sum(d.duration_us), sum(d.logical_reads), sum(d.physical_reads),
           sum(d.logical_writes), v_secs
      FROM (SELECT f.database_id, f.object_id, f.database_name, f.schema_name, f.object_name, f.type_desc,
                   CASE g.mode WHEN 'diff' THEN f.execution_count - l.execution_count WHEN 'whole' THEN f.execution_count ELSE 0 END AS executions,
                   CASE g.mode WHEN 'diff' THEN greatest(f.worker_us - l.worker_us, 0) WHEN 'whole' THEN f.worker_us ELSE 0 END AS cpu_us,
                   CASE g.mode WHEN 'diff' THEN greatest(f.elapsed_us - l.elapsed_us, 0) WHEN 'whole' THEN f.elapsed_us ELSE 0 END AS duration_us,
                   CASE g.mode WHEN 'diff' THEN greatest(f.logical_reads - l.logical_reads, 0) WHEN 'whole' THEN f.logical_reads ELSE 0 END AS logical_reads,
                   CASE g.mode WHEN 'diff' THEN greatest(f.physical_reads - l.physical_reads, 0) WHEN 'whole' THEN f.physical_reads ELSE 0 END AS physical_reads,
                   CASE g.mode WHEN 'diff' THEN greatest(f.logical_writes - l.logical_writes, 0) WHEN 'whole' THEN f.logical_writes ELSE 0 END AS logical_writes
              FROM pgv_mssql_proc_in f
              LEFT JOIN pgvigil.mssql_proc_last l ON l.instance_id = p_instance_id AND l.plan_handle = f.plan_handle
                                                 AND l.cached_time = f.cached_time
                   -- diff: the plan was in the read before and grew. whole: it counts lower than before (again from
                   -- zero); or it was not in the read before, and that read was complete (or the server restarted
                   -- since): the plan was cached after it; or that read was cut and the plan was cached at or after
                   -- its clock. none: not in a cut read although cached earlier: it only sets its counters.
             CROSS JOIN LATERAL (SELECT CASE WHEN l.instance_id IS NOT NULL AND f.execution_count >= l.execution_count THEN 'diff'
                                             WHEN l.instance_id IS NOT NULL OR v_restart OR NOT v_prev.capped THEN 'whole'
                                             WHEN f.cached_time >= v_prev.server_local THEN 'whole'
                                             ELSE 'none' END AS mode) g) d
     WHERE d.executions > 0
     GROUP BY d.database_id, d.object_id;
    INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs)
    SELECT p_instance_id, p_snapshot_at, v_secs,
           (SELECT count(*) FROM pgvigil.mssql_proc_sample s WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at);
  END IF;

  -- the state is this read's plans: one the cache dropped leaves it, and only counters that moved are rewritten
  DELETE FROM pgvigil.mssql_proc_last l
   WHERE l.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM pgv_mssql_proc_in f WHERE f.plan_handle = l.plan_handle AND f.cached_time = l.cached_time);
  INSERT INTO pgvigil.mssql_proc_last AS l (instance_id, plan_handle, cached_time, database_id, object_id, execution_count, worker_us,
      elapsed_us, logical_reads, physical_reads, logical_writes)
  SELECT p_instance_id, f.plan_handle, f.cached_time, f.database_id, f.object_id, f.execution_count, f.worker_us, f.elapsed_us,
         f.logical_reads, f.physical_reads, f.logical_writes
    FROM pgv_mssql_proc_in f
  ON CONFLICT (instance_id, plan_handle, cached_time) DO UPDATE SET
      execution_count = EXCLUDED.execution_count, worker_us = EXCLUDED.worker_us, elapsed_us = EXCLUDED.elapsed_us,
      logical_reads = EXCLUDED.logical_reads, physical_reads = EXCLUDED.physical_reads, logical_writes = EXCLUDED.logical_writes
   WHERE (l.execution_count, l.worker_us, l.elapsed_us, l.logical_reads, l.physical_reads, l.logical_writes)
         IS DISTINCT FROM (EXCLUDED.execution_count, EXCLUDED.worker_us, EXCLUDED.elapsed_us, EXCLUDED.logical_reads,
                           EXCLUDED.physical_reads, EXCLUDED.logical_writes);
  INSERT INTO pgvigil.mssql_proc_state AS s (instance_id, snapshot_at, server_utc, server_start, server_local, capped)
  VALUES (p_instance_id, p_snapshot_at, v_now, v_start, v_local, v_capped)
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, server_utc = EXCLUDED.server_utc,
      server_start = EXCLUDED.server_start, server_local = EXCLUDED.server_local, capped = EXCLUDED.capped;
END $$;

-- payload: one {kind:'state', server_utc, server_start, capped, skipped}; the 'index' rows {database_id, object_id,
-- index_id, partition_number, hobt_id, database_name, schema_name, table_name, index_name, index_type, row_lock_waits,
-- row_lock_wait_ms, page_lock_waits, page_lock_wait_ms, escalation_attempts, escalations}: the cumulative counters of
-- every rowset with a lock wait or an escalation attempt (capped: the list was cut at the collector's row limit;
-- skipped: the ids of the databases whose read failed this time).
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_indexlocks(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s        jsonb := pgvigil.mssql_perf_check('import_mssql_indexlocks', p_instance_id, p_payload);
  v_now      timestamptz := (v_s->>'server_utc')::timestamptz;
  v_start    timestamptz := (v_s->>'server_start')::timestamptz;
  v_capped   boolean := coalesce((v_s->>'capped')::boolean, false);
  v_skipped  int[];
  v_prev     pgvigil.mssql_indexlock_state;
  v_secs     real;
  v_whole    boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_indexlocks'), p_instance_id);
  SELECT * INTO v_prev FROM pgvigil.mssql_indexlock_state WHERE instance_id = p_instance_id;
  IF FOUND AND (v_prev.server_utc >= v_now OR v_prev.snapshot_at >= p_snapshot_at) THEN
    RETURN;  -- an older read arriving late (or the same read again)
  END IF;
  SELECT coalesce(array_agg(x.id::int), '{}') INTO v_skipped
    FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(v_s->'skipped') = 'array' THEN v_s->'skipped' ELSE '[]'::jsonb END) x(id);
  CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_ixl_in (
    database_id int, object_id bigint, index_id int, partition_number int, hobt_id bigint, database_name text, schema_name text,
    table_name text, index_name text, index_type text, row_lock_waits bigint, row_lock_wait_ms bigint, page_lock_waits bigint,
    page_lock_wait_ms bigint, escalation_attempts bigint, escalations bigint,
    PRIMARY KEY (database_id, object_id, index_id, partition_number, hobt_id)) ON COMMIT DROP;
  TRUNCATE pgv_mssql_ixl_in;
  INSERT INTO pgv_mssql_ixl_in
  SELECT DISTINCT ON ((r->>'database_id')::int, (r->>'object_id')::bigint, (r->>'index_id')::int, coalesce((r->>'partition_number')::int, 1),
                      coalesce((r->>'hobt_id')::bigint, 0))
         (r->>'database_id')::int, (r->>'object_id')::bigint, (r->>'index_id')::int, coalesce((r->>'partition_number')::int, 1),
         coalesce((r->>'hobt_id')::bigint, 0), r->>'database_name', r->>'schema_name', r->>'table_name', r->>'index_name', r->>'index_type',
         coalesce((r->>'row_lock_waits')::bigint, 0), coalesce((r->>'row_lock_wait_ms')::bigint, 0),
         coalesce((r->>'page_lock_waits')::bigint, 0), coalesce((r->>'page_lock_wait_ms')::bigint, 0),
         coalesce((r->>'escalation_attempts')::bigint, 0), coalesce((r->>'escalations')::bigint, 0)
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'index' AND r->>'database_id' IS NOT NULL AND r->>'object_id' IS NOT NULL AND r->>'index_id' IS NOT NULL
   ORDER BY 1, 2, 3, 4, 5;

  IF v_prev.instance_id IS NOT NULL AND v_now > v_prev.server_utc THEN
    v_secs := extract(epoch FROM v_now - v_prev.server_utc);
    -- a rowset the state does not hold counts whole: it had no wait at the last read that reached its database, or
    -- the server restarted since. Not when the read before was cut at the row limit: then it may have been past the
    -- cut, and it only sets its counters.
    v_whole := NOT v_prev.capped;
    PERFORM pgvigil.ensure_month_partition('mssql_indexlock_read', p_snapshot_at);
    PERFORM pgvigil.ensure_month_partition('mssql_indexlock_sample', p_snapshot_at);
    LOCK TABLE ONLY pgvigil.mssql_indexlock_read, ONLY pgvigil.mssql_indexlock_sample IN ROW EXCLUSIVE MODE;
    IF NOT pgvigil.mssql_same_run(v_prev.server_start, v_start) THEN
      DELETE FROM pgvigil.mssql_indexlock_last WHERE instance_id = p_instance_id;  -- a restart: everything counted since is new
      v_whole := true;
    END IF;
    DELETE FROM pgvigil.mssql_indexlock_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    DELETE FROM pgvigil.mssql_indexlock_read WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    INSERT INTO pgvigil.mssql_indexlock_sample (instance_id, snapshot_at, database_id, object_id, index_id, database_name, schema_name,
        table_name, index_name, index_type, row_lock_waits, row_lock_wait_ms, page_lock_waits, page_lock_wait_ms, escalation_attempts,
        escalations, interval_secs)
    SELECT p_instance_id, p_snapshot_at, d.database_id, d.object_id, d.index_id, max(d.database_name), max(d.schema_name), max(d.table_name),
           max(d.index_name), max(d.index_type), sum(d.row_lock_waits), sum(d.row_lock_wait_ms), sum(d.page_lock_waits),
           sum(d.page_lock_wait_ms), sum(d.escalation_attempts), sum(d.escalations), v_secs
      FROM (SELECT f.database_id, f.object_id, f.index_id, f.database_name, f.schema_name, f.table_name, f.index_name, f.index_type,
                   CASE g.mode WHEN 'diff' THEN f.row_lock_waits - l.row_lock_waits WHEN 'whole' THEN f.row_lock_waits ELSE 0 END AS row_lock_waits,
                   CASE g.mode WHEN 'diff' THEN f.row_lock_wait_ms - l.row_lock_wait_ms WHEN 'whole' THEN f.row_lock_wait_ms ELSE 0 END AS row_lock_wait_ms,
                   CASE g.mode WHEN 'diff' THEN f.page_lock_waits - l.page_lock_waits WHEN 'whole' THEN f.page_lock_waits ELSE 0 END AS page_lock_waits,
                   CASE g.mode WHEN 'diff' THEN f.page_lock_wait_ms - l.page_lock_wait_ms WHEN 'whole' THEN f.page_lock_wait_ms ELSE 0 END AS page_lock_wait_ms,
                   CASE g.mode WHEN 'diff' THEN f.escalation_attempts - l.escalation_attempts WHEN 'whole' THEN f.escalation_attempts ELSE 0 END AS escalation_attempts,
                   CASE g.mode WHEN 'diff' THEN f.escalations - l.escalations WHEN 'whole' THEN f.escalations ELSE 0 END AS escalations
              FROM pgv_mssql_ixl_in f
              LEFT JOIN pgvigil.mssql_indexlock_last l ON l.instance_id = p_instance_id AND l.database_id = f.database_id
                    AND l.object_id = f.object_id AND l.index_id = f.index_id AND l.partition_number = f.partition_number
                    AND l.hobt_id = f.hobt_id
                   -- diff: seen before with no counter lower, now minus before. whole: a counter went down (the cache
                   -- dropped the index and it counts again from zero), or new since a complete read. none: new after a cut read.
             CROSS JOIN LATERAL (SELECT CASE WHEN l.instance_id IS NULL THEN CASE WHEN v_whole THEN 'whole' ELSE 'none' END
                                             WHEN f.row_lock_waits >= l.row_lock_waits AND f.row_lock_wait_ms >= l.row_lock_wait_ms
                                              AND f.page_lock_waits >= l.page_lock_waits AND f.page_lock_wait_ms >= l.page_lock_wait_ms
                                              AND f.escalation_attempts >= l.escalation_attempts AND f.escalations >= l.escalations THEN 'diff'
                                             ELSE 'whole' END AS mode) g) d
     GROUP BY d.database_id, d.object_id, d.index_id
    HAVING sum(d.row_lock_waits) > 0 OR sum(d.page_lock_waits) > 0 OR sum(d.escalation_attempts) > 0 OR sum(d.escalations) > 0
        OR sum(d.row_lock_wait_ms) > 0 OR sum(d.page_lock_wait_ms) > 0;
    INSERT INTO pgvigil.mssql_indexlock_read (instance_id, snapshot_at, interval_secs, indexes)
    SELECT p_instance_id, p_snapshot_at, v_secs,
           (SELECT count(*) FROM pgvigil.mssql_indexlock_sample s WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at);
  END IF;

  -- the state is this read's rowsets, and those of a database this read did not reach stay as they were; only
  -- counters that moved are rewritten
  DELETE FROM pgvigil.mssql_indexlock_last l
   WHERE l.instance_id = p_instance_id AND NOT (l.database_id = ANY (v_skipped))
     AND NOT EXISTS (SELECT 1 FROM pgv_mssql_ixl_in f
                      WHERE f.database_id = l.database_id AND f.object_id = l.object_id AND f.index_id = l.index_id
                        AND f.partition_number = l.partition_number AND f.hobt_id = l.hobt_id);
  INSERT INTO pgvigil.mssql_indexlock_last AS l (instance_id, database_id, object_id, index_id, partition_number, hobt_id, row_lock_waits,
      row_lock_wait_ms, page_lock_waits, page_lock_wait_ms, escalation_attempts, escalations)
  SELECT p_instance_id, f.database_id, f.object_id, f.index_id, f.partition_number, f.hobt_id, f.row_lock_waits, f.row_lock_wait_ms,
         f.page_lock_waits, f.page_lock_wait_ms, f.escalation_attempts, f.escalations
    FROM pgv_mssql_ixl_in f
  ON CONFLICT (instance_id, database_id, object_id, index_id, partition_number, hobt_id) DO UPDATE SET
      row_lock_waits = EXCLUDED.row_lock_waits, row_lock_wait_ms = EXCLUDED.row_lock_wait_ms, page_lock_waits = EXCLUDED.page_lock_waits,
      page_lock_wait_ms = EXCLUDED.page_lock_wait_ms, escalation_attempts = EXCLUDED.escalation_attempts, escalations = EXCLUDED.escalations
   WHERE (l.row_lock_waits, l.row_lock_wait_ms, l.page_lock_waits, l.page_lock_wait_ms, l.escalation_attempts, l.escalations)
         IS DISTINCT FROM (EXCLUDED.row_lock_waits, EXCLUDED.row_lock_wait_ms, EXCLUDED.page_lock_waits, EXCLUDED.page_lock_wait_ms,
                           EXCLUDED.escalation_attempts, EXCLUDED.escalations);
  INSERT INTO pgvigil.mssql_indexlock_state AS s (instance_id, snapshot_at, server_utc, server_start, capped)
  VALUES (p_instance_id, p_snapshot_at, v_now, v_start, v_capped)
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, server_utc = EXCLUDED.server_utc,
      server_start = EXCLUDED.server_start, capped = EXCLUDED.capped;
END $$;

-- What a tempdb page is that a request waits for a LATCH on (PAGELATCH_*, never PAGEIOLATCH_*: that is the disk),
-- from the request's wait type and wait resource (2:<file>:<page>, with or without a PAGE: prefix; tempdb is
-- database 2): 'pfs' (page 1 and every
-- 8,088th), 'gam' (page 2 and every 511,232nd), 'sgam' (page 3 and every 511,232nd after it) - the three allocation
-- pages - or 'page' for any other; NULL when the wait is not a tempdb page latch (a request that waits for nothing
-- can still carry the resource of its last wait: no wait type, no wait).
CREATE OR REPLACE FUNCTION pgvigil.mssql_tempdb_page_kind(p_wait_type text, p_wait_resource text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN coalesce(p_wait_type, '') !~ '^PAGELATCH_' OR m.page IS NULL THEN NULL
              WHEN m.page = 1 OR (m.page > 0 AND m.page % 8088 = 0) THEN 'pfs'
              WHEN m.page = 2 OR (m.page > 0 AND m.page % 511232 = 0) THEN 'gam'
              WHEN m.page = 3 OR (m.page > 1 AND (m.page - 1) % 511232 = 0) THEN 'sgam'
              ELSE 'page' END
    FROM (SELECT ((regexp_match(p_wait_resource, '^\s*(?:PAGE:\s*)?2:[0-9]+:([0-9]{1,18})'))[1])::bigint AS page) m
$$;

-- What purge()'s month-partition list does not cover: the change history past the window, and the counters of an
-- instance not read within it (its next read sets them again). Returns the rows it removed, as purge() sums them.
CREATE OR REPLACE FUNCTION pgvigil.mssql_reads_purge(p_days int DEFAULT 30)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n       bigint := 0;
  v_rows  bigint;
BEGIN
  DELETE FROM pgvigil.mssql_property_change WHERE changed_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_proc_last l
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_proc_state s
                      WHERE s.instance_id = l.instance_id AND s.snapshot_at >= now() - make_interval(days => p_days));
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_proc_state WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_indexlock_last l
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_indexlock_state s
                      WHERE s.instance_id = l.instance_id AND s.snapshot_at >= now() - make_interval(days => p_days));
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_indexlock_state WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  RETURN n;
END $$;
