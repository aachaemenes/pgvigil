-- 0027_jobs_report: the job report (phase 2, task 38; DBADash's Jobs tab) over the jobs collection's tables (0009).
--   1. two columns the collector fills from its own pg_cron schedule parser (internal/collect/cronnext.go):
--      prior_due (the scheduled time before the latest one at the read) and schedule_note (a schedule it
--      could not parse, @reboot, or an unknown cron.timezone); next_run, NULL in cron.job, is filled by the
--      same parser; pgAgent's next run is its own (pga_job.jobnextrun). import_jobs is re-created to store them.
--   2. job_report: per job its last run, the runs, failures, average and maximum duration over 7 and 30 days,
--      the failures in a row, the last run against the average of the others, and the missed schedule
--   3. job_report_checks (the overview's "jobs report" check, the Summary column Jobs) and job_report_findings
--      (the ten columns the join UNIONs into pgvigil.findings)
--   4. retention: nothing new (job_runs is already purged by start_time; a job row stays while present)
--
-- The rules:
--   failing repeatedly  the last 3 or more finished runs failed (failed, internal error, aborted) with no
--                       success after them (within 30 days)
--   over its average    the latest run, when it succeeded or is still running (a running one by its age),
--                       took over twice the average of the job's other finished successful runs of 30 days
--                       (3 or more of them) and at least 10 s more (a failed run is the 'jobs' check's)
--   missed              pg_cron: no run started at or after prior_due (30 s of slack): two scheduled runs
--                       went by without one; only for an active, present job seen before prior_due, no run
--                       going (a running row under a day old: an older one is taken as left behind by a
--                       crashed launcher, and the job is judged), and prior_due within 25 days (the history
--                       kept is 30 days, so a schedule rarer than about every 12 days is not judged);
--                       pgAgent: its own next run is over 5 minutes past at the read (the agent did not pick
--                       the job up; no next run = not judged)

-- ---------------------------------------------------------------------------------------------------------
-- 1. the parser's columns
-- ---------------------------------------------------------------------------------------------------------
ALTER TABLE pgvigil.jobs ADD COLUMN IF NOT EXISTS prior_due timestamptz;
ALTER TABLE pgvigil.jobs ADD COLUMN IF NOT EXISTS schedule_note text;

-- the report reads each job's runs by start time
CREATE INDEX IF NOT EXISTS job_runs_job_start_idx ON pgvigil.job_runs (instance_id, scheduler, job_id, start_time);

-- 0009's body with prior_due and schedule_note
CREATE OR REPLACE FUNCTION pgvigil.import_jobs(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
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
                                     return_message, start_time, end_time, duration_secs, snapshot_at)
  SELECT p_instance_id, r->>'scheduler', (r->>'job_id')::bigint, (r->>'run_id')::bigint, (r->>'job_pid')::int, r->>'datname',
         r->>'run_as', r->>'command', r->>'status', r->>'return_message', (r->>'start_time')::timestamptz,
         (r->>'end_time')::timestamptz, (r->>'duration_secs')::float8, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'run' AND r->>'run_id' IS NOT NULL
  ON CONFLICT (instance_id, scheduler, job_id, run_id) DO UPDATE SET
    status = EXCLUDED.status, return_message = EXCLUDED.return_message, end_time = EXCLUDED.end_time,
    duration_secs = EXCLUDED.duration_secs, snapshot_at = EXCLUDED.snapshot_at
  WHERE x.end_time IS NULL;
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- 2. the report
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW pgvigil.job_report AS
SELECT j.instance_id, i.name AS instance, i.platform, j.scheduler, j.job_id, j.job_name, j.schedule, j.command, j.datname, j.run_as,
       j.active, j.is_present, j.next_run, j.prior_due, j.schedule_note, j.snapshot_at, j.first_seen,
       lr.run_id AS last_run_id, lr.status AS last_status, lr.start_time AS last_start, lr.end_time AS last_end,
       round(CASE WHEN lr.running THEN extract(epoch FROM now() - lr.start_time) ELSE lr.duration_secs END::numeric, 1) AS last_duration_secs,
       coalesce(lr.running, false) AS last_running, left(lr.return_message, 500) AS last_message,
       coalesce(a.runs_7d, 0) AS runs_7d, coalesce(a.failures_7d, 0) AS failures_7d, a.avg_7d_secs, a.max_7d_secs,
       coalesce(a.runs_30d, 0) AS runs_30d, coalesce(a.failures_30d, 0) AS failures_30d, a.avg_30d_secs, a.max_30d_secs,
       a.last_ok, coalesce(fs.n, 0) AS fail_streak, a.base_n AS base_runs, round(a.base_avg::numeric, 1) AS base_avg_secs,
       coalesce((lr.running OR lr.status = 'succeeded') AND a.base_n >= 3
                AND CASE WHEN lr.running THEN extract(epoch FROM now() - lr.start_time) ELSE lr.duration_secs END
                    > greatest(2 * a.base_avg, a.base_avg + 10), false) AS over_average,
       coalesce(CASE WHEN NOT j.is_present OR NOT coalesce(j.active, true)
                          OR (lr.running AND lr.start_time > now() - interval '1 day') THEN false
            WHEN j.scheduler = 'pg_cron' THEN
                 j.schedule_note IS NULL AND j.prior_due IS NOT NULL AND j.prior_due > j.first_seen
                 AND j.prior_due > now() - interval '25 days'
                 AND NOT EXISTS (SELECT 1 FROM pgvigil.job_runs x
                                  WHERE x.instance_id = j.instance_id AND x.scheduler = j.scheduler AND x.job_id = j.job_id
                                    AND x.start_time >= j.prior_due - interval '30 seconds')
            WHEN j.scheduler = 'pgagent' THEN j.next_run < j.snapshot_at - interval '5 minutes'
            ELSE false END, false) AS missed
  FROM pgvigil.jobs j
  JOIN pgvigil.instances i USING (instance_id)
  LEFT JOIN LATERAL (SELECT r.run_id, r.status, r.start_time, r.end_time, r.duration_secs, r.return_message,
                            r.end_time IS NULL AND r.status NOT IN ('succeeded', 'failed', 'internal error', 'aborted') AS running
                       FROM pgvigil.job_runs r
                      WHERE r.instance_id = j.instance_id AND r.scheduler = j.scheduler AND r.job_id = j.job_id
                        AND r.start_time IS NOT NULL
                      ORDER BY r.start_time DESC LIMIT 1) lr ON true
  LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE r.start_time > now() - interval '7 days') AS runs_7d,
                            count(*) FILTER (WHERE r.start_time > now() - interval '7 days'
                                               AND r.status IN ('failed', 'internal error', 'aborted')) AS failures_7d,
                            round(avg(r.duration_secs) FILTER (WHERE r.start_time > now() - interval '7 days')::numeric, 1) AS avg_7d_secs,
                            round(max(r.duration_secs) FILTER (WHERE r.start_time > now() - interval '7 days')::numeric, 1) AS max_7d_secs,
                            count(*) AS runs_30d,
                            count(*) FILTER (WHERE r.status IN ('failed', 'internal error', 'aborted')) AS failures_30d,
                            round(avg(r.duration_secs)::numeric, 1) AS avg_30d_secs,
                            round(max(r.duration_secs)::numeric, 1) AS max_30d_secs,
                            max(r.start_time) FILTER (WHERE r.status = 'succeeded') AS last_ok,
                            -- the base of over_average: the other finished successful runs
                            count(*) FILTER (WHERE r.status = 'succeeded' AND r.duration_secs IS NOT NULL
                                               AND r.run_id IS DISTINCT FROM lr.run_id) AS base_n,
                            avg(r.duration_secs) FILTER (WHERE r.status = 'succeeded' AND r.duration_secs IS NOT NULL
                                                           AND r.run_id IS DISTINCT FROM lr.run_id) AS base_avg
                       FROM pgvigil.job_runs r
                      WHERE r.instance_id = j.instance_id AND r.scheduler = j.scheduler AND r.job_id = j.job_id
                        AND r.start_time > now() - interval '30 days') a ON true
  LEFT JOIN LATERAL (SELECT count(*) AS n FROM pgvigil.job_runs r
                      WHERE r.instance_id = j.instance_id AND r.scheduler = j.scheduler AND r.job_id = j.job_id
                        AND r.start_time > coalesce(a.last_ok, now() - interval '30 days')
                        AND r.status IN ('failed', 'internal error', 'aborted')) fs ON true;

-- ---------------------------------------------------------------------------------------------------------
-- 3. the checks and the findings
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW pgvigil.job_report_checks AS
WITH r AS (
  SELECT *, scheduler || ' ' || coalesce(job_name, job_id::text) AS object
    FROM pgvigil.job_report
   WHERE is_present AND coalesce(active, true)
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

CREATE OR REPLACE VIEW pgvigil.job_report_findings AS
SELECT c.instance_id, c.severity, c.check_name AS setting, c.object AS value, true AS is_set,
       CASE c.check_name
         WHEN 'job failing repeatedly' THEN 'a successful run'
         WHEN 'job run over twice its average' THEN 'within twice its average'
         ELSE 'a run at every scheduled time' END AS suggested,
       'all' AS platforms, c.detail, 'pgvigil' AS source, c.at
  FROM pgvigil.job_report_checks c;

-- ---------------------------------------------------------------------------------------------------------
-- 4. retention: no new table; pgvigil.purge() already deletes job_runs by start_time (0009) and keeps its
--    shape (the join takes nothing from here).
-- ---------------------------------------------------------------------------------------------------------
