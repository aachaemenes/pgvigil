package web

import (
	"os"
	"strings"
	"testing"
)

// TestAzureDBServiceObjectivesOnItsPage (control audit row A6: DBA Dash's "Azure Service Objectives" tab of one Azure
// database's Configuration node, MainNodes L1704-1713): the Azure SQL Database page shows its own tier changes - the
// Azure Summary's slo_history read cut to the instance (ids=, bound since review t11-7's fold) - with DBA Dash's Old
// Config Valid From (the history's prev_from, now selected as old_valid_from).
func TestAzureDBServiceObjectivesOnItsPage(t *testing.T) {
	q, err := os.ReadFile("q_azuredb.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(q), "h.prev_from AS old_valid_from") {
		t.Error("sqlAzureSLOHistory does not select the old configuration's start (h.prev_from AS old_valid_from)")
	}
	b, err := os.ReadFile("../../web/src/azuredb.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "export async function mssqlAzureView(")
	j := strings.Index(src, "export async function azureSummaryView(")
	if i < 0 || j < 0 {
		t.Fatal("azuredb.ts: mssqlAzureView or azureSummaryView not found")
	}
	page := src[i:]
	if j > i {
		page = src[i:j]
	}
	for _, want := range []string{"part: 'slo_history'", "ids: String(ctx.instance)", "old_valid_from", "Service Objectives (changes)"} {
		if !strings.Contains(page, want) {
			t.Errorf("mssqlAzureView lacks %q", want)
		}
	}
}
