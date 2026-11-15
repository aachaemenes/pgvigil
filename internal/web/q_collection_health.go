package web

import (
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"
)

// Collection Health (B6.2): DBA Dash 4.25.0's Checks > Collection Health over a picked range, at the root, a tag
// folder (its instances) or an instance. The judgement is the repository's own (pgvigil.collection_health, 0166: the
// Summary reads the same function); this file adds what the page shows beside it over the range - durations, rows,
// the errors logged, the Summary's 24-hour failure rate, the window of the Last Failure link (CollectionHealth_Get.sql:
// 248-257) - and the grain: a row per collection per instance, or per collection over the instances in scope (the sums,
// the latest times, the worst status but N/A; Instances, Failing Instances = instances whose failures in a row are
// above 0).

// chReach: the hourly rows are kept up to 30 days (0166's CHECK): a range up to that is read whole
const chReach = 31 * 24 * time.Hour

// the scope and range filters every part shares: $1 from, $2 to, $3 instance (0 = none), $4 instance ids (NULL = all),
// $5 collection (” = all); $6 the part's own (every part references $1-$6: an unreferenced parameter is refused)
const chScope = `($3::int = 0 OR %[1]s.instance_id = $3) AND ($4::int[] IS NULL OR %[1]s.instance_id = ANY ($4)) AND ($5::text = '' OR %[1]s.collection = $5)`

func chScopeOf(alias string) string { return strings.ReplaceAll(chScope, "%[1]s", alias) }

// the hour that holds the range's start (rounded DOWN, as DBA Dash's page: CollectionHealth_Get @FromHour; the lead's
// 00:5x call on the review's #6) - the Summary's rate keeps rounding up (collection_health_summary)
const chHourFrom = `date_trunc('hour', $1::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'`

// the end of the hour that holds the range's end: 0166 counts the hours that begin before it, so Failed's window is
// chHourFrom .. chHourTo (capped at now); the Failed link opens that window (the review of B6.2, part b #1)
const chHourTo = `date_trunc('hour', ($2::timestamptz AT TIME ZONE 'UTC') + interval '1 hour' - interval '1 microsecond') AT TIME ZONE 'UTC'`

// sqlCHRows: one row per instance and collection. $7 the expected intervals (the stale check's), $6 the statuses
// shown (NULL = all).
var sqlCHRows = `
WITH c AS (
  SELECT c.*, i.name AS instance, i.engine
    FROM pgvigil.collection_health(` + chHourFrom + `, $7::jsonb, $2::timestamptz,
                                   CASE WHEN $3::int > 0 THEN ARRAY[$3::int] ELSE $4::int[] END, nullif($5::text, '')) c
    JOIN pgvigil.instances i ON i.instance_id = c.instance_id
   WHERE ` + chScopeOf("c") + `
), s AS (   -- the Summary's rate: its window, 24 hours from the next whole hour; the known runs only of an instance with a
            -- failure or a partial in it (DBA Dash's SummaryKnownCount, CollectionHealth_Get :244; the lead's 00:5x on #9a)
  SELECT h.instance_id, h.collection, sum(h.failed) AS failed24,
         CASE WHEN sum(h.failed) + sum(h.partial) > 0 THEN sum(h.ok + h.partial + h.failed) ELSE 0 END AS known24
    FROM pgvigil.collection_health_hour h
   WHERE h.hour >= date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - interval '23 hours' AND ` + chScopeOf("h") + `
   GROUP BY h.instance_id, h.collection
), e AS (
  SELECT l.instance_id, l.collection, count(*)::int AS errors
    FROM pgvigil.collection_log l
   WHERE l.status = 'error' AND l.snapshot_at >= $1::timestamptz AND l.snapshot_at < $2::timestamptz AND ` + chScopeOf("l") + `
   GROUP BY l.instance_id, l.collection
)
SELECT c.instance_id, c.instance, c.engine, c.collection, c.status, c.status_reason, c.runs, c.ok, c.partial, c.failed, c.skipped,
       c.failed_pct, c.problem_pct, s.failed24, s.known24, c.consecutive_failures, c.last_run_at, c.last_ok_at, c.last_failure_at,
       c.dur_sum, c.dur_max, c.rows_written, coalesce(e.errors, 0) AS errors,
       c.import_failed, c.import_runs, c.import_sum, c.import_max, c.cpu_runs, c.cpu_sum, c.cpu_max, c.reads_sum,
       CASE WHEN c.consecutive_failures > 0 AND c.last_ok_at IS NOT NULL THEN c.last_ok_at ELSE c.last_failure_at - interval '10 minutes' END AS errors_from,
       c.last_failure_at + interval '1 hour' AS errors_to
  FROM c
  LEFT JOIN s ON s.instance_id = c.instance_id AND s.collection = c.collection
  LEFT JOIN e ON e.instance_id = c.instance_id AND e.collection = c.collection`

// the page's columns from sqlCHRows' r: percentages over the known runs (ok + partial + failed), the average duration
// over them, DBA Dash's default thresholds named
const chCols = `
       r.runs, round(100.0 * (r.ok + r.partial) / nullif(r.ok + r.partial + r.failed, 0), 2) AS succeeded_pct,
       round(100.0 * r.failed / nullif(r.ok + r.partial + r.failed, 0), 2) AS failed_pct,
       -- DBA Dash's 0 where nothing failed in the summary's period, even with no run in it (CollectionHealth_Get :441-443)
       CASE WHEN coalesce(r.failed24, 0) = 0 THEN 0.00 ELSE round(100.0 * r.failed24 / nullif(r.known24, 0), 2) END AS failed_pct_24h,
       -- B6g-1 (N27): Failed is the failures at the read, Import Failed the ones at the write into the repository - DBA
       -- Dash's two counts (CollectionHealth_Get.sql :113-114); Failed % above is over both (:439), as 0166 judges
       r.ok + r.partial AS succeeded, r.partial, r.failed - r.import_failed AS failed, r.import_failed,
       r.consecutive_failures AS failures_in_a_row,
       r.last_run_at, r.last_ok_at AS last_success, r.last_failure_at AS last_failure,
       round(r.dur_sum::numeric / nullif(r.ok + r.partial + r.failed, 0)) AS avg_duration_ms, r.dur_max AS max_duration_ms,
       -- the import's own time, over the runs that attempted one (the durations above hold it too); B6g-1 (N25 / N26):
       -- the CPU and logical reads of the runs that read their own session at their end (SQL Server) - NULL where none
       -- did (the page: 'not read'), never 0
       round(r.import_sum::numeric / nullif(r.import_runs, 0)) AS avg_import_ms, CASE WHEN r.import_runs > 0 THEN r.import_max END AS max_import_ms,
       r.cpu_sum AS total_cpu_ms, round(r.cpu_sum::numeric / nullif(r.cpu_runs, 0)) AS avg_cpu_ms, r.cpu_max AS max_cpu_ms,
       r.reads_sum AS logical_reads, round(r.reads_sum::numeric / nullif(r.cpu_runs, 0)) AS avg_logical_reads,
       r.rows_written AS rows, r.errors, 'DBA Dash''s defaults' AS thresholds, r.errors_from, r.errors_to,
       ` + chHourFrom + ` AS rate_from, least(` + chHourTo + `, now()) AS rate_to`

// sqlCHInstance: Row per collection per instance (DBA Dash's default), worst first
var sqlCHInstance = `WITH r AS (` + sqlCHRows + `)
SELECT r.instance_id, r.instance, r.engine, r.collection, r.status, r.status_reason,` + chCols + `
  FROM r
 WHERE $6::text[] IS NULL OR r.status = ANY ($6)
 ORDER BY CASE r.status WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 WHEN 'n/a' THEN 3 WHEN 'ok' THEN 4 END, failed_pct DESC NULLS LAST, r.collection, r.instance   -- DBA Dash's: Status, FailedPct DESC, Name (the collection: CollectionHealth_Get.sql L521); then the instance`

// sqlCHCollection: Row per collection over the instances in scope (CollectionHealth_Get.sql:395-440, :508-517): the
// sums, the latest times, the worst status but N/A (all N/A = N/A), the errors' window the widest; Instance and Status
// Reason dropped as DBA Dash drops them at this grain
var sqlCHCollection = `WITH x AS (` + sqlCHRows + `), r AS (
  SELECT x.collection,
         CASE coalesce(min(CASE x.status WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 WHEN 'ok' THEN 4 END), 3)
              WHEN 1 THEN 'critical' WHEN 2 THEN 'warning' WHEN 4 THEN 'ok' ELSE 'n/a' END AS status,
         count(*)::int AS instances, count(*) FILTER (WHERE x.consecutive_failures > 0)::int AS failing_instances,
         sum(x.runs)::int AS runs, sum(x.ok)::int AS ok, sum(x.partial)::int AS partial, sum(x.failed)::int AS failed,
         sum(x.failed24) AS failed24, sum(x.known24) AS known24, max(x.consecutive_failures) AS consecutive_failures,
         max(x.last_run_at) AS last_run_at, max(x.last_ok_at) AS last_ok_at, max(x.last_failure_at) AS last_failure_at,
         sum(x.dur_sum) AS dur_sum, max(x.dur_max) AS dur_max, sum(x.rows_written) AS rows_written, sum(x.errors)::int AS errors,
         sum(x.import_failed)::int AS import_failed, sum(x.import_runs)::int AS import_runs, sum(x.import_sum) AS import_sum,
         max(x.import_max) AS import_max, sum(x.cpu_runs)::int AS cpu_runs, sum(x.cpu_sum) AS cpu_sum, max(x.cpu_max) AS cpu_max,
         sum(x.reads_sum) AS reads_sum,
         min(x.errors_from) AS errors_from, max(x.errors_to) AS errors_to
    FROM x
   GROUP BY x.collection
)
SELECT r.collection, r.status, r.instances, r.failing_instances,` + chCols + `
  FROM r
 WHERE $6::text[] IS NULL OR r.status = ANY ($6)
 ORDER BY CASE r.status WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 WHEN 'n/a' THEN 3 WHEN 'ok' THEN 4 END, failed_pct DESC NULLS LAST, r.collection   -- DBA Dash's: Status, FailedPct DESC, Name`

// sqlCHRuns: the Runs chart - runs per bucket of $6 seconds by outcome, over the collections in scope
var sqlCHRuns = `
SELECT to_timestamp(floor(extract(epoch FROM h.hour) / $6::int) * $6::int) AS at,   -- the epoch floored: PostgreSQL 13 has no binning function (0054, 0076)
       sum(h.failed)::int AS failed, sum(h.partial)::int AS partial, sum(h.ok)::int AS succeeded
  FROM pgvigil.collection_health_hour h
 WHERE h.hour >= ` + chHourFrom + ` AND h.hour < $2::timestamptz AND ` + chScopeOf("h") + `
 GROUP BY 1 ORDER BY 1`

// sqlCHCost: the Cost chart - the time spent collecting per bucket, in seconds (pgvigil has no import step: the page
// says so where DBA Dash shows its import time and lag)
var sqlCHCost = `
SELECT to_timestamp(floor(extract(epoch FROM h.hour) / $6::int) * $6::int) AS at,   -- the epoch floored: PostgreSQL 13 has no binning function (0054, 0076)
       round(sum(h.dur_ms_sum) / 1000.0, 1) AS collecting_s
  FROM pgvigil.collection_health_hour h
 WHERE h.hour >= ` + chHourFrom + ` AND h.hour < $2::timestamptz AND ` + chScopeOf("h") + `
 GROUP BY 1 ORDER BY 1`

// sqlCHErrors: the error list - collection_log's errors in scope between from and to (the Failed / Errors links: the
// range; Last Failure: errors_from .. errors_to), newest first, 500 at most; $6 a text the message holds (” = any:
// matched as text, never as a pattern)
var sqlCHErrors = `
SELECT l.instance_id, i.name AS instance, l.collection, l.snapshot_at AS at, l.duration_ms, l.note AS message
  FROM pgvigil.collection_log l
  JOIN pgvigil.instances i ON i.instance_id = l.instance_id AND i.is_active   -- as 0166's j counts Failed (B6f3 #2)
 WHERE l.status = 'error' AND l.snapshot_at >= $1::timestamptz AND l.snapshot_at < $2::timestamptz AND ` + chScopeOf("l") + `
   AND ($6::text = '' OR strpos(lower(coalesce(l.note, '')), lower($6)) > 0)
 ORDER BY l.snapshot_at DESC
 LIMIT 500`

// chStatuses: the status filter's words (DBA Dash's four; 'na' for N/A), NULL for all four
func chStatuses(v string) ([]string, error) {
	if v == "" {
		return nil, nil
	}
	var out []string
	for _, w := range strings.Split(v, ",") {
		v := strings.TrimSpace(w)
		switch v {
		case "critical", "warning", "ok":
		case "na":
			v = "n/a"
		default:
			return nil, errors.New("status must be critical, warning, na or ok, separated by commas")
		}
		if !slices.Contains(out, v) { // a repeated word is one status
			out = append(out, v)
		}
	}
	if len(out) == 4 { // all four (distinct): no filter
		return nil, nil
	}
	return out, nil
}

// chBucket: the charts' bucket in seconds - an hour at least (the rows are hourly), about 48 buckets over the range
func chBucket(from, to time.Time) int {
	h := int(to.Sub(from).Hours()/48) + 1
	return max(1, h) * 3600
}

// CollectionHealth is GET /api/collectionhealth[?instance=N|?instances=..][&from&to][&grain=instance|collection]
// [&collection=c][&status=critical,warning,na,ok][&q=text][&part=collections|runs|cost|errors].
func (s *Server) CollectionHealth(w http.ResponseWriter, r *http.Request) {
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
	st, err := chStatuses(q.Get("status"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	rows := sqlCHInstance
	switch q.Get("grain") {
	case "", "instance":
	case "collection":
		rows = sqlCHCollection
	default:
		writeErr(w, http.StatusBadRequest, errors.New("grain must be instance or collection"))
		return
	}
	exp, err := json.Marshal(s.expected)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	coll := q.Get("collection")
	scope := []any{from, to, id, ids, coll}
	with := func(x ...any) []any { return append(append([]any{}, scope...), x...) }
	all := map[string]part{
		"collections": {"collections", rows, with(st, string(exp))},
		"runs":        {"runs", sqlCHRuns, with(chBucket(from, to))},
		"cost":        {"cost", sqlCHCost, with(chBucket(from, to))},
		"errors":      {"errors", sqlCHErrors, with(q.Get("q"))},
	}
	var ps []part
	for _, n := range chPartNames(q.Get("part")) {
		ps = append(ps, all[n])
	}
	s.multiPart(w, r, ps)
}

// chPartNames: the parts a read offers multiPart (which runs the one part= names, or every one offered); the error list
// only when part=errors asks for it (the Errors link's list) - the page's main read draws no error list
func chPartNames(part string) []string {
	if part == "errors" {
		return []string{"collections", "runs", "cost", "errors"}
	}
	return []string{"collections", "runs", "cost"}
}
