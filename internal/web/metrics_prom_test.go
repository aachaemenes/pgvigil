package web

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// TestPromNamesCoverTheCatalog freezes the B24d name table: every row of metric_catalog's VALUES (0085, the only
// migration that defines the view) has exactly one row in promNames and every promNames row names a catalog key; the
// names are Prometheus names, unique, never '_total' (gauges), a per-database name only on the database family, and
// every unit has its conversion words.
func TestPromNamesCoverTheCatalog(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "repo", "sql", "0085_alert_rules.sql"))
	if err != nil {
		t.Fatal(err)
	}
	row := regexp.MustCompile(`(?m)^\s*\('(postgres|sqlserver|any)',\s*'([a-z_]+)',\s*'[^']*',\s*\d+,\s*'([a-z_0-9]+)',\s*'[^']*',\s*'([a-z_]+)',`)
	cat := map[string]string{}
	for _, m := range row.FindAllStringSubmatch(string(b), -1) {
		cat[m[2]+"."+m[3]] = m[4]
	}
	if len(cat) != 62 {
		t.Fatalf("metric_catalog's VALUES in 0085: %d keys read (want 62: the table was written for 62)", len(cat))
	}
	name := regexp.MustCompile(`^[a-zA-Z_:][a-zA-Z0-9_:]*$`)
	seen, names := map[string]bool{}, map[string]bool{}
	for _, p := range promNames {
		unit, ok := cat[p.key]
		if !ok {
			t.Errorf("%s: not a metric_catalog key", p.key)
		}
		if seen[p.key] {
			t.Errorf("%s: two rows", p.key)
		}
		seen[p.key] = true
		want := map[string]string{"database.deadlocks": "count", "server.checkpoints": "count", "server.checkpoints_req": "count"}[p.key]
		if p.unit == "interval" && want != unit {
			t.Errorf("%s: 'interval' on a key that is not a per-interval count", p.key)
		} else if p.unit != "interval" && p.unit != unit {
			t.Errorf("%s: unit %q, the catalog says %q", p.key, p.unit, unit)
		}
		if _, ok := promUnitWords[p.unit]; !ok {
			t.Errorf("%s: no conversion words for unit %q", p.key, p.unit)
		}
		for _, n := range []string{p.name, p.dbName} {
			if n == "" {
				continue
			}
			if !name.MatchString(n) || !strings.HasPrefix(n, "pgvigil_") || strings.HasSuffix(n, "_total") {
				t.Errorf("%s: name %q (a Prometheus name, pgvigil_ first, no _total on a gauge)", p.key, n)
			}
			if names[n] {
				t.Errorf("%s: name %q twice", p.key, n)
			}
			names[n] = true
		}
		if (p.dbName != "") != strings.HasPrefix(p.key, "database.") {
			t.Errorf("%s: a per-database name only on the database family", p.key)
		}
		if strings.HasPrefix(p.key, "database.") && !strings.HasPrefix(p.name, "pgvigil_instance_") {
			t.Errorf("%s: the instance total is a pgvigil_instance_* name, apart from the per-database series", p.key)
		}
	}
	for k := range cat {
		if !seen[k] {
			t.Errorf("metric_catalog key %s has no row in promNames", k)
		}
	}
}

func TestPromValueAndEscape(t *testing.T) {
	sec := int32(60)
	for _, c := range []struct {
		unit string
		in   float64
		secs *int32
		want float64
		ok   bool
	}{
		{"pct", 87.5, nil, 0.875, true}, {"ms", 1500, nil, 1.5, true}, {"mb", 1.5, nil, 1572864, true},
		{"interval", 3, &sec, 0.05, true}, {"interval", 3, nil, 0, false}, {"count", 7, nil, 7, true},
	} {
		got, ok := promValue(c.unit, c.in, c.secs)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("promValue(%s, %v): %v %v, want %v %v", c.unit, c.in, got, ok, c.want, c.ok)
		}
	}
	if got := promEscape("a\"b\\c\nd"); got != `a\"b\\c\nd` {
		t.Errorf("promEscape: %q", got)
	}
}

// TestPromBodyLayout: metric-first - one HELP and one TYPE per name, every sample of a name together even when added
// apart, a name without a sample left out.
func TestPromBodyLayout(t *testing.T) {
	var b promBody
	b.declare("pgvigil_a", "gauge", "A.")
	b.declare("pgvigil_b", "gauge", "B.")
	b.declare("pgvigil_empty", "gauge", "never sampled")
	b.add("pgvigil_a", [][2]string{{"server", `s"1`}}, 1)
	b.add("pgvigil_b", [][2]string{{"server", "s1"}}, 2)
	b.add("pgvigil_a", [][2]string{{"server", "s2"}}, 0.5)
	want := "# HELP pgvigil_a A.\n# TYPE pgvigil_a gauge\npgvigil_a{server=\"s\\\"1\"} 1\npgvigil_a{server=\"s2\"} 0.5\n" +
		"# HELP pgvigil_b B.\n# TYPE pgvigil_b gauge\npgvigil_b{server=\"s1\"} 2\n"
	if got := string(b.bytes()); got != want {
		t.Errorf("body:\n%s\nwant:\n%s", got, want)
	}
}

func TestCheckMetricsToken(t *testing.T) {
	dir := t.TempDir()
	short, long := filepath.Join(dir, "short"), filepath.Join(dir, "long")
	if err := os.WriteFile(short, []byte("abc\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(long, []byte("  "+strings.Repeat("k", 32)+"\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PGV_B24D_EMPTY", "  ")
	for _, c := range []struct {
		cfg   MetricsConfig
		login bool
		bad   bool
	}{
		{MetricsConfig{}, false, true},                              // -no-login and no token
		{MetricsConfig{}, true, false},                              // the login on: a browser can read it (a WARN)
		{MetricsConfig{Token: "file:" + short}, true, true},         // under 32 bytes
		{MetricsConfig{Token: "env:PGV_B24D_EMPTY"}, true, true},    // empty after trimming
		{MetricsConfig{Token: "file:" + long}, false, false},        // 32 bytes, whitespace trimmed
		{MetricsConfig{Token: strings.Repeat("k", 40)}, true, true}, // the token itself in the file: refused
		{MetricsConfig{Token: "file:" + filepath.Join(dir, "none")}, true, true},
	} {
		warns, err := CheckMetricsToken(&c.cfg, c.login)
		if (err != nil) != c.bad || len(warns) == 0 {
			t.Errorf("CheckMetricsToken(%q, login %v): %v (warns %d), want refused %v", c.cfg.Token, c.login, err, len(warns), c.bad)
		}
	}
}

// TestPromMetricsDoor (P3 without a store): the body is pre-rendered, so every row is the gate's.
func TestPromMetricsDoor(t *testing.T) {
	dir := t.TempDir()
	tokFile := filepath.Join(dir, "token")
	tok := strings.Repeat("a", 31) + "Z"
	if err := os.WriteFile(tokFile, []byte(tok+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil))} // s.auth nil: -no-login
	req := func(path string, h map[string]string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, path, nil)
		r.RemoteAddr = "192.0.2.7:5000"
		for k, v := range h {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		s.PromMetrics(w, r)
		return w
	}
	if w := req("/metrics", nil); w.Code != http.StatusNotFound || !strings.Contains(w.Body.String(), "doors.prometheus_metrics") {
		t.Fatalf("off: %d %s", w.Code, w.Body.String())
	}
	s.EnableMetrics(&MetricsConfig{Token: "file:" + tokFile})
	defer s.EnableMetrics(nil)
	st := s.prom()
	st.body, st.gz, st.at = []byte("pgvigil_sessions{server=\"a\",engine=\"postgres\"} 1\n"), []byte("gz"), time.Now()
	for _, c := range []struct {
		name string
		path string
		h    map[string]string
		want int
	}{
		{"no credentials", "/metrics", nil, 401},
		{"a stale cookie under -no-login", "/metrics", map[string]string{"Cookie": "pgvigil_session=stale"}, 401},
		{"a wrong token", "/metrics", map[string]string{"Authorization": "Bearer " + strings.Repeat("b", 32)}, 401},
		{"the last byte differs", "/metrics", map[string]string{"Authorization": "Bearer " + strings.Repeat("a", 31) + "Y"}, 401},
		{"'Bearer ' empty", "/metrics", map[string]string{"Authorization": "Bearer "}, 401},
		{"a token in the URL", "/metrics?token=" + tok, nil, 400},
		{"the token", "/metrics", map[string]string{"Authorization": "Bearer " + tok}, 200},
	} {
		if w := req(c.path, c.h); w.Code != c.want {
			t.Errorf("%s: %d %s, want %d", c.name, w.Code, w.Body.String(), c.want)
		} else if c.want == 200 && w.Header().Get("Content-Type") != promContentType {
			t.Errorf("%s: Content-Type %q", c.name, w.Header().Get("Content-Type"))
		}
	}
	if w := req("/metrics", map[string]string{"Authorization": "Bearer " + tok, "Accept-Encoding": "gzip"}); w.Code != 200 ||
		w.Header().Get("Content-Type") != promContentType || w.Header().Get("Content-Encoding") != "gzip" {
		t.Errorf("gzip: %d, Content-Type %q, Content-Encoding %q", w.Code, w.Header().Get("Content-Type"), w.Header().Get("Content-Encoding"))
	}
	if n := st.refused.Load(); n != 6 {
		t.Errorf("refused counter %d, want 6", n)
	}
	// rotation: a new file, the old token still accepted for 60 s, the new one at once
	newTok := strings.Repeat("n", 40)
	if err := os.WriteFile(tokFile, []byte(newTok), 0o600); err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(tokFile, later, later); err != nil {
		t.Fatal(err)
	}
	st.token.checked = time.Time{}
	for _, k := range []string{newTok, tok} {
		if w := req("/metrics", map[string]string{"Authorization": "Bearer " + k}); w.Code != 200 {
			t.Errorf("rotation: %d for the %s token", w.Code, map[bool]string{true: "new", false: "old"}[k == newTok])
		}
	}
	// the limiter: the address had 3 refused bearer attempts; two more fill it, the sixth is 429
	for i := 0; i < 2; i++ {
		req("/metrics", map[string]string{"Authorization": "Bearer wrong"})
	}
	if w := req("/metrics", map[string]string{"Authorization": "Bearer " + newTok}); w.Code != http.StatusTooManyRequests {
		t.Errorf("limiter: %d after 5 refused tokens, want 429", w.Code)
	}
}
