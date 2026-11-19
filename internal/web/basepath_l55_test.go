package web

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestUnderBaseL55 (RELNOTES L55, the lead's 00:47): serve's listener under web.base_path - the prefix stripped
// before the routes (which stay as written) and kept in the request for the pages that write links; a path outside
// it is a 404 naming the base, and the log names the base once; the base without its '/' is sent to it with the
// query kept. No base = the handler as it is.
func TestUnderBaseL55(t *testing.T) {
	var gotPath, gotBase string
	inner := http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) { gotPath, gotBase = r.URL.Path, baseFrom(r) })
	var logs bytes.Buffer
	h := UnderBase("/pgvigil", inner, slog.New(slog.NewTextHandler(&logs, nil)))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/pgvigil/api/health", nil))
	if rec.Code != http.StatusOK || gotPath != "/api/health" || gotBase != "/pgvigil" {
		t.Errorf("under the base: %d, the routes saw %q with base %q; want 200, /api/health, /pgvigil", rec.Code, gotPath, gotBase)
	}
	for _, p := range []string{"/api/health", "/", "/pgvigilx/api/health"} {
		gotPath = ""
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", p, nil))
		if rec.Code != http.StatusNotFound || gotPath != "" || !strings.Contains(rec.Body.String(), "/pgvigil/") {
			t.Errorf("%s outside the base: %d %q, the routes saw %q; want 404 naming /pgvigil/ and no route", p, rec.Code, rec.Body.String(), gotPath)
		}
	}
	if n := strings.Count(logs.String(), "base_path=/pgvigil"); n != 1 {
		t.Errorf("the log named the base %d times for three requests outside it, want once: %s", n, logs.String())
	}
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/pgvigil?x=1", nil))
	if rec.Code != http.StatusMovedPermanently || rec.Header().Get("Location") != "/pgvigil/?x=1" {
		t.Errorf("the base without its '/': %d to %q; want 301 to /pgvigil/?x=1", rec.Code, rec.Header().Get("Location"))
	}
	gotPath, gotBase = "", "x"
	UnderBase("", inner, slog.New(slog.NewTextHandler(io.Discard, nil))).ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/api/health", nil))
	if gotPath != "/api/health" || gotBase != "" {
		t.Errorf("no base: the routes saw %q with base %q; want /api/health and none", gotPath, gotBase)
	}
}

// TestShellUnderBaseL55: the page shell under the base carries <base href="/pgvigil/"> (its own links are relative,
// so its files and the UI's reads resolve under the base), an unknown page too; at the root it is the embedded file
// as it is.
func TestShellUnderBaseL55(t *testing.T) {
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	h := UnderBase("/pgvigil", s.Handler(), s.log)
	for _, p := range []string{"/pgvigil/", "/pgvigil/no/such/page"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", p, nil))
		if body := rec.Body.String(); rec.Code != http.StatusOK || !strings.Contains(body, `<base href="/pgvigil/">`) || !strings.Contains(body, "<title>pgvigil</title>") {
			t.Errorf("%s: %d, no <base href=\"/pgvigil/\"> in the shell", p, rec.Code)
		}
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/pgvigil/app.css", nil))
	if rec.Code != http.StatusOK || strings.Contains(rec.Body.String(), "<base") {
		t.Errorf("a file under the base: %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if body := rec.Body.String(); strings.Contains(body, "<base") || !strings.Contains(body, "<title>pgvigil</title>") {
		t.Error("at the root the shell gained a <base> or lost its title")
	}
}

// TestCookiePathUnderBaseL55: the session cookie is scoped to the base (not to every site on the host), '/' at the
// root - the render's own loopback listener serves at the root, so its cookie stays '/'.
func TestCookiePathUnderBaseL55(t *testing.T) {
	a := &authState{}
	r := httptest.NewRequest("POST", "/api/login", nil)
	if c := a.cookie(r, "tok", 60); c.Path != "/" {
		t.Errorf("at the root the cookie's Path is %q, want /", c.Path)
	}
	r = r.WithContext(withBase(r.Context(), "/pgvigil"))
	if c := a.cookie(r, "tok", 60); c.Path != "/pgvigil/" {
		t.Errorf("under the base the cookie's Path is %q, want /pgvigil/", c.Path)
	}
}
