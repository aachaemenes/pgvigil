package web

import "net/http"

// Azure SQL Database's resource use and tier (B2a; DBA Dash's Azure Summary, AzureSummary.cs with
// AzureDBPerformanceSummary_Get, and its instance's Azure DB tab, AzureDBResourceStats.cs). Data from
// mssql_azuredb_minute (mssql_azuredb_resources: a minute a database, from sys.dm_db_resource_stats), mssql_azuredb_gap
// (the minutes the view no longer held), mssql_azuredb_governance (the tier, hourly) and mssql_files (mssql_storage:
// the database's own files on Azure SQL Database).
//
// Every average over the window weighs each minute by its 15-second samples, so it equals DBA Dash's AVG over the
// view's rows; a maximum is the largest per-sample figure; the histograms sum the minutes' bucket counts (< 10, [10,
// 20) ... [80, 90), >= 90: AzureDBResourceStats_Raw).

// azdbWindowCols: the window's figures of one database (alias a = mssql_azuredb_minute), DBA Dash's columns
const azdbWindowCols = `
       sum(a.samples)::bigint AS samples, count(*) AS minutes,
       round(sum(a.avg_cpu_percent * a.samples) / nullif(sum(a.samples) FILTER (WHERE a.avg_cpu_percent IS NOT NULL), 0), 2) AS avg_cpu_percent,
       max(a.max_cpu_percent) AS max_cpu_percent,
       round(sum(a.avg_data_io_percent * a.samples) / nullif(sum(a.samples) FILTER (WHERE a.avg_data_io_percent IS NOT NULL), 0), 2) AS avg_data_io_percent,
       max(a.max_data_io_percent) AS max_data_io_percent,
       round(sum(a.avg_log_write_percent * a.samples) / nullif(sum(a.samples) FILTER (WHERE a.avg_log_write_percent IS NOT NULL), 0), 2) AS avg_log_write_percent,
       max(a.max_log_write_percent) AS max_log_write_percent,
       round(sum(a.avg_dtu_percent * a.samples) / nullif(sum(a.samples) FILTER (WHERE a.avg_dtu_percent IS NOT NULL), 0), 2) AS avg_dtu_percent,
       max(a.max_dtu_percent) AS max_dtu_percent,
       round(sum(a.avg_dtu * a.samples) / nullif(sum(a.samples) FILTER (WHERE a.avg_dtu IS NOT NULL), 0), 2) AS avg_dtu,
       max(a.max_dtu) AS max_dtu, min(a.dtu_limit) AS min_dtu_limit, max(a.dtu_limit) AS max_dtu_limit,
       max(a.dtu_limit) - max(a.max_dtu) AS unused_dtu,
       min(a.cpu_limit) AS min_cpu_limit, max(a.cpu_limit) AS max_cpu_limit`

// azdbHist sums one bucket column over the window's minutes of the database $id (10 counts)
func azdbHist(col, id string) string {
	return `ARRAY(SELECT coalesce(sum(h.` + col + `[k]), 0)::int FROM generate_series(1, 10) k LEFT JOIN pgvigil.mssql_azuredb_minute h
                 ON h.instance_id = ` + id + ` AND h.snapshot_at >= $2 AND h.snapshot_at < $3 GROUP BY k ORDER BY k)`
}

// the database's tier as last read (mssql_azuredb_governance) and its reads' times
const sqlAzureDBTier = `
SELECT g.snapshot_at AS tier_read_at, g.since AS tier_since, g.edition, g.service_objective, g.slo_name, g.pool, g.pool_note,
       g.dtu_limit, g.cpu_limit, round(g.max_size_bytes / 1048576.0) AS max_size_mb, g.usage_mb,
       g.gov ->> 'max_sessions' AS max_sessions, g.gov ->> 'primary_group_max_workers' AS max_workers,
       round((g.gov ->> 'primary_max_log_rate')::numeric / 1048576, 2) AS max_log_rate_mb_s,
       r.newest_minute, r.read_at AS resources_read_at
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.mssql_azuredb_governance g ON g.instance_id = i.instance_id
  LEFT JOIN pgvigil.mssql_azuredb_read r ON r.instance_id = i.instance_id
 WHERE i.instance_id = $1`

// the window's one row of the database (DBA Dash's Azure Summary row) with its four histograms; $1 id, $2 from, $3 to
var sqlAzureDBSummary = `
SELECT ` + azdbWindowCols + `,
       ` + azdbHist("cpu_buckets", "$1") + ` AS cpu_hist, ` + azdbHist("data_buckets", "$1") + ` AS data_hist,
       ` + azdbHist("log_buckets", "$1") + ` AS log_hist, ` + azdbHist("dtu_buckets", "$1") + ` AS dtu_hist
  FROM pgvigil.mssql_azuredb_minute a
 WHERE a.instance_id = $1 AND a.snapshot_at >= $2 AND a.snapshot_at < $3`

// the window's minutes, newest first (at most a day of them)
const sqlAzureDBMinutes = `
SELECT a.snapshot_at AS minute, a.samples, a.avg_cpu_percent, a.max_cpu_percent, a.avg_data_io_percent, a.max_data_io_percent,
       a.avg_log_write_percent, a.max_log_write_percent, a.avg_memory_usage_percent, a.max_worker_percent, a.max_session_percent,
       a.avg_dtu_percent, a.max_dtu_percent, a.avg_dtu, a.max_dtu, a.dtu_limit, a.cpu_limit, a.replica_role
  FROM pgvigil.mssql_azuredb_minute a
 WHERE a.instance_id = $1 AND a.snapshot_at >= $2 AND a.snapshot_at < $3
 ORDER BY a.snapshot_at DESC
 LIMIT 1440`

// the gaps that touch the window: minutes the store does not have because the view no longer held them
const sqlAzureDBGaps = `
SELECT g.gap_from, g.gap_to, round(extract(epoch FROM g.gap_to - g.gap_from) / 60) AS minutes, g.oldest_end, g.noted_at
  FROM pgvigil.mssql_azuredb_gap g
 WHERE g.instance_id = $1 AND g.gap_to > $2 AND g.gap_from < $3
 ORDER BY g.gap_from DESC`

// MSSQLAzureDB is GET /api/mssql/azuredb?instance=N&from=&to=[&part=]: one Azure SQL Database's tier, its window's
// row, its minutes and its gaps.
func (s *Server) MSSQLAzureDB(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"tier", sqlAzureDBTier, []any{id}},
		{"summary", sqlAzureDBSummary, []any{id, from, to}},
		{"minutes", sqlAzureDBMinutes, []any{id, from, to}},
		{"gaps", sqlAzureDBGaps, []any{id, from, to}},
	})
}

// the fleet's Azure SQL Databases over the window (DBA Dash's Azure Summary grid): the tier, the window's figures and
// histograms, the gaps in the window, and the storage of the PRIMARY data files as mssql_storage last read them (DBA
// Dash's AzureDBInfo: allocated and used against the summed max size, NULL when a file is unlimited) with the '% Max
// Size' status from the storage findings. $1 from, $2 to, $3 'sqlserver', $4 the tag scope (sqlPerfScope's rule).
var sqlAzureDBFleet = sqlPerfScope + `
SELECT inst.instance_id, inst.instance, g.edition, g.service_objective, g.pool, g.dtu_limit, g.cpu_limit,
       w.*, gp.gaps, gp.gap_minutes, fs.allocated_mb, fs.used_mb, fs.max_size_mb,
       round(100.0 * fs.allocated_mb / nullif(fs.max_size_mb, 0), 1) AS allocated_pct, round(100.0 * fs.used_mb / nullif(fs.max_size_mb, 0), 1) AS used_pct,
       coalesce(mf.severity, CASE WHEN fs.max_size_mb IS NULL THEN NULL ELSE 'ok' END) AS pctmax_status, fs.files_read_at,
       h.cpu_hist, h.dtu_hist
  FROM inst
  LEFT JOIN pgvigil.mssql_azuredb_governance g ON g.instance_id = inst.instance_id
  LEFT JOIN LATERAL (SELECT ` + azdbWindowCols + `
      FROM pgvigil.mssql_azuredb_minute a WHERE a.instance_id = inst.instance_id AND a.snapshot_at >= $1 AND a.snapshot_at < $2) w ON true
  LEFT JOIN LATERAL (
    SELECT ARRAY(SELECT coalesce(sum(x.cpu_buckets[k]), 0)::int FROM generate_series(1, 10) k LEFT JOIN pgvigil.mssql_azuredb_minute x
                  ON x.instance_id = inst.instance_id AND x.snapshot_at >= $1 AND x.snapshot_at < $2 GROUP BY k ORDER BY k) AS cpu_hist,
           ARRAY(SELECT coalesce(sum(x.dtu_buckets[k]), 0)::int FROM generate_series(1, 10) k LEFT JOIN pgvigil.mssql_azuredb_minute x
                  ON x.instance_id = inst.instance_id AND x.snapshot_at >= $1 AND x.snapshot_at < $2 GROUP BY k ORDER BY k) AS dtu_hist) h ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS gaps, coalesce(round(sum(extract(epoch FROM least(x.gap_to, $2) - greatest(x.gap_from, $1)) / 60)), 0) AS gap_minutes
      FROM pgvigil.mssql_azuredb_gap x WHERE x.instance_id = inst.instance_id AND x.gap_to > $1 AND x.gap_from < $2) gp ON true
  LEFT JOIN LATERAL (
    SELECT round(sum(f.size_bytes) / 1048576.0) AS allocated_mb,
           CASE WHEN bool_and(f.used_read) THEN round(sum(f.used_bytes) / 1048576.0) END AS used_mb,
           CASE WHEN bool_and(f.max_size_bytes IS NOT NULL) THEN round(sum(f.max_size_bytes) / 1048576.0) END AS max_size_mb,
           max(f.snapshot_at) AS files_read_at
      FROM pgvigil.mssql_files f
     WHERE f.instance_id = inst.instance_id AND f.is_present AND f.type_desc = 'ROWS' AND f.filegroup = 'PRIMARY') fs ON true
  LEFT JOIN LATERAL (
    SELECT sf.severity FROM pgvigil.mssql_storage_findings sf
     WHERE sf.instance_id = inst.instance_id AND sf.check_name = 'the database allocated over 80 % of its max size' LIMIT 1) mf ON true
 WHERE inst.platform = 'azuresqldb'
 ORDER BY inst.instance`

// AzureDBSummary is GET /api/azuredb/summary?[from=&to=][&tag=]: the fleet's Azure SQL Databases (DBA Dash's Azure
// Summary).
func (s *Server) AzureDBSummary(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var tag any
	if v := r.URL.Query().Get("tag"); v != "" {
		tag = v
	}
	s.multiPart(w, r, []part{{"databases", sqlAzureDBFleet, []any{from, to, "sqlserver", tag}}})
}
