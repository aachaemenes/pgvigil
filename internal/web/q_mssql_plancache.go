package web

import (
	"net/http"
	"strings"
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
//	  compare, compare_windows   with compare=prev|day|week: PerformanceMonitor's compare of the window against
//	             the same span earlier, and the two windows' reads (sqlMSSQLPCCompare)
//
// top's plan_hash, sql_handle and plan_handle are the statements cached at the last read (handles_at), not the
// window's.
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

// sqlMSSQLPCTop: the hashes and handles (PerformanceMonitor's 'Hashes and handles' group, one value of each per
// query as its MAX, DarlingDataReader.cs:1162-1164) are the statements the cache held at the last read
// (mssql_pc_last with 0126's mssql_pc_handles), not the window's: a query no longer cached has none.
const sqlMSSQLPCTop = `
WITH hh AS (
  SELECT l.database_id, l.query_key, max(h.plan_hash) AS plan_hash, max(h.sql_handle) AS sql_handle, max(l.plan_handle) AS plan_handle,
         count(DISTINCT h.plan_hash) AS plan_hashes, count(*) AS cached_statements
    FROM pgvigil.mssql_pc_last l
    JOIN pgvigil.mssql_pc_handles h ON h.instance_id = l.instance_id AND h.plan_handle = l.plan_handle AND h.stmt_start = l.stmt_start
                                   AND h.stmt_end = l.stmt_end AND h.creation_time = l.creation_time
   WHERE l.instance_id = $1
   GROUP BY 1, 2
), p AS (
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
       round(100.0 * p.max_used_grant_kb / nullif(p.max_grant_kb, 0), 1) AS grant_used_pct, p.max_dop, p.plans, p.intervals, p.last_seen,
       hh.plan_hash, hh.sql_handle, hh.plan_handle, hh.plan_hashes, hh.cached_statements,
       (SELECT st.snapshot_at FROM pgvigil.mssql_pc_state st WHERE st.instance_id = $1) AS handles_at
  FROM p
  LEFT JOIN hh ON hh.database_id = p.database_id AND hh.query_key = p.query_key
  LEFT JOIN pgvigil.mssql_pc_text t ON t.instance_id = $1 AND t.query_key = p.query_key
  LEFT JOIN pgvigil.mssql_pc_database q ON q.instance_id = $1 AND q.database_id = p.database_id
 ORDER BY p.cpu_us DESC, p.query_key
 LIMIT 1000`

// sqlMSSQLPCCompare: PerformanceMonitor's compare (top-compare.js, MIT, Erik Darling, Darling Data LLC) on the plan
// cache's stored reads: the window ($2, $3) against the same span $6 seconds earlier, one read over every stored
// sample of both windows keyed by (database, query key: the query hash, or handle:offset where the server gave
// none). NEW / GONE only when no read of either window was cut, nor
// the read just before either window (mssql_pc_read.capped: a statement past the collector's lists has no sample in
// a cut read, so it would flip at the cut; and the read before a window decides how its first read counts, 0092's
// diff / whole / none): otherwise 'not kept before' / 'not kept now' (the windows part says how many reads were
// cut). The union of each window's first 100 by duration, NEW first, GONE last, then by the rise of the average
// duration; n_* count the whole aggregate.
const sqlMSSQLPCCompare = `
WITH cur AS (
  SELECT s.database_id, s.query_key, max(s.database_name) AS database_name, sum(s.executions) AS e, sum(s.duration_us) AS d, sum(s.cpu_us) AS c
    FROM pgvigil.mssql_pc_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ` + pcScope + `
   GROUP BY 1, 2
), bef AS (
  SELECT s.database_id, s.query_key, max(s.database_name) AS database_name, sum(s.executions) AS e, sum(s.duration_us) AS d, sum(s.cpu_us) AS c
    FROM pgvigil.mssql_pc_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2::timestamptz - make_interval(secs => $6)
     AND s.snapshot_at <= $3::timestamptz - make_interval(secs => $6) AND ` + pcScope + `
   GROUP BY 1, 2
), cut AS (
  SELECT count(*) AS cut_reads FROM pgvigil.mssql_pc_read r
   WHERE r.instance_id = $1 AND r.capped
     AND ((r.snapshot_at > $2 AND r.snapshot_at <= $3)
       OR (r.snapshot_at > $2::timestamptz - make_interval(secs => $6) AND r.snapshot_at <= $3::timestamptz - make_interval(secs => $6))
       OR r.snapshot_at IN (SELECT ` + pcEdge + `))
), j AS (
  SELECT coalesce(c.database_id, b.database_id) AS database_id, coalesce(c.query_key, b.query_key) AS query_key,
         coalesce(c.database_name, b.database_name) AS database_name,
         coalesce(c.e, 0) AS now_e, c.d AS now_d, c.c AS now_c, coalesce(b.e, 0) AS bef_e, b.d AS bef_d, b.c AS bef_c
    FROM cur c FULL JOIN bef b ON b.database_id = c.database_id AND b.query_key = c.query_key
), k AS (
  SELECT j.*,
         CASE WHEN j.now_e > 0 AND j.bef_e = 0 THEN CASE WHEN cut.cut_reads = 0 THEN 'new' ELSE 'not kept before' END
              WHEN j.now_e = 0 AND j.bef_e > 0 THEN CASE WHEN cut.cut_reads = 0 THEN 'gone' ELSE 'not kept now' END ELSE '' END AS status,
         row_number() OVER (ORDER BY j.now_d DESC NULLS LAST, j.database_id, j.query_key) AS rn_now,
         row_number() OVER (ORDER BY j.bef_d DESC NULLS LAST, j.database_id, j.query_key) AS rn_bef
    FROM j CROSS JOIN cut
), n AS (
  SELECT k.*, count(*) OVER () AS n_keys, count(*) FILTER (WHERE k.status = '') OVER () AS n_both,
         count(*) FILTER (WHERE k.status IN ('new', 'not kept before')) OVER () AS n_new,
         count(*) FILTER (WHERE k.status IN ('gone', 'not kept now')) OVER () AS n_gone
    FROM k
)
SELECT o.database_id, coalesce(o.database_name, 'database ' || o.database_id) AS database, o.query_key, t.object_name, t.query, o.status,
       o.now_e AS executions, o.bef_e AS before_executions,
       round(o.now_d / 1000.0, 1) AS duration_ms, round(o.bef_d / 1000.0, 1) AS before_duration_ms,
       round(o.now_d / 1000.0 / nullif(o.now_e, 0), 3) AS avg_duration_ms, round(o.bef_d / 1000.0 / nullif(o.bef_e, 0), 3) AS before_avg_duration_ms,
       round(o.now_c / 1000.0 / nullif(o.now_e, 0), 3) AS avg_cpu_ms, round(o.bef_c / 1000.0 / nullif(o.bef_e, 0), 3) AS before_avg_cpu_ms,
       round(100.0 * (o.now_e - o.bef_e) / nullif(o.bef_e, 0), 1) AS executions_pct,
       round(100.0 * (o.now_d / nullif(o.now_e, 0) - o.bef_d / nullif(o.bef_e, 0)) / nullif(o.bef_d / nullif(o.bef_e, 0), 0), 1) AS avg_duration_pct,
       round(100.0 * (o.now_c / nullif(o.now_e, 0) - o.bef_c / nullif(o.bef_e, 0)) / nullif(o.bef_c / nullif(o.bef_e, 0), 0), 1) AS avg_cpu_pct,
       o.n_keys, o.n_both, o.n_new, o.n_gone
  FROM n o
  LEFT JOIN pgvigil.mssql_pc_text t ON t.instance_id = $1 AND t.query_key = o.query_key
 WHERE (o.rn_now <= 100 AND o.now_e > 0) OR (o.rn_bef <= 100 AND o.bef_e > 0)
 ORDER BY CASE WHEN o.status IN ('new', 'not kept before') THEN 0 WHEN o.status IN ('gone', 'not kept now') THEN 2 ELSE 1 END,
          (o.now_d / nullif(o.now_e, 0) - o.bef_d / nullif(o.bef_e, 0)) / nullif(o.bef_d / nullif(o.bef_e, 0), 0) DESC NULLS LAST,
          o.now_d DESC NULLS LAST, o.database_id, o.query_key`

// pcEdge lists the read just before each window (a day back at most), as a select list: $1 instance, $2 the
// window's start, $6 the shift in seconds.
const pcEdge = `(SELECT max(x.snapshot_at) FROM pgvigil.mssql_pc_read x WHERE x.instance_id = $1 AND x.snapshot_at <= $2
                   AND x.snapshot_at > $2::timestamptz - interval '1 day')
         UNION ALL SELECT (SELECT max(x.snapshot_at) FROM pgvigil.mssql_pc_read x WHERE x.instance_id = $1
                   AND x.snapshot_at <= $2::timestamptz - make_interval(secs => $6)
                   AND x.snapshot_at > $2::timestamptz - make_interval(secs => $6) - interval '1 day')`

// sqlMSSQLPCCompareWindows: the two windows, the reads each holds, the seconds they cover and how many were cut
// (edge_cut_reads: the read just before either window, which decides how the window's first read counts),
// whether the windows overlap, and the coverage word ('ok': the earlier window's reads cover at least 90 % of what
// the window's cover; 'partial': less; 'no baseline': no read; q_compare.go's words).
const sqlMSSQLPCCompareWindows = `
WITH w AS (
  SELECT $2::timestamptz AS now_from, $3::timestamptz AS now_to,
         $2::timestamptz - make_interval(secs => $4) AS before_from, $3::timestamptz - make_interval(secs => $4) AS before_to
), c AS (
  SELECT count(*) FILTER (WHERE r.snapshot_at > w.now_from AND r.snapshot_at <= w.now_to) AS now_reads,
         count(*) FILTER (WHERE r.snapshot_at > w.before_from AND r.snapshot_at <= w.before_to) AS before_reads,
         count(*) FILTER (WHERE r.capped AND r.snapshot_at > w.now_from AND r.snapshot_at <= w.now_to) AS now_cut_reads,
         count(*) FILTER (WHERE r.capped AND r.snapshot_at > w.before_from AND r.snapshot_at <= w.before_to) AS before_cut_reads,
         (SELECT count(*) FROM pgvigil.mssql_pc_read e WHERE e.instance_id = $1 AND e.capped
             AND e.snapshot_at IN (SELECT ` + strings.ReplaceAll(pcEdge, "$6", "$4") + `)) AS edge_cut_reads,
         coalesce(sum(r.interval_secs) FILTER (WHERE r.snapshot_at > w.now_from AND r.snapshot_at <= w.now_to), 0)::float8 AS now_covered_secs,
         coalesce(sum(r.interval_secs) FILTER (WHERE r.snapshot_at > w.before_from AND r.snapshot_at <= w.before_to), 0)::float8 AS before_covered_secs
    FROM w LEFT JOIN pgvigil.mssql_pc_read r ON r.instance_id = $1 AND r.snapshot_at > least(w.now_from, w.before_from) AND r.snapshot_at <= w.now_to
)
SELECT w.now_from, w.now_to, w.before_from, w.before_to, $4::float8 < extract(epoch FROM w.now_to - w.now_from) AS overlap, c.*,
       CASE WHEN c.before_reads = 0 THEN 'no baseline' WHEN c.before_covered_secs >= 0.9 * c.now_covered_secs THEN 'ok' ELSE 'partial' END AS coverage
  FROM w CROSS JOIN c`

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
	shift, cmp, err := compareShift(r.URL.Query().Get("compare"), from, to)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	parts := []part{
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
	}
	// the compare reads both windows: only when a shift is asked for (the page asks for it apart, part=compare)
	if cmp {
		parts = append(parts, part{"compare", sqlMSSQLPCCompare, []any{id, from, to, database, noQS, shift}},
			part{"compare_windows", sqlMSSQLPCCompareWindows, []any{id, from, to, shift}})
	}
	s.multiPart(w, r, parts)
}
