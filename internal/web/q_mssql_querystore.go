package web

import (
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
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
//       regressed one row per query raised by pgvigil's duration test or PerformanceMonitor's cost, timeouts or
//                 errors test against base= 7d (default: the 7 days before the window) | prev | day | week
//                 (sqlMSSQLQSRegressed); regressed_skipped: the queries the split tests could not judge (rows
//                 read before 0126);
//       compare, compare_windows   with compare=prev|day|week (not part of a view: the page asks part=compare):
//                 PerformanceMonitor's compare by (database, query hash) and the two windows' coverage;
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

// sqlMSSQLQSTotals: wait_ms is NULL (not measured) where the server keeps no wait statistics (SQL Server 2016: the
// collector stores NULL, querystore.go qsNoWaitMS) and 0 over a window in which no plan ran (no interval, or only
// intervals stored without totals); the series' wait_ms likewise per step.
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
       coalesce(sum(iv.logical_reads), 0) AS logical_reads, CASE WHEN count(iv.executions) = 0 THEN 0 ELSE sum(iv.wait_ms) END AS wait_ms,
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
       CASE WHEN count(i.executions) = 0 THEN 0 ELSE sum(i.wait_ms) END AS wait_ms
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

// sqlMSSQLQSRegressed: PerformanceMonitor 3.12.0's Query Store regressions (QueryStoreRegressionBaseline.cs and
// QueryStoreRegressionRules.cs, MIT, Erik Darling, Darling Data LLC) beside pgvigil's own duration test, one row per
// query (database, query id and the query's hash as its rows were read: a cleared store gives the id to another
// statement, so a regression is judged within one window pair and never across a clear).
//
// A row (one kept plan in one store interval) is placed as PerformanceMonitor places it, by its last execution
// (QueryStoreRegressionBaseline.cs L770-781): recent = the rows of the intervals that overlap the window ($2, $3)
// whose last run is at or after its start; baseline = the rows whose last run is in [$5, $6): by default
// PerformanceMonitor's 7 continuous days before the window, else the window of equal length before it, the window
// 24 hours or 168 hours earlier (mssqlQSBase). An interval that starts before the window and ran its last run before
// it is not recent, so a run before the window is never counted in it. A query is raised by:
//
//	duration (pgvigil): one of its plans averages 1.5 times the query's average duration (or CPU) over the
//	  baseline, all execution types, or more, and at least 1,000 us (task 129's test, unchanged);
//	cost (PerformanceMonitor, word for word): its Regular CPU per run is more than 25 % above its baseline's and
//	  the rise times its recent Regular runs adds at least 1,000 ms of CPU over the window (CostTestSql);
//	timeouts / errors (PerformanceMonitor): at least 3 Aborted (Exception) runs in the window, and a per-hour rate
//	  at least 2 times the baseline's, or any where the baseline had none or holds no hours. Per hour divides by the
//	  window's clock hours from its start, or from the database's first stored interval when that is later (PM's
//	  base_fail_hours / recent_fail_hours).
//
// A query with no kept row in the baseline is 'no kept baseline' (left join): the cost and duration tests need one,
// the failure tests count it as none. A row stored before 0126 (or by an older collector) with failed > 0 holds no
// split ('not read apart'; told by the row itself, which also catches an older collector importing after 0126): the
// Regular figures and the failure counts of that side are unknown, and the cost and failure tests are not applied
// to the query (never read as 0). Severity: PerformanceMonitor's (a cost row by its Regular duration rise: over 100 %
// CRITICAL, 50 % HIGH, 25 % MEDIUM, else LOW; a timeouts / errors row HIGH at 5 times the baseline's rate or none
// before, else MEDIUM, never CRITICAL; a row with both takes the higher); a row raised by the duration test alone
// takes the cost bands on its plan's ratio. The order and the cap are PerformanceMonitor's: the cost rows first by
// their added duration (a row raised by the duration test alone ranks with them by its plan's extra duration), then
// the rest by their failed runs; 200 rows, timeouts / errors alone at most a third of them when other rows fill the
// rest (FailureShareDivisor). The task 129 columns stay: plan_id, new_plan, executions, avg_duration_ms and
// duration_ratio are the plan the duration test picked (else the plan with the most extra duration, then the
// slowest), before_* the query's baseline over every execution type.
// qsRegBase: Regressed's rows (recent rp per plan, rq per query; baseline bq per query) and each database's data start
// (fst, bounded: a database with rows before both windows starts before them, which is all the hours need). $1
// instance, $2 / $3 the window, $4 the database or NULL, $5 / $6 the baseline.
var qsRegBase = `
WITH fst AS (
  SELECT i.database_name, min(i.snapshot_at) AS held
    FROM pgvigil.mssql_qs_interval i
   WHERE i.instance_id = $1 AND ($4::text IS NULL OR i.database_name = $4)
     AND i.snapshot_at > least($2::timestamptz, $5::timestamptz) - interval '1 day'
   GROUP BY 1
), rp AS (
  SELECT r.database_name, r.query_id, r.query_hash, r.plan_id, r.plan_hash_n,
         sum(r.executions) AS executions, sum(r.duration_us) AS duration_us, sum(r.cpu_us) AS cpu_us,
         sum(r.logical_reads) AS logical_reads, max(r.last_execution) AS last_execution,
         sum(r.executions - coalesce(r.failed, 0)) AS reg_execs,
         sum(CASE WHEN coalesce(r.failed, 0) = 0 THEN r.cpu_us ELSE r.cpu_us - r.aborted_cpu_us - r.exception_cpu_us END) AS reg_cpu_us,
         sum(CASE WHEN coalesce(r.failed, 0) = 0 THEN r.duration_us ELSE r.duration_us - r.aborted_duration_us - r.exception_duration_us END) AS reg_dur_us,
         count(*) FILTER (WHERE coalesce(r.failed, 0) > 0 AND (r.aborted_executions IS NULL OR r.exception_executions IS NULL)) AS unsplit,
         max(r.snapshot_at) FILTER (WHERE coalesce(r.failed, 0) > 0 AND (r.aborted_executions IS NULL OR r.exception_executions IS NULL)) AS newest_unsplit,
         coalesce(sum(r.aborted_executions), 0) AS a_execs, sum(r.aborted_cpu_us) AS a_cpu, sum(r.aborted_duration_us) AS a_dur,
         coalesce(sum(r.exception_executions), 0) AS e_execs, sum(r.exception_cpu_us) AS e_cpu, sum(r.exception_duration_us) AS e_dur
    FROM pgvigil.mssql_qs_runtime r
   WHERE ` + fmt.Sprintf(qsWindow, "r") + ` AND r.last_execution >= $2 AND r.query_id IS NOT NULL
   GROUP BY 1, 2, 3, 4, 5
), rq AS (
  SELECT database_name, query_id, query_hash, sum(executions) AS executions, sum(duration_us) AS duration_us,
         sum(reg_execs) AS reg_execs, sum(reg_cpu_us) AS reg_cpu_us, sum(reg_dur_us) AS reg_dur_us, sum(unsplit) AS unsplit,
         max(newest_unsplit) AS newest_unsplit,
         sum(a_execs) AS a_execs, sum(a_cpu) AS a_cpu, sum(a_dur) AS a_dur, sum(e_execs) AS e_execs, sum(e_cpu) AS e_cpu, sum(e_dur) AS e_dur,
         count(*) AS plans, max(last_execution) AS last_execution
    FROM rp GROUP BY 1, 2, 3
), bq AS (
  SELECT r.database_name, r.query_id, r.query_hash,
         sum(r.executions) AS executions, sum(r.duration_us) AS duration_us, sum(r.cpu_us) AS cpu_us, sum(r.logical_reads) AS logical_reads,
         sum(r.executions - coalesce(r.failed, 0)) AS reg_execs,
         sum(CASE WHEN coalesce(r.failed, 0) = 0 THEN r.cpu_us ELSE r.cpu_us - r.aborted_cpu_us - r.exception_cpu_us END) AS reg_cpu_us,
         sum(CASE WHEN coalesce(r.failed, 0) = 0 THEN r.duration_us ELSE r.duration_us - r.aborted_duration_us - r.exception_duration_us END) AS reg_dur_us,
         count(*) FILTER (WHERE coalesce(r.failed, 0) > 0 AND (r.aborted_executions IS NULL OR r.exception_executions IS NULL)) AS unsplit,
         max(r.snapshot_at) FILTER (WHERE coalesce(r.failed, 0) > 0 AND (r.aborted_executions IS NULL OR r.exception_executions IS NULL)) AS newest_unsplit,
         coalesce(sum(r.aborted_executions), 0) AS a_execs, sum(r.aborted_cpu_us) AS a_cpu, sum(r.aborted_duration_us) AS a_dur,
         coalesce(sum(r.exception_executions), 0) AS e_execs, sum(r.exception_cpu_us) AS e_cpu, sum(r.exception_duration_us) AS e_dur,
         array_agg(DISTINCT r.plan_id) AS plan_ids
    FROM pgvigil.mssql_qs_runtime r
   WHERE r.instance_id = $1 AND r.last_execution >= $5 AND r.last_execution < $6
     AND r.snapshot_at < $6 AND r.snapshot_at > $5::timestamptz - interval '1 day'
     AND ($4::text IS NULL OR r.database_name = $4) AND r.query_id IS NOT NULL
   GROUP BY 1, 2, 3
)`

var sqlMSSQLQSRegressed = qsRegBase + `, pd AS (
  -- pgvigil's duration test per plan, and the plan each query's row names
  SELECT DISTINCT ON (p.database_name, p.query_id, p.query_hash)
         p.database_name, p.query_id, p.query_hash, p.plan_id, p.plan_hash_n, p.executions, p.logical_reads,
         round(p.duration_us / 1000.0 / nullif(p.executions, 0), 3) AS avg_duration_ms,
         round(p.cpu_us / 1000.0 / nullif(p.executions, 0), 3) AS avg_cpu_ms,
         round(p.logical_reads / nullif(p.executions, 0), 1) AS avg_logical_reads,
         round((p.duration_us / nullif(p.executions, 0)) / nullif(b.duration_us / nullif(b.executions, 0), 0), 2) AS duration_ratio,
         (p.duration_us / nullif(p.executions, 0)) / nullif(b.duration_us / nullif(b.executions, 0), 0) AS duration_ratio_x,
         round((p.cpu_us / nullif(p.executions, 0)) / nullif(b.cpu_us / nullif(b.executions, 0), 0), 2) AS cpu_ratio,
         (b.plan_ids IS NULL OR NOT (p.plan_id = ANY (b.plan_ids))) AS new_plan,
         round((p.duration_us / nullif(p.executions, 0) - b.duration_us / nullif(b.executions, 0)) * p.executions / 1000.0, 1) AS extra_duration_ms,
         coalesce(p.executions > 0 AND b.executions > 0
           AND ((b.duration_us > 0 AND p.duration_us / p.executions >= 1000 AND p.duration_us / p.executions >= 1.5 * (b.duration_us / b.executions))
             OR (b.cpu_us > 0 AND p.cpu_us / p.executions >= 1000 AND p.cpu_us / p.executions >= 1.5 * (b.cpu_us / b.executions))), false) AS is_duration
    FROM rp p
    LEFT JOIN bq b ON b.database_name = p.database_name AND b.query_id = p.query_id AND b.query_hash IS NOT DISTINCT FROM p.query_hash
   ORDER BY p.database_name, p.query_id, p.query_hash, is_duration DESC,
            (p.duration_us / nullif(p.executions, 0) - b.duration_us / nullif(b.executions, 0)) * p.executions DESC NULLS LAST,
            p.duration_us / nullif(p.executions, 0) DESC NULLS LAST, p.plan_id
), j AS (
  SELECT q.database_name, q.query_id, q.query_hash, q.plans AS recent_plans, cardinality(b.plan_ids) AS base_plans,
         b.query_id IS NOT NULL AS has_baseline, q.unsplit AS recent_unsplit, coalesce(b.unsplit, 0) AS base_unsplit,
         q.last_execution, b.executions AS before_executions,
         round(b.duration_us / 1000.0 / nullif(b.executions, 0), 3) AS before_avg_duration_ms,
         round(b.cpu_us / 1000.0 / nullif(b.executions, 0), 3) AS before_avg_cpu_ms,
         round(b.logical_reads / nullif(b.executions, 0), 1) AS before_avg_logical_reads,
         -- PerformanceMonitor's Regular figures: per run, ms; unknown (NULL) on a side with a row not read apart
         CASE WHEN q.unsplit = 0 THEN q.reg_execs END AS recent_execs,
         CASE WHEN coalesce(b.unsplit, 0) = 0 THEN coalesce(b.reg_execs, 0) END AS base_execs,
         CASE WHEN q.unsplit = 0 THEN q.reg_dur_us / 1000.0 / nullif(q.reg_execs, 0) END AS recent_dur_ms,
         CASE WHEN coalesce(b.unsplit, 0) = 0 THEN b.reg_dur_us / 1000.0 / nullif(b.reg_execs, 0) END AS base_dur_ms,
         CASE WHEN q.unsplit = 0 THEN q.reg_cpu_us / 1000.0 / nullif(q.reg_execs, 0) END AS recent_cpu_ms,
         CASE WHEN coalesce(b.unsplit, 0) = 0 THEN b.reg_cpu_us / 1000.0 / nullif(b.reg_execs, 0) END AS base_cpu_ms,
         CASE WHEN q.unsplit = 0 THEN q.a_execs END AS recent_aborted_execs,
         CASE WHEN coalesce(b.unsplit, 0) = 0 THEN coalesce(b.a_execs, 0) END AS base_aborted_execs,
         CASE WHEN q.unsplit = 0 THEN q.e_execs END AS recent_exception_execs,
         CASE WHEN coalesce(b.unsplit, 0) = 0 THEN coalesce(b.e_execs, 0) END AS base_exception_execs,
         q.a_cpu / 1000.0 / nullif(q.a_execs, 0) AS recent_aborted_cpu_ms, b.a_cpu / 1000.0 / nullif(b.a_execs, 0) AS base_aborted_cpu_ms,
         q.a_dur / 1000.0 / nullif(q.a_execs, 0) AS recent_aborted_dur_ms, b.a_dur / 1000.0 / nullif(b.a_execs, 0) AS base_aborted_dur_ms,
         q.e_cpu / 1000.0 / nullif(q.e_execs, 0) AS recent_exception_cpu_ms, b.e_cpu / 1000.0 / nullif(b.e_execs, 0) AS base_exception_cpu_ms,
         q.e_dur / 1000.0 / nullif(q.e_execs, 0) AS recent_exception_dur_ms, b.e_dur / 1000.0 / nullif(b.e_execs, 0) AS base_exception_dur_ms,
         greatest(extract(epoch FROM ($6::timestamptz - greatest($5::timestamptz, f.held))) / 3600.0, 0)::float8 AS base_hours,
         greatest(extract(epoch FROM ($3::timestamptz - greatest($2::timestamptz, f.held))) / 3600.0, 0)::float8 AS recent_hours
    FROM rq q
    LEFT JOIN bq b ON b.database_name = q.database_name AND b.query_id = q.query_id AND b.query_hash IS NOT DISTINCT FROM q.query_hash
    LEFT JOIN fst f ON f.database_name = q.database_name
), fl AS (
  SELECT j.*, pd.plan_id, pd.plan_hash_n, pd.executions, pd.avg_duration_ms, pd.avg_cpu_ms, pd.avg_logical_reads, pd.duration_ratio, pd.duration_ratio_x,
         pd.cpu_ratio, pd.new_plan, pd.extra_duration_ms, pd.is_duration,
         (j.recent_dur_ms - j.base_dur_ms) * 100.0 / nullif(j.base_dur_ms, 0) AS duration_regression_percent,
         (j.recent_cpu_ms - j.base_cpu_ms) * 100.0 / nullif(j.base_cpu_ms, 0) AS cpu_regression_percent,
         COALESCE((j.recent_cpu_ms - j.base_cpu_ms) * 100.0 / NULLIF(j.base_cpu_ms, 0) > 25
              AND (j.recent_cpu_ms - j.base_cpu_ms) * j.recent_execs >= 1000, false) AS is_cost,
         COALESCE(j.recent_aborted_execs >= 3
              AND (j.base_aborted_execs = 0 OR j.base_hours = 0
                   OR (j.recent_aborted_execs / NULLIF(j.recent_hours, 0)) >= 2 * (j.base_aborted_execs / NULLIF(j.base_hours, 0))), false) AS is_timeouts,
         COALESCE(j.recent_exception_execs >= 3
              AND (j.base_exception_execs = 0 OR j.base_hours = 0
                   OR (j.recent_exception_execs / NULLIF(j.recent_hours, 0)) >= 2 * (j.base_exception_execs / NULLIF(j.base_hours, 0))), false) AS is_errors
    FROM j JOIN pd ON pd.database_name = j.database_name AND pd.query_id = j.query_id AND pd.query_hash IS NOT DISTINCT FROM j.query_hash
), qu AS (
  SELECT f.*,
         greatest(
           CASE WHEN NOT f.is_cost THEN 0 WHEN f.duration_regression_percent > 100 THEN 4 WHEN f.duration_regression_percent > 50 THEN 3
                WHEN f.duration_regression_percent > 25 THEN 2 ELSE 1 END,
           -- the duration test's bands only for a row nothing of PerformanceMonitor's raised, on the unrounded ratio
           CASE WHEN NOT f.is_duration OR f.is_cost OR f.is_timeouts OR f.is_errors THEN 0 WHEN f.duration_ratio_x > 2 THEN 4
                WHEN f.duration_ratio_x > 1.5 THEN 3 WHEN f.duration_ratio_x > 1.25 THEN 2 ELSE 1 END,
           CASE WHEN NOT f.is_timeouts THEN 0
                WHEN f.base_aborted_execs = 0 OR f.base_hours = 0
                     OR (f.recent_aborted_execs / NULLIF(f.recent_hours, 0)) >= 5 * (f.base_aborted_execs / NULLIF(f.base_hours, 0)) THEN 3 ELSE 2 END,
           CASE WHEN NOT f.is_errors THEN 0
                WHEN f.base_exception_execs = 0 OR f.base_hours = 0
                     OR (f.recent_exception_execs / NULLIF(f.recent_hours, 0)) >= 5 * (f.base_exception_execs / NULLIF(f.base_hours, 0)) THEN 3 ELSE 2 END) AS sev,
         (f.recent_dur_ms - f.base_dur_ms) * f.recent_execs AS additional_duration_ms,
         (f.is_cost OR f.is_duration) AS is_slower
    FROM fl f
   WHERE f.is_cost OR f.is_duration OR f.is_timeouts OR f.is_errors
), ranked AS (
  SELECT q.*,
         row_number() OVER (PARTITION BY q.is_slower
                            ORDER BY q.is_cost DESC,
                                     CASE WHEN q.is_cost THEN coalesce(q.additional_duration_ms, 0) WHEN q.is_slower THEN coalesce(q.extra_duration_ms, 0)
                                          ELSE q.recent_aborted_execs + q.recent_exception_execs END DESC,
                                     q.database_name, q.query_id, q.query_hash) AS class_rn,
         count(*) FILTER (WHERE q.is_slower) OVER () AS slower_total, count(*) FILTER (WHERE NOT q.is_slower) OVER () AS failure_total
    FROM qu q
), slots AS (
  SELECT greatest(least(max(failure_total), 200 / 3), least(max(failure_total), 200 - max(slower_total))) AS failure_slots FROM ranked
)
SELECT r.database_name, r.query_id, r.query_hash, qq.object_name, qq.query_text AS query,
       CASE r.sev WHEN 4 THEN 'CRITICAL' WHEN 3 THEN 'HIGH' WHEN 2 THEN 'MEDIUM' ELSE 'LOW' END AS severity,
       array_to_string(array_remove(ARRAY[CASE WHEN r.is_duration THEN 'duration' END, CASE WHEN r.is_cost THEN 'cost' END,
                                          CASE WHEN r.is_timeouts THEN 'timeouts' END, CASE WHEN r.is_errors THEN 'errors' END], NULL), ', ') AS raised_by,
       r.plan_id, r.new_plan, coalesce(p.is_forced, false) AS forced, r.executions, r.before_executions,
       r.avg_duration_ms, r.before_avg_duration_ms, r.duration_ratio, r.avg_cpu_ms, r.before_avg_cpu_ms, r.cpu_ratio,
       r.avg_logical_reads, r.before_avg_logical_reads, r.extra_duration_ms, r.base_plans AS before_plans, r.recent_plans,
       r.has_baseline, r.recent_unsplit, r.base_unsplit,
       r.recent_execs, r.base_execs, round(r.recent_dur_ms::numeric, 3) AS recent_dur_ms, round(r.base_dur_ms::numeric, 3) AS base_dur_ms,
       round(r.duration_regression_percent::numeric, 1) AS duration_regression_percent,
       round(r.recent_cpu_ms::numeric, 3) AS recent_cpu_ms, round(r.base_cpu_ms::numeric, 3) AS base_cpu_ms,
       round(r.cpu_regression_percent::numeric, 1) AS cpu_regression_percent, round(r.additional_duration_ms::numeric, 1) AS additional_duration_ms,
       r.recent_aborted_execs AS recent_timeouts, r.recent_exception_execs AS recent_errors,
       r.base_aborted_execs, r.recent_aborted_execs, round(r.base_aborted_cpu_ms::numeric, 3) AS base_aborted_cpu_ms,
       round(r.recent_aborted_cpu_ms::numeric, 3) AS recent_aborted_cpu_ms, round(r.base_aborted_dur_ms::numeric, 3) AS base_aborted_dur_ms,
       round(r.recent_aborted_dur_ms::numeric, 3) AS recent_aborted_dur_ms,
       round((r.base_aborted_execs / nullif(r.base_hours, 0))::numeric, 2) AS base_aborted_per_hour,
       round((r.recent_aborted_execs / nullif(r.recent_hours, 0))::numeric, 2) AS recent_aborted_per_hour,
       r.base_exception_execs, r.recent_exception_execs, round(r.base_exception_cpu_ms::numeric, 3) AS base_exception_cpu_ms,
       round(r.recent_exception_cpu_ms::numeric, 3) AS recent_exception_cpu_ms, round(r.base_exception_dur_ms::numeric, 3) AS base_exception_dur_ms,
       round(r.recent_exception_dur_ms::numeric, 3) AS recent_exception_dur_ms,
       round((r.base_exception_execs / nullif(r.base_hours, 0))::numeric, 2) AS base_exception_per_hour,
       round((r.recent_exception_execs / nullif(r.recent_hours, 0))::numeric, 2) AS recent_exception_per_hour,
       round((r.base_execs / nullif(r.base_hours, 0))::numeric, 1) AS base_regular_per_hour,
       round((r.recent_execs / nullif(r.recent_hours, 0))::numeric, 1) AS recent_regular_per_hour,
       round(r.base_hours::numeric, 2) AS base_hours, round(r.recent_hours::numeric, 2) AS recent_hours, r.last_execution
  FROM ranked r CROSS JOIN slots s
  LEFT JOIN pgvigil.mssql_qs_query qq ON qq.instance_id = $1 AND qq.database_name = r.database_name AND qq.query_id = r.query_id
                                     AND qq.query_hash IS NOT DISTINCT FROM r.query_hash
  LEFT JOIN pgvigil.mssql_qs_plan p ON p.instance_id = $1 AND p.database_name = r.database_name AND p.plan_id = r.plan_id
                                   AND p.plan_hash_n IS NOT DISTINCT FROM r.plan_hash_n
 WHERE (r.is_slower AND r.class_rn <= 200 - s.failure_slots) OR (NOT r.is_slower AND r.class_rn <= s.failure_slots)
 ORDER BY r.is_slower DESC, r.class_rn, r.database_name, r.query_id, r.query_hash`

// sqlMSSQLQSRegressedSkipped: the queries Regressed could not judge: a query of the window (rq) with a row not read
// apart on either side (rows stored before 0126): the cost and failure tests were not applied to it. The page says
// how many, and the newest such row.
var sqlMSSQLQSRegressedSkipped = qsRegBase + `
SELECT count(*) AS queries, max(greatest(q.newest_unsplit, b.newest_unsplit)) AS newest_unsplit
  FROM rq q
  LEFT JOIN bq b ON b.database_name = q.database_name AND b.query_id = q.query_id AND b.query_hash IS NOT DISTINCT FROM q.query_hash
 WHERE q.unsplit > 0 OR coalesce(b.unsplit, 0) > 0`

// qsBefore is qsWindow shifted back $5 seconds: the compare's earlier window; with the placement by the last run
// (sqlMSSQLQSCompare) a row is in it when its last run is in [$2 - $5, $3 - $5).
const qsBefore = `%[1]s.instance_id = $1 AND %[1]s.snapshot_at < $3::timestamptz - make_interval(secs => $5)
     AND %[1]s.interval_end > $2::timestamptz - make_interval(secs => $5)
     AND %[1]s.snapshot_at > $2::timestamptz - make_interval(secs => $5) - interval '1 day' AND ($4::text IS NULL OR %[1]s.database_name = $4)
     AND %[1]s.last_execution >= $2::timestamptz - make_interval(secs => $5) AND %[1]s.last_execution < $3::timestamptz - make_interval(secs => $5)`

// sqlMSSQLQSCompare: PerformanceMonitor's compare (top-compare.js, MIT, Erik Darling, Darling Data LLC) on the
// stored rows: the window ($2, $3) against the same span $5 seconds earlier (Previous period, Yesterday 24 h, Last
// week 168 h: UTC instants, as PerformanceMonitor shifts them), one read over every stored row of both windows,
// keyed by (database, query hash) as PerformanceMonitor's (rows with no hash: the plan left the store between the
// read's two steps; counted by the windows part and left out). A row is placed by its last run, as Regressed's
// (PerformanceMonitor's placement): in the window when it ran last at or after its start, in the earlier window when
// its last run is inside that one; with Previous period an interval that straddles the window's start is in one
// window only. NEW and GONE come from that whole aggregate; the rows
// shown are the union of each window's first 100 by duration (PerformanceMonitor's COMPARE_TOP), NEW first, GONE
// last, then by the rise of the average duration (its sort). The store keeps each interval's top plans only, so:
//
//	new              no kept row before, and the query's first plan was compiled at or after the earlier window's end
//	                 (mssql_qs_plan.initial_compile): it did not exist then;
//	not kept before  no kept row before, compiled earlier: it may have run then below the kept plans;
//	not kept now     no kept row in the window (the store's last execution is not read for a query out of the lists,
//	                 so 'gone' is never claimed).
//
// The deltas are percent of the earlier figure, NULL where it was 0; the averages' delta is also NULL on a row with
// no kept row now (pgvigil's choice: it may only have fallen below the kept plans; PerformanceMonitor shows -100 %
// there). n_* count the whole aggregate, before the display cut.
var sqlMSSQLQSCompare = `
WITH cur AS (
  SELECT r.database_name, r.query_hash, sum(r.executions) AS e, sum(r.duration_us) AS d, sum(r.cpu_us) AS c
    FROM pgvigil.mssql_qs_runtime r
   WHERE ` + fmt.Sprintf(qsWindow, "r") + ` AND r.last_execution >= $2 AND r.query_hash IS NOT NULL
   GROUP BY 1, 2
), bef AS (
  SELECT r.database_name, r.query_hash, sum(r.executions) AS e, sum(r.duration_us) AS d, sum(r.cpu_us) AS c
    FROM pgvigil.mssql_qs_runtime r
   WHERE ` + fmt.Sprintf(qsBefore, "r") + ` AND r.query_hash IS NOT NULL
   GROUP BY 1, 2
), comp AS (
  SELECT p.database_name, p.query_hash, min(p.initial_compile) AS first_compile
    FROM pgvigil.mssql_qs_plan p
   WHERE p.instance_id = $1 AND ($4::text IS NULL OR p.database_name = $4) AND p.query_hash IS NOT NULL
   GROUP BY 1, 2
), j AS (
  SELECT coalesce(c.database_name, b.database_name) AS database_name, coalesce(c.query_hash, b.query_hash) AS query_hash,
         coalesce(c.e, 0) AS now_e, c.d AS now_d, c.c AS now_c, coalesce(b.e, 0) AS bef_e, b.d AS bef_d, b.c AS bef_c
    FROM cur c FULL JOIN bef b ON b.database_name = c.database_name AND b.query_hash = c.query_hash
), k AS (
  SELECT j.*, m.first_compile,
         CASE WHEN j.now_e > 0 AND j.bef_e = 0 THEN
                CASE WHEN m.first_compile >= $3::timestamptz - make_interval(secs => $5) THEN 'new' ELSE 'not kept before' END
              WHEN j.now_e = 0 AND j.bef_e > 0 THEN 'not kept now' ELSE '' END AS status,
         row_number() OVER (ORDER BY j.now_d DESC NULLS LAST, j.database_name, j.query_hash) AS rn_now,
         row_number() OVER (ORDER BY j.bef_d DESC NULLS LAST, j.database_name, j.query_hash) AS rn_bef
    FROM j LEFT JOIN comp m ON m.database_name = j.database_name AND m.query_hash = j.query_hash
), n AS (
  SELECT k.*, count(*) OVER () AS n_keys, count(*) FILTER (WHERE k.status = '') OVER () AS n_both,
         count(*) FILTER (WHERE k.status = 'new') OVER () AS n_new, count(*) FILTER (WHERE k.status = 'not kept before') OVER () AS n_not_kept_before,
         count(*) FILTER (WHERE k.status = 'not kept now') OVER () AS n_not_kept_now
    FROM k
), o AS (
  SELECT n.* FROM n WHERE (n.rn_now <= 100 AND n.now_e > 0) OR (n.rn_bef <= 100 AND n.bef_e > 0)
), t AS (
  SELECT DISTINCT ON (q.database_name, q.query_hash) q.database_name, q.query_hash, q.object_name, q.query_text
    FROM pgvigil.mssql_qs_query q JOIN o ON o.database_name = q.database_name AND o.query_hash = q.query_hash
   WHERE q.instance_id = $1
   ORDER BY q.database_name, q.query_hash, q.last_execution DESC NULLS LAST, q.query_id DESC
)
SELECT o.database_name, o.query_hash, t.object_name, t.query_text AS query, o.status, o.first_compile,
       o.now_e AS executions, o.bef_e AS before_executions,
       round(o.now_d / 1000.0, 1) AS duration_ms, round(o.bef_d / 1000.0, 1) AS before_duration_ms,
       round(o.now_d / 1000.0 / nullif(o.now_e, 0), 3) AS avg_duration_ms, round(o.bef_d / 1000.0 / nullif(o.bef_e, 0), 3) AS before_avg_duration_ms,
       round(o.now_c / 1000.0 / nullif(o.now_e, 0), 3) AS avg_cpu_ms, round(o.bef_c / 1000.0 / nullif(o.bef_e, 0), 3) AS before_avg_cpu_ms,
       round(100.0 * (o.now_e - o.bef_e) / nullif(o.bef_e, 0), 1) AS executions_pct,
       round(100.0 * (o.now_d / nullif(o.now_e, 0) - o.bef_d / nullif(o.bef_e, 0)) / nullif(o.bef_d / nullif(o.bef_e, 0), 0), 1) AS avg_duration_pct,
       round(100.0 * (o.now_c / nullif(o.now_e, 0) - o.bef_c / nullif(o.bef_e, 0)) / nullif(o.bef_c / nullif(o.bef_e, 0), 0), 1) AS avg_cpu_pct,
       o.n_keys, o.n_both, o.n_new, o.n_not_kept_before, o.n_not_kept_now
  FROM o LEFT JOIN t ON t.database_name = o.database_name AND t.query_hash = o.query_hash
 ORDER BY CASE WHEN o.status IN ('new', 'not kept before') THEN 0 WHEN o.status = 'not kept now' THEN 2 ELSE 1 END,
          (o.now_d / nullif(o.now_e, 0) - o.bef_d / nullif(o.bef_e, 0)) / nullif(o.bef_d / nullif(o.bef_e, 0), 0) DESC NULLS LAST,
          o.now_d DESC NULLS LAST, o.database_name, o.query_hash`

// sqlMSSQLQSCompareWindows: the two windows of the compare, how much of each the stored intervals cover (the
// distinct intervals of the databases read, each cut to the window: a store writes no interval for a minute in
// which nothing ran, so this is activity, not coverage), whether they overlap (a shift shorter than the window), the
// coverage word by where the stored data starts (PerformanceMonitor's effective start; q_compare.go's words): 'ok'
// when it starts at or before the earlier window, 'partial' inside it, 'no baseline' after it; and the window's rows
// without a query hash.
var sqlMSSQLQSCompareWindows = `
WITH w AS (
  SELECT $2::timestamptz AS now_from, $3::timestamptz AS now_to,
         $2::timestamptz - make_interval(secs => $5) AS before_from, $3::timestamptz - make_interval(secs => $5) AS before_to
), iv AS (
  SELECT DISTINCT i.snapshot_at, i.interval_end FROM pgvigil.mssql_qs_interval i, w
   WHERE i.instance_id = $1 AND i.snapshot_at < w.now_to AND i.interval_end > least(w.now_from, w.before_from)
     AND i.snapshot_at > least(w.now_from, w.before_from) - interval '1 day' AND ($4::text IS NULL OR i.database_name = $4)
), st AS (
  -- bounded: data before the earlier window's start is all 'ok' needs
  SELECT min(i.snapshot_at) AS held FROM pgvigil.mssql_qs_interval i, w
   WHERE i.instance_id = $1 AND ($4::text IS NULL OR i.database_name = $4) AND i.snapshot_at > w.before_from - interval '1 day'
), c AS (
  SELECT count(*) FILTER (WHERE iv.snapshot_at < w.now_to AND iv.interval_end > w.now_from) AS now_intervals,
         count(*) FILTER (WHERE iv.snapshot_at < w.before_to AND iv.interval_end > w.before_from) AS before_intervals,
         coalesce(sum(greatest(extract(epoch FROM least(iv.interval_end, w.now_to) - greatest(iv.snapshot_at, w.now_from)), 0)), 0)::float8 AS now_covered_secs,
         coalesce(sum(greatest(extract(epoch FROM least(iv.interval_end, w.before_to) - greatest(iv.snapshot_at, w.before_from)), 0)), 0)::float8 AS before_covered_secs
    FROM w LEFT JOIN iv ON true
)
SELECT w.now_from, w.now_to, w.before_from, w.before_to, $5::float8 < extract(epoch FROM w.now_to - w.now_from) AS overlap,
       c.now_intervals, c.before_intervals, c.now_covered_secs, c.before_covered_secs,
       st.held AS data_from,
       CASE WHEN st.held IS NULL OR st.held >= w.before_to THEN 'no baseline' WHEN st.held <= w.before_from THEN 'ok' ELSE 'partial' END AS coverage,
       (SELECT count(*) FROM pgvigil.mssql_qs_runtime r WHERE ` + fmt.Sprintf(qsWindow, "r") + ` AND r.query_hash IS NULL) AS no_hash_rows
  FROM w CROSS JOIN c CROSS JOIN st`

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
	"top": {"totals", "series", "top"}, "regressed": {"regressed", "regressed_skipped"}, "forced": {"forced"},
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

// mssqlQSBase is Regressed's baseline window (base=): ” or '7d' PerformanceMonitor's 7 continuous days before the
// window (DarlingQueryStoreRegressionReader.cs:55); 'prev' the window of equal length before it (task 129's);
// 'day' / 'week' the window 24 / 168 hours earlier (the compare's shifts).
func mssqlQSBase(base string, from, to time.Time) (time.Time, time.Time, error) {
	switch base {
	case "", "7d":
		return from.Add(-7 * 24 * time.Hour), from, nil
	case "prev":
		return from.Add(-to.Sub(from)), from, nil
	case "day", "week":
		shift, _, _ := compareShift(base, from, to)
		d := time.Duration(shift * float64(time.Second))
		return from.Add(-d), to.Add(-d), nil
	}
	return time.Time{}, time.Time{}, errors.New("base must be one of 7d, prev, day, week")
}

// compareShift reads compare= (PerformanceMonitor's compare picks and DBA Dash's Previous Period): ” off; 'prev'
// the window's own length; 'day' 24 hours; 'week' 168 hours (fixed spans of UTC instants: across a change of the
// clocks in the viewer's zone the earlier window reads an hour off on the wall clock, and the page prints both).
func compareShift(v string, from, to time.Time) (float64, bool, error) {
	switch v {
	case "":
		return 0, false, nil
	case "prev":
		return to.Sub(from).Seconds(), true, nil
	case "day":
		return 24 * 3600, true, nil
	case "week":
		return 7 * 24 * 3600, true, nil
	}
	return 0, false, errors.New("compare must be one of prev, day, week")
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
	baseFrom, baseTo, err := mssqlQSBase(r.URL.Query().Get("base"), from, to)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	win := []any{id, from, to, db}
	parts := []part{
		{"state", sqlMSSQLQSState, []any{id}},
		{"totals", sqlMSSQLQSTotals, win},
		{"series", sqlMSSQLQSSeries, []any{id, from, to, db, mssqlQSStep(to.Sub(from).Seconds())}},
		{"top", sqlMSSQLQSTop, []any{id, from, to, db, order}},
		{"regressed", sqlMSSQLQSRegressed, []any{planEach, id, from, to, db, baseFrom, baseTo}},
		{"regressed_skipped", sqlMSSQLQSRegressedSkipped, []any{planEach, id, from, to, db, baseFrom, baseTo}},
		{"forced", sqlMSSQLQSForced, []any{id, db}},
		{"tuning", sqlMSSQLQSTuning, win},
		{"tuning_options", sqlMSSQLQSTuningOptions, []any{id, db}},
		{"checks", sqlMSSQLQSChecks, []any{id}},
	}
	// the compare reads both windows: only when a shift is asked for (the page asks for it apart, part=compare)
	if shift, on, err := compareShift(r.URL.Query().Get("compare"), from, to); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	} else if on {
		parts = append(parts, part{"compare", sqlMSSQLQSCompare, []any{planEach, id, from, to, db, shift}},
			part{"compare_windows", sqlMSSQLQSCompareWindows, []any{planEach, id, from, to, db, shift}})
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
