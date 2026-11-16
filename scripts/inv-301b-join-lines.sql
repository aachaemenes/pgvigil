-- inv-301b-join-lines.sql - task 301b's lines for the joined objects (the lead's JOIN-FILE RULE, 2026-11-15 03:3x): its
-- migration 0191 is above 0190, so it creates only its own objects; the next join (0300_join_release3.sql) re-creates
-- each object below WHOLE with these lines in it. Not a migration: `pgvigil migrate` never applies it (scripts/ is not
-- embedded).

-- 1. pgvigil.mssql_hadr_cursor (0140's on this branch; 0145's azdb_since arm beside it at the join): one more arm, the
--    collection mssql_backup_history's two cursors over 0191's mssql_backup_history_cursor (the whole function as the
--    joined tree holds it for this branch: scripts/inv-301b-joined-cursor.sql, which the branch's store test and proof
--    apply):
--    WHEN p_source IN ('backup_history', 'backup_history_mark', 'restore_history', 'restore_history_mark') THEN
--      (SELECT CASE p_source WHEN 'backup_history' THEN c.last_set_id WHEN 'backup_history_mark' THEN c.set_mark
--                            WHEN 'restore_history' THEN c.last_restore_id ELSE c.restore_mark END
--         FROM pgvigil.mssql_backup_history_cursor c WHERE c.instance_id = p_instance_id)

-- 2. pgvigil.findings (0190's union): one more arm, in the shape of the other mssql_* arms -
--    the newest backup's file missing, pseudo-simple recovery, the default backup path not reachable (warning each)
--    UNION ALL
--    -- task 301b (0191): a backup file not where msdb says, pseudo-simple, the default backup path not reachable
--    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_backup_check', at FROM pgvigil.mssql_backup_check_findings

-- 3. actions_log's three CHECKs (the lead's 03:3x: BOTH - 0191 widens them for this branch, 0300 re-creates each ONCE with
--    every slice's list). 301b's part:
--      actions_log_action_check  engine = 'sqlserver': 'verify_backup'
--      actions_log_pid_check     'verify_backup' among the actions with no pid
--      actions_log_outcome_check 'started', 'cut by shutdown', 'ended unknown' beside 0028's 'done', 'refused', 'failed'
--    (0191 copied 0157's lists whole: postgres cancel, terminate, explain_analyze, hypo_index, job_stop, job_start;
--    sqlserver kill, job_start, job_stop, plan_evict; no pid explain_analyze, hypo_index, job_start, job_stop, plan_evict.)

-- 4. purge(): no line. 0191's tables are current state (the newest 10 sets and 20 restores per key, pruned by each
--    import; one check row per database, type or instance, replaced by each read) and go with their instance (ON DELETE
--    CASCADE).
