-- 0362 (task 7b, PGRID B04): Save Table's From Data Table / From Grid - a write door that creates a table of a grid's
-- rows on a monitored instance through its actions login (internal/web/savetable.go). This file changes only the store's
-- audit: nothing is created, changed or switched on on a monitored server; the door stays off until doors: save_table
-- is on in pgvigil.yaml AND the instance's actions: list names save_table.
--
--   import_save_table_log      NEW (review-29 S3): one row per save attempt - 'started' before the write, then its end
--                              (done / refused / failed). The engine is read from pgvigil.instances (never the column's
--                              'postgres' default, 0067:395), the target (<db>.pgvigil_saved.<table>) and the database
--                              kept, pid NULL; a row of another action is an error, never dropped. import_actions_log
--                              (0078:211-222) and import_mssql_actions_log (0067:407-422) are NOT touched: a function of
--                              its own moves no other slice's text. Named import_* so apply_roles (run after every
--                              migrate) makes it the collector's SECURITY DEFINER door with search_path pinned.
--   actions_log_action_check   dropped and added again, both engines with save_table.
--   actions_log_pid_check      dropped and added again, save_table among the no-pid actions.
--   actions_log_outcome_check  dropped and added again.
--
-- THE THIRD NAMED CHECK of 7b's DONE (the lead 11-17 01:50 and 02:17) - the j17 join line: the three CHECKs are the
-- UNION of their newest texts, so no action kind is lost at the join:
--   0300_join_release3.sql:2690-2697 (on rel-j16-last 65083820: verify_backup, job_enable, job_disable on both engines;
--     the outcomes started / cut by shutdown / ended unknown),
--   0347_qsdd_s3_actions.sql:19-29 (rel-qsdd-force 8532f272, the same at 18794012: qs_force_plan / qs_unforce_plan with
--     no pid, the outcome 'requested' for those two alone; its own text DROPS verify_backup, job_enable, job_disable and
--     the three outcomes above - that loss is named here and fixed at its source),
--   and this file's save_table. 0353_job_start_step.sql:16-18 (rel-p21-a20 0b896f86) touches only action_kinds: no
--   CHECK. KILLGUARD (rel-killguard ef0327d4) has no migration. The join keeps ONE of each constraint, this list, in the
--   file applied last.
--
-- Locks: CREATE OR REPLACE FUNCTION locks the function only. Each CHECK is dropped and added again: ACCESS EXCLUSIVE
-- on pgvigil.actions_log for its validation scan (one row per attempt, a small table), last in the file, so the lock
-- is held only to the commit (0102's and 0194's order).

CREATE OR REPLACE FUNCTION pgvigil.import_save_table_log(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_engine text;
BEGIN
  SELECT engine INTO v_engine FROM pgvigil.instances WHERE instance_id = p_instance_id;
  IF v_engine IS NULL THEN
    RAISE EXCEPTION 'import_save_table_log: no instance %', p_instance_id;
  END IF;
  -- a row of another action is an error, never dropped: the attempt it records has been made already
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_payload, '[]'::jsonb)) e
              WHERE coalesce(e->>'action', '') <> 'save_table') THEN
    RAISE EXCEPTION 'import_save_table_log: an action other than save_table';
  END IF;
  INSERT INTO pgvigil.actions_log (instance_id, instance_name, at, ui_user, client, engine, action, pid, reason, outcome,
                                   detail, datname, target, statement, server_message)
  SELECT p_instance_id, x.instance_name, coalesce(x.at, p_snapshot_at), x.ui_user, nullif(x.client, ''), v_engine,
         x.action, NULL, coalesce(nullif(btrim(x.reason), ''), 'Save Table'), x.outcome, nullif(x.detail, ''),
         nullif(x.datname, ''), nullif(x.target, ''), nullif(x.statement, ''), nullif(x.server_message, '')
    FROM jsonb_to_recordset(p_payload) AS x(instance_name text, at timestamptz, ui_user text, client text, action text,
                                            reason text, outcome text, detail text, datname text, target text,
                                            statement text, server_message text);
END $$;
COMMENT ON FUNCTION pgvigil.import_save_table_log(int, timestamptz, jsonb) IS
  'Save Table''s audit (task 7b): one actions_log row per attempt, the engine from pgvigil.instances, pid NULL; save_table rows only.';

-- the actions door's CHECKs last (see Locks above): the union of 0300:2690-2697, 0347:19-29 and save_table
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_action_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_action_check CHECK (
     (engine = 'postgres' AND action IN ('cancel', 'terminate', 'explain_analyze', 'hypo_index', 'job_stop', 'job_start',
                                         'job_enable', 'job_disable', 'save_table'))
  OR (engine = 'sqlserver' AND action IN ('kill', 'job_start', 'job_stop', 'plan_evict', 'verify_backup', 'job_enable',
                                          'job_disable', 'qs_force_plan', 'qs_unforce_plan', 'save_table')));
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_pid_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_pid_check CHECK (
  pid IS NOT NULL OR action IN ('explain_analyze', 'hypo_index', 'job_start', 'job_stop', 'plan_evict', 'verify_backup',
                                'job_enable', 'job_disable', 'qs_force_plan', 'qs_unforce_plan', 'save_table'));
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_outcome_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_outcome_check CHECK (
     outcome IN ('done', 'refused', 'failed', 'started', 'cut by shutdown', 'ended unknown')
  OR (outcome = 'requested' AND action IN ('qs_force_plan', 'qs_unforce_plan')));
