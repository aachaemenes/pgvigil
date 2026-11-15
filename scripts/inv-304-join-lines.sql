-- Task 304 (migration 0147): the line for the lead's NEXT join migration - never an edit of 0190 (the migrator skips a
-- recorded file, so an edit of 0190 never reaches a repository that has it). Not a migration of its own: one piece to
-- place where its comment says.

-- (1) pgvigil.findings: one more UNION ALL arm, after task 301's mssql_backup_loc arm, in the shape of the other mssql_* arms:
    UNION ALL
    -- task 304 (0147): the log chain is broken (never for a gap a replica's late read may fill)
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_restore_chain', at FROM pgvigil.mssql_restore_findings

-- purge(): no line. 0147's tables are current state - mssql_restore_sets are upserted by each read and pruned below its
-- start set by the import, mssql_restore_files go with their set, mssql_restore_verdicts / _steps / _reads are one row
-- (or one chain) per database replaced at each import - and all go with their instance (ON DELETE CASCADE).
