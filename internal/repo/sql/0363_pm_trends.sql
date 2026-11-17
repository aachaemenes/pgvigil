-- 0363 (parity set 2, task 4; the lead 11-17 01:58, brief L167): the history L46 and L47 read.
--
--   pooler_sample.avg_recv / avg_sent   NEW bigint columns: SHOW STATS' bytes received / sent per second, PgBouncer's
--                                       own averages over its stats_period (internal/collect/pgbouncer.go), per database
--                                       and read; NULL on every read before this file (the traffic chart says 'not read').
--   import_pgbouncer                    re-made WHOLE from its newest text, 0081_pooler_clients.sql:62 (bd83f6a5; its only
--                                       other definition, 0061:186, is older; no branch re-creates it after 0081): the two
--                                       columns added to the stats rows' INSERT, nothing else changed. JOIN NOTE: another
--                                       branch that re-creates import_pgbouncer conflicts here and merges by hand.
--   [the per-table I/O history: 'ASK LEAD: PMROWS TABLE HISTORY' 11-17 02:5x - table_activity (0080) extended, or a
--    table_io of its own as answered 01:58; added to this file once answered]
--
-- Locks: ADD COLUMN IF NOT EXISTS with no default takes ACCESS EXCLUSIVE on pooler_sample and its partitions for a
-- catalog change only (no rewrite); CREATE OR REPLACE FUNCTION locks the function only.

ALTER TABLE pgvigil.pooler_sample ADD COLUMN IF NOT EXISTS avg_recv bigint;
ALTER TABLE pgvigil.pooler_sample ADD COLUMN IF NOT EXISTS avg_sent bigint;
COMMENT ON COLUMN pgvigil.pooler_sample.avg_recv IS 'kind stats: SHOW STATS avg_recv - bytes received per second (PgBouncer''s average over its stats_period); NULL before 0363.';
COMMENT ON COLUMN pgvigil.pooler_sample.avg_sent IS 'kind stats: SHOW STATS avg_sent - bytes sent per second; NULL before 0363.';

-- payload: as 0081's - the stats rows carry avg_recv and avg_sent too
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
                                     avg_query_us, total_xact_count, total_query_count, total_wait_us, avg_recv, avg_sent)
  SELECT p_instance_id, p_snapshot_at, r->>'kind', r->>'database', r->>'user', (r->>'cl_active')::int, (r->>'cl_waiting')::int,
         (r->>'sv_active')::int, (r->>'sv_idle')::int, (r->>'sv_used')::int, (r->>'sv_tested')::int, (r->>'sv_login')::int,
         (r->>'maxwait_ms')::float8, r->>'pool_mode', (r->>'pool_size')::int, r->>'pool_size_from', (r->>'xact_rate')::bigint, (r->>'query_rate')::bigint,
         (r->>'avg_wait_us')::bigint, (r->>'avg_query_us')::bigint, (r->>'total_xact_count')::bigint,
         (r->>'total_query_count')::bigint, (r->>'total_wait_us')::bigint,
         (r->>'avg_recv')::bigint, (r->>'avg_sent')::bigint
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
