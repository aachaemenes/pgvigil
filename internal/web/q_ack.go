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

// sqlAckAlerts: one row per open alert (its finding key over every channel) with what the store says of it now
const sqlAckAlerts = `
WITH o AS (
  SELECT s.finding_key, max(s.instance_id) AS instance_id, max(s.instance_name) AS instance, max(s.severity) AS severity,
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
                  AND pgvigil.ack_live(b.ended_at, b.starts_at, b.until, $1)) AS is_blackout,
       h.kind AS held_by, h.ack_id AS hold_id,
       (SELECT string_agg(z.note, '; ' ORDER BY z.ack_id) FROM pgvigil.acks z
         WHERE z.kind = 'noise' AND pgvigil.ack_live(z.ended_at, z.starts_at, z.until, $1)
           AND pgvigil.ack_rule_matches(z, o.instance, coalesce(t.tags, '{}'), o.finding_key, o.source, o.setting, o.value)) AS known_noise
  FROM o
  LEFT JOIN pgvigil.instance_tags_merged t USING (instance_id)
  LEFT JOIN LATERAL (SELECT a.ack_id, a.created_by, a.created_at FROM pgvigil.acks a WHERE a.kind = 'alert_ack'
                        AND a.finding_key = o.finding_key AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, $1)
                      ORDER BY a.created_at DESC LIMIT 1) ak ON true
  LEFT JOIN LATERAL (SELECT a.ack_id, a.created_by, a.created_at FROM pgvigil.acks a WHERE a.kind = 'close'
                        AND a.finding_key = o.finding_key AND a.ended_at IS NULL
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

// Ack is GET /api/ack: the store (acks), the window's attempts (log), the held sends (suppressed), the open alerts
// with their state (alerts) and the Needs-attention rates (attention); whether writes are on, and why not.
func (s *Server) Ack(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	now := time.Now()
	ps, err := onlyPart(r, []part{
		{"acks", sqlAckRows, []any{now}},
		{"log", sqlAckLog, []any{from, to}},
		{"suppressed", sqlAckSuppressed, []any{from, to}},
		{"alerts", sqlAckAlerts, []any{now}},
		{"attention", sqlAckAttention, []any{to}},
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
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.ackOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
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
	pay := map[string]any{"op": op, "ui_user": user, "client": clientIP(r)}
	if op == "end" {
		if in.AckID <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("ack_id must be a positive ack_id"))
			return
		}
		pay["ack_id"] = in.AckID
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
	if err := s.actions.audit.QueryRow(context.WithoutCancel(ctx), `SELECT pgvigil.import_ack($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
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
