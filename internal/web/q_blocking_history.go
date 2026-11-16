package web

import (
	"errors"
	"fmt"
	"math"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

// The blocking history of one instance over a window (task 120), on either engine. Read only.
//
// GET /api/blocking/history?instance=<id>&[from=&to=][&part=] (Server.BlockingHistory). The window is cut to its
// newest seven days (the meta part says so); a step is about 120 points over it, never under a minute.
//
// PostgreSQL (migration 0075, from the activity samples): meta, summary (the denominator: captures, captures with
// blocking, the share, the worst chain and its root's state, captures with a cycle), episodes (one row per head
// transaction: samples as root, its states, idle in transaction, victims, direct, depth, the longest blocked, its
// transaction's age, its last statement), trend (per step), xmin_summary, xmin_pins (which session held the oldest
// xmin of its capture, and how often) and xmin_now (what holds the horizon now: vacuum_xmin_holders).
//
// SQL Server (migration 0064's snapshots, 0065's deadlocks and blocked-process reports, 0116): meta, trend (per step:
// snapshots, snapshots with a blocked session, the most blocked, the longest wait, the most heads, the summed blocked
// wait of the snapshot that had the most, the blocked-process reports and the blocked transactions they name),
// deadlock_trend (per step: deadlocks and their processes) and pairs (the blocked / blocking pairs of the minute
// snapshots over the window, pgvigil.mssql_block_pairs); every step of the window is a row, an empty one with zeros, so
// a quiet stretch draws as zero.

// historyMaxWindow is the longest window the history reads (one pass over the samples per part).
const historyMaxWindow = 7 * 24 * time.Hour

const sqlHistoryEngine = `SELECT engine FROM pgvigil.instances WHERE instance_id = $1`

const sqlHistoryMeta = `SELECT $1::text AS engine, $2::timestamptz AS from_at, $3::timestamptz AS to_at, $4::int AS step_secs, $5::boolean AS cut`

const sqlPgHistorySummary = `SELECT * FROM pgvigil.blocking_history_summary($1, $2, $3)`

const sqlPgHistoryEpisodes = `
SELECT e.head_pid, e.head_backend_start, e.head_xact_start, e.first_at, e.last_at, e.samples, e.states, e.idle_in_txn_samples,
       e.last_state, e.head_backend_type, e.head_usename, e.head_datname, e.head_application, e.victims, e.direct, e.depth,
       e.longest_blocked_secs, e.xact_secs, left(e.head_query, 4000) AS "head_query@stmt"
  FROM pgvigil.blocking_history_episodes($1, $2, $3) e`

const sqlPgHistoryTrend = `SELECT * FROM pgvigil.blocking_history_trend($1, $2, $3, $4)`

const sqlPgXminSummary = `SELECT * FROM pgvigil.xmin_pins_summary($1, $2, $3)`

const sqlPgXminPins = `
SELECT p.pid, p.backend_start, p.samples, p.pinned_samples, p.peak_xmin_age, p.peak_at, p.state_at_peak, p.xact_secs_at_peak,
       p.backend_type, p.usename, p.datname, p.application_name, p.client, p.first_at, p.last_at, left(p.query_at_peak, 4000) AS "query_at_peak@stmt"
  FROM pgvigil.xmin_pins($1, $2, $3) p`

const sqlPgXminNow = `
SELECT h.snapshot_at, h.holder AS "holder@holder", h.name, h.datname, h.xmin_age, h.catalog_xmin_age, h.active, h.since, left(h.detail, 400) AS "detail@holderdetail"
  FROM pgvigil.vacuum_xmin_holders h
 WHERE h.instance_id = $1
 ORDER BY greatest(coalesce(h.xmin_age, 0), coalesce(h.catalog_xmin_age, 0)) DESC
 LIMIT 20`

// sqlMssqlBlockingTrend: every step of the window; a step's numbers from the snapshots inside it (the summed wait:
// the blocked requests' waits of one snapshot added up, the step's largest such sum) and from the blocked-process
// reports raised inside it (pgvigil's own capture, else system_health's: migration 0116).
const sqlMssqlBlockingTrend = `
WITH b AS (
  SELECT g AS bucket FROM generate_series(to_timestamp(floor(extract(epoch FROM $2::timestamptz) / $4) * $4), $3::timestamptz, make_interval(secs => $4)) g
), w AS (
  SELECT q.snapshot_at, sum(q.wait_ms) AS summed_wait_ms
    FROM pgvigil.mssql_requests q
   WHERE q.instance_id = $1 AND q.snapshot_at > $2 AND q.snapshot_at <= $3
     AND q.blocking_session_id > 0 AND q.blocking_session_id <> q.session_id
   GROUP BY q.snapshot_at
), s AS (
  SELECT to_timestamp(floor(extract(epoch FROM x.snapshot_at) / $4) * $4) AS bucket, x.blocked, x.heads, x.longest_wait_ms,
         w.summed_wait_ms
    FROM pgvigil.mssql_requests_summary x LEFT JOIN w ON w.snapshot_at = x.snapshot_at
   WHERE x.instance_id = $1 AND x.snapshot_at > $2 AND x.snapshot_at <= $3
), r AS (
  SELECT to_timestamp(floor(extract(epoch FROM x.event_at) / $4) * $4) AS bucket, count(*) AS reports,
         count(DISTINCT coalesce(x.transaction_id, -x.blocked_spid)) AS blocked_transactions
    FROM pgvigil.mssql_blocked_reports x
   WHERE x.instance_id = $1 AND x.event_at > $2 AND x.event_at <= $3
     AND (x.source = 'product' OR NOT EXISTS (SELECT 1 FROM pgvigil.mssql_blocked_reports p
            WHERE p.instance_id = $1 AND p.event_at > $2 AND p.event_at <= $3 AND p.source = 'product'))
   GROUP BY 1
)
SELECT b.bucket AS snapshot_at, count(s.bucket)::int AS snapshots, count(*) FILTER (WHERE s.blocked > 0)::int AS with_blocking,
       coalesce(max(s.blocked), 0) AS blocked_max, coalesce(max(s.heads), 0) AS heads_max,
       CASE WHEN count(s.bucket) > 0 THEN coalesce(max(s.longest_wait_ms) FILTER (WHERE s.blocked > 0), 0) END AS longest_wait_ms,
       CASE WHEN count(s.bucket) > 0 THEN coalesce(max(s.summed_wait_ms), 0) END AS summed_wait_ms,
       coalesce(max(r.reports), 0)::int AS reports, coalesce(max(r.blocked_transactions), 0)::int AS blocked_transactions
  FROM b LEFT JOIN s ON s.bucket = b.bucket LEFT JOIN r ON r.bucket = b.bucket
 GROUP BY b.bucket
 ORDER BY b.bucket`

// sqlMssqlBlockPairs: the blocked / blocking pairs of the minute snapshots over the window (migration 0116)
const sqlMssqlBlockPairs = `SELECT * FROM pgvigil.mssql_block_pairs($1, $2, $3) LIMIT 500`

// sqlMssqlBlockedBy (SQLMonitor's blocked sessions per lead-blocker login / program): every step of the window, and in
// it the blocked sessions behind each chain head's login (%[1]s = head_login) or program (head_program) in the step's
// snapshot with the most blocked sessions (one snapshot: a step's stack is a real snapshot's total), 0 in a step with
// none (the stacked bands fall to zero, never bridging a quiet stretch); the 8 with the most over the range by name, the
// rest as 'Other'. A blocked session is a request blocked by another session in the snapshot (its head the chain's,
// mssql_blocking's head of that snapshot).
const sqlMssqlBlockedBy = `
WITH v AS (
  SELECT q.snapshot_at, coalesce(nullif(k.%[1]s, ''), '(unknown)') AS who, count(*) AS n
    FROM pgvigil.mssql_requests q
    JOIN pgvigil.mssql_blocking k ON k.instance_id = q.instance_id AND k.snapshot_at = q.snapshot_at AND k.head_session_id = q.head_session_id
   WHERE q.instance_id = $1 AND q.snapshot_at > $2 AND q.snapshot_at <= $3
     AND q.blocking_session_id > 0 AND q.session_id <> q.head_session_id
   GROUP BY 1, 2
), top AS (
  SELECT v.who FROM v GROUP BY v.who ORDER BY sum(v.n) DESC, v.who LIMIT 8
), w AS (
  SELECT to_timestamp(floor(extract(epoch FROM v.snapshot_at) / $4) * $4) AS bucket, v.snapshot_at,
         CASE WHEN v.who IN (SELECT who FROM top) THEN v.who ELSE 'Other' END AS who, sum(v.n) AS n
    FROM v GROUP BY 1, 2, 3
), pick AS (
  SELECT DISTINCT ON (t.bucket) t.bucket, t.snapshot_at
    FROM (SELECT w.bucket, w.snapshot_at, sum(w.n) AS total FROM w GROUP BY 1, 2) t
   ORDER BY t.bucket, t.total DESC, t.snapshot_at DESC
), b AS (
  SELECT g AS bucket FROM generate_series(to_timestamp(floor(extract(epoch FROM $2::timestamptz) / $4) * $4), $3::timestamptz, make_interval(secs => $4)) g
), names AS (
  SELECT DISTINCT w.who FROM w
)
SELECT b.bucket AS snapshot_at, nm.who, coalesce(sum(w.n), 0)::int AS blocked
  FROM b CROSS JOIN names nm
  LEFT JOIN pick p ON p.bucket = b.bucket
  LEFT JOIN w ON w.bucket = b.bucket AND w.snapshot_at = p.snapshot_at AND w.who = nm.who
 GROUP BY b.bucket, nm.who
 ORDER BY b.bucket, nm.who`

// sqlMssqlChains (the chain timeline): one row per chain over the range - a head session and its transaction (its
// start); a head with no transaction start read is one chain per stretch of snapshots it heads, split where a requests
// snapshot of the instance passed without it (its spid reused later, or the same session blocking again hours on) -
// first and last seen, the snapshots, its longest wait and most victims, the head's login, program and last statement
const sqlMssqlChains = `
WITH k AS (
  SELECT b.*, lag(b.snapshot_at) OVER (PARTITION BY b.head_session_id, b.head_tran_start ORDER BY b.snapshot_at) AS prev_at
    FROM pgvigil.mssql_blocking b
   WHERE b.instance_id = $1 AND b.snapshot_at > $2 AND b.snapshot_at <= $3
), m AS (
  SELECT k.*, CASE WHEN k.prev_at IS NULL THEN 1
                   WHEN k.head_tran_start IS NULL AND EXISTS (SELECT 1 FROM pgvigil.mssql_requests_summary x
                          WHERE x.instance_id = $1 AND x.snapshot_at > k.prev_at AND x.snapshot_at < k.snapshot_at) THEN 1
                   ELSE 0 END AS fresh
    FROM k
), n AS (
  SELECT m.*, sum(m.fresh) OVER (PARTITION BY m.head_session_id, m.head_tran_start ORDER BY m.snapshot_at ROWS UNBOUNDED PRECEDING) AS stretch
    FROM m
)
SELECT b.head_session_id, b.head_tran_start AS tran_start, min(b.snapshot_at) AS first_at, max(b.snapshot_at) AS last_at,
       count(*)::int AS snapshots, max(b.longest_wait_ms) AS longest_wait_ms, max(b.victims)::int AS victims_max,
       (array_agg(b.head_login ORDER BY b.snapshot_at DESC))[1] AS head_login,
       (array_agg(b.head_program ORDER BY b.snapshot_at DESC))[1] AS head_program,
       (array_agg(b.head_database ORDER BY b.snapshot_at DESC))[1] AS head_database,
       left((array_agg(t.statement ORDER BY b.snapshot_at DESC))[1], 500) AS statement
  FROM n b
  LEFT JOIN pgvigil.mssql_statement_text t ON t.text_id = b.head_text_id
 GROUP BY b.head_session_id, b.head_tran_start, b.stretch
 ORDER BY min(b.snapshot_at), b.head_session_id
 LIMIT 500`

const sqlMssqlDeadlockTrend = `
WITH b AS (
  SELECT g AS bucket FROM generate_series(to_timestamp(floor(extract(epoch FROM $2::timestamptz) / $4) * $4), $3::timestamptz, make_interval(secs => $4)) g
), d AS (
  SELECT to_timestamp(floor(extract(epoch FROM x.event_at) / $4) * $4) AS bucket, x.process_count
    FROM pgvigil.mssql_deadlocks x
   WHERE x.instance_id = $1 AND x.event_at > $2 AND x.event_at <= $3
)
SELECT b.bucket AS snapshot_at, count(d.bucket)::int AS deadlocks, coalesce(sum(d.process_count), 0)::int AS processes
  FROM b LEFT JOIN d ON d.bucket = b.bucket
 GROUP BY b.bucket
 ORDER BY b.bucket`

// BlockingHistory serves /api/blocking/history.
func (s *Server) BlockingHistory(w http.ResponseWriter, r *http.Request) {
	// its reach is historyMaxWindow: a longer window reads its newest 7 days and the reply says so (paramsReach)
	id, from, to, err := paramsReach(r, true, historyMaxWindow)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	cut := readWindowOf(r) != nil
	step := int(math.Ceil(to.Sub(from).Seconds() / 120))
	if step < 60 {
		step = 60
	}
	var engine string
	if err := s.pool.QueryRow(r.Context(), sqlHistoryEngine, id).Scan(&engine); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeErr(w, http.StatusNotFound, errors.New("no such instance"))
		} else {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the instance's engine: %w", err))
		}
		return
	}
	meta := part{"meta", sqlHistoryMeta, []any{engine, from, to, step, cut}}
	if engine == "sqlserver" {
		s.multiPart(w, r, []part{
			meta,
			{"trend", sqlMssqlBlockingTrend, []any{id, from, to, step}},
			{"deadlock_trend", sqlMssqlDeadlockTrend, []any{id, from, to, step}},
			{"pairs", sqlMssqlBlockPairs, []any{id, from, to}},
			{"by_login", fmt.Sprintf(sqlMssqlBlockedBy, "head_login"), []any{id, from, to, step}},
			{"by_program", fmt.Sprintf(sqlMssqlBlockedBy, "head_program"), []any{id, from, to, step}},
			{"chains", sqlMssqlChains, []any{id, from, to}},
		})
		return
	}
	s.multiPart(w, r, []part{
		meta,
		{"summary", sqlPgHistorySummary, []any{id, from, to}},
		{"episodes", sqlPgHistoryEpisodes, []any{id, from, to}},
		{"trend", sqlPgHistoryTrend, []any{id, from, to, step}},
		{"xmin_summary", sqlPgXminSummary, []any{id, from, to}},
		{"xmin_pins", sqlPgXminPins, []any{id, from, to}},
		{"xmin_now", sqlPgXminNow, []any{id}},
	})
}
