package web

// Alert scope (task 403a; migration 0154). GET /api/alertscope?[from=&to=][&instance_id=][&part=windows|held|flapping|
// overrides|history|digests] reads:
//   windows    the blackout, mute and digest windows (live, and the ones ended in the window), each with whether it
//              holds now
//   held       the held sends of every hold (alert_held_all: the acks' and the windows', the digest carry-over, the
//              flapping hold) seen in the window - the Alerts page's 'why held' line
//   flapping   the rule series marked flapping now (SQLWATCH's ratio), with their mark
//   overrides  per live rule, the rule of its family in force instead of it, and on how many instances
//   history    the findings history (open, close, severity, the hourly sample) of one instance (instance_id), or of
//              the fleet, in the window (at most 90 days)
//   digests    the digests sent, failed or empty in the window
//   rules      0154's fields of every rule live or ended in the window (the tag list and its words, the family, the
//              band and zone of a baseline rule, the flapping opt-out), merged into the rules page by rule id
// POST /api/alertwindows makes, edits or ends one window the way of q_alert_rules.go: the UI login, the X-Pgvigil
// header and the actions door's audit pool; pgvigil.import_alert_window writes the row and its log line in one call.
// The minimum role for the write is operator (B24f).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/alerts"
)

const sqlAlertWindows = `
SELECT w.window_id, w.name, w.action, w.scope, w.scope_tags, w.instance_name, w.from_rule_id, w.weekdays,
       to_char(w.start_local, 'HH24:MI') AS start_local, to_char(w.end_local, 'HH24:MI') AS end_local, w.zone,
       w.severity_ceiling, w.starts_at, w.until, w.note, w.replaces, w.created_by, w.created_at, w.ended_by, w.ended_at,
       w.ended_at IS NULL AS live, pgvigil.alert_window_live(w, now()) AS holds_now
  FROM pgvigil.alert_windows w
 WHERE w.ended_at IS NULL OR w.ended_at >= $1
 ORDER BY w.ended_at IS NULL DESC, w.created_at DESC
 LIMIT 500`

const sqlAlertHeld = `
SELECT h.hold_kind, h.hold_id, h.hold_source, h.channel, h.finding_key, h.instance_name, h.severity, h.source, h.setting,
       h.value, h.first_at, h.last_at, h.passes
  FROM pgvigil.alert_held_all h
 WHERE h.last_at >= $1 AND h.last_at <= $2
 ORDER BY h.last_at DESC
 LIMIT 1000`

const sqlAlertFlapping = `
SELECT s.rule_id, r.name AS rule_name, i.name AS instance, s.metric, nullif(s.database, '') AS database, s.op_family,
       s.state, s.flapping_since, s.results
  FROM pgvigil.alert_rule_state s
  JOIN pgvigil.alert_rules r USING (rule_id)
  JOIN pgvigil.instances i USING (instance_id)
 WHERE s.flapping_since IS NOT NULL
 ORDER BY s.flapping_since`

const sqlAlertOverrides = `
SELECT o.rule_id, o.by_rule_id, b.name AS by_rule_name, o.instances
  FROM pgvigil.alert_rule_overrides o
  JOIN pgvigil.alert_rules b ON b.rule_id = o.by_rule_id
 ORDER BY o.rule_id, o.instances DESC`

// the newest 20,000 rows of the window, oldest first (a long window keeps its recent end; cut = the page says so)
const sqlFindingsHistory = `
SELECT x.*, count(*) OVER () = 20000 AS cut
  FROM (SELECT h.snapshot_at, h.finding_key, h.instance_id, h.instance_name, h.source, h.setting, h.value, h.event,
               h.severity, h.metric_value
          FROM pgvigil.findings_history h
         WHERE h.snapshot_at >= greatest($1::timestamptz, now() - interval '90 days') AND h.snapshot_at <= $2
           AND ($3::int IS NULL OR h.instance_id = $3)
         ORDER BY h.snapshot_at DESC, h.finding_key
         LIMIT 20000) x
 ORDER BY x.snapshot_at, x.finding_key`

const sqlAlertScopeRules = `
SELECT r.rule_id, r.scope_tags, pgvigil.alert_scope_text(r.scope_tags) AS scope_text, r.op_family, r.band_pct, r.zone,
       r.ignore_flapping
  FROM pgvigil.alert_rules r
 WHERE r.ended_at IS NULL OR r.ended_at >= $1`

const sqlDigests = `
SELECT l.channel, l.at, l.due_at, l.since, l.outcome, l.groups, l.alerts, l.error
  FROM pgvigil.digest_log l
 WHERE l.at >= $1 AND l.at <= $2
 ORDER BY l.at DESC
 LIMIT 500`

// AlertScope is GET /api/alertscope: the parts above.
func (s *Server) AlertScope(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var inst *int
	if v := r.URL.Query().Get("instance_id"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 || n > math.MaxInt32 {
			writeErr(w, http.StatusBadRequest, errors.New("instance_id must be a positive instance id"))
			return
		}
		inst = &n
	}
	ps, err := onlyPart(r, []part{
		{"windows", sqlAlertWindows, []any{from}},
		{"held", sqlAlertHeld, []any{from, to}},
		{"flapping", sqlAlertFlapping, nil},
		{"overrides", sqlAlertOverrides, nil},
		{"history", sqlFindingsHistory, []any{from, to, inst}},
		{"digests", sqlDigests, []any{from, to}},
		{"rules", sqlAlertScopeRules, []any{from}},
	})
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	out := map[string]any{}
	s.alertRulesDoor(r, out) // windows are written through the same door as the rules
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

// AlertWindowWrite is POST /api/alertwindows {op: add|edit|end, ...alerts.WindowRequest}: one window made, replaced
// by its successor, or ended; the row stays with who ended it and when.
func (s *Server) AlertWindowWrite(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.alertRulesOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(strings.Replace(why, "alert rule", "alert window", 1)))
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
	var in alerts.WindowRequest
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	var instName string
	if in.Scope == "instance" && in.InstanceID > 0 && in.InstanceID <= math.MaxInt32 {
		err := s.pool.QueryRow(ctx, `SELECT name FROM pgvigil.instances WHERE instance_id = $1 AND is_active`, in.InstanceID).Scan(&instName)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			s.log.Warn("alert window: the instance could not be read", "instance_id", in.InstanceID, "err", err)
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the instance could not be read: %v", err))
			return
		}
	}
	pay, err := alerts.WindowPayload(in, func(int) string { return instName })
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	pay["ui_user"], pay["client"] = user, clientIP(r)
	b, _ := json.Marshal(pay)
	var res struct {
		Outcome  string `json:"outcome"`
		Detail   string `json:"detail"`
		WindowID *int64 `json:"window_id"`
	}
	var out []byte
	// the write outlives a client that hangs up (its log row is kept), never the 15 s
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_alert_window($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("alert window: not written", "op", pay["op"], "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_alert_window answered %q", out))
		return
	}
	s.log.Info("alert window: attempt", "op", pay["op"], "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	o := map[string]any{"outcome": res.Outcome, "detail": res.Detail, "window_id": res.WindowID}
	if code != http.StatusOK {
		o["error"] = res.Detail
	}
	_ = json.NewEncoder(w).Encode(o)
}
