package web

import (
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The Query Store page of a SQL Server instance (task 129; DBA Dash's Query Store Top Queries, Forced Plans and
// QS options grids, Darling's Query Store tab). Data from the collection mssql_querystore (0083): the store's
// intervals as the collector read them, never a statement run on the server by a page.
//
// A window takes every interval of the store that OVERLAPS it (an interval is 60 minutes unless the database says
// otherwise, a day at most): the last hour at 10:20 is the intervals 09:00 and 10:00.
//
//   GET /api/mssql/querystore?instance=N[&from=&to=][&db=<database>][&order=...][&view=...][&part=...]
//       view = top | regressed | forced | tuning | state reads state, checks and that view's own parts only (the
//       page asks so); without it every part is read.
//       state     one row per database: the store's options, its judgement and why (the Store state tab);
//       totals    the window's totals over EVERY plan of the store (the interval rows) and the kept plans' share;
//       series    those totals per step, for the chart;
//       top       the queries of the window, the first 100 by order = duration (default) | cpu | reads | memory |
//                 waits | executions;
//       regressed a plan whose average duration or CPU in the window is 1.5 times its query's average in the
//                 window of equal length before it (over all the query's plans), or more, and at least 1 ms;
//       forced    every forced plan with its failure count and reason;
//       tuning, tuning_options   the automatic tuning recommendations and the databases' options;
//       checks    the slice's findings of the instance.
//   GET /api/mssql/querystore/query?instance=N&db=<database>&query=<id>&hash=0x...[&from=&to=]
//       query (text and properties), plans (each plan of the query that ran in the window), series (per interval
//       and plan).
//   GET /api/mssql/querystore/plan.sqlplan?instance=N&db=<database>&plan=<id>
//       the plan's showplan XML as a download SSMS opens; 404 when none is stored (a text policy other than full).

// qsWindow is the predicate "the interval overlaps the window" for an alias with snapshot_at (the interval's start)
// and interval_end; the third bound lets the planner prune partitions (an interval is a day at most).
const qsWindow = `%[1]s.instance_id = $1 AND %[1]s.snapshot_at < $3 AND %[1]s.interval_end > $2 AND %[1]s.snapshot_at > $2::timestamptz - interval '1 day'
     AND ($4::text IS NULL OR %[1]s.database_name = $4)`

const sqlMSSQLQSState = `
SELECT s.database_name, s.desired_state, s.actual_state, s.readonly_reason, s.readonly_reasons, s.capture_mode, s.cleanup_mode,
       s.wait_stats_mode, s.stale_days, s.max_plans_per_query, s.current_mb, s.max_mb, s.used_pct, s.flush_interval_s,
       s.interval_minutes, s.policy_execution_count, s.policy_stale_hours, s.policy_compile_cpu_ms, s.policy_exec_cpu_ms,
       s.database_state, s.database_read_only, s.options_read, s.can_read, s.note, s.additional_info, s.severity, s.verdict,
       s.newest_interval, s.snapshot_at
  FROM pgvigil.mssql_qs_store_status s
 WHERE s.instance_id = $1
 ORDER BY s.database_name`

var sqlMSSQLQSTotals = `
WITH iv AS (
  SELECT i.* FROM pgvigil.mssql_qs_interval i WHERE ` + fmt.Sprintf(qsWindow, "i") + `
), rt AS (
  SELECT sum(r.executions) AS executions, sum(r.duration_us) AS duration_us, sum(r.cpu_us) AS cpu_us,
         sum(r.logical_reads) AS logical_reads, sum(r.wait_ms) AS wait_ms,
         count(DISTINCT (r.database_name, r.query_id, r.query_hash)) AS queries
    FROM pgvigil.mssql_qs_runtime r WHERE ` + fmt.Sprintf(qsWindow, "r") + `
)
SELECT count(*) AS intervals, count(DISTINCT iv.database_name) AS databases, min(iv.snapshot_at) AS first_start,
       max(iv.interval_end) AS last_end, max(iv.read_at) AS read_at,
       coalesce(sum(iv.plans), 0) AS plan_runs, coalesce(sum(iv.executions), 0) AS executions,
       round(coalesce(sum(iv.duration_us), 0) / 1000.0, 1) AS duration_ms, round(coalesce(sum(iv.cpu_us), 0) / 1000.0, 1) AS cpu_ms,
       coalesce(sum(iv.logical_reads), 0) AS logical_reads, coalesce(sum(iv.wait_ms), 0) AS wait_ms,
       (SELECT rt.queries FROM rt) AS kept_queries, coalesce((SELECT rt.executions FROM rt), 0) AS kept_executions,
       round(coalesce((SELECT rt.duration_us FROM rt), 0) / 1000.0, 1) AS kept_duration_ms,
       round(coalesce((SELECT rt.cpu_us FROM rt), 0) / 1000.0, 1) AS kept_cpu_ms,
       coalesce((SELECT rt.logical_reads FROM rt), 0) AS kept_logical_reads, coalesce((SELECT rt.wait_ms FROM rt), 0) AS kept_wait_ms
  FROM iv`

// sqlMSSQLQSSeries: the store's totals over every plan, per step ($5 seconds) by the interval's start. The step is
// a minute (every interval its own point) or whole hours (mssqlQSStep): a step that is no multiple of the
// interval's length would hold one interval, then two, and draw a steady load as a zigzag.
var sqlMSSQLQSSeries = `
SELECT to_timestamp(floor(extract(epoch FROM i.snapshot_at) / $5) * $5) AS snapshot_at,
       coalesce(sum(i.executions), 0) AS executions, round(coalesce(sum(i.duration_us), 0) / 1000.0, 1) AS duration_ms,
       round(coalesce(sum(i.cpu_us), 0) / 1000.0, 1) AS cpu_ms, coalesce(sum(i.logical_reads), 0) AS logical_reads,
       coalesce(sum(i.wait_ms), 0) AS wait_ms
  FROM pgvigil.mssql_qs_interval i
 WHERE ` + fmt.Sprintf(qsWindow, "i") + `
 GROUP BY 1 ORDER BY 1`

// sqlMSSQLQSTop: one row per query (database, query id and the query's hash as it was when its rows were read: a
// cleared store gives the id to another statement). $5 is the order. The text comes from the stored query of the
// same hash. Memory is 8 KB pages on the server: MB here.
var sqlMSSQLQSTop = `
WITH g AS (
  SELECT r.database_name, r.query_id, r.query_hash,
         sum(r.executions) AS executions, sum(r.failed) AS failed, sum(r.duration_us) AS duration_us, sum(r.cpu_us) AS cpu_us,
         sum(r.logical_reads) AS logical_reads, sum(r.physical_reads) AS physical_reads, sum(r.logical_writes) AS logical_writes,
         sum(r.row_count) AS row_count, max(r.max_duration_us) AS max_duration_us, max(r.max_memory_pages) AS max_memory_pages,
         sum(r.memory_pages) AS memory_pages, max(r.max_dop) AS max_dop, sum(r.wait_ms) AS wait_ms,
         (array_agg(r.top_wait ORDER BY r.wait_ms DESC NULLS LAST) FILTER (WHERE r.top_wait IS NOT NULL))[1] AS top_wait,
         count(DISTINCT r.plan_id) AS plans, count(DISTINCT r.snapshot_at) AS intervals,
         min(r.first_execution) AS first_execution, max(r.last_execution) AS last_execution
    FROM pgvigil.mssql_qs_runtime r
   WHERE ` + fmt.Sprintf(qsWindow, "r") + `
   GROUP BY r.database_name, r.query_id, r.query_hash
)
SELECT g.database_name, g.query_id, g.query_hash, q.object_name, q.query_text AS query,
       g.executions, g.failed,
       round(g.duration_us / 1000.0, 1) AS duration_ms, round(g.duration_us / 1000.0 / nullif(g.executions, 0), 3) AS avg_duration_ms,
       round(g.max_duration_us / 1000.0, 1) AS max_duration_ms,
       round(g.cpu_us / 1000.0, 1) AS cpu_ms, round(g.cpu_us / 1000.0 / nullif(g.executions, 0), 3) AS avg_cpu_ms,
       g.logical_reads, round(g.logical_reads / nullif(g.executions, 0), 1) AS avg_logical_reads,
       g.physical_reads, g.logical_writes, g.row_count,
       round(g.max_memory_pages * 8 / 1024.0, 1) AS max_memory_mb,
       round(g.memory_pages * 8 / 1024.0 / nullif(g.executions, 0), 1) AS avg_memory_mb,
       g.wait_ms, g.top_wait, g.max_dop, g.plans, q.plan_count, g.intervals,
       EXISTS (SELECT 1 FROM pgvigil.mssql_qs_plan p
                WHERE p.instance_id = $1 AND p.database_name = g.database_name AND p.query_id = g.query_id
                  AND p.query_hash IS NOT DISTINCT FROM g.query_hash AND p.is_forced) AS forced,
       g.first_execution, g.last_execution
  FROM g
  LEFT JOIN pgvigil.mssql_qs_query q ON q.instance_id = $1 AND q.database_name = g.database_name AND q.query_id = g.query_id
                                    AND q.query_hash IS NOT DISTINCT FROM g.query_hash
 ORDER BY CASE $5::text WHEN 'cpu' THEN g.cpu_us WHEN 'reads' THEN g.logical_reads WHEN 'memory' THEN g.max_memory_pages
                        WHEN 'waits' THEN g.wait_ms WHEN 'executions' THEN g.executions ELSE g.duration_us END DESC NULLS LAST,
          g.database_name, g.query_id, g.query_hash
 LIMIT 100`

// sqlMSSQLQSRegressed: now = the intervals that overlap the window; before = the intervals that ended inside the
// window of equal length before it (no interval is in both). A row per plan that ran now, against its query's
// average before over all the query's plans; new_plan = the plan is in no stored row of the window before (it did
// not run then, or ran under every cut). A figure counts when its average before is above zero and its average
// now is at least 1 ms: a trivial statement at 0 before and 0 now is no regression, nor is 10 to 16 microseconds.
var sqlMSSQLQSRegressed = `
WITH now_ AS (
  SELECT r.database_name, r.query_id, r.query_hash, r.plan_id, r.plan_hash_n,
         sum(r.executions) AS executions, sum(r.duration_us) AS duration_us, sum(r.cpu_us) AS cpu_us,
         sum(r.logical_reads) AS logical_reads, max(r.last_execution) AS last_execution
    FROM pgvigil.mssql_qs_runtime r
   WHERE ` + fmt.Sprintf(qsWindow, "r") + ` AND r.query_id IS NOT NULL
   GROUP BY 1, 2, 3, 4, 5
), before AS (
  SELECT r.database_name, r.query_id, r.query_hash,
         sum(r.executions) AS executions, sum(r.duration_us) AS duration_us, sum(r.cpu_us) AS cpu_us,
         sum(r.logical_reads) AS logical_reads, array_agg(DISTINCT r.plan_id) AS plan_ids
    FROM pgvigil.mssql_qs_runtime r
   WHERE r.instance_id = $1 AND r.interval_end <= $2 AND r.interval_end > $2::timestamptz - ($3::timestamptz - $2::timestamptz)
     AND r.snapshot_at < $2 AND r.snapshot_at > $2::timestamptz - ($3::timestamptz - $2::timestamptz) - interval '1 day'
     AND ($4::text IS NULL OR r.database_name = $4) AND r.query_id IS NOT NULL
   GROUP BY 1, 2, 3
)
SELECT n.database_name, n.query_id, n.query_hash, n.plan_id, q.object_name, q.query_text AS query,
       NOT (n.plan_id = ANY (b.plan_ids)) AS new_plan, coalesce(p.is_forced, false) AS forced,
       n.executions, b.executions AS before_executions,
       round(n.duration_us / 1000.0 / n.executions, 3) AS avg_duration_ms, round(b.duration_us / 1000.0 / b.executions, 3) AS before_avg_duration_ms,
       round((n.duration_us / n.executions) / nullif(b.duration_us / b.executions, 0), 2) AS duration_ratio,
       round(n.cpu_us / 1000.0 / n.executions, 3) AS avg_cpu_ms, round(b.cpu_us / 1000.0 / b.executions, 3) AS before_avg_cpu_ms,
       round((n.cpu_us / n.executions) / nullif(b.cpu_us / b.executions, 0), 2) AS cpu_ratio,
       round(n.logical_reads / n.executions, 1) AS avg_logical_reads, round(b.logical_reads / b.executions, 1) AS before_avg_logical_reads,
       round((n.duration_us / n.executions - b.duration_us / b.executions) * n.executions / 1000.0, 1) AS extra_duration_ms,
       cardinality(b.plan_ids) AS before_plans, n.last_execution
  FROM now_ n
  JOIN before b ON b.database_name = n.database_name AND b.query_id = n.query_id AND b.query_hash IS NOT DISTINCT FROM n.query_hash
  LEFT JOIN pgvigil.mssql_qs_query q ON q.instance_id = $1 AND q.database_name = n.database_name AND q.query_id = n.query_id
                                    AND q.query_hash IS NOT DISTINCT FROM n.query_hash
  LEFT JOIN pgvigil.mssql_qs_plan p ON p.instance_id = $1 AND p.database_name = n.database_name AND p.plan_id = n.plan_id
                                   AND p.plan_hash_n IS NOT DISTINCT FROM n.plan_hash_n
 WHERE n.executions > 0 AND b.executions > 0
   AND ((b.duration_us > 0 AND n.duration_us / n.executions >= 1000 AND n.duration_us / n.executions >= 1.5 * (b.duration_us / b.executions))
     OR (b.cpu_us > 0 AND n.cpu_us / n.executions >= 1000 AND n.cpu_us / n.executions >= 1.5 * (b.cpu_us / b.executions)))
 ORDER BY extra_duration_ms DESC NULLS LAST, n.database_name, n.query_id, n.query_hash, n.plan_id
 LIMIT 200`

// sqlMSSQLQSForced: every forced plan of the databases the last read listed ($2 the database, NULL = all).
const sqlMSSQLQSForced = `
SELECT p.database_name, p.query_id, p.plan_id, q.object_name, q.query_text AS query, p.forcing_type, p.force_failure_count,
       p.force_failure_reason, q.plan_count, p.last_execution AS plan_last_execution, q.last_execution AS query_last_execution,
       p.last_compile, p.query_hash, p.plan_hash, p.is_parallel, p.forced_seen, p.xml_state, p.snapshot_at
  FROM pgvigil.mssql_qs_plan p
  JOIN pgvigil.mssql_qs_store s ON s.instance_id = p.instance_id AND s.database_name = p.database_name
  LEFT JOIN pgvigil.mssql_qs_query q ON q.instance_id = p.instance_id AND q.database_name = p.database_name AND q.query_id = p.query_id
                                    AND q.query_hash IS NOT DISTINCT FROM p.query_hash
 WHERE p.instance_id = $1 AND p.is_forced AND ($2::text IS NULL OR p.database_name = $2)
 ORDER BY p.force_failure_count DESC NULLS LAST, p.database_name, p.query_id, p.plan_id`

// sqlMSSQLQSTuning: the recommendations the server lists now (first seen by the window's end), and the ones it
// stopped listing inside the window ($2 its start, $3 its end). The statement is the store's current query of
// that number: the server's list carries no hash to match it by.
const sqlMSSQLQSTuning = `
SELECT t.database_name, t.rec_name, t.rec_type, t.reason, t.rec_state, t.state_reason, t.score, t.valid_since, t.last_refresh,
       t.is_executable, t.is_revertable, t.executed_at, t.executed_by, t.reverted_at, t.reverted_by, t.query_id,
       t.regressed_plan_id, t.recommended_plan_id, q.object_name, q.query_text AS query, t.script,
       t.is_present, t.first_seen, t.snapshot_at
  FROM pgvigil.mssql_qs_tuning t
  LEFT JOIN pgvigil.mssql_qs_query q ON q.instance_id = t.instance_id AND q.database_name = t.database_name AND q.query_id = t.query_id
 WHERE t.instance_id = $1 AND t.first_seen <= $3 AND (t.is_present OR (t.snapshot_at > $2 AND t.snapshot_at <= $3))
   AND ($4::text IS NULL OR t.database_name = $4)
 ORDER BY t.is_present DESC, t.score DESC NULLS LAST, t.last_refresh DESC NULLS LAST, t.database_name, t.rec_name
 LIMIT 500`

const sqlMSSQLQSTuningOptions = `
SELECT o.database_name, o.option_name, o.desired_state, o.actual_state, o.reason, o.snapshot_at
  FROM pgvigil.mssql_qs_tuning_option o
 WHERE o.instance_id = $1 AND ($2::text IS NULL OR o.database_name = $2)
 ORDER BY o.database_name, o.option_name`

const sqlMSSQLQSChecks = `
SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_querystore_findings
 WHERE instance_id = $1
 ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END, check_name, object`

// one query ($2 the database, $3 the query id, $4 its hash: a cleared store gives the id to another statement)
const sqlMSSQLQSQueryOne = `
SELECT q.database_name, q.query_id, q.query_hash, q.object_name, q.query_text AS query, q.parameterization, q.plan_count,
       q.last_execution, q.first_seen, q.snapshot_at
  FROM pgvigil.mssql_qs_query q
 WHERE q.instance_id = $1 AND q.database_name = $2 AND q.query_id = $3 AND q.query_hash = $4`

const qsQueryWindow = `r.instance_id = $1 AND r.snapshot_at < $3 AND r.interval_end > $2 AND r.snapshot_at > $2::timestamptz - interval '1 day'
     AND r.database_name = $4 AND r.query_id = $5 AND r.query_hash = $6`

// the query's plans that ran in the window, each with what the store says of the plan (the same plan hash: a
// number reused after a clear is another plan)
const sqlMSSQLQSQueryPlans = `
WITH g AS (
  SELECT r.plan_id, r.plan_hash_n, sum(r.executions) AS executions, sum(r.failed) AS failed, sum(r.duration_us) AS duration_us,
         max(r.max_duration_us) AS max_duration_us, sum(r.cpu_us) AS cpu_us, sum(r.logical_reads) AS logical_reads,
         max(r.max_memory_pages) AS max_memory_pages, sum(r.wait_ms) AS wait_ms, max(r.max_dop) AS max_dop,
         count(DISTINCT r.snapshot_at) AS intervals, min(r.first_execution) AS first_execution, max(r.last_execution) AS last_execution
    FROM pgvigil.mssql_qs_runtime r
   WHERE ` + qsQueryWindow + `
   GROUP BY r.plan_id, r.plan_hash_n
)
SELECT g.plan_id, p.plan_hash, coalesce(p.is_forced, false) AS forced, p.forcing_type, p.force_failure_count, p.force_failure_reason,
       g.executions, g.failed, round(g.duration_us / 1000.0 / nullif(g.executions, 0), 3) AS avg_duration_ms,
       round(g.max_duration_us / 1000.0, 1) AS max_duration_ms, round(g.cpu_us / 1000.0 / nullif(g.executions, 0), 3) AS avg_cpu_ms,
       round(g.logical_reads / nullif(g.executions, 0), 1) AS avg_logical_reads, round(g.max_memory_pages * 8 / 1024.0, 1) AS max_memory_mb,
       g.wait_ms, g.max_dop, g.intervals, g.first_execution, g.last_execution,
       p.is_parallel, p.is_trivial, p.compatibility_level, p.count_compiles, p.initial_compile, p.last_compile,
       p.xml_state, p.xml_note, p.plan_xml_bytes, (p.plan_id IS NOT NULL) AS in_store
  FROM g
  LEFT JOIN pgvigil.mssql_qs_plan p ON p.instance_id = $1 AND p.database_name = $4 AND p.plan_id = g.plan_id
                                   AND p.plan_hash_n IS NOT DISTINCT FROM g.plan_hash_n
 ORDER BY g.duration_us DESC NULLS LAST, g.plan_id`

const sqlMSSQLQSQuerySeries = `
SELECT r.snapshot_at, r.plan_id, r.executions, round(r.duration_us / 1000.0 / nullif(r.executions, 0), 3) AS avg_duration_ms,
       round(r.cpu_us / 1000.0 / nullif(r.executions, 0), 3) AS avg_cpu_ms,
       round(r.logical_reads::numeric / nullif(r.executions, 0), 1) AS avg_logical_reads
  FROM pgvigil.mssql_qs_runtime r
 WHERE ` + qsQueryWindow + `
 ORDER BY r.snapshot_at, r.plan_id`

const sqlMSSQLQSPlanXML = `
SELECT p.plan_xml, i.name, p.query_id
  FROM pgvigil.mssql_qs_plan p JOIN pgvigil.instances i ON i.instance_id = p.instance_id
 WHERE p.instance_id = $1 AND p.database_name = $2 AND p.plan_id = $3`

// mssqlQSOrders are the Top list's orders; the first is the default.
var mssqlQSOrders = []string{"duration", "cpu", "reads", "memory", "waits", "executions"}

// mssqlQSViews: the parts each view of the page reads beside state and checks.
var mssqlQSViews = map[string][]string{
	"top": {"totals", "series", "top"}, "regressed": {"regressed"}, "forced": {"forced"},
	"tuning": {"tuning", "tuning_options"}, "state": {},
}

// a query or plan hash as the store writes it and QueryRows stores it: 0x and sixteen hex digits
var mssqlQSHash = regexp.MustCompile(`^0[xX][0-9A-Fa-f]{16}$`)

// mssqlQSStep is the series' step: a minute while the window draws about 120 points at that width, whole hours
// beyond it (an interval is 60 minutes unless the database says otherwise).
func mssqlQSStep(secs float64) int {
	step := perfStep(secs)
	if step <= 60 {
		return 60
	}
	return (step + 3599) / 3600 * 3600
}

// mssqlQSDatabase reads the db= of a Query Store route (a SQL Server database name: 128 characters); "" = none given.
func mssqlQSDatabase(r *http.Request, required bool) (string, error) {
	db := r.URL.Query().Get("db")
	switch {
	case db == "" && required:
		return "", errors.New("db must name the database")
	case len([]rune(db)) > 128:
		return "", errors.New("db is longer than a database name")
	case !utf8.ValidString(db) || strings.ContainsRune(db, 0):
		return "", errors.New("db is not a database name")
	}
	return db, nil
}

// orNull is a text argument, NULL when empty (an optional filter).
func orNull(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// MSSQLQueryStore is GET /api/mssql/querystore?instance=N[&from=&to=][&db=][&order=][&view=][&part=...].
func (s *Server) MSSQLQueryStore(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	dbName, err := mssqlQSDatabase(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	db := orNull(dbName)
	order := r.URL.Query().Get("order")
	if order == "" {
		order = mssqlQSOrders[0]
	}
	if !slices.Contains(mssqlQSOrders, order) {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("order must be one of %v", mssqlQSOrders))
		return
	}
	win := []any{id, from, to, db}
	parts := []part{
		{"state", sqlMSSQLQSState, []any{id}},
		{"totals", sqlMSSQLQSTotals, win},
		{"series", sqlMSSQLQSSeries, []any{id, from, to, db, mssqlQSStep(to.Sub(from).Seconds())}},
		{"top", sqlMSSQLQSTop, []any{id, from, to, db, order}},
		{"regressed", sqlMSSQLQSRegressed, win},
		{"forced", sqlMSSQLQSForced, []any{id, db}},
		{"tuning", sqlMSSQLQSTuning, win},
		{"tuning_options", sqlMSSQLQSTuningOptions, []any{id, db}},
		{"checks", sqlMSSQLQSChecks, []any{id}},
	}
	// a view reads its own parts: the Store state tab does not run the top list over the window
	if view := r.URL.Query().Get("view"); view != "" {
		own, ok := mssqlQSViews[view]
		if !ok {
			writeErr(w, http.StatusBadRequest, errors.New("view must be one of top, regressed, forced, tuning, state"))
			return
		}
		kept := parts[:0:0]
		for _, p := range parts {
			if p.name == "state" || p.name == "checks" || slices.Contains(own, p.name) {
				kept = append(kept, p)
			}
		}
		parts = kept
	}
	s.multiPart(w, r, parts)
}

// mssqlQSNumber reads a positive id parameter (a query or plan number of the store).
func mssqlQSNumber(r *http.Request, name string) (int64, error) {
	n, err := strconv.ParseInt(r.URL.Query().Get(name), 10, 64)
	if err != nil || n <= 0 {
		return 0, errors.New(name + " must be a positive number")
	}
	return n, nil
}

// MSSQLQueryStoreQuery is GET /api/mssql/querystore/query?instance=N&db=&query=<id>&hash=0x...[&from=&to=]: one
// query's text, its plans in the window and their line per interval. The hash is part of the query's name: after
// a cleared store the id alone would mix two statements.
func (s *Server) MSSQLQueryStoreQuery(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	db, err := mssqlQSDatabase(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	query, err := mssqlQSNumber(r, "query")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	hash := r.URL.Query().Get("hash")
	if !mssqlQSHash.MatchString(hash) {
		writeErr(w, http.StatusBadRequest, errors.New("hash must be the query's hash (0x and sixteen hex digits)"))
		return
	}
	hash = "0x" + strings.ToUpper(hash[2:])
	win := []any{id, from, to, db, query, hash}
	s.multiPart(w, r, []part{
		{"query", sqlMSSQLQSQueryOne, []any{id, db, query, hash}},
		{"plans", sqlMSSQLQSQueryPlans, win},
		{"series", sqlMSSQLQSQuerySeries, win},
	})
}

// MSSQLQueryStorePlan is GET /api/mssql/querystore/plan.sqlplan?instance=N&db=&plan=<id>: the plan's showplan XML
// as SQL Server wrote it, as a .sqlplan file (SSMS opens it as a graphical plan). 404 when none is stored: the
// instance's query_text policy is not "full" (a showplan carries the statement and its compiled parameter values),
// the plan is over the size a plan may take, or its XML has not been read yet.
func (s *Server) MSSQLQueryStorePlan(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	db, err := mssqlQSDatabase(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	plan, err := mssqlQSNumber(r, "plan")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var xml, name *string
	var query *int64
	rows, err := s.pool.Query(r.Context(), sqlMSSQLQSPlanXML, id, db, plan)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	defer rows.Close()
	if rows.Next() {
		if err := rows.Scan(&xml, &name, &query); err != nil {
			s.reply(w, r, nil, err)
			return
		}
	}
	if err := rows.Err(); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	if xml == nil || *xml == "" {
		writeErr(w, http.StatusNotFound, errors.New("no plan XML is stored for this plan"))
		return
	}
	var qid int64
	if query != nil {
		qid = *query
	}
	file := fmt.Sprintf("plan-%s-%s-q%d-p%d.sqlplan", safeFileName(deref(name)), safeFileName(db), qid, plan)
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="`+file+`"`)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if _, err := w.Write([]byte(*xml)); err != nil {
		s.log.Warn("api write failed", "path", r.URL.Path, "err", err)
	}
}
