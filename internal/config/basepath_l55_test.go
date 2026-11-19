package config

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// TestWebBasePathL55 (RELNOTES L55, the lead's 00:47): web.base_path serves the UI under a sub-path behind a reverse
// proxy that passes the path whole. A leading '/', no trailing '/', no '..' segment, no query or fragment; empty is the
// root, as before. A bad value fails the load in words naming the key.
func TestWebBasePathL55(t *testing.T) {
	var c Config
	if err := yaml.Unmarshal([]byte("repository:\n  dsn: env:X\nweb:\n  base_path: /pgvigil\n"), &c); err != nil {
		t.Fatal(err)
	}
	if err := c.Validate(); err != nil || c.Web.BasePath != "/pgvigil" {
		t.Fatalf("web.base_path /pgvigil: %q, %v", c.Web.BasePath, err)
	}
	for _, ok := range []string{"", "/pgvigil", "/tools/pgvigil", "/a-b_c.d"} {
		if err := ValidBasePath(ok); err != nil {
			t.Errorf("%q refused: %v", ok, err)
		}
	}
	for _, bad := range []string{"pgvigil", "/pgvigil/", "/", "/a/../b", "/a/./b", "/a?x=1", "/a#f", "/a//b", "/a b", `/a\b`} {
		err := ValidBasePath(bad)
		if err == nil {
			t.Errorf("%q taken", bad)
			continue
		}
		if !strings.Contains(err.Error(), "web.base_path") {
			t.Errorf("%q: the words do not name web.base_path: %v", bad, err)
		}
		c.Web.BasePath = bad
		if err := c.Validate(); err == nil {
			t.Errorf("%q: the load takes it", bad)
		}
	}
}
