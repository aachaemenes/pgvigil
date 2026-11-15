package web

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestProbes (B6.4, PM Added 27; the pass's X5, the lead's 23:4x B6.4-d): /livez answers 'ok' whatever the login and
// reads nothing; /readyz answers 'ok' while the repository answers with its schema current, 503 'not ready: <why>'
// otherwise, cached about 5 s (one check for a burst); without the login it is open, with the login on it is 404
// unless web.readyz_without_login is set; neither says more than those words, and /api/ stays behind the login
func TestProbes(t *testing.T) {
	calls := 0
	ready := func(ok bool, why string, err error) func(context.Context) (bool, string, error) {
		return func(context.Context) (bool, string, error) { calls++; return ok, why, err }
	}
	get := func(h http.Handler, path string) (int, string) {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		b, _ := io.ReadAll(rec.Body)
		return rec.Code, strings.TrimSpace(string(b))
	}
	lg := slog.New(slog.NewTextHandler(io.Discard, nil))
	for _, c := range []struct {
		name               string
		login, open        bool
		check              func(context.Context) (bool, string, error)
		livez, readyz      int
		readyBody, apiWant string
	}{
		{"login off, current", false, false, ready(true, "", nil), 200, 200, "ok", ""},
		{"login off, behind", false, false, ready(false, "0166_collection_health", nil), 200, 503, "not ready: the repository's schema is behind this binary (needs 0166_collection_health)", ""},
		{"login off, no repository", false, false, ready(false, "", errors.New("dial tcp 10.0.0.9:5432: connect: connection refused (user=pgvigil)")), 200, 503, "not ready: the repository does not answer", ""},
		{"login on, switch off", true, false, ready(true, "", nil), 200, 404, "", "login required"},
		{"login on, switch on", true, true, ready(true, "", nil), 200, 200, "ok", "login required"},
	} {
		calls = 0
		s := &Server{log: lg, readyCheck: c.check, readyzOpen: !c.login || c.open}
		if c.login {
			s.auth = &authState{}
		}
		h := s.Handler()
		if code, body := get(h, "/livez"); code != c.livez || body != "ok" {
			t.Errorf("%s: /livez %d %q, want %d ok", c.name, code, body, c.livez)
		}
		code, body := get(h, "/readyz")
		if code != c.readyz || (c.readyBody != "" && body != c.readyBody) {
			t.Errorf("%s: /readyz %d %q, want %d %q", c.name, code, body, c.readyz, c.readyBody)
		}
		if c.readyz != 404 {
			_, _ = get(h, "/readyz")
			if calls != 1 {
				t.Errorf("%s: %d readiness checks for two reads in 5 s, want 1", c.name, calls)
			}
		}
		if c.apiWant != "" {
			if code, body := get(h, "/api/instances"); code != 401 || !strings.Contains(body, c.apiWant) {
				t.Errorf("%s: /api/instances without a session %d %q, want 401", c.name, code, body)
			}
		}
	}
}
