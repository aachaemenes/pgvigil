-- 0050: the join 49 review's two read shapes, re-created from 0046's bodies (a frozen file is never edited).
-- dbinfo(): the growth of every database came from one LATERAL per database over the instance's whole 30-day
-- database_sizes window (dbid only a filter on the (instance_id, snapshot_at) index: a 500-database server visits the
-- window 500 times); it is now one aggregate over the window grouped by dbid. The function also takes an optional
-- database, so the database page reads its one row instead of the whole instance (the old one-argument form is dropped:
-- the two-argument form with its default answers every old call).
-- fleet_table_growers(): the two one-day slices of table_sizes carried no instance_id, so the planner read the whole
-- monthly partition for each (a seq scan for the 7-day slice, the index's second column alone for the 30-day one);
-- both slices now run per active instance through the (instance_id, snapshot_at) index, 1,000 one-day range reads for a
-- fleet of 1,000 instead of two partition scans. The result columns and the ordering are 0046's.

DROP FUNCTION IF EXISTS pgvigil.dbinfo(int);
CREATE FUNCTION pgvigil.dbinfo(p_instance_id int, p_dbid bigint DEFAULT NULL)
RETURNS TABLE (dbid bigint, datname text, is_present boolean, owner text, encoding text, lc_collate text, lc_ctype text,
               locale_provider text, locale text, collation_recorded text, collation_actual text, collation_mismatch boolean,
               conn_limit int, tablespace text, tablespace_bytes bigint, allow_conn boolean, is_template boolean, can_connect boolean,
               size_bytes bigint, grown_7d_bytes bigint, grown_30d_bytes bigint, growth_7d_per_day numeric, growth_30d_per_day numeric,
               xid_age bigint, mxid_age bigint, extension_count int, extensions text, tables_read bigint, comment text,
               first_seen timestamptz, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH g AS (
    SELECT s.dbid,
           pgvigil.grown_since(array_agg(s.snapshot_at), array_agg(s.size_bytes), now() - interval '7 days', interval '1 day') AS grown7,
           pgvigil.grown_since(array_agg(s.snapshot_at), array_agg(s.size_bytes), now() - interval '30 days', interval '7 days') AS grown30,
           pgvigil.growth_per_day(array_agg(s.snapshot_at) FILTER (WHERE s.snapshot_at > now() - interval '7 days'),
                                  array_agg(s.size_bytes) FILTER (WHERE s.snapshot_at > now() - interval '7 days'), interval '1 day') AS g7,
           pgvigil.growth_per_day(array_agg(s.snapshot_at), array_agg(s.size_bytes), interval '7 days') AS g30
      FROM pgvigil.database_sizes s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at > now() - interval '30 days'
       AND (p_dbid IS NULL OR s.dbid = p_dbid)
     GROUP BY s.dbid)
  SELECT d.dbid, d.datname, d.is_present, d.owner, d.encoding, d.lc_collate, d.lc_ctype,
         CASE c.provider WHEN 'c' THEN 'libc' WHEN 'i' THEN 'icu' WHEN 'b' THEN 'builtin' ELSE c.provider END,
         c.locale, c.recorded_version, c.actual_version,
         c.recorded_version IS NOT NULL AND c.actual_version IS NOT NULL AND c.recorded_version <> c.actual_version,
         d.conn_limit, d.tablespace, ts.size_bytes, d.allow_conn, d.is_template, d.can_connect,
         d.size_bytes, g.grown7, g.grown30, g.g7, g.g30, d.xid_age, d.mxid_age,
         coalesce(e.n, 0), e.list, tr.n, d.comment, d.first_seen, d.snapshot_at
    FROM pgvigil.databases d
    LEFT JOIN pgvigil.database_collations c ON c.instance_id = d.instance_id AND c.dbid = d.dbid AND c.is_present
    LEFT JOIN pgvigil.storage_state ts ON ts.instance_id = d.instance_id AND ts.kind = 'tablespace' AND ts.name = d.tablespace AND ts.is_present
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS n, string_agg(x.name || coalesce(' ' || x.version, ''), ', ' ORDER BY x.name) AS list
        FROM pgvigil.database_extensions x
       WHERE x.instance_id = d.instance_id AND x.dbid = d.dbid AND x.is_present) e ON true
    LEFT JOIN LATERAL (
      SELECT count(*) AS n FROM pgvigil.tables t WHERE t.instance_id = d.instance_id AND t.dbid = d.dbid AND t.is_present) tr ON true
    LEFT JOIN g ON g.dbid = d.dbid AND d.is_present
   WHERE d.instance_id = p_instance_id AND (p_dbid IS NULL OR d.dbid = p_dbid)
   ORDER BY d.is_present DESC, d.is_template, d.size_bytes DESC NULLS LAST, d.datname
$$;

CREATE OR REPLACE FUNCTION pgvigil.fleet_table_growers(p_limit int DEFAULT 50)
RETURNS TABLE (instance_id int, instance text, platform text, dbid bigint, relid bigint, datname text, schema_name text, table_name text,
               total_bytes bigint, grown_7d_bytes bigint, grown_7d_pct numeric, grown_30d_bytes bigint, grown_30d_pct numeric,
               snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH o7 AS (
    SELECT x.* FROM pgvigil.instances i
    CROSS JOIN LATERAL (
      SELECT DISTINCT ON (s.dbid, s.relid) s.instance_id, s.dbid, s.relid, s.total_bytes
        FROM pgvigil.table_sizes s
       WHERE s.instance_id = i.instance_id
         AND s.snapshot_at >= now() - interval '7 days' AND s.snapshot_at < now() - interval '6 days' AND s.total_bytes IS NOT NULL
       ORDER BY s.dbid, s.relid, s.snapshot_at) x
     WHERE i.is_active),
  o30 AS (
    SELECT x.* FROM pgvigil.instances i
    CROSS JOIN LATERAL (
      SELECT DISTINCT ON (s.dbid, s.relid) s.instance_id, s.dbid, s.relid, s.total_bytes
        FROM pgvigil.table_sizes s
       WHERE s.instance_id = i.instance_id
         AND s.snapshot_at >= now() - interval '30 days' AND s.snapshot_at < now() - interval '29 days' AND s.total_bytes IS NOT NULL
       ORDER BY s.dbid, s.relid, s.snapshot_at) x
     WHERE i.is_active),
  h AS (
    SELECT t.instance_id, t.dbid, t.relid, t.total_bytes - o7.total_bytes AS grown7, t.total_bytes - o30.total_bytes AS grown30
      FROM pgvigil.tables t
      LEFT JOIN o7 ON o7.instance_id = t.instance_id AND o7.dbid = t.dbid AND o7.relid = t.relid
      LEFT JOIN o30 ON o30.instance_id = t.instance_id AND o30.dbid = t.dbid AND o30.relid = t.relid
     WHERE t.is_present AND (o7.relid IS NOT NULL OR o30.relid IS NOT NULL))
  SELECT i.instance_id, i.name, i.platform, t.dbid, t.relid, t.datname, t.schema_name, t.table_name, t.total_bytes,
         h.grown7, round(100.0 * h.grown7 / nullif(t.total_bytes - h.grown7, 0), 1),
         h.grown30, round(100.0 * h.grown30 / nullif(t.total_bytes - h.grown30, 0), 1), t.snapshot_at
    FROM h
    JOIN pgvigil.tables t ON t.instance_id = h.instance_id AND t.dbid = h.dbid AND t.relid = h.relid
    JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
   WHERE coalesce(h.grown7, 0) > 0 OR coalesce(h.grown30, 0) > 0
   ORDER BY h.grown7 DESC NULLS LAST, h.grown30 DESC NULLS LAST, i.name, t.datname, t.schema_name, t.table_name
   LIMIT p_limit
$$;
