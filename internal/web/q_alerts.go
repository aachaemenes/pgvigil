package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// The Alerts tab at the root (task 60): GET /api/alerts?[from=&to=][&part=channels|open|log] (Server.Alerts) is the
// channels the alert sender last recorded (pgvigil.alert_channels, 0059: kind, the destination as shown, the severity
// floor, the instances and tags, quiet hours, repeat, recovery, whether the configuration still names it) with each
// one's last attempt and last successful send, the alerts open now (sent, not yet cleared), and every send attempt of
// the window (pgvigil.alert_log: the outcome and the error text). The Findings tab's sent / when / where column reads
// pgvigil.findings_alerts (the shell's query change). No Summary column: an alert is a finding sent, not a finding.
//
// Task 151 (K07, migration 0093) adds the parts history (every firing and its clearance in the window:
// pgvigil.alert_occurrences, the value and the threshold where one is known), tests (the Send test requests and their
// answers), dismissed (the dismissals in force and the ones ended in the window) and mutes (the mute rules and known
// patterns with their start, pause and successor) and fixes (the fix statement of each open alert that has one:
// pgvigil.finding_fix); with k=<finding key> the same route serves one alert's page
// instead (part=card|occurrences|sends|notes: the finding now with its fix statement, every firing of it, every send
// attempt that carried it, its acknowledgements, notes, mutes and dismissals). Three writes ride the actions door as
// acknowledgements do (the UI login, the X-Pgvigil header, the audit pool): POST /api/alerts/test {channel},
// POST /api/alerts/dismiss {op: add|end, finding_key, reason | dismiss_id} and POST /api/alerts/mute {op: edit|pause|
// resume, ack_id, and for edit the rule's fields}.

const sqlAlertChannels = `
SELECT c.name, c.kind, c.destination, c.min_severity, c.instances, c.tags, c.quiet_hours, c.timezone, c.repeat_secs,
       c.recovery, c.max_per_hour, c.templates, c.link_base, c.is_configured, c.configured_at, c.updated_at,
       l.snapshot_at AS last_attempt_at, l.outcome AS last_outcome, l.error AS last_error,
       (SELECT max(s.snapshot_at) FROM pgvigil.alert_log s WHERE s.channel = c.name AND s.outcome = 'sent') AS last_sent_at,
       (SELECT count(*) FROM pgvigil.alert_state o WHERE o.channel = c.name AND o.cleared_at IS NULL) AS open_alerts,
       (SELECT coalesce(sum(h.n_firing + h.n_repeat + h.n_resolved), 0) FROM pgvigil.alert_log h
         WHERE h.channel = c.name AND h.outcome = 'sent' AND h.snapshot_at > now() - interval '1 hour') AS sent_last_hour,
       (SELECT count(*) FROM pgvigil.alert_log h WHERE h.channel = c.name AND h.outcome = 'capped'
           AND h.snapshot_at > now() - interval '1 hour') AS capped_passes_last_hour,
       t.test_id AS last_test_id, t.requested_by AS last_test_by, t.requested_at AS last_test_at, t.done_at AS last_test_done,
       CASE WHEN t.test_id IS NULL THEN NULL
            ELSE coalesce(t.outcome, CASE WHEN t.requested_at <= now() - pgvigil.alert_test_window() THEN 'no answer' ELSE 'waiting' END) END AS last_test_outcome,
       t.error AS last_test_error
  FROM pgvigil.alert_channels c
  LEFT JOIN LATERAL (SELECT a.snapshot_at, a.outcome, a.error FROM pgvigil.alert_log a
                      WHERE a.channel = c.name AND a.outcome <> 'cleared' ORDER BY a.snapshot_at DESC LIMIT 1) l ON true
  LEFT JOIN LATERAL (SELECT x.* FROM pgvigil.alert_tests x WHERE x.channel = c.name ORDER BY x.requested_at DESC LIMIT 1) t ON true
 ORDER BY c.is_configured DESC, c.name`

const sqlAlertOpen = `
SELECT s.channel, s.instance_id, s.instance_name AS instance, s.severity, s.source, s.setting, s.value, s.first_sent_at,
       s.last_sent_at, s.send_count, s.finding_key
  FROM pgvigil.alert_state s
 WHERE s.cleared_at IS NULL
 ORDER BY CASE s.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, s.first_sent_at DESC
 LIMIT 500`

const sqlAlertLog = `
SELECT l.snapshot_at AS at, l.channel, l.kind, l.destination, l.outcome, l.n_firing, l.n_repeat, l.n_resolved, l.error,
       i.name AS instance, cardinality(l.keys) AS alerts
  FROM pgvigil.alert_log l
  LEFT JOIN pgvigil.instances i ON i.instance_id = l.instance_id
 WHERE l.snapshot_at >= $1 AND l.snapshot_at < $2
 ORDER BY l.snapshot_at DESC
 LIMIT 1000`

// alertThreshold: an alert rule's value reads "above 10 for 5 min; last sample 12" (0085): its threshold is the first
// two words
const alertThreshold = `CASE WHEN o.source = 'alert rule' THEN substring(o.value FROM '^((?:above|below) [^ ]+)') END`

// sqlAlertHistory: every firing open at some point of the window [$1, $2), newest first; a finding's suggested value
// (its threshold while it stands) comes with the fixes part, so the findings view is not read here
const sqlAlertHistory = `
SELECT o.fired_at, o.cleared_at, o.status, o.severity, o.instance_id, o.instance, o.source, o.setting, o.value,
       ` + alertThreshold + ` AS threshold, o.channels, o.sends, o.occurrence, o.finding_key, o.missing_since,
       d.dismiss_id IS NOT NULL AS dismissed
  FROM pgvigil.alert_occurrences o
  LEFT JOIN pgvigil.alert_dismissals d ON d.finding_key = o.finding_key AND d.ended_at IS NULL
 WHERE o.fired_at < $2 AND (o.cleared_at IS NULL OR o.cleared_at >= $1)
 ORDER BY o.fired_at DESC
 LIMIT 1000`

// sqlAlertTests: the Send test requests asked in the window, newest first
const sqlAlertTests = `
SELECT t.test_id, t.channel, t.requested_by, t.requested_at, t.client, t.done_at,
       coalesce(t.outcome, CASE WHEN t.requested_at <= now() - pgvigil.alert_test_window() THEN 'no answer' ELSE 'waiting' END) AS outcome,
       t.error
  FROM pgvigil.alert_tests t
 WHERE t.requested_at >= $1 AND t.requested_at < $2
 ORDER BY t.requested_at DESC
 LIMIT 500`

// sqlAlertDismissed: the dismissals in force, and the ones ended in the window
const sqlAlertDismissed = `
SELECT d.dismiss_id, d.finding_key, d.instance_id, d.instance_name AS instance, d.source, d.setting, d.reason, d.created_by,
       d.created_at, d.client, d.ended_by, d.ended_at, d.ended_at IS NULL AS live
  FROM pgvigil.alert_dismissals d
 WHERE d.ended_at IS NULL OR d.ended_at >= $1
 ORDER BY d.ended_at IS NULL DESC, d.created_at DESC
 LIMIT 1000`

// sqlAlertMutes: the mute rules and known patterns in force, starting later, paused, or ended in the last 7 days
const sqlAlertMutes = `
SELECT a.ack_id, a.kind, a.instance_id, a.instance_name AS instance, a.check_key, a.finding_key, a.tag, a.match_text, a.note,
       a.starts_at, a.until, a.created_by, a.created_at, a.ended_by, a.ended_at, a.paused_at, a.paused_by, a.replaces,
       CASE WHEN a.ended_at IS NOT NULL THEN 'ended'
            WHEN a.until IS NOT NULL AND a.until <= $1 THEN 'expired'
            WHEN a.starts_at > $1 THEN 'upcoming'
            WHEN a.paused_at IS NOT NULL THEN 'paused'
            ELSE 'in force' END AS state,
       (SELECT count(*) FROM pgvigil.ack_suppressed x WHERE x.ack_id = a.ack_id) AS held_alerts,
       (SELECT max(x.last_at) FROM pgvigil.ack_suppressed x WHERE x.ack_id = a.ack_id) AS held_last,
       (SELECT n.ack_id FROM pgvigil.acks n WHERE n.replaces = a.ack_id LIMIT 1) AS replaced_by
  FROM pgvigil.acks a
 WHERE a.kind IN ('mute', 'noise')
   AND (a.ended_at IS NULL AND (a.until IS NULL OR a.until > $1) OR coalesce(a.ended_at, a.until) >= $1::timestamptz - interval '7 days')
 ORDER BY a.kind, (a.ended_at IS NULL AND (a.until IS NULL OR a.until > $1)) DESC, a.created_at DESC
 LIMIT 1000`

// sqlAlertFixes: per standing finding that an alert carries (any alert_state row of its key), its fix statement
// (pgvigil.finding_fix) and its suggested value: the open alerts' fix column and the history's threshold read
// pgvigil.findings once here
const sqlAlertFixes = `
WITH k AS (SELECT DISTINCT s.finding_key FROM pgvigil.alert_state s),
fx AS MATERIALIZED (
  SELECT pgvigil.alert_key(y.instance_id, y.source, y.setting, y.value) AS finding_key, y.suggested,
         pgvigil.finding_fix(i.engine, y.source, y.instance_id, y.setting, y.is_set, y.suggested, y.detail) AS fix,
         pgvigil.severity_rank(y.severity) AS sev
    FROM pgvigil.findings y
    LEFT JOIN pgvigil.instances i ON i.instance_id = y.instance_id
   WHERE i.is_active OR y.source = 'pgvigil repository'
)
SELECT DISTINCT ON (fx.finding_key) fx.finding_key, fx.fix, fx.suggested
  FROM fx JOIN k ON k.finding_key = fx.finding_key
 WHERE fx.fix IS NOT NULL OR fx.suggested IS NOT NULL
 ORDER BY fx.finding_key, fx.sev DESC`

// The alert's page (k=<finding key>): the finding as it stands now (none = gone from the findings) with its fix
const sqlAlertCard = `
WITH f AS MATERIALIZED (
  SELECT pgvigil.alert_key(y.instance_id, y.source, y.setting, y.value) AS finding_key, y.instance_id, y.severity,
         y.source, y.setting, y.value, y.suggested, y.detail, y.at, y.is_set
    FROM pgvigil.findings y
  UNION ALL
  SELECT pgvigil.alert_finding_key(r.instance_id, r.source, r.setting, r.value), r.instance_id, r.severity, r.source,
         r.setting, r.value, r.suggested, r.detail, r.at, r.is_set
    FROM pgvigil.alert_rule_findings r
)
SELECT f.finding_key, f.instance_id, coalesce(i.name, 'pgvigil') AS instance, f.severity, f.source, f.setting, f.value, f.suggested, f.detail,
       f.at, i.engine, f.is_set, pgvigil.finding_fix(i.engine, f.source, f.instance_id, f.setting, f.is_set, f.suggested, f.detail) AS fix,
       CASE WHEN f.source = 'alert rule' THEN substring(f.value FROM '^((?:above|below) [^ ]+)') ELSE f.suggested END AS threshold
  FROM f
  LEFT JOIN pgvigil.instances i ON i.instance_id = f.instance_id
 WHERE f.finding_key = $1 AND (i.is_active OR f.source = 'pgvigil repository')
 ORDER BY pgvigil.severity_rank(f.severity) DESC
 LIMIT 1`

// every firing of the alert, newest first, with the open one's per-channel state
const sqlAlertOccurrences = `
SELECT o.occurrence, o.fired_at, o.last_sent_at, o.cleared_at, o.status, o.severity, o.instance_id, o.instance, o.source,
       o.setting, o.value, CASE WHEN o.source = 'alert rule' THEN substring(o.value FROM '^((?:above|below) [^ ]+)') END AS threshold,
       o.channels, o.sends, o.missing_since, i.engine, i.is_active
  FROM pgvigil.alert_occurrences o
  LEFT JOIN pgvigil.instances i ON i.instance_id = o.instance_id
 WHERE o.finding_key = $1
 ORDER BY o.fired_at DESC
 LIMIT 200`

// every send attempt that carried the alert (its key in the attempt's keys), newest first
const sqlAlertSends = `
SELECT l.snapshot_at AS at, l.channel, l.kind, l.destination, l.outcome, l.n_firing, l.n_repeat, l.n_resolved, l.error
  FROM pgvigil.alert_log l
 WHERE $1 = ANY (l.keys)
   AND l.snapshot_at >= coalesce((SELECT min(s.first_sent_at) FROM pgvigil.alert_state s WHERE s.finding_key = $1), now()) - interval '1 day'
 ORDER BY l.snapshot_at DESC
 LIMIT 500`

// what people did with the alert: acknowledgements, notes, closes and mutes of its key, and its dismissals
const sqlAlertNotes = `
SELECT a.created_at AS at, a.kind, a.created_by AS by, a.note, a.until, a.ended_by, a.ended_at, a.paused_at
  FROM pgvigil.acks a
 WHERE a.finding_key = $1
UNION ALL
SELECT d.created_at, 'dismiss', d.created_by, d.reason, NULL, d.ended_by, d.ended_at, NULL
  FROM pgvigil.alert_dismissals d
 WHERE d.finding_key = $1
 ORDER BY 1 DESC
 LIMIT 500`

var findingKeyRE = regexp.MustCompile(`^[0-9a-f]{32}$`)

// Alerts serves the Alerts tab: the channels, the open alerts, the window's send log, the history, the tests, the
// dismissals and the mute rules; with k, one alert's page.
func (s *Server) Alerts(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	if k := r.URL.Query().Get("k"); k != "" {
		if !findingKeyRE.MatchString(k) {
			writeErr(w, http.StatusBadRequest, errors.New("k must be an alert's key (32 hexadecimal digits)"))
			return
		}
		s.multiPart(w, r, []part{
			{"card", sqlAlertCard, []any{k}},
			{"occurrences", sqlAlertOccurrences, []any{k}},
			{"sends", sqlAlertSends, []any{k}},
			{"notes", sqlAlertNotes, []any{k}},
		})
		return
	}
	now := time.Now()
	s.multiPart(w, r, []part{
		{"channels", sqlAlertChannels, nil},
		{"open", sqlAlertOpen, nil},
		{"log", sqlAlertLog, []any{from, to}},
		{"history", sqlAlertHistory, []any{from, to}},
		{"tests", sqlAlertTests, []any{from, to}},
		{"dismissed", sqlAlertDismissed, []any{from}},
		{"mutes", sqlAlertMutes, []any{now}},
		{"fixes", sqlAlertFixes, nil},
	})
}

// doorBody reads a write's body: at most 8 KB, no NUL, one JSON object.
func doorBody(r *http.Request, into any) error {
	raw, err := io.ReadAll(io.LimitReader(r.Body, 8193))
	if err != nil || len(raw) > 8192 {
		return errors.New("body: unreadable or over 8 KB")
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		return errors.New("the request holds a NUL character: nothing was written")
	}
	if err := json.Unmarshal(raw, into); err != nil {
		return fmt.Errorf("body: %w", err)
	}
	return nil
}

// alertDoor runs one write through the actions door's audit login: fn is an import_* function of 0093 taking
// (at, payload) and answering {outcome, detail, <id>}; build adds the request's fields to the payload (an error = 400,
// nothing called). The answer: 200 done, 409 refused (the store's reason), as /api/ack.
func (s *Server) alertDoor(w http.ResponseWriter, r *http.Request, fn string, build func(ctx context.Context, pay map[string]any) error) {
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
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	pay := map[string]any{"ui_user": user, "client": clientIP(r)}
	if err := build(ctx, pay); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	b, _ := json.Marshal(pay)
	var out []byte
	// the write outlives a client that hangs up (its audit row is kept), never the 15 s
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.`+fn+`($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("alerts: not written", "fn", fn, "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	var res map[string]any
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("%s answered %q", fn, out))
		return
	}
	s.log.Info("alerts: attempt", "fn", fn, "user", user, "outcome", res["outcome"], "detail", res["detail"])
	code := http.StatusOK
	if res["outcome"] != "done" {
		code = http.StatusConflict
		res["error"] = res["detail"]
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(res)
}

// AlertTest is POST /api/alerts/test {channel}: a Send test request the sender's next pass answers.
func (s *Server) AlertTest(w http.ResponseWriter, r *http.Request) {
	s.alertDoor(w, r, "import_alert_test", func(_ context.Context, pay map[string]any) error {
		var in struct {
			Channel string `json:"channel"`
		}
		if err := doorBody(r, &in); err != nil {
			return err
		}
		if strings.TrimSpace(in.Channel) == "" {
			return errors.New("channel is required")
		}
		pay["channel"] = in.Channel
		return nil
	})
}

// AlertDismiss is POST /api/alerts/dismiss {op: add, finding_key, reason} or {op: end, dismiss_id}.
func (s *Server) AlertDismiss(w http.ResponseWriter, r *http.Request) {
	s.alertDoor(w, r, "import_alert_dismiss", func(_ context.Context, pay map[string]any) error {
		var in struct {
			Op         string `json:"op"`
			FindingKey string `json:"finding_key"`
			Reason     string `json:"reason"`
			DismissID  int64  `json:"dismiss_id"`
		}
		if err := doorBody(r, &in); err != nil {
			return err
		}
		switch in.Op {
		case "add":
			if !findingKeyRE.MatchString(in.FindingKey) {
				return errors.New("finding_key must be an alert's key (32 hexadecimal digits)")
			}
			pay["finding_key"], pay["reason"] = in.FindingKey, in.Reason
		case "end":
			if in.DismissID <= 0 {
				return errors.New("dismiss_id must be a positive id")
			}
			pay["dismiss_id"] = in.DismissID
		default:
			return errors.New("op must be add or end")
		}
		pay["op"] = in.Op
		return nil
	})
}

// AlertMute is POST /api/alerts/mute {op: edit|pause|resume, ack_id} (edit: with the rule's fields, as POST /api/ack
// takes them: instance_id, check_key, tag, match_text, note, starts_at, until, and any_instance).
func (s *Server) AlertMute(w http.ResponseWriter, r *http.Request) {
	s.alertDoor(w, r, "import_ack_change", func(ctx context.Context, pay map[string]any) error {
		var in struct {
			Op         string     `json:"op"`
			AckID      int64      `json:"ack_id"`
			InstanceID int        `json:"instance_id"`
			CheckKey   string     `json:"check_key"`
			Tag        string     `json:"tag"`
			MatchText  string     `json:"match_text"`
			Note       string     `json:"note"`
			StartsAt   *time.Time `json:"starts_at"`
			Until      *time.Time `json:"until"`
			// AnyInstance: the edited rule matches every instance; without it and without instance_id the old
			// rule's instance stays (an instance removed since is never widened to the fleet by an edit)
			AnyInstance bool `json:"any_instance"`
		}
		if err := doorBody(r, &in); err != nil {
			return err
		}
		if in.Op != "edit" && in.Op != "pause" && in.Op != "resume" {
			return errors.New("op must be edit, pause or resume")
		}
		if in.AckID <= 0 {
			return errors.New("ack_id must be a positive rule id")
		}
		pay["op"], pay["ack_id"] = in.Op, in.AckID
		if in.Op != "edit" {
			return nil
		}
		if in.AnyInstance && in.InstanceID > 0 {
			return errors.New("any_instance and instance_id name two scopes: send one")
		}
		if in.AnyInstance {
			pay["any_instance"] = true
		}
		if in.InstanceID > 0 {
			var name string
			if err := s.pool.QueryRow(ctx, `SELECT name FROM pgvigil.instances WHERE instance_id = $1`, in.InstanceID).Scan(&name); err != nil {
				return fmt.Errorf("no instance %d", in.InstanceID)
			}
			pay["instance_id"], pay["instance_name"] = in.InstanceID, name
		}
		for k, v := range map[string]string{"check_key": in.CheckKey, "tag": in.Tag, "match_text": in.MatchText, "note": in.Note} {
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
		return nil
	})
}
