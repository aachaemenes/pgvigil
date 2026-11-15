package web

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// newestView: the body of the newest embedded migration's CREATE OR REPLACE VIEW pgvigil.<name> (to the next blank
// line followed by a statement or a comment), "" when none defines it (a table)
func newestView(t *testing.T, name string) string {
	t.Helper()
	files, err := filepath.Glob("../repo/sql/*.sql")
	if err != nil || len(files) == 0 {
		t.Fatalf("no migrations read: %v", err)
	}
	sort.Strings(files)
	head := "CREATE OR REPLACE VIEW pgvigil." + name + " AS"
	body := ""
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		s := string(b)
		if i := strings.Index(s, head); i >= 0 {
			rest := s[i+len(head):]
			if j := regexp.MustCompile(`;\s*\n\s*\n`).FindStringIndex(rest); j != nil {
				rest = rest[:j[0]]
			}
			body = rest
		}
	}
	return body
}

// TestCollectorFindingsReadsItsArms (B6.2 part c #5): the Collector page's findings read every arm of pgvigil.findings
// whose rows are pgvigil's own (source 'pgvigil collector' or 'pgvigil repository') straight from that arm's view, never
// pgvigil.findings itself - a filter on source cannot pass its DISTINCT ON, so a fleet-wide load built every arm. An
// arm joined later (403b's K3) turns this red until the page reads it too.
func TestCollectorFindingsReadsItsArms(t *testing.T) {
	if regexp.MustCompile(`pgvigil\.findings\b`).MatchString(sqlCollectorFindings) {
		t.Errorf("sqlCollectorFindings reads pgvigil.findings: a fleet-wide load builds every arm of it")
	}
	findings := newestView(t, "findings")
	if findings == "" {
		t.Fatal("no migration defines pgvigil.findings")
	}
	own := 0
	seen := map[string]bool{}
	for _, m := range regexp.MustCompile(`FROM pgvigil\.(\w+)`).FindAllStringSubmatch(findings, -1) {
		arm := m[1]
		if seen[arm] {
			continue
		}
		seen[arm] = true
		v := newestView(t, arm)
		if !strings.Contains(v, "'pgvigil collector'") && !strings.Contains(v, "'pgvigil repository'") {
			continue
		}
		own++
		if !regexp.MustCompile(`FROM pgvigil\.` + arm + `\b`).MatchString(sqlCollectorFindings) {
			t.Errorf("pgvigil.findings' arm %s gives pgvigil's own findings, and sqlCollectorFindings does not read it", arm)
		}
	}
	if own < 4 {
		t.Errorf("%d arms of pgvigil.findings give pgvigil's own findings, want at least 4 (0121's and 0166's three): the arm reading broke", own)
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
