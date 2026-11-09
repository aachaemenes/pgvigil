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
  query_hash        bigint,
  backend_type      text,                 -- 'client backend' for sampled sessions; a blocker can be autovacuum or a worker
  is_blocker        boolean NOT NULL DEFAULT false   -- stored because some waiter's blocking_pids named it
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
-- Month boundaries are UTC regardless of the importing session's TimeZone, so two
-- collectors with different PGTZ values agree on the partition a row belongs to.
CREATE OR REPLACE FUNCTION pgvigil.ensure_month_partition(p_table text, p_at timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_from timestamp := date_trunc('month', p_at AT TIME ZONE 'UTC');        -- UTC wall clock
  v_to   timestamp := v_from + interval '1 month';
  v_name text := p_table || '_' || to_char(v_from, 'YYYYMM');
BEGIN
  IF to_regclass('pgvigil.' || quote_ident(v_name)) IS NOT NULL THEN
    RETURN;
  END IF;
  BEGIN
    EXECUTE format('CREATE TABLE pgvigil.%I PARTITION OF pgvigil.%I FOR VALUES FROM (%L) TO (%L)',
                   v_name, p_table, v_from AT TIME ZONE 'UTC', v_to AT TIME ZONE 'UTC');
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
    blocking_pids, leader_pid, query_id, query_hash, backend_type, is_blocker)
  SELECT p_instance_id, p_snapshot_at, (r->>'pid')::int, (r->>'backend_start')::timestamptz,
         r->>'datname', r->>'usename', r->>'application_name', r->>'client', r->>'state',
         r->>'wait_event_type', r->>'wait_event', (r->>'xact_start')::timestamptz, (r->>'query_start')::timestamptz,
         (r->>'state_change')::timestamptz, (r->>'xid_assigned')::boolean, (r->>'backend_xmin_age')::int,
         CASE WHEN jsonb_typeof(r->'blocking_pids') = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(r->'blocking_pids')::int) END,
         (r->>'leader_pid')::int, (r->>'query_id')::bigint, (r->>'query_hash')::bigint,
         r->>'backend_type', coalesce((r->>'is_blocker')::boolean, false)
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

-- Blocking chains in one snapshot: one row per (Lock waiter, head), where a head is a
-- session that blocks and does not itself wait on a lock (or a pid the snapshot does not
-- hold: a prepared transaction shows as 0). The walk keeps one visited set per waiter, so
-- a lock queue of N sessions costs N steps, not 2^N paths; a waiter whose every path
-- closes on itself gets one row with head_pid NULL and in_cycle true (a deadlock caught
-- before deadlock_timeout fired). The root cause of a chain is the head's transaction and
-- its last statement, never the object the waiters want.
CREATE OR REPLACE FUNCTION pgvigil.blocking_chains(p_instance_id int, p_snapshot_at timestamptz)
RETURNS TABLE (pid int, head_pid int, depth int, in_cycle boolean, state text, wait_event text,
               head_state text, head_backend_type text, head_query text, waiter_query text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  w          record;
  v_frontier int[];
  v_next     int[];
  v_visited  int[];
  v_heads    int[];
  v_depth    int;
  v_cycle    boolean;
  v_p        int;
  v_bp       int[];
  v_wet      text;
  v_found    boolean;
BEGIN
  FOR w IN
    SELECT s.pid, s.blocking_pids, s.state, s.wait_event, s.query_hash
      FROM pgvigil.activity_sample s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at
       AND s.wait_event_type = 'Lock' AND cardinality(s.blocking_pids) > 0
     ORDER BY s.pid
  LOOP
    v_frontier := w.blocking_pids; v_visited := ARRAY[w.pid]; v_heads := '{}'; v_depth := 0; v_cycle := false;
    WHILE cardinality(v_frontier) > 0 AND v_depth < 64 LOOP
      v_depth := v_depth + 1; v_next := '{}';
      FOREACH v_p IN ARRAY v_frontier LOOP
        IF v_p = ANY (v_visited) THEN v_cycle := true; CONTINUE; END IF;
        v_visited := v_visited || v_p;
        SELECT s.blocking_pids, s.wait_event_type, true INTO v_bp, v_wet, v_found
          FROM pgvigil.activity_sample s
         WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at AND s.pid = v_p;
        IF NOT coalesce(v_found, false) OR v_wet IS DISTINCT FROM 'Lock' OR coalesce(cardinality(v_bp), 0) = 0 THEN
          IF NOT v_p = ANY (v_heads) THEN v_heads := v_heads || v_p; END IF;   -- holds, does not wait: a head
        ELSE
          v_next := v_next || v_bp;                                            -- a waiter itself: follow it
        END IF;
        v_found := false;
      END LOOP;
      v_frontier := v_next;
    END LOOP;

    IF cardinality(v_heads) = 0 THEN
      pid := w.pid; head_pid := NULL; depth := v_depth; in_cycle := true; state := w.state; wait_event := w.wait_event;
      head_state := NULL; head_backend_type := NULL; head_query := NULL;
      SELECT q.query INTO waiter_query FROM pgvigil.query_text q WHERE q.query_hash = w.query_hash;
      RETURN NEXT;
    ELSE
      FOREACH v_p IN ARRAY v_heads LOOP
        pid := w.pid; head_pid := v_p; depth := v_depth; in_cycle := v_cycle; state := w.state; wait_event := w.wait_event;
        SELECT hs.state, hs.backend_type, (SELECT q.query FROM pgvigil.query_text q WHERE q.query_hash = hs.query_hash)
          INTO head_state, head_backend_type, head_query
          FROM pgvigil.activity_sample hs
         WHERE hs.instance_id = p_instance_id AND hs.snapshot_at = p_snapshot_at AND hs.pid = v_p;
        SELECT q.query INTO waiter_query FROM pgvigil.query_text q WHERE q.query_hash = w.query_hash;
        RETURN NEXT;
      END LOOP;
    END IF;
  END LOOP;
END $$;

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
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)   -- partition bounds are UTC months
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
