package web

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestEveryMSSQLTabHasAPage: every tab of a SQL Server instance (web/src/router.ts mssqlInstanceTabs) has its page in
// web/src/main.ts mssqlPages, or in reports.ts reportPages, which mssqlPages spreads in. A tab without one opens the
// Summary (main.ts falls back to it), as the Schema tab did on the j16 candidate (review B #4: A26-PG listed the tab and
// the page map kept only the PostgreSQL entry). The check reads the source.
func TestEveryMSSQLTabHasAPage(t *testing.T) {
	block := func(file, head string) string {
		t.Helper()
		b, err := os.ReadFile("../../web/src/" + file)
		if err != nil {
			t.Fatal(err)
		}
		i := strings.Index(string(b), head)
		if i < 0 {
			t.Fatalf("web/src/%s has no %q", file, head)
		}
		j := strings.Index(string(b)[i:], "\n};")
		if j < 0 {
			t.Fatalf("web/src/%s: %q has no end", file, head)
		}
		return string(b)[i : i+j]
	}
	tabs := regexp.MustCompile(`[{ ,\n]\s*([a-z_0-9]+): '`).FindAllStringSubmatch(block("router.ts", "export const mssqlInstanceTabs: Record<string, string> = {"), -1)
	if len(tabs) == 0 {
		t.Fatal("router.ts mssqlInstanceTabs: no tab read")
	}
	key := regexp.MustCompile(`(?:^|[{,\n])\s*([a-z_0-9]+):`)
	pages := map[string]bool{}
	for _, b := range []string{block("main.ts", "const mssqlPages: Record<string, Render> = {"), block("reports.ts", "export const reportPages: Record<string, Render> = {")} {
		for _, m := range key.FindAllStringSubmatch(b, -1) {
			pages[m[1]] = true
		}
	}
	for _, m := range tabs {
		if !pages[m[1]] {
			t.Errorf("the SQL Server tab %q has no page in main.ts mssqlPages (nor reports.ts reportPages): it opens the Summary", m[1])
		}
	}
}
