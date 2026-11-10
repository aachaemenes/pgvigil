package web

import (
	"errors"
	"net/http"
	"strconv"
)

// The SQL Server CPU, Memory, File IO and TempDB pages (task 119; Darling's CPU, Memory, File I/O and I/O Trends
// tabs, DBA Dash's Performance, Memory and TempDB). Data from the collections mssql_cpu, mssql_memory, mssql_fileio
// and mssql_tempdb (0074). Every series is cut into steps of about 120 over the range, a minute at least ($4).
//
//   GET /api/mssql/cpu?instance=N[&from=&to=]      latest (schedulers, the newest CPU record, the counters' rates),
//                                                   cpu (SQL / other / total % per step), sched (runnable tasks, work
//                                                   queue, workers per step), counters (batch requests, compilations,
//                                                   recompilations, transactions per second per step), checks.
//   GET /api/mssql/memory?instance=N[&from=&to=]   latest, series (target, total, buffer pool, plan cache, stolen,
//                                                   PLE, grants per step), clerks (one row per step and clerk type,
//                                                   the 10 largest types of the range and the rest as '(other)'),
//                                                   clerk_stats (every type of the range: current, max, avg, min),
//                                                   checks.
//   GET /api/mssql/fileio?instance=N[&from=&to=]   latency (read and write ms per step by database and file type,
//                                                   the five busiest groups and the rest as '(other)'), throughput
//                                                   (read and write MB/s per step, the five busiest files and the
//                                                   rest), files (every file over the range: operations, latency,
//                                                   bytes, its path), checks.
//   GET /api/mssql/tempdb[?instance=N]             layout (one row per instance: DBA Dash's TempDB grid; without
//                                                   instance every active SQL Server instance), files, checks.

const sqlMSSQLCPULatest = `
SELECT s.snapshot_at, s.schedulers, s.cpu_count, s.runnable_tasks, s.work_queue, s.pending_io, s.current_workers, s.active_workers,
       s.max_workers, round((100.0 * s.current_workers / nullif(s.max_workers, 0))::numeric, 1) AS worker_pct,
       round((s.runnable_tasks::numeric / nullif(s.schedulers, 0)), 2) AS runnable_per_sched,
       s.batch_s, s.compiles_s, s.recompiles_s, s.transactions_s,
       c.snapshot_at AS cpu_at, c.sql_pct, c.other_pct, 100 - c.idle_pct AS total_pct, c.idle_pct IS NOT NULL AS machine_read
  FROM (SELECT * FROM pgvigil.mssql_sched_sample WHERE instance_id = $1 AND snapshot_at <= $3 ORDER BY snapshot_at DESC LIMIT 1) s
  FULL JOIN (SELECT * FROM pgvigil.mssql_cpu_sample WHERE instance_id = $1 AND snapshot_at <= $3 ORDER BY snapshot_at DESC LIMIT 1) c ON true
 WHERE $2::timestamptz < $3`

const sqlMSSQLCPUSeries = `
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at,
       round(avg(s.sql_pct), 1) AS sql_pct, round(avg(s.other_pct), 1) AS other_pct,
       round(avg(100 - s.idle_pct), 1) AS total_pct, max(100 - s.idle_pct) AS total_max, bool_or(s.idle_pct IS NOT NULL) AS machine_read
  FROM pgvigil.mssql_cpu_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
 GROUP BY 1 ORDER BY 1`

const sqlMSSQLSchedSeries = `
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at,
       round(avg(s.runnable_tasks), 2) AS runnable_tasks, max(s.runnable_tasks) AS runnable_max, round(avg(s.work_queue), 2) AS work_queue,
       round(avg(s.pending_io), 2) AS pending_io, round(avg(s.current_workers), 0) AS current_workers, round(avg(s.active_workers), 0) AS active_workers,
       max(s.max_workers) AS max_workers
  FROM pgvigil.mssql_sched_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
 GROUP BY 1 ORDER BY 1`

// sqlMSSQLCounterSeries: each read's rate weighed by its interval, so a step's figure is the step's own per second.
const sqlMSSQLCounterSeries = `
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at,
       round((sum(s.batch_s * s.interval_secs) / nullif(sum(s.interval_secs) FILTER (WHERE s.batch_s IS NOT NULL), 0))::numeric, 2) AS batch_s,
       round((sum(s.compiles_s * s.interval_secs) / nullif(sum(s.interval_secs) FILTER (WHERE s.compiles_s IS NOT NULL), 0))::numeric, 2) AS compiles_s,
       round((sum(s.recompiles_s * s.interval_secs) / nullif(sum(s.interval_secs) FILTER (WHERE s.recompiles_s IS NOT NULL), 0))::numeric, 2) AS recompiles_s,
       round((sum(s.transactions_s * s.interval_secs) / nullif(sum(s.interval_secs) FILTER (WHERE s.transactions_s IS NOT NULL), 0))::numeric, 2) AS transactions_s
  FROM pgvigil.mssql_sched_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND s.interval_secs > 0
 GROUP BY 1 ORDER BY 1`

// sqlMSSQLPerfChecks: the slice's findings of one instance; $2 picks them by the start of the check's name.
const sqlMSSQLPerfChecks = `
SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_perf_findings
 WHERE instance_id = $1 AND check_name ~ $2
 ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END, check_name, object`

const sqlMSSQLMemoryLatest = `
SELECT s.snapshot_at, s.physical_kb, s.available_kb, round((100.0 * (s.physical_kb - s.available_kb) / nullif(s.physical_kb, 0))::numeric, 1) AS used_pct,
       s.system_state, s.process_kb, s.process_low, s.committed_kb, s.committed_target_kb, s.target_kb, s.total_kb, s.stolen_kb,
       s.buffer_pool_kb, s.plan_cache_kb, s.clerks_kb, s.ple, s.grants_pending, s.grants_outstanding, s.sem_granted, s.sem_waiting,
       s.sem_granted_kb, s.sem_target_kb, s.grants, s.grants_waiting, s.max_grant_kb, s.sum_grant_kb, s.max_requested_kb, s.memory_model,
       (SELECT value_in_use FROM pgvigil.mssql_config c WHERE c.instance_id = $1 AND c.name = 'max server memory (MB)') AS max_server_memory_mb
  FROM pgvigil.mssql_memory_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at <= $3 AND $2::timestamptz < $3
 ORDER BY s.snapshot_at DESC LIMIT 1`

const sqlMSSQLMemorySeries = `
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at,
       round(avg(s.target_kb) / 1024.0, 1) AS target_mb, round(avg(s.total_kb) / 1024.0, 1) AS total_mb,
       round(avg(s.buffer_pool_kb) / 1024.0, 1) AS buffer_pool_mb, round(avg(s.plan_cache_kb) / 1024.0, 1) AS plan_cache_mb,
       round(avg(s.stolen_kb) / 1024.0, 1) AS stolen_mb, round(avg(s.available_kb) / 1024.0, 1) AS available_mb,
       min(s.ple) AS ple_min, round(avg(s.ple), 0) AS ple,
       max(greatest(s.grants_pending, s.grants_waiting, s.sem_waiting)) AS grants_waiting, round(avg(s.sem_granted), 2) AS grants_granted,
       round(max(s.max_grant_kb) / 1024.0, 1) AS max_grant_mb, round(avg(s.sum_grant_kb) / 1024.0, 1) AS sum_grant_mb
  FROM pgvigil.mssql_memory_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
 GROUP BY 1 ORDER BY 1`

// sqlMSSQLClerkSeries: the ten clerk types with the most memory over the range on their own, the rest summed.
const sqlMSSQLClerkSeries = `
WITH top AS (
  SELECT c.clerk_type FROM pgvigil.mssql_memory_clerk c
   WHERE c.instance_id = $1 AND c.snapshot_at > $2 AND c.snapshot_at <= $3 AND c.clerk_type <> '(other)'
   GROUP BY 1 ORDER BY avg(c.pages_kb) DESC LIMIT 10
)
SELECT x.snapshot_at, x.clerk_type, round(avg(x.kb) / 1024.0, 1) AS mb
  FROM (SELECT to_timestamp(floor(extract(epoch FROM c.snapshot_at) / $4) * $4) AS snapshot_at, c.snapshot_at AS at,
               CASE WHEN t.clerk_type IS NULL THEN '(other)' ELSE c.clerk_type END AS clerk_type, sum(c.pages_kb) AS kb
          FROM pgvigil.mssql_memory_clerk c LEFT JOIN top t ON t.clerk_type = c.clerk_type
         WHERE c.instance_id = $1 AND c.snapshot_at > $2 AND c.snapshot_at <= $3
         GROUP BY 1, 2, 3) x
 GROUP BY 1, 2 ORDER BY 1, 2`

const sqlMSSQLClerkStats = `
SELECT c.clerk_type, (array_agg(c.pages_kb ORDER BY c.snapshot_at DESC))[1] AS current_kb, max(c.pages_kb) AS max_kb,
       round(avg(c.pages_kb), 0) AS avg_kb, min(c.pages_kb) AS min_kb, max(c.snapshot_at) AS snapshot_at,
       round((100.0 * (array_agg(c.pages_kb ORDER BY c.snapshot_at DESC))[1]
              / nullif((SELECT clerks_kb FROM pgvigil.mssql_memory_sample m WHERE m.instance_id = $1 AND m.snapshot_at = max(c.snapshot_at)), 0))::numeric, 1) AS current_pct
  FROM pgvigil.mssql_memory_clerk c
 WHERE c.instance_id = $1 AND c.snapshot_at > $2 AND c.snapshot_at <= $3
 GROUP BY c.clerk_type
 ORDER BY 2 DESC NULLS LAST`

// sqlMSSQLFileLatency: read and write latency per step for each database and file type ('tempdb ROWS'); the five
// groups with the most stall over the range on their own, the rest as '(other)'.
const sqlMSSQLFileLatency = `
WITH g AS (
  SELECT coalesce(s.database_name, 'database ' || s.database_id) || ' ' || coalesce(s.type_desc, '?') AS grp, s.*
    FROM pgvigil.mssql_fileio_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
), top AS (
  SELECT grp FROM g GROUP BY grp ORDER BY sum(read_stall_ms + write_stall_ms) DESC, grp LIMIT 5
)
SELECT to_timestamp(floor(extract(epoch FROM g.snapshot_at) / $4) * $4) AS snapshot_at,
       CASE WHEN t.grp IS NULL THEN '(other)' ELSE g.grp END AS grp,
       round((sum(g.read_stall_ms)::numeric / nullif(sum(g.reads), 0)), 2) AS read_ms,
       round((sum(g.write_stall_ms)::numeric / nullif(sum(g.writes), 0)), 2) AS write_ms
  FROM g LEFT JOIN top t ON t.grp = g.grp
 GROUP BY 1, 2 ORDER BY 1, 2`

// sqlMSSQLFileThroughput: MB/s per step for the five files that moved the most bytes over the range, the rest summed.
// A step's seconds are the reads' intervals in it (each read once).
const sqlMSSQLFileThroughput = `
WITH f AS (
  SELECT coalesce(s.database_name, 'database ' || s.database_id) || ': ' || coalesce(s.file_name, 'file ' || s.file_id) AS file, s.*
    FROM pgvigil.mssql_fileio_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
), top AS (
  SELECT file FROM f GROUP BY file ORDER BY sum(read_bytes + write_bytes) DESC, file LIMIT 5
), secs AS (
  SELECT to_timestamp(floor(extract(epoch FROM r.snapshot_at) / $4) * $4) AS step, sum(r.secs) AS secs
    FROM (SELECT snapshot_at, max(interval_secs) AS secs FROM f GROUP BY snapshot_at) r GROUP BY 1
)
SELECT x.step AS snapshot_at, CASE WHEN t.file IS NULL THEN '(other)' ELSE x.file END AS file,
       round((sum(x.read_bytes) / max(c.secs) / 1048576.0)::numeric, 3) AS read_mb_s,
       round((sum(x.write_bytes) / max(c.secs) / 1048576.0)::numeric, 3) AS write_mb_s
  FROM (SELECT to_timestamp(floor(extract(epoch FROM f.snapshot_at) / $4) * $4) AS step, f.* FROM f) x
  JOIN secs c ON c.step = x.step
  LEFT JOIN top t ON t.file = x.file
 GROUP BY 1, 2 ORDER BY 1, 2`

const sqlMSSQLIOFiles = `
SELECT s.database_name, s.file_name, s.type_desc, l.physical_name, sum(s.reads) AS reads,
       round((sum(s.read_stall_ms)::numeric / nullif(sum(s.reads), 0)), 2) AS read_ms, sum(s.read_bytes) AS read_bytes,
       sum(s.writes) AS writes, round((sum(s.write_stall_ms)::numeric / nullif(sum(s.writes), 0)), 2) AS write_ms, sum(s.write_bytes) AS write_bytes,
       sum(s.read_stall_ms + s.write_stall_ms) AS stall_ms, max(s.snapshot_at) AS snapshot_at, s.database_id, s.file_id
  FROM pgvigil.mssql_fileio_sample s
  LEFT JOIN pgvigil.mssql_fileio_last l ON l.instance_id = s.instance_id AND l.database_id = s.database_id AND l.file_id = s.file_id
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
 GROUP BY s.database_id, s.file_id, s.database_name, s.file_name, s.type_desc, l.physical_name
 ORDER BY sum(s.read_stall_ms + s.write_stall_ms) DESC, s.database_name, s.file_id`

// sqlMSSQLTempdb: DBA Dash's TempDB grid, one row per instance ($1 NULL = every active SQL Server instance).
const sqlMSSQLTempdb = `
SELECT t.instance_id, i.name AS instance, t.snapshot_at, t.data_files, t.insufficient_files, t.recommended_files, t.log_files,
       t.even_size, t.even_growth, round(t.data_bytes / 1048576.0, 0) AS total_mb, round(t.log_bytes / 1048576.0, 0) AS log_mb,
       round(t.max_file_bytes / 1048576.0, 0) AS file_mb, round(t.max_growth_bytes / 1048576.0, 0) AS max_growth_mb,
       round(t.max_log_growth_bytes / 1048576.0, 0) AS max_log_growth_mb, t.max_growth_pct, t.max_log_growth_pct, t.volumes,
       t.cpu_count, t.tf1117, t.tf1118, t.flags_required, t.memopt_metadata, t.major
  FROM pgvigil.mssql_tempdb t
  JOIN pgvigil.instances i ON i.instance_id = t.instance_id
 WHERE i.is_active AND ($1::int IS NULL OR t.instance_id = $1)
 ORDER BY i.name`

const sqlMSSQLTempdbFiles = `
SELECT f.instance_id, i.name AS instance, f.file_id, f.file_name, f.type_desc, f.physical_name, f.size_bytes, f.max_size_bytes,
       f.growth_bytes, f.growth_pct, f.volume, f.snapshot_at
  FROM pgvigil.mssql_tempdb_files f
  JOIN pgvigil.instances i ON i.instance_id = f.instance_id
 WHERE i.is_active AND ($1::int IS NULL OR f.instance_id = $1)
 ORDER BY i.name, f.file_id`

const sqlMSSQLTempdbChecks = `
SELECT f.instance_id, i.name AS instance, f.severity, f.check_name, f.object, f.at, f.detail
  FROM pgvigil.mssql_perf_findings f
  JOIN pgvigil.instances i ON i.instance_id = f.instance_id
 WHERE f.check_name ~ '^(a )?tempdb' AND ($1::int IS NULL OR f.instance_id = $1)
 ORDER BY CASE f.severity WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END, i.name, f.check_name`

// perfStep: about 120 steps over the range, a minute at least.
func perfStep(secs float64) int {
	step := int(secs) / 120
	if step < 60 {
		step = 60
	}
	return step
}

// MSSQLCPU is GET /api/mssql/cpu?instance=N[&from=&to=][&part=...].
func (s *Server) MSSQLCPU(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	base := []any{id, from, to, perfStep(to.Sub(from).Seconds())}
	s.multiPart(w, r, []part{
		{"latest", sqlMSSQLCPULatest, []any{id, from, to}},
		{"cpu", sqlMSSQLCPUSeries, base},
		{"sched", sqlMSSQLSchedSeries, base},
		{"counters", sqlMSSQLCounterSeries, base},
		{"checks", sqlMSSQLPerfChecks, []any{id, "^(CPU|scheduler)"}},
	})
}

// MSSQLMemory is GET /api/mssql/memory?instance=N[&from=&to=][&part=...].
func (s *Server) MSSQLMemory(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	base := []any{id, from, to, perfStep(to.Sub(from).Seconds())}
	s.multiPart(w, r, []part{
		{"latest", sqlMSSQLMemoryLatest, []any{id, from, to}},
		{"series", sqlMSSQLMemorySeries, base},
		{"clerks", sqlMSSQLClerkSeries, base},
		{"clerk_stats", sqlMSSQLClerkStats, []any{id, from, to}},
		{"checks", sqlMSSQLPerfChecks, []any{id, "memory"}},
	})
}

// MSSQLFileIO is GET /api/mssql/fileio?instance=N[&from=&to=][&part=...].
func (s *Server) MSSQLFileIO(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	base := []any{id, from, to, perfStep(to.Sub(from).Seconds())}
	s.multiPart(w, r, []part{
		{"latency", sqlMSSQLFileLatency, base},
		{"throughput", sqlMSSQLFileThroughput, base},
		{"files", sqlMSSQLIOFiles, []any{id, from, to}},
		{"checks", sqlMSSQLPerfChecks, []any{id, "^slow (log|data)"}},
	})
}

// MSSQLTempdb is GET /api/mssql/tempdb[?instance=N][&part=...]: the layout as last read; no window.
func (s *Server) MSSQLTempdb(w http.ResponseWriter, r *http.Request) {
	var id any
	if v := r.URL.Query().Get("instance"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
			return
		}
		id = n
	}
	s.multiPart(w, r, []part{
		{"layout", sqlMSSQLTempdb, []any{id}},
		{"files", sqlMSSQLTempdbFiles, []any{id}},
		{"checks", sqlMSSQLTempdbChecks, []any{id}},
	})
}
