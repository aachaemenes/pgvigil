-- 0140: where a SQL Server database's newest backups went (task 301): every file of the newest full, differential and log
-- backup, the set's own facts (who took it, its name, checksum, encryption, compression, the media set), the database's
-- own files at backup time, the log writers of the last 7 days, and every destination root a database's backups were
-- seen at. The collection mssql_backup_files (internal/mssql/backups.go) reads msdb on from a backup_set_id cursor;
-- 0066's mssql_backup_state and import_mssql_backups stay as they are (the ages and the Summary's backup cells keep
-- reading them alone).
--   mssql_backup_sets         current: per database, type and copy-only the newest set a read listed (so beside a
--                             copy-only full the newest full that is not copy-only stays too), with its LSNs and guids
--                             (the restore chain, task 304, reads them)
--   mssql_backup_files        current: each media family and mirror of a stored set (the path whole: msdb's own
--                             physical_device_name is nvarchar(260))
--   mssql_backup_dbfiles      current: the database's data and log files as msdb.dbo.backupfile recorded them with the set
--   mssql_backup_writers      current: the log backups of the last 7 days (not copy-only) by device kind and destination
--                             root, with the logins that took them
--   mssql_backup_roots_seen   per database, type and destination root: when a set was first and last seen there
--   mssql_backup_files_cursor the collection's cursor: the newest backup_set_id read and that row's mark
-- Views: mssql_backup_locations (the newest set of each type merged over an availability group's monitored replicas,
-- with where it ran, whether it is judged and whether it sits on the database's own volume), mssql_backup_loc_findings,
-- mssql_backup_loc_db (per database the 'to' cells and DBA Dash's per-type flags) and mssql_backup_loc_inst (per
-- instance DBA Dash's 'n/m' counts and compression algorithms).
-- mssql_hadr_cursor is 0083's with one more pair of sources ('backup_sets', 'backup_sets_mark'); its other arms are
-- 0083's line for line (internal/repo TestHADRCursor0140Is0083PlusBackupSets).
-- For the lead's join (never here): the pgvigil.findings arm of mssql_backup_loc_findings and purge()'s line for
-- mssql_backup_roots_seen (400 days at least), scripts/inv-301-join-lines.sql.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_sets (
  instance_id            int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name          text NOT NULL,
  backup_type            text NOT NULL CHECK (backup_type IN ('full', 'diff', 'log')),
  is_copy_only           boolean NOT NULL,
  snapshot_at            timestamptz NOT NULL,      -- the read that stored it
  db_created_at          timestamptz,               -- the database's creation time at that read (a database created anew loses its sets)
  backup_set_id          bigint NOT NULL,
  backup_set_uuid        text,
  media_set_id           bigint,
  start_at               timestamptz,
  finish_at              timestamptz NOT NULL,      -- UTC by the set's own recorded offset
  duration_s             bigint,
  size_bytes             bigint,
  compressed_bytes       bigint,
  recovery_model         text,
  user_name              text,                      -- the login that took it
  machine_name           text,
  set_name               text,
  description            text,
  has_checksums          boolean,
  is_damaged             boolean,
  is_password_protected  boolean,                   -- backupset's own bit (DBA Dash's 'Password Protected')
  has_bulk_logged_data   boolean,
  is_readonly            boolean,
  is_single_user         boolean,
  is_force_offline       boolean,
  has_incomplete_metadata boolean,
  is_snapshot            boolean,
  key_algorithm          text,                      -- 'NO_Encryption' = not encrypted
  encryptor_type         text,
  compression_algorithm  text,                      -- SQL Server 2022 and later; NULL before
  last_valid_restore_at  timestamptz,               -- SQL Server 2022 and later; NULL before
  family_count           int,
  mirror_count           int,
  software_name          text,
  software_vendor_id     int,
  media_compressed       boolean,
  media_encrypted        boolean,
  media_password         boolean,                   -- the media set's bit (pgvigil's own column)
  device_kind            text,                      -- of family 1, mirror 0: disk, url, tape, virtual device
  folder                 text,                      -- family 1, mirror 0's directory (a URL's container)
  roots                  text[],                    -- the distinct destination roots of every family and mirror
  database_guid          text,
  family_guid            text,
  first_recovery_fork_guid text,
  last_recovery_fork_guid  text,
  fork_point_lsn         numeric(25,0),
  first_lsn              numeric(25,0),
  last_lsn               numeric(25,0),
  checkpoint_lsn         numeric(25,0),
  database_backup_lsn    numeric(25,0),
  differential_base_lsn  numeric(25,0),
  differential_base_guid text,
  begins_log_chain       boolean,
  PRIMARY KEY (instance_id, database_name, backup_type, is_copy_only)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_files (
  instance_id    int NOT NULL,
  database_name  text NOT NULL,
  backup_type    text NOT NULL,
  is_copy_only   boolean NOT NULL,
  backup_set_id  bigint NOT NULL,
  family         int NOT NULL,                      -- family_sequence_number: stripe n of family_count
  mirror         int NOT NULL,                      -- 0-3: one row per mirror
  device_kind    text,
  logical_name   text,
  path           text NOT NULL,
  root           text,
  PRIMARY KEY (instance_id, database_name, backup_type, is_copy_only, family, mirror),
  FOREIGN KEY (instance_id, database_name, backup_type, is_copy_only)
    REFERENCES pgvigil.mssql_backup_sets (instance_id, database_name, backup_type, is_copy_only) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_dbfiles (
  instance_id    int NOT NULL,
  database_name  text NOT NULL,
  backup_type    text NOT NULL,
  is_copy_only   boolean NOT NULL,
  backup_set_id  bigint NOT NULL,
  file_number    int NOT NULL,
  file_type      text,                              -- D data, L log
  logical_name   text,
  physical_name  text,
  PRIMARY KEY (instance_id, database_name, backup_type, is_copy_only, file_number),
  FOREIGN KEY (instance_id, database_name, backup_type, is_copy_only)
    REFERENCES pgvigil.mssql_backup_sets (instance_id, database_name, backup_type, is_copy_only) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_writers (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  device_kind    text NOT NULL,
  root           text NOT NULL,
  users          text[] NOT NULL DEFAULT '{}',
  sets           int NOT NULL,
  first_at       timestamptz,
  last_at        timestamptz,
  snapshot_at    timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, device_kind, root)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_roots_seen (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  backup_type    text NOT NULL,
  root           text NOT NULL,
  first_seen     timestamptz NOT NULL,              -- the finish of the first set seen there
  last_seen      timestamptz NOT NULL,              -- the finish of the newest set seen there
  first_set_id   bigint,                            -- that first set's backup_set_id: msdb keeps finish times to the second, two
                                                    -- sets of one second are told apart by it (a proof run, 11-14)
  PRIMARY KEY (instance_id, database_name, backup_type, root)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_backup_files_cursor (
  instance_id    int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  last_set_id    bigint NOT NULL,
  mark           bigint,                            -- CHECKSUM(backup_set_uuid) of the row at last_set_id as it was read
  updated_at     timestamptz NOT NULL
);

-- mssql_backup_root: the destination a backup file's path names, the part that does not change from one backup to the
-- next (a date folder, a file name). A URL by its scheme, never by the device kind: Azure Blob 'https://<account>/<container>';
-- S3 path style (an endpoint with a port, an IP address, or a host starting 's3.' / 's3-') 's3://<endpoint>/<bucket>',
-- virtual-host style 's3://<bucket>.<domain>'; any other scheme '<scheme>://<host>'. A share '\\host\share' in lower case
-- (\\name, \\name.domain and \\10.1.2.3 are three roots, and a DFS namespace hides its target); a drive 'X:\'; a Linux
-- path its first two directories ('/mnt/nfs_old'); a virtual device 'virtual device (<software>)'; NUL and a tape as
-- named; anything else the path itself.
CREATE OR REPLACE FUNCTION pgvigil.mssql_backup_root(p_path text, p_kind text, p_software text DEFAULT NULL)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_path IS NULL OR btrim(p_path) = '' THEN NULL
    WHEN upper(btrim(p_path)) IN ('NUL', 'NUL:') THEN 'NUL'
    WHEN p_path ~* '^[a-z][a-z0-9+.-]*://' THEN
      (SELECT CASE
         WHEN u.scheme = 's3' AND (u.host ~ ':[0-9]+$' OR u.host ~ '^[0-9.]+(:[0-9]+)?$' OR u.host ~ '^\[' OR u.host ~* '^s3[.-]')
           THEN 's3://' || u.host || coalesce('/' || nullif(u.seg1, ''), '')
         WHEN u.scheme = 's3' THEN 's3://' || u.host
         WHEN u.scheme IN ('https', 'http') THEN u.scheme || '://' || u.host || coalesce('/' || nullif(u.seg1, ''), '')
         ELSE u.scheme || '://' || u.host END
         FROM (SELECT lower(split_part(p_path, '://', 1)) AS scheme,
                      lower(split_part(split_part(p_path, '://', 2), '/', 1)) AS host,
                      split_part(split_part(p_path, '://', 2), '/', 2) AS seg1) u)
    WHEN p_kind = 'virtual device' THEN 'virtual device (' || coalesce(nullif(btrim(p_software), ''), 'unknown software') || ')'
    WHEN p_kind = 'tape' THEN 'tape ' || p_path
    WHEN p_path ~ '^\\\\[^\\]+\\[^\\]+' THEN lower(substring(p_path FROM '^(\\\\[^\\]+\\[^\\]+)'))
    WHEN p_path ~ '^[A-Za-z]:[\\/]' THEN upper(left(p_path, 1)) || ':\'
    WHEN p_path ~ '^/' THEN coalesce(substring(p_path FROM '^(/[^/]+/[^/]+)/'), substring(p_path FROM '^(/[^/]+)/'), p_path)
    ELSE p_path END
$$;

-- mssql_backup_dir: a path's directory with its separator ('D:\Backup\db\' of 'D:\Backup\db\x.bak'); NULL when it has none
CREATE OR REPLACE FUNCTION pgvigil.mssql_backup_dir(p_path text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT substring(p_path FROM '^(.*[\\/])[^\\/]*$')
$$;

-- mssql_backup_volume: the Windows volume a path sits on - the longest of the instance's volumes (mssql_volumes: the
-- mount points sys.dm_os_volume_stats named, a mounted folder or a Cluster Shared Volume among them) that the path
-- starts with, compared without case; the drive letter when none is; NULL for a share, a URL or a Linux path.
CREATE OR REPLACE FUNCTION pgvigil.mssql_backup_volume(p_instance_id int, p_path text)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_path ~ '^[A-Za-z]:[\\/]' THEN
    coalesce((SELECT upper(v.volume) FROM pgvigil.mssql_volumes v
               WHERE v.instance_id = p_instance_id AND v.is_present AND v.volume ~ '^[A-Za-z]:[\\/]'
                 AND left(upper(replace(p_path, '/', '\')), length(v.volume)) = upper(replace(v.volume, '/', '\'))
               ORDER BY length(v.volume) DESC LIMIT 1),
             upper(left(p_path, 1)) || ':\')
  END
$$;

-- mssql_backup_same_volume: whether a stored set's files sit with the database's own files, in words. 'yes: ...' is a
-- finding; 'no' is none; 'not judged: ...' says why it cannot be told. Windows: by volume (above); the instance's volumes
-- never read (the storage collection skipped, or every volume NULL without VIEW SERVER STATE) = not judged. Linux (a
-- path starting '/'): only a backup in the directory of one of the database's files (or below it) is judged, as 'yes';
-- the volume of any other directory is not read. A share, a URL, a tape or a virtual device never sits on the database's
-- volume. Amazon RDS and Managed Instance: not judged until a real row of theirs is seen.
CREATE OR REPLACE FUNCTION pgvigil.mssql_backup_same_volume(p_instance_id int, p_database text, p_type text, p_copy_only boolean)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_platform text;
  v_kind text;
  v_hit text;
BEGIN
  SELECT platform INTO v_platform FROM pgvigil.instances WHERE instance_id = p_instance_id;
  IF v_platform IN ('rdssqlserver', 'azuresqlmi') THEN
    RETURN 'not judged: ' || CASE v_platform WHEN 'rdssqlserver' THEN 'Amazon RDS' ELSE 'Azure SQL Managed Instance' END
           || ' - the volume of its backup rows is not known (no real row of it seen yet)';
  END IF;
  SELECT device_kind INTO v_kind FROM pgvigil.mssql_backup_sets
   WHERE instance_id = p_instance_id AND database_name = p_database AND backup_type = p_type AND is_copy_only = p_copy_only;
  IF NOT EXISTS (SELECT 1 FROM pgvigil.mssql_backup_files f WHERE f.instance_id = p_instance_id AND f.database_name = p_database
                    AND f.backup_type = p_type AND f.is_copy_only = p_copy_only AND (f.path ~ '^[A-Za-z]:[\\/]' OR f.path ~ '^/')) THEN
    RETURN 'no';   -- a share, a URL, a tape, a virtual device
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pgvigil.mssql_backup_dbfiles d WHERE d.instance_id = p_instance_id AND d.database_name = p_database
                    AND d.backup_type = p_type AND d.is_copy_only = p_copy_only AND d.physical_name IS NOT NULL) THEN
    RETURN 'not judged: msdb recorded no file of the database with this backup';
  END IF;
  -- Linux: the directory rule
  SELECT f.path || ' is in ' || pgvigil.mssql_backup_dir(d.physical_name) || ', the directory of ' || d.physical_name INTO v_hit
    FROM pgvigil.mssql_backup_files f
    JOIN pgvigil.mssql_backup_dbfiles d ON d.instance_id = f.instance_id AND d.database_name = f.database_name
         AND d.backup_type = f.backup_type AND d.is_copy_only = f.is_copy_only
   WHERE f.instance_id = p_instance_id AND f.database_name = p_database AND f.backup_type = p_type AND f.is_copy_only = p_copy_only
     AND f.path ~ '^/' AND d.physical_name ~ '^/' AND pgvigil.mssql_backup_dir(d.physical_name) IS NOT NULL
     AND left(f.path, length(pgvigil.mssql_backup_dir(d.physical_name))) = pgvigil.mssql_backup_dir(d.physical_name)
   ORDER BY f.family, f.mirror, d.file_number LIMIT 1;
  IF v_hit IS NOT NULL THEN
    RETURN 'yes: ' || v_hit;
  END IF;
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_backup_files f WHERE f.instance_id = p_instance_id AND f.database_name = p_database
                AND f.backup_type = p_type AND f.is_copy_only = p_copy_only AND f.path ~ '^/') THEN
    RETURN 'not judged: on Linux only a backup in the directory of the database''s own files is judged (the volume of another directory is not read)';
  END IF;
  -- Windows: by volume
  IF NOT EXISTS (SELECT 1 FROM pgvigil.mssql_volumes v WHERE v.instance_id = p_instance_id AND v.is_present AND v.volume ~ '^[A-Za-z]:[\\/]') THEN
    RETURN 'not judged: volumes not read (the storage collection needs VIEW ANY DEFINITION and VIEW SERVER STATE)';
  END IF;
  SELECT f.path || ' is on ' || pgvigil.mssql_backup_volume(p_instance_id, f.path) || ', the volume of ' || d.physical_name INTO v_hit
    FROM pgvigil.mssql_backup_files f
    JOIN pgvigil.mssql_backup_dbfiles d ON d.instance_id = f.instance_id AND d.database_name = f.database_name
         AND d.backup_type = f.backup_type AND d.is_copy_only = f.is_copy_only
   WHERE f.instance_id = p_instance_id AND f.database_name = p_database AND f.backup_type = p_type AND f.is_copy_only = p_copy_only
     AND f.path ~ '^[A-Za-z]:[\\/]' AND d.physical_name ~ '^[A-Za-z]:[\\/]'
     AND pgvigil.mssql_backup_volume(p_instance_id, f.path) = pgvigil.mssql_backup_volume(p_instance_id, d.physical_name)
   ORDER BY f.family, f.mirror, d.file_number LIMIT 1;
  RETURN CASE WHEN v_hit IS NOT NULL THEN 'yes: ' || v_hit ELSE 'no' END;
END $$;

-- mssql_hadr_cursor: 0083's, with the collection mssql_backup_files' cursor:
--   'backup_sets', 'backup_sets_mark'  the newest backup_set_id read and CHECKSUM(backup_set_uuid) of that row (msdb
--                                      replaced under the cursor shows as another mark).
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
    WHEN p_source IN ('backup_sets', 'backup_sets_mark') THEN
      (SELECT CASE p_source WHEN 'backup_sets' THEN c.last_set_id ELSE c.mark END
         FROM pgvigil.mssql_backup_files_cursor c WHERE c.instance_id = p_instance_id)
  END
$$;

-- payload: 'database' rows (every database the server lists: its name and creation time), 'set' rows (per database,
-- type and copy-only the newest set of the cursor's range), 'file' and 'dbfile' rows of those sets (by backup_set_id),
-- 'writer' rows with one 'writers_read' row (the 7-day window was read), one 'read' row, and from a cursor read one
-- 'cursor' row {last_set_id, mark}. 0066's two rules: a set is stored only for a database the read lists and only when
-- it finished after the database was created (an hour of slack: the creation time is converted at the read); a database
-- created anew under an old name (mssql_recreated) loses the sets stored for the old one; a database the server no longer
-- lists loses its sets. A stored set stays when a later read does not list it (the cursor reads only what is new) and is
-- replaced only by a newer set of its key.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_backup_files(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := pgvigil.mssql_rows(p_payload);
  v_dbs int;
BEGIN
  v_dbs := (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'database');
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_backup_files', p_snapshot_at, v_dbs) THEN
    RETURN;
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pgv_bf_db (database_name text PRIMARY KEY, created_at timestamptz) ON COMMIT DROP;
  TRUNCATE pgv_bf_db;
  INSERT INTO pgv_bf_db
  SELECT DISTINCT ON (r->>'database_name') r->>'database_name', (r->>'created_utc')::timestamptz
    FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'database' AND r->>'database_name' IS NOT NULL;

  IF v_dbs > 0 THEN
    -- gone from the server, or created anew under its name
    DELETE FROM pgvigil.mssql_backup_sets s
     WHERE s.instance_id = p_instance_id
       AND (NOT EXISTS (SELECT 1 FROM pgv_bf_db d WHERE d.database_name = s.database_name)
            OR EXISTS (SELECT 1 FROM pgv_bf_db d WHERE d.database_name = s.database_name AND pgvigil.mssql_recreated(s.db_created_at, d.created_at)));
    DELETE FROM pgvigil.mssql_backup_writers w
     WHERE w.instance_id = p_instance_id AND NOT EXISTS (SELECT 1 FROM pgv_bf_db d WHERE d.database_name = w.database_name);
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pgv_bf_set (r jsonb, database_name text, backup_type text, is_copy_only boolean,
    backup_set_id bigint, finish_at timestamptz, created_at timestamptz) ON COMMIT DROP;
  TRUNCATE pgv_bf_set;
  INSERT INTO pgv_bf_set
  SELECT DISTINCT ON (r->>'database_name', r->>'backup_type', (r->>'is_copy_only')::int = 1)
         r, r->>'database_name', r->>'backup_type', (r->>'is_copy_only')::int = 1, (r->>'backup_set_id')::bigint,
         (r->>'finish_utc')::timestamptz, d.created_at
    FROM jsonb_array_elements(v_rows) r
    JOIN pgv_bf_db d ON d.database_name = r->>'database_name'
   WHERE r->>'kind' = 'set' AND r->>'backup_type' IN ('full', 'diff', 'log') AND r->>'finish_utc' IS NOT NULL
     AND (d.created_at IS NULL OR (r->>'finish_utc')::timestamptz >= d.created_at - interval '1 hour')
   ORDER BY r->>'database_name', r->>'backup_type', (r->>'is_copy_only')::int = 1,
            (r->>'finish_utc')::timestamptz DESC, (r->>'backup_set_id')::bigint DESC;

  INSERT INTO pgvigil.mssql_backup_sets AS s (instance_id, database_name, backup_type, is_copy_only, snapshot_at, db_created_at,
      backup_set_id, backup_set_uuid, media_set_id, start_at, finish_at, duration_s, size_bytes, compressed_bytes, recovery_model,
      user_name, machine_name, set_name, description, has_checksums, is_damaged, is_password_protected, has_bulk_logged_data,
      is_readonly, is_single_user, is_force_offline, has_incomplete_metadata, is_snapshot, key_algorithm, encryptor_type,
      compression_algorithm, last_valid_restore_at, family_count, mirror_count, software_name, software_vendor_id,
      media_compressed, media_encrypted, media_password, device_kind, folder, roots,
      database_guid, family_guid, first_recovery_fork_guid, last_recovery_fork_guid, fork_point_lsn, first_lsn, last_lsn,
      checkpoint_lsn, database_backup_lsn, differential_base_lsn, differential_base_guid, begins_log_chain)
  SELECT p_instance_id, x.database_name, x.backup_type, x.is_copy_only, p_snapshot_at, x.created_at,
         x.backup_set_id, lower(x.r->>'backup_set_uuid'), (x.r->>'media_set_id')::bigint, (x.r->>'start_utc')::timestamptz, x.finish_at,
         (x.r->>'duration_s')::bigint, (x.r->>'size_bytes')::bigint, (x.r->>'compressed_bytes')::bigint, x.r->>'recovery_model',
         x.r->>'user_name', x.r->>'machine_name', x.r->>'set_name', x.r->>'description',
         (x.r->>'has_checksums')::int = 1, (x.r->>'is_damaged')::int = 1, (x.r->>'is_password_protected')::int = 1,
         (x.r->>'has_bulk_logged_data')::int = 1, (x.r->>'is_readonly')::int = 1, (x.r->>'is_single_user')::int = 1,
         (x.r->>'is_force_offline')::int = 1, (x.r->>'has_incomplete_metadata')::int = 1, (x.r->>'is_snapshot')::int = 1,
         nullif(x.r->>'key_algorithm', ''), nullif(x.r->>'encryptor_type', ''), nullif(x.r->>'compression_algorithm', ''), (x.r->>'last_valid_restore_utc')::timestamptz,
         (x.r->>'family_count')::int, (x.r->>'mirror_count')::int, x.r->>'software_name', (x.r->>'software_vendor_id')::int,
         (x.r->>'media_compressed')::int = 1, (x.r->>'media_encrypted')::int = 1, (x.r->>'media_password')::int = 1,
         f1.device_kind,
         CASE WHEN f1.device_kind IN ('url', 'virtual device', 'tape') OR pgvigil.mssql_backup_dir(f1.path) IS NULL
              THEN pgvigil.mssql_backup_root(f1.path, f1.device_kind, x.r->>'software_name')
              ELSE pgvigil.mssql_backup_dir(f1.path) END,
         (SELECT array_agg(DISTINCT pgvigil.mssql_backup_root(f->>'path', f->>'device_kind', x.r->>'software_name') ORDER BY pgvigil.mssql_backup_root(f->>'path', f->>'device_kind', x.r->>'software_name'))
            FROM jsonb_array_elements(v_rows) f WHERE f->>'kind' = 'file' AND (f->>'backup_set_id')::bigint = x.backup_set_id AND f->>'path' IS NOT NULL),
         lower(x.r->>'database_guid'), lower(x.r->>'family_guid'), lower(x.r->>'first_recovery_fork_guid'), lower(x.r->>'last_recovery_fork_guid'),
         (x.r->>'fork_point_lsn')::numeric, (x.r->>'first_lsn')::numeric, (x.r->>'last_lsn')::numeric, (x.r->>'checkpoint_lsn')::numeric,
         (x.r->>'database_backup_lsn')::numeric, (x.r->>'differential_base_lsn')::numeric, lower(x.r->>'differential_base_guid'),
         (x.r->>'begins_log_chain')::int = 1
    FROM pgv_bf_set x
    LEFT JOIN LATERAL (SELECT f->>'device_kind' AS device_kind, f->>'path' AS path FROM jsonb_array_elements(v_rows) f
                        WHERE f->>'kind' = 'file' AND (f->>'backup_set_id')::bigint = x.backup_set_id
                        ORDER BY (f->>'mirror')::int, (f->>'family')::int LIMIT 1) f1 ON true
  ON CONFLICT (instance_id, database_name, backup_type, is_copy_only) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, db_created_at = EXCLUDED.db_created_at, backup_set_id = EXCLUDED.backup_set_id,
      backup_set_uuid = EXCLUDED.backup_set_uuid, media_set_id = EXCLUDED.media_set_id, start_at = EXCLUDED.start_at,
      finish_at = EXCLUDED.finish_at, duration_s = EXCLUDED.duration_s, size_bytes = EXCLUDED.size_bytes,
      compressed_bytes = EXCLUDED.compressed_bytes, recovery_model = EXCLUDED.recovery_model, user_name = EXCLUDED.user_name,
      machine_name = EXCLUDED.machine_name, set_name = EXCLUDED.set_name, description = EXCLUDED.description,
      has_checksums = EXCLUDED.has_checksums, is_damaged = EXCLUDED.is_damaged, is_password_protected = EXCLUDED.is_password_protected,
      has_bulk_logged_data = EXCLUDED.has_bulk_logged_data, is_readonly = EXCLUDED.is_readonly, is_single_user = EXCLUDED.is_single_user,
      is_force_offline = EXCLUDED.is_force_offline, has_incomplete_metadata = EXCLUDED.has_incomplete_metadata,
      is_snapshot = EXCLUDED.is_snapshot, key_algorithm = EXCLUDED.key_algorithm, encryptor_type = EXCLUDED.encryptor_type,
      compression_algorithm = EXCLUDED.compression_algorithm, last_valid_restore_at = EXCLUDED.last_valid_restore_at,
      family_count = EXCLUDED.family_count, mirror_count = EXCLUDED.mirror_count, software_name = EXCLUDED.software_name,
      software_vendor_id = EXCLUDED.software_vendor_id, media_compressed = EXCLUDED.media_compressed,
      media_encrypted = EXCLUDED.media_encrypted, media_password = EXCLUDED.media_password, device_kind = EXCLUDED.device_kind,
      folder = EXCLUDED.folder, roots = EXCLUDED.roots, database_guid = EXCLUDED.database_guid, family_guid = EXCLUDED.family_guid,
      first_recovery_fork_guid = EXCLUDED.first_recovery_fork_guid, last_recovery_fork_guid = EXCLUDED.last_recovery_fork_guid,
      fork_point_lsn = EXCLUDED.fork_point_lsn, first_lsn = EXCLUDED.first_lsn, last_lsn = EXCLUDED.last_lsn,
      checkpoint_lsn = EXCLUDED.checkpoint_lsn, database_backup_lsn = EXCLUDED.database_backup_lsn,
      differential_base_lsn = EXCLUDED.differential_base_lsn, differential_base_guid = EXCLUDED.differential_base_guid,
      begins_log_chain = EXCLUDED.begins_log_chain
    -- the newer set of the key wins (the same set read again refreshes it); an older one never replaces it
    WHERE EXCLUDED.finish_at > s.finish_at OR (EXCLUDED.finish_at = s.finish_at AND EXCLUDED.backup_set_id >= s.backup_set_id);

  -- the files of the sets this read stored: what an earlier set of the key left goes
  DELETE FROM pgvigil.mssql_backup_files f USING pgvigil.mssql_backup_sets s
   WHERE s.instance_id = p_instance_id AND f.instance_id = s.instance_id AND f.database_name = s.database_name
     AND f.backup_type = s.backup_type AND f.is_copy_only = s.is_copy_only AND f.backup_set_id <> s.backup_set_id;
  DELETE FROM pgvigil.mssql_backup_dbfiles f USING pgvigil.mssql_backup_sets s
   WHERE s.instance_id = p_instance_id AND f.instance_id = s.instance_id AND f.database_name = s.database_name
     AND f.backup_type = s.backup_type AND f.is_copy_only = s.is_copy_only AND f.backup_set_id <> s.backup_set_id;
  INSERT INTO pgvigil.mssql_backup_files AS t (instance_id, database_name, backup_type, is_copy_only, backup_set_id, family, mirror,
      device_kind, logical_name, path, root)
  SELECT s.instance_id, s.database_name, s.backup_type, s.is_copy_only, s.backup_set_id, (f->>'family')::int, (f->>'mirror')::int,
         f->>'device_kind', f->>'logical_name', f->>'path', pgvigil.mssql_backup_root(f->>'path', f->>'device_kind', s.software_name)
    FROM pgv_bf_set x
    JOIN pgvigil.mssql_backup_sets s ON s.instance_id = p_instance_id AND s.database_name = x.database_name
         AND s.backup_type = x.backup_type AND s.is_copy_only = x.is_copy_only AND s.backup_set_id = x.backup_set_id
    JOIN jsonb_array_elements(v_rows) f ON f->>'kind' = 'file' AND (f->>'backup_set_id')::bigint = x.backup_set_id AND f->>'path' IS NOT NULL
  ON CONFLICT (instance_id, database_name, backup_type, is_copy_only, family, mirror) DO UPDATE SET
      backup_set_id = EXCLUDED.backup_set_id, device_kind = EXCLUDED.device_kind, logical_name = EXCLUDED.logical_name,
      path = EXCLUDED.path, root = EXCLUDED.root;
  INSERT INTO pgvigil.mssql_backup_dbfiles AS t (instance_id, database_name, backup_type, is_copy_only, backup_set_id, file_number,
      file_type, logical_name, physical_name)
  SELECT s.instance_id, s.database_name, s.backup_type, s.is_copy_only, s.backup_set_id, (f->>'file_number')::int,
         f->>'file_type', f->>'logical_name', f->>'physical_name'
    FROM pgv_bf_set x
    JOIN pgvigil.mssql_backup_sets s ON s.instance_id = p_instance_id AND s.database_name = x.database_name
         AND s.backup_type = x.backup_type AND s.is_copy_only = x.is_copy_only AND s.backup_set_id = x.backup_set_id
    JOIN jsonb_array_elements(v_rows) f ON f->>'kind' = 'dbfile' AND (f->>'backup_set_id')::bigint = x.backup_set_id
  ON CONFLICT (instance_id, database_name, backup_type, is_copy_only, file_number) DO UPDATE SET
      backup_set_id = EXCLUDED.backup_set_id, file_type = EXCLUDED.file_type, logical_name = EXCLUDED.logical_name,
      physical_name = EXCLUDED.physical_name;

  -- the roots seen: a set that is not copy-only (a copy taken elsewhere is no destination change), by its finish
  INSERT INTO pgvigil.mssql_backup_roots_seen AS t (instance_id, database_name, backup_type, root, first_seen, last_seen, first_set_id)
  SELECT s.instance_id, s.database_name, s.backup_type, r.root, s.finish_at, s.finish_at, s.backup_set_id
    FROM pgv_bf_set x
    JOIN pgvigil.mssql_backup_sets s ON s.instance_id = p_instance_id AND s.database_name = x.database_name
         AND s.backup_type = x.backup_type AND s.is_copy_only = x.is_copy_only AND s.backup_set_id = x.backup_set_id
    CROSS JOIN LATERAL unnest(s.roots) r(root)
   WHERE NOT s.is_copy_only AND r.root IS NOT NULL AND r.root <> 'NUL'
  ON CONFLICT (instance_id, database_name, backup_type, root) DO UPDATE SET
      first_seen = least(t.first_seen, EXCLUDED.first_seen), last_seen = greatest(t.last_seen, EXCLUDED.last_seen),
      first_set_id = CASE WHEN (EXCLUDED.first_seen, EXCLUDED.first_set_id) < (t.first_seen, coalesce(t.first_set_id, 9223372036854775807))
                          THEN EXCLUDED.first_set_id ELSE t.first_set_id END;

  -- the writers of the last 7 days: replaced whole when the read took the window
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'writers_read') THEN
    DELETE FROM pgvigil.mssql_backup_writers WHERE instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_backup_writers (instance_id, database_name, device_kind, root, users, sets, first_at, last_at, snapshot_at)
    SELECT p_instance_id, w.database_name, w.device_kind, w.root,
           array_agg(DISTINCT w.user_name ORDER BY w.user_name) FILTER (WHERE w.user_name IS NOT NULL),
           sum(w.sets)::int, min(w.first_at), max(w.last_at), p_snapshot_at
      FROM (SELECT r->>'database_name' AS database_name, coalesce(r->>'device_kind', '?') AS device_kind,
                   coalesce(pgvigil.mssql_backup_root(coalesce(r->>'directory', r->>'path'), r->>'device_kind', r->>'software_name'), '?') AS root,
                   r->>'user_name' AS user_name, (r->>'sets')::int AS sets,
                   (r->>'first_utc')::timestamptz AS first_at, (r->>'last_utc')::timestamptz AS last_at
              FROM jsonb_array_elements(v_rows) r
             WHERE r->>'kind' = 'writer' AND EXISTS (SELECT 1 FROM pgv_bf_db d WHERE d.database_name = r->>'database_name')) w
     GROUP BY w.database_name, w.device_kind, w.root;
  END IF;

  INSERT INTO pgvigil.mssql_backup_files_cursor AS c (instance_id, last_set_id, mark, updated_at)
  SELECT p_instance_id, (r->>'last_set_id')::bigint, (r->>'mark')::bigint, p_snapshot_at
    FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'cursor' AND r->>'last_set_id' IS NOT NULL
   LIMIT 1
  ON CONFLICT (instance_id) DO UPDATE SET last_set_id = EXCLUDED.last_set_id, mark = EXCLUDED.mark, updated_at = EXCLUDED.updated_at;
END $$;

-- mssql_backup_locations: per database of mssql_backup_judged (its instance, judged or not and why, whether a replica is
-- unseen) the sets of each type, merged over the availability group's monitored replicas as the judged view merges the
-- times: 'shown' = the newest set of the type wherever it ran (a copy-only full among them, as DBA Dash's Consider Copy
-- Only Backups); 'judged' = the newest set of the type that is not copy-only (destinations and the volume are judged on
-- it). One row per set; a set can be both. from_instance = where it ran. same_volume: mssql_backup_same_volume's words.
-- diff_base (a differential): whether the full shown is its base.
CREATE OR REPLACE VIEW pgvigil.mssql_backup_locations AS
WITH j AS (
  SELECT b.instance_id, b.instance, b.database_name, b.ag_group_id, b.ag_name, b.not_judged, b.replicas_unseen
    FROM pgvigil.mssql_backup_judged b
), c AS (
  SELECT j.instance_id AS for_instance_id, s.*, si.name AS from_instance,
         row_number() OVER (PARTITION BY j.instance_id, j.database_name, s.backup_type
                            ORDER BY s.finish_at DESC, (s.instance_id = j.instance_id) DESC, s.backup_set_id DESC) AS rn_any,
         row_number() OVER (PARTITION BY j.instance_id, j.database_name, s.backup_type, s.is_copy_only
                            ORDER BY s.finish_at DESC, (s.instance_id = j.instance_id) DESC, s.backup_set_id DESC) AS rn_kind
    FROM j
    JOIN pgvigil.mssql_backup_sets s ON s.database_name = j.database_name
         AND (s.instance_id = j.instance_id
              OR (j.ag_group_id IS NOT NULL AND EXISTS (SELECT 1 FROM pgvigil.mssql_backup_state x
                                                         WHERE x.instance_id = s.instance_id AND x.ag_group_id = j.ag_group_id
                                                           AND x.database_name = j.database_name AND x.is_present)))
    JOIN pgvigil.instances si ON si.instance_id = s.instance_id AND si.is_active
), k AS (
  SELECT c.*, c.rn_any = 1 AS shown, (NOT c.is_copy_only AND c.rn_kind = 1) AS judged
    FROM c WHERE c.rn_any = 1 OR (NOT c.is_copy_only AND c.rn_kind = 1)
)
SELECT j.instance_id, j.instance, j.database_name, j.ag_name, j.not_judged, j.replicas_unseen,
       k.backup_type, k.is_copy_only, k.shown, k.judged, k.instance_id AS from_instance_id, k.from_instance,
       k.backup_set_id, k.backup_set_uuid, k.start_at, k.finish_at, k.duration_s, k.size_bytes, k.compressed_bytes, k.recovery_model,
       k.user_name, k.machine_name, k.set_name, k.description, k.has_checksums, k.is_damaged, k.is_password_protected,
       k.has_bulk_logged_data, k.is_readonly, k.is_single_user, k.is_force_offline, k.has_incomplete_metadata, k.is_snapshot,
       k.key_algorithm, k.encryptor_type, k.compression_algorithm, k.last_valid_restore_at, k.family_count, k.mirror_count,
       k.software_name, k.software_vendor_id, k.media_compressed, k.media_encrypted, k.media_password, k.device_kind, k.folder,
       k.roots, k.differential_base_guid, k.database_backup_lsn, k.checkpoint_lsn,
       (k.compressed_bytes IS NOT NULL AND k.size_bytes IS NOT NULL AND k.compressed_bytes < k.size_bytes) AS is_compressed,
       (k.key_algorithm IS NOT NULL AND k.key_algorithm <> 'NO_Encryption') AS is_encrypted,
       CASE WHEN k.judged THEN pgvigil.mssql_backup_same_volume(k.instance_id, k.database_name, k.backup_type, k.is_copy_only) END AS same_volume,
       CASE WHEN k.backup_type = 'diff' THEN
         (SELECT CASE WHEN f.backup_set_uuid IS NOT NULL AND (k.differential_base_guid = f.backup_set_uuid OR k.database_backup_lsn = f.checkpoint_lsn)
                        THEN CASE WHEN f.shown THEN 'this full' ELSE 'the last full that is not copy-only' END
                      ELSE NULL END
            FROM k f WHERE f.for_instance_id = k.for_instance_id AND f.database_name = k.database_name AND f.backup_type = 'full'
             AND (k.differential_base_guid = f.backup_set_uuid OR k.database_backup_lsn = f.checkpoint_lsn)
           ORDER BY f.shown DESC LIMIT 1)
       END AS diff_base
  FROM j
  JOIN k ON k.for_instance_id = j.instance_id AND k.database_name = j.database_name;

-- mssql_backup_loc_findings (the findings columns): on a judged database only (not_judged NULL: excluded, new, offline,
-- a snapshot, tempdb are never judged) -
--   'a full / differential / log backup on the volume of the database's own files' (warning): the newest set of the type
--     that is not copy-only, by mssql_backup_same_volume ('yes');
--   'log backups to two destinations' (warning): the log backups of the last 7 days (not copy-only) of one server went to
--     two or more destination roots or device kinds; two logins writing to one root is a note in the panel, no finding;
--     each replica's msdb is its own (a split between two replicas is not seen);
--   'a backup destination not seen before' (info, 7 days): a set that is not copy-only went to a root the database's
--     backups of that type were not seen at before (a flip back to a known root writes nothing).
CREATE OR REPLACE VIEW pgvigil.mssql_backup_loc_findings AS
SELECT l.instance_id, 'warning'::text AS severity,
       'a ' || CASE l.backup_type WHEN 'full' THEN 'full' WHEN 'diff' THEN 'differential' ELSE 'log' END
         || ' backup on the volume of the database''s own files' AS check_name,
       l.database_name AS object,
       substr(l.same_volume, 6) || ' (taken ' || to_char(l.finish_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC on ' || l.from_instance
         || '): a lost volume takes the database and its backup together' AS detail,
       l.finish_at AS at
  FROM pgvigil.mssql_backup_locations l
 WHERE l.judged AND l.not_judged IS NULL AND l.same_volume LIKE 'yes:%'
UNION ALL
SELECT w.instance_id, 'warning', 'log backups to two destinations', w.database_name,
       string_agg(w.root || ' (' || w.device_kind || '): ' || w.sets || ' log backup' || CASE WHEN w.sets = 1 THEN '' ELSE 's' END
                  || ', the last ' || to_char(w.last_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'
                  || coalesce(', by ' || array_to_string(w.users, ', '), ''), '; ' ORDER BY w.last_at DESC)
         || ' - in the last 7 days; a restore needs every log backup of the chain, from each place',
       max(w.last_at)
  FROM pgvigil.mssql_backup_writers w
  JOIN pgvigil.mssql_backup_judged b ON b.instance_id = w.instance_id AND b.database_name = w.database_name AND b.not_judged IS NULL
 GROUP BY w.instance_id, w.database_name
HAVING count(*) >= 2
UNION ALL
SELECT r.instance_id, 'info', 'a backup destination not seen before', r.database_name,
       CASE r.backup_type WHEN 'full' THEN 'full' WHEN 'diff' THEN 'differential' ELSE 'log' END || ' backups now go to ' || r.root
         || ' (first seen ' || to_char(r.first_seen AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC); before: '
         || (SELECT string_agg(o.root, ', ' ORDER BY o.last_seen DESC) FROM pgvigil.mssql_backup_roots_seen o
              WHERE o.instance_id = r.instance_id AND o.database_name = r.database_name AND o.backup_type = r.backup_type
                AND (o.first_seen, coalesce(o.first_set_id, 0)) < (r.first_seen, coalesce(r.first_set_id, 0))),
       r.first_seen
  FROM pgvigil.mssql_backup_roots_seen r
  JOIN pgvigil.mssql_backup_judged b ON b.instance_id = r.instance_id AND b.database_name = r.database_name AND b.not_judged IS NULL
 WHERE r.first_seen > now() - interval '7 days'
   AND EXISTS (SELECT 1 FROM pgvigil.mssql_backup_roots_seen o
                WHERE o.instance_id = r.instance_id AND o.database_name = r.database_name AND o.backup_type = r.backup_type
                  AND (o.first_seen, coalesce(o.first_set_id, 0)) < (r.first_seen, coalesce(r.first_set_id, 0)));

-- mssql_backup_loc_db: per instance and database the fleet's and the tab's added cells (the lead's join into
-- sqlMSSQLBackups): '<type>_to' = the folder (a URL's container) of the newest set of the type, ', n files' when
-- striped, ', mirrored' when mirrored; and DBA Dash's Detail flags of that set (Is Full Damaged .. Log Compression
-- Algorithm).
CREATE OR REPLACE VIEW pgvigil.mssql_backup_loc_db AS
SELECT l.instance_id, l.database_name,
       max(CASE WHEN l.backup_type = 'full' THEN l.folder || CASE WHEN l.family_count > 1 THEN ', ' || l.family_count || ' files' ELSE '' END
                                                 || CASE WHEN l.mirror_count > 1 THEN ', mirrored' ELSE '' END END) AS full_to,
       max(CASE WHEN l.backup_type = 'diff' THEN l.folder || CASE WHEN l.family_count > 1 THEN ', ' || l.family_count || ' files' ELSE '' END
                                                 || CASE WHEN l.mirror_count > 1 THEN ', mirrored' ELSE '' END END) AS diff_to,
       max(CASE WHEN l.backup_type = 'log' THEN l.folder || CASE WHEN l.family_count > 1 THEN ', ' || l.family_count || ' files' ELSE '' END
                                                || CASE WHEN l.mirror_count > 1 THEN ', mirrored' ELSE '' END END) AS log_to,
       bool_or(l.is_damaged) FILTER (WHERE l.backup_type = 'full') AS full_damaged,
       bool_or(l.is_damaged) FILTER (WHERE l.backup_type = 'diff') AS diff_damaged,
       bool_or(l.is_damaged) FILTER (WHERE l.backup_type = 'log') AS log_damaged,
       bool_or(l.has_checksums) FILTER (WHERE l.backup_type = 'full') AS full_checksum,
       bool_or(l.has_checksums) FILTER (WHERE l.backup_type = 'diff') AS diff_checksum,
       bool_or(l.has_checksums) FILTER (WHERE l.backup_type = 'log') AS log_checksum,
       bool_or(l.is_compressed) FILTER (WHERE l.backup_type = 'full') AS full_compressed,
       bool_or(l.is_compressed) FILTER (WHERE l.backup_type = 'diff') AS diff_compressed,
       bool_or(l.is_compressed) FILTER (WHERE l.backup_type = 'log') AS log_compressed,
       bool_or(l.is_password_protected) FILTER (WHERE l.backup_type = 'full') AS full_password,
       bool_or(l.is_password_protected) FILTER (WHERE l.backup_type = 'diff') AS diff_password,
       bool_or(l.is_password_protected) FILTER (WHERE l.backup_type = 'log') AS log_password,
       bool_or(l.is_encrypted) FILTER (WHERE l.backup_type = 'full') AS full_encrypted,
       bool_or(l.is_encrypted) FILTER (WHERE l.backup_type = 'diff') AS diff_encrypted,
       bool_or(l.is_encrypted) FILTER (WHERE l.backup_type = 'log') AS log_encrypted,
       max(l.compression_algorithm) FILTER (WHERE l.backup_type = 'full') AS full_algorithm,
       max(l.compression_algorithm) FILTER (WHERE l.backup_type = 'diff') AS diff_algorithm,
       max(l.compression_algorithm) FILTER (WHERE l.backup_type = 'log') AS log_algorithm
  FROM pgvigil.mssql_backup_locations l
 WHERE l.shown
 GROUP BY l.instance_id, l.database_name;

-- mssql_backup_loc_inst: per instance DBA Dash's Summary texts over the databases judged that have a set of the type:
-- '<n>/<m>' with checksums, compressed, password protected, encrypted; and the compression algorithms as 'NAME(count)'.
CREATE OR REPLACE VIEW pgvigil.mssql_backup_loc_inst AS
WITH t AS (
  SELECT l.instance_id, l.backup_type, count(*) AS m,
         count(*) FILTER (WHERE l.has_checksums) AS checksums, count(*) FILTER (WHERE l.is_compressed) AS compressed,
         count(*) FILTER (WHERE l.is_password_protected) AS password, count(*) FILTER (WHERE l.is_encrypted) AS encrypted
    FROM pgvigil.mssql_backup_locations l
   WHERE l.shown AND l.not_judged IS NULL
   GROUP BY l.instance_id, l.backup_type
), a AS (
  SELECT x.instance_id, x.backup_type, string_agg(x.alg || '(' || x.n || ')', ', ' ORDER BY x.n DESC, x.alg) AS algorithms
    FROM (SELECT l.instance_id, l.backup_type, l.compression_algorithm AS alg, count(*) AS n
            FROM pgvigil.mssql_backup_locations l
           WHERE l.shown AND l.not_judged IS NULL AND l.compression_algorithm IS NOT NULL
           GROUP BY 1, 2, 3) x
   GROUP BY x.instance_id, x.backup_type
)
SELECT i.instance_id,
       max(CASE WHEN t.backup_type = 'full' THEN t.checksums || '/' || t.m END) AS full_checksums,
       max(CASE WHEN t.backup_type = 'diff' THEN t.checksums || '/' || t.m END) AS diff_checksums,
       max(CASE WHEN t.backup_type = 'log' THEN t.checksums || '/' || t.m END) AS log_checksums,
       max(CASE WHEN t.backup_type = 'full' THEN t.compressed || '/' || t.m END) AS full_compressed,
       max(CASE WHEN t.backup_type = 'diff' THEN t.compressed || '/' || t.m END) AS diff_compressed,
       max(CASE WHEN t.backup_type = 'log' THEN t.compressed || '/' || t.m END) AS log_compressed,
       max(CASE WHEN t.backup_type = 'full' THEN t.password || '/' || t.m END) AS full_password,
       max(CASE WHEN t.backup_type = 'diff' THEN t.password || '/' || t.m END) AS diff_password,
       max(CASE WHEN t.backup_type = 'log' THEN t.password || '/' || t.m END) AS log_password,
       max(CASE WHEN t.backup_type = 'full' THEN t.encrypted || '/' || t.m END) AS full_encrypted,
       max(CASE WHEN t.backup_type = 'diff' THEN t.encrypted || '/' || t.m END) AS diff_encrypted,
       max(CASE WHEN t.backup_type = 'log' THEN t.encrypted || '/' || t.m END) AS log_encrypted,
       (SELECT a.algorithms FROM a WHERE a.instance_id = i.instance_id AND a.backup_type = 'full') AS full_algorithms,
       (SELECT a.algorithms FROM a WHERE a.instance_id = i.instance_id AND a.backup_type = 'diff') AS diff_algorithms,
       (SELECT a.algorithms FROM a WHERE a.instance_id = i.instance_id AND a.backup_type = 'log') AS log_algorithms
  FROM pgvigil.instances i
  JOIN t ON t.instance_id = i.instance_id
 GROUP BY i.instance_id;
