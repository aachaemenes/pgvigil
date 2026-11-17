package web

import "net/http"

// The Elastic pool page of an Azure SQL Database in a pool (CLOUDSQL C4; DBA Dash's Azure Summary pool grid and its
// pool's Pool tab): the database's pool with DBA Dash's storage status, the pool's figures over the window, its
// databases pgvigil reads, and its minutes. Data from mssql_pool (0128): a minute a pool, from the first database
// read in it.

// the instance's pool and its storage status (mssql_pool_storage_status: DBA Dash's thresholds, a strict '>')
const sqlPoolStatus = `SELECT status, allocated_storage_percent, minute, server, pool, warning, critical
  FROM pgvigil.mssql_pool_storage_status($1)`

// the pool grid's one row over the window: the newest storage figures and the window's averages (each minute weighed by
// its samples, as the buckets and the Azure Summary's pools grid: review t11-2 SHOULD 3) and maxima
var sqlPoolSummary = `
WITH m AS (SELECT server, pool FROM pgvigil.mssql_pool_member WHERE instance_id = $1),
w AS (SELECT pm.* FROM m JOIN pgvigil.mssql_pool_minute pm ON pm.server = m.server AND pm.pool = m.pool
       WHERE pm.snapshot_at >= $2 AND pm.snapshot_at < $3),
n AS (SELECT * FROM w ORDER BY snapshot_at DESC LIMIT 1)
SELECT (SELECT server FROM m) AS server, (SELECT pool FROM m) AS pool, count(*) AS minutes,
       (SELECT allocated_storage_percent FROM n) AS allocated_storage_percent,
       (SELECT used_storage_percent FROM n) AS used_storage_percent,
       round((SELECT storage_limit_mb FROM n) / 1024.0, 2) AS storage_limit_gb,
       round((SELECT used_storage_mb FROM n) / 1024.0, 2) AS used_storage_gb,
       round((SELECT allocated_storage_mb FROM n) / 1024.0, 2) AS allocated_storage_gb,
       round(((SELECT storage_limit_mb FROM n) - (SELECT used_storage_mb FROM n)) / 1024.0, 2) AS free_storage_gb,
       (SELECT instance_vcores FROM n) AS instance_vcores,
       ` + avgW("avg_cpu_percent") + ` AS avg_cpu_percent, max(max_cpu_percent) AS max_cpu_percent,
       ` + avgW("avg_data_io_percent") + ` AS avg_data_io_percent, max(avg_data_io_percent) AS max_data_io_percent,
       ` + avgW("avg_log_write_percent") + ` AS avg_log_write_percent, max(avg_log_write_percent) AS max_log_write_percent,
       ` + avgW("avg_edtu_percent") + ` AS avg_edtu_percent, max(avg_edtu_percent) AS max_edtu_percent,
       max(max_worker_percent) AS max_worker_percent, max(max_session_percent) AS max_session_percent,
       min(snapshot_at) AS first_minute, max(snapshot_at) AS last_minute
  FROM w`

// the pool's databases pgvigil reads (each one's last read of the pool)
const sqlPoolMembers = `
SELECT i.instance_id, i.name, mb.seen_at
  FROM pgvigil.mssql_pool_member me
  JOIN pgvigil.mssql_pool_member mb ON mb.server = me.server AND mb.pool = me.pool
  JOIN pgvigil.instances i ON i.instance_id = mb.instance_id
 WHERE me.instance_id = $1
 ORDER BY i.name`

// the pool's minutes in the window, newest first (at most a day of them)
const sqlPoolMinutes = `
SELECT pm.snapshot_at AS minute, pm.samples, pm.avg_cpu_percent, pm.max_cpu_percent, pm.avg_data_io_percent, pm.avg_log_write_percent,
       pm.avg_edtu_percent, pm.max_worker_percent, pm.max_session_percent, pm.allocated_storage_percent, pm.used_storage_percent,
       i.name AS read_through
  FROM pgvigil.mssql_pool_member m
  JOIN pgvigil.mssql_pool_minute pm ON pm.server = m.server AND pm.pool = m.pool
  LEFT JOIN pgvigil.instances i ON i.instance_id = pm.instance_id
 WHERE m.instance_id = $1 AND pm.snapshot_at >= $2 AND pm.snapshot_at < $3
 ORDER BY pm.snapshot_at DESC
 LIMIT 1440`

// sqlPoolBuckets: the pool's minutes in the window grouped by UTC hour or day ($4: 'hour' | 'day'; P25 task 10, DBA Dash's
// Date Grouping), newest first: CPU, data IO, log write and eDTU averages weighed by the minutes' samples (0128's
// rule), the CPU, worker and session maxima the largest, the storage shares the bucket's last minute's.
const sqlPoolBuckets = `
SELECT date_trunc($4, pm.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS snapshot_at, count(*) AS minutes, sum(pm.samples)::bigint AS samples,
       round(sum(pm.avg_cpu_percent * pm.samples) / nullif(sum(pm.samples) FILTER (WHERE pm.avg_cpu_percent IS NOT NULL), 0), 2) AS avg_cpu_percent,
       max(pm.max_cpu_percent) AS max_cpu_percent,
       round(sum(pm.avg_data_io_percent * pm.samples) / nullif(sum(pm.samples) FILTER (WHERE pm.avg_data_io_percent IS NOT NULL), 0), 2) AS avg_data_io_percent,
       round(sum(pm.avg_log_write_percent * pm.samples) / nullif(sum(pm.samples) FILTER (WHERE pm.avg_log_write_percent IS NOT NULL), 0), 2) AS avg_log_write_percent,
       round(sum(pm.avg_edtu_percent * pm.samples) / nullif(sum(pm.samples) FILTER (WHERE pm.avg_edtu_percent IS NOT NULL), 0), 2) AS avg_edtu_percent,
       max(pm.max_worker_percent) AS max_worker_percent, max(pm.max_session_percent) AS max_session_percent,
       (array_agg(pm.allocated_storage_percent ORDER BY pm.snapshot_at DESC))[1] AS allocated_storage_percent,
       (array_agg(pm.used_storage_percent ORDER BY pm.snapshot_at DESC))[1] AS used_storage_percent
  FROM pgvigil.mssql_pool_member m
  JOIN pgvigil.mssql_pool_minute pm ON pm.server = m.server AND pm.pool = m.pool
 WHERE m.instance_id = $1 AND pm.snapshot_at >= $2 AND pm.snapshot_at < $3
 GROUP BY 1
 ORDER BY 1 DESC
 LIMIT 8784`

// MSSQLPool is GET /api/mssql/pool?instance=N&from=&to=.
func (s *Server) MSSQLPool(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"status", sqlPoolStatus, []any{id}},
		{"summary", sqlPoolSummary, []any{id, from, to}},
		{"members", sqlPoolMembers, []any{id}},
		{"minutes", sqlPoolMinutes, []any{id, from, to}},
		{"hours", sqlPoolBuckets, []any{id, from, to, "hour"}}, // P25 task 10: Date Grouping
		{"days", sqlPoolBuckets, []any{id, from, to, "day"}},
	})
}
