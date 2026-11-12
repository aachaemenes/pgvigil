package web

import (
	"errors"
	"math"
	"net/http"
	"strconv"
	"strings"
)

// The Reports tree (task 169; the stock reports of DBA Dash's Reports folder, at the root and under each instance, on
// both engines). Every report reads the repository: what an existing collection holds is read where it is, and only
// the role members, the SQL logins, the database properties, two service columns, SQL Server table sizes and the
// PostgreSQL password methods come from the new reads (0105_reports.sql: the collections mssql_reports and reports).
//
// GET /api/reports?r=<report>[&instance=<id> | &instances=<id,id,...>][&from=&to=][&days=][&top=][...] (Server.Reports)
// Scope: one instance, a list (a tag folder's), or every active instance. Each report's parts:
//
//	props        props (each present database property: SQL Server extended properties, PostgreSQL comments), state
//	finder       databases (each present database of both engines; &like= a LIKE pattern, &system=1 the system ones too,
//	             &top=), state
//	deadlocks    deadlocks (SQL Server, the window, each with its processes and resources, 2,000 newest), pg (the
//	             PostgreSQL instances with deadlocks in the window and how many: the page reads each one's
//	             /api/pg/deadlocks)
//	failed       server (each instance's failed logins of the last &days= and how its reader last ended), logins,
//	             clients, messages (the counts by login, client and reason over the scope), failed (the 5,000 newest:
//	             SQL Server's 'Login failed' lines read by mssql_reports, PostgreSQL's auth_fail log events)
//	flushed      flushed (the last &days=: DBCC FREEPROCCACHE / FREESYSTEMCACHE / FLUSHPROCINDB from
//	             the default trace, and the error log's 'cachestore flush' lines)
//	killed       killed (the actions log's kill, terminate and cancel attempts of the last &days=)
//	actions      actions (every attempt in the actions log of the last &days=), audit (PostgreSQL pgaudit ROLE and DDL
//	             entries of the last &days=, 2,000 newest)
//	roles        members (SQL Server server role members; PostgreSQL superusers, the members of the pg_* roles and of
//	             the managed services' admin roles),
//	             roles (the role names there are, for the picker), state
//	pwage        logins (SQL Server SQL logins with their password age; &disabled=1 keeps the disabled ones),
//	             pg (PostgreSQL login roles: expiry and password method), state
//	services     services (SQL Server services with the file name and cluster node)
//	tables       tables (SQL Server table sizes at each database's newest read, growth per day over &days= (Growth
//	             Days); &top=),
//	             state
//	querystats   stats (both engines over the window, grouped by &group=query|database|object|instance, ordered by
//	             &order=cpu|duration|executions|reads|writes, &top=)
//	qscharts     series (both engines over the window per bucket: executions, CPU, duration, reads), top (the 10
//	             largest queries by CPU or duration), meta
//	recycle      instances (inactive instances, and active ones no collection reached for a day)
//
// Every grid a page shows is one part, so the export (the shell's Export .xlsx) has one sheet per grid.

// reportDays are the Days choices of DBA Dash's reports.
var reportDays = map[int]bool{1: true, 2: true, 7: true, 14: true, 30: true, 60: true, 90: true, 180: true, 365: true}

const reportMaxInstances = 2000

// reportScope reads the scope: nil = every active instance; an empty folder asks with instances=0 (no row).
func reportScope(r *http.Request) ([]int32, error) {
	q := r.URL.Query()
	if v := q.Get("instance"); v != "" {
		id, err := strconv.Atoi(v)
		if err != nil || id <= 0 || id > math.MaxInt32 {
			return nil, errors.New("instance must be a positive instance_id")
		}
		return []int32{int32(id)}, nil
	}
	v := q.Get("instances")
	if v == "" {
		return nil, nil
	}
	ids := []int32{}
	for _, p := range strings.Split(v, ",") {
		n, err := strconv.Atoi(strings.TrimSpace(p))
		if err != nil || n < 0 || n > math.MaxInt32 || len(ids) >= reportMaxInstances {
			return nil, errors.New("instances must be instance ids separated by commas (2,000 at most)")
		}
		ids = append(ids, int32(n))
	}
	return ids, nil
}

func reportInt(r *http.Request, name string, def, lo, hi int) (int, error) {
	v := r.URL.Query().Get(name)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < lo || n > hi {
		return 0, errors.New(name + " must be " + strconv.Itoa(lo) + " to " + strconv.Itoa(hi))
	}
	return n, nil
}

// the scope as a WHERE condition on instances i; $1 is the id list (NULL = every instance)
const repScope = `i.is_active AND ($1::int[] IS NULL OR i.instance_id = ANY($1::int[]))`

// sqlRepState: how the last read of each named part ended on each instance of the scope and engine (no row of a part:
// the collection has not run there)
const sqlRepState = `
SELECT i.instance_id, i.name AS instance, coalesce(i.engine, 'postgres') AS engine, p.part, s.status, s.note, s.snapshot_at
  FROM pgvigil.instances i
 CROSS JOIN unnest($2::text[]) p(part)
  LEFT JOIN pgvigil.report_read_state s ON s.instance_id = i.instance_id AND s.part = p.part
 WHERE ` + repScope + ` AND coalesce(i.engine, 'postgres') = $3
 ORDER BY i.name, p.part`

const sqlRepProps = `
SELECT i.instance_id, i.name AS instance, coalesce(i.engine, 'postgres') AS engine, p.database_name, p.property, p.value,
       p.valid_from, p.snapshot_at
  FROM pgvigil.report_db_properties p JOIN pgvigil.instances i ON i.instance_id = p.instance_id
 WHERE ` + repScope + ` AND p.is_present
 ORDER BY i.name, p.database_name, p.property`

// the databases of both engines as their own collections list them now (SQL Server: the backups read's database
// list, which every SQL Server instance has; PostgreSQL: the databases collection)
const sqlRepFinder = `
WITH d AS (
  SELECT b.instance_id, b.database_name, b.state, b.recovery_model, b.created_at, NULL::bigint AS size_bytes,
         b.database_name IN ('master', 'model', 'msdb', 'tempdb', 'distribution', 'SSISDB', 'rdsadmin') AS is_system, b.snapshot_at
    FROM pgvigil.mssql_backup_state b
   WHERE b.is_present AND NOT coalesce(b.is_snapshot, false)
  UNION ALL
  SELECT x.instance_id, x.datname, CASE WHEN x.allow_conn IS FALSE THEN 'NO CONNECTIONS' ELSE 'ONLINE' END, NULL, NULL, x.size_bytes,
         x.datname IN ('postgres', 'rdsadmin', 'azure_maintenance', 'azure_sys', 'cloudsqladmin', 'alloydbadmin') AS is_system, x.snapshot_at
    FROM pgvigil.databases x
   WHERE x.is_present AND NOT coalesce(x.is_template, false)
)
SELECT i.instance_id, i.name AS instance, coalesce(i.engine, 'postgres') AS engine, d.database_name, d.state, d.recovery_model,
       d.created_at, coalesce(d.size_bytes, (SELECT z.data_bytes + coalesce(z.log_bytes, 0) FROM pgvigil.mssql_database_size z
         WHERE z.instance_id = d.instance_id AND z.database_name = d.database_name ORDER BY z.snapshot_at DESC LIMIT 1)) AS size_bytes,
       d.is_system, d.snapshot_at,
       (SELECT x.dbid FROM pgvigil.databases x WHERE x.instance_id = d.instance_id AND x.datname = d.database_name AND x.is_present LIMIT 1) AS dbid
  FROM d JOIN pgvigil.instances i ON i.instance_id = d.instance_id
 WHERE ` + repScope + ` AND ($2 = '' OR d.database_name ILIKE $2) AND ($3 OR NOT d.is_system)
 ORDER BY i.name, d.database_name
 LIMIT $4`

const sqlRepDeadlocks = `
SELECT d.instance_id, i.name AS instance, d.event_at, d.event_key, d.source, d.process_count, d.victim_count, d.victim_spid,
       d.victim_login, d.victim_program, d.victim_statement, d.database_names, d.object_names, d.processes, d.resources,
       (d.graph IS NOT NULL) AS has_graph
  FROM pgvigil.mssql_deadlocks d JOIN pgvigil.instances i ON i.instance_id = d.instance_id
 WHERE ` + repScope + ` AND i.engine = 'sqlserver' AND d.event_at > $2 AND d.event_at <= $3
 ORDER BY d.event_at DESC
 LIMIT 2000`

const sqlRepPgDeadlocks = `
SELECT i.instance_id, i.name AS instance, count(*) AS deadlocks
  FROM pgvigil.log_events e JOIN pgvigil.instances i ON i.instance_id = e.instance_id
 WHERE ` + repScope + ` AND coalesce(i.engine, 'postgres') = 'postgres' AND e.kind = 'deadlock'
   AND e.snapshot_at > $2 AND e.snapshot_at <= $3
 GROUP BY i.instance_id, i.name
 ORDER BY i.name`

// failed logins of both engines in one shape: SQL Server's error log lines read by mssql_reports (the login, the
// client and the reason taken apart on import), PostgreSQL's auth_fail log events (the message's quoted names left
// out of its reason, so one reason groups)
const repFailedCTE = `
WITH f AS (
  SELECT i.instance_id, i.name AS instance, 'sqlserver' AS engine, f.logged_at AS at, f.login_name, f.client,
         NULL::text AS database_name, f.reason, f.message
    FROM pgvigil.mssql_failed_logins f JOIN pgvigil.instances i ON i.instance_id = f.instance_id
   WHERE ` + repScope + ` AND i.engine = 'sqlserver' AND f.logged_at > now() - make_interval(days => $2)
  UNION ALL
  SELECT i.instance_id, i.name, 'postgres', l.snapshot_at, l.usename, l.client, l.datname,
         nullif(regexp_replace(coalesce(l.detail, ''), '"[^"]*"', '"..."', 'g'), ''), l.detail
    FROM pgvigil.log_events l JOIN pgvigil.instances i ON i.instance_id = l.instance_id
   WHERE ` + repScope + ` AND coalesce(i.engine, 'postgres') = 'postgres' AND l.kind = 'auth_fail'
     AND l.snapshot_at > now() - make_interval(days => $2)
)`

// the Server Summary: every instance of the scope, its failed logins and how its reader last ended (SQL Server: the
// failed_logins part of mssql_reports; PostgreSQL: the log reader's collection)
const sqlRepFailedServer = repFailedCTE + `
SELECT i.instance_id, i.name AS instance, coalesce(i.engine, 'postgres') AS engine, count(f.at) AS failed_logins,
       min(f.at) AS first_failed, max(f.at) AS last_failed,
       CASE WHEN i.engine = 'sqlserver' THEN s.snapshot_at ELSE c.snapshot_at END AS snapshot_at,
       CASE WHEN i.engine = 'sqlserver' THEN s.status ELSE c.status END AS read_status,
       CASE WHEN i.engine = 'sqlserver' THEN s.note ELSE c.note END AS read_note
  FROM pgvigil.instances i
  LEFT JOIN f ON f.instance_id = i.instance_id
  LEFT JOIN pgvigil.report_read_state s ON s.instance_id = i.instance_id AND s.part = 'failed_logins'
  LEFT JOIN LATERAL (SELECT x.snapshot_at, x.status, x.note FROM pgvigil.collection_dates x
                      WHERE x.instance_id = i.instance_id AND x.collection IN ('serverlog', 'logs')
                      ORDER BY x.snapshot_at DESC LIMIT 1) c ON true
 WHERE ` + repScope + `
 GROUP BY i.instance_id, i.name, i.engine, s.snapshot_at, s.status, s.note, c.snapshot_at, c.status, c.note
 ORDER BY count(f.at) DESC, i.name`

// the Login, Client and Message summaries (over the whole scope, as DBA Dash's) and the Detail (the newest 5,000)
func sqlRepFailedBy(col string) string {
	return repFailedCTE + `
SELECT ` + col + ` AS value, count(*) AS failed_logins, count(DISTINCT instance_id) AS instances, min(at) AS first_failed, max(at) AS last_failed
  FROM f GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT 5000`
}

const sqlRepFailedDetail = repFailedCTE + `
SELECT * FROM f ORDER BY at DESC LIMIT 5000`

const sqlRepFlushed = `
SELECT * FROM (
  SELECT i.instance_id, i.name AS instance, t.event_at AS at, t.login_name, t.host_name, t.program_name, t.session_id,
         t.database_name, coalesce(t.sub, 'DBCC') AS command, t.statement AS text, 'default trace' AS source
    FROM pgvigil.mssql_trace_events t JOIN pgvigil.instances i ON i.instance_id = t.instance_id
   WHERE ` + repScope + ` AND t.kind = 'dbcc' AND t.event_at > now() - make_interval(days => $2)
     AND (t.sub ~* '(FREEPROCCACHE|FREESYSTEMCACHE|FLUSHPROCINDB)'
          -- the command's own name only: the default trace reader names it in sub, 'DBCC' when it could not
          OR (t.sub = 'DBCC' AND t.statement ~* '^\s*DBCC\s+(FREEPROCCACHE|FREESYSTEMCACHE|FLUSHPROCINDB)'))
  UNION ALL
  SELECT i.instance_id, i.name, e.log_at, NULL, NULL, NULL, NULL, NULL, 'cachestore flush', e.message, 'error log'
    FROM pgvigil.mssql_errorlog e JOIN pgvigil.instances i ON i.instance_id = e.instance_id
   WHERE ` + repScope + ` AND e.log_at > now() - make_interval(days => $2) AND e.message ILIKE '%cachestore flush%'
) f
 ORDER BY at DESC
 LIMIT 5000`

const sqlRepActionsCols = `
SELECT a.action_id, a.instance_id, coalesce(i.name, a.instance_name) AS instance, a.engine, a.at, a.ui_user, a.client, a.action,
       a.pid AS session_id, a.backend_start, a.target_user, a.target_host, a.target_app, a.target, a.reason, a.outcome,
       coalesce(a.server_message, a.detail) AS detail
  FROM pgvigil.actions_log a LEFT JOIN pgvigil.instances i ON i.instance_id = a.instance_id`

// the actions log keeps a row of a removed instance (instance_id NULL): the fleet's report shows it, a folder's does not
const sqlRepKilled = sqlRepActionsCols + `
 WHERE ($1::int[] IS NULL OR a.instance_id = ANY($1::int[])) AND a.at > now() - make_interval(days => $2)
   AND a.action IN ('kill', 'terminate', 'cancel')
 ORDER BY a.at DESC
 LIMIT 5000`

const sqlRepActions = sqlRepActionsCols + `
 WHERE ($1::int[] IS NULL OR a.instance_id = ANY($1::int[])) AND a.at > now() - make_interval(days => $2)
 ORDER BY a.at DESC
 LIMIT 5000`

const sqlRepAudit = `
SELECT i.instance_id, i.name AS instance, e.snapshot_at AS at, e.usename, e.datname, e.client, e.class, e.command,
       e.object_type, e.object_name, e.target_role, e.statement
  FROM pgvigil.pgaudit_events e JOIN pgvigil.instances i ON i.instance_id = e.instance_id
 WHERE ` + repScope + ` AND e.class IN ('ROLE', 'DDL') AND e.snapshot_at > now() - make_interval(days => $2)
 ORDER BY e.snapshot_at DESC
 LIMIT 2000`

// the managed services' admin roles (no role is a superuser there): Amazon RDS / Aurora, Azure, Cloud SQL, AlloyDB
const repAdminRoles = `'rds_superuser', 'azure_pg_admin', 'cloudsqlsuperuser', 'alloydbsuperuser'`

// role members: SQL Server's server roles; PostgreSQL's superusers (the attribute, shown as the role 'superuser') and
// the members of the predefined pg_* roles (role_members: direct grants)
const sqlRepRoleMembers = `
SELECT * FROM (
  SELECT i.instance_id, i.name AS instance, 'sqlserver' AS engine, m.role_name, m.login_name, m.login_type, m.type_desc,
         m.is_disabled, m.created_at, m.modified_at, m.first_seen
    FROM pgvigil.mssql_server_role_members m JOIN pgvigil.instances i ON i.instance_id = m.instance_id
   WHERE ` + repScope + ` AND m.is_present
  UNION ALL
  SELECT i.instance_id, i.name, 'postgres', 'superuser', a.rolname, CASE WHEN a.canlogin THEN 'L' ELSE 'R' END,
         CASE WHEN a.canlogin THEN 'LOGIN ROLE' ELSE 'ROLE' END, NOT a.canlogin, NULL, NULL, NULL
    FROM pgvigil.role_attributes a JOIN pgvigil.instances i ON i.instance_id = a.instance_id
   WHERE ` + repScope + ` AND coalesce(i.engine, 'postgres') = 'postgres' AND a.is_present AND a.super
  UNION ALL
  SELECT DISTINCT i.instance_id, i.name, 'postgres', m.role_name, m.member_name, CASE WHEN a.canlogin THEN 'L' ELSE 'R' END,
         CASE WHEN a.canlogin THEN 'LOGIN ROLE' ELSE 'ROLE' END, NOT coalesce(a.canlogin, true), NULL::timestamptz, NULL::timestamptz, NULL::timestamptz
    FROM pgvigil.role_members m JOIN pgvigil.instances i ON i.instance_id = m.instance_id
    LEFT JOIN pgvigil.role_attributes a ON a.instance_id = m.instance_id AND a.rolname = m.member_name AND a.is_present
   WHERE ` + repScope + ` AND coalesce(i.engine, 'postgres') = 'postgres' AND m.is_present
     AND (m.role_name LIKE 'pg\_%' OR m.role_name IN (` + repAdminRoles + `))
) x
 WHERE $2 = '' OR x.role_name = $2
 ORDER BY instance, role_name, login_name`

const sqlRepRoleNames = `
SELECT DISTINCT engine, role_name FROM (
  SELECT 'sqlserver' AS engine, m.role_name FROM pgvigil.mssql_server_role_members m JOIN pgvigil.instances i ON i.instance_id = m.instance_id
   WHERE ` + repScope + ` AND m.is_present
  UNION ALL
  SELECT 'postgres', 'superuser' FROM pgvigil.instances i WHERE ` + repScope + ` AND coalesce(i.engine, 'postgres') = 'postgres'
  UNION ALL
  SELECT 'postgres', m.role_name FROM pgvigil.role_members m JOIN pgvigil.instances i ON i.instance_id = m.instance_id
   WHERE ` + repScope + ` AND m.is_present AND (m.role_name LIKE 'pg\_%' OR m.role_name IN (` + repAdminRoles + `))
) r
 ORDER BY 1 DESC, 2`

// SQL logins: the password age in whole days since PasswordLastSetTime; NULL = the server did not say
const sqlRepLogins = `
SELECT i.instance_id, i.name AS instance, l.login_name, l.is_disabled, l.created_at, l.modified_at, l.password_set_at,
       floor(extract(epoch FROM now() - l.password_set_at) / 86400)::int AS password_age_days,
       l.is_policy_checked, l.is_expiration_checked, l.days_until_expiration, l.is_expired, l.is_locked, l.bad_password_count, l.snapshot_at
  FROM pgvigil.mssql_sql_logins l JOIN pgvigil.instances i ON i.instance_id = l.instance_id
 WHERE ` + repScope + ` AND l.is_present AND ($2 OR NOT coalesce(l.is_disabled, false))
 ORDER BY password_age_days DESC NULLS LAST, i.name, l.login_name`

const sqlRepPgLogins = `
SELECT i.instance_id, i.name AS instance, a.rolname AS role_name, a.super AS is_superuser, a.valid_until,
       CASE WHEN a.valid_until IS NULL OR a.valid_until = 'infinity' THEN NULL
            ELSE floor(extract(epoch FROM a.valid_until - now()) / 86400)::int END AS days_until_expiration,
       p.method, CASE WHEN p.role_name IS NULL THEN coalesce(s.status, 'not read') ELSE 'read' END AS method_read,
       s.note AS method_note
  FROM pgvigil.role_attributes a JOIN pgvigil.instances i ON i.instance_id = a.instance_id
  LEFT JOIN pgvigil.pg_role_passwords p ON p.instance_id = a.instance_id AND p.role_name = a.rolname AND p.is_present
  LEFT JOIN pgvigil.report_read_state s ON s.instance_id = a.instance_id AND s.part = 'passwords'
 WHERE ` + repScope + ` AND coalesce(i.engine, 'postgres') = 'postgres' AND a.is_present AND a.canlogin
 ORDER BY i.name, a.rolname`

const sqlRepServices = `
SELECT i.instance_id, i.name AS instance, s.service_name,
       CASE WHEN s.service_name ILIKE 'SQL Server Agent%' THEN 'SQL Server Agent'
            WHEN s.service_name ILIKE 'SQL Full-text%' THEN 'Full-text'
            WHEN s.service_name ILIKE 'SQL Server Launchpad%' THEN 'Launchpad'
            WHEN s.service_name ILIKE 'SQL Server PolyBase%' THEN 'PolyBase'
            WHEN s.service_name ILIKE 'SQL Server (%' OR s.service_name ILIKE 'SQL Server' THEN 'SQL Server'
            ELSE split_part(s.service_name, ' (', 1) END AS service_type,
       s.startup_type, s.status, s.process_id, s.last_startup_at, s.service_account,
       (s.service_account LIKE '%$') AS is_managed_account, e.filename, s.is_clustered, e.cluster_nodename, s.ifi_enabled,
       s.snapshot_at
  FROM pgvigil.mssql_service s JOIN pgvigil.instances i ON i.instance_id = s.instance_id
  LEFT JOIN pgvigil.mssql_service_ext e ON e.instance_id = s.instance_id AND e.service_name = s.service_name
 WHERE ` + repScope + ` AND s.is_present
 ORDER BY i.name, s.service_name`

// SQL Server table sizes: each database the server still lists (the backups read's list), its tables at that
// database's newest read (a database a cut or a failed pass left out keeps its last read), against the read nearest
// &days= before it (the growth per day over the span between the two; NULL with one read only)
const sqlRepTables = `
WITH dbs AS (
  SELECT b.instance_id, b.database_name FROM pgvigil.mssql_backup_state b JOIN pgvigil.instances i ON i.instance_id = b.instance_id
   WHERE ` + repScope + ` AND i.engine = 'sqlserver' AND b.is_present
), last AS (
  SELECT d.instance_id, d.database_name, x.at
    FROM dbs d CROSS JOIN LATERAL (SELECT t.snapshot_at AS at FROM pgvigil.mssql_table_size t
                                    WHERE t.instance_id = d.instance_id AND t.database_name = d.database_name
                                    ORDER BY t.snapshot_at DESC LIMIT 1) x
)
SELECT i.instance_id, i.name AS instance, t.snapshot_at, t.database_name, t.schema_name, t.table_name, t.row_count,
       t.reserved_kb, t.used_kb, t.data_kb, t.index_kb, b.snapshot_at AS base_at,
       round((extract(epoch FROM t.snapshot_at - b.snapshot_at) / 86400)::numeric, 1) AS calc_days,
       CASE WHEN b.snapshot_at IS NOT NULL AND t.snapshot_at > b.snapshot_at
            THEN round((t.row_count - b.row_count) / (extract(epoch FROM t.snapshot_at - b.snapshot_at) / 86400)::numeric, 1) END AS avg_rows_per_day,
       CASE WHEN b.snapshot_at IS NOT NULL AND t.snapshot_at > b.snapshot_at
            THEN round((t.reserved_kb - b.reserved_kb) / (extract(epoch FROM t.snapshot_at - b.snapshot_at) / 86400)::numeric, 1) END AS avg_kb_per_day
  FROM last JOIN pgvigil.mssql_table_size t ON t.instance_id = last.instance_id AND t.database_name = last.database_name AND t.snapshot_at = last.at
  JOIN pgvigil.instances i ON i.instance_id = t.instance_id
  LEFT JOIN LATERAL (
    SELECT o.snapshot_at, o.row_count, o.reserved_kb FROM pgvigil.mssql_table_size o
     WHERE o.instance_id = t.instance_id AND o.database_name = t.database_name AND o.schema_name = t.schema_name
       AND o.table_name = t.table_name AND o.snapshot_at < t.snapshot_at AND o.snapshot_at >= t.snapshot_at - make_interval(days => $2)
     ORDER BY o.snapshot_at LIMIT 1) b ON true
 ORDER BY t.reserved_kb DESC NULLS LAST, i.name, t.database_name, t.schema_name, t.table_name
 LIMIT $3`

// one row per query (or per database, object or instance: &group=) over the window, both engines. PostgreSQL has no
// CPU time (pg_stat_statements' total_exec_time is the duration): its cpu_ms is NULL. Reads: SQL Server logical reads,
// PostgreSQL shared blocks hit + read; physical: SQL Server physical reads, PostgreSQL shared blocks read; writes: SQL
// Server logical writes (pages dirtied), PostgreSQL shared blocks dirtied. Each engine's samples are summed per key
// first and the statement's text joined once per key.
const sqlRepQueryRows = `
WITH ms AS (
  SELECT s.instance_id, s.database_name, s.query_key, sum(s.executions) AS executions, sum(s.cpu_us) / 1000.0 AS cpu_ms,
         sum(s.duration_us) / 1000.0 AS duration_ms, sum(s.logical_reads) AS logical_reads, sum(s.physical_reads) AS physical_reads,
         sum(s.logical_writes) AS writes, sum(s.row_count) AS row_count, max(s.plans) AS plans, max(s.max_grant_kb) AS max_grant_kb
    FROM pgvigil.mssql_pc_sample s JOIN pgvigil.instances i ON i.instance_id = s.instance_id
   WHERE ` + repScope + ` AND s.snapshot_at > $2 AND s.snapshot_at <= $3
   GROUP BY s.instance_id, s.database_name, s.query_key
), pg AS (
  SELECT d.instance_id, d.datname, d.queryid, sum(d.calls) AS executions, sum(d.total_exec_ms) AS duration_ms,
         sum(coalesce(d.shared_blks_hit, 0) + coalesce(d.shared_blks_read, 0)) AS logical_reads, sum(d.shared_blks_read) AS physical_reads,
         sum(d.shared_blks_dirtied) AS writes, sum(d.rows) AS row_count
    FROM pgvigil.statements_delta d JOIN pgvigil.instances i ON i.instance_id = d.instance_id
   WHERE ` + repScope + ` AND d.snapshot_at > $2 AND d.snapshot_at <= $3
   GROUP BY d.instance_id, d.datname, d.queryid
), q AS (
  SELECT ms.instance_id, 'sqlserver' AS engine, ms.database_name, t.object_name, ms.query_key, t.query AS query_text,
         ms.executions, ms.cpu_ms, ms.duration_ms, ms.logical_reads, ms.physical_reads, ms.writes, ms.row_count, ms.plans, ms.max_grant_kb
    FROM ms LEFT JOIN pgvigil.mssql_pc_text t ON t.instance_id = ms.instance_id AND t.query_key = ms.query_key
  UNION ALL
  SELECT pg.instance_id, 'postgres', pg.datname, NULL, pg.queryid::text, st.query,
         pg.executions, NULL, pg.duration_ms, pg.logical_reads, pg.physical_reads, pg.writes, pg.row_count, NULL, NULL
    FROM pg LEFT JOIN pgvigil.statement_text st ON st.instance_id = pg.instance_id AND st.queryid = pg.queryid
)
SELECT q.instance_id, i.name AS instance, q.engine,
       CASE WHEN $4 <> 'instance' THEN q.database_name END AS database_name,
       CASE WHEN $4 IN ('query', 'object') THEN q.object_name END AS object_name,
       CASE WHEN $4 = 'query' THEN q.query_key END AS query_key,
       CASE WHEN $4 = 'query' THEN left(q.query_text, 4000) END AS query_text,
       sum(q.executions) AS executions,
       round(sum(q.executions) / greatest(extract(epoch FROM $3::timestamptz - $2::timestamptz) / 60, 1)::numeric, 2) AS executions_per_min,
       sum(q.cpu_ms) AS cpu_ms, sum(q.cpu_ms) / nullif(sum(q.executions), 0) AS avg_cpu_ms,
       sum(q.duration_ms) AS duration_ms, sum(q.duration_ms) / nullif(sum(q.executions), 0) AS avg_duration_ms,
       sum(q.logical_reads) AS logical_reads, sum(q.logical_reads) / nullif(sum(q.executions), 0) AS avg_logical_reads,
       sum(q.physical_reads) AS physical_reads, sum(q.writes) AS writes, sum(q.row_count) AS row_count,
       max(q.plans) AS plans, max(q.max_grant_kb) AS max_grant_kb, count(*) AS queries
  FROM q JOIN pgvigil.instances i ON i.instance_id = q.instance_id
 GROUP BY q.instance_id, i.name, q.engine, 4, 5, 6, 7
 ORDER BY CASE $5 WHEN 'duration' THEN sum(q.duration_ms) WHEN 'executions' THEN sum(q.executions)
                  WHEN 'reads' THEN sum(q.logical_reads) WHEN 'writes' THEN sum(q.writes)
                  ELSE coalesce(sum(q.cpu_ms), sum(q.duration_ms)) END DESC NULLS LAST, i.name
 LIMIT $6`

const sqlRepQuerySeries = `
WITH x AS (
  SELECT s.snapshot_at, 'sqlserver' AS engine, s.executions, s.cpu_us / 1000.0 AS cpu_ms, s.duration_us / 1000.0 AS duration_ms,
         s.logical_reads, s.physical_reads
    FROM pgvigil.mssql_pc_sample s JOIN pgvigil.instances i ON i.instance_id = s.instance_id
   WHERE ` + repScope + ` AND s.snapshot_at > $2 AND s.snapshot_at <= $3
  UNION ALL
  SELECT d.snapshot_at, 'postgres', d.calls, NULL, d.total_exec_ms, coalesce(d.shared_blks_hit, 0) + coalesce(d.shared_blks_read, 0), d.shared_blks_read
    FROM pgvigil.statements_delta d JOIN pgvigil.instances i ON i.instance_id = d.instance_id
   WHERE ` + repScope + ` AND d.snapshot_at > $2 AND d.snapshot_at <= $3
)
SELECT to_timestamp(floor(extract(epoch FROM snapshot_at) / $4) * $4) AS at, engine, sum(executions) AS executions,
       sum(cpu_ms) AS cpu_ms, sum(duration_ms) AS duration_ms, sum(logical_reads) AS logical_reads, sum(physical_reads) AS physical_reads
  FROM x
 GROUP BY 1, 2
 ORDER BY 1, 2`

// the recycle bin: instances made inactive (the repository owner's UPDATE; a config that names one again brings it
// back), and active ones no collection has reached for a day (removed from the config, or unreachable)
const sqlRepRecycle = `
SELECT i.instance_id, i.name AS instance, coalesce(i.engine, 'postgres') AS engine, i.is_active, i.last_seen,
       (SELECT max(c.snapshot_at) FROM pgvigil.collection_dates c WHERE c.instance_id = i.instance_id) AS last_collection,
       floor(extract(epoch FROM now() - coalesce((SELECT max(c.snapshot_at) FROM pgvigil.collection_dates c WHERE c.instance_id = i.instance_id), i.last_seen)))::bigint AS secs_since
  FROM pgvigil.instances i
 WHERE ($1::int[] IS NULL OR i.instance_id = ANY($1::int[]))
   AND (NOT i.is_active OR coalesce((SELECT max(c.snapshot_at) FROM pgvigil.collection_dates c WHERE c.instance_id = i.instance_id), i.last_seen) < now() - interval '1 day')
 ORDER BY i.is_active, i.name`

// Reports serves the Reports tree's pages (see the top of this file).
func (s *Server) Reports(w http.ResponseWriter, r *http.Request) {
	ids, err := reportScope(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	bad := func(err error) { writeErr(w, http.StatusBadRequest, err) }
	q := r.URL.Query()
	days := 7
	if v := q.Get("days"); v != "" {
		if days, err = strconv.Atoi(v); err != nil || !reportDays[days] {
			bad(errors.New("days must be one of 1, 2, 7, 14, 30, 60, 90, 180, 365"))
			return
		}
	}
	state := func(engine string, parts ...string) part {
		return part{"state", sqlRepState, []any{ids, parts, engine}}
	}
	switch q.Get("r") {
	case "props":
		s.multi(w, r, []part{
			{"props", sqlRepProps, []any{ids}},
			state("sqlserver", "extended_properties"),
			{"pgstate", sqlRepState, []any{ids, []string{"comments"}, "postgres"}},
		})
	case "finder":
		top, err := reportInt(r, "top", 1000, 1, 20000)
		if err != nil {
			bad(err)
			return
		}
		like := strings.TrimSpace(q.Get("like"))
		if len(like) > 200 {
			bad(errors.New("like must be 200 characters at most"))
			return
		}
		// a name part is searched anywhere in the name; a pattern with % is taken as written (an _ alone is a common
		// separator in database names, never taken as the wildcard's sign of a pattern)
		if like != "" && !strings.Contains(like, "%") {
			like = "%" + like + "%"
		}
		s.multi(w, r, []part{{"databases", sqlRepFinder, []any{ids, like, q.Get("system") == "1", top}}})
	case "deadlocks":
		_, from, to, err := params(r, false)
		if err != nil {
			bad(err)
			return
		}
		s.multi(w, r, []part{
			{"deadlocks", sqlRepDeadlocks, []any{ids, from, to}},
			{"pg", sqlRepPgDeadlocks, []any{ids, from, to}},
		})
	case "failed":
		s.multi(w, r, []part{
			{"server", sqlRepFailedServer, []any{ids, days}},
			{"logins", sqlRepFailedBy("login_name"), []any{ids, days}},
			{"clients", sqlRepFailedBy("client"), []any{ids, days}},
			{"messages", sqlRepFailedBy("reason"), []any{ids, days}},
			{"failed", sqlRepFailedDetail, []any{ids, days}},
		})
	case "flushed":
		s.multi(w, r, []part{{"flushed", sqlRepFlushed, []any{ids, days}}})
	case "killed":
		s.multi(w, r, []part{{"killed", sqlRepKilled, []any{ids, days}}})
	case "actions":
		s.multi(w, r, []part{
			{"actions", sqlRepActions, []any{ids, days}},
			{"audit", sqlRepAudit, []any{ids, days}},
		})
	case "roles":
		role := q.Get("role")
		if len(role) > 128 {
			bad(errors.New("role must be 128 characters at most"))
			return
		}
		s.multi(w, r, []part{
			{"members", sqlRepRoleMembers, []any{ids, role}},
			{"roles", sqlRepRoleNames, []any{ids}},
			state("sqlserver", "role_members"),
		})
	case "pwage":
		s.multi(w, r, []part{
			{"logins", sqlRepLogins, []any{ids, q.Get("disabled") == "1"}},
			{"pg", sqlRepPgLogins, []any{ids}},
			state("sqlserver", "sql_logins"),
		})
	case "services":
		s.multi(w, r, []part{
			{"services", sqlRepServices, []any{ids}},
			state("sqlserver", "services"),
		})
	case "tables":
		top, err := reportInt(r, "top", 100, 1, 5000)
		if err != nil {
			bad(err)
			return
		}
		s.multi(w, r, []part{
			{"tables", sqlRepTables, []any{ids, days, top}},
			state("sqlserver", "table_sizes"),
		})
	case "querystats":
		_, from, to, err := params(r, false)
		if err != nil {
			bad(err)
			return
		}
		group, order := q.Get("group"), q.Get("order")
		if group == "" {
			group = "query"
		}
		if order == "" {
			order = "cpu"
		}
		if !map[string]bool{"query": true, "database": true, "object": true, "instance": true}[group] {
			bad(errors.New("group must be query, database, object or instance"))
			return
		}
		if !map[string]bool{"cpu": true, "duration": true, "executions": true, "reads": true, "writes": true}[order] {
			bad(errors.New("order must be cpu, duration, executions, reads or writes"))
			return
		}
		top, err := reportInt(r, "top", 100, 1, 5000)
		if err != nil {
			bad(err)
			return
		}
		s.multi(w, r, []part{{"stats", sqlRepQueryRows, []any{ids, from, to, group, order, top}}})
	case "qscharts":
		_, from, to, err := params(r, false)
		if err != nil {
			bad(err)
			return
		}
		// about 300 points over any window, never finer than the five-minute reads
		step := int(math.Ceil(to.Sub(from).Seconds() / 300))
		if step < 300 {
			step = 300
		}
		s.multi(w, r, []part{
			{"series", sqlRepQuerySeries, []any{ids, from, to, step}},
			{"top", sqlRepQueryRows, []any{ids, from, to, "query", "cpu", 10}},
			{"meta", `SELECT $1::int AS step_secs`, []any{step}},
		})
	case "recycle":
		s.multi(w, r, []part{{"instances", sqlRepRecycle, []any{ids}}})
	default:
		bad(errors.New("r must be props, finder, deadlocks, failed, flushed, killed, actions, roles, pwage, services, tables, querystats, qscharts or recycle"))
	}
}
