-- 0150: the PostgreSQL replication trends and the fleet's cluster checks (task 375; the pass 20261114-150708 folded by
-- the lead 17:3x): the hourly min / mean / max of replication_sample kept 730 days, its series read switched to the
-- hours past 2 days, the role band under the charts, and the checks a single server cannot make - two primaries, a
-- cluster without one, a cascaded standby's upstream, standby queries cancelled by recovery conflicts. Read from rows
-- the collectors already store; nothing is created, changed or switched on on a monitored server.
--
--   the hours          replication_hourly: per instance, kind, key and UTC hour the reads of the hour and the min / max /
--                      sum / count of lag_bytes and lag_secs (a chart's mean = sum / count), the reads with active set;
--                      for the counter kinds the hour's RISE per counter. Rolled: link senders (keys 'app:' and 'slot:'
--                      since 0141, a logical subscription's walsender 'slot:'; a base backup's, pg_rewind's and every
--                      pid-keyed sender are not), the receiver, slots, Aurora replicas (lag); 'conflict' (the six confl_*
--                      counters, only from reads taken in recovery and only hours with a rise: no row = 0) and
--                      'slot_stats' (the spill / stream / total counters). Not rolled: standby, sync, subscription,
--                      publication (state rows, kept by their own state tables)
--   a counter's rise   every pair of consecutive samples of one object whose later sample is in the hour; a drop is a
--                      reset and the later value is the rise (a restart, pg_stat_reset, a slot's stats_reset); a pair
--                      more than 10 minutes long (a collector gap) is left out of the rise and kept in gap_rise; a pair
--                      longer than a day is not seen. The hour's recompute reads up to 15 minutes before it, then the
--                      newest sample within a day
--   filled             by statement-level AFTER INSERT and AFTER DELETE triggers with transition tables on
--                      replication_sample, so every writer counts: import_replication (0006 / 0141), the seed of
--                      scripts/proof-darling-alerts.sh (its INSERT and its DELETE), any later writer. Each call
--                      RECOMPUTES the instance-hours its rows touch, and the hour after each (a counter pair's later
--                      sample), from the stored samples: a late or repeated row is never counted twice. The trigger
--                      recomputes ONLY those hours: it takes the instance's advisory lock with pg_try_advisory_xact_lock
--                      and, when a heal or a build holds it, merges the hours into the instance's 'mark' range and
--                      returns at once (the import never waits); after its hours it heals a 'mark' range of a day or
--                      less under the budget (pgvigil.replication_heal_ms, 2000 ms), one UTC hour a chunk, each chunk's
--                      cost estimated before it from its own samples at the rate of the chunks before
--   the first build    none in this file (no migration writes a stored row): 'pgvigil purge' builds each instance
--                      (replication_hourly_pending; replication_hourly_months in its own transaction first - a partition
--                      made inside the build would lock the table for every other instance's rollup until the build
--                      commits; then replication_hourly_heal_one), one instance per transaction, newest
--                      hours first, in chunks sized by a row estimate; the imports go on meanwhile (the lock is tried,
--                      never waited for). Until an instance is built its series reads the samples
--   a failure          never fails the import: the trigger catches any error, merges the hours into the 'mark' range
--                      and writes a 'rollup failed' row in collection_log (collection 'replication_hourly', status
--                      'error') at most once an hour; the heal of a logged range writes 'rollup healed' ('ok')
--   retention          pgvigil.hours_retention's row 'replication_hourly', 730 days (the table byte-identical to 0139's,
--                      created here when 0139 is not in the tree); replication_hourly_purge drops the months wholly older
--                      and returns their names for purge()'s last block (the lead's wiring)
--   the series         replication_series(instance, from, to, step, metric): the samples when the range is 2 days or
--                      less AND the stored samples reach back to its start, else the hours for the WHOLE range (raw
--                      for the hours not built: an unbuilt instance, a dirty range; 'building' says so); the hours path
--                      starts at the UTC hour of p_from (its first point may hold up to 59 minutes before p_from); the
--                      max per bucket (a spike survives the switch); metric 'lag' or 'conflicts' (the rise)
--
-- Locks: CREATE TRIGGER takes SHARE ROW EXCLUSIVE on replication_sample, and the ALTER TABLE of pg_repl_standby_state
-- ACCESS EXCLUSIVE on that table (one row per instance), until this file commits (the replication collection's writes
-- wait the few milliseconds the file takes; nothing here scans the samples). lock_timeout bounds it.
-- Partition parents for purge(): replication_hourly, dropped by replication_hourly_purge, not purge()'s list.
SET LOCAL lock_timeout = '20s';

CREATE TABLE IF NOT EXISTS pgvigil.replication_hourly (
  instance_id    int NOT NULL,
  kind           text NOT NULL,              -- sender | receiver | slot | aurora_replica | conflict | slot_stats
  key            text NOT NULL,              -- the object's key in replication_sample
  snapshot_at    timestamptz NOT NULL,       -- the UTC hour
  samples        int NOT NULL,               -- lag kinds: the reads of the hour; counter kinds: the pairs ending in it
  lag_bytes_min  bigint,
  lag_bytes_max  bigint,
  lag_bytes_sum  numeric,
  lag_bytes_n    int,
  lag_secs_min   double precision,
  lag_secs_max   double precision,
  lag_secs_sum   double precision,
  lag_secs_n     int,
  active_reads   int,
  rise           jsonb,                      -- counter kinds: {counter: the hour's rise} over pairs of 10 minutes or less
  gap_rise       jsonb,                      -- counter kinds: the rise of the longer pairs (a collector gap)
  PRIMARY KEY (instance_id, kind, key, snapshot_at)
) PARTITION BY RANGE (snapshot_at);

-- this month's and next month's partitions made here, so no import's rollup makes one: making a partition locks the
-- whole table until the import that made it commits (review A #1); purge makes each next month ahead after this
DO $$
BEGIN
  PERFORM pgvigil.ensure_month_partition('replication_hourly', now());
  PERFORM pgvigil.ensure_month_partition('replication_hourly', (date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month') AT TIME ZONE 'UTC');
END $$;

-- the hours not (re)built yet: 'build' = an instance's first build, its range shrunk from the newest end as chunks are
-- done; 'mark' = hours a locked or failed trigger call could not write, merged into one range
CREATE TABLE IF NOT EXISTS pgvigil.replication_hourly_dirty (
  instance_id  int NOT NULL REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  source       text NOT NULL CHECK (source IN ('build', 'mark')),
  from_at      timestamptz NOT NULL,
  to_at        timestamptz NOT NULL,
  noted_at     timestamptz NOT NULL DEFAULT now(),
  logged_at    timestamptz,             -- the last 'rollup failed' row written for this range (one an hour at most)
  why          text,
  PRIMARY KEY (instance_id, source)
);

-- the instances whose first build was queued; one with samples and no row is queued by the next purge
CREATE TABLE IF NOT EXISTS pgvigil.replication_hourly_first_build (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  queued_at    timestamptz NOT NULL DEFAULT now()
);

-- how long each hours table keeps its rows (days); a table with no row keeps its default
CREATE TABLE IF NOT EXISTS pgvigil.hours_retention (
  table_name  text PRIMARY KEY,
  days        int NOT NULL CHECK (days >= 1),
  changed_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO pgvigil.hours_retention (table_name, days) VALUES ('replication_hourly', 730) ON CONFLICT (table_name) DO NOTHING;

-- the counters of a counter kind (replication.go's conflicts read, slots.go's slot_stats read)
CREATE OR REPLACE FUNCTION pgvigil.replication_counters(p_kind text)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_kind
           WHEN 'conflict'   THEN ARRAY['confl_tablespace', 'confl_lock', 'confl_snapshot', 'confl_bufferpin', 'confl_deadlock', 'confl_active_logicalslot']
           WHEN 'slot_stats' THEN ARRAY['spill_txns', 'spill_count', 'spill_bytes', 'stream_txns', 'stream_count', 'stream_bytes', 'total_txns', 'total_bytes']
         END
$$;

-- replication_rises: the counter rises of one instance's pairs whose later sample lies in [p_from, p_to) - one row per
-- pair and counter (a 'conflict' pair only when its later read was taken in recovery: the read's 'standby' row); short =
-- the pair is 10 minutes or less. The earlier sample: the one before in the 15 minutes before p_from, else the newest
-- within a day before the later one.
CREATE OR REPLACE FUNCTION pgvigil.replication_rises(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (kind text, key text, snapshot_at timestamptz, counter text, rise numeric, short boolean)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT c.kind, c.key, c.snapshot_at, c.detail, lag(c.snapshot_at) OVER w AS p_at, lag(c.detail) OVER w AS p_detail
      FROM pgvigil.replication_sample c
     WHERE c.instance_id = p_instance_id AND c.kind IN ('conflict', 'slot_stats')
       AND c.snapshot_at >= p_from - interval '15 minutes' AND c.snapshot_at < p_to
    WINDOW w AS (PARTITION BY c.kind, c.key ORDER BY c.snapshot_at)),
  p AS (
    SELECT s.kind, s.key, s.snapshot_at, s.detail, coalesce(s.p_at, b.snapshot_at) AS p_at, coalesce(s.p_detail, b.detail) AS p_detail
      FROM s
      LEFT JOIN LATERAL (SELECT o.snapshot_at, o.detail FROM pgvigil.replication_sample o
                          WHERE s.p_at IS NULL AND o.instance_id = p_instance_id AND o.kind = s.kind AND o.key = s.key
                            AND o.snapshot_at < p_from - interval '15 minutes' AND o.snapshot_at >= s.snapshot_at - interval '1 day'
                          ORDER BY o.snapshot_at DESC LIMIT 1) b ON true
     WHERE s.snapshot_at >= p_from
       -- bounded to the range as well (review A #3: unbounded, the planner may hash every 'standby' sample of the
       -- instance - its whole history - on every import)
       AND (s.kind <> 'conflict' OR EXISTS (SELECT 1 FROM pgvigil.replication_sample r
                                             WHERE r.instance_id = p_instance_id AND r.snapshot_at = s.snapshot_at AND r.kind = 'standby'
                                               AND r.snapshot_at >= p_from AND r.snapshot_at < p_to)))
  SELECT p.kind, p.key, p.snapshot_at, c.counter,
         CASE WHEN (p.detail->>c.counter)::numeric >= (p.p_detail->>c.counter)::numeric
              THEN (p.detail->>c.counter)::numeric - (p.p_detail->>c.counter)::numeric
              ELSE (p.detail->>c.counter)::numeric END,
         p.snapshot_at - p.p_at <= interval '10 minutes'
    FROM p CROSS JOIN LATERAL unnest(pgvigil.replication_counters(p.kind)) c(counter)
   WHERE p.p_at IS NOT NULL AND p.detail->>c.counter IS NOT NULL AND p.p_detail->>c.counter IS NOT NULL
$$;

-- replication_hours: every UTC hour of one instance between p_from and p_to (widened to whole hours) recomputed from
-- the stored samples - the hours' rows upserted (a row whose values did not change is not rewritten) and the rows of
-- those hours the samples no longer give removed; a month's partition only where the month has samples. The caller
-- holds the instance's lock. Returns the hour rows the samples give.
CREATE OR REPLACE FUNCTION pgvigil.replication_hours(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_from timestamptz := date_trunc('hour', p_from AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_to   timestamptz := CASE WHEN date_trunc('hour', p_to AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' = p_to THEN p_to
                             ELSE (date_trunc('hour', p_to AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC' END;
  v_n    int;
BEGIN
  IF v_to <= v_from THEN RETURN 0; END IF;
  PERFORM pgvigil.ensure_month_partition('replication_hourly', m AT TIME ZONE 'UTC')
     FROM generate_series(date_trunc('month', v_from AT TIME ZONE 'UTC'), date_trunc('month', (v_to - interval '1 second') AT TIME ZONE 'UTC'), interval '1 month') m
    WHERE EXISTS (SELECT 1 FROM pgvigil.replication_sample s WHERE s.instance_id = p_instance_id
                     AND s.snapshot_at >= greatest(v_from, m AT TIME ZONE 'UTC') AND s.snapshot_at < least(v_to, (m + interval '1 month') AT TIME ZONE 'UTC'));
  WITH new AS MATERIALIZED (
    SELECT p_instance_id AS instance_id, s.kind, s.key, date_trunc('hour', s.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS snapshot_at,
           count(*)::int AS samples, min(s.lag_bytes) AS lag_bytes_min, max(s.lag_bytes) AS lag_bytes_max, sum(s.lag_bytes) AS lag_bytes_sum,
           count(s.lag_bytes)::int AS lag_bytes_n, min(s.lag_secs) AS lag_secs_min, max(s.lag_secs) AS lag_secs_max, sum(s.lag_secs) AS lag_secs_sum,
           count(s.lag_secs)::int AS lag_secs_n, (count(*) FILTER (WHERE s.active))::int AS active_reads, NULL::jsonb AS rise, NULL::jsonb AS gap_rise
      FROM pgvigil.replication_sample s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at >= v_from AND s.snapshot_at < v_to
       AND (s.kind IN ('receiver', 'slot', 'aurora_replica') OR (s.kind = 'sender' AND (s.key LIKE 'app:%' OR s.key LIKE 'slot:%')))
     GROUP BY s.kind, s.key, 4
    UNION ALL
    SELECT p_instance_id, y.kind, y.key, y.h, max(y.pairs)::int, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
           coalesce(jsonb_object_agg(y.counter, y.r) FILTER (WHERE y.r IS NOT NULL), '{}'::jsonb),
           jsonb_object_agg(y.counter, y.g) FILTER (WHERE y.g IS NOT NULL)
      FROM (SELECT x.kind, x.key, date_trunc('hour', x.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS h, x.counter,
                   sum(x.rise) FILTER (WHERE x.short) AS r, sum(x.rise) FILTER (WHERE NOT x.short) AS g,
                   count(DISTINCT x.snapshot_at) AS pairs
              FROM pgvigil.replication_rises(p_instance_id, v_from, v_to) x
             GROUP BY x.kind, x.key, 3, x.counter) y
     GROUP BY y.kind, y.key, y.h
    HAVING y.kind <> 'conflict' OR coalesce(sum(y.r), 0) > 0 OR coalesce(sum(y.g), 0) > 0),
  up AS (
    INSERT INTO pgvigil.replication_hourly AS h (instance_id, kind, key, snapshot_at, samples, lag_bytes_min, lag_bytes_max, lag_bytes_sum,
                                                 lag_bytes_n, lag_secs_min, lag_secs_max, lag_secs_sum, lag_secs_n, active_reads, rise, gap_rise)
    SELECT x.instance_id, x.kind, x.key, x.snapshot_at, x.samples, x.lag_bytes_min, x.lag_bytes_max, x.lag_bytes_sum, x.lag_bytes_n,
           x.lag_secs_min, x.lag_secs_max, x.lag_secs_sum, x.lag_secs_n, x.active_reads, x.rise, x.gap_rise
      FROM new x
    ON CONFLICT (instance_id, kind, key, snapshot_at) DO UPDATE
      SET samples = excluded.samples, lag_bytes_min = excluded.lag_bytes_min, lag_bytes_max = excluded.lag_bytes_max,
          lag_bytes_sum = excluded.lag_bytes_sum, lag_bytes_n = excluded.lag_bytes_n, lag_secs_min = excluded.lag_secs_min,
          lag_secs_max = excluded.lag_secs_max, lag_secs_sum = excluded.lag_secs_sum, lag_secs_n = excluded.lag_secs_n,
          active_reads = excluded.active_reads, rise = excluded.rise, gap_rise = excluded.gap_rise
      WHERE (h.samples, h.lag_bytes_min, h.lag_bytes_max, h.lag_bytes_sum, h.lag_bytes_n, h.lag_secs_min, h.lag_secs_max, h.lag_secs_sum,
             h.lag_secs_n, h.active_reads, h.rise, h.gap_rise)
            IS DISTINCT FROM
            (excluded.samples, excluded.lag_bytes_min, excluded.lag_bytes_max, excluded.lag_bytes_sum, excluded.lag_bytes_n, excluded.lag_secs_min,
             excluded.lag_secs_max, excluded.lag_secs_sum, excluded.lag_secs_n, excluded.active_reads, excluded.rise, excluded.gap_rise)
    RETURNING 1),
  gone AS (   -- the rows of these hours the samples no longer give (one snapshot: the upsert's rows are not seen here)
    DELETE FROM pgvigil.replication_hourly h
     WHERE h.instance_id = p_instance_id AND h.snapshot_at >= v_from AND h.snapshot_at < v_to
       AND NOT EXISTS (SELECT 1 FROM new x WHERE x.kind = h.kind AND x.key = h.key AND x.snapshot_at = h.snapshot_at)
    RETURNING 1)
  SELECT (SELECT count(*) FROM new) INTO v_n;
  RETURN v_n;
END $$;

-- replication_hourly_mark: hours merged into the instance's 'mark' range (no lock: the heal that later reads the range
-- removes it only as it read it)
CREATE OR REPLACE FUNCTION pgvigil.replication_hourly_mark(p_instance_id int, p_from timestamptz, p_to timestamptz, p_why text)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.replication_hourly_dirty AS d (instance_id, source, from_at, to_at, why)
  VALUES (p_instance_id, 'mark', p_from, p_to, p_why)
  ON CONFLICT (instance_id, source) DO UPDATE
    SET from_at = least(d.from_at, excluded.from_at), to_at = greatest(d.to_at, excluded.to_at), noted_at = now()
$$;

-- replication_hourly_failed: a trigger call that could not write its hours - merged into the 'mark' range, and a
-- 'rollup failed' row in collection_log when the range is new or its last such row is an hour old
CREATE OR REPLACE FUNCTION pgvigil.replication_hourly_failed(p_instance_id int, p_from timestamptz, p_to timestamptz, p_why text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_prev timestamptz; v_had boolean; v_log boolean;
BEGIN
  SELECT true, d.logged_at INTO v_had, v_prev FROM pgvigil.replication_hourly_dirty d WHERE d.instance_id = p_instance_id AND d.source = 'mark';
  v_log := v_had IS NULL OR v_prev IS NULL OR v_prev < now() - interval '1 hour';
  INSERT INTO pgvigil.replication_hourly_dirty AS d (instance_id, source, from_at, to_at, why, logged_at)
  VALUES (p_instance_id, 'mark', p_from, p_to, p_why, now())
  ON CONFLICT (instance_id, source) DO UPDATE
    SET from_at = least(d.from_at, excluded.from_at), to_at = greatest(d.to_at, excluded.to_at), noted_at = now(), why = excluded.why,
        logged_at = CASE WHEN v_log THEN now() ELSE d.logged_at END;
  IF v_log THEN
    INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
    VALUES (p_instance_id, 'replication_hourly', now(), 'error',
            format('rollup failed for the hours %s to %s (the samples are stored; the hours are rebuilt by the next import or purge): %s',
                   to_char(p_from AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), to_char(p_to AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), p_why));
  END IF;
END $$;

-- replication_hourly_heal: one instance's dirty ranges rebuilt, newest hours first; the caller holds the instance's
-- lock. p_build = also the 'build' range, and an instance with samples and no first build queued first (purge), in
-- chunks sized by a row estimate (about 200,000 samples a chunk, 1 to 168 hours, from the samples of the hour below the
-- chunk); else only a 'mark' range of a day or less (the trigger). 'build' first, 'mark' last and read only after the
-- build: a heal holds a row it deletes until its commit, and every import of the instance merges its hours into the
-- 'mark' row - deleted at a build's start it would hold each of them for the whole build (review A #2). With a budget
-- (p_budget_ms, the trigger) one UTC hour a chunk, its cost estimated before it from its own samples at the rate of the
-- chunks before (0.05 ms a sample until 1,000 are done); the first chunk always runs (an hour, never a day: review A
-- #4); the heal stops before a chunk that would pass the budget and keeps the rest of the range. A range done is
-- removed only as it was read (from, to and noted_at: a writer that merged hours into it meanwhile keeps it whole); one
-- that had a 'rollup failed' row gets a 'rollup healed' row. Returns the hour rows written.
CREATE OR REPLACE FUNCTION pgvigil.replication_hourly_heal(p_instance_id int, p_budget_ms int DEFAULT NULL, p_build boolean DEFAULT false)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v record; v_src text; v_n int := 0; v_t0 timestamptz := clock_timestamp(); v_lo timestamptz; v_hi timestamptz; v_cut timestamptz;
  v_rph numeric; v_hours int; v_rows numeric; v_c0 timestamptz; v_chunks int := 0; v_done_rows numeric := 0; v_done_ms numeric := 0;
BEGIN
  IF p_build AND NOT EXISTS (SELECT 1 FROM pgvigil.replication_hourly_first_build b WHERE b.instance_id = p_instance_id) THEN
    SELECT min(s.snapshot_at), max(s.snapshot_at) INTO v_lo, v_hi FROM pgvigil.replication_sample s WHERE s.instance_id = p_instance_id;
    IF v_lo IS NOT NULL THEN
      INSERT INTO pgvigil.replication_hourly_dirty AS d (instance_id, source, from_at, to_at, why)
      VALUES (p_instance_id, 'build', date_trunc('hour', v_lo AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',
              (date_trunc('hour', v_hi AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC', 'the first build')
      ON CONFLICT (instance_id, source) DO UPDATE SET from_at = least(d.from_at, excluded.from_at), to_at = greatest(d.to_at, excluded.to_at), noted_at = now();
    END IF;
    INSERT INTO pgvigil.replication_hourly_first_build (instance_id) VALUES (p_instance_id) ON CONFLICT (instance_id) DO NOTHING;
  END IF;
  FOREACH v_src IN ARRAY ARRAY['build', 'mark'] LOOP   -- each read at its turn: 'mark' after the build
    SELECT d.source, d.from_at, d.to_at, d.noted_at, d.logged_at INTO v FROM pgvigil.replication_hourly_dirty d
     WHERE d.instance_id = p_instance_id AND d.source = v_src
       AND (v_src = 'build' AND p_build OR v_src = 'mark' AND (p_build OR d.to_at - d.from_at <= interval '1 day'));
    CONTINUE WHEN NOT FOUND;
    v_lo := date_trunc('hour', v.from_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
    v_hi := v.to_at;
    WHILE v_hi > v_lo LOOP
      IF p_budget_ms IS NULL THEN
        SELECT count(*) INTO v_rph FROM pgvigil.replication_sample s
         WHERE s.instance_id = p_instance_id AND s.snapshot_at >= v_hi - interval '1 hour' AND s.snapshot_at < v_hi;
        v_hours := greatest(1, least(168, floor(200000 / greatest(v_rph, 1))))::int;
        v_cut := greatest(v_lo, v_hi - make_interval(hours => v_hours));
      ELSE
        v_cut := greatest(v_lo, date_trunc('hour', (v_hi - interval '1 microsecond') AT TIME ZONE 'UTC') AT TIME ZONE 'UTC');
        SELECT count(*) INTO v_rows FROM pgvigil.replication_sample s   -- the chunk's hour as replication_hours widens it
         WHERE s.instance_id = p_instance_id AND s.snapshot_at >= v_cut AND s.snapshot_at < v_cut + interval '1 hour';
        IF v_chunks > 0 AND extract(epoch FROM clock_timestamp() - v_t0) * 1000
                            + v_rows * (CASE WHEN v_done_rows >= 1000 THEN v_done_ms / v_done_rows ELSE 0.05 END) > p_budget_ms THEN   -- a bare CASE ... THEN would end plpgsql's IF condition
          UPDATE pgvigil.replication_hourly_dirty d SET to_at = v_hi, noted_at = now()
           WHERE d.instance_id = p_instance_id AND d.source = v.source AND d.from_at = v.from_at AND d.to_at = v.to_at AND d.noted_at = v.noted_at;
          RETURN v_n;
        END IF;
      END IF;
      v_c0 := clock_timestamp();
      v_n := v_n + pgvigil.replication_hours(p_instance_id, v_cut, v_hi);
      v_done_ms := v_done_ms + extract(epoch FROM clock_timestamp() - v_c0) * 1000;
      v_done_rows := v_done_rows + coalesce(v_rows, 0);
      v_chunks := v_chunks + 1;
      v_hi := v_cut;
    END LOOP;
    DELETE FROM pgvigil.replication_hourly_dirty d
     WHERE d.instance_id = p_instance_id AND d.source = v.source AND d.from_at = v.from_at AND d.to_at = v.to_at AND d.noted_at = v.noted_at;
    IF FOUND AND v.logged_at IS NOT NULL THEN
      INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
      VALUES (p_instance_id, 'replication_hourly', now(), 'ok',
              format('rollup healed: the hours %s to %s rebuilt', to_char(v.from_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'),
                     to_char(v.to_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"')));
    END IF;
  END LOOP;
  RETURN v_n;
END $$;

-- replication_hourly_pending: the instances 'pgvigil purge' heals - a dirty range, or samples and no first build queued
CREATE OR REPLACE FUNCTION pgvigil.replication_hourly_pending()
RETURNS SETOF int LANGUAGE sql STABLE AS $$
  SELECT d.instance_id FROM pgvigil.replication_hourly_dirty d
  UNION
  SELECT i.instance_id FROM pgvigil.instances i
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.replication_hourly_first_build b WHERE b.instance_id = i.instance_id)
     AND EXISTS (SELECT 1 FROM pgvigil.replication_sample s WHERE s.instance_id = i.instance_id)
   ORDER BY 1
$$;

-- replication_hourly_months: the month partitions of replication_hourly an instance's stored samples need, made - for
-- 'pgvigil purge' to call in its OWN transaction before replication_hourly_heal_one: making a partition locks the whole
-- table (ACCESS EXCLUSIVE), and inside a build's long transaction that lock would hold every other instance's rollup;
-- returns the partitions made
CREATE OR REPLACE FUNCTION pgvigil.replication_hourly_months(p_instance_id int)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_m timestamp; v_n int := 0;
BEGIN
  FOR v_m IN SELECT DISTINCT date_trunc('month', s.snapshot_at AT TIME ZONE 'UTC') FROM pgvigil.replication_sample s WHERE s.instance_id = p_instance_id LOOP
    IF to_regclass('pgvigil.replication_hourly_' || to_char(v_m, 'YYYYMM')) IS NULL THEN
      PERFORM pgvigil.ensure_month_partition('replication_hourly', v_m AT TIME ZONE 'UTC');
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;

-- replication_hourly_heal_one: one instance built or healed whole under its lock (no budget), for 'pgvigil purge' -
-- one call, one transaction; the instance's imports meanwhile mark their hours and go on. Returns the hour rows written.
CREATE OR REPLACE FUNCTION pgvigil.replication_hourly_heal_one(p_instance_id int)
RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.replication_hourly'), p_instance_id);
  RETURN pgvigil.replication_hourly_heal(p_instance_id, NULL, true);
END $$;

-- replication_hourly_touch: one instance's touched samples (p_lo to p_hi) - the lock TRIED, the hours recomputed and a
-- small 'mark' range healed under the budget; a held lock or any error leaves the hours in the 'mark' range
CREATE OR REPLACE FUNCTION pgvigil.replication_hourly_touch(p_instance_id int, p_lo timestamptz, p_hi timestamptz, p_budget_ms int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_from timestamptz := date_trunc('hour', p_lo AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_to   timestamptz := (date_trunc('hour', p_hi AT TIME ZONE 'UTC') + interval '2 hours') AT TIME ZONE 'UTC';   -- and the hour after
  v_lt   text := current_setting('lock_timeout');
BEGIN
  -- every lock the rollup waits for is waited 1 s at most (a month's partition made while a heal holds the table, a row
  -- a heal writes): past it the hours are marked and the import commits - it never waits out the repository timeout
  PERFORM set_config('lock_timeout', '1s', true);
  BEGIN
    IF v_to - v_from > interval '1 day' THEN   -- a wide write (a delete of an instance's history): purge's heal rebuilds it
      -- inside the handler's block: its error (a lock wait past 1 s) never fails the writer (review A #8)
      PERFORM pgvigil.replication_hourly_mark(p_instance_id, v_from, v_to, 'a write over more than a day of samples');
      PERFORM set_config('lock_timeout', v_lt, true);
      RETURN;
    END IF;
    IF NOT pg_try_advisory_xact_lock(hashtext('pgvigil.replication_hourly'), p_instance_id) THEN
      PERFORM pgvigil.replication_hourly_mark(p_instance_id, v_from, v_to, 'the instance''s hours were being built or healed');
      PERFORM set_config('lock_timeout', v_lt, true);
      RETURN;
    END IF;
    PERFORM pgvigil.replication_hours(p_instance_id, v_from, v_to);
    PERFORM pgvigil.replication_hourly_heal(p_instance_id, p_budget_ms, false);
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      PERFORM pgvigil.replication_hourly_failed(p_instance_id, v_from, v_to, SQLERRM);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'replication_hourly: the rollup of instance % failed and could not be recorded: %', p_instance_id, SQLERRM;
    END;
  END;
  PERFORM set_config('lock_timeout', v_lt, true);
END $$;

-- the triggers' body (INSERT and DELETE: the transition table is 'n' in both): per instance in the statement's rows, in
-- instance order
CREATE OR REPLACE FUNCTION pgvigil.replication_hourly_tg()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v record; v_budget int := coalesce(nullif(current_setting('pgvigil.replication_heal_ms', true), '')::int, 2000);
BEGIN
  FOR v IN SELECT x.instance_id, min(x.snapshot_at) AS lo, max(x.snapshot_at) AS hi FROM n x GROUP BY x.instance_id ORDER BY x.instance_id LOOP
    PERFORM pgvigil.replication_hourly_touch(v.instance_id, v.lo, v.hi, v_budget);
  END LOOP;
  RETURN NULL;
END $$;

-- replication_hourly_purge: the months of replication_hourly wholly older than its hours_retention row (730 days when
-- absent) dropped; returns their names (purge()'s last block adds them to the run's partitions_dropped). The builds and
-- heals are the purge command's, one instance per transaction (replication_hourly_pending, replication_hourly_heal_one).
-- It also makes next month's partitions (the hours' and the samples') ahead and keeps every hours partition at fillfactor 90: the current hour's rows are
-- rewritten every minute and an update stays HOT only with room on its page (measured at fillfactor 100 after a 30-day
-- build: 2 of 242 updates HOT). Here, not in the trigger: setting it needs the table's owner (purge), not the collector.
CREATE OR REPLACE FUNCTION pgvigil.replication_hourly_purge()
RETURNS text[] LANGUAGE plpgsql AS $$
DECLARE v_days int; v_part record; v_names text[] := '{}';
BEGIN
  SELECT r.days INTO v_days FROM pgvigil.hours_retention r WHERE r.table_name = 'replication_hourly';
  v_days := coalesce(v_days, 730);
  PERFORM pgvigil.ensure_month_partition('replication_hourly', (date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month') AT TIME ZONE 'UTC');
  -- and replication_sample's: the first import of a month would make it, and a build reading the samples for minutes
  -- would hold that import - and every import queued behind its lock
  PERFORM pgvigil.ensure_month_partition('replication_sample', (date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month') AT TIME ZONE 'UTC');
  FOR v_part IN
    SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent = 'pgvigil.replication_hourly'::regclass AND NOT coalesce('fillfactor=90' = ANY (c.reloptions), false)
  LOOP
    EXECUTE format('ALTER TABLE pgvigil.%I SET (fillfactor = 90)', v_part.relname);
  END LOOP;
  FOR v_part IN
    SELECT c.relname
      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent = 'pgvigil.replication_hourly'::regclass
       AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => v_days)
     ORDER BY c.relname
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    v_names := v_names || v_part.relname::text;
  END LOOP;
  RETURN v_names;
END $$;

-- replication_series: the lag (p_metric 'lag': senders, the receiver, slots, Aurora replicas) or the recovery-conflict
-- cancellations (p_metric 'conflicts': the rise of a database's confl_* counters on a standby) of one instance over
-- (p_from, p_to], one row per bucket of p_step seconds and object, the max of the bucket (a spike survives). The SAMPLES
-- when the range is 2 days or less and the stored samples reach back to p_from (the oldest month of replication_sample
-- starts at or before it); else the HOURS for the whole range from the UTC hour of p_from (the first point may hold up
-- to 59 minutes before p_from), buckets of at least an hour, the samples by hour where the hours are not built (an
-- instance not built yet, a dirty range) - 'building' then says so. Conflicts: buckets with a rise only (no row = 0).
CREATE OR REPLACE FUNCTION pgvigil.replication_series(p_instance_id int, p_from timestamptz, p_to timestamptz, p_step int, p_metric text DEFAULT 'lag')
RETURNS TABLE (snapshot_at timestamptz, kind text, key text, lag_bytes bigint, lag_secs double precision, rise numeric, building boolean)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE
  v_oldest   timestamptz;
  v_raw      boolean;
  v_from     timestamptz := date_trunc('hour', p_from AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_step     int := greatest(p_step, 3600);
  v_building boolean;
BEGIN
  IF p_metric NOT IN ('lag', 'conflicts') THEN RAISE EXCEPTION 'replication_series: p_metric is lag or conflicts, not %', p_metric; END IF;
  SELECT min(to_date(right(c.relname, 6) || '01', 'YYYYMMDD')::timestamp AT TIME ZONE 'UTC') INTO v_oldest
    FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
   WHERE i.inhparent = 'pgvigil.replication_sample'::regclass AND c.relname ~ '_[0-9]{6}$';
  v_raw := p_to - p_from <= interval '2 days' AND v_oldest IS NOT NULL AND v_oldest <= p_from;
  IF v_raw THEN
    IF p_metric = 'lag' THEN
      RETURN QUERY
      SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / p_step) * p_step), s.kind, s.key, max(s.lag_bytes), max(s.lag_secs), NULL::numeric, false
        FROM pgvigil.replication_sample s
       WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
         AND s.kind IN ('sender', 'receiver', 'slot', 'aurora_replica')
       GROUP BY 1, 2, 3;
    ELSE
      RETURN QUERY
      SELECT to_timestamp(floor(extract(epoch FROM x.snapshot_at) / p_step) * p_step), 'conflict'::text, x.key, NULL::bigint, NULL::float8, sum(x.rise), false
        FROM pgvigil.replication_rises(p_instance_id, p_from, p_to + interval '1 microsecond') x
       WHERE x.kind = 'conflict' AND x.short AND x.snapshot_at > p_from
       GROUP BY 1, 3 HAVING sum(x.rise) > 0;
    END IF;
    RETURN;
  END IF;
  v_building := NOT EXISTS (SELECT 1 FROM pgvigil.replication_hourly_first_build b WHERE b.instance_id = p_instance_id)
                OR EXISTS (SELECT 1 FROM pgvigil.replication_hourly_dirty d WHERE d.instance_id = p_instance_id AND d.source = 'build'
                              AND d.to_at > v_from AND d.from_at < p_to);
  IF p_metric = 'lag' THEN
    RETURN QUERY
    WITH d AS (SELECT x.from_at, x.to_at FROM pgvigil.replication_hourly_dirty x WHERE x.instance_id = p_instance_id
               UNION ALL
               SELECT '-infinity'::timestamptz, 'infinity'::timestamptz
                WHERE NOT EXISTS (SELECT 1 FROM pgvigil.replication_hourly_first_build b WHERE b.instance_id = p_instance_id)),
    u AS (SELECT h.snapshot_at AS at, h.kind, h.key, h.lag_bytes_max AS b, h.lag_secs_max AS t
            FROM pgvigil.replication_hourly h
           WHERE h.instance_id = p_instance_id AND h.snapshot_at >= v_from AND h.snapshot_at < p_to
             AND h.kind IN ('sender', 'receiver', 'slot', 'aurora_replica')
             AND NOT EXISTS (SELECT 1 FROM d WHERE h.snapshot_at < d.to_at AND h.snapshot_at + interval '1 hour' > d.from_at)
          UNION ALL
          SELECT s.snapshot_at, s.kind, s.key, s.lag_bytes, s.lag_secs
            FROM pgvigil.replication_sample s
           WHERE s.instance_id = p_instance_id AND s.snapshot_at >= v_from AND s.snapshot_at < p_to
             AND (s.kind IN ('receiver', 'slot', 'aurora_replica') OR (s.kind = 'sender' AND (s.key LIKE 'app:%' OR s.key LIKE 'slot:%')))
             AND EXISTS (SELECT 1 FROM d WHERE date_trunc('hour', s.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' < d.to_at
                                           AND (date_trunc('hour', s.snapshot_at AT TIME ZONE 'UTC') + interval '1 hour') AT TIME ZONE 'UTC' > d.from_at))
    SELECT to_timestamp(floor(extract(epoch FROM u.at) / v_step) * v_step), u.kind, u.key, max(u.b), max(u.t), NULL::numeric, v_building
      FROM u GROUP BY 1, 2, 3;
  ELSE
    RETURN QUERY
    WITH d AS (SELECT x.from_at, x.to_at FROM pgvigil.replication_hourly_dirty x WHERE x.instance_id = p_instance_id
               UNION ALL
               SELECT '-infinity'::timestamptz, 'infinity'::timestamptz
                WHERE NOT EXISTS (SELECT 1 FROM pgvigil.replication_hourly_first_build b WHERE b.instance_id = p_instance_id)),
    u AS (SELECT h.snapshot_at AS at, h.key, (SELECT sum(e.value::numeric) FROM jsonb_each_text(h.rise) e) AS r
            FROM pgvigil.replication_hourly h
           WHERE h.instance_id = p_instance_id AND h.kind = 'conflict' AND h.snapshot_at >= v_from AND h.snapshot_at < p_to
             AND NOT EXISTS (SELECT 1 FROM d WHERE h.snapshot_at < d.to_at AND h.snapshot_at + interval '1 hour' > d.from_at)
          UNION ALL
          SELECT date_trunc('hour', x.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC', x.key, sum(x.rise)
            FROM d CROSS JOIN LATERAL pgvigil.replication_rises(p_instance_id, greatest(d.from_at, v_from), least(d.to_at, p_to)) x
           WHERE x.kind = 'conflict' AND x.short
           GROUP BY 1, 2)
    SELECT to_timestamp(floor(extract(epoch FROM u.at) / v_step) * v_step), 'conflict'::text, u.key, NULL::bigint, NULL::float8, max(u.r), v_building
      FROM u WHERE u.r > 0 GROUP BY 1, 3;
  END IF;
END $$;

-- pg_role_bands: one instance's roles over [p_from, p_to] for the band under its charts: 'unknown' before its first
-- role read; from the first read to its first change, that change's from_role (no change at all: the role read now);
-- then each change's to_role until the next. A change of system identifier ('another cluster') starts a band with
-- break_before (the history before it is another server's).
CREATE OR REPLACE FUNCTION pgvigil.pg_role_bands(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (from_at timestamptz, to_at timestamptz, role text, break_before boolean)
LANGUAGE sql STABLE AS $$
  WITH st AS (SELECT rs.first_read_at, CASE WHEN rs.is_replica THEN 'standby' ELSE 'primary' END AS role_now
                FROM pgvigil.pg_role_state rs WHERE rs.instance_id = p_instance_id),
  ch AS (SELECT c.changed_at, c.change, c.from_role, c.to_role, row_number() OVER (ORDER BY c.changed_at, c.change_id) AS n
           FROM pgvigil.pg_role_changes c WHERE c.instance_id = p_instance_id),
  seg AS (SELECT '-infinity'::timestamptz AS f, st.first_read_at AS t, 'unknown'::text AS role, false AS brk FROM st
          UNION ALL
          SELECT st.first_read_at, coalesce((SELECT c.changed_at FROM ch c WHERE c.n = 1), 'infinity'),
                 coalesce((SELECT c.from_role FROM ch c WHERE c.n = 1), st.role_now), false FROM st
          UNION ALL
          SELECT c.changed_at, coalesce(lead(c.changed_at) OVER (ORDER BY c.n), 'infinity'), c.to_role, c.change = 'another cluster' FROM ch c)
  SELECT greatest(s.f, p_from), least(s.t, p_to), s.role, s.brk
    FROM seg s
   WHERE s.t > p_from AND s.f < p_to AND s.t > s.f
   ORDER BY 1
$$;

-- C3's threshold: recovery-conflict cancellations of one database of a standby in 10 minutes ('count': the unit check
-- takes it)
ALTER TABLE pgvigil.pg_threshold_keys DROP CONSTRAINT IF EXISTS pg_threshold_keys_unit_check;
ALTER TABLE pgvigil.pg_threshold_keys ADD CONSTRAINT pg_threshold_keys_unit_check CHECK (unit IN ('minutes', 'hours', 'days', 'seconds', 'MB', 'count'));
INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('standby_conflicts', 'Standby queries cancelled: recovery-conflict cancellations of one database in 10 minutes', 'count', 'over', 3, NULL, '{root,tag,instance}', 100000)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

-- a standby's last slot kept past its promotion (review A #5): import_replication (0141) stores primary_slot only while
-- the server is in recovery, and 'two primaries' pairs a promoted standby with its old primary's link by that slot (a
-- standby's walreceiver sends cluster_name, else 'walreceiver': with neither set the link names no one)
ALTER TABLE pgvigil.pg_repl_standby_state ADD COLUMN IF NOT EXISTS last_primary_slot text, ADD COLUMN IF NOT EXISTS last_slot_at timestamptz;
UPDATE pgvigil.pg_repl_standby_state SET last_primary_slot = primary_slot, last_slot_at = read_at
 WHERE in_recovery AND primary_slot IS NOT NULL AND last_primary_slot IS DISTINCT FROM primary_slot;
CREATE OR REPLACE FUNCTION pgvigil.pg_repl_standby_last_slot_tg()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.in_recovery AND NEW.primary_slot IS NOT NULL THEN   -- else the row keeps the slot it last streamed through
    NEW.last_primary_slot := NEW.primary_slot;
    NEW.last_slot_at := NEW.read_at;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pg_repl_standby_last_slot ON pgvigil.pg_repl_standby_state;
CREATE TRIGGER pg_repl_standby_last_slot BEFORE INSERT OR UPDATE ON pgvigil.pg_repl_standby_state
  FOR EACH ROW EXECUTE FUNCTION pgvigil.pg_repl_standby_last_slot_tg();

-- pg_cluster_checks: the checks across the members of one PostgreSQL cluster (one system identifier), the columns of
-- pg_hadr_checks. Members: active instances with a role read (rolechange, every minute), managed platforms out (the
-- provider's); fresh = read in the last 3 minutes.
--   'two primaries'             critical on EACH of two fresh primaries of one cluster when B was promoted after A's
--                               role began, both were read as primary 55 s or more after the collector saw B's
--                               promotion (detected_at: the collector's clock for both sides, never the promoted
--                               server's changed_at - review A #9), and the two are one topology: a link between them
--                               in 7 days (pg_repl_link_seen: the link's application_name is the other's name or
--                               cluster_name, or its slot is the one the other last streamed through, kept past its
--                               promotion), a common upstream that sent to both, or one 'cluster' tag value on both. A
--                               promoted copy that never streamed, and a switchover whose old primary is stopped, raise
--                               nothing. Patroni clusters too (the detail names Patroni's leader).
--   'cluster without a primary' critical, ONE finding on the member last seen primary (else the lowest instance id), when
--                               no fresh member is primary, every fresh standby of the identifier has had its receiver
--                               down for 2 reads or more or is cascaded (a fresh standby of the cluster streams to it now,
--                               the link named for it or through its slot: its receiver stays up), at least one is down,
--                               and a member was read as primary in the last 7 days; never where a fresh Patroni read
--                               covers a member (task 376's 'no leader' says it). A primary
--                               not read while its standbys stream raises nothing here.
--   'standby queries cancelled' warning on a standby in recovery, one per database, when a read in the last 2 minutes
--                               saw the database's confl_* counters rise by the 'standby_conflicts' threshold (3) or
--                               more over the 10 minutes before it (a drop is a reset; a pair over 10 minutes is left
--                               out); the detail names each counter's rise. Every platform.
CREATE OR REPLACE VIEW pgvigil.pg_cluster_checks AS
WITH m AS (
  SELECT rs.instance_id, i.name, rs.system_identifier AS sysid, rs.is_replica, rs.read_at, rs.since,
         nullif(rs.cluster_name, '') AS cluster_name,   -- an empty name matches no link (review A #5)
         rs.read_at > now() - interval '3 minutes' AS fresh,
         CASE WHEN ss.last_slot_at > now() - interval '7 days' THEN ss.last_primary_slot END AS last_slot
    FROM pgvigil.pg_role_state rs
    JOIN pgvigil.instances i ON i.instance_id = rs.instance_id AND i.is_active
    LEFT JOIN pgvigil.pg_repl_standby_state ss ON ss.instance_id = rs.instance_id
   WHERE rs.system_identifier IS NOT NULL AND i.platform NOT IN ('rds', 'aurora', 'azure', 'cloudsql', 'alloydb')
),
prom AS (
  SELECT DISTINCT ON (c.instance_id) c.instance_id, c.changed_at, c.detected_at
    FROM pgvigil.pg_role_changes c WHERE c.change = 'promotion' ORDER BY c.instance_id, c.changed_at DESC
),
split AS (    -- a: the primary whose role began first; b: promoted after it
  SELECT a.instance_id AS a_id, a.name AS a_name, b.instance_id AS b_id, b.name AS b_name, a.sysid, p.changed_at AS promoted_at,
         greatest(a.read_at, b.read_at) AS at
    FROM m a
    JOIN m b ON b.sysid = a.sysid AND b.instance_id <> a.instance_id
    JOIN prom p ON p.instance_id = b.instance_id
   WHERE a.fresh AND b.fresh AND NOT a.is_replica AND NOT b.is_replica
     AND coalesce(a.since, '-infinity') < p.changed_at
     AND a.read_at >= p.detected_at + interval '55 seconds'
     AND b.read_at >= p.detected_at + interval '55 seconds'
     AND (EXISTS (SELECT 1 FROM pgvigil.pg_repl_link_seen l
                   WHERE l.last_seen > now() - interval '7 days'
                     AND ((l.instance_id = a.instance_id AND (lower(l.application_name) IN (lower(b.name), lower(b.cluster_name)) OR l.slot_name = b.last_slot))
                       OR (l.instance_id = b.instance_id AND (lower(l.application_name) IN (lower(a.name), lower(a.cluster_name)) OR l.slot_name = a.last_slot))))
          OR EXISTS (SELECT 1 FROM pgvigil.pg_repl_link_seen la
                       JOIN pgvigil.pg_repl_link_seen lb ON lb.instance_id = la.instance_id
                      WHERE la.last_seen > now() - interval '7 days' AND lb.last_seen > now() - interval '7 days'
                        AND (lower(la.application_name) IN (lower(a.name), lower(a.cluster_name)) OR la.slot_name = a.last_slot)
                        AND (lower(lb.application_name) IN (lower(b.name), lower(b.cluster_name)) OR lb.slot_name = b.last_slot))
          OR EXISTS (SELECT 1 FROM pgvigil.instance_tag_pairs ta
                       JOIN pgvigil.instance_tag_pairs tb ON tb.key = ta.key AND tb.value = ta.value
                      WHERE ta.instance_id = a.instance_id AND tb.instance_id = b.instance_id AND ta.key = 'cluster'))
),
two AS (
  SELECT s.a_id AS instance_id, s.sysid, s.b_name AS other, s.promoted_at, s.at FROM split s
  UNION ALL
  SELECT s.b_id, s.sysid, s.a_name, s.promoted_at, s.at FROM split s
),
headless AS (
  SELECT g.sysid, g.standbys, g.reads, g.at,
         coalesce((SELECT x.instance_id FROM m x WHERE x.sysid = g.sysid AND NOT x.is_replica ORDER BY x.read_at DESC LIMIT 1),
                  (SELECT min(x.instance_id) FROM m x WHERE x.sysid = g.sysid)) AS instance_id,
         (SELECT x.name || ' at ' || to_char(x.read_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC'
            FROM m x WHERE x.sysid = g.sysid AND NOT x.is_replica ORDER BY x.read_at DESC LIMIT 1) AS last_primary
    FROM (SELECT mm.sysid, string_agg(mm.name, ', ' ORDER BY mm.name) FILTER (WHERE mm.fresh AND mm.is_replica AND NOT mm.cascaded) AS standbys,
                 min(mm.down_reads) FILTER (WHERE mm.fresh AND mm.is_replica AND NOT mm.cascaded) AS reads, max(mm.read_at) AS at
            FROM (SELECT m.*, st.in_recovery AS st_in_recovery, st.down_reads, st.read_at AS st_read_at,
                         EXISTS (SELECT 1 FROM pgvigil.pg_patroni_read pr
                                  WHERE pr.instance_id = m.instance_id AND pr.ok AND pr.snapshot_at > now() - interval '3 minutes') AS patroni_fresh,
                         -- a cascaded standby: a fresh standby of the cluster streams to it now (its receiver stays
                         -- up), the link named for it or through its slot
                         EXISTS (SELECT 1 FROM pgvigil.pg_repl_link_seen l JOIN m u ON u.instance_id = l.instance_id AND u.sysid = m.sysid AND u.fresh AND u.is_replica
                                  WHERE l.checked_at > now() - interval '3 minutes' AND l.gone_reads = 0 AND l.last_state = 'streaming'
                                    AND (lower(l.application_name) IN (lower(m.name), lower(m.cluster_name)) OR l.slot_name = st.primary_slot)) AS cascaded
                    FROM m LEFT JOIN pgvigil.pg_repl_standby_state st ON st.instance_id = m.instance_id) mm
           GROUP BY mm.sysid
          HAVING count(*) FILTER (WHERE mm.fresh AND NOT mm.is_replica) = 0
             AND count(*) FILTER (WHERE mm.fresh AND mm.is_replica) > 0
             AND count(*) FILTER (WHERE mm.fresh AND mm.is_replica AND mm.st_in_recovery AND mm.down_reads >= 2 AND mm.st_read_at > now() - interval '3 minutes') > 0
             AND count(*) FILTER (WHERE mm.fresh AND mm.is_replica)
                 = count(*) FILTER (WHERE mm.fresh AND mm.is_replica
                                      AND (mm.st_in_recovery AND mm.down_reads >= 2 AND mm.st_read_at > now() - interval '3 minutes' OR mm.cascaded))
             AND count(*) FILTER (WHERE NOT mm.is_replica AND mm.read_at > now() - interval '7 days') > 0
             AND NOT bool_or(mm.patroni_fresh)) g
),
conflicts AS (
  SELECT st.instance_id, w.datname, w.at, w.n, w.counters, t.warn, t.level
    FROM pgvigil.pg_repl_standby_state st
    JOIN pgvigil.instances i ON i.instance_id = st.instance_id AND i.is_active
    CROSS JOIN LATERAL (
      SELECT DISTINCT ON (k.key) k.key AS datname, k.at, k.n, k.counters
        FROM (SELECT q.key, q.at, sum(q.s) AS n, string_agg(q.counter || ' +' || trim_scale(q.s), ', ' ORDER BY q.counter) AS counters
                FROM (SELECT z.key, r.at, z.counter, sum(z.rise) AS s
                        FROM (SELECT DISTINCT s.snapshot_at AS at FROM pgvigil.replication_sample s
                               WHERE s.instance_id = st.instance_id AND s.kind = 'conflict' AND s.snapshot_at > now() - interval '2 minutes') r
                        JOIN (SELECT x.key, x.snapshot_at, x.counter, x.rise
                                FROM pgvigil.replication_rises(st.instance_id, now() - interval '12 minutes', now() + interval '1 minute') x
                               WHERE x.kind = 'conflict' AND x.short AND x.rise > 0) z
                          ON z.snapshot_at > r.at - interval '10 minutes' AND z.snapshot_at <= r.at
                       GROUP BY z.key, r.at, z.counter) q
               GROUP BY q.key, q.at) k
       ORDER BY k.key, k.n DESC) w
    CROSS JOIN LATERAL pgvigil.pg_threshold(st.instance_id, 'standby_conflicts', w.datname) t
   WHERE st.in_recovery AND st.read_at > now() - interval '30 minutes' AND t.warn IS NOT NULL AND w.n >= t.warn
)
SELECT t.instance_id, 'critical'::text AS severity, 'two primaries'::text AS check_name, 'system identifier ' || t.sysid AS object, max(t.at) AS at,
       format('primary together with %s, promoted %s UTC while this server stayed primary: a split brain - both accept writes%s',
              string_agg(t.other, ', ' ORDER BY t.other), to_char(max(t.promoted_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
              coalesce('; Patroni''s leader: ' || (SELECT pm.member FROM pgvigil.pg_patroni_members pm
                                                    WHERE pm.instance_id = t.instance_id AND pm.role IN ('leader', 'master', 'standby_leader')
                                                    ORDER BY pm.snapshot_at DESC LIMIT 1), '')) AS detail,
       2 AS reads,
       format('primary together with %s: a split brain', string_agg(t.other, ', ' ORDER BY t.other)) AS stable
  FROM two t
 GROUP BY t.instance_id, t.sysid
UNION ALL
SELECT h.instance_id, 'critical', 'cluster without a primary', 'system identifier ' || h.sysid, h.at,
       format('no member of the cluster is primary: the standbys %s have had no WAL receiver for %s reads or more%s',
              h.standbys, h.reads, coalesce('; the last primary read: ' || h.last_primary, '')),
       h.reads, 'no primary: every standby''s WAL receiver is down'
  FROM headless h
UNION ALL
SELECT c.instance_id, 'warning', 'standby queries cancelled', 'database ' || c.datname, c.at,
       format('%s queries cancelled by recovery conflicts in the 10 minutes to %s UTC (%s); warning at %s (%s)',
              c.n, to_char(c.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'), c.counters, trim_scale(c.warn), c.level),
       1, format('queries cancelled by recovery conflicts (warning at %s in 10 minutes)', trim_scale(c.warn))
  FROM conflicts c;

-- C2, a cascaded standby: 0141's pg_repl_link_health again (0141 L381-604), every column kept; a streaming link whose
-- sending server is itself in recovery reads 'streaming (cascaded from <the sending server>)', and the last column
-- sending_in_recovery says the sending server's role (the page draws the chain). No new rule: the upstream's own link
-- and receiver rules judge it.
CREATE OR REPLACE VIEW pgvigil.pg_repl_link_health AS
WITH unreach AS (   -- instances whose newest collection attempt could not connect (0118's 'server unreachable' read)
  SELECT c.instance_id
    FROM (SELECT DISTINCT ON (d.instance_id) d.instance_id, d.status, d.note, d.snapshot_at
            FROM pgvigil.collection_dates d ORDER BY d.instance_id, d.snapshot_at DESC) c
   WHERE c.status = 'error' AND c.note LIKE 'connect: %' AND c.snapshot_at > now() - interval '30 minutes'
),
stb AS (            -- the monitored standbys
  SELECT s.*, i.name AS standby, i.platform AS standby_platform, rs.system_identifier AS sysid, rs.cluster_name,
         (s.read_at > now() - interval '30 minutes' AND NOT EXISTS (SELECT 1 FROM unreach u WHERE u.instance_id = s.instance_id)) AS speaks,
         EXISTS (SELECT 1 FROM unreach u WHERE u.instance_id = s.instance_id) AS unreachable
    FROM pgvigil.pg_repl_standby_state s
    JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
    LEFT JOIN pgvigil.pg_role_state rs ON rs.instance_id = s.instance_id
   WHERE s.in_recovery
     AND i.platform <> 'aurora'   -- task 374: an Aurora reader has no WAL receiver; aurora_replica_status judges it
),
snd AS (            -- the sending side: every physical link a server sent to in the last 7 days
  SELECT l.*, i.name AS sending, i.platform AS sending_platform, rs.system_identifier AS sysid,
         (l.checked_at > now() - interval '30 minutes') AS fresh,
         -- the same standby back under another link (the header's rule): its vanished link is no gap
         (l.gone_reads > 0 AND (
            EXISTS (SELECT 1 FROM pgvigil.pg_repl_link_seen o
                     WHERE o.instance_id = l.instance_id AND o.link <> l.link AND o.gone_reads = 0
                       AND o.application_name IS NOT DISTINCT FROM l.application_name AND o.client_addr IS NOT DISTINCT FROM l.client_addr
                       AND (o.slot_name IS NULL OR l.slot_name IS NULL))
            OR (l.slot_name IS NULL
                AND (SELECT count(*) FROM pgvigil.pg_repl_link_seen o
                      WHERE o.instance_id = l.instance_id AND o.slot_name IS NULL AND o.gone_reads = 0
                        AND o.application_name IS NOT DISTINCT FROM l.application_name AND o.first_seen >= l.gone_since - interval '1 minute')
                 >= (SELECT count(*) FROM pgvigil.pg_repl_link_seen g
                      WHERE g.instance_id = l.instance_id AND g.slot_name IS NULL AND g.gone_reads > 0
                        AND g.application_name IS NOT DISTINCT FROM l.application_name AND g.last_seen > now() - interval '7 days')))) AS replaced
    FROM pgvigil.pg_repl_link_seen l
    JOIN pgvigil.instances i ON i.instance_id = l.instance_id AND i.is_active
    LEFT JOIN pgvigil.pg_role_state rs ON rs.instance_id = l.instance_id
   WHERE l.last_seen > now() - interval '7 days'
),
paired AS (         -- a link paired with the monitored standby it names: by its slot, or by a name exactly one standby has
  SELECT snd.*, CASE WHEN snd.slot_name IS NOT NULL OR m.n = 1 THEN m.instance_id END AS standby_id
    FROM snd
    LEFT JOIN LATERAL (
      SELECT b.instance_id, count(*) OVER () AS n FROM stb b
       WHERE b.instance_id <> snd.instance_id
         AND (b.sysid = snd.sysid OR b.sysid IS NULL OR snd.sysid IS NULL)
         AND ((snd.slot_name IS NOT NULL AND b.primary_slot = snd.slot_name)
              OR (snd.slot_name IS NULL AND (lower(b.cluster_name) = lower(snd.application_name) OR lower(b.standby) = lower(snd.application_name))))
       ORDER BY (b.sysid = snd.sysid) DESC NULLS LAST, b.read_at DESC LIMIT 1) m ON true
),
sync AS (           -- each primary's synchronous_standby_names, parsed (inert on a standby)
  SELECT r.instance_id, p.method, p.num_sync, p.names
    FROM pgvigil.replication_latest r
    CROSS JOIN LATERAL pgvigil.pg_sync_standbys(r.state) p
   WHERE r.kind = 'sync' AND NOT coalesce((r.detail->>'in_recovery')::boolean, false)
),
links AS (
  -- a link the sending server sent to, with its standby's own read when that standby is monitored
  SELECT 'sender'::text AS source, p.instance_id AS sending_id, p.sending, p.sending_platform, p.link, p.application_name,
         p.client_addr, p.slot_name, p.sysid, p.fresh AS sender_fresh, p.gone_reads, p.gone_since, p.last_seen, p.checked_at,
         p.last_state AS sender_state, p.sync_state, p.lag_bytes, p.prev_lag_bytes, p.flush_bytes, p.prev_flush_bytes,
         p.lag_secs, p.prev_lag_secs, p.standby_id, p.replaced
    FROM paired p
  UNION ALL
  -- a monitored standby no sending server's link names (its primary not monitored, or not matched)
  SELECT 'standby', NULL, NULL, NULL, 'standby:' || b.standby, NULL, NULL, b.primary_slot, b.sysid, NULL, NULL, NULL, NULL, b.read_at,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, b.instance_id, false
    FROM stb b WHERE NOT EXISTS (SELECT 1 FROM paired p WHERE p.standby_id = b.instance_id)
  UNION ALL
  -- an inactive physical slot no link was seen through: a standby expected, never seen here (0190's 'inactive
  -- replication slot' finding covers it)
  SELECT 'slot', s.instance_id, i.name, i.platform, 'slot:' || s.key, NULL, NULL, s.key, rs.system_identifier, true, NULL, NULL, NULL, s.snapshot_at,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, false
    FROM pgvigil.replication_latest s
    JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
    LEFT JOIN pgvigil.pg_role_state rs ON rs.instance_id = s.instance_id
   WHERE s.kind = 'slot' AND s.detail->>'slot_type' = 'physical' AND NOT coalesce(s.active, false)
     AND NOT coalesce((s.detail->>'temporary')::boolean, false) AND NOT coalesce((s.detail->>'synced')::boolean, false)
     AND NOT EXISTS (SELECT 1 FROM snd WHERE snd.instance_id = s.instance_id AND snd.link = 'slot:' || s.key)
  UNION ALL
  -- a name in synchronous_standby_names with no link of that application_name (task 372 judges it)
  SELECT 'sync names', y.instance_id, i.name, i.platform, 'app:' || n.name, n.name, NULL, NULL, rs.system_identifier, true, NULL, NULL, NULL, now(),
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, false
    FROM sync y
    CROSS JOIN LATERAL unnest(y.names) n(name)
    JOIN pgvigil.instances i ON i.instance_id = y.instance_id AND i.is_active
    LEFT JOIN pgvigil.pg_role_state rs ON rs.instance_id = y.instance_id
   WHERE NOT EXISTS (SELECT 1 FROM snd WHERE snd.instance_id = y.instance_id AND lower(snd.application_name) = lower(n.name))
),
judged AS (
  SELECT k.*, b.standby, b.standby_platform, b.speaks, b.unreachable, b.read_at AS standby_read_at, b.in_recovery,
         b.has_receiver, b.receiver_status, b.sender_host, b.conninfo_set, b.restore_set, b.primary_slot, b.min_apply_delay_ms,
         b.rcv_bytes, b.prev_rcv_bytes, b.replay_paused, b.prev_replay_paused, b.replay_moved_at, b.down_reads, b.down_since,
         b.replay_lsn AS standby_replay_lsn, b.receive_lsn AS standby_receive_lsn,
         ss.in_sync, ss.num_sync AS sync_num, ss.setting AS sync_setting, ss.snapshot_at AS sync_at,
         -- a standby paired with several links (an old one replaced, or vanished) judges its own side on one: its live
         -- link first, else the newest
         (k.standby_id IS NULL OR row_number() OVER (PARTITION BY k.standby_id ORDER BY (k.gone_reads = 0) DESC NULLS FIRST, k.last_seen DESC NULLS FIRST) = 1) AS own_row,
         coalesce(b.min_apply_delay_ms, 0) / 1000.0 AS delay_s,
         -- the standby speaks for this link only when read since its sender vanished (else its last word is older)
         -- and only when it can judge its own side: a receiver, or primary_conninfo readable (NULL = a login without
         -- pg_read_all_settings: then the sender's 'standby gone' holds)
         (b.speaks AND (b.has_receiver OR b.conninfo_set IS NOT NULL) AND (k.gone_since IS NULL OR b.read_at >= k.gone_since)) AS link_speaks,
         -- the sending server's view counts while its read is fresh and the link has a sender
         (k.source = 'sender' AND k.sender_fresh AND k.gone_reads = 0) AS sender_view,
         ts.warn AS t_warn, ts.crit AS t_crit, ts.level AS t_level, bs.warn AS b_warn, bs.crit AS b_crit, bs.level AS b_level,
         bb.warn AS sb_warn, bb.crit AS sb_crit, rst.crit AS stall_min, rst.level AS stall_level
    FROM links k
    LEFT JOIN stb b ON b.instance_id = k.standby_id
    LEFT JOIN pgvigil.pg_sync_state ss ON ss.instance_id = k.sending_id
         AND (k.source = 'sync names'
              OR (k.source = 'sender' AND k.gone_reads > 0 AND lower(k.application_name) IN (SELECT lower(x) FROM unnest(ss.names) x)))
    LEFT JOIN LATERAL pgvigil.pg_threshold(k.sending_id, 'standby_replay_lag') ts ON k.sending_id IS NOT NULL
    LEFT JOIN LATERAL pgvigil.pg_threshold(k.sending_id, 'standby_lag_bytes') bs ON k.sending_id IS NOT NULL
    LEFT JOIN LATERAL pgvigil.pg_threshold(k.standby_id, 'standby_lag_bytes') bb ON k.standby_id IS NOT NULL
    LEFT JOIN LATERAL pgvigil.pg_threshold(k.standby_id, 'restore_stall') rst ON k.standby_id IS NOT NULL
),
measured AS (
  SELECT j.*,
         -- bytes held for 2 reads: the sending server's replay position (its flush position on a standby that delays
         -- apply on purpose), else the standby's received - replayed (not judged on a delayed standby)
         -- (least() skips a NULL, so each pair is NULL unless both reads have a value: a first read is no 2 in a row)
         CASE WHEN NOT j.own_row AND NOT j.sender_view THEN NULL
              WHEN j.sender_view AND j.delay_s > 0 THEN CASE WHEN j.prev_flush_bytes IS NOT NULL AND j.flush_bytes IS NOT NULL THEN least(j.flush_bytes, j.prev_flush_bytes) END
              WHEN j.sender_view THEN CASE WHEN coalesce(j.prev_lag_bytes, j.prev_flush_bytes) IS NOT NULL AND coalesce(j.lag_bytes, j.flush_bytes) IS NOT NULL
                                           THEN least(coalesce(j.lag_bytes, j.flush_bytes), coalesce(j.prev_lag_bytes, j.prev_flush_bytes)) END   -- pg_receivewal / Barman: no replay position
              WHEN j.speaks AND j.has_receiver AND j.delay_s = 0 THEN CASE WHEN j.prev_rcv_bytes IS NOT NULL AND j.rcv_bytes IS NOT NULL THEN least(j.rcv_bytes, j.prev_rcv_bytes) END
         END AS bytes2,
         CASE WHEN j.sender_view AND j.prev_lag_secs IS NOT NULL AND j.lag_secs IS NOT NULL THEN least(j.lag_secs, j.prev_lag_secs) - j.delay_s END AS secs2,
         CASE WHEN j.sender_view THEN j.b_warn WHEN j.speaks THEN j.sb_warn END AS bw,
         CASE WHEN j.sender_view THEN j.b_crit WHEN j.speaks THEN j.sb_crit END AS bc,
         -- down_reads holds through one read with a receiver (the state's hysteresis), so has_receiver is not asked here
         (j.own_row AND j.speaks AND j.conninfo_set AND j.down_reads >= 2
          AND j.standby_platform NOT IN ('rds', 'aurora', 'azure', 'cloudsql', 'alloydb')) AS is_down,
         (j.source = 'sender' AND j.sender_fresh AND j.gone_reads >= 2 AND NOT coalesce(j.link_speaks, false) AND NOT j.replaced
          AND j.sending_platform NOT IN ('rds', 'aurora', 'azure', 'cloudsql', 'alloydb')) AS is_gone,
         (j.own_row AND j.speaks AND j.replay_paused AND j.prev_replay_paused
          AND j.standby_platform NOT IN ('rds', 'aurora', 'azure', 'cloudsql', 'alloydb')) AS is_paused,
         -- 'receiver down' is a warning only while restore_command still feeds replay past the last streamed position
         (j.restore_set AND j.replay_moved_at > j.down_since AND j.standby_replay_lsn > coalesce(j.standby_receive_lsn, '0/0'::pg_lsn)
          AND NOT (j.stall_min IS NOT NULL AND j.replay_moved_at < j.standby_read_at - make_interval(secs => j.stall_min * 60))) AS fed,
         -- a named synchronous standby not connected while num_sync still holds (fewer is pg_hadr_checks' critical)
         (j.source IN ('sync names', 'sender') AND j.in_sync >= j.sync_num AND j.sync_at > now() - interval '30 minutes') AS is_sync_absent
    FROM judged j
),
tiered AS (
  SELECT m.*,
         CASE WHEN (m.bc IS NOT NULL AND m.bytes2 >= m.bc * 1048576) OR (m.t_crit IS NOT NULL AND m.secs2 >= m.t_crit) THEN 'critical'
              WHEN (m.bw IS NOT NULL AND m.bytes2 >= m.bw * 1048576) OR (m.t_warn IS NOT NULL AND m.secs2 >= m.t_warn) THEN 'warning' END AS lag_sev,
         true AS tiered
    FROM measured m
)
SELECT t.source, t.sending_id, t.sending, t.link, t.application_name, t.client_addr, t.slot_name, t.sysid AS system_identifier,
       t.standby_id, t.standby,
       CASE WHEN t.source = 'slot' THEN 'missing: physical slot inactive'
            WHEN t.source = 'sync names' THEN 'missing: named in synchronous_standby_names'
            WHEN t.is_down THEN 'down: receiver'
            WHEN t.source = 'sender' AND NOT t.sender_fresh THEN 'sending server not read'
            WHEN t.source = 'sender' AND t.gone_reads > 0 AND t.replaced THEN 'replaced: the standby is back under another link'
            WHEN t.source = 'sender' AND t.gone_reads > 0 AND t.unreachable THEN 'down: standby unreachable'
            WHEN t.source = 'sender' AND t.gone_reads > 0 AND t.link_speaks AND t.has_receiver THEN 'moved: the standby streams from elsewhere'
            WHEN t.source = 'sender' AND t.gone_reads > 0 THEN 'down: no sender'
            WHEN t.is_paused OR (t.speaks AND t.replay_paused) THEN 'replay paused'
            WHEN t.source = 'standby' AND t.speaks AND t.has_receiver THEN 'streaming (its primary not monitored)'
            WHEN t.source = 'standby' AND t.speaks THEN 'no WAL receiver'
            WHEN t.source = 'standby' THEN 'standby not read'
            WHEN t.source = 'sender' AND t.sender_state = 'streaming'
                 AND EXISTS (SELECT 1 FROM pgvigil.pg_repl_standby_state c WHERE c.instance_id = t.sending_id AND c.in_recovery)
              THEN 'streaming (cascaded from ' || t.sending || ')'
            ELSE coalesce(t.sender_state, 'unknown') END AS status,
       t.sender_state, t.sync_state, t.lag_bytes AS sender_lag_bytes, t.flush_bytes AS sender_flush_bytes, t.lag_secs AS sender_lag_secs,
       t.receiver_status, t.sender_host, t.has_receiver, t.rcv_bytes AS standby_lag_bytes, t.min_apply_delay_ms, t.replay_paused,
       t.down_reads, t.gone_reads, t.last_seen, t.checked_at, t.standby_read_at, t.unreachable AS standby_unreachable,
       CASE WHEN t.is_down OR t.is_gone OR t.is_paused THEN NULL ELSE t.lag_sev END AS lag_severity,
       CASE WHEN t.is_down THEN 'receiver down' WHEN t.is_gone THEN 'standby gone' WHEN t.is_paused THEN 'replay paused'
            WHEN t.lag_sev IS NOT NULL THEN 'standby lag' WHEN t.is_sync_absent THEN 'synchronous standby absent' END AS check_name,
       CASE WHEN t.is_down THEN CASE WHEN t.fed OR t.has_receiver THEN 'warning' ELSE 'critical' END
            WHEN t.is_gone OR t.is_paused THEN 'critical'
            WHEN t.is_sync_absent THEN 'warning'
            ELSE t.lag_sev END AS severity,
       CASE WHEN t.is_down OR t.is_paused THEN t.standby_id WHEN t.is_gone THEN t.sending_id
            WHEN t.lag_sev IS NOT NULL THEN CASE WHEN t.sender_view THEN t.sending_id ELSE t.standby_id END
            WHEN t.is_sync_absent THEN t.sending_id END AS finding_id,
       CASE WHEN t.is_down THEN coalesce('slot ' || t.primary_slot, 'primary_conninfo')
            WHEN t.is_paused THEN 'replay'
            ELSE coalesce(nullif(t.application_name, ''), t.standby, '(no name)') || coalesce(' at ' || t.client_addr, '')
                 || coalesce(' (slot ' || t.slot_name || ')', '') END AS object,
       CASE WHEN t.is_down THEN t.standby_read_at WHEN t.is_paused THEN t.standby_read_at ELSE t.checked_at END AS at,
       CASE WHEN t.is_down THEN t.down_reads WHEN t.is_gone THEN t.gone_reads ELSE 2 END AS reads,
       CASE WHEN t.is_down THEN
              format('in recovery with primary_conninfo set and no WAL receiver for %s reads in a row (since %s UTC); %s',
                     t.down_reads, to_char(t.down_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
                     CASE WHEN t.has_receiver
                            THEN 'a WAL receiver is back (' || coalesce(t.receiver_status, 'status unknown') || '): the fault ends at the second read with it'
                          WHEN t.fed
                            THEN 'replay still advances through restore_command (last moved ' || to_char(t.replay_moved_at AT TIME ZONE 'UTC', 'HH24:MI:SS') || ' UTC): the standby follows whole WAL files, not the stream'
                          WHEN NOT coalesce(t.restore_set, false)
                            THEN 'no restore_command: nothing reaches the standby until the receiver is back'
                          WHEN t.replay_moved_at IS NULL OR t.replay_moved_at <= t.down_since
                            THEN 'replay has not moved since the receiver went down (restore_command finds nothing new)'
                          WHEN t.stall_min IS NOT NULL AND t.replay_moved_at < t.standby_read_at - make_interval(secs => t.stall_min * 60)
                            THEN 'replay has stopped: it last moved ' || to_char(t.replay_moved_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC (critical after ' || trim_scale(t.stall_min) || ' min, ' || t.stall_level || ')'
                          ELSE 'replay moved only through WAL already received: restore_command has brought nothing past it'
                     END || CASE WHEN t.replay_paused THEN '; replay is paused' ELSE '' END)
            WHEN t.is_gone THEN
              format('streamed from this server until %s UTC and has had no WAL sender for %s reads in a row: the standby is %s',
                     to_char(t.last_seen AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'), t.gone_reads,
                     CASE WHEN t.unreachable THEN 'not answering pgvigil either (stopped or cut off)' ELSE 'stopped, cut off or no longer replicating' END)
            WHEN t.is_paused THEN 'replay is paused (pg_wal_replay_pause) for 2 reads in a row: the standby receives WAL and applies none of it'
            WHEN t.is_sync_absent THEN
              format('named in synchronous_standby_names (%s) and not connected; %s in sync of the %s it asks for: commits go on, one more loss and they wait',
                     t.sync_setting, t.in_sync, t.sync_num)
            WHEN t.lag_sev IS NOT NULL THEN
              concat_ws('; ',
                CASE WHEN t.bw IS NOT NULL AND t.bytes2 >= t.bw * 1048576 THEN format('%s not yet replayed (%s)', pg_size_pretty(t.bytes2::numeric),
                       CASE WHEN t.sender_view AND t.delay_s > 0 THEN 'the sender''s flush position: apply is delayed on purpose'
                            WHEN t.sender_view THEN 'the sender''s replay position' ELSE 'received - replayed on the standby' END) END,
                CASE WHEN t.t_warn IS NOT NULL AND t.secs2 >= t.t_warn THEN format('replay_lag %s s beyond the apply delay of %s s', round(t.secs2::numeric, 1), round(t.delay_s, 1)) END,
                format('2 reads in a row; warning %s MB / %s s, critical %s MB / %s s', coalesce(trim_scale(t.bw)::text, '-'), coalesce(trim_scale(t.t_warn)::text, '-'),
                       coalesce(trim_scale(t.bc)::text, '-'), coalesce(trim_scale(t.t_crit)::text, '-')))
       END AS detail,
       CASE WHEN t.is_down THEN format('no WAL receiver since %s UTC while primary_conninfo is set', to_char(t.down_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'))
            WHEN t.is_gone THEN format('no WAL sender since %s UTC (it last streamed %s UTC)', to_char(t.gone_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
                                       to_char(t.last_seen AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'))
            WHEN t.is_paused THEN 'replay is paused'
            WHEN t.lag_sev IS NOT NULL THEN 'the standby is behind its primary (bytes not replayed or replay_lag past the thresholds)'
            WHEN t.is_sync_absent THEN 'named in synchronous_standby_names and not connected' END AS stable,
       (SELECT c.in_recovery FROM pgvigil.pg_repl_standby_state c WHERE c.instance_id = t.sending_id) AS sending_in_recovery
  FROM tiered t;

-- 0141's pg_hadr_checks again (0141 L865-939, every arm kept) with the cluster checks above as its last arm, so they
-- reach pgvigil.findings the way 0141's rules do (pg_backups_checks' 'replication' group, pg_backups_findings).
-- pg_hadr_checks: the streaming replication rules of this file, one row per finding (instance_id, severity, check_name,
-- object, at, detail, reads, stable): one per link at most. detail is the newest read's account (the Summary and the
-- Replication page); stable is the text the findings carry. A read older than 30 minutes raises nothing (the
-- Collections page says the collection is stale); a managed platform's standbys are the provider's.
CREATE OR REPLACE VIEW pgvigil.pg_hadr_checks AS
SELECT h.finding_id AS instance_id, h.severity, h.check_name, h.object, h.at, h.detail, h.reads, h.stable
  FROM pgvigil.pg_repl_link_health h
 WHERE h.check_name IS NOT NULL AND h.finding_id IS NOT NULL
UNION ALL
-- task 372: fewer standbys in sync than synchronous_standby_names asks for (one row per primary, not per link)
SELECT y.instance_id, CASE WHEN y.commit_level IN ('off', 'local') THEN 'warning' ELSE 'critical' END, 'synchronous commits waiting',
       'synchronous_standby_names', y.snapshot_at,
       format('%s standby(s) in sync of the %s that synchronous_standby_names = ''%s'' asks for (%s)%s; %s',
              y.in_sync, y.num_sync, y.setting, coalesce('senders: ' || y.senders, 'no sender connected'),
              coalesce('; named and not connected: ' || array_to_string(y.absent, ', '), ''),
              CASE WHEN y.commit_level IN ('off', 'local') THEN 'synchronous_commit is ' || y.commit_level || ' at the server: sessions that keep it do not wait, those that set on / remote_write / remote_apply do'
                   ELSE 'every commit waits (synchronous_commit ' || y.commit_level || ') until a standby is back or the setting changes' END),
       1, format('fewer synchronous standbys than synchronous_standby_names = ''%s'' asks for', y.setting)
  FROM pgvigil.pg_sync_state y
  JOIN pgvigil.instances i ON i.instance_id = y.instance_id AND i.is_active
 WHERE y.in_sync < y.num_sync AND y.snapshot_at > now() - interval '30 minutes'
UNION ALL
-- task 373: logical replication, one finding per subscription
SELECT k.instance_id, k.severity, k.check_name, k.object, k.at, k.detail, 1, k.stable
  FROM pgvigil.pg_logical_checks k
UNION ALL
-- task 374: one finding per slot (a temporary slot, and a failover slot synced to a standby, are not judged)
SELECT x.instance_id,
       CASE WHEN x.check_name = 'slot invalidated' THEN 'critical'
            WHEN x.check_name = 'slot WAL near its limit' AND x.wal_status = 'unreserved' THEN 'critical'
            ELSE 'warning' END,
       x.check_name, 'slot ' || x.key, x.snapshot_at,
       CASE x.check_name
         WHEN 'slot invalidated' THEN format('invalidated (%s): the slot can no longer be used; its consumer must be rebuilt (a standby from a new base backup, a subscription or CDC task re-synced)',
                                             coalesce(x.reason, 'wal_status lost'))
         WHEN 'slot WAL near its limit' THEN format('%s of WAL left before max_slot_wal_keep_size (%s) invalidates it (wal_status %s; retains %s; warning under %s MB or half the limit, the smaller)',
                                                    pg_size_pretty(x.safe_bytes), pg_size_pretty(x.max_keep), x.wal_status, pg_size_pretty(x.lag_bytes), trim_scale(x.safe_warn))
         WHEN 'slot WAL growing' THEN format('retained WAL grew %s in the last full hour (closed %s UTC; now %s; warning at %s MB)',
                                             pg_size_pretty(x.growth_bytes_h), to_char(x.growth_at AT TIME ZONE 'UTC', 'HH24:MI'), pg_size_pretty(x.lag_bytes), trim_scale(x.growth_warn))
       END,
       1,
       CASE x.check_name WHEN 'slot invalidated' THEN 'the slot is invalidated'
                         WHEN 'slot WAL near its limit' THEN 'the slot is near max_slot_wal_keep_size'
                         ELSE 'the slot keeps more WAL every hour' END
  FROM (SELECT r.instance_id, r.key, r.snapshot_at, r.lag_bytes, r.detail->>'wal_status' AS wal_status, r.detail->>'invalidation_reason' AS reason,
               (r.detail->>'safe_wal_size')::bigint AS safe_bytes, (r.detail->>'max_keep_bytes')::bigint AS max_keep,
               st.growth_bytes_h, st.growth_at, sw.warn AS safe_warn, gw.warn AS growth_warn,
               CASE WHEN r.detail->>'invalidation_reason' IS NOT NULL OR r.detail->>'wal_status' = 'lost' THEN 'slot invalidated'
                    WHEN r.detail->>'wal_status' = 'unreserved'
                         OR (sw.warn IS NOT NULL AND (r.detail->>'safe_wal_size')::bigint
                               < least(sw.warn * 1048576, (r.detail->>'max_keep_bytes')::bigint / 2)) THEN 'slot WAL near its limit'
                    WHEN gw.warn IS NOT NULL AND st.growth_bytes_h >= gw.warn * 1048576 AND st.growth_at > now() - interval '2 hours' THEN 'slot WAL growing'
               END AS check_name
          FROM pgvigil.replication_latest r
          JOIN pgvigil.instances i ON i.instance_id = r.instance_id AND i.is_active
          LEFT JOIN pgvigil.pg_repl_slot_state st ON st.instance_id = r.instance_id AND st.slot_name = r.key
          CROSS JOIN LATERAL pgvigil.pg_threshold(r.instance_id, 'slot_safe_wal') sw
          CROSS JOIN LATERAL pgvigil.pg_threshold(r.instance_id, 'slot_growth') gw
         WHERE r.kind = 'slot' AND r.snapshot_at > now() - interval '30 minutes'
           AND NOT coalesce((r.detail->>'temporary')::boolean, false) AND NOT coalesce((r.detail->>'synced')::boolean, false)) x
 WHERE x.check_name IS NOT NULL
UNION ALL
-- task 374: an Aurora replica, judged by aurora_replica_status on the writer (the writer's own row is left out); a
-- reader returns the same rows and raises only when no monitored writer reads that replica fresh - only the reader
-- endpoint configured, the writer's read failing, every member in recovery (a global database's secondary) - and then
-- once, on the lowest such reader (review 21:27 #1: with the reader's state stored since the Q7 fix, the writer-alone
-- rule left those cases silent)
SELECT a.instance_id, CASE WHEN t.crit IS NOT NULL AND a.lag_secs >= t.crit THEN 'critical' ELSE 'warning' END, 'Aurora replica lag',
       'replica ' || a.key, a.snapshot_at,
       format('the Aurora replica %s is %s s behind the writer (aurora_replica_status%s; warning %s s, critical %s s, %s)', a.key, round(a.lag_secs::numeric, 1),
              CASE WHEN a.on_reader THEN ' read on a reader: no monitored writer reads this replica' ELSE '' END,
              coalesce(trim_scale(t.warn)::text, '-'), coalesce(trim_scale(t.crit)::text, '-'), t.level),
       1, 'the Aurora replica is behind the writer'
  FROM (SELECT r.*, EXISTS (SELECT 1 FROM pgvigil.pg_repl_standby_state st WHERE st.instance_id = r.instance_id AND st.in_recovery) AS on_reader
          FROM pgvigil.replication_latest r
          JOIN pgvigil.instances i ON i.instance_id = r.instance_id AND i.is_active
         WHERE r.kind = 'aurora_replica' AND r.snapshot_at > now() - interval '30 minutes' AND coalesce(r.state, '') <> 'MASTER_SESSION_ID') a
  CROSS JOIN LATERAL pgvigil.pg_threshold(a.instance_id, 'standby_replay_lag') t
 WHERE coalesce(t.warn, t.crit) IS NOT NULL AND a.lag_secs >= coalesce(t.warn, t.crit)
   AND (NOT a.on_reader
        OR (NOT EXISTS (SELECT 1 FROM pgvigil.replication_latest w
                          JOIN pgvigil.instances wi ON wi.instance_id = w.instance_id AND wi.is_active
                         WHERE w.kind = 'aurora_replica' AND w.key = a.key AND w.instance_id <> a.instance_id
                           AND w.snapshot_at > now() - interval '30 minutes'
                           AND NOT EXISTS (SELECT 1 FROM pgvigil.pg_repl_standby_state ws WHERE ws.instance_id = w.instance_id AND ws.in_recovery))
            AND NOT EXISTS (SELECT 1 FROM pgvigil.replication_latest o
                              JOIN pgvigil.instances oi ON oi.instance_id = o.instance_id AND oi.is_active
                              JOIN pgvigil.pg_repl_standby_state os ON os.instance_id = o.instance_id AND os.in_recovery
                             WHERE o.kind = 'aurora_replica' AND o.key = a.key AND o.instance_id < a.instance_id
                               AND o.snapshot_at > now() - interval '30 minutes')))
UNION ALL
-- task 375 (0150): the checks across a cluster's members
SELECT c.instance_id, c.severity, c.check_name, c.object, c.at, c.detail, c.reads, c.stable
  FROM pgvigil.pg_cluster_checks c;

DROP TRIGGER IF EXISTS replication_hourly_ins ON pgvigil.replication_sample;
CREATE TRIGGER replication_hourly_ins AFTER INSERT ON pgvigil.replication_sample
  REFERENCING NEW TABLE AS n FOR EACH STATEMENT EXECUTE FUNCTION pgvigil.replication_hourly_tg();
DROP TRIGGER IF EXISTS replication_hourly_del ON pgvigil.replication_sample;
CREATE TRIGGER replication_hourly_del AFTER DELETE ON pgvigil.replication_sample
  REFERENCING OLD TABLE AS n FOR EACH STATEMENT EXECUTE FUNCTION pgvigil.replication_hourly_tg();
