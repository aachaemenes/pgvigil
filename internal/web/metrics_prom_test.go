package web

import (
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// TestPromNamesCoverTheCatalog freezes the B24d name table against metric_catalog as the migrations leave it: every
// file that defines the view is read in order (a full definition replaces the keys, an append to the live view adds
// its rows, a view of catalog rows the definition reads - the SQL Server counters - is read from its newest definer),
// and every key of the newest set has exactly one row in promNames OR is on promNotExported (a KEY with its words,
// never a family: PROMEXPORT's DECIDE 2 leaves counters.percent_log_used out alone), never both; every promNames row
// names a catalog key; the names are Prometheus names, unique, never '_total' (gauges), a per-database name only on
// the database family, and every unit has its conversion words. PROMEXPORT (D5, S6): the four SQL Server families'
// rows follow the name rule (promRuleName) but for the frozen exceptions, 43 counters, 2 xe, 1 waits, 5 collection;
// every family with a promNames row is one metrics_newest's newest definition reads.
func TestPromNamesCoverTheCatalog(t *testing.T) {
	cat, base, err := promCatalog(filepath.Join("..", "repo", "sql"))
	if err != nil {
		t.Fatal(err)
	}
	if len(base) != 62 {
		t.Fatalf("metric_catalog's VALUES in 0085: %d keys read (want 62: the table was written for 62)", len(base))
	}
	for k := range base {
		if _, ok := cat[k]; !ok {
			t.Errorf("%s: 0085's key is gone from the newest metric_catalog", k)
		}
	}
	t.Logf("metric_catalog: %d keys in the newest definition", len(cat))
	exportedFamilies := map[string]bool{}
	name := regexp.MustCompile(`^[a-zA-Z_:][a-zA-Z0-9_:]*$`)
	seen, names := map[string]bool{}, map[string]bool{}
	perFamily := map[string]int{}
	for _, p := range promNames {
		c, ok := cat[p.key]
		if !ok {
			t.Errorf("%s: not a metric_catalog key", p.key)
		}
		unit := c.unit
		exportedFamilies[c.family] = true
		if why, off := promNotExported[p.key]; off {
			t.Errorf("%s: a promNames row, and the key is on promNotExported (%s)", p.key, why)
		}
		if seen[p.key] {
			t.Errorf("%s: two rows", p.key)
		}
		seen[p.key] = true
		// the conversions that are not the catalog's unit: a count per interval exported per second, and the page
		// splits per 100 batches exported per batch (S6 c)
		conv := map[string]string{"database.deadlocks": "interval", "server.checkpoints": "interval", "server.checkpoints_req": "interval",
			"counters.page_splits_per_100_batches": "per_100"}[p.key]
		switch {
		case conv != "" && p.unit != conv:
			t.Errorf("%s: unit %q, want %q (the catalog's %q converted)", p.key, p.unit, conv, unit)
		case conv == "" && (p.unit == "interval" || p.unit == "per_100"):
			t.Errorf("%s: unit %q - 'interval' belongs on exactly the three per-interval counts, 'per_100' on the page splits per 100 batches", p.key, p.unit)
		case conv == "" && p.unit != unit:
			t.Errorf("%s: unit %q, the catalog says %q", p.key, p.unit, unit)
		}
		if f := c.family; f == "counters" || f == "xe" || f == "waits" || f == "collection" {
			want, frozen := promRuleExceptions[p.key]
			if !frozen {
				want = promRuleName(f, strings.TrimPrefix(p.key, f+"."), unit)
			}
			if p.name != want {
				t.Errorf("%s: name %q, the rule gives %q", p.key, p.name, want)
			}
			perFamily[f]++
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
	for k, c := range cat {
		if _, ok := promNotExported[k]; ok {
			continue
		}
		if !seen[k] {
			t.Errorf("metric_catalog key %s has no row in promNames and is not on promNotExported (family %s)", k, c.family)
		}
	}
	for k, why := range promNotExported {
		switch _, ok := cat[k]; {
		case !ok:
			t.Errorf("promNotExported names %s, not a metric_catalog key (the list holds keys, never a family)", k)
		case strings.TrimSpace(why) == "":
			t.Errorf("promNotExported names %s without its words", k)
		}
	}
	// DECIDE 2 (the lead 08:1x): Percent Log Used's _Total is the server's whole log space - one database's log near
	// full among empty ones reads low - so it is the one key left out, with its words, until per-database series come
	if len(promNotExported) != 1 || strings.TrimSpace(promNotExported["counters.percent_log_used"]) == "" {
		t.Errorf("promNotExported: %v - want counters.percent_log_used alone, with its words", promNotExported)
	}
	for f, n := range map[string]int{"counters": 43, "xe": 2, "waits": 1, "collection": 5} {
		if perFamily[f] != n {
			t.Errorf("family %s: %d promNames rows, want %d", f, perFamily[f], n)
		}
	}
	for k := range promRuleExceptions {
		if !seen[k] {
			t.Errorf("promRuleExceptions names %s, which has no promNames row", k)
		}
	}
	// a family with promNames rows is one metrics_newest reads: a family it does not read would be named and never sampled
	reads, err := promNewestReads(filepath.Join("..", "repo", "sql"))
	if err != nil || reads == "" {
		t.Fatalf("metrics_newest's newest definition: %q, %v", reads, err)
	}
	for f := range exportedFamilies {
		if !strings.Contains(reads, "'"+f+"'") {
			t.Errorf("the family %s has promNames rows and metrics_newest's newest definition does not read it", f)
		}
	}
}

// promRuleName is PROMEXPORT's name rule (D5, S6) for a key of the four SQL Server families: pgvigil_<family>_<metric>,
// a trailing _s read as _per_second, a percent as _ratio (its _pct dropped), milliseconds as _seconds (its _ms
// dropped), seconds with _seconds; the xe's per minute as _per_second, the waits' seconds per core per minute as
// _per_core_ratio. promRuleExceptions are the names the rule would get wrong, frozen with their reasons.
func promRuleName(family, metric, unit string) string {
	switch unit {
	case "per_min":
		return "pgvigil_" + family + "_" + strings.TrimSuffix(metric, "_per_min") + "_per_second"
	case "s_core_min":
		return "pgvigil_" + family + "_" + strings.TrimSuffix(metric, "_s_per_core_min") + "_per_core_ratio"
	}
	m, tail := metric, ""
	if strings.HasSuffix(m, "_s") {
		m, tail = strings.TrimSuffix(m, "_s"), "_per_second"
	}
	switch unit {
	case "pct":
		m = strings.TrimSuffix(m, "_pct") + "_ratio"
	case "ms":
		m = strings.TrimSuffix(m, "_ms") + "_seconds"
	case "secs":
		m += "_seconds"
	}
	return "pgvigil_" + family + "_" + m + tail
}

var promRuleExceptions = map[string]string{
	"counters.errors_total_s":              "pgvigil_counters_errors_per_second",                    // S6 e: not a counter's _total
	"counters.compiles_per_100_batches":    "pgvigil_counters_compilations_per_batch_ratio",         // S6 b: / 100 = per batch
	"counters.recompiles_per_100_compiles": "pgvigil_counters_recompilations_per_compilation_ratio", // S6 b
	"counters.page_splits_per_100_batches": "pgvigil_counters_page_splits_per_batch",                // S6 c: per_100
	"counters.ple_per_4gb":                 "pgvigil_counters_page_life_expectancy_per_4gb_seconds", // D5: the counter's own name
}

// promKey is a metric_catalog key's family and unit.
type promKey struct{ family, unit string }

// promStripComments blanks every '--' comment to its line's end outside a quoted literal (a doubled quote inside it), so
// a comment can neither end a definition's cut with its ';' nor be read as code.
func promStripComments(src string) string {
	var b strings.Builder
	b.Grow(len(src))
	in := false
	for i := 0; i < len(src); i++ {
		c := src[i]
		switch {
		case c == '\'':
			in = !in
		case !in && c == '-' && i+1 < len(src) && src[i+1] == '-':
			for i < len(src) && src[i] != '\n' {
				i++
			}
			if i < len(src) {
				b.WriteByte('\n')
			}
			continue
		case c == '\n':
			in = false // no literal of these files spans a line; a stray quote ends with its line
		}
		b.WriteByte(c)
	}
	return b.String()
}

// promCatalog reads metric_catalog's keys (key -> family, unit) as the migrations in dir leave it, and 0085's own keys.
// The files are read in their order, comments blanked (promStripComments); each definition of the view is cut from
// 'VIEW pgvigil.metric_catalog AS' to the first line ending in ';'. A definition inside an EXECUTE string of a DO
// block that reads the live definition (pg_get_viewdef of the same view) APPENDS its rows; any other REPLACES the set.
// A definition that reads another view of catalog rows (FROM pgvigil.<view>) takes that view's rows as the files
// leave it, by the same rules. Every mention of 'VIEW pgvigil.<view>' in a file (but COMMENT ON VIEW) must be a
// definition cut here, and each cut's rows begun ('(' at a line's start) must all be read: either miss is an error,
// never a quiet gap.
func promCatalog(dir string) (cat, base map[string]promKey, err error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		return nil, nil, err
	}
	sort.Strings(files)
	srcs := map[string]string{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return nil, nil, err
		}
		srcs[f] = promStripComments(string(b))
	}
	end := regexp.MustCompile(`;[ \t]*\n`)
	row := regexp.MustCompile(`\('(postgres|sqlserver|any)',\s*'([a-z_]+)',\s*'(?:[^']|'')*',\s*\d+,\s*'([a-z_0-9]+)',\s*'(?:[^']|'')*',\s*'([a-z_]+)',`)
	begun := regexp.MustCompile(`(?m)^\s*\('`)
	from := regexp.MustCompile(`FROM pgvigil\.([a-z_0-9]+)`)
	type cut struct {
		text   string
		append bool
	}
	cuts := func(f, view string) ([]cut, error) {
		src := srcs[f]
		marker := "VIEW pgvigil." + view + " AS"
		var out []cut
		for i := strings.Index(src, marker); i >= 0; {
			rest := src[i:]
			e := end.FindStringIndex(rest)
			if e == nil {
				return nil, fmt.Errorf("%s: view %s has no end after its CREATE", filepath.Base(f), view)
			}
			app := false
			if line := src[strings.LastIndexByte(src[:i], '\n')+1 : i]; strings.Contains(line, "EXECUTE '") {
				if do := strings.LastIndex(src[:i], "DO $"); do >= 0 && strings.Contains(src[do:i], "pg_get_viewdef('pgvigil."+view+"'") {
					app = true
				}
			}
			out = append(out, cut{rest[:e[1]], app})
			j := strings.Index(rest[e[1]:], marker)
			if j < 0 {
				break
			}
			i += e[1] + j
		}
		mention := regexp.MustCompile(`(?i)\bview\s+pgvigil\."?` + view + `"?\b`)
		comment := regexp.MustCompile(`(?i)\bcomment\s+on\s+view\s+pgvigil\."?` + view + `"?\b`)
		if n := len(mention.FindAllString(src, -1)) - len(comment.FindAllString(src, -1)); n != len(out) {
			return nil, fmt.Errorf("%s: %d definition(s) of pgvigil.%s, %d in the form this test reads ('VIEW pgvigil.%s AS'): read the others here", filepath.Base(f), n, view, len(out), view)
		}
		return out, nil
	}
	var keys func(view string, depth int) (map[string]promKey, map[string]promKey, error)
	keys = func(view string, depth int) (map[string]promKey, map[string]promKey, error) {
		if depth > 4 {
			return nil, nil, fmt.Errorf("view %s: catalog views read each other too deep", view)
		}
		set, own := map[string]promKey{}, map[string]promKey(nil)
		for _, f := range files {
			cs, err := cuts(f, view)
			if err != nil {
				return nil, nil, err
			}
			for _, c := range cs {
				part := map[string]promKey{}
				for _, m := range row.FindAllStringSubmatch(c.text, -1) {
					part[m[2]+"."+m[3]] = promKey{m[2], m[4]}
				}
				if n := len(begun.FindAllString(c.text, -1)); n != len(part) {
					return nil, nil, fmt.Errorf("%s (%s): %d catalog rows begun, %d read", filepath.Base(f), view, n, len(part))
				}
				if strings.HasSuffix(f, "0085_alert_rules.sql") {
					own = map[string]promKey{}
					for k, v := range part {
						own[k] = v
					}
				}
				for _, m := range from.FindAllStringSubmatch(c.text, -1) {
					inner, _, err := keys(m[1], depth+1)
					if err != nil {
						return nil, nil, err
					}
					if len(inner) == 0 {
						return nil, nil, fmt.Errorf("%s: %s reads pgvigil.%s, which gives no catalog rows", filepath.Base(f), view, m[1])
					}
					for k, v := range inner {
						part[k] = v
					}
				}
				if !c.append {
					set = map[string]promKey{}
				}
				for k, v := range part {
					set[k] = v
				}
			}
		}
		return set, own, nil
	}
	cat, base, err = keys("metric_catalog", 0)
	return cat, base, err
}

// promNewestReads is the text of metrics_newest's newest definition in dir (from its CREATE to its body's end), or the empty string.
func promNewestReads(dir string) (string, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		return "", err
	}
	sort.Strings(files)
	var text string
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return "", err
		}
		src := promStripComments(string(b))
		for i := strings.Index(src, "FUNCTION pgvigil.metrics_newest("); i >= 0; {
			e := strings.Index(src[i:], "$$;")
			if e < 0 {
				return "", fmt.Errorf("%s: metrics_newest has no body's end", filepath.Base(f))
			}
			text = src[i : i+e]
			j := strings.Index(src[i+e:], "FUNCTION pgvigil.metrics_newest(")
			if j < 0 {
				break
			}
			i += e + j
		}
	}
	return text, nil
}

// TestPromCatalogReadsEveryForm: promCatalog over small folders of migrations - a definer it cannot cut is an error,
// never a quiet pass; a '--' comment ending in ';' inside a definition does not cut it short; a full definition is
// full even when a comment in its file quotes the append's pg_get_viewdef call.
func TestPromCatalogReadsEveryForm(t *testing.T) {
	const head = "CREATE OR REPLACE VIEW pgvigil.metric_catalog AS\nSELECT * FROM (VALUES\n"
	row := func(metric string) string {
		return "    ('any', 'f', 'F', 1, '" + metric + "', 'a label', 'count', false, 600, 1),\n"
	}
	last := func(metric string) string {
		return "    ('any', 'f', 'F', 1, '" + metric + "', 'a label', 'count', false, 600, 1)\n  ) AS v(engine, family, family_label, family_sort, metric, label, unit, per_database, fresh_secs, sort);\n"
	}
	write := func(t *testing.T, files map[string]string) string {
		t.Helper()
		dir := t.TempDir()
		for n, body := range files {
			if err := os.WriteFile(filepath.Join(dir, n), []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		return dir
	}
	base := head + row("a") + last("b")
	t.Run("a definer it cannot cut", func(t *testing.T) {
		dir := write(t, map[string]string{"0001_a.sql": base,
			"0002_b.sql": "CREATE OR REPLACE VIEW pgvigil.metric_catalog (key, engine)\nAS SELECT * FROM (VALUES\n" + last("c")})
		if _, _, err := promCatalog(dir); err == nil {
			t.Fatalf("a definer written with a column list and AS on its next line was read as nothing (want an error naming it)")
		}
	})
	t.Run("a comment ending in a semicolon", func(t *testing.T) {
		dir := write(t, map[string]string{"0001_a.sql": head + row("a") + "    -- the next row (one more);\n" + last("b")})
		cat, _, err := promCatalog(dir)
		if err != nil || len(cat) != 2 {
			t.Fatalf("a definition with a comment ending in ';' above its last row: %d keys, %v (want 2)", len(cat), err)
		}
	})
	t.Run("a full definition whose comment quotes the append", func(t *testing.T) {
		dir := write(t, map[string]string{"0001_a.sql": base,
			"0002_b.sql": "-- unlike pg_get_viewdef('pgvigil.metric_catalog'::regclass), this file re-creates the view whole\n" + head + last("c")})
		cat, _, err := promCatalog(dir)
		if _, stale := cat["f.a"]; err != nil || stale || len(cat) != 1 {
			t.Fatalf("a full definition after a comment quoting the append: keys %v, %v (want f.c alone)", cat, err)
		}
	})
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
		// PROMEXPORT (S6 a, c): the xe's per minute and the waits' seconds per core per minute / 60, the page splits per
		// 100 batches / 100
		{"per_min", 120, nil, 2, true}, {"s_core_min", 30, nil, 0.5, true}, {"per_100", 250, nil, 2.5, true},
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
	padded := filepath.Join(dir, "padded")
	if err := os.WriteFile(padded, []byte("   "+strings.Repeat("p", 31)+"  \n"), 0o600); err != nil { // 37 bytes, 31 trimmed
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
		{MetricsConfig{Token: "file:" + padded}, true, true}, // the trim proven: 31 bytes once trimmed
	} {
		warns, err := CheckMetricsToken(&c.cfg, c.login)
		if (err != nil) != c.bad || len(warns) == 0 {
			t.Errorf("CheckMetricsToken(%q, login %v): %v (warns %d), want refused %v", c.cfg.Token, c.login, err, len(warns), c.bad)
		}
		// a value without file: / env: may be the token itself: never in the error
		if err != nil && !strings.HasPrefix(c.cfg.Token, "file:") && !strings.HasPrefix(c.cfg.Token, "env:") && c.cfg.Token != "" && strings.Contains(err.Error(), c.cfg.Token) {
			t.Errorf("the error prints the literal token: %v", err)
		}
	}
	if warns, _ := CheckMetricsToken(&MetricsConfig{}, true); !strings.Contains(strings.Join(warns, "|"), "metrics.token is not set") {
		t.Errorf("login on, no token: the WARN %q lacks 'metrics.token is not set'", warns)
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
	// the old token's 60 s end: refused after, the new one still accepted
	if st.token.match(tok, time.Now().Add(61*time.Second), func(string) {}) {
		t.Errorf("rotation: the old token still accepted 61 s after the change")
	}
	if !st.token.match(newTok, time.Now().Add(61*time.Second), func(string) {}) {
		t.Errorf("rotation: the new token refused 61 s after the change")
	}
	// the limiter: the address had 3 refused bearer attempts; two more fill it; a wrong token is then 429 and the
	// right one still passes (a shared address must not keep Prometheus out)
	for i := 0; i < 2; i++ {
		req("/metrics", map[string]string{"Authorization": "Bearer wrong"})
	}
	if w := req("/metrics", map[string]string{"Authorization": "Bearer wrong"}); w.Code != http.StatusTooManyRequests {
		t.Errorf("limiter: %d for a wrong token after 5 refused, want 429", w.Code)
	}
	if w := req("/metrics", map[string]string{"Authorization": "Bearer " + newTok}); w.Code != http.StatusOK {
		t.Errorf("limiter: the right token got %d during the lockout, want 200", w.Code)
	}
}

// TestPromGet (B24d review C7): the cache and the one render - a body aged 1.5 x cache is served at once and one render
// starts; eight concurrent gets during a held render start no second; a body aged 2.5 x cache with the render held past
// the wait is an error (the 503); the stored gzip decompresses to the body.
func TestPromGet(t *testing.T) {
	st := &promState{cfg: &MetricsConfig{CacheSeconds: 2}}
	cache := st.cfg.cache()
	release := make(chan struct{})
	var calls atomic.Int32
	started := make(chan struct{}, 16)
	render := func(ctx context.Context, _ *promState) ([]byte, error) {
		calls.Add(1)
		started <- struct{}{}
		select {
		case <-release:
		case <-ctx.Done():
		}
		return []byte("pgvigil_x 1\n"), nil
	}
	st.body, st.gz, st.at = []byte("old\n"), []byte("gz"), time.Now().Add(-cache*3/2)
	b, _, err := st.get(context.Background(), time.Second, render)
	if err != nil || string(b) != "old\n" {
		t.Fatalf("a body of 1.5 x cache: %q %v, want the old body at once", b, err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _, _ = st.get(context.Background(), 50*time.Millisecond, render) }()
	}
	wg.Wait()
	// the one render runs in its own goroutine and every get above returned the old body at once: wait until it has
	// started (on a loaded box it had not yet, and this read 0), then give a wrong second one the time to show
	select {
	case <-started:
	case <-time.After(10 * time.Second):
		t.Fatal("no render started within 10 s")
	}
	time.Sleep(100 * time.Millisecond)
	if n := calls.Load(); n != 1 {
		t.Errorf("renders started: %d, want 1", n)
	}
	st.mu.Lock()
	st.at = time.Now().Add(-cache * 5 / 2)
	st.mu.Unlock()
	if _, _, err := st.get(context.Background(), 100*time.Millisecond, render); err == nil {
		t.Errorf("a body of 2.5 x cache with the render held past the wait: no error, want one (the 503)")
	}
	close(release)
	deadline := time.Now().Add(2 * time.Second)
	for {
		st.mu.Lock()
		done := st.running == nil && string(st.body) == "pgvigil_x 1\n"
		gz := st.gz
		st.mu.Unlock()
		if done {
			zr, err := gzip.NewReader(bytes.NewReader(gz))
			if err != nil {
				t.Fatal(err)
			}
			out, err := io.ReadAll(zr)
			if err != nil || string(out) != "pgvigil_x 1\n" {
				t.Errorf("the gzip body: %q %v", out, err)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the render did not store its body")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
