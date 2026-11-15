package alerts

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// task 403b K2: the Slack bot sender against a loopback stand-in of chat.postMessage.

func TestSlackBuild(t *testing.T) {
	t.Setenv("PGV_TEST_SLACK", "xoxb-1-2-abc")
	t.Setenv("PGV_TEST_USER_TOKEN", "xoxp-1-2-abc")
	ok := func(b SlackBot) error {
		_, err := b.build()
		return err
	}
	if err := ok(SlackBot{BotToken: "env:PGV_TEST_SLACK", Channel: "C0123ABCD"}); err != nil {
		t.Fatalf("a plain bot channel: %v", err)
	}
	if err := ok(SlackBot{BotToken: "env:PGV_TEST_SLACK", Channel: "C0123ABCD", APIURL: "https://slack-gov.com/api"}); err != nil {
		t.Fatalf("GovSlack: %v", err)
	}
	for name, b := range map[string]SlackBot{
		"inline token":     {BotToken: "xoxb-1-2-abc", Channel: "C0123ABCD"},
		"user token":       {BotToken: "env:PGV_TEST_USER_TOKEN", Channel: "C0123ABCD"},
		"channel name":     {BotToken: "env:PGV_TEST_SLACK", Channel: "#alerts"},
		"other host":       {BotToken: "env:PGV_TEST_SLACK", Channel: "C0123ABCD", APIURL: "https://evil.example/api"},
		"plain http":       {BotToken: "env:PGV_TEST_SLACK", Channel: "C0123ABCD", APIURL: "http://slack.com/api"},
		"slack.com path":   {BotToken: "env:PGV_TEST_SLACK", Channel: "C0123ABCD", APIURL: "https://slack.com/other"},
		"bad app id":       {BotToken: "env:PGV_TEST_SLACK", Channel: "C0123ABCD", AppID: "B123"},
		"query on the API": {BotToken: "env:PGV_TEST_SLACK", Channel: "C0123ABCD", APIURL: "http://127.0.0.1:9/api?x=1"},
	} {
		if err := ok(b); err == nil {
			t.Errorf("%s: accepted", name)
		} else if strings.Contains(err.Error(), "xoxb-1-2-abc") {
			t.Errorf("%s: the token is in the error: %v", name, err)
		}
	}
}

// slackStub answers chat.postMessage from a queue (nil = ok with the next ts) and keeps every request.
type slackStub struct {
	mu      sync.Mutex
	answers []func(w http.ResponseWriter)
	bodies  []map[string]any
	auth    []string
	at      []time.Time
	n       int
}

func (st *slackStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	st.mu.Lock()
	defer st.mu.Unlock()
	b, _ := io.ReadAll(r.Body)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	st.bodies, st.auth, st.at = append(st.bodies, m), append(st.auth, r.Header.Get("Authorization")), append(st.at, time.Now())
	st.n++
	if r.URL.Path != "/api/chat.postMessage" {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if len(st.answers) > 0 {
		a := st.answers[0]
		st.answers = st.answers[1:]
		if a != nil {
			a(w)
			return
		}
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "ts": "1700000000." + strings.Repeat("0", 5) + string(rune('0'+st.n%10))})
}

func slackOK(code string) func(w http.ResponseWriter) {
	return func(w http.ResponseWriter) { _ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": code}) }
}

func newSlackTest(t *testing.T, st *slackStub) *slackSender {
	t.Helper()
	srv := httptest.NewServer(st)
	t.Cleanup(srv.Close)
	t.Setenv("PGV_TEST_SLACK", "xoxb-1-2-secret")
	snd, err := (&SlackBot{BotToken: "env:PGV_TEST_SLACK", Channel: "C0123ABCD", APIURL: srv.URL + "/api"}).build()
	if err != nil {
		t.Fatal(err)
	}
	s := snd.(*slackSender)
	s.gap = 50 * time.Millisecond
	return s
}

func slackAlert(key, ev, sev string) Alert {
	return Alert{Event: ev, FindingKey: key, Instance: "db1", Severity: sev, Source: "rule", Setting: "CPU: machine CPU", Value: "97",
		Detail: "<!channel> & <@U123> look", URL: "https://pgvigil.example/#/alert?k=" + key + "&t=1"}
}

func TestSlackPostReply(t *testing.T) {
	st := &slackStub{}
	s := newSlackTest(t, st)
	ctx := context.Background()
	ts, err := s.post(ctx, Message{Channel: "sb", Alerts: []Alert{slackAlert("k1", "firing", "warning")}})
	if err != nil || ts == "" {
		t.Fatalf("post: %q %v", ts, err)
	}
	if err := s.reply(ctx, Message{Channel: "sb", Alerts: []Alert{slackAlert("k1", "escalated", "critical")}}, ts, true); err != nil {
		t.Fatalf("reply: %v", err)
	}
	if err := s.reply(ctx, Message{Channel: "sb", Alerts: []Alert{slackAlert("k1", "resolved", "critical")}}, ts, false); err != nil {
		t.Fatalf("recovery: %v", err)
	}
	if len(st.bodies) != 3 {
		t.Fatalf("%d calls", len(st.bodies))
	}
	for i, a := range st.auth {
		if a != "Bearer xoxb-1-2-secret" {
			t.Errorf("call %d: Authorization %q", i, a)
		}
	}
	p, esc, rec := st.bodies[0], st.bodies[1], st.bodies[2]
	if p["channel"] != "C0123ABCD" || p["thread_ts"] != nil {
		t.Errorf("post: %v", p)
	}
	if esc["thread_ts"] != ts || esc["reply_broadcast"] != true {
		t.Errorf("escalation: thread_ts %v broadcast %v", esc["thread_ts"], esc["reply_broadcast"])
	}
	if rec["thread_ts"] != ts || rec["reply_broadcast"] != nil {
		t.Errorf("recovery: thread_ts %v broadcast %v", rec["thread_ts"], rec["reply_broadcast"])
	}
	all, _ := json.Marshal(st.bodies)
	if strings.Contains(string(all), "<!channel>") || strings.Contains(string(all), "<@U123>") {
		t.Errorf("a finding's text reached Slack unescaped: %s", all)
	}
	if !strings.Contains(string(all), `&lt;!channel&gt;`) && !strings.Contains(string(all), "&lt;!channel&gt;") {
		t.Errorf("the escaped mention is missing: %s", all)
	}
	// the post carries the link button only (the door is off); replies carry no actions
	if !strings.Contains(blocksOf(p), `"pgv_open"`) || strings.Contains(blocksOf(p), `"pgv_ack"`) {
		t.Errorf("post's actions: %s", blocksOf(p))
	}
	if strings.Contains(blocksOf(esc), `"actions"`) {
		t.Errorf("a reply carries actions: %s", blocksOf(esc))
	}
	// pacing: the calls are at least the gap apart
	for i := 1; i < len(st.at); i++ {
		if d := st.at[i].Sub(st.at[i-1]); d < 45*time.Millisecond {
			t.Errorf("calls %d and %d %s apart", i-1, i, d)
		}
	}
}

func blocksOf(m map[string]any) string {
	b, _ := json.Marshal(m["blocks"])
	return string(b)
}

func TestSlackButtonsWithTheDoor(t *testing.T) {
	st := &slackStub{}
	s := newSlackTest(t, st)
	s.buttons = true
	if _, err := s.post(context.Background(), Message{Channel: "sb", Alerts: []Alert{slackAlert("k1", "firing", "warning"), slackAlert("k2", "repeat", "warning")}}); err != nil {
		t.Fatal(err)
	}
	b := blocksOf(st.bodies[0])
	if strings.Count(b, `"pgv_ack"`) != 1 || strings.Count(b, `"pgv_mute1h"`) != 1 {
		t.Errorf("buttons on the firing alert only: %s", b)
	}
	if !strings.Contains(b, `"k1|sb"`) || !strings.Contains(b, `"confirm"`) {
		t.Errorf("the value or the mute's confirm: %s", b)
	}
}

func TestSlackRefusals(t *testing.T) {
	st := &slackStub{answers: []func(http.ResponseWriter){
		slackOK("channel_not_found"),
		slackOK("cannot_reply_to_message"),
		func(w http.ResponseWriter) {
			w.Header().Set("Location", "https://elsewhere.example/")
			w.WriteHeader(http.StatusFound)
		},
		func(w http.ResponseWriter) { _, _ = w.Write([]byte("<html>not json</html>")) },
		func(w http.ResponseWriter) { _ = json.NewEncoder(w).Encode(map[string]any{"ok": true}) },
		slackOK("Bad Code With Spaces xoxb-1-2-secret"),
	}}
	s := newSlackTest(t, st)
	ctx := context.Background()
	m := Message{Channel: "sb", Alerts: []Alert{slackAlert("k1", "repeat", "warning")}}
	_, err := s.post(ctx, m)
	if err == nil || err.Error() != "slack answered channel_not_found" || threadRefused(err) {
		t.Errorf("channel_not_found: %v", err)
	}
	err = s.reply(ctx, m, "1.1", false)
	if !threadRefused(err) {
		t.Errorf("cannot_reply_to_message is not a thread refusal: %v", err)
	}
	_, err = s.post(ctx, m)
	var re *refusedError
	if err == nil || !errors.As(err, &re) {
		t.Errorf("a redirect: %v", err)
	}
	if _, err = s.post(ctx, m); err == nil || !strings.Contains(err.Error(), "not Slack's JSON") {
		t.Errorf("not JSON: %v", err)
	}
	if _, err = s.post(ctx, m); err == nil || !strings.Contains(err.Error(), "without a ts") {
		t.Errorf("ok without ts: %v", err)
	}
	if _, err = s.post(ctx, m); err == nil || strings.Contains(err.Error(), "xoxb") || !strings.Contains(err.Error(), "unreadable") {
		t.Errorf("an unreadable code: %v", err)
	}
}

func TestSlackCut(t *testing.T) {
	long := strings.Repeat("a&", 2000) // escaped: 'a&amp;' x 2000 = 12,000 characters
	got := slackCut(slackEscape(long), slackSection)
	if n := len([]rune(got)); n > slackSection {
		t.Errorf("%d characters", n)
	}
	body := strings.TrimSuffix(got, " ...")
	if i := strings.LastIndexByte(body, '&'); i >= 0 && !strings.Contains(body[i:], ";") {
		t.Errorf("cut inside an entity: %q", body[len(body)-12:])
	}
	if slackCut("short", 10) != "short" {
		t.Error("a short text was cut")
	}
}
