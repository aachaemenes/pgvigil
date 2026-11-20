package main

import (
	"strings"
	"testing"
)

// TestAlertsBaseWarningL55: alerts_base_url without the UI's base path is warned of once at serve's start (every
// alert's link would open outside the UI); with the base, with no base and with no address there is no warning.
func TestAlertsBaseWarningL55(t *testing.T) {
	if w := alertsBaseWarning("https://tools.example.org", "/pgvigil"); !strings.Contains(w, "base path") {
		t.Errorf("an address without the base: %q, want a warning naming the base path", w)
	}
	for _, c := range [][2]string{{"https://tools.example.org/pgvigil", "/pgvigil"}, {"https://tools.example.org/pgvigil/", "/pgvigil"}, {"https://pgv.example.org", ""}, {"", "/pgvigil"}} {
		if w := alertsBaseWarning(c[0], c[1]); w != "" {
			t.Errorf("alerts_base_url %q, base %q: %q, want no warning", c[0], c[1], w)
		}
	}
}
