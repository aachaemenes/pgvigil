-- 0056: the index inventory (phase 3, task 71; the gap s1 named at wave D's join). Every index of every connectable
-- database with its definition, size and usage, read hourly by the indexes collection (0030's four reads gain a
-- fifth, the inventory: pg_stat_user_indexes joined to pg_index and pg_class) and kept current in index_inventory
-- (one row per index; an index no longer read is kept with is_present = false and purged after the window), with
-- one row per index and UTC day in index_usage_daily: the counters as the FIRST read of that day saw them, so the
-- scans over 7 or 30 days are the difference between today's current row and the day row 7 or 30 days back
-- (monthly partitions, dropped by purge(); a counter below its earlier value means a stats reset or a crash
-- restart and reads as unknown). The problem indexes of index_state stay what they are (the findings); the
-- inventory is the whole list, and index_inventory_read() says which problems an index carries.
-- import_indexes is re-created with the inventory part (0030's body kept as it was); drill_index() falls back to the
-- inventory row for an index with no problem (the index page opens from the inventory grid too).
-- pgvigil.findings is re-created from 0045 UNCHANGED (no new arm) and purge() from 0049 with one partition parent
-- added, so the next join builds from this file (build-join.sh: SRC 0056, ANCHOR 'index_usage_daily').
-- Rights: the reads stay pg_monitor (pg_stat_user_indexes, pg_index, pg_class, pg_am, pg_get_indexdef).

CREATE TABLE IF NOT EXISTS pgvigil.index_inventory (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid           bigint NOT NULL,
  indexrelid     bigint NOT NULL,
  datname        text NOT NULL,
  schema_name    text,
  table_name     text,
  index_name     text,
  relid          bigint,            -- the table's oid (the drill-down's key)
  access_method  text,
  is_unique      boolean,
  is_primary     boolean,
  is_valid       boolean,
  is_partition   boolean,           -- a partition's own index: it follows its parent's and cannot be dropped alone
  columns        text,              -- the key columns, expressions and predicate as pg_get_indexdef prints them
  index_def      text,
  index_bytes    bigint,
  idx_scan       bigint,
  idx_tup_read   bigint,
  idx_tup_fetch  bigint,
  last_idx_scan  timestamptz,       -- PostgreSQL 16 and later; NULL below
  first_seen     timestamptz NOT NULL,
  snapshot_at    timestamptz NOT NULL,   -- the last read that changed the row (a read that changed nothing leaves it)
  is_present     boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid, indexrelid)
);
CREATE INDEX IF NOT EXISTS index_inventory_table ON pgvigil.index_inventory (instance_id, dbid, relid);

-- one row per index and UTC day: the counters as the first read of the day saw them
CREATE TABLE IF NOT EXISTS pgvigil.index_usage_daily (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,     -- the day's start (UTC)
  dbid           bigint NOT NULL,
  indexrelid     bigint NOT NULL,
  idx_scan       bigint,
  idx_tup_read   bigint,
  idx_tup_fetch  bigint,
  index_bytes    bigint
) PARTITION BY RANGE (snapshot_at);
CREATE UNIQUE INDEX IF NOT EXISTS index_usage_daily_key ON pgvigil.index_usage_daily (instance_id, dbid, indexrelid, snapshot_at);

-- payload (0030's rows kept): {kind:'db', ...} per database read, {kind:'index', problem, ...} per finding,
-- {kind:'collector_error', source:'indexes:<db>'} per database that could not be read; and now {kind:'inv', dbid,
-- indexrelid, datname, schema_name, table_name, index_name, relid, access_method, is_unique, is_primary, is_valid,
-- is_partition, columns, index_def, index_bytes, idx_scan, idx_tup_read, idx_tup_fetch, last_idx_scan} per index of a
-- database read. An index of a database read and not in the payload is no longer present.
CREATE OR REPLACE FUNCTION pgvigil.import_indexes(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_day timestamptz := (date_trunc('day', p_snapshot_at AT TIME ZONE 'UTC')) AT TIME ZONE 'UTC';
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_indexes'), p_instance_id);
  INSERT INTO pgvigil.index_databases AS d (instance_id, dbid, datname, snapshot_at, indexes, index_bytes, stats_since, is_replica, is_present)
  SELECT p_instance_id, (r->>'dbid')::bigint, r->>'datname', p_snapshot_at, (r->>'indexes')::int, (r->>'index_bytes')::bigint,
         (r->>'stats_since')::timestamptz, (r->>'is_replica')::boolean, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND r->>'dbid' IS NOT NULL
  ON CONFLICT (instance_id, dbid) DO UPDATE SET datname = EXCLUDED.datname, snapshot_at = EXCLUDED.snapshot_at,
    indexes = EXCLUDED.indexes, index_bytes = EXCLUDED.index_bytes, stats_since = EXCLUDED.stats_since,
    is_replica = EXCLUDED.is_replica, is_present = true;

  INSERT INTO pgvigil.index_state AS s (instance_id, dbid, indexrelid, problem, datname, schema_name, table_name, index_name,
    access_method, index_bytes, table_bytes, idx_scan, covered_by, covered_by_def, index_def, supports_fk, drop_sql, undo_sql,
    first_seen, snapshot_at, is_present)
  SELECT DISTINCT ON ((r->>'dbid')::bigint, (r->>'indexrelid')::bigint, r->>'problem')
         p_instance_id, (r->>'dbid')::bigint, (r->>'indexrelid')::bigint, r->>'problem', r->>'datname', r->>'schema_name',
         r->>'table_name', r->>'index_name', r->>'access_method', (r->>'index_bytes')::bigint, (r->>'table_bytes')::bigint,
         (r->>'idx_scan')::bigint, r->>'covered_by', r->>'covered_by_def', r->>'index_def', (r->>'supports_fk')::boolean,
         r->>'drop_sql', r->>'undo_sql', p_snapshot_at, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'index' AND r->>'dbid' IS NOT NULL AND r->>'indexrelid' IS NOT NULL
     AND r->>'problem' IN ('unused', 'redundant', 'duplicate', 'invalid')
  ON CONFLICT (instance_id, dbid, indexrelid, problem) DO UPDATE SET datname = EXCLUDED.datname, schema_name = EXCLUDED.schema_name,
    table_name = EXCLUDED.table_name, index_name = EXCLUDED.index_name, access_method = EXCLUDED.access_method,
    index_bytes = EXCLUDED.index_bytes, table_bytes = EXCLUDED.table_bytes, idx_scan = EXCLUDED.idx_scan,
    covered_by = EXCLUDED.covered_by, covered_by_def = EXCLUDED.covered_by_def, index_def = EXCLUDED.index_def,
    supports_fk = EXCLUDED.supports_fk, drop_sql = EXCLUDED.drop_sql, undo_sql = EXCLUDED.undo_sql,
    first_seen = CASE WHEN s.is_present THEN s.first_seen ELSE EXCLUDED.first_seen END,
    snapshot_at = EXCLUDED.snapshot_at, is_present = true;

  -- the inventory: a row that changed nothing is left as it is (no dead update on a quiet index)
  INSERT INTO pgvigil.index_inventory AS v (instance_id, dbid, indexrelid, datname, schema_name, table_name, index_name, relid,
    access_method, is_unique, is_primary, is_valid, is_partition, columns, index_def, index_bytes, idx_scan, idx_tup_read,
    idx_tup_fetch, last_idx_scan, first_seen, snapshot_at, is_present)
  SELECT DISTINCT ON ((r->>'dbid')::bigint, (r->>'indexrelid')::bigint)
         p_instance_id, (r->>'dbid')::bigint, (r->>'indexrelid')::bigint, r->>'datname', r->>'schema_name', r->>'table_name',
         r->>'index_name', (r->>'relid')::bigint, r->>'access_method', (r->>'is_unique')::boolean, (r->>'is_primary')::boolean,
         (r->>'is_valid')::boolean, (r->>'is_partition')::boolean, r->>'columns', r->>'index_def', (r->>'index_bytes')::bigint,
         (r->>'idx_scan')::bigint, (r->>'idx_tup_read')::bigint, (r->>'idx_tup_fetch')::bigint, (r->>'last_idx_scan')::timestamptz,
         p_snapshot_at, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'inv' AND r->>'dbid' IS NOT NULL AND r->>'indexrelid' IS NOT NULL
  ON CONFLICT (instance_id, dbid, indexrelid) DO UPDATE SET datname = EXCLUDED.datname, schema_name = EXCLUDED.schema_name,
    table_name = EXCLUDED.table_name, index_name = EXCLUDED.index_name, relid = EXCLUDED.relid, access_method = EXCLUDED.access_method,
    is_unique = EXCLUDED.is_unique, is_primary = EXCLUDED.is_primary, is_valid = EXCLUDED.is_valid, is_partition = EXCLUDED.is_partition,
    columns = EXCLUDED.columns, index_def = EXCLUDED.index_def, index_bytes = EXCLUDED.index_bytes, idx_scan = EXCLUDED.idx_scan,
    idx_tup_read = EXCLUDED.idx_tup_read, idx_tup_fetch = EXCLUDED.idx_tup_fetch, last_idx_scan = EXCLUDED.last_idx_scan,
    first_seen = CASE WHEN v.is_present THEN v.first_seen ELSE EXCLUDED.first_seen END,
    snapshot_at = EXCLUDED.snapshot_at, is_present = true
  WHERE NOT v.is_present
     OR (v.datname, v.schema_name, v.table_name, v.index_name, v.relid, v.access_method, v.is_unique, v.is_primary, v.is_valid,
         v.is_partition, v.columns, v.index_def, v.index_bytes, v.idx_scan, v.idx_tup_read, v.idx_tup_fetch, v.last_idx_scan)
        IS DISTINCT FROM
        (EXCLUDED.datname, EXCLUDED.schema_name, EXCLUDED.table_name, EXCLUDED.index_name, EXCLUDED.relid, EXCLUDED.access_method,
         EXCLUDED.is_unique, EXCLUDED.is_primary, EXCLUDED.is_valid, EXCLUDED.is_partition, EXCLUDED.columns, EXCLUDED.index_def,
         EXCLUDED.index_bytes, EXCLUDED.idx_scan, EXCLUDED.idx_tup_read, EXCLUDED.idx_tup_fetch, EXCLUDED.last_idx_scan);

  -- the day row: the first read of the day writes it, the later reads of the day leave it
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'inv') THEN
    PERFORM pgvigil.ensure_month_partition('index_usage_daily', v_day);
    INSERT INTO pgvigil.index_usage_daily (instance_id, snapshot_at, dbid, indexrelid, idx_scan, idx_tup_read, idx_tup_fetch, index_bytes)
    SELECT DISTINCT ON ((r->>'dbid')::bigint, (r->>'indexrelid')::bigint)
           p_instance_id, v_day, (r->>'dbid')::bigint, (r->>'indexrelid')::bigint, (r->>'idx_scan')::bigint,
           (r->>'idx_tup_read')::bigint, (r->>'idx_tup_fetch')::bigint, (r->>'index_bytes')::bigint
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'inv' AND r->>'dbid' IS NOT NULL AND r->>'indexrelid' IS NOT NULL
    ON CONFLICT (instance_id, dbid, indexrelid, snapshot_at) DO NOTHING;
  END IF;

  -- a database read now: its findings not in this read are gone
  UPDATE pgvigil.index_state s SET is_present = false, snapshot_at = p_snapshot_at
   WHERE s.instance_id = p_instance_id AND s.is_present
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = s.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'index' AND (r->>'dbid')::bigint = s.dbid AND (r->>'indexrelid')::bigint = s.indexrelid
                        AND r->>'problem' = s.problem);
  -- and its inventory rows not in this read (a dropped index); a payload with a db row and no inv rows at all is 0030's
  -- shape (an older collector): the inventory is left alone
  UPDATE pgvigil.index_inventory v SET is_present = false, snapshot_at = p_snapshot_at
   WHERE v.instance_id = p_instance_id AND v.is_present
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'inv')
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = v.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'inv' AND (r->>'dbid')::bigint = v.dbid AND (r->>'indexrelid')::bigint = v.indexrelid);
  -- a database neither read nor in error: dropped, or no longer connectable
  UPDATE pgvigil.index_databases d SET is_present = false, snapshot_at = p_snapshot_at
   WHERE d.instance_id = p_instance_id AND d.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = d.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'collector_error' AND r->>'source' = 'indexes:' || d.datname);
  UPDATE pgvigil.index_state s SET is_present = false, snapshot_at = p_snapshot_at
   WHERE s.instance_id = p_instance_id AND s.is_present
     AND EXISTS (SELECT 1 FROM pgvigil.index_databases d WHERE d.instance_id = s.instance_id AND d.dbid = s.dbid AND NOT d.is_present);
  UPDATE pgvigil.index_inventory v SET is_present = false, snapshot_at = p_snapshot_at
   WHERE v.instance_id = p_instance_id AND v.is_present
     AND EXISTS (SELECT 1 FROM pgvigil.index_databases d WHERE d.instance_id = v.instance_id AND d.dbid = v.dbid AND NOT d.is_present);
END $$;

-- the inventory of one instance (or one of its databases) with the scans over the last 7 and 30 days (NULL without a day
-- row that old, or after a counter went backwards) and the problems the collection lists for the index
CREATE OR REPLACE FUNCTION pgvigil.index_inventory_read(p_instance_id int, p_dbid bigint DEFAULT NULL)
RETURNS TABLE (dbid bigint, indexrelid bigint, datname text, schema_name text, table_name text, index_name text, relid bigint,
               access_method text, is_unique boolean, is_primary boolean, is_valid boolean, is_partition boolean, columns text,
               index_def text, index_bytes bigint, idx_scan bigint, idx_tup_read bigint, idx_tup_fetch bigint, last_idx_scan timestamptz,
               scans_7d bigint, scans_30d bigint, problems text, first_seen timestamptz, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT v.dbid, v.indexrelid, v.datname, v.schema_name, v.table_name, v.index_name, v.relid, v.access_method, v.is_unique,
         v.is_primary, v.is_valid, v.is_partition, v.columns, v.index_def, v.index_bytes, v.idx_scan, v.idx_tup_read, v.idx_tup_fetch,
         v.last_idx_scan,
         CASE WHEN d7.idx_scan IS NOT NULL AND v.idx_scan >= d7.idx_scan THEN v.idx_scan - d7.idx_scan END AS scans_7d,
         CASE WHEN d30.idx_scan IS NOT NULL AND v.idx_scan >= d30.idx_scan THEN v.idx_scan - d30.idx_scan END AS scans_30d,
         (SELECT string_agg(s.problem, ', ' ORDER BY s.problem) FROM pgvigil.index_state s
           WHERE s.instance_id = v.instance_id AND s.dbid = v.dbid AND s.indexrelid = v.indexrelid AND s.is_present) AS problems,
         v.first_seen, v.snapshot_at
    FROM pgvigil.index_inventory v
    LEFT JOIN LATERAL (SELECT d.idx_scan FROM pgvigil.index_usage_daily d
                        WHERE d.instance_id = v.instance_id AND d.dbid = v.dbid AND d.indexrelid = v.indexrelid
                          AND d.snapshot_at <= now() - interval '7 days'
                        ORDER BY d.snapshot_at DESC LIMIT 1) d7 ON true
    LEFT JOIN LATERAL (SELECT d.idx_scan FROM pgvigil.index_usage_daily d
                        WHERE d.instance_id = v.instance_id AND d.dbid = v.dbid AND d.indexrelid = v.indexrelid
                          AND d.snapshot_at <= now() - interval '30 days'
                        ORDER BY d.snapshot_at DESC LIMIT 1) d30 ON true
   WHERE v.instance_id = p_instance_id AND v.is_present AND (p_dbid IS NULL OR v.dbid = p_dbid)
   ORDER BY v.datname, v.schema_name, v.table_name, v.index_bytes DESC NULLS LAST, v.index_name
$$;

-- the fleet root: the largest indexes nobody reads (no scan since the counters started, counted for 7 days at least, on a
-- primary, not behind a constraint, not a partition's), across every instance; and the duplicates across every instance
CREATE OR REPLACE FUNCTION pgvigil.index_inventory_fleet_unused(p_limit int DEFAULT 50)
RETURNS TABLE (instance_id int, instance text, dbid bigint, indexrelid bigint, datname text, schema_name text, table_name text,
               index_name text, index_bytes bigint, idx_scan bigint, stats_since timestamptz, is_replica boolean, index_def text)
LANGUAGE sql STABLE AS $$
  SELECT v.instance_id, i.name, v.dbid, v.indexrelid, v.datname, v.schema_name, v.table_name, v.index_name, v.index_bytes, v.idx_scan,
         d.stats_since, d.is_replica, v.index_def
    FROM pgvigil.index_inventory v
    JOIN pgvigil.instances i ON i.instance_id = v.instance_id AND i.is_active
    JOIN pgvigil.index_databases d ON d.instance_id = v.instance_id AND d.dbid = v.dbid AND d.is_present
   WHERE v.is_present AND v.idx_scan = 0 AND v.is_valid AND NOT v.is_unique AND NOT v.is_primary AND NOT v.is_partition
     AND NOT coalesce(d.is_replica, false) AND d.stats_since <= now() - interval '7 days'
   ORDER BY v.index_bytes DESC NULLS LAST, i.name, v.datname, v.index_name
   LIMIT greatest(p_limit, 1)
$$;

-- drill_index (0047) with the inventory as the fallback: an index with no problem row has its page from the inventory
-- (problem NULL, no DO / UNDO lines); the columns are 0047's
CREATE OR REPLACE FUNCTION pgvigil.drill_index(p_instance_id int, p_dbid bigint, p_indexrelid bigint)
RETURNS TABLE (dbid bigint, indexrelid bigint, datname text, schema_name text, table_name text, relid bigint, index_name text,
               problem text, access_method text, index_bytes bigint, table_bytes bigint, idx_scan bigint, stats_since timestamptz,
               is_replica boolean, covered_by text, covered_by_def text, index_def text, supports_fk boolean, drop_sql text, undo_sql text,
               severity text, suggested text, finding text, is_present boolean, first_seen timestamptz, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT u.* FROM (
  SELECT s.dbid, s.indexrelid, s.datname, s.schema_name, s.table_name,
         (SELECT t.relid FROM pgvigil.tables t WHERE t.instance_id = s.instance_id AND t.dbid = s.dbid
             AND t.schema_name = s.schema_name AND t.table_name = s.table_name AND t.is_present LIMIT 1) AS relid,
         s.index_name, s.problem, s.access_method, s.index_bytes, s.table_bytes, s.idx_scan, d.stats_since, d.is_replica,
         s.covered_by, s.covered_by_def, s.index_def, s.supports_fk, s.drop_sql, s.undo_sql,
         f.severity, f.suggested, f.detail AS finding, s.is_present, s.first_seen, s.snapshot_at
    FROM pgvigil.index_state s
    LEFT JOIN pgvigil.index_databases d ON d.instance_id = s.instance_id AND d.dbid = s.dbid
    LEFT JOIN pgvigil.index_findings f ON s.is_present AND f.instance_id = s.instance_id AND f.setting = s.problem || ' index'
                                      AND f.value = s.datname || ': ' || coalesce(s.schema_name || '.', '') || coalesce(s.index_name, s.indexrelid::text)
   WHERE s.instance_id = p_instance_id AND s.dbid = p_dbid AND s.indexrelid = p_indexrelid
     -- a cleared problem (is_present false) shows only when none is present: the index page and the table page agree
     AND (s.is_present OR NOT EXISTS (SELECT 1 FROM pgvigil.index_state p WHERE p.instance_id = s.instance_id AND p.dbid = s.dbid
                                                                         AND p.indexrelid = s.indexrelid AND p.is_present))
  UNION ALL
  SELECT v.dbid, v.indexrelid, v.datname, v.schema_name, v.table_name, v.relid, v.index_name, NULL::text, v.access_method, v.index_bytes,
         (SELECT t.total_bytes FROM pgvigil.tables t WHERE t.instance_id = v.instance_id AND t.dbid = v.dbid AND t.relid = v.relid AND t.is_present LIMIT 1),
         v.idx_scan, d.stats_since, d.is_replica, NULL::text, NULL::text, v.index_def, NULL::boolean, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, v.is_present, v.first_seen, v.snapshot_at
    FROM pgvigil.index_inventory v
    LEFT JOIN pgvigil.index_databases d ON d.instance_id = v.instance_id AND d.dbid = v.dbid
   WHERE v.instance_id = p_instance_id AND v.dbid = p_dbid AND v.indexrelid = p_indexrelid
     AND NOT EXISTS (SELECT 1 FROM pgvigil.index_state s WHERE s.instance_id = v.instance_id AND s.dbid = v.dbid AND s.indexrelid = v.indexrelid)
  ) u
   ORDER BY u.is_present DESC, CASE u.problem WHEN 'invalid' THEN 0 WHEN 'duplicate' THEN 1 WHEN 'redundant' THEN 2 WHEN 'unused' THEN 3 ELSE 4 END
$$;

-- pgvigil.findings: 0045's definition, unchanged (the inventory adds no finding)
CREATE OR REPLACE VIEW pgvigil.findings AS
WITH v AS (
  SELECT instance_id, snapshot_at, platform, server_version_num, is_replica, name, value, is_set,
         CASE WHEN value ~ '^-?[0-9]+(\.[0-9]+)?$' THEN value::numeric END AS num
    FROM pgvigil.instance_settings
), r(instance_id, name, severity, suggested, platforms, detail, hit) AS (
  SELECT instance_id, name, 'critical', 'on', 'all', 'autovacuum is off: no dead-row cleanup and no anti-wraparound vacuum beyond the forced one',
         value <> 'on' FROM v WHERE name = 'autovacuum'
  UNION ALL SELECT instance_id, name, 'warning', '2', 'all', 'autovacuum_vacuum_cost_delay outside 2-20 ms: 0 (or -1, which takes vacuum_cost_delay, 0 by default) lets autovacuum saturate I/O, above 20 it crawls',
         num > 20 OR num = 0 OR num = -1 FROM v WHERE name = 'autovacuum_vacuum_cost_delay'
  UNION ALL SELECT instance_id, name, 'info', '3', 'self-managed', 'more autovacuum workers share one cost limit, so each runs slower',
         num > 3 AND platform = 'onprem' FROM v WHERE name = 'autovacuum_max_workers'
  UNION ALL SELECT instance_id, name, 'warning', '200000000', 'all', 'autovacuum_freeze_max_age above 800 million leaves little room before wraparound',
         num > 800000000 FROM v WHERE name = 'autovacuum_freeze_max_age'
  UNION ALL SELECT instance_id, name, 'warning', '0.9', 'not aurora', 'a low checkpoint_completion_target writes each checkpoint in a burst (I/O spikes)',
         num < 0.7 AND platform <> 'aurora' FROM v WHERE name = 'checkpoint_completion_target'
  UNION ALL SELECT instance_id, name, 'info', '1800', 'not aurora', 'checkpoints closer than 20 minutes apart: more full-page writes and WAL',
         num < 1200 AND platform <> 'aurora' FROM v WHERE name = 'checkpoint_timeout'
  UNION ALL SELECT instance_id, name, 'info', 'lz4', 'all', 'lz4 compresses TOAST faster than pglz',
         value <> 'lz4' AND server_version_num >= 140000 FROM v WHERE name = 'default_toast_compression'
  UNION ALL SELECT instance_id, name, 'info', 'on', 'self-managed', 'huge pages are not required: a large shared_buffers pays for its page tables in memory and TLB misses',
         value <> 'on' AND platform = 'onprem' FROM v WHERE name = 'huge_pages'
  UNION ALL SELECT instance_id, name, 'warning', '0', 'all', 'idle_session_timeout ends idle pooled connections the application still holds',
         num > 0 FROM v WHERE name = 'idle_session_timeout'
  UNION ALL SELECT instance_id, name, 'info', '5min', 'all', 'no limit on idle-in-transaction sessions: one forgotten transaction holds its locks and pins vacuum',
         num = 0 FROM v WHERE name = 'idle_in_transaction_session_timeout'
  UNION ALL SELECT instance_id, name, 'info', 'off', 'all', 'JIT on globally: short OLTP statements pay compile time; enable it per session for analytics',
         value = 'on' FROM v WHERE name = 'jit'
  UNION ALL SELECT instance_id, name, 'info', 'off', 'all', 'log_hostname makes a DNS lookup per connection',
         value = 'on' FROM v WHERE name = 'log_hostname'
  UNION ALL SELECT instance_id, name, 'info', 'on', 'all', 'lock waits past deadlock_timeout are not logged: blocking leaves no trace in the log',
         value = 'off' FROM v WHERE name = 'log_lock_waits'
  UNION ALL SELECT instance_id, name, 'info', '500', 'self-managed', 'more than 500 connections: use a pooler; every backend costs memory and snapshot work',
         num > 500 AND platform = 'onprem' FROM v WHERE name = 'max_connections'
  UNION ALL SELECT instance_id, name, 'warning', '30000', 'replica', 'under 30 s: queries on the standby are cancelled by replay conflicts',
         num >= 0 AND num < 30000 AND is_replica FROM v WHERE name IN ('max_standby_streaming_delay', 'max_standby_archive_delay')
  UNION ALL SELECT instance_id, name, 'info', '30000', 'replica', 'over 5 min (or -1, unlimited): a long standby query holds replay back and the standby lags',
         (num > 300000 OR num = -1) AND is_replica FROM v WHERE name IN ('max_standby_streaming_delay', 'max_standby_archive_delay')
  UNION ALL SELECT instance_id, name, 'info', '8192', 'not aurora', 'max_wal_size under 8 GB: checkpoints forced by WAL volume under load',
         num < 8192 AND platform <> 'aurora' FROM v WHERE name = 'max_wal_size'
  UNION ALL SELECT instance_id, name, 'info', '2048', 'not aurora', 'min_wal_size under 2 GB: WAL segments removed and re-created between bursts',
         num < 2048 AND platform <> 'aurora' FROM v WHERE name = 'min_wal_size'
  UNION ALL SELECT instance_id, name, 'info', '1.1', 'managed', 'managed storage is SSD-backed: random reads cost about what sequential ones do',
         num > 1.2 AND platform <> 'onprem' FROM v WHERE name = 'random_page_cost'
  UNION ALL SELECT instance_id, name, 'warning', '1', 'all', 'seq_page_cost is the unit every other cost is relative to; change random_page_cost instead',
         num <> 1 FROM v WHERE name = 'seq_page_cost'
  UNION ALL SELECT v.instance_id, v.name, 'warning', 'local', 'all', 'synchronous_standby_names is set with synchronous_commit on / remote_write / remote_apply: every commit waits for a standby (hangs when it is gone)',
         v.value <> '' AND c.value IN ('on', 'remote_write', 'remote_apply') FROM v JOIN v c ON c.instance_id = v.instance_id AND c.name = 'synchronous_commit'
   WHERE v.name = 'synchronous_standby_names'
  UNION ALL SELECT instance_id, name, 'info', 'on', 'all', 'without I/O timing, statement and database read times are not measured',
         value = 'off' FROM v WHERE name = 'track_io_timing'
  UNION ALL SELECT instance_id, name, 'info', CASE WHEN server_version_num >= 150000 THEN 'lz4' ELSE 'on' END, 'not aurora',
         'full-page images go to WAL uncompressed', value = 'off' AND platform <> 'aurora' FROM v WHERE name = 'wal_compression'
  UNION ALL SELECT instance_id, name, 'info', 'fdatasync', 'self-managed', 'fdatasync or open_datasync is the safe and fast choice on Linux',
         value NOT IN ('fdatasync', 'open_datasync') AND platform = 'onprem' FROM v WHERE name = 'wal_sync_method'
  UNION ALL SELECT instance_id, name, 'warning', '60000', 'all', 'wal_sender_timeout 0: a dead standby connection is never noticed',
         num = 0 FROM v WHERE name = 'wal_sender_timeout'
  UNION ALL SELECT instance_id, name, 'warning', '65536', 'all', 'a global work_mem above 96 MB is multiplied by every sort and hash of every session',
         num > 98304 FROM v WHERE name = 'work_mem'
  UNION ALL SELECT instance_id, name, 'critical', 'off', 'all', 'zero_damaged_pages hides corruption by zeroing the damaged page (silent data loss)',
         value = 'on' FROM v WHERE name = 'zero_damaged_pages'
), c(instance_id, name, severity, suggested, platforms, detail, hit) AS (
  -- pg-collector's observations on settings (its autovacuum-off one is pg_gather's above)
  SELECT instance_id, name, 'critical', 'on', 'all', 'track_counts is off: autovacuum cannot see which tables need it and pg_stat_* stay empty',
         value <> 'on' FROM v WHERE name = 'track_counts'
  UNION ALL SELECT instance_id, name, 'warning', 'on', 'all', 'a planner method is switched off for every session: plans that need it degrade',
         value <> 'on' FROM v WHERE name IN ('enable_indexscan', 'enable_indexonlyscan')
  UNION ALL SELECT instance_id, name, 'warning', 'on', 'all', 'synchronous_commit off: the last commits are lost on a crash',
         value = 'off' FROM v WHERE name = 'synchronous_commit'
  UNION ALL SELECT instance_id, name, 'warning', 'none', 'all', 'log_statement all / mod logs every statement or every write: log volume and I/O',
         value IN ('all', 'mod') FROM v WHERE name = 'log_statement'
  UNION ALL SELECT instance_id, name, 'warning', '-1', 'all', 'log_min_duration_statement 0 logs every statement with its duration',
         num = 0 FROM v WHERE name = 'log_min_duration_statement'
  UNION ALL SELECT instance_id, name, 'warning', 'warning', 'all', 'a debug log level writes internal detail for every operation',
         value LIKE 'debug%' FROM v WHERE name = 'log_min_messages'
  UNION ALL SELECT instance_id, name, 'warning', 'off', 'all', 'per-statement parser / planner / executor statistics or parse-tree dumps go to the log',
         value = 'on' FROM v WHERE name IN ('log_parser_stats', 'log_planner_stats', 'log_executor_stats', 'log_statement_stats',
                                            'debug_print_parse', 'debug_print_rewritten', 'debug_print_plan')
  UNION ALL SELECT instance_id, name, 'info', '200000000', 'all', 'autovacuum_freeze_max_age above the 200 million default: anti-wraparound vacuums start later and do more at once',
         num > 200000000 AND num <= 800000000 FROM v WHERE name = 'autovacuum_freeze_max_age'
)
SELECT DISTINCT ON (x.instance_id, x.setting, x.value, x.detail) x.*
  FROM (
    SELECT v.instance_id, r.severity, r.name AS setting, v.value, v.is_set, r.suggested, r.platforms, r.detail,
           'pg_gather' AS source, v.snapshot_at AS at
      FROM r JOIN v ON v.instance_id = r.instance_id AND v.name = r.name AND r.hit
    UNION ALL
    SELECT v.instance_id, c.severity, c.name, v.value, v.is_set, c.suggested, c.platforms, c.detail, 'pg-collector', v.snapshot_at
      FROM c JOIN v ON v.instance_id = c.instance_id AND v.name = c.name AND c.hit
    UNION ALL
    -- pg-collector: a database's frozen-xid age past 300 million (the databases collection's xid_age)
    SELECT d.instance_id, CASE WHEN d.xid_age >= 1000000000 THEN 'critical' ELSE 'warning' END, 'database xid age',
           d.datname || ': ' || d.xid_age::text, true, 'under 300000000', 'all',
           'the oldest unfrozen transaction in the database is over 300 million old: find what holds vacuum back (a long transaction, a slot, a prepared transaction)',
           'pg-collector', d.snapshot_at
      FROM pgvigil.databases d
     WHERE d.is_present AND NOT coalesce(d.is_template, false) AND d.xid_age >= 300000000
    UNION ALL
    -- pg-collector: an inactive replication slot (the replication collection's latest read)
    SELECT s.instance_id, 'warning', 'inactive replication slot', s.key, true, 'drop it or reconnect its consumer', 'all',
           'an inactive slot keeps WAL and, for a logical slot, the catalog xmin: disk fills and vacuum is held back',
           'pg-collector', s.snapshot_at
      FROM pgvigil.replication_latest s
     WHERE s.kind = 'slot' AND NOT coalesce(s.active, false) AND NOT coalesce((s.detail->>'synced')::boolean, false)
    UNION ALL
    -- the host collection (0021): CPU over 90 % for 10 minutes, swap used, a disk under 10 % free
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.host_findings
    UNION ALL
    -- the storage forecast (0033): a volume full within 30 days (the free-% rule is host_findings', above)
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.storage_findings
    UNION ALL
    -- the vacuum collections (0024): over the threshold for hours, wraparound, a long or lock-waiting vacuum
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.vacuum_findings
     WHERE setting <> 'autovacuum off'
    UNION ALL
    -- the extensions collection (0019): outdated, preload and setting rules per extension
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.extension_findings
    UNION ALL
    -- the versions collection (0035): a deprecated engine version, pending maintenance, a changed collation version
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.version_findings
    UNION ALL
    -- the IO collection (0031): burst balance, queue depth, latency, the DMS instance's IO
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.io_findings
    UNION ALL
    -- the job report (0027): failing repeatedly, a run over twice its average, a missed schedule
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.job_report_findings
    UNION ALL
    -- the roles collection (0020): a superuser beyond the platform's own, CREATEROLE / BYPASSRLS on an application role, the monitoring login without pg_monitor, a role granted on every database, a login without a way in
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.role_findings
    UNION ALL
    -- the backups collection (0022): the archiver failing, the last archive older than the threshold while WAL waits, retention under 7 days, no snapshot in 24 h
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.backup_findings
    UNION ALL
    -- the corruption column (0023): checksums off, ignore_checksum_failure on, a corruption event in 24 h, amcheck damage
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.corruption_findings WHERE setting <> 'zero_damaged_pages'
    UNION ALL
    -- the plans slice (0029): estimates off by 10x, spills, a nested loop over a large outer, a filter removing most rows, a lossy bitmap scan, index-only heap fetches, JIT, trigger time, workers not launched, a CTE scanned twice
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.plan_findings
    UNION ALL
    -- the indexes collection (0030): invalid and duplicate indexes (warning), redundant and unused ones (info)
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.index_findings
  ) x
 ORDER BY x.instance_id, x.setting, x.value, x.detail;

-- purge(): 0049's body with index_usage_daily among the partition parents it drops
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
       AND p.relname IN ('activity_sample', 'statements_delta', 'dbstats', 'serverstats', 'iostats', 'replication_sample', 'database_sizes',
                         'log_events', 'dms_task_sample', 'table_sizes',
                         'host_sample', 'host_disk_history', 'host_io', 'storage_sample',
                         'vacuum_sample', 'cloud_io_sample', 'dms_ri_sample', 'backup_sample', 'amcheck_runs', 'wait_sample', 'index_usage_daily')
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
  DELETE FROM pgvigil.dms_table_stats WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.dms_tasks WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.dms_instances WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- tables out of the top N (or dropped) and databases gone, for longer than the retention
  DELETE FROM pgvigil.tables WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.table_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- volumes and storage objects no longer present, for longer than the retention (0021, 0033)
  DELETE FROM pgvigil.host_disks WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.storage_state WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- vacuum runs last seen before the retention, and the tables and databases no longer present (0024)
  DELETE FROM pgvigil.vacuum_runs WHERE last_seen < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.vacuum_tables WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.vacuum_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- extensions, their settings and per-database rows no longer present (0019; extension_history stays whole)
  DELETE FROM pgvigil.instance_extensions WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.instance_extension_settings WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.database_extensions WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- pending maintenance actions and database collations no longer present (0035)
  DELETE FROM pgvigil.version_pending WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.database_collations WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- the roles collection (0020): the current tables lose their absent rows after the retention; role_history,
  -- role_state and role_member_closure stay whole
  DELETE FROM pgvigil.role_attributes WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.role_members WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.role_databases WHERE NOT is_present AND read_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.acl_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.acl_schemas WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.acl_default_privileges WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.hba_rules WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- backup rows no longer present (0022: a snapshot AWS aged out, an archiver or cloud row of a resource the config no longer names; backup_sample is a partition parent above)
  DELETE FROM pgvigil.backup_state WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- plans older than the window (0029: a current table, one row per plan_key updated in place)
  DELETE FROM pgvigil.plans WHERE captured_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- indexes and their databases no longer present (0030; wait_profile_current, statements_monitor_total and statements_monitor_seen stay whole)
  DELETE FROM pgvigil.index_state WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.index_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- pg_stat_monitor totals whose statements_current row is gone (0030: one row per key, as statements_current)
  DELETE FROM pgvigil.statements_monitor_total t WHERE NOT EXISTS (SELECT 1 FROM pgvigil.statements_current c WHERE c.instance_id = t.instance_id AND c.dbid = t.dbid AND c.userid = t.userid AND c.queryid = t.queryid AND c.toplevel = t.toplevel);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- databases gone longer than the retention (0046: a dropped database goes absent at the next hourly read)
  DELETE FROM pgvigil.databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- the index inventory's rows gone longer than the retention (0056; its day rows go with their partitions)
  DELETE FROM pgvigil.index_inventory WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  RETURN n;
END $$;
