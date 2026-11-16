-- 0158 SQL Server storage depth (task 407, build B13 of the SQL Server tools audit): what SQLWATCH, SQLMonitor,
-- dbachecks, Telegraf and windows_exporter show of a SQL Server's storage that pgvigil did not. Every object here is
-- new or a column added; the three imports below are re-created with their old bodies whole plus the new columns.
--
--   tempdb's pages      mssql_versionstore_sample gains the user-object, internal-object, mixed-extent and unallocated
--                       pages of tempdb's data files (the same minute read of tempdb.sys.dm_db_file_space_usage that
--                       already gave the version store and the total); import_mssql_versionstore re-created.
--   file IO             mssql_fileio_sample gains the resource governor's queued read and write stall per file
--                       (io_stall_queued_*_ms: the IO a resource pool's limit held back) and the file's volume as it was
--                       at the read (a key into mssql_volume_key, so a database id given to another database later does
--                       not move old IO onto the new database's volume); mssql_fileio_last keeps the IOs pending at the
--                       newest read per file (sys.dm_io_pending_io_requests by its file path), mssql_fileio_read the
--                       read's total; import_mssql_fileio re-created.
--   space split         mssql_database_space: per database and hourly read, reserved / data / index / unused (the
--                       arithmetic of sp_spaceused over sys.dm_db_partition_stats), the data files' space not reserved
--                       yet, and the log's size and use; import_mssql_storage re-created to store it.
--   tables              mssql_tables (every user table now: type, compression, partitions, rows, sizes), mssql_table_sample
--                       (a row only when a table's size or rows changed), mssql_tables_db_read (per database: the last
--                       read, its outcome, the first read: the growth lists leave out a database not read);
--                       import_mssql_tables; mssql_table_growth(); mssql_table_series().
--   instance paths      mssql_storage_paths (the default data and log paths, the host's platform, 'SMO and DMO XPs'),
--                       mssql_fixed_drives, mssql_orphan_files; import_mssql_storage_depth.
--   forecast            mssql_volume_forecast(): days until each SQL Server volume is full.
--   IO per database     mssql_db_io() (per database and step), mssql_io_totals() and mssql_io_compare() (a range beside the
--                       same window a day or a week before, by database or by volume).
--   tempdb capacity     mssql_tempdb_capacity: tempdb's data files now against what they can still grow to.
--   findings            mssql_storage_depth_findings: the build's own arms, in the findings columns (the join adds the arm
--                       to pgvigil.findings; the Summary maps only 'a volume full within 30 days', to Disk).
--
-- Partition parents for purge(): mssql_database_space, mssql_table_sample. purge() also deletes mssql_tables and
-- mssql_fixed_drives rows not present for longer than the retention (the join's lines).

-- ---- tempdb's pages -------------------------------------------------------------------------------------------------

ALTER TABLE pgvigil.mssql_versionstore_sample ADD COLUMN IF NOT EXISTS user_object_bytes bigint;      -- user_object_reserved_page_count
ALTER TABLE pgvigil.mssql_versionstore_sample ADD COLUMN IF NOT EXISTS internal_object_bytes bigint;  -- internal_object_reserved_page_count
ALTER TABLE pgvigil.mssql_versionstore_sample ADD COLUMN IF NOT EXISTS mixed_extent_bytes bigint;     -- mixed_extent_page_count
ALTER TABLE pgvigil.mssql_versionstore_sample ADD COLUMN IF NOT EXISTS unallocated_bytes bigint;      -- unallocated_extent_page_count

-- payload: 0067's, the store row with user_object_kb, internal_object_kb, mixed_extent_kb, unallocated_kb added.
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
        holder_host, holder_program, holder_database, holder_is_snapshot, holder_started_at, holder_elapsed_s, holder_statement,
        user_object_bytes, internal_object_bytes, mixed_extent_bytes, unallocated_bytes)
    VALUES (p_instance_id, p_snapshot_at, (v_s->>'store_kb')::bigint * 1024, (v_s->>'reserved_kb')::bigint * 1024,
        (v_s->>'tempdb_data_kb')::bigint * 1024, (v_s->>'generation_raw_kb')::bigint, (v_s->>'cleanup_raw_kb')::bigint, v_gen, v_cln,
        (v_s->>'snapshot_tx_count')::int, (v_h->>'session_id')::int, v_h->>'login_name', v_h->>'host_name', v_h->>'program_name',
        v_h->>'database_name', (v_h->>'is_snapshot')::int = 1, (v_h->>'started_at_utc')::timestamptz, (v_h->>'elapsed_s')::bigint,
        v_h->>'statement',
        (v_s->>'user_object_kb')::bigint * 1024, (v_s->>'internal_object_kb')::bigint * 1024,
        (v_s->>'mixed_extent_kb')::bigint * 1024, (v_s->>'unallocated_kb')::bigint * 1024);
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

-- ---- file IO: the queued stall, the volume at the read, the IOs pending ---------------------------------------------

-- one key per instance and volume name: a sample row carries 4 bytes for its volume, not the name
CREATE TABLE IF NOT EXISTS pgvigil.mssql_volume_key (
  volume_key   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  volume       text NOT NULL,
  UNIQUE (instance_id, volume)
);

ALTER TABLE pgvigil.mssql_fileio_sample ADD COLUMN IF NOT EXISTS read_queued_ms bigint;   -- NULL = not read (a counter that went down)
ALTER TABLE pgvigil.mssql_fileio_sample ADD COLUMN IF NOT EXISTS write_queued_ms bigint;
ALTER TABLE pgvigil.mssql_fileio_sample ADD COLUMN IF NOT EXISTS volume_key int;          -- the file's volume at the read; NULL = not known
ALTER TABLE pgvigil.mssql_fileio_last ADD COLUMN IF NOT EXISTS read_queued_ms bigint;     -- cumulative, as read
ALTER TABLE pgvigil.mssql_fileio_last ADD COLUMN IF NOT EXISTS write_queued_ms bigint;
ALTER TABLE pgvigil.mssql_fileio_last ADD COLUMN IF NOT EXISTS pending_ios int;           -- IOs pending on the file at the newest read
ALTER TABLE pgvigil.mssql_fileio_last ADD COLUMN IF NOT EXISTS pending_in_os int;         -- of them, still with the operating system (io_pending = 1)
ALTER TABLE pgvigil.mssql_fileio_read ADD COLUMN IF NOT EXISTS pending_ios int;           -- the read's total over every file; NULL = not read
ALTER TABLE pgvigil.mssql_fileio_read ADD COLUMN IF NOT EXISTS pending_in_os int;

-- payload: 0074's, each file row with read_queued_ms, write_queued_ms, pending_ios, pending_in_os added; a row
-- {kind:'pending', read (0|1), note} says whether sys.dm_io_pending_io_requests was read.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_fileio(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s      jsonb := pgvigil.mssql_perf_check('import_mssql_fileio', p_instance_id, p_payload);
  v_now    timestamptz := (v_s->>'server_utc')::timestamptz;
  v_start  timestamptz := (v_s->>'server_start')::timestamptz;
  v_pend   boolean := EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'pending' AND r->>'read' = '1');
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_fileio'), p_instance_id);
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_fileio_last l WHERE l.instance_id = p_instance_id AND (l.server_utc >= v_now OR l.snapshot_at >= p_snapshot_at)) THEN
    RETURN;  -- an older read arriving late (or the same read again): the counters stored are newer
  END IF;
  -- a restart: the old counters mean nothing
  DELETE FROM pgvigil.mssql_fileio_last l WHERE l.instance_id = p_instance_id AND NOT pgvigil.mssql_same_run(l.server_start, v_start);
  PERFORM pgvigil.ensure_month_partition('mssql_fileio_read', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_fileio_sample', p_snapshot_at);
  LOCK TABLE ONLY pgvigil.mssql_fileio_read, ONLY pgvigil.mssql_fileio_sample IN ROW EXCLUSIVE MODE;
  -- the volumes the storage collection names, keyed once each: only the new ones reach the INSERT (an INSERT ... ON
  -- CONFLICT takes the identity's next value before it meets the conflict, so a key per volume per minute would run out)
  INSERT INTO pgvigil.mssql_volume_key (instance_id, volume)
  SELECT DISTINCT p_instance_id, f.volume FROM pgvigil.mssql_files f
   WHERE f.instance_id = p_instance_id AND f.is_present AND f.volume IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_volume_key k WHERE k.instance_id = p_instance_id AND k.volume = f.volume)
  ON CONFLICT (instance_id, volume) DO NOTHING;
  -- the read's seconds since the read before of the same run of the server (after a restart the state was emptied above)
  INSERT INTO pgvigil.mssql_fileio_read (instance_id, snapshot_at, interval_secs, files, pending_ios, pending_in_os)
  SELECT p_instance_id, p_snapshot_at, extract(epoch FROM v_now - max(l.server_utc)), 0,
         CASE WHEN v_pend THEN (SELECT coalesce((r->>'pending_ios')::int, 0) FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'pending' LIMIT 1) END,
         CASE WHEN v_pend THEN (SELECT coalesce((r->>'pending_in_os')::int, 0) FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'pending' LIMIT 1) END
    FROM pgvigil.mssql_fileio_last l
   WHERE l.instance_id = p_instance_id
  HAVING max(l.server_utc) < v_now;
  -- a file's difference: a read of it before this one, every counter grown or equal, and some IO in the interval; the
  -- queued stall as a difference where both reads carry it and it did not go down, else NULL; the volume as the
  -- storage collection names the file now (the same database name: an id reused by another database is not it)
  INSERT INTO pgvigil.mssql_fileio_sample (instance_id, snapshot_at, database_id, file_id, database_name, file_name, type_desc,
      reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, interval_secs, read_queued_ms, write_queued_ms, volume_key)
  SELECT p_instance_id, p_snapshot_at, f.database_id, f.file_id, f.database_name, f.file_name, f.type_desc,
         f.reads - l.reads, f.read_bytes - l.read_bytes, f.read_stall_ms - l.read_stall_ms,
         f.writes - l.writes, f.write_bytes - l.write_bytes, f.write_stall_ms - l.write_stall_ms,
         extract(epoch FROM v_now - l.server_utc),
         CASE WHEN f.read_queued_ms >= l.read_queued_ms THEN f.read_queued_ms - l.read_queued_ms END,
         CASE WHEN f.write_queued_ms >= l.write_queued_ms THEN f.write_queued_ms - l.write_queued_ms END,
         vk.volume_key
    FROM (SELECT DISTINCT ON ((r->>'database_id')::int, (r->>'file_id')::int)
                 (r->>'database_id')::int AS database_id, (r->>'file_id')::int AS file_id, r->>'database_name' AS database_name,
                 r->>'file_name' AS file_name, r->>'type_desc' AS type_desc,
                 (r->>'reads')::bigint AS reads, (r->>'read_bytes')::bigint AS read_bytes, (r->>'read_stall_ms')::bigint AS read_stall_ms,
                 (r->>'writes')::bigint AS writes, (r->>'write_bytes')::bigint AS write_bytes, (r->>'write_stall_ms')::bigint AS write_stall_ms,
                 (r->>'read_queued_ms')::bigint AS read_queued_ms, (r->>'write_queued_ms')::bigint AS write_queued_ms
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'file' AND r->>'database_id' IS NOT NULL AND r->>'file_id' IS NOT NULL AND r->>'reads' IS NOT NULL) f
    JOIN pgvigil.mssql_fileio_last l ON l.instance_id = p_instance_id AND l.database_id = f.database_id AND l.file_id = f.file_id
    LEFT JOIN pgvigil.mssql_files mf ON mf.instance_id = p_instance_id AND mf.database_id = f.database_id AND mf.file_id = f.file_id
                                    AND mf.is_present AND mf.database_name IS NOT DISTINCT FROM f.database_name
    LEFT JOIN pgvigil.mssql_volume_key vk ON vk.instance_id = p_instance_id AND vk.volume = mf.volume
   WHERE f.reads >= l.reads AND f.read_bytes >= l.read_bytes AND f.read_stall_ms >= l.read_stall_ms
     AND f.writes >= l.writes AND f.write_bytes >= l.write_bytes AND f.write_stall_ms >= l.write_stall_ms
     AND (f.reads > l.reads OR f.writes > l.writes)
     AND v_now > l.server_utc;

  INSERT INTO pgvigil.mssql_fileio_last AS l (instance_id, database_id, file_id, database_name, file_name, type_desc, physical_name,
      reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, snapshot_at, server_utc, server_start,
      read_queued_ms, write_queued_ms, pending_ios, pending_in_os)
  SELECT DISTINCT ON ((r->>'database_id')::int, (r->>'file_id')::int) p_instance_id, (r->>'database_id')::int, (r->>'file_id')::int,
         r->>'database_name', r->>'file_name', r->>'type_desc', r->>'physical_name',
         (r->>'reads')::bigint, (r->>'read_bytes')::bigint, (r->>'read_stall_ms')::bigint,
         (r->>'writes')::bigint, (r->>'write_bytes')::bigint, (r->>'write_stall_ms')::bigint, p_snapshot_at, v_now, v_start,
         (r->>'read_queued_ms')::bigint, (r->>'write_queued_ms')::bigint,
         CASE WHEN v_pend THEN (r->>'pending_ios')::int END, CASE WHEN v_pend THEN (r->>'pending_in_os')::int END
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'file' AND r->>'database_id' IS NOT NULL AND r->>'file_id' IS NOT NULL AND r->>'reads' IS NOT NULL
  ON CONFLICT (instance_id, database_id, file_id) DO UPDATE SET
      database_name = EXCLUDED.database_name, file_name = EXCLUDED.file_name, type_desc = EXCLUDED.type_desc,
      physical_name = EXCLUDED.physical_name, reads = EXCLUDED.reads, read_bytes = EXCLUDED.read_bytes,
      read_stall_ms = EXCLUDED.read_stall_ms, writes = EXCLUDED.writes, write_bytes = EXCLUDED.write_bytes,
      write_stall_ms = EXCLUDED.write_stall_ms, snapshot_at = EXCLUDED.snapshot_at, server_utc = EXCLUDED.server_utc,
      server_start = EXCLUDED.server_start, read_queued_ms = EXCLUDED.read_queued_ms, write_queued_ms = EXCLUDED.write_queued_ms,
      pending_ios = EXCLUDED.pending_ios, pending_in_os = EXCLUDED.pending_in_os;
  UPDATE pgvigil.mssql_fileio_read r SET files = (SELECT count(*) FROM pgvigil.mssql_fileio_sample s
                                                   WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at)
   WHERE r.instance_id = p_instance_id AND r.snapshot_at = p_snapshot_at;
  -- a file the server no longer lists (a dropped database) leaves the state
  DELETE FROM pgvigil.mssql_fileio_last l WHERE l.instance_id = p_instance_id AND l.snapshot_at < p_snapshot_at;
END $$;

-- ---- the space split per database -----------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_database_space (
  instance_id        int NOT NULL,
  snapshot_at        timestamptz NOT NULL,
  database_name      text NOT NULL,
  reserved_bytes     bigint,                  -- every page reserved for an object (sys.dm_db_partition_stats)
  data_bytes         bigint,                  -- the heap or clustered index's in-row, LOB and row-overflow pages used
  index_bytes        bigint,                  -- the other pages used (nonclustered indexes, the clustered index's upper levels)
  unused_bytes       bigint,                  -- reserved and not used
  unallocated_bytes  bigint,                  -- the data files' size not reserved by any object yet
  log_size_bytes     bigint,
  log_used_bytes     bigint                   -- NULL = not read
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_database_space_inst_db_idx ON pgvigil.mssql_database_space (instance_id, database_name, snapshot_at);

-- payload: 0067's, plus {kind:'space', database_id, database_name, reserved_kb, used_kb, data_kb} per database the read
-- entered with the rights for sys.dm_db_partition_stats.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_storage(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_storage: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_storage'), p_instance_id);
  -- The partitioned parents are taken in name order, the order purge() drops in: opening a month takes ACCESS
  -- EXCLUSIVE on a parent, and the LOCK takes them all (the parents ONLY, never their partitions: a drop in purge()
  -- holds a partition and asks for its parent) before anything is written (0067's deadlock, with a third parent).
  PERFORM pgvigil.ensure_month_partition('mssql_database_size', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_database_space', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_volume_sample', p_snapshot_at);
  LOCK TABLE ONLY pgvigil.mssql_database_size, ONLY pgvigil.mssql_database_space, ONLY pgvigil.mssql_volume_sample IN ROW EXCLUSIVE MODE;

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

    -- the space split of each database the read carried it for: the data files' unallocated space is their size
    -- (ROWS only: a FILESTREAM or full-text container holds no pages) less the reserved pages
    DELETE FROM pgvigil.mssql_database_space WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    INSERT INTO pgvigil.mssql_database_space (instance_id, snapshot_at, database_name, reserved_bytes, data_bytes, index_bytes,
        unused_bytes, unallocated_bytes, log_size_bytes, log_used_bytes)
    SELECT p_instance_id, p_snapshot_at, s.database_name, s.reserved_kb * 1024, s.data_kb * 1024, greatest(s.used_kb - s.data_kb, 0) * 1024,
           greatest(s.reserved_kb - s.used_kb, 0) * 1024, greatest(fs.rows_bytes - s.reserved_kb * 1024, 0), fs.log_bytes, fs.log_used
      FROM (SELECT DISTINCT ON ((r->>'database_id')::int) (r->>'database_id')::int AS database_id, r->>'database_name' AS database_name,
                   (r->>'reserved_kb')::bigint AS reserved_kb, (r->>'used_kb')::bigint AS used_kb, (r->>'data_kb')::bigint AS data_kb
              FROM jsonb_array_elements(p_payload) r
             WHERE r->>'kind' = 'space' AND r->>'database_id' IS NOT NULL AND r->>'reserved_kb' IS NOT NULL) s
      JOIN LATERAL (SELECT coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc = 'ROWS'), 0) AS rows_bytes,
                           coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc = 'LOG'), 0) AS log_bytes,
                           CASE WHEN bool_and(f.used_read) FILTER (WHERE f.type_desc = 'LOG') THEN sum(f.used_bytes) FILTER (WHERE f.type_desc = 'LOG') END AS log_used
                      FROM pgvigil.mssql_files f
                     WHERE f.instance_id = p_instance_id AND f.database_id = s.database_id AND f.is_present AND f.snapshot_at = p_snapshot_at) fs ON true;
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

-- ---- every table ------------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_tables (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name   text NOT NULL,
  schema_name     text NOT NULL,
  table_name      text NOT NULL,
  object_id       bigint,
  table_type      text,                       -- heap | clustered | clustered columnstore | memory-optimized
  temporal        text,                       -- NULL | 'history table' | 'system-versioned'
  graph           text,                       -- NULL | 'node' | 'edge' (SQL Server 2017 and later)
  compression     text,                       -- NONE, ROW, PAGE, COLUMNSTORE, COLUMNSTORE_ARCHIVE, or 'mixed: ROW 3, PAGE 9'
  partitions      int,
  row_count       bigint,
  reserved_kb     bigint,
  used_kb         bigint,
  data_kb         bigint,
  index_kb        bigint,
  snapshot_at     timestamptz NOT NULL,       -- the newest read that listed the table
  first_seen      timestamptz NOT NULL,
  changed_at      timestamptz NOT NULL,       -- the read that last saw its rows or sizes change (first_seen when never)
  is_present      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, database_name, schema_name, table_name)
);

-- a row only when a table is new or its rows, reserved or used size changed: a table that does not change costs no
-- row (its size at any time is the newest row at or before it, else its current row when changed_at is older)
CREATE TABLE IF NOT EXISTS pgvigil.mssql_table_sample (
  instance_id     int NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  database_name   text NOT NULL,
  schema_name     text NOT NULL,
  table_name      text NOT NULL,
  row_count       bigint,
  reserved_kb     bigint,
  used_kb         bigint,
  data_kb         bigint,
  index_kb        bigint
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS mssql_table_sample_name_idx ON pgvigil.mssql_table_sample (instance_id, database_name, schema_name, table_name, snapshot_at);

-- per database: the newest read and whether it listed the tables; first_read_at = the first read that did (the growth
-- over N days is known only for a database read at or before N days ago)
CREATE TABLE IF NOT EXISTS pgvigil.mssql_tables_db_read (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name   text NOT NULL,
  read_at         timestamptz NOT NULL,
  read_ok         boolean NOT NULL,
  note            text,                       -- why the tables were not read
  first_read_at   timestamptz,                -- the first read that listed its tables
  ok_at           timestamptz,                -- the newest read that listed its tables
  PRIMARY KEY (instance_id, database_name)
);

-- payload: {kind:'table', database_name, schema_name, table_name, object_id, table_type, temporal, graph, compression,
--           partitions, row_count, reserved_kb, used_kb, data_kb, index_kb} per table of a database read whole,
--          {kind:'dbread', database_name, read (0|1), note} per database the pass reached or skipped,
--          {kind:'collector_error', source, message}; the run's last batch also {kind:'dblist', names: [every database
--          the server lists]} and {kind:'cursor', source:'mssql_tables', last_seq: where the next pass starts}.
-- One run is several imports at one snapshot (storage.go's batches, a database never split). A database whose tables
-- were listed has its tables not in the list marked gone; a database not read keeps its tables as last read; only the
-- dblist row removes a database the server no longer lists.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_tables(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_tables: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_tables'), p_instance_id);
  -- a read older than one already stored changes nothing (a retry arriving late)
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_tables_db_read d WHERE d.instance_id = p_instance_id AND d.read_at > p_snapshot_at) THEN
    RETURN;
  END IF;
  PERFORM pgvigil.ensure_month_partition('mssql_table_sample', p_snapshot_at);
  LOCK TABLE ONLY pgvigil.mssql_table_sample IN ROW EXCLUSIVE MODE;

  CREATE TEMP TABLE IF NOT EXISTS mssql_tables_in (database_name text, schema_name text, table_name text, object_id bigint, table_type text,
      temporal text, graph text, compression text, partitions int, row_count bigint, reserved_kb bigint, used_kb bigint, data_kb bigint,
      index_kb bigint) ON COMMIT DROP;
  TRUNCATE mssql_tables_in;
  INSERT INTO mssql_tables_in
  SELECT DISTINCT ON (r->>'database_name', r->>'schema_name', r->>'table_name')
         r->>'database_name', r->>'schema_name', r->>'table_name', (r->>'object_id')::bigint, r->>'table_type', r->>'temporal', r->>'graph',
         r->>'compression', (r->>'partitions')::int, (r->>'row_count')::bigint, (r->>'reserved_kb')::bigint, (r->>'used_kb')::bigint,
         (r->>'data_kb')::bigint, (r->>'index_kb')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'table' AND r->>'database_name' IS NOT NULL AND r->>'schema_name' IS NOT NULL AND r->>'table_name' IS NOT NULL;

  -- the samples first, against the stored state: new tables and changed ones (a table back after a gap counts as new);
  -- a retry of this batch replaces its own databases' samples only (another batch of the run has the same snapshot)
  DELETE FROM pgvigil.mssql_table_sample s
   WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at
     AND s.database_name IN (SELECT r->>'database_name' FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'dbread' AND r->>'read' = '1');
  INSERT INTO pgvigil.mssql_table_sample (instance_id, snapshot_at, database_name, schema_name, table_name, row_count, reserved_kb, used_kb, data_kb, index_kb)
  SELECT p_instance_id, p_snapshot_at, i.database_name, i.schema_name, i.table_name, i.row_count, i.reserved_kb, i.used_kb, i.data_kb, i.index_kb
    FROM mssql_tables_in i
    LEFT JOIN pgvigil.mssql_tables t ON t.instance_id = p_instance_id AND t.database_name = i.database_name
                                    AND t.schema_name = i.schema_name AND t.table_name = i.table_name
   WHERE t.instance_id IS NULL OR NOT t.is_present
      OR t.row_count IS DISTINCT FROM i.row_count OR t.reserved_kb IS DISTINCT FROM i.reserved_kb OR t.used_kb IS DISTINCT FROM i.used_kb;

  INSERT INTO pgvigil.mssql_tables AS t (instance_id, database_name, schema_name, table_name, object_id, table_type, temporal, graph,
      compression, partitions, row_count, reserved_kb, used_kb, data_kb, index_kb, snapshot_at, first_seen, changed_at, is_present)
  SELECT p_instance_id, i.database_name, i.schema_name, i.table_name, i.object_id, i.table_type, i.temporal, i.graph, i.compression,
         i.partitions, i.row_count, i.reserved_kb, i.used_kb, i.data_kb, i.index_kb, p_snapshot_at, p_snapshot_at, p_snapshot_at, true
    FROM mssql_tables_in i
  ON CONFLICT (instance_id, database_name, schema_name, table_name) DO UPDATE SET
      changed_at = CASE WHEN NOT t.is_present OR t.row_count IS DISTINCT FROM EXCLUDED.row_count OR t.reserved_kb IS DISTINCT FROM EXCLUDED.reserved_kb
                             OR t.used_kb IS DISTINCT FROM EXCLUDED.used_kb THEN EXCLUDED.snapshot_at ELSE t.changed_at END,
      first_seen = CASE WHEN t.is_present THEN t.first_seen ELSE EXCLUDED.snapshot_at END,
      object_id = EXCLUDED.object_id, table_type = EXCLUDED.table_type, temporal = EXCLUDED.temporal, graph = EXCLUDED.graph,
      compression = EXCLUDED.compression, partitions = EXCLUDED.partitions, row_count = EXCLUDED.row_count,
      reserved_kb = EXCLUDED.reserved_kb, used_kb = EXCLUDED.used_kb, data_kb = EXCLUDED.data_kb, index_kb = EXCLUDED.index_kb,
      snapshot_at = EXCLUDED.snapshot_at, is_present = true;

  -- a table no longer listed in a database this read listed whole is gone
  UPDATE pgvigil.mssql_tables t SET is_present = false
   WHERE t.instance_id = p_instance_id AND t.is_present AND t.snapshot_at < p_snapshot_at
     AND t.database_name IN (SELECT r->>'database_name' FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'dbread' AND r->>'read' = '1');

  INSERT INTO pgvigil.mssql_tables_db_read AS d (instance_id, database_name, read_at, read_ok, note, first_read_at, ok_at)
  SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', p_snapshot_at, r->>'read' = '1', r->>'note',
         CASE WHEN r->>'read' = '1' THEN p_snapshot_at END, CASE WHEN r->>'read' = '1' THEN p_snapshot_at END
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'dbread' AND r->>'database_name' IS NOT NULL
  ON CONFLICT (instance_id, database_name) DO UPDATE SET
      read_at = EXCLUDED.read_at, read_ok = EXCLUDED.read_ok, note = EXCLUDED.note,
      first_read_at = coalesce(d.first_read_at, EXCLUDED.first_read_at), ok_at = coalesce(EXCLUDED.ok_at, d.ok_at);
  -- a database the server no longer lists (the run's last batch names every one it lists): its marker goes, its tables
  -- stay as last read, marked gone
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'dblist') THEN
    CREATE TEMP TABLE IF NOT EXISTS mssql_tables_dblist (database_name text) ON COMMIT DROP;
    TRUNCATE mssql_tables_dblist;
    INSERT INTO mssql_tables_dblist
    SELECT DISTINCT n FROM jsonb_array_elements(p_payload) r, jsonb_array_elements_text(coalesce(r->'names', '[]')) n WHERE r->>'kind' = 'dblist';
    UPDATE pgvigil.mssql_tables t SET is_present = false
     WHERE t.instance_id = p_instance_id AND t.is_present
       AND NOT EXISTS (SELECT 1 FROM mssql_tables_dblist l WHERE l.database_name = t.database_name);
    DELETE FROM pgvigil.mssql_tables_db_read d
     WHERE d.instance_id = p_instance_id AND NOT EXISTS (SELECT 1 FROM mssql_tables_dblist l WHERE l.database_name = d.database_name);
  END IF;
  -- where the next pass starts (0065's mssql_cursor)
  INSERT INTO pgvigil.mssql_cursor AS c (instance_id, source, last_seq, updated_at)
  SELECT DISTINCT ON (r->>'source') p_instance_id, r->>'source', (r->>'last_seq')::bigint, now()
    FROM jsonb_array_elements(p_payload) WITH ORDINALITY AS t(r, n)
   WHERE r->>'kind' = 'cursor' AND r->>'source' IS NOT NULL
   ORDER BY r->>'source', n DESC
  ON CONFLICT (instance_id, source) DO UPDATE SET last_seq = EXCLUDED.last_seq, updated_at = EXCLUDED.updated_at;
END $$;

-- The growth of every present table over the last p_days (p_db: one database's tables only; NULL every database), in
-- a database read whole now and at or before the window's start (else its tables are left out: 'did not grow' must
-- never hold a table nobody read). The size at the window's start: the newest sample at or before it; with none kept,
-- the current size when the table has not changed since before the window (changed_at); a table first seen inside the
-- window, in a database read before it, did not exist at the start: it grew from 0. Any other table's start is unknown
-- (the samples before were purged): it is left out too.
DROP FUNCTION IF EXISTS pgvigil.mssql_table_growth(int, int);
CREATE OR REPLACE FUNCTION pgvigil.mssql_table_growth(p_instance_id int, p_days int, p_db text DEFAULT NULL)
RETURNS TABLE (database_name text, schema_name text, table_name text, table_type text, compression text, row_count bigint,
               used_kb bigint, reserved_kb bigint, rows_grown bigint, used_kb_grown bigint, kb_per_day numeric, since timestamptz)
LANGUAGE sql STABLE AS $$
  WITH w AS (SELECT now() - make_interval(days => p_days) AS start_at),
  b AS (
    SELECT t.*, w.start_at,
           CASE WHEN s0.found THEN s0.row_count WHEN t.first_seen > w.start_at THEN 0 ELSE t.row_count END AS base_rows,
           CASE WHEN s0.found THEN s0.used_kb WHEN t.first_seen > w.start_at THEN 0 ELSE t.used_kb END AS base_used,
           coalesce(s0.found, false) OR t.changed_at <= w.start_at OR t.first_seen > w.start_at AS base_known
      FROM pgvigil.mssql_tables t
      CROSS JOIN w
      JOIN pgvigil.mssql_tables_db_read d ON d.instance_id = t.instance_id AND d.database_name = t.database_name
                                          AND d.read_ok AND d.first_read_at <= w.start_at
      LEFT JOIN LATERAL (SELECT true AS found, s.row_count, s.used_kb FROM pgvigil.mssql_table_sample s
                          WHERE s.instance_id = t.instance_id AND s.database_name = t.database_name AND s.schema_name = t.schema_name
                            AND s.table_name = t.table_name AND s.snapshot_at <= w.start_at
                          ORDER BY s.snapshot_at DESC LIMIT 1) s0 ON true
     WHERE t.instance_id = p_instance_id AND t.is_present AND (p_db IS NULL OR t.database_name = p_db))
  SELECT b.database_name, b.schema_name, b.table_name, b.table_type, b.compression, b.row_count, b.used_kb, b.reserved_kb,
         b.row_count - b.base_rows, b.used_kb - b.base_used,
         round((b.used_kb - b.base_used) / greatest(extract(epoch FROM b.snapshot_at - b.start_at)::numeric / 86400.0, 1 / 24.0), 1),
         b.start_at
    FROM b
   WHERE b.base_known
$$;

-- One table's size over [p_from, p_to]: its size at p_from (the newest sample at or before it; with none kept, its
-- current size when it has not changed since before p_from), every sample in the window, and its current size at its
-- newest read when it has not changed since p_to: a step line.
CREATE OR REPLACE FUNCTION pgvigil.mssql_table_series(p_instance_id int, p_db text, p_schema text, p_table text, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, row_count bigint, reserved_kb bigint, used_kb bigint, data_kb bigint, index_kb bigint)
LANGUAGE sql STABLE AS $$
  SELECT * FROM (
    (SELECT greatest(s.snapshot_at, p_from), s.row_count, s.reserved_kb, s.used_kb, s.data_kb, s.index_kb
       FROM pgvigil.mssql_table_sample s
      WHERE s.instance_id = p_instance_id AND s.database_name = p_db AND s.schema_name = p_schema AND s.table_name = p_table AND s.snapshot_at <= p_from
      ORDER BY s.snapshot_at DESC LIMIT 1)
    UNION ALL
    -- unchanged since before p_from, its samples before purged: the current size held from p_from
    SELECT p_from, t.row_count, t.reserved_kb, t.used_kb, t.data_kb, t.index_kb
      FROM pgvigil.mssql_tables t
     WHERE t.instance_id = p_instance_id AND t.database_name = p_db AND t.schema_name = p_schema AND t.table_name = p_table
       AND t.is_present AND t.changed_at <= p_from
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_table_sample s WHERE s.instance_id = p_instance_id AND s.database_name = p_db
                         AND s.schema_name = p_schema AND s.table_name = p_table AND s.snapshot_at <= p_from)
    UNION ALL
    SELECT s.snapshot_at, s.row_count, s.reserved_kb, s.used_kb, s.data_kb, s.index_kb
      FROM pgvigil.mssql_table_sample s
     WHERE s.instance_id = p_instance_id AND s.database_name = p_db AND s.schema_name = p_schema AND s.table_name = p_table
       AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
    UNION ALL
    SELECT least(t.snapshot_at, p_to), t.row_count, t.reserved_kb, t.used_kb, t.data_kb, t.index_kb
      FROM pgvigil.mssql_tables t
     WHERE t.instance_id = p_instance_id AND t.database_name = p_db AND t.schema_name = p_schema AND t.table_name = p_table
       AND t.is_present AND t.snapshot_at > p_from AND t.changed_at <= p_to) u
  ORDER BY 1
$$;

-- ---- the instance's paths, fixed drives and orphaned files -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_storage_paths (
  instance_id        int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at        timestamptz NOT NULL,
  host_platform      text,                    -- Windows | Linux (sys.dm_os_host_info; SQL Server 2016: Windows)
  machine_name       text,                    -- SERVERPROPERTY('MachineName'): the orphan rule's other instances on one host
  default_data_path  text,                    -- SERVERPROPERTY('InstanceDefaultDataPath')
  default_log_path   text,
  smo_xps            int,                     -- 'SMO and DMO XPs' in use: 0 turns the three filesystem functions off
  drives_read        boolean NOT NULL DEFAULT false,
  drives_note        text,                    -- why sys.dm_os_enumerate_fixed_drives was not read
  orphans_read       boolean NOT NULL DEFAULT false,
  orphans_note       text,
  tempdb_paths       text[],                  -- tempdb's files at pgvigil's first read after the server's start: the
                                              -- files it runs on until the next one (MODIFY FILE names new paths at once)
  tempdb_paths_start timestamp                -- that start: sqlserver_start_time on the server's own clock
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_fixed_drives (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  drive         text NOT NULL,                -- fixed_drive_path: C:\ on Windows, / on Linux
  drive_type    text,
  free_bytes    bigint,
  snapshot_at   timestamptz NOT NULL,
  is_present    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, drive)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_orphan_files (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  path          text NOT NULL,
  size_bytes    bigint,
  snapshot_at   timestamptz NOT NULL,
  note          text,                         -- set: named like tempdb's, written since the start, outside its kept paths
  PRIMARY KEY (instance_id, path)
);

-- payload: {kind:'paths', host_platform, server_start, machine_name, default_data_path, default_log_path, smo_xps},
--          {kind:'drives', read (0|1), note}, {kind:'drive', drive, drive_type, free_bytes},
--          {kind:'orphans', read (0|1), note, server_start, tempdb_paths [...]}, {kind:'orphan', path, size_bytes, written_since_start},
--          {kind:'collector_error', source, message}.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_storage_depth(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_p jsonb;
  v_d jsonb;
  v_o jsonb;
  v_tp text[];   -- tempdb's kept paths (the files it runs on)
  v_cur text[];  -- tempdb's paths as this read names them
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_storage_depth: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_storage_depth'), p_instance_id);
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_storage_paths s WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_snapshot_at) THEN
    RETURN;  -- an older read arriving late
  END IF;
  SELECT r INTO v_p FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'paths' LIMIT 1;
  SELECT r INTO v_d FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'drives' LIMIT 1;
  SELECT r INTO v_o FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'orphans' LIMIT 1;
  IF v_p IS NULL THEN
    RETURN;
  END IF;
  INSERT INTO pgvigil.mssql_storage_paths AS s (instance_id, snapshot_at, host_platform, machine_name, default_data_path, default_log_path,
      smo_xps, drives_read, drives_note, orphans_read, orphans_note)
  VALUES (p_instance_id, p_snapshot_at, v_p->>'host_platform', v_p->>'machine_name', v_p->>'default_data_path', v_p->>'default_log_path',
      (v_p->>'smo_xps')::int, coalesce(v_d->>'read' = '1', false), v_d->>'note', coalesce(v_o->>'read' = '1', false), v_o->>'note')
  ON CONFLICT (instance_id) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, host_platform = EXCLUDED.host_platform, machine_name = EXCLUDED.machine_name,
      default_data_path = EXCLUDED.default_data_path, default_log_path = EXCLUDED.default_log_path, smo_xps = EXCLUDED.smo_xps,
      drives_read = EXCLUDED.drives_read, drives_note = EXCLUDED.drives_note, orphans_read = EXCLUDED.orphans_read,
      orphans_note = EXCLUDED.orphans_note;

  IF coalesce(v_d->>'read' = '1', false) THEN
    INSERT INTO pgvigil.mssql_fixed_drives AS d (instance_id, drive, drive_type, free_bytes, snapshot_at, is_present)
    SELECT DISTINCT ON (r->>'drive') p_instance_id, r->>'drive', r->>'drive_type', (r->>'free_bytes')::bigint, p_snapshot_at, true
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'drive' AND r->>'drive' IS NOT NULL
    ON CONFLICT (instance_id, drive) DO UPDATE SET drive_type = EXCLUDED.drive_type, free_bytes = EXCLUDED.free_bytes,
        snapshot_at = EXCLUDED.snapshot_at, is_present = true;
    UPDATE pgvigil.mssql_fixed_drives d SET is_present = false
     WHERE d.instance_id = p_instance_id AND d.is_present AND d.snapshot_at < p_snapshot_at;
  END IF;
  -- the orphans are the newest read's whole list (a file deleted or attached is no longer one)
  IF coalesce(v_o->>'read' = '1', false) THEN
    v_cur := ARRAY(SELECT jsonb_array_elements_text(coalesce(v_o->'tempdb_paths', '[]'::jsonb)));
    -- tempdb's paths are kept from the first read after each server start: until the next start tempdb runs on those
    -- files, whatever path a pending ALTER DATABASE tempdb MODIFY FILE names
    UPDATE pgvigil.mssql_storage_paths s SET tempdb_paths = v_cur, tempdb_paths_start = (v_o->>'server_start')::timestamp
     WHERE s.instance_id = p_instance_id AND v_o->>'server_start' IS NOT NULL
       AND s.tempdb_paths_start IS DISTINCT FROM (v_o->>'server_start')::timestamp;
    SELECT coalesce(s.tempdb_paths, '{}') INTO v_tp FROM pgvigil.mssql_storage_paths s WHERE s.instance_id = p_instance_id;
    DELETE FROM pgvigil.mssql_orphan_files WHERE instance_id = p_instance_id;
    -- a kept tempdb path is never an orphan. A file outside them that was written since the server's start and is named
    -- like a tempdb file may be the file tempdb runs on after a move made before pgvigil's first read after the start:
    -- said so (info), never a plain orphan. A file not written since the start (left by a move a restart finished, or
    -- any other) is a plain orphan.
    INSERT INTO pgvigil.mssql_orphan_files (instance_id, path, size_bytes, snapshot_at, note)
    SELECT DISTINCT ON (r->>'path') p_instance_id, r->>'path', (r->>'size_bytes')::bigint, p_snapshot_at,
           CASE WHEN r->>'written_since_start' = '1'
                 AND (lower(regexp_replace(r->>'path', '^.*[/\\]', '')) ~ '^temp[^/\\]*\.(mdf|ndf|ldf)$'
                      OR EXISTS (SELECT 1 FROM unnest(v_cur || v_tp) t
                                  WHERE lower(regexp_replace(t, '^.*[/\\]', '')) = lower(regexp_replace(r->>'path', '^.*[/\\]', ''))))
                THEN 'a tempdb file move may be pending (the files run until the restart)' END
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'orphan' AND r->>'path' IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM unnest(v_tp) t WHERE lower(replace(t, '\', '/')) = lower(replace(r->>'path', '\', '/')));
  END IF;
END $$;

-- ---- days until each SQL Server volume is full ----------------------------------------------------------------------

-- Every present volume of the SQL Server instances (p_instance_id NULL = the fleet), with the growth of its used
-- space per day over 7 days (at least a day of reads) and over 30 days (at least 7 days of reads) - growth_per_day,
-- 0033's regression - and the days until it is full at each. The 30-day figure judges (days_until_full): a one-off
-- growth or a weekly clean-up moves a 7-day slope far more than a 30-day one; the 7-day figure is shown beside it.
-- On Linux the server names no mount point and storage.go stands each file's directory in for its volume: the
-- directories that read the same total and free bytes at the newest read are one file system, one row here (named
-- by its directories).
CREATE OR REPLACE FUNCTION pgvigil.mssql_volume_forecast(p_instance_id int DEFAULT NULL)
RETURNS TABLE (instance_id int, volume text, directories text, total_bytes bigint, free_bytes bigint, used_bytes bigint,
               growth_7d_per_day numeric, growth_30d_per_day numeric, days_until_full_7 numeric, days_until_full numeric,
               snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH v AS (
    SELECT v.instance_id, v.volume, v.total_bytes, v.free_bytes, v.snapshot_at,
           -- one row per Linux file system: its directories grouped by the read's total and free bytes
           CASE WHEN v.volume LIKE '/%' THEN min(v.volume) OVER (PARTITION BY v.instance_id, v.total_bytes, v.free_bytes, v.volume LIKE '/%') ELSE v.volume END AS fs,
           CASE WHEN v.volume LIKE '/%' THEN string_agg(v.volume, ', ') OVER (PARTITION BY v.instance_id, v.total_bytes, v.free_bytes, v.volume LIKE '/%') END AS dirs,
           CASE WHEN v.volume LIKE '/%' THEN array_agg(v.volume) OVER (PARTITION BY v.instance_id, v.total_bytes, v.free_bytes, v.volume LIKE '/%')
                ELSE ARRAY[v.volume] END AS vols
      FROM pgvigil.mssql_volumes v
      JOIN pgvigil.instances i ON i.instance_id = v.instance_id AND i.is_active
     WHERE v.is_present AND v.total_bytes > 0 AND v.free_bytes IS NOT NULL AND (p_instance_id IS NULL OR v.instance_id = p_instance_id)
  ), one AS (SELECT * FROM v WHERE v.volume = v.fs)
  SELECT one.instance_id, one.volume, one.dirs, one.total_bytes, one.free_bytes, one.total_bytes - one.free_bytes,
         g.g7, g.g30,
         round(one.free_bytes / nullif(greatest(g.g7, 0), 0), 1),
         round(one.free_bytes / nullif(greatest(g.g30, 0), 0), 1),
         one.snapshot_at
    FROM one
    CROSS JOIN LATERAL (
      -- every directory of the file system, one point per read (a directory new to the group brings its own history
      -- in; the group's name, its first directory, may change without losing the slope)
      SELECT pgvigil.growth_per_day(array_agg(s.snapshot_at) FILTER (WHERE s.snapshot_at > now() - interval '7 days'),
                                    array_agg(s.used) FILTER (WHERE s.snapshot_at > now() - interval '7 days'),
                                    interval '1 day') AS g7,
             pgvigil.growth_per_day(array_agg(s.snapshot_at), array_agg(s.used), interval '7 days') AS g30
        FROM (SELECT DISTINCT ON (vs.snapshot_at) vs.snapshot_at, vs.total_bytes - vs.free_bytes AS used
                FROM pgvigil.mssql_volume_sample vs
               WHERE vs.instance_id = one.instance_id AND vs.volume = ANY (one.vols) AND vs.snapshot_at > now() - interval '30 days'
               ORDER BY vs.snapshot_at, vs.volume) s) g
$$;

-- ---- IO per database ------------------------------------------------------------------------------------------------

-- Per database and step of p_step_secs: bytes read and written per second, operations per second, and the latency of
-- the step's reads and writes (their stall over their count: weighted by IO, as the files add up). A step's seconds
-- are the seconds its reads covered (mssql_fileio_read), so an idle file costs nothing and an idle step reads 0.
-- p_names (NULL = every database) keeps only those databases BEFORE the per-step sums: the chart's top 10 of 3,000
-- databases sums 10 x the steps, not every database's rows (proof P5).
DROP FUNCTION IF EXISTS pgvigil.mssql_db_io(int, timestamptz, timestamptz, int);
CREATE OR REPLACE FUNCTION pgvigil.mssql_db_io(p_instance_id int, p_from timestamptz, p_to timestamptz, p_step_secs int,
                                               p_names text[] DEFAULT NULL)
RETURNS TABLE (snapshot_at timestamptz, database_name text, read_bytes_s numeric, write_bytes_s numeric, iops numeric,
               read_latency_ms numeric, write_latency_ms numeric, queued_ms_s numeric)
LANGUAGE sql STABLE AS $$
  WITH secs AS (
    SELECT to_timestamp(floor(extract(epoch FROM r.snapshot_at) / p_step_secs) * p_step_secs) AS b, sum(r.interval_secs) AS secs
      FROM pgvigil.mssql_fileio_read r
     WHERE r.instance_id = p_instance_id AND r.snapshot_at > p_from AND r.snapshot_at <= p_to
     GROUP BY 1
  ), io AS (
    SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / p_step_secs) * p_step_secs) AS b, coalesce(s.database_name, 'database ' || s.database_id) AS database_name,
           sum(s.read_bytes) AS rb, sum(s.write_bytes) AS wb, sum(s.reads) AS r, sum(s.writes) AS w,
           sum(s.read_stall_ms) AS rs, sum(s.write_stall_ms) AS ws, sum(coalesce(s.read_queued_ms, 0) + coalesce(s.write_queued_ms, 0)) AS q
      FROM pgvigil.mssql_fileio_sample s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
       AND (p_names IS NULL OR coalesce(s.database_name, 'database ' || s.database_id) = ANY (p_names))
     GROUP BY 1, 2
  )
  SELECT io.b, io.database_name, round(io.rb / nullif(secs.secs, 0)::numeric, 0), round(io.wb / nullif(secs.secs, 0)::numeric, 0),
         round((io.r + io.w) / nullif(secs.secs, 0)::numeric, 2),
         round(io.rs::numeric / nullif(io.r, 0), 2), round(io.ws::numeric / nullif(io.w, 0), 2), round(io.q / nullif(secs.secs, 0)::numeric, 2)
    FROM io JOIN secs USING (b)
   ORDER BY 1, 2
$$;

-- The totals of [p_from, p_to] per database (p_by 'database') or per volume as it was at each read ('volume'):
-- operations, bytes, stalls and their averages, MB per second over the seconds the window's reads covered.
CREATE OR REPLACE FUNCTION pgvigil.mssql_io_totals(p_instance_id int, p_from timestamptz, p_to timestamptz, p_by text)
RETURNS TABLE (name text, reads bigint, writes bigint, read_bytes bigint, write_bytes bigint, read_stall_ms bigint, write_stall_ms bigint,
               queued_ms bigint, read_latency_ms numeric, write_latency_ms numeric, mb_s numeric, secs numeric)
LANGUAGE sql STABLE AS $$
  WITH secs AS (SELECT coalesce(sum(r.interval_secs), 0)::numeric AS secs FROM pgvigil.mssql_fileio_read r
                 WHERE r.instance_id = p_instance_id AND r.snapshot_at > p_from AND r.snapshot_at <= p_to)
  SELECT x.name, x.reads, x.writes, x.read_bytes, x.write_bytes, x.read_stall_ms, x.write_stall_ms, x.queued_ms,
         round(x.read_stall_ms::numeric / nullif(x.reads, 0), 2), round(x.write_stall_ms::numeric / nullif(x.writes, 0), 2),
         round((x.read_bytes + x.write_bytes) / 1048576.0 / nullif(secs.secs, 0), 3), secs.secs
    FROM (SELECT CASE WHEN p_by = 'volume' THEN coalesce(vk.volume, 'volume not known') ELSE coalesce(s.database_name, 'database ' || s.database_id) END AS name,
                 sum(s.reads)::bigint AS reads, sum(s.writes)::bigint AS writes, sum(s.read_bytes)::bigint AS read_bytes,
                 sum(s.write_bytes)::bigint AS write_bytes, sum(s.read_stall_ms)::bigint AS read_stall_ms, sum(s.write_stall_ms)::bigint AS write_stall_ms,
                 sum(coalesce(s.read_queued_ms, 0) + coalesce(s.write_queued_ms, 0))::bigint AS queued_ms
            FROM pgvigil.mssql_fileio_sample s
            LEFT JOIN pgvigil.mssql_volume_key vk ON vk.volume_key = s.volume_key
           WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
           GROUP BY 1) x
    CROSS JOIN secs
$$;

-- The range beside the same window p_shift earlier (a day, a week): each name's totals in both and the change.
CREATE OR REPLACE FUNCTION pgvigil.mssql_io_compare(p_instance_id int, p_from timestamptz, p_to timestamptz, p_shift interval, p_by text)
RETURNS TABLE (name text, mb_s numeric, mb_s_before numeric, read_latency_ms numeric, read_latency_ms_before numeric,
               write_latency_ms numeric, write_latency_ms_before numeric, reads bigint, reads_before bigint, writes bigint, writes_before bigint,
               secs numeric, secs_before numeric)
LANGUAGE sql STABLE AS $$
  SELECT coalesce(a.name, b.name), a.mb_s, b.mb_s, a.read_latency_ms, b.read_latency_ms, a.write_latency_ms, b.write_latency_ms,
         a.reads, b.reads, a.writes, b.writes, a.secs, b.secs
    FROM pgvigil.mssql_io_totals(p_instance_id, p_from, p_to, p_by) a
    FULL JOIN pgvigil.mssql_io_totals(p_instance_id, p_from - p_shift, p_to - p_shift, p_by) b ON b.name = a.name
   ORDER BY coalesce(a.read_bytes + a.write_bytes, 0) DESC, 1
$$;

-- ---- tempdb's capacity ------------------------------------------------------------------------------------------------

-- Per instance, the newest tempdb read (the minute's used space) against tempdb's capacity: what its data files can
-- reach. The capacity comes from the hourly storage read alone, per file system: a file that does not grow, its size; the
-- files that grow to a max size, the smaller of their max sizes and their size + the file system's free space; files
-- that grow without limit, their size + the free space. It does not move as tempdb grows between two reads (a file that
-- grows takes what the file system loses), so the minute's used space is judged against it as read: never the minute's
-- size plus room measured from an older, smaller size. Linux directories that read one total and one free are one file
-- system (as the forecast), its free space counted once. No tempdb file row, or a file without limit on a file system
-- whose free space was not read: the capacity is unknown (NULL), never the size alone.
CREATE OR REPLACE VIEW pgvigil.mssql_tempdb_capacity AS
WITH latest AS (
  SELECT DISTINCT ON (s.instance_id) s.instance_id, s.snapshot_at, s.tempdb_data_bytes, s.unallocated_bytes, s.user_object_bytes,
         s.internal_object_bytes, s.reserved_bytes AS version_store_bytes, s.mixed_extent_bytes
    FROM pgvigil.mssql_versionstore_sample s
   WHERE s.snapshot_at > now() - interval '1 day' AND s.unallocated_bytes IS NOT NULL
   ORDER BY s.instance_id, s.snapshot_at DESC
), files AS (
  SELECT f.instance_id, f.volume, f.size_bytes, f.max_size_bytes,
         CASE WHEN NOT (f.growth_bytes > 0 OR f.growth_pct > 0) THEN 'fixed' WHEN f.max_size_bytes IS NULL THEN 'unlimited' ELSE 'limited' END AS grows
    FROM pgvigil.mssql_files f
   WHERE f.database_name = 'tempdb' AND f.type_desc = 'ROWS' AND f.is_present
), fs AS (
  SELECT fl.instance_id, fl.volume, v.free_bytes,
         CASE WHEN fl.volume LIKE '/%' AND v.total_bytes IS NOT NULL THEN v.total_bytes || '/' || coalesce(v.free_bytes::text, '?') ELSE fl.volume END AS fs_key
    FROM (SELECT DISTINCT instance_id, volume FROM files) fl
    LEFT JOIN pgvigil.mssql_volumes v ON v.instance_id = fl.instance_id AND v.volume = fl.volume AND v.is_present
), per_fs AS (
  SELECT fl.instance_id, x.fs_key, max(x.free_bytes) AS free_bytes, bool_or(x.free_bytes IS NULL) AS free_unknown,
         coalesce(sum(fl.size_bytes) FILTER (WHERE fl.grows = 'fixed'), 0) AS fixed_size,
         coalesce(sum(fl.size_bytes) FILTER (WHERE fl.grows = 'limited'), 0) AS limited_size,
         coalesce(sum(fl.max_size_bytes) FILTER (WHERE fl.grows = 'limited'), 0) AS limited_max,
         coalesce(sum(fl.size_bytes) FILTER (WHERE fl.grows = 'unlimited'), 0) AS unlimited_size,
         bool_or(fl.grows = 'unlimited') AS unlimited, bool_and(fl.grows = 'fixed') AS all_fixed
    FROM files fl JOIN fs x ON x.instance_id = fl.instance_id AND x.volume = fl.volume
   GROUP BY fl.instance_id, x.fs_key
), cap AS (
  SELECT instance_id,
         sum(fixed_size + CASE WHEN unlimited THEN limited_size + unlimited_size + free_bytes
                               ELSE least(limited_max, limited_size + coalesce(free_bytes, limited_max)) END) AS capacity,
         bool_or(unlimited AND free_unknown) AS room_unknown,
         bool_or(unlimited OR (NOT free_unknown AND limited_size + free_bytes < limited_max)) AS volume_limited,
         bool_and(all_fixed) AS no_growth
    FROM per_fs
   GROUP BY instance_id
)
SELECT l.instance_id, l.snapshot_at, l.tempdb_data_bytes AS size_bytes, l.tempdb_data_bytes - l.unallocated_bytes AS used_bytes,
       l.user_object_bytes, l.internal_object_bytes, l.version_store_bytes, l.mixed_extent_bytes, l.unallocated_bytes,
       k.capacity - l.tempdb_data_bytes AS growth_room_bytes, k.capacity AS capacity_bytes,
       coalesce(c.volume_limited, false) AS volume_limited, k.capacity IS NULL AS capacity_unknown, coalesce(c.no_growth, false) AS no_growth,
       round(100.0 * (l.tempdb_data_bytes - l.unallocated_bytes) / nullif(k.capacity, 0), 1) AS used_pct
  FROM latest l
  LEFT JOIN cap c ON c.instance_id = l.instance_id
  CROSS JOIN LATERAL (SELECT CASE WHEN c.instance_id IS NULL OR c.room_unknown THEN NULL
                                  ELSE greatest(c.capacity, l.tempdb_data_bytes) END AS capacity) k;

-- ---- the findings ----------------------------------------------------------------------------------------------------

-- The build's own arms, in the findings columns (instance_id, severity, check_name, object, at, detail). No name here
-- is one 0111's or 0145's mssql_storage_findings raises: the conditions those arms judge (a volume under its
-- threshold, a file near its max size, a per-cent growth on a large file, a log larger than its data) stay theirs.
CREATE OR REPLACE VIEW pgvigil.mssql_storage_depth_findings AS
-- a volume full within 30 days at the 30-day growth: warning, under 7 days critical (the host rule's meaning)
SELECT f.instance_id, CASE WHEN f.days_until_full < 7 THEN 'critical' ELSE 'warning' END AS severity,
       'a volume full within 30 days'::text AS check_name, f.volume AS object, f.snapshot_at AS at,
       format('full in about %s days at %s a day (the last 30 days); %s at the last 7 days'' rate; %s free of %s%s',
              f.days_until_full, pg_size_pretty(f.growth_30d_per_day::bigint),
              coalesce(f.days_until_full_7 || ' days', 'not full'), pg_size_pretty(f.free_bytes), pg_size_pretty(f.total_bytes),
              CASE WHEN f.directories LIKE '%,%' THEN '; one file system holding ' || f.directories ELSE '' END) AS detail
  FROM pgvigil.mssql_volume_forecast(NULL) f
 WHERE f.days_until_full < 30 AND f.snapshot_at > now() - interval '3 hours'
UNION ALL
-- tempdb's data files filling, judged on the newest read against what they can still grow to
SELECT c.instance_id, CASE WHEN c.used_pct > 80 THEN 'critical' ELSE 'warning' END, 'tempdb data files filling', 'tempdb', c.snapshot_at,
       format('%s used of a capacity of %s (%s %%): the data files hold %s now and can grow by %s%s; user objects %s, internal objects %s, version store %s',
              pg_size_pretty(c.used_bytes), pg_size_pretty(c.capacity_bytes), c.used_pct, pg_size_pretty(c.size_bytes),
              pg_size_pretty(c.growth_room_bytes), CASE WHEN c.volume_limited THEN ' (limited by the volume''s free space)' ELSE '' END,
              pg_size_pretty(c.user_object_bytes), pg_size_pretty(c.internal_object_bytes), pg_size_pretty(c.version_store_bytes))
  FROM pgvigil.mssql_tempdb_capacity c
 WHERE c.used_pct > 50 AND c.snapshot_at > now() - interval '15 minutes'
UNION ALL
-- dbachecks LogfileCount: a database with more than one log file
SELECT f.instance_id, 'warning', 'more than one log file', f.database_name, max(f.snapshot_at),
       format('%s log files: %s; a log is written in turn, a second file adds no speed', count(*), string_agg(coalesce(f.file_name, f.file_id::text), ', ' ORDER BY f.file_id))
  FROM pgvigil.mssql_files f
 WHERE f.is_present AND f.type_desc = 'LOG' AND f.snapshot_at > now() - interval '3 hours'
 GROUP BY f.instance_id, f.database_name
HAVING count(*) > 1
UNION ALL
-- dbachecks FutureFileGrowth: a file with under 20 % of its size free inside it (where the used space was read)
SELECT f.instance_id, 'info', 'a file under 20 % free inside it', f.database_name || ': ' || coalesce(f.file_name, f.file_id::text), f.snapshot_at,
       format('%s (%s) is %s with %s used: %s %% free inside it; %s', coalesce(f.physical_name, f.file_name), lower(coalesce(f.type_desc, 'file')),
              pg_size_pretty(f.size_bytes), pg_size_pretty(f.used_bytes), round(100.0 * (f.size_bytes - f.used_bytes) / f.size_bytes, 1),
              CASE WHEN f.growth_bytes > 0 OR f.growth_pct > 0 THEN 'it grows when it fills' ELSE 'it does not grow' END)
  FROM pgvigil.mssql_files f
 WHERE f.is_present AND f.used_read AND f.size_bytes > 0 AND f.type_desc IN ('ROWS', 'LOG')
   AND f.size_bytes - f.used_bytes < 0.2 * f.size_bytes AND f.snapshot_at > now() - interval '3 hours'
UNION ALL
-- dbachecks FileGroupBalanced: a data file more than 5 % from its filegroup's average size (a filegroup of two files or more)
SELECT x.instance_id, 'info', 'a filegroup''s data files unbalanced', x.database_name || ': ' || x.filegroup, x.at,
       format('the files of %s are %s; their average is %s and %s is %s %% from it: SQL Server fills the files by their free space, so the larger file takes more of the IO',
              x.filegroup, x.sizes, pg_size_pretty(x.avg_bytes::bigint), x.worst_name, x.worst_pct)
  FROM (SELECT f.instance_id, f.database_name, f.filegroup, max(f.snapshot_at) AS at, avg(f.size_bytes) AS avg_bytes,
               string_agg(coalesce(f.file_name, f.file_id::text) || ' ' || pg_size_pretty(f.size_bytes), ', ' ORDER BY f.file_id) AS sizes,
               (array_agg(coalesce(f.file_name, f.file_id::text) ORDER BY abs(f.size_bytes - a.avg_bytes) DESC))[1] AS worst_name,
               round(max(100.0 * abs(f.size_bytes - a.avg_bytes) / nullif(a.avg_bytes, 0)), 1) AS worst_pct
          FROM pgvigil.mssql_files f
          JOIN (SELECT instance_id, database_id, filegroup, avg(size_bytes) AS avg_bytes, count(*) AS n FROM pgvigil.mssql_files
                 WHERE is_present AND type_desc = 'ROWS' AND filegroup IS NOT NULL GROUP BY 1, 2, 3) a
            ON a.instance_id = f.instance_id AND a.database_id = f.database_id AND a.filegroup = f.filegroup AND a.n > 1
         WHERE f.is_present AND f.type_desc = 'ROWS' AND f.snapshot_at > now() - interval '3 hours'
         GROUP BY f.instance_id, f.database_name, f.filegroup) x
 WHERE x.worst_pct > 5
UNION ALL
-- dbachecks DatafileAutoGrowthType: a data file growing in steps under 64 MB (65535 KB); a per-cent step is 0111's
SELECT f.instance_id, 'warning', 'a data file growth step under 64 MB', f.database_name || ': ' || coalesce(f.file_name, f.file_id::text), f.snapshot_at,
       format('%s grows by %s at a time: many small growths fragment the file and stall each write that waits for one',
              coalesce(f.physical_name, f.file_name), pg_size_pretty(f.growth_bytes))
  FROM pgvigil.mssql_files f
 WHERE f.is_present AND f.type_desc = 'ROWS' AND f.growth_bytes > 0 AND f.growth_bytes < 65535 * 1024::bigint
   AND f.database_name NOT IN ('model') AND f.snapshot_at > now() - interval '3 hours'
UNION ALL
-- dbachecks ModelDbGrowth: model's files (every new database copies them) growing by per cent or by 1 MB
SELECT f.instance_id, 'warning', CASE WHEN f.growth_pct > 0 THEN 'model grows by per cent' ELSE 'model grows by 1 MB' END,
       'model: ' || coalesce(f.file_name, f.file_id::text), f.snapshot_at,
       format('%s grows by %s; every new database starts with model''s files and their growth', coalesce(f.physical_name, f.file_name),
              CASE WHEN f.growth_pct > 0 THEN f.growth_pct || ' %' ELSE pg_size_pretty(f.growth_bytes) END)
  FROM pgvigil.mssql_files f
 WHERE f.is_present AND f.database_name = 'model' AND f.snapshot_at > now() - interval '3 hours'
   AND (f.growth_pct > 0 OR (f.growth_bytes > 0 AND f.growth_bytes <= 1024 * 1024))
UNION ALL
-- dbachecks TempDbConfiguration: a tempdb file on C: (Windows) and a tempdb file with a max size set
SELECT f.instance_id, 'warning', 'a tempdb file on C:', 'tempdb: ' || coalesce(f.file_name, f.file_id::text), f.snapshot_at,
       format('%s is on the system drive: a tempdb that grows can fill it and stop Windows', f.physical_name)
  FROM pgvigil.mssql_files f
 WHERE f.is_present AND f.database_name = 'tempdb' AND f.physical_name ILIKE 'C:%' AND f.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT f.instance_id, 'warning', 'a tempdb file with a max size', 'tempdb: ' || coalesce(f.file_name, f.file_id::text), f.snapshot_at,
       format('%s (%s) may grow to %s at most: a busy hour that needs more stops with error 1105 (data) or 9002 (log)',
              coalesce(f.physical_name, f.file_name), lower(coalesce(f.type_desc, 'file')), pg_size_pretty(f.max_size_bytes))
  FROM pgvigil.mssql_files f
 WHERE f.is_present AND f.database_name = 'tempdb' AND f.max_size_bytes IS NOT NULL AND (f.growth_bytes > 0 OR f.growth_pct > 0)
   -- a log file set to UNLIMITED reads max_size 268435456 pages (2 TB, sys.master_files): no max size was set
   AND NOT (f.type_desc = 'LOG' AND f.max_size_bytes >= 268435456::bigint * 8192)
   AND f.snapshot_at > now() - interval '3 hours'
UNION ALL
-- dbachecks DefaultFilePath: the default data or log path on C: (Windows)
SELECT p.instance_id, 'warning', CASE k.kind WHEN 'data' THEN 'the default data path on C:' ELSE 'the default log path on C:' END,
       'the instance', p.snapshot_at,
       format('a new database''s %s files go to %s, on the system drive', k.kind, k.path)
  FROM pgvigil.mssql_storage_paths p
  CROSS JOIN LATERAL (VALUES ('data', p.default_data_path), ('log', p.default_log_path)) k(kind, path)
 WHERE p.host_platform = 'Windows' AND k.path ILIKE 'C:%' AND p.snapshot_at > now() - interval '3 hours'
UNION ALL
-- dbachecks OrphanedFile: a data or log file in the instance's folders that no database lists; info where another
-- instance pgvigil monitors runs on the same host (its files may share the folder)
SELECT o.instance_id,
       CASE WHEN o.note IS NOT NULL THEN 'info'
            WHEN EXISTS (SELECT 1 FROM pgvigil.mssql_storage_paths q JOIN pgvigil.instances i ON i.instance_id = q.instance_id AND i.is_active
                          WHERE q.instance_id <> o.instance_id AND lower(q.machine_name) = lower(p.machine_name)) THEN 'info' ELSE 'warning' END,
       'an orphaned database file', o.path, o.snapshot_at,
       CASE WHEN o.note IS NOT NULL
            THEN format('%s (%s) is named like a tempdb file and no database lists it: %s', o.path, pg_size_pretty(o.size_bytes), o.note)
            ELSE format('%s (%s) is in a folder of this instance and no database of it lists the file: a detached or dropped database left it%s',
              o.path, pg_size_pretty(o.size_bytes),
              CASE WHEN EXISTS (SELECT 1 FROM pgvigil.mssql_storage_paths q JOIN pgvigil.instances i ON i.instance_id = q.instance_id AND i.is_active
                                 WHERE q.instance_id <> o.instance_id AND lower(q.machine_name) = lower(p.machine_name))
                   THEN '; another instance pgvigil watches runs on this host and may own it' ELSE '' END) END
  FROM pgvigil.mssql_orphan_files o
  JOIN pgvigil.mssql_storage_paths p ON p.instance_id = o.instance_id
 WHERE o.snapshot_at > now() - interval '3 hours';
