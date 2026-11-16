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
// the Run rows (collection_log's failed and partial runs of the range), newest first, $6 + 1 at most - read by
// pgvigil.collection_perf_rows (0166), which walks the range newest first and stops at the cap (J5 after the index, the
// call (a): the whole-range form aggregated every hour before keeping 5,001 - 96 s at the root for every
// collection at 2,124 instances x 60 collections x 8 days); its rows sorted again here in the page's own order.
// TestCollectionPerfCapOrderOnAStore holds it to the whole-range form, row for row.
var sqlCollPerfRows = `
SELECT x.at, x.instance_id, x.instance, x.engine, x.collection, x.period, x.outcome, x.stage, x.runs, x.failed, x.partial,
       x.duration_ms, x.max_duration_ms, x.cpu_ms, x.logical_reads, x.import_ms
  FROM pgvigil.collection_perf_rows($1::timestamptz, $2::timestamptz, $3::int, $4::int[], coalesce($5::text, ''), $6::int) x
 ORDER BY x.at DESC, x.instance, x.collection, x.period
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

// sqlCollPerfMeta: how long the hourly rows are kept (hours_retention, 8 days by default, clamped to 1-30 as 0166's trim
// clamps it) and the first hour still kept - the trim deletes every hour before now() - days, so the hour that holds
// that instant is gone too: rounded UP (its review #2: rounded down it named an hour already deleted), in UTC hours as
// the rows are (the review of B6g part c #2: a store whose zone is not a whole hour from UTC cut it half an hour off)
var sqlCollPerfMeta = `
SELECT r.days, date_trunc('hour', (now() - make_interval(days => r.days)) AT TIME ZONE 'UTC' + interval '1 hour' - interval '1 microsecond') AT TIME ZONE 'UTC' AS kept_from
  FROM (SELECT least(greatest(coalesce(max(h.days), 8), 1), 30) AS days FROM pgvigil.hours_retention h WHERE h.table_name = 'collection_health_hour') r`

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
