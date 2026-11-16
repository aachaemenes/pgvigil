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

-- mssql_blitz_due: whether the weekly run of an instance is due now, in words. 'off' (its own switch, else the site
-- default), 'not due' (a run is stored since the newest slot: <day> <hour>:00 in the site's zone, at or before now) or
-- 'due'. A run of any outcome counts: a refused or timed-out run is not retried before the next slot.
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
  IF v_slot > v_local THEN
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
  IF NOT enabled THEN
    state := 'off';
    why := CASE WHEN v_own IS NOT NULL
                THEN 'the weekly sp_Blitz is off for this instance (its own switch; the site default is '
                     || CASE WHEN s.enabled THEN 'on' ELSE 'off' END || ')'
                ELSE 'the weekly sp_Blitz is off for this instance (the site default is off; an admin turns it on for'
                     || ' the instance or the site on the instance''s Findings tab)' END;
  ELSIF last_run_at IS NOT NULL AND last_run_at >= slot_at THEN
    state := 'not due';
    why := 'not due yet: this week''s run started ' || to_char(last_run_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI')
           || ' UTC; the next is due ' || to_char(v_slot + interval '7 days', 'YYYY-MM-DD HH24:MI') || ' ' || s.run_tz
           || ' (every ' || v_when || ')';
  ELSE
    state := 'due';
    why := 'due: no run since ' || to_char(v_slot, 'YYYY-MM-DD HH24:MI') || ' ' || s.run_tz || ' (every ' || v_when || ')';
  END IF;
  RETURN NEXT;
END $$;
COMMENT ON FUNCTION pgvigil.mssql_blitz_due(int, timestamptz) IS
  'B20-2: whether an instance''s weekly sp_Blitz is due now, with its words (the page''s and the collector''s one rule).';

-- import_mssql_blitz_plan: the collector's question before a run (apply_roles makes an import_ function its door):
-- the state, its words, the database sp_Blitz is looked for in and the statement's timeout.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_blitz_plan(p_instance_id int)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('state', d.state, 'why', d.why, 'proc_db', d.proc_db, 'timeout_s', d.timeout_s)
    FROM pgvigil.mssql_blitz_due(p_instance_id) d
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
-- called). Ops: 'site' {enabled, run_dow, run_hour, run_tz, timeout_s} - a key left out keeps its value; 'instance'
-- {instance_id, enabled (true, false, or null = the site default), proc_db (left out = kept, else master)}. Every
-- attempt is written to admin_audit, done or refused; the answer is {outcome, detail}.
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
  s        record;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_mssql_blitz_setting: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op = 'site' THEN
    SELECT x.enabled, x.run_dow, x.run_hour, x.run_tz, x.timeout_s INTO s FROM pgvigil.mssql_blitz_site x FOR UPDATE;
    v_target := 'site';
    s.enabled := CASE WHEN p_payload ? 'enabled' THEN (p_payload->>'enabled')::boolean ELSE s.enabled END;
    s.run_dow := CASE WHEN p_payload ? 'run_dow' THEN (p_payload->>'run_dow')::int ELSE s.run_dow END;
    s.run_hour := CASE WHEN p_payload ? 'run_hour' THEN (p_payload->>'run_hour')::int ELSE s.run_hour END;
    s.run_tz := CASE WHEN p_payload ? 'run_tz' THEN p_payload->>'run_tz' ELSE s.run_tz END;
    s.timeout_s := CASE WHEN p_payload ? 'timeout_s' THEN (p_payload->>'timeout_s')::int ELSE s.timeout_s END;
    v_why := CASE
      WHEN s.enabled IS NULL THEN 'the site default is on or off (true or false)'
      WHEN s.run_dow IS NULL OR s.run_dow NOT BETWEEN 0 AND 6 THEN 'run_dow is a day of the week, 0 (Sunday) to 6 (Saturday)'
      WHEN s.run_hour IS NULL OR s.run_hour NOT BETWEEN 0 AND 23 THEN 'run_hour is an hour of the day, 0 to 23'
      WHEN s.run_tz IS NULL OR NOT EXISTS (SELECT 1 FROM pg_timezone_names z WHERE z.name = s.run_tz)
        THEN coalesce(s.run_tz, 'the zone') || ' is not a time zone PostgreSQL knows (pg_timezone_names: UTC, Europe/London, America/New_York ...)'
      WHEN s.timeout_s IS NULL OR s.timeout_s NOT BETWEEN 1 AND 1800 THEN 'timeout_s is 1 to 1800 seconds'
    END;
    IF v_why IS NULL THEN
      UPDATE pgvigil.mssql_blitz_site
         SET enabled = s.enabled, run_dow = s.run_dow, run_hour = s.run_hour, run_tz = s.run_tz, timeout_s = s.timeout_s,
             updated_at = p_at, updated_by = v_user;
      v_detail := 'the site default ' || CASE WHEN s.enabled THEN 'on' ELSE 'off' END || ', every '
                  || (ARRAY['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'])[s.run_dow + 1]
                  || ' ' || lpad(s.run_hour::text, 2, '0') || ':00 ' || s.run_tz || ', a ' || s.timeout_s || ' s timeout';
    END IF;
  ELSIF v_op = 'instance' THEN
    v_id := (p_payload->>'instance_id')::int;
    SELECT i.name, i.engine INTO v_name, v_engine FROM pgvigil.instances i WHERE i.instance_id = v_id;
    v_target := coalesce(v_name, 'instance ' || coalesce(v_id::text, '(none)'));
    v_db := CASE WHEN p_payload ? 'proc_db' THEN p_payload->>'proc_db'
                 ELSE coalesce((SELECT b.proc_db FROM pgvigil.mssql_blitz_setting b WHERE b.instance_id = v_id), 'master') END;
    v_why := CASE
      WHEN v_id IS NULL OR v_name IS NULL THEN 'no instance ' || coalesce(v_id::text, '(none named)')
      WHEN v_engine IS DISTINCT FROM 'sqlserver' THEN v_name || ' is not a SQL Server instance: sp_Blitz is SQL Server''s'
      WHEN v_db IS NULL OR length(v_db) NOT BETWEEN 1 AND 128 OR v_db ~ '[[:cntrl:]]'
        THEN 'the database sp_Blitz is in is a name of 1 to 128 characters'
    END;
    IF v_why IS NULL THEN
      INSERT INTO pgvigil.mssql_blitz_setting AS b (instance_id, enabled, proc_db, updated_at, updated_by)
      VALUES (v_id, (p_payload->>'enabled')::boolean, v_db, p_at, v_user)
      ON CONFLICT (instance_id) DO UPDATE
         SET enabled = EXCLUDED.enabled, proc_db = EXCLUDED.proc_db, updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by;
      v_detail := v_name || ': ' || CASE (p_payload->>'enabled')::boolean WHEN true THEN 'on' WHEN false THEN 'off'
                  ELSE 'the site default' END || ', sp_Blitz in ' || v_db;
    END IF;
  ELSE
    v_target := coalesce(v_op, '(none)');
    v_why := 'op is site or instance, not ' || coalesce(v_op, '(none)');
  END IF;
  INSERT INTO pgvigil.admin_audit (at, ui_user, client, op, target, outcome, detail)
  VALUES (p_at, v_user, v_client, 'mssql_blitz_' || coalesce(v_op, 'unknown'), v_target,
          CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, coalesce(v_why, v_detail));
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, 'detail', coalesce(v_why, v_detail));
END $$;

SELECT pgvigil.apply_roles();
