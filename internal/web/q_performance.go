package web

import (
	"net/http"
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
const sqlPerfMSSQLCPU = `
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at,
       round(avg(coalesce(100 - s.idle_pct, s.sql_pct)), 1) AS cpu_avg, max(coalesce(100 - s.idle_pct, s.sql_pct)) AS cpu_max, round(avg(s.sql_pct), 1) AS sql_avg,
       round(avg(s.other_pct), 1) AS other_avg, bool_or(s.idle_pct IS NOT NULL) AS machine_read
  FROM pgvigil.mssql_cpu_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
 GROUP BY 1 ORDER BY 1`

// sqlPerfMSSQLIO: every file's interval summed per read, then per step: latency = stall over operations, MB/s = bytes
// over the reads' seconds.
const sqlPerfMSSQLIO = `
SELECT to_timestamp(floor(extract(epoch FROM p.snapshot_at) / $4) * $4) AS snapshot_at,
       round((sum(p.read_stall_ms)::numeric / nullif(sum(p.reads), 0)), 2) AS read_ms,
       round((sum(p.write_stall_ms)::numeric / nullif(sum(p.writes), 0)), 2) AS write_ms,
       round((sum(p.read_bytes) / nullif(sum(p.secs), 0) / 1048576.0)::numeric, 3) AS read_mb_s,
       round((sum(p.write_bytes) / nullif(sum(p.secs), 0) / 1048576.0)::numeric, 3) AS write_mb_s,
       round((sum(p.reads + p.writes) / nullif(sum(p.secs), 0))::numeric, 1) AS iops
  FROM (SELECT f.snapshot_at, sum(f.reads) AS reads, sum(f.read_stall_ms) AS read_stall_ms, sum(f.writes) AS writes,
               sum(f.write_stall_ms) AS write_stall_ms, sum(f.read_bytes) AS read_bytes, sum(f.write_bytes) AS write_bytes,
               max(f.interval_secs) AS secs
          FROM pgvigil.mssql_fileio_sample f
         WHERE f.instance_id = $1 AND f.snapshot_at > $2 AND f.snapshot_at <= $3
         GROUP BY f.snapshot_at) p
 GROUP BY 1 ORDER BY 1`

// Performance is GET /api/performance?instance=N[&from=&to=][&part=...]: one instance's Performance page.
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
			part{"waits", sqlPerfMSSQLWaits, base}, part{"db", sqlMSSQLCounterSeries, base}, part{"io", sqlPerfMSSQLIO, base})
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
