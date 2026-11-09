-- 0033_storage: storage, growth and days until full (phase 2a, task 45; DBADash's drives view for PostgreSQL).
--   storage_state     the current row per instance and object the storage collection reads: the WAL directory,
--                     each tablespace, the RDS volume (allocated, the autoscaling maximum) and the Aurora cluster
--                     volume (VolumeBytesUsed against 128 TiB).
--   storage_sample    their sizes over time (partitioned by month).
--   volume_forecast() every volume with its growth per day over 7 and 30 days and the days until it is full: the
--                     host collection's volumes (host_disks, history host_disk_history; RDS storage measured against
--                     the autoscaling maximum when autoscaling is on) and the Aurora cluster volume.
--   database_growth() each database's size, growth per day over 7 and 30 days and the days to double (database_sizes).
--   table_growth()    the fastest-growing tables over 7 days (table_sizes).
-- A growth figure needs history: the 7-day line at least a day of points, the 30-day line at least 7 days; less
-- = NULL, never a guess. storage_checks feeds the overview (check group 'storage': the Summary column Storage) and
-- storage_findings carries its forecast rule in the findings columns (the join adds it to pgvigil.findings; the
-- free-% finding is host_findings', one per volume).

CREATE TABLE IF NOT EXISTS pgvigil.storage_state (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  kind                 text NOT NULL,          -- wal | tablespace | rds | aurora_volume
  name                 text NOT NULL,          -- pg_wal, the tablespace, the DB instance or cluster identifier
  snapshot_at          timestamptz NOT NULL,
  location             text,                   -- a tablespace's directory (NULL for pg_default / pg_global)
  size_bytes           bigint,                 -- wal, tablespace, aurora_volume
  files                bigint,                 -- wal: segment files
  allocated_bytes      bigint,                 -- rds
  max_allocated_bytes  bigint,                 -- rds: the storage autoscaling maximum
  autoscaling          boolean,                -- rds: storage autoscaling is on (a maximum is set)
  at_maximum           boolean,                -- rds: autoscaling has reached its maximum
  storage_type         text,
  iops                 int,
  throughput           int,
  class                text,
  limit_bytes          bigint,                 -- aurora_volume: 128 TiB
  metrics_at           timestamptz,            -- aurora_volume: the CloudWatch datapoint's time
  first_seen           timestamptz NOT NULL,
  is_present           boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, kind, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.storage_sample (
  instance_id      int NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  kind             text NOT NULL,
  name             text NOT NULL,
  size_bytes       bigint,
  allocated_bytes  bigint
) PARTITION BY RANGE (snapshot_at);

-- payload: {kind:'wal'|'tablespace'|'rds'|'aurora_volume', name, ...} and {kind:'collector_error', source:'storage:<part>', message}.
-- An object no longer listed is marked absent only inside a kind this payload read without an error for it.
CREATE OR REPLACE FUNCTION pgvigil.import_storage(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_storage'), p_instance_id);
  PERFORM pgvigil.ensure_month_partition('storage_sample', p_snapshot_at);

  INSERT INTO pgvigil.storage_state AS s (instance_id, kind, name, snapshot_at, location, size_bytes, files, allocated_bytes,
                                          max_allocated_bytes, autoscaling, at_maximum, storage_type, iops, throughput, class, limit_bytes,
                                          metrics_at, first_seen, is_present)
  SELECT p_instance_id, r->>'kind', r->>'name', p_snapshot_at, r->>'location', (r->>'size_bytes')::bigint, (r->>'files')::bigint,
         (r->>'allocated_bytes')::bigint, (r->>'max_allocated_bytes')::bigint, (r->>'autoscaling')::boolean, (r->>'at_maximum')::boolean, r->>'storage_type',
         (r->>'iops')::int, (r->>'throughput')::int, r->>'class', (r->>'limit_bytes')::bigint, (r->>'metrics_at')::timestamptz,
         p_snapshot_at, true
    FROM (SELECT DISTINCT ON (r->>'kind', r->>'name') r FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' IN ('wal', 'tablespace', 'rds', 'aurora_volume') AND r->>'name' IS NOT NULL) x
  ON CONFLICT (instance_id, kind, name) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, location = EXCLUDED.location, size_bytes = EXCLUDED.size_bytes, files = EXCLUDED.files,
    allocated_bytes = EXCLUDED.allocated_bytes, max_allocated_bytes = EXCLUDED.max_allocated_bytes, autoscaling = EXCLUDED.autoscaling, at_maximum = EXCLUDED.at_maximum,
    storage_type = EXCLUDED.storage_type, iops = EXCLUDED.iops, throughput = EXCLUDED.throughput, class = EXCLUDED.class,
    limit_bytes = EXCLUDED.limit_bytes, metrics_at = EXCLUDED.metrics_at, is_present = true;

  -- absence: only the kinds this payload carries, and never one whose read failed this run
  UPDATE pgvigil.storage_state s SET is_present = false
   WHERE s.instance_id = p_instance_id AND s.is_present
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = s.kind)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = s.kind AND r->>'name' = s.name);

  INSERT INTO pgvigil.storage_sample (instance_id, snapshot_at, kind, name, size_bytes, allocated_bytes)
  SELECT p_instance_id, p_snapshot_at, r->>'kind', r->>'name', (r->>'size_bytes')::bigint, (r->>'allocated_bytes')::bigint
    FROM (SELECT DISTINCT ON (r->>'kind', r->>'name') r FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' IN ('wal', 'tablespace', 'rds', 'aurora_volume') AND r->>'name' IS NOT NULL) x;
END $$;

-- The growth of a series in bytes per day: the least-squares slope over the window, NULL with fewer than
-- three points or when the points span less than p_min_span (a slope from an hour of data is noise).
CREATE OR REPLACE FUNCTION pgvigil.growth_per_day(p_at timestamptz[], p_bytes bigint[], p_min_span interval)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN count(*) >= 3 AND max(t) - min(t) >= p_min_span
              THEN round(regr_slope(b::float8, extract(epoch FROM t) / 86400.0)::numeric, 0) END
    FROM unnest(p_at, p_bytes) u(t, b)
   WHERE b IS NOT NULL
$$;

-- Every volume with its growth and days until full; p_instance_id NULL = the fleet.
--   capacity: the volume's size; an RDS volume with storage autoscaling grows to its maximum, so it is
--   measured against that (autoscaling true says so); the Aurora cluster volume against 128 TiB.
--   headroom: what the database can still write: the free bytes plus what autoscaling may add (a file system's
--   reserved blocks are not free to PostgreSQL, so used + free can be under the size).
--   days_until_full_7 / _30: the headroom over the 7- / 30-day growth per day, NULL when the volume does not grow;
--   days_until_full: the sooner of the two.
CREATE OR REPLACE FUNCTION pgvigil.volume_forecast(p_instance_id int DEFAULT NULL)
RETURNS TABLE (instance_id int, instance text, platform text, volume text, kind text, total_bytes bigint, used_bytes bigint,
               free_bytes bigint, free_pct numeric, capacity_bytes bigint, headroom_bytes bigint, headroom_pct numeric,
               autoscaling boolean, at_maximum boolean, holds_data boolean,
               growth_7d_per_day numeric, growth_30d_per_day numeric, days_until_full_7 numeric, days_until_full_30 numeric,
               days_until_full numeric, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH v AS (
    SELECT d.instance_id, d.mount_point AS volume, CASE WHEN d.mount_point = 'rds:storage' THEN 'rds' ELSE 'host' END AS kind,
           d.total_bytes, coalesce(d.used_bytes, d.total_bytes - d.free_bytes) AS used_bytes, d.free_bytes, d.holds_data, d.snapshot_at,
           CASE WHEN r.autoscaling THEN greatest(r.max_allocated_bytes, d.total_bytes) ELSE d.total_bytes END AS capacity_bytes,
           coalesce(r.autoscaling, false) AS autoscaling, coalesce(r.at_maximum, false) AS at_maximum, g.g7, g.g30
      FROM pgvigil.host_disks d
      LEFT JOIN pgvigil.storage_state r ON r.instance_id = d.instance_id AND r.kind = 'rds' AND r.is_present AND d.mount_point = 'rds:storage'
      -- one read of the volume's 30 days for both lines (the 7-day line is its last 7 days)
      CROSS JOIN LATERAL (
        SELECT pgvigil.growth_per_day(array_agg(h.snapshot_at) FILTER (WHERE h.snapshot_at > now() - interval '7 days'),
                                      array_agg(coalesce(h.used_bytes, h.total_bytes - h.free_bytes)) FILTER (WHERE h.snapshot_at > now() - interval '7 days'),
                                      interval '1 day') AS g7,
               pgvigil.growth_per_day(array_agg(h.snapshot_at), array_agg(coalesce(h.used_bytes, h.total_bytes - h.free_bytes)), interval '7 days') AS g30
          FROM pgvigil.host_disk_history h
         WHERE h.instance_id = d.instance_id AND h.mount_point = d.mount_point AND h.snapshot_at > now() - interval '30 days') g
     WHERE d.is_present AND d.total_bytes > 0 AND (p_instance_id IS NULL OR d.instance_id = p_instance_id)
    UNION ALL
    SELECT a.instance_id, 'aurora:' || a.name, 'aurora_volume', a.limit_bytes, a.size_bytes, a.limit_bytes - a.size_bytes, NULL, a.snapshot_at,
           a.limit_bytes, true, false, g.g7, g.g30
      FROM pgvigil.storage_state a
      CROSS JOIN LATERAL (
        SELECT pgvigil.growth_per_day(array_agg(s.snapshot_at) FILTER (WHERE s.snapshot_at > now() - interval '7 days'),
                                      array_agg(s.size_bytes) FILTER (WHERE s.snapshot_at > now() - interval '7 days'), interval '1 day') AS g7,
               pgvigil.growth_per_day(array_agg(s.snapshot_at), array_agg(s.size_bytes), interval '7 days') AS g30
          FROM pgvigil.storage_sample s
         WHERE s.instance_id = a.instance_id AND s.kind = 'aurora_volume' AND s.name = a.name AND s.snapshot_at > now() - interval '30 days') g
     WHERE a.kind = 'aurora_volume' AND a.is_present AND a.size_bytes IS NOT NULL AND (p_instance_id IS NULL OR a.instance_id = p_instance_id)
  ), w AS (
    -- the headroom is the free space the database can still write into: the volume's free bytes (a file system's
    -- reserved blocks are neither used nor free to PostgreSQL) plus what autoscaling may still add
    SELECT v.*, v.capacity_bytes - v.total_bytes + coalesce(v.free_bytes, v.total_bytes - v.used_bytes) AS headroom_bytes FROM v
  )
  SELECT w.instance_id, i.name, i.platform, w.volume, w.kind, w.total_bytes, w.used_bytes, w.free_bytes,
         round(100.0 * w.free_bytes / nullif(w.total_bytes, 0), 1), w.capacity_bytes, w.headroom_bytes,
         round(100.0 * w.headroom_bytes / nullif(w.capacity_bytes, 0), 1), w.autoscaling, w.at_maximum, w.holds_data, w.g7, w.g30,
         round(w.headroom_bytes / nullif(greatest(w.g7, 0), 0), 1),
         round(w.headroom_bytes / nullif(greatest(w.g30, 0), 0), 1),
         least(round(w.headroom_bytes / nullif(greatest(w.g7, 0), 0), 1), round(w.headroom_bytes / nullif(greatest(w.g30, 0), 0), 1)),
         w.snapshot_at
    FROM w JOIN pgvigil.instances i ON i.instance_id = w.instance_id
   WHERE i.is_active
$$;

-- Each present database: its size now, the growth per day over 7 and 30 days and the days until it doubles at
-- the faster of the two (NULL when it does not grow).
CREATE OR REPLACE FUNCTION pgvigil.database_growth(p_instance_id int)
RETURNS TABLE (dbid bigint, datname text, size_bytes bigint, growth_7d_per_day numeric, growth_30d_per_day numeric,
               days_to_double numeric, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT d.dbid, d.datname, d.size_bytes, x.g7, x.g30,
         round(d.size_bytes / nullif(greatest(coalesce(x.g7, 0), coalesce(x.g30, 0)), 0), 1), d.snapshot_at
    FROM pgvigil.databases d
    CROSS JOIN LATERAL (
      SELECT pgvigil.growth_per_day(array_agg(s.snapshot_at) FILTER (WHERE s.snapshot_at > now() - interval '7 days'),
                                    array_agg(s.size_bytes) FILTER (WHERE s.snapshot_at > now() - interval '7 days'), interval '1 day') AS g7,
             pgvigil.growth_per_day(array_agg(s.snapshot_at), array_agg(s.size_bytes), interval '7 days') AS g30
        FROM pgvigil.database_sizes s
       WHERE s.instance_id = d.instance_id AND s.dbid = d.dbid AND s.snapshot_at > now() - interval '30 days') x
   WHERE d.instance_id = p_instance_id AND d.is_present AND NOT coalesce(d.is_template, false)
   ORDER BY d.size_bytes DESC NULLS LAST
$$;

-- The tables that grew the most per day over the last 7 days (table_sizes: the tables collection's top N), in one
-- pass over the instance's week of history (a lateral per table would re-read it per table).
CREATE OR REPLACE FUNCTION pgvigil.table_growth(p_instance_id int, p_limit int DEFAULT 20)
RETURNS TABLE (datname text, schema_name text, table_name text, total_bytes bigint, growth_7d_per_day numeric, days_to_double numeric)
LANGUAGE sql STABLE AS $$
  SELECT t.datname, t.schema_name, t.table_name, t.total_bytes, x.g7, round(t.total_bytes / nullif(greatest(x.g7, 0), 0), 1)
    FROM (SELECT s.dbid, s.relid, pgvigil.growth_per_day(array_agg(s.snapshot_at), array_agg(s.total_bytes), interval '1 day') AS g7
            FROM pgvigil.table_sizes s
           WHERE s.instance_id = p_instance_id AND s.snapshot_at > now() - interval '7 days'
           GROUP BY s.dbid, s.relid) x
    JOIN pgvigil.tables t ON t.instance_id = p_instance_id AND t.dbid = x.dbid AND t.relid = x.relid
   WHERE t.is_present AND x.g7 > 0
   ORDER BY x.g7 DESC
   LIMIT p_limit
$$;

-- The overview's storage checks (instance_id, severity, check_name, object, at, detail), on volumes read in the last
-- hour (the host check's window): a volume full within 30 days (critical within 7) at the 7- or 30-day growth, and a
-- volume under 10 % free (critical under 5 %) measured as the headroom against the capacity: an RDS volume with
-- autoscaling counts to its maximum (the Disk column's host check measures the allocated size, so the two differ
-- there by design), a file system's reserved blocks count as not free.
CREATE OR REPLACE VIEW pgvigil.storage_checks AS
WITH f AS (SELECT * FROM pgvigil.volume_forecast(NULL) WHERE snapshot_at > now() - interval '1 hour')
SELECT f.instance_id, CASE WHEN f.days_until_full < 7 THEN 'critical' ELSE 'warning' END AS severity,
       'volume full within 30 days' AS check_name, f.volume AS object, f.snapshot_at AS at,
       'full in about ' || f.days_until_full::text || ' days at ' || pg_size_pretty(greatest(f.growth_7d_per_day, f.growth_30d_per_day)::bigint)
       || ' a day; ' || pg_size_pretty(f.headroom_bytes) || ' left of ' || pg_size_pretty(f.capacity_bytes)
       || CASE WHEN f.autoscaling AND f.kind = 'rds' THEN ' (the autoscaling maximum)' ELSE '' END AS detail
  FROM f
 WHERE f.days_until_full < 30
UNION ALL
SELECT f.instance_id, CASE WHEN f.headroom_pct < 5 THEN 'critical' ELSE 'warning' END, 'volume under 10 % free', f.volume, f.snapshot_at,
       f.headroom_pct::text || ' % free: ' || pg_size_pretty(f.headroom_bytes) || ' of ' || pg_size_pretty(f.capacity_bytes)
  FROM f
 WHERE f.headroom_pct < 10;

-- The forecast rule in the findings columns; the join UNION ALLs this into pgvigil.findings. The free-% rule is
-- not repeated here: host_findings (0021) already carries a volume under 10 % free, one finding per volume.
CREATE OR REPLACE VIEW pgvigil.storage_findings AS
SELECT c.instance_id, c.severity, c.check_name AS setting, c.object || ': ' || c.detail AS value, true AS is_set,
       'grow the volume, raise the autoscaling maximum or remove data before the date' AS suggested,
       'all' AS platforms,
       'at the measured growth the volume fills: a full volume stops the server' AS detail,
       'pgvigil storage' AS source, c.at
  FROM pgvigil.storage_checks c
 WHERE c.check_name = 'volume full within 30 days';
