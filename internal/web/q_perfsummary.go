package web

import (
	"context"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5"
)

// The Performance summary (plan task 108): GET /api/perfsummary?[from=&to=][&tag=] is the fleet page of DBA Dash's
// Performance Summary: one row per active instance in the scope, both engines, over the range. One statement per
// engine. Every read is driven from the instance list and reaches each history table through its
// (instance_id, snapshot_at) index (cloud_io_sample: instance_id, metric, snapshot_at), so the work grows with the
// instances in the scope times the samples of the range, never with the retention.
//
// What a column is, per engine:
//   cpu_*            PostgreSQL: host_sample.cpu_pct (system_stats or CloudWatch); no sample in the range = NULL (the
//                    page says 'no host read'). SQL Server: no CPU collection yet = NULL ('not read').
//   cpu_hist         the samples of the range in ten buckets of 10 % (the last one holds 90 to 100).
//   active_*         PostgreSQL: activity_summary.active; SQL Server: mssql_requests_summary.requests.
//   *_ms_s           milliseconds of wait per second of the range, by class. PostgreSQL: wait_sample by event type
//                    (pg_wait_sampling; the idling Activity type and an idle connection's ClientRead left out, as on
//                    the Waits tab; the CPU pseudo-type is not a wait; a row without a time, pgms_wait_sampling's, is left out). Where the instance has no wait_sample row in
//                    the range, lock_ms_s alone is estimated from activity_summary.waiting_lock (the sessions seen
//                    waiting on a lock at each minute's sample x 1000) and wait_source says 'activity'.
//                    SQL Server: mssql_wait_sample by category, the idle background waits left out.
//   signal_pct       SQL Server only: the part of the wait time spent runnable, waiting for a CPU.
//   commits_s ...    PostgreSQL: dbstats, the counters' rise per restart epoch (0010) summed over the databases.
//   read_ms ...      PostgreSQL: iostats (pg_stat_io, PostgreSQL 16+; a time of 0 with operations = track_io_timing
//                    off = NULL), else CloudWatch's ReadLatency / WriteLatency / *Throughput (cloud_io_sample),
//                    each column on its own; latency_source and io_source name which. SQL Server: not collected = NULL.
//   now_*            the newest snapshot inside the range (a preset range ends now): the longest running statement,
//                    the oldest open transaction, the sessions blocked.

// sqlPerfScope is the instances of one engine ($3) in the tag scope ($4; NULL = the fleet, 'untagged' = no tag).
const sqlPerfScope = `
WITH inst AS (
  SELECT i.instance_id, i.name AS instance, i.engine, i.platform
    FROM pgvigil.instances i
    LEFT JOIN pgvigil.instance_tags_merged tm ON tm.instance_id = i.instance_id
   WHERE i.is_active AND i.engine = $3
     AND ($4::text IS NULL
          OR CASE WHEN $4 = 'untagged' THEN cardinality(coalesce(tm.tags, i.tags)) = 0
                  ELSE $4 = ANY (coalesce(tm.tags, i.tags)) END)
)`

// sqlPerfSummaryPG: the PostgreSQL instances. $1 from, $2 to, $3 'postgres', $4 tag.
const sqlPerfSummaryPG = sqlPerfScope + `
SELECT inst.instance_id, inst.instance, inst.engine, inst.platform,
       h.cpu_samples, h.cpu_avg, h.cpu_max, h.cpu_hist,
       round(100.0 * (h.cpu_hist[8] + h.cpu_hist[9] + h.cpu_hist[10]) / nullif(h.cpu_samples, 0), 1) AS cpu_hot_pct,
       a.active_avg, a.active_max,
       CASE WHEN w.covered_secs > 0 THEN 'wait_sample' WHEN a.reads > 0 THEN 'activity' END AS wait_source,
       CASE WHEN w.covered_secs > 0 THEN round((1000 * w.lock_s / w.covered_secs)::numeric, 2)
            ELSE round(1000 * a.waiting_lock_avg, 2) END AS lock_ms_s,
       round((1000 * w.io_s / nullif(w.covered_secs, 0))::numeric, 2) AS io_ms_s,
       round((1000 * w.lwlock_s / nullif(w.covered_secs, 0))::numeric, 2) AS lwlock_ms_s,
       round((1000 * w.ipc_s / nullif(w.covered_secs, 0))::numeric, 2) AS ipc_ms_s,
       round((1000 * w.client_s / nullif(w.covered_secs, 0))::numeric, 2) AS client_ms_s,
       round((1000 * w.other_s / nullif(w.covered_secs, 0))::numeric, 2) AS other_ms_s,
       round((1000 * w.total_s / nullif(w.covered_secs, 0))::numeric, 2) AS total_ms_s,
       NULL::numeric AS signal_pct,
       round(d.commits / nullif(d.secs, 0), 2) AS commits_s,
       round(d.rollbacks / nullif(d.secs, 0), 2) AS rollbacks_s,
       round((d.commits + d.rollbacks) / nullif(d.secs, 0), 2) AS tps,
       round(d.temp_bytes / nullif(d.secs, 0), 0) AS temp_bytes_s,
       -- each column from pg_stat_io where it has the figure (latency needs track_io_timing), else CloudWatch
       CASE WHEN io.read_time IS NOT NULL OR io.write_time IS NOT NULL THEN 'pg_stat_io' WHEN c.read_latency_s IS NOT NULL THEN 'cloudwatch' END AS latency_source,
       CASE WHEN io.secs > 0 THEN 'pg_stat_io' WHEN c.points > 0 THEN 'cloudwatch' END AS io_source,
       coalesce(round((io.read_time / nullif(io.reads, 0))::numeric, 2), round((1000 * c.read_latency_s)::numeric, 2)) AS read_ms,
       coalesce(round((io.write_time / nullif(io.writes, 0))::numeric, 2), round((1000 * c.write_latency_s)::numeric, 2)) AS write_ms,
       CASE WHEN io.secs > 0 THEN round(io.bytes / io.secs / 1048576.0, 2)
            WHEN c.points > 0 THEN round((c.throughput_bytes_s / 1048576.0)::numeric, 2) END AS mb_s,
       n.now_at, n.longest_active_secs AS now_longest_stmt_secs, n.oldest_xact_secs AS now_oldest_xact_secs,
       n.waiting_lock AS now_blocked
  FROM inst
  LEFT JOIN LATERAL (
    SELECT count(*) AS cpu_samples, round(avg(s.cpu_pct)::numeric, 1) AS cpu_avg, round(max(s.cpu_pct)::numeric, 1) AS cpu_max,
           ARRAY[count(*) FILTER (WHERE s.cpu_pct < 10), count(*) FILTER (WHERE s.cpu_pct >= 10 AND s.cpu_pct < 20),
                 count(*) FILTER (WHERE s.cpu_pct >= 20 AND s.cpu_pct < 30), count(*) FILTER (WHERE s.cpu_pct >= 30 AND s.cpu_pct < 40),
                 count(*) FILTER (WHERE s.cpu_pct >= 40 AND s.cpu_pct < 50), count(*) FILTER (WHERE s.cpu_pct >= 50 AND s.cpu_pct < 60),
                 count(*) FILTER (WHERE s.cpu_pct >= 60 AND s.cpu_pct < 70), count(*) FILTER (WHERE s.cpu_pct >= 70 AND s.cpu_pct < 80),
                 count(*) FILTER (WHERE s.cpu_pct >= 80 AND s.cpu_pct < 90), count(*) FILTER (WHERE s.cpu_pct >= 90)]::int[] AS cpu_hist
      FROM pgvigil.host_sample s
     WHERE s.instance_id = inst.instance_id AND s.snapshot_at > $1 AND s.snapshot_at <= $2 AND s.cpu_pct IS NOT NULL) h ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS reads, round(avg(x.active), 2) AS active_avg, max(x.active) AS active_max,
           avg(x.waiting_lock) AS waiting_lock_avg
      FROM pgvigil.activity_summary x
     WHERE x.instance_id = inst.instance_id AND x.snapshot_at > $1 AND x.snapshot_at <= $2) a ON true
  LEFT JOIN LATERAL (
    -- one row per read first: a read's seconds count once, a quiet read included
    SELECT sum(r.secs) AS covered_secs, sum(r.lock_s) AS lock_s, sum(r.io_s) AS io_s, sum(r.lwlock_s) AS lwlock_s,
           sum(r.ipc_s) AS ipc_s, sum(r.client_s) AS client_s, sum(r.other_s) AS other_s, sum(r.total_s) AS total_s
      FROM (SELECT max(coalesce(ws.interval_secs, 60)) AS secs,
                   coalesce(sum(ws.wait_secs) FILTER (WHERE ws.event_type = 'Lock'), 0) AS lock_s,
                   coalesce(sum(ws.wait_secs) FILTER (WHERE ws.event_type = 'IO'), 0) AS io_s,
                   coalesce(sum(ws.wait_secs) FILTER (WHERE ws.event_type IN ('LWLock', 'BufferPin')), 0) AS lwlock_s,
                   coalesce(sum(ws.wait_secs) FILTER (WHERE ws.event_type = 'IPC'), 0) AS ipc_s,
                   coalesce(sum(ws.wait_secs) FILTER (WHERE ws.event_type = 'Client' AND NOT (ws.event = 'ClientRead' AND ws.queryid = 0)), 0) AS client_s,
                   coalesce(sum(ws.wait_secs) FILTER (WHERE ws.event_type NOT IN ('Lock', 'IO', 'LWLock', 'BufferPin', 'IPC', 'Client', 'CPU', 'Activity')), 0) AS other_s,
                   coalesce(sum(ws.wait_secs) FILTER (WHERE ws.event_type NOT IN ('CPU', 'Activity')
                                                        AND NOT (ws.event_type = 'Client' AND ws.event = 'ClientRead' AND ws.queryid = 0)), 0) AS total_s
              FROM pgvigil.wait_sample ws
             WHERE ws.instance_id = inst.instance_id AND ws.snapshot_at > $1 AND ws.snapshot_at <= $2
               AND ws.wait_secs IS NOT NULL   -- pgms_wait_sampling rows (and an unknown profile period) carry no time
             GROUP BY ws.snapshot_at) r) w ON true
  LEFT JOIN LATERAL (
    -- a counter's rise inside one restart epoch of one database is max - min; the seconds are the longest span any
    -- database's epochs cover
    SELECT sum(e.commits) AS commits, sum(e.rollbacks) AS rollbacks, sum(e.temp_bytes) AS temp_bytes, max(e.secs) AS secs
      FROM (SELECT sum(g.commits) AS commits, sum(g.rollbacks) AS rollbacks, sum(g.temp_bytes) AS temp_bytes, sum(g.secs) AS secs
              FROM (SELECT ds.dbid, (max(ds.xact_commit) - min(ds.xact_commit))::numeric AS commits,
                           (max(ds.xact_rollback) - min(ds.xact_rollback))::numeric AS rollbacks,
                           (max(ds.temp_bytes) - min(ds.temp_bytes))::numeric AS temp_bytes,
                           extract(epoch FROM max(ds.snapshot_at) - min(ds.snapshot_at))::numeric AS secs
                      FROM pgvigil.dbstats ds
                     WHERE ds.instance_id = inst.instance_id AND ds.snapshot_at > $1 AND ds.snapshot_at <= $2
                     GROUP BY ds.dbid, ds.epoch, ds.stats_reset) g
             GROUP BY g.dbid) e) d ON true
  LEFT JOIN LATERAL (
    -- pg_stat_io's counters rise until stats_reset moves: max - min per row key and reset; PostgreSQL 16 and 17
    -- give operations and op_bytes, 18 gives bytes
    -- the segments of one row key (split by a reset) add up first, then the seconds are the longest span any key covers
    SELECT sum(k.reads) AS reads, sum(k.writes) AS writes, nullif(sum(k.read_time), 0) AS read_time,
           nullif(sum(k.write_time), 0) AS write_time, sum(k.bytes) AS bytes, max(k.secs) AS secs
      FROM (SELECT sum(g.reads) AS reads, sum(g.writes) AS writes, sum(g.read_time) AS read_time, sum(g.write_time) AS write_time,
                   sum(g.bytes) AS bytes, sum(g.secs) AS secs
              FROM (SELECT o.backend_type, o.object, o.context, (max(o.reads) - min(o.reads))::numeric AS reads, (max(o.writes) - min(o.writes))::numeric AS writes,
                   max(o.read_time) - min(o.read_time) AS read_time, max(o.write_time) - min(o.write_time) AS write_time,
                   coalesce(max(o.read_bytes) - min(o.read_bytes), (max(o.reads) - min(o.reads)) * max(o.op_bytes), 0)
                   + coalesce(max(o.write_bytes) - min(o.write_bytes), (max(o.writes) - min(o.writes)) * max(o.op_bytes), 0) AS bytes,
                   extract(epoch FROM max(o.snapshot_at) - min(o.snapshot_at))::numeric AS secs
              FROM pgvigil.iostats o
             WHERE o.instance_id = inst.instance_id AND o.snapshot_at > $1 AND o.snapshot_at <= $2
             GROUP BY o.backend_type, o.object, o.context, o.stats_reset) g
             GROUP BY g.backend_type, g.object, g.context) k) io ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS points, avg(m.value) FILTER (WHERE m.metric = 'ReadLatency') AS read_latency_s,
           avg(m.value) FILTER (WHERE m.metric = 'WriteLatency') AS write_latency_s,
           coalesce(avg(m.value) FILTER (WHERE m.metric = 'ReadThroughput'), 0)
           + coalesce(avg(m.value) FILTER (WHERE m.metric = 'WriteThroughput'), 0) AS throughput_bytes_s
      FROM pgvigil.cloud_io_sample m
     WHERE m.instance_id = inst.instance_id AND m.metric = ANY ('{ReadLatency,WriteLatency,ReadThroughput,WriteThroughput}')
       AND m.snapshot_at > $1 AND m.snapshot_at <= $2) c ON true
  LEFT JOIN LATERAL (
    SELECT x.snapshot_at AS now_at, x.longest_active_secs, x.waiting_lock,
           (SELECT round(max(extract(epoch FROM p.snapshot_at - p.xact_start))::numeric, 0)
              FROM pgvigil.activity_sample p
             WHERE p.instance_id = x.instance_id AND p.snapshot_at = x.snapshot_at AND p.xact_start IS NOT NULL
               AND coalesce(p.backend_type, 'client backend') = 'client backend') AS oldest_xact_secs
      FROM pgvigil.activity_summary x
     WHERE x.instance_id = inst.instance_id AND x.snapshot_at > $1 AND x.snapshot_at <= $2
     ORDER BY x.snapshot_at DESC LIMIT 1) n ON true
 ORDER BY inst.instance`

// sqlPerfSummaryMSSQL: the SQL Server instances, the same columns. $1 from, $2 to, $3 'sqlserver', $4 tag. The wait
// classes are the collector's categories (internal/mssql/waits.go): Locking; Disk and Transaction log as IO; the
// latch categories; Parallelism beside PostgreSQL's IPC; the client and query category beside Client.
const sqlPerfSummaryMSSQL = sqlPerfScope + `
SELECT inst.instance_id, inst.instance, inst.engine, inst.platform,
       NULL::bigint AS cpu_samples, NULL::numeric AS cpu_avg, NULL::numeric AS cpu_max, NULL::int[] AS cpu_hist, NULL::numeric AS cpu_hot_pct,
       a.active_avg, a.active_max,
       CASE WHEN w.covered_secs > 0 THEN 'mssql_wait_sample' END AS wait_source,
       round((w.lock_ms / nullif(w.covered_secs, 0))::numeric, 2) AS lock_ms_s,
       round((w.io_ms / nullif(w.covered_secs, 0))::numeric, 2) AS io_ms_s,
       round((w.latch_ms / nullif(w.covered_secs, 0))::numeric, 2) AS lwlock_ms_s,
       round((w.parallel_ms / nullif(w.covered_secs, 0))::numeric, 2) AS ipc_ms_s,
       round((w.client_ms / nullif(w.covered_secs, 0))::numeric, 2) AS client_ms_s,
       round((w.other_ms / nullif(w.covered_secs, 0))::numeric, 2) AS other_ms_s,
       round((w.total_ms / nullif(w.covered_secs, 0))::numeric, 2) AS total_ms_s,
       round((100 * w.signal_ms / nullif(w.total_ms, 0))::numeric, 1) AS signal_pct,
       NULL::numeric AS commits_s, NULL::numeric AS rollbacks_s, NULL::numeric AS tps, NULL::numeric AS temp_bytes_s,
       NULL::text AS latency_source, NULL::text AS io_source, NULL::numeric AS read_ms, NULL::numeric AS write_ms, NULL::numeric AS mb_s,
       n.now_at, n.longest_stmt_secs AS now_longest_stmt_secs, n.oldest_xact_secs AS now_oldest_xact_secs, n.blocked AS now_blocked
  FROM inst
  LEFT JOIN LATERAL (
    SELECT round(avg(x.requests), 2) AS active_avg, max(x.requests) AS active_max
      FROM pgvigil.mssql_requests_summary x
     WHERE x.instance_id = inst.instance_id AND x.snapshot_at > $1 AND x.snapshot_at <= $2) a ON true
  LEFT JOIN LATERAL (
    SELECT sum(r.secs) AS covered_secs, sum(r.lock_ms) AS lock_ms, sum(r.io_ms) AS io_ms, sum(r.latch_ms) AS latch_ms,
           sum(r.parallel_ms) AS parallel_ms, sum(r.client_ms) AS client_ms, sum(r.total_ms) AS total_ms,
           sum(r.total_ms - r.lock_ms - r.io_ms - r.latch_ms - r.parallel_ms - r.client_ms) AS other_ms, sum(r.signal_ms) AS signal_ms
      FROM (SELECT max(ws.interval_secs)::float8 AS secs,
                   coalesce(sum(ws.wait_ms) FILTER (WHERE NOT ws.is_benign AND ws.category = 'Locking'), 0)::float8 AS lock_ms,
                   coalesce(sum(ws.wait_ms) FILTER (WHERE NOT ws.is_benign AND ws.category IN ('Disk', 'Transaction log')), 0)::float8 AS io_ms,
                   coalesce(sum(ws.wait_ms) FILTER (WHERE NOT ws.is_benign AND ws.category ILIKE '%latch%'), 0)::float8 AS latch_ms,
                   coalesce(sum(ws.wait_ms) FILTER (WHERE NOT ws.is_benign AND ws.category = 'Parallelism'), 0)::float8 AS parallel_ms,
                   coalesce(sum(ws.wait_ms) FILTER (WHERE NOT ws.is_benign AND ws.category LIKE 'Query (client%'), 0)::float8 AS client_ms,
                   coalesce(sum(ws.wait_ms) FILTER (WHERE NOT ws.is_benign), 0)::float8 AS total_ms,
                   coalesce(sum(ws.signal_ms) FILTER (WHERE NOT ws.is_benign), 0)::float8 AS signal_ms
              FROM pgvigil.mssql_wait_sample ws
             WHERE ws.instance_id = inst.instance_id AND ws.snapshot_at > $1 AND ws.snapshot_at <= $2
             GROUP BY ws.snapshot_at) r) w ON true
  LEFT JOIN LATERAL (
    SELECT x.snapshot_at AS now_at, x.blocked, q.longest_stmt_secs, q.oldest_xact_secs
      FROM pgvigil.mssql_requests_summary x
      LEFT JOIN LATERAL (
        SELECT round(max(p.elapsed_ms) FILTER (WHERE p.request_id IS NOT NULL) / 1000.0, 0) AS longest_stmt_secs,
               round(max(extract(epoch FROM p.snapshot_at - p.tran_start))::numeric, 0) AS oldest_xact_secs
          FROM pgvigil.mssql_requests p
         WHERE p.instance_id = x.instance_id AND p.snapshot_at = x.snapshot_at AND coalesce(p.is_user_process, true)) q ON true
     WHERE x.instance_id = inst.instance_id AND x.snapshot_at > $1 AND x.snapshot_at <= $2
     ORDER BY x.snapshot_at DESC LIMIT 1) n ON true
 ORDER BY inst.instance`

// PerfSummary is GET /api/perfsummary?[from=&to=][&tag=][&part=pg|mssql]: the fleet's Performance summary.
func (s *Server) PerfSummary(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var tag any
	if v := r.URL.Query().Get("tag"); v != "" {
		tag = v
	}
	ps, err := onlyPart(r, []part{
		{"pg", sqlPerfSummaryPG, []any{from, to, "postgres", tag}},
		{"mssql", sqlPerfSummaryMSSQL, []any{from, to, "sqlserver", tag}},
	})
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	out, err := s.queryNoJIT(r.Context(), ps)
	s.reply(w, r, out, err)
}

// queryNoJIT runs the parts in one read-only transaction with JIT off. A fleet statement's cost estimate grows with the
// instances (one lateral read per instance and table) and passes jit_above_cost at about 200 instances, where JIT's
// compile time (measured: 695 ms) is several times the statement's own (180 ms); the work is many small index reads,
// which JIT does not speed up.
func (s *Server) queryNoJIT(ctx context.Context, parts []part) (map[string]*table, error) {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, "SET LOCAL jit = off"); err != nil {
		return nil, err
	}
	out := map[string]*table{}
	for _, p := range parts {
		t, err := queryTx(ctx, tx, p.sql, p.args...)
		if err != nil {
			return nil, err
		}
		out[p.name] = t
	}
	return out, nil
}

// queryTx is Server.query inside a transaction.
func queryTx(ctx context.Context, tx pgx.Tx, sql string, args ...any) (*table, error) {
	rows, err := tx.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	t := &table{Rows: [][]any{}}
	for _, f := range rows.FieldDescriptions() {
		t.Columns = append(t.Columns, f.Name)
	}
	for rows.Next() {
		v, err := rows.Values()
		if err != nil {
			return nil, err
		}
		for i, x := range v {
			// a bigint past 2^53 would lose digits as a JSON number in a browser
			if n, ok := x.(int64); ok && (n > 1<<53 || n < -(1<<53)) {
				v[i] = strconv.FormatInt(n, 10)
			}
		}
		t.Rows = append(t.Rows, v)
	}
	return t, rows.Err()
}
