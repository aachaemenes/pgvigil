package web

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// migrationTexts: the embedded migrations' texts in apply order
func migrationTexts(t *testing.T) []string {
	t.Helper()
	files, err := filepath.Glob("../repo/sql/*.sql")
	if err != nil || len(files) == 0 {
		t.Fatalf("no migrations read: %v", err)
	}
	sort.Strings(files)
	out := make([]string, 0, len(files))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, string(b))
	}
	return out
}

// viewBody: the body of the last CREATE [OR REPLACE] VIEW pgvigil.<name> [(columns)] AS in srcs (apply order: the one
// PostgreSQL keeps), to the next blank line after a ';'; "" when none defines it (a table, a function)
func viewBody(srcs []string, name string) string {
	head := regexp.MustCompile(`CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\s+pgvigil\.` + regexp.QuoteMeta(name) + `(?:\s*\([^)]*\))?\s+AS\b`)
	end := regexp.MustCompile(`;\s*\n\s*\n`)
	body := ""
	for _, s := range srcs {
		locs := head.FindAllStringIndex(s, -1)
		if len(locs) == 0 {
			continue
		}
		rest := s[locs[len(locs)-1][1]:]
		if j := end.FindStringIndex(rest); j != nil {
			rest = rest[:j[0]]
		}
		body = rest
	}
	return body
}

var (
	armFrom   = regexp.MustCompile(`FROM\s+pgvigil\.(\w+)(\s*\()?`)
	ownSource = regexp.MustCompile(`'pgvigil (?:collector|repository)'(?:::text)?\s+AS\s+source\b`)
	anySource = regexp.MustCompile(`'[^']*'(?:::text)?\s+AS\s+source\b`)
)

// ownArms (B6f4 #2): the arms of pgvigil.findings AND pgvigil.alert_findings (403b's K3 is alert_findings' arm, never
// findings': its ck CTE reads findings) whose rows are pgvigil's own - the arm names 'pgvigil collector' or 'pgvigil
// repository' AS source - followed one level into an arm that names no source of its own (a union of arms, as 403b's
// alert_channel_findings); missing: those query reads no FROM of; fns: an arm that is a function (its rows cannot be
// read here: the caller fails on it, never a skip)
func ownArms(srcs []string, query string) (own, missing, fns []string) {
	seen := map[string]bool{"findings": true, "alert_findings": true}
	var walk func(body string, depth int)
	walk = func(body string, depth int) {
		for _, m := range armFrom.FindAllStringSubmatch(body, -1) {
			arm := m[1]
			if seen[arm] {
				continue
			}
			seen[arm] = true
			if m[2] != "" {
				fns = append(fns, arm)
				continue
			}
			v := viewBody(srcs, arm)
			switch {
			case v == "":
				// a table: no arm
			case ownSource.MatchString(v):
				own = append(own, arm)
				if !regexp.MustCompile(`FROM\s+pgvigil\.` + arm + `\b`).MatchString(query) {
					missing = append(missing, arm)
				}
			case depth == 0 && !anySource.MatchString(v):
				walk(v, 1)
			}
		}
	}
	walk(viewBody(srcs, "findings"), 0)
	walk(viewBody(srcs, "alert_findings"), 0)
	return own, missing, fns
}

// TestCollectorFindingsReadsItsArms (B6.2 part c #5; B6f4 #2): the Collector page's findings read every arm of
// pgvigil.findings and pgvigil.alert_findings whose rows are pgvigil's own (source 'pgvigil collector' or 'pgvigil
// repository') straight from that arm's view, never pgvigil.findings itself - a filter on source cannot pass its
// DISTINCT ON, so a fleet-wide load built every arm. An arm joined later turns this red until the page reads it too:
// 403b's K3 by its arms (TestCollectorFindingsK3AtTheJoin) and by name below.
func TestCollectorFindingsReadsItsArms(t *testing.T) {
	if regexp.MustCompile(`pgvigil\.findings\b`).MatchString(sqlCollectorFindings) {
		t.Errorf("sqlCollectorFindings reads pgvigil.findings: a fleet-wide load builds every arm of it")
	}
	srcs := migrationTexts(t)
	if viewBody(srcs, "findings") == "" || viewBody(srcs, "alert_findings") == "" {
		t.Fatal("no migration defines pgvigil.findings or pgvigil.alert_findings")
	}
	own, missing, fns := ownArms(srcs, sqlCollectorFindings)
	for _, arm := range missing {
		t.Errorf("the arm %s gives pgvigil's own findings, and sqlCollectorFindings does not read it", arm)
	}
	for _, fn := range fns {
		t.Errorf("an arm is the function pgvigil.%s: the source of its rows cannot be read here - read it in sqlCollectorFindings and name it in this test", fn)
	}
	if len(own) < 4 {
		t.Errorf("%d arms give pgvigil's own findings (%v), want at least 4 (0121's and 0166's three): the arm reading broke", len(own), own)
	}
	// K3 by name: once a migration defines 403b's view, the page reads it (B6 design: B6.4 shows it)
	if viewBody(srcs, "alert_channel_failing") != "" && !regexp.MustCompile(`FROM\s+pgvigil\.alert_channel_failing\b`).MatchString(sqlCollectorFindings) {
		t.Errorf("a migration defines pgvigil.alert_channel_failing (403b's K3) and sqlCollectorFindings does not read it")
	}
}

// k3Join: 403b's three views as rel-sqltb-s2 759e28e0's 0154 defines them (L1324, L1416, L1428; bodies cut to their
// source lines) and 0190's alert_findings with the third arm its wiring patch adds (proof-alert-scope-wiring.patch)
const k3Join = `CREATE OR REPLACE VIEW pgvigil.alert_channel_failing AS
SELECT NULL::int AS instance_id, 'warning'::text AS severity, 'alert channel failing'::text AS setting, c.name AS value,
       'pgvigil repository'::text AS source, c.since AS at
  FROM pgvigil.alert_channels c;

CREATE OR REPLACE VIEW pgvigil.alert_channel_quota_low AS
SELECT NULL::int AS instance_id, 'warning'::text AS severity, 'pushover quota low'::text AS setting, q.channel AS value,
       'pgvigil repository'::text AS source, q.at AS at
  FROM pgvigil.alert_channel_quota q;

CREATE OR REPLACE VIEW pgvigil.alert_channel_findings AS
SELECT f.instance_id, f.severity, f.setting, f.value, f.suggested, f.detail, f.source, f.at FROM pgvigil.alert_channel_failing f
UNION ALL
SELECT q.instance_id, q.severity, q.setting, q.value, q.suggested, q.detail, q.source, q.at FROM pgvigil.alert_channel_quota_low q;

CREATE OR REPLACE VIEW pgvigil.alert_findings AS
SELECT f.* FROM (SELECT x.* FROM pgvigil.findings x
                 UNION ALL
                 SELECT y.* FROM pgvigil.alert_rule_findings y
                 UNION ALL
                 SELECT z.* FROM pgvigil.alert_channel_findings z) f;

`

// TestCollectorFindingsK3AtTheJoin (B6f4 #2): at the B6 x 403b join, K3 is alert_findings' third arm through
// alert_channel_findings (never findings': its ck CTE reads findings) - the walk finds both of 403b's own-source views
// and names them until the page reads them; a page that reads them passes. The page's claim CASE and 'pushover quota
// low' on the page are the join's WIRING lines.
func TestCollectorFindingsK3AtTheJoin(t *testing.T) {
	srcs := append(migrationTexts(t), k3Join)
	_, missing, _ := ownArms(srcs, sqlCollectorFindings)
	for _, want := range []string{"alert_channel_failing", "alert_channel_quota_low"} {
		found := false
		for _, m := range missing {
			found = found || m == want
		}
		if !found {
			t.Errorf("at the join the walk does not name %s as unread (missing %v)", want, missing)
		}
	}
	read := sqlCollectorFindings + `
UNION ALL SELECT instance_id FROM pgvigil.alert_channel_failing
UNION ALL SELECT instance_id FROM pgvigil.alert_channel_quota_low`
	if _, m, _ := ownArms(srcs, read); len(m) != 0 {
		t.Errorf("a page that reads 403b's two views still misses %v", m)
	}
}

// TestCollectorMinutesLongest (B6.2 part c #8): the per-minute duration chart draws the minute's longest run beside its
// p95 - one collection running long among a minute's 200 runs moves no p95
func TestCollectorMinutesLongest(t *testing.T) {
	if !regexp.MustCompile(`max\(dur_ms_max\)[^,]*AS max_ms`).MatchString(sqlCollectorMinutes) {
		t.Errorf("sqlCollectorMinutes gives no max(dur_ms_max) AS max_ms per minute")
	}
	b, err := os.ReadFile("../../web/src/collector.ts")
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	i := strings.Index(s, "lineChart('Run duration per minute")
	if i < 0 {
		t.Fatal("collector.ts has no 'Run duration per minute' chart")
	}
	call := s[i:]
	if j := strings.Index(call, "\n"); j > 0 {
		call = call[:j]
	}
	if !strings.Contains(call, "key: 'max_ms'") {
		t.Errorf("the run duration chart draws no max_ms series: %s", call)
	}
}
