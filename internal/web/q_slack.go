package web

// The Slack door's handler (task 403b K5, row A38): POST /api/slack/actions, outside the UI login (the request's
// signature is its authentication: internal/alerts/slackdoor.go verifies it before anything is parsed). While the door
// is off (doors.slack_actions in pgvigil.yaml, the default) it answers 404 as an unknown path does. A verified click
// is answered 200 at once (Slack wants an answer within 3 s); the checks and the write follow on a bounded worker and
// the outcome goes back through the click's response_url: a refusal to the clicker alone (ephemeral), a write as a
// message in the channel. A click writes through the actions door's audit login as the pgvigil user the app maps the
// Slack user to, with client 'slack:<workspace>/<user>' and the Slack identity in the attempt's payload:
//   - every refusal of the UI's own acknowledgements first (ackOff: a demo serve, -no-login, no actions door, the
//     audit login off), then the mapped user: unmapped, disabled or gone = refused;
//   - the post's own occurrence (alert_threads by the post's ts, then alert_state): a click on an old post never
//     acknowledges or mutes the occurrence open now;
//   - Acknowledge = an alert_ack of that finding key (its repeats stop on every channel) unless one already covers the
//     occurrence; Mute 1 h = a mute of that finding key until now + 1 h unless a live one ends at or after now + 55 min.
// Slack's interaction page (docs.slack.dev/interactivity/handling-user-interaction, read 2026-11-15): a response_url
// takes "up to 5 times within 30 minutes of receiving the payload"; a reply is ephemeral unless response_type is
// in_channel; "A message's type cannot be changed from ephemeral to in_channel", so every answer here is a new
// message (replace_original false). Role: after B24f, operator or above, checked against the store at the click (no
// roles exist yet).

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/aachaemenes/pgvigil/internal/alerts"
)

var slackDoor atomic.Pointer[alerts.SlackDoor]

// SetSlackDoor turns the Slack door on (serve, when pgvigil.yaml turns it on) or off (nil).
func SetSlackDoor(d *alerts.SlackDoor) { slackDoor.Store(d) }

// at most 4 clicks are worked at once; a click past them is told to try again (a reply worker of its own, 8 at most)
var (
	slackWrites  = make(chan struct{}, 4)
	slackReplies = make(chan struct{}, 8)
)

var slackHTTP = &http.Client{
	Timeout: 10 * time.Second,
	Transport: &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}, TLSHandshakeTimeout: 10 * time.Second},
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

func (s *Server) slackActions(w http.ResponseWriter, r *http.Request) {
	d := slackDoor.Load()
	if d == nil {
		http.NotFound(w, r)
		return
	}
	now := time.Now()
	if !d.Allow(now) {
		w.Header().Set("Retry-After", "1")
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, alerts.SlackBodyMax+1))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	c, err := d.Verify(r.Header, raw, now)
	if err != nil {
		var ref *alerts.SlackRefusal
		status := http.StatusBadRequest
		if errors.As(err, &ref) {
			status = ref.Status
		}
		s.log.Warn("slack door: a request refused", "status", status, "why", err.Error())
		switch status {
		case http.StatusUnauthorized:
			http.Error(w, "unauthorized", http.StatusUnauthorized)
		case http.StatusConflict:
			w.WriteHeader(http.StatusOK) // a replay: taken once already, nothing written twice
		default:
			http.Error(w, "bad request", http.StatusBadRequest)
		}
		return
	}
	w.WriteHeader(http.StatusOK)
	if c.Action == "pgv_open" {
		return
	}
	select {
	case slackWrites <- struct{}{}:
		go func() {
			defer func() { <-slackWrites }()
			s.slackClick(d, c)
		}()
	default:
		select {
		case slackReplies <- struct{}{}:
			go func() {
				defer func() { <-slackReplies }()
				s.slackSay(c, "pgvigil is busy with other clicks: nothing was written. Click again in a moment.", true)
			}()
		default:
			s.log.Warn("slack door: a click dropped (every worker busy)", "team", c.TeamID, "slack_user", c.SlackUser)
		}
	}
}

// slackSay answers a click through its response_url (ephemeral: the clicker alone); neither the URL nor the payload
// is logged.
func (s *Server) slackSay(c *alerts.SlackClick, text string, ephemeral bool) {
	kind := "in_channel"
	if ephemeral {
		kind = "ephemeral"
	}
	b, _ := json.Marshal(map[string]any{"response_type": kind, "replace_original": false, "text": text})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.ResponseURL, bytes.NewReader(b))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	resp, err := slackHTTP.Do(req)
	if err != nil {
		var ue interface{ Unwrap() error }
		if errors.As(err, &ue) {
			err = ue.Unwrap()
		}
		s.log.Warn("slack door: the reply did not go", "team", c.TeamID, "slack_user", c.SlackUser, "err", err)
		return
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		s.log.Warn("slack door: the reply was refused", "team", c.TeamID, "slack_user", c.SlackUser, "status", resp.StatusCode)
	}
}

func (s *Server) slackClick(d *alerts.SlackDoor, c *alerts.SlackClick) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	refuse := func(text string) { s.slackSay(c, text+" Nothing was written.", true) }
	if !d.AllowUser(c, time.Now()) {
		refuse("Too many clicks from you this minute.")
		return
	}
	if why := s.ackOff(); why != "" {
		refuse("pgvigil takes no acknowledgement here: " + why + ".")
		return
	}
	if c.User == "" {
		refuse("Your Slack id is not mapped to a pgvigil user (an admin adds it under slack_apps users in pgvigil.yaml).")
		return
	}
	if hash, err := s.auth.lookup(ctx, c.User); err != nil || hash == "" {
		refuse("The pgvigil user mapped to you is disabled or gone.")
		return
	}
	// the clicked post is the occurrence's post, or one of its earlier ones (a reply Slack refused opened a new post:
	// the first post's buttons still act while the occurrence stands)
	var first time.Time
	if err := s.pool.QueryRow(ctx, `SELECT first_sent_at FROM pgvigil.alert_threads
	     WHERE channel = $1 AND finding_key = $2 AND slack_channel = $3 AND ($4 = ts OR $4 = ANY (older_ts))`,
		c.Channel, c.FindingKey, c.SlackChannel, c.MessageTS).Scan(&first); err != nil {
		refuse("pgvigil does not know this post's alert (or its record is gone): open it in pgvigil.")
		return
	}
	var cleared *time.Time
	if err := s.pool.QueryRow(ctx, `SELECT cleared_at FROM pgvigil.alert_state
	     WHERE channel = $1 AND finding_key = $2 AND first_sent_at = $3`, c.Channel, c.FindingKey, first).Scan(&cleared); err != nil {
		refuse("pgvigil does not know this post's alert (or its record is gone): open it in pgvigil.")
		return
	}
	if cleared != nil {
		refuse(fmt.Sprintf("This alert cleared at %s UTC; if it fired again, the open one is in a newer post.", cleared.UTC().Format("2006-01-02 15:04")))
		return
	}
	pay := map[string]any{"op": "add", "ui_user": c.User, "client": "slack:" + c.TeamID + "/" + c.SlackUser, "finding_key": c.FindingKey,
		"slack_user": c.SlackUser, "team": c.TeamID, "action_ts": c.ActionTS, "slack_app": c.AppID}
	var done string
	switch c.Action {
	case "pgv_ack":
		var by string
		var at time.Time
		err := s.pool.QueryRow(ctx, `SELECT a.created_by, a.created_at FROM pgvigil.acks a
		     WHERE a.kind = 'alert_ack' AND a.finding_key = $1 AND a.created_at >= $2 AND a.ended_at IS NULL
		       AND pgvigil.ack_alert_acked(now(), $1, $2) ORDER BY a.created_at LIMIT 1`, c.FindingKey, first).Scan(&by, &at)
		if err == nil {
			refuse(fmt.Sprintf("Already acknowledged by %s at %s UTC.", by, at.UTC().Format("2006-01-02 15:04")))
			return
		}
		pay["kind"] = "alert_ack"
		done = "Acknowledged in pgvigil by " + c.User + ": its repeats stop on every channel while this occurrence stands."
	case "pgv_mute1h":
		var by string
		var until time.Time
		err := s.pool.QueryRow(ctx, `SELECT a.created_by, a.until FROM pgvigil.acks a
		     WHERE a.kind = 'mute' AND a.finding_key = $1 AND a.paused_at IS NULL
		       AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, now()) AND a.until >= now() + interval '55 minutes'
		     ORDER BY a.until DESC LIMIT 1`, c.FindingKey).Scan(&by, &until)
		if err == nil {
			refuse(fmt.Sprintf("Already muted until %s UTC by %s.", until.UTC().Format("2006-01-02 15:04"), by))
			return
		}
		u := time.Now().Add(time.Hour).UTC()
		pay["kind"], pay["until"] = "mute", u.Format(time.RFC3339Nano)
		done = fmt.Sprintf("Muted for 1 h in pgvigil by %s (until %s UTC): held on every channel, its escalation included.", c.User, u.Format("15:04"))
	}
	b, _ := json.Marshal(pay)
	var out []byte
	if err := s.actions.audit.QueryRow(ctx, `SELECT pgvigil.import_ack($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("slack door: not written", "action", c.Action, "user", c.User, "err", err)
		refuse("The write failed in pgvigil's repository.")
		return
	}
	var res struct {
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
	}
	_ = json.Unmarshal(out, &res)
	s.log.Info("slack door: a click", "action", c.Action, "user", c.User, "team", c.TeamID, "slack_user", c.SlackUser, "outcome", res.Outcome, "detail", res.Detail)
	if res.Outcome == "refused" {
		refuse("pgvigil refused it: " + res.Detail + ".")
		return
	}
	s.slackSay(c, done, false)
}
