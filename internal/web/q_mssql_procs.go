package web

import (
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// The Procedures tab of a SQL Server instance (task 130; DBA Dash's Object Execution): what each stored procedure
// did over the window, from the differences of sys.dm_exec_procedure_stats between two reads (mssql_procstats,
// every five minutes; 0084).
//
//	GET /api/mssql/procs?instance=N[&from=&to=][&db=<database id>][&db_id=&object=][&part=...][&types=&search=]
//	  objects     (part=objects only) the procedures, functions and triggers in one list (P25 Object Execution)
//	  state       the mssql_procstats collection's last run
//	  reads       the reads of the window that took differences: how many, the seconds they cover
//	  databases   the databases with a procedure that ran in the window (the page's filter), each under one name
//	  totals      the window's sums over every procedure (db= one database's), whatever the grid's limit
//	  procs       one row per procedure (db= keeps one database's): executions, per minute over the covered
//	              time and per minute in its busiest read, CPU, duration, logical and physical reads and writes, each
//	              as a total and per execution; the CPU and the duration also as ms per second of the covered time.
//	              The most duration first; 2,000 at most.
//	  series      the window in about 120 steps (five minutes at least): executions per second, CPU ms per second
//	              and duration ms per second over all procedures (db= keeps one database's)
//	  intervals   with db_id= and object=: that procedure's own reads, newest first (1,000 at most)
//	  history     with db_id= and object=: that procedure in about 120 steps: PerformanceMonitor's four procedure
//	              history metrics (sqlMSSQLProcHistory)
//	  compare, compare_windows   with compare=prev|day|week: PerformanceMonitor's compare of the window against
//	              the same span earlier, and the two windows' reads (sqlMSSQLProcCompare)
//	  func_state  the mssql_funcstats collection's last run
//	  func_reads  that collection's reads of the window, as reads (sqlMSSQLFuncReads)
//	  functions   the scalar functions that ran without inlining, as procs, with the inlineability mark (sqlMSSQLFuncs)
//	  triggers    the triggers, as procs, with the scope of a DDL or logon trigger (sqlMSSQLTriggers)
//
// The extremes (0342): min_ / max_cpu_ms, _duration_ms, _logical_reads, _physical_reads, _logical_writes and _spills -
// the smallest and the largest single execution the server kept for the plans that ran in the window, each since
// the plan was cached (not the window's own smallest and largest); NULL: not read (the server has no such column, or
// the reads came before 0342).
//
// spills (0126): total_spills' pages over the window's reads that had the figure (spill_reads of intervals; none
// at all = NULL: the server has no total_spills, SQL Server 2016 SP2 / 2017 CU3 on, or the reads came before
// 0126); avg_spills over those reads' executions (PerformanceMonitor's Avg Spilled Pages, DarlingMcpDataTools.cs:1103).
//
// A figure is what ran between two reads. A procedure compiled, run and dropped from the plan cache between two
// reads is in no read, and the executions of a plan the cache dropped since the read before are lost with it.

const sqlMSSQLProcReads = `
SELECT count(*) AS reads, coalesce(sum(r.interval_secs), 0)::float8 AS covered_secs, min(r.snapshot_at) AS first_read, max(r.snapshot_at) AS last_read
  FROM pgvigil.mssql_proc_read r
 WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3`

// procDBNames: one name per database of the window, for the filter list, the grid and the chart alike: the newest
// name read (a read that gave up on a lock stores none), else 'database <id>'. $1 instance, $2 and $3 the window.
const procDBNames = `
  SELECT DISTINCT ON (s.database_id) s.database_id, coalesce(s.database_name, 'database ' || s.database_id) AS database
    FROM pgvigil.mssql_proc_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
   ORDER BY s.database_id, (s.database_name IS NULL), s.snapshot_at DESC`

// sqlMSSQLProcDatabases: the filter's databases - each where a procedure ran, and each where only functions or
// triggers ran (procs 0: the one filter narrows the three grids).
const sqlMSSQLProcDatabases = `
WITH dbn AS (` + procDBNames + `), g AS (
  SELECT s.database_id, s.object_id, sum(s.executions) AS e
    FROM pgvigil.mssql_proc_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
   GROUP BY 1, 2
), p AS (
  SELECT n.database_id, n.database, count(*) AS procs, sum(g.e)::bigint AS executions
    FROM g JOIN dbn n ON n.database_id = g.database_id
   GROUP BY n.database_id, n.database
), fdb AS (` + funcDBNames + `)
SELECT p.database_id, p.database, p.procs, p.executions FROM p
UNION ALL
SELECT f.database_id, f.database, 0::bigint, 0::bigint FROM fdb f WHERE NOT EXISTS (SELECT 1 FROM p WHERE p.database_id = f.database_id)
 ORDER BY 2, 1`

// sqlMSSQLProcs: $4 the database's id, NULL = every database. A name read in one interval and not in another (the
// read gave up on a lock) keeps the name: max() skips the NULL.
const sqlMSSQLProcs = `
WITH dbn AS (` + procDBNames + `), cover AS (
  SELECT coalesce(sum(r.interval_secs), 0)::float8 AS secs FROM pgvigil.mssql_proc_read r
   WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
), p AS (
  SELECT s.database_id, s.object_id,
         max(s.schema_name) AS schema_name, max(s.object_name) AS object_name, max(s.type_desc) AS type_desc,
         sum(s.executions)::bigint AS executions, sum(s.cpu_us)::bigint AS cpu_us, sum(s.duration_us)::bigint AS duration_us,
         sum(s.logical_reads)::bigint AS logical_reads, sum(s.physical_reads)::bigint AS physical_reads,
         sum(s.logical_writes)::bigint AS logical_writes, count(*) AS intervals, max(s.snapshot_at) AS last_seen,
         sum(s.spills)::bigint AS spills, count(s.spills) AS spill_reads,
         sum(s.executions) FILTER (WHERE s.spills IS NOT NULL) AS spill_executions,
         max(s.executions * 60.0 / nullif(s.interval_secs, 0)) AS max_executions_min,  -- the busiest single read
         min(s.min_cpu_us) AS min_cpu_us, max(s.max_cpu_us) AS max_cpu_us,
         min(s.min_duration_us) AS min_duration_us, max(s.max_duration_us) AS max_duration_us,
         min(s.min_logical_reads) AS min_logical_reads, max(s.max_logical_reads) AS max_logical_reads,
         min(s.min_physical_reads) AS min_physical_reads, max(s.max_physical_reads) AS max_physical_reads,
         min(s.min_logical_writes) AS min_logical_writes, max(s.max_logical_writes) AS max_logical_writes,
         min(s.min_spills) AS min_spills, max(s.max_spills) AS max_spills
    FROM pgvigil.mssql_proc_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ($4::int IS NULL OR s.database_id = $4)
   GROUP BY s.database_id, s.object_id
)
SELECT p.database_id, p.object_id, n.database, p.schema_name, coalesce(p.object_name, 'object ' || p.object_id) AS object_name,
       p.object_name IS NOT NULL AS named, p.type_desc, p.executions,
       round((p.executions * 60 / nullif(cover.secs, 0))::numeric, 2) AS executions_min,
       round(p.max_executions_min::numeric, 2) AS max_executions_min,
       round(p.duration_us / 1000.0, 1) AS duration_ms,
       round((p.duration_us / 1000.0 / nullif(cover.secs, 0))::numeric, 3) AS duration_ms_sec,
       round(p.duration_us / 1000.0 / nullif(p.executions, 0), 3) AS avg_duration_ms,
       round(p.cpu_us / 1000.0, 1) AS cpu_ms,
       round((p.cpu_us / 1000.0 / nullif(cover.secs, 0))::numeric, 3) AS cpu_ms_sec,
       round(p.cpu_us / 1000.0 / nullif(p.executions, 0), 3) AS avg_cpu_ms,
       p.logical_reads, round(p.logical_reads::numeric / nullif(p.executions, 0), 1) AS avg_logical_reads,
       p.physical_reads, round(p.physical_reads::numeric / nullif(p.executions, 0), 1) AS avg_physical_reads,
       p.logical_writes, round(p.logical_writes::numeric / nullif(p.executions, 0), 1) AS avg_logical_writes,
       p.intervals, p.last_seen,
       p.spills, round(p.spills::numeric / nullif(p.spill_executions, 0), 1) AS avg_spills, p.spill_reads,
       round(p.min_cpu_us / 1000.0, 3) AS min_cpu_ms, round(p.max_cpu_us / 1000.0, 3) AS max_cpu_ms,
       round(p.min_duration_us / 1000.0, 3) AS min_duration_ms, round(p.max_duration_us / 1000.0, 3) AS max_duration_ms,
       p.min_logical_reads, p.max_logical_reads, p.min_physical_reads, p.max_physical_reads,
       p.min_logical_writes, p.max_logical_writes, p.min_spills, p.max_spills
  FROM p JOIN dbn n ON n.database_id = p.database_id CROSS JOIN cover
 ORDER BY p.duration_us DESC, n.database, p.object_name NULLS LAST, p.object_id
 LIMIT 2000`

// sqlMSSQLProcTotals: the window's sums over EVERY procedure ($4 one database's), whatever the grid's limit.
// (grouped by procedure first: a count(DISTINCT) of the pair sorts every sample of the window; see sqlMSSQLPCTotals)
const sqlMSSQLProcTotals = `
SELECT count(*) AS procs, coalesce(sum(g.e), 0)::bigint AS executions,
       round(coalesce(sum(g.c), 0) / 1000.0, 1) AS cpu_ms, round(coalesce(sum(g.d), 0) / 1000.0, 1) AS duration_ms,
       coalesce(sum(g.r), 0)::bigint AS logical_reads
  FROM (SELECT s.database_id, s.object_id, sum(s.executions) AS e, sum(s.cpu_us) AS c, sum(s.duration_us) AS d, sum(s.logical_reads) AS r
          FROM pgvigil.mssql_proc_sample s
         WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ($4::int IS NULL OR s.database_id = $4)
         GROUP BY 1, 2) g`

// sqlMSSQLProcSeries: every procedure's work per step ($5 seconds) over the seconds the step's reads cover (each
// read once, an idle one too).
const sqlMSSQLProcSeries = `
WITH secs AS (
  SELECT to_timestamp(floor(extract(epoch FROM r.snapshot_at) / $5) * $5) AS step, sum(r.interval_secs)::float8 AS secs
    FROM pgvigil.mssql_proc_read r
   WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
   GROUP BY 1
), w AS (
  SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $5) * $5) AS step, sum(s.executions) AS executions,
         sum(s.cpu_us) AS cpu_us, sum(s.duration_us) AS duration_us
    FROM pgvigil.mssql_proc_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ($4::int IS NULL OR s.database_id = $4)
   GROUP BY 1
)
SELECT c.step AS snapshot_at, round((coalesce(w.executions, 0) / c.secs)::numeric, 3) AS executions_s,
       round((coalesce(w.cpu_us, 0) / 1000.0 / c.secs)::numeric, 3) AS cpu_ms_s,
       round((coalesce(w.duration_us, 0) / 1000.0 / c.secs)::numeric, 3) AS duration_ms_s
  FROM secs c LEFT JOIN w ON w.step = c.step
 WHERE c.secs > 0
 ORDER BY 1`

// sqlMSSQLProcIntervals: one procedure's reads ($4 database id, $5 object id), newest first.
const sqlMSSQLProcIntervals = `
SELECT s.snapshot_at, s.interval_secs, s.executions, s.spills, round(s.cpu_us / 1000.0, 1) AS cpu_ms, round(s.duration_us / 1000.0, 1) AS duration_ms,
       round(s.duration_us / 1000.0 / nullif(s.executions, 0), 3) AS avg_duration_ms,
       round(s.cpu_us / 1000.0 / nullif(s.executions, 0), 3) AS avg_cpu_ms,
       s.logical_reads, s.physical_reads, s.logical_writes
  FROM pgvigil.mssql_proc_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND s.database_id = $4 AND s.object_id = $5
 ORDER BY s.snapshot_at DESC
 LIMIT 1000`

// sqlMSSQLProcHistory: one procedure ($4 database id, $5 object id) in steps of $6 seconds, with PerformanceMonitor's
// procedure history metrics (stats-history.js:32-37, 52; DurationTrendRouting.cs:666-667, 785; MIT, Erik Darling,
// Darling Data LLC): Duration (ms/s) = its duration over the seconds the step's reads cover, Executions (per second)
// likewise, Avg Duration (ms) = the first over the second (its duration per execution), Avg CPU (ms) = its CPU per
// execution. A step whose reads hold no run of it reads 0 per second and no averages.
//
// Control audit E5: DBA Dash's object chart's fifteen measures beside them (ObjectExecutionLineChart.cs L46-62: CPU and
// duration in seconds, total and per execution, and per second of the reads; executions per minute, the largest of one
// read, the count; the reads and writes, total and per execution), and the step $6 seconds counted from $7 (seconds
// from the Unix epoch: 0 for the page's own step, 1900-01-01 for one of DBA Dash's Date Groupings - step=, as
// dbo.DateGroupingMins counts; procHistoryStep).
var sqlMSSQLProcHistory = `
WITH st AS (
  SELECT ` + procHistoryBucket("r.snapshot_at") + ` AS step, sum(r.interval_secs)::float8 AS secs, count(*) AS reads
    FROM pgvigil.mssql_proc_read r
   WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
   GROUP BY 1
), p AS (
  SELECT ` + procHistoryBucket("s.snapshot_at") + ` AS step, sum(s.executions) AS e,
         sum(s.cpu_us) AS c, sum(s.duration_us) AS d, sum(s.logical_reads) AS lr, sum(s.physical_reads) AS pr,
         sum(s.logical_writes) AS lw, max(s.executions * 60.0 / nullif(s.interval_secs, 0)) AS mx
    FROM pgvigil.mssql_proc_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND s.database_id = $4 AND s.object_id = $5
   GROUP BY 1
)
SELECT st.step AS snapshot_at, st.reads, coalesce(p.e, 0)::bigint AS executions,
       round((coalesce(p.d, 0) / 1000.0 / nullif(st.secs, 0))::numeric, 3) AS duration_ms_s,
       round((coalesce(p.e, 0) / nullif(st.secs, 0))::numeric, 4) AS executions_s,
       round(p.d / 1000.0 / nullif(p.e, 0), 3) AS avg_duration_ms,
       round(p.c / 1000.0 / nullif(p.e, 0), 3) AS avg_cpu_ms,
       coalesce(p.e, 0)::bigint AS execution_count,
       round(coalesce(p.c, 0) / 1000000.0, 6) AS total_cpu_sec, round(p.c / 1000000.0 / nullif(p.e, 0), 6) AS avg_cpu_sec,
       round((coalesce(p.c, 0) / 1000.0 / nullif(st.secs, 0))::numeric, 3) AS cpu_ms_sec,
       round((coalesce(p.e, 0) * 60.0 / nullif(st.secs, 0))::numeric, 3) AS executions_min, round(p.mx, 3) AS max_executions_min,
       round(coalesce(p.d, 0) / 1000000.0, 6) AS total_duration_sec, round(p.d / 1000000.0 / nullif(p.e, 0), 6) AS avg_duration_sec,
       round((coalesce(p.d, 0) / 1000.0 / nullif(st.secs, 0))::numeric, 3) AS duration_ms_sec,
       coalesce(p.lr, 0)::bigint AS total_logical_reads, round(p.lr::numeric / nullif(p.e, 0), 2) AS avg_logical_reads,
       coalesce(p.pr, 0)::bigint AS total_physical_reads, round(p.pr::numeric / nullif(p.e, 0), 2) AS avg_physical_reads,
       coalesce(p.lw, 0)::bigint AS total_writes, round(p.lw::numeric / nullif(p.e, 0), 2) AS avg_writes
  FROM st LEFT JOIN p ON p.step = st.step
 ORDER BY 1`

// procHistoryBucket: the start of the $6-second step a time falls in, counted from $7 (seconds from the Unix epoch)
func procHistoryBucket(col string) string {
	return stepBucket(col, "$6", "$7")
}

// stepBucket: the start of the step (seconds, the parameter step) a time falls in, counted from base (seconds from the
// Unix epoch, a parameter): 0 = the Unix epoch's steps, 1900-01-01 = DBA Dash's dbo.DateGroupingMins
func stepBucket(col, step, base string) string {
	return `to_timestamp(floor((extract(epoch FROM ` + col + `) - ` + base + `::bigint) / ` + step + `::bigint) * ` + step + `::bigint + ` + base + `::bigint)`
}

// procHistorySteps: DBA Dash's Date Groupings in minutes (DateHelper.cs DateGroups; its None, the 15-second rows, is not
// one: pgvigil stores reads)
var procHistorySteps = map[int]bool{1: true, 2: true, 5: true, 10: true, 15: true, 30: true, 60: true, 120: true, 240: true, 360: true, 720: true,
	1440: true, 2880: true, 10080: true, 20160: true}

// procHistoryStep reads step= for part=history: absent = the page's own step (procStep) counted from the Unix epoch;
// one of DBA Dash's groupings = that many minutes counted from 1900-01-01 (dbo.DateGroupingMins); any other = an error
func procHistoryStep(v string, window time.Duration) (secs int, base int64, err error) {
	if v == "" {
		return procStep(window.Seconds()), 0, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || !procHistorySteps[n] {
		return 0, 0, errors.New("step must be one of 1, 2, 5, 10, 15, 30, 60, 120, 240, 360, 720, 1440, 2880, 10080, 20160 (minutes)")
	}
	return n * 60, time.Date(1900, 1, 1, 0, 0, 0, 0, time.UTC).Unix(), nil
}

// sqlMSSQLFuncIntervals / sqlMSSQLFuncHistory: the two reads of one function or trigger (OBJ, the object page's Object
// Execution) - the procedure's reads over 0343's statistics (an object id is unique in its database, so the kind needs
// no filter)
var (
	sqlMSSQLFuncIntervals = strings.NewReplacer("pgvigil.mssql_proc_sample", "pgvigil.mssql_func_sample").Replace(sqlMSSQLProcIntervals)
	sqlMSSQLFuncHistory   = strings.NewReplacer("pgvigil.mssql_proc_sample", "pgvigil.mssql_func_sample", "pgvigil.mssql_proc_read", "pgvigil.mssql_func_read").Replace(sqlMSSQLProcHistory)
)

// sqlMSSQLProcCompare: PerformanceMonitor's compare (top-compare.js, MIT, Erik Darling, Darling Data LLC) on the
// procedures' stored reads, keyed as PerformanceMonitor keys them, by database and name ([database_name,
// full_name]: a procedure dropped and created again between the windows is one row; one whose name was not read is
// keyed by its id): the window ($2, $3) against the same span $5 seconds earlier, one read over every stored sample
// of both windows ($4 one database's id, NULL all). NEW: no run stored in the earlier window's reads; GONE: none in
// the window's (the view counts per cached plan, so a procedure compiled, run and dropped between two reads is in
// neither; pgvigil keeps no mark of a read cut at 5,000 plans, which the page says). The union of each window's first
// 100 by duration, NEW first, GONE last, then by the rise of the average duration.
const sqlMSSQLProcCompare = `
WITH s0 AS (
  -- each window apart: where the two overlap (a shift shorter than the window) a read counts in both
  SELECT s.database_id, s.object_id, true AS is_now, max(s.database_name) AS database_name,
         max(s.schema_name) AS schema_name, max(s.object_name) AS object_name,
         sum(s.executions) AS e, sum(s.duration_us) AS d, sum(s.cpu_us) AS c
    FROM pgvigil.mssql_proc_sample s
   WHERE s.instance_id = $1 AND ($4::int IS NULL OR s.database_id = $4) AND s.snapshot_at > $2 AND s.snapshot_at <= $3
   GROUP BY 1, 2
  UNION ALL
  SELECT s.database_id, s.object_id, false, max(s.database_name), max(s.schema_name), max(s.object_name),
         sum(s.executions), sum(s.duration_us), sum(s.cpu_us)
    FROM pgvigil.mssql_proc_sample s
   WHERE s.instance_id = $1 AND ($4::int IS NULL OR s.database_id = $4)
     AND s.snapshot_at > $2::timestamptz - make_interval(secs => $5) AND s.snapshot_at <= $3::timestamptz - make_interval(secs => $5)
   GROUP BY 1, 2
), named AS (
  -- one name per object id over both windows (a read that gave up on a lock stores none)
  SELECT database_id, object_id, max(database_name) AS database_name, max(schema_name) AS schema_name, max(object_name) AS object_name
    FROM s0 GROUP BY 1, 2
), k AS (
  SELECT s0.database_id, s0.is_now, n.database_name, n.schema_name, n.object_name,
         CASE WHEN n.object_name IS NULL THEN '#' || s0.object_id ELSE coalesce(n.schema_name, '') || '.' || n.object_name END AS proc_key,
         s0.object_id, s0.e, s0.d, s0.c
    FROM s0 JOIN named n ON n.database_id = s0.database_id AND n.object_id = s0.object_id
), j AS (
  SELECT k.database_id, k.proc_key, max(k.database_name) AS database_name, max(k.schema_name) AS schema_name, max(k.object_name) AS object_name,
         max(k.object_id) AS object_id,
         coalesce(sum(k.e) FILTER (WHERE k.is_now), 0) AS now_e, sum(k.d) FILTER (WHERE k.is_now) AS now_d, sum(k.c) FILTER (WHERE k.is_now) AS now_c,
         coalesce(sum(k.e) FILTER (WHERE NOT k.is_now), 0) AS bef_e, sum(k.d) FILTER (WHERE NOT k.is_now) AS bef_d, sum(k.c) FILTER (WHERE NOT k.is_now) AS bef_c
    FROM k GROUP BY 1, 2
), n AS (
  SELECT j.*,
         CASE WHEN j.now_e > 0 AND j.bef_e = 0 THEN 'new' WHEN j.now_e = 0 AND j.bef_e > 0 THEN 'gone' ELSE '' END AS status,
         row_number() OVER (ORDER BY j.now_d DESC NULLS LAST, j.database_id, j.proc_key) AS rn_now,
         row_number() OVER (ORDER BY j.bef_d DESC NULLS LAST, j.database_id, j.proc_key) AS rn_bef,
         count(*) OVER () AS n_keys, count(*) FILTER (WHERE j.now_e > 0 AND j.bef_e > 0) OVER () AS n_both,
         count(*) FILTER (WHERE j.now_e > 0 AND j.bef_e = 0) OVER () AS n_new, count(*) FILTER (WHERE j.now_e = 0 AND j.bef_e > 0) OVER () AS n_gone
    FROM j
)
SELECT o.database_id, o.object_id, coalesce(o.database_name, 'database ' || o.database_id) AS database, o.schema_name,
       coalesce(o.object_name, 'object ' || o.object_id) AS object_name, o.status,
       o.now_e AS executions, o.bef_e AS before_executions,
       round(o.now_d / 1000.0, 1) AS duration_ms, round(o.bef_d / 1000.0, 1) AS before_duration_ms,
       round(o.now_d / 1000.0 / nullif(o.now_e, 0), 3) AS avg_duration_ms, round(o.bef_d / 1000.0 / nullif(o.bef_e, 0), 3) AS before_avg_duration_ms,
       round(o.now_c / 1000.0 / nullif(o.now_e, 0), 3) AS avg_cpu_ms, round(o.bef_c / 1000.0 / nullif(o.bef_e, 0), 3) AS before_avg_cpu_ms,
       round(100.0 * (o.now_e - o.bef_e) / nullif(o.bef_e, 0), 1) AS executions_pct,
       round(100.0 * (o.now_d / nullif(o.now_e, 0) - o.bef_d / nullif(o.bef_e, 0)) / nullif(o.bef_d / nullif(o.bef_e, 0), 0), 1) AS avg_duration_pct,
       round(100.0 * (o.now_c / nullif(o.now_e, 0) - o.bef_c / nullif(o.bef_e, 0)) / nullif(o.bef_c / nullif(o.bef_e, 0), 0), 1) AS avg_cpu_pct,
       o.n_keys, o.n_both, o.n_new, o.n_gone
  FROM n o
 WHERE (o.rn_now <= 100 AND o.now_e > 0) OR (o.rn_bef <= 100 AND o.bef_e > 0)
 ORDER BY CASE o.status WHEN 'new' THEN 0 WHEN 'gone' THEN 2 ELSE 1 END,
          (o.now_d / nullif(o.now_e, 0) - o.bef_d / nullif(o.bef_e, 0)) / nullif(o.bef_d / nullif(o.bef_e, 0), 0) DESC NULLS LAST,
          o.now_d DESC NULLS LAST, o.database_id, o.proc_key`

// sqlMSSQLProcCompareWindows: the two windows, the reads each holds and the seconds they cover, whether they
// overlap, and the coverage word (as the plan cache's).
const sqlMSSQLProcCompareWindows = `
WITH w AS (
  SELECT $2::timestamptz AS now_from, $3::timestamptz AS now_to,
         $2::timestamptz - make_interval(secs => $4) AS before_from, $3::timestamptz - make_interval(secs => $4) AS before_to
), c AS (
  SELECT count(*) FILTER (WHERE r.snapshot_at > w.now_from AND r.snapshot_at <= w.now_to) AS now_reads,
         count(*) FILTER (WHERE r.snapshot_at > w.before_from AND r.snapshot_at <= w.before_to) AS before_reads,
         coalesce(sum(r.interval_secs) FILTER (WHERE r.snapshot_at > w.now_from AND r.snapshot_at <= w.now_to), 0)::float8 AS now_covered_secs,
         coalesce(sum(r.interval_secs) FILTER (WHERE r.snapshot_at > w.before_from AND r.snapshot_at <= w.before_to), 0)::float8 AS before_covered_secs
    FROM w LEFT JOIN pgvigil.mssql_proc_read r ON r.instance_id = $1 AND r.snapshot_at > least(w.now_from, w.before_from) AND r.snapshot_at <= w.now_to
)
SELECT w.now_from, w.now_to, w.before_from, w.before_to, $4::float8 < extract(epoch FROM w.now_to - w.now_from) AS overlap, c.*,
       CASE WHEN c.before_reads = 0 THEN 'no baseline' WHEN c.before_covered_secs >= 0.9 * c.now_covered_secs THEN 'ok' ELSE 'partial' END AS coverage
  FROM w CROSS JOIN c`

// procStep: about 120 steps over the range, never finer than the collection's five minutes.
func procStep(secs float64) int {
	step := int(secs) / 120
	if step < 300 {
		step = 300
	}
	return step
}

// dbFilter reads db=<database id>: nil = every database.
func dbFilter(r *http.Request) (any, error) {
	v := r.URL.Query().Get("db")
	if v == "" {
		return nil, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return nil, errors.New("db must be a database id")
	}
	return n, nil
}

// The functions and the triggers (0343, the collection mssql_funcstats): the procedures' grid shape over
// mssql_func_sample, one kind each, the busiest CPU first; the per-minute figures over the seconds the functions'
// own reads cover (mssql_func_read). $1 instance, $2 and $3 the window, $4 the database's id (NULL = every database).
// The names: as procDBNames, from the functions' and triggers' reads.
const funcDBNames = `
  SELECT DISTINCT ON (s.database_id) s.database_id, coalesce(s.database_name, 'database ' || s.database_id) AS database
    FROM pgvigil.mssql_func_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
   ORDER BY s.database_id, (s.database_name IS NULL), s.snapshot_at DESC`

// funcCover and funcAgg / funcCols: what the two parts share - the covered seconds, the sums and the extremes per
// object, and their columns as the procedures' part returns them (spills apart: the function view has none).
const funcCover = `cover AS (
  SELECT coalesce(sum(r.interval_secs), 0)::float8 AS secs FROM pgvigil.mssql_func_read r
   WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
)`

const funcAgg = `s.database_id, s.object_id,
         max(s.schema_name) AS schema_name, max(s.object_name) AS object_name, max(s.type_desc) AS type_desc,
         sum(s.executions)::bigint AS executions, sum(s.cpu_us)::bigint AS cpu_us, sum(s.duration_us)::bigint AS duration_us,
         sum(s.logical_reads)::bigint AS logical_reads, sum(s.physical_reads)::bigint AS physical_reads,
         sum(s.logical_writes)::bigint AS logical_writes, count(*) AS intervals, max(s.snapshot_at) AS last_seen,
         max(s.executions * 60.0 / nullif(s.interval_secs, 0)) AS max_executions_min,
         min(s.min_cpu_us) AS min_cpu_us, max(s.max_cpu_us) AS max_cpu_us,
         min(s.min_duration_us) AS min_duration_us, max(s.max_duration_us) AS max_duration_us,
         min(s.min_logical_reads) AS min_logical_reads, max(s.max_logical_reads) AS max_logical_reads,
         min(s.min_physical_reads) AS min_physical_reads, max(s.max_physical_reads) AS max_physical_reads,
         min(s.min_logical_writes) AS min_logical_writes, max(s.max_logical_writes) AS max_logical_writes`

const funcCols = `p.database_id, p.object_id, n.database, p.schema_name, coalesce(p.object_name, 'object ' || p.object_id) AS object_name,
       p.object_name IS NOT NULL AS named, p.type_desc, p.executions,
       round((p.executions * 60 / nullif(cover.secs, 0))::numeric, 2) AS executions_min,
       round(p.max_executions_min::numeric, 2) AS max_executions_min,
       round(p.duration_us / 1000.0, 1) AS duration_ms,
       round((p.duration_us / 1000.0 / nullif(cover.secs, 0))::numeric, 3) AS duration_ms_sec,
       round(p.duration_us / 1000.0 / nullif(p.executions, 0), 3) AS avg_duration_ms,
       round(p.cpu_us / 1000.0, 1) AS cpu_ms,
       round((p.cpu_us / 1000.0 / nullif(cover.secs, 0))::numeric, 3) AS cpu_ms_sec,
       round(p.cpu_us / 1000.0 / nullif(p.executions, 0), 3) AS avg_cpu_ms,
       p.logical_reads, round(p.logical_reads::numeric / nullif(p.executions, 0), 1) AS avg_logical_reads,
       p.physical_reads, round(p.physical_reads::numeric / nullif(p.executions, 0), 1) AS avg_physical_reads,
       p.logical_writes, round(p.logical_writes::numeric / nullif(p.executions, 0), 1) AS avg_logical_writes,
       p.intervals, p.last_seen,
       round(p.min_cpu_us / 1000.0, 3) AS min_cpu_ms, round(p.max_cpu_us / 1000.0, 3) AS max_cpu_ms,
       round(p.min_duration_us / 1000.0, 3) AS min_duration_ms, round(p.max_duration_us / 1000.0, 3) AS max_duration_ms,
       p.min_logical_reads, p.max_logical_reads, p.min_physical_reads, p.max_physical_reads,
       p.min_logical_writes, p.max_logical_writes`

// sqlMSSQLFuncReads: the functions' and triggers' reads of the window (mssql_func_read), as the procedures' reads:
// none = no read took a difference yet (the collection's first read only sets the starting counters).
const sqlMSSQLFuncReads = `
SELECT count(*) AS reads, coalesce(sum(r.interval_secs), 0)::float8 AS covered_secs, min(r.snapshot_at) AS first_read, max(r.snapshot_at) AS last_read
  FROM pgvigil.mssql_func_read r
 WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3`

// sqlMSSQLFuncs: the scalar functions that ran without inlining (the server lists no table-valued function and no
// scalar function it inlined), with the mark from sys.sql_modules as last read (mssql_func_inline): no row, or a
// figure not read = 'not read' (an earlier version than 2019, a module the login cannot see or a database it cannot
// enter, a failed read, a CLR scalar function - never inlined, its module is not in sys.sql_modules - or a function
// first listed after its database's hourly read);
// is_inlineable 0 = 'not inlineable' (the definition's constructs); is_inlineable 1 and inline_type 0 = 'inlining
// off' (INLINE = OFF on an inlineable function); both 1 = no mark (it ran without inlining for the call's own
// reason: a hint, the database's setting or compatibility level, the form of the call). inline_read_at: when that
// read was taken, by the server's clock.
const sqlMSSQLFuncs = `
WITH dbn AS (` + funcDBNames + `), ` + funcCover + `, p AS (
  SELECT ` + funcAgg + `
    FROM pgvigil.mssql_func_sample s
   WHERE s.instance_id = $1 AND s.kind = 'function' AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ($4::int IS NULL OR s.database_id = $4)
   GROUP BY s.database_id, s.object_id
)
SELECT ` + funcCols + `,
       CASE WHEN i.is_inlineable IS NULL OR (i.is_inlineable AND i.inline_type IS NULL) THEN 'not read'
            WHEN NOT i.is_inlineable THEN 'not inlineable'
            WHEN NOT i.inline_type THEN 'inlining off'
            ELSE '' END AS inline_mark,
       i.read_at AS inline_read_at
  FROM p JOIN dbn n ON n.database_id = p.database_id CROSS JOIN cover
  LEFT JOIN pgvigil.mssql_func_inline i ON i.instance_id = $1 AND i.database_id = p.database_id AND i.object_id = p.object_id
 ORDER BY p.cpu_us DESC, n.database, p.object_name NULLS LAST, p.object_id
 LIMIT 2000`

// sqlMSSQLTriggers: the triggers, with the spills as the procedures' (total_spills over the reads that had the
// figure; none = NULL) and the scope of a DDL or logon trigger ('server' or 'database', named from its catalog;
// NULL for a DML trigger).
const sqlMSSQLTriggers = `
WITH dbn AS (` + funcDBNames + `), ` + funcCover + `, p AS (
  SELECT ` + funcAgg + `,
         max(s.trigger_scope) AS trigger_scope,
         sum(s.spills)::bigint AS spills, count(s.spills) AS spill_reads,
         sum(s.executions) FILTER (WHERE s.spills IS NOT NULL) AS spill_executions,
         min(s.min_spills) AS min_spills, max(s.max_spills) AS max_spills
    FROM pgvigil.mssql_func_sample s
   WHERE s.instance_id = $1 AND s.kind = 'trigger' AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ($4::int IS NULL OR s.database_id = $4)
   GROUP BY s.database_id, s.object_id
)
SELECT ` + funcCols + `, p.trigger_scope,
       p.spills, round(p.spills::numeric / nullif(p.spill_executions, 0), 1) AS avg_spills, p.spill_reads,
       p.min_spills, p.max_spills
  FROM p JOIN dbn n ON n.database_id = p.database_id CROSS JOIN cover
 ORDER BY p.cpu_us DESC, n.database, p.object_name NULLS LAST, p.object_id
 LIMIT 2000`

// objCols: the columns the three kinds share, as Object Execution lists them
const objCols = `o.database_id, o.object_id, o.database, o.schema_name, o.object_name, o.named, o.type_desc, o.executions,
       o.executions_min, o.max_executions_min, o.duration_ms, o.duration_ms_sec, o.avg_duration_ms, o.cpu_ms, o.cpu_ms_sec,
       o.avg_cpu_ms, o.logical_reads, o.avg_logical_reads, o.physical_reads, o.avg_physical_reads, o.logical_writes,
       o.avg_logical_writes, o.last_seen`

// sqlMSSQLObjects: DBA Dash's Object Execution (P25 F102 / F505) - the procedures, the scalar functions and the
// triggers in ONE list, each row its kind and its Period Time (the seconds its kind's reads cover: the procedures'
// reads, the functions' and triggers' reads) and its DBA Dash type (type_code, objType); $5 the kinds or the types asked
// (NULL = every kind, DBA Dash's Type filter: objectKinds), $6 a
// text the schema or the name holds (case ignored; empty = any); the longest total duration first, 2,000 at most.
// The kind and the text are applied INSIDE each kind's read, before its own 2,000-row cut (objKind), so a search
// finds an object past the cut, and a kind not asked is not read at all.
var sqlMSSQLObjects = `
WITH pc AS (SELECT coalesce(sum(r.interval_secs), 0)::float8 AS secs FROM pgvigil.mssql_proc_read r
             WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3),
fc AS (SELECT coalesce(sum(r.interval_secs), 0)::float8 AS secs FROM pgvigil.mssql_func_read r
        WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3),
o AS (
  SELECT 'procedure'::text AS kind, ` + objType("o", "procedure") + ` AS type_code, ` + objCols + `, pc.secs AS period_secs FROM (` + objKind(sqlMSSQLProcs, "procedure") + `) o CROSS JOIN pc
  UNION ALL
  SELECT 'function', ` + objType("o", "function") + `, ` + objCols + `, fc.secs FROM (` + objKind(sqlMSSQLFuncs, "function") + `) o CROSS JOIN fc
  UNION ALL
  SELECT 'trigger', ` + objType("o", "trigger") + `, ` + objCols + `, fc.secs FROM (` + objKind(sqlMSSQLTriggers, "trigger") + `) o CROSS JOIN fc
)
SELECT o.kind, o.type_code, ` + objCols + `, o.period_secs
  FROM o
 ORDER BY o.duration_ms DESC NULLS LAST, o.database, o.object_name, o.object_id
 LIMIT 2000`

// objKind: one kind's grid read (sqlMSSQLProcs, sqlMSSQLFuncs or sqlMSSQLTriggers: each ends 'LIMIT 2000') as Object
// Execution reads it - its rows filtered by the kinds asked ($5) and the text ($6) BEFORE the cut, the longest total
// duration first. A read that does not end so panics at start-up (a change to the grid reads is seen at once).
func objKind(grid, kind string) string {
	body, ok := strings.CutSuffix(grid, "\n LIMIT 2000")
	if !ok {
		panic("objKind: the " + kind + " read does not end with LIMIT 2000")
	}
	// review t11-10 NIT 6: its own ORDER BY goes with its LIMIT (the outer order and cut are the list's)
	i := strings.LastIndex(body, "\n ORDER BY ")
	if i < 0 {
		panic("objKind: the " + kind + " read does not end with an ORDER BY line before its LIMIT")
	}
	body = body[:i]
	return `SELECT * FROM (` + body + `) g
 WHERE ($5::text[] IS NULL OR '` + kind + `' = ANY ($5::text[]) OR ` + objType("g", kind) + ` = ANY ($5::text[]))
   AND ($6::text = '' OR strpos(lower(coalesce(g.schema_name, '') || '.' || g.object_name), lower($6::text)) > 0)
 ORDER BY g.duration_ms DESC NULLS LAST, g.database, g.object_name, g.object_id
 LIMIT 2000`
}

// objType (control audit E1): a row's DBA Dash object type from its kind and its stored type_desc (Microsoft Learn:
// CLR_STORED_PROCEDURE = PC, EXTENDED_STORED_PROCEDURE = X, CLR_TRIGGER = TA; any other procedure P, trigger TR,
// scalar function FN - the function view lists CLR scalar functions under FN too)
func objType(alias, kind string) string {
	base := map[string]string{"procedure": "P", "function": "FN", "trigger": "TR"}[kind]
	if base == "" {
		panic("objType: no type for the kind " + kind)
	}
	return `(CASE ` + alias + `.type_desc WHEN 'CLR_STORED_PROCEDURE' THEN 'PC' WHEN 'EXTENDED_STORED_PROCEDURE' THEN 'X' WHEN 'CLR_TRIGGER' THEN 'TA' ELSE '` + base + `' END)`
}

// objMeasureCols: the measures of an Object Execution row (objCols' figures, and its kind's Period Time), each with a
// compare_ twin under Compare To (control audit E3)
var objMeasureCols = []string{"executions", "executions_min", "max_executions_min", "duration_ms", "duration_ms_sec", "avg_duration_ms",
	"cpu_ms", "cpu_ms_sec", "avg_cpu_ms", "logical_reads", "avg_logical_reads", "physical_reads", "avg_physical_reads",
	"logical_writes", "avg_logical_writes", "period_secs"}

// sqlMSSQLObjectsCompare: Object Execution with DBA Dash's Compare To (control audit E3; ObjectExecutionStatsSummary_Get
// with @CompareFrom / @CompareTo) - the list over the range ($2 / $3) beside the same list over the compare window
// ($7 / $8), FULL JOINed by object as DBA Dash joins them (an object of one window only keeps its row), each measure's
// compare_ column and DBA Dash's two diffs (diff_avg_duration_pct, diff_avg_cpu_pct: the change in % of the compare
// figure); the range's longest total duration first, then the compare window's, 2,000 at most. $4-$6 as sqlMSSQLObjects.
var sqlMSSQLObjectsCompare = func() string {
	keys := []string{"kind", "type_code", "database_id", "object_id", "database", "schema_name", "object_name", "named", "type_desc"}
	var cols []string
	for _, k := range keys {
		cols = append(cols, "coalesce(b."+k+", c."+k+") AS "+k)
	}
	for _, m := range objMeasureCols {
		cols = append(cols, "b."+m)
	}
	cols = append(cols, "b.last_seen")
	for _, m := range objMeasureCols {
		cols = append(cols, "c."+m+" AS compare_"+m)
	}
	return `
SELECT ` + strings.Join(cols, ",\n       ") + `,
       round(100.0 * (b.avg_duration_ms - c.avg_duration_ms) / nullif(c.avg_duration_ms, 0), 2) AS diff_avg_duration_pct,
       round(100.0 * (b.avg_cpu_ms - c.avg_cpu_ms) / nullif(c.avg_cpu_ms, 0), 2) AS diff_avg_cpu_pct
  FROM (` + sqlMSSQLObjects + `) b
  FULL JOIN (` + strings.NewReplacer("$2", "$7", "$3", "$8").Replace(sqlMSSQLObjects) + `) c
    ON c.kind = b.kind AND c.database_id = b.database_id AND c.object_id = b.object_id
 ORDER BY b.duration_ms DESC NULLS LAST, c.duration_ms DESC NULLS LAST, 5, 7, 4
 LIMIT 2000`
}()

// sqlMSSQLNodeObjectsCompare: sqlMSSQLObjectsCompare over a node's databases, as sqlMSSQLNodeObjects runs sqlMSSQLObjects
var sqlMSSQLNodeObjectsCompare = `
SELECT i.instance_id, i.name AS instance, o.*
  FROM unnest($1::int[]) AS u(id)
  JOIN pgvigil.instances i ON i.instance_id = u.id
  CROSS JOIN LATERAL (` + strings.ReplaceAll(sqlMSSQLObjectsCompare, "$1", "u.id") + `) o
 ORDER BY o.duration_ms DESC NULLS LAST, o.compare_duration_ms DESC NULLS LAST, i.name, o.database, o.object_name, o.object_id
 LIMIT 2000`

// objCompareWindow reads cmp= (DBA Dash's Compare To; control audit E3): empty = none; prev = the window just before
// the range, of its length; day / week = the range 24 hours / 7 days back; 'from,to' = a custom window (RFC 3339, from
// before to, at most the longest window the API takes)
func objCompareWindow(v string, from, to time.Time) (cfrom, cto time.Time, on bool, err error) {
	switch v {
	case "":
		return time.Time{}, time.Time{}, false, nil
	case "prev":
		return from.Add(-to.Sub(from)), from, true, nil
	case "day":
		return from.Add(-24 * time.Hour), to.Add(-24 * time.Hour), true, nil
	case "week":
		return from.Add(-7 * 24 * time.Hour), to.Add(-7 * 24 * time.Hour), true, nil
	}
	a, b, ok := strings.Cut(v, ",")
	if !ok {
		return time.Time{}, time.Time{}, false, errors.New("cmp must be prev, day, week or a custom window 'from,to' (RFC 3339)")
	}
	cfrom, err1 := time.Parse(time.RFC3339, a)
	cto, err2 := time.Parse(time.RFC3339, b)
	if err1 != nil || err2 != nil {
		return time.Time{}, time.Time{}, false, errors.New("cmp's custom window must be two RFC 3339 times, 'from,to'")
	}
	if !cfrom.Before(cto) || cto.Sub(cfrom) > maxWindow {
		return time.Time{}, time.Time{}, false, errors.New("cmp's custom window must start before it ends and span at most 366 days and an hour")
	}
	return cfrom, cto, true, nil
}

// sqlMSSQLNodeObjects: Object Execution over a node's databases (P25 (i): DBA Dash's logical server and elastic pool
// Object Execution, one grid with an instance column - the lead's Q2 (a)): sqlMSSQLObjects run for each id of $1 (an
// int[]: the node's Azure SQL Databases, each an instance of its own) through a lateral join, its own $1 the id, the
// longest total duration first over the whole list; $2 / $3 the window, $4 a database id (NULL here), $5 the kinds,
// $6 the search, as sqlMSSQLObjects.
var sqlMSSQLNodeObjects = `
SELECT i.instance_id, i.name AS instance, o.*
  FROM unnest($1::int[]) AS u(id)
  JOIN pgvigil.instances i ON i.instance_id = u.id
  CROSS JOIN LATERAL (` + strings.ReplaceAll(sqlMSSQLObjects, "$1", "u.id") + `) o
 ORDER BY o.duration_ms DESC NULLS LAST, i.name, o.database, o.object_name, o.object_id
 LIMIT 2000`

// review t11-7 item 8: the node variant is made by a text replace of $1 - a $1 followed by a digit ($10 and over) would
// silently become u.id0, so the start refuses it rather than a query going wrong later
func init() {
	if regexp.MustCompile(`\$1[0-9]`).MatchString(sqlMSSQLObjects) {
		panic("sqlMSSQLObjects holds a $1 followed by a digit: sqlMSSQLNodeObjects' $1 -> u.id replace would break it")
	}
	if !strings.Contains(sqlMSSQLNodeObjects, "u.id") || strings.Contains(sqlMSSQLNodeObjects[strings.Index(sqlMSSQLNodeObjects, "CROSS JOIN LATERAL"):], "$1") {
		panic("sqlMSSQLNodeObjects: the $1 -> u.id replace left a $1 in the lateral statement")
	}
}

// objectKinds reads types= (a comma list): DBA Dash's six object types (control audit E1: P, PC, X, TR, TA, FN - the
// type codes of Microsoft Learn's sys.dm_exec_procedure_stats, sys.dm_exec_trigger_stats and sys.dm_exec_function_stats)
// or a kind word (procedure, function, trigger: every type of the kind); nil = every kind.
func objectKinds(v string) ([]string, error) {
	if v == "" {
		return nil, nil
	}
	var out []string
	for _, k := range strings.Split(v, ",") {
		switch k = strings.TrimSpace(k); k {
		case "procedure", "function", "trigger", "P", "PC", "X", "TR", "TA", "FN":
			out = append(out, k)
		default:
			return nil, errors.New("types must list P, PC, X, TR, TA, FN, procedure, function or trigger")
		}
	}
	return out, nil
}

// procsParts: the tab's parts that every read asks for (database: db=, nil = every database). The functions'
// collection state is a part of its own: the page reads the procedures' state as the first row of 'state'.
func procsParts(id int, from, to time.Time, database any) []part {
	return []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_procstats"}}},
		{"reads", sqlMSSQLProcReads, []any{id, from, to}},
		{"databases", sqlMSSQLProcDatabases, []any{id, from, to}},
		{"totals", sqlMSSQLProcTotals, []any{id, from, to, database}},
		{"procs", sqlMSSQLProcs, []any{id, from, to, database}},
		{"series", sqlMSSQLProcSeries, []any{id, from, to, database, procStep(to.Sub(from).Seconds())}},
		{"func_state", sqlMssqlRunningState, []any{id, []string{"mssql_funcstats"}}},
		{"func_reads", sqlMSSQLFuncReads, []any{id, from, to}},
		{"functions", sqlMSSQLFuncs, []any{id, from, to, database}},
		{"triggers", sqlMSSQLTriggers, []any{id, from, to, database}},
	}
}

// MSSQLProcs is GET /api/mssql/procs?instance=N[&from=&to=][&db=][&db_id=&object=][&part=...]; with instances=
// in place of instance=, part=objects over those instances (the node tabs' Object Execution).
func (s *Server) MSSQLProcs(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("instances") != "" {
		s.mssqlNodeObjects(w, r)
		return
	}
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	database, err := dbFilter(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	parts := procsParts(id, from, to, database)
	// the compare reads both windows: only when a shift is asked for (the page asks for it apart, part=compare)
	if shift, on, err := compareShift(q.Get("compare"), from, to); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	} else if on {
		parts = append(parts, part{"compare", sqlMSSQLProcCompare, []any{planEach, id, from, to, database, shift}},
			part{"compare_windows", sqlMSSQLProcCompareWindows, []any{planEach, id, from, to, shift}})
	}
	// Object Execution's one list: read only when asked (part=objects), as it runs the three kinds' reads again
	if q.Get("part") == "objects" {
		kinds, err := objectKinds(q.Get("types"))
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		search := q.Get("search")
		if len([]rune(search)) > 128 {
			writeErr(w, http.StatusBadRequest, errors.New("search is longer than 128 characters"))
			return
		}
		// DBA Dash's Compare To (control audit E3): the compare window's figures beside the range's
		cfrom, cto, cmpOn, err := objCompareWindow(q.Get("cmp"), from, to)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		if cmpOn {
			parts = append(parts, part{"objects", sqlMSSQLObjectsCompare, []any{id, from, to, database, kinds, search, cfrom, cto}})
		} else {
			parts = append(parts, part{"objects", sqlMSSQLObjects, []any{id, from, to, database, kinds, search}})
		}
	}
	if (q.Get("db_id") != "" || q.Get("object") != "") && q.Get("part") != "object_statements" && q.Get("part") != "object_schema" {
		dbID, err1 := strconv.Atoi(q.Get("db_id"))
		obj, err2 := strconv.ParseInt(q.Get("object"), 10, 64)
		if err1 != nil || err2 != nil {
			writeErr(w, http.StatusBadRequest, errors.New("db_id and object must both be given as the procedure's database id and object id"))
			return
		}
		// the object page (OBJ) reads a function or a trigger the same way, from its kind's statistics (kind=)
		intervals, history := sqlMSSQLProcIntervals, sqlMSSQLProcHistory
		switch q.Get("kind") {
		case "", "procedure":
		case "function", "trigger":
			intervals, history = sqlMSSQLFuncIntervals, sqlMSSQLFuncHistory
		default:
			writeErr(w, http.StatusBadRequest, errors.New("kind must be procedure, function or trigger"))
			return
		}
		step, base, err := procHistoryStep(q.Get("step"), to.Sub(from))
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		parts = append(parts, part{"intervals", intervals, []any{id, from, to, dbID, obj}},
			part{"history", history, []any{planEach, id, from, to, dbID, obj, step, base}})
		// DBA Dash's compare chart (control audit E3): the same steps over the Compare To window (cmp=, objCompareWindow),
		// its own step when none is chosen
		cfrom, cto, cmpOn, err := objCompareWindow(q.Get("cmp"), from, to)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		if cmpOn {
			cstep, cbase, err := procHistoryStep(q.Get("step"), cto.Sub(cfrom))
			if err != nil {
				writeErr(w, http.StatusBadRequest, err)
				return
			}
			parts = append(parts, part{"history_compare", history, []any{planEach, id, cfrom, cto, dbID, obj, cstep, cbase}})
		}
	}
	// the object page's Schema History (OBJ, q_mssql_object.go): its stored changes, when asked
	if q.Get("part") == "object_schema" {
		p, err := objectSchemaPart(q, id)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		parts = append(parts, p)
	}
	// the object page's Slow Queries (OBJ, q_mssql_object.go): its completions by client app, when asked
	if q.Get("part") == "object_slow" {
		p, err := objectSlowPart(q, id, from, to)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		parts = append(parts, p)
	}
	// the object page's Query Stats (OBJ, q_mssql_object.go): its module's statements in its database, when asked
	if q.Get("part") == "object_statements" {
		p, err := objectStatementsPart(q, id, from, to)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		parts = append(parts, p)
	}
	// the object page's lookup (OBJ, q_mssql_object.go): read only when asked, its database by name (dbname=; db= stays
	// the database id this endpoint's other parts read)
	if q.Get("part") == "object_lookup" {
		p, err := objectLookupPart(q, id, from, to)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		parts = append(parts, p)
	}
	s.multiPart(w, r, parts)
}

// mssqlNodeObjects: part=objects over instances= (at most nodeObjectsMax ids; types= and search= as for one instance).
func (s *Server) mssqlNodeObjects(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("part") != "objects" {
		writeErr(w, http.StatusBadRequest, errors.New("instances= is read by part=objects only"))
		return
	}
	_, ids, err := storageScope(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	if len(ids) > nodeObjectsMax {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("at most %d instances in one Object Execution list (%d given)", nodeObjectsMax, len(ids)))
		return
	}
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	kinds, err := objectKinds(q.Get("types"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	search := q.Get("search")
	if len([]rune(search)) > 128 {
		writeErr(w, http.StatusBadRequest, errors.New("search is longer than 128 characters"))
		return
	}
	cfrom, cto, cmpOn, err := objCompareWindow(q.Get("cmp"), from, to)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	if cmpOn {
		s.multiPart(w, r, []part{{"objects", sqlMSSQLNodeObjectsCompare, []any{ids, from, to, nil, kinds, search, cfrom, cto}}})
		return
	}
	s.multiPart(w, r, []part{{"objects", sqlMSSQLNodeObjects, []any{ids, from, to, nil, kinds, search}}})
}

// nodeObjectsMax: the most databases one node's Object Execution reads at once (each runs the three kinds' reads)
const nodeObjectsMax = 500
