package web

import "testing"

// TestDBADashStatement: a screen's statement text under the instance's query_text - the strictest of the matching
// instances' policies, the read rule's words under none, the collector's normalized form under normalized.
func TestDBADashStatement(t *testing.T) {
	for _, c := range []struct {
		modes []string
		want  string
	}{
		{[]string{"full"}, "full"}, {[]string{"full", "normalized"}, "normalized"}, {[]string{"normalized", "none", "full"}, "none"},
		{[]string{"none"}, "none"}, {[]string{"full", "a word no policy has"}, "none"}, {nil, "full"},
	} {
		if got := strictestText(c.modes); got != c.want {
			t.Errorf("strictestText(%v) = %q, want %q", c.modes, got, c.want)
		}
	}
	const st = "CREATE LOGIN app WITH PASSWORD = '<masked>'; SELECT 1"
	if got := dbadashStatement("full", st); got != st {
		t.Errorf("full: %q", got)
	}
	if got := dbadashStatement("normalized", st); got != "CREATE LOGIN app WITH PASSWORD = ?; SELECT ?" {
		t.Errorf("normalized: %q", got)
	}
	for _, m := range []string{"none", "", "a word no policy has"} {
		if got := dbadashStatement(m, st); got != "(not shown: this instance's query_text policy is none)" {
			t.Errorf("%q: %q, want the words", m, got)
		}
	}
}
