-- 0012_logs: events read from the server log (slow statements, lock waits, deadlocks, failed logins),
-- in monthly partitions, and a read cursor per instance and source so a re-read never stores an event twice.
-- The collector reads its cursor through pgvigil.log_cursor (its door, like the import functions).

CREATE TABLE IF NOT EXISTS pgvigil.log_events (
  instance_id   int NOT NULL,
  snapshot_at   timestamptz NOT NULL,  -- the event's own time from the log line (the partition helper's column name)
  kind          text NOT NULL CHECK (kind IN ('slow', 'lock_wait', 'deadlock', 'auth_fail')),
  pid           int,
  client        text,
  usename       text,
  datname       text,
  duration_ms   double precision,
  statement     text,
  detail        text,
  source        text NOT NULL,         -- the log stream or file the event came from
  event_key     text NOT NULL          -- md5 of the parsed entry: the duplicate guard on a re-read
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.log_cursor (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  source        text NOT NULL,         -- e.g. cloudwatch:/aws/rds/cluster/<id>/postgresql
  read_to       timestamptz NOT NULL,  -- events up to here are stored
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (instance_id, source)
);

CREATE OR REPLACE FUNCTION pgvigil.log_cursor(p_instance_id int, p_source text)
RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT read_to FROM pgvigil.log_cursor WHERE instance_id = p_instance_id AND source = p_source
$$;

-- payload: rows {kind:'event', at, kind_of, pid, client, usename, datname, duration_ms, statement, detail, source, event_key}
-- and one {kind:'cursor', source, read_to}; events already stored (same instance, at, event_key) are skipped.
CREATE OR REPLACE FUNCTION pgvigil.import_logs(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  m timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_logs'), p_instance_id);
  FOR m IN SELECT DISTINCT date_trunc('month', (r->>'at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
             FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'event'
  LOOP
    PERFORM pgvigil.ensure_month_partition('log_events', m);
  END LOOP;

  INSERT INTO pgvigil.log_events (instance_id, snapshot_at, kind, pid, client, usename, datname, duration_ms, statement, detail, source, event_key)
  SELECT p_instance_id, (r->>'at')::timestamptz, r->>'kind_of', (r->>'pid')::int, r->>'client', r->>'usename', r->>'datname',
         (r->>'duration_ms')::float8, r->>'statement', r->>'detail', r->>'source', r->>'event_key'
    FROM (SELECT DISTINCT ON (r->>'at', r->>'event_key') r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'event') x
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.log_events e
                      WHERE e.instance_id = p_instance_id AND e.snapshot_at = (x.r->>'at')::timestamptz AND e.event_key = x.r->>'event_key');

  INSERT INTO pgvigil.log_cursor AS c (instance_id, source, read_to)
  SELECT p_instance_id, r->>'source', (r->>'read_to')::timestamptz
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cursor'
  ON CONFLICT (instance_id, source) DO UPDATE SET read_to = greatest(c.read_to, EXCLUDED.read_to), updated_at = now();
END $$;

CREATE OR REPLACE FUNCTION pgvigil.apply_roles()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  f record;
  t record;
BEGIN
  REVOKE ALL ON SCHEMA pgvigil FROM PUBLIC;
  GRANT USAGE ON SCHEMA pgvigil TO pgvigil_collector, pgvigil_reader;

  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgvigil'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    IF f.proname LIKE 'import\_%' OR f.proname IN ('ensure_instance', 'log_collection', 'schema_latest', 'log_cursor') THEN
      -- the collector's door: runs as the owner, sees only its arguments
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp', f.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_collector', f.sig);
    ELSIF f.proname IN ('apply_roles', 'purge', 'ensure_month_partition') THEN
      NULL;  -- owner only
    ELSE
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_reader', f.sig);
    END IF;
  END LOOP;

  FOR t IN
    SELECT c.oid::regclass AS rel
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p', 'v')
  LOOP
    EXECUTE format('REVOKE ALL ON %s FROM PUBLIC, pgvigil_collector', t.rel);
    EXECUTE format('GRANT SELECT ON %s TO pgvigil_reader', t.rel);
  END LOOP;
END $$;

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
       AND p.relname IN ('activity_sample', 'statements_delta', 'dbstats', 'serverstats', 'iostats', 'replication_sample', 'database_sizes', 'log_events')
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

SELECT pgvigil.apply_roles();
