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
// Uptime reads pg_threshold(instance, 'uptime') (the instance's own, a tag's, the root's) and DBA Dash's defaults,
// critical under 12 hours since the start and warning under 48, until one is set; Memory Dump reads
// pg_threshold(instance, 'crash') the same way (DBA Dash's 48 / 168 hours, 0117).
const sqlMSSQLSummaryCells = `
WITH inst AS (
  SELECT instance_id, name FROM pgvigil.instances WHERE engine = 'sqlserver' AND is_active
), grp(key, collections) AS (
  -- one row per Summary column a SQL Server read fills (DBA Dash's Summary columns, task P08) and the collections
  -- that read it
  VALUES ('blocking', ARRAY['mssql_requests']), ('events', ARRAY['mssql_xe']),
         ('availability', ARRAY['mssql_ag', 'mssql_replication']), ('logship', ARRAY['mssql_logshipping']), ('mirroring', ARRAY['mssql_mirroring']),
         ('full', ARRAY['mssql_backups']), ('diff', ARRAY['mssql_backups']), ('log', ARRAY['mssql_backups']), ('jobs', ARRAY['mssql_jobs']),
         ('filespace', ARRAY['mssql_storage', 'mssql_versionstore']), ('pctmax', ARRAY['mssql_storage']), ('disk', ARRAY['mssql_storage']),
         ('uptime', ARRAY['mssql_instance']), ('dbstate', ARRAY['mssql_storage']),
         ('agent', ARRAY['mssql_services']), ('dbmail', ARRAY['mssql_services']), ('dumps', ARRAY['mssql_services']),
         ('qs', ARRAY['mssql_querystore']), ('audit', ARRAY['mssql_audit']),
         ('checkdb', ARRAY['mssql_checks']), ('logspace', ARRAY['mssql_checks']), ('corruption', ARRAY['mssql_checks']),
         ('alerts', ARRAY['mssql_checks']), ('identity', ARRAY['mssql_identity'])
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
         CASE source WHEN 'mssql_running' THEN 'blocking' WHEN 'mssql_xe' THEN 'events'
                     -- DBA Dash's Log Shipping and Mirroring columns apart from Availability Groups (task P08)
                     WHEN 'mssql_hadr' THEN CASE WHEN setting LIKE 'log shipping%' THEN 'logship' WHEN setting LIKE 'mirroring%' THEN 'mirroring' ELSE 'availability' END
                     -- a volume's free space is DBA Dash's Drive Space (task 176); the files and the version store its File Space
                     -- DBA Dash's % Max Size apart (a file at or within one growth of its max size, task P08)
                     WHEN 'mssql_storage' THEN CASE WHEN setting = 'a volume under 10 % free' THEN 'disk' WHEN setting LIKE '%max size%' THEN 'pctmax' ELSE 'filespace' END
                     -- DBA Dash's Backup FULL, DIFF and LOG columns apart (task P08): a log or a differential finding by its
                     -- name ('backups not judged' by its detail), any other backup finding is FULL's
                     WHEN 'mssql_jobs' THEN CASE WHEN NOT (setting ILIKE '%backup%' OR value = 'mssql_backups') THEN 'jobs'
                                                 WHEN setting ILIKE '%log backup%' OR (setting LIKE 'backups not judged%' AND detail ILIKE '%log backup%')
                                                      OR (setting = 'a backup went to NUL' AND detail LIKE '%: a log backup %') THEN 'log'
                                                 WHEN setting ILIKE '%differential%' OR (setting = 'a backup went to NUL' AND detail LIKE '%: a differential backup %') THEN 'diff'
                                                 ELSE 'full' END END AS key
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
                             ORDER BY f.severity, f.setting) FILTER (WHERE f.instance_id IS NOT NULL))[1:12], '{}') AS detail,
         NULL::timestamptz AS since
    FROM st LEFT JOIN f ON f.instance_id = st.instance_id AND f.key = st.key
   WHERE st.key IN ('blocking', 'events', 'availability', 'logship', 'mirroring', 'full', 'diff', 'log', 'jobs', 'filespace', 'pctmax', 'disk')
   GROUP BY st.instance_id, st.key
  UNION ALL
  -- uptime: the threshold in force for the instance (pg_threshold(instance, 'uptime'): DBA Dash's defaults, critical
  -- under 12 hours since the start, warning under 48; set in the Summary's Uptime dialog, task 176b); a start time
  -- ahead of the repository's clock (skew) counts as just started, never as a negative age
  SELECT i.instance_id, 'uptime', s.started_at IS NOT NULL,
         coalesce(th.crit IS NOT NULL AND s.started_at > now() - th.crit * interval '1 hour', false)::int,
         coalesce(th.warn IS NOT NULL AND s.started_at > now() - th.warn * interval '1 hour'
                  AND NOT (th.crit IS NOT NULL AND s.started_at > now() - th.crit * interval '1 hour'), false)::int,
         CASE WHEN s.started_at IS NULL THEN NULL
              WHEN now() - s.started_at < interval '2 days' THEN greatest(0, floor(extract(epoch FROM now() - s.started_at) / 3600))::int || ' h'
              ELSE floor(extract(epoch FROM now() - s.started_at) / 86400)::int || ' d' END,
         CASE WHEN s.started_at IS NULL THEN '{}'::text[]
              ELSE ARRAY['SQL Server started ' || to_char(s.started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC ('
                         || coalesce(nullif(concat_ws(', ', 'critical under ' || trim_scale(th.crit) || ' hours', 'warning under ' || trim_scale(th.warn) || ' hours'), ''), 'not judged')
                         || CASE th.level WHEN 'default' THEN ', the default' WHEN 'tag' THEN ', set on the tag ' || th.tag ELSE ', set on the ' || th.level END || ')'] END,
         s.started_at
    FROM inst i LEFT JOIN started s USING (instance_id) CROSS JOIN LATERAL pgvigil.pg_threshold(i.instance_id, 'uptime') th
  UNION ALL
  -- database state: the count of databases in a state other than ONLINE / RESTORING / OFFLINE is critical, else
  -- the count of OFFLINE ones a warning
  SELECT i.instance_id, 'dbstate', d.n IS NOT NULL,
         coalesce(d.bad, 0)::int, CASE WHEN coalesce(d.bad, 0) = 0 THEN coalesce(d.offline, 0) ELSE 0 END::int,
         NULL::text,
         CASE WHEN d.names IS NULL THEN '{}'::text[] ELSE ARRAY[d.names] END, NULL::timestamptz
    FROM inst i LEFT JOIN dbs d USING (instance_id)
  UNION ALL
  -- Agent and Database Mail: the rules live in the view (migration 0070)
  SELECT i.instance_id, k.key, coalesce(c.sampled, false), coalesce(c.critical, 0), coalesce(c.warning, 0), c.value, coalesce(c.detail, '{}'), NULL::timestamptz
    FROM inst i CROSS JOIN (VALUES ('agent'), ('dbmail')) k(key)
    LEFT JOIN pgvigil.mssql_health_status c ON c.instance_id = i.instance_id AND c.key = k.key
  UNION ALL
  -- Memory Dump: the newest dump's age against the threshold in force (pg_threshold(instance, 'crash'), DBA Dash's
  -- Memory Dump Thresholds dialog: critical under 48 hours, warning under 168 until one is set, 0117; task P08)
  SELECT i.instance_id, 'dumps', coalesce(h.dumps_read, false),
         coalesce(h.dumps_read AND th.crit IS NOT NULL AND h.last_dump_at > now() - th.crit * interval '1 hour', false)::int,
         coalesce(h.dumps_read AND th.warn IS NOT NULL AND h.last_dump_at > now() - th.warn * interval '1 hour'
                  AND NOT (th.crit IS NOT NULL AND h.last_dump_at > now() - th.crit * interval '1 hour'), false)::int,
         CASE WHEN NOT coalesce(h.dumps_read, false) THEN NULL WHEN coalesce(h.dump_count, 0) = 0 THEN 'none' ELSE h.dump_count || ' file' || CASE WHEN h.dump_count = 1 THEN '' ELSE 's' END END,
         CASE WHEN NOT coalesce(h.dumps_read, false) THEN '{}'::text[]
              WHEN coalesce(h.dump_count, 0) = 0 THEN ARRAY['the server lists no memory dump file']
              ELSE ARRAY[h.dump_count || ' memory dump file(s) on the server; the newest '
                         || coalesce('written ' || to_char(h.last_dump_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'has no creation time the server can tell')
                         || ' (' || coalesce(nullif(concat_ws(', ', 'critical under ' || trim_scale(th.crit) || ' hours', 'warning under ' || trim_scale(th.warn) || ' hours'), ''), 'not judged')
                         || CASE th.level WHEN 'default' THEN ', the default' WHEN 'tag' THEN ', set on the tag ' || th.tag ELSE ', set on the ' || th.level END || ')'] END,
         h.last_dump_at
    FROM inst i LEFT JOIN pgvigil.mssql_health h USING (instance_id) CROSS JOIN LATERAL pgvigil.pg_threshold(i.instance_id, 'crash') th
  UNION ALL
  -- Query Store: the databases whose store is in the ERROR state (critical), read-only or off though asked for
  -- (warning); the rules live in the view (migration 0083)
  SELECT i.instance_id, 'qs', coalesce(c.sampled, false), coalesce(c.critical, 0), coalesce(c.warning, 0), c.value, coalesce(c.detail, '{}'), NULL::timestamptz
    FROM inst i LEFT JOIN pgvigil.mssql_querystore_status c ON c.instance_id = i.instance_id
  UNION ALL
  -- SQL Server Audit: an audit that failed (critical) or is stopped though defined (warning); the rules live in the
  -- view (migration 0101)
  SELECT i.instance_id, 'audit', coalesce(c.sampled, false), coalesce(c.critical, 0), coalesce(c.warning, 0), c.value, coalesce(c.detail, '{}'), NULL::timestamptz
    FROM inst i LEFT JOIN pgvigil.mssql_audit_status c ON c.instance_id = i.instance_id
  UNION ALL
  -- DBA Dash's Last Good Check DB, Log Space, Corruption, SQL Agent Alerts and Identity Columns: the day-one checks'
  -- areas (mssql_checks_status, 0090; task P08); since = what DBA Dash's cell counts from: the oldest last good
  -- CHECKDB, the newest corruption detection (suspect pages 1-3), the newest alert; value = DBA Dash's 'Never' (a
  -- database never checked) or the identity cell's 'max % used|fewest days left'
  SELECT i.instance_id, k.key, coalesce(c.sampled, false), coalesce(c.critical, 0), coalesce(c.warning, 0),
         CASE WHEN NOT coalesce(c.sampled, false) THEN NULL
              WHEN k.key = 'checkdb' THEN CASE WHEN cd.never THEN 'Never' END
              -- identity: '<the most used column's per cent, one decimal>|<the fewest days left>' (the page words it as
              -- DBA Dash does: '42.5% / 3 months')
              WHEN k.key = 'identity' THEN (SELECT to_char(max(ic.pct_used), 'FM9999990.0') || '|' || coalesce(floor(min(ic.days_left))::bigint::text, '')
                                              FROM pgvigil.mssql_identity_column ic WHERE ic.instance_id = i.instance_id)
              ELSE c.value END,
         coalesce(c.detail, '{}'),
         CASE k.key WHEN 'checkdb' THEN cd.oldest
                    WHEN 'corruption' THEN (SELECT max(sp.last_update_at) FROM pgvigil.mssql_suspect_page sp WHERE sp.instance_id = i.instance_id AND sp.event_type IN (1, 2, 3))
                    WHEN 'alerts' THEN (SELECT max(al.last_occurrence_at) FROM pgvigil.mssql_agent_alert al WHERE al.instance_id = i.instance_id) END
    FROM inst i CROSS JOIN (VALUES ('checkdb'), ('logspace'), ('corruption'), ('alerts'), ('identity')) k(key)
    LEFT JOIN pgvigil.mssql_checks_status c ON c.instance_id = i.instance_id AND c.key = k.key
    LEFT JOIN LATERAL (
      -- options->>'last_good_checkdb' is 'never' or the time in UTC (mssql dboptions); anything else is not read
      SELECT coalesce(bool_or(d.options->>'last_good_checkdb' = 'never'), false) AS never,
             min(CASE WHEN d.options->>'last_good_checkdb' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN (d.options->>'last_good_checkdb')::timestamptz END) AS oldest
        FROM pgvigil.mssql_database_option d
       WHERE d.instance_id = i.instance_id AND d.is_present AND d.options ? 'last_good_checkdb') cd ON k.key = 'checkdb'
)
SELECT c.instance_id, c.key, st.state, c.sampled, coalesce(c.critical, 0) AS critical, coalesce(c.warning, 0) AS warning,
       c.value, c.detail, st.read_at, st.err, c.since
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

// The Summary's Snapshot Age and Collection Errors (24hrs) columns for every instance of either engine (DBA Dash's
// SnapshotAgeStatus and CollectionErrorStatus, task P08): the youngest and the oldest last run of the instance's
// collections that run there and last ended well (not disabled, not skipped, not failed) in seconds, how many of them are
// stale (older than three intervals, at least 300 s; $2 when no interval is known: the daily check 'collection
// stale') and how many failed at their last run, and the errors collection_log holds for the last 24 hours. $1 the
// intervals as the daily checks read them.
const sqlSummaryCollect = `
WITH c AS (
  SELECT c.instance_id, c.collection, c.status, c.snapshot_at,
         coalesce(($1::jsonb -> 'instances' -> i.name ->> c.collection)::int, ($1::jsonb -> 'defaults' ->> c.collection)::int) AS iv
    FROM pgvigil.collection_dates c
    JOIN pgvigil.instances i ON i.instance_id = c.instance_id AND i.is_active
)
SELECT i.instance_id,
       -- the ages count from runs that ended well only: log_collection moves snapshot_at on a failed run too, and a
       -- collection failing for days is not a young one (DBA Dash's collection dates move on success); Collection
       -- Errors shows the failing ones
       (min(greatest(0, extract(epoch FROM now() - c.snapshot_at))) FILTER (WHERE c.status = 'ok' AND c.iv IS DISTINCT FROM 0))::bigint AS age_min_secs,
       (max(greatest(0, extract(epoch FROM now() - c.snapshot_at))) FILTER (WHERE c.status = 'ok' AND c.iv IS DISTINCT FROM 0))::bigint AS age_max_secs,
       count(*) FILTER (WHERE c.status NOT IN ('skipped', 'error') AND c.iv IS DISTINCT FROM 0
                          AND now() - c.snapshot_at > make_interval(secs => CASE WHEN c.iv IS NULL THEN $2::int ELSE greatest(300, 3 * c.iv) END))::int AS stale,
       count(*) FILTER (WHERE c.status = 'error' AND c.iv IS DISTINCT FROM 0)::int AS failing,
       coalesce(array_agg(c.collection || CASE WHEN c.status = 'error' THEN ': the last run failed' ELSE ': stale, the last run ' || to_char(c.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC' END
                          ORDER BY c.status <> 'error', c.collection)
                FILTER (WHERE c.iv IS DISTINCT FROM 0 AND (c.status = 'error' OR (c.status <> 'skipped'
                          AND now() - c.snapshot_at > make_interval(secs => CASE WHEN c.iv IS NULL THEN $2::int ELSE greatest(300, 3 * c.iv) END)))), '{}') AS detail,
       (SELECT count(*) FROM pgvigil.collection_log l
         WHERE l.instance_id = i.instance_id AND l.status = 'error' AND l.snapshot_at > now() - interval '24 hours')::int AS errors_24h
  FROM pgvigil.instances i
  LEFT JOIN c ON c.instance_id = i.instance_id
 WHERE i.is_active
 GROUP BY i.instance_id`

// The root's Instance Uptime and Memory Dump thresholds (DBA Dash's Options > Configure Thresholds dialogs, task
// P08): the root row in force if one is set, and the key's built-in defaults and limit.
const sqlSummaryRoots = `
SELECT k.key, k.label, k.unit, k.warn_default, k.crit_default, k.max_value,
       r.threshold_id, r.warn, r.crit, r.created_by, r.created_at
  FROM pgvigil.pg_threshold_keys k
  LEFT JOIN pgvigil.pg_thresholds r ON r.ended_at IS NULL AND r.key = k.key AND r.level = 'root'
 WHERE k.key IN ('uptime', 'crash')
 ORDER BY k.key`

// MSSQLSummary serves GET /api/mssql/summary: the status cells and the description of every SQL Server instance, the
// database state of the PostgreSQL ones (the Summary column both engines share), the collection ages and errors of
// every instance and the root's uptime and memory dump thresholds.
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
		{"collect", sqlSummaryCollect, []any{string(exp), DefaultStaleSecs}},
		{"roots", sqlSummaryRoots, nil},
	})
}
