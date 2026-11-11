package web

import (
	"net/http"
)

// The Plan cache tab of a SQL Server instance (task 150; sp_QuickieCache's and sp_BlitzCache's reads): what each
// cached statement did over the window, from the differences of sys.dm_exec_query_stats between two reads
// (mssql_plancache, every five minutes; 0092), and what the cache holds (mssql_plancache_health, hourly).
//
//	GET /api/mssql/plancache?instance=N[&from=&to=][&db=<database id>][&scope=noqs][&part=...]
//	  state      the two collections' last runs
//	  reads      the reads of the window that took differences: how many, the seconds they cover, how many were cut
//	  databases  the instance's databases with their Query Store switch (the filter, and scope=noqs)
//	  totals     the window's sums over every statement (db= / scope= narrow them)
//	  top        one row per query key: executions, CPU, duration, reads, writes, rows, spills, grants, plans; the
//	             most CPU first, 1,000 at most; the text where one was sent
//	  series     the window in about 120 steps: executions, CPU and duration per second
//	  health     the cache per database as last read; singles and duplicates: its two lists
//	  findings   the plan cache findings of the instance
//
// scope=noqs keeps the databases whose Query Store is off (the plan cache is their only statement history).

const sqlMSSQLPCReads = `
SELECT count(*) AS reads, coalesce(sum(r.interval_secs), 0)::float8 AS covered_secs, count(*) FILTER (WHERE r.capped) AS cut_reads,
       min(r.snapshot_at) AS first_read, max(r.snapshot_at) AS last_read
  FROM pgvigil.mssql_pc_read r
 WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3`

const sqlMSSQLPCDatabases = `
SELECT d.database_id, d.database_name, d.query_store_on, d.database_state, d.snapshot_at
  FROM pgvigil.mssql_pc_database d
 WHERE d.instance_id = $1
 ORDER BY d.database_name, d.database_id`

// pcScope: $4 one database's id or NULL, $5 true = only databases whose Query Store is off.
const pcScope = `($4::int IS NULL OR s.database_id = $4)
   AND (NOT $5::boolean OR NOT EXISTS (SELECT 1 FROM pgvigil.mssql_pc_database q WHERE q.instance_id = s.instance_id AND q.database_id = s.database_id AND q.query_store_on))`

const sqlMSSQLPCTotals = `
SELECT count(DISTINCT (s.database_id, s.query_key)) AS statements, coalesce(sum(s.executions), 0)::bigint AS executions,
       round(coalesce(sum(s.cpu_us), 0) / 1000.0, 1) AS cpu_ms, round(coalesce(sum(s.duration_us), 0) / 1000.0, 1) AS duration_ms,
       coalesce(sum(s.logical_reads), 0)::bigint AS logical_reads
  FROM pgvigil.mssql_pc_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ` + pcScope

const sqlMSSQLPCTop = `
WITH p AS (
  SELECT s.database_id, s.query_key, max(s.database_name) AS database_name,
         sum(s.executions)::bigint AS executions, sum(s.cpu_us)::bigint AS cpu_us, sum(s.duration_us)::bigint AS duration_us,
         sum(s.logical_reads)::bigint AS logical_reads, sum(s.physical_reads)::bigint AS physical_reads,
         sum(s.logical_writes)::bigint AS logical_writes, sum(s.row_count)::bigint AS row_count, sum(s.spills)::bigint AS spills,
         max(s.max_grant_kb) AS max_grant_kb, max(s.max_used_grant_kb) AS max_used_grant_kb, max(s.max_dop) AS max_dop,
         max(s.plans) AS plans, count(*) AS intervals, max(s.snapshot_at) AS last_seen
    FROM pgvigil.mssql_pc_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ` + pcScope + `
   GROUP BY s.database_id, s.query_key
)
SELECT p.database_id, coalesce(p.database_name, 'database ' || p.database_id) AS database, p.query_key, t.object_name, t.query,
       q.query_store_on, p.executions, round(p.cpu_us / 1000.0, 1) AS cpu_ms, round(p.cpu_us / 1000.0 / nullif(p.executions, 0), 3) AS avg_cpu_ms,
       round(p.duration_us / 1000.0, 1) AS duration_ms, round(p.duration_us / 1000.0 / nullif(p.executions, 0), 3) AS avg_duration_ms,
       p.logical_reads, round(p.logical_reads::numeric / nullif(p.executions, 0), 1) AS avg_logical_reads, p.physical_reads,
       p.logical_writes, p.row_count, p.spills, p.max_grant_kb, p.max_used_grant_kb,
       round(100.0 * p.max_used_grant_kb / nullif(p.max_grant_kb, 0), 1) AS grant_used_pct, p.max_dop, p.plans, p.intervals, p.last_seen
  FROM p
  LEFT JOIN pgvigil.mssql_pc_text t ON t.instance_id = $1 AND t.query_key = p.query_key
  LEFT JOIN pgvigil.mssql_pc_database q ON q.instance_id = $1 AND q.database_id = p.database_id
 ORDER BY p.cpu_us DESC, p.query_key
 LIMIT 1000`

const sqlMSSQLPCSeries = `
WITH secs AS (
  SELECT to_timestamp(floor(extract(epoch FROM r.snapshot_at) / $6) * $6) AS step, sum(r.interval_secs)::float8 AS secs
    FROM pgvigil.mssql_pc_read r
   WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
   GROUP BY 1
), w AS (
  SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $6) * $6) AS step, sum(s.executions) AS executions,
         sum(s.cpu_us) AS cpu_us, sum(s.duration_us) AS duration_us
    FROM pgvigil.mssql_pc_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ` + pcScope + `
   GROUP BY 1
)
SELECT c.step AS snapshot_at, round((coalesce(w.executions, 0) / c.secs)::numeric, 3) AS executions_s,
       round((coalesce(w.cpu_us, 0) / 1000.0 / c.secs)::numeric, 3) AS cpu_ms_s,
       round((coalesce(w.duration_us, 0) / 1000.0 / c.secs)::numeric, 3) AS duration_ms_s
  FROM secs c LEFT JOIN w ON w.step = c.step
 WHERE c.secs > 0
 ORDER BY 1`

const sqlMSSQLPCHealth = `
SELECT h.database_id, coalesce(h.database_name, 'database ' || h.database_id) AS database, h.plans, round(h.plan_bytes / 1048576.0, 1) AS plan_mb,
       h.single_use, round(h.single_use_bytes / 1048576.0, 1) AS single_use_mb, round(100.0 * h.single_use / nullif(h.plans, 0), 1) AS single_use_pct,
       h.adhoc_plans, h.prepared_plans, h.proc_plans, h.statements, h.compiled_24h, round(100.0 * h.compiled_24h / nullif(h.statements, 0), 1) AS compiled_24h_pct,
       h.compiled_4h, h.compiled_1h, h.oldest_compile, h.duplicate_statements, h.duplicate_hashes,
       round(100.0 * h.duplicate_statements / nullif(h.statements, 0), 1) AS duplicate_pct, h.snapshot_at
  FROM pgvigil.mssql_pc_health h
 WHERE h.instance_id = $1
 ORDER BY h.plans DESC, h.database_id`

const sqlMSSQLPCList = `
SELECT l.ord, l.database_id, coalesce(l.database_name, 'database ' || l.database_id) AS database, l.plan_kind, round(l.size_bytes / 1024.0, 1) AS size_kb,
       l.query_hash, l.plans, l.statements, l.executions, l.query, l.snapshot_at
  FROM pgvigil.mssql_pc_list l
 WHERE l.instance_id = $1 AND l.list = $2
 ORDER BY l.ord`

const sqlMSSQLPCFindings = `
SELECT f.severity, f.check_name, f.object, f.at, f.detail
  FROM pgvigil.mssql_plancache_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.check_name, f.object`

// MSSQLPlanCache is GET /api/mssql/plancache.
func (s *Server) MSSQLPlanCache(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	database, err := dbFilter(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	noQS := r.URL.Query().Get("scope") == "noqs"
	s.multiPart(w, r, []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_plancache", "mssql_plancache_health"}}},
		{"reads", sqlMSSQLPCReads, []any{id, from, to}},
		{"databases", sqlMSSQLPCDatabases, []any{id}},
		{"totals", sqlMSSQLPCTotals, []any{id, from, to, database, noQS}},
		{"top", sqlMSSQLPCTop, []any{id, from, to, database, noQS}},
		{"series", sqlMSSQLPCSeries, []any{id, from, to, database, noQS, procStep(to.Sub(from).Seconds())}},
		{"health", sqlMSSQLPCHealth, []any{id}},
		{"singles", sqlMSSQLPCList, []any{id, "single_use"}},
		{"duplicates", sqlMSSQLPCList, []any{id, "duplicate"}},
		{"findings", sqlMSSQLPCFindings, []any{id}},
	})
}
