package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strconv"
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
// $5 collection (empty = all); $6 the part's own (each part of these six references $1-$6: an unreferenced parameter is
// refused; part=thresholds takes its own two)
const chScope = `($3::int = 0 OR %[1]s.instance_id = $3) AND ($4::int[] IS NULL OR %[1]s.instance_id = ANY ($4)) AND ($5::text = '' OR %[1]s.collection = $5)`

func chScopeOf(alias string) string { return strings.ReplaceAll(chScope, "%[1]s", alias) }

// the hour that holds the range's start (rounded DOWN, as DBA Dash's page: CollectionHealth_Get @FromHour; the
// call on the review's #6) - the Summary's rate keeps rounding up (collection_health_summary)
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
), s AS (   -- the Summary's rate: its window, 24 hours from the next whole hour, or from the instance's acknowledgement of
            -- its collector errors rounded up to the hour if that is later (CollectionHealthRateFrom.sql; CollectionHealth_Get
            -- L154-169); the known runs only of an instance with a failure or a partial in it (DBA Dash's SummaryKnownCount,
            -- CollectionHealth_Get :244)
  SELECT h.instance_id, h.collection, sum(h.failed) AS failed24,
         CASE WHEN sum(h.failed) + sum(h.partial) > 0 THEN sum(h.ok + h.partial + h.failed) ELSE 0 END AS known24
    FROM pgvigil.collection_health_hour h
    LEFT JOIN pgvigil.collection_errors_ack() a ON a.instance_id = h.instance_id
   WHERE h.hour >= date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - interval '23 hours' AND ` + chScopeOf("h") + `
     AND (a.rate_from IS NULL OR h.hour >= a.rate_from)
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
       c.threshold_from, c.threshold_words,
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
       r.rows_written AS rows, r.errors,
       -- B6g-2: where the numbers come from (DBA Dash's defaults, or the scopes that set them), the numbers in the title
       -- a row per collection whose instances differ: 'each instance its own' (the review of B6g-2 #12: it read 'set on
       -- each instance its own' though an instance on the defaults is set nowhere)
       CASE WHEN r.threshold_from = 'differ by instance' THEN 'each instance its own' ELSE coalesce('set on ' || r.threshold_from, 'DBA Dash''s defaults') END AS thresholds, r.threshold_words, r.errors_from, r.errors_to,
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
         min(x.errors_from) AS errors_from, max(x.errors_to) AS errors_to,
         -- the engine where every instance of the row shares one (collection names never cross engines): its cost cells'
         -- words read it - a PostgreSQL collection's 'not read by pgvigil' (the review of B6g-1 part b #1)
         CASE WHEN min(x.engine) = max(x.engine) THEN min(x.engine) END AS engine,
         -- one source and one set of numbers over the instances, else said as differing
         CASE WHEN count(DISTINCT coalesce(x.threshold_from, '')) = 1 THEN min(x.threshold_from) ELSE 'differ by instance' END AS threshold_from,
         CASE WHEN count(DISTINCT x.threshold_words) = 1 THEN min(x.threshold_words) ELSE 'each instance its own' END AS threshold_words
    FROM x
   GROUP BY x.collection
)
SELECT r.collection, r.status, r.engine, r.instances, r.failing_instances,` + chCols + `
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

// sqlCHCost: the Cost chart - per bucket, in seconds: the time spent collecting (the whole runs), the collect's CPU of
// the runs that read their own session (SQL Server; NULL in a bucket with none) and the time spent importing (the
// writes alone, inside the collecting time). DBA Dash's chart also draws the import's own CPU: pgvigil does not read it
// (the page says so); there is no import lag (the write is inside the run)
var sqlCHCost = `
SELECT to_timestamp(floor(extract(epoch FROM h.hour) / $6::int) * $6::int) AS at,   -- the epoch floored: PostgreSQL 13 has no binning function (0054, 0076)
       round(sum(h.dur_ms_sum) / 1000.0, 1) AS collecting_s,
       round(sum(h.cpu_ms_sum) FILTER (WHERE h.cpu_runs > 0) / 1000.0, 1) AS cpu_s,
       round(sum(h.import_ms_sum) / 1000.0, 1) AS importing_s
  FROM pgvigil.collection_health_hour h
 WHERE h.hour >= ` + chHourFrom + ` AND h.hour < $2::timestamptz AND ` + chScopeOf("h") + `
 GROUP BY 1 ORDER BY 1`

// sqlCHErrors: the error list - collection_log's errors in scope between from and to (the Failed / Errors links: the
// range; Last Failure: errors_from .. errors_to), newest first, 500 at most; $6 a text the message holds (empty = any:
// matched as text, never as a pattern)
var sqlCHErrors = `
SELECT l.instance_id, i.name AS instance, l.collection, l.snapshot_at AS at, l.duration_ms, l.note AS message
  FROM pgvigil.collection_log l
  JOIN pgvigil.instances i ON i.instance_id = l.instance_id AND i.is_active   -- as 0166's j counts Failed (B6f3 #2)
 WHERE l.status = 'error' AND l.snapshot_at >= $1::timestamptz AND l.snapshot_at < $2::timestamptz AND ` + chScopeOf("l") + `
   AND ($6::text = '' OR strpos(lower(coalesce(l.note, '')), lower($6)) > 0)
 ORDER BY l.snapshot_at DESC
 LIMIT 500`

// sqlCHThresholds: the thresholds dialog's read (B6g-2, N33 / N41) - the live rows of the four 'Apply to' levels of one
// instance's collection, most specific first (DBA Dash's CollectionHealthThresholds_Get reads the same four for its
// 'Inherited:' values): this instance and collection, this instance and every collection, this collection on every
// instance, everything. $1 the instance (0 = none: the collection grain), $2 the collection (empty = none).
var sqlCHThresholds = `
SELECT t.threshold_id, t.instance_id, t.collection, t.warn_fails_in_row, t.warn_fail_minutes, t.crit_fails_in_row, t.crit_fail_minutes,
       t.warn_fail_pct, t.crit_fail_pct, t.min_runs, t.dont_monitor, t.created_by, t.created_at
  FROM pgvigil.collection_health_threshold t
 WHERE t.ended_at IS NULL
   AND (t.instance_id IS NULL OR t.instance_id = nullif($1::int, 0))
   AND (t.collection IS NULL OR t.collection = nullif($2::text, ''))
 ORDER BY t.instance_id NULLS LAST, t.collection NULLS LAST`

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
		"thresholds":  {"thresholds", sqlCHThresholds, []any{id, coll}},
	}
	var ps []part
	for _, n := range chPartNames(q.Get("part")) {
		ps = append(ps, all[n])
	}
	s.multiPart(w, r, ps)
}

// chPartNames: the parts a read offers multiPart (which runs the one part= names, or every one offered); the error list
// only when part=errors asks for it (the Errors link's list), the thresholds' live rows only when part=thresholds asks
// (the dialog's read: instance= and collection= name the row) - the page's main read draws neither
func chPartNames(part string) []string {
	switch part {
	case "errors", "thresholds":
		return []string{"collections", "runs", "cost", part}
	}
	return []string{"collections", "runs", "cost"}
}

// CHThresholdWrite is POST /api/collectionhealth/thresholds (B6g-2, N33 / N41): DBA Dash's per-collection thresholds,
// set or inherited at one scope - an instance's collection, every collection of an instance, a collection on every
// instance, everything (instance_id / collection left out). Any signed-in user writes them (ROLE (a)),
// audited in the table's history - admin-gated once B24f's role gate lands (on B24f's list); the demo door carries one demo instance's scopes and refuses the two wider ones in
// words. import_collection_health_threshold answers done or refused (409 with its words).
func (s *Server) CHThresholdWrite(w http.ResponseWriter, r *http.Request) {
	seat, ok := s.seat(w, r, strings.Replace(s.ackOff(), "acknowledgements", "Collection Health thresholds", 1))
	if !ok {
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 4097))
	if err != nil || len(raw) > 4096 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 4 KB"))
		return
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return
	}
	var in map[string]any
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	// only the named keys travel on; who and from where are the server's to say
	pay := map[string]any{"ui_user": seat.user, "client": seat.client}
	for _, k := range []string{"op", "instance_id", "collection", "warn_fails_in_row", "warn_fail_minutes", "crit_fails_in_row", "crit_fail_minutes",
		"warn_fail_pct", "crit_fail_pct", "min_runs", "dont_monitor"} {
		if v, ok := in[k]; ok && v != nil {
			// a number is passed on as its text: the function checks the shape before it casts
			if f, isNum := v.(float64); isNum {
				// as sent, never rounded (the review of B6g-2 #8: 0.999 became 1): the function refuses what is not a
				// whole number or a per cent to two places
				v = strconv.FormatFloat(f, 'f', -1, 64)
			}
			pay[k] = v
		}
	}
	b, _ := json.Marshal(pay)
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	pool, ok := seat.poolFor(wctx, w, scopeOfCHThreshold(pay))
	if !ok {
		return
	}
	var out []byte
	if err := pool.QueryRow(wctx, `SELECT pgvigil.import_collection_health_threshold($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("collection health threshold: not written", "user", seat.user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	var res struct {
		Outcome     string `json:"outcome"`
		Detail      string `json:"detail"`
		ThresholdID *int64 `json:"threshold_id"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_collection_health_threshold answered %q", out))
		return
	}
	s.log.Info("collection health threshold: attempt", "op", pay["op"], "instance_id", pay["instance_id"], "collection", pay["collection"], "user", seat.user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	o := map[string]any{"outcome": res.Outcome, "detail": res.Detail, "threshold_id": res.ThresholdID}
	if res.Outcome != "done" {
		// a refusal's words as the other writes give them (q_ack.go, q_drives.go): the page's post() shows 'error'
		code = http.StatusConflict
		o["error"] = "refused: " + res.Detail
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(o)
}
