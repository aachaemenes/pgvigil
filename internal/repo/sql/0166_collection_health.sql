-- 0166: collection health at DBA Dash 4.25.0's depth (B6.1) - a run-status row per instance and collection (DBA
-- Dash's dbo.CollectionRunStatus), the runs per instance, collection and UTC hour (its CollectionRuns rolled up), and
-- ONE status function the Summary and the Collection Health page both read (DBA Dash's CollectionHealthStatus with
-- its default thresholds, CollectionHealthThresholdDefaults.sql:18-25). Nothing here is defined again by 0190, which
-- applies after this file (purge() is 0190's: this table has its own trim, in import_collection_health).

-- the run status: the last run and how it ended, the failures in a row (a connect failure included: it is logged as
-- an 'error' run, 0118), the last success (an ok or a partial run: DBA Dash counts a partial as a success for the
-- streak and Last Success, CollectionRuns_Upd.sql:352-355), the last failure and the last partial. A skip is no run.
CREATE TABLE IF NOT EXISTS pgvigil.collection_run_status (
  instance_id           int NOT NULL REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  collection            text NOT NULL,
  last_run_at           timestamptz NOT NULL,
  last_status           text NOT NULL,             -- ok | partial | error
  consecutive_failures  int NOT NULL DEFAULT 0,
  last_ok_at            timestamptz,               -- the last ok or partial run
  last_failure_at       timestamptz,
  last_partial_at       timestamptz,
  PRIMARY KEY (instance_id, collection)
);

-- kept from collection_dates, which every run writes (log_collection, 0001; a connect failure through 0118): a row
-- trigger, as 0134's dbadash_move_reads, so no function another file redefines is touched
CREATE OR REPLACE FUNCTION pgvigil.collection_run_status_take() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status NOT IN ('ok', 'partial', 'error') THEN
    RETURN NULL;   -- a skip (or any status that is not a run's outcome) leaves the run status as it is
  END IF;
  INSERT INTO pgvigil.collection_run_status AS s (instance_id, collection, last_run_at, last_status, consecutive_failures,
                                                  last_ok_at, last_failure_at, last_partial_at)
  VALUES (NEW.instance_id, NEW.collection, NEW.snapshot_at, NEW.status, CASE WHEN NEW.status = 'error' THEN 1 ELSE 0 END,
          CASE WHEN NEW.status <> 'error' THEN NEW.snapshot_at END, CASE WHEN NEW.status = 'error' THEN NEW.snapshot_at END,
          CASE WHEN NEW.status = 'partial' THEN NEW.snapshot_at END)
  ON CONFLICT (instance_id, collection) DO UPDATE
     SET last_run_at = EXCLUDED.last_run_at, last_status = EXCLUDED.last_status,
         consecutive_failures = CASE WHEN EXCLUDED.last_status = 'error' THEN s.consecutive_failures + 1 ELSE 0 END,
         last_ok_at = coalesce(EXCLUDED.last_ok_at, s.last_ok_at),
         last_failure_at = coalesce(EXCLUDED.last_failure_at, s.last_failure_at),
         last_partial_at = coalesce(EXCLUDED.last_partial_at, s.last_partial_at)
   WHERE EXCLUDED.last_run_at >= s.last_run_at;   -- an older run written late never moves the status back
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS collection_run_status_take ON pgvigil.collection_dates;
CREATE TRIGGER collection_run_status_take AFTER INSERT OR UPDATE ON pgvigil.collection_dates
  FOR EACH ROW EXECUTE FUNCTION pgvigil.collection_run_status_take();

-- the runs per instance, collection, UTC hour and collector run: RUNNING TOTALS since that run began, written by its
-- beat once a minute (SET = EXCLUDED: a lost beat is repaired by the next); readers sum over collector_id. Known runs
-- = ok + partial + error (a skip is not one). Fillfactor 70 and no index on an updated column keep the updates HOT.
CREATE TABLE IF NOT EXISTS pgvigil.collection_health_hour (
  hour             timestamptz NOT NULL,
  instance_id      int NOT NULL REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  collection       text NOT NULL,
  collector_id     text NOT NULL,
  runs             int NOT NULL,
  ok               int NOT NULL,
  partial          int NOT NULL,
  failed           int NOT NULL,
  skipped          int NOT NULL,
  rows_written     bigint NOT NULL,
  dur_ms_sum       bigint NOT NULL,
  dur_ms_max       int NOT NULL,
  runs_over_half   int NOT NULL,
  runs_over_interval int NOT NULL,
  interval_s       int,
  last_ok_at       timestamptz,
  last_failure_at  timestamptz,
  last_partial_at  timestamptz,
  PRIMARY KEY (hour, instance_id, collection, collector_id)
) WITH (fillfactor = 70);
CREATE INDEX IF NOT EXISTS collection_health_hour_instance ON pgvigil.collection_health_hour (instance_id, hour);

-- 8 days by default (as collector_load); settable up to 30 with
--   UPDATE pgvigil.hours_retention SET days = 30, changed_at = now() WHERE table_name = 'collection_health_hour';
-- (docs/collection-health.md); the trim clamps it to 1-30 whatever the row says
INSERT INTO pgvigil.hours_retention (table_name, days) VALUES ('collection_health_hour', 8) ON CONFLICT (table_name) DO NOTHING;

-- the beat's door for the hourly rows: one set-based statement a beat (the beat's jsonb 'health' array, heartbeat.go
-- beatHealth), instances by name (a name not in pgvigil.instances is left out), then the table's own trim
CREATE OR REPLACE FUNCTION pgvigil.import_collection_health(p_id text, p_beat jsonb) RETURNS int
LANGUAGE plpgsql SET jit = off AS $$
DECLARE n int;
BEGIN
  INSERT INTO pgvigil.collection_health_hour AS h (hour, instance_id, collection, collector_id, runs, ok, partial, failed, skipped,
         rows_written, dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s, last_ok_at, last_failure_at, last_partial_at)
  SELECT x.hour, i.instance_id, x.collection, p_id, x.runs, x.ok, x.partial, x.error, x.skipped, x.rows, x.dur_ms_sum, x.dur_ms_max,
         x.over_half, x.over_interval, nullif(x.interval_s, 0), x.last_ok_at, x.last_error_at, x.last_partial_at
    FROM jsonb_to_recordset(coalesce(p_beat -> 'health', '[]')) AS x(instance text, collection text, hour timestamptz, runs int, ok int,
           partial int, error int, skipped int, rows bigint, dur_ms_sum bigint, dur_ms_max int, over_half int, over_interval int,
           interval_s int, last_ok_at timestamptz, last_error_at timestamptz, last_partial_at timestamptz)
    JOIN pgvigil.instances i ON i.name = x.instance
  ON CONFLICT (hour, instance_id, collection, collector_id) DO UPDATE
     SET runs = EXCLUDED.runs, ok = EXCLUDED.ok, partial = EXCLUDED.partial, failed = EXCLUDED.failed, skipped = EXCLUDED.skipped,
         rows_written = EXCLUDED.rows_written, dur_ms_sum = EXCLUDED.dur_ms_sum, dur_ms_max = EXCLUDED.dur_ms_max,
         runs_over_half = EXCLUDED.runs_over_half, runs_over_interval = EXCLUDED.runs_over_interval, interval_s = EXCLUDED.interval_s,
         last_ok_at = EXCLUDED.last_ok_at, last_failure_at = EXCLUDED.last_failure_at, last_partial_at = EXCLUDED.last_partial_at;
  GET DIAGNOSTICS n = ROW_COUNT;
  DELETE FROM pgvigil.collection_health_hour
   WHERE hour < now() - make_interval(days => (SELECT least(greatest(coalesce(max(r.days), 8), 1), 30) FROM pgvigil.hours_retention r
                                                WHERE r.table_name = 'collection_health_hour'));
  RETURN n;
END $$;

-- collection_health: ONE status per instance and collection, DBA Dash's rule with its default numbers
-- (CollectionHealthStatus.sql; B6g makes them settable): failures in a row counted in runs AND in minutes since the
-- LAST SUCCESS to the latest failure (never succeeded: runs only) - critical 3 runs and 30 minutes, warning 1 and 10;
-- over the runs since p_rate_from (5 or more known runs): critical when 50 % or more failed and the last run failed,
-- warning when 10 % or more failed or ended partial. N/A: the collection off for the instance (its interval 0 in
-- p_expected, the stale check's {"defaults": {...}, "instances": {name: {...}}}) or no known run (skips only).
-- A collection failing now is listed even with no run since p_rate_from. The Summary and the page both read this.
CREATE OR REPLACE FUNCTION pgvigil.collection_health(p_rate_from timestamptz, p_expected jsonb DEFAULT NULL)
RETURNS TABLE (instance_id int, collection text, status text, status_reason text, failing_minutes int, consecutive_failures int,
               runs int, ok int, partial int, failed int, skipped int, failed_pct numeric, problem_pct numeric,
               last_run_at timestamptz, last_ok_at timestamptz, last_failure_at timestamptz, last_partial_at timestamptz)
LANGUAGE sql STABLE SET jit = off AS $$
  WITH h AS (
    SELECT h.instance_id, h.collection, sum(h.runs)::int AS runs, sum(h.ok)::int AS ok, sum(h.partial)::int AS partial,
           sum(h.failed)::int AS failed, sum(h.skipped)::int AS skipped
      FROM pgvigil.collection_health_hour h
     WHERE h.hour >= date_trunc('hour', p_rate_from AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
     GROUP BY h.instance_id, h.collection
  ), k AS (
    SELECT coalesce(h.instance_id, s.instance_id) AS instance_id, coalesce(h.collection, s.collection) AS collection,
           coalesce(h.runs, 0) AS runs, coalesce(h.ok, 0) AS ok, coalesce(h.partial, 0) AS partial,
           coalesce(h.failed, 0) AS failed, coalesce(h.skipped, 0) AS skipped,
           s.last_run_at, s.last_status, coalesce(s.consecutive_failures, 0) AS cf, s.last_ok_at, s.last_failure_at, s.last_partial_at
      FROM h FULL JOIN pgvigil.collection_run_status s ON s.instance_id = h.instance_id AND s.collection = h.collection
     WHERE h.instance_id IS NOT NULL OR s.consecutive_failures > 0   -- failing now: listed with no run in the range
  ), j AS (
    SELECT k.*, i.name,
           coalesce((p_expected -> 'instances' -> i.name ->> k.collection)::int, (p_expected -> 'defaults' ->> k.collection)::int, -1) AS iv,
           CASE WHEN k.cf > 0 AND k.last_ok_at IS NOT NULL
                THEN floor(extract(epoch FROM k.last_failure_at - k.last_ok_at) / 60)::int END AS fm,
           k.ok + k.partial + k.failed AS known
      FROM k JOIN pgvigil.instances i ON i.instance_id = k.instance_id
     WHERE i.is_active
  )
  SELECT j.instance_id, j.collection,
         CASE WHEN j.iv = 0 OR (j.known = 0 AND j.cf = 0) THEN 'n/a'
              WHEN j.cf >= 3 AND (j.fm IS NULL OR j.fm >= 30) THEN 'critical'
              WHEN j.known >= 5 AND j.failed * 2 >= j.known AND j.last_status = 'error' THEN 'critical'
              WHEN j.cf >= 1 AND (j.fm IS NULL OR j.fm >= 10) THEN 'warning'
              WHEN j.known >= 5 AND (j.failed + j.partial) * 10 >= j.known THEN 'warning'
              ELSE 'ok' END,
         CASE WHEN j.iv = 0 THEN 'collection off'
              WHEN j.known = 0 AND j.cf = 0 THEN 'no runs (skipped only)'
              WHEN j.cf >= 1 AND (j.fm IS NULL OR j.fm >= 10)
                THEN j.cf || ' failure(s) in a row' || CASE WHEN j.fm IS NULL THEN ', never succeeded' ELSE ', failing ' || j.fm || ' min' END
              WHEN j.known >= 5 AND (j.failed + j.partial) * 10 >= j.known
                THEN round(100.0 * j.failed / j.known) || ' % failed, ' || round(100.0 * j.partial / j.known) || ' % partial of ' || j.known || ' runs'
              ELSE '' END,
         j.fm, j.cf, j.runs, j.ok, j.partial, j.failed, j.skipped,
         CASE WHEN j.known > 0 THEN round(100.0 * j.failed / j.known, 1) END,
         CASE WHEN j.known > 0 THEN round(100.0 * (j.failed + j.partial) / j.known, 1) END,
         j.last_run_at, j.last_ok_at, j.last_failure_at, j.last_partial_at
    FROM j
$$;

-- the Summary's 'Collection Health' cell per instance (DBA Dash's Summary_Upd.sql:156-158): the worst status but N/A,
-- n = the collections at warning or critical; the window 24 hours from the next whole hour (CollectionHealthRateFrom.sql)
CREATE OR REPLACE FUNCTION pgvigil.collection_health_summary(p_expected jsonb DEFAULT NULL)
RETURNS TABLE (instance_id int, level int, n int, collections text)
LANGUAGE sql STABLE SET jit = off AS $$
  SELECT c.instance_id,
         max(CASE c.status WHEN 'critical' THEN 2 WHEN 'warning' THEN 1 ELSE 0 END)::int,
         count(*) FILTER (WHERE c.status IN ('warning', 'critical'))::int,
         string_agg(c.collection || ' ' || c.status, ', ' ORDER BY c.status = 'critical' DESC, c.collection)
           FILTER (WHERE c.status IN ('warning', 'critical'))
    FROM pgvigil.collection_health(date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - interval '23 hours', p_expected) c
   WHERE c.status <> 'n/a'
   GROUP BY c.instance_id
$$;
