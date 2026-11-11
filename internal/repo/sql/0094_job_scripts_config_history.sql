-- 0094_job_scripts_config_history: job scripts and configuration history in DBA Dash's shape (task 154; DBA Dash's
-- Job DDL History, Configuration Change Log, the Configuration pivot, Trace Flags History and Agent Job Thresholds).
--
--   1. pgvigil.job_versions.script: the job as one script (SQL Server Agent: sp_add_job / sp_add_jobstep /
--      sp_add_jobschedule; pg_cron: cron.schedule_in_database; pgAgent: pgAdmin's DO block), written by the
--      collector and stored with every version. job_version_track stores a new version when the definition's hash
--      differs, as before, and now also when the script differs from the one kept (a change the definition's
--      fields do not carry: a schedule's start date, say). A version kept before this file has no script: the first
--      read after it fills the newest version's script in place, without a new version; older versions stay
--      without one. import_jobs and import_mssql_jobs (0072's bodies) hand the script over.
--   2. pgvigil.mssql_config_history: every value of sys.configurations a read saw, with valid_from and valid_to
--      (NULL = in force). It is written by a trigger on pgvigil.mssql_config, so import_mssql_instance (0063) is
--      not re-created here. The rows 0063 holds are carried over: the value in force, and where 0063 kept one, the
--      value before it (its start was never kept: valid_from NULL).
--   3. pgvigil.config_change_log(instance): every setting change of an instance (NULL: of the fleet) with the old
--      value's valid_from / valid_to, both engines: SQL Server from mssql_config_history, PostgreSQL from
--      instance_setting_history (0001), whose rows are changes already.
--   4. pgvigil.mssql_config_pivot(): sys.configurations of every active SQL Server instance side by side, the odd
--      value marked: a value that is not the one value most instances run.
--   5. pgvigil.mssql_trace_flags, mssql_trace_flag_history and import_mssql_traceflags: the trace flags switched on
--      (DBCC TRACESTATUS(-1)) as last read, and each flag's added / removed history.
--   6. pgvigil.job_thresholds: thresholds on a job's failures at three levels (the fleet's root, an instance, one
--      job; the most specific live row applies whole, a level without a row inherits), written through
--      import_job_threshold (the actions door's audit login: apply_roles makes every import_* SECURITY DEFINER and
--      grants it to pgvigil_collector); never updated in place: a change ends the row and writes its successor, so
--      the table is its own history. pgvigil.job_status(instance) judges every job against them.
--
-- Retention: job_versions, mssql_config_history, mssql_trace_flag_history and job_thresholds hold a row per change,
-- not per read; they are kept and go with their instance.
-- Lock footprint: one ALTER TABLE ... ADD COLUMN without a default (a catalog change, no rewrite), one trigger on
-- pgvigil.mssql_config (a row per instance and option, written hourly), new tables.

ALTER TABLE pgvigil.job_versions ADD COLUMN IF NOT EXISTS script text;

-- job_version_track: one read's definitions against the versions kept. p_defs = [{scheduler, job_id, job_name,
-- definition, script}]; p_schedulers = the schedulers this read covers (a job of one of them that p_defs does not
-- list is dropped). A read that is not newer than every version kept of those schedulers changes nothing. Returns
-- the rows written (the versions; a script filled in place is not one).
CREATE OR REPLACE FUNCTION pgvigil.job_version_track(p_instance_id int, p_at timestamptz, p_schedulers text[], p_defs jsonb)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  IF EXISTS (SELECT 1 FROM pgvigil.job_versions v
              WHERE v.instance_id = p_instance_id AND v.scheduler = ANY (p_schedulers) AND v.valid_from >= p_at) THEN
    RETURN 0;
  END IF;
  WITH d AS (
    SELECT DISTINCT ON (e->>'scheduler', e->>'job_id')
           e->>'scheduler' AS scheduler, e->>'job_id' AS job_id, e->>'job_name' AS job_name,
           coalesce(jsonb_strip_nulls(e->'definition'), '{}'::jsonb) AS def, nullif(e->>'script', '') AS script
      FROM jsonb_array_elements(coalesce(p_defs, '[]'::jsonb)) e
     WHERE e->>'job_id' IS NOT NULL AND e->>'scheduler' = ANY (p_schedulers)
     ORDER BY e->>'scheduler', e->>'job_id'
  ), cur AS (
    SELECT DISTINCT ON (v.scheduler, v.job_id) v.scheduler, v.job_id, v.job_name, v.version_no, v.def_hash, v.definition, v.dropped,
           v.script, v.valid_from
      FROM pgvigil.job_versions v
     WHERE v.instance_id = p_instance_id AND v.scheduler = ANY (p_schedulers)
     ORDER BY v.scheduler, v.job_id, v.valid_from DESC
  ), fill AS (
    -- the newest version was kept without a script (before 0094, or by a collector older than the script) and the
    -- definition is the same: the script is filled in place, it is no change
    UPDATE pgvigil.job_versions v SET script = d.script
      FROM d JOIN cur ON cur.scheduler = d.scheduler AND cur.job_id = d.job_id
     WHERE v.instance_id = p_instance_id AND v.scheduler = cur.scheduler AND v.job_id = cur.job_id AND v.valid_from = cur.valid_from
       AND NOT cur.dropped AND cur.def_hash = md5(d.def::text) AND cur.script IS NULL AND d.script IS NOT NULL
    RETURNING 1
  )
  INSERT INTO pgvigil.job_versions (instance_id, scheduler, job_id, valid_from, version_no, job_name, def_hash, definition, dropped, changes, script)
  -- a job seen for the first time, a definition with another hash, another script, a job that came back
  SELECT p_instance_id, d.scheduler, d.job_id, p_at, coalesce(cur.version_no, 0) + 1, d.job_name, md5(d.def::text), d.def, false,
         CASE WHEN cur.job_id IS NULL THEN NULL
              ELSE pgvigil.job_def_diff(cur.definition, d.def)
                   || CASE WHEN cur.dropped THEN '[{"field": "job", "old": "dropped", "new": "present"}]'::jsonb ELSE '[]'::jsonb END END,
         -- a read without a script (an older collector) keeps the script of the version before while the definition is the same
         coalesce(d.script, CASE WHEN cur.def_hash = md5(d.def::text) THEN cur.script END)
    FROM d LEFT JOIN cur ON cur.scheduler = d.scheduler AND cur.job_id = d.job_id
   WHERE cur.job_id IS NULL OR cur.dropped OR cur.def_hash <> md5(d.def::text)
      OR (cur.script IS NOT NULL AND d.script IS NOT NULL AND cur.script <> d.script)
  UNION ALL
  -- a job this read no longer lists: kept, marked dropped at this read, with the last script seen
  SELECT p_instance_id, cur.scheduler, cur.job_id, p_at, cur.version_no + 1, cur.job_name, cur.def_hash, cur.definition, true,
         '[{"field": "job", "old": "present", "new": "dropped"}]'::jsonb, cur.script
    FROM cur
   WHERE NOT cur.dropped AND NOT EXISTS (SELECT 1 FROM d WHERE d.scheduler = cur.scheduler AND d.job_id = cur.job_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- PostgreSQL: 0072's import_jobs, unchanged but for the job's script handed to job_version_track.
CREATE OR REPLACE FUNCTION pgvigil.import_jobs(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_newest boolean := NOT EXISTS (SELECT 1 FROM pgvigil.jobs j WHERE j.instance_id = p_instance_id AND j.snapshot_at > p_snapshot_at);
BEGIN
  INSERT INTO pgvigil.jobs AS j (instance_id, scheduler, job_id, snapshot_at, job_name, schedule, command, datname, run_as,
                                 active, nodename, nodeport, next_run, last_run, first_seen, is_present, prior_due, schedule_note)
  SELECT p_instance_id, r->>'scheduler', (r->>'job_id')::bigint, p_snapshot_at, r->>'job_name', r->>'schedule', r->>'command',
         r->>'datname', r->>'run_as', (r->>'active')::boolean, r->>'nodename', (r->>'nodeport')::int,
         (r->>'next_run')::timestamptz, (r->>'last_run')::timestamptz, p_snapshot_at, true,
         (r->>'prior_due')::timestamptz, r->>'schedule_note'
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'job'
  ON CONFLICT (instance_id, scheduler, job_id) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, job_name = EXCLUDED.job_name, schedule = EXCLUDED.schedule, command = EXCLUDED.command,
    datname = EXCLUDED.datname, run_as = EXCLUDED.run_as, active = EXCLUDED.active, nodename = EXCLUDED.nodename,
    nodeport = EXCLUDED.nodeport, next_run = EXCLUDED.next_run, last_run = EXCLUDED.last_run, is_present = true,
    prior_due = EXCLUDED.prior_due, schedule_note = EXCLUDED.schedule_note;

  UPDATE pgvigil.jobs j SET is_present = false
   WHERE j.instance_id = p_instance_id AND j.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'job' AND r->>'scheduler' = j.scheduler AND (r->>'job_id')::bigint = j.job_id);

  -- a run is stored once; a running row is updated when it ends
  INSERT INTO pgvigil.job_runs AS x (instance_id, scheduler, job_id, run_id, job_pid, datname, run_as, command, status,
                                     return_message, start_time, end_time, duration_secs, snapshot_at, failed_step, step_result)
  SELECT p_instance_id, r->>'scheduler', (r->>'job_id')::bigint, (r->>'run_id')::bigint, (r->>'job_pid')::int, r->>'datname',
         r->>'run_as', r->>'command', r->>'status', r->>'return_message', (r->>'start_time')::timestamptz,
         (r->>'end_time')::timestamptz, (r->>'duration_secs')::float8, p_snapshot_at, r->>'failed_step', (r->>'step_result')::int
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'run' AND r->>'run_id' IS NOT NULL
  ON CONFLICT (instance_id, scheduler, job_id, run_id) DO UPDATE SET
    status = EXCLUDED.status, return_message = EXCLUDED.return_message, end_time = EXCLUDED.end_time,
    duration_secs = EXCLUDED.duration_secs, snapshot_at = EXCLUDED.snapshot_at,
    failed_step = EXCLUDED.failed_step, step_result = EXCLUDED.step_result
  WHERE x.end_time IS NULL;

  -- the definitions of this read against the versions kept (the newest read only)
  IF v_newest THEN
    PERFORM pgvigil.job_version_track(p_instance_id, p_snapshot_at, ARRAY['pg_cron', 'pgagent'],
      (SELECT jsonb_agg(jsonb_build_object('scheduler', r->>'scheduler', 'job_id', r->>'job_id', 'job_name', r->>'job_name', 'script', r->'script',
                'definition', CASE WHEN jsonb_typeof(r->'definition') = 'object' THEN r->'definition'
                                   ELSE jsonb_build_object('name', r->'job_name', 'schedule', r->'schedule', 'command', r->'command',
                                                           'database', r->'datname', 'username', r->'run_as', 'active', r->'active') END))
         FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'job' AND r->>'scheduler' IS NOT NULL AND r->>'job_id' IS NOT NULL));
  END IF;
END $$;

-- SQL Server: 0072's import_mssql_jobs, unchanged but for the job's script handed to job_version_track.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_jobs(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := pgvigil.mssql_rows(p_payload);
  v_newest boolean;
  v_month timestamptz;
  v_cursor bigint;
  v_mark bigint;
  v_from timestamptz;
BEGIN
  v_newest := pgvigil.mssql_hadr_read(p_instance_id, 'mssql_jobs', p_snapshot_at,
                (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'job'));

  FOR v_month IN SELECT DISTINCT date_trunc('month', (r->>'run_utc')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
                   FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'run' AND r->>'run_utc' IS NOT NULL LOOP
    PERFORM pgvigil.ensure_month_partition('mssql_job_runs', v_month);
  END LOOP;
  -- a row is stored once: the same number, job, step and msdb date and time, within three hours of the instant
  -- (the instant itself moves by an hour when the server's offset changes between two reads of one row)
  INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, step_name, run_date, run_time,
      run_status, duration_s, sql_message_id, sql_severity, retries, message)
  SELECT DISTINCT ON ((r->>'history_id')::bigint)
         p_instance_id, (r->>'run_utc')::timestamptz, (r->>'history_id')::bigint, r->>'job_id', r->>'job_name', (r->>'step_id')::int,
         r->>'step_name', (r->>'run_date')::int, (r->>'run_time')::int, (r->>'run_status')::int, (r->>'duration_s')::bigint, (r->>'sql_message_id')::int,
         (r->>'sql_severity')::int, (r->>'retries')::int, r->>'message'
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'run' AND r->>'run_utc' IS NOT NULL AND r->>'history_id' IS NOT NULL AND r->>'job_id' IS NOT NULL
     AND r->>'step_id' IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_job_runs x
                      WHERE x.instance_id = p_instance_id
                        AND x.snapshot_at BETWEEN (r->>'run_utc')::timestamptz - interval '3 hours' AND (r->>'run_utc')::timestamptz + interval '3 hours'
                        AND x.history_id = (r->>'history_id')::bigint AND x.job_id = r->>'job_id' AND x.step_id = (r->>'step_id')::int
                        AND x.run_date IS NOT DISTINCT FROM (r->>'run_date')::int AND x.run_time IS NOT DISTINCT FROM (r->>'run_time')::int);

  -- the outcome rows this read touched and that were not looked at yet: the step that failed (the last step row of
  -- the run with the run's own status: failed for a failed run, cancelled for a cancelled one) and the retries of
  -- the run's steps. A run's step rows are the job's rows with a smaller number from the run's start on (the
  -- outcome row carries the job's start and its whole duration).
  SELECT min((r->>'run_utc')::timestamptz) INTO v_from
    FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'run' AND r->>'step_id' = '0' AND r->>'run_utc' IS NOT NULL;
  IF v_from IS NOT NULL THEN
    UPDATE pgvigil.mssql_job_runs o
       SET failed_step_id = f.step_id, failed_step_name = f.step_name, failed_message = f.message,
           failed_sql_message_id = f.sql_message_id, failed_sql_severity = f.sql_severity,
           step_retries = coalesce(t.retries, 0)
      FROM pgvigil.mssql_job_runs r
      LEFT JOIN LATERAL (SELECT x.step_id, x.step_name, x.message, x.sql_message_id, x.sql_severity
                           FROM pgvigil.mssql_job_runs x
                          WHERE x.instance_id = r.instance_id AND x.job_id = r.job_id AND x.step_id > 0
                            AND r.run_status IN (0, 3) AND x.run_status = r.run_status
                            AND x.snapshot_at >= r.snapshot_at - interval '1 second'
                            AND x.snapshot_at <= r.snapshot_at + make_interval(secs => coalesce(r.duration_s, 0) + 60)
                            AND x.history_id < r.history_id
                          ORDER BY x.history_id DESC LIMIT 1) f ON true
      LEFT JOIN LATERAL (SELECT sum(x.retries) AS retries
                           FROM pgvigil.mssql_job_runs x
                          WHERE x.instance_id = r.instance_id AND x.job_id = r.job_id AND x.step_id > 0
                            AND x.snapshot_at >= r.snapshot_at - interval '1 second'
                            AND x.snapshot_at <= r.snapshot_at + make_interval(secs => coalesce(r.duration_s, 0) + 60)
                            AND x.history_id < r.history_id) t ON true
     WHERE r.instance_id = p_instance_id AND r.step_id = 0 AND r.step_retries IS NULL AND r.snapshot_at >= v_from
       AND o.snapshot_at >= v_from   -- bounds the target's partitions too
       AND o.instance_id = r.instance_id AND o.snapshot_at = r.snapshot_at AND o.history_id = r.history_id
       AND o.job_id = r.job_id AND o.step_id = 0;
  END IF;

  SELECT (r->>'last_history_id')::bigint, (r->>'mark')::bigint INTO v_cursor, v_mark
    FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'cursor' LIMIT 1;
  IF v_cursor IS NOT NULL AND v_newest THEN
    INSERT INTO pgvigil.mssql_jobs_cursor (instance_id, last_history_id, mark, updated_at) VALUES (p_instance_id, v_cursor, v_mark, p_snapshot_at)
    ON CONFLICT (instance_id) DO UPDATE SET last_history_id = EXCLUDED.last_history_id, mark = EXCLUDED.mark, updated_at = EXCLUDED.updated_at;
  END IF;

  IF NOT v_newest THEN
    RETURN;
  END IF;
  DELETE FROM pgvigil.mssql_jobs WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, description, category, owner, created_at,
      modified_at, schedules, enabled_schedules, schedule_names, next_run_at, last_outcome, last_run_at, last_duration_s,
      last_message, running_since, running_after_step, steps, schedule_text)
  SELECT DISTINCT ON (r->>'job_id') p_instance_id, r->>'job_id', p_snapshot_at, r->>'name', (r->>'enabled')::int = 1, r->>'description',
         r->>'category', r->>'owner', (r->>'created_utc')::timestamptz, (r->>'modified_utc')::timestamptz, (r->>'schedules')::int,
         (r->>'enabled_schedules')::int, r->>'schedule_names', (r->>'next_run_utc')::timestamptz, (r->>'last_outcome')::int,
         (r->>'last_run_utc')::timestamptz, (r->>'last_duration_s')::bigint, r->>'last_message',
         (r->>'running_since_utc')::timestamptz, (r->>'running_after_step')::int,
         (SELECT jsonb_agg(s - 'kind' - 'job_id' ORDER BY (s->>'step_id')::int) FROM jsonb_array_elements(v_rows) s
           WHERE s->>'kind' = 'step' AND s->>'job_id' = r->>'job_id'),
         (SELECT string_agg(coalesce(s->>'runs', s->>'schedule_name') || CASE WHEN (s->>'enabled')::int = 0 THEN ' (disabled)' ELSE '' END,
                            '; ' ORDER BY s->>'schedule_key')
            FROM jsonb_array_elements(v_rows) s WHERE s->>'kind' = 'schedule' AND s->>'job_id' = r->>'job_id')
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'job' AND r->>'job_id' IS NOT NULL AND r->>'name' IS NOT NULL;

  -- each job's definition against the versions kept
  PERFORM pgvigil.job_version_track(p_instance_id, p_snapshot_at, ARRAY['sqlagent'],
    (SELECT jsonb_agg(jsonb_build_object('scheduler', 'sqlagent', 'job_id', r->>'job_id', 'job_name', r->>'name', 'script', r->'script', 'definition',
        jsonb_build_object(
          'name', r->'name', 'enabled', (r->>'enabled')::int = 1, 'owner', r->'owner', 'category', r->'category',
          'description', r->'description', 'start step', r->'start_step_id',
          'notifications', jsonb_strip_nulls(jsonb_build_object(
              'email', pgvigil.mssql_notify_level((r->>'notify_level_email')::int), 'email operator', r->'notify_email_operator',
              'page', pgvigil.mssql_notify_level((r->>'notify_level_page')::int), 'page operator', r->'notify_page_operator',
              'event log', pgvigil.mssql_notify_level((r->>'notify_level_eventlog')::int),
              'delete the job', pgvigil.mssql_notify_level((r->>'delete_level')::int))),
          'schedules', coalesce((SELECT jsonb_object_agg(coalesce(s->>'schedule_key', s->>'schedule_name'),
                                     jsonb_build_object('enabled', (s->>'enabled')::int = 1, 'runs', s->'runs'))
                                   FROM jsonb_array_elements(v_rows) s
                                  WHERE s->>'kind' = 'schedule' AND s->>'job_id' = r->>'job_id'
                                    AND coalesce(s->>'schedule_key', s->>'schedule_name') IS NOT NULL), '{}'::jsonb),
          'steps', coalesce((SELECT jsonb_object_agg('step ' || CASE WHEN (s->>'step_id')::int < 10 THEN '0' ELSE '' END || (s->>'step_id'),
                                     jsonb_build_object('name', s->'step_name', 'subsystem', s->'subsystem', 'database', s->'database_name',
                                                        'command', s->'command', 'on success', s->'on_success', 'on failure', s->'on_fail',
                                                        'retries', s->'retry_attempts', 'retry interval (minutes)', s->'retry_interval',
                                                        'output file', s->'output_file', 'proxy', s->'proxy'))
                               FROM jsonb_array_elements(v_rows) s
                              WHERE s->>'kind' = 'step' AND s->>'job_id' = r->>'job_id' AND s->>'step_id' IS NOT NULL), '{}'::jsonb))))
       FROM jsonb_array_elements(v_rows) r
      WHERE r->>'kind' = 'job' AND r->>'job_id' IS NOT NULL AND r->>'name' IS NOT NULL));
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- SQL Server: every value of sys.configurations with the time it was in force
CREATE TABLE IF NOT EXISTS pgvigil.mssql_config_history (
  history_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name          text NOT NULL,
  valid_from    timestamptz,            -- the read that first saw the value; NULL = its start was never kept (a value 0063 held as 'previous')
  valid_to      timestamptz,            -- the read that saw the next value, or that no longer listed the option; NULL = in force
  value         bigint,                 -- NULL on a carried-over 'previous' row: 0063 kept the value in use alone
  value_in_use  bigint,
  first_read    boolean NOT NULL DEFAULT false,   -- the value as the first read found it: in force at valid_from, begun before it
  UNIQUE (instance_id, name, valid_from)
);
CREATE UNIQUE INDEX IF NOT EXISTS mssql_config_history_open_idx ON pgvigil.mssql_config_history (instance_id, name) WHERE valid_to IS NULL;
CREATE INDEX IF NOT EXISTS mssql_config_history_to_idx ON pgvigil.mssql_config_history (instance_id, valid_to) WHERE valid_to IS NOT NULL;
COMMENT ON TABLE pgvigil.mssql_config_history IS 'Every value of sys.configurations a read saw, with valid_from / valid_to; written by the trigger mssql_config_track on mssql_config.';

-- mssql_config_track: the trigger behind mssql_config_history. A row of mssql_config is a value as last read; the
-- trigger keeps what it replaces. A value the server no longer lists ends at the newest read of the instance (the
-- read that missed it); one that comes back starts again.
CREATE OR REPLACE FUNCTION pgvigil.mssql_config_track()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  o    pgvigil.mssql_config_history;
  v_at timestamptz;
BEGIN
  SELECT * INTO o FROM pgvigil.mssql_config_history h
   WHERE h.instance_id = NEW.instance_id AND h.name = NEW.name AND h.valid_to IS NULL;
  IF NOT NEW.is_present THEN
    IF o.history_id IS NOT NULL THEN
      SELECT max(c.snapshot_at) INTO v_at FROM pgvigil.mssql_config c WHERE c.instance_id = NEW.instance_id;
      UPDATE pgvigil.mssql_config_history SET valid_to = greatest(v_at, o.valid_from) WHERE history_id = o.history_id;
    END IF;
  ELSIF o.history_id IS NULL THEN
    INSERT INTO pgvigil.mssql_config_history (instance_id, name, valid_from, value, value_in_use, first_read)
    VALUES (NEW.instance_id, NEW.name, NEW.snapshot_at, NEW.value, NEW.value_in_use, TG_OP = 'INSERT')
    ON CONFLICT (instance_id, name, valid_from) DO UPDATE SET valid_to = NULL, value = EXCLUDED.value, value_in_use = EXCLUDED.value_in_use;
  ELSIF o.value IS DISTINCT FROM NEW.value OR o.value_in_use IS DISTINCT FROM NEW.value_in_use THEN
    IF NEW.snapshot_at <= o.valid_from THEN
      -- the same read imported again with another value: the row it wrote is put right, no period is made
      UPDATE pgvigil.mssql_config_history SET value = NEW.value, value_in_use = NEW.value_in_use WHERE history_id = o.history_id;
    ELSE
      UPDATE pgvigil.mssql_config_history SET valid_to = NEW.snapshot_at WHERE history_id = o.history_id;
      INSERT INTO pgvigil.mssql_config_history (instance_id, name, valid_from, value, value_in_use)
      VALUES (NEW.instance_id, NEW.name, NEW.snapshot_at, NEW.value, NEW.value_in_use);
    END IF;
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS mssql_config_track ON pgvigil.mssql_config;
CREATE TRIGGER mssql_config_track AFTER INSERT OR UPDATE ON pgvigil.mssql_config
  FOR EACH ROW EXECUTE FUNCTION pgvigil.mssql_config_track();

-- what 0063 holds, carried over once: where it kept a change, the value before it (closed at the change, its start
-- unknown) and the value since; else the value as it stands, since the read that is known (first_read: it may be older)
INSERT INTO pgvigil.mssql_config_history (instance_id, name, valid_from, valid_to, value, value_in_use, first_read)
SELECT c.instance_id, c.name, NULL, c.changed_at, NULL, c.previous_in_use, false
  FROM pgvigil.mssql_config c
 WHERE c.changed_at IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_config_history h WHERE h.instance_id = c.instance_id AND h.name = c.name);
INSERT INTO pgvigil.mssql_config_history (instance_id, name, valid_from, valid_to, value, value_in_use, first_read)
SELECT c.instance_id, c.name, coalesce(c.changed_at, c.snapshot_at), NULL, c.value, c.value_in_use, c.changed_at IS NULL
  FROM pgvigil.mssql_config c
 WHERE c.is_present
   AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_config_history h WHERE h.instance_id = c.instance_id AND h.name = c.name AND h.valid_to IS NULL);

-- config_change_log: every setting change of one instance (NULL: of every instance), newest first, both engines.
-- A row is a value that was replaced: the value, what replaced it, and the time the old value was in force
-- (valid_from to valid_to; valid_to is the read that saw the change). first_read: the old value was there at the
-- first read, so it began at or before valid_from (PostgreSQL: valid_from NULL, the first read's time is not kept
-- per setting). removed: nothing replaced the value (SQL Server: the server no longer lists the option).
-- PostgreSQL values are the setting's text (NULL = back at its default); SQL Server's are sys.configurations'
-- numbers as text, with the value in use beside the value set.
CREATE OR REPLACE FUNCTION pgvigil.config_change_log(p_instance_id int DEFAULT NULL)
RETURNS TABLE (instance_id int, instance text, engine text, name text, value text, value_in_use text, new_value text,
               new_value_in_use text, valid_from timestamptz, valid_to timestamptz, first_read boolean, removed boolean,
               is_dynamic boolean, is_advanced boolean, minimum bigint, maximum bigint)
LANGUAGE sql STABLE AS $$
  SELECT x.instance_id, i.name, i.engine, x.name, x.value, x.value_in_use, x.new_value, x.new_value_in_use, x.valid_from, x.valid_to,
         x.first_read, x.removed, x.is_dynamic, x.is_advanced, x.minimum, x.maximum
    FROM (
      SELECT h.instance_id, h.name, h.value::text AS value, h.value_in_use::text AS value_in_use, n.value::text AS new_value,
             n.value_in_use::text AS new_value_in_use, h.valid_from, h.valid_to, h.first_read, n.history_id IS NULL AS removed,
             c.is_dynamic, c.is_advanced, c.minimum, c.maximum
        FROM pgvigil.mssql_config_history h
        LEFT JOIN pgvigil.mssql_config_history n ON n.instance_id = h.instance_id AND n.name = h.name AND n.valid_from = h.valid_to
        LEFT JOIN pgvigil.mssql_config c ON c.instance_id = h.instance_id AND c.name = h.name
       WHERE h.valid_to IS NOT NULL AND (p_instance_id IS NULL OR h.instance_id = p_instance_id)
      UNION ALL
      SELECT h.instance_id, h.name, h.old_value, NULL, h.new_value, NULL,
             lag(h.changed_at) OVER w, h.changed_at, lag(h.changed_at) OVER w IS NULL, false, NULL, NULL, NULL, NULL
        FROM pgvigil.instance_setting_history h
       WHERE p_instance_id IS NULL OR h.instance_id = p_instance_id
      WINDOW w AS (PARTITION BY h.instance_id, h.name ORDER BY h.changed_at)
    ) x
    JOIN pgvigil.instances i ON i.instance_id = x.instance_id
   ORDER BY x.valid_to DESC, i.name, x.name
   LIMIT 2000
$$;

-- mssql_config_pivot: sys.configurations of every active SQL Server instance, one row per instance and option, for
-- the page's pivot (an option a column, an instance a row). same = the instances that run this row's value in use,
-- instances = the instances that list the option, common_in_use = the one value most instances run (NULL where two
-- values tie for it). is_odd: the option has more than one value in the fleet and this row's is not that common
-- value - in a tie every value is odd, no side is called right.
CREATE OR REPLACE FUNCTION pgvigil.mssql_config_pivot()
RETURNS TABLE (instance_id int, instance text, name text, value bigint, value_in_use bigint, pending boolean,
               instances int, same int, distinct_values int, common_in_use bigint, is_odd boolean)
LANGUAGE sql STABLE AS $$
  WITH c AS (
    SELECT c.instance_id, i.name AS instance, c.name, c.value, c.value_in_use,
           c.value IS DISTINCT FROM c.value_in_use
           AND NOT (c.name = 'min server memory (MB)' AND c.value = 0 AND c.value_in_use <= 16) AS pending
      FROM pgvigil.mssql_config c
      JOIN pgvigil.instances i ON i.instance_id = c.instance_id
     WHERE c.is_present AND i.is_active AND i.engine = 'sqlserver'
  ), f AS (
    SELECT c.name, c.value_in_use, count(*)::int AS n FROM c GROUP BY c.name, c.value_in_use
  ), r AS (
    SELECT f.name, f.value_in_use, f.n, max(f.n) OVER p AS top, sum(f.n) OVER p AS instances, count(*) OVER p AS vals
      FROM f WINDOW p AS (PARTITION BY f.name)
  ), m AS (
    SELECT r.name, r.value_in_use, r.n, r.top, r.instances::int AS instances, r.vals::int AS vals,
           count(*) FILTER (WHERE r.n = r.top) OVER (PARTITION BY r.name) AS tops
      FROM r
  )
  SELECT c.instance_id, c.instance, c.name, c.value, c.value_in_use, c.pending, m.instances, m.n, m.vals,
         (SELECT x.value_in_use FROM m x WHERE x.name = c.name AND x.n = x.top AND x.tops = 1),
         m.vals > 1 AND NOT (m.n = m.top AND m.tops = 1)
    FROM c
    JOIN m ON m.name = c.name AND m.value_in_use IS NOT DISTINCT FROM c.value_in_use
   ORDER BY c.instance, c.name
$$;

-- ---------------------------------------------------------------------------------------------------------------
-- SQL Server: the trace flags switched on, and their history
CREATE TABLE IF NOT EXISTS pgvigil.mssql_trace_flags (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  trace_flag    int NOT NULL,
  is_global     boolean,
  is_session    boolean,                -- on for the collector's own session only: said, never counted as the server's
  first_seen    timestamptz NOT NULL,   -- the read that first saw it on (since it was last off)
  first_read    boolean NOT NULL DEFAULT false,   -- on at the first read of the instance's flags: switched on before it
  snapshot_at   timestamptz NOT NULL,
  PRIMARY KEY (instance_id, trace_flag)
);
CREATE TABLE IF NOT EXISTS pgvigil.mssql_trace_flag_history (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  trace_flag    int NOT NULL,
  changed_at    timestamptz NOT NULL,   -- the read that saw the change
  change        text NOT NULL CHECK (change IN ('added', 'removed')),
  PRIMARY KEY (instance_id, trace_flag, changed_at)
);
-- the last read of an instance's flags: a server with no flag on has no row in mssql_trace_flags
CREATE TABLE IF NOT EXISTS pgvigil.mssql_trace_flags_read (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  first_read_at timestamptz NOT NULL,
  snapshot_at   timestamptz NOT NULL
);

-- import_mssql_traceflags: one read of DBCC TRACESTATUS(-1). payload: a 'flag' row per flag that is on ({trace_flag,
-- global, session}: the numbers of the command's columns) and one 'read' row; a payload without a 'read' row is
-- refused (a read that failed must not turn every flag off). A flag on for the collector's session alone is kept
-- with is_global false and is no change of the server. The first read is the baseline: its flags get no 'added'
-- row. A read older than the newest one changes nothing.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_traceflags(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows  jsonb := CASE WHEN jsonb_typeof(p_payload) = 'array' THEN p_payload ELSE '[]'::jsonb END;
  v_last  timestamptz;
  v_first boolean;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_traceflags: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'read') THEN
    RAISE EXCEPTION 'import_mssql_traceflags: the payload has no read row';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.mssql_traceflags'), p_instance_id);
  SELECT snapshot_at INTO v_last FROM pgvigil.mssql_trace_flags_read WHERE instance_id = p_instance_id;
  IF v_last IS NOT NULL AND v_last >= p_snapshot_at THEN
    RETURN;
  END IF;
  v_first := v_last IS NULL;
  INSERT INTO pgvigil.mssql_trace_flags_read (instance_id, first_read_at, snapshot_at) VALUES (p_instance_id, p_snapshot_at, p_snapshot_at)
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at;

  -- global flags that are no longer on (or on for the session alone now): removed
  INSERT INTO pgvigil.mssql_trace_flag_history (instance_id, trace_flag, changed_at, change)
  SELECT p_instance_id, t.trace_flag, p_snapshot_at, 'removed'
    FROM pgvigil.mssql_trace_flags t
   WHERE t.instance_id = p_instance_id AND t.is_global
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r
                      WHERE r->>'kind' = 'flag' AND (r->>'trace_flag')::int = t.trace_flag AND (r->>'global')::int = 1);
  -- global flags that were not on: added (never on the first read)
  INSERT INTO pgvigil.mssql_trace_flag_history (instance_id, trace_flag, changed_at, change)
  SELECT DISTINCT p_instance_id, (r->>'trace_flag')::int, p_snapshot_at, 'added'
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'flag' AND r->>'trace_flag' IS NOT NULL AND (r->>'global')::int = 1 AND NOT v_first
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_trace_flags t
                      WHERE t.instance_id = p_instance_id AND t.trace_flag = (r->>'trace_flag')::int AND t.is_global);

  DELETE FROM pgvigil.mssql_trace_flags t
   WHERE t.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'flag' AND (r->>'trace_flag')::int = t.trace_flag);
  INSERT INTO pgvigil.mssql_trace_flags AS t (instance_id, trace_flag, is_global, is_session, first_seen, first_read, snapshot_at)
  SELECT DISTINCT ON ((r->>'trace_flag')::int) p_instance_id, (r->>'trace_flag')::int, (r->>'global')::int = 1, (r->>'session')::int = 1,
         p_snapshot_at, v_first, p_snapshot_at
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'flag' AND r->>'trace_flag' IS NOT NULL
   ORDER BY (r->>'trace_flag')::int
  ON CONFLICT (instance_id, trace_flag) DO UPDATE SET
      -- a flag that turns global starts again: it was the session's alone until this read
      first_seen = CASE WHEN EXCLUDED.is_global AND NOT coalesce(t.is_global, false) THEN EXCLUDED.first_seen ELSE t.first_seen END,
      first_read = CASE WHEN EXCLUDED.is_global AND NOT coalesce(t.is_global, false) THEN false ELSE t.first_read END,
      is_global = EXCLUDED.is_global, is_session = EXCLUDED.is_session, snapshot_at = EXCLUDED.snapshot_at;
END $$;

-- mssql_trace_flags_now and mssql_trace_flag_log: the flags on now and their history, of one instance or (NULL) of the fleet.
CREATE OR REPLACE FUNCTION pgvigil.mssql_trace_flags_now(p_instance_id int DEFAULT NULL)
RETURNS TABLE (instance_id int, instance text, trace_flag int, is_global boolean, is_session boolean, first_seen timestamptz,
               first_read boolean, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT t.instance_id, i.name, t.trace_flag, t.is_global, t.is_session, t.first_seen, t.first_read, t.snapshot_at
    FROM pgvigil.mssql_trace_flags t JOIN pgvigil.instances i ON i.instance_id = t.instance_id
   WHERE p_instance_id IS NULL OR t.instance_id = p_instance_id
   ORDER BY i.name, t.trace_flag
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_trace_flag_log(p_instance_id int DEFAULT NULL)
RETURNS TABLE (instance_id int, instance text, trace_flag int, changed_at timestamptz, change text)
LANGUAGE sql STABLE AS $$
  SELECT h.instance_id, i.name, h.trace_flag, h.changed_at, h.change
    FROM pgvigil.mssql_trace_flag_history h JOIN pgvigil.instances i ON i.instance_id = h.instance_id
   WHERE p_instance_id IS NULL OR h.instance_id = p_instance_id
   ORDER BY h.changed_at DESC, i.name, h.trace_flag
   LIMIT 2000
$$;

-- ---------------------------------------------------------------------------------------------------------------
-- Job thresholds at three levels
CREATE TABLE IF NOT EXISTS pgvigil.job_thresholds (
  threshold_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  level                text NOT NULL CHECK (level IN ('root', 'instance', 'job')),
  instance_id          int REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  job_name             text CHECK (length(job_name) <= 300),   -- the name: a job made again under its name keeps its thresholds
  fail_24h_warn        int CHECK (fail_24h_warn BETWEEN 1 AND 1000000),        -- failed runs in the last 24 hours
  fail_24h_crit        int CHECK (fail_24h_crit BETWEEN 1 AND 1000000),
  fail_7d_warn         int CHECK (fail_7d_warn BETWEEN 1 AND 1000000),         -- failed runs in the last 7 days
  fail_7d_crit         int CHECK (fail_7d_crit BETWEEN 1 AND 1000000),
  step_fail_24h_warn   int CHECK (step_fail_24h_warn BETWEEN 1 AND 1000000),   -- failed steps (SQL Server: msdb's step rows)
  step_fail_24h_crit   int CHECK (step_fail_24h_crit BETWEEN 1 AND 1000000),
  step_fail_7d_warn    int CHECK (step_fail_7d_warn BETWEEN 1 AND 1000000),
  step_fail_7d_crit    int CHECK (step_fail_7d_crit BETWEEN 1 AND 1000000),
  since_fail_warn_min  int CHECK (since_fail_warn_min BETWEEN 1 AND 5256000),  -- the last failure is no older than this
  since_fail_crit_min  int CHECK (since_fail_crit_min BETWEEN 1 AND 5256000),
  since_ok_warn_min    int CHECK (since_ok_warn_min BETWEEN 1 AND 5256000),    -- the last success is older than this
  since_ok_crit_min    int CHECK (since_ok_crit_min BETWEEN 1 AND 5256000),
  last_fail_is         text CHECK (last_fail_is IN ('warn', 'crit')),           -- the job's last run failed
  created_by           text NOT NULL,
  created_at           timestamptz NOT NULL,
  client               text,
  replaces             bigint,
  ended_by             text,
  ended_at             timestamptz,
  CONSTRAINT "the root level names no instance and no job" CHECK (level <> 'root' OR (instance_id IS NULL AND job_name IS NULL)),
  CONSTRAINT "an instance level names its instance and no job" CHECK (level <> 'instance' OR (instance_id IS NOT NULL AND job_name IS NULL)),
  CONSTRAINT "a job level names its instance and its job" CHECK (level <> 'job' OR (instance_id IS NOT NULL AND job_name IS NOT NULL))
);
-- one live row per level's place
CREATE UNIQUE INDEX IF NOT EXISTS job_thresholds_live_idx
  ON pgvigil.job_thresholds (level, coalesce(instance_id, 0), coalesce(job_name, '')) WHERE ended_at IS NULL;
COMMENT ON TABLE pgvigil.job_thresholds IS 'Job thresholds at the root, instance and job level; written through import_job_threshold only, a change ends the row and writes its successor.';

-- import_job_threshold: one attempt from the UI. p_payload: {op: set | inherit, level, instance_id, job_name,
-- ui_user, client, and for set the thresholds by their column names (a missing or null one is not judged)}.
-- set ends the level's live row and writes the new one; inherit ends it, so the level above applies. Answers
-- {outcome: done | refused, detail, threshold_id}; a refused attempt writes nothing.
CREATE OR REPLACE FUNCTION pgvigil.import_job_threshold(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op     text := p_payload->>'op';
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_level  text := p_payload->>'level';
  v_inst   int;
  v_job    text := nullif(p_payload->>'job_name', '');
  v_old    bigint;
  v_new    bigint;
  v_why    text;
  k        text;
  v_keys   text[] := ARRAY['fail_24h_warn', 'fail_24h_crit', 'fail_7d_warn', 'fail_7d_crit', 'step_fail_24h_warn', 'step_fail_24h_crit',
                           'step_fail_7d_warn', 'step_fail_7d_crit', 'since_fail_warn_min', 'since_fail_crit_min', 'since_ok_warn_min',
                           'since_ok_crit_min'];
  v_set    int := 0;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_job_threshold: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN
    v_inst := (p_payload->>'instance_id')::int;
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('set', 'inherit') THEN
    v_why := 'op must be set or inherit';
  ELSIF v_level IS NULL OR v_level NOT IN ('root', 'instance', 'job') THEN
    v_why := 'level must be root, instance or job';
  ELSIF v_level <> 'root' AND (v_inst IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = v_inst)) THEN
    v_why := format('no instance %s', coalesce(p_payload->>'instance_id', '(none)'));
  ELSIF v_level = 'job' AND (v_job IS NULL OR length(v_job) > 300) THEN
    v_why := 'a job level names its job (300 characters at most)';
  ELSIF v_op = 'set' AND p_payload->>'last_fail_is' IS NOT NULL AND p_payload->>'last_fail_is' NOT IN ('warn', 'crit') THEN
    v_why := 'last_fail_is must be warn, crit or null';
  ELSIF v_op = 'set' THEN
    FOREACH k IN ARRAY v_keys LOOP
      IF p_payload->>k IS NOT NULL THEN
        -- the table's own bounds: a count up to a million, minutes up to ten years
        IF p_payload->>k !~ '^[0-9]{1,7}$' OR (p_payload->>k)::int < 1
           OR (p_payload->>k)::int > (CASE WHEN k LIKE '%\_min' THEN 5256000 ELSE 1000000 END) THEN
          v_why := format('%s must be a whole number from 1 to %s, or null', k, CASE WHEN k LIKE '%\_min' THEN 5256000 ELSE 1000000 END);
          EXIT;
        END IF;
        v_set := v_set + 1;
      END IF;
    END LOOP;
    IF v_why IS NULL AND v_set = 0 AND p_payload->>'last_fail_is' IS NULL THEN
      v_why := 'no threshold is set: to take the level above, inherit';
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_level = 'root' THEN v_inst := NULL; v_job := NULL; ELSIF v_level = 'instance' THEN v_job := NULL; END IF;
  -- one writer per level's place
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.job_thresholds'), hashtext(v_level || '|' || coalesce(v_inst, 0) || '|' || coalesce(v_job, '')));
  SELECT t.threshold_id INTO v_old FROM pgvigil.job_thresholds t
   WHERE t.ended_at IS NULL AND t.level = v_level AND coalesce(t.instance_id, 0) = coalesce(v_inst, 0) AND coalesce(t.job_name, '') = coalesce(v_job, '');
  IF v_op = 'inherit' AND v_old IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'this level has no thresholds of its own: it inherits already');
  END IF;
  UPDATE pgvigil.job_thresholds SET ended_by = v_user, ended_at = p_at WHERE threshold_id = v_old;
  IF v_op = 'inherit' THEN
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'ended: the level above applies', 'threshold_id', v_old);
  END IF;
  INSERT INTO pgvigil.job_thresholds (level, instance_id, job_name, fail_24h_warn, fail_24h_crit, fail_7d_warn, fail_7d_crit,
      step_fail_24h_warn, step_fail_24h_crit, step_fail_7d_warn, step_fail_7d_crit, since_fail_warn_min, since_fail_crit_min,
      since_ok_warn_min, since_ok_crit_min, last_fail_is, created_by, created_at, client, replaces)
  VALUES (v_level, v_inst, v_job, (p_payload->>'fail_24h_warn')::int, (p_payload->>'fail_24h_crit')::int, (p_payload->>'fail_7d_warn')::int,
      (p_payload->>'fail_7d_crit')::int, (p_payload->>'step_fail_24h_warn')::int, (p_payload->>'step_fail_24h_crit')::int,
      (p_payload->>'step_fail_7d_warn')::int, (p_payload->>'step_fail_7d_crit')::int, (p_payload->>'since_fail_warn_min')::int,
      (p_payload->>'since_fail_crit_min')::int, (p_payload->>'since_ok_warn_min')::int, (p_payload->>'since_ok_crit_min')::int,
      p_payload->>'last_fail_is', v_user, p_at, nullif(p_payload->>'client', ''), v_old)
  RETURNING threshold_id INTO v_new;
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'set', 'threshold_id', v_new);
END $$;

-- job_threshold_levels: the live thresholds an instance's jobs can take: the root's, the instance's and each job's.
CREATE OR REPLACE FUNCTION pgvigil.job_threshold_levels(p_instance_id int)
RETURNS SETOF pgvigil.job_thresholds LANGUAGE sql STABLE AS $$
  SELECT t.* FROM pgvigil.job_thresholds t
   WHERE t.ended_at IS NULL AND (t.level = 'root' OR t.instance_id = p_instance_id)
   ORDER BY CASE t.level WHEN 'root' THEN 1 WHEN 'instance' THEN 2 ELSE 3 END, t.job_name
$$;

-- job_status: every job of an instance (SQL Server Agent's; pg_cron's and pgAgent's) judged against the thresholds
-- in force for it: the job's own row, else the instance's, else the root's, else the built-in rule (the last run
-- failed = critical, as the Jobs grid has always shown it). status: crit, warn, ok, or none (the row in force sets
-- no threshold a job can break). reason names the rule that is broken, the critical one first.
CREATE OR REPLACE FUNCTION pgvigil.job_status(p_instance_id int)
RETURNS TABLE (scheduler text, job_id text, job_name text, level text, threshold_id bigint, fail_24h bigint, fail_7d bigint,
               step_fail_24h bigint, step_fail_7d bigint, last_failed_at timestamptz, last_succeeded_at timestamptz,
               last_outcome text, status text, reason text)
LANGUAGE sql STABLE AS $$
  WITH j AS (
    SELECT 'sqlagent'::text AS scheduler, m.job_id, m.name AS job_name,
           CASE m.last_outcome WHEN 0 THEN 'failed' WHEN 1 THEN 'succeeded' WHEN 2 THEN 'retry' WHEN 3 THEN 'cancelled' END AS last_outcome,
           c.fail_24h, c.fail_7d, c.step_fail_24h, c.step_fail_7d, lf.at AS last_failed_at, ls.at AS last_succeeded_at, fr.at AS first_run_at
      FROM pgvigil.mssql_jobs m
      LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE r.step_id = 0 AND r.snapshot_at > now() - interval '24 hours') AS fail_24h,
                                count(*) FILTER (WHERE r.step_id = 0) AS fail_7d,
                                count(*) FILTER (WHERE r.step_id > 0 AND r.snapshot_at > now() - interval '24 hours') AS step_fail_24h,
                                count(*) FILTER (WHERE r.step_id > 0) AS step_fail_7d
                           FROM pgvigil.mssql_job_runs r
                          WHERE r.instance_id = m.instance_id AND r.job_id = m.job_id AND r.run_status = 0
                            AND r.snapshot_at > now() - interval '7 days' AND r.snapshot_at <= now()) c ON true
      LEFT JOIN LATERAL (SELECT r.snapshot_at AS at FROM pgvigil.mssql_job_runs r
                          WHERE r.instance_id = m.instance_id AND r.job_id = m.job_id AND r.step_id = 0 AND r.run_status = 0
                          ORDER BY r.snapshot_at DESC LIMIT 1) lf ON true
      LEFT JOIN LATERAL (SELECT r.snapshot_at AS at FROM pgvigil.mssql_job_runs r
                          WHERE r.instance_id = m.instance_id AND r.job_id = m.job_id AND r.step_id = 0 AND r.run_status = 1
                          ORDER BY r.snapshot_at DESC LIMIT 1) ls ON true
      LEFT JOIN LATERAL (SELECT r.snapshot_at AS at FROM pgvigil.mssql_job_runs r
                          WHERE r.instance_id = m.instance_id AND r.job_id = m.job_id AND r.step_id = 0
                          ORDER BY r.snapshot_at LIMIT 1) fr ON true
     WHERE m.instance_id = p_instance_id
    UNION ALL
    SELECT g.scheduler, g.job_id::text, coalesce(g.job_name, g.job_id::text),
           lr.outcome, c.fail_24h, c.fail_7d, 0::bigint, 0::bigint, lf.at, ls.at, fr.at
      FROM pgvigil.jobs g
      LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE r.start_time > now() - interval '24 hours') AS fail_24h, count(*) AS fail_7d
                           FROM pgvigil.job_runs r
                          WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id
                            AND r.status IN ('failed', 'internal error')
                            AND r.start_time > now() - interval '7 days' AND r.start_time <= now()) c ON true
      LEFT JOIN LATERAL (SELECT CASE WHEN r.status = 'succeeded' THEN 'succeeded' WHEN r.status IN ('failed', 'internal error') THEN 'failed'
                                     WHEN r.status = 'aborted' THEN 'cancelled' WHEN r.end_time IS NULL THEN 'running' ELSE r.status END AS outcome
                           FROM pgvigil.job_runs r
                          WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id
                          ORDER BY r.start_time DESC NULLS LAST LIMIT 1) lr ON true
      LEFT JOIN LATERAL (SELECT max(r.start_time) AS at FROM pgvigil.job_runs r
                          WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id
                            AND r.status IN ('failed', 'internal error')) lf ON true
      LEFT JOIN LATERAL (SELECT max(r.start_time) AS at FROM pgvigil.job_runs r
                          WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id
                            AND r.status = 'succeeded') ls ON true
      LEFT JOIN LATERAL (SELECT min(r.start_time) AS at FROM pgvigil.job_runs r
                          WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id) fr ON true
     WHERE g.instance_id = p_instance_id AND g.is_present
  ), e AS (
    SELECT j.*, t.threshold_id, coalesce(t.level, 'default') AS level,
           t.fail_24h_warn, t.fail_24h_crit, t.fail_7d_warn, t.fail_7d_crit, t.step_fail_24h_warn, t.step_fail_24h_crit,
           t.step_fail_7d_warn, t.step_fail_7d_crit, t.since_fail_warn_min, t.since_fail_crit_min, t.since_ok_warn_min, t.since_ok_crit_min,
           CASE WHEN t.threshold_id IS NULL THEN 'crit' ELSE t.last_fail_is END AS last_fail_is,
           extract(epoch FROM now() - j.last_failed_at) / 60 AS fail_min,
           extract(epoch FROM now() - coalesce(j.last_succeeded_at, j.first_run_at)) / 60 AS ok_min
      FROM j
      LEFT JOIN LATERAL (SELECT t.* FROM pgvigil.job_thresholds t
                          WHERE t.ended_at IS NULL
                            AND (t.level = 'root' OR (t.instance_id = p_instance_id AND (t.level = 'instance' OR t.job_name = j.job_name)))
                          ORDER BY CASE t.level WHEN 'job' THEN 1 WHEN 'instance' THEN 2 ELSE 3 END LIMIT 1) t ON true
  )
  SELECT e.scheduler, e.job_id, e.job_name, e.level, e.threshold_id, e.fail_24h, e.fail_7d, e.step_fail_24h, e.step_fail_7d,
         e.last_failed_at, e.last_succeeded_at, e.last_outcome,
         coalesce(b.sev, CASE WHEN num_nonnulls(e.fail_24h_warn, e.fail_24h_crit, e.fail_7d_warn, e.fail_7d_crit, e.step_fail_24h_warn,
                                                e.step_fail_24h_crit, e.step_fail_7d_warn, e.step_fail_7d_crit, e.since_fail_warn_min,
                                                e.since_fail_crit_min, e.since_ok_warn_min, e.since_ok_crit_min, e.last_fail_is) > 0
                              THEN 'ok' ELSE 'none' END),
         b.why
    FROM e
    LEFT JOIN LATERAL (
      SELECT v.sev, v.why
        FROM (VALUES
          (1, 'crit', e.last_outcome = 'failed' AND e.last_fail_is = 'crit', 'the last run failed'),
          (2, 'crit', e.fail_24h >= e.fail_24h_crit, format('%s failed run(s) in 24 hours (critical at %s)', e.fail_24h, e.fail_24h_crit)),
          (3, 'crit', e.fail_7d >= e.fail_7d_crit, format('%s failed run(s) in 7 days (critical at %s)', e.fail_7d, e.fail_7d_crit)),
          (4, 'crit', e.step_fail_24h >= e.step_fail_24h_crit, format('%s failed step(s) in 24 hours (critical at %s)', e.step_fail_24h, e.step_fail_24h_crit)),
          (5, 'crit', e.step_fail_7d >= e.step_fail_7d_crit, format('%s failed step(s) in 7 days (critical at %s)', e.step_fail_7d, e.step_fail_7d_crit)),
          (6, 'crit', e.fail_min <= e.since_fail_crit_min, format('failed %s minute(s) ago (critical within %s)', round(e.fail_min), e.since_fail_crit_min)),
          (7, 'crit', e.ok_min > e.since_ok_crit_min, format('no success for %s minute(s) (critical over %s)', round(e.ok_min), e.since_ok_crit_min)),
          (11, 'warn', e.last_outcome = 'failed' AND e.last_fail_is = 'warn', 'the last run failed'),
          (12, 'warn', e.fail_24h >= e.fail_24h_warn, format('%s failed run(s) in 24 hours (warning at %s)', e.fail_24h, e.fail_24h_warn)),
          (13, 'warn', e.fail_7d >= e.fail_7d_warn, format('%s failed run(s) in 7 days (warning at %s)', e.fail_7d, e.fail_7d_warn)),
          (14, 'warn', e.step_fail_24h >= e.step_fail_24h_warn, format('%s failed step(s) in 24 hours (warning at %s)', e.step_fail_24h, e.step_fail_24h_warn)),
          (15, 'warn', e.step_fail_7d >= e.step_fail_7d_warn, format('%s failed step(s) in 7 days (warning at %s)', e.step_fail_7d, e.step_fail_7d_warn)),
          (16, 'warn', e.fail_min <= e.since_fail_warn_min, format('failed %s minute(s) ago (warning within %s)', round(e.fail_min), e.since_fail_warn_min)),
          (17, 'warn', e.ok_min > e.since_ok_warn_min, format('no success for %s minute(s) (warning over %s)', round(e.ok_min), e.since_ok_warn_min))
        ) v(ord, sev, broken, why)
       WHERE v.broken
       ORDER BY v.ord LIMIT 1) b ON true
   ORDER BY e.scheduler, e.job_name
$$;
