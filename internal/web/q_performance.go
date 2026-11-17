package web

import (
	"errors"
	"net/http"
	"strconv"
)

// The instance Performance page (plan task 108, DBA Dash's Performance tab): GET /api/performance?instance=N[&from=&to=]
// is one instance's small charts over the range. Every part is cut into the same steps (about 120 over the range, a
// minute at least) and the part "grid" lists every step, so the page draws all charts on the same steps (it keeps the
// steps that hold a sample and breaks the lines where the samples stop for a while). The instance's engine chooses the parts:
//   PostgreSQL  meta, grid, cpu (host_sample), sessions (activity_summary), waits (wait_sample, else the activity
//               samples: the Waits tab's two sources), db (dbstats: commits, rollbacks, temp bytes), io (iostats =
//               pg_stat_io, and CloudWatch's volume figures beside it)
//   SQL Server  meta, grid, cpu (mssql_cpu_sample: the scheduler monitor's SQL Server and other processes' CPU),
//               sessions (mssql_requests_summary), waits (mssql_wait_sample by category), db (mssql_sched_sample: batch
//               requests, transactions and compilations per second), io (mssql_fileio_sample summed over the files:
//               read and write latency, MB/s).

// Every part takes $1 instance, $2 from, $3 to, $4 the step in seconds.
const sqlPerfMeta = `
SELECT i.instance_id, i.name AS instance, i.engine, i.platform, $4::int AS step_secs,
       (SELECT h.source FROM pgvigil.host_state h WHERE h.instance_id = i.instance_id) AS host_source
  FROM pgvigil.instances i
 WHERE i.instance_id = $1 AND $2::timestamptz < $3::timestamptz`

const sqlPerfGrid = `
SELECT to_timestamp(g * $4::bigint) AS snapshot_at
  FROM generate_series(floor(extract(epoch FROM $2::timestamptz) / $4)::bigint,
                       floor(extract(epoch FROM $3::timestamptz) / $4)::bigint) g
 WHERE $1::int IS NOT NULL
 ORDER BY 1`

const sqlPerfCPU = `
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at,
       round(avg(s.cpu_pct)::numeric, 1) AS cpu_avg, round(max(s.cpu_pct)::numeric, 1) AS cpu_max,
       round(avg(s.cpu_iowait_pct)::numeric, 1) AS iowait_avg
  FROM pgvigil.host_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND s.cpu_pct IS NOT NULL
 GROUP BY 1 ORDER BY 1`

const sqlPerfSessions = `
SELECT to_timestamp(floor(extract(epoch FROM x.snapshot_at) / $4) * $4) AS snapshot_at,
       round(avg(x.active), 2) AS active, round(avg(x.idle_in_txn), 2) AS idle_in_txn,
       round(avg(x.waiting_lock), 2) AS waiting_lock, round(avg(x.idle), 2) AS idle
  FROM pgvigil.activity_summary x
 WHERE x.instance_id = $1 AND x.snapshot_at > $2 AND x.snapshot_at <= $3
 GROUP BY 1 ORDER BY 1`

// sqlPerfWaits: milliseconds of wait per second by event type and step. The extension's rows when the range holds
// any (wait time over the seconds its reads cover), else the activity samples of active client sessions (one look a
// minute: a session seen waiting counts as waiting for that minute). The idling Activity type, an idle connection's
// ClientRead and the CPU pseudo-type are left out: the chart is what the work waited on.
const sqlPerfWaits = `
WITH raw AS (
  SELECT w.snapshot_at, w.event_type, w.event, w.queryid, w.wait_secs, coalesce(w.interval_secs, 60) AS secs
    FROM pgvigil.wait_sample w
   WHERE w.instance_id = $1 AND w.snapshot_at > $2 AND w.snapshot_at <= $3
     AND w.wait_secs IS NOT NULL   -- pgms_wait_sampling rows (and an unknown period) carry no time: the activity samples then
), cover AS (
  SELECT to_timestamp(floor(extract(epoch FROM r.snapshot_at) / $4) * $4) AS bucket, sum(r.secs)::float8 AS secs
    FROM (SELECT DISTINCT snapshot_at, secs FROM raw) r
   GROUP BY 1
), ext AS (
  SELECT c.bucket AS snapshot_at, r.event_type, 'wait_sample'::text AS source,
         round((1000 * sum(r.wait_secs) / max(c.secs))::numeric, 2)::float8 AS ms_s
    FROM raw r
    JOIN cover c ON c.bucket = to_timestamp(floor(extract(epoch FROM r.snapshot_at) / $4) * $4)
   WHERE r.event_type NOT IN ('CPU', 'Activity') AND NOT (r.event_type = 'Client' AND r.event = 'ClientRead' AND r.queryid = 0)
   GROUP BY 1, 2
), reads AS (
  SELECT to_timestamp(floor(extract(epoch FROM x.snapshot_at) / $4) * $4) AS bucket, count(*)::float8 AS n
    FROM pgvigil.activity_summary x
   WHERE x.instance_id = $1 AND x.snapshot_at > $2 AND x.snapshot_at <= $3 AND NOT EXISTS (SELECT 1 FROM raw)
   GROUP BY 1
), act AS (
  SELECT k.bucket AS snapshot_at, a.wait_event_type AS event_type, 'activity'::text AS source,
         round((1000 * count(*) / max(k.n))::numeric, 2)::float8 AS ms_s
    FROM pgvigil.activity_sample a
    JOIN reads k ON k.bucket = to_timestamp(floor(extract(epoch FROM a.snapshot_at) / $4) * $4)
   WHERE a.instance_id = $1 AND a.snapshot_at > $2 AND a.snapshot_at <= $3 AND a.state = 'active'
     AND a.wait_event_type IS NOT NULL AND a.wait_event_type <> 'Activity'
     AND coalesce(a.backend_type, 'client backend') = 'client backend'
   GROUP BY 1, 2
)
SELECT * FROM ext UNION ALL SELECT * FROM act ORDER BY 1, 2`

// sqlPerfDB: commits, rollbacks and temp bytes per second, each read's rate first (summed over the databases; a read in
// which a database's counters were reset gives no point), then the step's average. $5 = the lookback in seconds.
const sqlPerfDB = `
SELECT to_timestamp(floor(extract(epoch FROM p.snapshot_at) / $4) * $4) AS snapshot_at,
       round(avg(p.commits_s), 2) AS commits_s, round(avg(p.rollbacks_s), 2) AS rollbacks_s,
       round(avg(p.temp_bytes_s), 0) AS temp_bytes_s
  FROM (SELECT snapshot_at, sum(xact_commit)::numeric / max(interval_secs) AS commits_s,
               sum(xact_rollback)::numeric / max(interval_secs) AS rollbacks_s,
               sum(temp_bytes)::numeric / max(interval_secs) AS temp_bytes_s
          FROM pgvigil.dbstats_rate($1, $2, $3, make_interval(secs => $5))
         WHERE interval_secs > 0
         GROUP BY snapshot_at
        HAVING NOT bool_or(reset)) p
 GROUP BY 1 ORDER BY 1`

// sqlPerfIO: the read and write latency (time over operations) and the throughput per step from pg_stat_io, and
// CloudWatch's volume latency and throughput beside them (a five-minute period lands in the step it starts in).
// A time of 0 with operations (track_io_timing off) gives no latency.
const sqlPerfIO = `
WITH pg AS (
  SELECT to_timestamp(floor(extract(epoch FROM p.snapshot_at) / $4) * $4) AS snapshot_at,
         round((nullif(sum(p.read_time), 0) / nullif(sum(p.reads), 0))::numeric, 2) AS read_ms,
         round((nullif(sum(p.write_time), 0) / nullif(sum(p.writes), 0))::numeric, 2) AS write_ms,
         round(sum(p.read_bytes) / nullif(sum(p.secs), 0) / 1048576.0, 2) AS read_mb_s,
         round(sum(p.write_bytes) / nullif(sum(p.secs), 0) / 1048576.0, 2) AS write_mb_s
    FROM (SELECT snapshot_at, sum(reads) AS reads, sum(read_time) AS read_time, sum(writes) AS writes, sum(write_time) AS write_time,
                 sum(read_bytes) AS read_bytes, sum(write_bytes) AS write_bytes, max(interval_secs) AS secs
            FROM pgvigil.iostats_rate($1, $2, $3, make_interval(secs => $5))
           WHERE interval_secs > 0
           GROUP BY snapshot_at
          HAVING NOT bool_or(reset)) p
   GROUP BY 1
), cw AS (
  SELECT to_timestamp(floor(extract(epoch FROM m.snapshot_at) / $4) * $4) AS snapshot_at,
         round((1000 * avg(m.value) FILTER (WHERE m.metric = 'ReadLatency'))::numeric, 2) AS cw_read_ms,
         round((1000 * avg(m.value) FILTER (WHERE m.metric = 'WriteLatency'))::numeric, 2) AS cw_write_ms,
         round((avg(m.value) FILTER (WHERE m.metric = 'ReadThroughput') / 1048576.0)::numeric, 2) AS cw_read_mb_s,
         round((avg(m.value) FILTER (WHERE m.metric = 'WriteThroughput') / 1048576.0)::numeric, 2) AS cw_write_mb_s
    FROM pgvigil.cloud_io_sample m
   WHERE m.instance_id = $1 AND m.metric = ANY ('{ReadLatency,WriteLatency,ReadThroughput,WriteThroughput}')
     AND m.snapshot_at > $2 AND m.snapshot_at <= $3
   GROUP BY 1
)
SELECT snapshot_at, pg.read_ms, pg.write_ms, pg.read_mb_s, pg.write_mb_s, cw.cw_read_ms, cw.cw_write_ms, cw.cw_read_mb_s, cw.cw_write_mb_s
  FROM pg FULL JOIN cw USING (snapshot_at)
 ORDER BY 1`

const sqlPerfMSSQLSessions = `
SELECT to_timestamp(floor(extract(epoch FROM x.snapshot_at) / $4) * $4) AS snapshot_at,
       round(avg(x.requests), 2) AS requests, round(avg(x.blocked), 2) AS blocked, round(avg(x.sessions), 2) AS sessions,
       max(x.memory_grants_pending) AS memory_grants_pending
  FROM pgvigil.mssql_requests_summary x
 WHERE x.instance_id = $1 AND x.snapshot_at > $2 AND x.snapshot_at <= $3
 GROUP BY 1 ORDER BY 1`

// sqlPerfMSSQLWaits: milliseconds of wait per second by category and step (the idle background waits left out; a wait
// type without a category is 'Other').
const sqlPerfMSSQLWaits = `
WITH raw AS (
  SELECT w.snapshot_at, coalesce(nullif(w.category, ''), 'Other') AS event_type, w.is_benign, w.wait_ms, w.interval_secs
    FROM pgvigil.mssql_wait_sample w
   WHERE w.instance_id = $1 AND w.snapshot_at > $2 AND w.snapshot_at <= $3
), cover AS (
  SELECT to_timestamp(floor(extract(epoch FROM r.snapshot_at) / $4) * $4) AS bucket, sum(r.interval_secs)::float8 AS secs
    FROM (SELECT DISTINCT snapshot_at, interval_secs FROM raw) r
   GROUP BY 1
)
SELECT c.bucket AS snapshot_at, r.event_type, 'mssql_wait_sample'::text AS source,
       round((sum(r.wait_ms) / max(c.secs))::numeric, 2)::float8 AS ms_s
  FROM raw r
  JOIN cover c ON c.bucket = to_timestamp(floor(extract(epoch FROM r.snapshot_at) / $4) * $4)
 WHERE NOT r.is_benign
 GROUP BY 1, 2 ORDER BY 1, 2`

// sqlPerfMSSQLCPU: the machine's CPU per step from the scheduler monitor records (100 - idle), and the SQL Server
// process's share of it; on a Linux host (no idle figure) the total is the SQL Server share and machine_read false.
// On Azure SQL Database (B2a) the database's CPU of its limit from mssql_azuredb_minute, each minute weighed by its
// 15-second samples and its per-sample maximum the step's (DBA Dash's SQLCPU.sql reads sys.dm_db_resource_stats there);
// azure says which source the rows came from (the page's title and words follow it).
const sqlPerfMSSQLCPU = `
WITH p AS (SELECT CASE WHEN $3::timestamptz - $2::timestamptz > interval '1 day' AND (SELECT i.platform FROM pgvigil.instances i WHERE i.instance_id = $1) = 'azuresqldb'
                         THEN ceil($4::numeric / 3600) * 3600 ELSE $4::numeric END AS step)
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / p.step) * p.step) AS snapshot_at,
       round(sum(s.total * s.w) / nullif(sum(s.w) FILTER (WHERE s.total IS NOT NULL), 0), 1) AS cpu_avg, max(s.total_max) AS cpu_max,
       round(sum(s.sql_pct * s.w) / nullif(sum(s.w) FILTER (WHERE s.sql_pct IS NOT NULL), 0), 1) AS sql_avg,
       round(avg(s.other_pct), 1) AS other_avg, bool_or(s.machine) AS machine_read, bool_or(s.azure) AS azure
  FROM (SELECT c.snapshot_at, coalesce(100 - c.idle_pct, c.sql_pct)::numeric AS total, coalesce(100 - c.idle_pct, c.sql_pct)::numeric AS total_max,
               c.sql_pct::numeric AS sql_pct, c.other_pct, c.idle_pct IS NOT NULL AS machine, false AS azure, 1 AS w
          FROM pgvigil.mssql_cpu_sample c WHERE c.instance_id = $1 AND c.snapshot_at > $2 AND c.snapshot_at <= $3
        UNION ALL
        -- Azure SQL Database's window (DBA Dash's: a minute that starts in it): up to a day its minutes; past a day its
        -- built hours and edge minutes (pgvigil.mssql_azuredb_window, 0167) at a whole-hour step (an hour row lands whole
        -- in one step)
        SELECT a.snapshot_at, a.avg_cpu_percent, a.max_cpu_percent, a.avg_cpu_percent, NULL, false, true, a.samples
          FROM pgvigil.mssql_azuredb_minute a
         WHERE $3::timestamptz - $2::timestamptz <= interval '1 day' AND a.instance_id = $1 AND a.snapshot_at >= $2 AND a.snapshot_at < $3
        UNION ALL
        SELECT a.snapshot_at, a.cpu_total / nullif(a.cpu_counted, 0), a.max_cpu_percent, a.cpu_total / nullif(a.cpu_counted, 0), NULL, false, true, coalesce(a.cpu_counted, 0)
          FROM pgvigil.mssql_azuredb_window(ARRAY[$1::int], $2, $3) a WHERE $3::timestamptz - $2::timestamptz > interval '1 day') s, p
 GROUP BY 1 ORDER BY 1`

// sqlPerfMSSQLIO: every file's interval summed per read, then per step: latency = stall over operations, MB/s = bytes
// over the reads' seconds (mssql_fileio_read: an idle read's seconds count too).
const sqlPerfMSSQLIO = `
SELECT to_timestamp(floor(extract(epoch FROM p.snapshot_at) / $4) * $4) AS snapshot_at,
       round((sum(p.read_stall_ms)::numeric / nullif(sum(p.reads), 0)), 2) AS read_ms,
       round((sum(p.write_stall_ms)::numeric / nullif(sum(p.writes), 0)), 2) AS write_ms,
       round((sum(p.read_bytes) / nullif(sum(p.secs), 0) / 1048576.0)::numeric, 3) AS read_mb_s,
       round((sum(p.write_bytes) / nullif(sum(p.secs), 0) / 1048576.0)::numeric, 3) AS write_mb_s,
       round((sum(p.reads + p.writes) / nullif(sum(p.secs), 0))::numeric, 1) AS iops
  FROM (SELECT r.snapshot_at, coalesce(sum(f.reads), 0) AS reads, coalesce(sum(f.read_stall_ms), 0) AS read_stall_ms,
               coalesce(sum(f.writes), 0) AS writes, coalesce(sum(f.write_stall_ms), 0) AS write_stall_ms,
               coalesce(sum(f.read_bytes), 0) AS read_bytes, coalesce(sum(f.write_bytes), 0) AS write_bytes, max(r.interval_secs) AS secs
          FROM pgvigil.mssql_fileio_read r
          LEFT JOIN pgvigil.mssql_fileio_sample f ON f.instance_id = r.instance_id AND f.snapshot_at = r.snapshot_at
         WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
         GROUP BY r.snapshot_at) p
 GROUP BY 1 ORDER BY 1`

// sqlPerfMSSQLIODB: sqlPerfMSSQLIO cut to one database's files ($5, its name; P25 F101, DBA Dash's IO Performance:
// Database) and, with $6 not empty, to the data files of that file group (pgvigil.mssql_files' filegroup: a log file has
// none). A read with no file of the database keeps its step with no latency.
const sqlPerfMSSQLIODB = `
SELECT to_timestamp(floor(extract(epoch FROM p.snapshot_at) / $4) * $4) AS snapshot_at,
       round((sum(p.read_stall_ms)::numeric / nullif(sum(p.reads), 0)), 2) AS read_ms,
       round((sum(p.write_stall_ms)::numeric / nullif(sum(p.writes), 0)), 2) AS write_ms,
       round((sum(p.read_bytes) / nullif(sum(p.secs), 0) / 1048576.0)::numeric, 3) AS read_mb_s,
       round((sum(p.write_bytes) / nullif(sum(p.secs), 0) / 1048576.0)::numeric, 3) AS write_mb_s,
       round((sum(p.reads + p.writes) / nullif(sum(p.secs), 0))::numeric, 1) AS iops
  FROM (SELECT r.snapshot_at, coalesce(sum(f.reads), 0) AS reads, coalesce(sum(f.read_stall_ms), 0) AS read_stall_ms,
               coalesce(sum(f.writes), 0) AS writes, coalesce(sum(f.write_stall_ms), 0) AS write_stall_ms,
               coalesce(sum(f.read_bytes), 0) AS read_bytes, coalesce(sum(f.write_bytes), 0) AS write_bytes, max(r.interval_secs) AS secs
          FROM pgvigil.mssql_fileio_read r
          LEFT JOIN pgvigil.mssql_fileio_sample f ON f.instance_id = r.instance_id AND f.snapshot_at = r.snapshot_at
               AND f.database_name = $5::text
               AND ($6::text = '' OR EXISTS (SELECT 1 FROM pgvigil.mssql_files mf
                                             WHERE mf.instance_id = f.instance_id AND mf.database_id = f.database_id
                                               AND mf.file_id = f.file_id AND mf.filegroup = $6::text))
         WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
         GROUP BY r.snapshot_at) p
 GROUP BY 1 ORDER BY 1`

// sqlPerfMSSQLBlockingDB: the blocking chains whose head ran in one database ($5), per step: the most chains and
// blocked sessions any one read held (a read's chains summed) and the longest wait (DBA Dash's Blocking: Database).
const sqlPerfMSSQLBlockingDB = `
SELECT to_timestamp(floor(extract(epoch FROM b.snapshot_at) / $4) * $4) AS snapshot_at,
       max(b.chains) AS chains, max(b.victims) AS victims, max(b.longest_wait_ms) AS longest_wait_ms
  FROM (SELECT x.snapshot_at, count(*) AS chains, sum(x.victims) AS victims, max(x.longest_wait_ms) AS longest_wait_ms
          FROM pgvigil.mssql_blocking x
         WHERE x.instance_id = $1 AND x.snapshot_at > $2 AND x.snapshot_at <= $3 AND x.head_database = $5::text
         GROUP BY x.snapshot_at) b
 GROUP BY 1 ORDER BY 1`

// sqlPerfMSSQLFilegroups: one database's file groups (its present data files'), for the IO chart's filter.
const sqlPerfMSSQLFilegroups = `
SELECT DISTINCT mf.filegroup
  FROM pgvigil.mssql_files mf
 WHERE mf.instance_id = $1 AND mf.database_name = $2::text AND mf.is_present AND mf.filegroup IS NOT NULL
 ORDER BY 1`

// sqlPerfMSSQLExecStats: DBA Dash's Execution Stats on the SQL Server Performance page (P25 task 5, the sweep's L15):
// the procedures', functions' and triggers' samples (0084, 0343), the top $6 objects by the measure $5 over the
// window, each one's measure on each step of $4 seconds (counted from $9, seconds from the Unix epoch: 0 for the
// strip's own step procStep, never finer than the collections' five minutes; 1900-01-01 for one of DBA Dash's Date
// Groupings - step=, as dbo.DateGroupingMins counts), 0 on a step its OWN kind's reads cover where it did not run; a
// per-second or per-minute measure is over the seconds its own kind's reads cover in the step (the procedures' reads,
// the functions' and triggers' reads). One label per object: its database's newest name (procDBNames' rule over both
// kinds' samples) and its own schema and name (max() skips a read that gave up on a lock); each row carries
// database_id and object_id, the page's key. $7 one database by its newest name (its page), or empty: taken by its
// id, so its samples stored under an older name, or with none, count. Control audit E6: $5 is one of DBA Dash's
// fifteen measures (ObjectExecutionStats_Get's: value; the ranking by its total over the window, a rate by its raw
// total as DBA Dash's one period time ranks it) or one of the strip's older six per-second measures (per_sec beside
// value); $8 true = DBA Dash's Include Other: every object outside the top summed per step into one {Other} line (ids
// -1; its rates the sum of each kind's over its own seconds, its averages over the line as a whole), listed last.
var sqlPerfMSSQLExecStats = `
WITH x AS (
  SELECT 'p'::text AS k, p.snapshot_at, p.database_id, p.object_id, p.database_name, p.schema_name, p.object_name,
         p.duration_us, p.cpu_us, p.executions, p.logical_reads, p.physical_reads, p.logical_writes, p.interval_secs
    FROM pgvigil.mssql_proc_sample p
   WHERE p.instance_id = $1 AND p.snapshot_at > $2 AND p.snapshot_at <= $3
  UNION ALL
  SELECT 'f', f.snapshot_at, f.database_id, f.object_id, f.database_name, f.schema_name, f.object_name,
         f.duration_us, f.cpu_us, f.executions, f.logical_reads, f.physical_reads, f.logical_writes, f.interval_secs
    FROM pgvigil.mssql_func_sample f
   WHERE f.instance_id = $1 AND f.snapshot_at > $2 AND f.snapshot_at <= $3
), dbn AS (
  SELECT DISTINCT ON (x.database_id) x.database_id, coalesce(x.database_name, 'database ' || x.database_id) AS database
    FROM x
   ORDER BY x.database_id, (x.database_name IS NULL), x.snapshot_at DESC
), s AS (
  SELECT x.k, ` + stepBucket("x.snapshot_at", "$4", "$9") + ` AS step, x.database_id, x.object_id,
         n.database, x.schema_name, x.object_name,
         x.duration_us::float8 AS d, x.cpu_us::float8 AS c, x.executions::float8 AS e, x.logical_reads::float8 AS lr,
         x.physical_reads::float8 AS pr, x.logical_writes::float8 AS lw, x.executions * 60.0 / nullif(x.interval_secs, 0) AS mx
    FROM x JOIN dbn n ON n.database_id = x.database_id
   WHERE $7::text = '' OR n.database = $7::text
), o AS (
  SELECT s.k, s.database_id, s.object_id, s.database, max(s.schema_name) AS schema_name, max(s.object_name) AS object_name,
         sum(s.d) AS d, sum(s.c) AS c, sum(s.e) AS e, sum(s.lr) AS lr, sum(s.pr) AS pr, sum(s.lw) AS lw, max(s.mx) AS mx
    FROM s
   GROUP BY s.k, s.database_id, s.object_id, s.database
), top AS (
  SELECT o.k, o.database_id, o.object_id,
         o.database || '.' || coalesce(o.schema_name, '') || '.' || coalesce(o.object_name, 'object ' || o.object_id) AS name
    FROM o
   ORDER BY ` + execStatsRank + ` DESC NULLS LAST, o.database_id, o.object_id, o.k
   LIMIT $6
), cover AS (
  SELECT 'p'::text AS k, ` + stepBucket("r.snapshot_at", "$4", "$9") + ` AS step, sum(r.interval_secs)::float8 AS secs
    FROM pgvigil.mssql_proc_read r
   WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
   GROUP BY 2
  UNION ALL
  SELECT 'f', ` + stepBucket("r.snapshot_at", "$4", "$9") + `, sum(r.interval_secs)::float8
    FROM pgvigil.mssql_func_read r
   WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
   GROUP BY 2
), w AS (
  SELECT s.k, s.step, coalesce(t.database_id, -1) AS database_id, coalesce(t.object_id, -1) AS object_id,
         sum(s.d) AS d, sum(s.c) AS c, sum(s.e) AS e, sum(s.lr) AS lr, sum(s.pr) AS pr, sum(s.lw) AS lw, max(s.mx) AS mx
    FROM s LEFT JOIN top t ON t.k = s.k AND t.database_id = s.database_id AND t.object_id = s.object_id
   WHERE t.object_id IS NOT NULL OR $8::bool
   GROUP BY 1, 2, 3, 4
), lines AS (
  SELECT t.k, t.database_id, t.object_id, t.name FROM top t
  UNION ALL
  SELECT kk.k, -1, -1, '{Other}' FROM (VALUES ('p'::text), ('f')) kk(k)
   WHERE $8::bool AND EXISTS (SELECT 1 FROM o WHERE NOT EXISTS (
           SELECT 1 FROM top t WHERE t.k = o.k AND t.database_id = o.database_id AND t.object_id = o.object_id))
), r AS (
  SELECT c.step, l.database_id, l.object_id, l.name, c.secs, coalesce(w.d, 0) AS d, coalesce(w.c, 0) AS c, coalesce(w.e, 0) AS e,
         coalesce(w.lr, 0) AS lr, coalesce(w.pr, 0) AS pr, coalesce(w.lw, 0) AS lw, w.mx
    FROM lines l
    JOIN cover c ON c.k = l.k AND c.secs > 0
    LEFT JOIN w ON w.k = l.k AND w.step = c.step AND w.database_id = l.database_id AND w.object_id = l.object_id
)
SELECT r.step AS snapshot_at, r.database_id, r.object_id, r.name AS object,
       round((` + execStatsValue + `)::numeric, 6) AS value, round((` + execStatsValue + `)::numeric, 3) AS per_sec
  FROM r
 GROUP BY r.step, r.database_id, r.object_id, r.name
 ORDER BY 1, (r.object_id = -1), 4, 2, 3`

// execStatsRank: an object's rank over the window (alias o: its raw sums): DBA Dash's measure over the window, a rate
// by its raw total (DBA Dash ranks it over one period time)
const execStatsRank = `CASE $5::text
         WHEN 'AvgDuration' THEN o.d / nullif(o.e, 0) WHEN 'AvgCPU' THEN o.c / nullif(o.e, 0)
         WHEN 'MaxExecutionsPerMin' THEN o.mx
         WHEN 'AvgLogicalReads' THEN o.lr / nullif(o.e, 0) WHEN 'AvgPhysicalReads' THEN o.pr / nullif(o.e, 0) WHEN 'AvgWrites' THEN o.lw / nullif(o.e, 0)
         WHEN 'TotalDuration' THEN o.d WHEN 'duration_ms_per_sec' THEN o.d WHEN 'duration' THEN o.d
         WHEN 'TotalCPU' THEN o.c WHEN 'cpu_ms_per_sec' THEN o.c WHEN 'cpu' THEN o.c
         WHEN 'ExecutionCount' THEN o.e WHEN 'ExecutionsPerMin' THEN o.e WHEN 'executions' THEN o.e
         WHEN 'TotalLogicalReads' THEN o.lr WHEN 'logical_reads' THEN o.lr
         WHEN 'TotalPhysicalReads' THEN o.pr WHEN 'physical_reads' THEN o.pr
         ELSE o.lw END`

// execStatsValue: a line's measure on a step (alias r: its rows, one per kind - {Other}'s two kinds - each with its
// kind's covered seconds): DBA Dash's ObjectExecutionStats_Get columns, and the older six per second
const execStatsValue = `CASE $5::text
         WHEN 'TotalDuration' THEN sum(r.d) / 1000000.0 WHEN 'duration_ms_per_sec' THEN sum(r.d / 1000.0 / r.secs)
         WHEN 'AvgDuration' THEN sum(r.d) / nullif(sum(r.e), 0) / 1000000.0
         WHEN 'TotalCPU' THEN sum(r.c) / 1000000.0 WHEN 'cpu_ms_per_sec' THEN sum(r.c / 1000.0 / r.secs)
         WHEN 'AvgCPU' THEN sum(r.c) / nullif(sum(r.e), 0) / 1000000.0
         WHEN 'ExecutionCount' THEN sum(r.e) WHEN 'ExecutionsPerMin' THEN sum(r.e * 60.0 / r.secs) WHEN 'MaxExecutionsPerMin' THEN max(r.mx)
         WHEN 'TotalLogicalReads' THEN sum(r.lr) WHEN 'AvgLogicalReads' THEN sum(r.lr) / nullif(sum(r.e), 0)
         WHEN 'TotalPhysicalReads' THEN sum(r.pr) WHEN 'AvgPhysicalReads' THEN sum(r.pr) / nullif(sum(r.e), 0)
         WHEN 'TotalWrites' THEN sum(r.lw) WHEN 'AvgWrites' THEN sum(r.lw) / nullif(sum(r.e), 0)
         WHEN 'duration' THEN sum(r.d / 1000.0 / r.secs) WHEN 'cpu' THEN sum(r.c / 1000.0 / r.secs) WHEN 'executions' THEN sum(r.e / r.secs)
         WHEN 'logical_reads' THEN sum(r.lr / r.secs) WHEN 'physical_reads' THEN sum(r.pr / r.secs)
         ELSE sum(r.lw / r.secs) END`

// execStatsMeasures: the Execution Stats strip's measures - DBA Dash's fifteen (control audit E6) and the strip's older
// six per-second ones
var execStatsMeasures = map[string]bool{"duration": true, "cpu": true, "executions": true, "logical_reads": true, "physical_reads": true, "writes": true,
	"TotalDuration": true, "duration_ms_per_sec": true, "AvgDuration": true, "TotalCPU": true, "cpu_ms_per_sec": true, "AvgCPU": true,
	"ExecutionCount": true, "ExecutionsPerMin": true, "MaxExecutionsPerMin": true, "TotalLogicalReads": true, "AvgLogicalReads": true,
	"TotalPhysicalReads": true, "AvgPhysicalReads": true, "TotalWrites": true, "AvgWrites": true}

// Performance is GET /api/performance?instance=N[&from=&to=][&db=<database>[&filegroup=<name>]][&part=...]: one
// instance's Performance page.
// A SQL Server database (db=, P25 F101): its IO, its blocking and its file groups; CPU, sessions and waits stay the
// instance's (the store keeps no per-database row of them).
func (s *Server) Performance(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	step := int(to.Sub(from).Seconds()) / 120
	if step < 60 {
		step = 60
	}
	var engine string
	if err := s.pool.QueryRow(r.Context(), `SELECT engine FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&engine); err != nil {
		engine = "postgres" // an unknown instance: the PostgreSQL parts, all empty
	}
	base := []any{id, from, to, step}
	parts := []part{{"meta", sqlPerfMeta, base}, {"grid", sqlPerfGrid, base}}
	if engine == "sqlserver" {
		parts = append(parts, part{"cpu", sqlPerfMSSQLCPU, base}, part{"sessions", sqlPerfMSSQLSessions, base},
			part{"waits", sqlPerfMSSQLWaits, base}, part{"db", sqlMSSQLCounterSeries, base})
		// the Execution Stats strip: read only when asked (part=execstats), with its measure and top
		if q := r.URL.Query(); q.Get("part") == "execstats" {
			measure, top := q.Get("measure"), 5
			if measure == "" {
				measure = "duration"
			}
			if !execStatsMeasures[measure] {
				writeErr(w, http.StatusBadRequest, errors.New("measure must be one of DBA Dash's TotalDuration, duration_ms_per_sec, AvgDuration, TotalCPU, "+
					"cpu_ms_per_sec, AvgCPU, ExecutionCount, ExecutionsPerMin, MaxExecutionsPerMin, TotalLogicalReads, AvgLogicalReads, "+
					"TotalPhysicalReads, AvgPhysicalReads, TotalWrites, AvgWrites, or duration, cpu, executions, logical_reads, physical_reads, writes"))
				return
			}
			// DBA Dash's Date Grouping (control audit E6) or the strip's own step
			esStep, esBase, err := procHistoryStep(q.Get("step"), to.Sub(from))
			if err != nil {
				writeErr(w, http.StatusBadRequest, err)
				return
			}
			if v := q.Get("top"); v != "" {
				n, err := strconv.Atoi(v)
				if err != nil || n < 1 || n > 50 {
					writeErr(w, http.StatusBadRequest, errors.New("top must be 1 to 50"))
					return
				}
				top = n
			}
			// the strip's own step (procStep), and the two collections' state for its empty words
			parts = append(parts, part{"execstats", sqlPerfMSSQLExecStats, []any{id, from, to, esStep, measure, top, q.Get("db"), q.Get("include_other") == "1", esBase}},
				part{"execstats_state", sqlMssqlRunningState, []any{id, []string{"mssql_procstats", "mssql_funcstats"}}})
		}
		if db := r.URL.Query().Get("db"); db != "" {
			cut := []any{id, from, to, step, db, r.URL.Query().Get("filegroup")}
			parts = append(parts, part{"io", sqlPerfMSSQLIODB, cut}, part{"blocking", sqlPerfMSSQLBlockingDB, cut[:5]},
				part{"filegroups", sqlPerfMSSQLFilegroups, []any{id, db}})
		} else {
			parts = append(parts, part{"io", sqlPerfMSSQLIO, base})
		}
	} else {
		parts = append(parts,
			part{"cpu", sqlPerfCPU, base},
			part{"sessions", sqlPerfSessions, base},
			part{"waits", sqlPerfWaits, base},
			part{"db", sqlPerfDB, []any{id, from, to, step, s.rateLookback(r.Context(), id, "dbstats")}},
			part{"io", sqlPerfIO, []any{id, from, to, step, s.rateLookback(r.Context(), id, "iostats")}})
	}
	s.multiPart(w, r, parts)
}
