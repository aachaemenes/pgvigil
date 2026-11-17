package web

import (
	"os"
	"strings"
	"testing"
)

// TestAzureSummaryHiddenByDefault (control audit row A7; the lead's 11-17 14:37): DBA Dash hides by default the Azure
// Summary's four histograms and its Allocated / Used / Max Storage Size MB columns (AzureSummary.Designer.cs L274-504,
// IsVisible false); the Azure Summary grid's table names them in data-default-hidden (the grid tools' column names), and
// join line 14 asks the shared grid's owner (relw4-s1, row group G) for gridtools.ts load() to honour it.
func TestAzureSummaryHiddenByDefault(t *testing.T) {
	b, err := os.ReadFile("../../web/src/azuredb.ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `defaultHidden(grid(rows, [`) ||
		!strings.Contains(string(b), `['CPU histogram', 'data IO histogram', 'log write histogram', 'DTU histogram', 'allocated', 'used', 'max size']`) {
		t.Error("azuredb.ts: the Azure Summary grid does not name DBA Dash's hidden-by-default columns in data-default-hidden")
	}
	j, err := os.ReadFile("../../scripts/PARITY-S3-join-lines.sql")
	if err != nil {
		t.Fatal(err)
	}
	if i := strings.Index(string(j), "-- 14. "); i < 0 || !strings.Contains(string(j)[i:], "data-default-hidden") || !strings.Contains(string(j)[i:], "load()") {
		t.Error("join line 14 (gridtools.ts load() honouring data-default-hidden) is missing")
	}
}
