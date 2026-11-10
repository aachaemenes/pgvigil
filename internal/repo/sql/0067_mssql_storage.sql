-- 0067: SQL Server storage, the version store, and the SQL Server side of the actions door.
--
-- mssql_storage (hourly):
--   mssql_files            the current row per database file: its size, the space used inside it where the login could
--                          enter the database (used_read false = the allocated size only, with the reason), its
--                          maximum, its growth as a size or a per cent, the volume it sits on; the previous size and
--                          the time the size changed; is_present false = the server no longer lists the file.
--   mssql_volumes          the current row per volume the files sit on (sys.dm_os_volume_stats): total and free.
--   mssql_volume_sample    the volumes over time (partitioned by month).
--   mssql_database_size    each database's data and log size over time (partitioned by month).
-- mssql_versionstore (every minute):
--   mssql_versionstore_sample  the tempdb version store over time (partitioned by month): the counter's size, the
--                          pages reserved in tempdb, tempdb's data size, the generation and cleanup rates as the
--                          deltas of the two cumulative counters between this read and the one before, and THE
--                          HOLDER: the oldest active snapshot transaction with its session, login, program, start,
--                          elapsed time and last statement (NULLs = no snapshot transaction was active).
--   mssql_versionstore_db  the version store per database as last read (SQL Server 2016 SP2 and later).
--   mssql_pvs              the persistent version store of accelerated database recovery per database as last read
--                          (SQL Server 2019 and later).
-- mssql_storage_findings   the slice's findings in the findings columns (the join adds the arm to pgvigil.findings).
--
-- The actions door: pgvigil.actions_log (0028) gains the SQL Server actions (kill, job_start, job_stop) with the
-- statement sent and the server's own message; a job action has no pid. import_mssql_actions_log is its door.
--
-- Partition parents for purge(): mssql_volume_sample, mssql_database_size, mssql_versionstore_sample.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_files (
  instance_id        int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_id        int NOT NULL,
  file_id            int NOT NULL,
  database_name      text NOT NULL,
  database_state     text,                    -- ONLINE, RESTORING, OFFLINE ...
  file_name          text,                    -- the logical name
  type_desc          text,                    -- ROWS | LOG | FILESTREAM | FULLTEXT
  filegroup          text,                    -- NULL for a log file and for a database the login could not enter
  physical_name      text,
  state_desc         text,
  size_bytes         bigint,
  used_bytes         bigint,                  -- NULL = not read
  used_read          boolean NOT NULL DEFAULT false,
  used_note          text,                    -- why the used space was not read
  max_size_bytes     bigint,                  -- NULL = grows until the volume is full
  growth_bytes       bigint,                  -- a growth step as a size; 0 with growth_pct 0 = the file does not grow
  growth_pct         int,                     -- a growth step as a per cent of the file
  volume             text,
  snapshot_at        timestamptz NOT NULL,
  first_seen         timestamptz NOT NULL,
  previous_size_bytes bigint,
  size_changed_at    timestamptz,
  is_present         boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, database_id, file_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_volumes (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  volume        text NOT NULL,                -- the mount point; where the server names none (Linux), the files' directory
  logical_name  text,
  file_system   text,
  total_bytes   bigint,
  free_bytes    bigint,
  files         int,
  snapshot_at   timestamptz NOT NULL,
  is_present    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, volume)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_volume_sample (
  instance_id  int NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  volume       text NOT NULL,
  total_bytes  bigint,
  free_bytes   bigint
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_database_size (
  instance_id      int NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  database_name    text NOT NULL,
  data_bytes       bigint,
  log_bytes        bigint,
  data_used_bytes  bigint,                    -- NULL = not read
  log_used_bytes   bigint,
  files            int
) PARTITION BY RANGE (snapshot_at);

-- The pages read one database's or one volume's line over up to a year: an index that starts with the name (each
-- monthly partition also gets ensure_month_partition's own on instance_id, snapshot_at).
CREATE INDEX IF NOT EXISTS mssql_database_size_inst_db_idx ON pgvigil.mssql_database_size (instance_id, database_name, snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_volume_sample_inst_vol_idx ON pgvigil.mssql_volume_sample (instance_id, volume, snapshot_at);

-- payload: {kind:'file', database_id, database_name, database_state, file_id, file_name, type_desc, filegroup,
--           physical_name, state_desc, size_bytes, used_bytes, used_read (0|1), used_note, max_size_bytes,
--           growth_bytes, growth_pct, volume},
--          {kind:'volume', volume, logical_name, file_system, total_bytes, free_bytes, files},
--          {kind:'collector_error', source, message}.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_storage(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_storage: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_storage'), p_instance_id);
  PERFORM pgvigil.ensure_month_partition('mssql_volume_sample', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_database_size', p_snapshot_at);

  INSERT INTO pgvigil.mssql_files AS f (instance_id, database_id, file_id, database_name, database_state, file_name, type_desc,
      filegroup, physical_name, state_desc, size_bytes, used_bytes, used_read, used_note, max_size_bytes, growth_bytes, growth_pct,
      volume, snapshot_at, first_seen, is_present)
  SELECT p_instance_id, (r->>'database_id')::int, (r->>'file_id')::int, r->>'database_name', r->>'database_state', r->>'file_name',
         r->>'type_desc', r->>'filegroup', r->>'physical_name', r->>'state_desc', (r->>'size_bytes')::bigint, (r->>'used_bytes')::bigint,
         coalesce((r->>'used_read')::int, 0) = 1, r->>'used_note', (r->>'max_size_bytes')::bigint, (r->>'growth_bytes')::bigint,
         (r->>'growth_pct')::int, r->>'volume', p_snapshot_at, p_snapshot_at, true
    FROM (SELECT DISTINCT ON ((r->>'database_id')::int, (r->>'file_id')::int) r FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'file' AND r->>'database_id' IS NOT NULL AND r->>'file_id' IS NOT NULL AND r->>'database_name' IS NOT NULL) x
  ON CONFLICT (instance_id, database_id, file_id) DO UPDATE SET
      -- a database id given to another database starts the file's history again
      previous_size_bytes = CASE WHEN f.database_name IS DISTINCT FROM EXCLUDED.database_name THEN NULL
                                 WHEN f.size_bytes IS DISTINCT FROM EXCLUDED.size_bytes THEN f.size_bytes ELSE f.previous_size_bytes END,
      size_changed_at = CASE WHEN f.database_name IS DISTINCT FROM EXCLUDED.database_name THEN NULL
                             WHEN f.size_bytes IS DISTINCT FROM EXCLUDED.size_bytes THEN EXCLUDED.snapshot_at ELSE f.size_changed_at END,
      first_seen = CASE WHEN f.database_name IS DISTINCT FROM EXCLUDED.database_name THEN EXCLUDED.snapshot_at ELSE f.first_seen END,
      database_name = EXCLUDED.database_name, database_state = EXCLUDED.database_state, file_name = EXCLUDED.file_name,
      type_desc = EXCLUDED.type_desc, filegroup = EXCLUDED.filegroup, physical_name = EXCLUDED.physical_name,
      state_desc = EXCLUDED.state_desc, size_bytes = EXCLUDED.size_bytes, used_bytes = EXCLUDED.used_bytes,
      used_read = EXCLUDED.used_read, used_note = EXCLUDED.used_note, max_size_bytes = EXCLUDED.max_size_bytes,
      growth_bytes = EXCLUDED.growth_bytes, growth_pct = EXCLUDED.growth_pct, volume = EXCLUDED.volume,
      snapshot_at = EXCLUDED.snapshot_at, is_present = true
  WHERE f.snapshot_at <= EXCLUDED.snapshot_at;

  -- a file the server no longer lists stays as last read, marked gone; only when this payload read the files at all
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'file') THEN
    UPDATE pgvigil.mssql_files f SET is_present = false
     WHERE f.instance_id = p_instance_id AND f.is_present AND f.snapshot_at < p_snapshot_at;

    -- a payload imported twice at one snapshot time leaves one row per database, not two
    DELETE FROM pgvigil.mssql_database_size WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    INSERT INTO pgvigil.mssql_database_size (instance_id, snapshot_at, database_name, data_bytes, log_bytes, data_used_bytes, log_used_bytes, files)
    SELECT p_instance_id, p_snapshot_at, f.database_name,
           coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc <> 'LOG'), 0), coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc = 'LOG'), 0),
           -- used: a figure only when every file of that side was read
           CASE WHEN bool_and(f.used_read) FILTER (WHERE f.type_desc <> 'LOG') THEN sum(f.used_bytes) FILTER (WHERE f.type_desc <> 'LOG') END,
           CASE WHEN bool_and(f.used_read) FILTER (WHERE f.type_desc = 'LOG') THEN sum(f.used_bytes) FILTER (WHERE f.type_desc = 'LOG') END,
           count(*)
      FROM pgvigil.mssql_files f
     WHERE f.instance_id = p_instance_id AND f.is_present AND f.snapshot_at = p_snapshot_at
     GROUP BY f.database_name;
  END IF;

  INSERT INTO pgvigil.mssql_volumes AS v (instance_id, volume, logical_name, file_system, total_bytes, free_bytes, files, snapshot_at, is_present)
  SELECT p_instance_id, r->>'volume', r->>'logical_name', r->>'file_system', (r->>'total_bytes')::bigint, (r->>'free_bytes')::bigint,
         (r->>'files')::int, p_snapshot_at, true
    FROM (SELECT DISTINCT ON (r->>'volume') r FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'volume' AND r->>'volume' IS NOT NULL) x
  ON CONFLICT (instance_id, volume) DO UPDATE SET
      logical_name = EXCLUDED.logical_name, file_system = EXCLUDED.file_system, total_bytes = EXCLUDED.total_bytes,
      free_bytes = EXCLUDED.free_bytes, files = EXCLUDED.files, snapshot_at = EXCLUDED.snapshot_at, is_present = true
  WHERE v.snapshot_at <= EXCLUDED.snapshot_at;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'volume') THEN
    UPDATE pgvigil.mssql_volumes v SET is_present = false
     WHERE v.instance_id = p_instance_id AND v.is_present AND v.snapshot_at < p_snapshot_at;
    DELETE FROM pgvigil.mssql_volume_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    INSERT INTO pgvigil.mssql_volume_sample (instance_id, snapshot_at, volume, total_bytes, free_bytes)
    SELECT p_instance_id, p_snapshot_at, v.volume, v.total_bytes, v.free_bytes
      FROM pgvigil.mssql_volumes v
     WHERE v.instance_id = p_instance_id AND v.is_present AND v.snapshot_at = p_snapshot_at;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_versionstore_sample (
  instance_id         int NOT NULL,
  snapshot_at         timestamptz NOT NULL,
  store_bytes         bigint,                 -- the counter 'Version Store Size (KB)'
  reserved_bytes      bigint,                 -- version_store_reserved_page_count of tempdb's files
  tempdb_data_bytes   bigint,                 -- total_page_count of tempdb's data files
  generation_raw_kb   bigint,                 -- 'Version Generation rate (KB/s)': a cumulative counter, as read
  cleanup_raw_kb      bigint,                 -- 'Version Cleanup rate (KB/s)': a cumulative counter, as read
  generation_kb_s     numeric,                -- the delta against the read before, per second; NULL = no read before
  cleanup_kb_s        numeric,
  snapshot_tx_count   int,                    -- active transactions that generate or may read row versions
  holder_session_id   int,                    -- the oldest of them: NULL = none
  holder_login        text,
  holder_host         text,
  holder_program      text,
  holder_database     text,                   -- the session's current database
  holder_is_snapshot  boolean,                -- a snapshot isolation transaction (false: read committed snapshot, a trigger, MARS, an online index build)
  holder_started_at   timestamptz,
  holder_elapsed_s    bigint,
  holder_statement    text                    -- its last statement (the input buffer)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_versionstore_db (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name   text NOT NULL,
  reserved_bytes  bigint,
  snapshot_at     timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pvs (
  instance_id                 int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name               text NOT NULL,
  adr_on                      boolean,
  pvs_bytes                   bigint,
  online_index_bytes          bigint,
  aborted_tx_count            bigint,
  oldest_active_tx_id         bigint,
  oldest_aborted_tx_id        bigint,
  oldest_tx_session_id        int,           -- the session of the oldest active transaction, where it still runs
  oldest_tx_started_at        timestamptz,
  snapshot_at                 timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name)
);

-- payload: {kind:'store', store_kb, reserved_kb, tempdb_data_kb, generation_raw_kb, cleanup_raw_kb, snapshot_tx_count},
--          {kind:'holder', session_id, login_name, host_name, program_name, database_name, is_snapshot (0|1),
--           started_at_utc, elapsed_s, statement},
--          {kind:'db', database_name, reserved_kb}, {kind:'pvs', database_name, adr_on (0|1), pvs_kb, online_index_kb,
--           aborted_tx_count, oldest_active_tx_id, oldest_aborted_tx_id, oldest_tx_session_id, oldest_tx_started_at_utc},
--          {kind:'collector_error', source, message}.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_versionstore(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s    jsonb;
  v_h    jsonb;
  v_prev record;
  v_secs numeric;
  v_gen  numeric;
  v_cln  numeric;
  v_newer boolean;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_versionstore: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_versionstore'), p_instance_id);
  PERFORM pgvigil.ensure_month_partition('mssql_versionstore_sample', p_snapshot_at);
  SELECT r INTO v_s FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'store' LIMIT 1;
  SELECT r INTO v_h FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'holder' LIMIT 1;

  IF v_s IS NOT NULL THEN
    -- the rates: the cumulative counters against the read before, when that read is recent enough to be a rate
    SELECT s.snapshot_at, s.generation_raw_kb, s.cleanup_raw_kb INTO v_prev
      FROM pgvigil.mssql_versionstore_sample s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at < p_snapshot_at AND s.snapshot_at > p_snapshot_at - interval '10 minutes'
     ORDER BY s.snapshot_at DESC LIMIT 1;
    IF FOUND THEN
      v_secs := extract(epoch FROM p_snapshot_at - v_prev.snapshot_at);
      -- a counter below the read before = the server restarted in between: no rate for this read
      IF v_secs > 0 AND (v_s->>'generation_raw_kb')::bigint >= v_prev.generation_raw_kb THEN
        v_gen := round(((v_s->>'generation_raw_kb')::bigint - v_prev.generation_raw_kb) / v_secs, 3);
      END IF;
      IF v_secs > 0 AND (v_s->>'cleanup_raw_kb')::bigint >= v_prev.cleanup_raw_kb THEN
        v_cln := round(((v_s->>'cleanup_raw_kb')::bigint - v_prev.cleanup_raw_kb) / v_secs, 3);
      END IF;
    END IF;
    DELETE FROM pgvigil.mssql_versionstore_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    INSERT INTO pgvigil.mssql_versionstore_sample (instance_id, snapshot_at, store_bytes, reserved_bytes, tempdb_data_bytes,
        generation_raw_kb, cleanup_raw_kb, generation_kb_s, cleanup_kb_s, snapshot_tx_count, holder_session_id, holder_login,
        holder_host, holder_program, holder_database, holder_is_snapshot, holder_started_at, holder_elapsed_s, holder_statement)
    VALUES (p_instance_id, p_snapshot_at, (v_s->>'store_kb')::bigint * 1024, (v_s->>'reserved_kb')::bigint * 1024,
        (v_s->>'tempdb_data_kb')::bigint * 1024, (v_s->>'generation_raw_kb')::bigint, (v_s->>'cleanup_raw_kb')::bigint, v_gen, v_cln,
        (v_s->>'snapshot_tx_count')::int, (v_h->>'session_id')::int, v_h->>'login_name', v_h->>'host_name', v_h->>'program_name',
        v_h->>'database_name', (v_h->>'is_snapshot')::int = 1, (v_h->>'started_at_utc')::timestamptz, (v_h->>'elapsed_s')::bigint,
        v_h->>'statement');
  END IF;

  -- the two per-database states are replaced whole by a read that carried them. A newer read never loses to an
  -- older one: every read stores its sample row, so a sample past this payload's time means a newer read has been
  -- imported already (also one that listed no database and left the state empty)
  v_newer := EXISTS (SELECT 1 FROM pgvigil.mssql_versionstore_sample s WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_snapshot_at);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db') AND NOT v_newer THEN
    DELETE FROM pgvigil.mssql_versionstore_db WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_versionstore_db (instance_id, database_name, reserved_bytes, snapshot_at)
    SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', (r->>'reserved_kb')::bigint * 1024, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND r->>'database_name' IS NOT NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'pvs') AND NOT v_newer THEN
    DELETE FROM pgvigil.mssql_pvs WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_pvs (instance_id, database_name, adr_on, pvs_bytes, online_index_bytes, aborted_tx_count,
        oldest_active_tx_id, oldest_aborted_tx_id, oldest_tx_session_id, oldest_tx_started_at, snapshot_at)
    SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', (r->>'adr_on')::int = 1, (r->>'pvs_kb')::bigint * 1024,
           (r->>'online_index_kb')::bigint * 1024, (r->>'aborted_tx_count')::bigint, (r->>'oldest_active_tx_id')::bigint,
           (r->>'oldest_aborted_tx_id')::bigint, (r->>'oldest_tx_session_id')::int, (r->>'oldest_tx_started_at_utc')::timestamptz, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'pvs' AND r->>'database_name' IS NOT NULL;
  END IF;
END $$;

-- The newest version store read per instance, with the ten minutes before it summed up: how many reads carried a
-- rate, whether cleanup stood at zero in every one, and the store's size at the window's start.
CREATE OR REPLACE VIEW pgvigil.mssql_versionstore_latest AS
SELECT l.*, w.reads_10m, w.cleanup_zero_10m, w.generated_10m, w.first_reserved_bytes, w.first_at
  FROM (SELECT DISTINCT ON (s.instance_id) s.*
          FROM pgvigil.mssql_versionstore_sample s
         WHERE s.snapshot_at > now() - interval '1 day'
         ORDER BY s.instance_id, s.snapshot_at DESC) l
  LEFT JOIN LATERAL (
        SELECT count(*) FILTER (WHERE x.cleanup_kb_s IS NOT NULL) AS reads_10m,
               coalesce(bool_and(x.cleanup_kb_s = 0) FILTER (WHERE x.cleanup_kb_s IS NOT NULL), false) AS cleanup_zero_10m,
               coalesce(bool_or(x.generation_kb_s > 0), false) AS generated_10m,
               (array_agg(x.reserved_bytes ORDER BY x.snapshot_at))[1] AS first_reserved_bytes,
               min(x.snapshot_at) AS first_at
          FROM pgvigil.mssql_versionstore_sample x
         WHERE x.instance_id = l.instance_id AND x.snapshot_at <= l.snapshot_at AND x.snapshot_at >= l.snapshot_at - interval '10 minutes 30 seconds'
       ) w ON true;

-- The findings of the slice. Thresholds: a volume under 10 % free (warning) or 5 % (critical); a file that can grow
-- no further (critical) or has at most one growth step left (warning); a per cent growth on a file over 10 GiB
-- (info); a database whose log files are larger than its data files, from 1 GiB of log (info); a version store
-- that grew over ten minutes of reads in which cleanup stood at zero (warning, the holder in the detail); a version
-- store over a third of tempdb's data files (warning); a persistent version store over 1 GiB and over a tenth of
-- its database's data files with aborted transactions (warning). A read older than three hours (storage) or fifteen
-- minutes (version store) raises nothing: the Collections page says the collection is stale.
CREATE OR REPLACE VIEW pgvigil.mssql_storage_findings AS
SELECT v.instance_id, CASE WHEN 100.0 * v.free_bytes / v.total_bytes < 5 THEN 'critical' ELSE 'warning' END AS severity,
       'a volume under 10 % free'::text AS check_name, v.volume AS object, v.snapshot_at AS at,
       format('%s free of %s (%s %%); %s database file(s) sit on it', pg_size_pretty(v.free_bytes), pg_size_pretty(v.total_bytes),
              round(100.0 * v.free_bytes / v.total_bytes, 1), v.files) AS detail
  FROM pgvigil.mssql_volumes v
 WHERE v.is_present AND v.total_bytes > 0 AND v.free_bytes IS NOT NULL AND 100.0 * v.free_bytes / v.total_bytes < 10
   AND v.snapshot_at > now() - interval '3 hours'
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
   AND f.size_bytes + CASE WHEN f.growth_pct > 0 THEN f.size_bytes * f.growth_pct / 100 ELSE f.growth_bytes END >= f.max_size_bytes
   AND f.snapshot_at > now() - interval '3 hours'
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

-- The actions door, the SQL Server side: the same audit table. A PostgreSQL row keeps its shape (engine postgres:
-- cancel or terminate with a pid, explain_analyze without one, 0029); a SQL Server row is a kill (pid = the session
-- id, backend_start = the session's login time), or a job_start / job_stop (no pid; target = the job's name,
-- target_id = its job_id). statement (0029's column) holds the statement sent, or that would have been sent.
ALTER TABLE pgvigil.actions_log ADD COLUMN IF NOT EXISTS engine text NOT NULL DEFAULT 'postgres';
ALTER TABLE pgvigil.actions_log ADD COLUMN IF NOT EXISTS server_message text;   -- the server's own message for it
ALTER TABLE pgvigil.actions_log ADD COLUMN IF NOT EXISTS target_host text;
ALTER TABLE pgvigil.actions_log ADD COLUMN IF NOT EXISTS target text;
ALTER TABLE pgvigil.actions_log ADD COLUMN IF NOT EXISTS target_id text;
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_action_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_action_check CHECK (
     (engine = 'postgres' AND action IN ('cancel', 'terminate', 'explain_analyze'))
  OR (engine = 'sqlserver' AND action IN ('kill', 'job_start', 'job_stop')));
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_pid_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_pid_check CHECK (pid IS NOT NULL OR action IN ('explain_analyze', 'job_start', 'job_stop'));

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_actions_log(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_actions_log: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  INSERT INTO pgvigil.actions_log (instance_id, instance_name, at, ui_user, client, engine, action, pid, backend_start,
                                   target_user, target_app, target_host, target, target_id, reason, outcome, detail, statement, server_message)
  SELECT p_instance_id, x.instance_name, coalesce(x.at, p_snapshot_at), x.ui_user, nullif(x.client, ''), 'sqlserver', x.action, x.pid,
         x.backend_start, nullif(x.target_user, ''), nullif(x.target_app, ''), nullif(x.target_host, ''), nullif(x.target, ''),
         nullif(x.target_id, ''), x.reason, x.outcome, nullif(x.detail, ''), nullif(x.statement, ''), nullif(x.server_message, '')
    FROM jsonb_to_recordset(p_payload) AS x(instance_name text, at timestamptz, ui_user text, client text, action text,
                                            pid int, backend_start timestamptz, target_user text, target_app text, target_host text,
                                            target text, target_id text, reason text, outcome text, detail text, statement text,
                                            server_message text);
END $$;
