-- 0081_pooler_clients: the pooler traced (task 128). PgBouncer's SHOW CLIENTS and SHOW SERVERS stored beside the
-- pools, and a server's remote_pid joined to the activity snapshot and its blocking chains, so a client that waits
-- INSIDE the pooler (which pg_stat_activity never sees) traces to the backends its pool's servers run and to the head
-- that holds them.
--
--   pooler_conn_sample   monthly partitions; per pooler read a 'conns' row (clients_read, clients_kept,
--                        servers_read: the read happened, even with no client to keep), the 'client' rows kept (every
--                        client not idle, the longest waits first, at most 1000) and the 'server' rows (remote_pid =
--                        the backend's pid). ptr and link pair a client with its server (client.link = server.ptr).
--   import_pgbouncer     0061's import, unchanged for the state, pool and stats rows, now also storing the conns,
--                        client and server rows of the payload (a payload without them, from an older collector or a
--                        console that refused SHOW CLIENTS, stores none).
--   pooler_read_at(instance, at)
--                        the pooler read a page shows for a time: the read nearest to it within two minutes on either
--                        side (the Running page pairs the pooler read with its activity snapshot, both taken within
--                        the same minute), else the newest at or before it; NULL when none.
--   pooler_conns(instance, at)
--                        that read's clients and servers, each with the backend it runs on (a server's own
--                        remote_pid; a client's is its paired server's) joined to the activity snapshot nearest the
--                        read within two minutes: the backend's state, wait, ages and blockers, and from
--                        blocking_chains its role (head | blocked | in a cycle) and its chain's head with the head's
--                        state, application and last statement; head_via_pooler says whether the head is itself one
--                        of this pooler's servers, with the application of the client paired with it.
--
-- A backend that is idle between transactions is not in the activity sample (it samples active and idle-in-transaction
-- sessions and blockers): its backend_state is NULL and the page says 'not in the sample'. The pooler read and the
-- activity snapshot are taken by two collections in the same minute, seconds apart: both times are returned, and a
-- transaction-mode pairing (which client a server serves) can change between them.
--
-- Retention: pooler_conn_sample joins purge()'s list of partition parents in the wave's join migration (the lead's).
-- PostgreSQL 13 or later (no date_bin, no 14+ function).

CREATE TABLE IF NOT EXISTS pgvigil.pooler_conn_sample (
  instance_id       int NOT NULL,
  snapshot_at       timestamptz NOT NULL,
  kind              text NOT NULL CHECK (kind IN ('conns', 'client', 'server')),
  database          text,
  usr               text,
  state             text,
  application_name  text,
  addr              text,
  port              int,
  connect_time      timestamptz,
  request_time      timestamptz,
  wait_us           bigint,
  ptr               text,
  link              text,
  remote_pid        int,
  clients_read      int,
  clients_kept      int,
  servers_read      int
) PARTITION BY RANGE (snapshot_at);

-- payload: one {kind:'state', status, reason, version}; when ok, the 'pool', 'stats', 'database' and 'config' rows,
-- and where SHOW CLIENTS and SHOW SERVERS were read one 'conns' row and the 'client' and 'server' rows
CREATE OR REPLACE FUNCTION pgvigil.import_pgbouncer(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_state jsonb;
  v_ok    boolean;
BEGIN
  SELECT r INTO v_state FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'state' LIMIT 1;
  IF v_state IS NULL THEN
    RAISE EXCEPTION 'import_pgbouncer: the payload has no state row';
  END IF;
  v_ok := v_state->>'status' = 'ok';
  INSERT INTO pgvigil.pooler_state AS s (instance_id, snapshot_at, status, reason, version, databases, config, last_ok)
  VALUES (p_instance_id, p_snapshot_at, v_state->>'status', v_state->>'reason', v_state->>'version',
          CASE WHEN v_ok THEN (SELECT coalesce(jsonb_agg(r - 'kind'), '[]'::jsonb) FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'database') END,
          CASE WHEN v_ok THEN (SELECT coalesce(jsonb_agg(r - 'kind'), '[]'::jsonb) FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'config') END,
          CASE WHEN v_ok THEN p_snapshot_at END)
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, status = EXCLUDED.status, reason = EXCLUDED.reason,
    version = coalesce(EXCLUDED.version, s.version),
    databases = coalesce(EXCLUDED.databases, s.databases), config = coalesce(EXCLUDED.config, s.config),
    last_ok = coalesce(EXCLUDED.last_ok, s.last_ok)
  WHERE s.snapshot_at <= EXCLUDED.snapshot_at;
  IF NOT v_ok THEN
    RETURN;
  END IF;
  PERFORM pgvigil.ensure_month_partition('pooler_sample', p_snapshot_at);
  INSERT INTO pgvigil.pooler_sample (instance_id, snapshot_at, kind, database, usr, cl_active, cl_waiting, sv_active, sv_idle, sv_used,
                                     sv_tested, sv_login, maxwait_ms, pool_mode, pool_size, pool_size_from, xact_rate, query_rate, avg_wait_us,
                                     avg_query_us, total_xact_count, total_query_count, total_wait_us)
  SELECT p_instance_id, p_snapshot_at, r->>'kind', r->>'database', r->>'user', (r->>'cl_active')::int, (r->>'cl_waiting')::int,
         (r->>'sv_active')::int, (r->>'sv_idle')::int, (r->>'sv_used')::int, (r->>'sv_tested')::int, (r->>'sv_login')::int,
         (r->>'maxwait_ms')::float8, r->>'pool_mode', (r->>'pool_size')::int, r->>'pool_size_from', (r->>'xact_rate')::bigint, (r->>'query_rate')::bigint,
         (r->>'avg_wait_us')::bigint, (r->>'avg_query_us')::bigint, (r->>'total_xact_count')::bigint,
         (r->>'total_query_count')::bigint, (r->>'total_wait_us')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' IN ('pool', 'stats') AND r->>'database' IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pgvigil.pooler_sample x
                      WHERE x.instance_id = p_instance_id AND x.snapshot_at = p_snapshot_at AND x.kind = r->>'kind'
                        AND x.database = r->>'database' AND x.usr IS NOT DISTINCT FROM r->>'user');
  -- the clients and servers (task 128): a re-run of one read replaces its rows
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'conns') THEN
    PERFORM pgvigil.ensure_month_partition('pooler_conn_sample', p_snapshot_at);
    DELETE FROM pgvigil.pooler_conn_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
    INSERT INTO pgvigil.pooler_conn_sample (instance_id, snapshot_at, kind, database, usr, state, application_name, addr, port,
                                            connect_time, request_time, wait_us, ptr, link, remote_pid, clients_read, clients_kept, servers_read)
    SELECT p_instance_id, p_snapshot_at, r->>'kind', r->>'database', r->>'user', r->>'state', nullif(r->>'application_name', ''),
           r->>'addr', (r->>'port')::int, (r->>'connect_time')::timestamptz, (r->>'request_time')::timestamptz, (r->>'wait_us')::bigint,
           nullif(r->>'ptr', ''), nullif(r->>'link', ''), nullif((r->>'remote_pid')::int, 0),
           (r->>'clients_read')::int, (r->>'clients_kept')::int, (r->>'servers_read')::int
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' IN ('conns', 'client', 'server');
  END IF;
END $$;

-- the pooler read shown for a time (see the header)
CREATE OR REPLACE FUNCTION pgvigil.pooler_read_at(p_instance_id int, p_at timestamptz)
RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT c.snapshot_at FROM pgvigil.pooler_conn_sample c
      WHERE c.instance_id = p_instance_id AND c.kind = 'conns'
        AND c.snapshot_at BETWEEN p_at - interval '2 minutes' AND p_at + interval '2 minutes'
      ORDER BY abs(extract(epoch FROM c.snapshot_at - p_at)), c.snapshot_at DESC LIMIT 1),
    (SELECT max(c.snapshot_at) FROM pgvigil.pooler_conn_sample c
      WHERE c.instance_id = p_instance_id AND c.kind = 'conns' AND c.snapshot_at <= p_at))
$$;

-- a read's clients and servers joined to the backends they run on (see the header)
CREATE OR REPLACE FUNCTION pgvigil.pooler_conns(p_instance_id int, p_at timestamptz)
RETURNS TABLE (read_at timestamptz, activity_at timestamptz, kind text, database text, usr text, state text,
               application_name text, addr text, port int, connect_time timestamptz, request_time timestamptz, wait_us bigint,
               ptr text, link text, backend_pid int, paired_application text, paired_addr text,
               backend_state text, backend_wait_type text, backend_wait text, backend_query_secs double precision,
               backend_xact_secs double precision, blocking_pids int[], role text, head_pid int, head_state text,
               head_application text, head_query text, head_via_pooler boolean, head_client_application text,
               backend_query text)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE
  v_read timestamptz := pgvigil.pooler_read_at(p_instance_id, p_at);
  v_act  timestamptz;
BEGIN
  IF v_read IS NULL THEN
    RETURN;
  END IF;
  SELECT a.snapshot_at INTO v_act FROM pgvigil.activity_summary a
   WHERE a.instance_id = p_instance_id AND a.snapshot_at BETWEEN v_read - interval '2 minutes' AND v_read + interval '2 minutes'
   ORDER BY abs(extract(epoch FROM a.snapshot_at - v_read)), a.snapshot_at DESC LIMIT 1;
  RETURN QUERY
  WITH conn AS (
    SELECT c.* FROM pgvigil.pooler_conn_sample c
     WHERE c.instance_id = p_instance_id AND c.snapshot_at = v_read AND c.kind IN ('client', 'server')
  ), srv AS (
    SELECT * FROM conn WHERE conn.kind = 'server'
  ), cli AS (
    SELECT * FROM conn WHERE conn.kind = 'client'
  ), ch AS (
    SELECT * FROM pgvigil.blocking_chains(p_instance_id, v_act) WHERE v_act IS NOT NULL
  ), heads AS (
    SELECT DISTINCT ch.head_pid FROM ch WHERE ch.head_pid IS NOT NULL
  ), act AS (
    SELECT s.pid, s.state, s.wait_event_type, s.wait_event, s.blocking_pids, s.application_name, s.query_hash,
           extract(epoch FROM v_act - s.query_start)::float8 AS query_secs, extract(epoch FROM v_act - s.xact_start)::float8 AS xact_secs
      FROM pgvigil.activity_sample s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at = v_act
  ), x AS (
    SELECT c.kind, c.database, c.usr, c.state, c.application_name, c.addr, c.port, c.connect_time, c.request_time, c.wait_us,
           c.ptr, c.link,
           CASE WHEN c.kind = 'server' THEN c.remote_pid ELSE (SELECT s.remote_pid FROM srv s WHERE s.ptr = c.link LIMIT 1) END AS pid,
           CASE WHEN c.kind = 'server' THEN (SELECT k.application_name FROM cli k WHERE k.ptr = c.link LIMIT 1) END AS paired_app,
           CASE WHEN c.kind = 'server' THEN (SELECT k.addr FROM cli k WHERE k.ptr = c.link LIMIT 1)
                ELSE (SELECT s.addr FROM srv s WHERE s.ptr = c.link LIMIT 1) END AS paired_addr
      FROM conn c
  )
  SELECT v_read, v_act, x.kind, x.database, x.usr, x.state, x.application_name, x.addr, x.port, x.connect_time, x.request_time,
         x.wait_us, x.ptr, x.link, x.pid, x.paired_app, x.paired_addr,
         a.state, a.wait_event_type, a.wait_event, a.query_secs, a.xact_secs,
         CASE WHEN a.wait_event_type = 'Lock' THEN a.blocking_pids END,
         CASE WHEN x.pid IS NULL OR a.pid IS NULL THEN NULL
              WHEN EXISTS (SELECT 1 FROM heads h WHERE h.head_pid = x.pid) THEN 'head'
              WHEN EXISTS (SELECT 1 FROM ch WHERE ch.pid = x.pid AND ch.in_cycle AND ch.head_pid IS NULL) THEN 'in a cycle'
              WHEN EXISTS (SELECT 1 FROM ch WHERE ch.pid = x.pid) THEN 'blocked' END,
         hd.head_pid, hd.head_state, ha.application_name, hd.head_query,
         hd.head_pid IS NOT NULL AND EXISTS (SELECT 1 FROM srv s WHERE s.remote_pid = hd.head_pid),
         (SELECT k.application_name FROM srv s JOIN cli k ON k.ptr = s.link WHERE s.remote_pid = hd.head_pid LIMIT 1),
         (SELECT q.query FROM pgvigil.query_text q WHERE q.query_hash = a.query_hash)
    FROM x
    LEFT JOIN act a ON a.pid = x.pid
    -- the chain's head: the backend itself when it heads a chain, else the lowest head its waits lead to
    LEFT JOIN LATERAL (
      SELECT x.pid AS head_pid, a.state AS head_state, (SELECT q.query FROM pgvigil.query_text q WHERE q.query_hash = a.query_hash) AS head_query
       WHERE EXISTS (SELECT 1 FROM heads h WHERE h.head_pid = x.pid)
      UNION ALL
      SELECT ch.head_pid, ch.head_state, ch.head_query FROM ch
       WHERE ch.pid = x.pid AND ch.head_pid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM heads h WHERE h.head_pid = x.pid)
      ORDER BY 1 LIMIT 1) hd ON true
    LEFT JOIN act ha ON ha.pid = hd.head_pid
   ORDER BY CASE x.kind WHEN 'client' THEN 0 ELSE 1 END, x.wait_us DESC NULLS LAST, x.database, x.usr, x.pid;
END $$;
