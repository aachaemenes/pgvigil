-- Task 302 (migration 0148): the lines for the lead's NEXT join migration - never an edit of 0190 (the migrator skips a
-- recorded file, so an edit of 0190 never reaches a repository that has it). Not a migration of its own: each piece goes
-- where its comment says.

-- (1) pgvigil.findings: one more UNION ALL arm, beside the other pg_* arms, in their shape:
    UNION ALL
    -- task 302 (0148): a credential in the archiver's command, WAL discarded (warnings); the tool read off and 162's
    -- base backups not read (info: the Summary's Backup FULL cell maps 'base backups not read' to grey, never green)
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'backup_dest', at FROM pgvigil.pg_backup_dest_findings

-- (2) purge(): NO line. Every 0148 table but one is current state, replaced whole at each read, and goes with its
-- instance (ON DELETE CASCADE); pg_backup_dest_entered is a person's entries with their history (F10: history kept), so
-- its ended rows are kept as 0190 keeps pg_thresholds whole (302's review, finding 21).
