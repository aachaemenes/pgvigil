package web

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/actions"
)

// The Plan page's refusals that need no database: the door off, no header, the -no-login server; and the buttons'
// reasons.
func TestPlansOff(t *testing.T) {
	s := &Server{log: discardLog()}
	nologin, _ := s.NewActions(context.Background(), &ActionsConfig{LogDSN: "host=x"})
	none, _ := s.NewActions(context.Background(), nil)
	for _, path := range []string{"/api/plans/explain", "/api/plans/analyze"} {
		for _, c := range []struct {
			a      *Actions
			header bool
			code   int
			want   string
		}{
			{nil, true, 403, "actions are off"},
			{none, false, 403, "X-Pgvigil header"},
			{none, true, 403, "no actions configuration"},
			{nologin, true, 403, "-no-login"},
		} {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(`{"instance_id":1,"statement":"select 1"}`))
			if c.header {
				req.Header.Set(loginHeader, "1")
			}
			if strings.HasSuffix(path, "explain") {
				c.a.Explain(rec, req)
			} else {
				c.a.ExplainAnalyze(rec, req)
			}
			if rec.Code != c.code || !strings.Contains(rec.Body.String(), c.want) {
				t.Errorf("%s: got %d %q, want %d with %q", path, rec.Code, rec.Body.String(), c.code, c.want)
			}
		}
	}
}

func TestPlanButtons(t *testing.T) {
	s := &Server{log: discardLog()}
	s.actions, _ = s.NewActions(context.Background(), &ActionsConfig{LogDSN: "host=x"})
	if b := s.planButtons("i1"); b.Explain || b.Analyze || !strings.Contains(b.ExplainReason, "-no-login") || b.AnalyzeReason != b.ExplainReason {
		t.Errorf("no-login: %+v", b)
	}
	// a door that is on (as NewActions leaves it with the login and the audit pool): the gate decides
	s.actions = &Actions{s: s, doors: map[string]actions.Door{
		"i1": {Monitor: "host=m", Actions: "host=a", Configured: true},
		"i2": {Monitor: "host=m"},
	}}
	if b := s.planButtons("i1"); !b.Explain || b.Analyze || !strings.Contains(b.AnalyzeReason, "off by default") {
		t.Errorf("gate off: %+v", b)
	}
	s.SetPlans(PlansConfig{Gates: map[string]actions.ExplainGate{"i1": {Enabled: true}, "i2": {Enabled: true}}})
	if b := s.planButtons("i1"); !b.Explain || !b.Analyze {
		t.Errorf("gate on: %+v", b)
	}
	if b := s.planButtons("i2"); !b.Explain || b.Analyze || !strings.Contains(b.AnalyzeReason, "no actions_dsn") {
		t.Errorf("no actions login: %+v", b)
	}
	if b := s.planButtons("i3"); b.Explain || !strings.Contains(b.ExplainReason, "no monitoring dsn") {
		t.Errorf("unknown instance: %+v", b)
	}
}
