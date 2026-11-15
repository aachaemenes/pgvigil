package mcp

// The alert tool (task 403b, PerformanceMonitor 3.13 Added 20: get_alert_history for one server over up to 90 days).
// It reads /api/alertscope in process, as every tool reads the API: part alerts (the instance's alerts, filtered by
// the instance before the API's limit, so a busy fleet never pushes its rows out) and part history (the instance's
// findings history: each open, close, severity change and hourly sample). 90 days is the reach of the alert log and
// the findings history (purge keeps both at least that long). tools() lists alertTools() (a wiring line).

import (
	"context"
	"fmt"
	"net/url"
	"time"
)

// maxAlertHours is the alert history's longest window: 90 days.
const maxAlertHours = 90 * 24

func alertTools() []tool {
	return []tool{
		{Name: "alert_history", Title: "Alert history",
			Description: "One instance's alerts over a window of up to 90 days: each firing with when it cleared, its severity, check, value and threshold, the channels it went to and its sends; and the instance's findings history in the same window, newest first (each finding's open, close, severity change and hourly sample, whether or not it was sent).",
			args: []arg{argInstance, argFrom, argTo,
				{name: "hours", typ: "integer", desc: "window length in hours when from is not given (1..2160: 90 days, the alert log's reach; default 24)"}},
			run: alertHistory},
	}
}

func alertHistory(ctx context.Context, s *Server, a map[string]any) (any, error) {
	in, err := s.resolve(ctx, a, "instance")
	if err != nil {
		return nil, err
	}
	if _, err := integer(a, "hours", 24, 1, maxAlertHours); err != nil {
		return nil, err
	}
	q, err := window(a, 24)
	if err != nil {
		return nil, err
	}
	from, _ := time.Parse(time.RFC3339, q.Get("from"))
	to, _ := time.Parse(time.RFC3339, q.Get("to"))
	if !from.Before(to) {
		return nil, fmt.Errorf("from (%s) must be before to (%s)", q.Get("from"), q.Get("to"))
	}
	if to.Sub(from) > maxAlertHours*time.Hour {
		return nil, fmt.Errorf("the window is %.0f hours: at most %d (90 days, the alert log's reach)", to.Sub(from).Hours(), maxAlertHours)
	}
	q.Set("instance_id", in.ID)
	out := map[string]any{"instance": in, "from": q.Get("from"), "to": q.Get("to")}
	for _, p := range []struct{ part, key string }{{"alerts", "alerts"}, {"history", "findings_history"}} {
		pq := url.Values{}
		for k, v := range q {
			pq[k] = v
		}
		pq.Set("part", p.part)
		v, err := s.get(ctx, "/api/alertscope", pq)
		if err != nil {
			return nil, err
		}
		t := field(v, p.part)
		rows := records(t)
		if p.part == "history" {
			// the API gives the history oldest first; the reply's row cap (Server.limit) keeps a list's head, so the
			// tool turns it newest first: a cut reply keeps the recent end
			for i, j := 0, len(rows)-1; i < j; i, j = i+1, j-1 {
				rows[i], rows[j] = rows[j], rows[i]
			}
		}
		cut := false
		for _, r := range rows {
			if c, ok := r["cut"].(bool); ok && c {
				cut = true
			}
			delete(r, "cut")
			delete(r, "instance_id")
		}
		out[p.key] = rows
		if cut {
			out[p.key+"_note"] = fmt.Sprintf("the newest %d rows of the window only (newest first): ask a shorter window for the rest", len(rows))
		}
	}
	if len(out["alerts"].([]map[string]any)) == 0 {
		out["note"] = "no alert of this instance was open in the window"
	}
	return out, nil
}
