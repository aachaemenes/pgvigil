-- 0392: each SQL Server database snapshot (P25 row 2b, DBA Dash's database Snapshot Summary tab). The hourly read
-- mssql_confcheck lists the instance's database snapshots (sys.databases with a source_database_id): one 'db_snapshot'
-- row each - its name, its source database, its create date (UTC), its sparse files' size on disk
-- (sys.dm_io_virtual_file_stats' size_on_disk_bytes: the bytes the snapshot uses on disk; VIEW SERVER STATE, VIEW
-- SERVER PERFORMANCE STATE from SQL Server 2022 - without it NULL and the note) and their count - or one
-- 'snapshots_unread' row with why it could not list them:
--   mssql_db_snapshot   per instance and snapshot name: as last read; a snapshot the next listing does not hold is
--                       not present (dropped); a read that listed none leaves them as they were
--
-- THE JOIN-FILE RULE: 0392 sorts after the join file and creates only its own objects. Its lines for the join are in
-- scripts/PARITY-S3-join-lines.sql: import_mssql_confcheck calls pgvigil.import_mssql_db_snapshots with the same
-- payload; the table under the instance scope's policy (the join's scope tests name it).

CREATE TABLE IF NOT EXISTS pgvigil.mssql_db_snapshot (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_name       text NOT NULL,
  source_database     text,
  created_at          timestamptz,
  size_on_disk_bytes  bigint,
  files               int,
  size_note           text,                     -- why the size was not read
  first_seen          timestamptz NOT NULL,
  snapshot_at         timestamptz NOT NULL,
  is_present          boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, snapshot_name)
);

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_db_snapshots(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  -- a read that could not list the snapshots: nothing changes
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'snapshots_unread') THEN
    RETURN;
  END IF;
  UPDATE pgvigil.mssql_db_snapshot s SET is_present = false, snapshot_at = p_snapshot_at
   WHERE s.instance_id = p_instance_id AND s.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'db_snapshot' AND r->>'snapshot_name' = s.snapshot_name);
  INSERT INTO pgvigil.mssql_db_snapshot AS s (instance_id, snapshot_name, source_database, created_at, size_on_disk_bytes, files,
                                              size_note, first_seen, snapshot_at, is_present)
  SELECT p_instance_id, r->>'snapshot_name', r->>'source_database', (r->>'created_utc')::timestamp AT TIME ZONE 'UTC',
         (r->>'size_on_disk_bytes')::bigint, (r->>'files')::int, r->>'size_note', p_snapshot_at, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'db_snapshot' AND r->>'snapshot_name' IS NOT NULL
  ON CONFLICT (instance_id, snapshot_name) DO UPDATE
     SET source_database = EXCLUDED.source_database, created_at = EXCLUDED.created_at, size_on_disk_bytes = EXCLUDED.size_on_disk_bytes,
         files = EXCLUDED.files, size_note = EXCLUDED.size_note, snapshot_at = EXCLUDED.snapshot_at, is_present = true;
END $$;
