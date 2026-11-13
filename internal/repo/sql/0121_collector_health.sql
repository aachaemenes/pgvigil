-- 0121: the collector seen working (task 201; PerformanceMonitor's Collection Health as pgvigil's own page).
--
-- `pgvigil run` beats once a minute (internal/collect/heartbeat.go): who it is (host, OS, how it runs - a systemd unit,
-- a Windows service, a container, a console - its version, pid and start, the start in the repository's clock), its
-- memory and goroutines, and what the minute's runs did per collection (runs, failures, rows written, durations as a
-- histogram) and per instance (pgvigil's own load: connection attempts, connections opened and logins refused, counted
-- at every connect of a collection - a per-database connect included - and the runs and failures), with each instance
-- and collection's failed runs in a row. Every write is an import_ function (SECURITY DEFINER and granted to
-- pgvigil_collector by apply_roles); the beat trims this file's history past 8 days, so nothing here waits for purge().
--
-- Many collectors may write to one repository (one per host, the scale plan's ten): a collector is its host, each run
-- of `pgvigil run` a row. Two collectors collecting one instance in the same minutes is a finding.
--
-- purge() records each run in purge_runs (its line in 0190): when, the days kept, the partitions it dropped and the rows
-- it deleted; 'purge not run in 2 days' is a finding.
--
-- 'collector or network' is one alert per collector: its host not seen for 5 minutes (stopped, crashed, or the
-- repository out of its reach) while no other collector reads its instances, or a minute in which at least 3 of its
-- instances and over half of those it ran failed every run. alert_due (0190) holds only what a shared cause explains
-- (collector_shared_cause: the collector's own kinds and the findings judged by age on data a cut stops refreshing):
-- while the parent stands, those alerts of its instances not read since it began (the instances still read keep
-- alerting; a data finding from the last good read is sent); while one may be forming (collector_forming: the
-- newest minute shows 3+ instances and over half with a failed run) their NEW alerts wait for the next minute, 3
-- minutes at most; after it (collector_in_window) a collector kind needs one failure past its window. A refused login
-- or a server not answering at the instance's own connect is the instance's one finding ('authentication failing',
-- 'server unreachable'), never a 'collection failing' per collection. The repository-wide findings (source 'pgvigil
-- repository': the parent, the purge) go to every channel that passes its severity floor, scoped channels too.

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
  attempts      int NOT NULL,                     -- connection attempts, at every connect of a collection (heartbeat.go connectCounted)
  opened        int NOT NULL,                     -- connections opened
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

-- import_collector_claim: a starting collector's first write; its start is the repository's now() (the hosts' clocks
-- are never compared)
CREATE OR REPLACE FUNCTION pgvigil.import_collector_claim(p_id text, p_host text, p_os text, p_runs_as text, p_version text, p_pid int)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
  VALUES (p_id, p_host, p_os, p_runs_as, p_version, p_pid, now(), now())
  ON CONFLICT (collector_id) DO UPDATE SET beat_at = now(), stopped_at = NULL;
$$;

-- import_collector_beat: the minute's beat. p_beat: {mem_bytes, goroutines, instances,
--   runs: [{engine, collection, runs, failures, rows, dur_sum, dur_max, hist: [19 ints]}],
--   load: [{instance, attempts, opened, runs, failures, auth}],
--   streaks: [{instance, collection, fails, error, at, since}]}  (instances by name; an unknown name is skipped; since =
--   the streak's first failure, absent when the collector carried the count from the repository)
-- p_minute: the minute the runs belong to. Returns false when the collector has no row (its claim never written: it
-- claims again). Trims this file's history past 8 days.
CREATE OR REPLACE FUNCTION pgvigil.import_collector_beat(p_id text, p_minute timestamptz, p_beat jsonb)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  v_conns int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pgvigil.collector_heartbeat WHERE collector_id = p_id) THEN
    RETURN false;
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
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'runs') = 'array' THEN p_beat->'runs' ELSE '[]'::jsonb END)) AS r(engine text, collection text, runs int, failures int, rows bigint,
                                                                  dur_sum bigint, dur_max int, hist jsonb)
  ON CONFLICT (minute, collector_id, engine, collection) DO UPDATE
     SET runs = collector_runs.runs + EXCLUDED.runs, failures = collector_runs.failures + EXCLUDED.failures,
         rows_written = collector_runs.rows_written + EXCLUDED.rows_written, dur_ms_sum = collector_runs.dur_ms_sum + EXCLUDED.dur_ms_sum,
         dur_ms_max = greatest(collector_runs.dur_ms_max, EXCLUDED.dur_ms_max),
         dur_hist = ARRAY(SELECT coalesce(a, 0) + coalesce(b, 0) FROM unnest(collector_runs.dur_hist, EXCLUDED.dur_hist) AS u(a, b));
  INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures)
  SELECT p_minute, i.instance_id, p_id, l.attempts, l.opened, l.runs, l.failures, l.auth
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'load') = 'array' THEN p_beat->'load' ELSE '[]'::jsonb END)) AS l(instance text, attempts int, opened int, runs int, failures int, auth int)
    JOIN pgvigil.instances i ON i.name = l.instance
  ON CONFLICT (minute, instance_id, collector_id) DO UPDATE
     SET attempts = collector_load.attempts + EXCLUDED.attempts, opened = collector_load.opened + EXCLUDED.opened,
         runs = collector_load.runs + EXCLUDED.runs,
         failures = collector_load.failures + EXCLUDED.failures, auth_failures = collector_load.auth_failures + EXCLUDED.auth_failures;
  -- a streak whose beat carries its first failure ('since') takes it, whatever start is stored (a streak that ended
  -- and began again inside one beat never wrote its 0)
  UPDATE pgvigil.collector_streaks cs SET failing_since = NULL
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'streaks') = 'array' THEN p_beat->'streaks' ELSE '[]'::jsonb END)) AS s(instance text, collection text, since timestamptz)
    JOIN pgvigil.instances i ON i.name = s.instance
   WHERE cs.instance_id = i.instance_id AND cs.collection = s.collection AND s.since IS NOT NULL;
  INSERT INTO pgvigil.collector_streaks (instance_id, collection, fail_streak, last_error, last_run_at, failing_since)
  SELECT i.instance_id, s.collection, s.fails, nullif(s.error, ''), s.at, CASE WHEN s.fails > 0 THEN coalesce(s.since, s.at) END
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'streaks') = 'array' THEN p_beat->'streaks' ELSE '[]'::jsonb END)) AS s(instance text, collection text, fails int, error text, at timestamptz, since timestamptz)
    JOIN pgvigil.instances i ON i.name = s.instance
  ON CONFLICT (instance_id, collection) DO UPDATE
     SET fail_streak = EXCLUDED.fail_streak, last_error = EXCLUDED.last_error, last_run_at = EXCLUDED.last_run_at,
         failing_since = CASE WHEN EXCLUDED.fail_streak = 0 THEN NULL
                              ELSE coalesce(collector_streaks.failing_since, EXCLUDED.failing_since) END;
  INSERT INTO pgvigil.collector_beats (at, collector_id, mem_bytes, goroutines, repo_conns, repo_bytes, runs, failures, rows_written)
  SELECT now(), p_id, (p_beat->>'mem_bytes')::bigint, (p_beat->>'goroutines')::int, v_conns, pg_database_size(current_database()),
         coalesce(sum(r.runs), 0), coalesce(sum(r.failures), 0), coalesce(sum(r.rows), 0)
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'runs') = 'array' THEN p_beat->'runs' ELSE '[]'::jsonb END)) AS r(runs int, failures int, rows bigint);
  -- the history this file keeps: 8 days (the page reads 24 h and 7 days)
  DELETE FROM pgvigil.collector_beats WHERE at < now() - interval '8 days';
  DELETE FROM pgvigil.collector_runs WHERE minute < now() - interval '8 days';
  DELETE FROM pgvigil.collector_load WHERE minute < now() - interval '8 days';
  DELETE FROM pgvigil.collector_heartbeat WHERE beat_at < now() - interval '8 days';
  RETURN true;
END $$;

-- import_collector_streaks: the failed runs in a row the repository holds (a restarted collector counts on from them)
CREATE OR REPLACE FUNCTION pgvigil.import_collector_streaks()
RETURNS TABLE (instance text, collection text, fail_streak int, last_error text) LANGUAGE sql STABLE AS $$
  SELECT i.name, s.collection, s.fail_streak, s.last_error
    FROM pgvigil.collector_streaks s JOIN pgvigil.instances i USING (instance_id)
   WHERE i.is_active AND s.fail_streak > 0
$$;

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

-- collector_status: each run of `pgvigil run` seen in the last 8 days and its state: stopped (a clean stop), ended (a
-- newer run of the same host started after its last beat: a crash and a restart), up (a beat in the last 2 minutes),
-- not seen
CREATE OR REPLACE VIEW pgvigil.collector_status AS
SELECT h.*,
       CASE WHEN h.stopped_at IS NOT NULL THEN 'stopped'
            WHEN EXISTS (SELECT 1 FROM pgvigil.collector_heartbeat n WHERE n.host = h.host AND n.started_at > h.beat_at) THEN 'ended'
            WHEN h.beat_at > now() - interval '2 minutes' THEN 'up'
            ELSE 'not seen' END AS state,
       round(extract(epoch FROM now() - h.beat_at))::bigint AS beat_age_secs
  FROM pgvigil.collector_heartbeat h;

-- collector_live: the runs beating now (not stopped, not ended, a beat in the last 3 minutes)
CREATE OR REPLACE VIEW pgvigil.collector_live AS
SELECT * FROM pgvigil.collector_status
 WHERE state NOT IN ('stopped', 'ended') AND beat_at > now() - interval '3 minutes';

-- collector_hosts: each collector (a host): its newest beat over all its runs (a console run stopped beside the service
-- does not make the host look down), whether any run is live, and its active instances - those it collected in the 15
-- minutes before its newest beat - with the ones no other host has read since that beat (orphaned)
CREATE OR REPLACE VIEW pgvigil.collector_hosts AS
WITH hb AS (
  SELECT h.host, max(h.beat_at) AS beat_at, bool_and(h.stopped_at IS NOT NULL) AS all_stopped
    FROM pgvigil.collector_heartbeat h GROUP BY h.host
), mine AS (
  SELECT DISTINCT hb.host, l.instance_id
    FROM hb JOIN pgvigil.collector_heartbeat h ON h.host = hb.host
    JOIN pgvigil.collector_load l ON l.collector_id = h.collector_id AND l.minute >= hb.beat_at - interval '15 minutes'
    JOIN pgvigil.instances i ON i.instance_id = l.instance_id AND i.is_active
)
SELECT hb.host, hb.beat_at, hb.all_stopped,
       coalesce((SELECT array_agg(m.instance_id) FROM mine m WHERE m.host = hb.host), '{}') AS instances,
       coalesce((SELECT array_agg(m.instance_id) FROM mine m
                  WHERE m.host = hb.host
                    AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_load l2 JOIN pgvigil.collector_heartbeat h2 USING (collector_id)
                                     WHERE h2.host <> hb.host AND l2.instance_id = m.instance_id
                                       AND l2.minute >= date_trunc('minute', hb.beat_at))), '{}') AS orphaned
  FROM hb;

-- collector_parent: the 'collector or network' conditions now, one row per collector (host) at most:
--   'collector not seen': no beat for 5 minutes from any run of the host while some of its active instances have not
--     been read by another host since its newest beat (orphaned; a host whose every instance moved is retired, not
--     down); its instances = the orphaned ones (held whatever the down host read after its last beat)
--   'instances failing together': a minute among the host's last 4 minute stamps (the newest may not be written yet:
--     a beat writes minute M at M+1 min+2 s) in which at least 3 of its instances and over half of those it ran failed
--     every run (several minutes, so a minute in which hung connects finished few runs does not lift it); since = the
--     first such minute; its instances = the host's, held while they have had no ok collection since
-- instances: the host's instances (the hold reads them); since: when the condition began.
CREATE OR REPLACE VIEW pgvigil.collector_parent AS
WITH down AS (
  SELECT c.host, 'collector not seen'::text AS why,
         format('no heartbeat from %s for %s min (the last at %s%s); %s of its %s instance(s) read by no other collector since: %s', c.host,
                floor(extract(epoch FROM now() - c.beat_at) / 60), c.beat_at,
                CASE WHEN c.all_stopped THEN ', stopped cleanly' ELSE ', no stop mark: a crash, the host or the network' END,
                cardinality(c.orphaned), cardinality(c.instances),
                (SELECT string_agg(i.name, ', ' ORDER BY i.name) FROM pgvigil.instances i WHERE i.instance_id = ANY (c.orphaned))) AS detail,
         c.beat_at AS since, c.orphaned AS instances
    FROM pgvigil.collector_hosts c
   WHERE c.beat_at < now() - interval '5 minutes' AND cardinality(c.orphaned) > 0
), m AS (    -- the last 3 complete minutes, per host, minute and instance
  SELECT h.host, l.minute, l.instance_id, sum(l.runs) AS runs, sum(l.failures) AS failures
    FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE l.minute >= date_trunc('minute', now()) - interval '4 minutes' AND l.minute < date_trunc('minute', now())
   GROUP BY h.host, l.minute, l.instance_id
), bad AS (   -- the minutes that qualify
  SELECT m.host, m.minute,
         format('%s of the %s instance(s) %s ran failed every run in the minute %s: %s - a shared cause (the network, the collector host, a shared login, storage)',
                count(*) FILTER (WHERE m.failures >= m.runs AND m.runs > 0), count(*) FILTER (WHERE m.runs > 0), m.host, m.minute,
                string_agg(i.name, ', ' ORDER BY i.name) FILTER (WHERE m.failures >= m.runs AND m.runs > 0)) AS detail,
         array_agg(m.instance_id) AS instances
    FROM m JOIN pgvigil.instances i USING (instance_id)
   GROUP BY m.host, m.minute
  HAVING count(*) FILTER (WHERE m.failures >= m.runs AND m.runs > 0) >= 3
     AND count(*) FILTER (WHERE m.failures >= m.runs AND m.runs > 0) * 2 > count(*) FILTER (WHERE m.runs > 0)
), together AS (
  SELECT DISTINCT ON (b.host) b.host, 'instances failing together'::text AS why, b.detail,
         (SELECT min(b2.minute) FROM bad b2 WHERE b2.host = b.host) AS since,
         (SELECT array_agg(DISTINCT x) FROM bad b3, unnest(b3.instances) x WHERE b3.host = b.host) AS instances
    FROM bad b
   ORDER BY b.host, b.minute DESC
)
SELECT * FROM down
UNION ALL
SELECT * FROM together t WHERE NOT EXISTS (SELECT 1 FROM down d WHERE d.host = t.host);

-- collector_held_instances: the instances whose alerts are held - a 'collector or network' of a collector of theirs
-- stands and the instance has had no ok collection since it began (alert_due, 0190, reads it once per pass)
CREATE OR REPLACE VIEW pgvigil.collector_held_instances AS
SELECT DISTINCT x.instance_id
  FROM pgvigil.collector_parent p CROSS JOIN LATERAL unnest(p.instances) AS x(instance_id)
 WHERE p.why = 'collector not seen'   -- the orphaned instances: no other host has read them since the down host's last beat
    OR NOT EXISTS (SELECT 1 FROM pgvigil.collection_dates d
                    WHERE d.instance_id = x.instance_id AND d.status = 'ok' AND d.snapshot_at > p.since);

-- collector_shared_cause: the findings a shared cause (the network, the collector host, a shared login) explains -
-- the ones alert_due (0190) holds under 'collector or network' and makes wait while one forms: the collector's own
-- kinds, and the findings judged by age against now() on data a cut stops refreshing (a job still 'running', a due
-- time passed with no run seen, the last clean amcheck, an index's unused window). Every other finding comes from the
-- last good read and is sent as it is (a full disk found before a cut may be the shared cause itself).
CREATE OR REPLACE FUNCTION pgvigil.collector_shared_cause(p_source text, p_setting text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce((p_source = 'pgvigil collector' AND p_setting IN ('authentication failing', 'collection failing', 'server unreachable'))
      OR (p_source = 'pgvigil' AND p_setting IN ('job run over twice its average', 'job schedule missed'))
      OR (p_source = 'mssql_jobs' AND p_setting = 'a job runs far longer than its average')
      OR (p_source = 'pg-backups' AND p_setting LIKE 'amcheck older than %')
      OR (p_source = 'pgvigil indexes' AND p_setting = 'unused index'), false)
$$;

-- collector_forming: the instances of a 'collector or network' that may be forming - in a collector's (host's) newest
-- written minute at least 3 of its instances, and over half of those it ran, had a failed run (not every run: a cut
-- starts partway through a minute). alert_due holds the NEW alerts of these instances (collector_shared_cause) until
-- the next minute is written; the parent's own rule is unchanged. The cap: when the host's last 4 written minutes all
-- form, nothing waits any more (about 3 minutes). A minute older than 2 minutes is not newest (a late collector); the
-- repository's current minute counts (a beat writes a minute once it ended on the collector's clock, which may run ahead).
CREATE OR REPLACE VIEW pgvigil.collector_forming AS
WITH m AS (
  SELECT h.host, l.minute, l.instance_id, sum(l.runs) AS runs, sum(l.failures) AS failures
    FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE l.minute >= date_trunc('minute', now()) - interval '6 minutes' AND l.minute <= date_trunc('minute', now())
   GROUP BY h.host, l.minute, l.instance_id
), mm AS (
  SELECT m.host, m.minute,
         count(*) FILTER (WHERE m.failures > 0 AND m.runs > 0) >= 3
         AND count(*) FILTER (WHERE m.failures > 0 AND m.runs > 0) * 2 > count(*) FILTER (WHERE m.runs > 0) AS forming
    FROM m GROUP BY m.host, m.minute
), newest AS (
  SELECT DISTINCT ON (mm.host) mm.host, mm.minute, mm.forming FROM mm ORDER BY mm.host, mm.minute DESC
)
SELECT DISTINCT m.instance_id, n.host, n.minute
  FROM newest n
  JOIN m ON m.host = n.host AND m.minute = n.minute AND m.failures > 0 AND m.runs > 0
 WHERE n.forming AND n.minute >= date_trunc('minute', now()) - interval '2 minutes'
   AND (SELECT count(*) FROM mm x WHERE x.host = n.host AND x.forming
           AND x.minute >= n.minute - interval '3 minutes' AND x.minute <= n.minute) < 4;

-- collector_in_window: whether a failure at p_at of the instance lies inside an 'instances failing together' window
-- of a host that ran it - a failing-together minute after p_at - 5 minutes in which the instance itself failed every
-- run (the parent leaves collector_parent 5 minutes after its newest such minute). alert_due: a NEW collector kind of
-- the instance whose newest failure (the finding's at) is inside waits - after the parent clears, an instance still
-- failing alerts once per finding after one failure past the window, never off a streak or a refusal from inside it,
-- never after a fresh streak of 3. Anchored to the finding, with no look-back cap: it reads the minutes from p_at - 5
-- min to p_at + 5 min only (a window that holds p_at has a failing-together minute there: one in the 5 minutes before
-- it, or, in the cut's first mixed minute, the first one within the forming cap after it).
CREATE OR REPLACE FUNCTION pgvigil.collector_in_window(p_instance_id int, p_at timestamptz)
RETURNS boolean LANGUAGE sql STABLE AS $$
  WITH m AS (
    SELECT h.host, l.minute, l.instance_id, sum(l.runs) AS runs, sum(l.failures) AS failures
      FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
     WHERE l.minute > p_at - interval '5 minutes' AND l.minute <= p_at + interval '5 minutes'
       AND h.host IN (SELECT h1.host FROM pgvigil.collector_load l1 JOIN pgvigil.collector_heartbeat h1 USING (collector_id)
                       WHERE l1.instance_id = p_instance_id AND l1.minute > p_at - interval '5 minutes'
                         AND l1.minute <= p_at + interval '5 minutes')
     GROUP BY h.host, l.minute, l.instance_id
  )
  SELECT EXISTS (
    SELECT 1 FROM m b
     WHERE b.instance_id = p_instance_id AND b.failures >= b.runs AND b.runs > 0
       AND (SELECT count(*) FILTER (WHERE x.failures >= x.runs AND x.runs > 0) >= 3
                   AND count(*) FILTER (WHERE x.failures >= x.runs AND x.runs > 0) * 2 > count(*) FILTER (WHERE x.runs > 0)
              FROM m x WHERE x.host = b.host AND x.minute = b.minute))
$$;

-- collector_down: a collector not seen for 5 minutes (serve's watchdog runs the alert pass then: the collector that
-- would send it is the one down)
CREATE OR REPLACE FUNCTION pgvigil.collector_down()
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pgvigil.collector_parent WHERE why = 'collector not seen')
$$;

-- collector_findings: the findings shape (pgvigil.findings' arms). Source 'pgvigil repository' marks the
-- repository-wide ones (no instance: every channel past its severity floor takes them); 'pgvigil collector' an
-- instance's.
CREATE OR REPLACE VIEW pgvigil.collector_findings AS
SELECT NULL::int AS instance_id, 'critical'::text AS severity, 'collector or network'::text AS setting, p.why || ': ' || p.host AS value,
       true AS is_set, 'the collector beating and its instances read'::text AS suggested, 'all'::text AS platforms,
       p.detail || '; the alerts of its instances not read since are held until this clears'
       || coalesce((SELECT '; it covers ' || count(*) || ' open alert(s): ' || string_agg(o.x, ', ' ORDER BY o.x)
                      FROM (SELECT DISTINCT format('%s %s (%s)', a.instance_name, a.setting, a.value) AS x
                              FROM pgvigil.alert_state a
                             WHERE a.cleared_at IS NULL AND a.instance_id = ANY (p.instances)
                               AND pgvigil.collector_shared_cause(a.source, a.setting)
                               -- held: collector_held_instances' test for this parent
                               AND (p.why = 'collector not seen'
                                    OR NOT EXISTS (SELECT 1 FROM pgvigil.collection_dates d
                                                    WHERE d.instance_id = a.instance_id AND d.status = 'ok' AND d.snapshot_at > p.since))) o
                    HAVING count(*) > 0), '') AS detail,
       'pgvigil repository'::text AS source, p.since AS at
  FROM pgvigil.collector_parent p
UNION ALL
SELECT NULL::int, 'warning', 'purge not run in 2 days',
       CASE WHEN p.finished_at IS NULL THEN 'never' ELSE 'last ' || to_char(p.finished_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC' END,
       true, 'pgvigil purge daily (the installer''s timer or a scheduled task)', 'all',
       'the repository keeps every row until purge() runs: it grows by the day', 'pgvigil repository',
       coalesce(p.finished_at, now())
  FROM (SELECT max(finished_at) AS finished_at FROM pgvigil.purge_runs) p
 WHERE (p.finished_at IS NULL OR p.finished_at < now() - interval '2 days')
   AND EXISTS (SELECT 1 FROM pgvigil.instances WHERE first_seen < now() - interval '2 days')
UNION ALL
SELECT s.instance_id, 'critical', 'collection failing', s.collection, true, 'the collection runs', 'all',
       format('%s runs in a row failed since %s: %s', s.fail_streak, s.failing_since, coalesce(s.last_error, 'no error text')),
       'pgvigil collector', s.last_run_at
  FROM pgvigil.collector_streaks s JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND s.collection <> '(connect)' AND s.fail_streak >= 3 AND s.last_run_at > now() - interval '1 day'
   -- it stands during an outage too (the page shows it); alert_due (0190) decides the send: held while 'collector or
   -- network' stands, and after it one failed run past its window (collector_in_window)
UNION ALL
-- the instance's own connect failing, the server not answering (not a refused login: that is 'authentication
-- failing'): 3 attempts in a row over a minute or more (heartbeat.go's '(connect)' streak); a run that fails there
-- builds no 'collection failing'
SELECT s.instance_id, 'critical', 'server unreachable', 'no connection', true, 'the server answering the collector', 'all',
       format('%s connection attempts in a row failed since %s: %s', s.fail_streak, s.failing_since, coalesce(s.last_error, 'no error text')),
       'pgvigil collector', s.last_run_at
  FROM pgvigil.collector_streaks s JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND s.collection = '(connect)' AND s.fail_streak >= 3
   AND s.last_run_at - s.failing_since >= interval '60 seconds' AND s.last_run_at > now() - interval '1 day'
UNION ALL
SELECT l.instance_id, 'critical', 'authentication failing', 'login refused', true, 'the login the collector uses works', 'all',
       format('%s login(s) refused in 15 minutes (a per-database connect included): a changed password or pg_hba? each run retries it and can lock the login out',
              sum(l.auth_failures)),
       'pgvigil collector', max(l.minute) FILTER (WHERE l.auth_failures > 0)
  FROM pgvigil.collector_load l JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND l.minute > now() - interval '15 minutes'
 GROUP BY l.instance_id
-- it stands until a minute after the last refusal opened a connection (the login works again)
HAVING sum(l.auth_failures) > 0
   AND max(l.minute) FILTER (WHERE l.auth_failures > 0) >= coalesce(max(l.minute) FILTER (WHERE l.opened > 0 AND l.auth_failures = 0), '-infinity')
UNION ALL
-- two runs of `pgvigil run` live at once collecting one instance in the same minute, in at least 2 of the last 10
-- complete minutes: both write every collection, cursor imports twice. A run whose stop mark is at or before the
-- other's start is a restart, not a second collector (two clean restarts in 10 minutes raise nothing); a crash
-- (no stop mark) overlaps its replacement for one minute at most
SELECT d.instance_id, 'critical', 'collected by more than one collector', d.collectors::text || ' collectors', true,
       'one collector per instance', 'all',
       'the same minutes from ' || hh.hosts || ': each collection is written twice (logs, job history and every cursor import twice)',
       'pgvigil collector', d.last_minute
  FROM (SELECT x.instance_id, max(x.n) AS collectors, max(x.minute) AS last_minute
          FROM (SELECT l.instance_id, l.minute, count(DISTINCT l.collector_id) AS n
                  FROM pgvigil.collector_load l
                  JOIN pgvigil.collector_heartbeat ha ON ha.collector_id = l.collector_id
                 WHERE l.minute >= now() - interval '10 minutes' AND l.minute < date_trunc('minute', now())
                   AND EXISTS (SELECT 1 FROM pgvigil.collector_load o
                                 JOIN pgvigil.collector_heartbeat hb ON hb.collector_id = o.collector_id
                                WHERE o.instance_id = l.instance_id AND o.minute = l.minute AND o.collector_id <> l.collector_id
                                  AND NOT coalesce(ha.stopped_at <= hb.started_at, false)
                                  AND NOT coalesce(hb.stopped_at <= ha.started_at, false))
                 GROUP BY l.instance_id, l.minute
                HAVING count(DISTINCT l.collector_id) > 1) x
         GROUP BY x.instance_id
        HAVING count(*) >= 2) d
  JOIN pgvigil.instances i ON i.instance_id = d.instance_id AND i.is_active
  CROSS JOIN LATERAL (SELECT string_agg(DISTINCT format('%s (pid %s)', h.host, h.pid), ', ') AS hosts
                        FROM pgvigil.collector_load l2 JOIN pgvigil.collector_heartbeat h USING (collector_id)
                       WHERE l2.instance_id = d.instance_id AND l2.minute = d.last_minute) hh;
