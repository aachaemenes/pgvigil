-- 0002_activity: the running-queries snapshot (active and idle-in-transaction sessions,
-- their statements and blockers) and a per-snapshot session summary. Samples live in
-- monthly partitions dropped whole by pgvigil.purge; statement text is stored once per hash.

CREATE TABLE IF NOT EXISTS pgvigil.query_text (
  query_hash  bigint PRIMARY KEY,
  first_seen  timestamptz NOT NULL,
  last_seen   timestamptz NOT NULL,
  query       text NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.activity_sample (
  instance_id       int NOT NULL,
  snapshot_at       timestamptz NOT NULL,
  pid               int NOT NULL,
  backend_start     timestamptz,
  datname           text,
  usename           text,
  application_name  text,
  client            text,
  state             text,
  wait_event_type   text,
  wait_event        text,
  xact_start        timestamptz,
  query_start       timestamptz,
  state_change      timestamptz,
  xid_assigned      boolean,
  backend_xmin_age  int,
  blocking_pids     int[],
  leader_pid        int,
  query_id          bigint,
  query_hash        bigint
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.activity_summary (
  instance_id            int NOT NULL,
  snapshot_at            timestamptz NOT NULL,
  total                  int,
  active                 int,
  idle                   int,
  idle_in_txn            int,
  idle_in_txn_aborted    int,
  waiting_lock           int,
  active_client_wait     int,
  longest_active_secs    int,
  longest_idle_txn_secs  int,
  oldest_xmin_age        int,
  max_connections        int,
  PRIMARY KEY (instance_id, snapshot_at)
);

-- One monthly partition per sample table; called by every import, cheap when it exists.
CREATE OR REPLACE FUNCTION pgvigil.ensure_month_partition(p_table text, p_at timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_from date := date_trunc('month', p_at)::date;
  v_to   date := (date_trunc('month', p_at) + interval '1 month')::date;
  v_name text := p_table || '_' || to_char(v_from, 'YYYYMM');
BEGIN
  IF to_regclass('pgvigil.' || quote_ident(v_name)) IS NOT NULL THEN
    RETURN;
  END IF;
  BEGIN
    EXECUTE format('CREATE TABLE pgvigil.%I PARTITION OF pgvigil.%I FOR VALUES FROM (%L) TO (%L)',
                   v_name, p_table, v_from::timestamptz, v_to::timestamptz);
    EXECUTE format('CREATE INDEX %I ON pgvigil.%I (instance_id, snapshot_at)', v_name || '_inst_idx', v_name);
  EXCEPTION WHEN duplicate_table THEN
    NULL;  -- another importer made it first
  END;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_activity(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.ensure_month_partition('activity_sample', p_snapshot_at);

  INSERT INTO pgvigil.query_text AS t (query_hash, first_seen, last_seen, query)
  SELECT DISTINCT ON ((r->>'query_hash')::bigint)
         (r->>'query_hash')::bigint, p_snapshot_at, p_snapshot_at, r->>'query'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'session' AND r->>'query_hash' IS NOT NULL AND coalesce(r->>'query', '') <> ''
   ORDER BY (r->>'query_hash')::bigint
  ON CONFLICT (query_hash) DO UPDATE SET last_seen = EXCLUDED.last_seen;

  INSERT INTO pgvigil.activity_sample (
    instance_id, snapshot_at, pid, backend_start, datname, usename, application_name, client, state,
    wait_event_type, wait_event, xact_start, query_start, state_change, xid_assigned, backend_xmin_age,
    blocking_pids, leader_pid, query_id, query_hash)
  SELECT p_instance_id, p_snapshot_at, (r->>'pid')::int, (r->>'backend_start')::timestamptz,
         r->>'datname', r->>'usename', r->>'application_name', r->>'client', r->>'state',
         r->>'wait_event_type', r->>'wait_event', (r->>'xact_start')::timestamptz, (r->>'query_start')::timestamptz,
         (r->>'state_change')::timestamptz, (r->>'xid_assigned')::boolean, (r->>'backend_xmin_age')::int,
         CASE WHEN jsonb_typeof(r->'blocking_pids') = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(r->'blocking_pids')::int) END,
         (r->>'leader_pid')::int, (r->>'query_id')::bigint, (r->>'query_hash')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'session';

  INSERT INTO pgvigil.activity_summary (
    instance_id, snapshot_at, total, active, idle, idle_in_txn, idle_in_txn_aborted, waiting_lock,
    active_client_wait, longest_active_secs, longest_idle_txn_secs, oldest_xmin_age, max_connections)
  SELECT p_instance_id, p_snapshot_at, (r->>'total')::int, (r->>'active')::int, (r->>'idle')::int,
         (r->>'idle_in_txn')::int, (r->>'idle_in_txn_aborted')::int, (r->>'waiting_lock')::int,
         (r->>'active_client_wait')::int, (r->>'longest_active_secs')::int, (r->>'longest_idle_txn_secs')::int,
         (r->>'oldest_xmin_age')::int, (r->>'max_connections')::int
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'summary'
  ON CONFLICT (instance_id, snapshot_at) DO NOTHING;
END $$;

-- Blocking chains in one snapshot: each Lock waiter with the head of its chain (the session
-- that holds and does not itself wait on a lock) and its depth. The root cause of a chain is
-- the head's transaction and its last statement, never the object the waiters want.
CREATE OR REPLACE FUNCTION pgvigil.blocking_chains(p_instance_id int, p_snapshot_at timestamptz)
RETURNS TABLE (pid int, head_pid int, depth int, path int[], state text, wait_event text, head_state text,
               head_query text, waiter_query text)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE snap AS (
    SELECT s.* FROM pgvigil.activity_sample s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at
  ),
  walk AS (
    -- a waiter and its first blocker
    SELECT w.pid, b AS blocker, 1 AS depth, ARRAY[w.pid, b] AS path
      FROM snap w, unnest(w.blocking_pids) b
     WHERE w.wait_event_type = 'Lock'
    UNION ALL
    -- follow a blocker that is itself a Lock waiter
    SELECT k.pid, b, k.depth + 1, k.path || b
      FROM walk k
      JOIN snap n ON n.pid = k.blocker AND n.wait_event_type = 'Lock'
      CROSS JOIN LATERAL unnest(n.blocking_pids) b
     WHERE NOT b = ANY (k.path) AND k.depth < 32
  ),
  heads AS (
    -- the end of each walk whose blocker is not a Lock waiter (or is unknown to the snapshot)
    SELECT DISTINCT ON (k.pid) k.pid, k.blocker AS head_pid, k.depth, k.path
      FROM walk k
      LEFT JOIN snap n ON n.pid = k.blocker
     WHERE n.pid IS NULL OR n.wait_event_type IS DISTINCT FROM 'Lock'
     ORDER BY k.pid, k.depth DESC
  )
  SELECT h.pid, h.head_pid, h.depth, h.path, w.state, w.wait_event,
         hd.state AS head_state,
         (SELECT q.query FROM pgvigil.query_text q WHERE q.query_hash = hd.query_hash) AS head_query,
         (SELECT q.query FROM pgvigil.query_text q WHERE q.query_hash = w.query_hash)  AS waiter_query
    FROM heads h
    JOIN snap w  ON w.pid = h.pid
    LEFT JOIN snap hd ON hd.pid = h.head_pid
   ORDER BY h.head_pid, h.depth, h.pid
$$;

-- The newest snapshot of every instance, for a "right now" page.
CREATE OR REPLACE VIEW pgvigil.activity_latest AS
  SELECT s.*
    FROM pgvigil.activity_sample s
    JOIN (SELECT instance_id, max(snapshot_at) AS snapshot_at
            FROM pgvigil.activity_summary GROUP BY instance_id) l
      ON l.instance_id = s.instance_id AND l.snapshot_at = s.snapshot_at;

-- Retention: drop sample partitions older than p_days whole, delete old summaries and
-- statement text no sample refers to any more, and the collection log.
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
     WHERE ns.nspname = 'pgvigil' AND p.relname = 'activity_sample'
       AND c.relname ~ '^activity_sample_[0-9]{6}$'
       AND to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month' < now() - make_interval(days => p_days)
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    n := n + 1;
  END LOOP;

  DELETE FROM pgvigil.activity_summary WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;

  DELETE FROM pgvigil.query_text t
   WHERE t.last_seen < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.activity_sample s WHERE s.query_hash = t.query_hash);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;

  DELETE FROM pgvigil.collection_log WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  RETURN n;
END $$;
