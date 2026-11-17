-- 0391: each SQL Server database's scoped configuration (P25 row 2a, DBA Dash's database DB Configuration tab).
-- The hourly read mssql_confcheck already enters every database the login may and read its scoped MAXDOP there
-- (internal/mssql/dboptions.go); it sends every row of sys.database_scoped_configurations as well, one
-- 'scoped_config' row per database and name (its value and value for secondaries as text: the view's sql_variant),
-- and a 'scoped_unread' row for a database it did not read, with why:
--   mssql_db_scoped_config         per instance, database and name: the value as last read, its value for
--                                  secondaries, whether it is the default, and why the database's last read did not
--                                  read it (its rows kept as they were); a row the view no longer holds is not present
--   mssql_db_scoped_config_change  each change a read saw: the old and the new value (NULL: the row left the view)
-- A database's first read is its baseline: no change row.
--
-- THE JOIN-FILE RULE: 0391 sorts after the join file and creates only its own objects. Its lines for the join are in
-- scripts/PARITY-S3-join-lines.sql: import_mssql_confcheck calls pgvigil.import_mssql_db_scoped_config with the same
-- payload; both tables under the instance scope's policy (the join's scope tests name them); purge's lines.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_db_scoped_config (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name        text NOT NULL,
  name                 text NOT NULL,
  value                text,
  value_for_secondary  text,
  is_default           boolean,
  note                 text,                    -- why the database's last read did not read it
  first_seen           timestamptz NOT NULL,
  snapshot_at          timestamptz NOT NULL,
  is_present           boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, database_name, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_db_scoped_config_change (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  name           text NOT NULL,
  changed_at     timestamptz NOT NULL,
  old_value      text,
  new_value      text,                          -- NULL: the row left the view
  PRIMARY KEY (instance_id, database_name, name, changed_at)
);
CREATE INDEX IF NOT EXISTS mssql_db_scoped_config_change_at_idx ON pgvigil.mssql_db_scoped_config_change (instance_id, changed_at);

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_db_scoped_config(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  -- the changed values of the databases this read read, then the rows those databases no longer hold
  INSERT INTO pgvigil.mssql_db_scoped_config_change (instance_id, database_name, name, changed_at, old_value, new_value)
  SELECT p_instance_id, c.database_name, c.name, p_snapshot_at, c.value, r->>'value'
    FROM jsonb_array_elements(p_payload) r
    JOIN pgvigil.mssql_db_scoped_config c
      ON c.instance_id = p_instance_id AND c.database_name = r->>'database_name' AND c.name = r->>'name'
   WHERE r->>'kind' = 'scoped_config' AND c.is_present AND c.value IS DISTINCT FROM r->>'value'
  ON CONFLICT DO NOTHING;
  INSERT INTO pgvigil.mssql_db_scoped_config_change (instance_id, database_name, name, changed_at, old_value, new_value)
  SELECT p_instance_id, c.database_name, c.name, p_snapshot_at, c.value, NULL
    FROM pgvigil.mssql_db_scoped_config c
   WHERE c.instance_id = p_instance_id AND c.is_present
     AND c.database_name IN (SELECT r->>'database_name' FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'scoped_config')
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'scoped_config' AND r->>'database_name' = c.database_name AND r->>'name' = c.name)
  ON CONFLICT DO NOTHING;
  UPDATE pgvigil.mssql_db_scoped_config c SET is_present = false, snapshot_at = p_snapshot_at
   WHERE c.instance_id = p_instance_id AND c.is_present
     AND c.database_name IN (SELECT r->>'database_name' FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'scoped_config')
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'scoped_config' AND r->>'database_name' = c.database_name AND r->>'name' = c.name);
  INSERT INTO pgvigil.mssql_db_scoped_config AS c (instance_id, database_name, name, value, value_for_secondary, is_default, note,
                                                   first_seen, snapshot_at, is_present)
  SELECT p_instance_id, r->>'database_name', r->>'name', r->>'value', r->>'value_for_secondary', (r->>'is_value_default')::boolean,
         NULL, p_snapshot_at, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'scoped_config' AND r->>'database_name' IS NOT NULL AND r->>'name' IS NOT NULL
  ON CONFLICT (instance_id, database_name, name) DO UPDATE
     SET value = EXCLUDED.value, value_for_secondary = EXCLUDED.value_for_secondary, is_default = EXCLUDED.is_default,
         note = NULL, snapshot_at = EXCLUDED.snapshot_at, is_present = true;
  -- a database this read did not enter: its rows stay as they were, the note says why
  UPDATE pgvigil.mssql_db_scoped_config c SET note = r->>'note'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'scoped_unread' AND c.instance_id = p_instance_id AND c.database_name = r->>'database_name';
END $$;
