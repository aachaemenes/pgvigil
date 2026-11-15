package web

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
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
		s := &Server{log: lg, readyCheck: c.check, readyzWithoutLogin: c.open} // Open's own fields: readyz() decides
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

// readerQuerier answers as serve's login (pgvigil_ui IN ROLE pgvigil_reader) does on a store: no EXECUTE on the
// collector's functions (42501: apply_roles gives schema_missing and schema_latest to pgvigil_collector only), SELECT
// on schema_version; drop = the binary's newest file is not applied
type readerQuerier struct {
	drop    bool
	dropped string
}

type fakeRow struct {
	missing []string
	err     error
}

func (r fakeRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	*(dest[0].(*[]string)) = r.missing
	return nil
}

func (q *readerQuerier) QueryRow(_ context.Context, sql string, args ...any) pgx.Row {
	switch {
	case strings.Contains(sql, "pgvigil.schema_missing(") || strings.Contains(sql, "pgvigil.schema_latest("):
		return fakeRow{err: &pgconn.PgError{Code: "42501", Message: "permission denied for function schema_missing"}}
	case strings.Contains(sql, "pgvigil.schema_version") && len(args) == 1:
		names, _ := args[0].([]string)
		if q.drop && len(names) > 0 {
			q.dropped = names[len(names)-1]
			return fakeRow{missing: []string{q.dropped}}
		}
		return fakeRow{missing: []string{}}
	}
	return fakeRow{err: errors.New("a read the reader's login was not expected to make: " + sql)}
}

// TestReadyzOnTheReadersLogin (B6.2 part c #1): /readyz's own check (readyCheckOn, as Open wires it) on serve's login
// answers ready on a current store and 'behind (needs <file>)' with a file missing - never 'does not answer', which a
// call of the collector's schema_missing gives on that login (42501)
func TestReadyzOnTheReadersLogin(t *testing.T) {
	lg := slog.New(slog.NewTextHandler(io.Discard, nil))
	for _, drop := range []bool{false, true} {
		q := &readerQuerier{drop: drop}
		s := &Server{log: lg, readyCheck: readyCheckOn(q)}
		ok, why := s.readiness(context.Background())
		switch {
		case !drop && (!ok || why != ""):
			t.Errorf("current store on the reader's login: ready %v %q, want ready", ok, why)
		case drop && (ok || q.dropped == "" || why != "the repository's schema is behind this binary (needs "+q.dropped+")"):
			t.Errorf("a file missing on the reader's login: ready %v %q, want behind (needs %s)", ok, why, q.dropped)
		}
	}
}

// TestReadinessOutlivesTheProber (B6.2 part c #2): a prober that hangs up before the check ends (Kubernetes' 1 s
// timeout) does not cancel the check: its answer is the repository's, and that is what the next 5 s are told
func TestReadinessOutlivesTheProber(t *testing.T) {
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil)), readyCheck: func(ctx context.Context) (bool, string, error) {
		if err := ctx.Err(); err != nil { // the check still running when its context ends
			return false, "", err
		}
		return true, "", nil
	}}
	gone, hangUp := context.WithCancel(context.Background())
	hangUp()
	if ok, why := s.readiness(gone); !ok {
		t.Errorf("a prober gone before the check: ready %v %q, want ready (the repository answers)", ok, why)
	}
}

// TestReadinessCanceledNotKept (B6.2 part c #2): a check that ends Canceled answers not ready but is not kept: the next
// probe checks again
func TestReadinessCanceledNotKept(t *testing.T) {
	calls := 0
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil)), readyCheck: func(context.Context) (bool, string, error) {
		calls++
		if calls == 1 {
			return false, "", context.Canceled
		}
		return true, "", nil
	}}
	if ok, _ := s.readiness(context.Background()); ok {
		t.Errorf("a Canceled check answered ready")
	}
	if ok, why := s.readiness(context.Background()); !ok || calls != 2 {
		t.Errorf("after a Canceled check: ready %v %q in %d check(s), want ready in 2 (the Canceled answer not kept)", ok, why, calls)
	}
}

// TestOpenCopiesReadyzOption (B6f4 #3): Open copies the option the serve passes, the serve passes the config's
// web.readyz_without_login, and nothing else in the package writes the field - TestProbes builds its Server by hand,
// so a hard-wired 'true' in Open (/readyz open with the login on and the switch off) passed every row. The review
// B6f6 #3: the copy is Open's own top-level statement (one tab: a copy under a condition is not it), serve.go's line
// passes the config's value alone, and the field and the option are written once in the package and the serve
// command together, whatever their case (o.ReadyzWithoutLogin = true, cfg.Web.ReadyzWithoutLogin = true)
func TestOpenCopiesReadyzOption(t *testing.T) {
	for _, c := range []struct{ file, want, says string }{
		{"web.go", `(?m)^\ts\.readyzWithoutLogin = o\.ReadyzWithoutLogin$`, "Open does not copy o.ReadyzWithoutLogin into s.readyzWithoutLogin as its own statement"},
		{"../../cmd/pgvigil/serve.go", `(?m)^\s*ReadyzWithoutLogin:\s*cfg\.Web\.ReadyzWithoutLogin,\s*(?://.*)?$`, "serve does not pass cfg.Web.ReadyzWithoutLogin alone to web.Open"},
	} {
		b, err := os.ReadFile(c.file)
		if err != nil {
			t.Fatal(err)
		}
		if n := len(regexp.MustCompile(c.want).FindAllIndex(b, -1)); n != 1 {
			t.Errorf("%s (%s: %d match(es), want 1)", c.says, c.file, n)
		}
	}
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	cmd, err := filepath.Glob("../../cmd/pgvigil/*.go")
	if err != nil {
		t.Fatal(err)
	}
	files = append(files, cmd...)
	writes := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		writes += len(regexp.MustCompile(`(?i)\breadyzWithoutLogin\s*=[^=]`).FindAllIndex(b, -1))
	}
	if writes != 1 {
		t.Errorf("readyzWithoutLogin / ReadyzWithoutLogin is written %d time(s) in internal/web and cmd/pgvigil, want 1 (Open's copy)", writes)
	}
}
