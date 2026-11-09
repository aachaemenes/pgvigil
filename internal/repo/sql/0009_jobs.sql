-- 0009_jobs: scheduled jobs (pg_cron, pgAgent) - a current job table and a run history
-- de-duplicated by (scheduler, job_id, run_id), plus the failed-and-running views.

CREATE TABLE IF NOT EXISTS pgvigil.jobs (
  instance_id   int NOT NULL,
  scheduler     text NOT NULL,
  job_id        bigint NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  job_name      text,
  schedule      text,
  command       text,
  datname       text,
  run_as        text,
  active        boolean,
  nodename      text,
  nodeport      int,
  next_run      timestamptz,
  last_run      timestamptz,
  first_seen    timestamptz NOT NULL,
  is_present    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, scheduler, job_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.job_runs (
  instance_id     int NOT NULL,
  scheduler       text NOT NULL,
  job_id          bigint NOT NULL,
  run_id          bigint NOT NULL,
  job_pid         int,
  datname         text,
  run_as          text,
  command         text,
  status          text,
  return_message  text,
  start_time      timestamptz,
  end_time        timestamptz,
  duration_secs   double precision,
  snapshot_at     timestamptz NOT NULL,
  PRIMARY KEY (instance_id, scheduler, job_id, run_id)
);
CREATE INDEX IF NOT EXISTS job_runs_start_idx ON pgvigil.job_runs (instance_id, start_time);

CREATE OR REPLACE FUNCTION pgvigil.import_jobs(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.jobs AS j (instance_id, scheduler, job_id, snapshot_at, job_name, schedule, command, datname, run_as,
                                 active, nodename, nodeport, next_run, last_run, first_seen, is_present)
  SELECT p_instance_id, r->>'scheduler', (r->>'job_id')::bigint, p_snapshot_at, r->>'job_name', r->>'schedule', r->>'command',
         r->>'datname', r->>'run_as', (r->>'active')::boolean, r->>'nodename', (r->>'nodeport')::int,
         (r->>'next_run')::timestamptz, (r->>'last_run')::timestamptz, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'job'
  ON CONFLICT (instance_id, scheduler, job_id) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, job_name = EXCLUDED.job_name, schedule = EXCLUDED.schedule, command = EXCLUDED.command,
    datname = EXCLUDED.datname, run_as = EXCLUDED.run_as, active = EXCLUDED.active, nodename = EXCLUDED.nodename,
    nodeport = EXCLUDED.nodeport, next_run = EXCLUDED.next_run, last_run = EXCLUDED.last_run, is_present = true;

  UPDATE pgvigil.jobs j SET is_present = false
   WHERE j.instance_id = p_instance_id AND j.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'job' AND r->>'scheduler' = j.scheduler AND (r->>'job_id')::bigint = j.job_id);

  -- a run is stored once; a running row is updated when it ends
  INSERT INTO pgvigil.job_runs AS x (instance_id, scheduler, job_id, run_id, job_pid, datname, run_as, command, status,
                                     return_message, start_time, end_time, duration_secs, snapshot_at)
  SELECT p_instance_id, r->>'scheduler', (r->>'job_id')::bigint, (r->>'run_id')::bigint, (r->>'job_pid')::int, r->>'datname',
         r->>'run_as', r->>'command', r->>'status', r->>'return_message', (r->>'start_time')::timestamptz,
         (r->>'end_time')::timestamptz, (r->>'duration_secs')::float8, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'run' AND r->>'run_id' IS NOT NULL
  ON CONFLICT (instance_id, scheduler, job_id, run_id) DO UPDATE SET
    status = EXCLUDED.status, return_message = EXCLUDED.return_message, end_time = EXCLUDED.end_time,
    duration_secs = EXCLUDED.duration_secs, snapshot_at = EXCLUDED.snapshot_at
  WHERE x.end_time IS NULL;
END $$;

-- failed runs in the last day, and runs still going (the two daily-check questions)
CREATE OR REPLACE VIEW pgvigil.job_failures AS
  SELECT r.instance_id, r.scheduler, r.job_id, j.job_name, r.run_id, r.status, r.return_message, r.start_time, r.end_time, r.duration_secs
    FROM pgvigil.job_runs r
    LEFT JOIN pgvigil.jobs j ON j.instance_id = r.instance_id AND j.scheduler = r.scheduler AND j.job_id = r.job_id
   WHERE r.start_time > now() - interval '1 day'
     AND r.status IN ('failed', 'internal error', 'aborted');

CREATE OR REPLACE VIEW pgvigil.job_running AS
  SELECT r.instance_id, r.scheduler, r.job_id, j.job_name, r.run_id, r.start_time,
         extract(epoch FROM now() - r.start_time)::int AS running_secs
    FROM pgvigil.job_runs r
    LEFT JOIN pgvigil.jobs j ON j.instance_id = r.instance_id AND j.scheduler = r.scheduler AND j.job_id = r.job_id
   WHERE r.end_time IS NULL AND r.status IN ('running', 'starting');

CREATE OR REPLACE FUNCTION pgvigil.purge(p_days int DEFAULT 30)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n       bigint := 0;
  v_rows  bigint;
  v_part  record;
BEGIN
  FOR v_part IN
    SELECT c.relname
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent
      JOIN pg_namespace ns ON ns.oid = p.relnamespace
     WHERE ns.nspname = 'pgvigil'
       AND p.relname IN ('activity_sample', 'statements_delta', 'dbstats', 'serverstats', 'iostats', 'replication_sample', 'database_sizes')
       AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    n := n + 1;
  END LOOP;
  DELETE FROM pgvigil.job_runs WHERE start_time < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.activity_summary WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statements_info WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statements_current WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.query_text t
   WHERE t.last_seen < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.activity_sample s WHERE s.query_hash = t.query_hash);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statement_text t
   WHERE t.last_seen < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.statements_delta d WHERE d.instance_id = t.instance_id AND d.queryid = t.queryid);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.collection_log WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  RETURN n;
END $$;
