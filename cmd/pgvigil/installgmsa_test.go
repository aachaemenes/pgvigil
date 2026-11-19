package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestTemplateGMSAL131 (the lead's 01:14 (4)): a configuration the Windows install writes fresh carries gmsa: set to a
// gMSA -user; any other account leaves the template as it is.
func TestTemplateGMSAL131(t *testing.T) {
	const user = `CORP\pgvigil-gmsa$`
	tmpl := configTemplate("env:PGVIGIL_REPO_DSN")
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	if err := os.WriteFile(p, []byte(templateWithGMSA(tmpl, user)), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(p)
	if err != nil {
		t.Fatalf("the template with gmsa: does not load: %v", err)
	}
	if cfg.GMSA != user {
		t.Errorf("gmsa: %q, want %q", cfg.GMSA, user)
	}
	for _, other := range []string{`NT SERVICE\pgvigil`, `CORP\svc-pgvigil`, "pgvigil"} {
		if templateWithGMSA(tmpl, other) != tmpl {
			t.Errorf("-user %q changed the template", other)
		}
	}
}

// TestGMSALineToAddL131: an existing configuration is never edited; without a gmsa: line the install prints the one
// to add, and says nothing when the file already names one or the account is no gMSA.
func TestGMSALineToAddL131(t *testing.T) {
	const user = `CORP\pgvigil-gmsa$`
	if s := gmsaLineToAdd("repository:\n  dsn: x\n", user); !strings.Contains(s, "gmsa: "+user) || !strings.Contains(s, "kept") {
		t.Errorf("no gmsa: line: %q", s)
	}
	for _, c := range []struct{ text, user string }{
		{"repository:\n  dsn: x\ngmsa: CORP\\pgvigil-old$\n", user},
		{"gmsa: " + user + "\n", user},
		{"repository:\n  dsn: x\n", `CORP\svc-pgvigil`},
		{"repository:\n  dsn: x\n", `NT SERVICE\pgvigil`},
	} {
		if s := gmsaLineToAdd(c.text, c.user); s != "" {
			t.Errorf("%q with -user %q: %q, want nothing", c.text, c.user, s)
		}
	}
}
