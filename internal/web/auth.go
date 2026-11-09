package web

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/auth"
)

// The UI login. A password is checked against the argon2id hash pgvigil.ui_password_hash() returns
// (a SECURITY DEFINER function only the pgvigil_auth role may call); a session is a random token held
// in this process and sent as an HttpOnly, SameSite=Strict cookie (Secure under TLS). A POST needs
// the X-Pgvigil header, which no cross-site form can set, so the cookie alone never authorises a
// change. Failures are limited per client address and per user name.
const (
	sessionCookie = "pgvigil_session"
	loginHeader   = "X-Pgvigil"
	maxFails      = 5
	failWindow    = time.Minute
	defaultTTL    = 12 * time.Hour
	verifySlots   = 4 // concurrent argon2 verifies: each holds 19 MiB while it runs
)

type session struct {
	user    string
	expires time.Time
}

type failRecord struct {
	n     int
	reset time.Time
}

type authState struct {
	// lookup returns the stored hash of an enabled user, "" when there is none.
	lookup   func(ctx context.Context, user string) (string, error)
	secure   bool
	ttl      time.Duration
	sem      chan struct{}
	now      func() time.Time
	mu       sync.Mutex
	sessions map[string]session
	fails    map[string]failRecord
}

func newAuth(lookup func(context.Context, string) (string, error), secure bool, ttl time.Duration) *authState {
	if ttl <= 0 {
		ttl = defaultTTL
	}
	return &authState{lookup: lookup, secure: secure, ttl: ttl, sem: make(chan struct{}, verifySlots), now: time.Now,
		sessions: map[string]session{}, fails: map[string]failRecord{}}
}

// issue starts a session and returns its token (32 random bytes).
func (a *authState) issue(user string) (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	tok := base64.RawURLEncoding.EncodeToString(b)
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	for k, s := range a.sessions {
		if !now.Before(s.expires) {
			delete(a.sessions, k)
		}
	}
	a.sessions[tok] = session{user: user, expires: now.Add(a.ttl)}
	return tok, nil
}

func (a *authState) userOf(tok string) (string, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	s, ok := a.sessions[tok]
	if !ok {
		return "", false
	}
	if !a.now().Before(s.expires) {
		delete(a.sessions, tok)
		return "", false
	}
	return s.user, true
}

func (a *authState) revoke(tok string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.sessions, tok)
}

// blocked returns how long any of the keys stays locked after maxFails failures in failWindow.
func (a *authState) blocked(keys ...string) time.Duration {
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	var wait time.Duration
	for k, f := range a.fails {
		if !now.Before(f.reset) {
			delete(a.fails, k)
		}
	}
	for _, k := range keys {
		if f, ok := a.fails[k]; ok && f.n >= maxFails {
			if d := f.reset.Sub(now); d > wait {
				wait = d
			}
		}
	}
	return wait
}

func (a *authState) recordFail(keys ...string) {
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, k := range keys {
		f := a.fails[k]
		if !now.Before(f.reset) {
			f = failRecord{reset: now.Add(failWindow)}
		}
		f.n++
		a.fails[k] = f
	}
}

func (a *authState) clearFails(keys ...string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, k := range keys {
		delete(a.fails, k)
	}
}

func (a *authState) cookie(tok string, maxAge int) *http.Cookie {
	return &http.Cookie{Name: sessionCookie, Value: tok, Path: "/", HttpOnly: true, Secure: a.secure,
		SameSite: http.SameSiteStrictMode, MaxAge: maxAge}
}

func clientIP(r *http.Request) string {
	if h, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return h
	}
	return r.RemoteAddr
}

// requireLogin lets a request through with a live session, or when the login is off.
func (s *Server) requireLogin(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.auth != nil {
			c, err := r.Cookie(sessionCookie)
			if err != nil {
				writeErr(w, http.StatusUnauthorized, errors.New("login required"))
				return
			}
			if _, ok := s.auth.userOf(c.Value); !ok {
				writeErr(w, http.StatusUnauthorized, errors.New("login required"))
				return
			}
		}
		h.ServeHTTP(w, r)
	})
}

// login: POST /api/login {"username","password"} with the X-Pgvigil header.
func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	a := s.auth
	if a == nil {
		writeErr(w, http.StatusNotFound, errors.New("the login is off"))
		return
	}
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	var in struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, errors.New("a JSON body with username and password is required"))
		return
	}
	user := strings.ToLower(strings.TrimSpace(in.Username))
	if user == "" || in.Password == "" || len(user) > 64 {
		writeErr(w, http.StatusBadRequest, errors.New("user name and password are required"))
		return
	}
	keys := []string{"ip:" + clientIP(r), "user:" + user}
	if d := a.blocked(keys...); d > 0 {
		secs := int(d.Seconds()) + 1
		w.Header().Set("Retry-After", strconv.Itoa(secs))
		writeErr(w, http.StatusTooManyRequests, fmt.Errorf("too many login attempts; try again in %d s", secs))
		return
	}
	hash, err := a.lookup(r.Context(), user)
	if err != nil {
		s.log.Warn("login lookup failed", "err", err)
		writeErr(w, http.StatusInternalServerError, errors.New("the login check could not run"))
		return
	}
	target := hash
	if target == "" {
		target = auth.Dummy // an unknown name costs the same time as a wrong password
	}
	select {
	case a.sem <- struct{}{}:
	case <-r.Context().Done():
		return
	}
	ok, verr := auth.Verify(target, in.Password)
	<-a.sem
	if verr != nil {
		s.log.Warn("stored password hash is not usable", "user", user, "err", verr)
	}
	if verr != nil || !ok || hash == "" {
		a.recordFail(keys...)
		s.log.Info("login failed", "user", user, "from", clientIP(r))
		writeErr(w, http.StatusUnauthorized, errors.New("wrong user name or password"))
		return
	}
	tok, err := a.issue(user)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	a.clearFails(keys...)
	http.SetCookie(w, a.cookie(tok, int(a.ttl.Seconds())))
	s.log.Info("login", "user", user, "from", clientIP(r))
	s.reply(w, r, map[string]any{"login": true, "user": user}, nil)
}

// logout: POST /api/logout with the X-Pgvigil header ends the session named by the cookie.
func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	if s.auth == nil {
		writeErr(w, http.StatusNotFound, errors.New("the login is off"))
		return
	}
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if c, err := r.Cookie(sessionCookie); err == nil {
		s.auth.revoke(c.Value)
	}
	http.SetCookie(w, s.auth.cookie("", -1))
	w.WriteHeader(http.StatusNoContent)
}

// sessionInfo: GET /api/session says whether the login is on and who holds this session.
func (s *Server) sessionInfo(w http.ResponseWriter, r *http.Request) {
	if s.auth == nil {
		s.reply(w, r, map[string]any{"login": false}, nil)
		return
	}
	if c, err := r.Cookie(sessionCookie); err == nil {
		if u, ok := s.auth.userOf(c.Value); ok {
			s.reply(w, r, map[string]any{"login": true, "user": u}, nil)
			return
		}
	}
	writeErr(w, http.StatusUnauthorized, errors.New("login required"))
}
