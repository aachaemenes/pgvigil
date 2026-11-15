package alerts

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"
)

// task B24k: the Pushover kind against a loopback stub of the answers pushover.net/api documents (a 200 with status
// other than 1 is assumed: the page states status 1 for success only).

const (
	poTestToken = "azGDORePK8gMaC0QOYAMyEEuzJnyUi"
	poTestUser  = "uQiRzpo4DXghDmr9QzzfQu27cmVRsG"
)

func pushoverFor(t *testing.T, base, user, device string) *pushoverSender {
	t.Helper()
	t.Setenv("PGV_TEST_PO_TOKEN", poTestToken)
	t.Setenv("PGV_TEST_PO_USER", user)
	s, err := (&Pushover{Token: "env:PGV_TEST_PO_TOKEN", User: "env:PGV_TEST_PO_USER", Device: device, URL: base}).build()
	if err != nil {
		t.Fatal(err)
	}
	return s.(*pushoverSender)
}

func TestPushoverRefuses(t *testing.T) {
	t.Setenv("PGV_TEST_PO_TOKEN", poTestToken)
	t.Setenv("PGV_TEST_PO_USER", poTestUser)
	t.Setenv("PGV_TEST_PO_BAD", "not a key!")
	for name, p := range map[string]Pushover{
		"inline token":    {Token: poTestToken, User: "env:PGV_TEST_PO_USER"},
		"bad user":        {Token: "env:PGV_TEST_PO_TOKEN", User: "env:PGV_TEST_PO_BAD"},
		"another host":    {Token: "env:PGV_TEST_PO_TOKEN", User: "env:PGV_TEST_PO_USER", URL: "https://pushover.example.org"},
		"plain off host":  {Token: "env:PGV_TEST_PO_TOKEN", User: "env:PGV_TEST_PO_USER", URL: "http://api.pushover.net"},
		"a path":          {Token: "env:PGV_TEST_PO_TOKEN", User: "env:PGV_TEST_PO_USER", URL: "https://api.pushover.net/1/messages.json"},
		"device name":     {Token: "env:PGV_TEST_PO_TOKEN", User: "env:PGV_TEST_PO_USER", Device: "my phone"},
		"device too long": {Token: "env:PGV_TEST_PO_TOKEN", User: "env:PGV_TEST_PO_USER", Device: strings.Repeat("d", 26)},
	} {
		if _, err := p.build(); err == nil {
			t.Errorf("%s: built", name)
		}
	}
}

type poStub struct {
	mu    sync.Mutex
	forms []url.Values
	code  int
	body  string
	hdr   map[string]string
}

func (st *poStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	st.mu.Lock()
	defer st.mu.Unlock()
	if r.URL.Path != "/1/messages.json" || r.Method != http.MethodPost || r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	st.forms = append(st.forms, r.PostForm)
	for k, v := range st.hdr {
		w.Header().Set(k, v)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(st.code)
	_, _ = w.Write([]byte(st.body))
}

// answer sets the stub's next answers under its lock; posts reads what it got there.
func (st *poStub) answer(code int, body string, hdr map[string]string) {
	st.mu.Lock()
	st.code, st.body, st.hdr = code, body, hdr
	st.mu.Unlock()
}

func (st *poStub) posts(reset bool) []url.Values {
	st.mu.Lock()
	defer st.mu.Unlock()
	out := st.forms
	if reset {
		st.forms = nil
	}
	return out
}

func TestPushoverSend(t *testing.T) {
	st := &poStub{code: 200, body: `{"status":1,"request":"647d2300-702c-4b38-8b2f-d56326ae460b"}`,
		hdr: map[string]string{"X-Limit-App-Limit": "10000", "X-Limit-App-Remaining": "7496", "X-Limit-App-Reset": "1393653600"}}
	srv := httptest.NewServer(st)
	defer srv.Close()
	s := pushoverFor(t, srv.URL, poTestUser, "phone1,tablet")
	if d := s.destination(); strings.Contains(d, poTestToken) || !strings.HasSuffix(d, "(pushover)") {
		t.Fatalf("destination %q", d)
	}
	warn := crit
	warn.Severity, warn.FindingKey = "warning", "fedcba9876543210"
	res := crit
	res.Event = "resolved"
	withURL := crit
	withURL.URL = "https://pgvigil.example.org/#/alert?k=0123456789abcdef"
	at := time.Date(2026, 11, 15, 8, 0, 0, 0, time.UTC)
	if err := s.send(context.Background(), Message{Channel: "po", SentAt: at, Alerts: []Alert{withURL, warn, res}}); err != nil {
		t.Fatalf("send: %v", err)
	}
	forms := st.posts(true)
	if len(forms) != 3 {
		t.Fatalf("%d posts, want one per alert (3)", len(forms))
	}
	f := forms[0]
	if f.Get("token") != poTestToken || f.Get("user") != poTestUser || f.Get("device") != "phone1,tablet" {
		t.Errorf("token / user / device: %v", f)
	}
	if f.Get("priority") != "1" || forms[1].Get("priority") != "0" || forms[2].Get("priority") != "-1" {
		t.Errorf("priorities %s %s %s, want 1 (critical), 0 (warning), -1 (recovery)", f.Get("priority"), forms[1].Get("priority"), forms[2].Get("priority"))
	}
	if f.Get("url") != withURL.URL || f.Get("url_title") == "" || forms[1].Get("url") != "" {
		t.Errorf("url %q / %q, want the alert's page on the first only", f.Get("url"), forms[1].Get("url"))
	}
	if f.Get("timestamp") != fmt.Sprint(at.Unix()) || !strings.Contains(f.Get("message"), "erp01") || f.Get("title") == "" {
		t.Errorf("timestamp / message / title: %v", f)
	}
	q := s.lastQuota()
	if q == nil || q.Remaining != 7496 || q.Limit != 10000 || !q.Reset.Equal(time.Unix(1393653600, 0)) {
		t.Fatalf("quota %+v, want 7496 of 10000", q)
	}
	if s.lastQuota() != nil {
		t.Error("the quota is handed over twice")
	}
	// lengths in characters: a title of 300 runes is cut to 250, a message stays within 1,024
	long := crit
	long.Instance = strings.Repeat("é", 300)
	if err := s.send(context.Background(), Message{SentAt: at, Subject: strings.Repeat("ü", 300), Alerts: []Alert{long}}); err != nil {
		t.Fatal(err)
	}
	forms = st.posts(true)
	if n := utf8.RuneCountInString(forms[0].Get("title")); n != 250 {
		t.Errorf("title of %d characters, want 250", n)
	}
	if n := utf8.RuneCountInString(forms[0].Get("message")); n > 1024 {
		t.Errorf("message of %d characters", n)
	}
}

func TestPushoverAnswers(t *testing.T) {
	st := &poStub{}
	srv := httptest.NewServer(st)
	defer srv.Close()
	s := pushoverFor(t, srv.URL, poTestUser, "")
	now := time.Now()
	reset := now.Add(72 * time.Hour).Truncate(time.Second)
	cases := []struct {
		name     string
		code     int
		body     string
		hdr      map[string]string
		errHas   string
		held     bool
		heldWhen time.Time // held must end by then
	}{
		{"200 status 0", 200, `{"status":0,"errors":["something"]}`, nil, "status 0 (not 1)", false, time.Time{}},
		{"429", 429, `{"status":0,"errors":["application has exceeded its monthly limit"]}`,
			map[string]string{"X-Limit-App-Reset": fmt.Sprint(reset.Unix())}, "held until " + reset.UTC().Format(time.RFC3339) + ": ", true, reset.Add(time.Second)},
		{"400 echoing the token", 400, `{"user":"invalid","errors":["application token is invalid: ` + poTestToken + `"],"status":0}`, nil,
			"held until the configuration changes (" + s.cfg + "): ", true, time.Time{}},
		{"500", 500, `oops`, nil, "500", false, time.Time{}},
	}
	for _, c := range cases {
		st.answer(c.code, c.body, c.hdr)
		err := s.send(context.Background(), msg(crit))
		if err == nil || !strings.Contains(err.Error(), c.errHas) {
			t.Errorf("%s: err %v, want it to hold %q", c.name, err, c.errHas)
			continue
		}
		if strings.Contains(err.Error(), poTestToken) || strings.Contains(err.Error(), poTestUser) {
			t.Errorf("%s: the error shows a key: %v", c.name, err)
		}
		if h, why := s.held(err.Error(), now); h != c.held || (h && why == "") {
			t.Errorf("%s: held %v (%q), want %v", c.name, h, why, c.held)
		}
		if !c.heldWhen.IsZero() {
			if h, _ := s.held(err.Error(), c.heldWhen); h {
				t.Errorf("%s: still held after the reset", c.name)
			}
		}
		if c.code == 400 {
			// another configuration (another user key) is not held by this one's 4xx
			other := pushoverFor(t, srv.URL, "u2"+poTestUser[2:], "")
			if h, _ := other.held(err.Error(), now); h {
				t.Errorf("%s: a changed configuration is still held", c.name)
			}
		}
	}
	if h, _ := s.held("", now); h {
		t.Error("no last attempt holds")
	}
	if h, _ := s.held("some error: held until 2999-01-01T00:00:00Z: x", now); h {
		t.Error("a hold not at the head of the error text holds")
	}
}
