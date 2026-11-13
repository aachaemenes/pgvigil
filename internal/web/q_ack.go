package web

// Acknowledge, mute and notes (task 118). GET /api/ack?part=acks|log|suppressed|alerts|attention reads the store of
// 0073 (pgvigil.acks, ack_log, ack_suppressed), the open alerts with their acknowledgement, notes, close, blackout,
// hold and known-noise label, and the Summary's Needs-attention rates. POST /api/ack makes one acknowledgement, note or
// rule, POST /api/ack/end ends one; both go through the actions door's write path: the UI login (the session's user is
// the row's created_by), the X-Pgvigil header, and the audit login's pool (the config's repository dsn), never the
// read-only pool. pgvigil.import_ack writes the row and its ack_log line in one call, a refused attempt included.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// sqlAckRows: every row in force now and every row ended or expired in the last 7 days, newest first
const sqlAckRows = `
SELECT a.ack_id, a.kind, a.instance_id, a.instance_name AS instance, a.check_key, a.finding_key, a.job_name, a.tag,
       a.match_text, a.note, a.seen_state, a.starts_at, a.until, a.until_change, a.created_by, a.created_at, a.client,
       a.ended_by, a.ended_at, pgvigil.ack_live(a.ended_at, a.starts_at, a.until, $1) AS live,
       (SELECT count(*) FROM pgvigil.ack_suppressed x WHERE x.ack_id = a.ack_id) AS held_alerts,
       (SELECT sum(x.passes) FROM pgvigil.ack_suppressed x WHERE x.ack_id = a.ack_id) AS held_passes,
       (SELECT max(x.last_at) FROM pgvigil.ack_suppressed x WHERE x.ack_id = a.ack_id) AS held_last
  FROM pgvigil.acks a
 WHERE pgvigil.ack_live(a.ended_at, a.starts_at, a.until, $1) OR a.starts_at > $1
    OR coalesce(a.ended_at, a.until) >= $1::timestamptz - interval '7 days'
 ORDER BY a.created_at DESC, a.ack_id DESC
 LIMIT 2000`

// sqlAckLog: the window's attempts, newest first
const sqlAckLog = `
SELECT l.at, l.ui_user, l.client, l.op, l.kind, l.ack_id, l.instance_name AS instance, l.outcome, l.detail
  FROM pgvigil.ack_log l
 WHERE l.at >= $1 AND l.at < $2
 ORDER BY l.at DESC, l.log_id DESC
 LIMIT 1000`

// sqlAckSuppressed: the sends a mute, silence or blackout held, last held in the window
const sqlAckSuppressed = `
SELECT x.last_at, x.first_at, x.passes, x.channel, x.instance_name AS instance, x.severity, x.source, x.setting, x.value,
       x.ack_id, a.kind AS held_by, a.created_by, coalesce(a.match_text, a.check_key, a.tag, a.instance_name) AS rule
  FROM pgvigil.ack_suppressed x
  JOIN pgvigil.acks a USING (ack_id)
 WHERE x.last_at >= $1 AND x.first_at < $2
 ORDER BY x.last_at DESC
 LIMIT 1000`

// sqlAckAlerts: one row per open alert (its finding key over every channel) with what the store says of it now; an
// acknowledgement or a close counts for this occurrence only (made since its first send), and a close only while the
// alert is still resolved (a finding back hides nothing)
const sqlAckAlerts = `
WITH o AS (
  SELECT s.finding_key, max(s.instance_id) AS instance_id, max(s.instance_name) AS instance,
         (array_agg(s.severity ORDER BY pgvigil.severity_rank(s.severity) DESC))[1] AS severity,
         max(s.source) AS source, max(s.setting) AS setting, max(s.value) AS value, min(s.first_sent_at) AS first_sent_at,
         max(s.last_sent_at) AS last_sent_at, sum(s.send_count)::int AS sends,
         array_agg(DISTINCT s.channel ORDER BY s.channel) AS channels, bool_and(s.missing_since IS NOT NULL) AS resolved,
         min(s.missing_since) AS resolved_at
    FROM pgvigil.alert_state s
   WHERE s.cleared_at IS NULL
   GROUP BY s.finding_key
)
SELECT o.*, coalesce(t.tags, '{}'::text[]) AS tags,
       ak.ack_id AS ack_id, ak.created_by AS acked_by, ak.created_at AS acked_at,
       cl.ack_id AS close_id, cl.created_by AS closed_by, cl.created_at AS closed_at,
       (SELECT count(*) FROM pgvigil.acks n WHERE n.kind = 'note' AND n.finding_key = o.finding_key AND n.ended_at IS NULL) AS notes,
       (SELECT n.note || ' (' || n.created_by || ')' FROM pgvigil.acks n WHERE n.kind = 'note' AND n.finding_key = o.finding_key
           AND n.ended_at IS NULL ORDER BY n.created_at DESC LIMIT 1) AS last_note,
       EXISTS (SELECT 1 FROM pgvigil.acks b WHERE b.kind = 'blackout' AND b.instance_name = o.instance
                  AND o.source IS DISTINCT FROM 'pgvigil repository'   -- task 201: no instance, so no instance's blackout
                  AND pgvigil.ack_live(b.ended_at, b.starts_at, b.until, $1)) AS is_blackout,
       h.kind AS held_by, h.ack_id AS hold_id,
       (SELECT string_agg(z.note, '; ' ORDER BY z.ack_id) FROM pgvigil.acks z
         WHERE z.kind = 'noise' AND pgvigil.ack_live(z.ended_at, z.starts_at, z.until, $1)
           AND pgvigil.ack_rule_matches(z, o.instance, coalesce(t.tags, '{}'), o.finding_key, o.source, o.setting, o.value)) AS known_noise
  FROM o
  LEFT JOIN pgvigil.instance_tags_merged t USING (instance_id)
  LEFT JOIN LATERAL (SELECT a.ack_id, a.created_by, a.created_at FROM pgvigil.acks a WHERE a.kind = 'alert_ack'
                        AND a.finding_key = o.finding_key AND a.created_at >= o.first_sent_at
                        AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, $1)
                      ORDER BY a.created_at DESC LIMIT 1) ak ON true
  LEFT JOIN LATERAL (SELECT a.ack_id, a.created_by, a.created_at FROM pgvigil.acks a WHERE a.kind = 'close'
                        AND a.finding_key = o.finding_key AND a.ended_at IS NULL AND a.created_at >= o.first_sent_at
                        AND o.resolved
                      ORDER BY a.created_at DESC LIMIT 1) cl ON true
  LEFT JOIN LATERAL (SELECT a.kind, a.ack_id FROM pgvigil.acks a
                      WHERE a.ack_id = pgvigil.ack_hold($1, o.instance, coalesce(t.tags, '{}'), o.finding_key, o.source, o.setting, o.value)) h ON true
 ORDER BY CASE o.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, o.first_sent_at DESC
 LIMIT 500`

// sqlAckAttention: per active instance, the last 15 minutes before $1: blocking (PostgreSQL: distinct sessions seen
// waiting on a lock; SQL Server: blocked process reports), deadlocks (PostgreSQL: pg_stat_database's counter risen;
// SQL Server: deadlock graphs) and the newest host CPU; the page states each as a count and a rate per hour
const sqlAckAttention = `
SELECT i.instance_id, i.name AS instance, i.engine,
       CASE WHEN i.engine = 'postgres' THEN
              (SELECT count(DISTINCT (a.pid, a.backend_start, a.query_start)) FROM pgvigil.activity_sample a
                WHERE a.instance_id = i.instance_id AND a.snapshot_at > $1::timestamptz - interval '15 minutes' AND a.snapshot_at <= $1
                  AND a.wait_event_type = 'Lock')
            ELSE (SELECT count(*) FROM pgvigil.mssql_blocked_reports b
                   WHERE b.instance_id = i.instance_id AND b.event_at > $1::timestamptz - interval '15 minutes' AND b.event_at <= $1) END AS blocking,
       CASE WHEN i.engine = 'postgres' THEN
              (SELECT coalesce(sum(greatest(d.hi - d.lo, 0)), 0)::bigint FROM (
                 SELECT max(s.deadlocks) AS hi, min(s.deadlocks) AS lo FROM pgvigil.dbstats s
                  WHERE s.instance_id = i.instance_id AND s.snapshot_at > $1::timestamptz - interval '15 minutes' AND s.snapshot_at <= $1
                  GROUP BY s.dbid) d)
            ELSE (SELECT count(*) FROM pgvigil.mssql_deadlocks k
                   WHERE k.instance_id = i.instance_id AND k.event_at > $1::timestamptz - interval '15 minutes' AND k.event_at <= $1) END AS deadlocks,
       (SELECT h.cpu_pct FROM pgvigil.host_sample h WHERE h.instance_id = i.instance_id
           AND h.snapshot_at > $1::timestamptz - interval '15 minutes' AND h.snapshot_at <= $1 ORDER BY h.snapshot_at DESC LIMIT 1) AS cpu_pct,
       15 AS window_minutes
  FROM pgvigil.instances i
 WHERE i.is_active
 ORDER BY i.name`

// sqlAckLive (task 177 D29, PerformanceMonitor's server card and server page header): per active instance, at $1,
// the live figures of the Summary's PerformanceMonitor columns and of the instance header's chips.
//
//	collections   each collection of the instance in the frame's classes (q_frame.go sqlFrameStatus, $2 the stale
//	              expectations, $3 the default stale age, $4 the no-permission pattern): healthy, stale, failing,
//	              not collected, no permission; last_collect_at the newest healthy run of any collection
//	cpu           the newest read of the last 15 minutes: PostgreSQL host_sample.cpu_pct (cpu_sql NULL); SQL Server
//	              mssql_cpu_sample, total = 100 - idle (the SQL Server process's share where the record has no idle
//	              figure), cpu_sql the process's share, cpu_other the rest
//	acu           a Serverless v2 PostgreSQL instance: the newest ACUUtilization datapoint of the serverless
//	              collection's own 20-minute window (cloudwatch_serverless.go serverlessWindow, 5-minute periods) and
//	              the configured ceiling (serverless_scaling.max_acu); NULL elsewhere; serverless: the instance's
//	              describe (serverless_scaling, written each serverless run) names class db.serverless within 2 hours
//	              (a Serverless v2 instance without an ACU read is banded Unknown, never on its CPU figure)
//	threads       SQL Server: the newest mssql_sched_sample of the last 15 minutes (max, current, active workers,
//	              the work queue: requests waiting for a worker)
//	memory        SQL Server: the newest mssql_memory_sample of the last 15 minutes (Total / Target Server Memory,
//	              the buffer pool, grants pending); PostgreSQL: the newest host_sample's total and used memory
//	blocking      the last hour (PerformanceMonitor's 'recent', its fleet default), as the attention part counts it,
//	              and the longest wait seen: PostgreSQL the
//	              longest span one waiting statement (pid, backend start, query start) was seen waiting on a lock
//	              across the samples (a lower bound: its wait began before its first sample), SQL Server the longest
//	              wait_ms of a blocked process report
//	deadlocks     the last hour: PostgreSQL pg_stat_database's counter risen per database and restart epoch (0010), SQL Server the
//	              deadlock graphs and the newest one's time; blocking_read / deadlocks_read: their collection ran well
//	              in the hour (activity / dbstats, mssql_xe), else the measure has no reading
//	silenced      the newest silence in force for the instance (0073: kind 'silence'), its id, by and until
//
// $5 narrows it to one instance (the instance header's read); 0 = every active instance (the Summary's).
const sqlAckLive = `
WITH i AS (
  SELECT instance_id, name, engine FROM pgvigil.instances WHERE is_active AND ($5::int = 0 OR instance_id = $5)
), c AS (
  SELECT c.instance_id, c.snapshot_at, c.status,
         CASE WHEN c.status <> 'ok' AND coalesce(c.note, '') ~* $4 THEN 'no_permission'
              WHEN c.status = 'error' THEN 'failing'
              WHEN c.status <> 'ok' THEN 'not_collected'
              WHEN $1::timestamptz - c.snapshot_at > make_interval(secs => CASE WHEN e.iv IS NULL THEN $3::int ELSE greatest(300, 3 * e.iv) END) THEN 'stale'
              ELSE 'healthy' END AS state
    FROM pgvigil.collection_dates c
    JOIN i USING (instance_id)
    CROSS JOIN LATERAL (SELECT coalesce(($2::jsonb -> 'instances' -> i.name ->> c.collection)::int,
                                        ($2::jsonb -> 'defaults' ->> c.collection)::int) AS iv) e
   WHERE coalesce(e.iv, -1) <> 0
), k AS (
  SELECT instance_id,
         count(*) FILTER (WHERE state = 'healthy') AS coll_healthy, count(*) FILTER (WHERE state = 'stale') AS coll_stale,
         count(*) FILTER (WHERE state = 'failing') AS coll_failing, count(*) FILTER (WHERE state = 'not_collected') AS coll_not_collected,
         count(*) FILTER (WHERE state = 'no_permission') AS coll_no_permission,
         max(snapshot_at) FILTER (WHERE status = 'ok') AS last_collect_at
    FROM c GROUP BY instance_id
)
SELECT i.instance_id, i.name AS instance, i.engine,
       coalesce(k.coll_healthy, 0) AS coll_healthy, coalesce(k.coll_stale, 0) AS coll_stale, coalesce(k.coll_failing, 0) AS coll_failing,
       coalesce(k.coll_not_collected, 0) AS coll_not_collected, coalesce(k.coll_no_permission, 0) AS coll_no_permission, k.last_collect_at,
       cpu.at AS cpu_at, cpu.total AS cpu_pct, cpu.sql AS cpu_sql, cpu.other AS cpu_other,
       acu.at AS acu_at, acu.pct AS acu_pct, CASE WHEN acu.pct IS NOT NULL THEN sc.max_acu END AS max_acu,
       coalesce(sc.class = 'db.serverless' AND sc.snapshot_at > $1::timestamptz - interval '2 hours', false) AS serverless,
       th.snapshot_at AS threads_at, th.max_workers, th.current_workers, th.active_workers, th.work_queue, th.runnable_tasks,
       mm.snapshot_at AS memory_at, mm.total_kb, mm.target_kb, mm.buffer_pool_kb, mm.grants_pending, hm.mem_total, hm.mem_used,
       bl.blocking, bl.longest_wait_s, dl.deadlocks, dl.last_deadlock_at,
       EXISTS (SELECT 1 FROM pgvigil.collection_dates d WHERE d.instance_id = i.instance_id AND d.status = 'ok'
                  AND d.collection = CASE i.engine WHEN 'postgres' THEN 'activity' ELSE 'mssql_xe' END
                  AND d.snapshot_at > $1::timestamptz - interval '1 hour') AS blocking_read,
       EXISTS (SELECT 1 FROM pgvigil.collection_dates d WHERE d.instance_id = i.instance_id AND d.status = 'ok'
                  AND d.collection = CASE i.engine WHEN 'postgres' THEN 'dbstats' ELSE 'mssql_xe' END
                  AND d.snapshot_at > $1::timestamptz - interval '1 hour') AS deadlocks_read,
       $1::timestamptz AS live_at, 15 AS window_minutes, 60 AS recent_minutes,
       sl.ack_id AS silence_id, sl.created_by AS silenced_by, sl.until AS silenced_until
  FROM i
  LEFT JOIN k USING (instance_id)
  LEFT JOIN LATERAL (
    SELECT h.snapshot_at AS at, round(h.cpu_pct::numeric, 1) AS total, NULL::numeric AS sql, NULL::numeric AS other
      FROM pgvigil.host_sample h
     WHERE i.engine = 'postgres' AND h.instance_id = i.instance_id AND h.cpu_pct IS NOT NULL
       AND h.snapshot_at > $1::timestamptz - interval '15 minutes' AND h.snapshot_at <= $1
    UNION ALL
    SELECT x.snapshot_at, x.total, x.sql_pct, greatest(x.total - x.sql_pct, 0)
      FROM (SELECT m.snapshot_at, m.sql_pct::numeric AS sql_pct,
                   CASE WHEN m.idle_pct IS NULL THEN m.sql_pct ELSE 100 - m.idle_pct END::numeric AS total
              FROM pgvigil.mssql_cpu_sample m
             WHERE i.engine = 'sqlserver' AND m.instance_id = i.instance_id
               AND m.snapshot_at > $1::timestamptz - interval '15 minutes' AND m.snapshot_at <= $1) x
     ORDER BY 1 DESC LIMIT 1) cpu ON true
  LEFT JOIN LATERAL (
    SELECT s.snapshot_at AS at, round(s.value::numeric, 1) AS pct
      FROM pgvigil.serverless_sample s
     WHERE i.engine = 'postgres' AND s.instance_id = i.instance_id AND s.metric = 'ACUUtilization' AND s.value IS NOT NULL
       AND s.snapshot_at > $1::timestamptz - interval '20 minutes' AND s.snapshot_at <= $1
     ORDER BY s.snapshot_at DESC LIMIT 1) acu ON true
  LEFT JOIN pgvigil.serverless_scaling sc ON sc.instance_id = i.instance_id
  LEFT JOIN LATERAL (
    SELECT s.snapshot_at, s.max_workers, s.current_workers, s.active_workers, s.work_queue, s.runnable_tasks
      FROM pgvigil.mssql_sched_sample s
     WHERE i.engine = 'sqlserver' AND s.instance_id = i.instance_id
       AND s.snapshot_at > $1::timestamptz - interval '15 minutes' AND s.snapshot_at <= $1
     ORDER BY s.snapshot_at DESC LIMIT 1) th ON true
  LEFT JOIN LATERAL (
    SELECT m.snapshot_at, m.total_kb, m.target_kb, m.buffer_pool_kb, m.grants_pending
      FROM pgvigil.mssql_memory_sample m
     WHERE i.engine = 'sqlserver' AND m.instance_id = i.instance_id
       AND m.snapshot_at > $1::timestamptz - interval '15 minutes' AND m.snapshot_at <= $1
     ORDER BY m.snapshot_at DESC LIMIT 1) mm ON true
  LEFT JOIN LATERAL (
    SELECT h.mem_total, h.mem_used
      FROM pgvigil.host_sample h
     WHERE i.engine = 'postgres' AND h.instance_id = i.instance_id AND h.mem_total IS NOT NULL
       AND h.snapshot_at > $1::timestamptz - interval '15 minutes' AND h.snapshot_at <= $1
     ORDER BY h.snapshot_at DESC LIMIT 1) hm ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS blocking, round(max(x.waited)::numeric, 1) AS longest_wait_s FROM (
      SELECT extract(epoch FROM max(a.snapshot_at) - min(a.snapshot_at)) AS waited
        FROM pgvigil.activity_sample a
       WHERE i.engine = 'postgres' AND a.instance_id = i.instance_id AND a.wait_event_type = 'Lock'
         AND a.snapshot_at > $1::timestamptz - interval '1 hour' AND a.snapshot_at <= $1
       GROUP BY a.pid, a.backend_start, a.query_start) x
    UNION ALL
    SELECT count(*), round(max(b.wait_ms) / 1000.0, 1)
      FROM pgvigil.mssql_blocked_reports b
     WHERE i.engine = 'sqlserver' AND b.instance_id = i.instance_id
       AND b.event_at > $1::timestamptz - interval '1 hour' AND b.event_at <= $1
     ORDER BY 1 DESC LIMIT 1) bl ON true
  LEFT JOIN LATERAL (
    SELECT coalesce(sum(greatest(d.hi - d.lo, 0)), 0)::bigint AS deadlocks, NULL::timestamptz AS last_deadlock_at FROM (
      SELECT max(s.deadlocks) AS hi, min(s.deadlocks) AS lo FROM pgvigil.dbstats s
       WHERE i.engine = 'postgres' AND s.instance_id = i.instance_id
         AND s.snapshot_at > $1::timestamptz - interval '1 hour' AND s.snapshot_at <= $1
       GROUP BY s.dbid, s.epoch) d
     WHERE i.engine = 'postgres'
    UNION ALL
    SELECT count(*), max(k.event_at) FROM pgvigil.mssql_deadlocks k
     WHERE i.engine = 'sqlserver' AND k.instance_id = i.instance_id
       AND k.event_at > $1::timestamptz - interval '1 hour' AND k.event_at <= $1
     ORDER BY 1 DESC LIMIT 1) dl ON true
  LEFT JOIN LATERAL (
    SELECT a.ack_id, a.created_by, a.until FROM pgvigil.acks a
     WHERE a.kind = 'silence' AND a.instance_name = i.name AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, $1)
     ORDER BY a.created_at DESC LIMIT 1) sl ON true
 ORDER BY i.name`

// sqlAckSeen (task 177 D29, PerformanceMonitor's Analysis Findings' Occurrences and First seen): one instance's
// findings as the alert history knows them, by source, setting and value (the finding's identity, 0059's
// alert_finding_key): first sent, last sent, the occurrences (each time it was raised anew: alert_state's episodes of
// one channel - a channel in quiet hours or with a higher minimum sends one episode later, under its own first send -
// the most of any channel) and the sends. A finding never sent (no channel, or below every rule) has no row.
const sqlAckSeen = `
SELECT c.source, c.setting, c.value, min(c.first_seen) AS first_seen, max(c.last_seen) AS last_seen,
       max(c.episodes) AS occurrences, sum(c.sends)::bigint AS sends
  FROM (SELECT s.channel, s.source, s.setting, s.value, min(s.first_sent_at) AS first_seen, max(s.last_sent_at) AS last_seen,
               count(*) AS episodes, sum(s.send_count) AS sends
          FROM pgvigil.alert_state s
         WHERE s.instance_id = $1
         GROUP BY s.channel, s.source, s.setting, s.value) c
 GROUP BY c.source, c.setting, c.value`

// Ack is GET /api/ack: the store (acks), the window's attempts (log), the held sends (suppressed), the open alerts
// with their state (alerts), the Needs-attention rates (attention) and the live figures (live); whether writes are
// on, and why not.
func (s *Server) Ack(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// instance= narrows live to one instance and names seen's (params reads it only when a route requires it)
	id := 0
	if v := r.URL.Query().Get("instance"); v != "" {
		if id, err = strconv.Atoi(v); err != nil || id <= 0 {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("instance: want a positive number, got %q", v))
			return
		}
	}
	if id == 0 && strings.Contains(","+r.URL.Query().Get("part")+",", ",seen,") {
		writeErr(w, http.StatusBadRequest, errors.New("part seen needs instance="))
		return
	}
	now := time.Now()
	exp, err := json.Marshal(s.expected)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	ps, err := onlyPart(r, []part{
		{"acks", sqlAckRows, []any{now}},
		{"log", sqlAckLog, []any{from, to}},
		{"suppressed", sqlAckSuppressed, []any{from, to}},
		{"alerts", sqlAckAlerts, []any{now}},
		{"attention", sqlAckAttention, []any{to}},
		{"live", sqlAckLive, []any{to, string(exp), DefaultStaleSecs, noPermission, id}},
		{"seen", sqlAckSeen, []any{id}},
	})
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	out := map[string]any{}
	why := s.ackOff()
	out["writable"] = why == ""
	if why != "" {
		out["reason"] = why
	}
	out["user"] = ""
	if s.auth != nil {
		out["user"] = s.sessionUser(r)
	}
	if d := s.doorInfo(); d != nil {
		// a demo serve: writable stays false, and the door names its user and the instances it writes for
		out["door"] = d
	}
	for _, p := range ps {
		t, err := s.query(r.Context(), p.sql, p.args...)
		if err != nil {
			s.reply(w, r, nil, fmt.Errorf("%s: %w", p.name, err))
			return
		}
		out[p.name] = t
	}
	s.reply(w, r, out, nil)
}

// ackOff says why acknowledgements cannot be written on this server, "" when they can: they ride the actions door's
// audit login and the UI login.
func (s *Server) ackOff() string {
	switch {
	case s.demo != nil:
		// a demo serve: 'writable' stays false with the door's words, and the door's instances are named beside them (demodoor.go)
		return doorOff
	case s.auth == nil:
		return "acknowledgements need the UI login: this server runs with -no-login"
	case s.actions == nil:
		return "acknowledgements are off on this server (no actions door)"
	case s.actions.audit == nil:
		if s.actions.off != "" {
			return "acknowledgements are written through the actions door's audit login, and it is off: " + s.actions.off
		}
		return "acknowledgements are written through the actions door's audit login, and it is not connected"
	}
	return ""
}

// ackKinds are the kinds import_ack takes (0073).
var ackKinds = map[string]bool{"ack": true, "alert_ack": true, "note": true, "close": true, "blackout": true, "job": true,
	"silence": true, "mute": true, "noise": true}

type ackBody struct {
	Kind        string     `json:"kind"`
	InstanceID  int        `json:"instance_id"`
	CheckKey    string     `json:"check_key"`
	FindingKey  string     `json:"finding_key"`
	JobName     string     `json:"job_name"`
	Tag         string     `json:"tag"`
	MatchText   string     `json:"match_text"`
	Note        string     `json:"note"`
	SeenState   string     `json:"seen_state"`
	StartsAt    *time.Time `json:"starts_at"`
	Until       *time.Time `json:"until"`
	UntilChange bool       `json:"until_change"`
	AckID       int64      `json:"ack_id"`
}

// AckAdd is POST /api/ack: one acknowledgement, note or rule.
func (s *Server) AckAdd(w http.ResponseWriter, r *http.Request) { s.ackWrite(w, r, "add") }

// AckEnd is POST /api/ack/end {ack_id}: ends one (unacknowledge, unsilence, a rule removed); the row stays.
func (s *Server) AckEnd(w http.ResponseWriter, r *http.Request) { s.ackWrite(w, r, "end") }

func (s *Server) ackWrite(w http.ResponseWriter, r *http.Request, op string) {
	seat, ok := s.seat(w, r, s.ackOff())
	if !ok {
		return
	}
	user := seat.user
	raw, err := io.ReadAll(io.LimitReader(r.Body, 8193))
	if err != nil || len(raw) > 8192 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 8 KB"))
		return
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return
	}
	var in ackBody
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	pay := map[string]any{"op": op, "ui_user": user, "client": seat.client}
	sc := writeScope{Route: doorAck, InstanceID: in.InstanceID, FindingKey: in.FindingKey, Tag: in.Tag}
	if op == "end" {
		if in.AckID <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("ack_id must be a positive ack_id"))
			return
		}
		pay["ack_id"] = in.AckID
		sc = writeScope{Route: doorAckEnd, Row: &doorRowRef{"acks", in.AckID}}
	} else {
		if !ackKinds[in.Kind] {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("kind must be one of ack, alert_ack, note, close, blackout, job, silence, mute, noise"))
			return
		}
		pay["kind"] = in.Kind
		if in.InstanceID > 0 {
			var name string
			if err := s.pool.QueryRow(ctx, `SELECT name FROM pgvigil.instances WHERE instance_id = $1`, in.InstanceID).Scan(&name); err != nil {
				writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", in.InstanceID))
				return
			}
			pay["instance_id"], pay["instance_name"] = in.InstanceID, name
		}
		for k, v := range map[string]string{"check_key": in.CheckKey, "finding_key": in.FindingKey, "job_name": in.JobName,
			"tag": in.Tag, "match_text": in.MatchText, "note": in.Note, "seen_state": in.SeenState} {
			if v != "" {
				pay[k] = v
			}
		}
		if in.StartsAt != nil {
			pay["starts_at"] = in.StartsAt.UTC().Format(time.RFC3339Nano)
		}
		if in.Until != nil {
			pay["until"] = in.Until.UTC().Format(time.RFC3339Nano)
		}
		pay["until_change"] = in.UntilChange
	}
	b, _ := json.Marshal(pay)
	var res struct {
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
		AckID   *int64 `json:"ack_id"`
	}
	var out []byte
	// the write outlives a client that hangs up (its audit row is kept), never the 15 s
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	// who writes and on which pool: the audit login on a serve; on a demo serve the door's own, and only for a scope it allows
	pool, ok := seat.poolFor(wctx, w, sc)
	if !ok {
		return
	}
	if err := pool.QueryRow(wctx, `SELECT pgvigil.import_ack($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("ack: not written", "op", op, "kind", in.Kind, "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_ack answered %q", out))
		return
	}
	s.log.Info("ack: attempt", "op", op, "kind", in.Kind, "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	o := map[string]any{"outcome": res.Outcome, "detail": res.Detail, "ack_id": res.AckID}
	if code != http.StatusOK {
		o["error"] = res.Detail
	}
	_ = json.NewEncoder(w).Encode(o)
}
