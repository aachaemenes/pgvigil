package web

import (
	"errors"
	"math"
	"net/http"
	"time"
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
// SQL Server (migration 0064's snapshots and 0065's deadlocks): meta, trend (per step: snapshots, snapshots with a
// blocked session, the most blocked, the longest wait, the most heads) and deadlock_trend (per step: deadlocks and
// their processes); every step of the window is a row, an empty one with zeros, so a quiet stretch draws as zero.

// historyMaxWindow is the longest window the history reads (one pass over the samples per part).
const historyMaxWindow = 7 * 24 * time.Hour

const sqlHistoryEngine = `SELECT engine FROM pgvigil.instances WHERE instance_id = $1`

const sqlHistoryMeta = `SELECT $1::text AS engine, $2::timestamptz AS from_at, $3::timestamptz AS to_at, $4::int AS step_secs, $5::boolean AS cut`

const sqlPgHistorySummary = `SELECT * FROM pgvigil.blocking_history_summary($1, $2, $3)`

const sqlPgHistoryEpisodes = `
SELECT e.head_pid, e.head_backend_start, e.head_xact_start, e.first_at, e.last_at, e.samples, e.states, e.idle_in_txn_samples,
       e.last_state, e.head_backend_type, e.head_usename, e.head_datname, e.head_application, e.victims, e.direct, e.depth,
       e.longest_blocked_secs, e.xact_secs, left(e.head_query, 4000) AS head_query
  FROM pgvigil.blocking_history_episodes($1, $2, $3) e`

const sqlPgHistoryTrend = `SELECT * FROM pgvigil.blocking_history_trend($1, $2, $3, $4)`

const sqlPgXminSummary = `SELECT * FROM pgvigil.xmin_pins_summary($1, $2, $3)`

const sqlPgXminPins = `
SELECT p.pid, p.backend_start, p.samples, p.pinned_samples, p.peak_xmin_age, p.peak_at, p.state_at_peak, p.xact_secs_at_peak,
       p.backend_type, p.usename, p.datname, p.application_name, p.client, p.first_at, p.last_at, left(p.query_at_peak, 4000) AS query_at_peak
  FROM pgvigil.xmin_pins($1, $2, $3) p`

const sqlPgXminNow = `
SELECT h.snapshot_at, h.holder, h.name, h.datname, h.xmin_age, h.catalog_xmin_age, h.active, h.since, left(h.detail, 400) AS detail
  FROM pgvigil.vacuum_xmin_holders h
 WHERE h.instance_id = $1
 ORDER BY greatest(coalesce(h.xmin_age, 0), coalesce(h.catalog_xmin_age, 0)) DESC
 LIMIT 20`

// sqlMssqlBlockingTrend: every step of the window; a step's numbers from the snapshots inside it.
const sqlMssqlBlockingTrend = `
WITH b AS (
  SELECT g AS bucket FROM generate_series(to_timestamp(floor(extract(epoch FROM $2::timestamptz) / $4) * $4), $3::timestamptz, make_interval(secs => $4)) g
), s AS (
  SELECT to_timestamp(floor(extract(epoch FROM x.snapshot_at) / $4) * $4) AS bucket, x.blocked, x.heads, x.longest_wait_ms
    FROM pgvigil.mssql_requests_summary x
   WHERE x.instance_id = $1 AND x.snapshot_at > $2 AND x.snapshot_at <= $3
)
SELECT b.bucket AS snapshot_at, count(s.bucket)::int AS snapshots, count(*) FILTER (WHERE s.blocked > 0)::int AS with_blocking,
       coalesce(max(s.blocked), 0) AS blocked_max, coalesce(max(s.heads), 0) AS heads_max,
       CASE WHEN count(s.bucket) > 0 THEN coalesce(max(s.longest_wait_ms) FILTER (WHERE s.blocked > 0), 0) END AS longest_wait_ms
  FROM b LEFT JOIN s ON s.bucket = b.bucket
 GROUP BY b.bucket
 ORDER BY b.bucket`

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
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	cut := false
	if to.Sub(from) > historyMaxWindow {
		from, cut = to.Add(-historyMaxWindow), true
	}
	step := int(math.Ceil(to.Sub(from).Seconds() / 120))
	if step < 60 {
		step = 60
	}
	var engine string
	if err := s.pool.QueryRow(r.Context(), sqlHistoryEngine, id).Scan(&engine); err != nil {
		writeErr(w, http.StatusNotFound, errors.New("no such instance"))
		return
	}
	meta := part{"meta", sqlHistoryMeta, []any{engine, from, to, step, cut}}
	if engine == "sqlserver" {
		s.multiPart(w, r, []part{
			meta,
			{"trend", sqlMssqlBlockingTrend, []any{id, from, to, step}},
			{"deadlock_trend", sqlMssqlDeadlockTrend, []any{id, from, to, step}},
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
