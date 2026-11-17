package web

import (
	"os"
	"strings"
	"testing"
)

// TestAdminRightsOptInOnlyWords (review t11-1 NIT 6, P25 task 9b): on a pooled Azure SQL Database where nothing is
// missing the rights script still carries Pool history's opt-in block; the page then says the script is an opt-in
// block, every line a comment - never 'the script of the missing rights' under 'Nothing is missing.'.
func TestAdminRightsOptInOnlyWords(t *testing.T) {
	b, err := os.ReadFile("../../web/src/admin_checks.ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "an opt-in block, every line a comment") {
		t.Error("admin_checks.ts: no words for a script that holds only the opt-in block")
	}
}
