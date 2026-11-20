package alerts

// Pushover (task B24k, SQLWATCH's action 'Push notification via Pushover'): a channel's pushover: block posts each
// alert as one message to Pushover's Messages API (POST /1/messages.json, form-encoded token, user, message, title,
// url, priority). The application's token and the user (or group) key come through env: or file: only and are never
// logged or shown; the UI shows the host. The answers, as Pushover's API page states them:
//   - 200 with status 1: sent. A 200 whose status is not 1 is a failed send (assumed: the page states 1 for success
//     and does not name another status under a 200);
//   - 429: the application's messages for the month are used up. The channel is held - nothing is posted - until the
//     reset time Pushover names (X-Limit-App-Reset), said on the Alerts page as the last attempt's error;
//   - another 4xx: the request is wrong (the token or user key invalid, a device unknown) and posting it again changes
//     nothing. The channel is held until its configuration changes (a hash of its settings) or a Send test goes through;
//   - a 5xx or no answer: a failed send, tried again by a later pass (the loop's back-off: at least a minute, past the
//     5 seconds Pushover asks for).
// Every 200 carries the month's quota (X-Limit-App-Limit, -Remaining, -Reset): the pass records it, and under 10 % left
// the repository raises 'pushover quota low' (0154's alert_channel_quota_low).
//
//	pushover: {token: env:PGVIGIL_PO_TOKEN, user: env:PGVIGIL_PO_USER}            # device: one device's name (optional)
//
// Priority follows the alert: critical 1 (high: shown and sounded in quiet hours), warning 0, info -1 (quiet); a
// recovery and a test -1. Priority 2 (emergency: repeated until acknowledged) is not offered: pgvigil's own repeat does that.

import (
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
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Pushover is a channel's pushover: block.
type Pushover struct {
	Token  string `yaml:"token"`  // the application's API token: env: or file:
	User   string `yaml:"user"`   // the user or group key: env: or file:
	Device string `yaml:"device"` // optional: send to these devices only (names, comma-separated)
	URL    string `yaml:"url"`    // default https://api.pushover.net; plain http only to a loopback listener (a test)
}

// pushoverURL is the Messages API's host.
const pushoverURL = "https://api.pushover.net"

// The Messages API's limits (pushover.net/api): message 1,024 characters, title 250, url 512, url_title 100.
const (
	poMaxMessage  = 1024
	poMaxTitle    = 250
	poMaxURL      = 512
	poMaxURLTitle = 100
)

var (
	poKeyRE    = regexp.MustCompile(`^[A-Za-z0-9]{1,64}$`)
	poDeviceRE = regexp.MustCompile(`^[A-Za-z0-9_-]{1,25}(,[A-Za-z0-9_-]{1,25})*$`)
	// the holds a Pushover channel's last attempt can carry, at the head of its error text (written by this sender only)
	poHeldUntilRE  = regexp.MustCompile(`^held until (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ): `)
	poHeldConfigRE = regexp.MustCompile(`^held until the configuration changes \(([0-9a-f]{12})\): `)
)

type pushoverSender struct {
	base        *url.URL
	token, user string
	device      string
	cfg         string // the settings' hash: a 4xx hold ends when it changes
	client      *http.Client
	quota       *channelQuota // the newest answer's quota, read by the pass after a send
}

// channelQuota is a destination's monthly quota as its last answer gave it.
type channelQuota struct {
	Remaining, Limit int
	Reset            time.Time
}

func (p *Pushover) build() (sender, error) {
	tok, err := secret("pushover.token", p.Token)
	if err != nil {
		return nil, err
	}
	usr, err := secret("pushover.user", p.User)
	if err != nil {
		return nil, err
	}
	tok, usr = strings.TrimSpace(tok), strings.TrimSpace(usr)
	if !poKeyRE.MatchString(tok) {
		return nil, errors.New("pushover.token is not an application token (letters and digits)")
	}
	if !poKeyRE.MatchString(usr) {
		return nil, errors.New("pushover.user is not a user or group key (letters and digits)")
	}
	dev := strings.TrimSpace(p.Device)
	if dev != "" && !poDeviceRE.MatchString(dev) {
		return nil, fmt.Errorf("pushover.device %q: device names of letters, digits, '_' and '-' (up to 25 each), comma-separated", dev)
	}
	raw := strings.TrimSpace(p.URL)
	if raw == "" {
		raw = pushoverURL
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return nil, errors.New("pushover.url is not an absolute URL")
	}
	switch {
	case u.Scheme == "https" && u.Hostname() == "api.pushover.net":
	case u.Scheme == "http" && loopback(u.Hostname()):
	default:
		return nil, fmt.Errorf("pushover.url must be https://api.pushover.net (got %s)", hostOf(u))
	}
	if u.User != nil || u.RawQuery != "" || strings.Trim(u.Path, "/") != "" {
		return nil, errors.New("pushover.url is the API's host only: no user:password, path or query")
	}
	u.Path = ""
	sum := sha256.Sum256([]byte(strings.Join([]string{tok, usr, dev, u.String()}, "\x00")))
	tr := &http.Transport{
		Proxy:               nil, // the configured destination only: no proxy from the environment
		DialContext:         (&net.Dialer{Timeout: 15 * time.Second}).DialContext,
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 15 * time.Second,
		ForceAttemptHTTP2:   true,
		MaxConnsPerHost:     2, // Pushover asks for 2 at most
	}
	return &pushoverSender{base: u, token: tok, user: usr, device: dev, cfg: hex.EncodeToString(sum[:])[:12], client: &http.Client{
		Transport:     tr,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func (s *pushoverSender) destination() string { return hostOf(s.base) + " (pushover)" }

// perAlert: one message is one alert (a phone notification per alert, each with its own priority and link).
func (s *pushoverSender) perAlert() bool { return true }

// held says whether the channel's newest attempt (its error text) holds its sends at now, and why.
func (s *pushoverSender) held(lastErr string, now time.Time) (bool, string) {
	if m := poHeldUntilRE.FindStringSubmatch(lastErr); m != nil {
		if t, err := time.Parse(time.RFC3339, m[1]); err == nil && now.Before(t) {
			return true, "the month's Pushover messages are used up: held until " + m[1]
		}
		return false, ""
	}
	if m := poHeldConfigRE.FindStringSubmatch(lastErr); m != nil && m[1] == s.cfg {
		return true, "Pushover refused the request: held until the channel's configuration changes or a Send test goes through"
	}
	return false, ""
}

// lastQuota hands the pass the newest answer's quota once (nil: none since the last call).
func (s *pushoverSender) lastQuota() *channelQuota {
	q := s.quota
	s.quota = nil
	return q
}

func poPriority(a Alert) int {
	switch {
	case a.Event == "resolved" || a.Event == "cleared" || a.Event == "test":
		return -1
	case a.Severity == "critical":
		return 1
	case a.Severity == "warning":
		return 0
	}
	return -1
}

func (s *pushoverSender) form(m Message, a Alert) url.Values {
	title := m.Subject
	if title == "" {
		title = Message{Alerts: []Alert{a}}.Summary()
	}
	f := url.Values{
		"token":     {s.token},
		"user":      {s.user},
		"title":     {cutRunes(title, poMaxTitle)},
		"message":   {cutRunes(a.Line(), poMaxMessage)},
		"priority":  {strconv.Itoa(poPriority(a))},
		"timestamp": {strconv.FormatInt(m.SentAt.Unix(), 10)},
	}
	if s.device != "" {
		f.Set("device", s.device)
	}
	if a.URL != "" && utf8.RuneCountInString(a.URL) <= poMaxURL {
		f.Set("url", a.URL)
		f.Set("url_title", cutRunes("Open the alert in pgvigil", poMaxURLTitle))
	}
	return f
}

// poDigestCut ends a digest's text that did not fit a notification.
const poDigestCut = "\n... (cut: the Alerts page lists every held alert)"

// digestForm is a daily digest as ONE notification (a push per group would sound once per group and spend the
// month's messages): the digest's subject as the title, its group lines as the message (cut at a line
// within 1,024 characters, the cut said), priority 0 (a digest is never urgent: what was urgent was not held).
func (s *pushoverSender) digestForm(m Message) url.Values {
	lines := make([]string, len(m.Alerts))
	for i, a := range m.Alerts {
		lines[i] = a.Line()
	}
	text := strings.Join(lines, "\n")
	if utf8.RuneCountInString(text) > poMaxMessage {
		r := []rune(text)[:poMaxMessage-utf8.RuneCountInString(poDigestCut)]
		text = string(r)
		if i := strings.LastIndexByte(text, '\n'); i > 0 {
			text = text[:i]
		}
		text += poDigestCut
	}
	title := m.Subject
	if title == "" {
		title = m.Summary()
	}
	f := url.Values{
		"token":     {s.token},
		"user":      {s.user},
		"title":     {cutRunes(title, poMaxTitle)},
		"message":   {text},
		"priority":  {"0"},
		"timestamp": {strconv.FormatInt(m.SentAt.Unix(), 10)},
	}
	if s.device != "" {
		f.Set("device", s.device)
	}
	return f
}

// isDigest: a daily digest's message (digest.go: every item's event is 'digest').
func isDigest(m Message) bool {
	for _, a := range m.Alerts {
		if a.Event != "digest" {
			return false
		}
	}
	return len(m.Alerts) > 0
}

func (s *pushoverSender) send(ctx context.Context, m Message) error {
	if isDigest(m) {
		return s.post(ctx, s.digestForm(m))
	}
	for _, a := range m.Alerts {
		if err := s.post(ctx, s.form(m, a)); err != nil {
			return err
		}
	}
	return nil
}

func (s *pushoverSender) post(ctx context.Context, f url.Values) error {
	body := f.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.base.String()+"/1/messages.json", strings.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", "pgvigil-alerts")
	resp, err := s.client.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			return fmt.Errorf("post %s: %w", hostOf(s.base), ue.Err)
		}
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	var ans struct {
		Status int      `json:"status"`
		Errors []string `json:"errors"`
	}
	_ = json.Unmarshal(raw, &ans)
	words := s.scrub(strings.Join(ans.Errors, "; "))
	if words == "" {
		words = "no error text"
	}
	switch {
	case resp.StatusCode == http.StatusOK && ans.Status == 1:
		s.quota = poQuota(resp.Header)
		return nil
	case resp.StatusCode == http.StatusOK:
		return fmt.Errorf("%s answered 200 with status %d (not 1): %s", hostOf(s.base), ans.Status, words)
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return refused("%s answered %d with a redirect: not followed (the send goes to the configured URL only)", hostOf(s.base), resp.StatusCode)
	case resp.StatusCode == http.StatusTooManyRequests:
		reset := time.Now().Add(time.Hour) // no readable reset: an hour, then the next answer says
		if n, err := strconv.ParseInt(strings.TrimSpace(resp.Header.Get("X-Limit-App-Reset")), 10, 64); err == nil && n > 0 {
			reset = time.Unix(n, 0)
		}
		return fmt.Errorf("held until %s: %s answered 429: the application's messages for the month are used up (%s)",
			reset.UTC().Format(time.RFC3339), hostOf(s.base), words)
	case resp.StatusCode >= 400 && resp.StatusCode < 500:
		return fmt.Errorf("held until the configuration changes (%s): %s answered %s: %s", s.cfg, hostOf(s.base), resp.Status, words)
	}
	return fmt.Errorf("%s answered %s: %s", hostOf(s.base), resp.Status, words)
}

// scrub takes the token and the user key out of a text Pushover sent back.
func (s *pushoverSender) scrub(t string) string {
	for _, k := range []string{s.token, s.user} {
		if k != "" {
			t = strings.ReplaceAll(t, k, "[key]")
		}
	}
	return capLine(t)
}

// poQuota reads the month's quota from a 200's headers; nil when they are absent or unreadable.
func poQuota(h http.Header) *channelQuota {
	limit, err1 := strconv.Atoi(strings.TrimSpace(h.Get("X-Limit-App-Limit")))
	left, err2 := strconv.Atoi(strings.TrimSpace(h.Get("X-Limit-App-Remaining")))
	reset, err3 := strconv.ParseInt(strings.TrimSpace(h.Get("X-Limit-App-Reset")), 10, 64)
	if err1 != nil || err2 != nil || err3 != nil || limit <= 0 || left < 0 {
		return nil
	}
	return &channelQuota{Remaining: left, Limit: limit, Reset: time.Unix(reset, 0).UTC()}
}
