-- 0137: one judge of a job for every page, and a read of it a fleet can afford (the fleet Jobs page's 'Job status'
-- grid, the Summary's Agent Jobs cell, the instance tab). Everything is read from rows the collectors already store;
-- nothing is created, changed or switched on on a monitored server.
--
--   the rule with no threshold row   DBA Dash 4.24.1's default (its root AgentJobThresholds row: TimeSinceLastFailureCritical
--                        60, TimeSinceLastFailureWarning 10080 minutes, LastFailIsCritical 1): critical when the job's
--                        last run failed or a run failed in the last 60 minutes, warning when a run failed in the last 7
--                        days. Before this file the rule was 'critical only when the last run failed', so a job that
--                        failed at 08:00 and succeeded at 09:00 read 'ok' at 10:00; it reads 'warn' now, for 7 days. A
--                        threshold row at any level (root, instance, job) still replaces the default whole, as before.
--   a cancelled run is a failure   as in DBA Dash 4.24.1 (JobHistory_Upd's LastFailed and StepLastFailed, JobStats_RAW's
--                        FailedCount: run_status IN (0,3)): a SQL Agent run or step with run_status 0 (failed) or 3
--                        (cancelled), a PostgreSQL run 'failed', 'internal error' or 'aborted', a pgAgent step 'failed'
--                        or 'aborted' counts in the last failure, the 24 h / 7 d counts and 'the last run failed' (a
--                        last run that was cancelled reads 'the last run was cancelled'). Before this file 0102 counted
--                        run_status 0 and 'failed' / 'internal error' only.
--   job_status_view(p_ids int[])    0102's job_status for a set of instances in one statement, one row per job with
--                        its instance_id first and horizon_min last. The last failure and the last success are looked
--                        for inside a horizon H = the longest 'since' threshold in force for those instances (the root
--                        row, their instance rows, their job rows), at least 7 days (the default's own warning span)
--                        and at most 400 days: no threshold can judge a failure or a success older than its own span,
--                        so a run older than H changes no verdict. A job with no failure (no success) inside H has
--                        last_failed_at (last_succeeded_at) NULL: the pages say 'none in the last <H>', never 'never'.
--                        'No success for N minutes' is still judged past H: a job that ran before H and has no success
--                        inside it breaks the rule, and its reason says 'no success in the last <H>'.
--   job_status(p_instance_id)       unchanged in name, arguments and columns: job_status_view of that one instance.
--   two partial indexes hold the failed and cancelled rows by job, newest first (mssql_job_runs: steps too; job_runs), so the last
--                        failure and the failed counts are a probe and not a walk of a job's every stored row. The
--                        last success needs none: a job's newest rows are its last run's, so the index by job finds it
--                        in a few rows (measured on a synthetic store: the view read the same with and without an
--                        index of the succeeded rows, which would be written on every job row); a job with no success
--                        walks its own rows inside H, no more.
--
-- Locks, and what an upgrade waits for: CREATE INDEX holds SHARE on its table until this file's transaction commits
-- (a migration file runs in one transaction, so the builds cannot be CONCURRENTLY): reads go on, the jobs collections'
-- writes of mssql_job_runs (every partition) and of job_runs wait for the builds and are stored by their next run
-- (the collectors read msdb and the PostgreSQL schedulers again from their cursor: nothing is lost). The builds scan
-- every stored job run once; on a large store that is the time 'pgvigil migrate' takes on this file (the upgrade notes
-- give a measured figure). mssql_job_runs first, then job_runs: the order purge() takes them (its partition drops, then
-- its deletes), so no wait can close a ring with it. lock_timeout bounds each lock's wait, not the file's.
--
-- Partition parents for purge(): none new. Findings: none new.
SET LOCAL lock_timeout = '20s';

CREATE INDEX IF NOT EXISTS mssql_job_runs_failed_idx ON pgvigil.mssql_job_runs (instance_id, job_id, snapshot_at DESC)
  WHERE run_status IN (0, 3);
CREATE INDEX IF NOT EXISTS job_runs_failed_idx ON pgvigil.job_runs (instance_id, scheduler, job_id, start_time DESC)
  WHERE status IN ('failed', 'internal error', 'aborted');

CREATE OR REPLACE FUNCTION pgvigil.job_status_view(p_ids int[])
RETURNS TABLE (instance_id int, scheduler text, job_id text, job_name text, level text, threshold_id bigint, fail_24h bigint, fail_7d bigint,
               step_fail_24h bigint, step_fail_7d bigint, last_failed_at timestamptz, last_succeeded_at timestamptz,
               last_outcome text, status text, reason text, horizon_min int)
LANGUAGE sql STABLE AS $$
  WITH h AS MATERIALIZED (
    -- H in minutes: 7 days (10080) at least, 400 days (576000) at most
    SELECT least(576000, greatest(10080, coalesce(max(greatest(coalesce(t.since_fail_warn_min, 0), coalesce(t.since_fail_crit_min, 0),
                                                                 coalesce(t.since_ok_warn_min, 0), coalesce(t.since_ok_crit_min, 0))), 0)))::int AS mins
      FROM pgvigil.job_thresholds t
     WHERE t.ended_at IS NULL AND (t.level = 'root' OR t.instance_id = ANY(p_ids))
  ), j AS (
    SELECT m.instance_id, 'sqlagent'::text AS scheduler, m.job_id, m.name AS job_name,
           CASE m.last_outcome WHEN 0 THEN 'failed' WHEN 1 THEN 'succeeded' WHEN 2 THEN 'retry' WHEN 3 THEN 'cancelled' END AS last_outcome,
           c.fail_24h, c.fail_7d, c.step_fail_24h, c.step_fail_7d, lf.at AS last_failed_at, ls.at AS last_succeeded_at, fr.at AS first_run_at,
           NULL::text AS excluded_by
      FROM pgvigil.mssql_jobs m
      -- the failed and cancelled rows of 7 days: mssql_job_runs_failed_idx
      LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE r.step_id = 0 AND r.snapshot_at > now() - interval '24 hours') AS fail_24h,
                                count(*) FILTER (WHERE r.step_id = 0) AS fail_7d,
                                count(*) FILTER (WHERE r.step_id > 0 AND r.snapshot_at > now() - interval '24 hours') AS step_fail_24h,
                                count(*) FILTER (WHERE r.step_id > 0) AS step_fail_7d
                           FROM pgvigil.mssql_job_runs r
                          WHERE r.instance_id = m.instance_id AND r.job_id = m.job_id AND r.run_status IN (0, 3)
                            AND r.snapshot_at > now() - interval '7 days' AND r.snapshot_at <= now()) c ON true
      -- the newest failed or cancelled job row inside H: mssql_job_runs_failed_idx
      LEFT JOIN LATERAL (SELECT r.snapshot_at AS at FROM pgvigil.mssql_job_runs r
                          WHERE r.instance_id = m.instance_id AND r.job_id = m.job_id AND r.step_id = 0 AND r.run_status IN (0, 3)
                            AND r.snapshot_at > now() - make_interval(mins => (SELECT h.mins FROM h))
                          ORDER BY r.snapshot_at DESC LIMIT 1) lf ON true
      -- the newest succeeded job row inside H: the job's newest rows in mssql_job_runs_job_idx
      LEFT JOIN LATERAL (SELECT r.snapshot_at AS at FROM pgvigil.mssql_job_runs r
                          WHERE r.instance_id = m.instance_id AND r.job_id = m.job_id AND r.step_id = 0 AND r.run_status = 1
                            AND r.snapshot_at > now() - make_interval(mins => (SELECT h.mins FROM h))
                          ORDER BY r.snapshot_at DESC LIMIT 1) ls ON true
      -- the job's first stored run: the first row of mssql_job_runs_job_idx (a job row is its run's oldest row)
      LEFT JOIN LATERAL (SELECT r.snapshot_at AS at FROM pgvigil.mssql_job_runs r
                          WHERE r.instance_id = m.instance_id AND r.job_id = m.job_id AND r.step_id = 0
                          ORDER BY r.snapshot_at LIMIT 1) fr ON true
     WHERE m.instance_id = ANY(p_ids)
    UNION ALL
    SELECT g.instance_id, g.scheduler, g.job_id::text, coalesce(g.job_name, g.job_id::text),
           lr.outcome, c.fail_24h, c.fail_7d, coalesce(sf.step_fail_24h, 0), coalesce(sf.step_fail_7d, 0), lf.at, ls.at, fr.at,
           pgvigil.job_exclusion(g.instance_id, coalesce(g.job_name, g.job_id::text), g.command)
      FROM pgvigil.jobs g
      -- the failed and aborted runs of 7 days: job_runs_failed_idx
      LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE r.start_time > now() - interval '24 hours') AS fail_24h, count(*) AS fail_7d
                           FROM pgvigil.job_runs r
                          WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id
                            AND r.status IN ('failed', 'internal error', 'aborted')
                            AND r.start_time > now() - interval '7 days' AND r.start_time <= now()) c ON true
      -- pgAgent's failed and aborted steps (0102's step log); pg_cron has no steps
      LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE s.start_time > now() - interval '24 hours') AS step_fail_24h, count(*) AS step_fail_7d
                           FROM pgvigil.job_step_runs s
                          WHERE g.scheduler = 'pgagent' AND s.instance_id = g.instance_id AND s.job_id = g.job_id AND s.status IN ('failed', 'aborted')
                            AND s.start_time > now() - interval '7 days' AND s.start_time <= now()) sf ON true
      -- the newest run that has a start: the last row of job_runs_job_start_idx (0102 sorted a job's every run for it)
      LEFT JOIN LATERAL (SELECT CASE WHEN r.status = 'succeeded' THEN 'succeeded' WHEN r.status IN ('failed', 'internal error') THEN 'failed'
                                     WHEN r.status = 'aborted' THEN 'cancelled' WHEN r.end_time IS NULL THEN 'running' ELSE r.status END AS outcome
                           FROM pgvigil.job_runs r
                          WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id AND r.start_time IS NOT NULL
                          ORDER BY r.start_time DESC LIMIT 1) lr ON true
      -- the newest failed or aborted run inside H: job_runs_failed_idx
      LEFT JOIN LATERAL (SELECT r.start_time AS at FROM pgvigil.job_runs r
                          WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id
                            AND r.status IN ('failed', 'internal error', 'aborted')
                            AND r.start_time > now() - make_interval(mins => (SELECT h.mins FROM h))
                          ORDER BY r.start_time DESC LIMIT 1) lf ON true
      -- the newest succeeded run inside H: the job's newest rows in job_runs_job_start_idx
      LEFT JOIN LATERAL (SELECT r.start_time AS at FROM pgvigil.job_runs r
                          WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id
                            AND r.status = 'succeeded'
                            AND r.start_time > now() - make_interval(mins => (SELECT h.mins FROM h))
                          ORDER BY r.start_time DESC LIMIT 1) ls ON true
      -- the job's first stored run: the first row of job_runs_job_start_idx
      LEFT JOIN LATERAL (SELECT r.start_time AS at FROM pgvigil.job_runs r
                          WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id AND r.start_time IS NOT NULL
                          ORDER BY r.start_time LIMIT 1) fr ON true
     WHERE g.instance_id = ANY(p_ids) AND g.is_present
  ), e AS (
    SELECT j.*, t.threshold_id, coalesce(t.level, 'default') AS level,
           t.fail_24h_warn, t.fail_24h_crit, t.fail_7d_warn, t.fail_7d_crit, t.step_fail_24h_warn, t.step_fail_24h_crit,
           t.step_fail_7d_warn, t.step_fail_7d_crit, t.since_ok_warn_min, t.since_ok_crit_min,
           -- no threshold row at any level: DBA Dash's default row
           CASE WHEN t.threshold_id IS NULL THEN 10080 ELSE t.since_fail_warn_min END AS since_fail_warn_min,
           CASE WHEN t.threshold_id IS NULL THEN 60 ELSE t.since_fail_crit_min END AS since_fail_crit_min,
           CASE WHEN t.threshold_id IS NULL THEN 'crit' ELSE t.last_fail_is END AS last_fail_is,
           extract(epoch FROM now() - j.last_failed_at) / 60 AS fail_min,
           extract(epoch FROM now() - coalesce(j.last_succeeded_at, j.first_run_at)) / 60 AS ok_min,
           -- no success inside H for a job that ran before it: the minutes since its first run are not 'since a success'
           j.last_succeeded_at IS NULL AND j.first_run_at <= now() - make_interval(mins => (SELECT h.mins FROM h)) AS ok_past
      FROM j
      LEFT JOIN LATERAL (SELECT t.* FROM pgvigil.job_thresholds t
                          WHERE t.ended_at IS NULL
                            AND (t.level = 'root' OR (t.instance_id = j.instance_id AND (t.level = 'instance' OR t.job_name = j.job_name)))
                          ORDER BY CASE t.level WHEN 'job' THEN 1 WHEN 'instance' THEN 2 ELSE 3 END LIMIT 1) t ON true
  )
  SELECT e.instance_id, e.scheduler, e.job_id, e.job_name, e.level, e.threshold_id, e.fail_24h, e.fail_7d, e.step_fail_24h, e.step_fail_7d,
         e.last_failed_at, e.last_succeeded_at, e.last_outcome,
         CASE WHEN e.excluded_by IS NOT NULL THEN 'excluded'
              ELSE coalesce(b.sev, CASE WHEN num_nonnulls(e.fail_24h_warn, e.fail_24h_crit, e.fail_7d_warn, e.fail_7d_crit, e.step_fail_24h_warn,
                                                e.step_fail_24h_crit, e.step_fail_7d_warn, e.step_fail_7d_crit, e.since_fail_warn_min,
                                                e.since_fail_crit_min, e.since_ok_warn_min, e.since_ok_crit_min, e.last_fail_is) > 0
                              THEN 'ok' ELSE 'none' END) END,
         CASE WHEN e.excluded_by IS NOT NULL THEN 'left out of the job checks (' || e.excluded_by || ')' ELSE b.why END,
         (SELECT h.mins FROM h)
    FROM e
    LEFT JOIN LATERAL (
      SELECT v.sev, v.why
        FROM (VALUES
          (1, 'crit', e.last_outcome IN ('failed', 'cancelled') AND e.last_fail_is = 'crit',
              CASE e.last_outcome WHEN 'cancelled' THEN 'the last run was cancelled' ELSE 'the last run failed' END),
          (2, 'crit', e.fail_24h >= e.fail_24h_crit, format('%s failed run(s) in 24 hours (critical at %s)', e.fail_24h, e.fail_24h_crit)),
          (3, 'crit', e.fail_7d >= e.fail_7d_crit, format('%s failed run(s) in 7 days (critical at %s)', e.fail_7d, e.fail_7d_crit)),
          (4, 'crit', e.step_fail_24h >= e.step_fail_24h_crit, format('%s failed step(s) in 24 hours (critical at %s)', e.step_fail_24h, e.step_fail_24h_crit)),
          (5, 'crit', e.step_fail_7d >= e.step_fail_7d_crit, format('%s failed step(s) in 7 days (critical at %s)', e.step_fail_7d, e.step_fail_7d_crit)),
          (6, 'crit', e.fail_min <= e.since_fail_crit_min, format('failed %s minute(s) ago (critical within %s)', round(e.fail_min), e.since_fail_crit_min)),
          (7, 'crit', e.ok_min > e.since_ok_crit_min,
              CASE WHEN e.ok_past THEN format('no success in the last %s day(s) (critical over %s minute(s))', (SELECT h.mins FROM h) / 1440, e.since_ok_crit_min)
                   ELSE format('no success for %s minute(s) (critical over %s)', round(e.ok_min), e.since_ok_crit_min) END),
          (11, 'warn', e.last_outcome IN ('failed', 'cancelled') AND e.last_fail_is = 'warn',
              CASE e.last_outcome WHEN 'cancelled' THEN 'the last run was cancelled' ELSE 'the last run failed' END),
          (12, 'warn', e.fail_24h >= e.fail_24h_warn, format('%s failed run(s) in 24 hours (warning at %s)', e.fail_24h, e.fail_24h_warn)),
          (13, 'warn', e.fail_7d >= e.fail_7d_warn, format('%s failed run(s) in 7 days (warning at %s)', e.fail_7d, e.fail_7d_warn)),
          (14, 'warn', e.step_fail_24h >= e.step_fail_24h_warn, format('%s failed step(s) in 24 hours (warning at %s)', e.step_fail_24h, e.step_fail_24h_warn)),
          (15, 'warn', e.step_fail_7d >= e.step_fail_7d_warn, format('%s failed step(s) in 7 days (warning at %s)', e.step_fail_7d, e.step_fail_7d_warn)),
          (16, 'warn', e.fail_min <= e.since_fail_warn_min, format('failed %s minute(s) ago (warning within %s)', round(e.fail_min), e.since_fail_warn_min)),
          (17, 'warn', e.ok_min > e.since_ok_warn_min,
              CASE WHEN e.ok_past THEN format('no success in the last %s day(s) (warning over %s minute(s))', (SELECT h.mins FROM h) / 1440, e.since_ok_warn_min)
                   ELSE format('no success for %s minute(s) (warning over %s)', round(e.ok_min), e.since_ok_warn_min) END)
        ) v(ord, sev, broken, why)
       WHERE v.broken AND e.excluded_by IS NULL
       ORDER BY v.ord LIMIT 1) b ON true
   ORDER BY e.instance_id, e.scheduler, e.job_name
$$;

-- job_status: 0102's name, arguments and columns, one instance of job_status_view
CREATE OR REPLACE FUNCTION pgvigil.job_status(p_instance_id int)
RETURNS TABLE (scheduler text, job_id text, job_name text, level text, threshold_id bigint, fail_24h bigint, fail_7d bigint,
               step_fail_24h bigint, step_fail_7d bigint, last_failed_at timestamptz, last_succeeded_at timestamptz,
               last_outcome text, status text, reason text)
LANGUAGE sql STABLE AS $$
  SELECT v.scheduler, v.job_id, v.job_name, v.level, v.threshold_id, v.fail_24h, v.fail_7d, v.step_fail_24h, v.step_fail_7d,
         v.last_failed_at, v.last_succeeded_at, v.last_outcome, v.status, v.reason
    FROM pgvigil.job_status_view(ARRAY[p_instance_id]) v
   ORDER BY v.scheduler, v.job_name
$$;
