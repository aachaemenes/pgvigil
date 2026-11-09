package web

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The Slow queries handler's parameter checks need no database (the route is the lead's: the test calls it).
func TestSlowQueriesParams(t *testing.T) {
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	for _, c := range []struct{ q, want string }{
		{"instance=0", "instance must be"},
		{"instance=x", "instance must be"},
		{"min=-1", "min must be"},
		{"min=86400001", "min must be"},
		{"min=1s", "min must be"},
		{"tz=Europe/Berlin%3Bdrop", "tz must be"},
		{"tz=" + strings.Repeat("A", 65), "tz must be"},
		{"limit=0", "limit must be"},
		{"limit=501", "limit must be"},
		{"from=2026-01-02T00:00:00Z&to=2026-01-01T00:00:00Z", "from must be before to"},
	} {
		rec := httptest.NewRecorder()
		s.SlowQueries(rec, httptest.NewRequest(http.MethodGet, "/api/slowqueries?"+c.q, nil))
		if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), c.want) {
			t.Errorf("%s: got %d %q, want 400 containing %q", c.q, rec.Code, rec.Body.String(), c.want)
		}
	}
}
