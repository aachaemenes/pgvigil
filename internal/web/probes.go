package web

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/repo"
)

// The probes (B6.4, PM Added 27; the B6 pass's X5; the lead's 23:4x B6.4-d): /livez - this process answers, nothing
// read; /readyz - this process can serve: the repository answers and its schema is current (the check 'pgvigil run'
// makes at its start). Neither needs the login nor says more than its words: no version, no instance, no driver error
// (a connect error names the login and the address). /readyz is open while the login is off; with the login on only
// when web.readyz_without_login is set (else 404). The collector's own state is a finding, never a probe's answer.

// readyTTL: a /readyz answer is kept this long; a burst of probes runs one check (single-flight: the lock is held
// across the check)
const readyTTL = 5 * time.Second

type readyCache struct {
	mu  sync.Mutex
	at  time.Time
	ok  bool
	why string
}

// readyCheckOn: /readyz's check on serve's own pool (Open). Serve's login is the reader's: the check reads
// schema_version itself (repo.SchemaCurrentRead), never the collector's schema_missing (B6.2 part c #1)
func readyCheckOn(q repo.RowQuerier) func(context.Context) (bool, string, error) {
	return func(ctx context.Context) (bool, string, error) { return repo.SchemaCurrentRead(ctx, q) }
}

func (s *Server) livez(w http.ResponseWriter, _ *http.Request) {
	probeReply(w, http.StatusOK, "ok")
}

func (s *Server) readyz(w http.ResponseWriter, r *http.Request) {
	if s.auth != nil && !s.readyzWithoutLogin { // the login on and web.readyz_without_login not set
		probeReply(w, http.StatusNotFound, "not found")
		return
	}
	ok, why := s.readiness(r.Context())
	if !ok {
		probeReply(w, http.StatusServiceUnavailable, "not ready: "+why)
		return
	}
	probeReply(w, http.StatusOK, "ok")
}

// readiness: the cached answer, or a new check under the lock
func (s *Server) readiness(ctx context.Context) (bool, string) {
	c := s.ready
	if c == nil { // a Server built without Handler() (a test): no cache to share
		c = &readyCache{}
		s.ready = c
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.at.IsZero() && time.Since(c.at) < readyTTL {
		return c.ok, c.why
	}
	c.ok, c.why = true, ""
	switch {
	case s.readyCheck == nil:
		c.ok, c.why = false, "no readiness check is set"
	default:
		// the check's own 3 s, not the prober's: a prober that hangs up first (Kubernetes' 1 s) does not cut the check
		// whose answer the next 5 s are told (B6.2 part c #2)
		cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
		ok, needs, err := s.readyCheck(cctx)
		cancel()
		switch {
		case errors.Is(err, context.Canceled):
			// not the repository's answer: not ready now, not kept
			s.log.Warn("readyz: the check was cancelled", "err", err)
			return false, "the repository does not answer"
		case err != nil:
			// the error's text stays in the log: it can name the login and the repository's address
			s.log.Warn("readyz: the repository did not answer", "err", err)
			c.ok, c.why = false, "the repository does not answer"
		case !ok:
			c.ok, c.why = false, "the repository's schema is behind this binary (needs "+needs+")"
		}
	}
	c.at = time.Now()
	return c.ok, c.why
}

func probeReply(w http.ResponseWriter, code int, words string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_, _ = w.Write([]byte(words + "\n"))
}
