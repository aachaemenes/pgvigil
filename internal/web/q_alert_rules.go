package web

// Alert rules (task 131; Darling's Alert Rules and Threshold Overrides). GET /api/alertrules?[from=&to=]
// [&part=rules|state|log|catalog|sender|inforce] reads the store of 0085: the rules (live, and the ones ended in the window)
// with where each is in force and fires, what the alert sender last made of every rule in force (alert_rule_state),
// the window's attempts (alert_rule_log), the metrics a rule may name, and whether a sender judges the rules at all.
// POST /api/alertrules makes, edits or switches one rule and POST /api/alertrules/end ends one, both the way of
// q_ack.go: the UI login (the session's user is the row's created_by), the X-Pgvigil header, and the actions door's
// audit pool, never the read-only pool. pgvigil.import_alert_rule writes the row and its log line in one call, a
// refused attempt included. A request's shape is checked by alerts.RulePayload; the rules are judged by the alert
// sender's pass (internal/alerts), not here.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/alerts"
)

// sqlAlertRules: the live rules and the ones ended at or after $1, live first. covers = the active instances in the
// rule's scope; in_force = where no more specific rule overrides it; the state counts are the sender's last pass.
const sqlAlertRules = `
WITH sc AS (
  SELECT s.rule_id, count(*) AS covers FROM pgvigil.alert_rule_scope s GROUP BY s.rule_id
), ef AS (
  SELECT e.rule_id, count(*) AS in_force FROM pgvigil.alert_rules_effective e GROUP BY e.rule_id
), st AS (
  SELECT s.rule_id,
         count(*) FILTER (WHERE s.state IN ('warning', 'critical')) AS firing,
         count(*) FILTER (WHERE s.state = 'pending') AS pending,
         count(*) FILTER (WHERE s.state = 'nodata') AS nodata,
         string_agg(i.name || CASE WHEN s.database <> '' THEN ' [' || s.database || ']' ELSE '' END, ', ' ORDER BY i.name, s.database)
           FILTER (WHERE s.state IN ('warning', 'critical')) AS firing_on,
         max(s.evaluated_at) AS evaluated_at
    FROM pgvigil.alert_rule_state s JOIN pgvigil.instances i USING (instance_id)
   GROUP BY s.rule_id
)
SELECT r.rule_id, r.name, r.metric, c.family_label, c.label, c.unit, c.engine, c.per_database,
       r.op, r.warning, r.critical, r.for_minutes, r.scope, r.tag, r.instance_name, r.instance_id, r.database, r.note,
       r.enabled, r.replaces, r.created_by, r.created_at, r.client, r.ended_by, r.ended_at, r.ended_at IS NULL AS live,
       coalesce(sc.covers, 0) AS covers, coalesce(ef.in_force, 0) AS in_force,
       coalesce(st.firing, 0) AS firing, coalesce(st.pending, 0) AS pending, coalesce(st.nodata, 0) AS nodata,
       st.firing_on, st.evaluated_at, f.last_fired_at, f.last_instance, f.fired
  FROM pgvigil.alert_rules r
  LEFT JOIN pgvigil.metric_catalog c ON c.key = r.metric
  LEFT JOIN sc ON sc.rule_id = r.rule_id
  LEFT JOIN ef ON ef.rule_id = r.rule_id
  LEFT JOIN st ON st.rule_id = r.rule_id
  LEFT JOIN pgvigil.alert_rule_fired f ON f.rule_id = r.rule_id
 WHERE r.ended_at IS NULL OR r.ended_at >= $1
 ORDER BY (r.ended_at IS NULL) DESC, r.metric, CASE r.scope WHEN 'fleet' THEN 1 WHEN 'tag' THEN 2 ELSE 3 END, r.rule_id
 LIMIT 2000`

// sqlAlertRuleState: what the sender last made of every rule in force, per instance and series; the rows firing
// first, then pending, no data, ok
const sqlAlertRuleState = `
SELECT s.instance_id, i.name AS instance, s.metric, c.family_label, c.label, c.unit, nullif(s.database, '') AS database,
       s.rule_id, r.name AS rule_name, r.op, r.for_minutes, r.scope, coalesce(r.tag, r.instance_name) AS target,
       s.state, s.held, s.value, s.threshold, s.sample_at, s.beyond_since, s.since, s.evaluated_at
  FROM pgvigil.alert_rule_state s
  JOIN pgvigil.instances i USING (instance_id)
  JOIN pgvigil.alert_rules r USING (rule_id)
  LEFT JOIN pgvigil.metric_catalog c ON c.key = s.metric
 ORDER BY CASE s.state WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 WHEN 'pending' THEN 2 WHEN 'nodata' THEN 3 ELSE 4 END,
          i.name, s.metric, s.database
 LIMIT 5000`

// sqlAlertRuleLog: the window's attempts, newest first
const sqlAlertRuleLog = `
SELECT l.at, l.ui_user, l.client, l.op, l.rule_id, l.metric, l.outcome, l.detail
  FROM pgvigil.alert_rule_log l
 WHERE l.at >= $1 AND l.at < $2
 ORDER BY l.at DESC, l.log_id DESC
 LIMIT 1000`

// sqlAlertRuleCatalog: every metric a rule may name
const sqlAlertRuleCatalog = `
SELECT c.key, c.engine, c.family, c.family_label, c.metric, c.label, c.unit, c.per_database
  FROM pgvigil.metric_catalog c
 ORDER BY CASE c.engine WHEN 'postgres' THEN 1 WHEN 'sqlserver' THEN 2 ELSE 3 END, c.family_sort, c.sort`

// sqlAlertRuleSender: does anything judge the rules? The sender's newest evaluation and how old it is by the
// repository's clock (a sender that stopped leaves its last states standing: the page says how old they are), the
// channels configured, and the sender's newest pass of any kind (a pass with no channel judges nothing)
const sqlAlertRuleSender = `
SELECT (SELECT max(s.evaluated_at) FROM pgvigil.alert_rule_state s) AS evaluated_at,
       (SELECT extract(epoch FROM now() - max(s.evaluated_at))::int FROM pgvigil.alert_rule_state s) AS evaluated_secs_ago,
       (SELECT count(*) FROM pgvigil.alert_channels c WHERE c.is_configured) AS channels,
       (SELECT max(l.snapshot_at) FROM pgvigil.alert_log l WHERE l.snapshot_at > now() - interval '1 day') AS last_pass_at,
       (SELECT count(*) FROM pgvigil.alert_rules_effective) AS in_force`

// sqlThresholdsInForce (task 151, K07.07): every threshold in force per active instance - the alert rule the sender
// judges each metric's series by (alert_rules_effective: an instance's rule over a tag's over the fleet's), with the
// rules it overrides on that instance - and, on a SQL Server instance, the HA/DR, jobs and backups thresholds of
// mssql_hadr_limits (0066), each marked 'file' where the configuration sets it (mssql_thresholds) and 'default'
// where it does not: those are read only here, the file is their source.
const sqlThresholdsInForce = `
SELECT i.instance_id, i.name AS instance, i.engine, 'rule' AS source, e.metric AS what, c.family_label, c.label, c.unit,
       e.database, e.rule_id, e.name AS rule_name, e.scope, coalesce(e.tag, e.instance_name) AS target, e.op,
       e.warning, e.critical, e.for_minutes, NULL::text AS value,
       (SELECT string_agg('rule ' || o.rule_id || ' (' || o.scope || coalesce(' ' || coalesce(o.tag, o.instance_name), '') || ')', ', '
                          ORDER BY o.level DESC, o.rule_id DESC)
          FROM pgvigil.alert_rule_scope o
         WHERE o.instance_id = e.instance_id AND o.metric = e.metric AND coalesce(o.database, '') = coalesce(e.database, '')
           AND o.rule_id <> e.rule_id) AS overrides,
       coalesce(t.tags, '{}'::text[]) AS tags
  FROM pgvigil.alert_rules_effective e
  JOIN pgvigil.instances i ON i.instance_id = e.instance_id
  LEFT JOIN pgvigil.metric_catalog c ON c.key = e.metric
  LEFT JOIN pgvigil.instance_tags_merged t ON t.instance_id = i.instance_id
UNION ALL
SELECT i.instance_id, i.name, i.engine, CASE WHEN f.value IS NOT NULL THEN 'file' ELSE 'default' END, 'mssql.' || l.key,
       'SQL Server HA/DR, jobs and backups', l.key, NULL, NULL, NULL, NULL, 'instance', i.name, NULL, NULL, NULL, NULL,
       l.value, NULL, coalesce(t.tags, '{}'::text[])
  FROM pgvigil.mssql_hadr_limits h
  JOIN pgvigil.instances i ON i.instance_id = h.instance_id AND i.is_active
  CROSS JOIN LATERAL jsonb_each_text(to_jsonb(h) - 'instance_id') l
  LEFT JOIN LATERAL (SELECT to_jsonb(x) -> l.key AS value FROM pgvigil.mssql_hadr_thresholds x
                      WHERE x.instance_id = h.instance_id AND to_jsonb(x) -> l.key <> 'null'::jsonb) f ON true
  LEFT JOIN pgvigil.instance_tags_merged t ON t.instance_id = i.instance_id
 ORDER BY 2, 4 DESC, 5, 9 NULLS FIRST
 LIMIT 5000`

// AlertRules is GET /api/alertrules: the rules, their state, the window's attempts, the metric catalogue and the
// sender's line; whether writes are on, and why not.
func (s *Server) AlertRules(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ps, err := onlyPart(r, []part{
		{"rules", sqlAlertRules, []any{from}},
		{"state", sqlAlertRuleState, nil},
		{"log", sqlAlertRuleLog, []any{from, to}},
		{"catalog", sqlAlertRuleCatalog, nil},
		{"sender", sqlAlertRuleSender, nil},
		{"inforce", sqlThresholdsInForce, nil},
	})
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	out := map[string]any{}
	s.alertRulesDoor(r, out)
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

// alertRulesDoor writes into a reply whether alert rules can be written on this server (writable, the reason when
// not) and the session's user.
func (s *Server) alertRulesDoor(r *http.Request, out map[string]any) {
	why := s.alertRulesOff()
	out["writable"] = why == ""
	if why != "" {
		out["reason"] = why
	}
	out["user"] = ""
	if s.auth != nil {
		out["user"] = s.sessionUser(r)
	}
}

// alertRulesOff says why alert rules cannot be written on this server, "" when they can: like acknowledgements they
// ride the UI login and the actions door's audit login.
func (s *Server) alertRulesOff() string {
	switch {
	case s.auth == nil:
		return "alert rules are edited behind the UI login: this server runs with -no-login"
	case s.actions == nil:
		return "alert rule edits are off on this server (no actions door)"
	case s.actions.audit == nil:
		if s.actions.off != "" {
			return "alert rules are written through the actions door's audit login, and it is off: " + s.actions.off
		}
		return "alert rules are written through the actions door's audit login, and it is not connected"
	}
	return ""
}

// AlertRuleWrite is POST /api/alertrules: one rule added, edited (the rule is ended and its successor written) or
// switched on or off.
func (s *Server) AlertRuleWrite(w http.ResponseWriter, r *http.Request) { s.alertRuleWrite(w, r, "") }

// AlertRuleEnd is POST /api/alertrules/end {rule_id}: ends one rule; the row stays with who ended it and when.
func (s *Server) AlertRuleEnd(w http.ResponseWriter, r *http.Request) { s.alertRuleWrite(w, r, "end") }

func (s *Server) alertRuleWrite(w http.ResponseWriter, r *http.Request, forced string) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.alertRulesOff(); why != "" {
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
	var in alerts.RuleRequest
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	// an instance rule's instance, read here: no such active instance is the request's fault (400, said by
	// RulePayload), a repository that could not answer is not (500)
	var instName string
	if in.Scope == "instance" && in.InstanceID > 0 && in.InstanceID <= math.MaxInt32 {
		err := s.pool.QueryRow(ctx, `SELECT name FROM pgvigil.instances WHERE instance_id = $1 AND is_active`, in.InstanceID).Scan(&instName)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			s.log.Warn("alert rule: the instance could not be read", "instance_id", in.InstanceID, "err", err)
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the instance could not be read: %v", err))
			return
		}
	}
	pay, err := alerts.RulePayload(in, forced, func(int) string { return instName })
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	pay["ui_user"], pay["client"] = user, clientIP(r)
	b, _ := json.Marshal(pay)
	var res struct {
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
		RuleID  *int64 `json:"rule_id"`
	}
	var out []byte
	// the write outlives a client that hangs up (its log row is kept), never the 15 s
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_alert_rule($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("alert rule: not written", "op", pay["op"], "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_alert_rule answered %q", out))
		return
	}
	s.log.Info("alert rule: attempt", "op", pay["op"], "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	o := map[string]any{"outcome": res.Outcome, "detail": res.Detail, "rule_id": res.RuleID}
	if code != http.StatusOK {
		o["error"] = res.Detail
	}
	_ = json.NewEncoder(w).Encode(o)
}
