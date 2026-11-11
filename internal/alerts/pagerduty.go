package alerts

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// PagerDuty is a channel's pagerduty: block: the PagerDuty Events API v2. Each alert is its own event - firing,
// escalated and repeat trigger, resolved resolves - under one dedup key per instance and finding, so PagerDuty opens
// one incident per finding, folds the repeats into it and closes it when the finding clears. The routing key (the
// service's integration key) comes through env: or file: only and is never logged or shown; the UI shows the host.
//
//	pagerduty: {routing_key: env:PGVIGIL_PD_KEY}                  # url defaults to https://events.pagerduty.com/v2/enqueue
//	pagerduty: {routing_key: file:/etc/pgvigil/pd.key, url: https://events.eu.pagerduty.com/v2/enqueue}
type PagerDuty struct {
	RoutingKey string `yaml:"routing_key"`
	URL        string `yaml:"url"`
}

// pagerDutyURL is the Events API v2 address of PagerDuty's US service region.
const pagerDutyURL = "https://events.pagerduty.com/v2/enqueue"

// pagerDutyHosts are the Events API v2 hosts a channel may name (US and EU service regions); plain http goes to a
// loopback listener only (a test).
var pagerDutyHosts = map[string]bool{"events.pagerduty.com": true, "events.eu.pagerduty.com": true}

// maxDedupKey is the Events API v2 limit on dedup_key (payload.summary's 1024 is above maxLine).
const maxDedupKey = 255

type pagerDutySender struct {
	u      *url.URL
	key    string
	client *http.Client
}

func (p *PagerDuty) build() (sender, error) {
	key, err := secret("pagerduty.routing_key", p.RoutingKey)
	if err != nil {
		return nil, err
	}
	key = strings.TrimSpace(key)
	if len(key) != 32 || strings.Trim(key, "0123456789abcdefABCDEF") != "" {
		return nil, errors.New("pagerduty.routing_key is not a 32-character integration key (Events API v2)")
	}
	raw := strings.TrimSpace(p.URL)
	if raw == "" {
		raw = pagerDutyURL
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return nil, errors.New("pagerduty.url is not an absolute URL")
	}
	switch {
	case u.Scheme == "https" && pagerDutyHosts[u.Hostname()]:
	case u.Scheme == "http" && loopback(u.Hostname()):
	default:
		return nil, fmt.Errorf("pagerduty.url must be https on events.pagerduty.com or events.eu.pagerduty.com (got %s)", hostOf(u))
	}
	if u.User != nil {
		return nil, errors.New("pagerduty.url must not carry a user:password")
	}
	tr := &http.Transport{
		Proxy:               nil, // the configured destination only: no proxy from the environment
		DialContext:         (&net.Dialer{Timeout: 15 * time.Second}).DialContext,
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 15 * time.Second,
		ForceAttemptHTTP2:   true,
	}
	return &pagerDutySender{u: u, key: key, client: &http.Client{
		Transport:     tr,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func (s *pagerDutySender) destination() string { return hostOf(s.u) + " (pagerduty)" }

// perAlert: an Events API v2 event carries one alert.
func (s *pagerDutySender) perAlert() bool { return true }

func (s *pagerDutySender) send(ctx context.Context, m Message) error {
	for _, a := range m.Alerts {
		if err := s.sendOne(ctx, a); err != nil {
			return err
		}
	}
	return nil
}

func (s *pagerDutySender) sendOne(ctx context.Context, a Alert) error {
	body, err := json.Marshal(pagerDutyEvent(s.key, a))
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.u.String(), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "pgvigil-alerts")
	resp, err := s.client.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			return fmt.Errorf("post %s: %w", hostOf(s.u), ue.Err)
		}
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	switch {
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return refused("%s answered %d with a redirect: not followed (the send goes to the configured URL only)", hostOf(s.u), resp.StatusCode)
	case resp.StatusCode == http.StatusTooManyRequests:
		return fmt.Errorf("%s answered 429: rate limited, the next pass sends again", hostOf(s.u))
	case resp.StatusCode >= 400:
		// PagerDuty's answer names the fault ("Event object is invalid" with errors); it never echoes the routing key,
		// but strip it anyway before the text reaches a log
		msg := strings.ReplaceAll(strings.TrimSpace(string(b)), s.key, "<routing key>")
		if len(msg) > 300 {
			msg = msg[:300] + " ..."
		}
		return fmt.Errorf("%s answered %s: %s", hostOf(s.u), resp.Status, msg)
	}
	return nil
}

// pagerDutyEvent is one Events API v2 event for one alert.
func pagerDutyEvent(key string, a Alert) map[string]any {
	ev := map[string]any{"routing_key": key, "dedup_key": dedupKey(a), "client": "pgvigil"}
	if a.Event == "resolved" || a.Event == "cleared" {
		ev["event_action"] = "resolve"
		return ev
	}
	ev["event_action"] = "trigger"
	summary := a.Line() // at most maxLine bytes, under the API's maxSummary
	source := a.Instance
	if source == "" {
		source = "pgvigil"
	}
	details := map[string]any{"event": a.Event, "finding": a.FindingKey, "setting": a.Setting, "value": a.Value}
	if a.Detail != "" {
		details["detail"] = a.Detail
	}
	if a.Suggested != "" {
		details["suggested"] = a.Suggested
	}
	if a.FindingAt != nil {
		details["finding_at"] = a.FindingAt.UTC().Format(time.RFC3339)
	}
	ev["payload"] = map[string]any{
		"summary":        summary,
		"source":         source,
		"severity":       pagerDutySeverity(a.Severity),
		"component":      a.Source,
		"class":          a.Setting,
		"custom_details": details,
	}
	return ev
}

// pagerDutySeverity maps a finding's severity onto the Events API's critical | error | warning | info.
func pagerDutySeverity(s string) string {
	switch s {
	case "critical", "warning", "info":
		return s
	}
	return "error"
}

// dedupKey ties every event of one finding on one instance to one PagerDuty incident: the readable form while it fits
// the API's 255 bytes, else a hash of it.
func dedupKey(a Alert) string {
	k := "pgvigil:" + a.Instance + ":" + a.FindingKey
	if len(k) <= maxDedupKey {
		return k
	}
	h := sha256.Sum256([]byte(k))
	return "pgvigil:" + hex.EncodeToString(h[:])
}
