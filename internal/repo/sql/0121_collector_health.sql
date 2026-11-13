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
-- repository out of its reach) while no other collector reads its instances, or instances whose failures BEGAN
-- together (collector_cohorts: their 'dead' spells - every run failed - began within one window of each other, and
-- they are a shared cause by collector_together: 5 or more, or at least 3 and over half of those it ran then). A
-- failure that stood before is never counted, so standing failures begun apart raise nothing however many there are.
-- alert_due (0190) holds only what a shared cause explains
-- (collector_shared_cause: the collector's own kinds and the findings judged by age on data a cut stops refreshing):
-- while the parent stands, those alerts of its members still failing (an instance read again has left; a standing
-- failure that began before is no member and alerts as any; a data finding from the last good read is sent); while
-- one may be forming (collector_forming: in the
-- newest minute the instances with a failed connect or a newly failed run are a shared cause) their NEW alerts wait
-- for the next minute, 3 minutes at most; after it (collector_in_window: a minute in which the parent stood with the
-- instance among its failing members) a collector kind needs one failure past its window, for a new alert and for an
-- open one's repeat alike. A refused login
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
  retired_at    timestamptz,                      -- the host's collector uninstalled (import_collector_retire): the run is left out of collector_hosts
  mem_bytes     bigint,                           -- the Go runtime's memory from the OS (runtime.MemStats.Sys)
  goroutines    int,
  instances     int,                              -- instances it ran a collection on in the last minute
  repo_conns    int,                              -- the repository's sessions named pgvigil* at the beat (every pgvigil process)
  span_s        int,                              -- the host's span at this run's newest beat (collector_span_take); NULL: no interval known
  beat_minute   timestamptz                       -- the newest minute this run's beat wrote, on the collector's clock (collector_reading)
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
  interval_s    int,                              -- the fastest configured interval of the minute's runs of it (NULL: not known)
  noanswer      int NOT NULL DEFAULT 0,           -- failed connects the server never answered (no SQLSTATE: heartbeat.go NoAnswer)
  target        text,                             -- the dial target, 'postgres:<host>:<port>' (NULL: not known; collector_server_down)
  PRIMARY KEY (minute, instance_id, collector_id)
);
-- an instance's rows in time order (collector_server_down_at: the row before a spell, rows between two minutes)
CREATE INDEX IF NOT EXISTS collector_load_instance ON pgvigil.collector_load (instance_id, minute);

-- per instance, collection and collector (host): the failed runs in a row now. By host: two hosts reading one
-- instance (a move, a second collector) each keep their own count, and the lowest of the hosts still reading speaks
-- (collector_streaks_now). A renamed host starts at 0. Trimmed by the beat when its host has not named the instance
-- for 8 days.
CREATE TABLE IF NOT EXISTS pgvigil.collector_streaks (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  collection    text NOT NULL,
  host          text NOT NULL,
  fail_streak   int NOT NULL,
  last_error    text,
  last_run_at   timestamptz NOT NULL,
  failing_since timestamptz,
  PRIMARY KEY (instance_id, collection, host)
);

-- per run and instance NAME: the instances a run reads - written at an instance's own connect (its first in the run,
-- and again when it was not written for 10 minutes: heartbeat.go's name) and by every beat for what it loaded. By
-- name: an instance never reached has no row in pgvigil.instances until its first failed read is recorded. seen_at
-- is on the collector's clock, as the load's minute and a read's snapshot_at are. collector_covers reads it.
CREATE TABLE IF NOT EXISTS pgvigil.collector_instances (
  collector_id  text NOT NULL,
  instance      text NOT NULL,
  seen_at       timestamptz NOT NULL,
  interval_s    int,                              -- the fastest configured interval of its newest loaded minute (collector_reading's allowance)
  PRIMARY KEY (collector_id, instance)
);
CREATE INDEX IF NOT EXISTS collector_instances_name ON pgvigil.collector_instances (instance, seen_at);

-- per host, instance and kind: a SPELL is an unbroken run of the instance's written minutes on the host in which it was
-- 'dead' (it ran and every run failed), 'noconn' (a connect of it did not open) or 'down' (every connect of it got no
-- answer from the server: collector_server_down). Kept by the beat
-- (collector_spells_take) from its own load rows: a minute that shows the kind continues the open spell or starts one; a
-- written minute of the instance without it ends the spell (ended_at = that minute); a minute with no row of the
-- instance changes nothing, so a 5-minute instance's bands are one spell. By HOST, not by run: a restart's two runs
-- write one minute twice, and the spell the newer run continues is not ended by the older run's row. When a failure
-- BEGAN is read here, never off the newest minutes (a standing failure looks new in every minute). Trimmed at 8 days.
CREATE TABLE IF NOT EXISTS pgvigil.collector_spells (
  host          text NOT NULL,
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  kind          text NOT NULL CHECK (kind IN ('dead', 'noconn', 'down')),
  since         timestamptz NOT NULL,             -- its first minute (the collector's clock, as the load's minute)
  last          timestamptz NOT NULL,             -- its newest minute
  ended_at      timestamptz,                      -- the written minute without it; NULL = open
  PRIMARY KEY (host, instance_id, kind, since)
);
CREATE UNIQUE INDEX IF NOT EXISTS collector_spells_open ON pgvigil.collector_spells (host, instance_id, kind) WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS collector_spells_since ON pgvigil.collector_spells (host, kind, since);

-- alert_state (0059, the alerts owner's; on released stores) gains what was last SENT of a repository-wide alert's
-- claim - its why ('collector not seen', 'instances failing together') and, where named, the server: alert_record (0190)
-- fills it at each send, alert_due sends ONE repeat when the parent's claim changes. A column added here, never by an
-- edit of 0059: a released store has applied 0059 and not this file.
ALTER TABLE pgvigil.alert_state ADD COLUMN IF NOT EXISTS why text;

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
  ON CONFLICT (collector_id) DO UPDATE SET beat_at = now(), stopped_at = NULL, retired_at = NULL;
$$;

-- import_collector_seen: the run p_id reads the instance named p_instance, at p_at on the collector's clock (the
-- heartbeat calls it inside the instance's own connect, before that connect's failure is recorded)
CREATE OR REPLACE FUNCTION pgvigil.import_collector_seen(p_id text, p_instance text, p_at timestamptz)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.collector_instances (collector_id, instance, seen_at) VALUES (p_id, p_instance, p_at)
  ON CONFLICT (collector_id, instance) DO UPDATE SET seen_at = greatest(collector_instances.seen_at, EXCLUDED.seen_at)
$$;

-- collector_spells_take: the spells of run p_id's host after its load rows of p_minute are written (the beat calls it;
-- beats come in minute order). In the minute an instance's row shows a kind or not: 'dead' = it ran and every run
-- failed, 'noconn' = a connect did not open. Without the kind: the open spell whose newest minute is older ends here.
-- With it: a spell another run of the host ended at this very minute takes it back (a restart's overlap, either run
-- first); else the open spell continues, or a new one starts - but never for a minute inside a spell of the host
-- already ended (a late minute of a run whose clock is behind: it is counted, and a new spell there would take the
-- ended one's key).
CREATE OR REPLACE FUNCTION pgvigil.collector_spells_take(p_id text, p_minute timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_host text;
BEGIN
  SELECT host INTO v_host FROM pgvigil.collector_heartbeat WHERE collector_id = p_id;
  IF v_host IS NULL THEN
    RETURN;
  END IF;
  UPDATE pgvigil.collector_spells s SET ended_at = p_minute
    FROM pgvigil.collector_load l
   WHERE l.minute = p_minute AND l.collector_id = p_id
     AND s.host = v_host AND s.instance_id = l.instance_id AND s.ended_at IS NULL AND s.last < p_minute
     AND NOT CASE s.kind WHEN 'dead' THEN l.runs > 0 AND l.failures >= l.runs
                         WHEN 'noconn' THEN l.attempts > l.opened
                         ELSE l.attempts > 0 AND l.noanswer >= l.attempts END;
  WITH k AS (
    SELECT l.instance_id, x.kind
      FROM pgvigil.collector_load l
      CROSS JOIN LATERAL (VALUES ('dead', l.runs > 0 AND l.failures >= l.runs), ('noconn', l.attempts > l.opened),
                               ('down', l.attempts > 0 AND l.noanswer >= l.attempts)) AS x(kind, hit)
     WHERE l.minute = p_minute AND l.collector_id = p_id AND x.hit)
  UPDATE pgvigil.collector_spells s SET ended_at = NULL, last = greatest(s.last, p_minute)
    FROM k
   WHERE s.host = v_host AND s.instance_id = k.instance_id AND s.kind = k.kind AND s.ended_at = p_minute
     AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_spells o
                      WHERE o.host = v_host AND o.instance_id = k.instance_id AND o.kind = k.kind AND o.ended_at IS NULL);
  INSERT INTO pgvigil.collector_spells (host, instance_id, kind, since, last)
  SELECT v_host, l.instance_id, x.kind, p_minute, p_minute
    FROM pgvigil.collector_load l
    CROSS JOIN LATERAL (VALUES ('dead', l.runs > 0 AND l.failures >= l.runs), ('noconn', l.attempts > l.opened),
                               ('down', l.attempts > 0 AND l.noanswer >= l.attempts)) AS x(kind, hit)
   WHERE l.minute = p_minute AND l.collector_id = p_id AND x.hit
     AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_spells e
                      WHERE e.host = v_host AND e.instance_id = l.instance_id AND e.kind = x.kind
                        AND e.since <= p_minute AND e.ended_at > p_minute)
  ON CONFLICT (host, instance_id, kind) WHERE ended_at IS NULL
  DO UPDATE SET last = greatest(collector_spells.last, EXCLUDED.last), since = least(collector_spells.since, EXCLUDED.since);
END $$;

-- collector_span_take: run p_id's host's span after its load rows of p_minute are written (the beat calls it): the
-- least configured interval of the instances the host read in the 15 minutes up to p_minute, 1 minute at least and 5
-- at most, in seconds on the run's heartbeat row; no interval known = NULL (collector_span then says 1 minute). The
-- configured interval, never the gaps between written minutes: a 5-minute band that straddles the beat's minute edge
-- writes two minutes in a row.
CREATE OR REPLACE FUNCTION pgvigil.collector_span_take(p_id text, p_minute timestamptz)
RETURNS void LANGUAGE sql AS $$
  UPDATE pgvigil.collector_heartbeat c
     SET span_s = (SELECT CASE WHEN x.m IS NOT NULL THEN greatest(60, least(300, x.m)) END
                     FROM (SELECT min(l.interval_s) AS m
                             FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
                            WHERE h.host = c.host AND l.minute > p_minute - interval '15 minutes' AND l.minute <= p_minute
                              AND l.interval_s > 0) x)
   WHERE c.collector_id = p_id
$$;

-- import_collector_beat: the minute's beat. p_beat: {mem_bytes, goroutines, instances,
--   runs: [{engine, collection, runs, failures, rows, dur_sum, dur_max, hist: [19 ints]}],
--   load: [{instance, attempts, opened, runs, failures, auth, interval_s}],  (interval_s: the fastest configured interval, absent when not known)
--   streaks: [{instance, collection, fails, error, at, since}]}  (instances by name; an unknown name is skipped; since =
--   the streak's first failure, absent when the collector carried the count from the repository)
-- p_minute: the minute the runs belong to. Returns false when the collector has no row (its claim never written: it
-- claims again). Trims this file's history past 8 days.
CREATE OR REPLACE FUNCTION pgvigil.import_collector_beat(p_id text, p_minute timestamptz, p_beat jsonb)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  v_conns int;
  v_host  text;
BEGIN
  SELECT host INTO v_host FROM pgvigil.collector_heartbeat WHERE collector_id = p_id;
  IF v_host IS NULL THEN
    RETURN false;
  END IF;
  SELECT count(*) INTO v_conns FROM pg_stat_activity
   WHERE datname = current_database() AND application_name LIKE 'pgvigil%';
  UPDATE pgvigil.collector_heartbeat
     SET beat_at = now(), mem_bytes = (p_beat->>'mem_bytes')::bigint, goroutines = (p_beat->>'goroutines')::int,
         instances = (p_beat->>'instances')::int, repo_conns = v_conns,
         beat_minute = greatest(beat_minute, p_minute),
         -- a run still beating 2 minutes after it was retired was retired by mistake (a second host of that name, the
         -- door run for a host that is not gone): the mark goes. A beat sooner than that is a stopping service's last
         -- one and must not undo its uninstall's retire
         retired_at = CASE WHEN retired_at < now() - interval '2 minutes' THEN NULL ELSE retired_at END
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
  INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures, interval_s, noanswer, target)
  SELECT p_minute, i.instance_id, p_id, l.attempts, l.opened, l.runs, l.failures, l.auth, nullif(l.interval_s, 0), coalesce(l.noanswer, 0), nullif(l.target, '')
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'load') = 'array' THEN p_beat->'load' ELSE '[]'::jsonb END)) AS l(instance text, attempts int, opened int, runs int, failures int, auth int, interval_s int, noanswer int, target text)
    JOIN pgvigil.instances i ON i.name = l.instance
  ON CONFLICT (minute, instance_id, collector_id) DO UPDATE
     SET attempts = collector_load.attempts + EXCLUDED.attempts, opened = collector_load.opened + EXCLUDED.opened,
         runs = collector_load.runs + EXCLUDED.runs,
         failures = collector_load.failures + EXCLUDED.failures, auth_failures = collector_load.auth_failures + EXCLUDED.auth_failures,
         interval_s = least(collector_load.interval_s, EXCLUDED.interval_s),
         noanswer = collector_load.noanswer + EXCLUDED.noanswer, target = coalesce(EXCLUDED.target, collector_load.target);
  PERFORM pgvigil.collector_spells_take(p_id, p_minute);
  PERFORM pgvigil.collector_span_take(p_id, p_minute);
  -- the beat names the instances it loaded (collector_instances): seen at the minute's end
  INSERT INTO pgvigil.collector_instances (collector_id, instance, seen_at, interval_s)
  SELECT p_id, l.instance, p_minute + interval '1 minute', nullif(l.interval_s, 0)
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'load') = 'array' THEN p_beat->'load' ELSE '[]'::jsonb END)) AS l(instance text, interval_s int)
   WHERE l.instance IS NOT NULL
  ON CONFLICT (collector_id, instance) DO UPDATE SET seen_at = greatest(collector_instances.seen_at, EXCLUDED.seen_at),
                                                    interval_s = coalesce(EXCLUDED.interval_s, collector_instances.interval_s);
  -- a streak whose beat carries its first failure ('since') takes it, whatever start is stored (a streak that ended
  -- and began again inside one beat never wrote its 0)
  UPDATE pgvigil.collector_streaks cs SET failing_since = NULL
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'streaks') = 'array' THEN p_beat->'streaks' ELSE '[]'::jsonb END)) AS s(instance text, collection text, since timestamptz)
    JOIN pgvigil.instances i ON i.name = s.instance
   WHERE cs.instance_id = i.instance_id AND cs.collection = s.collection AND cs.host = v_host AND s.since IS NOT NULL;
  INSERT INTO pgvigil.collector_streaks (instance_id, collection, host, fail_streak, last_error, last_run_at, failing_since)
  SELECT i.instance_id, s.collection, v_host, s.fails, nullif(s.error, ''), s.at, CASE WHEN s.fails > 0 THEN coalesce(s.since, s.at) END
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'streaks') = 'array' THEN p_beat->'streaks' ELSE '[]'::jsonb END)) AS s(instance text, collection text, fails int, error text, at timestamptz, since timestamptz)
    JOIN pgvigil.instances i ON i.name = s.instance
  ON CONFLICT (instance_id, collection, host) DO UPDATE
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
  DELETE FROM pgvigil.collector_spells WHERE coalesce(ended_at, last) < now() - interval '8 days';
  DELETE FROM pgvigil.collector_instances WHERE seen_at < now() - interval '8 days';
  -- this host's streaks of an instance it has not named for 8 days, written 8 days ago or more (never by the streak's
  -- own time alone: a streak at 0 is not written again while it stays 0, and a host still reading must keep counting
  -- as 0; never by the naming alone: a streak just written stays)
  DELETE FROM pgvigil.collector_streaks s
   WHERE s.host = v_host AND s.last_run_at < now() - interval '8 days'
     AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_instances ci JOIN pgvigil.collector_heartbeat h USING (collector_id)
                       JOIN pgvigil.instances i ON i.name = ci.instance
                      WHERE h.host = s.host AND i.instance_id = s.instance_id);
  DELETE FROM pgvigil.collector_heartbeat WHERE beat_at < now() - interval '8 days';
  RETURN true;
END $$;

-- import_collector_streaks: the failed runs in a row the repository holds for host p_host (a collector started again
-- on that host counts on from them; a collector on another host never takes them)
CREATE OR REPLACE FUNCTION pgvigil.import_collector_streaks(p_host text)
RETURNS TABLE (instance text, collection text, fail_streak int, last_error text) LANGUAGE sql STABLE AS $$
  SELECT i.name, s.collection, s.fail_streak, s.last_error
    FROM pgvigil.collector_streaks s JOIN pgvigil.instances i USING (instance_id)
   WHERE i.is_active AND s.fail_streak > 0 AND s.host = p_host
$$;

-- import_collector_retire: the host's collector is uninstalled and its repository kept (uninstall calls it; the
-- repository owner may, for a host that is gone): every run of the host is marked retired. collector_hosts and
-- collector_live leave such runs out, so the host raises no 'collector not seen', holds no alert and no longer keeps
-- serve's watchdog on - without it the host would stand as not seen for good. The stop mark is not touched: a run of
-- that host name still beating (a second host of the name, the door run by mistake) loses the retire at its first beat
-- 2 minutes on and reads 'up' again, never 'stopped'. A new run on the host claims a fresh row and is back. Returns
-- the runs it marked.
CREATE OR REPLACE FUNCTION pgvigil.import_collector_retire(p_host text)
RETURNS int LANGUAGE sql AS $$
  WITH u AS (
    UPDATE pgvigil.collector_heartbeat SET retired_at = now()
     WHERE host = p_host AND retired_at IS NULL RETURNING 1)
  SELECT count(*)::int FROM u
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
       CASE WHEN h.retired_at IS NOT NULL THEN 'retired'
            WHEN h.stopped_at IS NOT NULL THEN 'stopped'
            WHEN EXISTS (SELECT 1 FROM pgvigil.collector_heartbeat n WHERE n.host = h.host AND n.started_at > h.beat_at) THEN 'ended'
            WHEN h.beat_at > now() - interval '2 minutes' THEN 'up'
            ELSE 'not seen' END AS state,
       round(extract(epoch FROM now() - h.beat_at))::bigint AS beat_age_secs
  FROM pgvigil.collector_heartbeat h;

-- collector_live: the runs beating now (not stopped, not ended, not retired, a beat in the last 3 minutes)
CREATE OR REPLACE VIEW pgvigil.collector_live AS
SELECT * FROM pgvigil.collector_status
 WHERE state NOT IN ('stopped', 'ended', 'retired') AND beat_at > now() - interval '3 minutes';

-- collector_hosts: each collector (a host): its newest beat over all its runs (a console run stopped beside the service
-- does not make the host look down), whether any run is live, and its active instances - those it collected in the 15
-- minutes before its newest beat - with the ones no other host has read since that beat (orphaned). A retired run
-- (import_collector_retire) is not read: a host whose every run is retired is no collector any more
CREATE OR REPLACE VIEW pgvigil.collector_hosts AS
WITH hb AS (
  SELECT h.host, max(h.beat_at) AS beat_at, bool_and(h.stopped_at IS NOT NULL) AS all_stopped
    FROM pgvigil.collector_heartbeat h WHERE h.retired_at IS NULL GROUP BY h.host
), mine AS (
  SELECT DISTINCT hb.host, l.instance_id
    FROM hb JOIN pgvigil.collector_heartbeat h ON h.host = hb.host AND h.retired_at IS NULL
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

-- collector_together: do p_n instances, of the p_ran a collector ran, point at a shared cause - 5 or more (40 of 200
-- cut is one alert, not forty: DBA Dash's consolidation threshold), or at least 3 and over half of those it ran (a
-- small collector). The cohorts, the forming wait and the window call it, each with its own count.
CREATE OR REPLACE FUNCTION pgvigil.collector_together(p_n bigint, p_ran bigint)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_n >= 5 OR (p_n >= 3 AND p_n * 2 > p_ran)
$$;

-- collector_span: the host's span - how far apart its written minutes of one instance may lie: the least configured
-- interval of the instances it read in the last 15 minutes, 1 to 5 minutes (collector_span_take, at each beat; the
-- newest run of the host that has one); 1 minute while none is known. A cohort's window and a spell's 'still read' are
-- span + 3 minutes, the in-window reach span + 4, forming's newest minute and novelty span + 1. A host slower than 5
-- minutes keeps the early alerts.
CREATE OR REPLACE FUNCTION pgvigil.collector_span(p_host text)
RETURNS interval LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT make_interval(secs => h.span_s) FROM pgvigil.collector_heartbeat h
                    WHERE h.host = p_host AND h.span_s IS NOT NULL ORDER BY h.beat_at DESC LIMIT 1), interval '1 minute')
$$;

-- collector_cohorts: per collector (host), the instances whose failures BEGAN together. A cohort starts at a 'dead'
-- spell's first minute s0 (an ended spell's too: its first member may have recovered) and holds every dead spell of
-- the host that began in [s0, s0 + span + 3 min]; it is a shared cause when collector_together(those that began, the
-- instances the host ran in those minutes) holds, and it STANDS while 3 or more of them still fail every run (their
-- spell open and read within span + 3 minutes of the host's newest written minute). members = those still failing.
-- A spell that began before s0 is no member, however long it stands; a cohort that never recovers keeps standing
-- (a server taken out for good is removed from the configuration or muted).
CREATE OR REPLACE VIEW pgvigil.collector_cohorts AS
WITH hn AS (
  SELECT h.host, max(l.minute) AS newest, pgvigil.collector_span(h.host) + interval '3 minutes' AS w
    FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE l.minute > now() - interval '15 minutes' AND h.retired_at IS NULL
   GROUP BY h.host
), live AS (
  SELECT s.host, s.instance_id, s.since, hn.w
    FROM pgvigil.collector_spells s JOIN hn USING (host)
   WHERE s.kind = 'dead' AND s.ended_at IS NULL AND s.last >= hn.newest - hn.w
), anchor AS (
  SELECT DISTINCT a.host, a.since AS s0, l.w
    FROM live l
    JOIN pgvigil.collector_spells a ON a.host = l.host AND a.kind = 'dead' AND a.since BETWEEN l.since - l.w AND l.since
), cand AS (
  SELECT a.host, a.s0,
         (SELECT count(DISTINCT s.instance_id) FROM pgvigil.collector_spells s
           WHERE s.host = a.host AND s.kind = 'dead' AND s.since BETWEEN a.s0 AND a.s0 + a.w) AS began,
         (SELECT count(DISTINCT l.instance_id) FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
           WHERE h.host = a.host AND l.minute BETWEEN a.s0 AND a.s0 + a.w AND l.runs > 0) AS ran,
         ARRAY(SELECT DISTINCT v.instance_id FROM live v WHERE v.host = a.host AND v.since BETWEEN a.s0 AND a.s0 + a.w ORDER BY 1) AS members
    FROM anchor a
)
SELECT c.host, c.s0 AS since, c.began, c.ran, c.members,
       (SELECT string_agg(i.name, ', ' ORDER BY i.name) FROM pgvigil.instances i WHERE i.instance_id = ANY (c.members)) AS names
  FROM cand c
 WHERE pgvigil.collector_together(c.began, c.ran) AND cardinality(c.members) >= 3;

-- collector_server_down_at (task 201 DONE-2 N8, review part D's D-2 as the lead took it 14:08): per dial target, a
-- server not answering on host p_host in its written minute p_minute. The identity is the DIAL target, never the
-- server's reported address (a pooler, a container's address, a virtual name).
--   ON the target: an instance whose newest row of the 15 minutes up to the minute names it; DOWN: that row is a
--     down minute (it made connects and none got an answer: no SQLSTATE - a dropped database, a refused login, too
--     many connections are answers).
--   the QUORUM: 3 or more down members that are NEW (the row before their 'down' spell opened a connect, however old)
--     and began together (their spell's start within span + 3 minutes of the anchor, or no row of theirs between the
--     anchor and that start: an instance read every 5 or 60 minutes could not fail earlier); the ANCHOR (since) = the
--     earliest new down spell's start that gives a quorum.
--   no instance on the target ANSWERED a connect (attempts > noanswer) at or after the anchor (a row before the outage,
--     or one with no connect, is no evidence).
--   instances = every down instance on the target: a standing or never-answered member is held with them, never counted.
CREATE OR REPLACE FUNCTION pgvigil.collector_server_down_at(p_host text, p_minute timestamptz)
RETURNS TABLE (target text, since timestamptz, instances int[]) LANGUAGE sql STABLE AS $$
  WITH k AS (
    SELECT pgvigil.collector_span(p_host) + interval '3 minutes' AS w
  ), ids AS (
    SELECT h.collector_id FROM pgvigil.collector_heartbeat h WHERE h.host = p_host
  ), rws AS (
    SELECT l.instance_id, l.minute, l.target, l.attempts, l.noanswer
      FROM pgvigil.collector_load l
     WHERE l.collector_id IN (SELECT collector_id FROM ids) AND l.minute > p_minute - interval '15 minutes' AND l.minute <= p_minute
  ), tgt AS (
    SELECT DISTINCT ON (r.instance_id) r.instance_id, r.target, r.minute, (r.attempts > 0 AND r.noanswer >= r.attempts) AS down
      FROM rws r WHERE r.target IS NOT NULL
     ORDER BY r.instance_id, r.minute DESC
  ), dn AS (
    SELECT t.target, t.instance_id, s.since,
           coalesce((SELECT b.opened > 0 FROM pgvigil.collector_load b
                      WHERE b.instance_id = t.instance_id AND b.collector_id IN (SELECT collector_id FROM ids) AND b.minute < s.since
                      ORDER BY b.minute DESC LIMIT 1), false) AS new
      FROM tgt t
      JOIN pgvigil.collector_spells s ON s.host = p_host AND s.instance_id = t.instance_id AND s.kind = 'down'
                                     AND s.since <= t.minute AND s.last >= t.minute
     WHERE t.down
  ), anc AS (
    SELECT a.target, a.since AS s0,
           (SELECT count(*) FROM dn q
             WHERE q.target = a.target AND q.new AND q.since >= a.since
               AND (q.since <= a.since + k.w
                    OR NOT EXISTS (SELECT 1 FROM pgvigil.collector_load b
                                    WHERE b.instance_id = q.instance_id AND b.collector_id IN (SELECT collector_id FROM ids)
                                      AND b.minute > a.since AND b.minute < q.since))) AS quorum
      FROM dn a CROSS JOIN k
     WHERE a.new
  ), pick AS (
    SELECT DISTINCT ON (a.target) a.target, a.s0 FROM anc a WHERE a.quorum >= 3 ORDER BY a.target, a.s0
  )
  SELECT p.target, p.s0, ARRAY(SELECT d.instance_id FROM dn d WHERE d.target = p.target ORDER BY 1)
    FROM pick p
   WHERE NOT EXISTS (SELECT 1 FROM tgt t JOIN rws r ON r.instance_id = t.instance_id
                      WHERE t.target = p.target AND r.target = p.target AND r.minute >= p.s0 AND r.attempts > r.noanswer)
$$;

-- collector_server_down: the servers not answering now - collector_server_down_at of each collector's (host's) newest
-- written minute. since = the down set's anchor; instances = the down set.
CREATE OR REPLACE VIEW pgvigil.collector_server_down AS
WITH hn AS (
  SELECT h.host, max(l.minute) AS newest
    FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE l.minute > now() - interval '15 minutes' AND h.retired_at IS NULL
   GROUP BY h.host
)
SELECT hn.host, d.target, d.since, d.instances
  FROM hn CROSS JOIN LATERAL pgvigil.collector_server_down_at(hn.host, hn.newest) d;

-- collector_parent: the 'collector or network' conditions now, one row per collector (host) at most:
--   'collector not seen': no beat for 5 minutes from any run of the host while some of its active instances have not
--     been read by another host since its newest beat (orphaned; a host whose every instance moved is retired, not
--     down); its instances = the orphaned ones (held whatever the down host read after its last beat)
--   'instances failing together': a standing cohort of the host (collector_cohorts); server = the dial target when the
--     held instances are exactly a target's down set (collector_server_down: N8 - the claim then names it); since = its
--     first minute (the earliest when two stand)
--   'server not answering' (N8, the server's OWN quorum, only where no cohort stands): the host's down sets
--     (collector_server_down); server = the newest one's target; since = the earliest down set's start
-- instances (both arms, review part D's D-3): every standing cohort's members still failing AND every down set of the
-- host - a second server down, or a cohort beside a down server, releases nothing. event: the start of the host's
-- NEWEST event - a standing cohort or down set with no other one begun in the span + 3 minutes before it (chained by
-- their windows they are one event: a cut spread over a minute's edge makes a second cohort of the same cut). The
-- claim names it (collector_findings), so a new cut or a second server down on a host whose parent stands is one
-- repeat (alert_due) that passes an acknowledgement, never silence.
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
), co AS (
  SELECT c.*, pgvigil.collector_span(c.host) + interval '3 minutes' AS w FROM pgvigil.collector_cohorts c
), sd AS (
  SELECT d.*, pgvigil.collector_span(d.host) + interval '3 minutes' AS w,
         (SELECT string_agg(i.name, ', ' ORDER BY i.name) FROM pgvigil.instances i WHERE i.instance_id = ANY (d.instances)) AS names
    FROM pgvigil.collector_server_down d
), st AS (
  SELECT host, since, w FROM co UNION ALL SELECT host, since, w FROM sd
), ev AS (
  SELECT c.host, max(c.since) AS event
    FROM st c
   WHERE NOT EXISTS (SELECT 1 FROM st o WHERE o.host = c.host AND o.since < c.since AND o.since >= c.since - c.w)
   GROUP BY c.host
), held AS (
  SELECT x.host, array_agg(DISTINCT x.i ORDER BY x.i) AS instances
    FROM (SELECT c.host, m AS i FROM co c, unnest(c.members) m UNION ALL SELECT d.host, m FROM sd d, unnest(d.instances) m) x
   GROUP BY x.host
), srvs AS (
  SELECT d.host, string_agg(format('%s (%s)', d.target, d.names), '; ' ORDER BY d.since, d.target) AS text
    FROM sd d GROUP BY d.host
), together AS (
  SELECT DISTINCT ON (c.host) c.host, 'instances failing together'::text AS why,
         format('%s of the %s instance(s) %s ran failed every run in the minutes from %s, their failures beginning together: %s - a shared cause (the network, the collector host, a shared login, storage)%s',
                c.began, c.ran, c.host, c.since, c.names,
                CASE WHEN cardinality(c.members) < c.began THEN format(' (%s of them still failing)', cardinality(c.members)) ELSE '' END)
         || coalesce('; servers not answering: ' || (SELECT s.text FROM srvs s WHERE s.host = c.host), '') AS detail,
         (SELECT min(c2.since) FROM co c2 WHERE c2.host = c.host) AS since,
         (SELECT h.instances FROM held h WHERE h.host = c.host) AS instances,
         (SELECT e.event FROM ev e WHERE e.host = c.host) AS event,
         (SELECT d.target FROM sd d
           WHERE d.host = c.host AND d.instances = (SELECT h.instances FROM held h WHERE h.host = c.host)
           LIMIT 1) AS server
    FROM co c
   ORDER BY c.host, c.since DESC
), srv AS (
  SELECT DISTINCT ON (d.host) d.host, 'server not answering'::text AS why,
         format('the %s instance(s) %s reads on %s got no answer at their connects in the minutes from %s, their failures beginning together: %s - the server or the network to it, not the collector',
                cardinality(d.instances), d.host, d.target, d.since, d.names)
         || CASE WHEN (SELECT count(*) FROM sd o WHERE o.host = d.host) > 1
                 THEN '; servers not answering: ' || (SELECT s.text FROM srvs s WHERE s.host = d.host) ELSE '' END AS detail,
         (SELECT min(o.since) FROM sd o WHERE o.host = d.host) AS since,
         (SELECT h.instances FROM held h WHERE h.host = d.host) AS instances,
         (SELECT e.event FROM ev e WHERE e.host = d.host) AS event,
         d.target AS server
    FROM sd d
   ORDER BY d.host, d.since DESC, d.target
)
SELECT d.*, NULL::timestamptz AS event, NULL::text AS server FROM down d
UNION ALL
SELECT * FROM together t WHERE NOT EXISTS (SELECT 1 FROM down d WHERE d.host = t.host)
UNION ALL
SELECT * FROM srv s WHERE NOT EXISTS (SELECT 1 FROM down d WHERE d.host = s.host) AND NOT EXISTS (SELECT 1 FROM together t WHERE t.host = s.host);

-- collector_held_instances: the instances whose alerts are held - a member still failing of a standing 'instances
-- failing together', or an orphaned instance of a collector not seen (alert_due, 0190, reads it once per pass)
CREATE OR REPLACE VIEW pgvigil.collector_held_instances AS
SELECT DISTINCT x.instance_id
  FROM pgvigil.collector_parent p CROSS JOIN LATERAL unnest(p.instances) AS x(instance_id);

-- collector_shared_cause: the findings a shared cause (the network, the collector host, a shared login) explains -
-- the ones alert_due (0190) holds under 'collector or network' and makes wait while one forms: the collector's own
-- kinds (0118's 'server unreachable' with them, for an instance no heartbeat covers), and the findings judged by age against now() on data a cut stops refreshing (a job still 'running', a due
-- time passed with no run seen, the last clean amcheck, an index's unused window). Every other finding comes from the
-- last good read and is sent as it is (a full disk found before a cut may be the shared cause itself).
CREATE OR REPLACE FUNCTION pgvigil.collector_shared_cause(p_source text, p_setting text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce((p_source = 'pgvigil collector' AND p_setting IN ('authentication failing', 'collection failing', 'server unreachable'))
      OR (p_source = 'collector' AND p_setting = 'server unreachable')   -- 0118's (task 177 D30), where no heartbeat covers the instance
      OR (p_source = 'pgvigil' AND p_setting IN ('job run over twice its average', 'job schedule missed'))
      OR (p_source = 'mssql_jobs' AND p_setting = 'a job runs far longer than its average')
      OR (p_source = 'pg-backups' AND p_setting LIKE 'amcheck older than %')
      OR (p_source = 'pgvigil indexes' AND p_setting = 'unused index'), false)
$$;

-- collector_covers: does a collector that beats cover the instance's failed read at p_at - has a run not retired
-- NAMED the instance (collector_instances) after p_at - 20 minutes? Then the instance's connect failures are this
-- file's to report ('authentication failing', 'server unreachable': they carry the streak, its start and the
-- failing-together window), and the findings view (0190) leaves 0118's own 'server unreachable' out for it: an
-- instance has ONE. A run names an instance inside the instance's own connect, before that connect's failure is
-- recorded, and at every beat - so a collector back after a long stop, an instance read once an hour and one never
-- reached are covered at their first failed read, which a load row (written only at the next beat) is not. Tied to
-- the failed read's own time: an instance moved to a `pgvigil collect` on a schedule (no heartbeat) is named no more
-- and has 0118's finding back 20 minutes after its last name; a stopped collector's instances stay covered for the
-- reads it made.
CREATE OR REPLACE FUNCTION pgvigil.collector_covers(p_instance_id int, p_at timestamptz)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pgvigil.instances i
                   JOIN pgvigil.collector_instances ci ON ci.instance = i.name
                   JOIN pgvigil.collector_heartbeat h USING (collector_id)
                  WHERE i.instance_id = p_instance_id AND h.retired_at IS NULL
                    AND ci.seen_at > p_at - interval '20 minutes')
$$;

-- alert_key: an alert's key. The repository-wide 'collector or network' is keyed on its value AS IT IS - the value
-- names the collector's host, and alert_finding_key (0059) replaces a number by '#', so the parents of hosts 'pgv-1'
-- and 'pgv-2' shared one key and the second, cut by the same event, was never sent. Every other finding keeps 0059's
-- key. alert_findings (0190) and the alert page's two queries call it, so they agree.
CREATE OR REPLACE FUNCTION pgvigil.alert_key(p_instance_id int, p_source text, p_setting text, p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_instance_id IS NULL AND p_source = 'pgvigil repository' AND p_setting = 'collector or network'
              THEN md5('0' || E'\x1f' || p_source || E'\x1f' || p_setting || E'\x1f' || coalesce(p_value, ''))
              ELSE pgvigil.alert_finding_key(coalesce(p_instance_id, 0), p_source, p_setting, p_value) END
$$;

-- collector_forming_at: the instances of a 'collector or network' that may be forming on host p_host in its written
-- minute p_minute - the instances whose trouble is NEW in that minute are a shared cause (collector_together, of the
-- instances the host ran in it). New: a 'noconn' spell (a connect that did not open) that covers the minute and began
-- within span + 1 minute of it, or a failed run in the minute with a failed-run streak of the host that began as
-- recently (the streak as it stands now: a past minute whose streak has since ended reads as not new). A standing
-- failure is never new (a refused login an hour old, a 5-minute collection failing every run), however many instances
-- carry one. collector_forming asks it of each host's newest minute; collector_forming_ended and the parent's covers
-- text (collector_forming_stopped) of earlier minutes.
CREATE OR REPLACE FUNCTION pgvigil.collector_forming_at(p_host text, p_minute timestamptz)
RETURNS TABLE (instance_id int) LANGUAGE sql STABLE AS $$
  WITH m AS (
    SELECT l.instance_id, sum(l.runs) AS runs, sum(l.failures) AS failures, pgvigil.collector_span(p_host) + interval '1 minute' AS age
      FROM pgvigil.collector_heartbeat h
      JOIN pgvigil.collector_load l ON l.collector_id = h.collector_id AND l.minute = p_minute
     WHERE h.host = p_host
     GROUP BY l.instance_id
  ), c AS (
    SELECT m.*,
           EXISTS (SELECT 1 FROM pgvigil.collector_spells s
                    WHERE s.host = p_host AND s.instance_id = m.instance_id AND s.kind = 'noconn'
                      AND s.since <= p_minute AND s.last >= p_minute AND s.since >= p_minute - m.age)
           OR (m.failures > 0 AND EXISTS (SELECT 1 FROM pgvigil.collector_streaks t
                                           WHERE t.instance_id = m.instance_id AND t.host = p_host AND t.fail_streak > 0
                                             AND t.failing_since >= p_minute - m.age)) AS counts
      FROM m
  )
  SELECT c.instance_id FROM c
   WHERE c.counts AND pgvigil.collector_together((SELECT count(*) FROM c WHERE c.counts), (SELECT count(*) FROM c WHERE c.runs > 0))
$$;

-- collector_forming: the instances of a 'collector or network' that may be forming now - collector_forming_at of each
-- collector's (host's) newest written minute. alert_due holds the NEW alerts of the counted instances
-- (collector_shared_cause) until the next minute is written; nothing waits longer than span + 3 minutes after its own
-- trouble began - the cap is the clock. A minute older than span + 1 minutes is not newest (a late collector); the
-- repository's current minute counts (a beat writes a minute once it ended on the collector's clock, which may run
-- ahead).
CREATE OR REPLACE VIEW pgvigil.collector_forming AS
WITH hn AS (
  SELECT x.host, x.newest
    FROM (SELECT h.host, max(l.minute) AS newest, pgvigil.collector_span(h.host) + interval '1 minute' AS age
            FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
           WHERE l.minute >= date_trunc('minute', now()) - interval '6 minutes' AND h.retired_at IS NULL
           GROUP BY h.host) x
   WHERE x.newest >= date_trunc('minute', now()) - x.age
)
SELECT f.instance_id, hn.host, hn.newest AS minute
  FROM hn CROSS JOIN LATERAL pgvigil.collector_forming_at(hn.host, hn.newest) f;

-- collector_stood (review part D's D-4): did a 'collector or network' condition stand on host p_host at one of its
-- written minutes in [p_from, p_to] - a cohort (a 'dead' spell anchor meeting collector_together, 3 or more of its
-- members failing at that minute: collector_cohorts' rule) or a server not answering (collector_server_down_at)?
-- A forming wait that ran into a parent, since cleared, did not end without one.
CREATE OR REPLACE FUNCTION pgvigil.collector_stood(p_host text, p_from timestamptz, p_to timestamptz)
RETURNS boolean LANGUAGE sql STABLE AS $$
  WITH k AS (
    SELECT pgvigil.collector_span(p_host) + interval '3 minutes' AS w
  ), mins AS (
    SELECT DISTINCT l.minute FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
     WHERE h.host = p_host AND l.minute BETWEEN p_from AND p_to
  ), anchor AS (
    SELECT DISTINCT a.since AS s0, k.w
      FROM pgvigil.collector_spells a CROSS JOIN k
     WHERE a.host = p_host AND a.kind = 'dead' AND a.since <= p_to
       AND EXISTS (SELECT 1 FROM pgvigil.collector_spells c
                    WHERE c.host = p_host AND c.kind = 'dead' AND c.since BETWEEN a.since AND a.since + k.w AND c.last >= p_from)
  )
  SELECT EXISTS (SELECT 1 FROM anchor a
                  WHERE pgvigil.collector_together(
                          (SELECT count(DISTINCT c.instance_id) FROM pgvigil.collector_spells c
                            WHERE c.host = p_host AND c.kind = 'dead' AND c.since BETWEEN a.s0 AND a.s0 + a.w),
                          (SELECT count(DISTINCT l.instance_id) FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
                            WHERE h.host = p_host AND l.minute BETWEEN a.s0 AND a.s0 + a.w AND l.runs > 0))
                    AND EXISTS (SELECT 1 FROM mins t
                                 WHERE (SELECT count(DISTINCT c.instance_id) FROM pgvigil.collector_spells c
                                         WHERE c.host = p_host AND c.kind = 'dead' AND c.since BETWEEN a.s0 AND a.s0 + a.w
                                           AND c.since <= t.minute AND c.last >= t.minute) >= 3))
      OR EXISTS (SELECT 1 FROM mins t WHERE EXISTS (SELECT 1 FROM pgvigil.collector_server_down_at(p_host, t.minute)))
$$;

-- collector_forming_ended (task 201 DONE-2 N7): per collector (host) on which a forming wait ended WITHOUT a parent - no
-- parent stands, forming does not hold in its newest written minute, and in one of its written minutes of the last 15
-- forming held: last_forming = the newest such minute, ended_at = the next written minute (the wait's end: its alerts
-- went out as they came), instances = those it counted. A wait that ran into a parent since cleared (collector_stood
-- from span + 3 minutes before its last forming minute) is not one (review part D's D-4); the newest minute is judged
-- by its own forming, not by collector_forming's freshness (a host whose beats come late: nit 8). The Collector page
-- says it under the host; a parent's detail never does (a parent that rises later says it in its covers text:
-- collector_forming_stopped).
CREATE OR REPLACE VIEW pgvigil.collector_forming_ended AS
WITH hn AS (
  SELECT h.host, max(l.minute) AS newest, pgvigil.collector_span(h.host) + interval '3 minutes' AS w
    FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE l.minute > now() - interval '16 minutes' AND h.retired_at IS NULL
   GROUP BY h.host
), w AS (
  SELECT hn.host, hn.newest, hn.w, m.minute, ARRAY(SELECT f.instance_id FROM pgvigil.collector_forming_at(hn.host, m.minute) f ORDER BY 1) AS insts
    FROM hn
    CROSS JOIN LATERAL (SELECT DISTINCT l.minute FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
                         WHERE h.host = hn.host AND l.minute > hn.newest - interval '15 minutes' AND l.minute <= hn.newest) m
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.collector_parent p WHERE p.host = hn.host)
), lf AS (
  SELECT DISTINCT ON (w.host) w.host, w.newest, w.w, w.minute AS last_forming, w.insts
    FROM w WHERE cardinality(w.insts) > 0
   ORDER BY w.host, w.minute DESC
)
SELECT lf.host, lf.last_forming,
       (SELECT min(l.minute) FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
         WHERE h.host = lf.host AND l.minute > lf.last_forming) AS ended_at,
       lf.insts AS instances
  FROM lf
 WHERE lf.last_forming < lf.newest
   AND NOT pgvigil.collector_stood(lf.host, lf.last_forming - lf.w, lf.newest);

-- collector_forming_stopped (task 201 DONE-2 N7): for a parent on host p_host since p_since, the written minute at which
-- a forming wait of the 15 minutes before it stopped without a parent (forming held, then a written minute before
-- p_since in which it did not): the alerts that went out then are the ones the parent's covers text says went first.
-- NULL when the wait ran into this parent, or into an earlier one since cleared (collector_stood before p_since:
-- review part D's D-4), or none ran.
CREATE OR REPLACE FUNCTION pgvigil.collector_forming_stopped(p_host text, p_since timestamptz)
RETURNS timestamptz LANGUAGE sql STABLE AS $$
  WITH m AS (
    SELECT DISTINCT l.minute FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
     WHERE h.host = p_host AND l.minute >= p_since - interval '15 minutes' AND l.minute < p_since
  ), f AS (
    SELECT m.minute, EXISTS (SELECT 1 FROM pgvigil.collector_forming_at(p_host, m.minute)) AS forming FROM m
  ), f1 AS (
    SELECT max(f.minute) AS last FROM f WHERE f.forming
  )
  SELECT min(f2.minute) FROM f f2, f1
   WHERE NOT f2.forming AND f2.minute > f1.last
     AND NOT pgvigil.collector_stood(p_host, f1.last - (pgvigil.collector_span(p_host) + interval '3 minutes'), p_since - interval '1 minute')
$$;

-- collector_in_window: whether a failure at p_at of the instance lies inside an 'instances failing together' window
-- of a host that ran it - a minute in (p_at - (span + 4 min), p_at + (span + 4 min)] in which the instance's dead spell
-- ran and its cohort stood (it began together with a shared cause, and 3 or more of it failed every run then).
-- alert_due: a NEW collector kind of the instance whose newest failure (the finding's at) is inside waits - after the
-- parent clears, an instance still failing alerts once per finding after one failure past the window, never off a
-- streak or a refusal from inside it. Anchored to the finding, with no look-back cap: it reads the instance's spells
-- that overlap the reach and their cohorts only. A spell that began before a cohort is never in its window.
-- The server arm (review part D's D-1): a written minute of the host in the reach at which the instance's 'down'
-- spell ran and it was in a server's down set (collector_server_down_at) - the members whose connects fell before a
-- server came back wait as a cohort's stragglers do; they never go out the minute the first member answers.
CREATE OR REPLACE FUNCTION pgvigil.collector_in_window(p_instance_id int, p_at timestamptz)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
      FROM pgvigil.collector_spells s
      CROSS JOIN LATERAL (SELECT pgvigil.collector_span(s.host) + interval '4 minutes' AS r) k
      CROSS JOIN LATERAL (SELECT DISTINCT l.minute FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
                           WHERE h.host = s.host AND l.minute > p_at - k.r AND l.minute <= p_at + k.r
                             AND l.minute >= s.since AND l.minute <= s.last) t
     WHERE s.instance_id = p_instance_id AND s.kind = 'down'
       AND s.last > p_at - k.r AND s.since <= p_at + k.r
       AND EXISTS (SELECT 1 FROM pgvigil.collector_server_down_at(s.host, t.minute) d WHERE p_instance_id = ANY (d.instances)))
  OR EXISTS (
    SELECT 1
      FROM pgvigil.collector_spells s
      CROSS JOIN LATERAL (SELECT pgvigil.collector_span(s.host) + interval '3 minutes' AS w,
                                 pgvigil.collector_span(s.host) + interval '4 minutes' AS r) k
      JOIN pgvigil.collector_spells a ON a.host = s.host AND a.kind = 'dead' AND a.since BETWEEN s.since - k.w AND s.since
     WHERE s.instance_id = p_instance_id AND s.kind = 'dead'
       AND s.last > p_at - k.r AND s.since <= p_at + k.r
       AND pgvigil.collector_together(
             (SELECT count(DISTINCT c.instance_id) FROM pgvigil.collector_spells c
               WHERE c.host = s.host AND c.kind = 'dead' AND c.since BETWEEN a.since AND a.since + k.w),
             (SELECT count(DISTINCT l.instance_id) FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
               WHERE h.host = s.host AND l.minute BETWEEN a.since AND a.since + k.w AND l.runs > 0))
       AND EXISTS (SELECT 1
                     FROM generate_series(greatest(s.since, date_trunc('minute', p_at - k.r)), least(s.last, p_at + k.r), interval '1 minute') t
                    WHERE t > p_at - k.r
                      AND (SELECT count(DISTINCT c.instance_id) FROM pgvigil.collector_spells c
                            WHERE c.host = s.host AND c.kind = 'dead' AND c.since BETWEEN a.since AND a.since + k.w
                              AND c.since <= t AND c.last >= t) >= 3))
$$;

-- collector_down: a collector not seen for 5 minutes (serve's watchdog runs the alert pass then: the collector that
-- would send it is the one down)
CREATE OR REPLACE FUNCTION pgvigil.collector_down()
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pgvigil.collector_parent WHERE why = 'collector not seen')
$$;

-- collector_reading: the hosts still reading each instance - a host reads it while its newest naming of it (the beat
-- names what it loaded, at the minute's end; the instance's own connect names it too) is no older than the host's own
-- newest - its newest naming of any instance, or its newest beat minute's end when later - less the instance's
-- interval and a beat. Judged against the host's OWN clock, never another host's rows: a host that beats with nothing
-- left to read stops reading what moved away. A host with no live run (crashed, stopped, renamed: its newest frozen)
-- reads an instance only while no live host reads it - its old streaks never speak over a live host's; as the only
-- reader it speaks until collector_covers ends that, 20 minutes after its last naming.
CREATE OR REPLACE VIEW pgvigil.collector_reading AS
WITH n AS (
  SELECT h.host, ci.instance, max(ci.seen_at) AS seen, max(ci.interval_s) AS interval_s
    FROM pgvigil.collector_instances ci JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE h.retired_at IS NULL
   GROUP BY h.host, ci.instance
), hs AS (
  SELECT n.host, greatest(max(n.seen), (SELECT max(h.beat_minute) + interval '1 minute' FROM pgvigil.collector_heartbeat h
                                          WHERE h.host = n.host AND h.retired_at IS NULL)) AS newest,
         n.host IN (SELECT v.host FROM pgvigil.collector_live v) AS live
    FROM n GROUP BY n.host
), r AS (
  SELECT n.host, i.instance_id, hs.live
    FROM n JOIN hs USING (host) JOIN pgvigil.instances i ON i.name = n.instance
   WHERE n.seen >= hs.newest - make_interval(secs => coalesce(n.interval_s, 60)) - interval '1 minute'
)
SELECT r.host, r.instance_id
  FROM r
 WHERE r.live OR NOT EXISTS (SELECT 1 FROM r o WHERE o.instance_id = r.instance_id AND o.live);

-- collector_streaks_now: per instance and collection the streak that speaks - the LOWEST among the hosts still reading
-- the instance (collector_reading); a host with no streak of that collection (it has it off) is left out, never counted
-- as 0. One host failing beside another reading fine is no finding: the instance is being read ('collected by more
-- than one collector' already says two read it).
CREATE OR REPLACE VIEW pgvigil.collector_streaks_now AS
SELECT DISTINCT ON (s.instance_id, s.collection) s.instance_id, s.collection, s.host, s.fail_streak, s.last_error, s.last_run_at, s.failing_since
  FROM pgvigil.collector_streaks s
  JOIN pgvigil.collector_reading r ON r.host = s.host AND r.instance_id = s.instance_id
 ORDER BY s.instance_id, s.collection, s.fail_streak, s.last_run_at DESC;

-- collector_claim: a repository-wide finding's claim - the part of its detail before the first ': ' (the parent's
-- detail leads with it: '<why>: ...'). alert_record stores it at a send, alert_due compares it, the page reads it.
CREATE OR REPLACE FUNCTION pgvigil.collector_claim(p_detail text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(split_part(coalesce(p_detail, ''), ': ', 1), '')
$$;

-- collector_claim_newer: does claim p_new name a NEWER event of failures beginning together than claim p_old - the
-- one change that passes an acknowledgement of the parent (alert_due, as an escalation does: what the ack covered was
-- known when it was given; a second outage hidden by it is the worse failure). The old claim names no start ('collector
-- not seen') or an earlier one: the start times alone are compared (the fixed 'YYYY-MM-DD HH24:MI' form orders as
-- text), read from either form - 'instances failing together from <T> UTC' or 'server <target> not answering from <T>
-- UTC' (review part D's D-3: a second server down is a newer event; a down server's event widening into a cohort of
-- the same start is not). A why turning to 'collector not seen', back to an older start when a newer event clears, or
-- a server named or dropped on one event (N8), is no newer event: the ack holds.
CREATE OR REPLACE FUNCTION pgvigil.collector_claim_newer(p_new text, p_old text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(substring(p_new FROM '^(?:instances failing together|server [^ ]+ not answering) from ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}) UTC')
                  > coalesce(substring(p_old FROM '^(?:instances failing together|server [^ ]+ not answering) from ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}) UTC'), ''), false)
$$;

-- collector_findings: the findings shape (pgvigil.findings' arms). Source 'pgvigil repository' marks the
-- repository-wide ones (no instance: every channel past its severity floor takes them); 'pgvigil collector' an
-- instance's.
CREATE OR REPLACE VIEW pgvigil.collector_findings AS
-- the parent: its value is the host alone (one alert per collector, whatever its why: a restart inside the hold, or a
-- cut that turns into a host not seen, is the same alert, repeated once with its new why - alert_due); the claim
-- leads the detail (collector_claim reads it): the why, and for 'instances failing together' the start of the host's
-- newest event in UTC minutes (a new cut while one stands is one repeat; UTC: one session stores the claim, another
-- compares it)
SELECT NULL::int AS instance_id, 'critical'::text AS severity, 'collector or network'::text AS setting, p.host AS value,
       true AS is_set, 'the collector beating and its instances read'::text AS suggested, 'all'::text AS platforms,
       CASE WHEN p.why = 'server not answering' THEN 'server ' || p.server || ' not answering'
                 || coalesce(' from ' || to_char(p.event AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '')
            ELSE p.why || coalesce(' from ' || to_char(p.event AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '')
                 || coalesce(' on server ' || p.server, '') END || ': '
       || p.detail || '; the alerts of its instances not read since are held until this clears'
       || coalesce((SELECT '; it covers ' || count(*) || ' open alert(s): ' || string_agg(o.x, ', ' ORDER BY o.x)
                           -- N7: a forming wait that stopped before this parent rose sent these as they came - the
                           -- ones first sent from the wait's stop to the parent's own first send (nit 6), its time in UTC (nit 5)
                           || coalesce('; the forming wait had stopped at ' || to_char(st.at AT TIME ZONE 'UTC', 'HH24:MI') || ' UTC: '
                                       || count(*) FILTER (WHERE o.first_sent >= st.at AND o.first_sent < coalesce(ps.first, now())) || ' of these went out before this parent', '')
                      FROM (SELECT format('%s %s (%s)', a.instance_name, a.setting, a.value) AS x, min(a.first_sent_at) AS first_sent
                              FROM pgvigil.alert_state a
                             WHERE a.cleared_at IS NULL AND a.instance_id = ANY (p.instances)   -- held: collector_held_instances
                               AND pgvigil.collector_shared_cause(a.source, a.setting)
                             GROUP BY 1) o
                      CROSS JOIN (SELECT pgvigil.collector_forming_stopped(p.host, p.since) AS at) st
                      CROSS JOIN (SELECT min(s.first_sent_at) AS first FROM pgvigil.alert_state s
                                   WHERE s.cleared_at IS NULL AND s.source = 'pgvigil repository'
                                     AND s.setting = 'collector or network' AND s.value = p.host) ps
                    GROUP BY st.at, ps.first
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
  FROM pgvigil.collector_streaks_now s JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND s.collection <> '(connect)' AND s.fail_streak >= 3 AND s.last_run_at > now() - interval '1 day'
   -- it stands during an outage too (the page shows it); alert_due (0190) decides the send: held while 'collector or
   -- network' stands, and after it one failed run past its window (collector_in_window)
   -- a streak speaks only while a beating collector still names the instance (collector_covers): only such a run ends
   -- it. An instance moved to a `pgvigil collect` on a schedule, or one whose collector died, leaves this view 20
   -- minutes after its last naming; the Summary's Collection Errors check reads the scheduled collect's errors
   AND pgvigil.collector_covers(s.instance_id, now())
UNION ALL
-- the instance's own connect failing, the server not answering (not a refused login: that is 'authentication
-- failing'): 3 attempts in a row over a minute or more (heartbeat.go's '(connect)' streak); a run that fails there
-- builds no 'collection failing'
SELECT s.instance_id, 'critical', 'server unreachable', 'no connection', true, 'the server answering the collector', 'all',
       format('%s connection attempts in a row failed since %s: %s', s.fail_streak, s.failing_since, coalesce(s.last_error, 'no error text')),
       'pgvigil collector', s.last_run_at
  FROM pgvigil.collector_streaks_now s JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND s.collection = '(connect)' AND s.fail_streak >= 3
   AND s.last_run_at - s.failing_since >= interval '60 seconds' AND s.last_run_at > now() - interval '1 day'
   -- while a beating collector names the instance (as 'collection failing'); past that 0118's own speaks for it (0190
   -- lets it through for a read no heartbeat covers): one finding for the server, never two. Its open alert is not
   -- resolved by leaving (0059 resolves on an ok read only); a move to a scheduled collect while it fails is announced
   -- again by 0118's (another source: the docs say it)
   AND pgvigil.collector_covers(s.instance_id, now())
UNION ALL
-- per host it stands until a minute after the last refusal opened a connection (the login works again); the instance's
-- finding stands at the LOWEST of the hosts still reading it, as the streaks' (a host refused beside one reading fine
-- is no finding)
SELECT a.instance_id, 'critical', 'authentication failing', 'login refused', true, 'the login the collector uses works', 'all',
       format('%s login(s) refused in 15 minutes (a per-database connect included): a changed password or pg_hba? each run retries it and can lock the login out',
              min(a.n)),
       'pgvigil collector', max(a.at)
  FROM (SELECT h.host, l.instance_id,
               CASE WHEN sum(l.auth_failures) > 0
                     AND max(l.minute) FILTER (WHERE l.auth_failures > 0) >= coalesce(max(l.minute) FILTER (WHERE l.opened > 0 AND l.auth_failures = 0), '-infinity')
                    THEN sum(l.auth_failures) ELSE 0 END AS n,
               max(l.minute) FILTER (WHERE l.auth_failures > 0) AS at
          FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id) JOIN pgvigil.instances i USING (instance_id)
         WHERE i.is_active AND l.minute > now() - interval '15 minutes'
         GROUP BY h.host, l.instance_id) a
  JOIN pgvigil.collector_reading r ON r.host = a.host AND r.instance_id = a.instance_id
 GROUP BY a.instance_id
HAVING min(a.n) > 0
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
