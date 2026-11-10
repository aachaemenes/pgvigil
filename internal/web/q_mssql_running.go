package web

import (
	"fmt"
	"net/http"
	"time"
)

// The SQL Server Running queries and Waits tabs (task 96). Both read only this slice's own tables (0064) and
// collection_dates.
//
// GET /api/mssql/running?instance=<id>&[from=&to=][&at=] (Server.MssqlRunning): the kept snapshots of the window
// (the time slider's stops, a quiet minute included), and one snapshot in full: the newest at or before at (or the
// window's end): its rows with the statement text and the handles as 0x text, and its blocking heads.
// GET /api/mssql/waits?instance=<id>&[from=&to=] (Server.MssqlWaits): what the server waited on over the window
// (the differences of sys.dm_os_wait_stats between reads), per wait type and over time. The waits of idle
// background work (is_benign) are listed after the real ones and left out of the shares and the chart.

// sqlMssqlRunningState: the two collections' last runs on the instance (why one is skipped or partial).
const sqlMssqlRunningState = `
SELECT c.collection, c.status, c.note, c.snapshot_at
  FROM pgvigil.collection_dates c
 WHERE c.instance_id = $1 AND c.collection = ANY ($2::text[])
 ORDER BY c.collection`

// sqlMssqlSnapshots: the snapshots of the window, newest first; 1,500 at most (a day of minutes).
const sqlMssqlSnapshots = `
SELECT s.snapshot_at, s.server_utc, s.source, s.source_note, s.sessions, s.requests, s.blocked, s.heads, s.longest_wait_ms,
       s.memory_grants_pending, s.read_ms
  FROM pgvigil.mssql_requests_summary s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
 ORDER BY s.snapshot_at DESC
 LIMIT 1500`

// sqlMssqlRunningRows: one snapshot, the newest at or before $2. A chain's rows come together, the head first.
const sqlMssqlRunningRows = `
SELECT q.snapshot_at, q.server_utc, q.source, q.session_id, q.request_id, q.status, q.command, q.wait_type, q.wait_ms, q.wait_resource,
       q.wait_is_benign, q.blocking_session_id, q.open_tran, q.transaction_id, q.tran_start, q.tran_age_ms, q.tran_log_bytes,
       q.is_implicit_tran, q.isolation_level, q.cpu_ms, q.reads, q.writes, q.logical_reads, q.granted_memory_kb, q.tempdb_alloc_kb,
       q.tempdb_current_kb, q.dop, q.task_count, q.tasks_cpu_ms, q.tasks_physical_io, q.percent_complete, q.elapsed_ms, q.start_time,
       q.last_request_start, q.last_request_end, q.login_time, q.login_name, q.host_name, q.program_name, q.database_name,
       q.sql_handle, q.stmt_start, q.stmt_end, left(q.statement, 4000) AS statement, q.full_chars, q.plan_handle, q.query_hash,
       q.query_plan_hash, q.session_waits::text AS session_waits, q.is_user_process, q.head_session_id, q.chain_depth, q.victims,
       q.longest_victim_wait_ms, q.in_cycle, q.chain_note
  FROM pgvigil.mssql_requests_v q
 WHERE q.instance_id = $1
   AND q.snapshot_at = (SELECT max(s.snapshot_at) FROM pgvigil.mssql_requests_summary s WHERE s.instance_id = $1 AND s.snapshot_at <= $2)
 ORDER BY q.head_session_id NULLS LAST, q.chain_depth, q.session_id, q.request_id NULLS FIRST
 LIMIT 5000`

// sqlMssqlBlocking: the heads of that snapshot, the one with the longest wait behind it first.
const sqlMssqlBlocking = `
SELECT b.snapshot_at, b.head_session_id, b.victims, b.longest_wait_ms, b.in_snapshot, b.head_status, b.head_wait_type, b.head_open_tran,
       b.head_tran_start, b.head_tran_age_ms, b.head_login, b.head_host, b.head_program, b.head_database,
       left(t.statement, 4000) AS head_statement, b.note
  FROM pgvigil.mssql_blocking b
  LEFT JOIN pgvigil.mssql_statement_text t ON t.text_id = b.head_text_id
 WHERE b.instance_id = $1
   AND b.snapshot_at = (SELECT max(s.snapshot_at) FROM pgvigil.mssql_requests_summary s WHERE s.instance_id = $1 AND s.snapshot_at <= $2)
 ORDER BY b.longest_wait_ms DESC NULLS LAST, b.head_session_id`

// MssqlRunning serves /api/mssql/running.
func (s *Server) MssqlRunning(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	at := to
	if v := r.URL.Query().Get("at"); v != "" {
		if at, err = time.Parse(time.RFC3339, v); err != nil {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("at: %w", err))
			return
		}
	}
	s.multiPart(w, r, []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_requests"}}},
		{"snapshots", sqlMssqlSnapshots, []any{id, from, to}},
		{"rows", sqlMssqlRunningRows, []any{id, at}},
		{"blocking", sqlMssqlBlocking, []any{id, at}},
	})
}

// sqlMssqlWaitEvents: every wait type of the window. pct is the share of the wait time of the real waits; a benign
// wait has none. signal_pct is the part of a wait's time spent runnable, waiting for a CPU.
const sqlMssqlWaitEvents = `
WITH a AS (
  SELECT w.wait_type, max(w.category) AS category, bool_or(w.is_benign) AS is_benign, sum(w.waiting_tasks)::bigint AS waiting_tasks,
         sum(w.wait_ms)::bigint AS wait_ms, sum(w.signal_ms)::bigint AS signal_ms, max(w.max_wait_ms) AS max_wait_ms
    FROM pgvigil.mssql_wait_sample w
   WHERE w.instance_id = $1 AND w.snapshot_at > $2 AND w.snapshot_at <= $3
   GROUP BY w.wait_type
)
SELECT a.wait_type, coalesce(a.category, CASE WHEN a.is_benign THEN 'Idle background work' ELSE 'Other' END) AS category, a.is_benign,
       a.waiting_tasks, a.wait_ms, a.signal_ms,
       round(100.0 * a.signal_ms / nullif(a.wait_ms, 0), 1) AS signal_pct,
       round(a.wait_ms::numeric / nullif(a.waiting_tasks, 0), 1) AS avg_ms, a.max_wait_ms,
       CASE WHEN NOT a.is_benign THEN round(100.0 * a.wait_ms / nullif(sum(a.wait_ms) FILTER (WHERE NOT a.is_benign) OVER (), 0), 1) END AS pct
  FROM a
 ORDER BY a.is_benign, a.wait_ms DESC, a.wait_type
 LIMIT 300`

// sqlMssqlWaitSeries: the tasks waiting on average (wait seconds per second) per wait type over time, the eight
// largest real waits of the window and the rest as 'other', in about 120 steps of at least a minute. A step's wait
// time is spread over the seconds its reads cover (each read's own interval), so a missed read leaves no dip.
const sqlMssqlWaitSeries = `
WITH w AS (
  SELECT x.snapshot_at, x.wait_type, x.is_benign, x.wait_ms, x.interval_secs
    FROM pgvigil.mssql_wait_sample x
   WHERE x.instance_id = $1 AND x.snapshot_at > $2 AND x.snapshot_at <= $3
), top AS (
  SELECT wait_type FROM w WHERE NOT is_benign GROUP BY wait_type ORDER BY sum(wait_ms) DESC, wait_type LIMIT 8
), step AS (
  SELECT greatest(60, extract(epoch FROM $3::timestamptz - $2::timestamptz) / 120)::int AS secs
), cover AS (
  SELECT to_timestamp(floor(extract(epoch FROM r.snapshot_at) / step.secs) * step.secs) AS bucket, sum(r.interval_secs)::float8 AS secs
    FROM (SELECT DISTINCT snapshot_at, interval_secs FROM w) r, step
   GROUP BY 1
)
SELECT c.bucket AS snapshot_at, b.wait_type, round((sum(b.wait_ms) / 1000.0 / max(c.secs))::numeric, 3)::float8 AS waiting
  FROM (SELECT to_timestamp(floor(extract(epoch FROM w.snapshot_at) / step.secs) * step.secs) AS bucket,
               CASE WHEN w.wait_type IN (SELECT wait_type FROM top) THEN w.wait_type ELSE 'other' END AS wait_type, w.wait_ms
          FROM w, step
         WHERE NOT w.is_benign) b
  JOIN cover c USING (bucket)
 WHERE c.secs > 0
 GROUP BY 1, 2
 ORDER BY 1, 2`

// sqlMssqlWaitReads: the reads of the window: how many, and the seconds they cover.
const sqlMssqlWaitReads = `
SELECT count(*) AS reads, coalesce(sum(r.interval_secs), 0)::float8 AS covered_secs, min(r.snapshot_at) AS first_read, max(r.snapshot_at) AS last_read
  FROM (SELECT DISTINCT w.snapshot_at, w.interval_secs FROM pgvigil.mssql_wait_sample w
         WHERE w.instance_id = $1 AND w.snapshot_at > $2 AND w.snapshot_at <= $3) r`

// MssqlWaits serves /api/mssql/waits.
func (s *Server) MssqlWaits(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_waits"}}},
		{"reads", sqlMssqlWaitReads, []any{id, from, to}},
		{"events", sqlMssqlWaitEvents, []any{id, from, to}},
		{"series", sqlMssqlWaitSeries, []any{id, from, to}},
	})
}
