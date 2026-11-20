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
--   the heal           the hours not (re)built yet are one merged range per instance and source (job_stats_dirty).
--                      Every trigger call of an instance heals it first, UNDER A BUDGET (2 s, the session setting
--                      pgvigil.job_stats_heal_ms): newest week first, the range shrunk as its weeks are done, the rest
--                      left to the next call - so an import under the collector's 30 s repository timeout is never
--                      cancelled by a heal (a cancel is not an error the trigger can catch). 'pgvigil purge' heals every
--                      instance still dirty (job_stats_pending, job_stats_heal_one), each in its own transaction, with
--                      no budget. A range is removed only as it was read: one an unlocked writer widened meanwhile
--                      stays for the next heal
--   a failure          never fails the import: the trigger's body catches any error, merges the hours into the dirty
--                      range and writes a 'rollup failed' row in collection_log (collection 'job_stats_hourly', status
--                      'error', the hours and the error in its note) at most once an hour per range; the runs commit.
--                      The heal of a range that was logged writes one 'ok' row ('rollup healed'). A failure of that
--                      record itself is a WARNING, never the import's error
--   the first build    none in this file, and no row written by it (it would hold the job tables' writes or leave
--                      holes; and no migration writes a stored row, docs/upgrade.md): the first heal that meets an
--                      instance with no job_stats_first_build row queues its whole range (a dirty row per source) and
--                      the row; the heals above build it, newest week first. Until an instance's last 7 days are built
--                      job_stats_7day says 'building' for it and its four values are NULL (the page: 'being built')
--   a history import   the DBA Dash import (206) writes up to 730 day-batches an instance: it calls
--                      import_job_stats_defer first, and until that defer's end (2 hours from the call, never renewed by
--                      a trigger: the live collector's writes of a moved instance are deferred too) the triggers only
--                      merge the touched range into the dirty row; import_job_stats_build at the import's end builds it
--                      ONCE. An import that dies leaves the defer to lapse: the next write or purge heals
--   retention          pgvigil.hours_retention, one row per hours table (this file seeds job_stats_hourly 730 days,
--                      DBA Dash's for JobStats_60MIN); job_stats_hourly_purge drops the months older than it and returns
--                      their names, and is called by purge()'s last block
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

-- the hours not (re)built yet, one merged range per instance and source: a failed trigger call's hours, a deferred
-- import's batches, an instance's first build; the heal that rebuilds a range removes it
CREATE TABLE IF NOT EXISTS pgvigil.job_stats_dirty (
  instance_id  int NOT NULL REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  source       text NOT NULL CHECK (source IN ('mssql_job_runs', 'job_runs')),
  from_at      timestamptz NOT NULL,
  to_at        timestamptz NOT NULL,
  noted_at     timestamptz NOT NULL DEFAULT now(),
  logged_at    timestamptz,             -- the last 'rollup failed' row written for this range (one an hour at most)
  why          text,
  PRIMARY KEY (instance_id, source)
);

-- the instances whose first build was queued (their whole range as job_stats_dirty rows); an instance with no row is
-- queued by the next heal that meets it
CREATE TABLE IF NOT EXISTS pgvigil.job_stats_first_build (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  queued_at    timestamptz NOT NULL DEFAULT now()
);

-- how long each hours table keeps its rows (days); a table with no row keeps its default
CREATE TABLE IF NOT EXISTS pgvigil.hours_retention (
  table_name  text PRIMARY KEY,
  days        int NOT NULL CHECK (days >= 1),
  changed_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO pgvigil.hours_retention (table_name, days) VALUES ('job_stats_hourly', 730) ON CONFLICT (table_name) DO NOTHING;

-- an instance whose history is being imported: until until_at (set by import_job_stats_defer, never renewed by a
-- trigger) the triggers only mark its hours dirty
CREATE TABLE IF NOT EXISTS pgvigil.job_stats_defer (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
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

-- job_stats_rebuild: every hour of one instance's stored runs between p_from and p_to recomputed from the runs (one
-- source, or both when p_source is NULL), under the instance's lock (re-entrant: a trigger that holds it may call
-- this); the range is widened to whole UTC hours (a bound inside an hour never writes a part of it); ONE pass over the
-- range per source (a GROUP BY by job, step and hour); a month's partition only where the month has runs; idempotent
-- (twice = once). Hours whose runs were purged keep their rows (a rebuild writes the hours it finds runs for, it
-- removes none). Returns the hour rows written.
CREATE OR REPLACE FUNCTION pgvigil.job_stats_rebuild(p_instance_id int, p_from timestamptz, p_to timestamptz, p_source text DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_from timestamptz; v_to timestamptz; v_lo timestamptz; v_hi timestamptz; v_k int; v_n int := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.job_stats_hourly'), p_instance_id);
  v_from := CASE WHEN isfinite(p_from) THEN date_trunc('hour', p_from AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' ELSE p_from END;
  v_to := CASE WHEN NOT isfinite(p_to) THEN p_to
               WHEN date_trunc('hour', p_to AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' = p_to THEN p_to
               ELSE (date_trunc('hour', p_to AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC' END;
  -- SQL Agent
  IF p_source IS NULL OR p_source = 'mssql_job_runs' THEN
    SELECT min(r.snapshot_at), max(r.snapshot_at) INTO v_lo, v_hi
      FROM pgvigil.mssql_job_runs r WHERE r.instance_id = p_instance_id AND r.step_id = 0 AND r.snapshot_at >= v_from AND r.snapshot_at < v_to;
    IF v_lo IS NOT NULL THEN
      PERFORM pgvigil.ensure_month_partition('job_stats_hourly', m AT TIME ZONE 'UTC')
         FROM generate_series(date_trunc('month', v_lo AT TIME ZONE 'UTC'), date_trunc('month', v_hi AT TIME ZONE 'UTC'), interval '1 month') m
        WHERE EXISTS (SELECT 1 FROM pgvigil.mssql_job_runs r WHERE r.instance_id = p_instance_id AND r.step_id = 0
                         AND r.snapshot_at >= greatest(v_from, m AT TIME ZONE 'UTC') AND r.snapshot_at < least(v_to, (m + interval '1 month') AT TIME ZONE 'UTC'));
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
  END IF;
  -- PostgreSQL (ended runs)
  IF p_source IS NULL OR p_source = 'job_runs' THEN
    SELECT min(r.start_time), max(r.start_time) INTO v_lo, v_hi
      FROM pgvigil.job_runs r WHERE r.instance_id = p_instance_id AND r.start_time >= v_from AND r.start_time < v_to AND r.end_time IS NOT NULL;
    IF v_lo IS NOT NULL THEN
      PERFORM pgvigil.ensure_month_partition('job_stats_hourly', m AT TIME ZONE 'UTC')
         FROM generate_series(date_trunc('month', v_lo AT TIME ZONE 'UTC'), date_trunc('month', v_hi AT TIME ZONE 'UTC'), interval '1 month') m
        WHERE EXISTS (SELECT 1 FROM pgvigil.job_runs r WHERE r.instance_id = p_instance_id AND r.end_time IS NOT NULL
                         AND r.start_time >= greatest(v_from, m AT TIME ZONE 'UTC') AND r.start_time < least(v_to, (m + interval '1 month') AT TIME ZONE 'UTC'));
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
  END IF;
  RETURN v_n;
END $$;

-- job_stats_heal: one instance's dirty ranges rebuilt (the caller holds the instance's lock). An instance met for the
-- first time (no job_stats_first_build row) has its whole range queued first. Each range is clipped to its source's
-- stored runs and rebuilt newest week first; with a budget (p_budget_ms, NULL = none) the heal stops once it is spent
-- and keeps what is left of the range (as it was read: a range widened meanwhile is kept whole). A range done is
-- removed as it was read; one that had a 'rollup failed' row gets a 'rollup healed' row. Returns the hour rows written.
CREATE OR REPLACE FUNCTION pgvigil.job_stats_heal(p_instance_id int, p_budget_ms int DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v record; v_n int := 0; v_t0 timestamptz := clock_timestamp(); v_lo timestamptz; v_hi timestamptz; v_cut timestamptz;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pgvigil.job_stats_first_build b WHERE b.instance_id = p_instance_id) THEN
    INSERT INTO pgvigil.job_stats_dirty AS d (instance_id, source, from_at, to_at, why)
    SELECT p_instance_id, s, '-infinity', 'infinity', 'the first build' FROM unnest(ARRAY['mssql_job_runs', 'job_runs']) s
    ON CONFLICT (instance_id, source) DO UPDATE SET from_at = '-infinity', to_at = 'infinity', noted_at = now();
    INSERT INTO pgvigil.job_stats_first_build (instance_id) VALUES (p_instance_id) ON CONFLICT (instance_id) DO NOTHING;
  END IF;
  FOR v IN SELECT d.source, d.from_at, d.to_at, d.logged_at FROM pgvigil.job_stats_dirty d
            WHERE d.instance_id = p_instance_id ORDER BY d.source DESC LOOP   -- mssql_job_runs first
    IF v.source = 'mssql_job_runs' THEN
      SELECT min(r.snapshot_at), max(r.snapshot_at) INTO v_lo, v_hi FROM pgvigil.mssql_job_runs r
       WHERE r.instance_id = p_instance_id AND r.step_id = 0 AND r.snapshot_at >= v.from_at AND r.snapshot_at < v.to_at;
    ELSE
      SELECT min(r.start_time), max(r.start_time) INTO v_lo, v_hi FROM pgvigil.job_runs r
       WHERE r.instance_id = p_instance_id AND r.start_time >= v.from_at AND r.start_time < v.to_at AND r.end_time IS NOT NULL;
    END IF;
    v_hi := (date_trunc('hour', v_hi AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC';   -- NULL when no run
    WHILE v_lo IS NOT NULL AND v_hi > v_lo LOOP
      v_cut := greatest(v_lo, v_hi - interval '7 days');
      v_n := v_n + pgvigil.job_stats_rebuild(p_instance_id, v_cut, v_hi, v.source);
      v_hi := v_cut;
      IF p_budget_ms IS NOT NULL AND v_hi > v_lo AND clock_timestamp() - v_t0 >= make_interval(secs => p_budget_ms / 1000.0) THEN
        UPDATE pgvigil.job_stats_dirty d SET to_at = v_hi, noted_at = now()
         WHERE d.instance_id = p_instance_id AND d.source = v.source AND d.from_at = v.from_at AND d.to_at = v.to_at;
        RETURN v_n;
      END IF;
    END LOOP;
    DELETE FROM pgvigil.job_stats_dirty d
     WHERE d.instance_id = p_instance_id AND d.source = v.source AND d.from_at = v.from_at AND d.to_at = v.to_at;
    IF FOUND AND v.logged_at IS NOT NULL THEN
      INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
      VALUES (p_instance_id, 'job_stats_hourly', now(), 'ok',
              format('rollup healed: the %s hours %s to %s rebuilt', v.source,
                     coalesce(to_char(v.from_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), v.from_at::text),
                     coalesce(to_char(v.to_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), v.to_at::text)));
    END IF;
  END LOOP;
  RETURN v_n;
END $$;

-- job_stats_failed: a trigger call that could not write its hours - merged into the instance's dirty range of that
-- source, and a 'rollup failed' row in collection_log when the range is new or its last such row is an hour old
CREATE OR REPLACE FUNCTION pgvigil.job_stats_failed(p_instance_id int, p_source text, p_from timestamptz, p_to timestamptz, p_why text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_prev timestamptz; v_had boolean; v_log boolean;
BEGIN
  SELECT true, d.logged_at INTO v_had, v_prev FROM pgvigil.job_stats_dirty d WHERE d.instance_id = p_instance_id AND d.source = p_source;
  v_log := v_had IS NULL OR v_prev IS NULL OR v_prev < now() - interval '1 hour';
  INSERT INTO pgvigil.job_stats_dirty AS d (instance_id, source, from_at, to_at, why, logged_at)
  VALUES (p_instance_id, p_source, p_from, p_to, p_why, now())
  ON CONFLICT (instance_id, source) DO UPDATE
    SET from_at = least(d.from_at, excluded.from_at), to_at = greatest(d.to_at, excluded.to_at), noted_at = now(), why = excluded.why,
        logged_at = CASE WHEN v_log THEN now() ELSE d.logged_at END;
  IF v_log THEN
    INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
    VALUES (p_instance_id, 'job_stats_hourly', now(), 'error',
            format('rollup failed for the %s hours %s to %s (the runs are stored; the hours are rebuilt by the next import or purge): %s',
                   p_source, coalesce(to_char(p_from AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), p_from::text),
                   coalesce(to_char(p_to AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), p_to::text), p_why));
  END IF;
END $$;

-- job_stats_mark: a deferred instance's touched range merged into its dirty range of that source (no lock: the heal
-- that later reads the range removes it only as it read it)
CREATE OR REPLACE FUNCTION pgvigil.job_stats_mark(p_instance_id int, p_source text, p_from timestamptz, p_to timestamptz)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.job_stats_dirty AS d (instance_id, source, from_at, to_at, why)
  VALUES (p_instance_id, p_source, p_from, p_to, 'deferred')
  ON CONFLICT (instance_id, source) DO UPDATE
    SET from_at = least(d.from_at, excluded.from_at), to_at = greatest(d.to_at, excluded.to_at), noted_at = now()
$$;

-- import_job_stats_defer: a history import of the instance starts (the DBA Dash import, before its job runs): for 2
-- hours, or until import_job_stats_build, the triggers only mark its hours dirty. The collector's door (import_*):
-- runs as the owner
CREATE OR REPLACE FUNCTION pgvigil.import_job_stats_defer(p_instance_id int)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.job_stats_defer (instance_id, until_at) VALUES (p_instance_id, now() + interval '2 hours')
  ON CONFLICT (instance_id) DO UPDATE SET until_at = excluded.until_at
$$;

-- import_job_stats_build: the import's end - the defer lifted, the instance's dirty hours built once under its lock,
-- with no budget (its own statement, not an import's); returns the hour rows written
CREATE OR REPLACE FUNCTION pgvigil.import_job_stats_build(p_instance_id int)
RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM pgvigil.job_stats_defer WHERE instance_id = p_instance_id;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.job_stats_hourly'), p_instance_id);
  RETURN pgvigil.job_stats_heal(p_instance_id);
END $$;

-- job_stats_pending: the instances 'pgvigil purge' heals - a dirty range, or stored runs and no first build queued -
-- and not under a live defer
CREATE OR REPLACE FUNCTION pgvigil.job_stats_pending()
RETURNS SETOF int LANGUAGE sql STABLE AS $$
  SELECT u.instance_id
    FROM (SELECT d.instance_id FROM pgvigil.job_stats_dirty d
          UNION
          SELECT i.instance_id FROM pgvigil.instances i
           WHERE NOT EXISTS (SELECT 1 FROM pgvigil.job_stats_first_build b WHERE b.instance_id = i.instance_id)
             AND (EXISTS (SELECT 1 FROM pgvigil.mssql_job_runs r WHERE r.instance_id = i.instance_id)
                  OR EXISTS (SELECT 1 FROM pgvigil.job_runs r WHERE r.instance_id = i.instance_id))) u
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.job_stats_defer f WHERE f.instance_id = u.instance_id AND f.until_at > now())
   ORDER BY u.instance_id
$$;

-- job_stats_heal_one: one instance healed whole under its lock (no budget), for 'pgvigil purge' - one call, one
-- transaction; returns the hour rows written
CREATE OR REPLACE FUNCTION pgvigil.job_stats_heal_one(p_instance_id int)
RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.job_stats_hourly'), p_instance_id);
  RETURN pgvigil.job_stats_heal(p_instance_id);
END $$;

-- the triggers' body: per instance in the statement's rows (in instance order), the lock in its own statement, the
-- instance's dirty ranges healed under the budget, then the touched hours recomputed; any error caught per instance,
-- and its record guarded in turn
CREATE OR REPLACE FUNCTION pgvigil.job_stats_mssql_tg()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v record; v_budget int := coalesce(nullif(current_setting('pgvigil.job_stats_heal_ms', true), '')::int, 2000);
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
      PERFORM pgvigil.job_stats_heal(v.instance_id, v_budget);
      PERFORM pgvigil.job_stats_hours_mssql(v.instance_id, v.hours);
    EXCEPTION WHEN OTHERS THEN
      BEGIN
        PERFORM pgvigil.job_stats_failed(v.instance_id, 'mssql_job_runs', (SELECT min(h) FROM unnest(v.hours) h),
                                         (SELECT max(h) FROM unnest(v.hours) h) + interval '1 hour', SQLERRM);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'job_stats_hourly: the rollup of instance % failed and could not be recorded: %', v.instance_id, SQLERRM;
      END;
    END;
  END LOOP;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.job_stats_pg_tg()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v record; v_budget int := coalesce(nullif(current_setting('pgvigil.job_stats_heal_ms', true), '')::int, 2000);
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
      PERFORM pgvigil.job_stats_heal(v.instance_id, v_budget);
      PERFORM pgvigil.job_stats_hours_pg(v.instance_id, v.hours);
    EXCEPTION WHEN OTHERS THEN
      BEGIN
        PERFORM pgvigil.job_stats_failed(v.instance_id, 'job_runs', (SELECT min(h) FROM unnest(v.hours) h),
                                         (SELECT max(h) FROM unnest(v.hours) h) + interval '1 hour', SQLERRM);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'job_stats_hourly: the rollup of instance % failed and could not be recorded: %', v.instance_id, SQLERRM;
      END;
    END;
  END LOOP;
  RETURN NULL;
END $$;

-- job_stats_7day: the fleet Jobs page's four 7-day columns per job of the instances p_ids (NULL = every active
-- instance), read from the hours with DBA Dash 4.24.1's arithmetic (AgentJob7Day.sql): at step 0, the successes of
-- the hours that started within 24 hours / 168 hours of now (DATEADD on GETUTCDATE(): whole hours, whatever the
-- session's zone; an hour is in when its start is, and an hour dated after now counts, as in DBA Dash), the longest =
-- the largest hourly maximum, the average = the average over the hours of each hour's total / (failed + succeeded),
-- both in whole seconds as DBA Dash's integers give them. 'building': the instance's hours of the 7 days are not built
-- yet (stored runs and no first build queued, or a dirty range inside the 7 days) - its four values are then NULL
CREATE OR REPLACE FUNCTION pgvigil.job_stats_7day(p_ids int[])
RETURNS TABLE (instance_id int, scheduler text, job_id text, ok_24h bigint, ok_7d bigint, max_secs_7d numeric, avg_secs_7d numeric, building boolean)
LANGUAGE sql STABLE AS $$
  WITH ids AS (SELECT unnest(coalesce(p_ids, ARRAY(SELECT x.instance_id FROM pgvigil.instances x WHERE x.is_active))) AS instance_id),
  b AS (SELECT i.instance_id,
               (NOT EXISTS (SELECT 1 FROM pgvigil.job_stats_first_build f WHERE f.instance_id = i.instance_id)
                AND (EXISTS (SELECT 1 FROM pgvigil.mssql_job_runs r WHERE r.instance_id = i.instance_id)
                     OR EXISTS (SELECT 1 FROM pgvigil.job_runs r WHERE r.instance_id = i.instance_id)))
               OR EXISTS (SELECT 1 FROM pgvigil.job_stats_dirty d WHERE d.instance_id = i.instance_id
                             AND d.to_at > now() - interval '168 hours' AND d.from_at < now() + interval '1 hour') AS building
          FROM ids i),
  h AS (SELECT s.instance_id, s.scheduler, s.job_id,
               sum(s.succeeded) FILTER (WHERE s.snapshot_at >= now() - interval '24 hours') AS ok_24h,
               sum(s.succeeded) AS ok_7d,
               trunc(max(s.max_secs))::numeric AS max_secs_7d,
               trunc(avg(trunc(s.total_secs / nullif(s.succeeded + s.failed, 0))))::numeric AS avg_secs_7d
          FROM pgvigil.job_stats_hourly s JOIN ids i ON i.instance_id = s.instance_id
         WHERE s.step_id = 0 AND s.snapshot_at >= now() - interval '168 hours'
         GROUP BY s.instance_id, s.scheduler, s.job_id)
  SELECT m.instance_id, 'sqlagent'::text, m.job_id,
         CASE WHEN NOT b.building THEN coalesce(h.ok_24h, 0) END, CASE WHEN NOT b.building THEN coalesce(h.ok_7d, 0) END,
         CASE WHEN NOT b.building THEN h.max_secs_7d END, CASE WHEN NOT b.building THEN h.avg_secs_7d END, b.building
    FROM pgvigil.mssql_jobs m JOIN b ON b.instance_id = m.instance_id
    LEFT JOIN h ON h.instance_id = m.instance_id AND h.scheduler = 'sqlagent' AND h.job_id = m.job_id
  UNION ALL
  SELECT g.instance_id, g.scheduler, g.job_id::text,
         CASE WHEN NOT b.building THEN coalesce(h.ok_24h, 0) END, CASE WHEN NOT b.building THEN coalesce(h.ok_7d, 0) END,
         CASE WHEN NOT b.building THEN h.max_secs_7d END, CASE WHEN NOT b.building THEN h.avg_secs_7d END, b.building
    FROM pgvigil.jobs g JOIN b ON b.instance_id = g.instance_id
    LEFT JOIN h ON h.instance_id = g.instance_id AND h.scheduler = g.scheduler AND h.job_id = g.job_id::text
   WHERE g.is_present
$$;

-- job_stats_hourly_purge: the months of job_stats_hourly wholly older than its hours_retention row (730 days when
-- absent) dropped; returns their names (purge()'s last block adds them to the run's partitions_dropped). The heals
-- are the purge command's, one instance per transaction (job_stats_pending, job_stats_heal_one), not this function's.
CREATE OR REPLACE FUNCTION pgvigil.job_stats_hourly_purge()
RETURNS text[] LANGUAGE plpgsql AS $$
DECLARE v_days int; v_part record; v_names text[] := '{}';
BEGIN
  SELECT r.days INTO v_days FROM pgvigil.hours_retention r WHERE r.table_name = 'job_stats_hourly';
  v_days := coalesce(v_days, 730);
  FOR v_part IN
    SELECT c.relname
      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent = 'pgvigil.job_stats_hourly'::regclass
       -- a name ending in a month (YYYYMM), parsed inside a CASE: the server may test these conditions on every pg_class
       -- row before the join, in any order, and a TOAST table pg_toast_<six digits> ending in no month (a database past
       -- OID 100,000) failed the whole purge with 22008 (proof-purge's OID row)
       AND c.relname ~ '_[0-9]{4}(0[1-9]|1[0-2])$'
       AND (CASE WHEN c.relname ~ '_[0-9]{4}(0[1-9]|1[0-2])$' THEN to_date(right(c.relname, 6) || '01', 'YYYYMMDD') END
            + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => v_days)
     ORDER BY c.relname
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    v_names := v_names || v_part.relname::text;
  END LOOP;
  RETURN v_names;
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
