package mcp

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// TestReadWindowNote: a window up to a year and an hour is asked (hours 1..8785, the API's maxWindow); a statements
// read the API cut to its reach (read_from / read_to beside its rows) comes back with what was read and a note, never
// as the whole window's numbers, in the page's words; a plans read (a struct reply: the cut table is its 'plans' field)
// the same; one inside its reach carries no note; 8786 hours is refused.
func TestReadWindowNote(t *testing.T) {
	cut := true
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/instances":
			_ = json.NewEncoder(w).Encode(map[string]any{"columns": []string{"instance_id", "name"}, "rows": [][]any{{1, "Alpha"}}})
		case "/api/statements":
			v := map[string]any{"columns": []string{"queryid", "query"}, "rows": [][]any{{"1", "select 1"}}}
			if cut {
				v["read_from"], v["read_to"] = "2026-10-13T19:00:00Z", "2026-11-13T20:00:00Z"
			}
			_ = json.NewEncoder(w).Encode(v)
		case "/api/plans":
			p := map[string]any{"columns": []string{"plan_id", "queryid"}, "rows": [][]any{{7, "1"}}}
			if cut {
				p["read_from"], p["read_to"] = "2026-10-13T19:00:00Z", "2026-11-13T20:00:00Z"
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"buttons": map[string]any{}, "shape": nil, "plans": p})
		default:
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"no such endpoint"}`))
		}
	})
	s := New(api, "test")
	got, _, _ := exchange(t, s,
		call(1, "top_statements", `{"instance":"Alpha","hours":8760}`),
		call(2, "top_statements", `{"instance":"Alpha","hours":8785}`),
		call(3, "top_statements", `{"instance":"Alpha","hours":8786}`),
		call(5, "plan_findings", `{"instance":"Alpha","hours":8760}`))
	words := `"read_note": "This list reads the newest 31 days of this window: 2026-10-13T19:00:00Z to 2026-11-13T20:00:00Z."`
	for id, want := range map[string][]string{"1": {`"read_from": "2026-10-13T19:00:00Z"`, `"read_to": "2026-11-13T20:00:00Z"`, words}, "2": {`"read_note"`},
		"5": {`"read_from": "2026-10-13T19:00:00Z"`, words}} {
		txt, isErr := text(t, got[id])
		for _, w := range want {
			if isErr || !strings.Contains(txt, w) {
				t.Errorf("call %s: want %s, got (error %v) %s", id, w, isErr, txt)
			}
		}
	}
	if txt, isErr := text(t, got["3"]); !isErr || !strings.Contains(txt, "hours must be an integer 1..8785") {
		t.Errorf("8786 hours: want refused with 'hours must be an integer 1..8785', got (error %v) %s", isErr, txt)
	}
	cut = false
	got, _, _ = exchange(t, s, call(4, "top_statements", `{"instance":"Alpha","hours":24}`))
	if txt, isErr := text(t, got["4"]); isErr || strings.Contains(txt, "read_note") || strings.Contains(txt, "read_from") {
		t.Errorf("24 hours, not cut: want no read note, got (error %v) %s", isErr, txt)
	}
}
