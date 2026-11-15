package mcp

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// Row A11 (task 310): contacts are personal data - no MCP tool reads an application's contacts or answers a contact's
// name or address. The fake API answers the applications' paths with a planted team and its group address; every
// tool is called as TestTools calls them; no request reaches /api/applications and no answer carries the planted
// values. The check itself is shown to bite: the same values planted in an answer a tool does read (/api/findings)
// are seen.
const plantedTeam, plantedMail = "Planted Owners 310", "planted-owners.310@example.org"

func plantedAPI(t *testing.T, seen *[]string, inFindings bool) http.Handler {
	t.Helper()
	base := fakeAPI(t, seen)
	planted := map[string]any{"columns": []string{"contact_id", "role", "kind", "name", "email"},
		"rows": [][]any{{1, "business owner", "team", plantedTeam, plantedMail}}}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/api/applications"):
			*seen = append(*seen, r.Method+" "+r.URL.String())
			_ = json.NewEncoder(w).Encode(map[string]any{"contacts": planted, "applications": planted})
		case inFindings && r.URL.Path == "/api/findings" && r.URL.Query().Get("instance") != "2":
			*seen = append(*seen, r.Method+" "+r.URL.String())
			_ = json.NewEncoder(w).Encode(planted)
		default:
			base.ServeHTTP(w, r)
		}
	})
}

// toolCalls: every tool with one or two argument shapes each; TestEveryToolCalled holds it to tools/list.
var toolCalls = []struct{ name, args string }{
	{"fleet_summary", `{}`},
	{"instance_findings", `{"instance":"alpha"}`},
	{"blocking_chain", `{"instance":1,"at":"2026-11-09T10:00:00Z"}`},
	{"top_statements", `{"instance":"beta","hours":6,"limit":5}`},
	{"plan_findings", `{"plan_id":7}`},
	{"plan_findings", `{"instance":"Alpha"}`},
	{"table_state", `{"instance":"Alpha","table":"orders"}`},
	{"storage_forecast", `{}`},
	{"storage_forecast", `{"instance":"beta"}`},
	{"statement_everywhere", `{"query_hash":"0x1A2B","hours":6}`},
	{"find_statements", `{"text":"orders"}`},
	{"find_statements", `{"text":"orders","instance":"Alpha"}`},
}

func allTools(t *testing.T, h http.Handler) string {
	t.Helper()
	s := New(h, "test")
	lines := make([]string, 0, len(toolCalls))
	for i, c := range toolCalls {
		lines = append(lines, call(i+1, c.name, c.args))
	}
	_, _, raw := exchange(t, s, lines...)
	return raw
}

// Review B, m6: A11 calls every tool the server lists - a tool added later and not called here fails this test.
func TestEveryToolCalled(t *testing.T) {
	var seen []string
	got, _, _ := exchange(t, New(fakeAPI(t, &seen), "test"), `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	called := map[string]bool{}
	for _, c := range toolCalls {
		called[c.name] = true
	}
	list, _ := got["1"]["result"].(map[string]any)["tools"].([]any)
	if len(list) == 0 {
		t.Fatal("tools/list answered no tool")
	}
	for _, x := range list {
		if n, _ := x.(map[string]any)["name"].(string); !called[n] {
			t.Errorf("tools/list names %q, which A11 (TestNoToolAnswersContacts) never calls", n)
		}
	}
}

func TestNoToolAnswersContacts(t *testing.T) {
	var seen []string
	raw := allTools(t, plantedAPI(t, &seen, false))
	for _, p := range seen {
		if strings.Contains(p, "/api/applications") {
			t.Errorf("a tool read %s", p)
		}
	}
	if strings.Contains(raw, plantedTeam) || strings.Contains(raw, plantedMail) {
		t.Errorf("a tool answered a planted contact: %s", raw)
	}
	if len(seen) == 0 {
		t.Fatal("no tool reached the API: the check saw nothing")
	}
	// the check bites: the same values in an answer a tool reads are seen
	var seen2 []string
	if raw2 := allTools(t, plantedAPI(t, &seen2, true)); !strings.Contains(raw2, plantedTeam) && !strings.Contains(raw2, plantedMail) {
		t.Errorf("planted in /api/findings, the values were not seen in any answer: the check cannot fail")
	}
}
