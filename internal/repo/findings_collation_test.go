package repo

import (
	"os"
	"strings"
	"testing"
)

// TestFindingsValueCollation (B6's box run vis-b6r1, 11-15: 0190 failed on a fresh store with 42P16): a findings
// arm's value built from a catalog name (relname, nspname: type name, collation "C") carries COLLATE "default", or
// pgvigil.findings - its value text with the default collation since 0110 - cannot be re-created over it
func TestFindingsValueCollation(t *testing.T) {
	b, err := os.ReadFile("sql/0166_collection_health.sql")
	if err != nil {
		t.Fatal(err)
	}
	for i, l := range strings.Split(string(b), "\n") {
		if strings.Contains(l, "AS value") && (strings.Contains(l, "relname") || strings.Contains(l, "nspname")) && !strings.Contains(l, `COLLATE "default"`) {
			t.Errorf("0166 L%d builds value from a catalog name without COLLATE \"default\": %s", i+1, strings.TrimSpace(l))
		}
	}
}
