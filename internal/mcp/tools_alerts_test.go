package mcp

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

// task 403b: alert_history reads one instance's alerts and findings history over at most 90 days.

func TestAlertHistory(t *testing.T) {
	var seen, asked []string
	base := fakeAPI(t, &seen)
	tbl := func(cols []string, rows ...[]any) map[string]any {
		return map[string]any{"columns": cols, "rows": rows}
	}
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/alertscope" {
			base.ServeHTTP(w, r)
			return
		}
		asked = append(asked, r.URL.RawQuery)
		q := r.URL.Query()
		switch q.Get("part") {
		case "alerts":
			_ = json.NewEncoder(w).Encode(map[string]any{"alerts": tbl([]string{"fired_at", "severity", "setting", "instance_id", "cut"},
				[]any{"2026-11-14T10:00:00Z", "warning", "a blocking chain", 2, false},
				[]any{"2026-11-13T10:00:00Z", "critical", "server unreachable", 2, false})})
		case "history":
			_ = json.NewEncoder(w).Encode(map[string]any{"history": tbl([]string{"snapshot_at", "event", "instance_id", "cut"},
				[]any{"2026-11-14T09:00:00Z", "open", 2, true},
				[]any{"2026-11-14T10:00:00Z", "sample", 2, true})})
		default:
			w.WriteHeader(http.StatusBadRequest)
		}
	})
	s := New(h, "test")
	ctx := context.Background()
	out, err := alertHistory(ctx, s, map[string]any{"instance": "beta", "hours": json.Number("48")})
	if err != nil {
		t.Fatalf("alert_history beta 48 h: %v", err)
	}
	m := out.(map[string]any)
	if len(asked) != 2 {
		t.Fatalf("asked %v, want the parts alerts and history", asked)
	}
	for i, part := range []string{"alerts", "history"} {
		if !strings.Contains(asked[i], "part="+part) || !strings.Contains(asked[i], "instance_id=2") {
			t.Errorf("request %d %q: want part=%s and instance_id=2", i, asked[i], part)
		}
	}
	from, _ := time.Parse(time.RFC3339, m["from"].(string))
	to, _ := time.Parse(time.RFC3339, m["to"].(string))
	if to.Sub(from) != 48*time.Hour {
		t.Errorf("window %s to %s, want 48 hours", m["from"], m["to"])
	}
	alerts := m["alerts"].([]map[string]any)
	if len(alerts) != 2 || alerts[0]["setting"] != "a blocking chain" {
		t.Fatalf("alerts %v, want the two rows newest first", alerts)
	}
	for _, r := range alerts {
		if _, ok := r["cut"]; ok {
			t.Errorf("a row keeps the cut column: %v", r)
		}
		if _, ok := r["instance_id"]; ok {
			t.Errorf("a row keeps the instance_id column: %v", r)
		}
	}
	if _, ok := m["alerts_note"]; ok {
		t.Errorf("alerts not cut, but noted: %v", m["alerts_note"])
	}
	// the API's history is oldest first; the tool turns it newest first so the reply's row cap keeps the recent end
	if hist := m["findings_history"].([]map[string]any); len(hist) != 2 || hist[0]["event"] != "sample" || hist[1]["event"] != "open" {
		t.Errorf("findings history %v, want the two rows newest first", hist)
	}
	if n, _ := m["findings_history_note"].(string); !strings.Contains(n, "newest 2 rows") {
		t.Errorf("findings history cut: note %q, want the newest rows named", n)
	}
	for name, a := range map[string]map[string]any{
		"hours 2161":   {"instance": "beta", "hours": json.Number("2161")},
		"91 days":      {"instance": "beta", "from": "2026-08-01T00:00:00Z", "to": "2026-10-31T00:00:00Z"},
		"to before":    {"instance": "beta", "from": "2026-11-02T00:00:00Z", "to": "2026-11-01T00:00:00Z"},
		"no instance":  {"hours": json.Number("1")},
		"unknown name": {"instance": "gamma"},
	} {
		asked = nil
		if _, err := alertHistory(ctx, s, a); err == nil {
			t.Errorf("%s: no error", name)
		}
		if len(asked) != 0 {
			t.Errorf("%s: the API was asked %v", name, asked)
		}
	}
	if _, err := alertHistory(ctx, s, map[string]any{"instance": "beta", "from": "2026-08-03T00:00:00Z", "to": "2026-11-01T00:00:00Z"}); err != nil {
		t.Errorf("exactly 90 days: %v", err)
	}
}

// the tool's list entry: its name, the instance it requires and its hours bound (tools() lists it).
func TestAlertToolListed(t *testing.T) {
	ts := alertTools()
	if len(ts) != 1 || ts[0].Name != "alert_history" || ts[0].run == nil {
		t.Fatalf("alertTools %v, want alert_history with its run", ts)
	}
	sc := ts[0].schema()
	if req, _ := sc["required"].([]string); len(req) != 1 || req[0] != "instance" {
		t.Errorf("required %v, want [instance]", sc["required"])
	}
	if !ts[0].takes("hours") || !ts[0].takes("from") || !ts[0].takes("to") {
		t.Errorf("args %v, want instance, from, to, hours", ts[0].argNames())
	}
}
