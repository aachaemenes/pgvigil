package web

import "net/http"

// The Summary of the SQL Server instances: one row per instance and status group, read from the findings the
// wave's collections raise (pgvigil.findings, the mssql_* sources) and from what the base collection stores
// (the server's start time, the databases' states). sampled says whether a collection of the group has ever
// stored a read for the instance: a group nothing was read for is 'not yet', never OK.
//
// Uptime follows DBA Dash's defaults: critical under 12 hours since the start, warning under 48.
const sqlMSSQLSummaryCells = `
WITH inst AS (
  SELECT instance_id FROM pgvigil.instances WHERE engine = 'sqlserver' AND is_active
), grp(key, collections) AS (
  VALUES ('blocking', ARRAY['mssql_requests']), ('events', ARRAY['mssql_xe']),
         ('availability', ARRAY['mssql_ag', 'mssql_mirroring', 'mssql_logshipping', 'mssql_replication']),
         ('backups', ARRAY['mssql_backups']), ('jobs', ARRAY['mssql_jobs']), ('storage', ARRAY['mssql_storage', 'mssql_versionstore'])
), f AS (
  SELECT instance_id, severity, setting, value, detail,
         CASE source WHEN 'mssql_running' THEN 'blocking' WHEN 'mssql_xe' THEN 'events' WHEN 'mssql_hadr' THEN 'availability'
                     WHEN 'mssql_storage' THEN 'storage'
                     WHEN 'mssql_jobs' THEN CASE WHEN setting ILIKE '%backup%' OR value = 'mssql_backups' THEN 'backups' ELSE 'jobs' END END AS key
    -- the five SQL Server findings views themselves, as pgvigil.findings maps them (check_name = setting, object =
    -- value): a filter on the big view's source still scans every PostgreSQL arm of it
    FROM (SELECT instance_id, severity, check_name AS setting, object AS value, detail, 'mssql_running' AS source FROM pgvigil.mssql_running_findings
          UNION ALL SELECT instance_id, severity, check_name, object, detail, 'mssql_xe' FROM pgvigil.mssql_xe_findings
          UNION ALL SELECT instance_id, severity, check_name, object, detail, 'mssql_hadr' FROM pgvigil.mssql_hadr_findings
          UNION ALL SELECT instance_id, severity, check_name, object, detail, 'mssql_jobs' FROM pgvigil.mssql_jobs_findings
          UNION ALL SELECT instance_id, severity, check_name, object, detail, 'mssql_storage' FROM pgvigil.mssql_storage_findings) u
   WHERE severity IN ('critical', 'warning')
), started AS (
  SELECT DISTINCT ON (m.instance_id) m.instance_id, m.started_at, m.snapshot_at
    FROM pgvigil.mssql_instance m JOIN inst USING (instance_id)
   ORDER BY m.instance_id, m.snapshot_at DESC
), dbs AS (
  SELECT x.instance_id, count(*) AS n,
         count(*) FILTER (WHERE x.database_state NOT IN ('ONLINE', 'RESTORING', 'OFFLINE')) AS bad,
         count(*) FILTER (WHERE x.database_state = 'OFFLINE') AS offline,
         string_agg(x.database_name || ' ' || lower(replace(x.database_state, '_', ' ')), ', ' ORDER BY x.database_name)
           FILTER (WHERE x.database_state NOT IN ('ONLINE', 'RESTORING')) AS names
    FROM (SELECT DISTINCT instance_id, database_name, database_state FROM pgvigil.mssql_files WHERE is_present) x
    JOIN inst USING (instance_id)
   GROUP BY x.instance_id
)
SELECT i.instance_id, g.key,
       EXISTS (SELECT 1 FROM pgvigil.collection_dates c
                WHERE c.instance_id = i.instance_id AND c.collection = ANY (g.collections) AND c.status = 'ok') AS sampled,
       count(f.instance_id) FILTER (WHERE f.severity = 'critical')::int AS critical,
       count(f.instance_id) FILTER (WHERE f.severity = 'warning')::int AS warning,
       NULL::text AS value,
       coalesce((array_agg(f.setting || coalesce(': ' || nullif(f.value, ''), '') || coalesce(' - ' || f.detail, '')
                           ORDER BY f.severity, f.setting) FILTER (WHERE f.instance_id IS NOT NULL))[1:12], '{}') AS detail
  FROM inst i CROSS JOIN grp g
  LEFT JOIN f ON f.instance_id = i.instance_id AND f.key = g.key
 GROUP BY i.instance_id, g.key, g.collections
UNION ALL
SELECT i.instance_id, 'uptime', s.started_at IS NOT NULL,
       (s.started_at > now() - interval '12 hours')::int,
       (s.started_at <= now() - interval '12 hours' AND s.started_at > now() - interval '48 hours')::int,
       CASE WHEN s.started_at IS NULL THEN NULL
            WHEN now() - s.started_at < interval '2 days' THEN floor(extract(epoch FROM now() - s.started_at) / 3600)::int || ' h'
            ELSE floor(extract(epoch FROM now() - s.started_at) / 86400)::int || ' d' END,
       CASE WHEN s.started_at IS NULL THEN '{}'::text[]
            ELSE ARRAY['SQL Server started ' || to_char(s.started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC (critical under 12 hours, warning under 48)'] END
  FROM inst i LEFT JOIN started s USING (instance_id)
UNION ALL
SELECT i.instance_id, 'dbstate', d.n IS NOT NULL,
       (coalesce(d.bad, 0) > 0)::int, (coalesce(d.bad, 0) = 0 AND coalesce(d.offline, 0) > 0)::int,
       NULL::text,
       CASE WHEN d.names IS NULL THEN '{}'::text[] ELSE ARRAY[d.names] END
  FROM inst i LEFT JOIN dbs d USING (instance_id)
 ORDER BY 1, 2`

// The newest description of each SQL Server instance (the base collection, mssql_instance).
const sqlMSSQLSummaryServers = `
SELECT DISTINCT ON (m.instance_id) m.instance_id, m.snapshot_at, m.machine_name, m.server_name, m.instance_name, m.edition,
       m.product_version, m.product_level, m.product_update_level, m.server_collation, m.is_clustered, m.is_hadr_enabled,
       m.cpu_count, m.physical_memory_mb, m.committed_target_mb, m.virtual_machine_type, m.started_at
  FROM pgvigil.mssql_instance m
  JOIN pgvigil.instances i ON i.instance_id = m.instance_id AND i.engine = 'sqlserver' AND i.is_active
 ORDER BY m.instance_id, m.snapshot_at DESC`

// The database state of the PostgreSQL instances, for the same Summary column: a database left invalid by an
// interrupted DROP DATABASE (datconnlimit -2, PostgreSQL 15 and later) is critical; one that refuses connections
// (datallowconn off, not a template) is a warning, since it can be deliberate and it stops being vacuumed.
const sqlPGDatabaseState = `
SELECT d.instance_id, count(*)::int AS n,
       count(*) FILTER (WHERE d.conn_limit = -2)::int AS critical,
       count(*) FILTER (WHERE d.conn_limit IS DISTINCT FROM -2 AND NOT d.allow_conn)::int AS warning,
       coalesce(array_agg(d.datname || CASE WHEN d.conn_limit = -2 THEN ' is invalid (an interrupted DROP DATABASE)' ELSE ' refuses connections (datallowconn off)' END
                          ORDER BY d.datname) FILTER (WHERE d.conn_limit = -2 OR NOT d.allow_conn), '{}') AS detail
  FROM pgvigil.databases d
  JOIN pgvigil.instances i ON i.instance_id = d.instance_id AND i.engine = 'postgres' AND i.is_active
 WHERE d.is_present AND NOT d.is_template
 GROUP BY d.instance_id`

// MSSQLSummary serves GET /api/mssql/summary: the status cells and the description of every SQL Server instance, and
// the database state of the PostgreSQL ones (the Summary column both engines share).
func (s *Server) MSSQLSummary(w http.ResponseWriter, r *http.Request) {
	s.multiPart(w, r, []part{
		{"cells", sqlMSSQLSummaryCells, nil},
		{"servers", sqlMSSQLSummaryServers, nil},
		{"pgdb", sqlPGDatabaseState, nil},
	})
}
