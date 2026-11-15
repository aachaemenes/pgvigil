package web

// Collection Performance (B6g-3, N42): DBA Dash 4.25.0's Collection Performance report (CollectionPerformanceReport.cs,
// CollectionPerformance_Get.sql) - one collection's runs over the range the Collection Health grid was read with.
//
//	GET /api/collectionperf  s.CollectionPerf  parts rows, charts, meta
//
// pgvigil keeps every run in collection_health_hour (summed per hour, per collector) and a failed or partial run one by
// one in collection_log (log_collection writes no ok run: the design's (iv) CHANGED). So the report's Hour rows are
// every run, its Run rows the failed and partial runs only - never all the runs, said on the page. A Run row holds its
// duration alone (CPU, logical reads and the import are kept by the hour). The charts read the hours only.

import (
	"errors"
	"net/http"
	"strconv"
)

// collPerfCap is DBA Dash's @MaxRows: the grid's rows, the latest. The read asks one more, so the page can say it was hit.
const collPerfCap = 5000

// every part shares Collection Health's scope (chScope: $1 from, $2 to, $3 instance, $4 instance ids, $5 collection)

// sqlCollPerfRows: the Hour rows (an instance, a collection and an hour, summed over the collectors that wrote it) and
// the Run rows (collection_log's failed and partial runs of the range; 0139's job statistics rollup rows are not runs),
// newest first, $6 + 1 at most. The averages as the Collection Health grid's: the duration over the runs that ran (ok,
// partial, failed: skips left out), the CPU and logical reads over the runs that read their session at their end, the
// import over the runs that wrote or tried to. Failed holds the import's failures too (DBA Dash's FailedCount +
// ImportFailedCount); pgvigil has no retries, so its Partial is DBA Dash's 'Retried / Partial'.
var sqlCollPerfRows = `
WITH h AS (
  SELECT h.hour AS at, h.instance_id, h.collection, 'Hour'::text AS period, NULL::text AS outcome,
         sum(h.runs)::bigint AS runs, sum(h.failed)::bigint AS failed, sum(h.partial)::bigint AS partial,
         round(sum(h.dur_ms_sum)::numeric / nullif(sum(h.ok + h.partial + h.failed), 0))::bigint AS duration_ms,
         max(h.dur_ms_max)::bigint AS max_duration_ms,
         round(sum(h.cpu_ms_sum)::numeric / nullif(sum(h.cpu_runs), 0))::bigint AS cpu_ms,
         round(sum(h.reads_sum)::numeric / nullif(sum(h.cpu_runs), 0))::bigint AS logical_reads,
         round(sum(h.import_ms_sum)::numeric / nullif(sum(h.import_runs), 0))::bigint AS import_ms
    FROM pgvigil.collection_health_hour h
   WHERE h.hour >= date_trunc('hour', $1::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AND h.hour < $2::timestamptz
     AND ` + chScopeOf("h") + `
   GROUP BY h.hour, h.instance_id, h.collection
), r AS (
  SELECT l.snapshot_at, l.instance_id, l.collection, 'Run'::text, CASE l.status WHEN 'error' THEN 'Failed' ELSE 'Partial' END,
         1::bigint, (l.status = 'error')::int::bigint, (l.status = 'partial')::int::bigint,
         l.duration_ms::bigint, l.duration_ms::bigint, NULL::bigint, NULL::bigint, NULL::bigint
    FROM pgvigil.collection_log l
   WHERE l.status IN ('error', 'partial') AND l.collection <> 'job_stats_hourly'
     AND l.snapshot_at >= $1::timestamptz AND l.snapshot_at < $2::timestamptz AND ` + chScopeOf("l") + `
)
SELECT x.at, x.instance_id, i.name AS instance, i.engine, x.collection, x.period, x.outcome, x.runs, x.failed, x.partial,
       x.duration_ms, x.max_duration_ms, x.cpu_ms, x.logical_reads, x.import_ms
  FROM (SELECT * FROM h UNION ALL SELECT * FROM r) x
  JOIN pgvigil.instances i ON i.instance_id = x.instance_id AND i.is_active
 ORDER BY x.at DESC, i.name, x.collection, x.period
 LIMIT $6::int + 1`

// sqlCollPerfCharts: the four charts' points, one an hour over every instance in scope (DBA Dash's #Buckets from the
// hourly rollup): the runs by outcome, the collecting and import time (average and highest), the CPU (SQL Server's
// runs that read it) and the logical reads
var sqlCollPerfCharts = `
SELECT h.hour AS at, sum(h.ok)::bigint AS succeeded, sum(h.partial)::bigint AS partial, sum(h.failed)::bigint AS failed,
       round(sum(h.dur_ms_sum)::numeric / nullif(sum(h.ok + h.partial + h.failed), 0))::bigint AS collect_avg_ms,
       max(h.dur_ms_max)::bigint AS collect_max_ms,
       round(sum(h.import_ms_sum)::numeric / nullif(sum(h.import_runs), 0))::bigint AS import_avg_ms,
       max(h.import_ms_max) FILTER (WHERE h.import_runs > 0)::bigint AS import_max_ms,
       round(sum(h.cpu_ms_sum)::numeric / nullif(sum(h.cpu_runs), 0))::bigint AS cpu_avg_ms,
       max(h.cpu_ms_max) FILTER (WHERE h.cpu_runs > 0)::bigint AS cpu_max_ms,
       round(sum(h.reads_sum)::numeric / nullif(sum(h.cpu_runs), 0))::bigint AS reads_avg
  FROM pgvigil.collection_health_hour h
  JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
 WHERE h.hour >= date_trunc('hour', $1::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AND h.hour < $2::timestamptz
   AND ` + chScopeOf("h") + `
 GROUP BY h.hour
 ORDER BY h.hour`

// sqlCollPerfMeta: how long the hourly rows are kept (hours_retention, 8 days by default, 30 at most: 0166) and the
// hour the report can read from - a range starting before it says so on the page
var sqlCollPerfMeta = `
SELECT r.days, date_trunc('hour', now() - make_interval(days => r.days)) AS kept_from
  FROM (SELECT coalesce((SELECT days FROM pgvigil.hours_retention WHERE table_name = 'collection_health_hour'), 8) AS days) r`

// CollectionPerf is GET /api/collectionperf: instance= or instances= (none = every instance), collection= (none =
// every collection), from= / to= (the Collection Health page's range; reach as Collection Health's); part= one of rows,
// charts, meta (none = all three).
func (s *Server) CollectionPerf(w http.ResponseWriter, r *http.Request) {
	id, ids, err := storageScope(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	_, from, to, err := paramsReach(r, false, chReach)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	coll := q.Get("collection")
	if len(coll) > 100 {
		writeErr(w, http.StatusBadRequest, errors.New("collection: 100 characters at most"))
		return
	}
	limit := collPerfCap
	if v := q.Get("limit"); v != "" {
		if limit, err = strconv.Atoi(v); err != nil || limit < 1 || limit > collPerfCap {
			writeErr(w, http.StatusBadRequest, errors.New("limit must be a number from 1 to "+strconv.Itoa(collPerfCap)))
			return
		}
	}
	scope := []any{from, to, id, ids, coll}
	all := map[string]part{
		"rows":   {"rows", sqlCollPerfRows, append(append([]any{}, scope...), limit)},
		"charts": {"charts", sqlCollPerfCharts, scope},
		"meta":   {"meta", sqlCollPerfMeta, nil},
	}
	var ps []part
	for _, n := range []string{"rows", "charts", "meta"} {
		ps = append(ps, all[n])
	}
	s.multiPart(w, r, ps)
}
