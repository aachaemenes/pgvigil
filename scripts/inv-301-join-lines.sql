-- Task 301 (migration 0140): the lines for the lead's NEXT join migration - never an edit of 0190 (the migrator skips a
-- recorded file, so an edit of 0190 never reaches a repository that has it). Not a migration of its own: two pieces to
-- place, each where its comment says.

-- (1) pgvigil.findings: one more UNION ALL arm, after the mssql_cpu arm, in the shape of the other mssql_* arms:
    UNION ALL
    -- task 301 (0140): a backup on the database's own volume, log backups to two destinations, a destination not seen before
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_backup_loc', at FROM pgvigil.mssql_backup_loc_findings

-- (2) purge(): the destinations seen are kept 400 days at least (the info finding 'a backup destination not seen before'
-- needs the earlier destinations; a database's history of roots is small: one row per database, type and root):
  DELETE FROM pgvigil.mssql_backup_roots_seen WHERE last_seen < now() - make_interval(days => greatest(p_days, 400));
-- The other 0140 tables need no line: mssql_backup_sets, _files, _dbfiles, _writers and _files_cursor are current state
-- (one row per key, replaced by each read) and go with their instance (ON DELETE CASCADE).
