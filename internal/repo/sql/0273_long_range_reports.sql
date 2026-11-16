-- 0273_long_range_reports: B20's long-range reports (the lead 11-15 16:3x / 17:0x / 18:1x).
--   trend_series: the Trend report's reader (B20-1) - one series per instance (or per database of one instance) of a
--   metric over raw samples of both engines, a statistic inside each hour or day bucket. Raw only: B21's hours add
--   their arm in B21's reader slice (419), not here. The fleet file-IO window (the newest raw days the fleet latency
--   reads) is the handler's: it moves p_from; this function reads what it is given.
--   The metrics and their cells (the design's table, review-19's fold):
--     os_cpu       SQL Server 100 - mssql_cpu_sample.idle_pct; PostgreSQL host_sample.cpu_pct (system_stats or CloudWatch)
--     sql_cpu      SQL Server mssql_cpu_sample.sql_pct; PostgreSQL has none (the handler says so)
--     latency      SQL Server sum(stall) / sum(IO) over a sample's files (mssql_fileio_sample), per database with
--                  p_by = 'database'; PostgreSQL (read_time + write_time) / (reads + writes) of iostats_rate's deltas
--                  where track_io_timing is on, else CloudWatch Read / WriteLatency x 1000; a sample under 1 IO a
--                  second draws nothing (0031's floor)
--     active       SQL Server mssql_requests_summary.requests; PostgreSQL activity_summary.active
--     free_memory  a percent of the total: available_kb / physical_kb; (mem_free + mem_cache) / mem_total
--     connections  SQL Server mssql_session_summary sessions - background; PostgreSQL activity_summary.total
--   p_stat: p50 / p95 / p98 / p99 / max, or p5 / p2 / p1 / min (memory ranks lowest first); a percentile is
--   percentile_cont inside the bucket; p_hour keeps one hour of the day in p_tz; a bucket's 'at' is its start in p_tz.
--   One read gives both: a row per bucket, and a row with 'at' NULL per series - its statistic over every sample of
--   the range (the rank the top N orders by; GROUPING SETS, so the samples are read once).
--   B20-2, the stored weekly sp_Blitz (collection mssql_blitz, internal/mssql/blitz.go; off by default, D4):
--     mssql_blitz_site     one row: the site default (off), the weekly slot (a day and an hour in a zone), the timeout
--     mssql_blitz_setting  per instance: its own switch (NULL = the site default) and the database sp_Blitz is in
--     mssql_blitz_run      each run: when, how long, the kit's version, the login, the outcome (done, done with
--                          messages, refused, failed, timed out), its error and the server's messages
--     mssql_blitz_finding  a run's rows of sp_Blitz's result set (the query plan columns left out)
--     mssql_blitz_due      the due rule: on, and no run stored since the newest weekly slot in the site's zone (the
--                          collector's loops restart at every inventory change, so the rule reads the store, never a
--                          timer); the collector asks it hourly through import_mssql_blitz_plan
--   12 runs are kept per instance, and the newest successful one beside them: import_mssql_blitz deletes the older
--   runs in the transaction that stores a new one (no purge arm, so no joined object).

CREATE OR REPLACE FUNCTION pgvigil.trend_series(p_metric text, p_ids int[], p_from timestamptz, p_to timestamptz,
  p_bucket text, p_stat text, p_hour int, p_tz text, p_by text DEFAULT NULL)
RETURNS TABLE (instance_id int, database_name text, at timestamptz, v double precision, n int)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_frac double precision := CASE p_stat WHEN 'p50' THEN 0.5 WHEN 'p95' THEN 0.95 WHEN 'p98' THEN 0.98 WHEN 'p99' THEN 0.99
                                         WHEN 'max' THEN 1 WHEN 'p5' THEN 0.05 WHEN 'p2' THEN 0.02 WHEN 'p1' THEN 0.01 WHEN 'min' THEN 0 END;
  v_ids  text := 'AND ($1 IS NULL OR x.instance_id = ANY ($1))';
  v_t    text := 'x.snapshot_at > $2 AND x.snapshot_at <= $3';
  v_src  text;
BEGIN
  IF v_frac IS NULL THEN RAISE EXCEPTION 'stat must be p50, p95, p98, p99, max, p5, p2, p1 or min, not %', p_stat; END IF;
  IF p_bucket NOT IN ('hour', 'day') THEN RAISE EXCEPTION 'bucket must be hour or day, not %', p_bucket; END IF;
  IF p_hour IS NOT NULL AND (p_hour < 0 OR p_hour > 23) THEN RAISE EXCEPTION 'hour must be 0 to 23, not %', p_hour; END IF;
  PERFORM now() AT TIME ZONE p_tz;   -- an unknown zone is refused here, in PostgreSQL's words
  -- s: one row per sample (instance_id, database_name, at, v)
  v_src := CASE p_metric
    WHEN 'os_cpu' THEN format(
      'SELECT x.instance_id, NULL::text, x.snapshot_at, (100 - x.idle_pct)::float8 FROM pgvigil.mssql_cpu_sample x WHERE %1$s AND x.idle_pct IS NOT NULL %2$s
       UNION ALL SELECT x.instance_id, NULL, x.snapshot_at, x.cpu_pct::float8 FROM pgvigil.host_sample x WHERE %1$s AND x.cpu_pct IS NOT NULL %2$s', v_t, v_ids)
    WHEN 'sql_cpu' THEN format(
      'SELECT x.instance_id, NULL::text, x.snapshot_at, x.sql_pct::float8 FROM pgvigil.mssql_cpu_sample x WHERE %1$s %2$s', v_t, v_ids)
    WHEN 'latency' THEN format(
      'SELECT x.instance_id, %3$s, x.snapshot_at, sum(x.read_stall_ms + x.write_stall_ms)::float8 / sum(x.reads + x.writes)
         FROM pgvigil.mssql_fileio_sample x WHERE %1$s %2$s
        GROUP BY x.instance_id, %3$s, x.snapshot_at HAVING sum(x.reads + x.writes) / max(x.interval_secs) >= 1
       UNION ALL
       SELECT r.instance_id, NULL, r.snapshot_at, sum(r.read_time + r.write_time) / sum(r.reads + r.writes)
         FROM pgvigil.instances x JOIN pgvigil.instance_state st ON st.instance_id = x.instance_id AND st.track_io_timing = ''on''
        CROSS JOIN LATERAL pgvigil.iostats_rate(x.instance_id, $2, $3) r
        WHERE x.engine = ''postgres'' %2$s AND $4 IS NULL
        GROUP BY r.instance_id, r.snapshot_at HAVING sum(r.reads + r.writes) / max(r.interval_secs) >= 1
       UNION ALL
       SELECT x.instance_id, NULL, x.snapshot_at, avg(x.value) * 1000 FROM pgvigil.cloud_io_sample x
        WHERE %1$s %2$s AND $4 IS NULL AND x.metric IN (''ReadLatency'', ''WriteLatency'') AND x.value IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM pgvigil.instance_state st WHERE st.instance_id = x.instance_id AND st.track_io_timing = ''on'')
        GROUP BY x.instance_id, x.snapshot_at', v_t, v_ids, CASE WHEN p_by = 'database' THEN 'x.database_name' ELSE 'NULL::text' END)
    WHEN 'active' THEN format(
      'SELECT x.instance_id, NULL::text, x.snapshot_at, x.requests::float8 FROM pgvigil.mssql_requests_summary x WHERE %1$s %2$s
       UNION ALL SELECT x.instance_id, NULL, x.snapshot_at, x.active::float8 FROM pgvigil.activity_summary x WHERE %1$s AND x.active IS NOT NULL %2$s', v_t, v_ids)
    WHEN 'free_memory' THEN format(
      'SELECT x.instance_id, NULL::text, x.snapshot_at, 100.0 * x.available_kb / x.physical_kb FROM pgvigil.mssql_memory_sample x
        WHERE %1$s AND x.physical_kb > 0 AND x.available_kb IS NOT NULL %2$s
       UNION ALL SELECT x.instance_id, NULL, x.snapshot_at, 100.0 * (x.mem_free + coalesce(x.mem_cache, 0)) / x.mem_total FROM pgvigil.host_sample x
        WHERE %1$s AND x.mem_total > 0 AND x.mem_free IS NOT NULL %2$s', v_t, v_ids)
    WHEN 'connections' THEN format(
      'SELECT x.instance_id, NULL::text, x.snapshot_at, (x.sessions - coalesce(x.background, 0))::float8 FROM pgvigil.mssql_session_summary x
        WHERE %1$s AND x.sessions IS NOT NULL %2$s
       UNION ALL SELECT x.instance_id, NULL, x.snapshot_at, x.total::float8 FROM pgvigil.activity_summary x WHERE %1$s AND x.total IS NOT NULL %2$s', v_t, v_ids)
  END;
  IF v_src IS NULL THEN RAISE EXCEPTION 'metric must be os_cpu, sql_cpu, latency, active, free_memory or connections, not %', p_metric; END IF;
  IF p_by IS NOT NULL AND (p_by <> 'database' OR p_metric <> 'latency') THEN RAISE EXCEPTION 'by database is for the latency of one instance'; END IF;
  RETURN QUERY EXECUTE format(
    'SELECT s.iid, s.db, CASE WHEN GROUPING(s.bkt) = 0 THEN s.bkt AT TIME ZONE $5 END, percentile_cont($6) WITHIN GROUP (ORDER BY s.v), count(*)::int
       FROM (SELECT s0.iid, s0.db, s0.v, date_trunc(%L, s0.at AT TIME ZONE $5) AS bkt
               FROM (%s) s0 (iid, db, at, v)
              WHERE $7 IS NULL OR extract(hour FROM s0.at AT TIME ZONE $5) = $7) s
      GROUP BY GROUPING SETS ((s.iid, s.db, s.bkt), (s.iid, s.db))', p_bucket, v_src)
    USING p_ids, p_from, p_to, p_by, p_tz, v_frac, p_hour;
END $$;
COMMENT ON FUNCTION pgvigil.trend_series(text, int[], timestamptz, timestamptz, text, text, int, text, text) IS
  'B20-1: the Trend report''s reader over raw samples of both engines (0273''s header says each metric''s cells).';

-- ---- B20-2: the stored weekly sp_Blitz ------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_blitz_site (
  one         boolean PRIMARY KEY DEFAULT true CHECK (one),
  enabled     boolean NOT NULL DEFAULT false,
  run_dow     smallint NOT NULL DEFAULT 0 CHECK (run_dow BETWEEN 0 AND 6),     -- 0 = Sunday, as extract(dow)
  run_hour    smallint NOT NULL DEFAULT 2 CHECK (run_hour BETWEEN 0 AND 23),
  run_tz      text NOT NULL DEFAULT 'UTC',
  timeout_s   int NOT NULL DEFAULT 600 CHECK (timeout_s BETWEEN 1 AND 1800),  -- sp_Blitz's own statement
  updated_at  timestamptz,
  updated_by  text
);
INSERT INTO pgvigil.mssql_blitz_site DEFAULT VALUES ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_blitz_setting (
  instance_id int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  enabled     boolean,                                   -- NULL = the site default
  proc_db     text NOT NULL DEFAULT 'master' CHECK (length(proc_db) BETWEEN 1 AND 128 AND proc_db !~ '[[:cntrl:]]'),
  updated_at  timestamptz NOT NULL,
  updated_by  text NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_blitz_run (
  run_id           bigserial PRIMARY KEY,
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  started_at       timestamptz NOT NULL,
  seconds          numeric(9,1),
  outcome          text NOT NULL CHECK (outcome IN ('done', 'done with messages', 'refused', 'failed', 'timed out')),
  error            text,                                 -- why a run refused, failed or timed out
  frk_version      text,                                 -- sp_Blitz's @Version, read with @VersionCheckMode = 1
  frk_version_date date,
  login            text,
  proc_db          text,
  messages         jsonb NOT NULL DEFAULT '[]',          -- the server's messages: number, severity, state, line, proc, message
  findings         int NOT NULL DEFAULT 0,
  UNIQUE (instance_id, started_at)
);
CREATE INDEX IF NOT EXISTS mssql_blitz_run_inst ON pgvigil.mssql_blitz_run (instance_id, started_at DESC);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_blitz_finding (
  run_id          bigint NOT NULL REFERENCES pgvigil.mssql_blitz_run(run_id) ON DELETE CASCADE,
  n               int NOT NULL,                          -- the row's place in sp_Blitz's own order
  check_id        int,
  priority        int,
  findings_group  text,
  finding         text,
  database_name   text,
  url             text,
  details         text,
  PRIMARY KEY (run_id, n)
);

-- mssql_blitz_due: whether the weekly run of an instance is due at p_now, in words. 'off' (its own switch, else the
-- site default; and an id that is no SQL Server instance), 'not due' (a run is stored since the newest slot: <day>
-- <hour>:00 in the site's zone, at or before p_now as an instant - an hour that happens twice when the clocks go back
-- counts once: PostgreSQL reads that local time as its second occurrence, standard time, and the slot is that instant:
-- review-22 bzstore SF1) or 'due' (a switch just turned on is
-- due at its next hourly look). A run of any outcome counts: a refused or timed-out run is not retried before the next
-- slot. The collector asks with its run's own start (import_mssql_blitz_plan), the instant it stores the run under.
CREATE OR REPLACE FUNCTION pgvigil.mssql_blitz_due(p_instance_id int, p_now timestamptz DEFAULT now())
RETURNS TABLE (state text, why text, enabled boolean, own_switch boolean, site_enabled boolean, proc_db text,
               timeout_s int, run_dow int, run_hour int, run_tz text, slot_at timestamptz, next_at timestamptz,
               last_run_at timestamptz)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE
  s       record;
  v_own   boolean;
  v_db    text;
  v_local timestamp;
  v_slot  timestamp;
  v_when  text;
  v_eng   text;
  v_name  text;
  v_days  CONSTANT text[] := ARRAY['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
BEGIN
  SELECT x.enabled, x.run_dow, x.run_hour, x.run_tz, x.timeout_s INTO s FROM pgvigil.mssql_blitz_site x LIMIT 1;
  IF NOT FOUND THEN
    SELECT false AS enabled, 0 AS run_dow, 2 AS run_hour, 'UTC'::text AS run_tz, 600 AS timeout_s INTO s;
  END IF;
  SELECT b.enabled, b.proc_db INTO v_own, v_db FROM pgvigil.mssql_blitz_setting b WHERE b.instance_id = p_instance_id;
  v_local := p_now AT TIME ZONE s.run_tz;
  v_slot := date_trunc('day', v_local) - make_interval(days => (extract(dow FROM v_local)::int - s.run_dow + 7) % 7)
            + make_interval(hours => s.run_hour);
  IF (v_slot AT TIME ZONE s.run_tz) > p_now THEN
    v_slot := v_slot - interval '7 days';
  END IF;
  v_when := v_days[s.run_dow + 1] || ' ' || lpad(s.run_hour::text, 2, '0') || ':00 ' || s.run_tz;
  enabled := coalesce(v_own, s.enabled);
  own_switch := v_own IS NOT NULL;
  site_enabled := s.enabled;
  proc_db := coalesce(v_db, 'master');
  timeout_s := s.timeout_s;
  run_dow := s.run_dow;
  run_hour := s.run_hour;
  run_tz := s.run_tz;
  slot_at := v_slot AT TIME ZONE s.run_tz;
  next_at := (v_slot + interval '7 days') AT TIME ZONE s.run_tz;
  SELECT max(r.started_at) INTO last_run_at FROM pgvigil.mssql_blitz_run r WHERE r.instance_id = p_instance_id;
  SELECT i.engine, i.name INTO v_eng, v_name FROM pgvigil.instances i WHERE i.instance_id = p_instance_id;
  IF v_name IS NULL OR v_eng IS DISTINCT FROM 'sqlserver' THEN
    state := 'off';
    enabled := false;
    why := CASE WHEN v_name IS NULL THEN 'no instance ' || coalesce(p_instance_id::text, '(none)')
                ELSE v_name || ' is not a SQL Server instance: sp_Blitz is SQL Server''s' END;
  ELSIF NOT enabled THEN
    state := 'off';
    why := CASE WHEN v_own IS NOT NULL
                THEN 'the weekly sp_Blitz is off for this instance (its own switch; the site default is '
                     || CASE WHEN s.enabled THEN 'on' ELSE 'off' END || ')'
                ELSE 'the weekly sp_Blitz is off for this instance (the site default is off; an admin turns it on for'
                     || ' the instance or the site on the instance''s Findings tab)' END;
  ELSIF last_run_at IS NOT NULL AND last_run_at >= slot_at THEN
    state := 'not due';
    why := 'not due yet: this week''s run started ' || to_char(last_run_at AT TIME ZONE s.run_tz, 'YYYY-MM-DD HH24:MI')
           || ' ' || s.run_tz || '; the next is due ' || to_char(v_slot + interval '7 days', 'YYYY-MM-DD HH24:MI') || ' '
           || s.run_tz || ' (every ' || v_when || ')';
  ELSIF last_run_at IS NULL THEN
    state := 'due';
    why := 'due: no run is stored yet - the first runs at the next hourly look, then every ' || v_when;
  ELSE
    state := 'due';
    why := 'due: no run since ' || to_char(v_slot, 'YYYY-MM-DD HH24:MI') || ' ' || s.run_tz || ' (every ' || v_when || ')';
  END IF;
  RETURN NEXT;
END $$;
COMMENT ON FUNCTION pgvigil.mssql_blitz_due(int, timestamptz) IS
  'B20-2: whether an instance''s weekly sp_Blitz is due now, with its words (the page''s and the collector''s one rule).';

-- import_mssql_blitz_plan: the collector's question before a run (apply_roles makes an import_ function its door), at
-- p_at - the run's own start, the instant its run is stored under, so the question and the stored time share one clock
-- (review-22 bzstore SF2): the state, its words, the database sp_Blitz is looked for in and the statement's timeout.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_blitz_plan(p_instance_id int, p_at timestamptz)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('state', d.state, 'why', d.why, 'proc_db', d.proc_db, 'timeout_s', d.timeout_s)
    FROM pgvigil.mssql_blitz_due(p_instance_id, p_at) d
$$;

-- import_mssql_blitz: one run. Rows: 'run' {outcome, seconds, error, frk_version, frk_version_date (YYYYMMDD), login,
-- proc_db}; 'msg' {n, number, severity, state, line, proc, message}; 'finding' {n, check_id, priority, findings_group,
-- finding, database_name, url, message (sp_Blitz's Details: under 'message' so the credential mask reads it)}; a
-- 'collector_error' row is the run's note, not stored here. The same read twice stores one run. Then the 12 newest runs
-- of the instance are kept, and the newest successful one beside them.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_blitz(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  r      jsonb;
  v_msgs jsonb;
  v_run  bigint;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_blitz: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_blitz'), p_instance_id);
  SELECT x INTO r FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'run' LIMIT 1;
  IF r IS NULL THEN
    RETURN;
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('number', (x->>'number')::int, 'severity', (x->>'severity')::int,
                                               'state', (x->>'state')::int, 'line', (x->>'line')::int,
                                               'proc', x->>'proc', 'message', x->>'message')
                            ORDER BY (x->>'n')::int), '[]'::jsonb)
    INTO v_msgs
    FROM jsonb_array_elements(p_payload) x
   WHERE x->>'kind' = 'msg';
  INSERT INTO pgvigil.mssql_blitz_run (instance_id, started_at, seconds, outcome, error, frk_version, frk_version_date,
                                       login, proc_db, messages, findings)
  VALUES (p_instance_id, p_snapshot_at, (r->>'seconds')::numeric(9,1), r->>'outcome', r->>'error', r->>'frk_version',
          CASE WHEN r->>'frk_version_date' ~ '^[0-9]{8}$' THEN to_date(r->>'frk_version_date', 'YYYYMMDD') END,
          r->>'login', r->>'proc_db', v_msgs,
          (SELECT count(*) FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'finding'))
  ON CONFLICT (instance_id, started_at) DO NOTHING
  RETURNING run_id INTO v_run;
  IF v_run IS NULL THEN
    RETURN;  -- the same read twice
  END IF;
  INSERT INTO pgvigil.mssql_blitz_finding (run_id, n, check_id, priority, findings_group, finding, database_name, url, details)
  SELECT v_run, (x->>'n')::int, (x->>'check_id')::int, (x->>'priority')::int, x->>'findings_group', x->>'finding',
         x->>'database_name', x->>'url', x->>'message'
    FROM jsonb_array_elements(p_payload) x
   WHERE x->>'kind' = 'finding' AND x->>'n' IS NOT NULL
  ON CONFLICT (run_id, n) DO NOTHING;
  UPDATE pgvigil.mssql_blitz_run SET findings = (SELECT count(*) FROM pgvigil.mssql_blitz_finding f WHERE f.run_id = v_run)
   WHERE run_id = v_run;
  DELETE FROM pgvigil.mssql_blitz_run d
   WHERE d.instance_id = p_instance_id
     AND d.run_id NOT IN (SELECT k.run_id FROM pgvigil.mssql_blitz_run k WHERE k.instance_id = p_instance_id
                           ORDER BY k.started_at DESC, k.run_id DESC LIMIT 12)
     AND d.run_id IS DISTINCT FROM (SELECT g.run_id FROM pgvigil.mssql_blitz_run g
                                     WHERE g.instance_id = p_instance_id AND g.outcome IN ('done', 'done with messages')
                                     ORDER BY g.started_at DESC, g.run_id DESC LIMIT 1);
END $$;

-- import_mssql_blitz_setting: the admin's switch (POST /api/mssql/blitz/settings; the role is checked before it is
-- called). Ops: 'site' {enabled, run_dow, run_hour, run_tz, timeout_s}; 'instance' {instance_id, enabled (true, false,
-- or null = the site default), proc_db}; a key left out keeps its value (proc_db master at first). Every value is
-- checked as jsonb before it is cast, so a direct caller is refused in words, never with a cast error (review-22
-- bzstore NIT5); every attempt that reaches the function is written to admin_audit, done or refused; the answer is
-- {outcome, detail}.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_blitz_setting(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user   text := nullif(p_payload->>'ui_user', '');
  v_client text := p_payload->>'client';
  v_op     text := p_payload->>'op';
  v_why    text;
  v_target text;
  v_detail text;
  v_id     int;
  v_name   text;
  v_engine text;
  v_db     text;
  v_en     boolean;
  v_dow    int;
  v_hour   int;
  v_tz     text;
  v_to     int;
  s        record;
  b        record;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_mssql_blitz_setting: no ui_user' USING ERRCODE = '22023';
  END IF;
  v_target := coalesce(v_op, '(none)');
  -- the types first: booleans, whole numbers that fit an int, texts
  v_why := CASE
    WHEN v_op IS NULL OR v_op NOT IN ('site', 'instance') THEN 'op is site or instance, not ' || coalesce(v_op, '(none)')
    WHEN p_payload ? 'enabled' AND jsonb_typeof(p_payload->'enabled') <> 'boolean'
         AND NOT (v_op = 'instance' AND jsonb_typeof(p_payload->'enabled') = 'null')
      THEN CASE WHEN v_op = 'site' THEN 'enabled is true or false' ELSE 'enabled is true, false or null (the site default)' END
    WHEN EXISTS (SELECT 1 FROM unnest(ARRAY['run_dow', 'run_hour', 'timeout_s', 'instance_id']) k
                  WHERE p_payload ? k AND (jsonb_typeof(p_payload->k) <> 'number' OR (p_payload->>k) !~ '^-?[0-9]{1,9}$'))
      THEN 'run_dow, run_hour, timeout_s and instance_id are whole numbers'
    WHEN EXISTS (SELECT 1 FROM unnest(ARRAY['run_tz', 'proc_db']) k WHERE p_payload ? k AND jsonb_typeof(p_payload->k) <> 'string')
      THEN 'run_tz and proc_db are texts'
  END;
  IF v_why IS NULL AND v_op = 'site' THEN
    SELECT x.enabled, x.run_dow, x.run_hour, x.run_tz, x.timeout_s INTO s FROM pgvigil.mssql_blitz_site x FOR UPDATE;
    v_target := 'site';
    v_en := CASE WHEN p_payload ? 'enabled' THEN (p_payload->>'enabled')::boolean ELSE s.enabled END;
    v_dow := CASE WHEN p_payload ? 'run_dow' THEN (p_payload->>'run_dow')::int ELSE s.run_dow END;
    v_hour := CASE WHEN p_payload ? 'run_hour' THEN (p_payload->>'run_hour')::int ELSE s.run_hour END;
    v_tz := CASE WHEN p_payload ? 'run_tz' THEN p_payload->>'run_tz' ELSE s.run_tz END;
    v_to := CASE WHEN p_payload ? 'timeout_s' THEN (p_payload->>'timeout_s')::int ELSE s.timeout_s END;
    v_why := CASE
      WHEN v_dow NOT BETWEEN 0 AND 6 THEN 'run_dow is a day of the week, 0 (Sunday) to 6 (Saturday)'
      WHEN v_hour NOT BETWEEN 0 AND 23 THEN 'run_hour is an hour of the day, 0 to 23'
      WHEN v_tz IS NULL OR NOT EXISTS (SELECT 1 FROM pg_timezone_names z WHERE z.name = v_tz)
        THEN coalesce(v_tz, 'the zone') || ' is not a time zone PostgreSQL knows (pg_timezone_names: UTC, Europe/London, America/New_York ...)'
      WHEN v_to NOT BETWEEN 1 AND 1800 THEN 'timeout_s is 1 to 1800 seconds'
    END;
    IF v_why IS NULL THEN
      UPDATE pgvigil.mssql_blitz_site
         SET enabled = v_en, run_dow = v_dow, run_hour = v_hour, run_tz = v_tz, timeout_s = v_to, updated_at = p_at, updated_by = v_user;
      v_detail := 'the site default ' || CASE WHEN v_en THEN 'on' ELSE 'off' END || ', every '
                  || (ARRAY['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'])[v_dow + 1]
                  || ' ' || lpad(v_hour::text, 2, '0') || ':00 ' || v_tz || ', a ' || v_to || ' s timeout';
    END IF;
  ELSIF v_why IS NULL AND v_op = 'instance' THEN
    v_id := (p_payload->>'instance_id')::int;
    SELECT i.name, i.engine INTO v_name, v_engine FROM pgvigil.instances i WHERE i.instance_id = v_id;
    v_target := coalesce(v_name, 'instance ' || coalesce(v_id::text, '(none)'));
    SELECT x.enabled, x.proc_db INTO b FROM pgvigil.mssql_blitz_setting x WHERE x.instance_id = v_id;
    -- a key left out keeps the stored value: a write that only moves sp_Blitz's database keeps the switch
    v_en := CASE WHEN p_payload ? 'enabled' THEN (p_payload->>'enabled')::boolean ELSE b.enabled END;
    v_db := CASE WHEN p_payload ? 'proc_db' THEN p_payload->>'proc_db' ELSE coalesce(b.proc_db, 'master') END;
    v_why := CASE
      WHEN v_id IS NULL OR v_name IS NULL THEN 'no instance ' || coalesce(v_id::text, '(none named)')
      WHEN v_engine IS DISTINCT FROM 'sqlserver' THEN v_name || ' is not a SQL Server instance: sp_Blitz is SQL Server''s'
      WHEN v_db IS NULL OR length(v_db) NOT BETWEEN 1 AND 128 OR v_db ~ '[[:cntrl:]]'
        THEN 'the database sp_Blitz is in is a name of 1 to 128 characters'
    END;
    IF v_why IS NULL THEN
      INSERT INTO pgvigil.mssql_blitz_setting AS t (instance_id, enabled, proc_db, updated_at, updated_by)
      VALUES (v_id, v_en, v_db, p_at, v_user)
      ON CONFLICT (instance_id) DO UPDATE
         SET enabled = EXCLUDED.enabled, proc_db = EXCLUDED.proc_db, updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by;
      v_detail := v_name || ': ' || CASE v_en WHEN true THEN 'on' WHEN false THEN 'off' ELSE 'the site default' END
                  || ', sp_Blitz in ' || v_db;
    END IF;
  END IF;
  INSERT INTO pgvigil.admin_audit (at, ui_user, client, op, target, outcome, detail)
  VALUES (p_at, v_user, v_client, 'mssql_blitz_' || coalesce(v_op, 'unknown'), v_target,
          CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, coalesce(v_why, v_detail));
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, 'detail', coalesce(v_why, v_detail));
END $$;

-- ---- B20-4 the daily fleet health (the lead 11-15 16:3x D5 (a)): the Daily checks mail also posts its counts --------
-- The kept schedule names webhook channels (post_channels: pgvigil.yaml's reports.daily_checks post: list, or the Daily
-- checks page's dialog). Its scheduled turn carries the drawn page's numbers (the render's post: web/src/checksorder.ts
-- dailyPost) onto the send row; the sender, after the mail is recorded sent, takes the post once (report_mail_post_take:
-- a failed mail is never taken; the second turn of the same day in the schedule's zone is refused by the index) and
-- records its answer (report_mail_post_record: posted_at, or post_error and a 'daily checks post failed' notice).
-- import_report_mail_kept (0258's) and import_report_mail_send (0107's) are re-created whole with the lines marked B20-4.
ALTER TABLE pgvigil.report_mail_schedules ADD COLUMN IF NOT EXISTS post_channels text[];
ALTER TABLE pgvigil.report_mail_sends
  ADD COLUMN IF NOT EXISTS post jsonb CHECK (post IS NULL OR octet_length(post::text) <= 4096),
  ADD COLUMN IF NOT EXISTS post_channels text[],
  ADD COLUMN IF NOT EXISTS post_day date,
  ADD COLUMN IF NOT EXISTS post_taken_at timestamptz,
  ADD COLUMN IF NOT EXISTS posted_at timestamptz,
  ADD COLUMN IF NOT EXISTS post_error text;
CREATE UNIQUE INDEX IF NOT EXISTS report_mail_sends_post_day_idx ON pgvigil.report_mail_sends (schedule_id, post_day)
  WHERE post_taken_at IS NOT NULL;
GRANT UPDATE (post_taken_at, posted_at, post_error) ON pgvigil.report_mail_sends TO pgvigil_alerter;

-- import_report_mail_kept: 0258's, whole, with B20-4's post_channels (payload post_channels: a list of names; each a
-- configured webhook channel of alert_channels, refused in words otherwise; part of 'unchanged')
CREATE OR REPLACE FUNCTION pgvigil.import_report_mail_kept(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      text := p_payload->>'op';
  v_by      text := p_payload->>'by';
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_kept    text := coalesce(nullif(p_payload->>'kept_as', ''), 'daily_checks');
  v_as      text := lower(nullif(btrim(coalesce(p_payload->>'as', '')), ''));
  v_chan    text := nullif(btrim(coalesce(p_payload->>'channel', '')), '');
  v_cron    text := btrim(coalesce(p_payload->>'cron', ''));
  v_tz      text := nullif(btrim(coalesce(p_payload->>'timezone', '')), '');
  v_xlsx    boolean := coalesce((p_payload->>'attach_xlsx')::boolean, true);
  v_name    text;
  v_route   text;
  v_rcpt    text[];
  v_next    timestamptz;
  v_id      bigint;
  v_old     pgvigil.report_mail_schedules;
  v_why     text;
  v_done    text;
  v_moved   boolean;
  v_post    text[];   -- B20-4: the webhook channels the counts are posted to ('{}' = no post)
  v_bad     text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_report_mail_kept: no ui_user' USING ERRCODE = '22023';
  END IF;
  v_name := pgvigil.report_mail_kept_name(v_kept);
  v_route := pgvigil.report_mail_kept_route(v_kept);
  IF jsonb_typeof(p_payload->'recipients') = 'array' THEN
    SELECT array_agg(lower(btrim(r)) ORDER BY o) INTO v_rcpt FROM jsonb_array_elements_text(p_payload->'recipients') WITH ORDINALITY AS a(r, o);
  END IF;
  IF jsonb_typeof(p_payload->'post_channels') = 'array' THEN
    SELECT coalesce(array_agg(DISTINCT btrim(r) ORDER BY btrim(r)) FILTER (WHERE btrim(r) <> ''), '{}') INTO v_post
      FROM jsonb_array_elements_text(p_payload->'post_channels') AS a(r);
  END IF;
  v_post := coalesce(v_post, '{}');
  IF coalesce(p_payload->>'next_at', '') <> '' THEN
    BEGIN
      v_next := (p_payload->>'next_at')::timestamptz;
    EXCEPTION WHEN others THEN
      v_why := 'next_at is not a time';
    END;
  END IF;

  IF v_why IS NOT NULL THEN
    NULL;
  ELSIF v_name IS NULL THEN
    v_why := format('%s is not a kept schedule (daily_checks)', v_kept);
  ELSIF v_op NOT IN ('keep', 'drop') OR v_op IS NULL THEN
    v_why := format('op %s is not keep or drop', coalesce(v_op, '(none)'));
  ELSIF v_by NOT IN ('file', 'page') OR v_by IS NULL THEN
    v_why := format('by %s is not file or page', coalesce(v_by, '(none)'));
  END IF;

  IF v_why IS NULL THEN
    -- one writer at a time per kept schedule: the second waits and then reads what the first wrote
    PERFORM pg_advisory_xact_lock(hashtextextended('pgvigil.report_mail_kept:' || v_kept, 0));
    SELECT * INTO v_old FROM pgvigil.report_mail_schedules WHERE kept_as = v_kept AND ended_at IS NULL FOR UPDATE;
    v_id := v_old.schedule_id;
    IF v_by = 'page' AND v_old.kept_by = 'file' THEN
      v_why := 'the Daily checks mail is kept by pgvigil.yaml (reports.daily_checks): change it there';
    ELSIF v_op = 'drop' THEN
      IF v_old.schedule_id IS NULL THEN
        RETURN jsonb_build_object('outcome', 'unchanged', 'detail', 'no Daily checks mail is kept', 'schedule_id', NULL);
      END IF;
      UPDATE pgvigil.report_mail_schedules
         SET enabled = false, claimed_until = NULL, claim_token = NULL, ended_by = left(v_user, 200), ended_at = p_at
       WHERE schedule_id = v_id;
      v_done := format('schedule %s ended: the Daily checks mail is off', v_id);
    ELSE
      IF v_as IS NULL THEN
        v_why := 'the Daily checks mail needs the UI user its page is drawn as';
      ELSE
        v_why := pgvigil.report_mail_why(v_name, v_route, v_rcpt, v_chan, v_tz);
      END IF;
      IF v_why IS NULL AND v_tz IS NULL THEN
        v_why := 'the Daily checks mail needs its time zone';
      ELSIF v_why IS NULL AND v_cron !~ '^([0-9]|[1-5][0-9]) ([0-9]|1[0-9]|2[0-3]) [*] [*] [*]$' THEN
        -- a minute 0-59 and an hour 0-23 as the server writes them (no leading zero): equal settings compare equal
        v_why := 'the Daily checks mail is sent once a day: its cron line is M H * * * (a minute 0-59, an hour 0-23)';
      END IF;
      -- B20-4: each post channel is a webhook channel the sender records (alert_channels), never an application's route
      IF v_why IS NULL THEN
        SELECT min(p) INTO v_bad FROM unnest(v_post) AS p
         WHERE NOT EXISTS (SELECT 1 FROM pgvigil.alert_channels c WHERE c.name = p AND c.kind = 'webhook' AND c.is_configured AND c.name NOT LIKE 'contact-%');
        IF v_bad IS NOT NULL THEN
          v_why := format('post: %s is not a webhook channel the sender records (alerts:): the counts could not be posted there', v_bad);
        END IF;
      END IF;
      IF v_why IS NULL AND v_old.schedule_id IS NOT NULL
         AND v_old.recipients = v_rcpt AND v_old.channel = v_chan AND v_old.cron = v_cron AND v_old.timezone = v_tz
         AND v_old.created_by = v_as AND v_old.kept_by = v_by AND v_old.attach_xlsx = v_xlsx AND v_old.enabled
         AND v_old.route = v_route AND v_old.name = v_name AND coalesce(v_old.post_channels, '{}') = v_post THEN
        RETURN jsonb_build_object('outcome', 'unchanged',
                                  'detail', format('schedule %s is as asked, next send %s', v_id, v_old.next_at), 'schedule_id', v_id);
      END IF;
      -- the next send moves only with the hour or the zone (or on a row that has none): other changes keep the turn
      v_moved := v_old.schedule_id IS NULL OR v_old.next_at IS NULL OR NOT v_old.enabled
                 OR v_old.cron IS DISTINCT FROM v_cron OR v_old.timezone IS DISTINCT FROM v_tz;
      IF v_why IS NULL AND v_moved AND (v_next IS NULL OR v_next <= p_at) THEN
        v_why := 'the next send must be in the future';
      END IF;
      IF v_why IS NULL AND v_old.schedule_id IS NULL THEN
        BEGIN
          INSERT INTO pgvigil.report_mail_schedules (name, route, page, recipients, channel, cadence, cron, timezone, attach_xlsx,
                                                     enabled, next_at, created_by, created_at, client, kept_as, kept_by, post_channels)
          VALUES (v_name, v_route, v_name, v_rcpt, v_chan, 'daily', v_cron, v_tz, v_xlsx, true, v_next,
                  left(v_as, 200), p_at, left(v_client, 100), v_kept, v_by, nullif(v_post, '{}'))
          RETURNING schedule_id INTO v_id;
          v_done := format('schedule %s kept: %s, drawn as %s, next send %s', v_id, v_name, v_as, v_next);
        EXCEPTION WHEN unique_violation THEN
          v_why := 'another live Daily checks mail exists: nothing was written';
        END;
      ELSIF v_why IS NULL THEN
        UPDATE pgvigil.report_mail_schedules
           SET name = v_name, route = v_route, page = v_name, recipients = v_rcpt, channel = v_chan, cadence = 'daily', cron = v_cron,
               timezone = v_tz, attach_xlsx = v_xlsx, enabled = true, next_at = CASE WHEN v_moved THEN v_next ELSE next_at END,
               created_by = left(v_as, 200), kept_by = v_by, claimed_until = NULL, claim_token = NULL, post_channels = nullif(v_post, '{}'),
               changed_by = left(v_user, 200), changed_at = p_at
         WHERE schedule_id = v_id;
        v_done := format('schedule %s changed: drawn as %s, next send %s', v_id, v_as,
                         CASE WHEN v_moved THEN v_next ELSE v_old.next_at END);
      END IF;
    END IF;
  END IF;
  INSERT INTO pgvigil.report_mail_log (at, ui_user, client, op, schedule_id, outcome, detail, payload)
  VALUES (p_at, left(v_user, 200), left(v_client, 100), left(coalesce(v_op, ''), 20), v_id,
          CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, left(coalesce(v_why, v_done), 2000),
          p_payload - 'ui_user' - 'client');
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, v_done), 'schedule_id', v_id);
END $$;

-- import_report_mail_send: 0107's, whole, with B20-4's post (payload post: the drawn page's numbers, an object of at
-- most 4 KB) stored on a kept schedule's scheduled turn that has post channels
CREATE OR REPLACE FUNCTION pgvigil.import_report_mail_send(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_kind    text := p_payload->>'kind';
  v_name    text := btrim(coalesce(p_payload->>'name', ''));
  v_route   text := p_payload->>'route';
  v_chan    text := nullif(btrim(coalesce(p_payload->>'channel', '')), '');
  v_subject text := btrim(coalesce(p_payload->>'subject', ''));
  v_html    text := p_payload->>'html';
  v_b64     text := nullif(p_payload->>'xlsx', '');
  v_xname   text := left(nullif(btrim(coalesce(p_payload->>'xlsx_name', '')), ''), 200);
  v_rerr    text := left(nullif(btrim(coalesce(p_payload->>'render_error', '')), ''), 2000);
  v_grids   int;
  v_rows    int;
  v_xlsx    bytea;
  v_rcpt    text[];
  v_next    timestamptz;
  v_sid     bigint;
  v_sched   pgvigil.report_mail_schedules;
  v_why     text;
  v_id      bigint;
  v_n       int;
  v_moved   boolean := false;
  v_post    jsonb := CASE WHEN jsonb_typeof(p_payload->'post') = 'object' AND octet_length((p_payload->'post')::text) <= 4096 THEN p_payload->'post' END;
  v_pchan   text[];   -- B20-4: the kept schedule's post channels, copied onto its turn
  v_pday    date;
  v_perr    text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_report_mail_send: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_payload->'recipients') = 'array' THEN
    SELECT array_agg(lower(btrim(r)) ORDER BY o) INTO v_rcpt FROM jsonb_array_elements_text(p_payload->'recipients') WITH ORDINALITY AS a(r, o);
  END IF;
  IF coalesce(p_payload->>'grids', '') ~ '^[0-9]{1,6}$' THEN v_grids := (p_payload->>'grids')::int; END IF;
  IF coalesce(p_payload->>'rows', '') ~ '^[0-9]{1,9}$' THEN v_rows := (p_payload->>'rows')::int; END IF;
  IF coalesce(p_payload->>'schedule_id', '') ~ '^[0-9]{1,18}$' THEN
    v_sid := (p_payload->>'schedule_id')::bigint;
    SELECT * INTO v_sched FROM pgvigil.report_mail_schedules WHERE schedule_id = v_sid FOR UPDATE;
  END IF;
  IF coalesce(p_payload->>'next_at', '') <> '' THEN
    BEGIN
      v_next := (p_payload->>'next_at')::timestamptz;
    EXCEPTION WHEN others THEN
      v_why := 'next_at is not a time';
    END;
  END IF;
  IF v_b64 IS NOT NULL THEN
    BEGIN
      v_xlsx := decode(v_b64, 'base64');
    EXCEPTION WHEN others THEN
      v_why := coalesce(v_why, 'the workbook is not base64');
    END;
  END IF;

  IF v_why IS NOT NULL THEN
    NULL;
  ELSIF v_kind IS NULL OR v_kind NOT IN ('now', 'scheduled', 'test') THEN
    v_why := format('kind %s is not now, scheduled or test', coalesce(v_kind, '(none)'));
  ELSIF v_kind <> 'now' AND v_sched.schedule_id IS NULL THEN
    v_why := format('no schedule %s', coalesce(p_payload->>'schedule_id', '(none)'));
  ELSIF v_kind <> 'now' AND v_sched.ended_at IS NOT NULL THEN
    v_why := format('schedule %s was ended by %s at %s', v_sid, v_sched.ended_by, v_sched.ended_at);
  ELSIF v_kind = 'scheduled' AND (v_sched.claim_token IS NULL OR v_sched.claim_token IS DISTINCT FROM nullif(p_payload->>'claim', '') OR NOT v_sched.enabled) THEN
    v_why := format('schedule %s''s turn was no longer this server''s (changed, turned off or claimed again while its page was drawn): not mailed', v_sid);
  ELSIF v_kind = 'scheduled' AND (v_next IS NULL OR v_next <= p_at) THEN
    v_why := 'a scheduled send names the turn after it (next_at, in the future)';
  END IF;
  IF v_why IS NULL AND v_kind = 'scheduled' THEN
    -- a turn is mailed or refused once: the schedule moves on either way
    UPDATE pgvigil.report_mail_schedules SET next_at = v_next, claimed_until = NULL, claim_token = NULL WHERE schedule_id = v_sid;
    v_moved := true;
  END IF;
  IF v_why IS NULL THEN
    v_why := pgvigil.report_mail_why(v_name, v_route, v_rcpt, v_chan, NULL);
  END IF;
  IF v_why IS NULL AND v_rerr IS NULL THEN
    IF length(v_subject) NOT BETWEEN 1 AND 200 OR v_subject ~ '[\r\n]' THEN
      v_why := 'a subject of 1 to 200 characters on one line is required';
    ELSIF v_html IS NULL OR length(v_html) < 20 THEN
      v_why := 'the mail has no body: the page drew no grid';
    ELSIF octet_length(v_html) > 4194304 THEN
      v_why := format('the page''s grids make a mail body of %s MB, over the 4 MB a mail carries: narrow the window or filter the grid', round(octet_length(v_html) / 1048576.0, 1));
    ELSIF v_html ~* '<\s*(script|iframe|object|embed|form|link|style|base|svg|math|img|a|meta\s+http-equiv)\M' OR v_html ~* '<[^>]*[\s/"'']on[a-z]+\s*=' OR v_html ~* '<[^>]*(java|vb)\s*script' OR v_html ~* '<[^>]*&#' THEN
      v_why := 'the mail body holds active content (a script, a frame, a form or an event attribute): refused';
    ELSIF v_xlsx IS NOT NULL AND octet_length(v_xlsx) > 8388608 THEN
      v_why := format('the workbook is %s MB, over the 8 MB a mail carries', round(octet_length(v_xlsx) / 1048576.0, 1));
    ELSIF v_xlsx IS NOT NULL AND substr(v_xlsx, 1, 4) <> '\x504b0304'::bytea THEN
      v_why := 'the workbook is not a zip (.xlsx)';
    END IF;
  END IF;
  -- a scheduled turn the checks refuse is queued as a failed render: the sender records it failed and alerts
  IF v_moved AND v_why IS NOT NULL THEN
    v_rerr := left(coalesce(v_rerr || '; ', '') || v_why, 2000);
    v_why := NULL;
  END IF;
  IF v_why IS NULL AND v_kind IN ('now', 'test') THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('pgvigil.report_mail_sends:' || v_user, 0));
    SELECT count(*) INTO v_n FROM pgvigil.report_mail_sends s
     WHERE s.requested_by = v_user AND s.kind IN ('now', 'test') AND s.outcome IS DISTINCT FROM 'refused'
       AND s.requested_at > p_at - interval '1 hour';
    IF v_n >= pgvigil.report_mail_hourly_cap() THEN
      v_why := format('%s asked %s mails in the last hour: at most %s an hour', v_user, v_n, pgvigil.report_mail_hourly_cap());
    END IF;
  END IF;

  -- B20-4: a kept schedule's scheduled turn, queued to be mailed, carries its post: the drawn page's numbers, the
  -- channels and the turn's day in the schedule's zone (one post a schedule a day: report_mail_post_take)
  IF v_kind = 'scheduled' AND v_why IS NULL AND v_rerr IS NULL AND v_sched.kept_as IS NOT NULL AND cardinality(v_sched.post_channels) > 0 THEN
    v_pchan := v_sched.post_channels;
    -- the day of the TURN (the claimed next_at, read before the turn moved it on), never the day it was queued: a turn
    -- mailed past midnight or late after an outage posts under its own day (review-26 S2)
    v_pday := (coalesce(v_sched.next_at, p_at) AT TIME ZONE v_sched.timezone)::date;
    IF v_post IS NULL AND jsonb_typeof(p_payload->'post') = 'object' THEN
      v_perr := 'the drawn page''s counts are over 4 KB: nothing posted';
    ELSIF v_post IS NULL THEN
      v_perr := 'the drawn page sent no counts: nothing posted';
    END IF;
  END IF;
  INSERT INTO pgvigil.report_mail_sends (schedule_id, kind, name, route, requested_by, requested_at, client, channel,
                                         recipients, subject, html, xlsx, xlsx_name, grids, rows, html_bytes, xlsx_bytes,
                                         render_error, done_at, outcome, error, post, post_channels, post_day, post_error)
  VALUES (v_sid, coalesce(v_kind, 'now'), left(coalesce(nullif(v_name, ''), '(no name)'), 120), left(coalesce(v_route, ''), 500),
          left(v_user, 200), p_at, left(v_client, 100), left(coalesce(v_chan, ''), 63), coalesce(v_rcpt, '{}'),
          left(coalesce(nullif(v_subject, ''), v_name, ''), 200),
          CASE WHEN v_why IS NULL AND v_rerr IS NULL THEN v_html END, CASE WHEN v_why IS NULL AND v_rerr IS NULL THEN v_xlsx END,
          v_xname, v_grids, v_rows, octet_length(v_html), octet_length(v_xlsx), v_rerr,
          CASE WHEN v_why IS NOT NULL THEN p_at END, CASE WHEN v_why IS NOT NULL THEN 'refused' END, v_why,
          CASE WHEN v_pchan IS NOT NULL THEN v_post END, v_pchan, v_pday, v_perr)
  RETURNING send_id INTO v_id;
  INSERT INTO pgvigil.report_mail_log (at, ui_user, client, op, schedule_id, send_id, outcome, detail, payload)
  VALUES (p_at, left(v_user, 200), left(v_client, 100), 'send ' || left(coalesce(v_kind, ''), 12), v_sid, v_id,
          CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
          left(coalesce(v_why, format('mail %s queued for %s: the sender''s next pass mails it', v_id, array_to_string(v_rcpt, ', '))), 2000),
          p_payload - 'ui_user' - 'client' - 'html' - 'xlsx' - 'post');
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, format('mail %s queued: the sender''s next pass mails it (within a minute while pgvigil run is up)', v_id)),
                            'send_id', v_id);
END $$;

-- report_mail_post_take: the post of a sent mail, taken once (post_taken_at): nothing when the mail was not sent, has no
-- post or was taken, or when the schedule took a post on that day already (the index: one post a schedule a day)
CREATE OR REPLACE FUNCTION pgvigil.report_mail_post_take(p_at timestamptz, p_send_id bigint)
RETURNS TABLE (o_post jsonb, o_channels text[], o_day date, o_route text)
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    RETURN QUERY
      UPDATE pgvigil.report_mail_sends s SET post_taken_at = p_at
       WHERE s.send_id = p_send_id AND s.outcome = 'sent' AND s.post IS NOT NULL AND s.post_taken_at IS NULL
         AND cardinality(s.post_channels) > 0
      RETURNING s.post, s.post_channels, s.post_day, s.route;
  EXCEPTION WHEN unique_violation THEN
    -- the schedule's post of that day was taken already: this turn posts nothing, and its row says why (review-26 N5)
    UPDATE pgvigil.report_mail_sends s
       SET post_error = format('the schedule''s post of %s was taken already: this turn posts nothing', s.post_day)
     WHERE s.send_id = p_send_id AND s.post_taken_at IS NULL AND s.post_error IS NULL;
    RETURN;
  END;
END $$;

-- report_mail_post_record: a taken post's answer - posted_at, or the error (the sender alerts it)
CREATE OR REPLACE FUNCTION pgvigil.report_mail_post_record(p_at timestamptz, p_send_id bigint, p_error text)
RETURNS void LANGUAGE sql AS $$
  UPDATE pgvigil.report_mail_sends
     SET posted_at = CASE WHEN nullif(p_error, '') IS NULL THEN p_at END, post_error = left(nullif(p_error, ''), 2000)
   WHERE send_id = p_send_id AND post_taken_at IS NOT NULL AND posted_at IS NULL AND post_error IS NULL
$$;
GRANT EXECUTE ON FUNCTION pgvigil.report_mail_post_take(timestamptz, bigint), pgvigil.report_mail_post_record(timestamptz, bigint, text) TO pgvigil_alerter;

SELECT pgvigil.apply_roles();
