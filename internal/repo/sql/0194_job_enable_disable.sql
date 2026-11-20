-- 0194 (B9c, B9-13): the actions door's job_enable and job_disable, on both engines - a SQL Server Agent job through
-- EXEC msdb.dbo.sp_update_job @job_id, @enabled (internal/mssql/actions.go), a pgAgent job through
-- UPDATE pgagent.pga_job SET jobenabled and a pg_cron job of the actions login's own through cron.alter_job(job_id,
-- active) (internal/collect/jobs_actions.go). Neither carries a pid: the target is the job (target = its name,
-- target_id = its id, as job_start's row). Nothing is created, changed or switched on on a monitored server by this
-- file; the actions stay off until an instance's actions: list names them.
--
--   actions_log_action_check   dropped and added again: 0157's list (task 406: plan_evict on SQL Server) and
--                              0191's (task 301b: verify_backup on SQL Server), which sort before
--                              it, with job_enable and job_disable on both engines, so this branch's proof accepts
--                              them; the two kinds are named again in 0300,
--                              which re-creates the CHECKs once with every feature's actions (BOTH).
--   actions_log_pid_check      dropped and added again: 0191's list (0157's plus verify_backup) with the two kinds (no
--                              pid). actions_log_outcome_check is not touched: 0191's stands.
--   import_pg_job_actions_log  replaced WHOLE (0102's text, its only definition on every branch read): its
--                              action list takes job_enable and job_disable; nothing else changes.
--   import_mssql_actions_log   unchanged (0067): it filters no action; the CHECK decides.
--
-- Locks: CREATE OR REPLACE FUNCTION locks the function only. Each CHECK is dropped and added again: ACCESS EXCLUSIVE
-- on pgvigil.actions_log for its validation scan (one row per attempt, a small table), last in the file, so the lock
-- is held only to the commit (0102's order).

CREATE OR REPLACE FUNCTION pgvigil.import_pg_job_actions_log(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'postgres' THEN
    RAISE EXCEPTION 'import_pg_job_actions_log: instance % is not a PostgreSQL instance', p_instance_id;
  END IF;
  -- a row of another action is an error, never dropped: the action it records has been sent already
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_payload, '[]'::jsonb)) e
              WHERE coalesce(e->>'action', '') NOT IN ('job_stop', 'job_start', 'job_enable', 'job_disable')) THEN
    RAISE EXCEPTION 'import_pg_job_actions_log: an action other than job_stop, job_start, job_enable and job_disable';
  END IF;
  INSERT INTO pgvigil.actions_log (instance_id, instance_name, at, ui_user, client, engine, action, pid, backend_start,
                                   target_user, target_app, target, target_id, reason, outcome, detail, datname, statement, server_message)
  SELECT p_instance_id, x.instance_name, coalesce(x.at, p_snapshot_at), x.ui_user, nullif(x.client, ''), 'postgres', x.action,
         nullif(x.pid, 0), x.backend_start, nullif(x.target_user, ''), nullif(x.target_app, ''), nullif(x.target, ''),
         nullif(x.target_id, ''), x.reason, x.outcome, nullif(x.detail, ''), nullif(x.datname, ''), nullif(x.statement, ''),
         nullif(x.server_message, '')
    FROM jsonb_to_recordset(p_payload) AS x(instance_name text, at timestamptz, ui_user text, client text, action text,
                                            pid int, backend_start timestamptz, target_user text, target_app text, target text,
                                            target_id text, reason text, outcome text, detail text, datname text, statement text,
                                            server_message text);
END $$;

-- the actions door's CHECKs last (see Locks above)
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_action_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_action_check CHECK (
     (engine = 'postgres' AND action IN ('cancel', 'terminate', 'explain_analyze', 'hypo_index', 'job_stop', 'job_start', 'job_enable', 'job_disable'))
  OR (engine = 'sqlserver' AND action IN ('kill', 'job_start', 'job_stop', 'plan_evict', 'verify_backup', 'job_enable', 'job_disable')));
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_pid_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_pid_check CHECK (pid IS NOT NULL OR action IN ('explain_analyze', 'hypo_index', 'job_start', 'job_stop', 'plan_evict', 'verify_backup', 'job_enable', 'job_disable'));
