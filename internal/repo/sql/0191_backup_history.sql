-- 0191: a SQL Server database's backup history, its restore history and three checks of its backups (task 301b): the
-- newest 10 sets per database, type and copy-only (msdb.dbo.backupset with family 1's device and path), the newest 20
-- restores per destination database and restore type (msdb.dbo.restorehistory with the set restored), and per read
-- whether the newest backup's file is still where msdb says it was written (sys.dm_os_file_exists: Database#7, an
-- admin's opt-in per instance), whether a FULL or BULK_LOGGED database is pseudo-simple (sys.database_recovery_status'
-- last_log_backup_lsn NULL: Database#39) and whether the default backup path is a directory the service account sees
-- (SERVERPROPERTY('InstanceDefaultBackupPath'), the registry's BackupDirectory before 2019: Instance#14). The collections
-- mssql_backup_history and mssql_backup_checks (internal/mssql/backup_history.go) write them; 0140's tables and views
-- are not touched.
--   mssql_backup_history         current: the newest N sets per database, type (D / I / L) and copy-only
--   mssql_restore_history        current: the newest M restores per destination database and restore type
--   mssql_backup_history_cursor  the collection's two cursors (the newest backup_set_id and restore_history_id read,
--                                each with its row's mark) and whether the restore history was read
--   mssql_backup_history_dbs     the databases the last read listed (a database listed again sends the cursor to 0)
--   mssql_backup_db_checks       per database the recovery model and last_log_backup_lsn, or why it was not read
--   mssql_backup_file_checks     per database and type the newest set's file and its state
--   mssql_backup_path_check      per instance the default backup path and its state, and whether files were checked
-- Views: mssql_backup_check_cells (per database the pseudo-simple and file words), mssql_backup_path_cells (per instance
-- the path's words) and mssql_backup_check_findings (the three findings, judged as mssql_backup_judged judges).
-- An AUTO_CLOSE database is not read for last_log_backup_lsn unless the instance opts in (the read opens a closed
-- database: probe 301bP2 on SQL Server 2019 and 2022): its cell says 'not read: AUTO_CLOSE (reading would open it)'.
--
-- THE JOIN-FILE RULE (the lead's 2026-11-15 03:3x): 0191 sorts after 0190 and creates its own objects only. The joined
-- objects' lines are in scripts/inv-301b-join-lines.sql: mssql_hadr_cursor's arm for this collection's two cursors, the
-- pgvigil.findings arm, and the actions_log lists. On this branch mssql_hadr_cursor does not know the cursors (a whole
-- pass every read); the store test and the proof apply scripts/inv-301b-joined-cursor.sql, the function as the joined
-- tree holds it.
-- actions_log's three CHECKs are widened HERE too (BOTH), so this branch's action verify_backup can be
-- written: the lists copy 0157's (task 406, plan_evict) whole and add verify_backup (no pid) and the outcomes started,
-- cut by shutdown and ended unknown; 0194 (B9c) copies these, 0300 re-creates each CHECK once with every slice's list.
-- Lock footprint: three new tables' worth of CREATE, and an ACCESS EXCLUSIVE lock on actions_log while each CHECK is
-- validated and a SHARE lock while actions_log_verify_idx is built (a small audit table).

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_history (
  instance_id            int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  backup_set_uuid        uuid NOT NULL,
  backup_set_id          bigint NOT NULL,
  database_name          text NOT NULL,
  backup_type            text NOT NULL CHECK (backup_type IN ('D', 'I', 'L')),
  is_copy_only           boolean NOT NULL,
  start_at               timestamptz,
  finish_at              timestamptz NOT NULL,
  size_bytes             bigint,
  compressed_bytes       bigint,
  recovery_model         text,
  user_name              text,
  machine_name           text,
  server_name            text,
  set_name               text,
  has_checksums          boolean,
  is_damaged             boolean,
  is_password_protected  boolean,
  is_snapshot            boolean,
  has_bulk_logged_data   boolean,
  is_readonly            boolean,
  is_force_offline       boolean,
  is_single_user         boolean,
  encryptor_type         text,
  key_algorithm          text,
  compression_algorithm  text,
  family_count           int,
  position               int,
  device_kind            text,
  path                   text,
  first_lsn              text,
  last_lsn               text,
  checkpoint_lsn         text,
  database_backup_lsn    text,
  differential_base_guid uuid,
  read_at                timestamptz NOT NULL,
  PRIMARY KEY (instance_id, backup_set_uuid)
);
CREATE INDEX IF NOT EXISTS mssql_backup_history_db_idx ON pgvigil.mssql_backup_history (instance_id, database_name, backup_type, is_copy_only, finish_at DESC);
COMMENT ON TABLE pgvigil.mssql_backup_history IS 'The newest 10 backup sets per SQL Server database, type and copy-only (task 301b); written by import_mssql_backup_history only.';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_restore_history (
  instance_id               int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  restore_history_id        bigint NOT NULL,
  restore_at                timestamptz NOT NULL,
  destination_database_name text NOT NULL,
  user_name                 text,
  restore_type              text NOT NULL,
  is_replace                boolean,
  is_recovery               boolean,
  stop_at                   timestamptz,
  source_server             text,
  source_database           text,
  source_type               text,
  source_finish_at          timestamptz,
  source_backup_set_uuid    uuid,
  source_path               text,
  read_at                   timestamptz NOT NULL,
  PRIMARY KEY (instance_id, restore_history_id)
);
CREATE INDEX IF NOT EXISTS mssql_restore_history_dest_idx ON pgvigil.mssql_restore_history (instance_id, destination_database_name, restore_type, restore_at DESC);
COMMENT ON TABLE pgvigil.mssql_restore_history IS 'The newest 20 restores per SQL Server destination database and restore type (task 301b); written by import_mssql_backup_history only.';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_history_cursor (
  instance_id     int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  last_set_id     bigint,
  set_mark        bigint,
  last_restore_id bigint,
  restore_mark    bigint,
  restore_state   text NOT NULL,
  read_at         timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_history_dbs (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name text NOT NULL,
  created_at    timestamptz,
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_db_checks (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name       text NOT NULL,
  recovery_model      text,
  lsn_state           text NOT NULL,
  last_log_backup_lsn text,
  read_at             timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_file_checks (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name   text NOT NULL,
  backup_type     text NOT NULL CHECK (backup_type IN ('full', 'diff', 'log')),
  backup_set_uuid uuid,
  path            text NOT NULL,
  state           text NOT NULL CHECK (state IN ('present', 'gone', 'folder gone', 'not judged')),
  detail          text,
  read_at         timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, backup_type)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_path_check (
  instance_id int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  path        text,
  state       text CHECK (state IN ('directory', 'gone', 'not judged')),
  detail      text,
  files_state text NOT NULL,
  read_at     timestamptz NOT NULL
);

-- import_mssql_backup_history: the payload's kinds are named in internal/repo/backup_history_test.go's header. 0066's two
-- rules: a set is stored only for a database the read lists and only when it finished after the database was created
-- (an hour of slack); a database created anew under an old name loses the sets stored for the old one; a database the
-- server no longer lists loses its sets. A cursor read (from_set_id > 0) that lists a database the last read did not
-- sends the cursor to 0, so the next read is one whole pass (301's F7). The restores are written only when the read had
-- the right ('no right': the state says so and the stored restores stay). N = 10, M = 20 (the lead's E2). Its first
-- statement is 0066's mssql_hadr_read (the engine, the instance's lock for the collection, and a read older than the
-- stored one - a one-off collect imported late - changes nothing).
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_backup_history(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_from         bigint;
  v_restore_read text;
  v_again        boolean;
BEGIN
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_backup_history', p_snapshot_at,
                                 (SELECT count(*)::int FROM jsonb_array_elements(pgvigil.mssql_rows(p_payload)) r WHERE r->>'kind' = 'database')) THEN
    RETURN;
  END IF;
  SELECT coalesce((r->>'from_set_id')::bigint, 0), coalesce(r->>'restore_read', 'read') INTO v_from, v_restore_read
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'read' LIMIT 1;
  v_from := coalesce(v_from, 0);
  v_restore_read := coalesce(v_restore_read, 'read');

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.bkh_db (database_name text PRIMARY KEY, created_at timestamptz) ON COMMIT DROP;
  TRUNCATE pg_temp.bkh_db;
  INSERT INTO pg_temp.bkh_db
  SELECT DISTINCT ON (r->>'database_name') r->>'database_name', (r->>'created_utc')::timestamptz
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'database' AND coalesce(r->>'database_name', '') <> ''
   ORDER BY r->>'database_name';

  v_again := v_from > 0 AND EXISTS (
    SELECT 1 FROM pg_temp.bkh_db d
     WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_backup_history_dbs s WHERE s.instance_id = p_instance_id AND s.database_name = d.database_name));

  INSERT INTO pgvigil.mssql_backup_history AS h (instance_id, backup_set_uuid, backup_set_id, database_name, backup_type, is_copy_only,
         start_at, finish_at, size_bytes, compressed_bytes, recovery_model, user_name, machine_name, server_name, set_name,
         has_checksums, is_damaged, is_password_protected, is_snapshot, has_bulk_logged_data, is_readonly, is_force_offline,
         is_single_user, encryptor_type, key_algorithm, compression_algorithm, family_count, position,
         device_kind, path, first_lsn, last_lsn, checkpoint_lsn, database_backup_lsn, differential_base_guid, read_at)
  SELECT DISTINCT ON (x.backup_set_uuid) p_instance_id, x.backup_set_uuid, x.backup_set_id, x.database_name,
         CASE x.backup_type WHEN 'full' THEN 'D' WHEN 'diff' THEN 'I' ELSE 'L' END, coalesce(x.is_copy_only, 0) = 1,
         x.start_utc, x.finish_utc, x.size_bytes, x.compressed_bytes, x.recovery_model, x.user_name, x.machine_name, x.server_name,
         nullif(x.set_name, ''), x.has_checksums = 1, x.is_damaged = 1, x.is_password_protected = 1, x.is_snapshot = 1,
         x.has_bulk_logged_data = 1, x.is_readonly = 1, x.is_force_offline = 1, x.is_single_user = 1, nullif(x.encryptor_type, ''),
         nullif(x.key_algorithm, ''),
         nullif(x.compression_algorithm, ''), x.family_count, x.position, x.device_kind, x.path, x.first_lsn, x.last_lsn,
         x.checkpoint_lsn, x.database_backup_lsn, x.differential_base_guid, p_snapshot_at
    FROM jsonb_to_recordset(p_payload) AS x(kind text, database_name text, backup_type text, is_copy_only int, backup_set_id bigint,
         backup_set_uuid uuid, start_utc timestamptz, finish_utc timestamptz, size_bytes bigint, compressed_bytes bigint,
         recovery_model text, user_name text, machine_name text, server_name text, set_name text, has_checksums int,
         is_damaged int, is_password_protected int, is_snapshot int, has_bulk_logged_data int, is_readonly int,
         is_force_offline int, is_single_user int, encryptor_type text, key_algorithm text, compression_algorithm text, family_count int,
         position int, device_kind text, path text, first_lsn text, last_lsn text, checkpoint_lsn text, database_backup_lsn text,
         differential_base_guid uuid)
    JOIN pg_temp.bkh_db d ON d.database_name = x.database_name
   WHERE x.kind = 'set' AND x.backup_type IN ('full', 'diff', 'log') AND x.backup_set_uuid IS NOT NULL AND x.finish_utc IS NOT NULL
     AND (d.created_at IS NULL OR x.finish_utc >= d.created_at - interval '1 hour')
   ORDER BY x.backup_set_uuid, x.backup_set_id DESC
  ON CONFLICT (instance_id, backup_set_uuid) DO UPDATE
     SET backup_set_id = excluded.backup_set_id, finish_at = excluded.finish_at, path = excluded.path, device_kind = excluded.device_kind,
         read_at = excluded.read_at;

  IF EXISTS (SELECT 1 FROM pg_temp.bkh_db) THEN
    DELETE FROM pgvigil.mssql_backup_history h
     WHERE h.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pg_temp.bkh_db d WHERE d.database_name = h.database_name
                          AND (d.created_at IS NULL OR h.finish_at >= d.created_at - interval '1 hour'));
  END IF;

  DELETE FROM pgvigil.mssql_backup_history h
   USING (SELECT backup_set_uuid,
                 row_number() OVER (PARTITION BY database_name, backup_type, is_copy_only ORDER BY finish_at DESC, backup_set_id DESC) AS rn
            FROM pgvigil.mssql_backup_history WHERE instance_id = p_instance_id) k
   WHERE h.instance_id = p_instance_id AND h.backup_set_uuid = k.backup_set_uuid AND k.rn > 10;

  IF v_restore_read = 'read' THEN
    INSERT INTO pgvigil.mssql_restore_history AS rh (instance_id, restore_history_id, restore_at, destination_database_name, user_name,
           restore_type, is_replace, is_recovery, stop_at, source_server, source_database, source_type, source_finish_at,
           source_backup_set_uuid, source_path, read_at)
    SELECT DISTINCT ON (x.restore_history_id) p_instance_id, x.restore_history_id, x.restore_utc, x.destination_database_name,
           x.user_name, x.restore_type, x.replace = 1, x.recovery = 1, x.stop_at_utc, x.source_server, x.source_database,
           x.source_type, x.source_finish_utc, x.source_backup_set_uuid, x.source_path, p_snapshot_at
      FROM jsonb_to_recordset(p_payload) AS x(kind text, restore_history_id bigint, restore_utc timestamptz,
           destination_database_name text, user_name text, restore_type text, replace int, recovery int, stop_at_utc timestamptz,
           source_server text, source_database text, source_type text, source_finish_utc timestamptz, source_backup_set_uuid uuid,
           source_path text)
     WHERE x.kind = 'restore' AND x.restore_history_id IS NOT NULL AND x.restore_utc IS NOT NULL
       AND coalesce(x.destination_database_name, '') <> '' AND coalesce(x.restore_type, '') <> ''
     ORDER BY x.restore_history_id
    ON CONFLICT (instance_id, restore_history_id) DO UPDATE
       SET restore_at = excluded.restore_at, destination_database_name = excluded.destination_database_name,
           user_name = excluded.user_name, restore_type = excluded.restore_type, is_replace = excluded.is_replace,
           is_recovery = excluded.is_recovery, stop_at = excluded.stop_at, source_server = excluded.source_server,
           source_database = excluded.source_database, source_type = excluded.source_type,
           source_finish_at = excluded.source_finish_at, source_backup_set_uuid = excluded.source_backup_set_uuid,
           source_path = excluded.source_path, read_at = excluded.read_at;

    DELETE FROM pgvigil.mssql_restore_history h
     USING (SELECT restore_history_id,
                   row_number() OVER (PARTITION BY destination_database_name, restore_type ORDER BY restore_at DESC, restore_history_id DESC) AS rn
              FROM pgvigil.mssql_restore_history WHERE instance_id = p_instance_id) k
     WHERE h.instance_id = p_instance_id AND h.restore_history_id = k.restore_history_id AND k.rn > 20;
  END IF;

  INSERT INTO pgvigil.mssql_backup_history_cursor AS c (instance_id, last_set_id, set_mark, last_restore_id, restore_mark, restore_state, read_at)
  SELECT p_instance_id,
         CASE WHEN v_again THEN 0 ELSE (SELECT (r->>'last_id')::bigint FROM jsonb_array_elements(p_payload) r
                                         WHERE r->>'kind' = 'cursor' AND r->>'source' = 'backup_history' LIMIT 1) END,
         (SELECT (r->>'mark')::bigint FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cursor' AND r->>'source' = 'backup_history' LIMIT 1),
         (SELECT (r->>'last_id')::bigint FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cursor' AND r->>'source' = 'restore_history' LIMIT 1),
         (SELECT (r->>'mark')::bigint FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cursor' AND r->>'source' = 'restore_history' LIMIT 1),
         CASE WHEN v_restore_read = 'read' THEN 'read' ELSE 'not read: no right (SELECT on msdb.dbo.restorehistory)' END,
         p_snapshot_at
  ON CONFLICT (instance_id) DO UPDATE
     SET last_set_id = coalesce(excluded.last_set_id, c.last_set_id), set_mark = coalesce(excluded.set_mark, c.set_mark),
         last_restore_id = CASE WHEN v_restore_read = 'read' THEN coalesce(excluded.last_restore_id, c.last_restore_id) ELSE c.last_restore_id END,
         restore_mark = CASE WHEN v_restore_read = 'read' THEN coalesce(excluded.restore_mark, c.restore_mark) ELSE c.restore_mark END,
         restore_state = excluded.restore_state, read_at = excluded.read_at;

  IF EXISTS (SELECT 1 FROM pg_temp.bkh_db) THEN
    DELETE FROM pgvigil.mssql_backup_history_dbs s WHERE s.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pg_temp.bkh_db d WHERE d.database_name = s.database_name);
    INSERT INTO pgvigil.mssql_backup_history_dbs (instance_id, database_name, created_at)
    SELECT p_instance_id, d.database_name, d.created_at FROM pg_temp.bkh_db d
    ON CONFLICT (instance_id, database_name) DO UPDATE SET created_at = excluded.created_at;
  END IF;
END $$;

-- import_mssql_backup_checks: each read replaces the instance's database and file rows, and its path row. A file row
-- is kept only when the file check ran ('files_read' state 'read'); off ('not read: the file check is off') or refused,
-- every file cell carries that state. Its first statement is 0066's mssql_hadr_read (as import_mssql_backup_history).
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_backup_checks(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_files text;
BEGIN
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_backup_checks', p_snapshot_at,
                                 (SELECT count(*)::int FROM jsonb_array_elements(pgvigil.mssql_rows(p_payload)) r WHERE r->>'kind' = 'database')) THEN
    RETURN;
  END IF;
  SELECT coalesce(r->>'state', 'not read') INTO v_files FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'files_read' LIMIT 1;
  v_files := coalesce(v_files, 'not read');

  DELETE FROM pgvigil.mssql_backup_db_checks WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_backup_db_checks (instance_id, database_name, recovery_model, lsn_state, last_log_backup_lsn, read_at)
  SELECT DISTINCT ON (x.database_name) p_instance_id, x.database_name, x.recovery_model, coalesce(nullif(x.lsn_state, ''), 'not read'),
         nullif(x.last_log_backup_lsn, ''), p_snapshot_at
    FROM jsonb_to_recordset(p_payload) AS x(kind text, database_name text, recovery_model text, lsn_state text, last_log_backup_lsn text)
   WHERE x.kind = 'database' AND coalesce(x.database_name, '') <> ''
   ORDER BY x.database_name;

  DELETE FROM pgvigil.mssql_backup_file_checks WHERE instance_id = p_instance_id;
  IF v_files = 'read' THEN
    INSERT INTO pgvigil.mssql_backup_file_checks (instance_id, database_name, backup_type, backup_set_uuid, path, state, detail, read_at)
    SELECT DISTINCT ON (x.database_name, x.backup_type) p_instance_id, x.database_name, x.backup_type, x.backup_set_uuid, x.path,
           x.state, nullif(x.detail, ''), p_snapshot_at
      FROM jsonb_to_recordset(p_payload) AS x(kind text, database_name text, backup_type text, backup_set_uuid uuid, path text,
           state text, detail text)
     WHERE x.kind = 'file' AND coalesce(x.database_name, '') <> '' AND x.backup_type IN ('full', 'diff', 'log')
       AND coalesce(x.path, '') <> '' AND x.state IN ('present', 'gone', 'folder gone', 'not judged')
     ORDER BY x.database_name, x.backup_type;
  END IF;

  INSERT INTO pgvigil.mssql_backup_path_check AS p (instance_id, path, state, detail, files_state, read_at)
  SELECT p_instance_id, nullif(r->>'path', ''), CASE WHEN r->>'state' IN ('directory', 'gone', 'not judged') THEN r->>'state' END,
         nullif(r->>'detail', ''), v_files, p_snapshot_at
    FROM (SELECT (SELECT r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'default_path' LIMIT 1) AS r) q
  ON CONFLICT (instance_id) DO UPDATE
     SET path = excluded.path, state = excluded.state, detail = excluded.detail, files_state = excluded.files_state,
         read_at = excluded.read_at;
END $$;

-- mssql_backup_file_newer: the judged set of a file row's database and type when it is another set (F6: Database#7
-- judges only 0140's judged set - the group's newest of its type that is not copy-only over the monitored replicas -
-- and each replica checks its own msdb's newest): a row of mssql_backup_locations, NULL when the judged set is the
-- file row's own or 0140 holds no set of that database and type (its read has not run: the check stands alone).
CREATE OR REPLACE FUNCTION pgvigil.mssql_backup_file_newer(p_instance_id int, p_database text, p_type text, p_uuid uuid)
RETURNS TABLE (from_instance_id int, from_instance text) LANGUAGE sql STABLE AS $$
  SELECT l.from_instance_id, l.from_instance FROM pgvigil.mssql_backup_locations l
   WHERE l.instance_id = p_instance_id AND l.database_name = p_database AND l.backup_type = p_type AND l.judged
     AND lower(l.backup_set_uuid) IS DISTINCT FROM p_uuid::text   -- 0140 keeps the uuid as SQL Server's text
   LIMIT 1
$$;

-- mssql_backup_file_cell: the words of one database's newest <type> file cell: the file check's own state, or 'not
-- judged' when the judged set is another (mssql_backup_file_newer): 'a newer <type> backup ran on <replica>', or on
-- this instance 'the backup read and the file check saw different newest sets' (the next reads agree).
CREATE OR REPLACE FUNCTION pgvigil.mssql_backup_file_cell(p_instance_id int, p_database text, p_type text)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN n.from_instance_id IS NULL THEN CASE f.state WHEN 'present' THEN 'present' ELSE f.detail END
              WHEN n.from_instance_id <> f.instance_id
                THEN 'not judged: a newer ' || CASE p_type WHEN 'full' THEN 'full' WHEN 'diff' THEN 'differential' ELSE 'log' END
                     || ' backup ran on ' || n.from_instance
              ELSE 'not judged: the backup read and the file check saw different newest sets' END
    FROM pgvigil.mssql_backup_file_checks f
    LEFT JOIN LATERAL pgvigil.mssql_backup_file_newer(f.instance_id, f.database_name, f.backup_type, f.backup_set_uuid) n ON true
   WHERE f.instance_id = p_instance_id AND f.database_name = p_database AND f.backup_type = p_type
$$;

-- mssql_backup_check_cells: per database of the last read, the pseudo-simple cell and the newest full / diff / log
-- backup's file cell, in words. Pseudo-simple (dbachecks' PseudoSimple; probe 301bP1): FULL or BULK_LOGGED with
-- last_log_backup_lsn NULL - before the first full, and after SIMPLE -> FULL until a full or a differential; a restored
-- database is never pseudo-simple, a RESTORING one reads NULL and is not judged (mssql_backup_judged's state rule).
-- master, model, msdb and tempdb are never judged; a database mssql_backup_judged leaves out says its reason (before
-- its recovery model). The file cells: mssql_backup_file_cell.
CREATE OR REPLACE VIEW pgvigil.mssql_backup_check_cells AS
SELECT dc.instance_id, dc.database_name, dc.recovery_model, dc.read_at,
       CASE WHEN dc.database_name IN ('master', 'model', 'msdb', 'tempdb') THEN 'not judged: ' || dc.database_name
            WHEN dc.lsn_state <> 'read' THEN dc.lsn_state
            WHEN j.database_name IS NULL THEN 'not judged: not in the backup read'
            WHEN j.not_judged IS NOT NULL THEN 'not judged: ' || j.not_judged
            WHEN dc.recovery_model IS NULL OR dc.recovery_model NOT IN ('FULL', 'BULK_LOGGED') THEN 'no (' || coalesce(dc.recovery_model, 'unknown') || ')'
            WHEN dc.last_log_backup_lsn IS NULL
              THEN 'yes: ' || dc.recovery_model || ', but no log backup can be taken: no full or differential backup since the log chain began'
            ELSE 'no' END AS pseudo_simple,
       CASE WHEN p.files_state IS DISTINCT FROM 'read' THEN coalesce(p.files_state, 'not read')
            ELSE pgvigil.mssql_backup_file_cell(dc.instance_id, dc.database_name, 'full') END AS file_full,
       CASE WHEN p.files_state IS DISTINCT FROM 'read' THEN coalesce(p.files_state, 'not read')
            ELSE pgvigil.mssql_backup_file_cell(dc.instance_id, dc.database_name, 'diff') END AS file_diff,
       CASE WHEN p.files_state IS DISTINCT FROM 'read' THEN coalesce(p.files_state, 'not read')
            ELSE pgvigil.mssql_backup_file_cell(dc.instance_id, dc.database_name, 'log') END AS file_log,
       j.not_judged, j.replicas_unseen
  FROM pgvigil.mssql_backup_db_checks dc
  LEFT JOIN pgvigil.mssql_backup_path_check p ON p.instance_id = dc.instance_id
  LEFT JOIN pgvigil.mssql_backup_judged j ON j.instance_id = dc.instance_id AND j.database_name = dc.database_name;

-- mssql_backup_path_cells: per instance the default backup path, its words and reachable (yes / no; NULL = not judged):
-- the Properties tab's row 'Default backup path reachable' beside mssql_properties' own 'Default backup path'.
CREATE OR REPLACE VIEW pgvigil.mssql_backup_path_cells AS
SELECT p.instance_id, p.path AS default_backup_path,
       coalesce(p.detail, CASE p.state WHEN 'directory' THEN 'a directory the service account sees (writing not tried)'
                                       WHEN 'gone' THEN 'not a directory the service account sees' ELSE 'not judged' END) AS default_backup_path_state,
       p.files_state, p.read_at,
       CASE p.state WHEN 'directory' THEN 'yes' WHEN 'gone' THEN 'no' END AS reachable
  FROM pgvigil.mssql_backup_path_check p;

-- mssql_backup_check_findings: the three findings (warning each, the lead's E5). A file is judged only for a database
-- mssql_backup_judged judges (no not-judged reason), 'info' when a replica of its availability group is not monitored
-- (0140's rule); an answered 'gone' is the finding, a timeout or a refusal is 'not judged' and none (F5); a set that
-- is not 0140's judged set (a newer one ran on another replica) raises none (F6: mssql_backup_file_newer).
CREATE OR REPLACE VIEW pgvigil.mssql_backup_check_findings AS
SELECT f.instance_id, CASE WHEN j.replicas_unseen THEN 'info' ELSE 'warning' END AS severity, 'backup file missing'::text AS check_name,
       f.database_name || ' (' || f.backup_type || ')' AS object,
       'the newest ' || f.backup_type || ' backup''s file is not where msdb says it was written: ' || f.path || ' ('
         || coalesce(f.detail, CASE f.state WHEN 'gone' THEN 'the file is gone' ELSE 'its folder is gone' END)
         || ') - a job may have moved it, or it was deleted' AS detail,
       f.read_at AS at
  FROM pgvigil.mssql_backup_file_checks f
  JOIN pgvigil.mssql_backup_path_check p ON p.instance_id = f.instance_id AND p.files_state = 'read'
  JOIN pgvigil.mssql_backup_judged j ON j.instance_id = f.instance_id AND j.database_name = f.database_name AND j.not_judged IS NULL
 WHERE f.state IN ('gone', 'folder gone')
   AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_backup_file_newer(f.instance_id, f.database_name, f.backup_type, f.backup_set_uuid))
UNION ALL
SELECT c.instance_id, 'warning', 'pseudo-simple recovery', c.database_name, substr(c.pseudo_simple, 6), c.read_at
  FROM pgvigil.mssql_backup_check_cells c
 WHERE c.pseudo_simple LIKE 'yes: %'
UNION ALL
SELECT p.instance_id, 'warning', 'default backup path not reachable', p.path,
       'the default backup path ' || p.path || ' is ' || coalesce(p.detail, 'not a directory the service account sees'), p.read_at
  FROM pgvigil.mssql_backup_path_check p
 WHERE p.state = 'gone' AND p.path IS NOT NULL;

-- actions_log: verify_backup (RESTORE VERIFYONLY through the actions door, task 301b) on SQL Server, no pid; its run is
-- detached from the request, so its audit has the outcomes started, cut by shutdown (serve stopped under it) and ended
-- unknown (a 'started' row found at serve's start with no end). 0157's lists whole, plus these.
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_action_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_action_check CHECK (
     (engine = 'postgres' AND action IN ('cancel', 'terminate', 'explain_analyze', 'hypo_index', 'job_stop', 'job_start'))
  OR (engine = 'sqlserver' AND action IN ('kill', 'job_start', 'job_stop', 'plan_evict', 'verify_backup')));
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_pid_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_pid_check CHECK (pid IS NOT NULL OR action IN ('explain_analyze', 'hypo_index', 'job_start', 'job_stop', 'plan_evict', 'verify_backup'));
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_outcome_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_outcome_check CHECK (outcome IN ('done', 'refused', 'failed', 'started', 'cut by shutdown', 'ended unknown'));

-- the Backup history's 'last verify' (one row per set: the newest verify of its uuid) reads by this
CREATE INDEX IF NOT EXISTS actions_log_verify_idx ON pgvigil.actions_log (instance_id, action, target_id, at DESC);

SELECT pgvigil.apply_roles();
