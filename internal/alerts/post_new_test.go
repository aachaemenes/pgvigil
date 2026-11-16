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
)

// B20-4: a channel's Post - a short text outside the alert cycle (the Daily checks mail's counts) - on a webhook
// channel in each format, with the page's link after alerts_base_url; a channel of another kind refuses it in words.
func TestChannelPostFormats(t *testing.T) {
	var mu sync.Mutex
	var got []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var v map[string]any
		b, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(b, &v); err != nil || r.Header.Get("Content-Type") != "application/json" {
			http.Error(w, "bad", 400)
			return
		}
		mu.Lock()
		got = append(got, v)
		mu.Unlock()
	}))
	defer srv.Close()
	p := Post{Kind: "daily checks", Title: "Daily checks 2026-11-16: 3 critical, 4 warnings on 12 instances",
		Lines: []string{"1. sql01: 2 critical", "2. pg02: 1 critical, 4 warnings"}, Route: "#/checks?w=24h",
		Fields: map[string]any{"critical": 3, "warnings": 4, "instances": 12, "kind": "not this"}}
	const link = "https://pgvigil.example.org/#/checks?w=24h"
	formats := []string{"json", "slack", "teams", "discord", "googlechat"}
	for _, f := range formats {
		c := &Channel{Name: "hook-" + f, Kind: "webhook", sender: webhookFor(t, srv.URL+"/hook/token", f), base: "https://pgvigil.example.org/"}
		if err := c.Post(context.Background(), p); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
	}
	if len(got) != len(formats) {
		t.Fatalf("posts %d, want %d", len(got), len(formats))
	}
	j := got[0]
	if j["source"] != "pgvigil" || j["kind"] != "daily checks" || j["summary"] != p.Title || j["link"] != link || j["critical"] != float64(3) || j["instances"] != float64(12) {
		t.Errorf("json body %v", j)
	}
	if txt, _ := j["text"].(string); !strings.HasPrefix(txt, p.Title+"\n1. sql01: 2 critical\n2. pg02") || !strings.HasSuffix(txt, link) {
		t.Errorf("json text %q", j["text"])
	}
	for i, key := range map[int]string{1: "text", 3: "content", 4: "text"} {
		s, _ := got[i][key].(string)
		if !strings.Contains(s, p.Title) || !strings.Contains(s, "2. pg02: 1 critical, 4 warnings") || !strings.Contains(s, link) {
			t.Errorf("%s body %v", formats[i], got[i])
		}
	}
	if got[2]["type"] != "message" || len(got[2]["attachments"].([]any)) != 1 || !strings.Contains(mustJSON(t, got[2]), link) {
		t.Errorf("teams body %v", got[2])
	}
	// no alerts_base_url: no link, the rest the same
	c := &Channel{Name: "hook", Kind: "webhook", sender: webhookFor(t, srv.URL+"/hook/token", "json")}
	if err := c.Post(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	if l, there := got[len(got)-1]["link"]; there && l != "" {
		t.Errorf("a link with no alerts_base_url: %v", l)
	}
	for _, k := range []string{"smtp", "file", "pagerduty"} {
		err := (&Channel{Name: "x", Kind: k}).Post(context.Background(), p)
		if err == nil || !strings.Contains(err.Error(), "channel x is a "+k+" channel: a post goes to a webhook channel") {
			t.Errorf("a %s channel's post: %v", k, err)
		}
	}
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
