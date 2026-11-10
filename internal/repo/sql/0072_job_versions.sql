-- 0072_job_versions: the Jobs pages in DBA Dash's shape on both engines (task 110) - the failed step's message on
-- the run, and the history of a job's definition.
--
--   1. pgvigil.mssql_job_runs gets, on a job's outcome row (step 0), the step that failed in that run (its id, its
--      name, its own message, sql_message_id and sql_severity) and the retries of the run's steps; the import fills
--      them from the step rows of the same run, for the outcome rows of each read (rows stored before 0072 are not
--      filled: their failed step shows empty). pgvigil.job_runs gets failed_step and step_result (pgAgent's
--      pga_jobsteplog; pg_cron has no steps). The run tables are extended, not forked.
--   2. pgvigil.mssql_jobs gets schedule_text (each schedule in words, from the collector).
--   3. pgvigil.job_versions: one row per version of a job's definition, both engines, keyed by instance, scheduler
--      ('pg_cron', 'pgagent', 'sqlagent'), job id and valid_from. Every read hashes each job's definition; another
--      hash stores a new row with the fields that differ (old against new); a job the read no longer lists gets a
--      row marked dropped with the time of that read, and one that comes back a row again.
--   4. import_jobs (0027's body) and import_mssql_jobs (0066's body) re-created with 1-3.
--
-- Retention: job_versions is kept (a row per change, not per read); it goes with its instance.
-- Lock footprint: three ALTER TABLE ... ADD COLUMN without a default (a catalog change, no rewrite) and one index on
-- mssql_job_runs built per partition.

ALTER TABLE pgvigil.mssql_job_runs ADD COLUMN IF NOT EXISTS failed_step_id int;
ALTER TABLE pgvigil.mssql_job_runs ADD COLUMN IF NOT EXISTS failed_step_name text;
ALTER TABLE pgvigil.mssql_job_runs ADD COLUMN IF NOT EXISTS failed_message text;
ALTER TABLE pgvigil.mssql_job_runs ADD COLUMN IF NOT EXISTS failed_sql_message_id int;
ALTER TABLE pgvigil.mssql_job_runs ADD COLUMN IF NOT EXISTS failed_sql_severity int;
ALTER TABLE pgvigil.mssql_job_runs ADD COLUMN IF NOT EXISTS step_retries int;   -- not NULL = the run's steps were looked at
-- a job's runs over a range (the history grid, the last failure of each job)
CREATE INDEX IF NOT EXISTS mssql_job_runs_job_idx ON pgvigil.mssql_job_runs (instance_id, job_id, snapshot_at);

ALTER TABLE pgvigil.job_runs ADD COLUMN IF NOT EXISTS failed_step text;
ALTER TABLE pgvigil.job_runs ADD COLUMN IF NOT EXISTS step_result int;

ALTER TABLE pgvigil.mssql_jobs ADD COLUMN IF NOT EXISTS schedule_text text;

CREATE TABLE IF NOT EXISTS pgvigil.job_versions (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  scheduler    text NOT NULL,          -- 'pg_cron', 'pgagent', 'sqlagent'
  job_id       text NOT NULL,          -- pg_cron's and pgAgent's jobid; msdb's job_id
  valid_from   timestamptz NOT NULL,   -- the read that first saw this version (or that no longer listed the job)
  version_no   int NOT NULL,           -- 1 = the first version seen: not a change
  job_name     text,
  def_hash     text NOT NULL,
  definition   jsonb NOT NULL,         -- nested objects, no arrays; on a dropped row the last definition seen
  dropped      boolean NOT NULL DEFAULT false,
  changes      jsonb,                  -- [{field, old, new}] against the version before; NULL on version 1
  PRIMARY KEY (instance_id, scheduler, job_id, valid_from)
);

-- jsonb_flat: every leaf of a document of nested objects as (path, value); a path's parts are joined by ' / '
CREATE OR REPLACE FUNCTION pgvigil.jsonb_flat(p jsonb)
RETURNS TABLE (path text, value text) LANGUAGE sql IMMUTABLE AS $$
  WITH RECURSIVE t(path, v) AS (
    SELECT ''::text, p
    UNION ALL
    SELECT CASE WHEN t.path = '' THEN e.key ELSE t.path || ' / ' || e.key END, e.value
      FROM t CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(t.v) = 'object' THEN t.v ELSE '{}'::jsonb END) e
  )
  SELECT t.path, t.v #>> '{}' FROM t WHERE jsonb_typeof(t.v) NOT IN ('object', 'null') AND t.path <> ''
$$;

-- job_def_diff: the fields that differ between two definitions, [{field, old, new}] by field; a field only one side
-- has carries no old or no new
CREATE OR REPLACE FUNCTION pgvigil.job_def_diff(p_old jsonb, p_new jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('field', x.path, 'old', x.o, 'new', x.n) ORDER BY x.path), '[]'::jsonb)
    FROM (SELECT path, a.value AS o, b.value AS n
            FROM pgvigil.jsonb_flat(p_old) a FULL JOIN pgvigil.jsonb_flat(p_new) b USING (path)
           WHERE a.value IS DISTINCT FROM b.value) x
$$;

-- job_version_track: one read's definitions against the versions kept. p_defs = [{scheduler, job_id, job_name,
-- definition}]; p_schedulers = the schedulers this read covers (a job of one of them that p_defs does not list is
-- dropped). A read that is not newer than every version kept of those schedulers changes nothing. Returns the rows
-- written.
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
           coalesce(jsonb_strip_nulls(e->'definition'), '{}'::jsonb) AS def
      FROM jsonb_array_elements(coalesce(p_defs, '[]'::jsonb)) e
     WHERE e->>'job_id' IS NOT NULL AND e->>'scheduler' = ANY (p_schedulers)
     ORDER BY e->>'scheduler', e->>'job_id'
  ), cur AS (
    SELECT DISTINCT ON (v.scheduler, v.job_id) v.scheduler, v.job_id, v.job_name, v.version_no, v.def_hash, v.definition, v.dropped
      FROM pgvigil.job_versions v
     WHERE v.instance_id = p_instance_id AND v.scheduler = ANY (p_schedulers)
     ORDER BY v.scheduler, v.job_id, v.valid_from DESC
  )
  INSERT INTO pgvigil.job_versions (instance_id, scheduler, job_id, valid_from, version_no, job_name, def_hash, definition, dropped, changes)
  -- a job seen for the first time, a definition with another hash, a job that came back
  SELECT p_instance_id, d.scheduler, d.job_id, p_at, coalesce(cur.version_no, 0) + 1, d.job_name, md5(d.def::text), d.def, false,
         CASE WHEN cur.job_id IS NULL THEN NULL
              ELSE pgvigil.job_def_diff(cur.definition, d.def)
                   || CASE WHEN cur.dropped THEN '[{"field": "job", "old": "dropped", "new": "present"}]'::jsonb ELSE '[]'::jsonb END END
    FROM d LEFT JOIN cur ON cur.scheduler = d.scheduler AND cur.job_id = d.job_id
   WHERE cur.job_id IS NULL OR cur.dropped OR cur.def_hash <> md5(d.def::text)
  UNION ALL
  -- a job this read no longer lists: kept, marked dropped at this read
  SELECT p_instance_id, cur.scheduler, cur.job_id, p_at, cur.version_no + 1, cur.job_name, cur.def_hash, cur.definition, true,
         '[{"field": "job", "old": "present", "new": "dropped"}]'::jsonb
    FROM cur
   WHERE NOT cur.dropped AND NOT EXISTS (SELECT 1 FROM d WHERE d.scheduler = cur.scheduler AND d.job_id = cur.job_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- PostgreSQL: 0027's import_jobs with failed_step and step_result on a run and the version tracking. A job row's
-- definition is its own 'definition' (pgAgent: the collector builds it from the job's schedules and steps) or, for
-- pg_cron, the six fields of cron.job.
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
      (SELECT jsonb_agg(jsonb_build_object('scheduler', r->>'scheduler', 'job_id', r->>'job_id', 'job_name', r->>'job_name',
                'definition', CASE WHEN jsonb_typeof(r->'definition') = 'object' THEN r->'definition'
                                   ELSE jsonb_build_object('name', r->'job_name', 'schedule', r->'schedule', 'command', r->'command',
                                                           'database', r->'datname', 'username', r->'run_as', 'active', r->'active') END))
         FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'job' AND r->>'scheduler' IS NOT NULL AND r->>'job_id' IS NOT NULL));
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- SQL Server: the level of a job's notification (msdb's 0-3) in words
CREATE OR REPLACE FUNCTION pgvigil.mssql_notify_level(p int)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p WHEN 0 THEN NULL WHEN 1 THEN 'when the job succeeds' WHEN 2 THEN 'when the job fails' WHEN 3 THEN 'when the job completes' ELSE p::text END
$$;

-- 0066's import_mssql_jobs with: the failed step on the outcome row; schedule_text; the definition of each job
-- (name, enabled, owner, category, description, start step, notifications, each schedule, each step with its command
-- and database) tracked as versions. payload: 'job', 'step', 'schedule' and 'run' rows, one 'read' row, and from a
-- cursor read one 'cursor' row.
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
    (SELECT jsonb_agg(jsonb_build_object('scheduler', 'sqlagent', 'job_id', r->>'job_id', 'job_name', r->>'name', 'definition',
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
