package web

import (
	"os"
	"strings"
	"testing"
)

// TestWalkerReadsTheThemeBack (review t11-6 NIT 11, named at the fold and taken after it): the walker reads the
// applied theme back after each reload (main.ts applyTheme sets data-theme on the root element) and fails a page
// drawn in the other theme, so axe never sees light twice.
func TestWalkerReadsTheThemeBack(t *testing.T) {
	b, err := os.ReadFile("../../scripts/parity-s3-pages.mjs")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "document.documentElement.getAttribute('data-theme')") || !strings.Contains(string(b), "THEME NOT APPLIED") {
		t.Error("parity-s3-pages.mjs does not read the applied theme back")
	}
}
