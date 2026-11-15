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
  -- B6g-1: the imports (N27: import_failed is inside failed; import_runs = the runs that attempted an import, the
  -- divisor of its average; the times in ms, apart from dur_ms_sum, which holds them too) and the runs that read their
  -- own session's CPU and logical reads at their end (N25 / N26: SQL Server; cpu_runs = those runs). The LAST columns,
  -- each with a default: a row written by position, or by a collector from before them, holds zeros
  import_failed    int NOT NULL DEFAULT 0,
  import_runs      int NOT NULL DEFAULT 0,
  import_ms_sum    bigint NOT NULL DEFAULT 0,
  import_ms_max    int NOT NULL DEFAULT 0,
  cpu_runs         int NOT NULL DEFAULT 0,
  cpu_ms_sum       bigint NOT NULL DEFAULT 0,
  cpu_ms_max       int NOT NULL DEFAULT 0,
  reads_sum        bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (hour, instance_id, collection, collector_id)
) WITH (fillfactor = 70);
-- a store that applied this file before B6g-1 has the table without them. 'pgvigil migrate' applies a recorded file
-- no second time (such a store is made fresh, as every store of an untagged build is until v0.4.0); this ALTER and
-- the DROP before collection_health() below let the file be applied again by hand, whole and in one transaction, with
-- the roles put back after it: psql -1 -f 0166_collection_health.sql -c 'SELECT pgvigil.apply_roles()' (CREATE OR
-- REPLACE resets SECURITY DEFINER, which migrate puts back after every file: without it the collector's heartbeat
-- import is refused)
ALTER TABLE pgvigil.collection_health_hour
  ADD COLUMN IF NOT EXISTS import_failed int NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS import_runs int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS import_ms_sum bigint NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS import_ms_max int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cpu_runs int NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS cpu_ms_sum bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cpu_ms_max int NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS reads_sum bigint NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS collection_health_hour_instance ON pgvigil.collection_health_hour (instance_id, hour);
-- one collection's rows across the fleet (the Collection Performance report and the Collection family at the root): J5
-- (the review of B6g-3 #6, the lead's 13:3x rule) read 'activity' over 8 days at 2,124 instances x 60 collections in
-- 5,398 ms without it - every hour row read (742,756 buffers) for 1 in 60. Its cost on the beat's upsert is in the DONE.
CREATE INDEX IF NOT EXISTS collection_health_hour_collection ON pgvigil.collection_health_hour (collection, hour);

-- 8 days by default (as collector_load); settable up to 30 with
--   UPDATE pgvigil.hours_retention SET days = 30, changed_at = now() WHERE table_name = 'collection_health_hour';
-- (docs/collection-health.md); more than 30 is refused (the CHECK below: 'pgvigil purge -hours
-- collection_health_hour=40' fails in words, never trims silently at 30), and the trim clamps it to 1-30 as well
INSERT INTO pgvigil.hours_retention (table_name, days) VALUES ('collection_health_hour', 8) ON CONFLICT (table_name) DO NOTHING;
ALTER TABLE pgvigil.hours_retention DROP CONSTRAINT IF EXISTS hours_retention_collection_health_30;
ALTER TABLE pgvigil.hours_retention ADD CONSTRAINT hours_retention_collection_health_30
  CHECK (table_name <> 'collection_health_hour' OR days <= 30);

-- the beat's door for the hourly rows: one set-based statement a beat (the beat's jsonb 'health' array, heartbeat.go
-- beatHealth), instances by name (a name not in pgvigil.instances is left out), then the fold's stamps for the beating run's
-- host (collection_runs_long_since, B6f7 #2), then the table's own trim
CREATE OR REPLACE FUNCTION pgvigil.import_collection_health(p_id text, p_beat jsonb) RETURNS int
LANGUAGE plpgsql SET jit = off AS $$
DECLARE n int; v_host text; v_long int[];
BEGIN
  INSERT INTO pgvigil.collection_health_hour AS h (hour, instance_id, collection, collector_id, runs, ok, partial, failed, skipped,
         rows_written, dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s, last_ok_at, last_failure_at, last_partial_at,
         import_failed, import_runs, import_ms_sum, import_ms_max, cpu_runs, cpu_ms_sum, cpu_ms_max, reads_sum)
  SELECT x.hour, i.instance_id, x.collection, p_id, x.runs, x.ok, x.partial, x.error, x.skipped, x.rows, x.dur_ms_sum, x.dur_ms_max,
         x.over_half, x.over_interval, nullif(x.interval_s, 0), x.last_ok_at, x.last_error_at, x.last_partial_at,
         -- B6g-1's keys: a collector from before them sends none (zeros)
         coalesce(x.import_failed, 0), coalesce(x.import_runs, 0), coalesce(x.import_ms_sum, 0), coalesce(x.import_ms_max, 0),
         coalesce(x.cpu_runs, 0), coalesce(x.cpu_ms_sum, 0), coalesce(x.cpu_ms_max, 0), coalesce(x.reads_sum, 0)
    FROM jsonb_to_recordset(coalesce(p_beat -> 'health', '[]')) AS x(instance text, collection text, hour timestamptz, runs int, ok int,
           partial int, error int, skipped int, rows bigint, dur_ms_sum bigint, dur_ms_max int, over_half int, over_interval int,
           interval_s int, last_ok_at timestamptz, last_error_at timestamptz, last_partial_at timestamptz,
           import_failed int, import_runs int, import_ms_sum bigint, import_ms_max int, cpu_runs int, cpu_ms_sum bigint, cpu_ms_max int,
           reads_sum bigint)
    JOIN pgvigil.instances i ON i.name = x.instance
  ON CONFLICT (hour, instance_id, collection, collector_id) DO UPDATE
     SET runs = EXCLUDED.runs, ok = EXCLUDED.ok, partial = EXCLUDED.partial, failed = EXCLUDED.failed, skipped = EXCLUDED.skipped,
         rows_written = EXCLUDED.rows_written, dur_ms_sum = EXCLUDED.dur_ms_sum, dur_ms_max = EXCLUDED.dur_ms_max,
         runs_over_half = EXCLUDED.runs_over_half, runs_over_interval = EXCLUDED.runs_over_interval, interval_s = EXCLUDED.interval_s,
         last_ok_at = EXCLUDED.last_ok_at, last_failure_at = EXCLUDED.last_failure_at, last_partial_at = EXCLUDED.last_partial_at,
         import_failed = EXCLUDED.import_failed, import_runs = EXCLUDED.import_runs, import_ms_sum = EXCLUDED.import_ms_sum,
         import_ms_max = EXCLUDED.import_ms_max, cpu_runs = EXCLUDED.cpu_runs, cpu_ms_sum = EXCLUDED.cpu_ms_sum,
         cpu_ms_max = EXCLUDED.cpu_ms_max, reads_sum = EXCLUDED.reads_sum
   -- a row the beat sends unchanged (the hour before, a slow collection's) is not written again: every counted run
   -- raises runs or skipped, so a change is never missed, and a lost beat still differs from the stored row
   WHERE (h.runs, h.skipped) IS DISTINCT FROM (EXCLUDED.runs, EXCLUDED.skipped);
  GET DIAGNOSTICS n = ROW_COUNT;
  -- B6f7 #2 (the lead's 07:2x (a)): the beating run's host - its judged instances running long there stamped since now
  -- (kept while they stay long), the others unstamped; collection_runs_long_forming reads the stamps. A host with no
  -- unretired run left loses its stamps.
  -- In its own sub-block (B6f9 #2): a failure there is a WARNING and the hour rows above are kept; one host's runs
  -- stamp in turn (an advisory lock per host; two runs of a host beat at the same second), in instance order.
  SELECT h.host INTO v_host FROM pgvigil.collector_heartbeat h WHERE h.collector_id = p_id;
  IF v_host IS NOT NULL THEN
    BEGIN
      PERFORM pg_advisory_xact_lock(hashtext('collection_runs_long_since'), hashtext(v_host));
      SELECT coalesce(array_agg(j.instance_id ORDER BY j.instance_id), '{}') INTO v_long
        FROM pgvigil.collection_runs_long_judged j WHERE j.host = v_host AND j.level >= 1;
      DELETE FROM pgvigil.collection_runs_long_since s WHERE s.host = v_host AND s.instance_id <> ALL (v_long);
      INSERT INTO pgvigil.collection_runs_long_since (host, instance_id, since)
      SELECT v_host, x.instance_id, now() FROM unnest(v_long) AS x(instance_id) ORDER BY x.instance_id
      ON CONFLICT (host, instance_id) DO NOTHING;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'collection_runs_long_since: % not stamped: %', v_host, SQLERRM;
    END;
  END IF;
  DELETE FROM pgvigil.collection_runs_long_since s
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.collector_heartbeat h WHERE h.host = s.host AND h.retired_at IS NULL);
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
-- B6g-2 (N33 / N41): DBA Dash's per-collection thresholds (dbo.CollectionHealthThresholds) in pg_thresholds' history
-- shape (0103): instance_id NULL = every instance, collection NULL = every collection; each column NULL = the next
-- level up - this instance and collection, this instance's row for every collection, this collection's row for every
-- instance, the row for everything, then DBA Dash's defaults (CollectionHealthThresholds.sql's order). dont_monitor
-- three-state: NULL inherit, true not judged (N/A), false judged over a wider true. Written through
-- import_collection_health_threshold only; a change ends the live row and writes its successor (replaces); inherit
-- ends it.
CREATE TABLE IF NOT EXISTS pgvigil.collection_health_threshold (
  threshold_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id        int REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  instance_name      text,
  collection         text CHECK (length(collection) BETWEEN 1 AND 100),
  warn_fails_in_row  int CHECK (warn_fails_in_row BETWEEN 1 AND 100000),   -- DBA Dash's dialog ranges
  warn_fail_minutes  int CHECK (warn_fail_minutes BETWEEN 0 AND 1000000),
  crit_fails_in_row  int CHECK (crit_fails_in_row BETWEEN 1 AND 100000),
  crit_fail_minutes  int CHECK (crit_fail_minutes BETWEEN 0 AND 1000000),
  warn_fail_pct      numeric(5,2) CHECK (warn_fail_pct BETWEEN 0 AND 100),
  crit_fail_pct      numeric(5,2) CHECK (crit_fail_pct BETWEEN 0 AND 100),
  min_runs           int CHECK (min_runs BETWEEN 1 AND 100000),
  dont_monitor       boolean,
  created_by         text NOT NULL,
  created_at         timestamptz NOT NULL,
  client             text,
  replaces           bigint,
  ended_by           text,
  ended_at           timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS collection_health_threshold_live
  ON pgvigil.collection_health_threshold (coalesce(instance_id, 0), coalesce(collection, '')) WHERE ended_at IS NULL;

-- import_collection_health_threshold(at, p): p = {op: set | inherit, ui_user, client, instance_id (none = every
-- instance), collection (none = every collection), and for a set the columns it gives}; answers {outcome: done |
-- refused, detail, threshold_id}. A set of no column, a value out of its range, an unknown or inactive instance, an
-- inherit of a scope with no row of its own: refused in words, nothing written.
-- collection_dont_monitor (B6g-2, the lead's 07:4x DONT-MONITOR (a)): whether a collection of an instance is set Don't
-- monitor - resolved as collection_health()'s th CTE resolves it (this instance and collection, this instance, this
-- collection on every instance, everything, then false: keep the two in step). 0121's 'collection failing' arm and the
-- overview's check of the same name leave such a collection out; 0121 holds a stub of it for its view's sake
CREATE OR REPLACE FUNCTION pgvigil.collection_dont_monitor(p_instance_id int, p_collection text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT coalesce(ic.dont_monitor, ia.dont_monitor, ac.dont_monitor, aa.dont_monitor, false)
    FROM (SELECT 1) one
    LEFT JOIN pgvigil.collection_health_threshold ic ON ic.ended_at IS NULL AND ic.instance_id = p_instance_id AND ic.collection = p_collection
    LEFT JOIN pgvigil.collection_health_threshold ia ON ia.ended_at IS NULL AND ia.instance_id = p_instance_id AND ia.collection IS NULL
    LEFT JOIN pgvigil.collection_health_threshold ac ON ac.ended_at IS NULL AND ac.instance_id IS NULL AND ac.collection = p_collection
    LEFT JOIN pgvigil.collection_health_threshold aa ON aa.ended_at IS NULL AND aa.instance_id IS NULL AND aa.collection IS NULL
$$;

CREATE OR REPLACE FUNCTION pgvigil.import_collection_health_threshold(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op    text := p_payload->>'op';
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_inst  int;
  v_name  text;
  v_coll  text := nullif(btrim(coalesce(p_payload->>'collection', '')), '');
  v_why   text;
  v_old   bigint;
  v_new   bigint;
  v_given int := 0;
  v_lo    int;
  v_hi    int;
  k       text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_collection_health_threshold: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'instance_id', '') <> '' THEN
    IF p_payload->>'instance_id' !~ '^[0-9]{1,9}$' THEN
      v_why := 'instance_id must be an instance''s number, or none for every instance';
    ELSE
      v_inst := (p_payload->>'instance_id')::int;
      -- an inherit ends an inactive instance's own row too (the review of B6g-2 #14: else it comes back in force when
      -- the instance does); a set needs an active one
      SELECT i.name INTO v_name FROM pgvigil.instances i WHERE i.instance_id = v_inst AND (i.is_active OR v_op = 'inherit');
      IF v_name IS NULL THEN v_why := format(CASE WHEN v_op = 'inherit' THEN 'no instance %s' ELSE 'no active instance %s' END, v_inst); END IF;
    END IF;
  END IF;
  IF v_why IS NULL AND (v_op IS NULL OR v_op NOT IN ('set', 'inherit')) THEN
    v_why := 'op must be set or inherit';
  ELSIF v_why IS NULL AND v_coll IS NOT NULL AND length(v_coll) > 100 THEN
    v_why := 'a collection''s name is 100 characters at most';
  ELSIF v_why IS NULL AND v_op = 'set' THEN
    FOREACH k IN ARRAY ARRAY['warn_fails_in_row', 'crit_fails_in_row', 'warn_fail_minutes', 'crit_fail_minutes', 'min_runs'] LOOP
      IF p_payload ? k AND jsonb_typeof(p_payload->k) <> 'null' THEN
        v_given := v_given + 1;
        -- DBA Dash's ranges (the dialog's NumericUpDown): 1 to 100000 in a row and runs, 0 to 1000000 minutes (the review
        -- of B6g-2 #4: 1000000 passed the dialog and was refused in words that called it valid)
        -- the bounds first: an IF's condition ends at its first THEN, a CASE's too (vis-b6g0166: 4e4a4fe4's CASE inside
        -- the condition made 0166 fail to apply, 'syntax error at end of input')
        v_lo := CASE WHEN k LIKE '%minutes' THEN 0 ELSE 1 END;
        v_hi := CASE WHEN k LIKE '%minutes' THEN 1000000 ELSE 100000 END;
        IF (p_payload->>k) !~ '^[0-9]{1,7}$' OR (p_payload->>k)::int < v_lo OR (p_payload->>k)::int > v_hi THEN
          v_why := format('%s must be a whole number from %s to %s, or null to inherit', k, v_lo, v_hi);
          EXIT;
        END IF;
      END IF;
    END LOOP;
    IF v_why IS NULL THEN
      FOREACH k IN ARRAY ARRAY['warn_fail_pct', 'crit_fail_pct'] LOOP
        IF p_payload ? k AND jsonb_typeof(p_payload->k) <> 'null' THEN
          v_given := v_given + 1;
          IF (p_payload->>k) !~ '^[0-9]{1,3}(\.[0-9]{1,2})?$' OR (p_payload->>k)::numeric > 100 THEN
            v_why := format('%s must be a percentage from 0 to 100, or null to inherit', k);
            EXIT;
          END IF;
        END IF;
      END LOOP;
    END IF;
    IF v_why IS NULL AND p_payload ? 'dont_monitor' AND jsonb_typeof(p_payload->'dont_monitor') <> 'null' THEN
      IF jsonb_typeof(p_payload->'dont_monitor') <> 'boolean' THEN v_why := 'dont_monitor must be true, false or null';
      ELSE v_given := v_given + 1; END IF;
    END IF;
    IF v_why IS NULL AND v_given = 0 THEN
      v_why := 'no threshold is set: to take the level above, inherit';
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.collection_health_threshold'), hashtext(coalesce(v_inst, 0) || '|' || coalesce(v_coll, '')));
  SELECT t.threshold_id INTO v_old FROM pgvigil.collection_health_threshold t
   WHERE t.ended_at IS NULL AND coalesce(t.instance_id, 0) = coalesce(v_inst, 0) AND coalesce(t.collection, '') = coalesce(v_coll, '');
  IF v_op = 'inherit' AND v_old IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'this scope has no threshold of its own: it inherits already');
  END IF;
  UPDATE pgvigil.collection_health_threshold SET ended_by = v_user, ended_at = p_at WHERE threshold_id = v_old;
  IF v_op = 'inherit' THEN
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'ended: the level above applies', 'threshold_id', v_old);
  END IF;
  INSERT INTO pgvigil.collection_health_threshold (instance_id, instance_name, collection, warn_fails_in_row, warn_fail_minutes, crit_fails_in_row,
         crit_fail_minutes, warn_fail_pct, crit_fail_pct, min_runs, dont_monitor, created_by, created_at, client, replaces)
  VALUES (v_inst, v_name, v_coll, (p_payload->>'warn_fails_in_row')::int, (p_payload->>'warn_fail_minutes')::int, (p_payload->>'crit_fails_in_row')::int,
          (p_payload->>'crit_fail_minutes')::int, (p_payload->>'warn_fail_pct')::numeric, (p_payload->>'crit_fail_pct')::numeric,
          (p_payload->>'min_runs')::int, (p_payload->>'dont_monitor')::boolean, v_user, p_at, nullif(p_payload->>'client', ''), v_old)
  RETURNING threshold_id INTO v_new;
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'set', 'threshold_id', v_new);
END $$;

-- its result grew (B6g-1): CREATE OR REPLACE cannot change a result's columns, so an earlier form is dropped first
-- (nothing depends on it: collection_health_summary's body is text, the page reads it by name)
DROP FUNCTION IF EXISTS pgvigil.collection_health(timestamptz, jsonb, timestamptz, int[], text);
CREATE OR REPLACE FUNCTION pgvigil.collection_health(p_rate_from timestamptz, p_expected jsonb DEFAULT NULL, p_rate_to timestamptz DEFAULT NULL,
                                                     p_instances int[] DEFAULT NULL, p_collection text DEFAULT NULL)
RETURNS TABLE (instance_id int, collection text, status text, status_reason text, failing_minutes int, consecutive_failures int,
               runs int, ok int, partial int, failed int, skipped int, failed_pct numeric, problem_pct numeric,
               last_run_at timestamptz, last_ok_at timestamptz, last_failure_at timestamptz, last_partial_at timestamptz,
               dur_sum numeric, dur_max int, rows_written numeric,
               -- B6g-1: Failed holds import_failed; the CPU and reads are NULL where no run of the range read its
               -- session (PostgreSQL: 'not read by pgvigil'), never 0
               import_failed int, import_runs int, import_sum numeric, import_max int,
               cpu_runs int, cpu_sum numeric, cpu_max int, reads_sum numeric,
               -- B6g-2: where the row's thresholds come from (NULL = DBA Dash's defaults alone) and the numbers in words
               threshold_from text, threshold_words text)
LANGUAGE sql STABLE SET jit = off AS $$
  WITH h AS (
    SELECT h.instance_id, h.collection, sum(h.runs)::int AS runs, sum(h.ok)::int AS ok, sum(h.partial)::int AS partial,
           sum(h.failed)::int AS failed, sum(h.skipped)::int AS skipped,
           sum(h.dur_ms_sum) AS dur_sum, max(h.dur_ms_max) AS dur_max, sum(h.rows_written) AS rows_written,
           sum(h.import_failed)::int AS import_failed, sum(h.import_runs)::int AS import_runs,
           sum(h.import_ms_sum) AS import_sum, max(h.import_ms_max) AS import_max, sum(h.cpu_runs)::int AS cpu_runs,
           sum(h.cpu_ms_sum) FILTER (WHERE h.cpu_runs > 0) AS cpu_sum, max(h.cpu_ms_max) FILTER (WHERE h.cpu_runs > 0) AS cpu_max,
           sum(h.reads_sum) FILTER (WHERE h.cpu_runs > 0) AS reads_sum
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
           h.dur_sum, h.dur_max, h.rows_written,
           coalesce(h.import_failed, 0) AS import_failed, coalesce(h.import_runs, 0) AS import_runs, h.import_sum, h.import_max,
           coalesce(h.cpu_runs, 0) AS cpu_runs, h.cpu_sum, h.cpu_max, h.reads_sum
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
  ), live AS MATERIALIZED (
    -- B6g-2: the thresholds in force, read once and joined four times (the review of B6g-2 #6: the history table's
    -- rows, ended ones too, under four joins per instance and collection)
    SELECT * FROM pgvigil.collection_health_threshold WHERE ended_at IS NULL
  ), th AS (
    -- B6g-2: each threshold resolved on its own - this instance and collection, this instance's row for every
    -- collection, this collection's row for every instance, the row for everything, then DBA Dash's defaults
    -- (CollectionHealthStatus.sql's order); pgvigil.collection_dont_monitor resolves dm the same way: keep in step
    SELECT j.*,
           coalesce(ic.warn_fails_in_row, ia.warn_fails_in_row, ac.warn_fails_in_row, aa.warn_fails_in_row, 1) AS wfr,
           coalesce(ic.warn_fail_minutes, ia.warn_fail_minutes, ac.warn_fail_minutes, aa.warn_fail_minutes, 10) AS wfm,
           coalesce(ic.crit_fails_in_row, ia.crit_fails_in_row, ac.crit_fails_in_row, aa.crit_fails_in_row, 3) AS cfr,
           coalesce(ic.crit_fail_minutes, ia.crit_fail_minutes, ac.crit_fail_minutes, aa.crit_fail_minutes, 30) AS cfm,
           coalesce(ic.warn_fail_pct, ia.warn_fail_pct, ac.warn_fail_pct, aa.warn_fail_pct, 10) AS wpct,
           coalesce(ic.crit_fail_pct, ia.crit_fail_pct, ac.crit_fail_pct, aa.crit_fail_pct, 50) AS cpct,
           coalesce(ic.min_runs, ia.min_runs, ac.min_runs, aa.min_runs, 5) AS mr,
           coalesce(ic.dont_monitor, ia.dont_monitor, ac.dont_monitor, aa.dont_monitor, false) AS dm,
           nullif(concat_ws(', ', CASE WHEN ic.threshold_id IS NOT NULL THEN 'this instance and collection' END,
                            CASE WHEN ia.threshold_id IS NOT NULL THEN 'this instance' END,
                            CASE WHEN ac.threshold_id IS NOT NULL THEN 'this collection on every instance' END,
                            CASE WHEN aa.threshold_id IS NOT NULL THEN 'everything' END), '') AS th_from
      FROM j
      LEFT JOIN live ic ON ic.instance_id = j.instance_id AND ic.collection = j.collection
      LEFT JOIN live ia ON ia.instance_id = j.instance_id AND ia.collection IS NULL
      LEFT JOIN live ac ON ac.instance_id IS NULL AND ac.collection = j.collection
      LEFT JOIN live aa ON aa.instance_id IS NULL AND aa.collection IS NULL
     WHERE j.in_range OR j.last_run_at >= now() - make_interval(secs => greatest(3 * j.iv, 86400))
  ), t AS (
    -- the rate as DBA Dash judges it (CollectionHealthStatus.sql L94-98): only with a failure to count, so a 0 %
    -- threshold means any failure, never every run (the review of B6g-2 #1); the per cent to two places as its
    -- DECIMAL(5,2) (#9)
    SELECT th.*,
           format('in a row %s / %s, failing %s / %s min, failed %s / %s %% of %s runs or more', th.wfr, th.cfr, th.wfm, th.cfm,
                  trim_scale(th.wpct), trim_scale(th.cpct), th.mr) AS th_words,
           CASE WHEN th.cf >= th.cfr AND (th.fm IS NULL OR th.fm >= th.cfm) THEN 2
                WHEN th.cf >= th.wfr AND (th.fm IS NULL OR th.fm >= th.wfm) THEN 1 ELSE 0 END AS st,
           CASE WHEN th.known >= th.mr AND th.failed > 0 AND round(100.0 * th.failed / th.known, 2) >= th.cpct AND th.last_status = 'error' THEN 2
                WHEN th.known >= th.mr AND th.failed + th.partial > 0 AND round(100.0 * (th.failed + th.partial) / th.known, 2) >= th.wpct THEN 1 ELSE 0 END AS rt,
           th.iv = 0 OR th.dm OR (th.known = 0 AND th.cf = 0) AS na
      FROM th
  )
  SELECT t.instance_id, t.collection,
         CASE WHEN t.na THEN 'n/a' WHEN greatest(t.st, t.rt) = 2 THEN 'critical' WHEN greatest(t.st, t.rt) = 1 THEN 'warning' ELSE 'ok' END,
         CASE WHEN t.iv = 0 THEN 'collection off'
              WHEN t.dm THEN 'not monitored (its Collection Health threshold)'
              WHEN t.na THEN 'no runs (skipped only)'
              WHEN t.st > 0 AND t.st >= t.rt
                THEN t.cf || ' failure(s) in a row' || CASE WHEN t.fm IS NULL THEN ', never succeeded' ELSE ', failing ' || t.fm || ' min' END
              WHEN t.rt > 0
                THEN trim_scale(round(100.0 * t.failed / t.known, 1)) || ' % failed, ' || trim_scale(round(100.0 * t.partial / t.known, 1)) || ' % partial of ' || t.known || ' runs'   -- one place, as DBA Dash's DECIMAL(5,1) (part a #6: 1 of 300 read '0 %')
              ELSE '' END,
         t.fm, t.cf, t.runs, t.ok, t.partial, t.failed, t.skipped,
         CASE WHEN t.known > 0 THEN round(100.0 * t.failed / t.known, 1) END,
         CASE WHEN t.known > 0 THEN round(100.0 * (t.failed + t.partial) / t.known, 1) END,
         t.last_run_at, t.last_ok_at, t.last_failure_at, t.last_partial_at, t.dur_sum, t.dur_max, t.rows_written,
         t.import_failed, t.import_runs, t.import_sum, t.import_max, t.cpu_runs, t.cpu_sum, t.cpu_max, t.reads_sum,
         t.th_from, t.th_words
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
-- now and the level its open alert was sent at - are HELD for the collections that run long on its host (alert_due's
-- term, 0190 WIRING, through collection_runs_long_held); one above it is sent on its own, and a new one waits while 3
-- or more of the host's instances turned long within its span and a minute (collection_runs_long_forming). Its alert is
-- not resolved while the host's own 'collector or network' stands (alert_due). An arm of 0190's pgvigil.findings
-- (WIRING). What is judged (B6f7, the review of the fold; the lead's 07:1x / 07:2x / 07:5x calls; B6f10): the host's
-- runs not retired, and the host only while a run of it beat within its span + 3 minutes (a stopped, retired or renamed
-- host folds nothing from its old rows); never an instance a 'collector or network' holds now (collector_held_instances,
-- as collector_connects: a cut slows the runs it does not fail); and no NEW fold for a host whose 'collector or network'
-- stood inside the window - its alert open there on a configured channel, or held unsent by a mute (ack_suppressed; a
-- silence or blackout names an instance and never holds it) - the cut's rows stay in the two hours, so the host is
-- judged again once the window has passed its parent (a mute's hold seen up to 10 minutes before the window counts, and
-- a sent alert cleared that long before it, less its channel's clear_after: B6f11 #5, B6f12 #4). A host whose fold's
-- alert is not cleared keeps being judged - its finding present, or missing no more than 5 minutes before a parent of
-- the host inside the window was sent, or later (B6f10 #1, B6f11 #2, B6f12 #1: the sender stamps the miss with its
-- pass's time and the parent's send after it) - the held instances still left out; the fold then comes back at more
-- than half (its lower bar reads a present finding: an alert standing at half or less is gone after one missing pass,
-- B6f11 #1). A parent the alert sender never saw (no
-- channel configured, quiet hours over the whole of it, every send failing, its channel removed and no mute) is not seen
-- here: its rows are judged once it clears (docs/alerts.md).
CREATE OR REPLACE FUNCTION pgvigil.collection_runs_long_open(p_host text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pgvigil.alert_state s JOIN pgvigil.alert_channels c ON c.name = s.channel AND c.is_configured
                  WHERE s.cleared_at IS NULL AND s.missing_since IS NULL AND s.source = 'pgvigil repository'
                    AND s.setting = 'collections run long' AND s.value = p_host)
$$;

-- collection_runs_long_rows: per host, instance and collection, the window's runs on the host's own rows (5 or more),
-- of the runs and hosts the fold judges (above)
CREATE OR REPLACE VIEW pgvigil.collection_runs_long_rows AS
WITH w AS (
  SELECT date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - interval '1 hour' AS start
), stood AS MATERIALIZED (   -- the hosts whose 'collector or network' stood inside the window, each with the time the
                             -- sender has for it: sent on a configured channel (since = its first send), or held
                             -- unsent by a mute (ack_suppressed, the lead's 07:5x; since = that mute's FIRST hold of
                             -- this host's parent, however long ago - first_at never moves, B6f12 #2). A cut ending
                             -- just before an hour's edge leaves its last slowed run in the next hour, so the parent
                             -- counts for 10 minutes past its end: a hold seen up to 10 minutes before the window
                             -- (B6f11 #5), a sent alert cleared up to 10 minutes before it less the channel's own
                             -- clear_after, which its cleared_at already trails by (B6f12 #4). Read once, not per
                             -- heartbeat row (B6f10 #3)
  SELECT s.value AS host, s.first_sent_at AS since
    FROM pgvigil.alert_state s JOIN pgvigil.alert_channels c ON c.name = s.channel AND c.is_configured
   CROSS JOIN w
   WHERE s.source = 'pgvigil repository' AND s.setting = 'collector or network'
     AND (s.cleared_at IS NULL OR s.cleared_at >= w.start - make_interval(secs => greatest(600 - c.clear_after_secs, 0)))
  UNION
  SELECT x.value, x.first_at FROM pgvigil.ack_suppressed x CROSS JOIN w
   WHERE x.source = 'pgvigil repository' AND x.setting = 'collector or network' AND x.last_at >= w.start - interval '10 minutes'
), kept AS MATERIALIZED (    -- the hosts whose fold's alert is not cleared on a configured channel - its finding present,
                             -- or missing since a parent of the host rose (B6f10 #1: a fold that drops under a cut is
                             -- still judged; the hysteresis's collection_runs_long_open reads a present one); a fold
                             -- already found gone BEFORE the parent keeps nothing: the cut's rows do not revive it
                             -- (B6f11 #2). 'Since it rose' is read with 5 minutes' room (B6f12 #1): the pass that
                             -- first sees the parent stamps the fold's miss with its own time and records the
                             -- parent's send after it, and 'collector not seen' rises up to a minute after its host
                             -- stops being judged (a 1-minute span; at a longer span not after it). The price: an
                             -- alert that had truly ended inside those 5 minutes is kept too (B6f13 #3: the two
                             -- cannot be told apart). Any parent of the host inside the window answers (B6f12 #3)
  SELECT f.value AS host FROM pgvigil.alert_state f JOIN pgvigil.alert_channels k ON k.name = f.channel AND k.is_configured
   WHERE f.cleared_at IS NULL AND f.source = 'pgvigil repository' AND f.setting = 'collections run long'
     AND (f.missing_since IS NULL
          OR EXISTS (SELECT 1 FROM stood t WHERE t.host = f.value AND t.since <= f.missing_since + interval '5 minutes'))
), hb AS (    -- the host's runs not retired; the host beating; and no 'collector or network' of it inside the window,
              -- unless the host's fold's alert is not cleared: that fold keeps being judged (B6f9 #1, the lead's 07:5x
              -- (a); B6f10 #1), the instances a parent holds still left out below
  SELECT h.collector_id, h.host
    FROM pgvigil.collector_heartbeat h
   WHERE h.retired_at IS NULL
     AND EXISTS (SELECT 1 FROM pgvigil.collector_heartbeat n
                  WHERE n.host = h.host AND n.retired_at IS NULL
                    AND n.beat_at >= now() - pgvigil.collector_span(h.host) - interval '3 minutes')
     AND (NOT EXISTS (SELECT 1 FROM stood WHERE stood.host = h.host) OR EXISTS (SELECT 1 FROM kept WHERE kept.host = h.host))
)
SELECT hb.host, h.instance_id, h.collection, sum(h.runs) AS runs, sum(h.runs_over_half) AS half,
       sum(h.runs_over_interval) AS over_i, max(greatest(h.last_ok_at, h.last_failure_at, h.last_partial_at)) AS at
  FROM pgvigil.collection_health_hour h
  JOIN hb ON hb.collector_id = h.collector_id
  JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
 WHERE h.hour >= (SELECT w.start FROM w)
   AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances x WHERE x.instance_id = h.instance_id)
 GROUP BY hb.host, h.instance_id, h.collection
HAVING sum(h.runs) >= 5;

-- collection_runs_long_judged: per host and judged instance - its level there (0 not long, 1 warning, 2 critical), its
-- highest share of runs over half (the slowest first in the fold's detail) and the collections that run long there
CREATE OR REPLACE VIEW pgvigil.collection_runs_long_judged AS
SELECT r.host, r.instance_id, max(r.at) AS at,
       max(CASE WHEN r.over_i * 20 > r.runs THEN 2 WHEN r.half * 20 > r.runs THEN 1 ELSE 0 END) AS level,
       max(r.half::numeric / r.runs) AS share,
       coalesce(array_agg(r.collection ORDER BY r.collection) FILTER (WHERE r.half * 20 > r.runs), '{}') AS long_collections
  FROM pgvigil.collection_runs_long_rows r
 GROUP BY r.host, r.instance_id;

-- collection_runs_long_since (B6f7 #2, the lead's 07:1x / 07:2x (a)): per host and judged instance running long there,
-- since when - stamped and unstamped by the beat's door for the beating run's host (import_collection_health): the
-- forming wait reads it (collection_runs_long_forming). A host's rows go once no run of it is left unretired.
CREATE TABLE IF NOT EXISTS pgvigil.collection_runs_long_since (
  host         text NOT NULL,
  instance_id  int NOT NULL REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  since        timestamptz NOT NULL,
  PRIMARY KEY (host, instance_id)
);

-- collection_runs_long_forming: the instances of a host whose fold may be forming - 3 or more of its judged instances
-- were stamped long within its span + 1 minute: a NEW 'collection runs long' of one of those waits (alert_due, 0190)
-- until its stamp is older (one beat: collector_slow_forming's place and bound), so a fold forming over two beats
-- sends no member first
CREATE OR REPLACE VIEW pgvigil.collection_runs_long_forming AS
SELECT x.instance_id
  FROM (SELECT s.instance_id, count(*) OVER (PARTITION BY s.host) AS n
          FROM pgvigil.collection_runs_long_since s
         WHERE s.since > now() - pgvigil.collector_span(s.host) - interval '1 minute') x
 WHERE x.n >= 3;

CREATE OR REPLACE VIEW pgvigil.collection_runs_long_fold AS
WITH m AS (   -- per host and judged instance (collection_runs_long_judged), read once
  SELECT * FROM pgvigil.collection_runs_long_judged
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
), mk AS (    -- the members, the slowest first (B6f7 #7: the detail names 3 and how many more)
  SELECT m.host, m.instance_id, m.long_collections, i.name,
         row_number() OVER (PARTITION BY m.host ORDER BY m.level DESC, m.share DESC, i.name) AS rn
    FROM m JOIN hf ON hf.host = m.host JOIN pgvigil.instances i ON i.instance_id = m.instance_id
   WHERE m.level >= 1
), fa AS (
  SELECT hf.host, greatest(hf.level, coalesce(max(sent.level), 0)) AS held_level,
         array_agg(mk.instance_id ORDER BY mk.instance_id) AS members,
         jsonb_object_agg(mk.instance_id::text, mk.long_collections) AS member_collections,
         string_agg(mk.name, ', ' ORDER BY mk.rn) FILTER (WHERE mk.rn <= 3) AS names
    FROM hf JOIN mk ON mk.host = hf.host
    LEFT JOIN sent ON sent.host = hf.host
   GROUP BY hf.host, hf.level
)
SELECT NULL::int AS instance_id, CASE WHEN hf.level = 2 THEN 'critical' ELSE 'warning' END AS severity,
       'collections run long'::text AS setting, hf.host AS value, NULL::boolean AS is_set,
       'what slows the collector host itself - its CPU, memory or disks (the Collector page''s load and run duration), or fewer instances on it'::text AS suggested,
       'all'::text AS platforms,
       format('collections run long on collector %s: %s of its %s judged instance(s) since %s UTC (%s at critical): %s%s - the collector''s own load, not the servers''; the members'' own ''collection runs long'' alerts are held while this stands, unless one is over this alert''s level',
              hf.host, hf.long_n, hf.judged,
              to_char((date_trunc('hour', now() AT TIME ZONE 'UTC') - interval '1 hour'), 'YYYY-MM-DD HH24:MI'), hf.crit_n, fa.names,
              CASE WHEN hf.long_n > 3 THEN format(' and %s more', hf.long_n - 3) ELSE '' END) AS detail,
       'pgvigil repository'::text AS source, hf.at AS at,
       fa.members, CASE WHEN fa.held_level = 2 THEN 'critical' ELSE 'warning' END AS held_severity, fa.member_collections
  FROM hf JOIN fa ON fa.host = hf.host;

-- collection_runs_long_held: per member of a standing fold and collection that runs long on the fold's host, the
-- severity at or under which its own 'collection runs long' of that collection is held (the highest over its folds: an
-- instance read by two hosts); alert_due (0190) reads it once a pass. By collection (B6f7 #6): a member's collection
-- long only on another host is not explained by this fold and is sent on its own.
CREATE OR REPLACE VIEW pgvigil.collection_runs_long_held AS
SELECT mc.key::int AS instance_id,
       CASE max(CASE f.held_severity WHEN 'critical' THEN 2 ELSE 1 END) WHEN 2 THEN 'critical' ELSE 'warning' END AS severity,
       c.collection
  FROM pgvigil.collection_runs_long_fold f
  CROSS JOIN LATERAL jsonb_each(f.member_collections) AS mc(key, value)
  CROSS JOIN LATERAL jsonb_array_elements_text(mc.value) AS c(collection)
 GROUP BY mc.key::int, c.collection;

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

-- ===== B6g-4 (N30 / N31, design L12 / L56; the lead's 07:4x SERIES (a)): the Metrics family 'collection' =====
-- The collection counters chartable and alertable, as DBA Dash's: per collection (the sub-series slot 'database' carries
-- the collection; the instance's series is the worst collection each hour: the B6g-4 fold, the lead's 14:5x (a) #6 - a
-- rule naming no collection watches that series, so its run may pass from one collection to another hour by hour, and
-- its alert names no collection - an alert that names its collection is a rule per collection (the lead's 15:3x (b));
-- a 'below' rule must name one, the worst being the highest), from the hour rows (one
-- point an hour, stamped at the hour's END so two points are exactly 60 minutes apart and an hourly collection's
-- 60-minute rule never turns on a few ms of ticker jitter: #2 - so a failure at 10:17 is 'beyond since 11:00', and a
-- page range under an hour may hold no point; every collector summed; fresh for 2 hours - a collection run less often
-- reads 'no data' between its points: #14): duration, CPU and logical reads (SQL Server's runs alone read their session, so those two are SQL
-- Server's rows - no rule on them judges a PostgreSQL instance: #13), import duration, and the failed per cent.
-- DBA Dash's Import CPU, Import Logical Reads and Import Lag are not read (the page says so).
-- metric_catalog keeps 0085's rows and every row another file adds there: its live definition is read and this
-- family's rows appended (a copy of 0085's list would drop the others'); a re-apply finds them and does nothing.
DO $do$
DECLARE d text := pg_get_viewdef('pgvigil.metric_catalog'::regclass, true);
BEGIN
  IF position('''collection''' IN d) = 0 THEN
    EXECUTE 'CREATE OR REPLACE VIEW pgvigil.metric_catalog AS ' || regexp_replace(d, ';\s*$', '') || $u$
UNION ALL
SELECT x.family || '.' || x.metric, x.engine, x.family, x.family_label, x.family_sort, x.metric, x.label, x.unit, x.per_database, x.fresh_secs, x.sort
  FROM (VALUES
    ('any', 'collection', 'Collection', 95, 'duration_ms',   'collection duration',        'ms',    true, 7200, 1),
    ('sqlserver', 'collection', 'Collection', 95, 'cpu_ms',        'collection CPU',           'ms',    true, 7200, 2),
    ('sqlserver', 'collection', 'Collection', 95, 'logical_reads', 'collection logical reads', 'count', true, 7200, 3),
    ('any', 'collection', 'Collection', 95, 'failed_pct',    'collection failed',          'pct',   true, 7200, 4),
    ('any', 'collection', 'Collection', 95, 'import_ms',     'collection import duration', 'ms',    true, 7200, 5)
  ) AS x(engine, family, family_label, family_sort, metric, label, unit, per_database, fresh_secs, sort)$u$;
  END IF;
END $do$;

-- metric_points: 0085's function is renamed once (metric_points_0085, a re-apply leaves it) and wrapped: the 'collection'
-- family read here, every other family as 0085 reads it. Only functions call metric_points (metric_grid,
-- alert_rule_eval: by name at run time), so none is left on the old one.
DO $do$ BEGIN
  IF to_regprocedure('pgvigil.metric_points_0085(integer,text,timestamp with time zone,timestamp with time zone,interval,text)') IS NULL THEN
    ALTER FUNCTION pgvigil.metric_points(int, text, timestamptz, timestamptz, interval, text) RENAME TO metric_points_0085;
  END IF;
END $do$;
CREATE OR REPLACE FUNCTION pgvigil.metric_points(p_instance_id int, p_family text, p_from timestamptz, p_to timestamptz,
                                                 p_lookback interval DEFAULT interval '15 minutes', p_database text DEFAULT NULL)
RETURNS TABLE (at timestamptz, metric text, value double precision)
LANGUAGE plpgsql STABLE SET jit = off AS $$
#variable_conflict use_column
BEGIN
  IF p_family = 'collection' THEN
    -- p_database: one collection's series; NULL = the instance's: each hour's worst collection, per metric (every
    -- metric of the family is worse higher). Each point stamped at its hour's end: an open hour has no point yet.
    RETURN QUERY
    WITH h AS (
      SELECT h.hour, h.collection,
             sum(h.dur_ms_sum) AS dur, sum(h.ok + h.partial + h.failed) AS ran, sum(h.failed) AS failed,
             sum(h.cpu_ms_sum) AS cpu, sum(h.cpu_runs) AS cpu_runs, sum(h.reads_sum) AS reads,
             sum(h.import_ms_sum) AS imp, sum(h.import_runs) AS imp_runs
        FROM pgvigil.collection_health_hour h
       WHERE h.instance_id = p_instance_id AND (p_database IS NULL OR h.collection = p_database)
         AND h.hour > p_from - interval '1 hour' AND h.hour <= p_to - interval '1 hour'
       GROUP BY h.hour, h.collection
    )
    SELECT h.hour + interval '1 hour', v.metric, max(v.value)
      FROM h CROSS JOIN LATERAL (VALUES
        ('duration_ms', (h.dur::numeric / nullif(h.ran, 0))::double precision),
        ('cpu_ms', (h.cpu::numeric / nullif(h.cpu_runs, 0))::double precision),
        ('logical_reads', (h.reads::numeric / nullif(h.cpu_runs, 0))::double precision),
        ('import_ms', (h.imp::numeric / nullif(h.imp_runs, 0))::double precision),
        ('failed_pct', (100.0 * h.failed / nullif(h.ran, 0))::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL
     GROUP BY h.hour, v.metric;
  ELSE
    RETURN QUERY SELECT x.at, x.metric, x.value FROM pgvigil.metric_points_0085(p_instance_id, p_family, p_from, p_to, p_lookback, p_database) x;
  END IF;
END $$;

-- The Collection family's 60-minute floor in the store too (the B6g-4 fold #8): RulePayload refuses a shorter window in
-- words; a call of import_alert_rule past the API meets this check, which the function's own 'refused by the store'
-- path turns into a refused row of alert_rule_log. NOT VALID: no stored row is judged (no release carried the family).
-- And a 'below' rule on the family names its collection (the review of the fold #4): with none it would read the
-- worst - the highest - collection, so 'below' would mean every collection below.
DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'alert_rules_collection_window' AND conrelid = 'pgvigil.alert_rules'::regclass) THEN
    ALTER TABLE pgvigil.alert_rules ADD CONSTRAINT alert_rules_collection_window
      CHECK (metric NOT LIKE 'collection.%' OR for_minutes >= 60) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'alert_rules_collection_below' AND conrelid = 'pgvigil.alert_rules'::regclass) THEN
    ALTER TABLE pgvigil.alert_rules ADD CONSTRAINT alert_rules_collection_below
      CHECK (metric NOT LIKE 'collection.%' OR op = 'above' OR database IS NOT NULL) NOT VALID;
  END IF;
END $do$;
