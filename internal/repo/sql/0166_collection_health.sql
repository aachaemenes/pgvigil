-- 0166: collection health at DBA Dash 4.25.0's depth (B6.1) - a run-status row per instance and collection (DBA
-- Dash's dbo.CollectionRunStatus), the runs per instance, collection and UTC hour (its CollectionRuns rolled up), and
-- ONE status function the Summary and the Collection Health page both read (DBA Dash's CollectionHealthStatus with
-- its default thresholds, CollectionHealthThresholdDefaults.sql:18-25). Nothing here is defined again by 0190, which
-- applies after this file (purge() is 0190's: this table has its own trim, in import_collection_health).

-- the run status: the last run and how it ended, the failures in a row (a connect failure included: it is logged as
-- an 'error' run, 0118), the last success (an ok or a partial run: DBA Dash counts a partial as a success for the
-- streak and Last Success, CollectionRuns_Upd.sql:352-355), the last failure and the last partial. A skip is no run,
-- but it ends a streak (pgvigil's own rule, heartbeat.go record(): a collection that skips after it failed is failing
-- no more): the skip that ends one is written as the last status 'skipped', so the rate's critical arm (the last run
-- failed) ends with it too. Fillfactor 70: the row is updated at every run, no index on an updated column (HOT).
CREATE TABLE IF NOT EXISTS pgvigil.collection_run_status (
  instance_id           int NOT NULL REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  collection            text NOT NULL,
  last_run_at           timestamptz NOT NULL,      -- the last run, or the skip that ended its failures in a row
  last_status           text NOT NULL,             -- ok | partial | error | skipped (that skip)
  consecutive_failures  int NOT NULL DEFAULT 0,
  last_ok_at            timestamptz,               -- the last ok or partial run
  last_failure_at       timestamptz,
  last_partial_at       timestamptz,
  PRIMARY KEY (instance_id, collection)
) WITH (fillfactor = 70);

-- kept from collection_dates, which every run that reached the repository writes (log_collection, 0001; a connect
-- failure through 0118's import_connect_failure; a failure before the instance's row was read - the server's version
-- read, Detect - through import_run_failure below): a row trigger, as 0134's dbadash_move_reads, so no function
-- another file redefines is touched. A run that failed on the repository's own side (EnsureInstance) is not logged.
CREATE OR REPLACE FUNCTION pgvigil.collection_run_status_take() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'skipped' THEN
    -- a skip ends the failures in a row (it writes only then: a skip after an ok run is no run, nothing changes)
    UPDATE pgvigil.collection_run_status
       SET consecutive_failures = 0, last_status = 'skipped', last_run_at = NEW.snapshot_at
     WHERE instance_id = NEW.instance_id AND collection = NEW.collection
       AND consecutive_failures > 0 AND NEW.snapshot_at >= last_run_at;
    RETURN NULL;
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
  FOR EACH ROW WHEN (NEW.status IN ('ok', 'partial', 'error', 'skipped'))
  EXECUTE FUNCTION pgvigil.collection_run_status_take();

-- an upgraded store starts from each collection's last run (collection_dates holds one per instance and collection):
-- a collection whose last run was ok keeps its last success, one whose last run failed starts at 1 failure in a row
-- (collection_log keeps no ok run, so an older success is not known: 'never succeeded' until its next one). The
-- trigger's lock on collection_dates holds a concurrent run's write out until this file commits.
INSERT INTO pgvigil.collection_run_status (instance_id, collection, last_run_at, last_status, consecutive_failures,
                                           last_ok_at, last_failure_at, last_partial_at)
SELECT d.instance_id, d.collection, d.snapshot_at, d.status, (d.status = 'error')::int,
       CASE WHEN d.status <> 'error' THEN d.snapshot_at END, CASE WHEN d.status = 'error' THEN d.snapshot_at END,
       CASE WHEN d.status = 'partial' THEN d.snapshot_at END
  FROM pgvigil.collection_dates d
 WHERE d.status IN ('ok', 'partial', 'error')
ON CONFLICT (instance_id, collection) DO NOTHING;

-- import_run_failure: a run that connected but failed before the instance's row was read (the server's version read,
-- Detect: a server under load, a login missing a right it needs), recorded as that collection's error with the note
-- 'detect: <the error>' - never 'connect: ' (0118's 'server unreachable' reads only those). An instance with no row,
-- or a retired one, is left alone (its row is made by a read that gets past Detect, or by a connect failure). The
-- collector's door (an import_ function: apply_roles makes it SECURITY DEFINER and the collector's).
CREATE OR REPLACE FUNCTION pgvigil.import_run_failure(p_name text, p_engine text, p_collection text, p_at timestamptz,
                                                      p_duration_ms int, p_error text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id int;
BEGIN
  SELECT i.instance_id INTO v_id FROM pgvigil.instances i WHERE i.name = p_name AND i.engine = p_engine AND i.is_active;
  IF v_id IS NULL THEN RETURN; END IF;
  PERFORM pgvigil.log_collection(v_id, p_collection, p_at, p_duration_ms, 'error', 'detect: ' || left(coalesce(nullif(p_error, ''), 'no reason given'), 2000));
END $$;

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
-- (docs/collection-health.md); more than 30 is refused (the CHECK below: 'pgvigil purge -hours
-- collection_health_hour=40' fails in words, never trims silently at 30), and the trim clamps it to 1-30 as well
INSERT INTO pgvigil.hours_retention (table_name, days) VALUES ('collection_health_hour', 8) ON CONFLICT (table_name) DO NOTHING;
ALTER TABLE pgvigil.hours_retention DROP CONSTRAINT IF EXISTS hours_retention_collection_health_30;
ALTER TABLE pgvigil.hours_retention ADD CONSTRAINT hours_retention_collection_health_30
  CHECK (table_name <> 'collection_health_hour' OR days <= 30);

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
         last_ok_at = EXCLUDED.last_ok_at, last_failure_at = EXCLUDED.last_failure_at, last_partial_at = EXCLUDED.last_partial_at
   -- a row the beat sends unchanged (the hour before, a slow collection's) is not written again: every counted run
   -- raises runs or skipped, so a change is never missed, and a lost beat still differs from the stored row
   WHERE (h.runs, h.skipped) IS DISTINCT FROM (EXCLUDED.runs, EXCLUDED.skipped);
  GET DIAGNOSTICS n = ROW_COUNT;
  DELETE FROM pgvigil.collection_health_hour
   WHERE hour < now() - make_interval(days => (SELECT least(greatest(coalesce(max(r.days), 8), 1), 30) FROM pgvigil.hours_retention r
                                                WHERE r.table_name = 'collection_health_hour'));
  RETURN n;
END $$;

-- collection_health: ONE status per instance and collection, DBA Dash's rule with its default numbers
-- (CollectionHealthStatus.sql; B6g makes them settable): failures in a row counted in runs AND in minutes since the
-- LAST SUCCESS to the latest failure (minute boundaries, as DATEDIFF(mi); never succeeded: runs only) - critical 3
-- runs and 30 minutes, warning 1 and 10; over the runs since p_rate_from rounded UP to the next whole hour
-- (CollectionHealthRateFrom.sql:10-12), 5 or more known runs: critical when 50 % or more failed and the last run
-- failed, warning when 10 % or more failed or ended partial. The worse of the two tiers is the status, and the reason
-- is that tier's (the streak's when both are equal). N/A: the collection off for the instance (its interval 0 in
-- p_expected, the stale check's {"defaults": {...}, "instances": {name: {...}}}) or no known run (skips only). A
-- collection failing now is listed even with no run since p_rate_from - while its last run is within three of its
-- intervals and at least a day (a collection removed from the configuration while it failed leaves the list then;
-- B6.1 has no acknowledge). An inactive instance is not listed (DBA Dash's CollectionHealth_Get: IsActive = 1).
-- The Summary and the page both read this. p_rate_to (B6.2: a picked range in the past) ends the runs counted
-- (hours that begin before it; NULL = now); the failures in a row are always now's, as DBA Dash's.
-- p_instances / p_collection (the review of B6.2, part a #4): the page's scope applied inside, on the hourly scan and on
-- the run status side, so an instance's page never aggregates the fleet; the durations and rows written come from the
-- same scan (the page read them twice). NULL = every instance / every collection (the Summary's call)
CREATE OR REPLACE FUNCTION pgvigil.collection_health(p_rate_from timestamptz, p_expected jsonb DEFAULT NULL, p_rate_to timestamptz DEFAULT NULL,
                                                     p_instances int[] DEFAULT NULL, p_collection text DEFAULT NULL)
RETURNS TABLE (instance_id int, collection text, status text, status_reason text, failing_minutes int, consecutive_failures int,
               runs int, ok int, partial int, failed int, skipped int, failed_pct numeric, problem_pct numeric,
               last_run_at timestamptz, last_ok_at timestamptz, last_failure_at timestamptz, last_partial_at timestamptz,
               dur_sum numeric, dur_max int, rows_written numeric)
LANGUAGE sql STABLE SET jit = off AS $$
  WITH h AS (
    SELECT h.instance_id, h.collection, sum(h.runs)::int AS runs, sum(h.ok)::int AS ok, sum(h.partial)::int AS partial,
           sum(h.failed)::int AS failed, sum(h.skipped)::int AS skipped,
           sum(h.dur_ms_sum) AS dur_sum, max(h.dur_ms_max) AS dur_max, sum(h.rows_written) AS rows_written
      FROM pgvigil.collection_health_hour h
     WHERE h.hour >= date_trunc('hour', (p_rate_from AT TIME ZONE 'UTC') + interval '1 hour' - interval '1 microsecond') AT TIME ZONE 'UTC'
       AND (p_rate_to IS NULL OR h.hour < p_rate_to)
       AND (p_instances IS NULL OR h.instance_id = ANY (p_instances)) AND (p_collection IS NULL OR h.collection = p_collection)
     GROUP BY h.instance_id, h.collection
  ), k AS (
    SELECT coalesce(h.instance_id, s.instance_id) AS instance_id, coalesce(h.collection, s.collection) AS collection,
           h.instance_id IS NOT NULL AS in_range,
           coalesce(h.runs, 0) AS runs, coalesce(h.ok, 0) AS ok, coalesce(h.partial, 0) AS partial,
           coalesce(h.failed, 0) AS failed, coalesce(h.skipped, 0) AS skipped,
           s.last_run_at, s.last_status, coalesce(s.consecutive_failures, 0) AS cf, s.last_ok_at, s.last_failure_at, s.last_partial_at,
           h.dur_sum, h.dur_max, h.rows_written
      FROM h FULL JOIN (SELECT x.* FROM pgvigil.collection_run_status x
                         WHERE (p_instances IS NULL OR x.instance_id = ANY (p_instances)) AND (p_collection IS NULL OR x.collection = p_collection)) s
             ON s.instance_id = h.instance_id AND s.collection = h.collection
     WHERE h.instance_id IS NOT NULL OR s.consecutive_failures > 0   -- failing now: listed with no run in the range
  ), j AS (
    SELECT k.*, i.name,
           coalesce((p_expected -> 'instances' -> i.name ->> k.collection)::int, (p_expected -> 'defaults' ->> k.collection)::int, -1) AS iv,
           CASE WHEN k.cf = 0 THEN 0
                WHEN k.last_ok_at IS NOT NULL
                THEN (extract(epoch FROM date_trunc('minute', k.last_failure_at) - date_trunc('minute', k.last_ok_at)) / 60)::int END AS fm,
           k.ok + k.partial + k.failed AS known
      FROM k JOIN pgvigil.instances i ON i.instance_id = k.instance_id
     WHERE i.is_active
  ), t AS (
    SELECT j.*,
           CASE WHEN j.cf >= 3 AND (j.fm IS NULL OR j.fm >= 30) THEN 2
                WHEN j.cf >= 1 AND (j.fm IS NULL OR j.fm >= 10) THEN 1 ELSE 0 END AS st,
           CASE WHEN j.known >= 5 AND j.failed * 2 >= j.known AND j.last_status = 'error' THEN 2
                WHEN j.known >= 5 AND (j.failed + j.partial) * 10 >= j.known THEN 1 ELSE 0 END AS rt,
           j.iv = 0 OR (j.known = 0 AND j.cf = 0) AS na
      FROM j
     WHERE j.in_range OR j.last_run_at >= now() - make_interval(secs => greatest(3 * j.iv, 86400))
  )
  SELECT t.instance_id, t.collection,
         CASE WHEN t.na THEN 'n/a' WHEN greatest(t.st, t.rt) = 2 THEN 'critical' WHEN greatest(t.st, t.rt) = 1 THEN 'warning' ELSE 'ok' END,
         CASE WHEN t.iv = 0 THEN 'collection off'
              WHEN t.na THEN 'no runs (skipped only)'
              WHEN t.st > 0 AND t.st >= t.rt
                THEN t.cf || ' failure(s) in a row' || CASE WHEN t.fm IS NULL THEN ', never succeeded' ELSE ', failing ' || t.fm || ' min' END
              WHEN t.rt > 0
                THEN round(100.0 * t.failed / t.known) || ' % failed, ' || round(100.0 * t.partial / t.known) || ' % partial of ' || t.known || ' runs'
              ELSE '' END,
         t.fm, t.cf, t.runs, t.ok, t.partial, t.failed, t.skipped,
         CASE WHEN t.known > 0 THEN round(100.0 * t.failed / t.known, 1) END,
         CASE WHEN t.known > 0 THEN round(100.0 * (t.failed + t.partial) / t.known, 1) END,
         t.last_run_at, t.last_ok_at, t.last_failure_at, t.last_partial_at, t.dur_sum, t.dur_max, t.rows_written
    FROM t
$$;

-- the Summary's 'Collection Health' cell per instance (DBA Dash's Summary_Upd.sql:156-158): the worst status but N/A,
-- n = the collections at warning or critical, all_na when every listed collection is N/A (the cell then says N/A, as
-- DBA Dash's ISNULL(MIN(NULLIF(...,3)),3)); the window 24 hours from the next whole hour (CollectionHealthRateFrom.sql)
CREATE OR REPLACE FUNCTION pgvigil.collection_health_summary(p_expected jsonb DEFAULT NULL)
RETURNS TABLE (instance_id int, level int, n int, collections text, all_na boolean)
LANGUAGE sql STABLE SET jit = off AS $$
  SELECT c.instance_id,
         coalesce(max(CASE c.status WHEN 'critical' THEN 2 WHEN 'warning' THEN 1 ELSE 0 END) FILTER (WHERE c.status <> 'n/a'), 0)::int,
         count(*) FILTER (WHERE c.status IN ('warning', 'critical'))::int,
         string_agg(c.collection || ' ' || c.status, ', ' ORDER BY c.status = 'critical' DESC, c.collection)
           FILTER (WHERE c.status IN ('warning', 'critical')),
         bool_and(c.status = 'n/a')
    FROM pgvigil.collection_health(date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - interval '23 hours', p_expected) c
   GROUP BY c.instance_id
$$;

-- the error list of the Collection Health page (B6.2: one instance and collection, or one collection over a scope,
-- between two times): its errors only. collection_log is a plain table (0001), so this build holds its writes for its
-- length at the upgrade - measured at 10M rows on the box before it is kept here (the lead's 23:2x call)
CREATE INDEX IF NOT EXISTS collection_log_errors_idx ON pgvigil.collection_log (instance_id, collection, snapshot_at) WHERE status = 'error';

-- B6.4 (DONE-3, the lead's 23:4x calls): pgvigil's own health findings, each a view in the findings' columns; each is
-- an arm of 0190's pgvigil.findings (a WIRING line there: this file never redefines what 0190 defines).

-- 'collection runs long' (CHK#38 / OVW#140; source 'pgvigil collector', per instance and collection): over the current
-- and the previous UTC hour of collection_health_hour, with 5 or more runs - critical when more than 5 % of the runs
-- took longer than the collection's interval (its p95 over the interval), warning when more than 5 % took longer than
-- half of it. A collection's interval is the shortest its runs were scheduled at (interval_s).
CREATE OR REPLACE VIEW pgvigil.collection_runs_long_findings AS
SELECT h.instance_id,
       CASE WHEN sum(h.runs_over_interval) * 20 > sum(h.runs) THEN 'critical' ELSE 'warning' END AS severity,
       'collection runs long'::text AS setting, h.collection AS value, NULL::boolean AS is_set,
       'a longer interval for the collection (its schedules: in pgvigil.yaml), or what slows it on the server'::text AS suggested,
       'all'::text AS platforms,
       format('%s of %s run(s) since %s UTC took longer than half the collection''s %s s interval, %s longer than all of it',
              sum(h.runs_over_half), sum(h.runs), to_char(min(h.hour) AT TIME ZONE 'UTC', 'HH24:MI'), min(h.interval_s),
              sum(h.runs_over_interval)) AS detail,
       'pgvigil collector'::text AS source,
       max(greatest(h.last_ok_at, h.last_failure_at, h.last_partial_at)) AS at
  FROM pgvigil.collection_health_hour h
  JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
 WHERE h.hour >= date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - interval '1 hour'
 GROUP BY h.instance_id, h.collection
HAVING sum(h.runs) >= 5 AND sum(h.runs_over_half) * 20 > sum(h.runs);

-- 'collections run long' (B6.4 #4, the lead's 03:2x (a) and 04:2x (i)-(iii); source 'pgvigil repository', the value the
-- collector's HOST): a host slow while its runs succeed (CPU-starved) forms no 'collector or network' parent, so each
-- of its instances would send its own 'collection runs long' - one alert per host instead, on the slow-connect fold's
-- shape (0121 collector_slow_folds). Over the finding's own window (the current and the previous UTC hour) and the
-- host's OWN rows (collection_health_hour by collector_heartbeat.host, every run of the host summed): an instance is
-- JUDGED on the host when a collection of it has 5 or more runs there, and runs LONG there by the finding's rule on
-- those rows (more than 5 % over half the interval: warning; over all of it: critical). The fold FORMS when more than
-- half AND at least 3 of the judged run long, and while its alert is open on a configured channel it STANDS until a
-- quarter or less, or under 3, do (collection_runs_long_open: the hysteresis); critical when more than half of the
-- judged run long at critical. Its members' own 'collection runs long' at or under its level - the higher of its level
-- now and the level its open alert was sent at - are HELD (alert_due's term, 0190 WIRING, through
-- collection_runs_long_held); one above it is sent on its own. Its alert is not resolved while the host's own
-- 'collector or network' stands (alert_due). An arm of 0190's pgvigil.findings (WIRING).
CREATE OR REPLACE FUNCTION pgvigil.collection_runs_long_open(p_host text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pgvigil.alert_state s JOIN pgvigil.alert_channels c ON c.name = s.channel AND c.is_configured
                  WHERE s.cleared_at IS NULL AND s.missing_since IS NULL AND s.source = 'pgvigil repository'
                    AND s.setting = 'collections run long' AND s.value = p_host)
$$;

CREATE OR REPLACE VIEW pgvigil.collection_runs_long_fold AS
WITH r AS (   -- each instance's collections on each host over the window, with 5 or more runs there
  SELECT hb.host, h.instance_id, sum(h.runs) AS runs, sum(h.runs_over_half) AS half, sum(h.runs_over_interval) AS over_i,
         max(greatest(h.last_ok_at, h.last_failure_at, h.last_partial_at)) AS at
    FROM pgvigil.collection_health_hour h
    JOIN (SELECT DISTINCT collector_id, host FROM pgvigil.collector_heartbeat) hb ON hb.collector_id = h.collector_id
    JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
   WHERE h.hour >= date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - interval '1 hour'
   GROUP BY hb.host, h.instance_id, h.collection
  HAVING sum(h.runs) >= 5
), m AS (     -- per host and judged instance: its level there (0 not long, 1 warning, 2 critical)
  SELECT r.host, r.instance_id, max(r.at) AS at,
         max(CASE WHEN r.over_i * 20 > r.runs THEN 2 WHEN r.half * 20 > r.runs THEN 1 ELSE 0 END) AS level
    FROM r GROUP BY r.host, r.instance_id
), hs AS (
  SELECT m.host, count(*) AS judged, count(*) FILTER (WHERE m.level >= 1) AS long_n, count(*) FILTER (WHERE m.level = 2) AS crit_n,
         max(m.at) FILTER (WHERE m.level >= 1) AS at
    FROM m GROUP BY m.host
), hf AS (
  SELECT hs.*, CASE WHEN hs.crit_n * 2 > hs.judged THEN 2 ELSE 1 END AS level
    FROM hs
   WHERE CASE WHEN hs.long_n >= 3 AND hs.long_n * 2 > hs.judged THEN true
              WHEN hs.long_n >= 3 AND hs.long_n * 4 > hs.judged THEN pgvigil.collection_runs_long_open(hs.host)
              ELSE false END
), sent AS (  -- the highest level the fold's open alert was sent at (as collection_runs_long_open's alerts)
  SELECT s.value AS host, max(CASE s.severity WHEN 'critical' THEN 2 WHEN 'warning' THEN 1 ELSE 0 END) AS level
    FROM pgvigil.alert_state s JOIN pgvigil.alert_channels c ON c.name = s.channel AND c.is_configured
   WHERE s.cleared_at IS NULL AND s.missing_since IS NULL AND s.source = 'pgvigil repository' AND s.setting = 'collections run long'
   GROUP BY s.value
), fa AS (
  SELECT hf.host, greatest(hf.level, coalesce(max(sent.level), 0)) AS held_level,
         array_agg(m.instance_id ORDER BY m.instance_id) AS members,
         string_agg(i.name, ', ' ORDER BY m.level DESC, i.name) AS names
    FROM hf JOIN m ON m.host = hf.host AND m.level >= 1
    JOIN pgvigil.instances i ON i.instance_id = m.instance_id
    LEFT JOIN sent ON sent.host = hf.host
   GROUP BY hf.host, hf.level
)
SELECT NULL::int AS instance_id, CASE WHEN hf.level = 2 THEN 'critical' ELSE 'warning' END AS severity,
       'collections run long'::text AS setting, hf.host AS value, NULL::boolean AS is_set,
       'what slows the collector host itself - its CPU, memory or disks (the Collector page''s load and run duration), or fewer instances on it'::text AS suggested,
       'all'::text AS platforms,
       format('collections run long on collector %s: %s of its %s judged instance(s) since %s UTC (%s at critical): %s - the collector''s own load, not the servers''; the members'' own ''collection runs long'' alerts are held while this stands, unless one is over this alert''s level',
              hf.host, hf.long_n, hf.judged,
              to_char((date_trunc('hour', now() AT TIME ZONE 'UTC') - interval '1 hour'), 'YYYY-MM-DD HH24:MI'), hf.crit_n, fa.names) AS detail,
       'pgvigil repository'::text AS source, hf.at AS at,
       fa.members, CASE WHEN fa.held_level = 2 THEN 'critical' ELSE 'warning' END AS held_severity
  FROM hf JOIN fa ON fa.host = hf.host;

-- collection_runs_long_held: per member of a standing fold, the severity at or under which its own 'collection runs
-- long' is held (the highest over its folds: an instance read by two hosts); alert_due (0190) reads it once a pass
CREATE OR REPLACE VIEW pgvigil.collection_runs_long_held AS
SELECT m.instance_id, CASE max(CASE f.held_severity WHEN 'critical' THEN 2 ELSE 1 END) WHEN 2 THEN 'critical' ELSE 'warning' END AS severity
  FROM pgvigil.collection_runs_long_fold f CROSS JOIN LATERAL unnest(f.members) AS m(instance_id)
 GROUP BY m.instance_id;

-- 'alert sender idle' (CHK#35; source 'pgvigil repository', no instance): alert channels configured (a contact's route is
-- not one) and the rules last judged more than 180 s ago - ONE number with the Alert rules page's line (alert_rules.ts
-- 'ago > 180'). Only while a live run says it sends (its beat's sends_alerts: B6.2 part c #3, the lead's 03:2x) - never
-- when no collector beats ('collector not seen' is the cause then: the sender runs inside pgvigil run), nor when every
-- live run has no channel (alerts turned off on purpose), nor before the sender's first pass (the page says so in
-- words). A scheduled 'pgvigil alerts' beside runs with no channel beats nothing: its stop raises no finding. SHOWN, NEVER SENT: 0190's alert_findings leaves
-- it out (a WIRING term) - an idle sender cannot send its own news.
CREATE OR REPLACE VIEW pgvigil.alert_sender_idle_findings AS
SELECT NULL::int AS instance_id, 'warning'::text AS severity, 'alert sender idle'::text AS setting, NULL::text AS value, NULL::boolean AS is_set,
       'pgvigil run''s log: its alert pass runs once a minute; a stopped pass leaves the alert states as they were'::text AS suggested,
       'all'::text AS platforms,
       format('no alert rule judged for %s s (the page''s line is 180 s): the alert states shown are from %s UTC',
              extract(epoch FROM now() - s.evaluated_at)::int, to_char(s.evaluated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')) AS detail,
       'pgvigil repository'::text AS source, s.evaluated_at AS at
  FROM (SELECT max(r.evaluated_at) AS evaluated_at FROM pgvigil.alert_rule_state r) s
 WHERE s.evaluated_at < now() - interval '180 seconds'
   AND EXISTS (SELECT 1 FROM pgvigil.alert_channels c WHERE c.is_configured AND c.name NOT LIKE 'contact-%')
   AND EXISTS (SELECT 1 FROM pgvigil.collector_live l WHERE l.sends_alerts);

-- 'repository autovacuum behind' (PM Added 12; source 'pgvigil repository', warning): a table of the pgvigil schema
-- (each partition judged alone, named with its parent), or its TOAST table (autovacuum judges one on its own; purge's
-- deletes leave a text-heavy table's dead chunks there; B6.2 part c #9), whose dead tuples are over autovacuum's own
-- trigger and at least 10,000, with no vacuum (auto or manual) for 24 hours. The trigger is autovacuum's:
-- autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor x reltuples, capped from PostgreSQL 18 by
-- autovacuum_vacuum_max_threshold (-1: no cap; no such setting before 18), each from the reloptions autovacuum reads
-- (the table's; a TOAST table's own when it has any, else its table's - autovacuum.c do_autovacuum), else the server's.
CREATE OR REPLACE VIEW pgvigil.repository_autovacuum_findings AS
WITH r AS (
  SELECT s.relid AS main_relid, s.relname, s.n_dead_tup, s.n_live_tup, greatest(s.last_autovacuum, s.last_vacuum) AS last_vac,
         greatest(c.reltuples, 0) AS reltuples, c.reloptions AS opts
    FROM pg_stat_user_tables s
    JOIN pg_class c ON c.oid = s.relid
   WHERE s.schemaname = 'pgvigil'
  UNION ALL
  SELECT s.relid, s.relname || ' (TOAST)', ts.n_dead_tup, ts.n_live_tup, greatest(ts.last_autovacuum, ts.last_vacuum),
         greatest(tc.reltuples, 0), coalesce(tc.reloptions, c.reloptions)
    FROM pg_stat_user_tables s
    JOIN pg_class c ON c.oid = s.relid
    JOIN pg_class tc ON tc.oid = c.reltoastrelid
    JOIN pg_stat_all_tables ts ON ts.relid = c.reltoastrelid
   WHERE s.schemaname = 'pgvigil'
), t AS (
  SELECT r.*,
         coalesce((SELECT split_part(o, '=', 2)::float8 FROM unnest(r.opts) o WHERE o LIKE 'autovacuum\_vacuum\_threshold=%'),
                  current_setting('autovacuum_vacuum_threshold')::float8) AS thr,
         coalesce((SELECT split_part(o, '=', 2)::float8 FROM unnest(r.opts) o WHERE o LIKE 'autovacuum\_vacuum\_scale\_factor=%'),
                  current_setting('autovacuum_vacuum_scale_factor')::float8) AS sf,
         coalesce((SELECT split_part(o, '=', 2)::float8 FROM unnest(r.opts) o WHERE o LIKE 'autovacuum\_vacuum\_max\_threshold=%'),
                  nullif(current_setting('autovacuum_vacuum_max_threshold', true), '')::float8) AS maxthr,
         (SELECT p.relname FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhparent WHERE i.inhrelid = r.main_relid LIMIT 1) AS parent
    FROM r
), v AS (
  SELECT t.*, greatest(10000, CASE WHEN t.maxthr >= 0 THEN least(t.thr + t.sf * t.reltuples, t.maxthr)
                                   ELSE t.thr + t.sf * t.reltuples END) AS trigger_at
    FROM t
)
SELECT NULL::int AS instance_id, 'warning'::text AS severity, 'repository autovacuum behind'::text AS setting,
       -- relname is type name (collation "C"): the default collation, as every findings arm's value (0110's view)
       (coalesce(v.parent || ' / ', '') || v.relname)::text COLLATE "default" AS value, NULL::boolean AS is_set,
       'the repository''s autovacuum settings (autovacuum_max_workers, the table''s reloptions), or a VACUUM of the table'::text AS suggested,
       'all'::text AS platforms,
       format('%s dead tuple(s), %s live; autovacuum''s own trigger is %s; last vacuumed %s', v.n_dead_tup, v.n_live_tup,
              round(v.trigger_at), coalesce(to_char(v.last_vac AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'never')) AS detail,
       'pgvigil repository'::text AS source, now() AS at
  FROM v
 WHERE v.n_dead_tup > v.trigger_at
   AND (v.last_vac IS NULL OR v.last_vac < now() - interval '24 hours');
