package config

import (
	"strings"
	"testing"
)

// The azure: block (task 390a): SQL Server only, its three names required, its cloud one of three.
func TestAzureBlock(t *testing.T) {
	base := func(engine string, a *Azure) Config {
		return Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{{Name: "a", Engine: engine, DSNRaw: "env:X", Azure: a}}}
	}
	ok := &Azure{Subscription: "s", ResourceGroup: "g", Server: "pgv-a"}
	cases := []struct {
		what   string
		cfg    Config
		refuse string
	}{
		{"sqlserver with the three names", base(EngineSQLServer, ok), ""},
		{"usgov", base(EngineSQLServer, &Azure{Subscription: "s", ResourceGroup: "g", Server: "a", Cloud: "usgov"}), ""},
		{"no server", base(EngineSQLServer, &Azure{Subscription: "s", ResourceGroup: "g"}), "names subscription, resource_group and server"},
		{"an unknown cloud", base(EngineSQLServer, &Azure{Subscription: "s", ResourceGroup: "g", Server: "a", Cloud: "moon"}), "public, usgov or china"},
		{"on PostgreSQL", base(EnginePostgres, ok), "SQL Server's"},
	}
	for _, c := range cases {
		err := c.cfg.Validate()
		switch {
		case c.refuse == "" && err != nil:
			t.Errorf("%s: refused: %v", c.what, err)
		case c.refuse != "" && (err == nil || !strings.Contains(err.Error(), c.refuse)):
			t.Errorf("%s: %v, want a refusal naming %q", c.what, err, c.refuse)
		}
	}
	if k := (Azure{Subscription: "S", ResourceGroup: "G", Server: "PGV-A"}).ServerKey(); k != "s/g/pgv-a" {
		t.Errorf("ServerKey %q", k)
	}
}
