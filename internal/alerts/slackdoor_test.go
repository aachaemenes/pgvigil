package alerts

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

// task 403b K5: the Slack door's settings, its verification order and its limits, with no network.

const doorYAML = `
doors: {slack_actions: true}
slack_apps:
  - {app_id: A0AAAAAAAA1, team_id: T0TTTTTTTT1, signing_secret: env:PGV_TEST_SIGN1, users: {U0UUUUUUUU1: alice}}
  - {app_id: A0AAAAAAAA2, team_id: T0TTTTTTTT2, signing_secret: env:PGV_TEST_SIGN2, users: {U0UUUUUUUU2: bob}}
alerts:
  - {name: sb, kind: slack, slack: {bot_token: env:PGV_TEST_SLACK, channel: C0123ABCD, app_id: A0AAAAAAAA1}}
  - {name: sb2, kind: slack, slack: {bot_token: env:PGV_TEST_SLACK, channel: C0123ABCE, app_id: A0ZZZZZZZZ9}}
`

func doorEnv(t *testing.T) {
	t.Setenv("PGV_TEST_SLACK", "xoxb-1-2-abc")
	t.Setenv("PGV_TEST_SIGN1", "s3cr3t-one")
	t.Setenv("PGV_TEST_SIGN2", "s3cr3t-two")
}

func TestSlackDoorSettings(t *testing.T) {
	doorEnv(t)
	s, err := Parse([]byte(doorYAML))
	if err != nil {
		t.Fatal(err)
	}
	if !s.SlackActionsOn() {
		t.Fatal("the door is off")
	}
	if !s.Channels[0].sender.(*slackSender).buttons || s.Channels[1].sender.(*slackSender).buttons {
		t.Error("buttons: on for the listed app only")
	}
	off, err := Parse([]byte(strings.Replace(doorYAML, "slack_actions: true", "slack_actions: false", 1)))
	if err != nil || off.SlackActionsOn() || off.Channels[0].sender.(*slackSender).buttons {
		t.Errorf("the switch off: %v", err)
	}
	if d, err := off.SlackDoor(); d != nil || err != nil {
		t.Errorf("an off door reads secrets: %v %v", d, err)
	}
	for name, bad := range map[string]string{
		"user by name":  strings.Replace(doorYAML, "U0UUUUUUUU1: alice", "alice.smith: alice", 1),
		"inline secret": strings.Replace(doorYAML, "env:PGV_TEST_SIGN1", "s3cr3t-one", 1),
		"no users":      strings.Replace(doorYAML, "users: {U0UUUUUUUU1: alice}", "users: {}", 1),
		"twice":         strings.Replace(doorYAML, "A0AAAAAAAA2", "A0AAAAAAAA1", 1),
		"bad team":      strings.Replace(doorYAML, "T0TTTTTTTT1", "workspace", 1),
		"leading dot":   strings.Replace(doorYAML, "U0UUUUUUUU1: alice", "U0UUUUUUUU1: .alice", 1),
		"leading at":    strings.Replace(doorYAML, "U0UUUUUUUU1: alice", "U0UUUUUUUU1: \"@alice\"", 1),
	} {
		if _, err := Parse([]byte(bad)); err == nil {
			t.Errorf("%s: accepted", name)
		} else if strings.Contains(err.Error(), "s3cr3t") {
			t.Errorf("%s: the secret is in the error: %v", name, err)
		}
	}
}

// serve reads the door's part only - a file whose Slack bot channel's token is not on
// this host still gives the door; the switch on with a fault is an error, off is nil
func TestParseSlackDoorWithoutChannelToken(t *testing.T) {
	doorEnv(t)
	t.Setenv("PGV_TEST_SLACK", "") // the channels' bot token is not on this host
	cfg := doorYAML
	if _, err := Parse([]byte(cfg)); err == nil || !strings.Contains(err.Error(), "slack.bot_token") {
		t.Fatalf("the whole file without the token (the old door start's read): %v", err)
	}
	d, err := ParseSlackDoor([]byte(cfg))
	if err != nil || d == nil || strings.Join(d.AppIDs(), ",") != "A0AAAAAAAA1,A0AAAAAAAA2" {
		t.Fatalf("the door without a channel token: %v %v", d, err)
	}
	if d, err := ParseSlackDoor([]byte(strings.Replace(cfg, "slack_actions: true", "slack_actions: false", 1))); d != nil || err != nil {
		t.Errorf("off: %v %v", d, err)
	}
	if _, err := ParseSlackDoor([]byte(strings.Replace(cfg, "env:PGV_TEST_SIGN1", "s3cr3t-one", 1))); err == nil {
		t.Error("an inline secret with the switch on: no error")
	}
	if _, err := ParseSlackDoor([]byte("doors: {slack_actions: true}\n")); err == nil {
		t.Error("the switch on with no app: no error")
	}
}

// a pgvigil user name is read as the UI login reads it (lowercased), so an
// acknowledgement is written under the store's one spelling
func TestSlackDoorUserLowercase(t *testing.T) {
	doorEnv(t)
	s, err := Parse([]byte(strings.Replace(doorYAML, "U0UUUUUUUU1: alice", "U0UUUUUUUU1: Alice", 1)))
	if err != nil {
		t.Fatal(err)
	}
	if u := s.SlackApps[0].Users["U0UUUUUUUU1"]; u != "alice" {
		t.Errorf("mapped to %q", u)
	}
}

func signed(t *testing.T, secret string, ts int64, payload map[string]any) (http.Header, []byte) {
	t.Helper()
	pj, _ := json.Marshal(payload)
	body := []byte(url.Values{"payload": {string(pj)}}.Encode())
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte("v0:" + strconv.FormatInt(ts, 10) + ":"))
	m.Write(body)
	h := http.Header{}
	h.Set("Content-Type", "application/x-www-form-urlencoded")
	h.Set("X-Slack-Request-Timestamp", strconv.FormatInt(ts, 10))
	h.Set("X-Slack-Signature", "v0="+hex.EncodeToString(m.Sum(nil)))
	return h, body
}

func click(app, team, user, action, value string) map[string]any {
	return map[string]any{"type": "block_actions", "api_app_id": app, "team": map[string]any{"id": team}, "user": map[string]any{"id": user},
		"container":    map[string]any{"message_ts": "1700000000.000100", "channel_id": "C0123ABCD"},
		"response_url": "https://hooks.slack.com/actions/T0TTTTTTTT1/1/abc", "token": "ignored",
		"actions": []map[string]any{{"action_id": action, "value": value, "action_ts": "1700000001.1"}}}
}

func TestSlackDoorVerify(t *testing.T) {
	doorEnv(t)
	s, err := Parse([]byte(doorYAML))
	if err != nil {
		t.Fatal(err)
	}
	d, err := s.SlackDoor()
	if err != nil || d == nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	status := func(err error) int {
		var r *SlackRefusal
		if errors.As(err, &r) {
			return r.Status
		}
		return -1
	}
	h, b := signed(t, "s3cr3t-one", now.Unix(), click("A0AAAAAAAA1", "T0TTTTTTTT1", "U0UUUUUUUU1", "pgv_ack", "k1|sb"))
	c, err := d.Verify(h, b, now)
	if err != nil || c.User != "alice" || c.FindingKey != "k1" || c.Channel != "sb" || c.MessageTS != "1700000000.000100" || c.SlackChannel != "C0123ABCD" {
		t.Fatalf("a good click: %+v %v", c, err)
	}
	if _, err := d.Verify(h, b, now); status(err) != http.StatusConflict {
		t.Errorf("a replay: %v", err)
	}
	// serve's clock 250 s behind Slack's - the request's timestamp is taken until 550 s
	// after it arrives, so its signature is kept that long (6 minutes would free it at 360 s)
	h, b = signed(t, "s3cr3t-one", now.Unix()+250, click("A0AAAAAAAA1", "T0TTTTTTTT1", "U0UUUUUUUU1", "pgv_ack", "k9|sb"))
	if _, err := d.Verify(h, b, now); err != nil {
		t.Fatalf("a click 250 s ahead: %v", err)
	}
	if _, err := d.Verify(h, b, now.Add(400*time.Second)); status(err) != http.StatusConflict {
		t.Errorf("its replay 400 s on: %v", err)
	}
	if _, err := d.Verify(h, b, now.Add(560*time.Second)); status(err) != http.StatusUnauthorized {
		t.Errorf("its replay 560 s on (its timestamp 310 s past): %v", err)
	}
	// the second app's secret picks the second app; its user map applies
	h, b = signed(t, "s3cr3t-two", now.Unix(), click("A0AAAAAAAA2", "T0TTTTTTTT2", "U0UUUUUUUU2", "pgv_mute1h", "k2|sb"))
	if c, err := d.Verify(h, b, now); err != nil || c.User != "bob" || c.AppID != "A0AAAAAAAA2" {
		t.Errorf("the second app: %+v %v", c, err)
	}
	// an unmapped user is a click with no user (the handler refuses it in words)
	h, b = signed(t, "s3cr3t-one", now.Unix(), click("A0AAAAAAAA1", "T0TTTTTTTT1", "U0XXXXXXXX9", "pgv_ack", "k1|sb"))
	if c, err := d.Verify(h, b, now); err != nil || c.User != "" {
		t.Errorf("unmapped: %+v %v", c, err)
	}
	for name, tc := range map[string]struct {
		secret string
		ts     int64
		p      map[string]any
		mutate func(http.Header, []byte) []byte
		want   int
	}{
		"bad signature":                     {"wrong", now.Unix(), click("A0AAAAAAAA1", "T0TTTTTTTT1", "U0UUUUUUUU1", "pgv_ack", "k1|sb"), nil, 401},
		"stale":                             {"s3cr3t-one", now.Unix() - 301, click("A0AAAAAAAA1", "T0TTTTTTTT1", "U0UUUUUUUU1", "pgv_ack", "k1|sb"), nil, 401},
		"future":                            {"s3cr3t-one", now.Unix() + 301, click("A0AAAAAAAA1", "T0TTTTTTTT1", "U0UUUUUUUU1", "pgv_ack", "k1|sb"), nil, 401},
		"app's secret, other app's payload": {"s3cr3t-one", now.Unix(), click("A0AAAAAAAA2", "T0TTTTTTTT2", "U0UUUUUUUU2", "pgv_ack", "k1|sb"), nil, 401},
		"other workspace":                   {"s3cr3t-one", now.Unix(), click("A0AAAAAAAA1", "T0TTTTTTTT9", "U0UUUUUUUU1", "pgv_ack", "k1|sb"), nil, 401},
		"json content type":                 {"s3cr3t-one", now.Unix(), click("A0AAAAAAAA1", "T0TTTTTTTT1", "U0UUUUUUUU1", "pgv_ack", "k1|sb"), func(h http.Header, b []byte) []byte { h.Set("Content-Type", "application/json"); return b }, 401},
		"body changed":                      {"s3cr3t-one", now.Unix(), click("A0AAAAAAAA1", "T0TTTTTTTT1", "U0UUUUUUUU1", "pgv_ack", "k1|sb"), func(_ http.Header, b []byte) []byte { return append(b, '&', 'x', '=', '1') }, 401},
		"unknown action":                    {"s3cr3t-one", now.Unix(), click("A0AAAAAAAA1", "T0TTTTTTTT1", "U0UUUUUUUU1", "pgv_delete", "k1|sb"), nil, 400},
		"bad value":                         {"s3cr3t-one", now.Unix(), click("A0AAAAAAAA1", "T0TTTTTTTT1", "U0UUUUUUUU1", "pgv_ack", "no-channel"), nil, 400},
		"not block_actions":                 {"s3cr3t-one", now.Unix(), map[string]any{"type": "view_submission", "api_app_id": "A0AAAAAAAA1", "team": map[string]any{"id": "T0TTTTTTTT1"}}, nil, 400},
		"response_url host": {"s3cr3t-one", now.Unix(), func() map[string]any {
			p := click("A0AAAAAAAA1", "T0TTTTTTTT1", "U0UUUUUUUU1", "pgv_ack", "k1|sb")
			p["response_url"] = "https://evil.example/hook"
			return p
		}(), nil, 400},
	} {
		h, b := signed(t, tc.secret, tc.ts, tc.p)
		if tc.mutate != nil {
			b = tc.mutate(h, b)
		}
		if _, err := d.Verify(h, b, now); status(err) != tc.want {
			t.Errorf("%s: %v (want %d)", name, err, tc.want)
		}
	}
	if _, err := d.Verify(http.Header{}, make([]byte, SlackBodyMax+1), now); status(err) != 400 {
		t.Errorf("over the cap: %v", err)
	}
}

func TestSlackDoorLimits(t *testing.T) {
	b := newBucket(20, 40)
	now := time.Unix(1_800_000_000, 0)
	n := 0
	for b.take(now) {
		n++
	}
	if n != 40 {
		t.Errorf("burst %d", n)
	}
	if !b.take(now.Add(100 * time.Millisecond)) {
		t.Error("no refill after 100 ms at 20 a second")
	}
	d := &SlackDoor{users: map[string]*bucket{}}
	c := &SlackClick{TeamID: "T0TTTTTTTT1", SlackUser: "U0UUUUUUUU1"}
	n = 0
	for d.AllowUser(c, now) {
		n++
	}
	if n != 30 {
		t.Errorf("per user %d a minute", n)
	}
}
