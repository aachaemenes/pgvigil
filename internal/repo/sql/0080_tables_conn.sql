-- 0080_tables_conn: tables, connections and databases (parity3 task 127; pgwatch's Tables Overview and Health Check,
-- pghero's Space and Connections, DBA Dash's New Databases and Deleted Databases).
--   1. table_activity: the scan and row-change counters of the busiest tables of each database, read every 5 minutes
--      (the table_activity collection), and table_activity_top: the top N tables by sequential scans, inserts,
--      updates and deletes over a window, as the sum of the read-to-read rises.
--   2. conn_sources: every client connection counted per application, user, database and client at each read
--      (the connections collection, every minute; idle sessions included, which activity_sample does not store),
--      and conn_sources_window: one row per source over a window (average, peak, states, share).
--   3. instance_tiles: one instance's tile wall at the end of a window (xmin horizon age, idle in transaction,
--      blocked sessions, longest query, connections used, cache hit) and its safety settings.
--   4. database_changes: databases created and dropped over the last days, on both engines.
-- Every function runs on PostgreSQL 13 (the CI matrix's lowest): no date_bin, no jsonb subscripts.

-- ---------------------------------------------------------------------------------------------------------
-- 1. table activity
-- ---------------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.table_activity (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  dbid           bigint NOT NULL,
  relid          bigint NOT NULL,
  datname        text,
  schema_name    text,
  table_name     text,
  seq_scan       bigint,
  seq_tup_read   bigint,
  idx_scan       bigint,
  n_tup_ins      bigint,
  n_tup_upd      bigint,
  n_tup_del      bigint,
  n_tup_hot_upd  bigint
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS table_activity_rel_idx ON pgvigil.table_activity (instance_id, dbid, relid, snapshot_at);

-- payload: {kind:'table', dbid, relid, datname, schema_name, table_name, seq_scan, seq_tup_read, idx_scan, n_tup_ins,
-- n_tup_upd, n_tup_del, n_tup_hot_upd} per table read, {kind:'collector_error', ...} (the collect step logs those).
CREATE OR REPLACE FUNCTION pgvigil.import_table_activity(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF jsonb_typeof(p_payload) IS DISTINCT FROM 'array'
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'table') THEN
    RETURN;
  END IF;
  PERFORM pgvigil.ensure_month_partition('table_activity', p_snapshot_at);
  INSERT INTO pgvigil.table_activity (instance_id, snapshot_at, dbid, relid, datname, schema_name, table_name, seq_scan,
                                      seq_tup_read, idx_scan, n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd)
  SELECT p_instance_id, p_snapshot_at, (r->>'dbid')::bigint, (r->>'relid')::bigint, r->>'datname', r->>'schema_name',
         r->>'table_name', (r->>'seq_scan')::bigint, (r->>'seq_tup_read')::bigint, (r->>'idx_scan')::bigint,
         (r->>'n_tup_ins')::bigint, (r->>'n_tup_upd')::bigint, (r->>'n_tup_del')::bigint, (r->>'n_tup_hot_upd')::bigint
    FROM (SELECT DISTINCT ON ((r->>'dbid')::bigint, (r->>'relid')::bigint) r
            FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'table') x;
END $$;

-- table_activity_top: per table, the sum of its read-to-read rises over the window; the read before the window's
-- start (up to a day back) is the base of the first rise. A counter that fell (a statistics reset, a crash, a
-- failover) counts its new value for that step (what it rose by since the reset); resets says how many steps did.
-- A table first read inside the window (it joined the busiest set later) counts from that read on: an
-- understatement, said by first_at. rank_* is the table's place by each measure (NULL when it did not move);
-- a row comes back when any of the four ranks is within p_n.
CREATE OR REPLACE FUNCTION pgvigil.table_activity_top(p_instance_id int, p_from timestamptz, p_to timestamptz, p_n int)
RETURNS TABLE (dbid bigint, relid bigint, datname text, schema_name text, table_name text,
               seq_scan bigint, seq_tup_read bigint, idx_scan bigint, n_tup_ins bigint, n_tup_upd bigint, n_tup_del bigint,
               n_tup_hot_upd bigint, first_at timestamptz, last_at timestamptz, steps int, resets int,
               rank_seq int, rank_ins int, rank_upd int, rank_del int)
LANGUAGE sql STABLE AS $$
WITH base AS (
  SELECT coalesce(max(a.snapshot_at), p_from) AS at
    FROM pgvigil.table_activity a
   WHERE a.instance_id = p_instance_id AND a.snapshot_at <= p_from AND a.snapshot_at > p_from - interval '1 day'
), r AS (
  SELECT a.*,
         lag(a.snapshot_at)   OVER w AS p_at,
         lag(a.seq_scan)      OVER w AS p_seq, lag(a.seq_tup_read) OVER w AS p_seqtup, lag(a.idx_scan) OVER w AS p_idx,
         lag(a.n_tup_ins)     OVER w AS p_ins, lag(a.n_tup_upd)    OVER w AS p_upd,    lag(a.n_tup_del) OVER w AS p_del,
         lag(a.n_tup_hot_upd) OVER w AS p_hot
    FROM pgvigil.table_activity a
   WHERE a.instance_id = p_instance_id AND a.snapshot_at >= (SELECT at FROM base) AND a.snapshot_at <= p_to
  WINDOW w AS (PARTITION BY a.dbid, a.relid ORDER BY a.snapshot_at)
), d AS (
  SELECT r.dbid, r.relid,
         (array_agg(r.datname ORDER BY r.snapshot_at DESC))[1] AS datname,
         (array_agg(r.schema_name ORDER BY r.snapshot_at DESC))[1] AS schema_name,
         (array_agg(r.table_name ORDER BY r.snapshot_at DESC))[1] AS table_name,
         sum(CASE WHEN r.seq_scan >= r.p_seq THEN r.seq_scan - r.p_seq ELSE r.seq_scan END) FILTER (WHERE r.p_at IS NOT NULL) AS seq_scan,
         sum(CASE WHEN r.seq_tup_read >= r.p_seqtup THEN r.seq_tup_read - r.p_seqtup ELSE r.seq_tup_read END) FILTER (WHERE r.p_at IS NOT NULL) AS seq_tup_read,
         sum(CASE WHEN r.idx_scan >= r.p_idx THEN r.idx_scan - r.p_idx ELSE r.idx_scan END) FILTER (WHERE r.p_at IS NOT NULL) AS idx_scan,
         sum(CASE WHEN r.n_tup_ins >= r.p_ins THEN r.n_tup_ins - r.p_ins ELSE r.n_tup_ins END) FILTER (WHERE r.p_at IS NOT NULL) AS n_tup_ins,
         sum(CASE WHEN r.n_tup_upd >= r.p_upd THEN r.n_tup_upd - r.p_upd ELSE r.n_tup_upd END) FILTER (WHERE r.p_at IS NOT NULL) AS n_tup_upd,
         sum(CASE WHEN r.n_tup_del >= r.p_del THEN r.n_tup_del - r.p_del ELSE r.n_tup_del END) FILTER (WHERE r.p_at IS NOT NULL) AS n_tup_del,
         sum(CASE WHEN r.n_tup_hot_upd >= r.p_hot THEN r.n_tup_hot_upd - r.p_hot ELSE r.n_tup_hot_upd END) FILTER (WHERE r.p_at IS NOT NULL) AS n_tup_hot_upd,
         min(r.snapshot_at) AS first_at, max(r.snapshot_at) AS last_at,
         count(*) FILTER (WHERE r.p_at IS NOT NULL)::int AS steps,
         count(*) FILTER (WHERE r.p_at IS NOT NULL AND (r.seq_scan < r.p_seq OR r.idx_scan < r.p_idx OR r.n_tup_ins < r.p_ins
                                                         OR r.n_tup_upd < r.p_upd OR r.n_tup_del < r.p_del))::int AS resets
    FROM r
   GROUP BY r.dbid, r.relid
), k AS (
  SELECT d.*,
         CASE WHEN d.seq_scan  > 0 THEN rank() OVER (ORDER BY d.seq_scan  DESC NULLS LAST) END::int AS rank_seq,
         CASE WHEN d.n_tup_ins > 0 THEN rank() OVER (ORDER BY d.n_tup_ins DESC NULLS LAST) END::int AS rank_ins,
         CASE WHEN d.n_tup_upd > 0 THEN rank() OVER (ORDER BY d.n_tup_upd DESC NULLS LAST) END::int AS rank_upd,
         CASE WHEN d.n_tup_del > 0 THEN rank() OVER (ORDER BY d.n_tup_del DESC NULLS LAST) END::int AS rank_del
    FROM d
   WHERE d.steps > 0
)
SELECT k.dbid, k.relid, k.datname, k.schema_name, k.table_name, k.seq_scan::bigint, k.seq_tup_read::bigint, k.idx_scan::bigint,
       k.n_tup_ins::bigint, k.n_tup_upd::bigint, k.n_tup_del::bigint, k.n_tup_hot_upd::bigint, k.first_at, k.last_at, k.steps,
       k.resets, k.rank_seq, k.rank_ins, k.rank_upd, k.rank_del
  FROM k
 WHERE k.rank_seq <= p_n OR k.rank_ins <= p_n OR k.rank_upd <= p_n OR k.rank_del <= p_n
 ORDER BY least(coalesce(k.rank_seq, 2147483647), coalesce(k.rank_ins, 2147483647), coalesce(k.rank_upd, 2147483647),
                coalesce(k.rank_del, 2147483647)), k.datname, k.schema_name, k.table_name
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 2. connection sources
-- ---------------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.conn_sources (
  instance_id       int NOT NULL,
  snapshot_at       timestamptz NOT NULL,
  application_name  text NOT NULL,
  usename           text NOT NULL,
  datname           text NOT NULL,
  client            text NOT NULL,           -- client_hostname or client_addr; 'local socket'; '' = not shown to the login
  total             int NOT NULL,
  active            int NOT NULL,
  idle              int NOT NULL,
  idle_in_txn       int NOT NULL,            -- both idle in transaction states
  waiting_lock      int NOT NULL,
  other             int NOT NULL             -- another state, or none the login may see
) PARTITION BY RANGE (snapshot_at);

-- payload: {kind:'source', application_name, usename, datname, client, total, active, idle, idle_in_txn, waiting_lock,
-- other} per source, and one {kind:'read'} row on every read: a read that found no client session but the collector's
-- own stores one zero row, so the window still counts it as a read (with no connection).
CREATE OR REPLACE FUNCTION pgvigil.import_connections(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF jsonb_typeof(p_payload) IS DISTINCT FROM 'array' THEN
    RETURN;
  END IF;
  PERFORM pgvigil.ensure_month_partition('conn_sources', p_snapshot_at);
  INSERT INTO pgvigil.conn_sources (instance_id, snapshot_at, application_name, usename, datname, client, total, active, idle,
                                    idle_in_txn, waiting_lock, other)
  SELECT p_instance_id, p_snapshot_at, coalesce(r->>'application_name', ''), coalesce(r->>'usename', ''),
         coalesce(r->>'datname', ''), coalesce(r->>'client', ''), coalesce((r->>'total')::int, 0),
         coalesce((r->>'active')::int, 0), coalesce((r->>'idle')::int, 0), coalesce((r->>'idle_in_txn')::int, 0),
         coalesce((r->>'waiting_lock')::int, 0), coalesce((r->>'other')::int, 0)
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'source'
  UNION ALL
  -- the read marker: a zero row, so a read in which no client was connected still counts as a read
  SELECT p_instance_id, p_snapshot_at, '', '', '', '', 0, 0, 0, 0, 0, 0
   WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'read')
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'source');
END $$;

-- conn_sources_window: one row per source over the window, grouped by the dimensions p_by names ('application',
-- 'user', 'database', 'client'; a dimension left out comes back NULL = all of them). Each read's connections are
-- summed per group first, so the peak is the most the group held at one read; the average divides by every read of
-- the window (a read the group was absent from counts 0). share_pct is the group's part of all the window's
-- connections. now_* is the newest read of the window.
CREATE OR REPLACE FUNCTION pgvigil.conn_sources_window(p_instance_id int, p_from timestamptz, p_to timestamptz, p_by text[])
RETURNS TABLE (application_name text, usename text, datname text, client text,
               avg_total numeric, peak_total int, now_total int, avg_active numeric, peak_active int, avg_idle numeric,
               avg_idle_in_txn numeric, peak_idle_in_txn int, peak_waiting_lock int, avg_other numeric,
               share_pct numeric, reads_seen int, reads int, first_seen timestamptz, last_seen timestamptz)
LANGUAGE sql STABLE AS $$
WITH s AS (
  SELECT c.* FROM pgvigil.conn_sources c
   WHERE c.instance_id = p_instance_id AND c.snapshot_at > p_from AND c.snapshot_at <= p_to
), n AS (
  SELECT count(DISTINCT s.snapshot_at)::int AS reads, max(s.snapshot_at) AS last_at FROM s
), g AS (
  SELECT s.snapshot_at,
         CASE WHEN 'application' = ANY (p_by) THEN s.application_name END AS application_name,
         CASE WHEN 'user'        = ANY (p_by) THEN s.usename END          AS usename,
         CASE WHEN 'database'    = ANY (p_by) THEN s.datname END          AS datname,
         CASE WHEN 'client'      = ANY (p_by) THEN s.client END           AS client,
         sum(s.total)::int AS total, sum(s.active)::int AS active, sum(s.idle)::int AS idle,
         sum(s.idle_in_txn)::int AS idle_in_txn, sum(s.waiting_lock)::int AS waiting_lock, sum(s.other)::int AS other
    FROM s
   WHERE s.total > 0
   GROUP BY 1, 2, 3, 4, 5
)
SELECT g.application_name, g.usename, g.datname, g.client,
       round(sum(g.total)::numeric / n.reads, 1), max(g.total), coalesce(sum(g.total) FILTER (WHERE g.snapshot_at = n.last_at), 0)::int,
       round(sum(g.active)::numeric / n.reads, 1), max(g.active), round(sum(g.idle)::numeric / n.reads, 1),
       round(sum(g.idle_in_txn)::numeric / n.reads, 1), max(g.idle_in_txn), max(g.waiting_lock),
       round(sum(g.other)::numeric / n.reads, 1),
       round(100.0 * sum(g.total) / nullif(sum(sum(g.total)) OVER (), 0), 1),
       count(*)::int, n.reads, min(g.snapshot_at), max(g.snapshot_at)
  FROM g CROSS JOIN n
 GROUP BY g.application_name, g.usename, g.datname, g.client, n.reads, n.last_at
 ORDER BY sum(g.total) DESC, g.application_name, g.usename, g.datname, g.client
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 3. the tile wall
-- ---------------------------------------------------------------------------------------------------------

-- instance_tiles: the newest activity summary of the window (oldest_xmin_age is the oldest backend_xmin of a client
-- session; replication slots and prepared transactions hold the horizon too and are on the Replication and Vacuum
-- pages), the cache hit ratio over the window from pg_stat_database (blks_hit / (blks_hit + blks_read), the rises
-- within each statistics epoch), and the safety settings as the newest instance read has them (a setting absent
-- from non_default_settings is at its default: fsync, full_page_writes and synchronous_commit default to on).
CREATE OR REPLACE FUNCTION pgvigil.instance_tiles(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (activity_at timestamptz, total int, max_connections int, conn_used_pct numeric, active int,
               idle_in_txn int, longest_idle_txn_secs int, waiting_lock int, longest_active_secs int, oldest_xmin_age int,
               hit_pct numeric, hit_blocks numeric, read_blocks numeric, settings_at timestamptz, fsync text,
               full_page_writes text, synchronous_commit text, data_checksums text, wal_level text, server_version_num int)
LANGUAGE sql STABLE AS $$
WITH a AS (
  SELECT s.* FROM pgvigil.activity_summary s
   WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
   ORDER BY s.snapshot_at DESC LIMIT 1
), h AS (
  SELECT sum(e.hit) AS hit, sum(e.rd) AS rd
    FROM (SELECT greatest(0, max(d.blks_hit) - min(d.blks_hit)) AS hit, greatest(0, max(d.blks_read) - min(d.blks_read)) AS rd
            FROM pgvigil.dbstats d
           WHERE d.instance_id = p_instance_id AND d.snapshot_at >= p_from AND d.snapshot_at <= p_to
           GROUP BY d.dbid, d.stats_reset, d.epoch) e
), st AS (
  SELECT i.snapshot_at, i.data_checksums, i.wal_level, i.server_version_num,
         (SELECT x->>'value' FROM jsonb_array_elements(coalesce(i.non_default_settings, '[]')) x WHERE x->>'name' = 'fsync' LIMIT 1) AS fsync,
         (SELECT x->>'value' FROM jsonb_array_elements(coalesce(i.non_default_settings, '[]')) x WHERE x->>'name' = 'full_page_writes' LIMIT 1) AS fpw,
         (SELECT x->>'value' FROM jsonb_array_elements(coalesce(i.non_default_settings, '[]')) x WHERE x->>'name' = 'synchronous_commit' LIMIT 1) AS sc
    FROM pgvigil.instance_state i WHERE i.instance_id = p_instance_id
)
SELECT a.snapshot_at, a.total, a.max_connections,
       CASE WHEN a.max_connections > 0 THEN round(100.0 * a.total / a.max_connections, 1) END,
       a.active, a.idle_in_txn + coalesce(a.idle_in_txn_aborted, 0), a.longest_idle_txn_secs, a.waiting_lock,
       a.longest_active_secs, a.oldest_xmin_age,
       CASE WHEN h.hit + h.rd > 0 THEN round(100.0 * h.hit / (h.hit + h.rd), 2) END, h.hit, h.rd,
       st.snapshot_at,
       CASE WHEN st.snapshot_at IS NOT NULL THEN coalesce(st.fsync, 'on') END,
       CASE WHEN st.snapshot_at IS NOT NULL THEN coalesce(st.fpw, 'on') END,
       CASE WHEN st.snapshot_at IS NOT NULL THEN coalesce(st.sc, 'on') END,
       st.data_checksums, st.wal_level, st.server_version_num
  FROM (SELECT 1) one
  LEFT JOIN a ON true
  CROSS JOIN h
  LEFT JOIN st ON true
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 4. new and dropped databases
-- ---------------------------------------------------------------------------------------------------------

-- database_changes: the databases created and dropped in the last p_days days, both engines, newest first.
--   PostgreSQL keeps no creation time: a database counts as new when the databases collection first saw it after the
--   instance's first read (first_seen), created between the read before (created_after) and that read; dropped when a
--   read no longer listed it (is_present false), between its last read (last_seen) and the next read
--   (dropped_by), with the size of its last read.
--   SQL Server: sys.databases.create_date (the backups collection's created_at, UTC; a database created anew under an
--   old name shows its new date), and dropped when the backups read no longer lists it; its size is the newest
--   data + log size the storage collection read for that name, dropped_by the first storage read after last_seen that
--   did not list it.
-- p_instance_id NULL = every active instance.
CREATE OR REPLACE FUNCTION pgvigil.database_changes(p_days int, p_instance_id int DEFAULT NULL)
RETURNS TABLE (instance_id int, instance text, engine text, change text, datname text, at timestamptz,
               created_at timestamptz, created_after timestamptz, first_seen timestamptz, last_seen timestamptz,
               dropped_by timestamptz, size_bytes bigint, owner text)
LANGUAGE sql STABLE AS $$
WITH i AS (
  SELECT x.instance_id, x.name, coalesce(x.engine, 'postgres') AS engine
    FROM pgvigil.instances x
   WHERE x.is_active AND (p_instance_id IS NULL OR x.instance_id = p_instance_id)
), since AS (SELECT now() - make_interval(days => p_days) AS at),
pg_base AS (
  SELECT d.instance_id, min(d.first_seen) AS first_read FROM pgvigil.databases d JOIN i USING (instance_id) GROUP BY d.instance_id
)
-- PostgreSQL: new
SELECT i.instance_id, i.name, i.engine, 'new', d.datname, d.first_seen, NULL::timestamptz,
       (SELECT max(z.snapshot_at) FROM pgvigil.database_sizes z
         WHERE z.instance_id = d.instance_id AND z.snapshot_at < d.first_seen AND z.snapshot_at >= d.first_seen - interval '31 days'),
       d.first_seen, d.snapshot_at, NULL::timestamptz,
       d.size_bytes, d.owner
  FROM pgvigil.databases d JOIN i USING (instance_id) JOIN pg_base b USING (instance_id)
 WHERE i.engine = 'postgres' AND d.first_seen > b.first_read AND d.first_seen > (SELECT at FROM since)
   AND NOT coalesce(d.is_template, false)
UNION ALL
-- PostgreSQL: dropped
SELECT i.instance_id, i.name, i.engine, 'dropped', d.datname, d.snapshot_at, NULL::timestamptz, NULL::timestamptz,
       d.first_seen, d.snapshot_at,
       (SELECT min(z.snapshot_at) FROM pgvigil.database_sizes z
         WHERE z.instance_id = d.instance_id AND z.snapshot_at > d.snapshot_at AND z.snapshot_at <= d.snapshot_at + interval '31 days'),
       d.size_bytes, d.owner
  FROM pgvigil.databases d JOIN i USING (instance_id)
 WHERE i.engine = 'postgres' AND NOT d.is_present AND d.snapshot_at > (SELECT at FROM since)
UNION ALL
-- SQL Server: new (by its own creation time)
SELECT i.instance_id, i.name, i.engine, 'new', s.database_name, s.created_at, s.created_at, NULL::timestamptz,
       NULL::timestamptz, s.snapshot_at, NULL::timestamptz,
       (SELECT z.data_bytes + coalesce(z.log_bytes, 0) FROM pgvigil.mssql_database_size z
         WHERE z.instance_id = s.instance_id AND z.database_name = s.database_name
         ORDER BY z.snapshot_at DESC LIMIT 1),
       NULL::text
  FROM pgvigil.mssql_backup_state s JOIN i USING (instance_id)
 WHERE i.engine = 'sqlserver' AND s.created_at > (SELECT at FROM since) AND NOT coalesce(s.is_snapshot, false)
UNION ALL
-- SQL Server: dropped
SELECT i.instance_id, i.name, i.engine, 'dropped', s.database_name, s.snapshot_at, s.created_at, NULL::timestamptz,
       NULL::timestamptz, s.snapshot_at,
       (SELECT min(z.snapshot_at) FROM pgvigil.mssql_database_size z
         WHERE z.instance_id = s.instance_id AND z.snapshot_at > s.snapshot_at AND z.snapshot_at <= s.snapshot_at + interval '31 days'
           AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_database_size y
                            WHERE y.instance_id = z.instance_id AND y.snapshot_at = z.snapshot_at AND y.database_name = s.database_name)),
       (SELECT z.data_bytes + coalesce(z.log_bytes, 0) FROM pgvigil.mssql_database_size z
         WHERE z.instance_id = s.instance_id AND z.database_name = s.database_name AND z.snapshot_at <= s.snapshot_at + interval '1 day'
         ORDER BY z.snapshot_at DESC LIMIT 1),
       NULL::text
  FROM pgvigil.mssql_backup_state s JOIN i USING (instance_id)
 WHERE i.engine = 'sqlserver' AND NOT s.is_present AND s.snapshot_at > (SELECT at FROM since)
 ORDER BY 6 DESC, 2, 5
$$;
