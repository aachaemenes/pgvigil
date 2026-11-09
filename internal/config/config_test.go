package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestResolve(t *testing.T) {
	t.Setenv("PGVIGIL_TEST_DSN", "host=a user=b")
	if got := Resolve("env:PGVIGIL_TEST_DSN"); got != "host=a user=b" {
		t.Fatalf("env: got %q", got)
	}
	p := filepath.Join(t.TempDir(), "dsn")
	if err := os.WriteFile(p, []byte("host=c\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := Resolve("file:" + p); got != "host=c" {
		t.Fatalf("file: got %q", got)
	}
	if got := Resolve("plain"); got != "plain" {
		t.Fatalf("plain: got %q", got)
	}
	if got := Resolve("env:PGVIGIL_UNSET_FOR_TEST"); got != "" {
		t.Fatalf("unset env: got %q", got)
	}
}

func TestLoadAndInterval(t *testing.T) {
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	body := `repository:
  dsn: env:REPO
schedules:
  instance: 30m
  activity: disabled
instances:
  - name: a
    dsn: env:A
    schedules:
      instance: 5m
  - name: b
    dsn: env:B
    disabled: [instance]
`
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if c.Instances[0].Platform != "auto" {
		t.Fatalf("platform default: %q", c.Instances[0].Platform)
	}
	if got := c.Interval(c.Instances[0], "instance", time.Hour); got != 5*time.Minute {
		t.Fatalf("instance override: %v", got)
	}
	if got := c.Interval(c.Instances[1], "instance", time.Hour); got != 0 {
		t.Fatalf("disabled list: %v", got)
	}
	if got := c.Interval(c.Instances[1], "activity", time.Minute); got != 0 {
		t.Fatalf("global disabled: %v", got)
	}
	if got := c.Interval(c.Instances[1], "other", 7*time.Minute); got != 7*time.Minute {
		t.Fatalf("default: %v", got)
	}
}

func TestValidateRejects(t *testing.T) {
	cases := map[string]Config{
		"no repo":    {Instances: []Instance{{Name: "a", DSNRaw: "x"}}},
		"dup name":   {Repository: Repository{DSNRaw: "r"}, Instances: []Instance{{Name: "a", DSNRaw: "x"}, {Name: "a", DSNRaw: "y"}}},
		"bad plat":   {Repository: Repository{DSNRaw: "r"}, Instances: []Instance{{Name: "a", DSNRaw: "x", Platform: "mainframe"}}},
		"empty dsn":  {Repository: Repository{DSNRaw: "r"}, Instances: []Instance{{Name: "a"}}},
		"empty name": {Repository: Repository{DSNRaw: "r"}, Instances: []Instance{{DSNRaw: "x"}}},
	}
	for name, c := range cases {
		c := c
		if err := c.Validate(); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

// A repository with no instances is valid: a host that only serves the UI.
func TestValidateServeOnly(t *testing.T) {
	c := Config{Repository: Repository{DSNRaw: "r"}}
	if err := c.Validate(); err != nil {
		t.Fatalf("serve-only config rejected: %v", err)
	}
}

func TestActionsDSN(t *testing.T) {
	base := "repository:\n  dsn: env:REPO\ninstances:\n  - name: a\n    dsn: env:A\n"
	for _, c := range []struct {
		line string
		ok   bool
	}{
		{"", true},
		{"    actions_dsn: env:PGVIGIL_ACT\n", true},
		{"    actions_dsn: file:/run/secrets/act\n", true},
		{"    actions_dsn: \"host=h user=pgvigil_actions password=p\"\n", false},
		{"    actions_dsn: postgres://u:p@h/db\n", false},
	} {
		p := filepath.Join(t.TempDir(), "c.yaml")
		if err := os.WriteFile(p, []byte(base+c.line), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := Load(p)
		if (err == nil) != c.ok {
			t.Errorf("%q: err=%v, want ok=%v", c.line, err, c.ok)
		}
		if err != nil && !strings.Contains(err.Error(), "env:NAME or file:/path") {
			t.Errorf("%q: the refusal does not say why: %v", c.line, err)
		}
	}
	t.Setenv("PGVIGIL_ACT", "host=x user=pgvigil_actions")
	if got := (Instance{ActionsDSNRaw: "env:PGVIGIL_ACT"}).ActionsDSN(); got != "host=x user=pgvigil_actions" {
		t.Errorf("ActionsDSN: %q", got)
	}
	if got := (Instance{}).ActionsDSN(); got != "" {
		t.Errorf("no actions_dsn: %q", got)
	}
}
