-- 0083: SQL Server Query Store (the collection mssql_querystore; internal/mssql/querystore.go).
--
-- mssql_querystore (hourly), per database of the instance:
--   mssql_qs_store          the store's state as last read, one row per database: actual against desired state, why
--                           it is read-only (a bit map), its size against its limit, its options; newest_interval is
--                           where the next read goes on from.
--   mssql_qs_tuning_option  the database's automatic tuning options (FORCE_LAST_GOOD_PLAN ...), SQL Server 2017+.
--   mssql_qs_interval       one row per interval of the store (snapshot_at = the interval's start, UTC) with the
--                           interval's totals over EVERY plan that ran in it.
--   mssql_qs_runtime        one row per kept plan and interval: the plans in the interval's first 50 by total
--                           duration, CPU, logical reads, the largest memory grant and wait time (the candidate
--                           set). An interval read again (it was open) is replaced whole.
--   mssql_qs_query          a query of the store: its hash, object and text (the instance's text policy applied
--                           before it was sent).
--   mssql_qs_plan           a plan: its hash, its forcing state with the failure count and reason, its showplan XML
--                           (stored under the 'full' text policy only: a showplan carries the statement and the
--                           compiled parameter values).
--   mssql_qs_tuning         the automatic tuning recommendations (sys.dm_db_tuning_recommendations) and their state.
-- mssql_querystore_findings the slice's findings in the findings columns (the join adds the arm to pgvigil.findings).
-- mssql_querystore_status   the Summary's 'QS' cell, one row per instance (the shape of mssql_health_status).
--
-- A cleared store numbers its queries and plans again from 1. A runtime row therefore carries its query's hash and
-- its plan's hash as they were when it was read, and every join from a runtime row to mssql_qs_query or
-- mssql_qs_plan asks for the same hash: a row from before the clear never borrows the text of the plan that took
-- its number.
--
-- pgvigil.mssql_hadr_cursor (0066) is re-created here with two more sources, 'qs_since:<database>' and
-- 'qs_plan:<plan id>:<database>'; 'jobs' and 'jobs_mark' answer as before.
--
-- Partition parents for purge() (the join adds them): mssql_qs_interval, mssql_qs_runtime. The join also ages
-- mssql_qs_query, mssql_qs_plan and mssql_qs_tuning by snapshot_at. Until that migration none of them is purged.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_qs_store (
  instance_id             int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name           text NOT NULL,
  database_id             int,
  snapshot_at             timestamptz NOT NULL,   -- the read that last listed the database
  database_state          text,                   -- ONLINE | RESTORING | OFFLINE ...
  database_read_only      boolean,
  options_read            boolean NOT NULL DEFAULT false,  -- false = this read did not read the store's options (note says why)
  note                    text,                   -- why the options or the contents were not read
  desired_state           text,                   -- OFF | READ_ONLY | READ_WRITE
  actual_state            text,                   -- OFF | READ_ONLY | READ_WRITE | ERROR
  readonly_reason         int,                    -- sys.database_query_store_options.readonly_reason, a bit map
  current_mb              bigint,
  max_mb                  bigint,
  flush_interval_s        bigint,
  interval_minutes        bigint,
  stale_days              bigint,
  max_plans_per_query     bigint,
  capture_mode            text,                   -- ALL | AUTO | NONE | CUSTOM
  cleanup_mode            text,                   -- OFF | AUTO
  wait_stats_mode         text,                   -- NULL = SQL Server 2016 (no wait statistics)
  additional_info         text,
  can_read                boolean,                -- the login may read the store's contents (VIEW DATABASE STATE)
  policy_execution_count  bigint,                 -- the custom capture policy, SQL Server 2019+
  policy_compile_cpu_ms   bigint,
  policy_exec_cpu_ms      bigint,
  policy_stale_hours      bigint,
  newest_interval         timestamptz,            -- the start of the newest interval stored (the next read's floor)
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_qs_tuning_option (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  option_name    text NOT NULL,
  desired_state  text,
  actual_state   text,
  reason         text,
  snapshot_at    timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, option_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_qs_interval (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,            -- the interval's start
  database_name  text NOT NULL,
  interval_id    bigint,
  interval_end   timestamptz NOT NULL,
  plans          bigint,                          -- the plans that ran in the interval; NULL = none
  executions     bigint,
  duration_us    bigint,
  cpu_us         bigint,
  logical_reads  bigint,
  wait_ms        bigint,
  read_at        timestamptz NOT NULL
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_qs_runtime (
  instance_id       int NOT NULL,
  snapshot_at       timestamptz NOT NULL,         -- the interval's start
  interval_end      timestamptz NOT NULL,
  database_name     text NOT NULL,
  plan_id           bigint NOT NULL,
  query_id          bigint,                       -- NULL = the plan left the store between the read's two steps
  query_hash        text,                         -- 0x..., as the store wrote it
  plan_hash_n       bigint,
  executions        bigint NOT NULL,
  failed            bigint,                       -- executions that were aborted or ended in an exception
  duration_us       bigint,                       -- totals over the interval
  cpu_us            bigint,
  logical_reads     bigint,
  physical_reads    bigint,
  logical_writes    bigint,
  row_count         bigint,
  max_duration_us   bigint,
  memory_pages      bigint,                       -- the sum of each execution's largest grant in use, 8 KB pages
  max_memory_pages  bigint,
  max_dop           bigint,
  first_execution   timestamptz,
  last_execution    timestamptz,
  wait_ms           bigint,
  top_wait          text                          -- the wait category with the most time
) PARTITION BY RANGE (snapshot_at);

-- the pages read one database's lines, and one query's
CREATE INDEX IF NOT EXISTS mssql_qs_interval_db_idx ON pgvigil.mssql_qs_interval (instance_id, database_name, snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_qs_runtime_db_idx ON pgvigil.mssql_qs_runtime (instance_id, database_name, query_id, snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_qs_query (
  instance_id       int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name     text NOT NULL,
  query_id          bigint NOT NULL,
  query_hash        text,
  object_name       text,                         -- schema.object of a statement inside a module
  query_text        text,                         -- NULL under the text policy 'none'
  parameterization  text,
  plan_count        bigint,                       -- the plans the store holds for the query
  last_execution    timestamptz,
  first_seen        timestamptz NOT NULL,
  snapshot_at       timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, query_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_qs_plan (
  instance_id           int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name         text NOT NULL,
  plan_id               bigint NOT NULL,
  query_id              bigint NOT NULL,
  query_hash            text,
  plan_hash             text,
  plan_hash_n           bigint,
  is_forced             boolean NOT NULL DEFAULT false,
  forcing_type          text,                     -- MANUAL | AUTO | NONE
  force_failure_count   bigint,
  force_failure_reason  text,
  forced_seen           timestamptz,              -- when a read first found the plan forced
  is_parallel           boolean,
  is_trivial            boolean,
  count_compiles        bigint,
  compatibility_level   int,
  initial_compile       timestamptz,
  last_compile          timestamptz,
  last_execution        timestamptz,
  plan_xml_bytes        bigint,
  xml_note              text,
  plan_xml              text,
  xml_state             text,                     -- stored | policy (the text policy keeps none) | too large; NULL = not read yet
  xml_checked_at        timestamptz,
  first_seen            timestamptz NOT NULL,
  snapshot_at           timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, plan_id)
);
CREATE INDEX IF NOT EXISTS mssql_qs_plan_forced_idx ON pgvigil.mssql_qs_plan (instance_id) WHERE is_forced;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_qs_tuning (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name        text NOT NULL,
  rec_name             text NOT NULL,
  rec_type             text,
  reason               text,
  valid_since          timestamptz,
  last_refresh         timestamptz,
  rec_state            text,                      -- Active | Verifying | Success | Reverted | Expired
  state_reason         text,
  is_executable        boolean,
  is_revertable        boolean,
  executed_at          timestamptz,
  executed_by          text,
  reverted_at          timestamptz,
  reverted_by          text,
  score                int,
  query_id             bigint,
  regressed_plan_id    bigint,
  recommended_plan_id  bigint,
  script               text,
  rec_details          text,                      -- the server's JSON, 8,000 characters at most
  is_present           boolean NOT NULL DEFAULT true,  -- false = the server no longer lists it (a restart empties the list)
  first_seen           timestamptz NOT NULL,
  snapshot_at          timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, rec_name)
);

-- readonly_reason spelled out (Microsoft's list for sys.database_query_store_options); a bit not on the list is named
-- by its number.
CREATE OR REPLACE FUNCTION pgvigil.mssql_qs_readonly_reasons(p_reason int)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT nullif(concat_ws('; ',
           CASE WHEN p_reason & 1 <> 0 THEN 'the database is read-only' END,
           CASE WHEN p_reason & 2 <> 0 THEN 'the database is in single-user mode' END,
           CASE WHEN p_reason & 4 <> 0 THEN 'the database is in emergency mode' END,
           CASE WHEN p_reason & 8 <> 0 THEN 'the database is a secondary replica' END,
           CASE WHEN p_reason & 65536 <> 0 THEN 'the store reached its max size (MAX_STORAGE_SIZE_MB)' END,
           CASE WHEN p_reason & 131072 <> 0 THEN 'the number of different statements reached the internal memory limit' END,
           CASE WHEN p_reason & 262144 <> 0 THEN 'the in-memory items waiting to be written reached the internal memory limit' END,
           CASE WHEN p_reason & 524288 <> 0 THEN 'the database reached its disk size limit' END,
           CASE WHEN p_reason & ~(1 | 2 | 4 | 8 | 65536 | 131072 | 262144 | 524288) <> 0
                THEN 'reason ' || (p_reason & ~(1 | 2 | 4 | 8 | 65536 | 131072 | 262144 | 524288)) END), '')
$$;

-- mssql_hadr_cursor: how far a source of an instance was read (NULL: never). Sources:
--   'jobs', 'jobs_mark'            the newest sysjobhistory row read and that row's mark (0066, unchanged);
--   'qs_since:<database>'          the start of the newest Query Store interval stored for the database, as epoch
--                                  seconds: the next read takes the intervals that ended after it (the newest one
--                                  again: it was open);
--   'qs_plan:<plan id>:<database>' the stored plan's hash as a number when its showplan XML needs no read: it is
--                                  stored, or it was looked at within a day and the text policy kept none (a policy
--                                  changed to full is noticed within a day). The collector compares the hash: a
--                                  cleared store gives the number to another plan.
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
  END
$$;

-- payload (internal/mssql/querystore.go writes it; a database's rows are complete or absent):
--   {kind:'store', database_id, database_name, database_state, database_read_only (0|1), read (1 = the options were
--     read), note, desired_state, actual_state, readonly_reason, current_mb, max_mb, flush_interval_s,
--     interval_minutes, stale_days, max_plans_per_query, capture_mode, cleanup_mode, wait_stats_mode,
--     additional_info, can_read (0|1), policy_execution_count, policy_compile_cpu_ms, policy_exec_cpu_ms,
--     policy_stale_hours}
--   {kind:'tuning_option', database_name, option_name, desired_state, actual_state, reason}
--   {kind:'interval', database_name, interval_id, interval_start, interval_end, plans, executions, duration_us,
--     cpu_us, logical_reads, wait_ms}                 (the totals are absent when no plan ran)
--   {kind:'runtime', database_name, interval_start, plan_id, executions, failed, duration_us, cpu_us, logical_reads,
--     physical_reads, logical_writes, row_count, max_duration_us, memory_pages, max_memory_pages, max_dop,
--     first_execution, last_execution, wait_ms, top_wait}
--   {kind:'plan', database_name, plan_id, query_id, query_hash_hex, plan_hash_hex, plan_hash_n, object_name,
--     is_forced (0|1), forcing_type, force_failure_count, force_failure_reason, is_parallel, is_trivial,
--     count_compiles, compatibility_level, initial_compile, last_compile, plan_last_execution, query_last_execution,
--     parameterization, plan_count, plan_xml_bytes, xml_note, query}
--   {kind:'forced_read', database_name}               the plan read ran: a stored forced plan it does not list is no
--                                                     longer forced
--   {kind:'plan_xml', database_name, plan_id, statement}   statement = the showplan XML, NULL when the text policy
--                                                     keeps none
--   {kind:'tuning', database_name, rec_name, rec_type, reason, valid_since, last_refresh, rec_state, state_reason,
--     is_executable, is_revertable, executed_at, executed_by, reverted_at, reverted_by, score, query_id,
--     regressed_plan_id, recommended_plan_id, script, rec_details}
--   {kind:'tuning_read', database_name}               the recommendations were read: a stored one not listed is gone
--   {kind:'collector_error', source, message}
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_querystore(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows   jsonb := pgvigil.mssql_rows(p_payload);
  v_month  timestamptz;
BEGIN
  -- the engine check, the advisory lock and "an older read arriving late stores nothing" (0066)
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_querystore', p_snapshot_at,
           (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'store')) THEN
    RETURN;
  END IF;

  -- the partitioned parents in name order, the order purge() drops in (0067's lock-order note), before anything
  -- is written
  FOR v_month IN SELECT DISTINCT date_trunc('month', (r->>'interval_start')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
                   FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'interval' AND r->>'interval_start' IS NOT NULL
                  ORDER BY 1 LOOP
    PERFORM pgvigil.ensure_month_partition('mssql_qs_interval', v_month);
  END LOOP;
  FOR v_month IN SELECT DISTINCT date_trunc('month', (r->>'interval_start')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
                   FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'interval' AND r->>'interval_start' IS NOT NULL
                  ORDER BY 1 LOOP
    PERFORM pgvigil.ensure_month_partition('mssql_qs_runtime', v_month);
  END LOOP;
  LOCK TABLE ONLY pgvigil.mssql_qs_interval, ONLY pgvigil.mssql_qs_runtime IN ROW EXCLUSIVE MODE;

  -- the stores: a database the read lists is written whole (a row that was not read loses its options: the page
  -- says "not read" and why, never an hour-old state under a new time); newest_interval is the cursor and stays
  INSERT INTO pgvigil.mssql_qs_store AS s (instance_id, database_name, database_id, snapshot_at, database_state, database_read_only,
      options_read, note, desired_state, actual_state, readonly_reason, current_mb, max_mb, flush_interval_s, interval_minutes,
      stale_days, max_plans_per_query, capture_mode, cleanup_mode, wait_stats_mode, additional_info, can_read,
      policy_execution_count, policy_compile_cpu_ms, policy_exec_cpu_ms, policy_stale_hours)
  SELECT p_instance_id, r->>'database_name', (r->>'database_id')::int, p_snapshot_at, r->>'database_state',
         (r->>'database_read_only')::int = 1, coalesce((r->>'read')::int, 0) = 1, r->>'note', r->>'desired_state', r->>'actual_state',
         (r->>'readonly_reason')::int, (r->>'current_mb')::bigint, (r->>'max_mb')::bigint, (r->>'flush_interval_s')::bigint,
         (r->>'interval_minutes')::bigint, (r->>'stale_days')::bigint, (r->>'max_plans_per_query')::bigint, r->>'capture_mode',
         r->>'cleanup_mode', r->>'wait_stats_mode', r->>'additional_info', (r->>'can_read')::int = 1,
         (r->>'policy_execution_count')::bigint, (r->>'policy_compile_cpu_ms')::bigint, (r->>'policy_exec_cpu_ms')::bigint,
         (r->>'policy_stale_hours')::bigint
    FROM (SELECT DISTINCT ON (r->>'database_name') r FROM jsonb_array_elements(v_rows) r
           WHERE r->>'kind' = 'store' AND r->>'database_name' IS NOT NULL) x
  ON CONFLICT (instance_id, database_name) DO UPDATE SET
      database_id = EXCLUDED.database_id, snapshot_at = EXCLUDED.snapshot_at, database_state = EXCLUDED.database_state,
      database_read_only = EXCLUDED.database_read_only, options_read = EXCLUDED.options_read, note = EXCLUDED.note,
      desired_state = EXCLUDED.desired_state, actual_state = EXCLUDED.actual_state, readonly_reason = EXCLUDED.readonly_reason,
      current_mb = EXCLUDED.current_mb, max_mb = EXCLUDED.max_mb, flush_interval_s = EXCLUDED.flush_interval_s,
      interval_minutes = EXCLUDED.interval_minutes, stale_days = EXCLUDED.stale_days,
      max_plans_per_query = EXCLUDED.max_plans_per_query, capture_mode = EXCLUDED.capture_mode, cleanup_mode = EXCLUDED.cleanup_mode,
      wait_stats_mode = EXCLUDED.wait_stats_mode, additional_info = EXCLUDED.additional_info, can_read = EXCLUDED.can_read,
      policy_execution_count = EXCLUDED.policy_execution_count, policy_compile_cpu_ms = EXCLUDED.policy_compile_cpu_ms,
      policy_exec_cpu_ms = EXCLUDED.policy_exec_cpu_ms, policy_stale_hours = EXCLUDED.policy_stale_hours;
  -- a database the server no longer lists leaves the state (its history stays until the purge); a payload without
  -- a single store row is a read that listed nothing and changes nothing
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'store') THEN
    DELETE FROM pgvigil.mssql_qs_store s WHERE s.instance_id = p_instance_id AND s.snapshot_at < p_snapshot_at;
    DELETE FROM pgvigil.mssql_qs_tuning_option o
     WHERE o.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_qs_store s WHERE s.instance_id = p_instance_id AND s.database_name = o.database_name);
  END IF;

  -- the automatic tuning options of each database whose store was read without a note (a read that stopped early
  -- keeps what an earlier one stored)
  DELETE FROM pgvigil.mssql_qs_tuning_option o
   WHERE o.instance_id = p_instance_id
     AND o.database_name IN (SELECT r->>'database_name' FROM jsonb_array_elements(v_rows) r
                              WHERE r->>'kind' = 'store' AND (r->>'read')::int = 1 AND r->>'note' IS NULL);
  INSERT INTO pgvigil.mssql_qs_tuning_option AS o (instance_id, database_name, option_name, desired_state, actual_state, reason, snapshot_at)
  SELECT DISTINCT ON (r->>'database_name', r->>'option_name') p_instance_id, r->>'database_name', r->>'option_name',
         r->>'desired_state', r->>'actual_state', r->>'reason', p_snapshot_at
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'tuning_option' AND r->>'database_name' IS NOT NULL AND r->>'option_name' IS NOT NULL
  ON CONFLICT (instance_id, database_name, option_name) DO UPDATE SET
      desired_state = EXCLUDED.desired_state, actual_state = EXCLUDED.actual_state, reason = EXCLUDED.reason, snapshot_at = EXCLUDED.snapshot_at;

  -- the queries and the plans. A query or plan number whose hash changed belongs to another statement now (the
  -- store was cleared): the row starts again, its XML with it.
  INSERT INTO pgvigil.mssql_qs_query AS q (instance_id, database_name, query_id, query_hash, object_name, query_text, parameterization,
      plan_count, last_execution, first_seen, snapshot_at)
  SELECT DISTINCT ON (r->>'database_name', (r->>'query_id')::bigint) p_instance_id, r->>'database_name', (r->>'query_id')::bigint,
         r->>'query_hash_hex', r->>'object_name', r->>'query', r->>'parameterization', (r->>'plan_count')::bigint,
         (r->>'query_last_execution')::timestamptz, p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'plan' AND r->>'database_name' IS NOT NULL AND r->>'query_id' IS NOT NULL
  ON CONFLICT (instance_id, database_name, query_id) DO UPDATE SET
      first_seen = CASE WHEN q.query_hash IS DISTINCT FROM EXCLUDED.query_hash THEN EXCLUDED.first_seen ELSE q.first_seen END,
      -- the text as the policy in force sent it: a policy tightened later takes the stored text with it at the next read
      query_text = EXCLUDED.query_text,
      query_hash = EXCLUDED.query_hash, object_name = EXCLUDED.object_name, parameterization = EXCLUDED.parameterization,
      plan_count = EXCLUDED.plan_count, last_execution = EXCLUDED.last_execution, snapshot_at = EXCLUDED.snapshot_at;

  INSERT INTO pgvigil.mssql_qs_plan AS p (instance_id, database_name, plan_id, query_id, query_hash, plan_hash, plan_hash_n, is_forced,
      forcing_type, force_failure_count, force_failure_reason, forced_seen, is_parallel, is_trivial, count_compiles,
      compatibility_level, initial_compile, last_compile, last_execution, plan_xml_bytes, xml_note, xml_state, first_seen, snapshot_at)
  SELECT DISTINCT ON (r->>'database_name', (r->>'plan_id')::bigint) p_instance_id, r->>'database_name', (r->>'plan_id')::bigint,
         (r->>'query_id')::bigint, r->>'query_hash_hex', r->>'plan_hash_hex', (r->>'plan_hash_n')::bigint,
         coalesce((r->>'is_forced')::int, 0) = 1, r->>'forcing_type', (r->>'force_failure_count')::bigint, r->>'force_failure_reason',
         CASE WHEN coalesce((r->>'is_forced')::int, 0) = 1 THEN p_snapshot_at END,
         (r->>'is_parallel')::int = 1, (r->>'is_trivial')::int = 1, (r->>'count_compiles')::bigint, (r->>'compatibility_level')::int,
         (r->>'initial_compile')::timestamptz, (r->>'last_compile')::timestamptz, (r->>'plan_last_execution')::timestamptz,
         (r->>'plan_xml_bytes')::bigint, r->>'xml_note', CASE WHEN r->>'xml_note' IS NOT NULL THEN 'too large' END,
         p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'plan' AND r->>'database_name' IS NOT NULL AND r->>'plan_id' IS NOT NULL AND r->>'query_id' IS NOT NULL
  ON CONFLICT (instance_id, database_name, plan_id) DO UPDATE SET
      first_seen = CASE WHEN p.plan_hash_n IS DISTINCT FROM EXCLUDED.plan_hash_n THEN EXCLUDED.first_seen ELSE p.first_seen END,
      plan_xml = CASE WHEN p.plan_hash_n IS DISTINCT FROM EXCLUDED.plan_hash_n THEN NULL ELSE p.plan_xml END,
      xml_state = CASE WHEN EXCLUDED.xml_state IS NOT NULL THEN EXCLUDED.xml_state
                       WHEN p.plan_hash_n IS DISTINCT FROM EXCLUDED.plan_hash_n OR p.xml_state = 'too large' THEN NULL ELSE p.xml_state END,
      xml_checked_at = CASE WHEN p.plan_hash_n IS DISTINCT FROM EXCLUDED.plan_hash_n THEN NULL ELSE p.xml_checked_at END,
      forced_seen = CASE WHEN NOT EXCLUDED.is_forced THEN NULL
                         WHEN p.is_forced AND p.plan_hash_n IS NOT DISTINCT FROM EXCLUDED.plan_hash_n THEN p.forced_seen
                         ELSE EXCLUDED.forced_seen END,
      query_id = EXCLUDED.query_id, query_hash = EXCLUDED.query_hash, plan_hash = EXCLUDED.plan_hash, plan_hash_n = EXCLUDED.plan_hash_n,
      is_forced = EXCLUDED.is_forced, forcing_type = EXCLUDED.forcing_type, force_failure_count = EXCLUDED.force_failure_count,
      force_failure_reason = EXCLUDED.force_failure_reason, is_parallel = EXCLUDED.is_parallel, is_trivial = EXCLUDED.is_trivial,
      count_compiles = EXCLUDED.count_compiles, compatibility_level = EXCLUDED.compatibility_level,
      initial_compile = EXCLUDED.initial_compile, last_compile = EXCLUDED.last_compile, last_execution = EXCLUDED.last_execution,
      plan_xml_bytes = EXCLUDED.plan_xml_bytes, xml_note = EXCLUDED.xml_note, snapshot_at = EXCLUDED.snapshot_at;

  -- a plan the repository holds as forced and a database's plan read no longer lists is not forced any more (the
  -- read lists every forced plan of the database)
  UPDATE pgvigil.mssql_qs_plan p SET is_forced = false, forcing_type = 'NONE', forced_seen = NULL
   WHERE p.instance_id = p_instance_id AND p.is_forced AND p.snapshot_at < p_snapshot_at
     AND p.database_name IN (SELECT r->>'database_name' FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'forced_read');

  -- the showplan XML: stored, or looked at and kept none under the text policy
  UPDATE pgvigil.mssql_qs_plan p
     SET plan_xml = x.xml, xml_state = CASE WHEN x.xml IS NULL THEN 'policy' ELSE 'stored' END, xml_checked_at = p_snapshot_at
    FROM (SELECT DISTINCT ON (r->>'database_name', (r->>'plan_id')::bigint) r->>'database_name' AS database_name,
                 (r->>'plan_id')::bigint AS plan_id, nullif(r->>'statement', '') AS xml
            FROM jsonb_array_elements(v_rows) r
           WHERE r->>'kind' = 'plan_xml' AND r->>'database_name' IS NOT NULL AND r->>'plan_id' IS NOT NULL) x
   WHERE p.instance_id = p_instance_id AND p.database_name = x.database_name AND p.plan_id = x.plan_id;

  -- the intervals: one read again (it was open) is replaced whole, its runtime rows with it
  DELETE FROM pgvigil.mssql_qs_runtime t
   USING (SELECT DISTINCT r->>'database_name' AS database_name, (r->>'interval_start')::timestamptz AS at
            FROM jsonb_array_elements(v_rows) r
           WHERE r->>'kind' = 'interval' AND r->>'database_name' IS NOT NULL AND r->>'interval_start' IS NOT NULL) x
   WHERE t.instance_id = p_instance_id AND t.database_name = x.database_name AND t.snapshot_at = x.at;
  DELETE FROM pgvigil.mssql_qs_interval t
   USING (SELECT DISTINCT r->>'database_name' AS database_name, (r->>'interval_start')::timestamptz AS at
            FROM jsonb_array_elements(v_rows) r
           WHERE r->>'kind' = 'interval' AND r->>'database_name' IS NOT NULL AND r->>'interval_start' IS NOT NULL) x
   WHERE t.instance_id = p_instance_id AND t.database_name = x.database_name AND t.snapshot_at = x.at;
  INSERT INTO pgvigil.mssql_qs_interval (instance_id, snapshot_at, database_name, interval_id, interval_end, plans, executions,
      duration_us, cpu_us, logical_reads, wait_ms, read_at)
  SELECT DISTINCT ON (r->>'database_name', (r->>'interval_start')::timestamptz) p_instance_id, (r->>'interval_start')::timestamptz,
         r->>'database_name', (r->>'interval_id')::bigint, (r->>'interval_end')::timestamptz, (r->>'plans')::bigint,
         (r->>'executions')::bigint, (r->>'duration_us')::bigint, (r->>'cpu_us')::bigint, (r->>'logical_reads')::bigint,
         (r->>'wait_ms')::bigint, p_snapshot_at
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'interval' AND r->>'database_name' IS NOT NULL AND r->>'interval_start' IS NOT NULL AND r->>'interval_end' IS NOT NULL;
  -- a runtime row belongs to an interval of this payload; its query and hashes come from the payload's plan row
  INSERT INTO pgvigil.mssql_qs_runtime (instance_id, snapshot_at, interval_end, database_name, plan_id, query_id, query_hash, plan_hash_n,
      executions, failed, duration_us, cpu_us, logical_reads, physical_reads, logical_writes, row_count, max_duration_us,
      memory_pages, max_memory_pages, max_dop, first_execution, last_execution, wait_ms, top_wait)
  SELECT p_instance_id, x.at, i.interval_end, x.database_name, x.plan_id, pl.query_id, pl.query_hash, pl.plan_hash_n,
         coalesce((x.r->>'executions')::bigint, 0), (x.r->>'failed')::bigint, (x.r->>'duration_us')::bigint, (x.r->>'cpu_us')::bigint,
         (x.r->>'logical_reads')::bigint, (x.r->>'physical_reads')::bigint, (x.r->>'logical_writes')::bigint, (x.r->>'row_count')::bigint,
         (x.r->>'max_duration_us')::bigint, (x.r->>'memory_pages')::bigint, (x.r->>'max_memory_pages')::bigint, (x.r->>'max_dop')::bigint,
         (x.r->>'first_execution')::timestamptz, (x.r->>'last_execution')::timestamptz, (x.r->>'wait_ms')::bigint, x.r->>'top_wait'
    FROM (SELECT DISTINCT ON (r->>'database_name', (r->>'interval_start')::timestamptz, (r->>'plan_id')::bigint)
                 r, r->>'database_name' AS database_name, (r->>'interval_start')::timestamptz AS at, (r->>'plan_id')::bigint AS plan_id
            FROM jsonb_array_elements(v_rows) r
           WHERE r->>'kind' = 'runtime' AND r->>'database_name' IS NOT NULL AND r->>'interval_start' IS NOT NULL AND r->>'plan_id' IS NOT NULL) x
    JOIN pgvigil.mssql_qs_interval i ON i.instance_id = p_instance_id AND i.database_name = x.database_name AND i.snapshot_at = x.at
                                    AND i.read_at = p_snapshot_at
    LEFT JOIN (SELECT DISTINCT ON (r->>'database_name', (r->>'plan_id')::bigint) r->>'database_name' AS database_name,
                      (r->>'plan_id')::bigint AS plan_id, (r->>'query_id')::bigint AS query_id, r->>'query_hash_hex' AS query_hash,
                      (r->>'plan_hash_n')::bigint AS plan_hash_n
                 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'plan') pl
           ON pl.database_name = x.database_name AND pl.plan_id = x.plan_id;
  -- the cursor: the newest interval stored per database
  UPDATE pgvigil.mssql_qs_store s SET newest_interval = greatest(s.newest_interval, x.newest)
    FROM (SELECT r->>'database_name' AS database_name, max((r->>'interval_start')::timestamptz) AS newest
            FROM jsonb_array_elements(v_rows) r
           WHERE r->>'kind' = 'interval' AND r->>'interval_start' IS NOT NULL AND r->>'interval_end' IS NOT NULL
           GROUP BY 1) x
   WHERE s.instance_id = p_instance_id AND s.database_name = x.database_name;

  -- the automatic tuning recommendations: a database whose list was read marks the ones it no longer lists
  UPDATE pgvigil.mssql_qs_tuning t SET is_present = false
   WHERE t.instance_id = p_instance_id AND t.is_present
     AND t.database_name IN (SELECT r->>'database_name' FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'tuning_read');
  INSERT INTO pgvigil.mssql_qs_tuning AS t (instance_id, database_name, rec_name, rec_type, reason, valid_since, last_refresh, rec_state,
      state_reason, is_executable, is_revertable, executed_at, executed_by, reverted_at, reverted_by, score, query_id,
      regressed_plan_id, recommended_plan_id, script, rec_details, is_present, first_seen, snapshot_at)
  SELECT DISTINCT ON (r->>'database_name', r->>'rec_name') p_instance_id, r->>'database_name', r->>'rec_name', r->>'rec_type', r->>'reason',
         (r->>'valid_since')::timestamptz, (r->>'last_refresh')::timestamptz, r->>'rec_state', r->>'state_reason',
         (r->>'is_executable')::int = 1, (r->>'is_revertable')::int = 1, (r->>'executed_at')::timestamptz, r->>'executed_by',
         (r->>'reverted_at')::timestamptz, r->>'reverted_by', (r->>'score')::int, (r->>'query_id')::bigint,
         (r->>'regressed_plan_id')::bigint, (r->>'recommended_plan_id')::bigint, r->>'script', r->>'rec_details', true,
         p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'tuning' AND r->>'database_name' IS NOT NULL AND r->>'rec_name' IS NOT NULL
  ON CONFLICT (instance_id, database_name, rec_name) DO UPDATE SET
      rec_type = EXCLUDED.rec_type, reason = EXCLUDED.reason, valid_since = EXCLUDED.valid_since, last_refresh = EXCLUDED.last_refresh,
      rec_state = EXCLUDED.rec_state, state_reason = EXCLUDED.state_reason, is_executable = EXCLUDED.is_executable,
      is_revertable = EXCLUDED.is_revertable, executed_at = EXCLUDED.executed_at, executed_by = EXCLUDED.executed_by,
      reverted_at = EXCLUDED.reverted_at, reverted_by = EXCLUDED.reverted_by, score = EXCLUDED.score, query_id = EXCLUDED.query_id,
      regressed_plan_id = EXCLUDED.regressed_plan_id, recommended_plan_id = EXCLUDED.recommended_plan_id, script = EXCLUDED.script,
      rec_details = EXCLUDED.rec_details, is_present = true, snapshot_at = EXCLUDED.snapshot_at;
END $$;

-- One row per database's store with its judgement, for the findings, the Summary cell and the page:
--   critical  the store is in the ERROR state;
--   warning   the store is READ_ONLY, asked for or not, unless the only reasons are a read-only database or a
--             secondary replica (nothing to do there); the store is OFF though a state was asked for;
--   info      a READ_WRITE store at 90 % of its max size with size-based cleanup off (it goes read-only when full).
-- A store whose options this read did not read is judged by nothing.
CREATE OR REPLACE VIEW pgvigil.mssql_qs_store_status AS
SELECT s.*,
       pgvigil.mssql_qs_readonly_reasons(s.readonly_reason) AS readonly_reasons,
       round(100.0 * s.current_mb / nullif(s.max_mb, 0), 1) AS used_pct,
       CASE WHEN NOT s.options_read THEN NULL
            WHEN s.actual_state = 'ERROR' THEN 'critical'
            WHEN s.actual_state = 'READ_ONLY'
                 AND NOT (coalesce(s.readonly_reason, 0) <> 0 AND coalesce(s.readonly_reason, 0) & ~(1 | 8) = 0) THEN 'warning'
            WHEN s.actual_state = 'OFF' AND s.desired_state <> 'OFF' THEN 'warning'
            WHEN s.actual_state = 'READ_WRITE' AND s.cleanup_mode = 'OFF' AND s.max_mb > 0 AND s.current_mb >= 0.9 * s.max_mb THEN 'info'
       END AS severity,
       CASE WHEN NOT s.options_read THEN NULL
            WHEN s.actual_state = 'ERROR'
              THEN 'Query Store is in the ERROR state (asked for ' || coalesce(s.desired_state, '?') || '): it records nothing. '
                   || 'sys.sp_query_store_consistency_check, or setting it OFF and on again, is the way out; clearing it loses its history.'
            WHEN s.actual_state = 'READ_ONLY'
                 AND NOT (coalesce(s.readonly_reason, 0) <> 0 AND coalesce(s.readonly_reason, 0) & ~(1 | 8) = 0)
              THEN 'Query Store is READ_ONLY, '
                   || CASE WHEN s.desired_state = 'READ_ONLY' THEN 'as asked for' ELSE 'not as asked for (' || coalesce(s.desired_state, '?') || ')' END
                   || coalesce(': ' || pgvigil.mssql_qs_readonly_reasons(s.readonly_reason), '')
                   || format(' (%s of %s MB). It records nothing new: no new plan, no runtime statistics.', s.current_mb, s.max_mb)
            WHEN s.actual_state = 'OFF' AND s.desired_state <> 'OFF'
              THEN 'Query Store is OFF though ' || s.desired_state || ' was asked for.'
            WHEN s.actual_state = 'READ_WRITE' AND s.cleanup_mode = 'OFF' AND s.max_mb > 0 AND s.current_mb >= 0.9 * s.max_mb
              THEN format('Query Store holds %s of %s MB (%s %%) with size-based cleanup off: it goes read-only when it is full.',
                          s.current_mb, s.max_mb, round(100.0 * s.current_mb / s.max_mb, 1))
       END AS verdict
  FROM pgvigil.mssql_qs_store s;

-- The findings of the slice. A read older than three hours raises nothing: the Collections page says the
-- collection is stale.
--   the stores' judgements above, and
--   a forced plan fails (warning): a plan is forced and SQL Server could not use it (force_failure_count above 0),
--     with the last failure's reason; the query runs with another plan.
CREATE OR REPLACE VIEW pgvigil.mssql_querystore_findings AS
SELECT s.instance_id, s.severity,
       CASE WHEN s.actual_state = 'ERROR' THEN 'Query Store in the ERROR state'
            WHEN s.actual_state = 'READ_ONLY' THEN 'Query Store is read-only'
            WHEN s.actual_state = 'OFF' THEN 'Query Store is off though asked for'
            ELSE 'Query Store near its max size' END::text AS check_name,
       s.database_name AS object, s.snapshot_at AS at, s.verdict AS detail
  FROM pgvigil.mssql_qs_store_status s
 WHERE s.severity IS NOT NULL AND s.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT p.instance_id, 'warning', 'a forced plan fails', p.database_name || ': query ' || p.query_id || ', plan ' || p.plan_id, p.snapshot_at,
       format('plan %s is forced (%s) for query %s%s and SQL Server could not use it %s time(s); the last reason: %s. The query runs with another plan.',
              p.plan_id, lower(coalesce(p.forcing_type, 'manual')), p.query_id, coalesce(' in ' || q.object_name, ''),
              p.force_failure_count, coalesce(p.force_failure_reason, 'not given'))
  FROM pgvigil.mssql_qs_plan p
  LEFT JOIN pgvigil.mssql_qs_query q ON q.instance_id = p.instance_id AND q.database_name = p.database_name AND q.query_id = p.query_id
                                    AND q.query_hash IS NOT DISTINCT FROM p.query_hash
 WHERE p.is_forced AND p.force_failure_count > 0 AND p.snapshot_at > now() - interval '3 hours';

-- The Summary's 'QS' cell, one row per instance with a store read (the shape of mssql_health_status, 0070):
-- critical and warning count the databases whose store is judged so; value says how many stores are on.
CREATE OR REPLACE VIEW pgvigil.mssql_querystore_status AS
SELECT s.instance_id, 'qs'::text AS key, bool_or(s.options_read) AS sampled,
       count(*) FILTER (WHERE s.severity = 'critical')::int AS critical,
       count(*) FILTER (WHERE s.severity = 'warning')::int AS warning,
       CASE WHEN NOT bool_or(s.options_read) THEN NULL
            ELSE count(*) FILTER (WHERE s.options_read AND s.actual_state IN ('READ_WRITE', 'READ_ONLY')) || ' of ' || count(*) FILTER (WHERE s.options_read) || ' on' END AS value,
       CASE WHEN count(*) FILTER (WHERE s.severity IN ('critical', 'warning')) > 0
            THEN (array_agg(s.database_name || ': ' || s.verdict ORDER BY s.severity, s.database_name)
                    FILTER (WHERE s.severity IN ('critical', 'warning')))[1:12]
            WHEN NOT bool_or(s.options_read) THEN '{}'::text[]
            ELSE ARRAY[format('Query Store is on in %s of the %s databases read, each in the state asked for%s (read %s UTC)',
                              count(*) FILTER (WHERE s.options_read AND s.actual_state IN ('READ_WRITE', 'READ_ONLY')), count(*) FILTER (WHERE s.options_read),
                              CASE WHEN count(*) FILTER (WHERE NOT s.options_read) > 0
                                   THEN '; ' || count(*) FILTER (WHERE NOT s.options_read) || ' database(s) not read' ELSE '' END,
                              to_char(max(s.snapshot_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'))] END AS detail
  FROM pgvigil.mssql_qs_store_status s
 GROUP BY s.instance_id;
