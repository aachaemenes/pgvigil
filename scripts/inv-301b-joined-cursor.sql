-- inv-301b-joined-cursor.sql - pgvigil.mssql_hadr_cursor as the joined tree will hold it for task 301b: 0140's function
-- whole plus one arm for the collection mssql_backup_history's two cursors (0191's mssql_backup_history_cursor):
--   'backup_history', 'backup_history_mark'    the newest backup_set_id read and CHECKSUM(backup_set_uuid) of that row
--   'restore_history', 'restore_history_mark'  the newest restore_history_id read and its row's mark
-- Not a migration (the JOIN-FILE RULE: 0191 never replaces a joined function). Applied ONLY by this branch's store test
-- (internal/repo TestBackupHistoryOnAStore) and its proof (scripts/proof-mssql-backup-history.sh), so the cursor rows are
-- proven before the join; the join (0300) takes the arm into the function it re-creates with every branch's arms
-- (scripts/inv-301b-join-lines.sql). internal/repo TestJoinedCursor301bIs0140PlusArm holds it equal to 0140's plus the arm.
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
    WHEN p_source IN ('backup_history', 'backup_history_mark', 'restore_history', 'restore_history_mark') THEN
      (SELECT CASE p_source WHEN 'backup_history' THEN c.last_set_id WHEN 'backup_history_mark' THEN c.set_mark
                            WHEN 'restore_history' THEN c.last_restore_id ELSE c.restore_mark END
         FROM pgvigil.mssql_backup_history_cursor c WHERE c.instance_id = p_instance_id)
  END
$$;
