package web

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestInvestigationsOffDoorAnswers200: with agents.enabled off (the default) the list a page reads on every load is a
// plain answer, not an error - GET /api/investigations (and ?state=open, the tab strip's probe) answers 200 with
// enabled false, the door's words and no rows, so a default install logs no 404 on every page. One request (?id=) and
// the three writes keep the refusal: there is nothing to show or write on an off door.
func TestInvestigationsOffDoorAnswers200(t *testing.T) {
	s := &Server{log: discardLog()} // agents false: the door off, no store needed
	for _, target := range []string{"/api/investigations", "/api/investigations?state=open", "/api/investigations?instance=3"} {
		rec := httptest.NewRecorder()
		s.Investigations(rec, httptest.NewRequest(http.MethodGet, target, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("GET %s on an off door: HTTP %d (%s), want 200", target, rec.Code, strings.TrimSpace(rec.Body.String()))
		}
		var got struct {
			Enabled  *bool            `json:"enabled"`
			Rows     []map[string]any `json:"rows"`
			Writable bool             `json:"writable"`
			Said     string           `json:"said"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatalf("GET %s: the answer is not JSON: %v (%s)", target, err, rec.Body.String())
		}
		if got.Enabled == nil || *got.Enabled {
			t.Errorf("GET %s: enabled %v, want false", target, got.Enabled)
		}
		if got.Rows == nil || len(got.Rows) != 0 {
			t.Errorf("GET %s: rows %v, want an empty list", target, got.Rows)
		}
		if got.Writable {
			t.Errorf("GET %s: writable true on an off door", target)
		}
		if got.Said != agentsOff {
			t.Errorf("GET %s: said %q, want the door's words %q", target, got.Said, agentsOff)
		}
		if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
			t.Errorf("GET %s: Cache-Control %q, want no-store (as the on door's list)", target, cc)
		}
	}
	refused := []struct {
		name string
		call func(http.ResponseWriter, *http.Request)
		req  *http.Request
	}{
		{"GET ?id=", s.Investigations, httptest.NewRequest(http.MethodGet, "/api/investigations?id=1", nil)},
		{"POST ask", s.InvestigationAsk, httptest.NewRequest(http.MethodPost, "/api/investigations", strings.NewReader(`{"kind":"ask","question":"q"}`))},
		{"POST close", s.InvestigationClose, httptest.NewRequest(http.MethodPost, "/api/investigations/close", strings.NewReader(`{"id":1,"reason":"r"}`))},
		{"POST run", s.InvestigationRun, httptest.NewRequest(http.MethodPost, "/api/investigations/run", strings.NewReader(`{"id":1}`))},
	}
	for _, c := range refused {
		rec := httptest.NewRecorder()
		c.call(rec, c.req)
		if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), agentsOffWordsPrefix) {
			t.Errorf("%s on an off door: HTTP %d %s, want 404 with the door's words", c.name, rec.Code, strings.TrimSpace(rec.Body.String()))
		}
	}
}

// agentsOffWordsPrefix is the start of agentsOff the web side matches (web/src/investigate.ts agentsOffWords).
const agentsOffWordsPrefix = "agents.enabled is off"
