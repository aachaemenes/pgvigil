-- 0086_diff_grids: the instance diff, connections over time and three grids (parity4 task 132; DBA Dash's Diff menu,
-- Job Stats and fleet Table Size; Darling's Application Connections and PostgreSQL Configuration).
--   1. instance_state.settings_detail: every non-default or pending-restart setting with its unit, boot value, source,
--      context, category and pending_restart (the instance collection's second list), and pg_config_settings: the
--      Configuration page's grid.
--   2. conn_sources_series: the connection sources as a series per bucket (the stacked chart above the grid).
--   3. table_size_fleet: the largest tables of every PostgreSQL instance with their growth over a window.
--   4. the diff: diff_settings, diff_jobs, diff_schema (two instances, or two databases, as they are now),
--      diff_schema_snapshots (one instance at two times) and diff_sides (how far back each store reaches).
-- What the repository holds per engine: settings and jobs on both; schema objects, table sizes and connection
-- sources on PostgreSQL only (the SQL Server collections store none of the three).
-- Every function is LANGUAGE sql STABLE (IMMUTABLE where it reads no table) and runs on PostgreSQL 13 (the CI
-- matrix's lowest): no date_bin, no any_value, no MERGE, no jsonb subscripts.
-- Lock footprint: one ALTER TABLE ... ADD COLUMN without a default (a catalog change, no rewrite).

-- ---------------------------------------------------------------------------------------------------------
-- 1. the settings' detail
-- ---------------------------------------------------------------------------------------------------------

ALTER TABLE pgvigil.instance_state ADD COLUMN IF NOT EXISTS settings_detail jsonb;

-- 0001's import_instance with settings_detail stored beside non_default_settings. The change history still compares
-- name and value of non_default_settings only: a setting that is only pending a restart is not a change yet.
CREATE OR REPLACE FUNCTION pgvigil.import_instance(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  r      jsonb;
  v_old  jsonb;
BEGIN
  r := p_payload -> 0;           -- one row per instance
  IF r IS NULL THEN RETURN; END IF;
  -- two imports of the same instance at once (a one-off collect beside the scheduler)
  -- would both read the same old snapshot and write the same history rows: serialise them
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_instance'), p_instance_id);

  SELECT non_default_settings INTO v_old FROM pgvigil.instance_state WHERE instance_id = p_instance_id;

  -- settings that changed since the last snapshot (added, removed or a new value)
  IF v_old IS NOT NULL THEN
    INSERT INTO pgvigil.instance_setting_history (instance_id, changed_at, name, old_value, new_value)
    SELECT p_instance_id, p_snapshot_at, coalesce(o.name, n.name), o.value, n.value
      FROM (SELECT x->>'name' AS name, x->>'value' AS value FROM jsonb_array_elements(v_old) x) o
      FULL JOIN (SELECT x->>'name' AS name, x->>'value' AS value FROM jsonb_array_elements(r->'non_default_settings') x) n
        ON o.name = n.name
     WHERE o.value IS DISTINCT FROM n.value;
  END IF;

  INSERT INTO pgvigil.instance_state AS s (
    instance_id, snapshot_at, platform, server_version, server_version_num, is_replica, postmaster_start, server_now,
    time_zone, connected_database, connected_user, server_addr, server_port, data_checksums, shared_buffers,
    max_connections, work_mem, wal_level, track_io_timing, log_min_duration_statement, database_count,
    has_pg_stat_statements, has_pg_cron, has_pgagent, has_wait_sampling, has_log_fdw, extensions, non_default_settings,
    settings_detail)
  VALUES (
    p_instance_id, p_snapshot_at, r->>'platform', r->>'server_version', (r->>'server_version_num')::int,
    (r->>'is_replica')::boolean, (r->>'postmaster_start')::timestamptz, (r->>'server_now')::timestamptz,
    r->>'time_zone', r->>'connected_database', r->>'connected_user', r->>'server_addr', (r->>'server_port')::int,
    r->>'data_checksums', r->>'shared_buffers', (r->>'max_connections')::int, r->>'work_mem', r->>'wal_level',
    r->>'track_io_timing', r->>'log_min_duration_statement', (r->>'database_count')::int,
    (r->>'has_pg_stat_statements')::boolean, (r->>'has_pg_cron')::boolean, (r->>'has_pgagent')::boolean,
    (r->>'has_wait_sampling')::boolean, (r->>'has_log_fdw')::boolean, r->'extensions', r->'non_default_settings',
    CASE WHEN jsonb_typeof(r->'settings_detail') = 'array' THEN r->'settings_detail' END)
  ON CONFLICT (instance_id) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, platform = EXCLUDED.platform, server_version = EXCLUDED.server_version,
    server_version_num = EXCLUDED.server_version_num, is_replica = EXCLUDED.is_replica,
    postmaster_start = EXCLUDED.postmaster_start, server_now = EXCLUDED.server_now, time_zone = EXCLUDED.time_zone,
    connected_database = EXCLUDED.connected_database, connected_user = EXCLUDED.connected_user,
    server_addr = EXCLUDED.server_addr, server_port = EXCLUDED.server_port, data_checksums = EXCLUDED.data_checksums,
    shared_buffers = EXCLUDED.shared_buffers, max_connections = EXCLUDED.max_connections, work_mem = EXCLUDED.work_mem,
    wal_level = EXCLUDED.wal_level, track_io_timing = EXCLUDED.track_io_timing,
    log_min_duration_statement = EXCLUDED.log_min_duration_statement, database_count = EXCLUDED.database_count,
    has_pg_stat_statements = EXCLUDED.has_pg_stat_statements, has_pg_cron = EXCLUDED.has_pg_cron,
    has_pgagent = EXCLUDED.has_pgagent, has_wait_sampling = EXCLUDED.has_wait_sampling, has_log_fdw = EXCLUDED.has_log_fdw,
    extensions = EXCLUDED.extensions, non_default_settings = EXCLUDED.non_default_settings,
    settings_detail = EXCLUDED.settings_detail;
END $$;

-- pg_config_settings: one row per setting the newest instance read stored, the ones waiting for a restart first.
--   value and default_value are pg_settings.setting and boot_val (both in the setting's own unit); source is where the
--   value in use comes from; context is what a change needs (postmaster = a restart; sighup = a reload; superuser,
--   user, backend, superuser-backend = a session); pending_restart: the configuration file holds another value than
--   the running server (a postmaster setting edited and not restarted: its source can still read 'default').
--   non_default: the setting is in the server-level non-default list (the change history's list).
-- A read by a collector older than the detail list stores none: the rows then come from non_default_settings with
-- the detail columns NULL and detail_read false.
CREATE OR REPLACE FUNCTION pgvigil.pg_config_settings(p_instance_id int)
RETURNS TABLE (name text, value text, unit text, default_value text, source text, context text, restart_needed boolean,
               pending_restart boolean, category text, non_default boolean, detail_read boolean, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH st AS (
    SELECT s.snapshot_at,
           CASE WHEN jsonb_typeof(s.non_default_settings) = 'array' THEN s.non_default_settings ELSE '[]'::jsonb END AS nd,
           CASE WHEN jsonb_typeof(s.settings_detail) = 'array' THEN s.settings_detail END AS det
      FROM pgvigil.instance_state s WHERE s.instance_id = p_instance_id
  ), x AS (
    SELECT d->>'name' AS name, d->>'value' AS value, d->>'unit' AS unit, d->>'boot_val' AS default_value,
           d->>'source' AS source, d->>'context' AS context, (d->>'context') = 'postmaster' AS restart_needed,
           coalesce((d->>'pending_restart')::boolean, false) AS pending_restart, d->>'category' AS category,
           EXISTS (SELECT 1 FROM jsonb_array_elements(st.nd) n WHERE n->>'name' = d->>'name') AS non_default,
           true AS detail_read, st.snapshot_at
      FROM st, jsonb_array_elements(st.det) d
     WHERE st.det IS NOT NULL
    UNION ALL
    SELECT n->>'name', n->>'value', NULL, NULL, NULL, NULL, NULL, NULL, NULL, true, false, st.snapshot_at
      FROM st, jsonb_array_elements(st.nd) n
     WHERE st.det IS NULL
  )
  SELECT x.name, x.value, x.unit, x.default_value, x.source, x.context, x.restart_needed, x.pending_restart, x.category,
         x.non_default, x.detail_read, x.snapshot_at
    FROM x
   ORDER BY coalesce(x.pending_restart, false) DESC, lower(x.name)
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 2. connection sources over time
-- ---------------------------------------------------------------------------------------------------------

-- conn_sources_series: the window's connections per bucket (p_step_secs wide, aligned to the epoch) and source of
-- one dimension (p_dim: 'application', 'user', 'database' or 'client'). The p_top sources with the most connections
-- over the window keep their name; the rest are summed per read into one folded series (source NULL, folded true,
-- sources = how many it holds). Every bucket with a read carries a row for every series (0 when the source was
-- absent), so a stacked chart has no hole.
--   conns      the sum of the series' connections over the bucket's reads
--   reads      the reads in the bucket (a read with no client connected counts)
--   peak       the most the series held at one read of the bucket
--   avg_conns  conns / reads: the chart's value
-- Per source over the whole window sum(conns) / sum(reads) is conn_sources_window's avg_total (grouped by that
-- dimension alone) and max(peak) its peak_total.
CREATE OR REPLACE FUNCTION pgvigil.conn_sources_series(p_instance_id int, p_from timestamptz, p_to timestamptz, p_dim text,
                                                       p_step_secs int, p_top int DEFAULT 8)
RETURNS TABLE (bucket timestamptz, source text, folded boolean, conns bigint, reads int, peak int, avg_conns numeric,
               sources int, rank int)
LANGUAGE sql STABLE AS $$
WITH s AS (
  SELECT c.snapshot_at,
         CASE p_dim WHEN 'application' THEN c.application_name WHEN 'user' THEN c.usename WHEN 'database' THEN c.datname
                    ELSE c.client END AS source,
         c.total
    FROM pgvigil.conn_sources c
   WHERE c.instance_id = p_instance_id AND c.snapshot_at > p_from AND c.snapshot_at <= p_to
), rd AS (
  SELECT DISTINCT s.snapshot_at,
         to_timestamp(floor(extract(epoch FROM s.snapshot_at) / greatest(p_step_secs, 1)) * greatest(p_step_secs, 1)) AS bucket
    FROM s
), g AS (
  SELECT s.snapshot_at, s.source, sum(s.total)::int AS total FROM s WHERE s.total > 0 GROUP BY s.snapshot_at, s.source
), rk AS (
  SELECT g.source, row_number() OVER (ORDER BY sum(g.total) DESC, g.source)::int AS rn FROM g GROUP BY g.source
), f AS (
  -- per read and series: a top source under its own name, the others as one
  SELECT g.snapshot_at, CASE WHEN rk.rn <= p_top THEN g.source END AS source, rk.rn > p_top AS folded,
         sum(g.total)::int AS total
    FROM g JOIN rk ON rk.source = g.source
   GROUP BY g.snapshot_at, CASE WHEN rk.rn <= p_top THEN g.source END, rk.rn > p_top
), ser AS (
  SELECT CASE WHEN rk.rn <= p_top THEN rk.source END AS source, rk.rn > p_top AS folded, count(*)::int AS sources,
         min(least(rk.rn, p_top + 1))::int AS rank
    FROM rk
   GROUP BY CASE WHEN rk.rn <= p_top THEN rk.source END, rk.rn > p_top
), b AS (
  SELECT rd.bucket, count(*)::int AS reads FROM rd GROUP BY rd.bucket
), v AS (
  SELECT rd.bucket, f.source, f.folded, sum(f.total)::bigint AS conns, max(f.total)::int AS peak
    FROM f JOIN rd ON rd.snapshot_at = f.snapshot_at
   GROUP BY rd.bucket, f.source, f.folded
)
SELECT b.bucket, ser.source, ser.folded, coalesce(v.conns, 0)::bigint, b.reads, coalesce(v.peak, 0),
       round(coalesce(v.conns, 0)::numeric / b.reads, 2), ser.sources, ser.rank
  FROM b CROSS JOIN ser
  LEFT JOIN v ON v.bucket = b.bucket AND v.folded = ser.folded AND v.source IS NOT DISTINCT FROM ser.source
 ORDER BY b.bucket, ser.rank
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 3. the fleet's table sizes
-- ---------------------------------------------------------------------------------------------------------

-- table_size_fleet: the tables of every active PostgreSQL instance at its newest table read of the window, the
-- largest (p_order 'size') or the fastest growing (p_order 'growth') first, p_top rows.
--   The store: table_sizes holds an hourly point per table in the tables collection's top N of its database, so a
--   table outside that top N is not here, and neither is a table the newest read no longer lists.
--   The base of the growth: the instance's last read at or before p_from (two days back at most); an instance first
--   read inside the window, or a table that joined the top N later, counts from its first read inside the window
--   (in_window true: the growth covers less than the window). One read only = no growth (NULL).
--   days = read_at - base_at; bytes_per_day and rows_per_day are the growth over those days.
--   heap, TOAST and index sizes come from pgvigil.tables when it still holds that same read (the newest read of all).
-- Two index range reads per instance (the newest read, the base read) and one more per table absent from the base
-- read; never the whole window.
CREATE OR REPLACE FUNCTION pgvigil.table_size_fleet(p_from timestamptz, p_to timestamptz, p_top int DEFAULT 100,
                                                    p_order text DEFAULT 'size')
RETURNS TABLE (instance_id int, instance text, platform text, dbid bigint, relid bigint, datname text, schema_name text,
               table_name text, total_bytes bigint, heap_bytes bigint, toast_bytes bigint, index_bytes bigint,
               n_live_tup bigint, read_at timestamptz, base_at timestamptz, base_bytes bigint, base_rows bigint,
               in_window boolean, growth_bytes bigint, growth_rows bigint, days numeric, bytes_per_day numeric,
               rows_per_day numeric)
LANGUAGE sql STABLE AS $$
WITH i AS (
  SELECT x.instance_id, x.name, x.platform,
         (SELECT max(s.snapshot_at) FROM pgvigil.table_sizes s
           WHERE s.instance_id = x.instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to) AS read_at,
         coalesce((SELECT max(s.snapshot_at) FROM pgvigil.table_sizes s
                    WHERE s.instance_id = x.instance_id AND s.snapshot_at <= p_from AND s.snapshot_at > p_from - interval '2 days'),
                  (SELECT min(s.snapshot_at) FROM pgvigil.table_sizes s
                    WHERE s.instance_id = x.instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to)) AS base_at
    FROM pgvigil.instances x
   WHERE x.is_active AND coalesce(x.engine, 'postgres') = 'postgres'
), n AS (
  SELECT i.instance_id, i.name, i.platform, i.read_at, i.base_at, s.dbid, s.relid, s.total_bytes, s.n_live_tup
    FROM i JOIN pgvigil.table_sizes s ON s.instance_id = i.instance_id AND s.snapshot_at = i.read_at
   WHERE i.read_at IS NOT NULL AND s.total_bytes IS NOT NULL
), w AS (
  SELECT n.*, coalesce(b.snapshot_at, l.snapshot_at) AS t_base_at, coalesce(b.total_bytes, l.total_bytes) AS base_bytes,
         CASE WHEN b.snapshot_at IS NOT NULL THEN b.n_live_tup ELSE l.n_live_tup END AS base_rows
    FROM n
    LEFT JOIN pgvigil.table_sizes b
      ON b.instance_id = n.instance_id AND b.snapshot_at = n.base_at AND b.dbid = n.dbid AND b.relid = n.relid
     AND b.total_bytes IS NOT NULL AND n.base_at < n.read_at
    LEFT JOIN LATERAL (
      SELECT z.snapshot_at, z.total_bytes, z.n_live_tup
        FROM pgvigil.table_sizes z
       WHERE b.snapshot_at IS NULL AND z.instance_id = n.instance_id AND z.snapshot_at > n.base_at AND z.snapshot_at < n.read_at
         AND z.dbid = n.dbid AND z.relid = n.relid AND z.total_bytes IS NOT NULL
       ORDER BY z.snapshot_at LIMIT 1) l ON true
), o AS (
  SELECT w.*, w.total_bytes - w.base_bytes AS growth_bytes, w.n_live_tup - w.base_rows AS growth_rows,
         round((extract(epoch FROM w.read_at - w.t_base_at) / 86400.0)::numeric, 2) AS days
    FROM w
)
SELECT o.instance_id, o.name, o.platform, o.dbid, o.relid, t.datname, t.schema_name, t.table_name, o.total_bytes,
       CASE WHEN t.snapshot_at = o.read_at THEN t.heap_bytes END, CASE WHEN t.snapshot_at = o.read_at THEN t.toast_bytes END,
       CASE WHEN t.snapshot_at = o.read_at THEN t.index_bytes END,
       o.n_live_tup, o.read_at, o.t_base_at, o.base_bytes, o.base_rows, o.t_base_at > p_from,
       o.growth_bytes, o.growth_rows, o.days,
       CASE WHEN extract(epoch FROM o.read_at - o.t_base_at) > 0
            THEN round((o.growth_bytes * 86400.0 / extract(epoch FROM o.read_at - o.t_base_at))::numeric, 0) END,
       CASE WHEN extract(epoch FROM o.read_at - o.t_base_at) > 0
            THEN round((o.growth_rows * 86400.0 / extract(epoch FROM o.read_at - o.t_base_at))::numeric, 0) END
  FROM o
  JOIN pgvigil.tables t ON t.instance_id = o.instance_id AND t.dbid = o.dbid AND t.relid = o.relid
 ORDER BY CASE WHEN p_order = 'growth' THEN o.growth_bytes END DESC NULLS LAST, o.total_bytes DESC, o.name, t.datname,
          t.schema_name, t.table_name
 LIMIT greatest(p_top, 1)
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 4. the diff
-- ---------------------------------------------------------------------------------------------------------

-- diff_settings_at: an instance's settings as they were at p_at (NULL = as last read).
--   PostgreSQL: the server-level non-default settings (instance_state), rolled back through
--   instance_setting_history: a setting's first change after p_at carries, as its old value, the value at p_at (no
--   old value = not set then: no row). The history starts at the instance's first read.
--   SQL Server: sys.configurations' value in use (mssql_config), or the previous value when the last change came
--   after p_at. The store keeps ONE earlier value per setting: an as-of read is exact back to the change before
--   last only.
CREATE OR REPLACE FUNCTION pgvigil.diff_settings_at(p_instance_id int, p_at timestamptz)
RETURNS TABLE (name text, value text)
LANGUAGE sql STABLE AS $$
  WITH e AS (
    SELECT coalesce(i.engine, 'postgres') AS engine FROM pgvigil.instances i WHERE i.instance_id = p_instance_id
  ), cur AS (
    SELECT x->>'name' AS name, x->>'value' AS value
      FROM pgvigil.instance_state st,
           jsonb_array_elements(CASE WHEN jsonb_typeof(st.non_default_settings) = 'array' THEN st.non_default_settings ELSE '[]'::jsonb END) x
     WHERE st.instance_id = p_instance_id
  ), back AS (
    SELECT DISTINCT ON (h.name) h.name, h.old_value
      FROM pgvigil.instance_setting_history h
     WHERE h.instance_id = p_instance_id AND p_at IS NOT NULL AND h.changed_at > p_at
     ORDER BY h.name, h.changed_at
  ), pg AS (
    SELECT coalesce(b.name, c.name) AS name, CASE WHEN b.name IS NOT NULL THEN b.old_value ELSE c.value END AS value
      FROM cur c FULL JOIN back b ON b.name = c.name
  )
  SELECT pg.name, pg.value FROM pg, e WHERE e.engine = 'postgres' AND pg.value IS NOT NULL
  UNION ALL
  SELECT c.name, (CASE WHEN p_at IS NOT NULL AND c.changed_at > p_at THEN c.previous_in_use ELSE c.value_in_use END)::text
    FROM pgvigil.mssql_config c, e
   WHERE e.engine = 'sqlserver' AND c.instance_id = p_instance_id AND c.is_present
     AND (CASE WHEN p_at IS NOT NULL AND c.changed_at > p_at THEN c.previous_in_use ELSE c.value_in_use END) IS NOT NULL
$$;

-- diff_settings: side a against side b, one row per setting either side holds. status: 'same', 'different',
-- 'only a', 'only b' (PostgreSQL: the other side has the setting at its default).
CREATE OR REPLACE FUNCTION pgvigil.diff_settings(p_a int, p_at_a timestamptz, p_b int, p_at_b timestamptz)
RETURNS TABLE (name text, a_value text, b_value text, status text)
LANGUAGE sql STABLE AS $$
  SELECT coalesce(a.name, b.name), a.value, b.value,
         CASE WHEN a.name IS NULL THEN 'only b' WHEN b.name IS NULL THEN 'only a'
              WHEN a.value = b.value THEN 'same' ELSE 'different' END
    FROM pgvigil.diff_settings_at(p_a, p_at_a) a
    FULL JOIN pgvigil.diff_settings_at(p_b, p_at_b) b ON b.name = a.name
   ORDER BY lower(coalesce(a.name, b.name))
$$;

-- diff_jobs_at: an instance's jobs as they were at p_at (NULL = as last read): the newest version of each job at or
-- before p_at (job_versions, both engines), the dropped ones left out.
CREATE OR REPLACE FUNCTION pgvigil.diff_jobs_at(p_instance_id int, p_at timestamptz)
RETURNS TABLE (scheduler text, job_id text, job_name text, definition jsonb, valid_from timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT x.scheduler, x.job_id, x.job_name, x.definition, x.valid_from
    FROM (SELECT DISTINCT ON (v.scheduler, v.job_id) v.scheduler, v.job_id, v.job_name, v.definition, v.valid_from, v.dropped
            FROM pgvigil.job_versions v
           WHERE v.instance_id = p_instance_id AND (p_at IS NULL OR v.valid_from <= p_at)
           ORDER BY v.scheduler, v.job_id, v.valid_from DESC) x
   WHERE NOT x.dropped
$$;

-- diff_job_fields: the fields that differ between two job definitions, [{field, a, b}] by field (jsonb_flat's
-- paths). p_strip_ids: between two servers the ' #<id>' a schedule's or a step's key ends in is taken out of the path
-- (two servers number the same schedule differently); two keys that then read the same are compared as one, their
-- values joined by ' | '.
CREATE OR REPLACE FUNCTION pgvigil.diff_job_fields(p_a jsonb, p_b jsonb, p_strip_ids boolean)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  WITH a AS (
    SELECT CASE WHEN p_strip_ids THEN regexp_replace(f.path, ' #[0-9]+( / |$)', '\1', 'g') ELSE f.path END AS path,
           string_agg(f.value, ' | ' ORDER BY f.value) AS value
      FROM pgvigil.jsonb_flat(p_a) f GROUP BY 1
  ), b AS (
    SELECT CASE WHEN p_strip_ids THEN regexp_replace(f.path, ' #[0-9]+( / |$)', '\1', 'g') ELSE f.path END AS path,
           string_agg(f.value, ' | ' ORDER BY f.value) AS value
      FROM pgvigil.jsonb_flat(p_b) f GROUP BY 1
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('field', path, 'a', a.value, 'b', b.value) ORDER BY path), '[]'::jsonb)
    FROM a FULL JOIN b USING (path)
   WHERE a.value IS DISTINCT FROM b.value
$$;

-- diff_jobs: side a's jobs against side b's. One instance at two times: a job is matched by its scheduler and id.
-- Two instances: by scheduler and name (a job without a name: its command), and among jobs of one name by their
-- order (the ids of two servers say nothing about each other). status: 'same', 'different' (fields = what differs),
-- 'only a', 'only b'.
CREATE OR REPLACE FUNCTION pgvigil.diff_jobs(p_a int, p_at_a timestamptz, p_b int, p_at_b timestamptz)
RETURNS TABLE (scheduler text, job_name text, a_job_id text, b_job_id text, status text, fields jsonb,
               a_valid_from timestamptz, b_valid_from timestamptz)
LANGUAGE sql STABLE AS $$
  -- the match key is computed per side: PostgreSQL refuses a FULL JOIN whose condition is not a plain equality
  WITH a AS (
    SELECT j.*, CASE WHEN p_a = p_b THEN j.job_id
                     ELSE coalesce(j.job_name, j.definition->>'command', '') || ' #'
                          || row_number() OVER (PARTITION BY j.scheduler, coalesce(j.job_name, j.definition->>'command', '') ORDER BY j.job_id) END AS k
      FROM pgvigil.diff_jobs_at(p_a, p_at_a) j
  ), b AS (
    SELECT j.*, CASE WHEN p_a = p_b THEN j.job_id
                     ELSE coalesce(j.job_name, j.definition->>'command', '') || ' #'
                          || row_number() OVER (PARTITION BY j.scheduler, coalesce(j.job_name, j.definition->>'command', '') ORDER BY j.job_id) END AS k
      FROM pgvigil.diff_jobs_at(p_b, p_at_b) j
  ), m AS (
    SELECT coalesce(a.scheduler, b.scheduler) AS scheduler, coalesce(b.job_name, a.job_name) AS job_name,
           a.job_id AS a_job_id, b.job_id AS b_job_id, a.k AS ak, b.k AS bk,
           CASE WHEN a.k IS NOT NULL AND b.k IS NOT NULL THEN pgvigil.diff_job_fields(a.definition, b.definition, p_a <> p_b) END AS fields,
           a.valid_from AS a_valid_from, b.valid_from AS b_valid_from
      FROM a FULL JOIN b ON b.scheduler = a.scheduler AND b.k = a.k
  )
  SELECT m.scheduler, m.job_name, m.a_job_id, m.b_job_id,
         CASE WHEN m.ak IS NULL THEN 'only b' WHEN m.bk IS NULL THEN 'only a'
              WHEN m.fields = '[]'::jsonb THEN 'same' ELSE 'different' END,
         m.fields, m.a_valid_from, m.b_valid_from
    FROM m
   ORDER BY m.scheduler, m.job_name, m.a_job_id, m.b_job_id
$$;

-- diff_schema: the schema objects of side a against side b AS LAST READ (schema_objects; PostgreSQL only).
--   Two instances: their present databases are paired by name; p_db_a and p_db_b pick one pair instead (two
--   databases of one instance too). A database only one side holds is one row (kind 'database', children = its
--   objects).
--   An object is matched by kind and identity. status: 'same' (equal hash: kind, definition, owner and ACL),
--   'different' (differs names what does: definition, owner, acl; the definition by its own hash, so a change past
--   the stored 20,000 characters counts), 'only a', 'only b'.
--   A column, index, constraint, trigger or owned sequence whose table (or view) is on that one side only is folded
--   into the table's row and counted in children.
CREATE OR REPLACE FUNCTION pgvigil.diff_schema(p_a int, p_b int, p_db_a text DEFAULT NULL, p_db_b text DEFAULT NULL)
RETURNS TABLE (datname_a text, datname_b text, kind text, identity text, schema_name text, object_name text, parent text,
               status text, differs text, a_definition text, b_definition text, a_owner text, b_owner text, a_acl text,
               b_acl text, children int)
LANGUAGE sql STABLE AS $$
  WITH da AS (
    SELECT d.dbid, d.datname, d.objects FROM pgvigil.schema_databases d
     WHERE d.instance_id = p_a AND d.is_present AND (p_db_a IS NULL OR d.datname = p_db_a)
  ), db AS (
    SELECT d.dbid, d.datname, d.objects FROM pgvigil.schema_databases d
     WHERE d.instance_id = p_b AND d.is_present AND (p_db_b IS NULL OR d.datname = p_db_b)
  ), pair AS (
    -- the key is computed per side (a FULL JOIN takes a plain equality only): the database's name, or one key for
    -- the picked pair
    SELECT x.dbid AS a_dbid, x.datname AS a_name, x.objects AS a_objects, y.dbid AS b_dbid, y.datname AS b_name, y.objects AS b_objects
      FROM (SELECT da.*, CASE WHEN p_db_a IS NOT NULL AND p_db_b IS NOT NULL THEN '' ELSE da.datname END AS k FROM da) x
      FULL JOIN (SELECT db.*, CASE WHEN p_db_a IS NOT NULL AND p_db_b IS NOT NULL THEN '' ELSE db.datname END AS k FROM db) y
        ON y.k = x.k
  ), oa AS (
    SELECT p.a_name, p.b_name, o.* FROM pair p JOIN pgvigil.schema_objects o
      ON o.instance_id = p_a AND o.dbid = p.a_dbid AND o.is_present
     WHERE p.a_dbid IS NOT NULL AND p.b_dbid IS NOT NULL
  ), ob AS (
    SELECT p.a_name, p.b_name, o.* FROM pair p JOIN pgvigil.schema_objects o
      ON o.instance_id = p_b AND o.dbid = p.b_dbid AND o.is_present
     WHERE p.a_dbid IS NOT NULL AND p.b_dbid IS NOT NULL
  ), j AS (
    SELECT coalesce(a.a_name, b.a_name) AS datname_a, coalesce(a.b_name, b.b_name) AS datname_b,
           coalesce(a.kind, b.kind) AS kind, coalesce(a.identity, b.identity) AS identity,
           coalesce(a.schema_name, b.schema_name) AS schema_name, coalesce(a.object_name, b.object_name) AS object_name,
           coalesce(a.parent, b.parent) AS parent,
           CASE WHEN a.identity IS NULL THEN 'only b' WHEN b.identity IS NULL THEN 'only a'
                WHEN a.hash = b.hash THEN 'same' ELSE 'different' END AS status,
           CASE WHEN a.identity IS NOT NULL AND b.identity IS NOT NULL AND a.hash <> b.hash THEN
             coalesce(nullif(concat_ws(', ',
               CASE WHEN CASE WHEN a.def_hash IS NOT NULL AND b.def_hash IS NOT NULL THEN a.def_hash <> b.def_hash
                              ELSE a.definition IS DISTINCT FROM b.definition END THEN 'definition' END,
               CASE WHEN a.owner IS DISTINCT FROM b.owner THEN 'owner' END,
               CASE WHEN a.acl IS DISTINCT FROM b.acl THEN 'acl' END), ''), 'definition') END AS differs,
           a.definition AS a_definition, b.definition AS b_definition, a.owner AS a_owner, b.owner AS b_owner,
           a.acl AS a_acl, b.acl AS b_acl
      FROM oa a FULL JOIN ob b ON b.a_name = a.a_name AND b.kind = a.kind AND b.identity = a.identity
  ), top AS (
    SELECT j.datname_a, j.identity, j.status FROM j
     WHERE j.kind IN ('table', 'view', 'materialized view') AND j.status IN ('only a', 'only b')
  ), k AS (
    SELECT j.*, j.parent IS NOT NULL AND j.status IN ('only a', 'only b')
                AND EXISTS (SELECT 1 FROM top t WHERE t.datname_a = j.datname_a AND t.identity = j.parent AND t.status = j.status) AS is_folded
      FROM j
  )
  SELECT k.datname_a, k.datname_b, k.kind, k.identity, k.schema_name, k.object_name, k.parent, k.status, k.differs,
         k.a_definition, k.b_definition, k.a_owner, k.b_owner, k.a_acl, k.b_acl,
         CASE WHEN k.kind IN ('table', 'view', 'materialized view') AND k.status IN ('only a', 'only b')
              THEN (SELECT count(*)::int FROM k c WHERE c.is_folded AND c.datname_a = k.datname_a AND c.parent = k.identity) END
    FROM k
   WHERE NOT k.is_folded
  UNION ALL
  SELECT p.a_name, p.b_name, 'database', coalesce(p.a_name, p.b_name), NULL, coalesce(p.a_name, p.b_name), NULL,
         CASE WHEN p.a_dbid IS NULL THEN 'only b' ELSE 'only a' END, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         coalesce(p.a_objects, p.b_objects)
    FROM pair p
   WHERE p.a_dbid IS NULL OR p.b_dbid IS NULL
$$;

-- diff_schema_snapshots: one instance's schema at p_at_a against p_at_b (PostgreSQL only), from the change history:
-- the changes found by the reads of (p_at_a, p_at_b] are netted per object.
--   added first and dropped last          no row (it was at neither end)
--   added first                           'only b' (its definition as last stored inside the window)
--   dropped last                          'only a' (its definition at the start: the first change's 'before')
--   otherwise, per attribute (definition, owner, acl): the first change's 'before' against the last change's
--   'after'; equal on all three = no row (changed and changed back), unless a definition changed past the stored
--   20,000 characters (its texts read the same: it still counts as 'different').
--   A column, index, constraint, trigger or owned sequence netted to the same side as its table is folded into the
--   table's row (children).
-- p_all adds, as 'same', every object first seen at or before p_at_a with no change in the window that is still
-- present or was dropped after p_at_b. p_db narrows to one database by name.
-- The history starts at each database's first read (schema_databases.first_read) and ends at the repository's
-- retention: a p_at_a before either compares from there, and diff_sides says where that is.
CREATE OR REPLACE FUNCTION pgvigil.diff_schema_snapshots(p_instance_id int, p_at_a timestamptz, p_at_b timestamptz,
                                                         p_db text DEFAULT NULL, p_all boolean DEFAULT false)
RETURNS TABLE (datname_a text, datname_b text, kind text, identity text, schema_name text, object_name text, parent text,
               status text, differs text, a_definition text, b_definition text, a_owner text, b_owner text, a_acl text,
               b_acl text, children int)
LANGUAGE sql STABLE AS $$
  WITH c AS (
    SELECT x.dbid, coalesce(d.datname, x.datname) AS datname, x.kind, x.identity, x.schema_name, x.object_name, x.parent,
           x.snapshot_at, x.change, x.attribute, x.before, x.after
      FROM pgvigil.schema_changes x
      LEFT JOIN pgvigil.schema_databases d ON d.instance_id = x.instance_id AND d.dbid = x.dbid
     WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_at_a AND x.snapshot_at <= p_at_b
       AND (p_db IS NULL OR coalesce(d.datname, x.datname) = p_db)
  ), n AS (
    SELECT c.dbid, c.kind, c.identity,
           (array_agg(c.datname ORDER BY c.snapshot_at DESC))[1] AS datname,
           (array_agg(c.schema_name ORDER BY c.snapshot_at DESC))[1] AS schema_name,
           (array_agg(c.object_name ORDER BY c.snapshot_at DESC))[1] AS object_name,
           (array_agg(c.parent ORDER BY c.snapshot_at DESC))[1] AS parent,
           (array_agg(c.change ORDER BY c.snapshot_at, c.change))[1] AS first_change,
           (array_agg(c.change ORDER BY c.snapshot_at DESC, c.change))[1] AS last_change,
           -- the definition at the start: the 'before' of the first row that carries one (a drop, or a definition change)
           (array_agg(c.before ORDER BY c.snapshot_at) FILTER (WHERE c.change = 'dropped' OR c.attribute = 'definition'))[1] AS a_def,
           (array_agg(c.after ORDER BY c.snapshot_at DESC) FILTER (WHERE c.change = 'added' OR c.attribute = 'definition'))[1] AS b_def,
           count(*) FILTER (WHERE c.change = 'dropped' OR c.change = 'added' OR c.attribute = 'definition') AS def_rows,
           bool_or(c.change = 'changed' AND c.attribute = 'definition' AND c.before IS NOT DISTINCT FROM c.after) AS past_cut,
           (array_agg(c.before ORDER BY c.snapshot_at) FILTER (WHERE c.attribute = 'owner'))[1] AS a_owner,
           (array_agg(c.after ORDER BY c.snapshot_at DESC) FILTER (WHERE c.attribute = 'owner'))[1] AS b_owner,
           count(*) FILTER (WHERE c.attribute = 'owner') AS owner_rows,
           (array_agg(c.before ORDER BY c.snapshot_at) FILTER (WHERE c.attribute = 'acl'))[1] AS a_acl,
           (array_agg(c.after ORDER BY c.snapshot_at DESC) FILTER (WHERE c.attribute = 'acl'))[1] AS b_acl,
           count(*) FILTER (WHERE c.attribute = 'acl') AS acl_rows
      FROM c
     GROUP BY c.dbid, c.kind, c.identity
  ), s AS (
    SELECT n.*,
           CASE WHEN n.first_change = 'added' AND n.last_change = 'dropped' THEN NULL
                WHEN n.first_change = 'added' THEN 'only b'
                WHEN n.last_change = 'dropped' THEN 'only a'
                ELSE 'different' END AS status,
           nullif(concat_ws(', ',
             CASE WHEN n.def_rows > 0 AND (n.a_def IS DISTINCT FROM n.b_def OR n.past_cut) THEN 'definition' END,
             CASE WHEN n.owner_rows > 0 AND n.a_owner IS DISTINCT FROM n.b_owner THEN 'owner' END,
             CASE WHEN n.acl_rows > 0 AND n.a_acl IS DISTINCT FROM n.b_acl THEN 'acl' END), '') AS differs
      FROM n
  ), k AS (
    SELECT s.*, s.parent IS NOT NULL AND s.status IN ('only a', 'only b')
                AND EXISTS (SELECT 1 FROM s t WHERE t.dbid = s.dbid AND t.kind IN ('table', 'view', 'materialized view')
                               AND t.identity = s.parent AND t.status = s.status) AS is_folded
      FROM s
     WHERE s.status IS NOT NULL AND (s.status <> 'different' OR s.differs IS NOT NULL)
  )
  SELECT k.datname, k.datname, k.kind, k.identity, k.schema_name, k.object_name, k.parent, k.status,
         CASE WHEN k.status = 'different' THEN k.differs END,
         CASE WHEN k.status <> 'only b' THEN k.a_def END, CASE WHEN k.status <> 'only a' THEN k.b_def END,
         CASE WHEN k.status = 'different' THEN k.a_owner END, CASE WHEN k.status = 'different' THEN k.b_owner END,
         CASE WHEN k.status = 'different' THEN k.a_acl END, CASE WHEN k.status = 'different' THEN k.b_acl END,
         CASE WHEN k.kind IN ('table', 'view', 'materialized view') AND k.status IN ('only a', 'only b')
              THEN (SELECT count(*)::int FROM k x WHERE x.is_folded AND x.dbid = k.dbid AND x.parent = k.identity) END
    FROM k
   WHERE NOT k.is_folded
  UNION ALL
  SELECT o.datname, o.datname, o.kind, o.identity, o.schema_name, o.object_name, o.parent, 'same', NULL,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM pgvigil.schema_objects o
   WHERE p_all AND o.instance_id = p_instance_id AND o.first_seen <= p_at_a
     AND (o.is_present OR o.snapshot_at > p_at_b)
     AND (p_db IS NULL OR o.datname = p_db)
     AND NOT EXISTS (SELECT 1 FROM c WHERE c.dbid = o.dbid AND c.kind = o.kind AND c.identity = o.identity)
$$;

-- diff_sides: the two sides of a diff, each with its instance, engine, as-of time (NULL = as last read) and, per
-- store, its newest read and where its history starts, so the page can say how far back a snapshot reaches.
--   settings: the instance read (PostgreSQL: instance_state; the change history starts at the instance's first read)
--             or mssql_config's read (SQL Server: one earlier value per setting, no start to name).
--   jobs:     the newest job version stored and the oldest (job_versions keeps every version: it starts at its first read).
--   schema:   the newest schema read of a present database and the oldest first_read among them, and the oldest
--             change still held (older ones went with the repository's retention).
CREATE OR REPLACE FUNCTION pgvigil.diff_sides(p_a int, p_at_a timestamptz, p_b int, p_at_b timestamptz)
RETURNS TABLE (side text, instance_id int, instance text, engine text, platform text, at timestamptz,
               settings_read timestamptz, settings_from timestamptz, jobs_read timestamptz, jobs_from timestamptz,
               schema_read timestamptz, schema_from timestamptz, schema_changes_from timestamptz, schema_databases int)
LANGUAGE sql STABLE AS $$
  SELECT v.side, i.instance_id, i.name, coalesce(i.engine, 'postgres'), i.platform, v.at,
         CASE WHEN coalesce(i.engine, 'postgres') = 'sqlserver'
              THEN (SELECT max(c.snapshot_at) FROM pgvigil.mssql_config c WHERE c.instance_id = i.instance_id)
              ELSE (SELECT s.snapshot_at FROM pgvigil.instance_state s WHERE s.instance_id = i.instance_id) END,
         CASE WHEN coalesce(i.engine, 'postgres') = 'postgres' THEN i.first_seen END,
         (SELECT max(j.valid_from) FROM pgvigil.job_versions j WHERE j.instance_id = i.instance_id),
         (SELECT min(j.valid_from) FROM pgvigil.job_versions j WHERE j.instance_id = i.instance_id),
         (SELECT max(d.snapshot_at) FROM pgvigil.schema_databases d WHERE d.instance_id = i.instance_id AND d.is_present),
         (SELECT min(d.first_read) FROM pgvigil.schema_databases d WHERE d.instance_id = i.instance_id AND d.is_present),
         (SELECT min(x.snapshot_at) FROM pgvigil.schema_changes x WHERE x.instance_id = i.instance_id),
         (SELECT count(*)::int FROM pgvigil.schema_databases d WHERE d.instance_id = i.instance_id AND d.is_present)
    FROM (VALUES ('a', p_a, p_at_a), ('b', p_b, p_at_b)) v(side, id, at)
    JOIN pgvigil.instances i ON i.instance_id = v.id
   ORDER BY v.side
$$;
