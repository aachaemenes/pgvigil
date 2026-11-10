package web

import (
	"errors"
	"fmt"
	"math"
	"net/http"
	"regexp"
	"time"
)

// The Extended Events tabs of a SQL Server instance (task 97): Deadlocks, Blocked reports and Slow queries (with the
// Attentions section). They read only the mssql_xe tables of migration 0065 and pgvigil.instances; the XML was taken
// apart when it was collected, so a page reads stored columns and never parses a graph.
//
// GET /api/mssql/xe?instance=<id>&[from=&to=][&part=] (Server.MSSQLXE): the capture states (which sessions are
// running, stopped or not installed), the instance's Extended Events findings, the deadlocks of the window, the
// blocked-process reports grouped by the blocking statement, the slow completions by statement shape with their
// count per time bucket, the attentions, and AlwaysOn_health's events. ?part= reads one of them.
// GET /api/mssql/xe/deadlock?instance=<id>&at=<event time>&key=<event key> (Server.MSSQLXEDeadlock): one deadlock,
// its processes and resources. The same with /deadlock.xdl (Server.MSSQLXEDeadlockXDL) downloads its graph XML.
// GET /api/mssql/xe/blocked?instance=<id>&head=<head key>&[from=&to=] (Server.MSSQLXEBlocked): the reports of one
// blocking statement, the head's side first.
// GET /api/mssql/xe/slow?instance=<id>&shape=<shape key>&[from=&to=] (Server.MSSQLXESlow): the events of one shape.

const sqlMSSQLXEState = `
SELECT s.capture, s.state, s.state_since, s.reads_in_state, s.source, s.session_name, s.target, s.buffer_kb, s.buffer_used_kb,
       s.event_count, s.new_events, s.dropped_events, s.dropped_buffers, s.missed_events, s.unknown_events, s.truncated,
       s.counter, s.threshold_s, s.lost_at, s.lost_events, s.note, s.snapshot_at
  FROM pgvigil.mssql_xe_state s
 WHERE s.instance_id = $1
 ORDER BY CASE s.capture WHEN 'deadlocks' THEN 0 WHEN 'blocked' THEN 1 WHEN 'slow' THEN 2 WHEN 'attention' THEN 3 ELSE 4 END`

const sqlMSSQLXEFindings = `
SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_xe_findings
 WHERE instance_id = $1
 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, at DESC`

const sqlMSSQLXEDeadlocks = `
SELECT d.event_at, d.event_key, d.source, d.process_count, d.victim_count, d.victim_spid, d.victim_login, d.victim_program,
       d.victim_statement, d.database_names, d.object_names, (d.graph IS NOT NULL) AS has_graph
  FROM pgvigil.mssql_deadlocks d
 WHERE d.instance_id = $1 AND d.event_at > $2 AND d.event_at <= $3
 ORDER BY d.event_at DESC
 LIMIT 500`

// one row per head statement; the head's side (what blocked) before the blocked side (how many, how long)
const sqlMSSQLXEBlockedHeads = `
SELECT b.head_key,
       (array_agg(b.blocking_statement ORDER BY b.event_at DESC))[1] AS blocking_statement,
       (array_agg(b.blocking_spid ORDER BY b.event_at DESC))[1] AS blocking_spid,
       (array_agg(b.blocking_status ORDER BY b.event_at DESC))[1] AS blocking_status,
       (array_agg(b.blocking_login ORDER BY b.event_at DESC))[1] AS blocking_login,
       (array_agg(b.blocking_program ORDER BY b.event_at DESC))[1] AS blocking_program,
       count(*) AS reports, count(DISTINCT b.blocked_spid) AS blocked_sessions, max(b.wait_ms) AS worst_wait_ms,
       string_agg(DISTINCT b.database_name, ', ') AS database_names, min(b.event_at) AS first_at, max(b.event_at) AS last_at
  FROM pgvigil.mssql_blocked_reports b
 WHERE b.instance_id = $1 AND b.event_at > $2 AND b.event_at <= $3
 GROUP BY b.head_key
 ORDER BY max(b.wait_ms) DESC NULLS LAST, count(*) DESC
 LIMIT 200`

const sqlMSSQLXEBlockedOne = `
SELECT b.event_at, b.blocking_spid, b.blocking_status, b.blocking_trancount, b.blocking_login, b.blocking_host, b.blocking_program,
       b.blocking_last_batch, b.blocking_statement, b.blocked_spid, b.blocked_login, b.blocked_host, b.blocked_program,
       b.blocked_statement, b.wait_ms, b.wait_resource, b.lock_mode, b.database_name
  FROM pgvigil.mssql_blocked_reports b
 WHERE b.instance_id = $1 AND b.event_at > $2 AND b.event_at <= $3 AND b.head_key IS NOT DISTINCT FROM $4
 ORDER BY b.event_at DESC
 LIMIT 500`

const sqlMSSQLXESlowShapes = `
SELECT e.shape_key, max(e.shape) AS shape, count(*) AS events, round(sum(e.duration_ms), 1) AS total_ms,
       round(max(e.duration_ms), 1) AS worst_ms, round(avg(e.duration_ms), 1) AS mean_ms, round(sum(e.cpu_ms), 1) AS cpu_ms,
       sum(e.logical_reads) AS logical_reads, sum(e.writes) AS writes,
       count(*) FILTER (WHERE e.result IS DISTINCT FROM 'OK') AS not_ok,
       string_agg(DISTINCT e.database_name, ', ') AS database_names,
       (array_agg(e.query_hash ORDER BY e.duration_ms DESC) FILTER (WHERE e.query_hash IS NOT NULL))[1] AS query_hash,
       max(e.event_at) AS last_at
  FROM pgvigil.mssql_slow_events e
 WHERE e.instance_id = $1 AND e.event_at > $2 AND e.event_at <= $3 AND e.event_name IN ('rpc_completed', 'sql_batch_completed')
 GROUP BY e.shape_key
 ORDER BY sum(e.duration_ms) DESC NULLS LAST
 LIMIT 200`

// the completions per bucket ($4 seconds wide): the chart's points and the table behind it
const sqlMSSQLXESlowSeries = `
SELECT to_timestamp(floor(extract(epoch FROM e.event_at) / $4) * $4) AS snapshot_at, count(*) AS events,
       round(max(e.duration_ms), 1) AS worst_ms, round(sum(e.duration_ms), 1) AS total_ms
  FROM pgvigil.mssql_slow_events e
 WHERE e.instance_id = $1 AND e.event_at > $2 AND e.event_at <= $3 AND e.event_name IN ('rpc_completed', 'sql_batch_completed')
 GROUP BY 1
 ORDER BY 1`

const sqlMSSQLXESlowOne = `
SELECT e.event_at, e.event_name, e.duration_ms, e.cpu_ms, e.logical_reads, e.physical_reads, e.writes, e.row_count, e.result,
       e.login_name, e.host_name, e.program_name, e.database_name, e.session_id, e.query_hash, e.query_plan_hash,
       e.object_name, e.statement
  FROM pgvigil.mssql_slow_events e
 WHERE e.instance_id = $1 AND e.event_at > $2 AND e.event_at <= $3 AND e.shape_key IS NOT DISTINCT FROM $4
   AND e.event_name IN ('rpc_completed', 'sql_batch_completed')
 ORDER BY e.duration_ms DESC NULLS LAST
 LIMIT 500`

const sqlMSSQLXEAttentions = `
SELECT a.event_at, a.session_id, a.login_name, a.host_name, a.program_name, a.database_name, a.interrupt_us, a.statement
  FROM pgvigil.mssql_attentions a
 WHERE a.instance_id = $1 AND a.event_at > $2 AND a.event_at <= $3
 ORDER BY a.event_at DESC
 LIMIT 500`

const sqlMSSQLXEAGEvents = `
SELECT e.event_at, e.event_name, e.ag_name, e.replica_name, e.previous_state, e.current_state, e.is_failover, e.error_number,
       e.severity, e.family, e.message, e.ddl_action, e.ddl_phase, e.statement
  FROM pgvigil.mssql_ag_events e
 WHERE e.instance_id = $1 AND e.event_at > $2 AND e.event_at <= $3
 ORDER BY e.event_at DESC
 LIMIT 500`

const sqlMSSQLXEDeadlockOne = `
SELECT d.event_at, d.event_key, d.source, d.session_name, d.process_count, d.victim_count, d.victim_spid, d.database_names,
       d.object_names, d.processes, d.resources, (d.graph IS NOT NULL) AS has_graph
  FROM pgvigil.mssql_deadlocks d
 WHERE d.instance_id = $1 AND d.event_at = $2 AND d.event_key = $3`

const sqlMSSQLXEDeadlockGraph = `
SELECT d.graph, i.name FROM pgvigil.mssql_deadlocks d JOIN pgvigil.instances i ON i.instance_id = d.instance_id
 WHERE d.instance_id = $1 AND d.event_at = $2 AND d.event_key = $3`

// MSSQLXE serves the Extended Events tabs of one SQL Server instance (?part= one of them).
func (s *Server) MSSQLXE(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// about 120 points over any window, never finer than a minute
	step := int(math.Ceil(to.Sub(from).Seconds() / 120))
	if step < 60 {
		step = 60
	}
	s.multiPart(w, r, []part{
		{"state", sqlMSSQLXEState, []any{id}},
		{"findings", sqlMSSQLXEFindings, []any{id}},
		{"deadlocks", sqlMSSQLXEDeadlocks, []any{id, from, to}},
		{"blocked", sqlMSSQLXEBlockedHeads, []any{id, from, to}},
		{"slow_shapes", sqlMSSQLXESlowShapes, []any{id, from, to}},
		{"slow_series", sqlMSSQLXESlowSeries, []any{id, from, to, step}},
		{"attentions", sqlMSSQLXEAttentions, []any{id, from, to}},
		{"ag_events", sqlMSSQLXEAGEvents, []any{id, from, to}},
	})
}

var mssqlXEKey = regexp.MustCompile(`^[0-9a-f]{1,64}(-[0-9]{1,9})?$`)

// mssqlXEEvent reads the instance, time and key that name one stored event.
func mssqlXEEvent(r *http.Request) (id int, at time.Time, key string, err error) {
	if id, _, _, err = params(r, true); err != nil {
		return 0, at, "", err
	}
	q := r.URL.Query()
	if at, err = time.Parse(time.RFC3339Nano, q.Get("at")); err != nil {
		return 0, at, "", errors.New("at must be the event's time (RFC 3339)")
	}
	if key = q.Get("key"); !mssqlXEKey.MatchString(key) {
		return 0, at, "", errors.New("key must be the event's key")
	}
	return id, at, key, nil
}

// MSSQLXEDeadlock serves one deadlock: its processes and resources.
func (s *Server) MSSQLXEDeadlock(w http.ResponseWriter, r *http.Request) {
	id, at, key, err := mssqlXEEvent(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	t, err := s.query(r.Context(), sqlMSSQLXEDeadlockOne, id, at, key)
	if err == nil && len(t.Rows) == 0 {
		writeErr(w, http.StatusNotFound, errors.New("no such deadlock"))
		return
	}
	s.reply(w, r, t, err)
}

// MSSQLXEDeadlockXDL downloads one deadlock's graph as an .xdl file (the XML SQL Server wrote, which SSMS opens as a
// deadlock graph). 404 when the graph was not stored (a query-text policy other than full keeps no raw text).
func (s *Server) MSSQLXEDeadlockXDL(w http.ResponseWriter, r *http.Request) {
	id, at, key, err := mssqlXEEvent(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var graph, name *string
	rows, err := s.pool.Query(r.Context(), sqlMSSQLXEDeadlockGraph, id, at, key)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	defer rows.Close()
	if rows.Next() {
		if err := rows.Scan(&graph, &name); err != nil {
			s.reply(w, r, nil, err)
			return
		}
	}
	if err := rows.Err(); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	if graph == nil || *graph == "" {
		writeErr(w, http.StatusNotFound, errors.New("no graph is stored for this deadlock"))
		return
	}
	file := fmt.Sprintf("deadlock-%s-%s.xdl", safeFileName(deref(name)), at.UTC().Format("20060102-150405"))
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="`+file+`"`)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if _, err := w.Write([]byte(*graph)); err != nil {
		s.log.Warn("api write failed", "path", r.URL.Path, "err", err)
	}
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// safeFileName keeps letters, digits, dot, dash and underscore of a name for a download's file name.
func safeFileName(s string) string {
	out := make([]rune, 0, len(s))
	for _, c := range s {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '.', c == '-', c == '_':
			out = append(out, c)
		default:
			out = append(out, '_')
		}
	}
	if len(out) == 0 {
		return "instance"
	}
	if len(out) > 60 {
		out = out[:60]
	}
	return string(out)
}

var mssqlXEGroupKey = regexp.MustCompile(`^[0-9a-f]{0,64}$`)

// mssqlXEGroup serves the rows of one group (a head statement's reports, a shape's events); an empty key is the
// group of the rows that have none.
func (s *Server) mssqlXEGroup(w http.ResponseWriter, r *http.Request, param, sql string) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	key := r.URL.Query().Get(param)
	if !mssqlXEGroupKey.MatchString(key) {
		writeErr(w, http.StatusBadRequest, errors.New(param+" must be a group's key"))
		return
	}
	var arg any
	if key != "" {
		arg = key
	}
	t, err := s.query(r.Context(), sql, id, from, to, arg)
	s.reply(w, r, t, err)
}

// MSSQLXEBlocked serves the blocked-process reports of one blocking statement.
func (s *Server) MSSQLXEBlocked(w http.ResponseWriter, r *http.Request) {
	s.mssqlXEGroup(w, r, "head", sqlMSSQLXEBlockedOne)
}

// MSSQLXESlow serves the slow completions of one statement shape.
func (s *Server) MSSQLXESlow(w http.ResponseWriter, r *http.Request) {
	s.mssqlXEGroup(w, r, "shape", sqlMSSQLXESlowOne)
}
