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
)

func (s *webhookSender) budget() int {
	switch s.format {
	case "discord":
		return discordLimit - maxLine - 8
	case "googlechat":
		return googleChatLimit - maxLine - 8
	}
	return 0
}

func (s *webhookSender) send(ctx context.Context, m Message) error {
	body, err := s.payload(m)
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
		return fmt.Errorf("%s answered %s", hostOf(s.u), resp.Status)
	}
	return nil
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
			tb := map[string]any{"type": "TextBlock", "text": a.Line(), "wrap": true}
			switch {
			case a.Event == "resolved":
				tb["color"] = "Good"
			case a.Severity == "critical":
				tb["color"] = "Attention"
			case a.Severity == "warning":
				tb["color"] = "Warning"
			}
			body = append(body, tb)
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
