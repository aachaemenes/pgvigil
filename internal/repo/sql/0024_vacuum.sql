-- 0024_vacuum: vacuuming (phase 2, task 35).
--   1. the vacuum collection (every minute): the vacuums and analyzes running now (pg_stat_progress_vacuum,
--      pg_stat_progress_analyze, the autovacuum workers of pg_stat_activity, and a VACUUM or ANALYZE still
--      waiting for its table lock), a run history derived from those samples, the autovacuum state of the
--      server, and the xmin holders outside the sessions (replication slots, prepared transactions, standbys
--      with hot_standby_feedback); the sessions come from the activity samples
--   2. the vacuum_tables collection (hourly): per database the tables near or over their autovacuum
--      thresholds (computed from the table's reloptions and the server settings), never or long unvacuumed,
--      autovacuum off, near a forced freeze; the per-database counts; and the wraparound view per database
--      (age(datfrozenxid) and mxid_age(datminmxid) against the freeze max ages)
--   3. the checks (the overview's "vacuum" group, the Summary column Vacuum) and their findings rows
--   4. retention (the names the join's purge takes)

-- ---------------------------------------------------------------------------------------------------------
-- 1. the minute collection
-- ---------------------------------------------------------------------------------------------------------

-- every vacuum, analyze or autovacuum worker seen in a minute sample
CREATE TABLE IF NOT EXISTS pgvigil.vacuum_sample (
  instance_id          int NOT NULL,
  snapshot_at          timestamptz NOT NULL,
  kind                 text NOT NULL,          -- vacuum, analyze, worker (an autovacuum worker between tables)
  pid                  int NOT NULL,
  dbid                 bigint,
  datname              text,
  relid                bigint,
  table_name           text,                   -- schema.table: resolved in the connected database, else from the autovacuum query text
  backend_type         text,
  is_auto              boolean,                -- an autovacuum worker
  is_wraparound        boolean,                -- "(to prevent wraparound)" in the worker's query
  phase                text,                   -- NULL: not started (a VACUUM or ANALYZE waiting for its lock)
  heap_blks_total      bigint,
  heap_blks_scanned    bigint,
  heap_blks_vacuumed   bigint,
  index_vacuum_count   bigint,
  indexes_total        bigint,                 -- PG17+
  indexes_processed    bigint,                 -- PG17+
  dead_tuples          bigint,                 -- num_dead_tuples (to PG16), num_dead_item_ids (PG17+)
  max_dead_tuples      bigint,                 -- to PG16; PG17+ reports bytes (max_dead_tuple_bytes), not stored
  sample_blks_total    bigint,                 -- analyze
  sample_blks_scanned  bigint,
  xact_start           timestamptz,
  query_start          timestamptz,
  elapsed_secs         int,                    -- on the server's clock: now - query_start
  wait_event_type      text,
  wait_event           text,
  blocking_pids        int[],                  -- Lock waits only (pg_blocking_pids)
  query                text
) PARTITION BY RANGE (snapshot_at);

-- one row per vacuum or analyze of one table, folded from the samples (a run shorter than the sample
-- interval can be missed: the history is "seen running", the log's lines are the complete record)
CREATE TABLE IF NOT EXISTS pgvigil.vacuum_runs (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  pid                  int NOT NULL,
  started_at           timestamptz NOT NULL,   -- query_start of the run
  kind                 text NOT NULL,          -- vacuum or analyze
  dbid                 bigint,
  datname              text,
  relid                bigint,
  table_name           text,
  is_auto              boolean,
  is_wraparound        boolean,
  first_seen           timestamptz NOT NULL,
  last_seen            timestamptz NOT NULL,
  elapsed_secs         int,                    -- at the last sample: the run took at least this long
  last_phase           text,
  heap_blks_total      bigint,
  heap_blks_scanned    bigint,
  dead_tuples          bigint,
  index_vacuum_count   bigint,
  waited_lock          boolean NOT NULL DEFAULT false,
  samples              int NOT NULL DEFAULT 1,
  PRIMARY KEY (instance_id, pid, started_at)
);
CREATE INDEX IF NOT EXISTS vacuum_runs_seen ON pgvigil.vacuum_runs (instance_id, last_seen);

-- the autovacuum state of each instance: the minute columns from the vacuum collection, the settings
-- from the hourly vacuum_tables collection
CREATE TABLE IF NOT EXISTS pgvigil.vacuum_state (
  instance_id                  int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at                  timestamptz,    -- the last minute read (the "running now" rows are this snapshot's)
  autovacuum                   text,
  track_counts                 text,
  max_workers                  int,
  workers_running              int,
  vacuums_running              int,
  analyzes_running             int,
  settings_at                  timestamptz,    -- the last hourly read
  naptime_secs                 int,
  vacuum_threshold             double precision,
  vacuum_scale_factor          double precision,
  vacuum_max_threshold         double precision, -- PG18+; -1 = no cap
  insert_threshold             double precision, -- PG13+; -1 = insert-triggered vacuums off
  insert_scale_factor          double precision,
  analyze_threshold            double precision,
  analyze_scale_factor         double precision,
  freeze_max_age               bigint,
  mxid_freeze_max_age          bigint,
  failsafe_age                 bigint,          -- PG14+ vacuum_failsafe_age
  cost_limit                   int,
  cost_delay_ms                double precision,
  log_min_duration_ms          int              -- log_autovacuum_min_duration: -1 = autovacuum runs are not logged
);

-- the xmin holders that are not sessions, replaced by every minute read
CREATE TABLE IF NOT EXISTS pgvigil.vacuum_holders (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  holder        text NOT NULL,                -- slot, prepared, standby
  name          text NOT NULL,
  datname       text,
  xmin_age      bigint,
  catalog_xmin_age bigint,
  active        boolean,
  since         timestamptz,                  -- prepared: when; standby: backend_start
  detail        text
);
CREATE INDEX IF NOT EXISTS vacuum_holders_instance ON pgvigil.vacuum_holders (instance_id);

-- payload: {kind:'summary', autovacuum, track_counts, max_workers, workers_running}, {kind:'vacuum'|'analyze'|'worker', ...}
-- per running process, {kind:'holder', holder, name, ...} per non-session xmin holder.
CREATE OR REPLACE FUNCTION pgvigil.import_vacuum(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_vacuum'), p_instance_id);

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' IN ('vacuum', 'analyze', 'worker')) THEN
    PERFORM pgvigil.ensure_month_partition('vacuum_sample', p_snapshot_at);
    INSERT INTO pgvigil.vacuum_sample (instance_id, snapshot_at, kind, pid, dbid, datname, relid, table_name, backend_type, is_auto,
                                       is_wraparound, phase, heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
                                       index_vacuum_count, indexes_total, indexes_processed, dead_tuples, max_dead_tuples,
                                       sample_blks_total, sample_blks_scanned, xact_start, query_start, elapsed_secs,
                                       wait_event_type, wait_event, blocking_pids, query)
    SELECT p_instance_id, p_snapshot_at, r->>'kind', (r->>'pid')::int, (r->>'dbid')::bigint, r->>'datname', (r->>'relid')::bigint,
           r->>'table_name', r->>'backend_type', (r->>'is_auto')::boolean, (r->>'is_wraparound')::boolean, r->>'phase',
           (r->>'heap_blks_total')::bigint, (r->>'heap_blks_scanned')::bigint, (r->>'heap_blks_vacuumed')::bigint,
           (r->>'index_vacuum_count')::bigint, (r->>'indexes_total')::bigint, (r->>'indexes_processed')::bigint,
           (r->>'dead_tuples')::bigint, (r->>'max_dead_tuples')::bigint, (r->>'sample_blks_total')::bigint,
           (r->>'sample_blks_scanned')::bigint, (r->>'xact_start')::timestamptz, (r->>'query_start')::timestamptz,
           (r->>'elapsed_secs')::int, r->>'wait_event_type', r->>'wait_event',
           CASE WHEN jsonb_typeof(r->'blocking_pids') = 'array'
                THEN ARRAY(SELECT jsonb_array_elements_text(r->'blocking_pids')::int) END,
           r->>'query'
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' IN ('vacuum', 'analyze', 'worker');

    -- fold into the runs: one per (pid, query_start); a later sample of the same run moves last_seen and the
    -- progress, a table resolved later fills its name
    INSERT INTO pgvigil.vacuum_runs AS v (instance_id, pid, started_at, kind, dbid, datname, relid, table_name, is_auto, is_wraparound,
                                          first_seen, last_seen, elapsed_secs, last_phase, heap_blks_total, heap_blks_scanned,
                                          dead_tuples, index_vacuum_count, waited_lock, samples)
    SELECT DISTINCT ON ((r->>'pid')::int, (r->>'query_start')::timestamptz)
           p_instance_id, (r->>'pid')::int, (r->>'query_start')::timestamptz, r->>'kind', (r->>'dbid')::bigint, r->>'datname',
           (r->>'relid')::bigint, r->>'table_name', (r->>'is_auto')::boolean, (r->>'is_wraparound')::boolean,
           p_snapshot_at, p_snapshot_at, (r->>'elapsed_secs')::int, r->>'phase', (r->>'heap_blks_total')::bigint,
           (r->>'heap_blks_scanned')::bigint, (r->>'dead_tuples')::bigint, (r->>'index_vacuum_count')::bigint,
           coalesce(r->>'wait_event_type' = 'Lock', false), 1
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' IN ('vacuum', 'analyze') AND r->>'query_start' IS NOT NULL
     ORDER BY (r->>'pid')::int, (r->>'query_start')::timestamptz, r->>'kind' DESC   -- 'vacuum' over 'analyze' (VACUUM ANALYZE)
    ON CONFLICT (instance_id, pid, started_at) DO UPDATE SET
      kind = EXCLUDED.kind, dbid = coalesce(EXCLUDED.dbid, v.dbid), datname = coalesce(EXCLUDED.datname, v.datname),
      relid = coalesce(EXCLUDED.relid, v.relid), table_name = coalesce(EXCLUDED.table_name, v.table_name),
      is_wraparound = EXCLUDED.is_wraparound OR coalesce(v.is_wraparound, false),
      last_seen = greatest(v.last_seen, EXCLUDED.last_seen), elapsed_secs = greatest(v.elapsed_secs, EXCLUDED.elapsed_secs),
      last_phase = coalesce(EXCLUDED.last_phase, v.last_phase),
      heap_blks_total = coalesce(EXCLUDED.heap_blks_total, v.heap_blks_total),
      heap_blks_scanned = greatest(v.heap_blks_scanned, EXCLUDED.heap_blks_scanned),
      dead_tuples = greatest(v.dead_tuples, EXCLUDED.dead_tuples),
      index_vacuum_count = greatest(v.index_vacuum_count, EXCLUDED.index_vacuum_count),
      waited_lock = v.waited_lock OR EXCLUDED.waited_lock, samples = v.samples + 1;
  END IF;

  INSERT INTO pgvigil.vacuum_state AS s (instance_id, snapshot_at, autovacuum, track_counts, max_workers, workers_running,
                                          vacuums_running, analyzes_running)
  SELECT p_instance_id, p_snapshot_at, r->>'autovacuum', r->>'track_counts', (r->>'max_workers')::int, (r->>'workers_running')::int,
         (SELECT count(*) FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'vacuum'),
         (SELECT count(*) FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'analyze')
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'summary'
   LIMIT 1
  ON CONFLICT (instance_id) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, autovacuum = EXCLUDED.autovacuum, track_counts = EXCLUDED.track_counts,
    max_workers = EXCLUDED.max_workers, workers_running = EXCLUDED.workers_running,
    vacuums_running = EXCLUDED.vacuums_running, analyzes_running = EXCLUDED.analyzes_running;

  -- the holders are a current set: a read that reached the server replaces them (a payload without its
  -- summary row is not a read: nothing replaced)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'summary') THEN
    DELETE FROM pgvigil.vacuum_holders WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.vacuum_holders (instance_id, snapshot_at, holder, name, datname, xmin_age, catalog_xmin_age, active, since, detail)
    SELECT p_instance_id, p_snapshot_at, r->>'holder', r->>'name', r->>'datname', (r->>'xmin_age')::bigint,
           (r->>'catalog_xmin_age')::bigint, (r->>'active')::boolean, (r->>'since')::timestamptz, r->>'detail'
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'holder';
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- 2. the hourly collection
-- ---------------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.vacuum_databases (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid                 bigint NOT NULL,
  datname              text NOT NULL,
  snapshot_at          timestamptz NOT NULL,
  allow_conn           boolean,
  xid_age              bigint,                 -- age(datfrozenxid)
  mxid_age             bigint,                 -- mxid_age(datminmxid)
  tables_at            timestamptz,            -- when its tables were last read (NULL: never read, e.g. not connectable)
  user_tables          bigint,
  over_vacuum          bigint,                 -- dead rows over the vacuum threshold, autovacuum on
  over_insert          bigint,                 -- inserts since vacuum over the insert threshold (PG13+)
  over_analyze         bigint,                 -- changes since analyze over the analyze threshold
  autovacuum_off       bigint,                 -- autovacuum_enabled = false on the table
  never_vacuumed       bigint,                 -- with 1,000 rows or more
  is_present           boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid)
);

-- the tables of interest per database (a capped list: over or near a threshold, autovacuum off, never or long
-- unvacuumed, past half the freeze max age), the latest read
CREATE TABLE IF NOT EXISTS pgvigil.vacuum_tables (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid                 bigint NOT NULL,
  relid                bigint NOT NULL,
  datname              text NOT NULL,
  schema_name          text NOT NULL,
  table_name           text NOT NULL,
  snapshot_at          timestamptz NOT NULL,
  relkind              text,
  reltuples            double precision,
  n_live_tup           bigint,
  n_dead_tup           bigint,
  n_ins_since_vacuum   bigint,
  n_mod_since_analyze  bigint,
  vac_threshold        double precision,       -- the dead rows that trigger an autovacuum
  ins_threshold        double precision,       -- the inserts that trigger one (NULL: off, or before PG13)
  anl_threshold        double precision,       -- the changes that trigger an autoanalyze
  autovacuum_enabled   boolean,
  has_own_settings     boolean,                -- an autovacuum_* reloption on the table
  over_vacuum          boolean,
  over_insert          boolean,
  over_analyze         boolean,
  over_since           timestamptz,            -- the first read of the current streak over the vacuum or insert threshold
  last_vacuum          timestamptz,
  last_autovacuum      timestamptz,
  last_analyze         timestamptz,
  last_autoanalyze     timestamptz,
  autovacuum_count     bigint,
  autoanalyze_count    bigint,
  xid_age              bigint,
  mxid_age             bigint,
  freeze_max_age       bigint,                 -- the table's own (a reloption can only lower it) or the server's
  first_seen           timestamptz NOT NULL,
  is_present           boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid, relid)
);

-- payload: {kind:'settings', ...}, {kind:'wrap', dbid, datname, allow_conn, xid_age, mxid_age} per database,
-- {kind:'db', dbid, datname, user_tables, over_vacuum, ...} per database read, {kind:'table', ...} per table,
-- {kind:'collector_error', source:'vacuum_tables:<datname>' | 'vacuum_tables', message}. Absence is judged
-- only inside a database this payload read; a database that failed keeps its rows.
CREATE OR REPLACE FUNCTION pgvigil.import_vacuum_tables(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_vacuum_tables'), p_instance_id);

  INSERT INTO pgvigil.vacuum_state AS s (instance_id, settings_at, autovacuum, track_counts, max_workers, naptime_secs,
                                          vacuum_threshold, vacuum_scale_factor, vacuum_max_threshold, insert_threshold,
                                          insert_scale_factor, analyze_threshold, analyze_scale_factor, freeze_max_age,
                                          mxid_freeze_max_age, failsafe_age, cost_limit, cost_delay_ms, log_min_duration_ms)
  SELECT p_instance_id, p_snapshot_at, r->>'autovacuum', r->>'track_counts', (r->>'max_workers')::int, (r->>'naptime_secs')::int,
         (r->>'vacuum_threshold')::float8, (r->>'vacuum_scale_factor')::float8, (r->>'vacuum_max_threshold')::float8,
         (r->>'insert_threshold')::float8, (r->>'insert_scale_factor')::float8, (r->>'analyze_threshold')::float8,
         (r->>'analyze_scale_factor')::float8, (r->>'freeze_max_age')::bigint, (r->>'mxid_freeze_max_age')::bigint,
         (r->>'failsafe_age')::bigint, (r->>'cost_limit')::int, (r->>'cost_delay_ms')::float8, (r->>'log_min_duration_ms')::int
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'settings'
   LIMIT 1
  ON CONFLICT (instance_id) DO UPDATE SET
    settings_at = EXCLUDED.settings_at, naptime_secs = EXCLUDED.naptime_secs,
    -- the minute read owns these three while it runs; the hourly read fills them when it does not
    autovacuum = CASE WHEN s.snapshot_at > EXCLUDED.settings_at - interval '10 minutes' THEN s.autovacuum ELSE EXCLUDED.autovacuum END,
    track_counts = CASE WHEN s.snapshot_at > EXCLUDED.settings_at - interval '10 minutes' THEN s.track_counts ELSE EXCLUDED.track_counts END,
    max_workers = CASE WHEN s.snapshot_at > EXCLUDED.settings_at - interval '10 minutes' THEN s.max_workers ELSE EXCLUDED.max_workers END,
    vacuum_threshold = EXCLUDED.vacuum_threshold, vacuum_scale_factor = EXCLUDED.vacuum_scale_factor,
    vacuum_max_threshold = EXCLUDED.vacuum_max_threshold, insert_threshold = EXCLUDED.insert_threshold,
    insert_scale_factor = EXCLUDED.insert_scale_factor, analyze_threshold = EXCLUDED.analyze_threshold,
    analyze_scale_factor = EXCLUDED.analyze_scale_factor, freeze_max_age = EXCLUDED.freeze_max_age,
    mxid_freeze_max_age = EXCLUDED.mxid_freeze_max_age, failsafe_age = EXCLUDED.failsafe_age,
    cost_limit = EXCLUDED.cost_limit, cost_delay_ms = EXCLUDED.cost_delay_ms, log_min_duration_ms = EXCLUDED.log_min_duration_ms;

  -- the wraparound rows: every database of pg_database, read on the main connection
  INSERT INTO pgvigil.vacuum_databases AS d (instance_id, dbid, datname, snapshot_at, allow_conn, xid_age, mxid_age, is_present)
  SELECT p_instance_id, (r->>'dbid')::bigint, r->>'datname', p_snapshot_at, (r->>'allow_conn')::boolean,
         (r->>'xid_age')::bigint, (r->>'mxid_age')::bigint, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'wrap'
  ON CONFLICT (instance_id, dbid) DO UPDATE SET
    datname = EXCLUDED.datname, snapshot_at = EXCLUDED.snapshot_at, allow_conn = EXCLUDED.allow_conn,
    xid_age = EXCLUDED.xid_age, mxid_age = EXCLUDED.mxid_age, is_present = true;
  -- a database not in pg_database any more was dropped (only when the wrap read came: it is one statement)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'wrap') THEN
    UPDATE pgvigil.vacuum_databases d SET is_present = false
     WHERE d.instance_id = p_instance_id AND d.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'wrap' AND (r->>'dbid')::bigint = d.dbid);
    UPDATE pgvigil.vacuum_tables t SET is_present = false
     WHERE t.instance_id = p_instance_id AND t.is_present
       AND NOT EXISTS (SELECT 1 FROM pgvigil.vacuum_databases d WHERE d.instance_id = t.instance_id AND d.dbid = t.dbid AND d.is_present);
  END IF;

  UPDATE pgvigil.vacuum_databases d SET
    tables_at = p_snapshot_at, user_tables = (r->>'user_tables')::bigint, over_vacuum = (r->>'over_vacuum')::bigint,
    over_insert = (r->>'over_insert')::bigint, over_analyze = (r->>'over_analyze')::bigint,
    autovacuum_off = (r->>'autovacuum_off')::bigint, never_vacuumed = (r->>'never_vacuumed')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'db' AND d.instance_id = p_instance_id AND d.dbid = (r->>'dbid')::bigint;

  INSERT INTO pgvigil.vacuum_tables AS t (instance_id, dbid, relid, datname, schema_name, table_name, snapshot_at, relkind, reltuples,
                                          n_live_tup, n_dead_tup, n_ins_since_vacuum, n_mod_since_analyze, vac_threshold,
                                          ins_threshold, anl_threshold, autovacuum_enabled, has_own_settings, over_vacuum,
                                          over_insert, over_analyze, over_since, last_vacuum, last_autovacuum, last_analyze,
                                          last_autoanalyze, autovacuum_count, autoanalyze_count, xid_age, mxid_age, freeze_max_age,
                                          first_seen, is_present)
  SELECT p_instance_id, (r->>'dbid')::bigint, (r->>'relid')::bigint, r->>'datname', r->>'schema_name', r->>'table_name', p_snapshot_at,
         r->>'relkind', (r->>'reltuples')::float8, (r->>'n_live_tup')::bigint, (r->>'n_dead_tup')::bigint,
         (r->>'n_ins_since_vacuum')::bigint, (r->>'n_mod_since_analyze')::bigint, (r->>'vac_threshold')::float8,
         (r->>'ins_threshold')::float8, (r->>'anl_threshold')::float8, (r->>'autovacuum_enabled')::boolean,
         (r->>'has_own_settings')::boolean, (r->>'over_vacuum')::boolean, (r->>'over_insert')::boolean,
         (r->>'over_analyze')::boolean,
         CASE WHEN (r->>'over_vacuum')::boolean OR (r->>'over_insert')::boolean THEN p_snapshot_at END,
         (r->>'last_vacuum')::timestamptz, (r->>'last_autovacuum')::timestamptz, (r->>'last_analyze')::timestamptz,
         (r->>'last_autoanalyze')::timestamptz, (r->>'autovacuum_count')::bigint, (r->>'autoanalyze_count')::bigint,
         (r->>'xid_age')::bigint, (r->>'mxid_age')::bigint, (r->>'freeze_max_age')::bigint, p_snapshot_at, true
    FROM (SELECT DISTINCT ON ((r->>'dbid')::bigint, (r->>'relid')::bigint) r
            FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'table') x
  ON CONFLICT (instance_id, dbid, relid) DO UPDATE SET
    datname = EXCLUDED.datname, schema_name = EXCLUDED.schema_name, table_name = EXCLUDED.table_name,
    snapshot_at = EXCLUDED.snapshot_at, relkind = EXCLUDED.relkind, reltuples = EXCLUDED.reltuples,
    n_live_tup = EXCLUDED.n_live_tup, n_dead_tup = EXCLUDED.n_dead_tup, n_ins_since_vacuum = EXCLUDED.n_ins_since_vacuum,
    n_mod_since_analyze = EXCLUDED.n_mod_since_analyze, vac_threshold = EXCLUDED.vac_threshold,
    ins_threshold = EXCLUDED.ins_threshold, anl_threshold = EXCLUDED.anl_threshold,
    autovacuum_enabled = EXCLUDED.autovacuum_enabled, has_own_settings = EXCLUDED.has_own_settings,
    over_vacuum = EXCLUDED.over_vacuum, over_insert = EXCLUDED.over_insert, over_analyze = EXCLUDED.over_analyze,
    -- the streak continues only through reads that kept the table listed and over
    over_since = CASE WHEN EXCLUDED.over_since IS NULL THEN NULL
                      WHEN t.is_present AND t.over_since IS NOT NULL THEN t.over_since
                      ELSE EXCLUDED.over_since END,
    last_vacuum = EXCLUDED.last_vacuum, last_autovacuum = EXCLUDED.last_autovacuum, last_analyze = EXCLUDED.last_analyze,
    last_autoanalyze = EXCLUDED.last_autoanalyze, autovacuum_count = EXCLUDED.autovacuum_count,
    autoanalyze_count = EXCLUDED.autoanalyze_count, xid_age = EXCLUDED.xid_age, mxid_age = EXCLUDED.mxid_age,
    freeze_max_age = EXCLUDED.freeze_max_age, is_present = true;

  -- inside a database read this run, a table not listed is no longer of interest (or was dropped)
  UPDATE pgvigil.vacuum_tables t SET is_present = false, over_since = NULL
   WHERE t.instance_id = p_instance_id AND t.is_present
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = t.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'table' AND (r->>'dbid')::bigint = t.dbid AND (r->>'relid')::bigint = t.relid);
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- 3. views, checks, findings
-- ---------------------------------------------------------------------------------------------------------

-- the vacuums and analyzes running now: the latest minute read's rows, while that read is under 10 minutes old
CREATE OR REPLACE VIEW pgvigil.vacuum_running AS
SELECT v.*,
       CASE WHEN v.heap_blks_total > 0 THEN round(100.0 * v.heap_blks_scanned / v.heap_blks_total, 1) END AS scanned_pct
  FROM pgvigil.vacuum_state s
  JOIN pgvigil.vacuum_sample v ON v.instance_id = s.instance_id AND v.snapshot_at = s.snapshot_at
 WHERE s.snapshot_at > now() - interval '10 minutes';

-- the per-table autovacuum state with the hours over a threshold
CREATE OR REPLACE VIEW pgvigil.vacuum_table_state AS
SELECT t.*, t.datname || '.' || t.schema_name || '.' || t.table_name AS object,
       round((t.n_dead_tup / nullif(t.vac_threshold, 0))::numeric, 2) AS dead_ratio,
       round((t.n_ins_since_vacuum / nullif(t.ins_threshold, 0))::numeric, 2) AS ins_ratio,
       round((t.n_mod_since_analyze / nullif(t.anl_threshold, 0))::numeric, 2) AS anl_ratio,
       round(extract(epoch FROM t.snapshot_at - t.over_since)::numeric / 3600, 1) AS hours_over,
       round(100.0 * t.xid_age / nullif(t.freeze_max_age, 0), 1) AS freeze_pct
  FROM pgvigil.vacuum_tables t
 WHERE t.is_present;

-- wraparound per database: the ages against the freeze max ages (the server's) and the 2^31 horizon
CREATE OR REPLACE VIEW pgvigil.vacuum_wraparound AS
SELECT d.instance_id, d.dbid, d.datname, d.snapshot_at, d.allow_conn, d.xid_age, d.mxid_age,
       s.freeze_max_age, s.mxid_freeze_max_age, s.failsafe_age,
       round(100.0 * d.xid_age / nullif(s.freeze_max_age, 0), 1) AS xid_freeze_pct,
       round(100.0 * d.mxid_age / nullif(s.mxid_freeze_max_age, 0), 1) AS mxid_freeze_pct,
       round(100.0 * d.xid_age / 2147483648, 2) AS xid_horizon_pct,
       d.tables_at, d.user_tables, d.over_vacuum, d.over_insert, d.over_analyze, d.autovacuum_off, d.never_vacuumed
  FROM pgvigil.vacuum_databases d
  LEFT JOIN pgvigil.vacuum_state s ON s.instance_id = d.instance_id
 WHERE d.is_present;

-- who holds the xmin horizon back: the sessions of the latest activity sample (under 10 minutes old) with a
-- backend_xmin, plus the slots, prepared transactions and standbys of the latest vacuum read
CREATE OR REPLACE VIEW pgvigil.vacuum_xmin_holders AS
SELECT a.instance_id, a.snapshot_at, 'session' AS holder, a.pid::text AS name, a.datname, a.backend_xmin_age::bigint AS xmin_age,
       NULL::bigint AS catalog_xmin_age, a.state <> 'idle' AS active, a.xact_start AS since,
       coalesce(a.usename, '') || coalesce(' / ' || nullif(a.application_name, ''), '') || ', ' || coalesce(a.state, '?')
       || coalesce(', ' || a.backend_type, '') || coalesce(': ' || left(q.query, 200), '') AS detail
  FROM pgvigil.activity_sample a
  JOIN (SELECT instance_id, max(snapshot_at) AS at FROM pgvigil.activity_summary
         WHERE snapshot_at > now() - interval '10 minutes' GROUP BY instance_id) l
    ON l.instance_id = a.instance_id AND l.at = a.snapshot_at
  LEFT JOIN pgvigil.query_text q ON q.query_hash = a.query_hash
 WHERE a.backend_xmin_age IS NOT NULL
UNION ALL
SELECT h.instance_id, h.snapshot_at, h.holder, h.name, h.datname, h.xmin_age, h.catalog_xmin_age, h.active, h.since, h.detail
  FROM pgvigil.vacuum_holders h
  JOIN pgvigil.vacuum_state s ON s.instance_id = h.instance_id
 WHERE s.snapshot_at > now() - interval '10 minutes';

-- The vacuum checks, one row per finding: instance_id, severity, check_name, object, at, detail (the overview's
-- shape; its "vacuum" group is the Summary column Vacuum).
--   autovacuum off             - the server setting (critical): no dead-row cleanup, only the forced freeze
--   table over vacuum threshold- dead rows (or inserts) over the table's autovacuum threshold in every hourly
--                                read for 6 hours (warning) or 24 (critical): autovacuum is not reaching it
--                                (workers busy, a lock, a held xmin, a cost limit too low)
--   wraparound                 - age(datfrozenxid) or mxid_age(datminmxid) over 50 % of the freeze max age
--                                (warning), over 1,000,000,000 or the failsafe age (critical)
--   vacuum running over an hour- a vacuum or analyze running for an hour or more now
--   vacuum waiting on a lock   - a vacuum or analyze waiting on a heavyweight lock now (critical when it is an
--                                anti-wraparound one), with the blocking pids
CREATE OR REPLACE VIEW pgvigil.vacuum_checks AS
SELECT s.instance_id, 'critical' AS severity, 'autovacuum off' AS check_name, 'autovacuum' AS object,
       coalesce(s.snapshot_at, s.settings_at) AS at,
       'autovacuum = ' || s.autovacuum || ': dead rows are never cleaned up automatically and only the forced anti-wraparound vacuum runs' AS detail
  FROM pgvigil.vacuum_state s
 WHERE s.autovacuum IS NOT NULL AND s.autovacuum <> 'on'
UNION ALL
SELECT t.instance_id, CASE WHEN t.hours_over >= 24 THEN 'critical' ELSE 'warning' END, 'table over vacuum threshold', t.object, t.snapshot_at,
       'over its autovacuum threshold for ' || t.hours_over::text || ' h: '
       || CASE WHEN t.over_vacuum THEN t.n_dead_tup::text || ' dead rows against ' || round(t.vac_threshold)::text
               ELSE t.n_ins_since_vacuum::text || ' inserts against ' || round(t.ins_threshold)::text END
       || '; last autovacuum ' || coalesce(to_char(t.last_autovacuum AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'never recorded')
  FROM pgvigil.vacuum_table_state t
 WHERE t.hours_over >= 6 AND t.autovacuum_enabled
UNION ALL
SELECT w.instance_id,
       CASE WHEN greatest(w.xid_age, w.mxid_age) >= 1000000000 OR w.xid_age >= coalesce(w.failsafe_age, 1600000000) THEN 'critical' ELSE 'warning' END,
       'wraparound', w.datname, w.snapshot_at,
       'xid age ' || w.xid_age::text || ' (' || coalesce(w.xid_freeze_pct::text, '?') || ' % of autovacuum_freeze_max_age '
       || coalesce(w.freeze_max_age::text, '?') || '), multixact age ' || coalesce(w.mxid_age::text, '?') || ' ('
       || coalesce(w.mxid_freeze_pct::text, '?') || ' %): find what holds the xmin horizon back'
  FROM pgvigil.vacuum_wraparound w
 WHERE w.xid_freeze_pct > 50 OR w.mxid_freeze_pct > 50 OR greatest(w.xid_age, w.mxid_age) >= 1000000000
UNION ALL
SELECT r.instance_id, 'warning', 'vacuum running over an hour',
       coalesce(r.datname || '.' || r.table_name, r.datname || ' relid ' || r.relid::text, 'pid ' || r.pid::text), r.snapshot_at,
       CASE WHEN r.is_auto THEN 'autovacuum' ELSE 'manual' END || ' ' || r.kind
       || CASE WHEN r.is_wraparound THEN ' (to prevent wraparound)' ELSE '' END || ', pid ' || r.pid::text || ', running '
       || (r.elapsed_secs / 60)::text || ' min, phase ' || coalesce(r.phase, 'not started')
       || coalesce(', ' || r.scanned_pct::text || ' % of the heap scanned', '')
  FROM pgvigil.vacuum_running r
 WHERE r.kind IN ('vacuum', 'analyze') AND r.elapsed_secs >= 3600
UNION ALL
SELECT r.instance_id, CASE WHEN r.is_wraparound THEN 'critical' ELSE 'warning' END, 'vacuum waiting on a lock',
       coalesce(r.datname || '.' || r.table_name, r.datname || ' relid ' || r.relid::text, 'pid ' || r.pid::text), r.snapshot_at,
       CASE WHEN r.is_auto THEN 'autovacuum' ELSE 'manual' END || ' ' || r.kind || ', pid ' || r.pid::text || ', waiting on '
       || coalesce(r.wait_event, 'a lock') || ' for up to ' || (r.elapsed_secs / 60)::text || ' min'
       || coalesce(', blocked by pid ' || array_to_string(r.blocking_pids, ', '), '')
  FROM pgvigil.vacuum_running r
 WHERE r.kind IN ('vacuum', 'analyze') AND r.wait_event_type = 'Lock';

-- the same rows in the findings shape (the join UNION ALLs this view into pgvigil.findings)
CREATE OR REPLACE VIEW pgvigil.vacuum_findings AS
SELECT c.instance_id, c.severity, c.check_name AS setting, c.object AS value, true AS is_set,
       CASE c.check_name
         WHEN 'autovacuum off' THEN 'on'
         WHEN 'table over vacuum threshold' THEN 'autovacuum reaches it within the hour'
         WHEN 'wraparound' THEN 'under 50 % of autovacuum_freeze_max_age'
         WHEN 'vacuum running over an hour' THEN 'under an hour'
         ELSE 'no lock wait' END AS suggested,
       'all' AS platforms, c.detail, 'pgvigil' AS source, c.at
  FROM pgvigil.vacuum_checks c;

-- The vacuum and analyze runs of a window, newest first: the runs seen in the minute samples, and the
-- server log's "automatic vacuum of table" entries where the log is read (log_events kind 'autovacuum').
-- The log's entries come once a log reader parses them; the kind is allowed here so the reader needs no
-- migration of its own.
ALTER TABLE pgvigil.log_events DROP CONSTRAINT IF EXISTS log_events_kind_check;
ALTER TABLE pgvigil.log_events ADD CONSTRAINT log_events_kind_check
  CHECK (kind IN ('slow', 'lock_wait', 'deadlock', 'auth_fail', 'autovacuum'));

CREATE OR REPLACE FUNCTION pgvigil.vacuum_history(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (source text, started_at timestamptz, ended_at timestamptz, kind text, datname text, table_name text, is_auto boolean,
               is_wraparound boolean, elapsed_secs int, last_phase text, heap_blks_total bigint, heap_blks_scanned bigint,
               dead_tuples bigint, index_vacuum_count bigint, waited_lock boolean, detail text)
LANGUAGE sql STABLE AS $$
  SELECT 'sample', r.started_at, r.last_seen, r.kind, r.datname, r.table_name, r.is_auto, r.is_wraparound, r.elapsed_secs,
         r.last_phase, r.heap_blks_total, r.heap_blks_scanned, r.dead_tuples, r.index_vacuum_count, r.waited_lock,
         NULL::text
    FROM pgvigil.vacuum_runs r
   WHERE r.instance_id = p_instance_id AND r.last_seen >= p_from AND r.started_at <= p_to
  UNION ALL
  SELECT 'log', e.snapshot_at - make_interval(secs => coalesce(e.duration_ms, 0) / 1000), e.snapshot_at, 'vacuum', e.datname,
         e.statement, true, coalesce(e.detail ~* 'to prevent wraparound', false), (e.duration_ms / 1000)::int, NULL, NULL, NULL,
         NULL, NULL, false, e.detail
    FROM pgvigil.log_events e
   WHERE e.instance_id = p_instance_id AND e.kind = 'autovacuum' AND e.snapshot_at >= p_from AND e.snapshot_at <= p_to
   ORDER BY 2 DESC
   LIMIT 2000
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 4. retention: pgvigil.purge() is re-created once by the wave's join migration; it takes from here the
--    partitioned table vacuum_sample, and these deletes:
--      DELETE FROM pgvigil.vacuum_runs WHERE last_seen < now() - make_interval(days => p_days);
--      DELETE FROM pgvigil.vacuum_tables WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
--      DELETE FROM pgvigil.vacuum_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
-- ---------------------------------------------------------------------------------------------------------
