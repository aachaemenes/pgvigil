-- 0007_databases: the hourly database inventory - a current row per database and a size
-- history (one row per database per snapshot) for growth charts and the wraparound check.

CREATE TABLE IF NOT EXISTS pgvigil.databases (
  instance_id   int NOT NULL,
  dbid          bigint NOT NULL,
  datname       text NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  owner         text,
  encoding      text,
  lc_collate    text,
  lc_ctype      text,
  is_template   boolean,
  allow_conn    boolean,
  conn_limit    int,
  tablespace    text,
  xid_age       bigint,
  mxid_age      bigint,
  can_connect   boolean,
  size_bytes    bigint,
  first_seen    timestamptz NOT NULL,
  is_present    boolean NOT NULL DEFAULT true,      -- false once a snapshot no longer lists it (dropped)
  PRIMARY KEY (instance_id, dbid)
);

CREATE TABLE IF NOT EXISTS pgvigil.database_sizes (
  instance_id   int NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  dbid          bigint NOT NULL,
  datname       text,
  size_bytes    bigint,
  xid_age       bigint
) PARTITION BY RANGE (snapshot_at);

CREATE OR REPLACE FUNCTION pgvigil.import_databases(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.ensure_month_partition('database_sizes', p_snapshot_at);

  INSERT INTO pgvigil.databases AS d (
    instance_id, dbid, datname, snapshot_at, owner, encoding, lc_collate, lc_ctype, is_template, allow_conn, conn_limit,
    tablespace, xid_age, mxid_age, can_connect, size_bytes, first_seen, is_present)
  SELECT p_instance_id, (r->>'dbid')::bigint, r->>'datname', p_snapshot_at, r->>'owner', r->>'encoding', r->>'lc_collate', r->>'lc_ctype',
         (r->>'is_template')::boolean, (r->>'allow_conn')::boolean, (r->>'conn_limit')::int, r->>'tablespace',
         (r->>'xid_age')::bigint, (r->>'mxid_age')::bigint, (r->>'can_connect')::boolean, (r->>'size_bytes')::bigint,
         p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
  ON CONFLICT (instance_id, dbid) DO UPDATE SET
    datname = EXCLUDED.datname, snapshot_at = EXCLUDED.snapshot_at, owner = EXCLUDED.owner, encoding = EXCLUDED.encoding,
    lc_collate = EXCLUDED.lc_collate, lc_ctype = EXCLUDED.lc_ctype, is_template = EXCLUDED.is_template, allow_conn = EXCLUDED.allow_conn,
    conn_limit = EXCLUDED.conn_limit, tablespace = EXCLUDED.tablespace, xid_age = EXCLUDED.xid_age, mxid_age = EXCLUDED.mxid_age,
    can_connect = EXCLUDED.can_connect, size_bytes = EXCLUDED.size_bytes, is_present = true;

  -- a database no longer listed was dropped (or renamed: a rename keeps its oid and updates in place)
  UPDATE pgvigil.databases d SET is_present = false
   WHERE d.instance_id = p_instance_id AND d.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE (r->>'dbid')::bigint = d.dbid);

  INSERT INTO pgvigil.database_sizes (instance_id, snapshot_at, dbid, datname, size_bytes, xid_age)
  SELECT p_instance_id, p_snapshot_at, (r->>'dbid')::bigint, r->>'datname', (r->>'size_bytes')::bigint, (r->>'xid_age')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE NOT (r->>'is_template')::boolean;
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
       AND p.relname IN ('activity_sample', 'statements_delta', 'dbstats', 'serverstats', 'iostats', 'replication_sample', 'database_sizes')
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
