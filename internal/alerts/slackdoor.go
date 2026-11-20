package alerts

// The Slack door (task 403b K5, row A38): Acknowledge and Mute 1 h on a Slack bot's posts. It is OFF unless
// pgvigil.yaml says `doors: {slack_actions: true}` (the one switch, task 330's list; default false: serve answers 404 on
// its path) AND names the app under `slack_apps:` - its id, its workspace, its signing secret (env: or file:) and the
// map of its Slack users to pgvigil users (an admin's own hand, in this one file). serve reads only these apps'
// secrets, never a channel's token; it answers through the click's response_url. This file is the door's pure part:
// the settings, the verification (Slack's 'verifying requests' page, read 2026-11-14: v0= hex HMAC-SHA256 of
// 'v0:' + X-Slack-Request-Timestamp + ':' + the raw body, 5 minutes), the click, and the limits. internal/web's
// q_alert_scope.go is the handler (the user and role checks, the occurrence, the write, the reply).
// Verification order: the raw body under SlackBodyMax, the form content type, an integer
// timestamp within 300 s, the signature compared in constant time with each app's secret - and only then the form and
// the payload are parsed. The payload's deprecated token field is ignored; neither the payload nor response_url is
// ever logged.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"mime"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"gopkg.in/yaml.v3"
)

// SlackBodyMax caps a click's body before the signature is checked: a block_actions payload carries the whole message
// (up to 41 blocks, form-encoded); proof part B measures the largest post the sender builds against it.
const SlackBodyMax = 256 << 10

// slackProofHooks lets a proof build answer a click through a loopback stand-in of Slack's hooks host
// (-ldflags "-X github.com/aachaemenes/pgvigil/internal/alerts.slackProofHooks=on"); never set in a release build.
var slackProofHooks = ""

// SlackPath is the door's path on serve.
const SlackPath = "/api/slack/actions"

var (
	slackTeamRE = regexp.MustCompile(`^T[A-Z0-9]{8,20}$`)
	slackEntRE  = regexp.MustCompile(`^E[A-Z0-9]{8,20}$`)
	slackUserRE = regexp.MustCompile(`^[UW][A-Z0-9]{8,20}$`)
	pgvUserRE   = regexp.MustCompile(`^[a-z0-9][a-z0-9._@-]{0,63}$`) // the store's ui_users.username check (0015)
)

// slackDoorSwitch is the door's switch as this package reads it (config.Doors carries the same key for task 330).
type slackDoorSwitch struct {
	SlackActions bool `yaml:"slack_actions"`
}

// SlackApp is one Slack app the door answers.
type SlackApp struct {
	AppID         string            `yaml:"app_id"`
	TeamID        string            `yaml:"team_id"`
	EnterpriseID  string            `yaml:"enterprise_id"`  // Enterprise Grid only
	SigningSecret string            `yaml:"signing_secret"` // env:NAME or file:/path; read by serve only
	Users         map[string]string `yaml:"users"`          // Slack user id (U0123ABCD) -> pgvigil user
}

func (a *SlackApp) check() error {
	if !slackAppRE.MatchString(a.AppID) {
		return fmt.Errorf("slack_apps: app_id must be the app's id (A0123ABCD) (got %q)", a.AppID)
	}
	if !slackTeamRE.MatchString(a.TeamID) {
		return fmt.Errorf("slack_apps %s: team_id must be the workspace's id (T0123ABCD) (got %q)", a.AppID, a.TeamID)
	}
	if a.EnterpriseID != "" && !slackEntRE.MatchString(a.EnterpriseID) {
		return fmt.Errorf("slack_apps %s: enterprise_id must be E0123ABCD (got %q)", a.AppID, a.EnterpriseID)
	}
	if !strings.HasPrefix(a.SigningSecret, "env:") && !strings.HasPrefix(a.SigningSecret, "file:") {
		return fmt.Errorf("slack_apps %s: signing_secret must be env:NAME or file:/path, never inline", a.AppID)
	}
	if len(a.Users) == 0 {
		return fmt.Errorf("slack_apps %s: users maps no Slack user to a pgvigil user: nobody could click", a.AppID)
	}
	for su, pu := range a.Users {
		if !slackUserRE.MatchString(su) {
			return fmt.Errorf("slack_apps %s: users: %q is not a Slack user id (U0123ABCD): map by id, never by name", a.AppID, su)
		}
		// a pgvigil user name as the UI login reads it (lowercased), so an acknowledgement is written under the
		// one spelling the store holds
		lc := strings.ToLower(strings.TrimSpace(pu))
		if !pgvUserRE.MatchString(lc) {
			return fmt.Errorf("slack_apps %s: users: %s maps to %q, not a pgvigil user name (a-z, 0-9 and . _ @ -, a letter or digit first)", a.AppID, su, pu)
		}
		a.Users[su] = lc
	}
	return nil
}

// checkSlackDoor checks the apps (one entry per app id) and gives the Slack bot channels whose app_id names one its
// buttons, while the door is on. A channel naming an app the door does not list carries the link button only.
func checkSlackDoor(s *Settings) error {
	seen := map[string]bool{}
	for i := range s.SlackApps {
		a := &s.SlackApps[i]
		if err := a.check(); err != nil {
			return err
		}
		if seen[a.AppID] {
			return fmt.Errorf("slack_apps: app %s is listed twice: one entry per app (its secret and its users belong to the app)", a.AppID)
		}
		seen[a.AppID] = true
	}
	for i := range s.Channels {
		if sb, ok := s.Channels[i].sender.(*slackSender); ok {
			sb.buttons = s.Doors.SlackActions && sb.appID != "" && seen[sb.appID]
		}
	}
	return nil
}

// SlackActionsOn says the switch is on and at least one app is listed.
func (s *Settings) SlackActionsOn() bool { return s.Doors.SlackActions && len(s.SlackApps) > 0 }

// SlackDoor is the door serve runs: the apps with their secrets read, the limits and the replay guard.
type SlackDoor struct {
	apps   []slackDoorApp
	global *bucket // every request, before its body is read
	mu     sync.Mutex
	users  map[string]*bucket   // per workspace and Slack user, after verification
	seen   map[string]time.Time // a taken signature: until when its timestamp is still inside the window
}

type slackDoorApp struct {
	SlackApp
	secret []byte
}

// LoadSlackDoor reads only the door's part of a configuration file - doors.slack_actions and slack_apps:, never the
// channels (their tokens are not on serve) - and returns the door with its apps' signing secrets read, or nil, nil
// while the switch is off. With the switch on, any fault (an app's entry, a secret, no app listed) is an error:
// serve refuses to start with it, rather than leave the door off while the collector posts the buttons.
func LoadSlackDoor(path string) (*SlackDoor, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("doors.slack_actions: %w", err)
	}
	return ParseSlackDoor(b)
}

// ParseSlackDoor is LoadSlackDoor on a configuration file's text.
func ParseSlackDoor(b []byte) (*SlackDoor, error) {
	var part struct {
		Doors     slackDoorSwitch `yaml:"doors"`
		SlackApps []SlackApp      `yaml:"slack_apps"`
	}
	if err := yaml.Unmarshal(b, &part); err != nil {
		return nil, fmt.Errorf("doors.slack_actions: the file: %w", err)
	}
	if !part.Doors.SlackActions {
		return nil, nil
	}
	if len(part.SlackApps) == 0 {
		return nil, errors.New("doors.slack_actions is on but slack_apps lists no app: list the app (its id, workspace, signing secret and users) or turn the door off")
	}
	s := Settings{Doors: part.Doors, SlackApps: part.SlackApps}
	if err := checkSlackDoor(&s); err != nil {
		return nil, fmt.Errorf("doors.slack_actions: %w", err)
	}
	return s.SlackDoor()
}

// SlackDoor reads the door's secrets (serve only; the collector never reads them). Off = nil, nil.
func (s *Settings) SlackDoor() (*SlackDoor, error) {
	if !s.SlackActionsOn() {
		return nil, nil
	}
	d := &SlackDoor{global: newBucket(20, 40), users: map[string]*bucket{}, seen: map[string]time.Time{}}
	for _, a := range s.SlackApps {
		v, err := secret("slack_apps "+a.AppID+": signing_secret", a.SigningSecret)
		if err != nil {
			return nil, err
		}
		d.apps = append(d.apps, slackDoorApp{SlackApp: a, secret: []byte(strings.TrimSpace(v))})
	}
	return d, nil
}

// AppIDs names the door's apps (serve's start line).
func (d *SlackDoor) AppIDs() []string {
	out := make([]string, 0, len(d.apps))
	for _, a := range d.apps {
		out = append(out, a.AppID)
	}
	return out
}

// SlackClick is one verified click.
type SlackClick struct {
	AppID, TeamID, SlackUser string
	User                     string // the pgvigil user the app maps the Slack user to; "" = not mapped
	Action                   string // pgv_ack | pgv_mute1h | pgv_open
	FindingKey, Channel      string // the button's value: the finding key and the pgvigil channel
	MessageTS, SlackChannel  string // the clicked post
	ActionTS                 string
	ResponseURL              string
}

// SlackRefusal is a click refused before anything is written: Status 401 (the signature or the time; a fixed body,
// no Slack call) or 400 (a verified request that is not a click this door takes).
type SlackRefusal struct {
	Status int
	Why    string // for the log only, never the payload
}

func (e *SlackRefusal) Error() string { return e.Why }

func unauthorized(why string) error { return &SlackRefusal{Status: http.StatusUnauthorized, Why: why} }
func malformed(why string) error    { return &SlackRefusal{Status: http.StatusBadRequest, Why: why} }

// Allow is the global limit, asked before the body is read (20 a second, bursts of 40; false = answer 429).
func (d *SlackDoor) Allow(now time.Time) bool { return d.global.take(now) }

// Verify checks one request and reads its click; raw is the whole body (the caller read at most SlackBodyMax + 1
// bytes and refused more). A replay of a signature seen while its timestamp is still taken is refused (409: nothing
// written twice): a signature is kept until its own timestamp is 300 s past, however far serve's clock is from Slack's.
func (d *SlackDoor) Verify(h http.Header, raw []byte, now time.Time) (*SlackClick, error) {
	if len(raw) > SlackBodyMax {
		return nil, malformed("the body is over the cap")
	}
	if mt, _, err := mime.ParseMediaType(h.Get("Content-Type")); err != nil || mt != "application/x-www-form-urlencoded" {
		return nil, unauthorized("not a form-encoded request")
	}
	tsRaw := h.Get("X-Slack-Request-Timestamp")
	ts, err := strconv.ParseInt(tsRaw, 10, 64)
	if err != nil || tsRaw != strconv.FormatInt(ts, 10) {
		return nil, unauthorized("no integer timestamp")
	}
	if d := now.Unix() - ts; d > 300 || d < -300 {
		return nil, unauthorized("the timestamp is over 5 minutes from now")
	}
	sig := h.Get("X-Slack-Signature")
	var app *slackDoorApp
	for i := range d.apps {
		m := hmac.New(sha256.New, d.apps[i].secret)
		m.Write([]byte("v0:" + tsRaw + ":"))
		m.Write(raw)
		want := "v0=" + hex.EncodeToString(m.Sum(nil))
		if hmac.Equal([]byte(want), []byte(sig)) && app == nil {
			app = &d.apps[i]
		}
	}
	if app == nil {
		return nil, unauthorized("no app's signature matches")
	}
	d.mu.Lock()
	for k, until := range d.seen {
		if now.After(until) {
			delete(d.seen, k)
		}
	}
	_, replay := d.seen[sig]
	d.seen[sig] = time.Unix(ts+301, 0) // the window above takes this timestamp until ts + 300 s
	d.mu.Unlock()
	if replay {
		return nil, &SlackRefusal{Status: http.StatusConflict, Why: "a replay of a request already taken"}
	}
	// verified: only now the form and the payload
	form, err := url.ParseQuery(string(raw))
	if err != nil {
		return nil, malformed("the form does not parse")
	}
	var p struct {
		Type       string               `json:"type"`
		APIAppID   string               `json:"api_app_id"`
		Team       struct{ ID string }  `json:"team"`
		Enterprise *struct{ ID string } `json:"enterprise"`
		User       struct{ ID string }  `json:"user"`
		Container  struct {
			MessageTS string `json:"message_ts"`
			ChannelID string `json:"channel_id"`
		} `json:"container"`
		ResponseURL string `json:"response_url"`
		Actions     []struct {
			ActionID string `json:"action_id"`
			Value    string `json:"value"`
			ActionTS string `json:"action_ts"`
		} `json:"actions"`
	}
	if err := json.Unmarshal([]byte(form.Get("payload")), &p); err != nil {
		return nil, malformed("the payload is not JSON")
	}
	switch {
	case p.Type != "block_actions":
		return nil, malformed("not a block_actions payload")
	case p.APIAppID != app.AppID:
		return nil, unauthorized("the payload's app is not the one whose secret signed it")
	case p.Team.ID != app.TeamID:
		return nil, unauthorized("the payload's workspace is not the app's")
	case app.EnterpriseID != "" && (p.Enterprise == nil || p.Enterprise.ID != app.EnterpriseID):
		return nil, unauthorized("the payload's organisation is not the app's")
	case len(p.Actions) != 1:
		return nil, malformed("not one action")
	}
	c := &SlackClick{AppID: app.AppID, TeamID: app.TeamID, SlackUser: p.User.ID, User: app.Users[p.User.ID],
		Action: p.Actions[0].ActionID, MessageTS: p.Container.MessageTS, SlackChannel: p.Container.ChannelID,
		ActionTS: p.Actions[0].ActionTS, ResponseURL: p.ResponseURL}
	switch c.Action {
	case "pgv_open":
		return c, nil // a link button: Slack opened the page; nothing to write
	case "pgv_ack", "pgv_mute1h":
	default:
		return nil, malformed("an action this door does not take")
	}
	key, ch, ok := strings.Cut(p.Actions[0].Value, "|")
	if !ok || key == "" || len(key) > 64 || !nameRE.MatchString(ch) {
		return nil, malformed("the button's value is not '<finding key>|<channel>'")
	}
	c.FindingKey, c.Channel = key, ch
	if !slackUserRE.MatchString(c.SlackUser) || c.MessageTS == "" || c.SlackChannel == "" {
		return nil, malformed("the click names no user or no post")
	}
	if err := slackResponseURL(c.ResponseURL); err != nil {
		return nil, malformed(err.Error())
	}
	return c, nil
}

// AllowUser is the per-user limit after verification (30 a minute per workspace and Slack user).
func (d *SlackDoor) AllowUser(c *SlackClick, now time.Time) bool {
	k := c.TeamID + "/" + c.SlackUser
	d.mu.Lock()
	b, ok := d.users[k]
	if !ok {
		b = newBucket(0.5, 30)
		d.users[k] = b
	}
	d.mu.Unlock()
	return b.take(now)
}

// slackResponseURL: a click's response_url must be Slack's hooks host over https [inferred: the GovSlack page says to
// point a response_url at slack-gov.com instead of slack.com; hooks.slack-gov.com is that form].
func slackResponseURL(raw string) error {
	u, err := url.Parse(raw)
	if err == nil && slackProofHooks == "on" && u.Scheme == "http" && loopback(u.Hostname()) {
		return nil // a proof build only: the proof's stand-in of Slack's hooks host on loopback
	}
	if err != nil || u.Scheme != "https" || u.User != nil || (u.Host != "hooks.slack.com" && u.Host != "hooks.slack-gov.com") {
		return errors.New("the click's response_url is not Slack's hooks host")
	}
	return nil
}

// bucket is a token bucket: rate tokens a second up to burst.
type bucket struct {
	mu          sync.Mutex
	rate, burst float64
	tokens      float64
	at          time.Time
}

func newBucket(rate, burst float64) *bucket { return &bucket{rate: rate, burst: burst, tokens: burst} }

func (b *bucket) take(now time.Time) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.at.IsZero() {
		b.tokens = min(b.burst, b.tokens+now.Sub(b.at).Seconds()*b.rate)
	}
	b.at = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}
