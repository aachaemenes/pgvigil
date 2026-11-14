-- 0139: the jobs' hourly statistics (DBA Dash 4.24.1's dbo.JobStats_60MIN in pgvigil's shape): per job, step and UTC
-- hour the runs, successes, failures, retries and the total / longest / shortest duration, kept 730 days, so the fleet
-- Jobs page's four 7-day columns (succeeded 24 h / 7 days, longest and average over 7 days) read hours, not every run,
-- and a job's year stays readable after its runs are purged. Read from rows the collectors already store; nothing is
-- created, changed or switched on on a monitored server.
--
--   the hour           the UTC hour of the run's START (DBA Dash's DateGroupingMins(RunDateTime, 60): a run belongs
--                      to the hour it started in, whatever hour it ends in)
--   step 0 only        the job's outcome rows (SQL Agent step_id 0; PostgreSQL's runs as step 0): every page that reads
--                      the hours reads step 0. A stated DEPARTURE from DBA Dash's JobStats_60MIN, which keeps every step:
--                      the step rows would be about three quarters of the hours (about 75 GB more at a first site's 305
--                      instances over 730 days, measured shape); SQL Agent's and pgAgent's step rows, with the step chart
--                      that reads them, are a later task. step_id stays in the key for them
--   the counts         exact: runs = every row of the hour; failed = SQL Agent run_status IN (0, 3), PostgreSQL 'failed',
--                      'internal error', 'aborted' (0137's rule, DBA Dash's FailedCount); succeeded = run_status 1 /
--                      'succeeded'; retries = the rows' own retries (DBA Dash's retries_attempted); total, max and min of
--                      the duration in seconds. The grid's arithmetic (DBA Dash's whole seconds) is done at read time
--                      (job_stats_7day), so the stored columns stay exact for the charts
--   filled             by statement-level AFTER triggers with transition tables on mssql_job_runs (INSERT) and job_runs
--                      (INSERT, and UPDATE: a PostgreSQL run is stored while it runs and ended by a later import), so
--                      every writer counts - import_mssql_jobs, import_dbadash_jobruns, import_jobs, the seeds; each
--                      trigger call RECOMPUTES the instance-hours its rows touch from the stored runs (never adds to
--                      them), so a re-import, a late row or a run updated twice is never counted twice; it takes a
--                      per-instance advisory xact lock first, in its own statement (READ COMMITTED: the recompute then
--                      sees every committed run of the hour - without it two writers of one hour lose a count, measured
--                      on PostgreSQL 13, 16 and 18). An INSERT naming a partition would not fire the parent's trigger:
--                      no writer does, and the next write of that hour recomputes it
--   a failure          never fails the import: the trigger's body catches any error, records the hours as a DIRTY
--                      range (job_stats_dirty) and a 'rollup failed' row in collection_log (collection
--                      'job_stats_hourly', status 'error', the hours and the error in its note), and the runs commit.
--                      The heal is automatic: every later trigger call of that instance rebuilds its dirty ranges
--                      first (job_stats_heal), and purge()'s last block heals an instance that writes no more runs
--   a history import   the DBA Dash import (206) writes up to 730 day-batches an instance: it calls job_stats_defer
--                      first, and while that instance's defer row lives (30 minutes, renewed by each deferred batch) the
--                      triggers only merge the touched range into one dirty row; job_stats_build at the import's end
--                      builds it ONCE. An import that dies leaves the row to lapse: the next write or purge heals
--   the first build    none in this file (it would hold the job tables' writes or leave holes): every instance with
--                      stored runs gets a dirty range here, so its next import (or purge()'s block) builds its hours
--                      through job_stats_rebuild under the same lock; the stats cells fill as each instance's next jobs
--                      import runs (5 minutes)
--   retention          pgvigil.hours_retention, one row per hours table (this file seeds job_stats_hourly 730 days,
--                      DBA Dash's for JobStats_60MIN); job_stats_hourly_purge drops the months older than it, and is
--                      called by purge()'s last block
--
-- Locks: CREATE TRIGGER takes SHARE ROW EXCLUSIVE on mssql_job_runs and job_runs until this file commits (the jobs
-- collections' writes wait the few milliseconds the file takes; nothing here scans the runs). mssql_job_runs first,
-- then job_runs: purge()'s order. lock_timeout bounds each wait.
--
-- Partition parents for purge(): job_stats_hourly, dropped by job_stats_hourly_purge, not purge()'s list (its own age).
SET LOCAL lock_timeout = '20s';

CREATE TABLE IF NOT EXISTS pgvigil.job_stats_hourly (
  instance_id  int NOT NULL,
  scheduler    text NOT NULL,          -- 'sqlagent', 'pg_cron', 'pgagent'
  job_id       text NOT NULL,
  step_id      int NOT NULL,           -- 0 = the job's outcome (PostgreSQL: the run)
  snapshot_at  timestamptz NOT NULL,   -- the UTC hour the runs started in
  runs         int NOT NULL,
  succeeded    int NOT NULL,
  failed       int NOT NULL,
  retries      int NOT NULL,
  total_secs   double precision,
  max_secs     double precision,
  min_secs     double precision,
  PRIMARY KEY (instance_id, scheduler, job_id, step_id, snapshot_at)
) PARTITION BY RANGE (snapshot_at);

-- the hours a failed trigger call could not write, per instance and source table, until a heal rebuilds them
CREATE TABLE IF NOT EXISTS pgvigil.job_stats_dirty (
  instance_id  int NOT NULL,
  source       text NOT NULL CHECK (source IN ('mssql_job_runs', 'job_runs')),
  from_at      timestamptz NOT NULL,
  to_at        timestamptz NOT NULL,
  noted_at     timestamptz NOT NULL DEFAULT now(),
  why          text,
  PRIMARY KEY (instance_id, source, from_at)
);

-- how long each hours table keeps its rows (days); a table with no row keeps its default
CREATE TABLE IF NOT EXISTS pgvigil.hours_retention (
  table_name  text PRIMARY KEY,
  days        int NOT NULL CHECK (days >= 1),
  changed_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO pgvigil.hours_retention (table_name, days) VALUES ('job_stats_hourly', 730) ON CONFLICT (table_name) DO NOTHING;

-- an instance whose history is being imported: until until_at the triggers only mark its hours dirty
CREATE TABLE IF NOT EXISTS pgvigil.job_stats_defer (
  instance_id  int PRIMARY KEY,
  until_at     timestamptz NOT NULL
);

-- the given UTC hours of one instance's SQL Agent job outcomes (step 0), recomputed (the caller holds the instance's lock)
CREATE OR REPLACE FUNCTION pgvigil.job_stats_hours_mssql(p_instance_id int, p_hours timestamptz[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  PERFORM pgvigil.ensure_month_partition('job_stats_hourly', m)
     FROM (SELECT DISTINCT date_trunc('month', h AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS m FROM unnest(p_hours) h) x;
  INSERT INTO pgvigil.job_stats_hourly AS s (instance_id, scheduler, job_id, step_id, snapshot_at, runs, succeeded, failed, retries,
                                             total_secs, max_secs, min_secs)
  SELECT p_instance_id, 'sqlagent', r.job_id, r.step_id, h.h, count(*), count(*) FILTER (WHERE r.run_status = 1),
         count(*) FILTER (WHERE r.run_status IN (0, 3)), coalesce(sum(r.retries), 0), sum(r.duration_s), max(r.duration_s), min(r.duration_s)
    FROM unnest(p_hours) h(h)
    JOIN pgvigil.mssql_job_runs r ON r.instance_id = p_instance_id AND r.step_id = 0 AND r.snapshot_at >= h.h AND r.snapshot_at < h.h + interval '1 hour'
   GROUP BY r.job_id, r.step_id, h.h
  ON CONFLICT (instance_id, scheduler, job_id, step_id, snapshot_at) DO UPDATE
    SET runs = excluded.runs, succeeded = excluded.succeeded, failed = excluded.failed, retries = excluded.retries,
        total_secs = excluded.total_secs, max_secs = excluded.max_secs, min_secs = excluded.min_secs;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- the given UTC hours of one instance's ended PostgreSQL runs (pg_cron, pgAgent's job rows), recomputed (the caller
-- holds the instance's lock)
CREATE OR REPLACE FUNCTION pgvigil.job_stats_hours_pg(p_instance_id int, p_hours timestamptz[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  PERFORM pgvigil.ensure_month_partition('job_stats_hourly', m)
     FROM (SELECT DISTINCT date_trunc('month', h AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS m FROM unnest(p_hours) h) x;
  INSERT INTO pgvigil.job_stats_hourly AS s (instance_id, scheduler, job_id, step_id, snapshot_at, runs, succeeded, failed, retries,
                                             total_secs, max_secs, min_secs)
  SELECT p_instance_id, r.scheduler, r.job_id::text, 0, h.h, count(*), count(*) FILTER (WHERE r.status = 'succeeded'),
         count(*) FILTER (WHERE r.status IN ('failed', 'internal error', 'aborted')), 0,
         sum(r.duration_secs), max(r.duration_secs), min(r.duration_secs)
    FROM unnest(p_hours) h(h)
    JOIN pgvigil.job_runs r ON r.instance_id = p_instance_id AND r.start_time >= h.h AND r.start_time < h.h + interval '1 hour'
                            AND r.end_time IS NOT NULL
   GROUP BY r.scheduler, r.job_id, h.h
  ON CONFLICT (instance_id, scheduler, job_id, step_id, snapshot_at) DO UPDATE
    SET runs = excluded.runs, succeeded = excluded.succeeded, failed = excluded.failed, retries = excluded.retries,
        total_secs = excluded.total_secs, max_secs = excluded.max_secs, min_secs = excluded.min_secs;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- job_stats_rebuild: every hour of one instance's stored runs between p_from and p_to recomputed from the runs, under
-- the instance's lock (re-entrant: a trigger that holds it may call this); the range is widened to whole UTC hours (a
-- bound inside an hour never writes a part of it); ONE pass over the range per table (a GROUP BY by job, step and hour:
-- the first build reads an instance's every run once); idempotent (twice = once). Hours whose runs were purged keep
-- their rows (a rebuild writes the hours it finds runs for, it removes none). Returns the hour rows written.
CREATE OR REPLACE FUNCTION pgvigil.job_stats_rebuild(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_from timestamptz; v_to timestamptz; v_lo timestamptz; v_hi timestamptz; v_k int; v_n int := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.job_stats_hourly'), p_instance_id);
  v_from := CASE WHEN isfinite(p_from) THEN date_trunc('hour', p_from AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' ELSE p_from END;
  v_to := CASE WHEN NOT isfinite(p_to) THEN p_to
               WHEN date_trunc('hour', p_to AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' = p_to THEN p_to
               ELSE (date_trunc('hour', p_to AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC' END;
  -- SQL Agent
  SELECT min(r.snapshot_at), max(r.snapshot_at) INTO v_lo, v_hi
    FROM pgvigil.mssql_job_runs r WHERE r.instance_id = p_instance_id AND r.step_id = 0 AND r.snapshot_at >= v_from AND r.snapshot_at < v_to;
  IF v_lo IS NOT NULL THEN
    PERFORM pgvigil.ensure_month_partition('job_stats_hourly', m AT TIME ZONE 'UTC')
       FROM generate_series(date_trunc('month', v_lo AT TIME ZONE 'UTC'), date_trunc('month', v_hi AT TIME ZONE 'UTC'), interval '1 month') m;
    INSERT INTO pgvigil.job_stats_hourly AS s (instance_id, scheduler, job_id, step_id, snapshot_at, runs, succeeded, failed, retries,
                                               total_secs, max_secs, min_secs)
    SELECT p_instance_id, 'sqlagent', r.job_id, r.step_id, date_trunc('hour', r.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC', count(*),
           count(*) FILTER (WHERE r.run_status = 1), count(*) FILTER (WHERE r.run_status IN (0, 3)), coalesce(sum(r.retries), 0),
           sum(r.duration_s), max(r.duration_s), min(r.duration_s)
      FROM pgvigil.mssql_job_runs r
     WHERE r.instance_id = p_instance_id AND r.step_id = 0 AND r.snapshot_at >= v_from AND r.snapshot_at < v_to
     GROUP BY r.job_id, r.step_id, date_trunc('hour', r.snapshot_at AT TIME ZONE 'UTC')
    ON CONFLICT (instance_id, scheduler, job_id, step_id, snapshot_at) DO UPDATE
      SET runs = excluded.runs, succeeded = excluded.succeeded, failed = excluded.failed, retries = excluded.retries,
          total_secs = excluded.total_secs, max_secs = excluded.max_secs, min_secs = excluded.min_secs;
    GET DIAGNOSTICS v_k = ROW_COUNT; v_n := v_n + v_k;
  END IF;
  -- PostgreSQL (ended runs)
  SELECT min(r.start_time), max(r.start_time) INTO v_lo, v_hi
    FROM pgvigil.job_runs r WHERE r.instance_id = p_instance_id AND r.start_time >= v_from AND r.start_time < v_to AND r.end_time IS NOT NULL;
  IF v_lo IS NOT NULL THEN
    PERFORM pgvigil.ensure_month_partition('job_stats_hourly', m AT TIME ZONE 'UTC')
       FROM generate_series(date_trunc('month', v_lo AT TIME ZONE 'UTC'), date_trunc('month', v_hi AT TIME ZONE 'UTC'), interval '1 month') m;
    INSERT INTO pgvigil.job_stats_hourly AS s (instance_id, scheduler, job_id, step_id, snapshot_at, runs, succeeded, failed, retries,
                                               total_secs, max_secs, min_secs)
    SELECT p_instance_id, r.scheduler, r.job_id::text, 0, date_trunc('hour', r.start_time AT TIME ZONE 'UTC') AT TIME ZONE 'UTC', count(*),
           count(*) FILTER (WHERE r.status = 'succeeded'), count(*) FILTER (WHERE r.status IN ('failed', 'internal error', 'aborted')), 0,
           sum(r.duration_secs), max(r.duration_secs), min(r.duration_secs)
      FROM pgvigil.job_runs r
     WHERE r.instance_id = p_instance_id AND r.start_time >= v_from AND r.start_time < v_to AND r.end_time IS NOT NULL
     GROUP BY r.scheduler, r.job_id, date_trunc('hour', r.start_time AT TIME ZONE 'UTC')
    ON CONFLICT (instance_id, scheduler, job_id, step_id, snapshot_at) DO UPDATE
      SET runs = excluded.runs, succeeded = excluded.succeeded, failed = excluded.failed, retries = excluded.retries,
          total_secs = excluded.total_secs, max_secs = excluded.max_secs, min_secs = excluded.min_secs;
    GET DIAGNOSTICS v_k = ROW_COUNT; v_n := v_n + v_k;
  END IF;
  RETURN v_n;
END $$;

-- job_stats_heal: one instance's dirty ranges rebuilt and removed (the caller holds the instance's lock); an error
-- leaves them for the next call
CREATE OR REPLACE FUNCTION pgvigil.job_stats_heal(p_instance_id int)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v record; v_n int := 0;
BEGIN
  FOR v IN SELECT d.from_at, d.to_at FROM pgvigil.job_stats_dirty d WHERE d.instance_id = p_instance_id ORDER BY d.from_at LOOP
    v_n := v_n + pgvigil.job_stats_rebuild(p_instance_id, v.from_at, v.to_at);
  END LOOP;
  DELETE FROM pgvigil.job_stats_dirty WHERE instance_id = p_instance_id;
  RETURN v_n;
END $$;

-- job_stats_failed: a trigger call that could not write its hours - a dirty range (merged into one already noted at
-- the same start) and a 'rollup failed' row in collection_log
CREATE OR REPLACE FUNCTION pgvigil.job_stats_failed(p_instance_id int, p_source text, p_from timestamptz, p_to timestamptz, p_why text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.job_stats_dirty AS d (instance_id, source, from_at, to_at, why)
  VALUES (p_instance_id, p_source, p_from, p_to, p_why)
  ON CONFLICT (instance_id, source, from_at) DO UPDATE SET to_at = greatest(d.to_at, excluded.to_at), noted_at = now(), why = excluded.why;
  INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
  VALUES (p_instance_id, 'job_stats_hourly', now(), 'error',
          format('rollup failed for the %s hours %s to %s (the runs are stored; the hours are rebuilt by the next import or purge): %s',
                 p_source, to_char(p_from AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), to_char(p_to AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), p_why));
END $$;

-- job_stats_mark: a deferred instance's touched range merged into its one 'deferred' dirty row per source
CREATE OR REPLACE FUNCTION pgvigil.job_stats_mark(p_instance_id int, p_source text, p_from timestamptz, p_to timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE pgvigil.job_stats_dirty d SET from_at = least(d.from_at, p_from), to_at = greatest(d.to_at, p_to), noted_at = now()
   WHERE d.instance_id = p_instance_id AND d.source = p_source AND d.why = 'deferred';
  IF NOT FOUND THEN
    INSERT INTO pgvigil.job_stats_dirty AS d (instance_id, source, from_at, to_at, why)
    VALUES (p_instance_id, p_source, p_from, p_to, 'deferred')
    ON CONFLICT (instance_id, source, from_at) DO UPDATE SET to_at = greatest(d.to_at, excluded.to_at), noted_at = now();
  END IF;
  -- each deferred batch keeps the defer alive; one that stops lets it lapse
  UPDATE pgvigil.job_stats_defer SET until_at = greatest(until_at, now() + interval '30 minutes') WHERE instance_id = p_instance_id;
END $$;

-- job_stats_defer: a history import of the instance starts (the DBA Dash import, before its job runs): until
-- job_stats_build or 30 minutes without a deferred batch, the triggers only mark its hours dirty
CREATE OR REPLACE FUNCTION pgvigil.job_stats_defer(p_instance_id int)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.job_stats_defer (instance_id, until_at) VALUES (p_instance_id, now() + interval '30 minutes')
  ON CONFLICT (instance_id) DO UPDATE SET until_at = excluded.until_at
$$;

-- job_stats_build: the import's end - the defer lifted, the instance's dirty hours built once under its lock; returns the
-- hour rows written
CREATE OR REPLACE FUNCTION pgvigil.job_stats_build(p_instance_id int)
RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM pgvigil.job_stats_defer WHERE instance_id = p_instance_id;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.job_stats_hourly'), p_instance_id);
  RETURN pgvigil.job_stats_heal(p_instance_id);
END $$;

-- the triggers' body: per instance in the statement's rows (in instance order), the lock in its own statement, the
-- instance's dirty ranges healed, then the touched hours recomputed; any error caught per instance
CREATE OR REPLACE FUNCTION pgvigil.job_stats_mssql_tg()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM n x WHERE x.step_id = 0) THEN RETURN NULL; END IF;   -- a statement trigger fires on every call: no outcome rows, no lock
  FOR v IN SELECT x.instance_id, array_agg(DISTINCT date_trunc('hour', x.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') AS hours
             FROM n x WHERE x.step_id = 0 GROUP BY x.instance_id ORDER BY x.instance_id LOOP
    BEGIN
      IF EXISTS (SELECT 1 FROM pgvigil.job_stats_defer d WHERE d.instance_id = v.instance_id AND d.until_at > now()) THEN
        PERFORM pgvigil.job_stats_mark(v.instance_id, 'mssql_job_runs', (SELECT min(h) FROM unnest(v.hours) h),
                                       (SELECT max(h) FROM unnest(v.hours) h) + interval '1 hour');
        CONTINUE;
      END IF;
      PERFORM pg_advisory_xact_lock(hashtext('pgvigil.job_stats_hourly'), v.instance_id);
      PERFORM pgvigil.job_stats_heal(v.instance_id);
      PERFORM pgvigil.job_stats_hours_mssql(v.instance_id, v.hours);
    EXCEPTION WHEN OTHERS THEN
      PERFORM pgvigil.job_stats_failed(v.instance_id, 'mssql_job_runs', (SELECT min(h) FROM unnest(v.hours) h),
                                       (SELECT max(h) FROM unnest(v.hours) h) + interval '1 hour', SQLERRM);
    END;
  END LOOP;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.job_stats_pg_tg()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM n x WHERE x.end_time IS NOT NULL AND x.start_time IS NOT NULL) THEN RETURN NULL; END IF;
  FOR v IN SELECT x.instance_id, array_agg(DISTINCT date_trunc('hour', x.start_time AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') AS hours
             FROM n x WHERE x.end_time IS NOT NULL AND x.start_time IS NOT NULL GROUP BY x.instance_id ORDER BY x.instance_id LOOP
    BEGIN
      IF EXISTS (SELECT 1 FROM pgvigil.job_stats_defer d WHERE d.instance_id = v.instance_id AND d.until_at > now()) THEN
        PERFORM pgvigil.job_stats_mark(v.instance_id, 'job_runs', (SELECT min(h) FROM unnest(v.hours) h),
                                       (SELECT max(h) FROM unnest(v.hours) h) + interval '1 hour');
        CONTINUE;
      END IF;
      PERFORM pg_advisory_xact_lock(hashtext('pgvigil.job_stats_hourly'), v.instance_id);
      PERFORM pgvigil.job_stats_heal(v.instance_id);
      PERFORM pgvigil.job_stats_hours_pg(v.instance_id, v.hours);
    EXCEPTION WHEN OTHERS THEN
      PERFORM pgvigil.job_stats_failed(v.instance_id, 'job_runs', (SELECT min(h) FROM unnest(v.hours) h),
                                       (SELECT max(h) FROM unnest(v.hours) h) + interval '1 hour', SQLERRM);
    END;
  END LOOP;
  RETURN NULL;
END $$;

-- job_stats_7day: the fleet Jobs page's four 7-day columns per job of the instances p_ids (NULL = every active
-- instance), read from the hours with DBA Dash 4.24.1's arithmetic (AgentJob7Day.sql): at step 0, the successes of
-- the hours that started within 1 day / 7 days of now (an hour is in when its start is), the longest = the largest
-- hourly maximum, the average = the average over the hours of each hour's total / (failed + succeeded), both in
-- whole seconds as DBA Dash's integers give them
CREATE OR REPLACE FUNCTION pgvigil.job_stats_7day(p_ids int[])
RETURNS TABLE (instance_id int, scheduler text, job_id text, ok_24h bigint, ok_7d bigint, max_secs_7d numeric, avg_secs_7d numeric)
LANGUAGE sql STABLE AS $$
  WITH ids AS (SELECT unnest(coalesce(p_ids, ARRAY(SELECT x.instance_id FROM pgvigil.instances x WHERE x.is_active))) AS instance_id),
  h AS (SELECT s.instance_id, s.scheduler, s.job_id,
               sum(s.succeeded) FILTER (WHERE s.snapshot_at >= now() - interval '1 day') AS ok_24h,
               sum(s.succeeded) AS ok_7d,
               trunc(max(s.max_secs))::numeric AS max_secs_7d,
               trunc(avg(trunc(s.total_secs / nullif(s.succeeded + s.failed, 0))))::numeric AS avg_secs_7d
          FROM pgvigil.job_stats_hourly s JOIN ids i ON i.instance_id = s.instance_id
         WHERE s.step_id = 0 AND s.snapshot_at >= now() - interval '7 days'
         GROUP BY s.instance_id, s.scheduler, s.job_id)
  SELECT m.instance_id, 'sqlagent'::text, m.job_id, coalesce(h.ok_24h, 0), coalesce(h.ok_7d, 0), h.max_secs_7d, h.avg_secs_7d
    FROM pgvigil.mssql_jobs m JOIN ids i ON i.instance_id = m.instance_id
    LEFT JOIN h ON h.instance_id = m.instance_id AND h.scheduler = 'sqlagent' AND h.job_id = m.job_id
  UNION ALL
  SELECT g.instance_id, g.scheduler, g.job_id::text, coalesce(h.ok_24h, 0), coalesce(h.ok_7d, 0), h.max_secs_7d, h.avg_secs_7d
    FROM pgvigil.jobs g JOIN ids i ON i.instance_id = g.instance_id
    LEFT JOIN h ON h.instance_id = g.instance_id AND h.scheduler = g.scheduler AND h.job_id = g.job_id::text
   WHERE g.is_present
$$;

-- job_stats_hourly_purge: the months of job_stats_hourly wholly older than its hours_retention row (730 days when
-- absent) dropped, then the dirty ranges of the instances no trigger call healed (they write no more runs) rebuilt;
-- called by purge()'s last block. Returns the partitions dropped.
CREATE OR REPLACE FUNCTION pgvigil.job_stats_hourly_purge()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_days int; v_part record; v_i record; v_n int := 0;
BEGIN
  SELECT r.days INTO v_days FROM pgvigil.hours_retention r WHERE r.table_name = 'job_stats_hourly';
  v_days := coalesce(v_days, 730);
  FOR v_part IN
    SELECT c.relname
      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent = 'pgvigil.job_stats_hourly'::regclass
       AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => v_days)
     ORDER BY c.relname
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    v_n := v_n + 1;
  END LOOP;
  FOR v_i IN SELECT DISTINCT d.instance_id FROM pgvigil.job_stats_dirty d
              WHERE NOT EXISTS (SELECT 1 FROM pgvigil.job_stats_defer f WHERE f.instance_id = d.instance_id AND f.until_at > now())
              ORDER BY d.instance_id LOOP
    BEGIN
      PERFORM pg_advisory_xact_lock(hashtext('pgvigil.job_stats_hourly'), v_i.instance_id);
      PERFORM pgvigil.job_stats_heal(v_i.instance_id);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
      VALUES (v_i.instance_id, 'job_stats_hourly', now(), 'error', 'rollup heal failed in purge (the dirty hours stay for the next try): ' || SQLERRM);
    END;
  END LOOP;
  RETURN v_n;
END $$;

DROP TRIGGER IF EXISTS job_stats_hourly_ins ON pgvigil.mssql_job_runs;
CREATE TRIGGER job_stats_hourly_ins AFTER INSERT ON pgvigil.mssql_job_runs
  REFERENCING NEW TABLE AS n FOR EACH STATEMENT EXECUTE FUNCTION pgvigil.job_stats_mssql_tg();
DROP TRIGGER IF EXISTS job_stats_hourly_ins ON pgvigil.job_runs;
CREATE TRIGGER job_stats_hourly_ins AFTER INSERT ON pgvigil.job_runs
  REFERENCING NEW TABLE AS n FOR EACH STATEMENT EXECUTE FUNCTION pgvigil.job_stats_pg_tg();
DROP TRIGGER IF EXISTS job_stats_hourly_upd ON pgvigil.job_runs;
CREATE TRIGGER job_stats_hourly_upd AFTER UPDATE ON pgvigil.job_runs
  REFERENCING NEW TABLE AS n FOR EACH STATEMENT EXECUTE FUNCTION pgvigil.job_stats_pg_tg();

-- the first build: every instance with stored runs is dirty from its first run to an hour past now (a run committed
-- while this file ran is inside it), so its next import or purge() builds its hours
INSERT INTO pgvigil.job_stats_dirty (instance_id, source, from_at, to_at, why)
SELECT i.instance_id, 'mssql_job_runs', '-infinity', now() + interval '1 hour', '0139: the first build'
  FROM pgvigil.instances i WHERE EXISTS (SELECT 1 FROM pgvigil.mssql_job_runs r WHERE r.instance_id = i.instance_id)
ON CONFLICT (instance_id, source, from_at) DO NOTHING;
INSERT INTO pgvigil.job_stats_dirty (instance_id, source, from_at, to_at, why)
SELECT i.instance_id, 'job_runs', '-infinity', now() + interval '1 hour', '0139: the first build'
  FROM pgvigil.instances i WHERE EXISTS (SELECT 1 FROM pgvigil.job_runs r WHERE r.instance_id = i.instance_id)
ON CONFLICT (instance_id, source, from_at) DO NOTHING;
