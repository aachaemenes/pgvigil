package web

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The routes that need no database: the shell, its assets, unknown paths, bad parameters.
func TestRoutesWithoutDatabase(t *testing.T) {
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	h := s.Handler()
	cases := []struct {
		path string
		code int
		want string
	}{
		{"/", 200, "<title>pgvigil</title>"},
		{"/app.js", 200, ""},
		{"/app.css", 200, ""},
		{"/some/client/route", 200, "<title>pgvigil</title>"},
		{"/api/nope", 404, "no such endpoint"},
		{"/api/activity", 400, "instance must be"},
		{"/api/statements?instance=1&from=bad", 400, "from:"},
		{"/api/statements?instance=1&from=2026-01-02T00:00:00Z&to=2026-01-01T00:00:00Z", 400, "from must be before to"},
		{"/api/statements?instance=1&from=2025-01-01T00:00:00Z&to=2026-01-01T00:00:00Z", 400, "longer than 31 days"},
		{"/api/statements?instance=1&limit=9999", 400, "limit must be"},
		{"/api/counters?instance=1&kind=disk", 400, "kind must be"},
	}
	for _, c := range cases {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, c.path, nil))
		if rec.Code != c.code || !strings.Contains(rec.Body.String(), c.want) {
			t.Errorf("%s: got %d %q, want %d containing %q", c.path, rec.Code, firstLine(rec.Body.String()), c.code, c.want)
		}
		if rec.Header().Get("X-Frame-Options") != "DENY" {
			t.Errorf("%s: security headers missing", c.path)
		}
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/instances", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /api/instances: got %d, want 405", rec.Code)
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// A loopback server answers only to its own names: a DNS-rebinding page sends its own Host.
func TestHostGuard(t *testing.T) {
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil)), hosts: hostSet(LoopbackHosts("8080"))}
	h := s.Handler()
	for host, want := range map[string]int{"127.0.0.1:8080": 200, "localhost:8080": 200, "[::1]:8080": 200,
		"evil.example:8080": 421, "127.0.0.1:9999": 421} {
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		req.Host = host
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Errorf("Host %s: got %d, want %d", host, rec.Code, want)
		}
	}
}
