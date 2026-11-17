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
       sum(a.samples)::bigint AS samples, coalesce(sum(a.minutes), 0)::bigint AS minutes,
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
       a.avg_dtu_percent, a.max_dtu_percent, a.avg_dtu, a.max_dtu, a.dtu_limit, a.cpu_limit, a.replica_role,
       a.avg_xtp_storage_percent AS xtp_storage_percent, a.avg_instance_cpu_percent, a.max_instance_cpu_percent,
       a.avg_instance_memory_percent, a.max_instance_memory_percent  -- control audit A2: DBA Dash's DB chart's measures
  FROM pgvigil.mssql_azuredb_minute a
 WHERE a.instance_id = $1 AND a.snapshot_at >= $2 AND a.snapshot_at < $3
 ORDER BY a.snapshot_at DESC
 LIMIT 1440`

// the window's hours, newest first, through the same split as the summary (pgvigil.mssql_azuredb_window): a built hour
// whole, an edge or unbuilt hour from its minutes, its minutes counted (partial: fewer than 60 minutes in the window);
// the page lists them for a window over a day and draws its charts from them (snapshot_at: the chart's x) (B2a-N2)
const sqlAzureDBHours = `
SELECT date_trunc('hour', a.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS hour,
       date_trunc('hour', a.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS snapshot_at, sum(a.minutes)::int AS minutes, sum(a.samples)::bigint AS samples,
       round(sum(a.cpu_total) / nullif(sum(a.cpu_counted), 0), 2) AS avg_cpu_percent, max(a.max_cpu_percent) AS max_cpu_percent,
       round(sum(a.data_io_total) / nullif(sum(a.data_io_counted), 0), 2) AS avg_data_io_percent, max(a.max_data_io_percent) AS max_data_io_percent,
       round(sum(a.log_write_total) / nullif(sum(a.log_write_counted), 0), 2) AS avg_log_write_percent, max(a.max_log_write_percent) AS max_log_write_percent,
       round(sum(a.memory_usage_total) / nullif(sum(a.memory_usage_counted), 0), 2) AS avg_memory_usage_percent,
       round(sum(a.dtu_percent_total) / nullif(sum(a.dtu_percent_counted), 0), 2) AS avg_dtu_percent, max(a.max_dtu_percent) AS max_dtu_percent,
       max(a.max_worker_percent) AS max_worker_percent, max(a.max_session_percent) AS max_session_percent,
       round(sum(a.xtp_storage_total) / nullif(sum(a.xtp_storage_counted), 0), 2) AS xtp_storage_percent,
       round(sum(a.instance_cpu_total) / nullif(sum(a.instance_cpu_counted), 0), 2) AS avg_instance_cpu_percent, max(a.max_instance_cpu_percent) AS max_instance_cpu_percent,
       round(sum(a.instance_memory_total) / nullif(sum(a.instance_memory_counted), 0), 2) AS avg_instance_memory_percent, max(a.max_instance_memory_percent) AS max_instance_memory_percent,
       round(sum(a.dtu_total) / nullif(sum(a.dtu_counted), 0), 2) AS avg_dtu, max(a.max_dtu) AS max_dtu, max(a.max_dtu_limit) AS dtu_limit, max(a.max_cpu_limit) AS cpu_limit,
       sum(a.minutes) < 60 AS partial
  FROM pgvigil.mssql_azuredb_window(ARRAY[$1::int], $2, $3) a
 GROUP BY 1
 ORDER BY 1 DESC
 LIMIT 8784`

// sqlAzureDBDays: the window's UTC days, newest first, from the same split as the hours (P25 task 10: DBA Dash's Date
// Grouping 'day') - each average weighed by its samples, the maximum the largest, the minutes counted (partial: fewer
// than a day's 1440 in the window)
var sqlAzureDBDays = strings.NewReplacer("date_trunc('hour',", "date_trunc('day',", "AS hour,", "AS day,", "sum(a.minutes) < 60 AS partial", "sum(a.minutes) < 1440 AS partial",
	"LIMIT 8784", "LIMIT 366").Replace(sqlAzureDBHours)

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
	step, err := azureStep(r) // control audit A1: DBA Dash's other Date Grouping steps (q_azure_grouping.go)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"grouped", azureGroupedDB(step), []any{id, from, to, step}},
		{"tier", sqlAzureDBTier, []any{id}},
		{"summary", sqlAzureDBSummary, []any{id, from, to}},
		{"minutes", sqlAzureDBMinutes, []any{id, from, to}},
		{"hours", sqlAzureDBHours, []any{id, from, to}},
		{"days", sqlAzureDBDays, []any{id, from, to}}, // P25 task 10: Date Grouping
		{"gaps", sqlAzureDBGaps, []any{id, from, to}},
	})
}

// sqlAzureScope: sqlPerfScope's instances, each with its logical server and its elastic pool, cut to a list of
// instance ids ($5 int[]; NULL = no cut: P25 (i)'s node tabs' own cut; sqlPerfScope itself stays as it is, the
// Performance Summary's ids= being a variant of its own statements), one logical server ($6; NULL = every
// server) and one pool of it ($7; NULL = in a pool or not) - P25 task 7's server and pool nodes; a
// name is matched without case, as Azure names them. A database's server is its pool member row's (the pool read),
// else the instance's own server name (@@SERVERNAME, mssql_instance), else its governance row's server_name; its pool
// the member row's while it is current, else the governance row's - the member row stays behind when a database leaves
// its pool (0128), so it counts unless the governance row is newer and not ElasticPool (review t11-2 BLOCKER 1: a
// database moved to a single tier is in no pool). pool_read: the pool is the member row's - the database's own pool
// read stored it, so the Elastic pool page read through this database has the pool's minutes (review t11-3 SHOULD 2).
var sqlAzureScope = strings.Replace(sqlPerfScope, "WITH inst AS (", "WITH inst_scope AS (", 1) + `, inst AS (
  SELECT s.instance_id, s.instance, s.engine, s.platform, x.az_server, coalesce(x.pm_pool, g.pool) AS az_pool, x.pm_pool IS NOT NULL AS pool_read
    FROM inst_scope s
    LEFT JOIN pgvigil.mssql_pool_member pm ON pm.instance_id = s.instance_id
    LEFT JOIN pgvigil.mssql_instance mi ON mi.instance_id = s.instance_id
    LEFT JOIN pgvigil.mssql_azuredb_governance g ON g.instance_id = s.instance_id
    CROSS JOIN LATERAL (SELECT coalesce(pm.server, nullif(mi.server_name, ''), g.gov->>'server_name') AS az_server,
                               CASE WHEN NOT coalesce(g.snapshot_at > pm.seen_at AND g.service_objective IS DISTINCT FROM 'ElasticPool', false)
                                    THEN pm.pool END AS pm_pool) x
   WHERE ($5::int[] IS NULL OR s.instance_id = ANY ($5::int[]))
     AND ($6::text IS NULL OR upper(x.az_server) = upper($6::text))
     AND ($7::text IS NULL OR upper(coalesce(x.pm_pool, g.pool)) = upper($7::text))
)`

// the fleet's Azure SQL Databases over the window (DBA Dash's Azure Summary grid): the tier (its limits from the minutes
// when the tier is not read: mssql_azuredb_governance needs ##MS_ServerStateReader## on Basic, S0, S1 and in a pool),
// the window's figures, histograms and hot shares in one GROUP BY over the window's hours and edge minutes, the gaps, and
// the PRIMARY data files as mssql_storage last read them (DBA Dash's AzureDBInfo: allocated and used against the summed
// max size, none when a file is unlimited) with the % Max Size status of 0145's arm computed here from the same read:
// over 90 % critical, over 80 % warning (a strict 'over'), 'stale' when the files were read over 3 hours ago (the
// findings' window), 'no max size' with an unlimited file. DBA Dash's order: the most unused DTUs first. $1 from,
// $2 to, $3 'sqlserver', $4 the tag scope (sqlPerfScope's rule), $5 the ids, $6 / $7 the node (sqlAzureScope's).
var sqlAzureDBFleet = sqlAzureScope + `, w AS (
  SELECT a.instance_id, ` + azdbWindowCols + `
    FROM pgvigil.mssql_azuredb_window(ARRAY(SELECT instance_id FROM inst WHERE platform = 'azuresqldb'), $1, $2) a
   GROUP BY a.instance_id
)
SELECT inst.instance_id, inst.instance, inst.az_server AS server, g.edition, g.service_objective, inst.az_pool AS pool, inst.pool_read,
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
            ELSE 'ok' END AS pctmax_status, fs.files_read_at,
       rr.replica_role, coalesce(rr.replica_role, 0) > 0 AS read_only
  FROM inst
  LEFT JOIN pgvigil.mssql_azuredb_governance g ON g.instance_id = inst.instance_id
  -- the replica role of the database's newest stored minute (0145: 0 primary, 1 high-availability secondary, 2
  -- geo-replication forwarder, 3 named replica): a database read through a read-only connection reports its primary's
  -- server and database names (DBA Dash's '(read-only)' node, issue #2047; P25 finding L109)
  LEFT JOIN pgvigil.mssql_azuredb_read rd ON rd.instance_id = inst.instance_id
  LEFT JOIN LATERAL (SELECT m.replica_role FROM pgvigil.mssql_azuredb_minute m
                      WHERE m.instance_id = inst.instance_id AND m.snapshot_at = rd.newest_minute) rr ON true
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

// sqlAzureSLOHistory: DBA Dash's Azure Service Objectives history (P25 task 9): each tier CHANGE of the scope's Azure
// SQL Databases - a governance history period (0145) that follows another - its old and new edition, objective, pool
// and limits and when it changed, the newest first - every change, not cut by the window (DBA Dash's history lists
// them all; $1 <= $2 only types the window's parameters so the scope's $3 / $4 keep their places).
var sqlAzureSLOHistory = sqlAzureScope + `, h AS (
  SELECT g.instance_id, g.valid_from, g.edition, g.service_objective, g.pool, g.dtu_limit, g.cpu_limit,
         lag(g.edition) OVER w AS old_edition, lag(g.service_objective) OVER w AS old_service_objective,
         lag(g.pool) OVER w AS old_pool, lag(g.dtu_limit) OVER w AS old_dtu_limit, lag(g.cpu_limit) OVER w AS old_cpu_limit,
         lag(g.valid_from) OVER w AS prev_from
    FROM pgvigil.mssql_azuredb_governance_history g JOIN inst ON inst.instance_id = g.instance_id
  WINDOW w AS (PARTITION BY g.instance_id ORDER BY g.valid_from)
)
SELECT h.instance_id, inst.instance, h.valid_from AS changed_at, h.old_edition, h.edition AS new_edition,
       h.old_service_objective, h.service_objective AS new_service_objective, h.old_pool, h.pool AS new_pool,
       h.old_dtu_limit, h.dtu_limit AS new_dtu_limit, h.old_cpu_limit, h.cpu_limit AS new_cpu_limit
  FROM h JOIN inst USING (instance_id)
 WHERE h.prev_from IS NOT NULL AND $1::timestamptz <= $2::timestamptz
   -- a tier change: 0145 opens a period when any governance column changes; only these make a change (review t11-2 SHOULD 2)
   AND (h.old_edition, h.old_service_objective, h.old_pool, h.old_dtu_limit, h.old_cpu_limit)
       IS DISTINCT FROM (h.edition, h.service_objective, h.pool, h.dtu_limit, h.cpu_limit)
 ORDER BY h.valid_from DESC, inst.instance
 LIMIT 2000`

// sqlAzureGovernance: DBA Dash's Azure Resource Governance grid (P25 task 9): each Azure SQL Database of the scope
// with its tier and its governance row as last read (0145's gov: sys.dm_user_db_resource_governance whole), the
// viewer's source.
var sqlAzureGovernance = sqlAzureScope + `
SELECT g.instance_id, inst.instance, g.edition, g.service_objective, g.pool, g.dtu_limit, g.cpu_limit, g.since, g.snapshot_at,
       g.gov
  FROM pgvigil.mssql_azuredb_governance g JOIN inst ON inst.instance_id = g.instance_id
 WHERE $1::timestamptz <= $2::timestamptz
 ORDER BY inst.instance`

// avgW: one figure's average over the minutes, each weighed by its 15-second samples (0128's rule)
func avgW(col string) string {
	return "round(sum(w." + col + " * w.samples) / nullif(sum(w.samples) FILTER (WHERE w." + col + " IS NOT NULL), 0), 2)"
}

// sqlAzurePools: the Azure Summary's Elastic Pool grid (P25 task 8, DBA Dash's): each elastic pool one of the scope's
// Azure SQL Databases belongs to (mssql_pool_member), once - how many of its databases pgvigil reads in the scope,
// and over the window its minutes' figures (0128: an average weighs each minute by its samples, a maximum is the
// largest) and its storage as last read. $1 / $2 the window, $3 / $4 sqlPerfScope's engine and tag, $5 the ids, $6 / $7 the node.
var sqlAzurePools = sqlAzureScope + `, mp AS (
  SELECT upper(inst.az_server) AS u_server, upper(inst.az_pool) AS u_pool, min(inst.az_server) AS server, min(inst.az_pool) AS pool,
         count(*) AS databases
    FROM inst
   WHERE inst.az_server IS NOT NULL AND inst.az_pool IS NOT NULL
   GROUP BY 1, 2
), w AS (
  SELECT pm.*, mp.u_server, mp.u_pool FROM pgvigil.mssql_pool_minute pm JOIN mp ON upper(pm.server) = mp.u_server AND upper(pm.pool) = mp.u_pool
   WHERE pm.snapshot_at >= $1 AND pm.snapshot_at < $2
)
SELECT mp.server, mp.pool, mp.databases, count(w.snapshot_at) AS minutes,
       ` + avgW("avg_cpu_percent") + ` AS avg_cpu_percent, max(w.max_cpu_percent) AS max_cpu_percent,
       ` + avgW("avg_data_io_percent") + ` AS avg_data_io_percent, max(w.avg_data_io_percent) AS max_data_io_percent,
       ` + avgW("avg_log_write_percent") + ` AS avg_log_write_percent, max(w.avg_log_write_percent) AS max_log_write_percent,
       ` + avgW("avg_edtu_percent") + ` AS avg_edtu_percent, max(w.avg_edtu_percent) AS max_edtu_percent,
       max(w.max_worker_percent) AS max_worker_percent, max(w.max_session_percent) AS max_session_percent,
       (array_agg(w.used_storage_percent ORDER BY w.snapshot_at DESC) FILTER (WHERE w.snapshot_at IS NOT NULL))[1] AS used_storage_percent,
       (array_agg(w.allocated_storage_percent ORDER BY w.snapshot_at DESC) FILTER (WHERE w.snapshot_at IS NOT NULL))[1] AS allocated_storage_percent,
       max(w.snapshot_at) AS last_minute
  FROM mp LEFT JOIN w ON w.u_server = mp.u_server AND w.u_pool = mp.u_pool
 GROUP BY mp.u_server, mp.u_pool, mp.server, mp.pool, mp.databases
 ORDER BY max(w.avg_edtu_percent) DESC NULLS LAST, max(w.max_cpu_percent) DESC NULLS LAST, mp.server, mp.pool`

// sqlAzurePoolHistory: DBA Dash's Pool history (P25 task 9b): each change of an elastic pool's DTU or storage limit -
// a period of 0395's that follows another of the same pool with another limit - once, however many of the pool's
// databases keep a copy (DISTINCT: the copies differ only in their first period's start, which no change has), with
// the old and new limits and when it changed, the newest first. A database's copy counts for the pool it is in now
// (the scope's az_server / az_pool); a change of the CPU limit alone is not one (Microsoft: elastic_pool_cpu_limit
// 'informational purposes only. Not supported.' - never shown). $1 <= $2 only types the window's parameters (the
// history is not cut by the window, as the Service Objectives changes are not).
// A copy whose reads had a gap (a database not read for over master's 14 days) holds a change at the first period it
// read after the gap: its period before ends earlier, so the change is known only between the two - changed_after,
// left out where another copy holds the same change inside the gap (review t11-1 SHOULD 3). A database's copy counts
// only while it is in that pool (the scope's az_pool: review t11-1 NIT 5, t11-2 BLOCKER 1).
var sqlAzurePoolHistory = sqlAzureScope + `, p AS (
  SELECT h.server, h.pool, h.valid_from, h.dtu_limit, h.storage_limit_mb, lag(h.valid_from) OVER w AS prev_from,
         lag(h.valid_to) OVER w AS prev_to, lag(h.dtu_limit) OVER w AS old_dtu, lag(h.storage_limit_mb) OVER w AS old_storage
    FROM pgvigil.mssql_pool_limit_history h
    JOIN inst ON inst.instance_id = h.instance_id AND upper(h.server) = upper(inst.az_server) AND upper(h.pool) = upper(inst.az_pool)
  WINDOW w AS (PARTITION BY h.instance_id, h.server, h.pool ORDER BY h.valid_from)
), c AS (
  SELECT DISTINCT p.server, p.pool, p.valid_from AS changed_at, CASE WHEN p.prev_to < p.valid_from THEN p.prev_to END AS changed_after,
         p.old_dtu AS old_dtu_limit, p.dtu_limit AS new_dtu_limit, p.old_storage AS old_storage_limit_mb, p.storage_limit_mb AS new_storage_limit_mb
    FROM p
   WHERE p.prev_from IS NOT NULL AND (p.old_dtu IS DISTINCT FROM p.dtu_limit OR p.old_storage IS DISTINCT FROM p.storage_limit_mb)
)
SELECT c.server, c.pool, c.changed_at, c.changed_after, c.old_dtu_limit, c.new_dtu_limit, c.old_storage_limit_mb, c.new_storage_limit_mb
  FROM c
 WHERE (c.changed_after IS NULL OR NOT EXISTS (
          SELECT 1 FROM c k
           WHERE k.changed_after IS NULL AND upper(k.server) = upper(c.server) AND upper(k.pool) = upper(c.pool)
             AND (k.old_dtu_limit, k.new_dtu_limit, k.old_storage_limit_mb, k.new_storage_limit_mb)
                 IS NOT DISTINCT FROM (c.old_dtu_limit, c.new_dtu_limit, c.old_storage_limit_mb, c.new_storage_limit_mb)
             AND k.changed_at > c.changed_after AND k.changed_at <= c.changed_at))
   AND $1::timestamptz <= $2::timestamptz
 ORDER BY c.changed_at DESC, c.server, c.pool
 LIMIT 2000`

// sqlAzurePoolHistoryState: per elastic pool of the scope's databases, when one of them last read master's view
// (0395's mssql_pool_limit_read) - counted only from a database whose mssql_pool_limits run still reads (its last run
// ok or partial, or none logged yet), so a pool whose readers were skipped since (no dbmanager, no way into master) or
// failed has no current read (review t11-1 SHOULD 1) - its last read before that (read_until) and, where a run was
// skipped, the newest skip's words: the page's words for such a pool.
var sqlAzurePoolHistoryState = sqlAzureScope + `
SELECT inst.az_server AS server, inst.az_pool AS pool,
       max(rd.read_at) FILTER (WHERE rd.state = 'read' AND (cd.status IS NULL OR cd.status IN ('ok', 'partial'))) AS last_read,
       max(rd.read_at) FILTER (WHERE rd.state = 'read') AS read_until,
       (array_agg(cd.note ORDER BY cd.snapshot_at DESC) FILTER (WHERE cd.status = 'skipped'))[1] AS skip_note,
       max(cd.snapshot_at) FILTER (WHERE cd.status = 'skipped') AS skipped_at
  FROM inst
  LEFT JOIN pgvigil.mssql_pool_limit_read rd ON rd.instance_id = inst.instance_id
  LEFT JOIN pgvigil.collection_dates cd ON cd.instance_id = inst.instance_id AND cd.collection = 'mssql_pool_limits'
 WHERE inst.platform = 'azuresqldb' AND inst.az_server IS NOT NULL AND inst.az_pool IS NOT NULL AND $1::timestamptz <= $2::timestamptz
 GROUP BY inst.az_server, inst.az_pool
 ORDER BY inst.az_server, inst.az_pool`

// AzureDBSummary is GET /api/azuredb/summary?[from=&to=][&tag=][&server=[&pool=]]: the fleet's Azure SQL Databases
// (DBA Dash's Azure Summary), or one logical server's (server=) or one of its elastic pools' (pool=, with its server:
// a pool's name is its server's) - DBA Dash's server and pool nodes (P25 task 7).
func (s *Server) AzureDBSummary(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var tag, server, pool any
	q := r.URL.Query()
	if v := q.Get("tag"); v != "" {
		tag = v
	}
	if v := q.Get("server"); v != "" {
		server = v
	}
	if v := q.Get("pool"); v != "" {
		if server == nil {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("pool= needs server=: an elastic pool's name is its logical server's"))
			return
		}
		pool = v
	}
	// the ids cut (sqlAzureScope's $5): ids= (a node's own databases; review t11-7 item 6: bound, no longer always nil)
	ids, err := idsParam(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var idsArg any
	if ids != nil {
		idsArg = ids
	}
	args := []any{from, to, "sqlserver", tag, idsArg, server, pool}
	s.multiPart(w, r, []part{{"databases", sqlAzureDBFleet, args},
		{"pools", sqlAzurePools, args},            // P25 task 8: the Elastic Pool grid
		{"slo_history", sqlAzureSLOHistory, args}, // P25 task 9
		{"governance", sqlAzureGovernance, args},
		{"pool_history", sqlAzurePoolHistory, args}, // P25 task 9b
		{"pool_history_state", sqlAzurePoolHistoryState, args}})
}
