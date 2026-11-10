-- 0046_dbinfo: the Database info tab and the fleet's top growers (task 37; DBADash's Database tab).
--
-- The facts of a database come from the collections that already read them, joined here, never read twice:
--   databases            owner, encoding, collation and ctype, connection limit, default tablespace, allow
--                        connections, is template, CONNECT for the login, size, xid and mxid age (hourly); this
--                        file adds its comment (pg_database's shared description).
--   database_collations  the locale provider and locale, the recorded and the library's collation version (versions).
--   database_extensions  the extensions installed in it (extensions).
--   storage_state        each tablespace's size (storage, every 15 minutes).
--   database_sizes       the size history (databases); table_sizes the table size history (tables, the top N per database).
--
-- Read functions (the API reads only these):
--   dbinfo(i)                         every database of an instance with its facts, growth over 7 and 30 days and extensions;
--                                     a dropped database stays listed with is_present false until purge() deletes it after the
--                                     retention (the delete rides the wave's join migration, which re-creates purge()).
--   dbinfo_tablespaces(i)             each tablespace, its size and the databases whose default it is.
--   database_size_series(i, f, t, b, n)   the n largest present databases' size per b-second bucket of the window (long form).
--   table_size_series(i, db, f, t, b, n)  the n largest present tables' size per bucket (db NULL = the whole instance).
--   fleet_database_growers(n)         the fleet's databases that grew the most over 7 days, with the 30-day growth.
--   fleet_table_growers(n)            the same for tables, from the oldest day of each window only (see the function).
-- "grown" is the newest size minus the oldest inside the window, NULL until the history spans a day (7 days) or a
-- week (30 days); the per-day slope is growth_per_day (0033) over the same points.

ALTER TABLE pgvigil.databases ADD COLUMN IF NOT EXISTS comment text;

CREATE OR REPLACE FUNCTION pgvigil.import_databases(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.ensure_month_partition('database_sizes', p_snapshot_at);

  INSERT INTO pgvigil.databases AS d (
    instance_id, dbid, datname, snapshot_at, owner, encoding, lc_collate, lc_ctype, is_template, allow_conn, conn_limit,
    tablespace, xid_age, mxid_age, can_connect, size_bytes, comment, first_seen, is_present)
  SELECT p_instance_id, (r->>'dbid')::bigint, r->>'datname', p_snapshot_at, r->>'owner', r->>'encoding', r->>'lc_collate', r->>'lc_ctype',
         (r->>'is_template')::boolean, (r->>'allow_conn')::boolean, (r->>'conn_limit')::int, r->>'tablespace',
         (r->>'xid_age')::bigint, (r->>'mxid_age')::bigint, (r->>'can_connect')::boolean, (r->>'size_bytes')::bigint,
         r->>'comment', p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
  ON CONFLICT (instance_id, dbid) DO UPDATE SET
    datname = EXCLUDED.datname, snapshot_at = EXCLUDED.snapshot_at, owner = EXCLUDED.owner, encoding = EXCLUDED.encoding,
    lc_collate = EXCLUDED.lc_collate, lc_ctype = EXCLUDED.lc_ctype, is_template = EXCLUDED.is_template, allow_conn = EXCLUDED.allow_conn,
    conn_limit = EXCLUDED.conn_limit, tablespace = EXCLUDED.tablespace, xid_age = EXCLUDED.xid_age, mxid_age = EXCLUDED.mxid_age,
    can_connect = EXCLUDED.can_connect, size_bytes = EXCLUDED.size_bytes, comment = EXCLUDED.comment, is_present = true;

  -- a database no longer listed was dropped (or renamed: a rename keeps its oid and updates in place)
  UPDATE pgvigil.databases d SET is_present = false
   WHERE d.instance_id = p_instance_id AND d.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE (r->>'dbid')::bigint = d.dbid);

  INSERT INTO pgvigil.database_sizes (instance_id, snapshot_at, dbid, datname, size_bytes, xid_age)
  SELECT p_instance_id, p_snapshot_at, (r->>'dbid')::bigint, r->>'datname', (r->>'size_bytes')::bigint, (r->>'xid_age')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE NOT (r->>'is_template')::boolean;
END $$;

-- newest minus oldest of the points at or after p_since, NULL when they span less than p_min_span
CREATE OR REPLACE FUNCTION pgvigil.grown_since(p_at timestamptz[], p_bytes bigint[], p_since timestamptz, p_min_span interval)
RETURNS bigint LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN max(t) - min(t) >= p_min_span
              THEN (array_agg(b ORDER BY t DESC))[1] - (array_agg(b ORDER BY t))[1] END
    FROM unnest(p_at, p_bytes) u(t, b)
   WHERE b IS NOT NULL AND t >= p_since
$$;

CREATE OR REPLACE FUNCTION pgvigil.dbinfo(p_instance_id int)
RETURNS TABLE (dbid bigint, datname text, is_present boolean, owner text, encoding text, lc_collate text, lc_ctype text,
               locale_provider text, locale text, collation_recorded text, collation_actual text, collation_mismatch boolean,
               conn_limit int, tablespace text, tablespace_bytes bigint, allow_conn boolean, is_template boolean, can_connect boolean,
               size_bytes bigint, grown_7d_bytes bigint, grown_30d_bytes bigint, growth_7d_per_day numeric, growth_30d_per_day numeric,
               xid_age bigint, mxid_age bigint, extension_count int, extensions text, tables_read bigint, comment text,
               first_seen timestamptz, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
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
    LEFT JOIN LATERAL (
      SELECT pgvigil.grown_since(array_agg(s.snapshot_at), array_agg(s.size_bytes), now() - interval '7 days', interval '1 day') AS grown7,
             pgvigil.grown_since(array_agg(s.snapshot_at), array_agg(s.size_bytes), now() - interval '30 days', interval '7 days') AS grown30,
             pgvigil.growth_per_day(array_agg(s.snapshot_at) FILTER (WHERE s.snapshot_at > now() - interval '7 days'),
                                    array_agg(s.size_bytes) FILTER (WHERE s.snapshot_at > now() - interval '7 days'), interval '1 day') AS g7,
             pgvigil.growth_per_day(array_agg(s.snapshot_at), array_agg(s.size_bytes), interval '7 days') AS g30
        FROM pgvigil.database_sizes s
       WHERE s.instance_id = d.instance_id AND s.dbid = d.dbid AND s.snapshot_at > now() - interval '30 days') g ON d.is_present
   WHERE d.instance_id = p_instance_id
   ORDER BY d.is_present DESC, d.is_template, d.size_bytes DESC NULLS LAST, d.datname
$$;

CREATE OR REPLACE FUNCTION pgvigil.dbinfo_tablespaces(p_instance_id int)
RETURNS TABLE (name text, location text, size_bytes bigint, default_for text, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT s.name, s.location, s.size_bytes,
         (SELECT string_agg(d.datname, ', ' ORDER BY d.datname) FROM pgvigil.databases d
           WHERE d.instance_id = s.instance_id AND d.is_present AND d.tablespace = s.name),
         s.snapshot_at
    FROM pgvigil.storage_state s
   WHERE s.instance_id = p_instance_id AND s.kind = 'tablespace' AND s.is_present
   ORDER BY s.size_bytes DESC NULLS LAST, s.name
$$;

CREATE OR REPLACE FUNCTION pgvigil.database_size_series(p_instance_id int, p_from timestamptz, p_to timestamptz, p_bucket int, p_limit int DEFAULT 8)
RETURNS TABLE (snapshot_at timestamptz, dbid bigint, datname text, size_bytes bigint)
LANGUAGE sql STABLE AS $$
  WITH top AS (SELECT d.dbid, d.datname FROM pgvigil.databases d
                WHERE d.instance_id = p_instance_id AND d.is_present AND NOT coalesce(d.is_template, false)
                ORDER BY d.size_bytes DESC NULLS LAST, d.datname LIMIT p_limit)
  SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / greatest(p_bucket, 60)) * greatest(p_bucket, 60)), s.dbid, top.datname, max(s.size_bytes)
    FROM pgvigil.database_sizes s JOIN top USING (dbid)
   WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
   GROUP BY 1, 2, 3
   ORDER BY 1, 3
$$;

CREATE OR REPLACE FUNCTION pgvigil.table_size_series(p_instance_id int, p_dbid bigint, p_from timestamptz, p_to timestamptz, p_bucket int, p_limit int DEFAULT 8)
RETURNS TABLE (snapshot_at timestamptz, dbid bigint, relid bigint, label text, total_bytes bigint)
LANGUAGE sql STABLE AS $$
  WITH top AS (SELECT t.dbid, t.relid, t.datname || '.' || t.schema_name || '.' || t.table_name AS label FROM pgvigil.tables t
                WHERE t.instance_id = p_instance_id AND t.is_present AND (p_dbid IS NULL OR t.dbid = p_dbid)
                ORDER BY t.total_bytes DESC NULLS LAST, 3 LIMIT p_limit)
  SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / greatest(p_bucket, 60)) * greatest(p_bucket, 60)), s.dbid, s.relid, top.label, max(s.total_bytes)
    FROM pgvigil.table_sizes s JOIN top USING (dbid, relid)
   WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
   GROUP BY 1, 2, 3, 4
   ORDER BY 1, 4
$$;

CREATE OR REPLACE FUNCTION pgvigil.fleet_database_growers(p_limit int DEFAULT 50)
RETURNS TABLE (instance_id int, instance text, platform text, dbid bigint, datname text, size_bytes bigint,
               grown_7d_bytes bigint, grown_7d_pct numeric, grown_30d_bytes bigint, grown_30d_pct numeric, growth_7d_per_day numeric,
               snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH h AS (
    SELECT s.instance_id, s.dbid,
           pgvigil.grown_since(array_agg(s.snapshot_at), array_agg(s.size_bytes), now() - interval '7 days', interval '1 day') AS grown7,
           pgvigil.grown_since(array_agg(s.snapshot_at), array_agg(s.size_bytes), now() - interval '30 days', interval '7 days') AS grown30,
           pgvigil.growth_per_day(array_agg(s.snapshot_at) FILTER (WHERE s.snapshot_at > now() - interval '7 days'),
                                  array_agg(s.size_bytes) FILTER (WHERE s.snapshot_at > now() - interval '7 days'), interval '1 day') AS g7
      FROM pgvigil.database_sizes s
     WHERE s.snapshot_at > now() - interval '30 days'
     GROUP BY s.instance_id, s.dbid)
  SELECT i.instance_id, i.name, i.platform, d.dbid, d.datname, d.size_bytes,
         h.grown7, round(100.0 * h.grown7 / nullif(d.size_bytes - h.grown7, 0), 1),
         h.grown30, round(100.0 * h.grown30 / nullif(d.size_bytes - h.grown30, 0), 1), h.g7, d.snapshot_at
    FROM h
    JOIN pgvigil.databases d ON d.instance_id = h.instance_id AND d.dbid = h.dbid AND d.is_present
    JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
   WHERE coalesce(h.grown7, 0) > 0 OR coalesce(h.grown30, 0) > 0
   ORDER BY h.grown7 DESC NULLS LAST, h.grown30 DESC NULLS LAST, i.name, d.datname
   LIMIT p_limit
$$;

-- The fleet's tables by growth. table_sizes holds an hourly point per tracked table (the top N of every database), so the
-- 30-day history of a fleet is millions of rows: this reads only two one-day slices of it, the oldest day of each window
-- (a point 6 to 7 days old, and 29 to 30 days old), and takes the growth as the table's size now minus the first point of
-- the slice. A table younger than the window has no point there: its growth is NULL here (dbinfo, per instance, reads the
-- whole history). No per-day slope: it would need every point.
CREATE OR REPLACE FUNCTION pgvigil.fleet_table_growers(p_limit int DEFAULT 50)
RETURNS TABLE (instance_id int, instance text, platform text, dbid bigint, relid bigint, datname text, schema_name text, table_name text,
               total_bytes bigint, grown_7d_bytes bigint, grown_7d_pct numeric, grown_30d_bytes bigint, grown_30d_pct numeric,
               snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH o7 AS (
    SELECT DISTINCT ON (s.instance_id, s.dbid, s.relid) s.instance_id, s.dbid, s.relid, s.total_bytes
      FROM pgvigil.table_sizes s
     WHERE s.snapshot_at >= now() - interval '7 days' AND s.snapshot_at < now() - interval '6 days' AND s.total_bytes IS NOT NULL
     ORDER BY s.instance_id, s.dbid, s.relid, s.snapshot_at),
  o30 AS (
    SELECT DISTINCT ON (s.instance_id, s.dbid, s.relid) s.instance_id, s.dbid, s.relid, s.total_bytes
      FROM pgvigil.table_sizes s
     WHERE s.snapshot_at >= now() - interval '30 days' AND s.snapshot_at < now() - interval '29 days' AND s.total_bytes IS NOT NULL
     ORDER BY s.instance_id, s.dbid, s.relid, s.snapshot_at),
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
