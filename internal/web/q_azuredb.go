package web

import (
	"fmt"
	"net/http"
	"strings"
)

// Azure SQL Database's resource use and tier (B2a; DBA Dash's Azure Summary, AzureSummary.cs with
// AzureDBPerformanceSummary_Get, and its instance's Azure DB tab, AzureDBResourceStats.cs). Data from
// mssql_azuredb_minute (mssql_azuredb_resources: a minute a database, from sys.dm_db_resource_stats), mssql_azuredb_gap
// (the minutes the view no longer held), mssql_azuredb_governance (the tier, hourly) and mssql_files (mssql_storage:
// the database's own files on Azure SQL Database).
//
// Every average over the window weighs each minute by its 15-second samples, so it equals DBA Dash's AVG over the
// view's rows; a maximum is the largest per-sample figure; the histograms sum the minutes' bucket counts (< 10, [10,
// 20) ... [80, 90), >= 90: AzureDBResourceStats_Raw).
//
// The window is DBA Dash's: the minutes that start at or after its start and before its end (end_time >= @FromDate AND
// end_time < @ToDate). A window reads its built whole hours from mssql_azuredb_hour and only its two edge parts (and
// any hour not built yet) from the minutes (pgvigil.mssql_azuredb_window, 0167): the same numbers as the minutes at any
// length - a departure from DBA Dash, which rounds a window over a day to its hours (Use60MIN).

// azdbWindowCols: the window's figures of one database (alias a = pgvigil.mssql_azuredb_window's rows: built hours and
// minutes in the hour shape, 0167, task B2a-N2), DBA Dash's columns, in one pass: an average is the sum of the totals
// over the sum of the counted samples (exactly the minutes' weighted average), the four histograms sum each bucket,
// and the 'hot' shares are the samples at 70 % and over of those counted (as the Performance summary's)
var azdbWindowCols = `
       sum(a.samples)::bigint AS samples, sum(a.minutes)::bigint AS minutes,
       round(sum(a.cpu_total) / nullif(sum(a.cpu_counted), 0), 2) AS avg_cpu_percent,
       max(a.max_cpu_percent) AS max_cpu_percent,
       round(sum(a.data_io_total) / nullif(sum(a.data_io_counted), 0), 2) AS avg_data_io_percent,
       max(a.max_data_io_percent) AS max_data_io_percent,
       round(sum(a.log_write_total) / nullif(sum(a.log_write_counted), 0), 2) AS avg_log_write_percent,
       max(a.max_log_write_percent) AS max_log_write_percent,
       round(sum(a.dtu_percent_total) / nullif(sum(a.dtu_percent_counted), 0), 2) AS avg_dtu_percent,
       max(a.max_dtu_percent) AS max_dtu_percent,
       round(sum(a.dtu_total) / nullif(sum(a.dtu_counted), 0), 2) AS avg_dtu,
       max(a.max_dtu) AS max_dtu, min(a.min_dtu_limit) AS min_dtu_limit, max(a.max_dtu_limit) AS max_dtu_limit,
       max(a.max_dtu_limit) - max(a.max_dtu) AS unused_dtu,
       min(a.min_cpu_limit) AS min_cpu_limit, max(a.max_cpu_limit) AS max_cpu_limit,
       ` + azdbHist("cpu") + ` AS cpu_hist, ` + azdbHist("data") + ` AS data_hist, ` + azdbHist("log") + ` AS log_hist, ` + azdbHist("dtu") + ` AS dtu_hist,
       ` + azdbHot("cpu") + ` AS cpu_hot_pct, ` + azdbHot("data") + ` AS data_hot_pct, ` + azdbHot("log") + ` AS log_hot_pct, ` + azdbHot("dtu") + ` AS dtu_hot_pct`

// azdbHist: one histogram's ten sums over the minutes (alias a)
func azdbHist(name string) string {
	parts := make([]string, 10)
	for k := range parts {
		parts[k] = fmt.Sprintf("coalesce(sum(a.%s_buckets[%d]), 0)", name, k+1)
	}
	return "ARRAY[" + strings.Join(parts, ", ") + "]::int[]"
}

// azdbHot: the share of one histogram's samples in its last three buckets (70 % and over), NULL with none counted
func azdbHot(name string) string {
	all := make([]string, 10)
	for k := range all {
		all[k] = fmt.Sprintf("sum(a.%s_buckets[%d])", name, k+1)
	}
	return fmt.Sprintf("round(100.0 * (sum(a.%[1]s_buckets[8]) + sum(a.%[1]s_buckets[9]) + sum(a.%[1]s_buckets[10])) / nullif(%[2]s, 0), 1)", name, strings.Join(all, " + "))
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
SELECT ` + azdbWindowCols + `
  FROM pgvigil.mssql_azuredb_window(ARRAY[$1::int], $2, $3) a`

// the window's minutes, newest first (at most a day of them)
const sqlAzureDBMinutes = `
SELECT a.snapshot_at AS minute, a.snapshot_at, a.samples, a.avg_cpu_percent, a.max_cpu_percent, a.avg_data_io_percent, a.max_data_io_percent,
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

// the fleet's Azure SQL Databases over the window (DBA Dash's Azure Summary grid): the tier (its limits from the minutes
// when the tier is not read: mssql_azuredb_governance needs ##MS_ServerStateReader## on Basic, S0, S1 and in a pool),
// the window's figures, histograms and hot shares in one GROUP BY over the window's hours and edge minutes, the gaps, and
// the PRIMARY data files as mssql_storage last read them (DBA Dash's AzureDBInfo: allocated and used against the summed
// max size, none when a file is unlimited) with the % Max Size status of 0145's arm computed here from the same read:
// over 90 % critical, over 80 % warning (a strict 'over'), 'stale' when the files were read over 3 hours ago (the
// findings' window), 'no max size' with an unlimited file. DBA Dash's order: the most unused DTUs first. $1 from,
// $2 to, $3 'sqlserver', $4 the tag scope (sqlPerfScope's rule).
var sqlAzureDBFleet = sqlPerfScope + `, w AS (
  SELECT a.instance_id, ` + azdbWindowCols + `
    FROM pgvigil.mssql_azuredb_window(ARRAY(SELECT instance_id FROM inst WHERE platform = 'azuresqldb'), $1, $2) a
   GROUP BY a.instance_id
)
SELECT inst.instance_id, inst.instance, g.edition, g.service_objective, g.pool,
       coalesce(g.dtu_limit, w.max_dtu_limit) AS dtu_limit, coalesce(g.cpu_limit, w.max_cpu_limit) AS cpu_limit, g.instance_id IS NOT NULL AS tier_read,
       w.samples, w.minutes, w.avg_cpu_percent, w.max_cpu_percent, w.avg_data_io_percent, w.max_data_io_percent, w.avg_log_write_percent,
       w.max_log_write_percent, w.avg_dtu_percent, w.max_dtu_percent, w.avg_dtu, w.max_dtu, w.unused_dtu,
       w.cpu_hist, w.data_hist, w.log_hist, w.dtu_hist, w.cpu_hot_pct, w.data_hot_pct, w.log_hot_pct, w.dtu_hot_pct,
       gp.gaps, gp.gap_minutes, round(fs.allocated_mb) AS allocated_mb, round(fs.used_mb) AS used_mb, round(fs.max_size_mb) AS max_size_mb,
       round(100.0 * fs.allocated_mb / nullif(fs.max_size_mb, 0), 1) AS allocated_pct, round(100.0 * fs.used_mb / nullif(fs.max_size_mb, 0), 1) AS used_pct,
       CASE WHEN fs.files_read_at IS NULL THEN NULL
            WHEN fs.files_read_at < now() - interval '3 hours' THEN 'stale'
            WHEN fs.max_size_mb IS NULL THEN 'no max size'
            WHEN fs.allocated_mb > 0.9 * fs.max_size_mb THEN 'critical'
            WHEN fs.allocated_mb > 0.8 * fs.max_size_mb THEN 'warning'
            ELSE 'ok' END AS pctmax_status, fs.files_read_at
  FROM inst
  LEFT JOIN pgvigil.mssql_azuredb_governance g ON g.instance_id = inst.instance_id
  LEFT JOIN w ON w.instance_id = inst.instance_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS gaps, coalesce(round(sum(extract(epoch FROM least(x.gap_to, $2) - greatest(x.gap_from, $1)) / 60)), 0) AS gap_minutes
      FROM pgvigil.mssql_azuredb_gap x WHERE x.instance_id = inst.instance_id AND x.gap_to > $1 AND x.gap_from < $2) gp ON true
  LEFT JOIN LATERAL (
    SELECT sum(f.size_bytes) / 1048576.0 AS allocated_mb,
           CASE WHEN bool_and(f.used_read) THEN sum(f.used_bytes) / 1048576.0 END AS used_mb,
           CASE WHEN bool_and(f.max_size_bytes IS NOT NULL) THEN sum(f.max_size_bytes) / 1048576.0 END AS max_size_mb,
           max(f.snapshot_at) AS files_read_at
      FROM pgvigil.mssql_files f
     WHERE f.instance_id = inst.instance_id AND f.is_present AND f.type_desc = 'ROWS' AND f.filegroup = 'PRIMARY') fs ON true
 WHERE inst.platform = 'azuresqldb'
 ORDER BY w.unused_dtu DESC NULLS LAST, inst.instance`

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
