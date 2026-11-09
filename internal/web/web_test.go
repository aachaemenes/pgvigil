package web

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/auth"
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
		{"/api/dms?instance=zero", 400, "instance must be"},
		{"/api/dms?task=arn:x&task_instance=-1", 400, "task_instance must be"},
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

// The login: every /api endpoint but login, logout and session is 401 without a session while the
// shell stays public; a POST needs the X-Pgvigil header; a wrong password is 401; the right one opens
// a session the cookie carries (HttpOnly, SameSite=Strict, Secure under TLS); logout kills it; a
// session dies at its TTL; five failures lock the name and the address for a minute, the right
// password included.
func TestLogin(t *testing.T) {
	hash, err := auth.Hash("correct horse battery")
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil)), tls: true}
	s.auth = newAuth(func(_ context.Context, user string) (string, error) {
		if user == "alice" {
			return hash, nil
		}
		return "", nil
	}, true, time.Hour)
	h := s.Handler()
	do := func(method, path, body string, header bool, cookie *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.RemoteAddr = "10.1.1.1:5000"
		if header {
			req.Header.Set(loginHeader, "1")
		}
		if cookie != nil {
			req.AddCookie(cookie)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	login := func(user, pw string) *httptest.ResponseRecorder {
		return do(http.MethodPost, "/api/login", `{"username":"`+user+`","password":"`+pw+`"}`, true, nil)
	}
	want := func(rec *httptest.ResponseRecorder, code int, text string) {
		t.Helper()
		if rec.Code != code || !strings.Contains(rec.Body.String(), text) {
			t.Fatalf("got %d %q, want %d containing %q", rec.Code, firstLine(rec.Body.String()), code, text)
		}
	}
	want(do(http.MethodGet, "/", "", false, nil), 200, "<title>pgvigil</title>")
	want(do(http.MethodGet, "/app.js", "", false, nil), 200, "")
	want(do(http.MethodGet, "/api/instances", "", false, nil), 401, "login required")
	want(do(http.MethodGet, "/api/health", "", false, nil), 401, "login required")
	want(do(http.MethodGet, "/api/session", "", false, nil), 401, "login required")
	want(do(http.MethodPost, "/api/login", `{"username":"alice","password":"correct horse battery"}`, false, nil), 403, "X-Pgvigil")
	want(do(http.MethodPost, "/api/login", `not json`, true, nil), 400, "JSON body")
	want(do(http.MethodPost, "/api/login", `{"username":"","password":"x"}`, true, nil), 400, "required")
	want(login("alice", "wrong password here"), 401, "wrong user name or password")
	want(login("nobody", "correct horse battery"), 401, "wrong user name or password")

	rec := login("Alice", "correct horse battery") // the name is case-insensitive
	want(rec, 200, `"user":"alice"`)
	var cookie *http.Cookie
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookie {
			cookie = c
		}
	}
	if cookie == nil || cookie.Value == "" || !cookie.HttpOnly || !cookie.Secure || cookie.SameSite != http.SameSiteStrictMode || cookie.MaxAge != 3600 {
		t.Fatalf("session cookie: %+v", cookie)
	}
	want(do(http.MethodGet, "/api/session", "", false, cookie), 200, `"user":"alice"`)
	want(do(http.MethodGet, "/api/activity", "", false, cookie), 400, "instance must be") // through the gate, into the handler
	want(do(http.MethodGet, "/api/nope", "", false, cookie), 404, "no such endpoint")
	want(do(http.MethodGet, "/api/session", "", false, &http.Cookie{Name: sessionCookie, Value: "forged"}), 401, "login required")

	want(do(http.MethodPost, "/api/logout", "", false, cookie), 403, "X-Pgvigil")
	want(do(http.MethodPost, "/api/logout", "", true, cookie), 204, "")
	want(do(http.MethodGet, "/api/session", "", false, cookie), 401, "login required")

	rec = login("alice", "correct horse battery")
	want(rec, 200, "alice")
	cookie = rec.Result().Cookies()[0]
	want(do(http.MethodGet, "/api/session", "", false, cookie), 200, "alice")
	s.auth.now = func() time.Time { return time.Now().Add(61 * time.Minute) }
	want(do(http.MethodGet, "/api/session", "", false, cookie), 401, "login required") // the TTL passed

	for i := 0; i < maxFails; i++ {
		want(login("alice", "wrong password here"), 401, "wrong user name or password")
	}
	rec = login("alice", "correct horse battery")
	want(rec, 429, "too many login attempts")
	if rec.Header().Get("Retry-After") == "" {
		t.Fatal("429 without Retry-After")
	}
	want(login("bob", "whatever this is"), 429, "too many") // the address is locked too
	s.auth.now = func() time.Time { return time.Now().Add(63 * time.Minute) }
	want(login("alice", "correct horse battery"), 200, "alice") // the minute passed
}

// The failure counters: a name is locked from every address, an address for every name; a different
// pair is not; a lock ends with its window.
func TestLoginLockKeys(t *testing.T) {
	a := newAuth(nil, false, 0)
	for i := 0; i < maxFails; i++ {
		a.recordFail("ip:A", "user:bob")
	}
	if a.blocked("ip:A", "user:carol") == 0 || a.blocked("ip:B", "user:bob") == 0 {
		t.Fatal("the address or the name was not locked")
	}
	if a.blocked("ip:B", "user:carol") != 0 {
		t.Fatal("an unrelated pair was locked")
	}
	a.now = func() time.Time { return time.Now().Add(failWindow + time.Second) }
	if a.blocked("ip:A", "user:bob") != 0 {
		t.Fatal("the lock outlived its window")
	}
	a.recordFail("ip:A")
	if n := a.fails["ip:A"].n; n != 1 {
		t.Fatalf("a failure after the window counted %d, want 1", n)
	}
}

// With the login off, /api/session says so and the endpoints are open (the loopback -no-login case).
func TestLoginOff(t *testing.T) {
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	h := s.Handler()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/session", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"login":false`) {
		t.Fatalf("session with the login off: %d %s", rec.Code, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader("{}")))
	if rec.Code != 404 {
		t.Fatalf("login with the login off: %d, want 404", rec.Code)
	}
	if rec.Header().Get("Strict-Transport-Security") != "" {
		t.Fatal("HSTS sent on a plain listener")
	}
}
