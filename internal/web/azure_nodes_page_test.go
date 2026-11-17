package web

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestAzureNodePagesAreWired (P25 task 7: DBA Dash's logical server and elastic pool nodes): a logical server and an
// elastic pool each have a page of the root - web/src/azure_nodes.ts's azureServerView (#/azureserver?server=) and
// azurePoolView (#/azurepool?server=&pool=), each the Azure Summary read cut to its node - named in router.ts
// rootTabs, marked SQL Server's in pageEngine, drawn by main.ts rootPages, and their server / pool kept by a range
// change. The check reads the source.
func TestAzureNodePagesAreWired(t *testing.T) {
	read := func(file string) string {
		t.Helper()
		b, err := os.ReadFile("../../web/src/" + file)
		if err != nil {
			t.Fatalf("web/src/%s: %v", file, err)
		}
		return string(b)
	}
	page := read("azure_nodes.ts")
	for _, w := range []string{"export async function azureServerView(", "export async function azurePoolView(", "hashParam('server')", "hashParam('pool')"} {
		if !strings.Contains(page, w) {
			t.Errorf("azure_nodes.ts has no %s", w)
		}
	}
	if !regexp.MustCompile(`azureSummaryView\(ctx, \{[^}]*server`).MatchString(page) {
		t.Error("azure_nodes.ts draws no Azure Summary cut to the node (azureSummaryView(ctx, { server ... }))")
	}
	if !regexp.MustCompile(`export async function azureSummaryView\(ctx: Ctx, node\?: `).MatchString(read("azuredb.ts")) {
		t.Error("azuredb.ts azureSummaryView takes no node (the server / pool cut)")
	}
	router := read("router.ts")
	if !regexp.MustCompile(`rootTabs: Record<string, string> = \{[^}]*\bazureserver: 'Logical server'[^}]*\bazurepool: 'Elastic pool'`).MatchString(router) {
		t.Error("router.ts rootTabs has no azureserver: 'Logical server' / azurepool: 'Elastic pool' (the pages would open the Summary)")
	}
	if !regexp.MustCompile(`pageEngine: Record<string, 'sqlserver' \| 'postgres'> = \{[^}]*\bazureserver: 'sqlserver', azurepool: 'sqlserver'`).MatchString(router) {
		t.Error("router.ts pageEngine does not mark azureserver / azurepool SQL Server's")
	}
	if !regexp.MustCompile(`c\.tab === 'azureserver' \|\| c\.tab === 'azurepool'\)\) \{[^}]*for \(const k of \['server', 'pool'\]\)`).MatchString(router) {
		t.Error("router.ts: a range change on azureserver / azurepool keeps no server / pool")
	}
	if !regexp.MustCompile(`const rootPages: Record<string, Render> = \{[^\n]*\bazureserver: azureServerView, azurepool: azurePoolView\b`).MatchString(read("main.ts")) {
		t.Error("main.ts rootPages has no azureserver: azureServerView, azurepool: azurePoolView")
	}
}
