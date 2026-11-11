-- 0102_pg_jobs_deadlocks: the PostgreSQL twins of DBA Dash's job actions, Running Jobs and job exclusions (task 161;
-- the Deadlocks page reads log_events as they are and needs nothing here).
--
--   1. The actions door gains two PostgreSQL job actions in pgvigil.actions_log: job_stop (pg_cron or pgAgent: the
--      run's backend is cancelled, pid = that backend) and job_start (pgAgent's Run now: jobnextrun = now(), no pid).
--      import_pg_job_actions_log is their audit door (the SQL Server door's shape, 0067: target = the job's name,
--      target_id = '<scheduler>:<job_id>', statement = the statement sent or that would have been sent).
--   2. pgvigil.job_step_runs: pgAgent's step log per run (pga_jobsteplog), one row per step run, written by the
--      collection job_steps through import_job_steps; a running step's row is updated when it ends.
--   3. pgvigil.job_exclusions: pg_cron / pgAgent jobs left out of the job checks by a pattern on the job's name or its
--      command (* any text, ? one character, any case), fleet-wide (level root) or per instance, written through
--      import_job_exclusion; never updated in place but ended, so the table is its own history.
--      pgvigil.job_exclusion(instance, name, command) is the exclusion that takes a job (instance level first), or NULL.
--      The checks that read it: job_status (status 'excluded', reason the pattern), job_report_checks (the Summary's
--      Jobs column and job_report_findings) and job_failures (the overview's 'jobs' check). The grids still list the
--      job and its runs.
--   4. pgvigil.job_status: 0094's, with the exclusions and pgAgent's failed steps (job_step_runs) counted as SQL Server
--      Agent's are; its signature is 0094's.
--   5. pgvigil.pg_jobs_running(instance): the runs the newest read still saw running, with how long they have run,
--      the job's average over its successful runs of 30 days and the estimated end from it, and pgAgent's current step.
--
-- Retention: job_step_runs is kept as job_runs is (purge() deletes it by start_time: the join's line in 0110);
-- job_exclusions holds a row per change and goes with its instance.
-- Lock footprint: actions_log's action CHECK dropped and added again (ACCESS EXCLUSIVE for the validation scan of a
-- small table); the views job_report_checks and job_failures and the function job_status replaced; new tables.

-- ---------------------------------------------------------------------------------------------------------
-- 1. the actions door: job_stop and job_start on PostgreSQL
-- ---------------------------------------------------------------------------------------------------------
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_action_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_action_check CHECK (
     (engine = 'postgres' AND action IN ('cancel', 'terminate', 'explain_analyze', 'hypo_index', 'job_stop', 'job_start'))
  OR (engine = 'sqlserver' AND action IN ('kill', 'job_start', 'job_stop')));

CREATE OR REPLACE FUNCTION pgvigil.import_pg_job_actions_log(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'postgres' THEN
    RAISE EXCEPTION 'import_pg_job_actions_log: instance % is not a PostgreSQL instance', p_instance_id;
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
                                            server_message text)
   WHERE x.action IN ('job_stop', 'job_start');
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- 2. pgAgent's step log per run
-- ---------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.job_step_runs (
  instance_id     int NOT NULL,
  job_id          bigint NOT NULL,           -- pga_jobsteplog's run's jlgjobid
  run_id          bigint NOT NULL,           -- pga_joblog.jlgid (job_runs.run_id of scheduler 'pgagent')
  step_log_id     bigint NOT NULL,           -- pga_jobsteplog.jslid
  step_id         bigint,                    -- pga_jobstep.jstid
  step_name       text,
  status          text,                      -- succeeded | failed | ignored | aborted | running | the letter as read
  result          int,                       -- jslresult
  start_time      timestamptz,
  end_time        timestamptz,
  duration_secs   double precision,
  output          text,                      -- the first 4,000 characters of jsloutput, masked
  snapshot_at     timestamptz NOT NULL,
  PRIMARY KEY (instance_id, step_log_id)
);
CREATE INDEX IF NOT EXISTS job_step_runs_run_idx ON pgvigil.job_step_runs (instance_id, job_id, run_id);
CREATE INDEX IF NOT EXISTS job_step_runs_start_idx ON pgvigil.job_step_runs (instance_id, start_time);
COMMENT ON TABLE pgvigil.job_step_runs IS 'pgAgent''s step log per run (pga_jobsteplog), written by the collection job_steps.';

CREATE OR REPLACE FUNCTION pgvigil.import_job_steps(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  -- a step run is stored once; a running row is updated when it ends
  INSERT INTO pgvigil.job_step_runs AS x (instance_id, job_id, run_id, step_log_id, step_id, step_name, status, result, start_time,
                                          end_time, duration_secs, output, snapshot_at)
  SELECT p_instance_id, (r->>'job_id')::bigint, (r->>'run_id')::bigint, (r->>'step_log_id')::bigint, (r->>'step_id')::bigint,
         r->>'step_name', r->>'status', (r->>'result')::int, (r->>'start_time')::timestamptz, (r->>'end_time')::timestamptz,
         (r->>'duration_secs')::float8, left(r->>'output', 4000), p_snapshot_at
    FROM jsonb_array_elements(coalesce(p_payload, '[]'::jsonb)) r
   WHERE r->>'step_log_id' IS NOT NULL AND r->>'run_id' IS NOT NULL AND r->>'job_id' IS NOT NULL
  ON CONFLICT (instance_id, step_log_id) DO UPDATE SET
    status = EXCLUDED.status, result = EXCLUDED.result, end_time = EXCLUDED.end_time, duration_secs = EXCLUDED.duration_secs,
    output = EXCLUDED.output, step_name = coalesce(EXCLUDED.step_name, x.step_name), snapshot_at = EXCLUDED.snapshot_at
  WHERE x.end_time IS NULL;
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- 3. job exclusions
-- ---------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.job_exclusions (
  exclusion_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  level          text NOT NULL CHECK (level IN ('root', 'instance')),
  instance_id    int REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  match_on       text NOT NULL CHECK (match_on IN ('name', 'command')),
  pattern        text NOT NULL CHECK (length(pattern) BETWEEN 1 AND 300),
  note           text CHECK (length(note) <= 500),
  created_by     text NOT NULL,
  created_at     timestamptz NOT NULL,
  client         text,
  ended_by       text,
  ended_at       timestamptz,
  CONSTRAINT "the root level names no instance" CHECK (level <> 'root' OR instance_id IS NULL),
  CONSTRAINT "an instance level names its instance" CHECK (level <> 'instance' OR instance_id IS NOT NULL)
);
-- one live row per level's place, field and pattern
CREATE UNIQUE INDEX IF NOT EXISTS job_exclusions_live_idx
  ON pgvigil.job_exclusions (level, coalesce(instance_id, 0), match_on, lower(pattern)) WHERE ended_at IS NULL;
COMMENT ON TABLE pgvigil.job_exclusions IS 'pg_cron / pgAgent jobs left out of the job checks by a name or command pattern; written through import_job_exclusion only, ended, never updated.';

-- job_pattern_like: a pattern as LIKE reads it: * any text, ? one character, every other character itself
CREATE OR REPLACE FUNCTION pgvigil.job_pattern_like(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT replace(replace(replace(replace(replace(p, '\', '\\'), '%', '\%'), '_', '\_'), '*', '%'), '?', '_')
$$;

-- job_exclusion: the live exclusion that takes a job, the instance's before the fleet's, as one line; NULL = none
CREATE OR REPLACE FUNCTION pgvigil.job_exclusion(p_instance_id int, p_job_name text, p_command text)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE x.level WHEN 'root' THEN 'every instance' ELSE 'this instance' END || ': ' || x.match_on || ' like ' || x.pattern
    FROM pgvigil.job_exclusions x
   WHERE x.ended_at IS NULL AND (x.level = 'root' OR x.instance_id = p_instance_id)
     AND CASE x.match_on WHEN 'name' THEN coalesce(p_job_name, '') ELSE coalesce(p_command, '') END ILIKE pgvigil.job_pattern_like(x.pattern)
   ORDER BY CASE x.level WHEN 'instance' THEN 1 ELSE 2 END, x.exclusion_id
   LIMIT 1
$$;

-- import_job_exclusion: one attempt from the UI. p_payload: {op: add | end, level, instance_id, match_on, pattern, note,
-- exclusion_id (end), ui_user, client}. Answers {outcome: done | refused, detail, exclusion_id}; a refused attempt
-- writes nothing.
CREATE OR REPLACE FUNCTION pgvigil.import_job_exclusion(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op     text := p_payload->>'op';
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_level  text := p_payload->>'level';
  v_match  text := coalesce(p_payload->>'match_on', 'name');
  v_pat    text := nullif(btrim(coalesce(p_payload->>'pattern', '')), '');
  v_note   text := nullif(btrim(coalesce(p_payload->>'note', '')), '');
  v_inst   int;
  v_id     bigint;
  v_new    bigint;
  v_why    text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_job_exclusion: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN
    v_inst := (p_payload->>'instance_id')::int;
  END IF;
  IF coalesce(p_payload->>'exclusion_id', '') ~ '^[0-9]{1,18}$' THEN
    v_id := (p_payload->>'exclusion_id')::bigint;
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('add', 'end') THEN
    v_why := 'op must be add or end';
  ELSIF v_op = 'end' THEN
    IF v_id IS NULL THEN
      v_why := 'end names the exclusion_id';
    ELSIF NOT EXISTS (SELECT 1 FROM pgvigil.job_exclusions x WHERE x.exclusion_id = v_id AND x.ended_at IS NULL) THEN
      v_why := format('no live exclusion %s', v_id);
    END IF;
  ELSIF v_level IS NULL OR v_level NOT IN ('root', 'instance') THEN
    v_why := 'level must be root or instance';
  ELSIF v_level = 'instance' AND (v_inst IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = v_inst AND i.engine = 'postgres')) THEN
    v_why := format('no PostgreSQL instance %s', coalesce(p_payload->>'instance_id', '(none)'));
  ELSIF v_match NOT IN ('name', 'command') THEN
    v_why := 'match_on must be name or command';
  ELSIF v_pat IS NULL OR length(v_pat) > 300 THEN
    v_why := 'a pattern of 1 to 300 characters is required (* any text, ? one character)';
  ELSIF v_pat ~ '^[*?]*$' THEN
    v_why := 'a pattern of wildcards alone would leave every job out of the checks: name a part of the name or the command';
  ELSIF v_note IS NOT NULL AND length(v_note) > 500 THEN
    v_why := 'the note is longer than 500 characters';
  END IF;
  IF v_why IS NULL AND v_op = 'add' THEN
    IF v_level = 'root' THEN v_inst := NULL; END IF;
    PERFORM pg_advisory_xact_lock(hashtext('pgvigil.job_exclusions'), hashtext(v_level || '|' || coalesce(v_inst, 0) || '|' || v_match || '|' || lower(v_pat)));
    IF EXISTS (SELECT 1 FROM pgvigil.job_exclusions x
                WHERE x.ended_at IS NULL AND x.level = v_level AND coalesce(x.instance_id, 0) = coalesce(v_inst, 0)
                  AND x.match_on = v_match AND lower(x.pattern) = lower(v_pat)) THEN
      v_why := 'this exclusion is in force already';
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_op = 'end' THEN
    UPDATE pgvigil.job_exclusions SET ended_by = v_user, ended_at = p_at WHERE exclusion_id = v_id AND ended_at IS NULL;
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'ended: the job checks take these jobs again', 'exclusion_id', v_id);
  END IF;
  INSERT INTO pgvigil.job_exclusions (level, instance_id, match_on, pattern, note, created_by, created_at, client)
  VALUES (v_level, v_inst, v_match, v_pat, v_note, v_user, p_at, nullif(p_payload->>'client', ''))
  RETURNING exclusion_id INTO v_new;
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'added', 'exclusion_id', v_new);
END $$;

-- job_exclusion_rows: the live exclusions an instance's jobs can take, and the jobs each one takes now
CREATE OR REPLACE FUNCTION pgvigil.job_exclusion_rows(p_instance_id int)
RETURNS TABLE (exclusion_id bigint, level text, match_on text, pattern text, note text, created_by text, created_at timestamptz,
               jobs_taken bigint, jobs text)
LANGUAGE sql STABLE AS $$
  SELECT x.exclusion_id, x.level, x.match_on, x.pattern, x.note, x.created_by, x.created_at,
         count(j.job_id), string_agg(coalesce(j.job_name, j.job_id::text), ', ' ORDER BY j.job_name) FILTER (WHERE j.job_id IS NOT NULL)
    FROM pgvigil.job_exclusions x
    LEFT JOIN pgvigil.jobs j ON j.instance_id = p_instance_id AND j.is_present
         AND CASE x.match_on WHEN 'name' THEN coalesce(j.job_name, '') ELSE coalesce(j.command, '') END ILIKE pgvigil.job_pattern_like(x.pattern)
   WHERE x.ended_at IS NULL AND (x.level = 'root' OR x.instance_id = p_instance_id)
   GROUP BY x.exclusion_id
   ORDER BY CASE x.level WHEN 'instance' THEN 1 ELSE 2 END, x.exclusion_id
$$;

-- the checks without the excluded jobs: the overview's 'jobs' check (0009's view) and the job report's (0027's view)
CREATE OR REPLACE VIEW pgvigil.job_failures AS
  SELECT r.instance_id, r.scheduler, r.job_id, j.job_name, r.run_id, r.status, r.return_message, r.start_time, r.end_time, r.duration_secs
    FROM pgvigil.job_runs r
    LEFT JOIN pgvigil.jobs j ON j.instance_id = r.instance_id AND j.scheduler = r.scheduler AND j.job_id = r.job_id
   WHERE r.start_time > now() - interval '1 day'
     AND r.status IN ('failed', 'internal error', 'aborted')
     AND pgvigil.job_exclusion(r.instance_id, j.job_name, coalesce(j.command, r.command)) IS NULL;

CREATE OR REPLACE VIEW pgvigil.job_report_checks AS
WITH r AS (
  SELECT *, scheduler || ' ' || coalesce(job_name, job_id::text) AS object
    FROM pgvigil.job_report
   WHERE is_present AND coalesce(active, true)
     AND pgvigil.job_exclusion(instance_id, job_name, command) IS NULL
)
SELECT instance_id, 'critical' AS severity, 'job failing repeatedly' AS check_name, object, last_start AS at,
       'failed ' || fail_streak::text || ' times in a row; '
       || coalesce('last success ' || to_char(last_ok AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'no success in 30 days')
       || coalesce(': ' || left(last_message, 200), '') AS detail
  FROM r WHERE fail_streak >= 3
UNION ALL
SELECT instance_id, 'warning', 'job run over twice its average', object, last_start,
       CASE WHEN last_running THEN 'running for ' ELSE 'the run took ' END || last_duration_secs::text || ' s (started '
       || to_char(last_start AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC) against an average of ' || base_avg_secs::text
       || ' s over ' || base_runs::text || ' successful runs in 30 days'
  FROM r WHERE over_average
UNION ALL
SELECT instance_id, 'critical', 'job schedule missed', object, coalesce(prior_due, next_run),
       CASE WHEN scheduler = 'pg_cron'
            THEN 'no run since ' || to_char(prior_due AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC: two scheduled runs of '''
                 || schedule || ''' went by without one; last run ' || coalesce(to_char(last_start AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'none in 30 days')
                 || CASE WHEN last_running THEN ', its row still says running over a day later (left behind by a crashed or restarted launcher?)' ELSE '' END
                 || ' (is pg_cron running, cron.database_name right, the job''s node reachable?)'
            ELSE 'pgAgent''s next run ' || to_char(next_run AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC is past and the job has not started: is the pgAgent service running?' END
  FROM r WHERE missed;

-- ---------------------------------------------------------------------------------------------------------
-- 4. job_status: 0094's, with the exclusions and pgAgent's failed steps
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgvigil.job_status(p_instance_id int)
RETURNS TABLE (scheduler text, job_id text, job_name text, level text, threshold_id bigint, fail_24h bigint, fail_7d bigint,
               step_fail_24h bigint, step_fail_7d bigint, last_failed_at timestamptz, last_succeeded_at timestamptz,
               last_outcome text, status text, reason text)
LANGUAGE sql STABLE AS $$
  WITH j AS (
    SELECT 'sqlagent'::text AS scheduler, m.job_id, m.name AS job_name,
           CASE m.last_outcome WHEN 0 THEN 'failed' WHEN 1 THEN 'succeeded' WHEN 2 THEN 'retry' WHEN 3 THEN 'cancelled' END AS last_outcome,
           c.fail_24h, c.fail_7d, c.step_fail_24h, c.step_fail_7d, lf.at AS last_failed_at, ls.at AS last_succeeded_at, fr.at AS first_run_at,
           NULL::text AS excluded_by
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
           lr.outcome, c.fail_24h, c.fail_7d, coalesce(sf.step_fail_24h, 0), coalesce(sf.step_fail_7d, 0), lf.at, ls.at, fr.at,
           pgvigil.job_exclusion(g.instance_id, g.job_name, g.command)
      FROM pgvigil.jobs g
      LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE r.start_time > now() - interval '24 hours') AS fail_24h, count(*) AS fail_7d
                           FROM pgvigil.job_runs r
                          WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id
                            AND r.status IN ('failed', 'internal error')
                            AND r.start_time > now() - interval '7 days' AND r.start_time <= now()) c ON true
      -- pgAgent's failed steps (0102's step log); pg_cron has no steps
      LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE s.start_time > now() - interval '24 hours') AS step_fail_24h, count(*) AS step_fail_7d
                           FROM pgvigil.job_step_runs s
                          WHERE g.scheduler = 'pgagent' AND s.instance_id = g.instance_id AND s.job_id = g.job_id AND s.status = 'failed'
                            AND s.start_time > now() - interval '7 days' AND s.start_time <= now()) sf ON true
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
         CASE WHEN e.excluded_by IS NOT NULL THEN 'excluded'
              ELSE coalesce(b.sev, CASE WHEN num_nonnulls(e.fail_24h_warn, e.fail_24h_crit, e.fail_7d_warn, e.fail_7d_crit, e.step_fail_24h_warn,
                                                e.step_fail_24h_crit, e.step_fail_7d_warn, e.step_fail_7d_crit, e.since_fail_warn_min,
                                                e.since_fail_crit_min, e.since_ok_warn_min, e.since_ok_crit_min, e.last_fail_is) > 0
                              THEN 'ok' ELSE 'none' END) END,
         CASE WHEN e.excluded_by IS NOT NULL THEN 'left out of the job checks (' || e.excluded_by || ')' ELSE b.why END
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
       WHERE v.broken AND e.excluded_by IS NULL
       ORDER BY v.ord LIMIT 1) b ON true
   ORDER BY e.scheduler, e.job_name
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 5. Running now
-- ---------------------------------------------------------------------------------------------------------
-- pg_jobs_running: every pg_cron / pgAgent run of an instance that the newest read of its job still saw running (the
-- collector reads a run without an end on every read, so its snapshot_at follows the job's); running_secs from its
-- start to now; the average, count and longest of the job's successful runs in 30 days; the estimated end = the start
-- plus that average (none without a successful run); over_average as the job report's rule (3 runs or more, over
-- twice the average and 10 s more); pgAgent's step running now (0102's step log).
CREATE OR REPLACE FUNCTION pgvigil.pg_jobs_running(p_instance_id int)
RETURNS TABLE (scheduler text, job_id bigint, job_name text, run_id bigint, job_pid int, datname text, run_as text, command text,
               status text, start_time timestamptz, running_secs double precision, avg_secs double precision, ok_runs bigint,
               max_secs double precision, estimated_end timestamptz, over_average boolean, current_step text,
               current_step_start timestamptz, read_at timestamptz, active boolean, excluded_by text)
LANGUAGE sql STABLE AS $$
  SELECT r.scheduler, r.job_id, coalesce(j.job_name, r.job_id::text), r.run_id, r.job_pid, coalesce(r.datname, j.datname),
         coalesce(r.run_as, j.run_as), coalesce(r.command, j.command), r.status, r.start_time,
         round(extract(epoch FROM now() - r.start_time)::numeric, 1)::float8,
         round(a.avg_secs::numeric, 1)::float8, coalesce(a.n, 0), round(a.max_secs::numeric, 1)::float8,
         CASE WHEN a.n > 0 THEN r.start_time + make_interval(secs => a.avg_secs) END,
         coalesce(a.n >= 3 AND extract(epoch FROM now() - r.start_time) > greatest(2 * a.avg_secs, a.avg_secs + 10), false),
         st.step_name, st.start_time, r.snapshot_at, j.active,
         pgvigil.job_exclusion(r.instance_id, j.job_name, coalesce(j.command, r.command))
    FROM pgvigil.job_runs r
    JOIN pgvigil.jobs j ON j.instance_id = r.instance_id AND j.scheduler = r.scheduler AND j.job_id = r.job_id
    LEFT JOIN LATERAL (SELECT avg(x.duration_secs) AS avg_secs, count(*) AS n, max(x.duration_secs) AS max_secs
                         FROM pgvigil.job_runs x
                        WHERE x.instance_id = r.instance_id AND x.scheduler = r.scheduler AND x.job_id = r.job_id
                          AND x.status = 'succeeded' AND x.duration_secs IS NOT NULL
                          AND x.start_time > now() - interval '30 days' AND x.run_id <> r.run_id) a ON true
    LEFT JOIN LATERAL (SELECT s.step_name, s.start_time FROM pgvigil.job_step_runs s
                        WHERE r.scheduler = 'pgagent' AND s.instance_id = r.instance_id AND s.run_id = r.run_id AND s.end_time IS NULL
                        ORDER BY s.start_time DESC LIMIT 1) st ON true
   WHERE r.instance_id = p_instance_id AND r.end_time IS NULL
     AND r.status NOT IN ('succeeded', 'failed', 'internal error', 'aborted')
     AND j.is_present AND r.snapshot_at >= j.snapshot_at - interval '1 second'
   ORDER BY r.start_time
$$;

SELECT pgvigil.apply_roles();
