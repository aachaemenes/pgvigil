package alerts

// The Slack bot channel (task 403b K2, row A34): kind slack posts through the Web API's chat.postMessage with a bot
// token, so every alert keeps a thread. A repeat, an escalation and the recovery are replies in the thread of the post
// that first carried the alert (an escalation broadcast to the channel too), and the pass sends the posts and the
// replies as separate sends, each with its own attempt (alerts.go sendThreaded). With the Slack door on (K5:
// doors.slack_actions and the channel's app_id in slack_apps:) a post's firing alerts carry Acknowledge and Mute 1 h;
// every alert with a page address carries an 'Open in pgvigil' link button.
// Slack's pages (docs.slack.dev, read 2026-11-14/15):
//   - POST <api>/chat.postMessage, a JSON body, the token "as a bearer token in the Authorization HTTP header"
//     (docs.slack.dev/apis/web-api, read 2026-11-15);
//   - the answer's ok and ts; ok false carries an error code from the page's table - only the code is kept;
//   - thread_ts makes a reply, reply_broadcast shows it to the channel; cannot_reply_to_message and
//     restricted_action_thread_locked / _non_threadable_channel refuse a reply (then the alert goes as a new post);
//     the page names no code for a deleted parent [unverified: such a reply is a failed send];
//   - text best under 4,000 characters; a section's text 3,000; one message a second per channel (the sender paces
//     its calls); a 429 carries Retry-After (K1's postRetrying);
//   - GovSlack: "use slack-gov.com when calling any API endpoint instead of slack.com" (docs.slack.dev/govslack).
// The token never reaches an error text, a log, the destination or alert_log. A finding's text is escaped (&, <, >)
// so it can never mention a person, a group or the channel: "&, <, and > ... must be converted to HTML entities if
// they're not going to be used for their parsing purpose"; nothing else is encoded (docs.slack.dev/messaging/
// formatting-message-text, read 2026-11-15).

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
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	slackAPI      = "https://slack.com/api"
	slackGovAPI   = "https://slack-gov.com/api"
	slackPerPost  = 20   // alerts in one post: a header, a section and an actions block each = 41 blocks
	slackReplies  = 20   // thread replies one pass sends; the rest stay owed for the next pass
	slackSection  = 3000 // characters of a section's text
	slackFallback = 3900 // characters of a post's text fallback (Slack: best under 4,000)
)

var (
	slackChannelRE = regexp.MustCompile(`^[CGD][A-Z0-9]{8,20}$`)
	slackAppRE     = regexp.MustCompile(`^A[A-Z0-9]{8,20}$`)
)

// SlackBot is a channel of kind slack.
type SlackBot struct {
	BotToken string `yaml:"bot_token"` // env:NAME or file:/path: a bot token (xoxb-...)
	Channel  string `yaml:"channel"`   // the Slack channel's id (C0123ABCD), never its name
	APIURL   string `yaml:"api_url"`   // default https://slack.com/api; https://slack-gov.com/api for GovSlack; plain http only to loopback (a test)
	AppID    string `yaml:"app_id"`    // K5: the Slack app (slack_apps:) whose Acknowledge / Mute buttons these posts carry
}

type slackSender struct {
	api     *url.URL
	token   string
	channel string
	appID   string
	buttons bool          // the door is on and app_id names a slack_apps entry (Parse sets it)
	gap     time.Duration // between two calls (one message a second per channel)
	client  *http.Client
	mu      sync.Mutex
	last    time.Time
}

func (b *SlackBot) build() (sender, error) {
	tok, err := secret("slack.bot_token", b.BotToken)
	if err != nil {
		return nil, err
	}
	tok = strings.TrimSpace(tok)
	if !strings.HasPrefix(tok, "xoxb-") || strings.ContainsAny(tok, " \t\r\n") {
		return nil, errors.New("slack.bot_token is not a bot token (xoxb-...)")
	}
	ch := strings.TrimSpace(b.Channel)
	if !slackChannelRE.MatchString(ch) {
		return nil, fmt.Errorf("slack.channel must be the channel's id (C0123ABCD: the channel's details, at the bottom), never its name (got %q)", ch)
	}
	app := strings.TrimSpace(b.AppID)
	if app != "" && !slackAppRE.MatchString(app) {
		return nil, fmt.Errorf("slack.app_id must be the Slack app's id (A0123ABCD) (got %q)", app)
	}
	raw := strings.TrimSuffix(strings.TrimSpace(b.APIURL), "/")
	if raw == "" {
		raw = slackAPI
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return nil, errors.New("slack.api_url is not an absolute URL")
	}
	switch {
	case u.Scheme == "https" && (raw == slackAPI || raw == slackGovAPI):
	case u.Scheme == "http" && loopback(u.Hostname()):
	default:
		return nil, fmt.Errorf("slack.api_url must be %s or %s (GovSlack) (got %s%s)", slackAPI, slackGovAPI, hostOf(u), u.Path)
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("slack.api_url is the API's root only: no user:password, query or fragment")
	}
	tr := &http.Transport{
		Proxy:               nil, // the configured destination only: no proxy from the environment
		DialContext:         (&net.Dialer{Timeout: 15 * time.Second}).DialContext,
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 15 * time.Second,
		ForceAttemptHTTP2:   true,
		MaxConnsPerHost:     2,
	}
	return &slackSender{api: u, token: tok, channel: ch, appID: app, gap: time.Second, client: &http.Client{
		Transport:     tr,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func (s *slackSender) destination() string {
	return hostOf(s.api) + " (slack bot, " + s.channel + ")"
}

func (s *slackSender) perAlert() bool { return false }

// send is a post with no thread kept (a Send test).
func (s *slackSender) send(ctx context.Context, m Message) error {
	_, err := s.post(ctx, m)
	return err
}

func (s *slackSender) slackChannel() string { return s.channel }

// post sends m as a top-level message; its ts is the thread of every alert it carries.
func (s *slackSender) post(ctx context.Context, m Message) (string, error) {
	return s.call(ctx, map[string]any{"channel": s.channel, "text": slackText(m), "blocks": s.blocks(m, true),
		"unfurl_links": false, "unfurl_media": false})
}

// reply sends m (one alert) in the thread threadTS; broadcast shows it in the channel too (an escalation).
func (s *slackSender) reply(ctx context.Context, m Message, threadTS string, broadcast bool) error {
	body := map[string]any{"channel": s.channel, "thread_ts": threadTS, "text": slackText(m), "blocks": s.blocks(m, false),
		"unfurl_links": false, "unfurl_media": false}
	if broadcast {
		body["reply_broadcast"] = true
	}
	_, err := s.call(ctx, body)
	return err
}

// slackError is Slack's own refusal (ok false): its error code only.
type slackError struct{ code string }

func (e *slackError) Error() string { return "slack answered " + e.code }

// threadRefused: Slack refused a reply as a reply (the alert then goes as a new post).
func threadRefused(err error) bool {
	var se *slackError
	if !errors.As(err, &se) {
		return false
	}
	switch se.code {
	case "cannot_reply_to_message", "restricted_action_thread_locked", "restricted_action_non_threadable_channel":
		return true
	}
	return false
}

var slackCodeRE = regexp.MustCompile(`^[a-z0-9_]{1,80}$`)

// pace waits until gap after the previous call.
func (s *slackSender) pace(ctx context.Context) error {
	s.mu.Lock()
	wait := time.Until(s.last.Add(s.gap))
	s.mu.Unlock()
	if wait > 0 {
		t := time.NewTimer(wait)
		defer t.Stop()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
		}
	}
	s.mu.Lock()
	s.last = time.Now()
	s.mu.Unlock()
	return nil
}

func (s *slackSender) call(ctx context.Context, body map[string]any) (string, error) {
	if err := s.pace(ctx); err != nil {
		return "", err
	}
	b, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	resp, r, err := postRetrying(ctx, s.client, func() (*http.Request, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.api.String()+"/chat.postMessage", bytes.NewReader(b))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/json; charset=utf-8")
		req.Header.Set("Authorization", "Bearer "+s.token)
		return req, nil
	})
	if err != nil {
		return "", fmt.Errorf("slack bot: %w", stripURLError(err))
	}
	defer func() { _ = resp.Body.Close() }()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	switch {
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return "", refused("slack bot: %s answered a redirect (HTTP %d): not followed", hostOf(s.api), resp.StatusCode)
	case resp.StatusCode == http.StatusTooManyRequests:
		return "", fmt.Errorf("slack bot: rate limited (HTTP 429)%s", r.note(resp))
	case resp.StatusCode != http.StatusOK:
		return "", fmt.Errorf("slack bot: HTTP %d%s", resp.StatusCode, r.note(resp))
	}
	var ans struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
		TS    string `json:"ts"`
	}
	if err := json.Unmarshal(raw, &ans); err != nil {
		return "", errors.New("slack bot: the answer is not Slack's JSON")
	}
	if !ans.OK {
		code := ans.Error
		if !slackCodeRE.MatchString(code) {
			code = "an unreadable error"
		}
		return "", &slackError{code: code}
	}
	if ans.TS == "" {
		return "", errors.New("slack bot: ok without a ts")
	}
	return ans.TS, nil
}

// stripURLError keeps a transport error's cause without its request line (the host and path are the destination's,
// never the token, which rides in a header; the cause alone is enough).
func stripURLError(err error) error {
	var ue *url.Error
	if errors.As(err, &ue) {
		return ue.Err
	}
	return err
}

// slackEscape writes text so Slack shows it as written: &, < and > as entities (no mention, link or channel ping).
func slackEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

// slackCut cuts escaped text at max characters on a rune boundary, never inside an entity.
func slackCut(s string, limit int) string {
	if utf8.RuneCountInString(s) <= limit {
		return s
	}
	n, cut := 0, len(s)
	for i := range s {
		if n == limit-4 {
			cut = i
			break
		}
		n++
	}
	s = s[:cut]
	if amp := strings.LastIndexByte(s, '&'); amp >= 0 && !strings.Contains(s[amp:], ";") {
		s = s[:amp]
	}
	return s + " ..."
}

// slackText is the post's text fallback (notifications, clients without blocks).
func slackText(m Message) string {
	var b strings.Builder
	b.WriteString(m.Summary())
	for _, a := range m.Alerts {
		b.WriteString("\n" + a.Line())
	}
	return slackCut(slackEscape(b.String()), slackFallback)
}

func slackPlain(s string) map[string]any { return map[string]any{"type": "plain_text", "text": s} }

func slackMrkdwn(s string) map[string]any { return map[string]any{"type": "mrkdwn", "text": s} }

// slackButtonValue is what a click hands back: the finding key and the pgvigil channel (K5; the occurrence is the
// clicked post's, read from alert_threads by its ts).
func slackButtonValue(a Alert, channel string) string { return a.FindingKey + "|" + channel }

// blocks: a header section, then each alert's section; on a post (top) each alert's actions - the link button when
// the alert has a page, Acknowledge and Mute 1 h on a firing or escalated alert when the door is on.
func (s *slackSender) blocks(m Message, top bool) []map[string]any {
	out := []map[string]any{{"type": "section", "text": slackMrkdwn("*" + slackCut(slackEscape(m.Summary()), 200) + "*")}}
	for _, a := range m.Alerts {
		out = append(out, map[string]any{"type": "section", "text": slackMrkdwn(slackCut(slackEscape(a.Line()), slackSection))})
		if !top {
			continue
		}
		var els []map[string]any
		if a.URL != "" && a.Event != "resolved" && a.Event != "test" {
			els = append(els, map[string]any{"type": "button", "action_id": "pgv_open", "text": slackPlain("Open in pgvigil"), "url": a.URL})
		}
		if s.buttons && (a.Event == "firing" || a.Event == "escalated") {
			v := slackButtonValue(a, m.Channel)
			els = append(els,
				map[string]any{"type": "button", "action_id": "pgv_ack", "style": "primary", "text": slackPlain("Acknowledge"), "value": v},
				map[string]any{"type": "button", "action_id": "pgv_mute1h", "text": slackPlain("Mute 1 h"), "value": v,
					"confirm": map[string]any{"title": slackPlain("Mute for one hour?"),
						"text":    slackPlain("This holds the alert on every pgvigil channel for one hour, its escalation included."),
						"confirm": slackPlain("Mute 1 h"), "deny": slackPlain("Cancel")}})
		}
		if len(els) > 0 {
			out = append(out, map[string]any{"type": "actions", "elements": els})
		}
	}
	return out
}
