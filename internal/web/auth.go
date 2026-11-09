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
// in this process and sent as an HttpOnly, SameSite=Strict cookie (Secure under TLS). Every gated
// request asks the repository for the user's current hash again (one primary-key read), so a user
// disabled, removed or given a new password loses an open session at once. A POST needs the
// X-Pgvigil header, which no cross-site form can set, so the cookie alone never authorises a change.
// Failures are counted per client address and per user name: an address past the limit is refused
// for the rest of the minute; a user name past it is slowed down, never locked, so a stranger who
// knows an operator's name cannot keep the operator out.
const (
	sessionCookie = "pgvigil_session"
	loginHeader   = "X-Pgvigil"
	maxFails      = 5
	failWindow    = time.Minute
	nameDelayStep = 2 * time.Second
	nameDelayMax  = 20 * time.Second
	defaultTTL    = 12 * time.Hour
	verifySlots   = 4 // concurrent argon2 verifies: each holds 19 MiB while it runs
)

type session struct {
	user    string
	hash    string // the hash the login verified against; a different one now = the password changed
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
	sleep    func(ctx context.Context, d time.Duration) error // the name slowdown; a test stubs it
	mu       sync.Mutex
	sessions map[string]session
	fails    map[string]failRecord
}

func newAuth(lookup func(context.Context, string) (string, error), secure bool, ttl time.Duration) *authState {
	if ttl <= 0 {
		ttl = defaultTTL
	}
	return &authState{lookup: lookup, secure: secure, ttl: ttl, sem: make(chan struct{}, verifySlots), now: time.Now,
		sleep: sleepCtx, sessions: map[string]session{}, fails: map[string]failRecord{}}
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// issue starts a session and returns its token (32 random bytes).
func (a *authState) issue(user, hash string) (string, error) {
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
	a.sessions[tok] = session{user: user, hash: hash, expires: now.Add(a.ttl)}
	return tok, nil
}

// verify returns the session's user when the token is live and the user still exists, is enabled
// and keeps the password the session was opened with; otherwise the session is gone. A repository
// error keeps the session (the request's own query fails on the same error).
func (a *authState) verify(ctx context.Context, tok string) (string, bool) {
	a.mu.Lock()
	s, ok := a.sessions[tok]
	if ok && !a.now().Before(s.expires) {
		delete(a.sessions, tok)
		ok = false
	}
	a.mu.Unlock()
	if !ok {
		return "", false
	}
	hash, err := a.lookup(ctx, s.user)
	if err != nil {
		return s.user, true
	}
	if hash == "" || hash != s.hash {
		a.revoke(tok)
		return "", false
	}
	return s.user, true
}

func (a *authState) revoke(tok string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.sessions, tok)
}

func (a *authState) sweepFails(now time.Time) {
	for k, f := range a.fails {
		if !now.Before(f.reset) {
			delete(a.fails, k)
		}
	}
}

// addrWait returns how long a client address stays refused after maxFails failures in failWindow.
func (a *authState) addrWait(ip string) time.Duration {
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	a.sweepFails(now)
	if f, ok := a.fails["ip:"+ip]; ok && f.n >= maxFails {
		return f.reset.Sub(now)
	}
	return 0
}

// nameDelay returns the slowdown an attempt on a user name carries after maxFails failures in
// failWindow: 2 s more per failure, 20 s at most; the attempt is still judged.
func (a *authState) nameDelay(user string) time.Duration {
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	a.sweepFails(now)
	f, ok := a.fails["user:"+user]
	if !ok || f.n < maxFails {
		return 0
	}
	d := time.Duration(f.n-maxFails+1) * nameDelayStep
	if d > nameDelayMax {
		d = nameDelayMax
	}
	return d
}

func (a *authState) recordFail(ip, user string) {
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, k := range []string{"ip:" + ip, "user:" + user} {
		f := a.fails[k]
		if !now.Before(f.reset) {
			f = failRecord{reset: now.Add(failWindow)}
		}
		f.n++
		a.fails[k] = f
	}
}

func (a *authState) clearFails(ip, user string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.fails, "ip:"+ip)
	delete(a.fails, "user:"+user)
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

// sessionUser names the live session's user, or "" without one.
func (s *Server) sessionUser(r *http.Request) string {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return ""
	}
	u, ok := s.auth.verify(r.Context(), c.Value)
	if !ok {
		return ""
	}
	return u
}

// requireLogin lets a request through with a live session, or when the login is off.
func (s *Server) requireLogin(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.auth != nil && s.sessionUser(r) == "" {
			writeErr(w, http.StatusUnauthorized, errors.New("login required"))
			return
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
	ip := clientIP(r)
	if d := a.addrWait(ip); d > 0 {
		secs := int(d.Seconds()) + 1
		w.Header().Set("Retry-After", strconv.Itoa(secs))
		writeErr(w, http.StatusTooManyRequests, fmt.Errorf("too many login attempts from this address; try again in %d s", secs))
		return
	}
	if d := a.nameDelay(user); d > 0 {
		if err := a.sleep(r.Context(), d); err != nil {
			return
		}
	}
	hash, err := a.lookup(r.Context(), user)
	if err != nil {
		s.log.Warn("login lookup failed", "err", err)
		writeErr(w, http.StatusInternalServerError, errors.New("the login check could not run"))
		return
	}
	target := hash
	if target == "" {
		target = auth.Dummy() // an unknown name costs the same time as a wrong password
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
		a.recordFail(ip, user)
		s.log.Info("login failed", "user", user, "from", ip)
		writeErr(w, http.StatusUnauthorized, errors.New("wrong user name or password"))
		return
	}
	tok, err := a.issue(user, hash)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	a.clearFails(ip, user)
	http.SetCookie(w, a.cookie(tok, int(a.ttl.Seconds())))
	s.log.Info("login", "user", user, "from", ip)
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
	if u := s.sessionUser(r); u != "" {
		s.reply(w, r, map[string]any{"login": true, "user": u}, nil)
		return
	}
	writeErr(w, http.StatusUnauthorized, errors.New("login required"))
}
