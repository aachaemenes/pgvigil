package alerts

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// Webhook is a channel's webhook: block. The URL carries its token, so it comes through env: or file: only, and the
// UI shows its scheme and host alone. https is required, plain http only to a loopback listener. A redirect is never
// followed: the send is refused (the destination is the configured one or none).
type Webhook struct {
	URL    string `yaml:"url"`
	Format string `yaml:"format"`  // teams | slack | discord | googlechat | json (default json)
	CAFile string `yaml:"ca_file"` // a PEM bundle of the CA that signed the endpoint's certificate (an internal CA)
}

type webhookSender struct {
	u      *url.URL
	format string
	client *http.Client
}

func (w *Webhook) build() (sender, error) {
	raw, err := secret("webhook.url", w.URL)
	if err != nil {
		return nil, err
	}
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Host == "" {
		return nil, errors.New("webhook.url is not an absolute URL")
	}
	switch u.Scheme {
	case "https":
	case "http":
		if !loopback(u.Hostname()) {
			return nil, fmt.Errorf("webhook.url must be https (plain http only to a loopback listener; got host %q)", u.Hostname())
		}
	default:
		return nil, fmt.Errorf("webhook.url scheme must be https (got %q)", u.Scheme)
	}
	if u.User != nil {
		return nil, errors.New("webhook.url must not carry a user:password")
	}
	f := w.Format
	if f == "" {
		f = "json"
	}
	if !webhookFormats[f] {
		return nil, fmt.Errorf("webhook.format must be teams, slack, discord, googlechat or json (got %q)", f)
	}
	tcfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if w.CAFile != "" {
		pem, err := os.ReadFile(w.CAFile)
		if err != nil {
			return nil, fmt.Errorf("webhook.ca_file: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("webhook.ca_file %s holds no PEM certificate", w.CAFile)
		}
		tcfg.RootCAs = pool
	}
	tr := &http.Transport{
		Proxy:               nil, // the configured destination only: no proxy from the environment
		DialContext:         (&net.Dialer{Timeout: 15 * time.Second}).DialContext,
		TLSClientConfig:     tcfg,
		TLSHandshakeTimeout: 15 * time.Second,
		ForceAttemptHTTP2:   true,
	}
	return &webhookSender{u: u, format: f, client: &http.Client{
		Transport:     tr,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func (s *webhookSender) destination() string { return hostOf(s.u) + " (" + s.format + ")" }

func (s *webhookSender) perAlert() bool { return false }

// webhookFormats are the bodies a webhook posts.
var webhookFormats = map[string]bool{"teams": true, "slack": true, "discord": true, "googlechat": true, "json": true}

// Text limits of the chat formats: Discord's content holds 2000 characters, a Google Chat message 4096; the budget
// leaves room for the headline (at most maxLine bytes) and the line breaks, and counts bytes (never fewer than
// characters), so a message never reaches the limit and no alert line is ever cut to fit.
const (
	discordLimit    = 2000
	googleChatLimit = 4096
	// teamsBlocks: the bytes of a Teams card's alert blocks as json.Marshal writes them (each line JSON-escaped, and
	// its 'Open in pgvigil' button with the address), so a card with its headline and envelope stays under 24 KB:
	// Microsoft's webhook page says a message over 28 KB is refused [unverified: whether it counts UTF-8 or UTF-16
	// bytes; the body is sent as UTF-8]
	teamsBlocks = 23000
)

func (s *webhookSender) budget() int {
	switch s.format {
	case "discord":
		return discordLimit - maxLine - 8
	case "googlechat":
		return googleChatLimit - maxLine - 8
	case "teams":
		return teamsBlocks
	}
	return 0
}

// lineCost is what one alert adds to a message: a Teams card's blocks as marshalled, a chat line otherwise.
func (s *webhookSender) lineCost(a Alert) int {
	if s.format != "teams" {
		return len(a.Line()) + 1
	}
	n := 0
	for _, b := range teamsAlertBlocks(a) {
		j, _ := json.Marshal(b)
		n += len(j) + 1
	}
	return n
}

// teamsAlertBlocks is one alert on a Teams card: its line, colored by its state, and for a firing alert with a page
// address an 'Open in pgvigil' button (task 403b, A38, the lead's D1 = a: it opens the alert's own page in pgvigil,
// where the UI login and its roles apply and the acknowledge is done; a Teams button that acts by itself would need
// a bot app registered in the tenant).
func teamsAlertBlocks(a Alert) []map[string]any {
	tb := map[string]any{"type": "TextBlock", "text": a.Line(), "wrap": true}
	switch {
	case a.Event == "resolved":
		tb["color"] = "Good"
	case a.Severity == "critical":
		tb["color"] = "Attention"
	case a.Severity == "warning":
		tb["color"] = "Warning"
	}
	out := []map[string]any{tb}
	if a.URL != "" && a.Event != "resolved" && a.Event != "test" {
		out = append(out, map[string]any{"type": "ActionSet", "actions": []map[string]any{
			{"type": "Action.OpenUrl", "title": "Open in pgvigil", "url": a.URL}}})
	}
	return out
}

func (s *webhookSender) send(ctx context.Context, m Message) error {
	body, err := s.payload(m)
	if err != nil {
		return err
	}
	resp, wait, err := postRetrying(ctx, s.client, func() (*http.Request, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.u.String(), bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("User-Agent", "pgvigil-alerts")
		return req, nil
	})
	if err != nil {
		// the error text holds the URL, and the URL holds the token: report the host only
		var ue *url.Error
		if errors.As(err, &ue) {
			return fmt.Errorf("post %s: %w", hostOf(s.u), ue.Err)
		}
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	switch {
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return refused("%s answered %d with a redirect: not followed (the send goes to the configured URL only)", hostOf(s.u), resp.StatusCode)
	case resp.StatusCode >= 400:
		return fmt.Errorf("%s answered %s%s", hostOf(s.u), resp.Status, wait.note(resp))
	}
	return nil
}

// ---- a 429's Retry-After (task 403b, PerformanceMonitor Fixed 28) --------------------------------------------------

// maxRetryAfter is the longest Retry-After one send waits out inside the pass (PerformanceMonitor's 10 s): a 429 that
// asks for more, or none, fails that send, and the loop's back-off holds that channel alone, as before.
const maxRetryAfter = 10 * time.Second

// retryWait waits d or until ctx ends; the tests replace it.
var retryWait = func(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// retryAfter reads a 429's Retry-After header (delay-seconds, or an HTTP date, RFC 9110 10.2.3) at now: the wait and
// true when it is readable and at most maxRetryAfter.
func retryAfter(h string, now time.Time) (time.Duration, bool) {
	h = strings.TrimSpace(h)
	if h == "" {
		return 0, false
	}
	var d time.Duration
	if n, err := strconv.Atoi(h); err == nil {
		if n < 0 {
			return 0, false
		}
		if int64(n) > int64(maxRetryAfter/time.Second) {
			// over the wait before the multiplication: a huge value would overflow time.Duration into a negative wait
			return time.Duration(min(int64(n), 1<<32)) * time.Second, false
		}
		d = time.Duration(n) * time.Second
	} else if t, err := http.ParseTime(h); err == nil {
		d = max(t.Sub(now), 0)
	} else {
		return 0, false
	}
	return d, d <= maxRetryAfter
}

// retried says what a send did about a 429, for the error text of a send that still failed.
type retried struct {
	waited time.Duration // > 0 or tried: the send waited this long and posted once more
	tried  bool
	asked  string // the first 429's Retry-After when it was not waited out ("" = none)
}

func (r retried) note(resp *http.Response) string {
	switch {
	case r.tried:
		return fmt.Sprintf(" (after waiting out a Retry-After of %s and posting once more)", r.waited)
	case resp.StatusCode == http.StatusTooManyRequests && r.asked != "":
		return fmt.Sprintf(" (Retry-After %q: more than the %s a send waits)", r.asked, maxRetryAfter)
	case resp.StatusCode == http.StatusTooManyRequests:
		return " (no Retry-After)"
	}
	return ""
}

// postRetrying sends the request build makes; a 429 whose Retry-After is at most maxRetryAfter is waited out (inside
// ctx: the send's own timeout) and the request built and sent once more. The answer of the second try stands. A
// redirect is never followed (the client's CheckRedirect).
func postRetrying(ctx context.Context, client *http.Client, build func() (*http.Request, error)) (*http.Response, retried, error) {
	var r retried
	req, err := build()
	if err != nil {
		return nil, r, err
	}
	resp, err := client.Do(req)
	if err != nil || resp.StatusCode != http.StatusTooManyRequests {
		return resp, r, err
	}
	h := resp.Header.Get("Retry-After")
	d, ok := retryAfter(h, time.Now())
	if !ok {
		r.asked = h
		return resp, r, nil
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	_ = resp.Body.Close()
	if err := retryWait(ctx, d); err != nil {
		return nil, r, fmt.Errorf("waiting out a Retry-After of %s: %w", d, err)
	}
	r.waited, r.tried = d, true
	if req, err = build(); err != nil {
		return nil, r, err
	}
	resp, err = client.Do(req)
	return resp, r, err
}

func (s *webhookSender) payload(m Message) ([]byte, error) {
	switch s.format {
	case "slack":
		var b strings.Builder
		b.WriteString("*" + m.Summary() + "*")
		for _, a := range m.Alerts {
			b.WriteString("\n" + a.Line())
		}
		return json.Marshal(map[string]any{"text": b.String()})
	case "discord":
		// an incoming webhook's content; allowed_mentions empty: a finding's text never pings @everyone or a role
		var b strings.Builder
		b.WriteString("**" + m.Summary() + "**")
		for _, a := range m.Alerts {
			b.WriteString("\n" + a.Line())
		}
		return json.Marshal(map[string]any{"content": b.String(), "username": "pgvigil",
			"allowed_mentions": map[string]any{"parse": []string{}}})
	case "googlechat":
		// a space's incoming webhook takes a text message (*bold* is Chat's own markup); a mention written as
		// <users/...> in a finding's text is broken, so it never notifies the space
		var b strings.Builder
		b.WriteString("*" + m.Summary() + "*")
		for _, a := range m.Alerts {
			b.WriteString("\n" + a.Line())
		}
		return json.Marshal(map[string]any{"text": strings.ReplaceAll(b.String(), "<users/", "< users/")})
	case "teams":
		// a Workflows (Power Automate) webhook takes an Adaptive Card in a message's attachments
		body := []map[string]any{{"type": "TextBlock", "text": m.Summary(), "weight": "Bolder", "size": "Medium", "wrap": true}}
		for _, a := range m.Alerts {
			body = append(body, teamsAlertBlocks(a)...)
		}
		return json.Marshal(map[string]any{"type": "message", "attachments": []map[string]any{{
			"contentType": "application/vnd.microsoft.card.adaptive",
			"content": map[string]any{"type": "AdaptiveCard", "version": "1.4",
				"$schema": "http://adaptivecards.io/schemas/adaptive-card.json", "body": body},
		}}})
	}
	return json.Marshal(struct {
		Source  string `json:"source"`
		Summary string `json:"summary"`
		Message
	}{"pgvigil", m.Summary(), m})
}
