package web

import (
	"net/http"
)

// The Alerts tab at the root (task 60): GET /api/alerts?[from=&to=][&part=channels|open|log] (Server.Alerts) is the
// channels the alert sender last recorded (pgvigil.alert_channels, 0059: kind, the destination as shown, the severity
// floor, the instances and tags, quiet hours, repeat, recovery, whether the configuration still names it) with each
// one's last attempt and last successful send, the alerts open now (sent, not yet cleared), and every send attempt of
// the window (pgvigil.alert_log: the outcome and the error text). The Findings tab's sent / when / where column reads
// pgvigil.findings_alerts (the shell's query change). No Summary column: an alert is a finding sent, not a finding.

const sqlAlertChannels = `
SELECT c.name, c.kind, c.destination, c.min_severity, c.instances, c.tags, c.quiet_hours, c.timezone, c.repeat_secs,
       c.recovery, c.is_configured, c.configured_at, c.updated_at,
       l.snapshot_at AS last_attempt_at, l.outcome AS last_outcome, l.error AS last_error,
       (SELECT max(s.snapshot_at) FROM pgvigil.alert_log s WHERE s.channel = c.name AND s.outcome = 'sent') AS last_sent_at,
       (SELECT count(*) FROM pgvigil.alert_state o WHERE o.channel = c.name AND o.cleared_at IS NULL) AS open_alerts
  FROM pgvigil.alert_channels c
  LEFT JOIN LATERAL (SELECT a.snapshot_at, a.outcome, a.error FROM pgvigil.alert_log a
                      WHERE a.channel = c.name AND a.outcome <> 'cleared' ORDER BY a.snapshot_at DESC LIMIT 1) l ON true
 ORDER BY c.is_configured DESC, c.name`

const sqlAlertOpen = `
SELECT s.channel, s.instance_id, s.instance_name AS instance, s.severity, s.source, s.setting, s.value, s.first_sent_at,
       s.last_sent_at, s.send_count
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

// Alerts serves the Alerts tab: the channels, the open alerts and the window's send log.
func (s *Server) Alerts(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"channels", sqlAlertChannels, nil},
		{"open", sqlAlertOpen, nil},
		{"log", sqlAlertLog, []any{from, to}},
	})
}
