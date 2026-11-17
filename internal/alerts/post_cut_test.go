package alerts

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"unicode/utf8"
)

// B20-4 (review-26 go1 N1 / N3): a chat format's text over its limit is cut by line, at a character, never the link;
// Google Chat's mention guard is applied before it is measured; the link's slashes; the reserved keys of the json body.
func TestChannelPostCut(t *testing.T) {
	var got []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		var v map[string]any
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &v)
		got = append(got, v)
	}))
	defer srv.Close()
	const link = "https://pgvigil.example.org/#/checks?w=24h"
	long := Post{Kind: "daily checks", Title: "x" + strings.Repeat("€", 700), Lines: []string{"1. " + strings.Repeat("<users/é", 400)}, Route: "#/checks?w=24h"}
	for _, f := range []struct {
		format, key string
		limit       int
	}{{"discord", "content", discordLimit}, {"googlechat", "text", googleChatLimit}} {
		got = nil
		c := &Channel{Name: f.format, Kind: "webhook", sender: webhookFor(t, srv.URL+"/hook", f.format), base: "https://pgvigil.example.org"}
		if err := c.Post(context.Background(), long); err != nil {
			t.Fatalf("%s: %v", f.format, err)
		}
		s, _ := got[0][f.key].(string)
		switch {
		case strings.ContainsRune(s, utf8.RuneError):
			t.Errorf("%s: a character cut in two", f.format)
		case !strings.HasSuffix(s, "\n"+link):
			t.Errorf("%s: the link is not the last line: ...%q", f.format, s[max(0, len(s)-60):])
		case len(s) > f.limit:
			t.Errorf("%s: %d bytes, over its %d", f.format, len(s), f.limit)
		case f.format == "googlechat" && strings.Contains(s, "<users/"):
			t.Errorf("googlechat: a mention left in")
		}
	}
	// the link's slashes: a base without one, a route with one; a missing base on a chat format = no link line
	got = nil
	c := &Channel{Name: "s", Kind: "webhook", sender: webhookFor(t, srv.URL+"/hook", "slack"), base: "https://pgvigil.example.org"}
	if err := c.Post(context.Background(), Post{Title: "t", Route: "/#/checks?w=24h"}); err != nil {
		t.Fatal(err)
	}
	if s, _ := got[0]["text"].(string); s != "*t*\n"+link {
		t.Errorf("slack with a slashed route: %q", s)
	}
	c.base = ""
	if err := c.Post(context.Background(), Post{Title: "t", Lines: []string{"l"}, Route: "#/checks"}); err != nil {
		t.Fatal(err)
	}
	if s, _ := got[1]["text"].(string); s != "*t*\nl" {
		t.Errorf("slack with no base: %q", s)
	}
	// the json body's reserved keys are the post's, whatever Fields holds
	c = &Channel{Name: "j", Kind: "webhook", sender: webhookFor(t, srv.URL+"/hook", "json"), base: "https://pgvigil.example.org"}
	if err := c.Post(context.Background(), Post{Kind: "daily checks", Title: "t", Route: "#/checks?w=24h",
		Fields: map[string]any{"source": "x", "summary": "x", "text": "x", "link": "x", "kind": "x", "n": 1}}); err != nil {
		t.Fatal(err)
	}
	j := got[2]
	if j["source"] != "pgvigil" || j["summary"] != "t" || j["text"] != "t\n"+link || j["link"] != link || j["kind"] != "daily checks" || j["n"] != float64(1) {
		t.Errorf("json body %v", j)
	}
}
