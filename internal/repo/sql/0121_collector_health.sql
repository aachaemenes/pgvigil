-- 0121: the collector seen working (task 201; PerformanceMonitor's Collection Health as pgvigil's own page).
--
-- `pgvigil run` beats once a minute (internal/collect/heartbeat.go): who it is (host, OS, how it runs - a systemd unit,
-- a Windows service, a container, a console - its version, pid and start), its memory and goroutines, and what the
-- minute's runs did per collection (runs, failures, rows written, durations as a histogram) and per instance (the
-- connections pgvigil opened - one per run on both engines - its failures and authentication failures), with each
-- instance and collection's failed runs in a row. Every write is an import_ function (SECURITY DEFINER and granted to
-- pgvigil_collector by apply_roles); the beat trims its own history past 8 days, so nothing here waits for purge().
--
-- One collector per repository (v0.4.0): a collector that starts while another host's collector beat in the last 3
-- minutes is refused (import_collector_claim returns why and `pgvigil run` stops), and a running collector that finds
-- an older live collector on another host is refused at its beat; two live collectors on one host (a console run beside
-- the service: a crash leaves no stop mark, so a restart on the same host is never refused) are a critical finding.
--
-- purge() records each run in purge_runs (its line in 0190): when, the days kept, the partitions it dropped and the rows
-- it deleted; 'purge not run in 2 days' is a finding.
--
-- 'collector or network' (no instance) is the one alert for a collector that stopped beating for 5 minutes or a minute in
-- which at least 3 instances and over half of those that ran failed every run: while it stands, alert_due (0190) holds
-- every per-instance alert - none fires, repeats or resolves - and the parent clears by itself.

CREATE TABLE IF NOT EXISTS pgvigil.collector_heartbeat (
  collector_id  text PRIMARY KEY,                 -- host/pid/start: one row per run of `pgvigil run`
  host          text NOT NULL,
  os            text NOT NULL,
  runs_as       text NOT NULL,                    -- systemd unit | windows service | container | console
  version       text NOT NULL,
  pid           int NOT NULL,
  started_at    timestamptz NOT NULL,
  beat_at       timestamptz NOT NULL,
  stopped_at    timestamptz,                      -- a clean stop; a crash leaves it empty and the beat ages
  refused_at    timestamptz,                      -- another collector writes to this repository
  refused_why   text,
  mem_bytes     bigint,                           -- the Go runtime's memory from the OS (runtime.MemStats.Sys)
  goroutines    int,
  instances     int,                              -- instances it ran a collection on in the last minute
  repo_conns    int                               -- the repository's sessions named pgvigil* at the beat (every pgvigil process)
);

CREATE TABLE IF NOT EXISTS pgvigil.collector_beats (
  at            timestamptz NOT NULL,
  collector_id  text NOT NULL,
  mem_bytes     bigint,
  goroutines    int,
  repo_conns    int,
  repo_bytes    bigint,                           -- pg_database_size of the repository at the beat
  runs          int NOT NULL DEFAULT 0,
  failures      int NOT NULL DEFAULT 0,
  rows_written  bigint NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS collector_beats_at ON pgvigil.collector_beats (at);

-- per minute and collection: every instance's runs of it; dur_hist[b + 1] counts the runs of bucket b: b 0 = under 1 ms,
-- b n = 2^(n-1) to 2^n ms, b 18 = 131 s and over
CREATE TABLE IF NOT EXISTS pgvigil.collector_runs (
  minute        timestamptz NOT NULL,
  collector_id  text NOT NULL,
  engine        text NOT NULL,
  collection    text NOT NULL,
  runs          int NOT NULL,
  failures      int NOT NULL,
  rows_written  bigint NOT NULL,
  dur_ms_sum    bigint NOT NULL,
  dur_ms_max    int NOT NULL,
  dur_hist      int[] NOT NULL,
  PRIMARY KEY (minute, collector_id, engine, collection)
);

-- per minute and instance: pgvigil's own load on the monitored server
CREATE TABLE IF NOT EXISTS pgvigil.collector_load (
  minute        timestamptz NOT NULL,
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  collector_id  text NOT NULL,
  connections   int NOT NULL,                     -- connection attempts: one per run (collect.go, mssql.go)
  runs          int NOT NULL,
  failures      int NOT NULL,
  auth_failures int NOT NULL,                     -- the server refused the login (28P01 / 28000, SQL Server 18456)
  PRIMARY KEY (minute, instance_id, collector_id)
);

-- per instance and collection: the failed runs in a row now
CREATE TABLE IF NOT EXISTS pgvigil.collector_streaks (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  collection    text NOT NULL,
  fail_streak   int NOT NULL,
  last_error    text,
  last_run_at   timestamptz NOT NULL,
  failing_since timestamptz,
  PRIMARY KEY (instance_id, collection)
);

CREATE TABLE IF NOT EXISTS pgvigil.purge_runs (
  run_id              bigserial PRIMARY KEY,
  started_at          timestamptz NOT NULL,
  finished_at         timestamptz NOT NULL,
  days                int NOT NULL,
  partitions_dropped  text[] NOT NULL DEFAULT '{}',
  rows_deleted        bigint NOT NULL DEFAULT 0,
  total               bigint NOT NULL DEFAULT 0
);

-- import_collector_claim: a starting collector's first write. Refused (the reason returned, the row marked) when another
-- host's collector beat in the last 3 minutes and did not stop; else the row is written and NULL returned.
CREATE OR REPLACE FUNCTION pgvigil.import_collector_claim(p_id text, p_host text, p_os text, p_runs_as text, p_version text,
                                                          p_pid int, p_started timestamptz)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_other pgvigil.collector_heartbeat;
  v_why   text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('pgvigil.collector_claim', 0));
  SELECT * INTO v_other FROM pgvigil.collector_heartbeat h
   WHERE h.collector_id <> p_id AND h.host <> p_host AND h.stopped_at IS NULL AND h.refused_at IS NULL
     AND h.beat_at > now() - interval '3 minutes'
   ORDER BY h.started_at LIMIT 1;
  IF FOUND THEN
    v_why := format('another collector writes to this repository: %s (%s, pgvigil %s, pid %s, beat %s s ago); one collector per repository - stop it first, or start this one 3 minutes after it stopped',
                    v_other.host, v_other.runs_as, v_other.version, v_other.pid, round(extract(epoch FROM now() - v_other.beat_at)));
  END IF;
  INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at, refused_at, refused_why)
  VALUES (p_id, p_host, p_os, p_runs_as, p_version, p_pid, p_started, now(), CASE WHEN v_why IS NOT NULL THEN now() END, v_why)
  ON CONFLICT (collector_id) DO UPDATE SET beat_at = now(), refused_at = EXCLUDED.refused_at, refused_why = EXCLUDED.refused_why;
  RETURN v_why;
END $$;

-- import_collector_beat: the minute's beat. p_beat: {mem_bytes, goroutines, instances,
--   runs: [{engine, collection, runs, failures, rows, dur_sum, dur_max, hist: [19 ints]}],
--   load: [{instance, connections, runs, failures, auth}],
--   streaks: [{instance, collection, fails, error, at}]}  (instances by name; an unknown name is skipped)
-- p_minute: the minute the runs belong to. Returns the reason when this collector is refused (an older live collector of
-- another host), else NULL. Trims this file's history past 8 days.
CREATE OR REPLACE FUNCTION pgvigil.import_collector_beat(p_id text, p_minute timestamptz, p_beat jsonb)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_me    pgvigil.collector_heartbeat;
  v_other pgvigil.collector_heartbeat;
  v_conns int;
  v_why   text;
BEGIN
  SELECT * INTO v_me FROM pgvigil.collector_heartbeat WHERE collector_id = p_id;
  IF NOT FOUND THEN
    RETURN 'this collector never claimed the repository (no heartbeat row): restart it';
  END IF;
  IF v_me.refused_at IS NOT NULL THEN
    RETURN v_me.refused_why;
  END IF;
  SELECT * INTO v_other FROM pgvigil.collector_heartbeat h
   WHERE h.collector_id <> p_id AND h.host <> v_me.host AND h.stopped_at IS NULL AND h.refused_at IS NULL
     AND h.beat_at > now() - interval '3 minutes' AND h.started_at < v_me.started_at
   ORDER BY h.started_at LIMIT 1;
  IF FOUND THEN
    v_why := format('another collector writes to this repository: %s (%s, pgvigil %s, pid %s, started %s); one collector per repository - this one, the later, stops',
                    v_other.host, v_other.runs_as, v_other.version, v_other.pid, v_other.started_at);
    UPDATE pgvigil.collector_heartbeat SET refused_at = now(), refused_why = v_why, beat_at = now() WHERE collector_id = p_id;
    RETURN v_why;
  END IF;
  SELECT count(*) INTO v_conns FROM pg_stat_activity
   WHERE datname = current_database() AND application_name LIKE 'pgvigil%';
  UPDATE pgvigil.collector_heartbeat
     SET beat_at = now(), mem_bytes = (p_beat->>'mem_bytes')::bigint, goroutines = (p_beat->>'goroutines')::int,
         instances = (p_beat->>'instances')::int, repo_conns = v_conns
   WHERE collector_id = p_id;
  INSERT INTO pgvigil.collector_runs (minute, collector_id, engine, collection, runs, failures, rows_written, dur_ms_sum, dur_ms_max, dur_hist)
  SELECT p_minute, p_id, coalesce(nullif(r.engine, ''), 'postgres'), r.collection, r.runs, r.failures, r.rows, r.dur_sum, r.dur_max,
         ARRAY(SELECT jsonb_array_elements_text(r.hist)::int)
    FROM jsonb_to_recordset(coalesce(p_beat->'runs', '[]')) AS r(engine text, collection text, runs int, failures int, rows bigint,
                                                                  dur_sum bigint, dur_max int, hist jsonb)
  ON CONFLICT (minute, collector_id, engine, collection) DO UPDATE
     SET runs = collector_runs.runs + EXCLUDED.runs, failures = collector_runs.failures + EXCLUDED.failures,
         rows_written = collector_runs.rows_written + EXCLUDED.rows_written, dur_ms_sum = collector_runs.dur_ms_sum + EXCLUDED.dur_ms_sum,
         dur_ms_max = greatest(collector_runs.dur_ms_max, EXCLUDED.dur_ms_max),
         dur_hist = ARRAY(SELECT coalesce(a, 0) + coalesce(b, 0) FROM unnest(collector_runs.dur_hist, EXCLUDED.dur_hist) AS u(a, b));
  INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, connections, runs, failures, auth_failures)
  SELECT p_minute, i.instance_id, p_id, l.connections, l.runs, l.failures, l.auth
    FROM jsonb_to_recordset(coalesce(p_beat->'load', '[]')) AS l(instance text, connections int, runs int, failures int, auth int)
    JOIN pgvigil.instances i ON i.name = l.instance
  ON CONFLICT (minute, instance_id, collector_id) DO UPDATE
     SET connections = collector_load.connections + EXCLUDED.connections, runs = collector_load.runs + EXCLUDED.runs,
         failures = collector_load.failures + EXCLUDED.failures, auth_failures = collector_load.auth_failures + EXCLUDED.auth_failures;
  INSERT INTO pgvigil.collector_streaks (instance_id, collection, fail_streak, last_error, last_run_at, failing_since)
  SELECT i.instance_id, s.collection, s.fails, nullif(s.error, ''), s.at, CASE WHEN s.fails > 0 THEN s.at END
    FROM jsonb_to_recordset(coalesce(p_beat->'streaks', '[]')) AS s(instance text, collection text, fails int, error text, at timestamptz)
    JOIN pgvigil.instances i ON i.name = s.instance
  ON CONFLICT (instance_id, collection) DO UPDATE
     SET fail_streak = EXCLUDED.fail_streak, last_error = EXCLUDED.last_error, last_run_at = EXCLUDED.last_run_at,
         failing_since = CASE WHEN EXCLUDED.fail_streak = 0 THEN NULL
                              ELSE coalesce(collector_streaks.failing_since, EXCLUDED.failing_since) END;
  INSERT INTO pgvigil.collector_beats (at, collector_id, mem_bytes, goroutines, repo_conns, repo_bytes, runs, failures, rows_written)
  SELECT now(), p_id, (p_beat->>'mem_bytes')::bigint, (p_beat->>'goroutines')::int, v_conns, pg_database_size(current_database()),
         coalesce(sum(r.runs), 0), coalesce(sum(r.failures), 0), coalesce(sum(r.rows), 0)
    FROM jsonb_to_recordset(coalesce(p_beat->'runs', '[]')) AS r(runs int, failures int, rows bigint);
  -- the history this file keeps: 8 days (the page reads 24 h and 7 days)
  DELETE FROM pgvigil.collector_beats WHERE at < now() - interval '8 days';
  DELETE FROM pgvigil.collector_runs WHERE minute < now() - interval '8 days';
  DELETE FROM pgvigil.collector_load WHERE minute < now() - interval '8 days';
  DELETE FROM pgvigil.collector_heartbeat WHERE beat_at < now() - interval '8 days';
  RETURN NULL;
END $$;

-- import_collector_stop: a clean stop
CREATE OR REPLACE FUNCTION pgvigil.import_collector_stop(p_id text)
RETURNS void LANGUAGE sql AS $$
  UPDATE pgvigil.collector_heartbeat SET stopped_at = now() WHERE collector_id = p_id AND stopped_at IS NULL;
$$;

-- collector_pctl: a percentile of a duration histogram (collector_runs.dur_hist), linear inside its bucket: an estimate
-- whose error is at most the bucket's width (a factor of two)
CREATE OR REPLACE FUNCTION pgvigil.collector_pctl(p_hist int[], p_q double precision)
RETURNS double precision LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_total bigint := 0;
  v_seen  bigint := 0;
  v_want  double precision;
  v_n     int;
  v_lo    double precision;
  v_hi    double precision;
BEGIN
  SELECT coalesce(sum(x), 0) INTO v_total FROM unnest(p_hist) x;
  IF v_total = 0 THEN RETURN NULL; END IF;
  v_want := p_q * v_total;
  FOR b IN 1 .. cardinality(p_hist) LOOP
    v_n := coalesce(p_hist[b], 0);
    IF v_n > 0 AND v_seen + v_n >= v_want THEN
      v_lo := CASE WHEN b = 1 THEN 0 ELSE power(2, b - 2) END;
      v_hi := power(2, b - 1);
      RETURN v_lo + (v_hi - v_lo) * greatest(0, least(1, (v_want - v_seen) / v_n));
    END IF;
    v_seen := v_seen + v_n;
  END LOOP;
  RETURN power(2, cardinality(p_hist) - 1);
END $$;

-- collector_status: each collector seen in the last 8 days and its state
CREATE OR REPLACE VIEW pgvigil.collector_status AS
SELECT h.*,
       CASE WHEN h.refused_at IS NOT NULL THEN 'refused'
            WHEN h.stopped_at IS NOT NULL THEN 'stopped'
            WHEN h.beat_at > now() - interval '2 minutes' THEN 'up'
            ELSE 'not seen' END AS state,
       round(extract(epoch FROM now() - h.beat_at))::bigint AS beat_age_secs
  FROM pgvigil.collector_heartbeat h;

-- collector_live: the collectors beating now (not stopped, not refused, a beat in the last 3 minutes)
CREATE OR REPLACE VIEW pgvigil.collector_live AS
SELECT * FROM pgvigil.collector_status
 WHERE stopped_at IS NULL AND refused_at IS NULL AND beat_at > now() - interval '3 minutes';

-- collector_parent: the 'collector or network' condition now (one row, or none). Why: 'collector not seen' (no beat
-- for 5 minutes while the repository has active instances) or 'instances failing together' (the newest complete minute
-- in which at least 3 instances and over half of those that ran failed every run).
CREATE OR REPLACE VIEW pgvigil.collector_parent AS
WITH last_beat AS (
  SELECT max(beat_at) AS at FROM pgvigil.collector_heartbeat WHERE refused_at IS NULL
), down AS (
  SELECT 'collector not seen'::text AS why,
         CASE WHEN b.at IS NULL THEN 'no collector has beaten on this repository'
              ELSE format('no heartbeat for %s min (the last at %s)', floor(extract(epoch FROM now() - b.at) / 60), b.at) END AS detail,
         coalesce(b.at, now()) AS since
    FROM last_beat b
   WHERE (b.at IS NULL OR b.at < now() - interval '5 minutes')
     AND EXISTS (SELECT 1 FROM pgvigil.instances WHERE is_active)
), m AS (
  SELECT max(minute) AS minute FROM pgvigil.collector_load
   WHERE minute >= now() - interval '3 minutes' AND minute < date_trunc('minute', now())
), together AS (
  SELECT 'instances failing together'::text AS why,
         format('%s of %s instances failed every run in the minute %s: the network, the collector host or a shared login, not each server',
                count(*) FILTER (WHERE l.failures >= l.runs AND l.runs > 0), count(*) FILTER (WHERE l.runs > 0), m.minute) AS detail,
         m.minute AS since
    FROM m JOIN pgvigil.collector_load l ON l.minute = m.minute
   GROUP BY m.minute
  HAVING count(*) FILTER (WHERE l.failures >= l.runs AND l.runs > 0) >= 3
     AND count(*) FILTER (WHERE l.failures >= l.runs AND l.runs > 0) * 2 > count(*) FILTER (WHERE l.runs > 0)
)
SELECT * FROM down
UNION ALL
SELECT * FROM together WHERE NOT EXISTS (SELECT 1 FROM down);

-- collector_hold: true while 'collector or network' stands; alert_due (0190) holds every per-instance alert then
CREATE OR REPLACE FUNCTION pgvigil.collector_hold()
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pgvigil.collector_parent)
$$;

-- collector_down: no collector beat for 5 minutes (serve's watchdog runs the alert pass then: the collector that would
-- send it is the one that stopped)
CREATE OR REPLACE FUNCTION pgvigil.collector_down()
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pgvigil.collector_parent WHERE why = 'collector not seen')
$$;

-- collector_findings: the findings shape (pgvigil.findings' arms); instance_id NULL for the repository-wide ones
CREATE OR REPLACE VIEW pgvigil.collector_findings AS
SELECT NULL::int AS instance_id, 'critical'::text AS severity, 'collector or network'::text AS setting, p.why AS value,
       true AS is_set, 'a collector beating, and most instances read'::text AS suggested, 'all'::text AS platforms,
       p.detail || '; the per-instance alerts are held until this clears' AS detail, 'pgvigil collector'::text AS source, p.since AS at
  FROM pgvigil.collector_parent p
UNION ALL
SELECT NULL::int, 'critical', 'two collectors on one repository', count(*)::text || ' collectors', true, 'one collector per repository',
       'all', 'live now: ' || string_agg(format('%s (%s, pid %s)', l.host, l.runs_as, l.pid), '; ' ORDER BY l.started_at)
              || ': both write every collection; stop all but one', 'pgvigil collector', max(l.beat_at)
  FROM pgvigil.collector_live l
HAVING count(*) > 1
UNION ALL
SELECT NULL::int, 'warning', 'purge not run in 2 days',
       CASE WHEN p.finished_at IS NULL THEN 'never' ELSE 'last ' || to_char(p.finished_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC' END,
       true, 'pgvigil purge daily (the installer''s timer or a scheduled task)', 'all',
       'the repository keeps every row until purge() runs: it grows by the day', 'pgvigil collector',
       coalesce(p.finished_at, now())
  FROM (SELECT max(finished_at) AS finished_at FROM pgvigil.purge_runs) p
 WHERE (p.finished_at IS NULL OR p.finished_at < now() - interval '2 days')
   AND EXISTS (SELECT 1 FROM pgvigil.instances WHERE first_seen < now() - interval '2 days')
UNION ALL
SELECT s.instance_id, 'critical', 'collection failing', s.collection, true, 'the collection runs', 'all',
       format('%s runs in a row failed since %s: %s', s.fail_streak, s.failing_since, coalesce(s.last_error, 'no error text')),
       'pgvigil collector', s.last_run_at
  FROM pgvigil.collector_streaks s JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND s.fail_streak >= 3 AND s.last_run_at > now() - interval '1 day'
UNION ALL
SELECT l.instance_id, 'critical', 'authentication failing', 'login refused', true, 'the login the collector uses works', 'all',
       format('%s authentication failures in 15 minutes: the server refused the collector''s login (a changed password?); each run retries it and can lock the login out',
              sum(l.auth_failures)),
       'pgvigil collector', max(l.minute)
  FROM pgvigil.collector_load l JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND l.minute > now() - interval '15 minutes'
 GROUP BY l.instance_id
HAVING sum(l.auth_failures) > 0;
