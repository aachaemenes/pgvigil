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
)

const testPDKey = "0123456789abcdef0123456789abcdef"

// TestPagerDutyEvents: a firing alert triggers and its recovery resolves under one dedup key; the routing key reaches
// the API in the body and nowhere else (not the destination, not an error).
func TestPagerDutyEvents(t *testing.T) {
	var mu sync.Mutex
	var got []map[string]any
	status := http.StatusAccepted
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		var ev map[string]any
		if err := json.Unmarshal(b, &ev); err != nil {
			t.Errorf("body is not JSON: %v", err)
		}
		mu.Lock()
		got = append(got, ev)
		st := status
		mu.Unlock()
		w.WriteHeader(st)
		if st >= 400 {
			_, _ = io.WriteString(w, `{"status":"invalid event","message":"Event object is invalid","errors":["routing_key `+testPDKey+` bad"]}`)
			return
		}
		_, _ = io.WriteString(w, `{"status":"success","message":"Event processed"}`)
	}))
	defer srv.Close()
	t.Setenv("PGV_TEST_PD", testPDKey)
	st, err := Parse([]byte("alerts: [{name: pd, kind: pagerduty, min_severity: info, pagerduty: {routing_key: env:PGV_TEST_PD, url: " + srv.URL + "/v2/enqueue}}]"))
	if err != nil {
		t.Fatal(err)
	}
	c := &st.Channels[0]
	if d := c.Destination(); strings.Contains(d, testPDKey) || !strings.HasSuffix(d, "(pagerduty)") {
		t.Errorf("destination %q", d)
	}
	if !c.sender.perAlert() {
		t.Error("pagerduty must send one event per alert")
	}
	at := time.Date(2026, 11, 11, 17, 0, 0, 0, time.UTC)
	fire := Alert{Event: "firing", FindingKey: "autovacuum is off", Instance: "erp01", Severity: "critical", Source: "settings",
		Setting: "autovacuum", Value: "off", Suggested: "on", FindingAt: &at}
	ctx := context.Background()
	if err := c.sender.send(ctx, Message{Channel: "pd", SentAt: at, Alerts: []Alert{fire}}); err != nil {
		t.Fatal(err)
	}
	res := fire
	res.Event = "resolved"
	if err := c.sender.send(ctx, Message{Channel: "pd", SentAt: at, Alerts: []Alert{res}}); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("events %d, want 2", len(got))
	}
	if got[0]["event_action"] != "trigger" || got[1]["event_action"] != "resolve" {
		t.Errorf("actions %v, %v", got[0]["event_action"], got[1]["event_action"])
	}
	if got[0]["dedup_key"] != "pgvigil:erp01:autovacuum is off" || got[1]["dedup_key"] != got[0]["dedup_key"] {
		t.Errorf("dedup keys %v, %v", got[0]["dedup_key"], got[1]["dedup_key"])
	}
	if got[0]["routing_key"] != testPDKey {
		t.Errorf("routing key not sent")
	}
	p, _ := got[0]["payload"].(map[string]any)
	if p["severity"] != "critical" || p["source"] != "erp01" || !strings.Contains(p["summary"].(string), "autovacuum") {
		t.Errorf("payload %v", p)
	}
	if _, ok := got[1]["payload"]; ok {
		t.Error("a resolve carries no payload")
	}
	// a refused event: the error names the fault, never the key (even when the answer echoes it)
	mu.Lock()
	status = http.StatusBadRequest
	mu.Unlock()
	err = c.sender.send(ctx, Message{Channel: "pd", SentAt: at, Alerts: []Alert{fire}})
	if err == nil || strings.Contains(err.Error(), testPDKey) || !strings.Contains(err.Error(), "invalid") {
		t.Errorf("refused event error %v", err)
	}
	mu.Lock()
	status = http.StatusTooManyRequests
	mu.Unlock()
	if err := c.sender.send(ctx, Message{Channel: "pd", SentAt: at, Alerts: []Alert{fire}}); err == nil || !strings.Contains(err.Error(), "429") {
		t.Errorf("rate limit error %v", err)
	}
}

// TestPagerDutyRefuses: the key only through env: or file:, a real key shape, PagerDuty's hosts only (plain http to
// loopback alone), and no channel that would leave incidents open.
func TestPagerDutyRefuses(t *testing.T) {
	t.Setenv("PGV_TEST_PD", testPDKey)
	t.Setenv("PGV_TEST_PD_SHORT", "abc")
	for name, c := range map[string]string{
		"inline key":  `{name: a, kind: pagerduty, pagerduty: {routing_key: ` + testPDKey + `}}`,
		"short key":   `{name: a, kind: pagerduty, pagerduty: {routing_key: env:PGV_TEST_PD_SHORT}}`,
		"other host":  `{name: a, kind: pagerduty, pagerduty: {routing_key: env:PGV_TEST_PD, url: "https://events.example.org/v2/enqueue"}}`,
		"plain http":  `{name: a, kind: pagerduty, pagerduty: {routing_key: env:PGV_TEST_PD, url: "http://events.pagerduty.com/v2/enqueue"}}`,
		"no recovery": `{name: a, kind: pagerduty, recovery: false, pagerduty: {routing_key: env:PGV_TEST_PD}}`,
		"no block":    `{name: a, kind: pagerduty, file: {dir: /tmp}}`,
		"two blocks":  `{name: a, kind: pagerduty, file: {dir: /tmp}, pagerduty: {routing_key: env:PGV_TEST_PD}}`,
	} {
		if _, err := Parse([]byte("alerts: [" + c + "]")); err == nil {
			t.Errorf("%s: accepted", name)
		} else if strings.Contains(err.Error(), testPDKey) {
			t.Errorf("%s: the error shows the key", name)
		}
	}
	st, err := Parse([]byte(`alerts: [{name: a, kind: pagerduty, pagerduty: {routing_key: env:PGV_TEST_PD}}, {name: b, kind: pagerduty, pagerduty: {routing_key: env:PGV_TEST_PD, url: "https://events.eu.pagerduty.com/v2/enqueue"}}]`))
	if err != nil {
		t.Fatal(err)
	}
	if d := st.Channels[0].Destination(); d != "https://events.pagerduty.com (pagerduty)" {
		t.Errorf("default destination %q", d)
	}
	if d := st.Channels[1].Destination(); d != "https://events.eu.pagerduty.com (pagerduty)" {
		t.Errorf("EU destination %q", d)
	}
}

// TestDedupKeyLong: a key past the API's 255 bytes becomes a stable hash.
func TestDedupKeyLong(t *testing.T) {
	a := Alert{Instance: "erp01", FindingKey: strings.Repeat("x", 300)}
	k := dedupKey(a)
	if len(k) > maxDedupKey || k != dedupKey(a) || !strings.HasPrefix(k, "pgvigil:") {
		t.Errorf("dedup key %q (%d bytes)", k, len(k))
	}
}
