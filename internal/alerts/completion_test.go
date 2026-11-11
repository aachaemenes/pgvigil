package alerts

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Task 151 (K07): the base address, the templates, the Opsgenie kind, the chat formats' budgets, the send cap's
// order and the Send test's message.

func TestBaseURL(t *testing.T) {
	for raw, want := range map[string]string{
		"https://pgvigil.example.org/":      "https://pgvigil.example.org",
		"http://127.0.0.1:8080":             "http://127.0.0.1:8080",
		"https://ops.example.org/pgvigil//": "https://ops.example.org/pgvigil",
		"":                                  "",
	} {
		got, err := parseBaseURL(raw)
		if err != nil || got != want {
			t.Errorf("%q: got %q, %v; want %q", raw, got, err, want)
		}
	}
	for _, raw := range []string{"ftp://x.example.org", "pgvigil.example.org", "https://u:p@x.example.org", "https://x.example.org/?a=1", "https://x.example.org/#/alerts"} {
		if _, err := parseBaseURL(raw); err == nil {
			t.Errorf("%q accepted", raw)
		}
	}
	st, err := Parse([]byte("alerts_base_url: https://pgvigil.example.org/\nalerts: [{name: d, kind: file, file: {dir: " + t.TempDir() + "}}]"))
	if err != nil {
		t.Fatal(err)
	}
	c := &st.Channels[0]
	at := time.Unix(1762900000, 0)
	a := c.decorate(Alert{Event: "firing", FindingKey: "5f0c2a9d8e7b6a5f4e3d2c1b0a9f8e7d", Instance: "erp01", Severity: "critical", Source: "s", Setting: "x", Value: "1"}, at)
	want := "https://pgvigil.example.org/#/alert?k=5f0c2a9d8e7b6a5f4e3d2c1b0a9f8e7d&t=1762900000"
	if a.URL != want {
		t.Errorf("url %q, want %q", a.URL, want)
	}
	if l := a.Line(); !strings.HasSuffix(l, " "+want) {
		t.Errorf("the line does not end with the address: %q", l)
	}
	// a long value is cut before the address, never the address
	a.Value = strings.Repeat("v", 2000)
	if l := a.Line(); !strings.HasSuffix(l, " ... "+want) || len(l) != maxLine+1+len(want) {
		t.Errorf("long line: %d bytes, ends %q", len(l), l[len(l)-90:])
	}
}

func TestTemplates(t *testing.T) {
	bad := map[string]string{
		"{subject: {firing: 'x {instnace}'}}":     "unknown placeholder {instnace}",
		"{subject: {fired: 'x'}}":                 "the events are",
		"{line: {firing: 'n={count}'}}":           "belongs to a subject",
		"{subject: {firing: \"a\\nb\"}}":          "line break",
		"{subject: {firing: '   '}}":              "is empty",
		"{line: {repeat: '{severity} {nope_1}'}}": "unknown placeholder {nope_1}",
	}
	for tpl, want := range bad {
		_, err := Parse([]byte("alerts: [{name: d, kind: file, file: {dir: " + t.TempDir() + "}, templates: " + tpl + "}]"))
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v, want %q", tpl, err, want)
		}
	}
	st, err := Parse([]byte(`alerts_base_url: https://p.example.org
alerts: [{name: d, kind: file, file: {dir: ` + t.TempDir() + `}, templates: {
  subject: {firing: "{severity}: {setting} on {instance} ({count} in all)", resolved: "OK: {instance}"},
  line: {firing: "{instance} {setting} = {value} see {url}", repeat: "still {instance} {setting} after {sends} send(s)"}}}]`))
	if err != nil {
		t.Fatal(err)
	}
	c := &st.Channels[0]
	if w := c.tpl.words(); w != "subject firing, line firing, line repeat, subject resolved" {
		t.Errorf("words %q", w)
	}
	now := time.Unix(1762900000, 0)
	first := now.Add(-time.Hour)
	fire := c.decorate(Alert{Event: "escalated", FindingKey: "5f0c2a9d8e7b6a5f4e3d2c1b0a9f8e7d", Instance: "erp01", Severity: "critical", Setting: "autovacuum", Value: "off", FirstSentAt: &first}, now)
	rep := c.decorate(Alert{Event: "repeat", FindingKey: "5f0c2a9d8e7b6a5f4e3d2c1b0a9f8e7e", Instance: "crm01", Severity: "warning", Setting: "xid age", Value: "9", SentBefore: 3}, now)
	res := c.decorate(Alert{Event: "resolved", FindingKey: "5f0c2a9d8e7b6a5f4e3d2c1b0a9f8e7f", Instance: "hr01", Severity: "info", Setting: "x", Value: "y"}, now)
	// escalated takes firing's line; the template placed {url}, so it is not appended again
	if l := fire.Line(); l != "erp01 autovacuum = off see "+fire.URL || strings.Count(l, "https://") != 1 {
		t.Errorf("escalated line %q", l)
	}
	if l := rep.Line(); l != "still crm01 xid age after 3 send(s) "+rep.URL {
		t.Errorf("repeat line %q", l)
	}
	// no line template for resolved: the built-in line, then the address
	if l := res.Line(); !strings.HasPrefix(l, "[RESOLVED] hr01: ") || !strings.HasSuffix(l, res.URL) {
		t.Errorf("resolved line %q", l)
	}
	if s := c.subject([]Alert{rep, fire, res}); s != "critical: autovacuum on erp01 (3 in all)" {
		t.Errorf("subject %q", s)
	}
	if s := c.subject([]Alert{res}); s != "OK: hr01" {
		t.Errorf("resolved subject %q", s)
	}
	// a repeat-only message has no repeat subject template: the built-in summary
	if s := c.subject([]Alert{rep}); s != "" {
		t.Errorf("repeat subject %q, want the built-in", s)
	}
	if m := (Message{Alerts: []Alert{rep}}); m.Summary() != "pgvigil: 1 still open" {
		t.Errorf("summary %q", m.Summary())
	}
}

const testOGKey = "0123abcd-4567-89ef-0123-456789abcdef"

func TestOpsgenie(t *testing.T) {
	type req struct {
		method, path, query, auth string
		body                      map[string]any
	}
	var mu sync.Mutex
	var got []req
	status := http.StatusAccepted
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		var m map[string]any
		_ = json.Unmarshal(b, &m)
		mu.Lock()
		got = append(got, req{r.Method, r.URL.EscapedPath(), r.URL.RawQuery, r.Header.Get("Authorization"), m})
		st := status
		mu.Unlock()
		w.WriteHeader(st)
		if st >= 400 {
			_, _ = io.WriteString(w, `{"message":"Key `+testOGKey+` is invalid","took":0.001}`)
			return
		}
		_, _ = io.WriteString(w, `{"result":"Request will be processed","took":0.1,"requestId":"x"}`)
	}))
	defer srv.Close()
	t.Setenv("PGV_TEST_OG", testOGKey)
	st, err := Parse([]byte("alerts_base_url: https://p.example.org\nalerts: [{name: og, kind: opsgenie, min_severity: info, opsgenie: {api_key: env:PGV_TEST_OG, url: " + srv.URL + "}}]"))
	if err != nil {
		t.Fatal(err)
	}
	c := &st.Channels[0]
	if d := c.Destination(); strings.Contains(d, testOGKey) || !strings.HasSuffix(d, "(opsgenie)") {
		t.Errorf("destination %q", d)
	}
	now := time.Unix(1762900000, 0)
	fire := c.decorate(Alert{Event: "firing", FindingKey: "5f0c2a9d8e7b6a5f4e3d2c1b0a9f8e7d", Instance: "erp/01", Severity: "critical", Source: "pg_gather", Setting: "autovacuum", Value: "off", Suggested: "on"}, now)
	esc := fire
	esc.Event = "escalated"
	res := fire
	res.Event = "resolved"
	clr := fire
	clr.Event = "cleared"
	ctx := context.Background()
	for _, a := range []Alert{fire, esc, res, clr} {
		if err := c.sender.send(ctx, Message{Channel: "og", SentAt: now, Alerts: []Alert{a}}); err != nil {
			t.Fatalf("%s: %v", a.Event, err)
		}
	}
	alias := "pgvigil:erp%2F01:5f0c2a9d8e7b6a5f4e3d2c1b0a9f8e7d"
	want := []struct{ method, path, query string }{
		{"POST", "/v2/alerts", ""}, {"POST", "/v2/alerts", ""}, {"PUT", "/v2/alerts/" + alias + "/priority", "identifierType=alias"},
		{"POST", "/v2/alerts/" + alias + "/close", "identifierType=alias"}, {"POST", "/v2/alerts/" + alias + "/close", "identifierType=alias"},
	}
	if len(got) != len(want) {
		t.Fatalf("%d requests, want %d: %+v", len(got), len(want), got)
	}
	for i, w := range want {
		g := got[i]
		if g.method != w.method || g.path != w.path || g.query != w.query || g.auth != "GenieKey "+testOGKey {
			t.Errorf("request %d: %s %s ?%s auth %q; want %s %s ?%s", i, g.method, g.path, g.query, g.auth, w.method, w.path, w.query)
		}
	}
	b := got[0].body
	if b["alias"] != "pgvigil:erp/01:5f0c2a9d8e7b6a5f4e3d2c1b0a9f8e7d" || b["priority"] != "P1" || b["entity"] != "erp/01" {
		t.Errorf("create body %v", b)
	}
	if d, _ := b["details"].(map[string]any); d["url"] != fire.URL || d["suggested"] != "on" {
		t.Errorf("details %v", b["details"])
	}
	if msg, _ := b["message"].(string); msg != "erp/01: pg_gather autovacuum" {
		t.Errorf("message %q", msg)
	}
	if got[2].body["priority"] != "P1" {
		t.Errorf("priority body %v", got[2].body)
	}
	if n, _ := got[4].body["note"].(string); !strings.Contains(n, "cleared without a fix") {
		t.Errorf("cleared note %q", n)
	}
	// an error answer: the key never reaches the error text
	mu.Lock()
	status = http.StatusUnprocessableEntity
	mu.Unlock()
	err = c.sender.send(ctx, Message{Alerts: []Alert{fire}})
	if err == nil || strings.Contains(err.Error(), testOGKey) || !strings.Contains(err.Error(), "<api key>") {
		t.Errorf("error %v", err)
	}
	// refusals at load
	for yaml, want := range map[string]string{
		"{api_key: env:PGV_TEST_OG, url: https://api.example.org}": "api.opsgenie.com or api.eu.opsgenie.com",
		"{api_key: abc}":                                     "env:NAME or file:/path",
		"{api_key: env:PGV_TEST_OG_BAD}":                     "not an API integration key",
		"{api_key: env:PGV_TEST_OG, url: 'http://10.1.2.3'}": "api.opsgenie.com or api.eu.opsgenie.com",
	} {
		t.Setenv("PGV_TEST_OG_BAD", "short")
		_, err := Parse([]byte("alerts: [{name: og, kind: opsgenie, opsgenie: " + yaml + "}]"))
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v, want %q", yaml, err, want)
		}
	}
	if _, err := Parse([]byte("alerts: [{name: og, kind: opsgenie, recovery: false, opsgenie: {api_key: env:PGV_TEST_OG}}]")); err == nil || !strings.Contains(err.Error(), "sends every recovery") {
		t.Errorf("recovery false: %v", err)
	}
	if _, err := Parse([]byte("alerts: [{name: og, kind: opsgenie, opsgenie: {api_key: env:PGV_TEST_OG, url: https://api.eu.opsgenie.com}}]")); err != nil {
		t.Errorf("the EU host: %v", err)
	}
}

// TestChatBudgets: a Discord or Google Chat message stays under its text limit by carrying fewer alerts, never a cut
// line; every alert goes out once.
func TestChatBudgets(t *testing.T) {
	var mu sync.Mutex
	posts := map[string][]map[string]any{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		var m map[string]any
		if err := json.Unmarshal(b, &m); err != nil {
			t.Errorf("body: %v", err)
		}
		mu.Lock()
		posts[r.URL.Path] = append(posts[r.URL.Path], m)
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	t.Setenv("PGV_TEST_DC", srv.URL+"/discord")
	t.Setenv("PGV_TEST_GC", srv.URL+"/gchat")
	st, err := Parse([]byte("alerts: [{name: dc, kind: webhook, webhook: {url: env:PGV_TEST_DC, format: discord}}, {name: gc, kind: webhook, webhook: {url: env:PGV_TEST_GC, format: googlechat}}]"))
	if err != nil {
		t.Fatal(err)
	}
	var alerts []Alert
	for i := 0; i < 30; i++ {
		alerts = append(alerts, Alert{Event: "firing", FindingKey: strings.Repeat("a", 31) + string(rune('a'+i%26)), Instance: "erp01", Severity: "warning", Source: "s",
			Setting: "x", Value: strings.Repeat("v", 450) + " @everyone"})
	}
	for i, path := range []string{"/discord", "/gchat"} {
		c := &st.Channels[i]
		b := c.sender.(budgeted).budget()
		n := 0
		for _, batch := range batchesWithin(alerts, c.sender.perAlert(), b) {
			n += len(batch)
			if err := c.sender.send(context.Background(), Message{Channel: c.Name, Alerts: batch}); err != nil {
				t.Fatal(err)
			}
		}
		if n != len(alerts) {
			t.Errorf("%s: %d alerts batched, want %d", path, n, len(alerts))
		}
		limit, field := discordLimit, "content"
		if path == "/gchat" {
			limit, field = googleChatLimit, "text"
		}
		lines := 0
		for _, p := range posts[path] {
			s, _ := p[field].(string)
			if len([]rune(s)) > limit {
				t.Errorf("%s: a post of %d characters", path, len([]rune(s)))
			}
			lines += strings.Count(s, "\n")
		}
		if lines != len(alerts) {
			t.Errorf("%s: %d alert lines in %d posts, want %d", path, lines, len(posts[path]), len(alerts))
		}
		if len(posts[path]) < 2 {
			t.Errorf("%s: %d post(s): the budget did not split", path, len(posts[path]))
		}
	}
	if am, _ := posts["/discord"][0]["allowed_mentions"].(map[string]any); am == nil || len(am["parse"].([]any)) != 0 {
		t.Errorf("discord allowed_mentions %v", posts["/discord"][0]["allowed_mentions"])
	}
}

// fakeQuerier answers the cap's one read (the alerts sent in the last hour) with its row
type fakeQuerier struct{ row fakeRow }

func (f fakeQuerier) QueryRow(context.Context, string, ...any) pgx.Row { return f.row }

func TestCapHold(t *testing.T) {
	c := &Channel{Name: "x", MaxPerHour: 10}
	send := []Alert{
		{Event: "repeat", FindingKey: "r", Severity: "critical"},
		{Event: "resolved", FindingKey: "z", Severity: "warning"},
		{Event: "firing", FindingKey: "w", Severity: "warning"},
		{Event: "firing", FindingKey: "c", Severity: "critical"},
		{Event: "escalated", FindingKey: "e", Severity: "critical"},
	}
	held, err := c.capHold(context.Background(), fakeQuerier{fakeRow{v: 8}}, time.Now(), &send)
	if err != nil {
		t.Fatal(err)
	}
	keys := func(a []Alert) string {
		var k []string
		for _, x := range a {
			k = append(k, x.FindingKey)
		}
		return strings.Join(k, ",")
	}
	if keys(send) != "c,e" || keys(held) != "w,z,r" {
		t.Errorf("sent %s, held %s; want c,e and w,z,r", keys(send), keys(held))
	}
	send = []Alert{{Event: "firing", FindingKey: "a", Severity: "info"}}
	held, _ = c.capHold(context.Background(), fakeQuerier{fakeRow{v: 3}}, time.Now(), &send)
	if len(held) != 0 || len(send) != 1 {
		t.Errorf("under the cap: sent %d held %d", len(send), len(held))
	}
	send = []Alert{{Event: "firing", FindingKey: "a", Severity: "info"}}
	held, _ = c.capHold(context.Background(), fakeQuerier{fakeRow{v: 12}}, time.Now(), &send)
	if len(held) != 1 || len(send) != 0 {
		t.Errorf("over the cap: sent %d held %d", len(send), len(held))
	}
	if _, err := Parse([]byte("alerts: [{name: d, kind: file, max_per_hour: -1, file: {dir: /tmp}}]")); err == nil {
		t.Error("max_per_hour -1 accepted")
	}
}

func TestTestMessage(t *testing.T) {
	t.Setenv("PGV_TEST_PD", testPDKey)
	st, err := Parse([]byte("alerts_base_url: https://p.example.org\nalerts: [{name: pd, kind: pagerduty, pagerduty: {routing_key: env:PGV_TEST_PD}}, {name: d, kind: file, file: {dir: /tmp}}]"))
	if err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, 11, 11, 23, 0, 0, 0, time.UTC)
	pd := testAlerts(&st.Channels[0], testRequest{id: 7, channel: "pd", by: "allen", at: at})
	fd := testAlerts(&st.Channels[1], testRequest{id: 8, channel: "d", by: "allen", at: at})
	if len(pd) != 2 || pd[0].Event != "test" || pd[1].Event != "resolved" || pd[0].FindingKey != "test-7" || pd[1].FindingKey != "test-7" {
		t.Errorf("pagerduty's test: %+v", pd)
	}
	if len(fd) != 1 {
		t.Errorf("file's test: %d alerts", len(fd))
	}
	l := fd[0].Line()
	if !strings.HasPrefix(l, "[TEST] pgvigil: a test message on channel d, asked by allen at 2026-11-11 23:00:00 UTC") || !strings.HasSuffix(l, " https://p.example.org/#/alerts") {
		t.Errorf("test line %q", l)
	}
	if s := (Message{Alerts: fd}).Summary(); s != "pgvigil: test message" {
		t.Errorf("summary %q", s)
	}
	if ev := pagerDutyEvent(testPDKey, pd[0]); ev["event_action"] != "trigger" {
		t.Errorf("the test's event %v", ev["event_action"])
	}
}
