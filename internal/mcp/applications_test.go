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

func allTools(t *testing.T, h http.Handler) string {
	t.Helper()
	s := New(h, "test")
	_, _, raw := exchange(t, s,
		call(1, "fleet_summary", `{}`),
		call(2, "instance_findings", `{"instance":"alpha"}`),
		call(3, "blocking_chain", `{"instance":1,"at":"2026-11-09T10:00:00Z"}`),
		call(4, "top_statements", `{"instance":"beta","hours":6,"limit":5}`),
		call(5, "plan_findings", `{"plan_id":7}`),
		call(6, "plan_findings", `{"instance":"Alpha"}`),
		call(7, "table_state", `{"instance":"Alpha","table":"orders"}`),
		call(8, "storage_forecast", `{}`),
		call(9, "storage_forecast", `{"instance":"beta"}`),
	)
	return raw
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
