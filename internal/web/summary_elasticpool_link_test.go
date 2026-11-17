package web

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestSummaryElasticPoolTestLinksAzureSummary (control audit row X3; refwalk-s3's Summary list T2 #17): DBA Dash's
// Summary test 'Elastic Pool Storage' opens the Azure Summary (Summary.cs L68); pgvigil's fleet Summary filtered the
// instance grid instead, though the root Azure Summary page exists (rootTabs' azuresummary). The test's key
// (fleet.ts: elasticpool) maps to it in pages.ts's rootTabOf, so testLink draws a link. The walker
// (scripts/parity-s3-pages.mjs, summary-elasticpool) reads the link the demo's Summary really draws.
func TestSummaryElasticPoolTestLinksAzureSummary(t *testing.T) {
	b, err := os.ReadFile("../../web/src/pages.ts")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)const rootTabOf: Record<string, string> = \{(.*?)\};`).FindStringSubmatch(string(b))
	if m == nil {
		t.Fatal("pages.ts: no rootTabOf map")
	}
	if !strings.Contains(m[1], "elasticpool: 'azuresummary'") {
		t.Errorf("pages.ts: rootTabOf has no elasticpool: 'azuresummary' (the Elastic Pool Storage test filters instead of opening the Azure Summary): %s", strings.TrimSpace(m[1]))
	}
	f, err := os.ReadFile("../../web/src/fleet.ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(f), "{ key: 'elasticpool', label: 'Elastic Pool Storage'") {
		t.Error("fleet.ts: the Elastic Pool Storage test's key is no longer elasticpool")
	}
	r, err := os.ReadFile("../../web/src/router.ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(r), "azuresummary: 'Azure Summary'") {
		t.Error("router.ts: no root azuresummary page for the link to open")
	}
}
