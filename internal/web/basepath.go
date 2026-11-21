package web

import (
	"bytes"
	"context"
	"fmt"
	"html"
	"log/slog"
	"net/http"
	"strings"
	"sync"
)

// baseKey carries web.base_path in a request served under it (UnderBase): the shell's <base href> and the session
// cookie's Path read it. The render's loopback listener and the MCP server call Handler() at the root: no base there.
type baseKey struct{}

func withBase(ctx context.Context, base string) context.Context {
	return context.WithValue(ctx, baseKey{}, base)
}

// baseFrom is the base path the request came in under, "" at the root
func baseFrom(r *http.Request) string {
	b, _ := r.Context().Value(baseKey{}).(string)
	return b
}

// UnderBase serves h under base (config.ValidBasePath's form) for a reverse proxy that passes the path whole: the
// prefix is stripped before the routes, which stay as written, and kept in the request; a Location a route writes as a
// root path gets the base in front (baseWriter: the mux's own redirects - "/api" to "/api/", a path it cleans - stay
// under it); the bare base is sent to base + "/"; a path outside it is a 404 naming the base, and the log names the
// base once. No base = h.
func UnderBase(base string, h http.Handler, log *slog.Logger) http.Handler {
	if base == "" {
		return h
	}
	inner := http.StripPrefix(base, h)
	var once sync.Once
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, base+"/"):
			inner.ServeHTTP(&baseWriter{ResponseWriter: w, base: base}, r.WithContext(withBase(r.Context(), base)))
		case r.URL.Path == base:
			to := base + "/"
			if r.URL.RawQuery != "" {
				to += "?" + r.URL.RawQuery
			}
			http.Redirect(w, r, to, http.StatusMovedPermanently)
		default:
			once.Do(func() {
				log.Warn("a request outside web.base_path: pgvigil serves under it alone - a reverse proxy passes the path whole (docs/configuration.md, The UI under a sub-path, behind a reverse proxy)", "base_path", base, "path", r.URL.Path)
			})
			writeErr(w, http.StatusNotFound, fmt.Errorf("not found: pgvigil is served under %s/", base))
		}
	})
}

// baseWriter puts the base in front of a Location written as a root path ("/api/" -> base + "/api/") when the header
// is sent; a full URL, a "//host" one and a relative one are left as written. Unwrap keeps NewResponseController's
// deadlines working through it.
type baseWriter struct {
	http.ResponseWriter
	base string
	sent bool
}

func (w *baseWriter) fixLocation() {
	if w.sent {
		return
	}
	w.sent = true
	h := w.Header()
	if loc := h.Get("Location"); strings.HasPrefix(loc, "/") && !strings.HasPrefix(loc, "//") {
		h.Set("Location", w.base+loc)
	}
}

func (w *baseWriter) WriteHeader(code int) { w.fixLocation(); w.ResponseWriter.WriteHeader(code) }

func (w *baseWriter) Write(b []byte) (int, error) { w.fixLocation(); return w.ResponseWriter.Write(b) }

func (w *baseWriter) Flush() {
	w.fixLocation()
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *baseWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// withBaseHref writes <base href> into the shell for a request served under a base, so its relative links and the
// UI's reads resolve under it
func withBaseHref(shell []byte, base string) []byte {
	return bytes.Replace(shell, []byte("<head>"), []byte("<head>\n<base href=\""+html.EscapeString(base)+"/\">"), 1)
}
