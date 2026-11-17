package web

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestAzureDBTierLimitsWordsNameTheirHistory (control audit row X2): the Azure SQL Database page's "The tier's limits"
// paragraph said their history is on Properties (Changes). 0145's Properties rows track only the tier (service
// objective, elastic pool, DTU and vCore limit: 'tracked' true); the grid's limits (max size, max sessions, worker
// threads, log rate) are 'tracked' false, and the Azure Summary's Service Objectives (changes) (sqlAzureSLOHistory) lists
// the same tier columns only. The words say where the tier's changes are (both, linked) and that a change of these
// limits alone is listed on no page.
func TestAzureDBTierLimitsWordsNameTheirHistory(t *testing.T) {
	b, err := os.ReadFile("../../web/src/azuredb.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if strings.Contains(src, "their history is on Properties (Changes)") {
		t.Error("azuredb.ts still says the tier limits' history is on Properties (Changes)")
	}
	m := regexp.MustCompile(`(?s)el\('h3', \{\}, 'The tier\\'s limits'\),(.*?)grid\(limits,`).FindStringSubmatch(src)
	if m == nil {
		t.Fatal("azuredb.ts: no \"The tier's limits\" heading before the limits grid")
	}
	for _, want := range []string{"Service Objectives (changes)", "tab: 'azuresummary'", "Properties (Changes)", "tab: mssqlPropertiesTab", "listed on no page"} {
		if !strings.Contains(m[1], want) {
			t.Errorf("azuredb.ts: the tier's limits words lack %q: %s", want, strings.TrimSpace(m[1]))
		}
	}
	q, err := os.ReadFile("q_azuredb.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(q), `{"slo_history", sqlAzureSLOHistory, args}`) {
		t.Error("q_azuredb.go: the Azure Summary no longer serves slo_history (the words would point nowhere)")
	}
}
