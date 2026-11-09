-- 0006_replication: the HADR page. Senders, the receiver, slots, subscriptions, publications,
-- recovery conflicts and Aurora replica status, one row per object per snapshot in monthly UTC
-- partitions, plus a current view per kind (the newest snapshot of each instance).

CREATE TABLE IF NOT EXISTS pgvigil.replication_sample (
  instance_id        int NOT NULL,
  snapshot_at        timestamptz NOT NULL,
  kind               text NOT NULL,            -- sender | receiver | slot | subscription | publication | conflict | aurora_replica
  key                text NOT NULL,            -- the object's name or pid within its kind
  state              text,                     -- sender state, receiver status, slot wal_status, subscription enabled, aurora server_id
  lag_bytes          bigint,                   -- sender replay lag, slot retained bytes
  lag_secs           double precision,         -- sender replay_lag, receiver replay delay, aurora replica_lag_in_msec / 1000
  active             boolean,                  -- slot active, subscription enabled, sender streaming
  detail             jsonb NOT NULL            -- every column as collected
) PARTITION BY RANGE (snapshot_at);

CREATE OR REPLACE FUNCTION pgvigil.import_replication(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.ensure_month_partition('replication_sample', p_snapshot_at);
  INSERT INTO pgvigil.replication_sample (instance_id, snapshot_at, kind, key, state, lag_bytes, lag_secs, active, detail)
  SELECT p_instance_id, p_snapshot_at, r->>'kind',
         CASE r->>'kind'
           WHEN 'sender'         THEN coalesce(r->>'application_name', '') || '@' || coalesce(r->>'client_addr', '') || '#' || coalesce(r->>'pid', '')
           WHEN 'receiver'       THEN coalesce(r->>'slot_name', r->>'sender_host', 'receiver')
           WHEN 'slot'           THEN r->>'slot_name'
           WHEN 'subscription'   THEN coalesce(r->>'datname', '') || ':' || coalesce(r->>'subname', '')
           WHEN 'publication'    THEN r->>'pubname'
           WHEN 'conflict'       THEN r->>'datname'
           WHEN 'aurora_replica' THEN r->>'server_id'
           ELSE coalesce(r->>'pid', '?') END,
         CASE r->>'kind'
           WHEN 'sender'         THEN r->>'state'
           WHEN 'receiver'       THEN r->>'status'
           WHEN 'slot'           THEN r->>'wal_status'
           WHEN 'subscription'   THEN CASE WHEN (r->>'enabled')::boolean THEN 'enabled' ELSE 'disabled' END
           WHEN 'aurora_replica' THEN r->>'session_id'
           ELSE NULL END,
         CASE r->>'kind'
           WHEN 'sender' THEN (r->>'replay_lag_bytes')::bigint
           WHEN 'slot'   THEN (r->>'retained_bytes')::bigint
           ELSE NULL END,
         CASE r->>'kind'
           WHEN 'sender'         THEN (r->>'replay_lag_secs')::float8
           WHEN 'receiver'       THEN (r->>'replay_delay_secs')::float8
           WHEN 'aurora_replica' THEN (r->>'replica_lag_in_msec')::float8 / 1000.0
           ELSE NULL END,
         CASE r->>'kind'
           WHEN 'sender'       THEN (r->>'state') = 'streaming'
           WHEN 'slot'         THEN (r->>'active')::boolean
           WHEN 'subscription' THEN (r->>'enabled')::boolean
           ELSE NULL END,
         r
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' <> 'collector_error';

  -- a kind that could not be read is reported by the collector as status 'partial' through
  -- log_collection (collection_dates and collection_log); replication_checks lists it
END $$;

-- newest snapshot per instance, every kind (bounded to the last day: a cadence gap longer than
-- that means the instance is stale anyway, and the full scan over every partition is avoided)
CREATE OR REPLACE VIEW pgvigil.replication_latest AS
  SELECT s.*
    FROM pgvigil.replication_sample s
    JOIN (SELECT instance_id, max(snapshot_at) AS snapshot_at
            FROM pgvigil.replication_sample WHERE snapshot_at > now() - interval '1 day' GROUP BY instance_id) l
      ON l.instance_id = s.instance_id AND l.snapshot_at = s.snapshot_at
   WHERE s.snapshot_at > now() - interval '1 day';

-- the daily-check questions, one row each: inactive slots retaining WAL, lagging senders, lost slots
CREATE OR REPLACE VIEW pgvigil.replication_checks AS
  SELECT instance_id, snapshot_at, 'inactive slot retaining WAL' AS check_name, key AS object,
         lag_bytes AS value, 'bytes' AS unit, detail->>'wal_status' AS state
    FROM pgvigil.replication_latest
   WHERE kind = 'slot' AND NOT coalesce(active, false) AND coalesce(lag_bytes, 0) > 0
     AND NOT coalesce((detail->>'synced')::boolean, false)      -- a failover slot synced from the primary is always inactive on a PG17 standby
  UNION ALL
  SELECT instance_id, snapshot_at, 'slot WAL status not reserved', key, lag_bytes, 'bytes', detail->>'wal_status'
    FROM pgvigil.replication_latest
   WHERE kind = 'slot' AND detail->>'wal_status' IN ('unreserved', 'lost')
  UNION ALL
  SELECT instance_id, snapshot_at, 'sender not streaming', key, lag_bytes, 'bytes', state
    FROM pgvigil.replication_latest
   WHERE kind = 'sender' AND state IS DISTINCT FROM 'streaming'
  UNION ALL
  SELECT instance_id, snapshot_at, 'replay lag', key, lag_secs::bigint, 'seconds', state
    FROM pgvigil.replication_latest
   WHERE kind IN ('sender', 'receiver', 'aurora_replica') AND coalesce(lag_secs, 0) > 30
  UNION ALL
  -- a read that failed is a check of its own: an unreadable slot list must not look healthy
  SELECT d.instance_id, d.snapshot_at, 'replication read failed', split_part(d.note, ':', 1), NULL::bigint, NULL, d.note
    FROM pgvigil.collection_dates d
   WHERE d.collection = 'replication' AND d.status = 'partial';

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
       AND p.relname IN ('activity_sample', 'statements_delta', 'dbstats', 'serverstats', 'iostats', 'replication_sample')
       AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    n := n + 1;
  END LOOP;
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
