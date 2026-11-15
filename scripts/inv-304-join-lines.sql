-- Task 304 (migration 0147): the lines for the join's migration 0190, placed there (its one piece, each
-- where its comment says): 0190 is extended in place until the release, nothing of it having been released yet.
-- Not a migration of its own; kept as the record of what the join placed.

-- (1) pgvigil.findings: one more UNION ALL arm, after task 301's mssql_backup_loc arm, in the shape of the other mssql_* arms:
    UNION ALL
    -- task 304 (0147): the log chain is broken (never for a gap a replica's late read may fill)
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_restore_chain', at FROM pgvigil.mssql_restore_findings

-- purge(): no line. 0147's tables are current state - mssql_restore_sets are upserted by each read and pruned below its
-- start set by the import, mssql_restore_files go with their set, mssql_restore_verdicts / _steps / _reads are one row
-- (or one chain) per database replaced at each import - and all go with their instance (ON DELETE CASCADE).
