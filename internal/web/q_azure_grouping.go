package web

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
)

// DBA Dash's Date Grouping past minute / hour / day on the Azure DB and Pool charts (control audit row A1;
// DBADashGUI/DateHelper.cs DateGroups): part=grouped&step=<minutes> on /api/mssql/azuredb and /api/mssql/pool. A bucket
// starts a whole number of steps after 1900-01-01 (DBA Dash's dbo.DateGroupingMins; UTC here, as pgvigil's hours and
// days are - DBA Dash shifts to the display zone first); a step under 60 minutes reads the minutes, 60 and over the hour
// split (AzureDBElasticPoolResourceStats_Get's @Use60MIN). Each average is weighed by its samples, each maximum the
// largest, the minutes counted (partial: fewer than the step holds). No step = no rows; another step = 400.

// azureSteps: DBA Dash's groupings that the minute / hour / day parts do not already serve
var azureSteps = map[int]bool{2: true, 5: true, 10: true, 15: true, 30: true, 120: true, 240: true, 360: true, 720: true, 2880: true, 10080: true, 20160: true}

// azureStep reads step= (0 when absent)
func azureStep(r *http.Request) (int, error) {
	v := r.URL.Query().Get("step")
	if v == "" {
		return 0, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || !azureSteps[n] {
		return 0, errors.New("step must be one of 2, 5, 10, 15, 30, 120, 240, 360, 720, 2880, 10080, 20160 (minutes)")
	}
	return n, nil
}

// azureBucket: the start of the $4-minute bucket a time falls in, counted from 1900-01-01 UTC
func azureBucket(col string) string {
	return `timestamptz '1900-01-01 00:00:00+00' + floor(extract(epoch FROM ` + col + ` - timestamptz '1900-01-01 00:00:00+00') / ($4::int * 60)) * ($4::int * 60) * interval '1 second'`
}

// the database's buckets over its rows in the hour table's shape (s): the totals and the samples counted
var sqlAzureDBGroupedSelect = `
SELECT ` + azureBucket("s.snapshot_at") + ` AS snapshot_at,
       sum(s.minutes)::int AS minutes, sum(s.samples)::bigint AS samples,
       round(sum(s.cpu_total) / nullif(sum(s.cpu_counted), 0), 2) AS avg_cpu_percent, max(s.max_cpu_percent) AS max_cpu_percent,
       round(sum(s.data_io_total) / nullif(sum(s.data_io_counted), 0), 2) AS avg_data_io_percent, max(s.max_data_io_percent) AS max_data_io_percent,
       round(sum(s.log_write_total) / nullif(sum(s.log_write_counted), 0), 2) AS avg_log_write_percent, max(s.max_log_write_percent) AS max_log_write_percent,
       round(sum(s.memory_usage_total) / nullif(sum(s.memory_usage_counted), 0), 2) AS avg_memory_usage_percent,
       round(sum(s.dtu_percent_total) / nullif(sum(s.dtu_percent_counted), 0), 2) AS avg_dtu_percent, max(s.max_dtu_percent) AS max_dtu_percent,
       max(s.max_worker_percent) AS max_worker_percent, max(s.max_session_percent) AS max_session_percent,
       round(sum(s.xtp_storage_total) / nullif(sum(s.xtp_storage_counted), 0), 2) AS xtp_storage_percent,
       round(sum(s.instance_cpu_total) / nullif(sum(s.instance_cpu_counted), 0), 2) AS avg_instance_cpu_percent, max(s.max_instance_cpu_percent) AS max_instance_cpu_percent,
       round(sum(s.instance_memory_total) / nullif(sum(s.instance_memory_counted), 0), 2) AS avg_instance_memory_percent, max(s.max_instance_memory_percent) AS max_instance_memory_percent,
       round(sum(s.dtu_total) / nullif(sum(s.dtu_counted), 0), 2) AS avg_dtu, max(s.max_dtu) AS max_dtu, max(s.max_dtu_limit) AS dtu_limit, max(s.max_cpu_limit) AS cpu_limit,
       sum(s.minutes) < $4::int AS partial
  FROM s
 GROUP BY 1
 ORDER BY 1 DESC
 LIMIT 1440`

// sqlAzureDBGroupedMinutes: a step under an hour, from the minutes (an hour already built holds no minute detail)
var sqlAzureDBGroupedMinutes = `
WITH s AS (
  SELECT a.snapshot_at, 1 AS minutes, a.samples,
         a.avg_cpu_percent * a.samples AS cpu_total, CASE WHEN a.avg_cpu_percent IS NOT NULL THEN a.samples END AS cpu_counted, a.max_cpu_percent,
         a.avg_data_io_percent * a.samples AS data_io_total, CASE WHEN a.avg_data_io_percent IS NOT NULL THEN a.samples END AS data_io_counted, a.max_data_io_percent,
         a.avg_log_write_percent * a.samples AS log_write_total, CASE WHEN a.avg_log_write_percent IS NOT NULL THEN a.samples END AS log_write_counted, a.max_log_write_percent,
         a.avg_memory_usage_percent * a.samples AS memory_usage_total, CASE WHEN a.avg_memory_usage_percent IS NOT NULL THEN a.samples END AS memory_usage_counted,
         a.avg_dtu_percent * a.samples AS dtu_percent_total, CASE WHEN a.avg_dtu_percent IS NOT NULL THEN a.samples END AS dtu_percent_counted, a.max_dtu_percent,
         a.max_worker_percent, a.max_session_percent,
         a.avg_xtp_storage_percent * a.samples AS xtp_storage_total, CASE WHEN a.avg_xtp_storage_percent IS NOT NULL THEN a.samples END AS xtp_storage_counted,
         a.avg_instance_cpu_percent * a.samples AS instance_cpu_total, CASE WHEN a.avg_instance_cpu_percent IS NOT NULL THEN a.samples END AS instance_cpu_counted,
         a.max_instance_cpu_percent, a.avg_instance_memory_percent * a.samples AS instance_memory_total,
         CASE WHEN a.avg_instance_memory_percent IS NOT NULL THEN a.samples END AS instance_memory_counted, a.max_instance_memory_percent,
         a.avg_dtu * a.samples AS dtu_total, CASE WHEN a.avg_dtu IS NOT NULL THEN a.samples END AS dtu_counted, a.max_dtu,
         a.dtu_limit AS max_dtu_limit, a.cpu_limit AS max_cpu_limit
    FROM pgvigil.mssql_azuredb_minute a
   WHERE a.instance_id = $1 AND a.snapshot_at >= $2 AND a.snapshot_at < $3
)` + sqlAzureDBGroupedSelect

// sqlAzureDBGroupedHours: a step of an hour or more, from the hour split (built hours whole, edge and unbuilt minutes)
var sqlAzureDBGroupedHours = `
WITH s AS (
  SELECT w.snapshot_at, w.minutes, w.samples, w.cpu_total, w.cpu_counted, w.max_cpu_percent, w.data_io_total, w.data_io_counted,
         w.max_data_io_percent, w.log_write_total, w.log_write_counted, w.max_log_write_percent, w.memory_usage_total,
         w.memory_usage_counted, w.dtu_percent_total, w.dtu_percent_counted, w.max_dtu_percent, w.max_worker_percent, w.max_session_percent,
         w.xtp_storage_total, w.xtp_storage_counted, w.instance_cpu_total, w.instance_cpu_counted, w.max_instance_cpu_percent,
         w.instance_memory_total, w.instance_memory_counted, w.max_instance_memory_percent, w.dtu_total, w.dtu_counted, w.max_dtu,
         w.max_dtu_limit, w.max_cpu_limit
    FROM pgvigil.mssql_azuredb_window(ARRAY[$1::int], $2, $3) w
)` + sqlAzureDBGroupedSelect

// sqlPoolGrouped: the pool's minutes in $4-minute buckets - the hour / day read (sqlPoolBuckets) with its date_trunc
// swapped for the 1900-based bucket
var sqlPoolGrouped = strings.Replace(sqlPoolBuckets, "date_trunc($4, pm.snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'", azureBucket("pm.snapshot_at"), 1)

// sqlNoGroup: part=grouped asked with no step
const sqlNoGroup = `SELECT NULL::timestamptz AS snapshot_at WHERE $1::int IS NULL AND $2::timestamptz IS NULL AND $3::timestamptz IS NULL AND $4::int IS NULL`

// azureGroupedDB / azureGroupedPool: the read a step asks for
func azureGroupedDB(step int) string {
	switch {
	case step == 0:
		return sqlNoGroup
	case step < 60:
		return sqlAzureDBGroupedMinutes
	default:
		return sqlAzureDBGroupedHours
	}
}

func azureGroupedPool(step int) string {
	if step == 0 {
		return sqlNoGroup
	}
	return sqlPoolGrouped
}
