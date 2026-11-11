package web

import (
	"encoding/json"
	"net/http"
)

// The Summary of the SQL Server instances: one row per instance and status group, read from the findings the
// wave's collections raise (pgvigil.findings, the mssql_* sources) and from what the base collection stores
// (the server's start time, the databases' states, the services read). sampled says whether a collection of the group has ever
// stored a read for the instance: a group nothing was read for is 'not yet', never OK.
//
// Uptime follows DBA Dash's defaults: critical under 12 hours since the start, warning under 48.
const sqlMSSQLSummaryCells = `
WITH inst AS (
  SELECT instance_id, name FROM pgvigil.instances WHERE engine = 'sqlserver' AND is_active
), grp(key, collections) AS (
  VALUES ('blocking', ARRAY['mssql_requests']), ('events', ARRAY['mssql_xe']),
         ('availability', ARRAY['mssql_ag', 'mssql_mirroring', 'mssql_logshipping', 'mssql_replication']),
         ('backups', ARRAY['mssql_backups']), ('jobs', ARRAY['mssql_jobs']), ('storage', ARRAY['mssql_storage', 'mssql_versionstore']),
         ('uptime', ARRAY['mssql_instance']), ('dbstate', ARRAY['mssql_storage']),
         ('agent', ARRAY['mssql_services']), ('dbmail', ARRAY['mssql_services']), ('dumps', ARRAY['mssql_services']),
         ('qs', ARRAY['mssql_querystore'])
), runs AS (
  -- the last run of each of the group's collections (collection_dates keeps one row per collection): old = older
  -- than three of its intervals, the rule of the daily check 'collection stale' ($1 the intervals, $2 the age for
  -- a collection without one; an interval of 0 = disabled there, never old)
  SELECT i.instance_id, g.key,
         count(*) FILTER (WHERE c.status = 'skipped') AS skipped,
         count(*) FILTER (WHERE c.status = 'error') AS failed,
         count(*) FILTER (WHERE c.status NOT IN ('skipped', 'error') AND NOT x.old) AS fresh,
         count(*) FILTER (WHERE c.status NOT IN ('skipped', 'error') AND x.old) AS old,
         max(c.snapshot_at) FILTER (WHERE c.status NOT IN ('skipped', 'error')) AS read_at,
         string_agg(c.collection || ': ' || coalesce(nullif(c.note, ''), 'the last run failed'), '; ' ORDER BY c.collection) FILTER (WHERE c.status = 'error') AS err
    FROM inst i CROSS JOIN grp g
    LEFT JOIN pgvigil.collection_dates c ON c.instance_id = i.instance_id AND c.collection = ANY (g.collections)
    LEFT JOIN LATERAL (
      SELECT CASE WHEN iv.iv = 0 THEN false
                  ELSE now() - c.snapshot_at > make_interval(secs => CASE WHEN iv.iv IS NULL THEN $2::int ELSE greatest(300, 3 * iv.iv) END) END AS old
        FROM (SELECT coalesce(($1::jsonb -> 'instances' -> i.name ->> c.collection)::int,
                              ($1::jsonb -> 'defaults' ->> c.collection)::int) AS iv) iv) x ON true
   GROUP BY i.instance_id, g.key
), st AS (
  -- ok = a read young enough; stale = only older reads; failed = no read left, the last run an error; n/a = every
  -- collection of the group is skipped on this kind of server; never = nothing ran yet
  SELECT instance_id, key, read_at, err,
         CASE WHEN fresh > 0 THEN 'ok' WHEN old > 0 THEN 'stale' WHEN failed > 0 THEN 'failed' WHEN skipped > 0 THEN 'n/a' ELSE 'never' END AS state
    FROM runs
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
  SELECT m.instance_id, m.started_at FROM pgvigil.mssql_instance m JOIN inst USING (instance_id)
), dbs AS (
  SELECT x.instance_id, count(*) AS n,
         count(*) FILTER (WHERE x.database_state NOT IN ('ONLINE', 'RESTORING', 'OFFLINE')) AS bad,
         count(*) FILTER (WHERE x.database_state = 'OFFLINE') AS offline,
         string_agg(x.database_name || ' ' || lower(replace(x.database_state, '_', ' ')), ', ' ORDER BY x.database_name)
           FILTER (WHERE x.database_state NOT IN ('ONLINE', 'RESTORING')) AS names
    FROM (SELECT DISTINCT instance_id, database_name, database_state FROM pgvigil.mssql_files WHERE is_present) x
    JOIN inst USING (instance_id)
   GROUP BY x.instance_id
), cell AS (
  -- the groups judged by findings
  SELECT st.instance_id, st.key, true AS sampled,
         count(f.instance_id) FILTER (WHERE f.severity = 'critical')::int AS critical,
         count(f.instance_id) FILTER (WHERE f.severity = 'warning')::int AS warning,
         NULL::text AS value,
         coalesce((array_agg(f.setting || coalesce(': ' || nullif(f.value, ''), '') || coalesce(' - ' || f.detail, '')
                             ORDER BY f.severity, f.setting) FILTER (WHERE f.instance_id IS NOT NULL))[1:12], '{}') AS detail
    FROM st LEFT JOIN f ON f.instance_id = st.instance_id AND f.key = st.key
   WHERE st.key IN ('blocking', 'events', 'availability', 'backups', 'jobs', 'storage')
   GROUP BY st.instance_id, st.key
  UNION ALL
  -- uptime, DBA Dash's defaults: critical under 12 hours since the start, warning under 48; a start time ahead of
  -- the repository's clock (skew) counts as just started, never as a negative age
  SELECT i.instance_id, 'uptime', s.started_at IS NOT NULL,
         (s.started_at > now() - interval '12 hours')::int,
         (s.started_at <= now() - interval '12 hours' AND s.started_at > now() - interval '48 hours')::int,
         CASE WHEN s.started_at IS NULL THEN NULL
              WHEN now() - s.started_at < interval '2 days' THEN greatest(0, floor(extract(epoch FROM now() - s.started_at) / 3600))::int || ' h'
              ELSE floor(extract(epoch FROM now() - s.started_at) / 86400)::int || ' d' END,
         CASE WHEN s.started_at IS NULL THEN '{}'::text[]
              ELSE ARRAY['SQL Server started ' || to_char(s.started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC (critical under 12 hours, warning under 48)'] END
    FROM inst i LEFT JOIN started s USING (instance_id)
  UNION ALL
  -- database state: the count of databases in a state other than ONLINE / RESTORING / OFFLINE is critical, else
  -- the count of OFFLINE ones a warning
  SELECT i.instance_id, 'dbstate', d.n IS NOT NULL,
         coalesce(d.bad, 0)::int, CASE WHEN coalesce(d.bad, 0) = 0 THEN coalesce(d.offline, 0) ELSE 0 END::int,
         NULL::text,
         CASE WHEN d.names IS NULL THEN '{}'::text[] ELSE ARRAY[d.names] END
    FROM inst i LEFT JOIN dbs d USING (instance_id)
  UNION ALL
  -- Agent, Database Mail and memory dumps: the rules live in the view (migration 0070)
  SELECT i.instance_id, k.key, coalesce(c.sampled, false), coalesce(c.critical, 0), coalesce(c.warning, 0), c.value, coalesce(c.detail, '{}')
    FROM inst i CROSS JOIN (VALUES ('agent'), ('dbmail'), ('dumps')) k(key)
    LEFT JOIN pgvigil.mssql_health_status c ON c.instance_id = i.instance_id AND c.key = k.key
  UNION ALL
  -- Query Store: the databases whose store is in the ERROR state (critical), read-only or off though asked for
  -- (warning); the rules live in the view (migration 0083)
  SELECT i.instance_id, 'qs', coalesce(c.sampled, false), coalesce(c.critical, 0), coalesce(c.warning, 0), c.value, coalesce(c.detail, '{}')
    FROM inst i LEFT JOIN pgvigil.mssql_querystore_status c ON c.instance_id = i.instance_id
)
SELECT c.instance_id, c.key, st.state, c.sampled, coalesce(c.critical, 0) AS critical, coalesce(c.warning, 0) AS warning,
       c.value, c.detail, st.read_at, st.err
  FROM cell c JOIN st USING (instance_id, key)
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
	exp, err := json.Marshal(s.expected)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	s.multiPart(w, r, []part{
		{"cells", sqlMSSQLSummaryCells, []any{string(exp), DefaultStaleSecs}},
		{"servers", sqlMSSQLSummaryServers, nil},
		{"pgdb", sqlPGDatabaseState, nil},
	})
}
