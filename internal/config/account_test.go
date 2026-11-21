package config

import "testing"

// TestLookupNameForms: the forms LookupAccountName is given - '.\user' as this computer's user (the lookup does not
// read the dot), LocalSystem as SYSTEM, a domain account as written, trimmed.
func TestLookupNameForms(t *testing.T) {
	for _, c := range []struct{ in, computer, want string }{
		{`.\pgvsvc`, "WIN01", `WIN01\pgvsvc`},
		{` .\pgvsvc `, "WIN01", `WIN01\pgvsvc`},
		{`.\pgvsvc`, "", `.\pgvsvc`},
		{"LocalSystem", "WIN01", `NT AUTHORITY\SYSTEM`},
		{"localsystem", "WIN01", `NT AUTHORITY\SYSTEM`},
		{`CORP\svc-pgvigil`, "WIN01", `CORP\svc-pgvigil`},
		{` CORP\pgv-gmsa$ `, "WIN01", `CORP\pgv-gmsa$`},
		{`NT SERVICE\pgvigil`, "WIN01", `NT SERVICE\pgvigil`},
	} {
		if got := LookupName(c.in, c.computer); got != c.want {
			t.Errorf("LookupName(%q, %q) = %q, want %q", c.in, c.computer, got, c.want)
		}
	}
}
