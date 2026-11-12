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
	"regexp"
	"strings"
	"time"
)

// Opsgenie is a channel's opsgenie: block: Opsgenie's Alert API v2. Each alert is its own request under one alias per
// instance and finding - firing and repeat create (Opsgenie folds a create with an open alias into its alert and counts
// it), escalated creates and then raises the priority, resolved and cleared close by alias - so Opsgenie keeps one alert
// per finding and closes it when the finding clears, also when it is cleared without a fix (as PagerDuty's). The API key
// (an API integration's key) comes through env: or file: only and is never logged or shown; the UI shows the host.
//
//	opsgenie: {api_key: env:PGVIGIL_OG_KEY}                                # url defaults to https://api.opsgenie.com
//	opsgenie: {api_key: file:/etc/pgvigil/og.key, url: https://api.eu.opsgenie.com}
type Opsgenie struct {
	APIKey string `yaml:"api_key"`
	URL    string `yaml:"url"`
}

// opsgenieURL is the Alert API's address in Opsgenie's US region.
const opsgenieURL = "https://api.opsgenie.com"

// opsgenieHosts are the hosts a channel may name (US and EU); plain http goes to a loopback listener only (a test).
var opsgenieHosts = map[string]bool{"api.opsgenie.com": true, "api.eu.opsgenie.com": true}

// The Alert API's limits: message 130 characters, alias 512, description 15000.
const (
	ogMaxMessage = 130
	ogMaxAlias   = 512
	ogMaxDesc    = 15000
)

var ogKeyRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

type opsgenieSender struct {
	base   *url.URL
	key    string
	client *http.Client
}

func (o *Opsgenie) build() (sender, error) {
	key, err := secret("opsgenie.api_key", o.APIKey)
	if err != nil {
		return nil, err
	}
	key = strings.TrimSpace(key)
	if !ogKeyRE.MatchString(key) {
		return nil, errors.New("opsgenie.api_key is not an API integration key (a UUID: 8-4-4-4-12 hexadecimal digits)")
	}
	raw := strings.TrimSpace(o.URL)
	if raw == "" {
		raw = opsgenieURL
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return nil, errors.New("opsgenie.url is not an absolute URL")
	}
	switch {
	case u.Scheme == "https" && opsgenieHosts[u.Hostname()]:
	case u.Scheme == "http" && loopback(u.Hostname()):
	default:
		return nil, fmt.Errorf("opsgenie.url must be https on api.opsgenie.com or api.eu.opsgenie.com (got %s)", hostOf(u))
	}
	if u.User != nil || u.RawQuery != "" {
		return nil, errors.New("opsgenie.url must not carry a user:password or a query")
	}
	u.Path = strings.TrimRight(u.Path, "/")
	tr := &http.Transport{
		Proxy:               nil, // the configured destination only: no proxy from the environment
		DialContext:         (&net.Dialer{Timeout: 15 * time.Second}).DialContext,
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 15 * time.Second,
		ForceAttemptHTTP2:   true,
	}
	return &opsgenieSender{base: u, key: key, client: &http.Client{
		Transport:     tr,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func (s *opsgenieSender) destination() string { return hostOf(s.base) + " (opsgenie)" }

// perAlert: one request is one alert.
func (s *opsgenieSender) perAlert() bool { return true }

func (s *opsgenieSender) send(ctx context.Context, m Message) error {
	for _, a := range m.Alerts {
		var err error
		switch a.Event {
		case "resolved", "cleared":
			err = s.post(ctx, http.MethodPost, "/v2/alerts/"+url.PathEscape(ogAlias(a))+"/close", url.Values{"identifierType": {"alias"}},
				map[string]any{"source": "pgvigil", "user": "pgvigil", "note": ogNote(a)})
		default:
			var id string
			id, err = s.postID(ctx, http.MethodPost, "/v2/alerts", nil, opsgenieAlert(a, m.Subject))
			if err == nil && a.Event == "test" {
				// the API works a request after its 202: a close sent before the create is done finds no alert, and
				// the test alert would stay open; the request's status is read first (at most about 10 s)
				s.waitRequest(ctx, id)
			}
			if err == nil && a.Event == "escalated" {
				// a create with an open alias only counts again: the priority is raised by its own request
				err = s.post(ctx, http.MethodPut, "/v2/alerts/"+url.PathEscape(ogAlias(a))+"/priority", url.Values{"identifierType": {"alias"}},
					map[string]any{"priority": ogPriority(a.Severity)})
			}
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func (s *opsgenieSender) post(ctx context.Context, method, path string, q url.Values, body any) error {
	_, err := s.postID(ctx, method, path, q, body)
	return err
}

// waitRequest reads a request's status until Opsgenie has worked it (or about 10 s pass); "" = no id to read.
func (s *opsgenieSender) waitRequest(ctx context.Context, id string) {
	if id == "" {
		return
	}
	for i := 0; i < 10; i++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(s.base.String(), "/")+"/v2/alerts/requests/"+url.PathEscape(id), nil)
		if err != nil {
			return
		}
		req.Header.Set("Authorization", "GenieKey "+s.key)
		req.Header.Set("User-Agent", "pgvigil-alerts")
		resp, err := s.client.Do(req)
		if err != nil {
			return
		}
		var st struct {
			Data struct {
				IsSuccess bool   `json:"isSuccess"`
				Status    string `json:"status"`
			} `json:"data"`
		}
		_ = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&st)
		_ = resp.Body.Close()
		if resp.StatusCode == http.StatusOK && (st.Data.IsSuccess || st.Data.Status != "") {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}

// postID sends one request and returns the requestId of a 202 answer ("" when the answer carries none).
func (s *opsgenieSender) postID(ctx context.Context, method, path string, q url.Values, body any) (string, error) {
	b, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	// path is already escaped (the alias through url.PathEscape); the base carries no query (build refuses one)
	target := strings.TrimRight(s.base.String(), "/") + path
	if len(q) > 0 {
		target += "?" + q.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, target, bytes.NewReader(b))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "GenieKey "+s.key)
	req.Header.Set("User-Agent", "pgvigil-alerts")
	resp, err := s.client.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			return "", fmt.Errorf("post %s: %w", hostOf(s.base), ue.Err)
		}
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	rb, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	switch {
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return "", refused("%s answered %d with a redirect: not followed (the send goes to the configured URL only)", hostOf(s.base), resp.StatusCode)
	case resp.StatusCode == http.StatusTooManyRequests:
		return "", fmt.Errorf("%s answered 429: rate limited, the next pass sends again", hostOf(s.base))
	case resp.StatusCode >= 400:
		msg := strings.ReplaceAll(strings.TrimSpace(string(rb)), s.key, "<api key>")
		if len(msg) > 300 {
			msg = msg[:300] + " ..."
		}
		return "", fmt.Errorf("%s answered %s: %s", hostOf(s.base), resp.Status, msg)
	}
	var ok struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rb, &ok)
	return ok.RequestID, nil
}

// opsgenieAlert is the create request of one alert; subject is the channel's subject template filled ("" = the line).
func opsgenieAlert(a Alert, subject string) map[string]any {
	msg := subject
	if msg == "" {
		msg = fmt.Sprintf("%s: %s %s", a.Instance, a.Source, a.Setting)
		if a.Event == "test" {
			msg = "pgvigil test message"
		}
	}
	details := map[string]string{"event": a.Event, "finding": a.FindingKey, "setting": a.Setting, "value": a.Value}
	if a.Suggested != "" {
		details["suggested"] = a.Suggested
	}
	if a.URL != "" {
		details["url"] = a.URL
	}
	if a.FindingAt != nil {
		details["finding_at"] = a.FindingAt.UTC().Format(time.RFC3339)
	}
	desc := a.Line()
	if a.Detail != "" && !strings.Contains(desc, a.Detail) {
		desc += "\n\n" + a.Detail
	}
	entity := a.Instance
	if entity == "" {
		entity = "pgvigil"
	}
	return map[string]any{
		"message":     cutRunes(msg, ogMaxMessage),
		"alias":       ogAlias(a),
		"description": cutRunes(desc, ogMaxDesc),
		"priority":    ogPriority(a.Severity),
		"source":      "pgvigil",
		"entity":      cutRunes(entity, 512),
		"tags":        []string{"pgvigil", a.Severity},
		"details":     details,
	}
}

func ogNote(a Alert) string {
	if a.Event == "cleared" {
		return cutRunes("Closed by pgvigil: the finding was cleared without a fix (its instance retired, or the channel no longer covers it). "+a.Line(), 25000)
	}
	return cutRunes("Resolved in pgvigil: "+a.Line(), 25000)
}

// ogPriority maps a severity onto Opsgenie's P1 (critical) to P5 (info).
func ogPriority(sev string) string {
	switch sev {
	case "critical":
		return "P1"
	case "warning":
		return "P3"
	}
	return "P5"
}

// ogAlias ties every request of one finding on one instance to one Opsgenie alert: the readable form while it fits
// 512 bytes, else a hash of it.
func ogAlias(a Alert) string {
	k := "pgvigil:" + a.Instance + ":" + a.FindingKey
	if len(k) <= ogMaxAlias {
		return k
	}
	h := sha256.Sum256([]byte(k))
	return "pgvigil:" + hex.EncodeToString(h[:])
}

// cutRunes cuts s to at most n characters.
func cutRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}
