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

func TestTags(t *testing.T) {
	for _, c := range [][2]string{{"prod", "tag/prod"}, {" Env : prod ", "env/prod"}, {"team:billing", "team/billing"}, {"tag:prod", "tag/prod"},
		{"url:http://x", "url/http://x"}} {
		g, err := ParseTag(c[0])
		if err != nil || g.Key+"/"+g.Value != c[1] {
			t.Errorf("%q: got %+v %v, want %s", c[0], g, err, c[1])
		}
	}
	for _, bad := range []string{"", "  ", "env:", ":prod", "tag:a:b", "a:b:c:d" + "\t", "\tprod", "bad key:x", "env:a,b", strings.Repeat("k", 41) + ":v"} {
		if _, err := ParseTag(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	if s := (Tag{Key: "tag", Value: "prod"}).String() + " " + (Tag{Key: "env", Value: "dev"}).String(); s != "prod env:dev" {
		t.Errorf("String: %q", s)
	}
	base := "repository:\n  dsn: env:REPO\n"
	for _, c := range []struct {
		body string
		want string // "" = ok
	}{
		{"instances:\n  - name: a\n    dsn: env:A\n    tags: [prod, env:prod, team:billing]\n", ""},
		{"instances:\n  - name: a\n    dsn: env:A\n    tags: [\"env:\"]\n", "has no value"},
		{"ui:\n  group_by: [env, team]\n  env_order: [prod, dev]\n", ""},
		{"ui:\n  group_by: [env, env]\n", "listed twice"},
		{"ui:\n  group_by: [Env]\n", "not a tag key"},
		{"ui:\n  group_by: [a, b, c, d, e]\n", "at most 4"},
		{"ui:\n  env_order: [prod, \"\"]\n", "empty value"},
		{"ui:\n  env_order: [Prod, \" Dev \"]\n", ""},
	} {
		p := filepath.Join(t.TempDir(), "c.yaml")
		if err := os.WriteFile(p, []byte(base+c.body), 0o600); err != nil {
			t.Fatal(err)
		}
		cfg, err := Load(p)
		switch {
		case c.want == "" && err != nil:
			t.Errorf("%q: %v", c.body, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%q: err=%v, want %q", c.body, err, c.want)
		case c.want == "" && len(cfg.UI.EnvOrder) == 0:
			t.Errorf("%q: env_order not defaulted", c.body)
		}
	}
	cu := &Config{Repository: Repository{DSNRaw: "x"}, UI: UI{EnvOrder: []string{"Prod", " Dev "}}}
	if err := cu.Validate(); err != nil || cu.UI.EnvOrder[0] != "prod" || cu.UI.EnvOrder[1] != "dev" {
		t.Errorf("env_order not lower-cased and trimmed: %v %v", cu.UI.EnvOrder, err)
	}
	if got := (Instance{Tags: []string{"prod", "env:dev"}}).TagPairs(); len(got) != 2 || got[1].Key != "env" {
		t.Errorf("TagPairs: %+v", got)
	}
}

// An instance is PostgreSQL unless it says sqlserver; a SQL Server instance has its own platform words, takes a
// password only through env: or file:, and none of PostgreSQL's doors.
func TestEngine(t *testing.T) {
	ok := Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{
		{Name: "pg", DSNRaw: "host=x"},
		{Name: "ms", Engine: "sqlserver", DSNRaw: "sqlserver://mon@h:1433?database=master"},
		{Name: "ms-env", Engine: "sqlserver", DSNRaw: "env:MS_DSN", Platform: "azuresqlmi"},
		{Name: "ms-ado", Engine: "sqlserver", DSNRaw: "server=h;user id=mon;database=master", Platform: "rds"},
	}}
	ok.Instances = append(ok.Instances,
		Instance{Name: "ms-act", Engine: "sqlserver", DSNRaw: "env:MS_DSN", ActionsDSNRaw: "env:MS_ACT", Actions: []string{"kill", "job_start", "job_stop"}},
		Instance{Name: "ms-act-none", Engine: "sqlserver", DSNRaw: "env:MS_DSN", ActionsDSNRaw: "file:/run/secrets/ms-act"})
	if err := ok.Validate(); err != nil {
		t.Fatalf("a valid two-engine config was rejected: %v", err)
	}
	if ok.Instances[0].Engine != EnginePostgres || ok.Instances[1].Engine != EngineSQLServer {
		t.Errorf("engines after Validate: %q, %q", ok.Instances[0].Engine, ok.Instances[1].Engine)
	}
	bad := map[string]Instance{
		"unknown engine":       {Name: "a", Engine: "oracle", DSNRaw: "x"},
		"postgres platform":    {Name: "a", Engine: "sqlserver", DSNRaw: "env:X", Platform: "aurora"},
		"sqlserver platform":   {Name: "a", DSNRaw: "x", Platform: "azuresqldb"},
		"inline password url":  {Name: "a", Engine: "sqlserver", DSNRaw: "sqlserver://mon:secret@h:1433"},
		"inline password ado":  {Name: "a", Engine: "sqlserver", DSNRaw: "server=h;user id=mon;password=secret"},
		"actions inline":       {Name: "a", Engine: "sqlserver", DSNRaw: "env:X", ActionsDSNRaw: "sqlserver://act@h:1433"},
		"actions = read login": {Name: "a", Engine: "sqlserver", DSNRaw: "env:X", ActionsDSNRaw: "env:X"},
		"unknown action":       {Name: "a", Engine: "sqlserver", DSNRaw: "env:X", ActionsDSNRaw: "env:Y", Actions: []string{"kill", "terminate"}},
		"action twice":         {Name: "a", Engine: "sqlserver", DSNRaw: "env:X", ActionsDSNRaw: "env:Y", Actions: []string{"kill", "kill"}},
		"actions without dsn":  {Name: "a", Engine: "sqlserver", DSNRaw: "env:X", Actions: []string{"kill"}},
		"actions on postgres":  {Name: "a", DSNRaw: "env:X", ActionsDSNRaw: "env:Y", Actions: []string{"kill"}},
		"explain door":         {Name: "a", Engine: "sqlserver", DSNRaw: "env:X", ExplainDSNRaw: "env:Y"},
		"explain analyze":      {Name: "a", Engine: "sqlserver", DSNRaw: "env:X", ExplainAnalyze: true},
		"pooler":               {Name: "a", Engine: "sqlserver", DSNRaw: "env:X", PgBouncerDSNRaw: "env:Y"},
		"aws block":            {Name: "a", Engine: "sqlserver", DSNRaw: "env:X", AWS: &AWS{}},
		"backups block":        {Name: "a", Engine: "sqlserver", DSNRaw: "env:X", Backups: &Backups{}},
		"engine in upper case": {Name: "a", Engine: "SQLServer", DSNRaw: "env:X"},
	}
	for name, in := range bad {
		c := Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{in}}
		if err := c.Validate(); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

// A connection string written into the file is refused when it carries a password, wherever the password sits and
// whatever it holds; an '@' inside a query value is not a password.
func TestInlinePassword(t *testing.T) {
	for dsn, want := range map[string]bool{
		"sqlserver://mon:secret@h:1433":                      true,
		"sqlserver://sa:Pa=ss@host":                          true,
		"sqlserver://sa:Pa=ss@host:1433?database=master":     true,
		"sqlserver://sa:p@ss@host/instance":                  true,
		"sqlserver://sa:pa/ss@host":                          true,
		"sqlserver://sa:p=a/ss@host":                         true,
		"sqlserver://h:1433?database=master&password=secret": true,
		"sqlserver://h:1433?database=master;pwd=secret":      true,
		"server=h;user id=mon; Password =secret":             true,
		"odbc:server=h;user id=mon;pwd=secret":               true,
		"sqlserver://mon@h:1433?database=master":             false,
		"sqlserver://h:1433?user+id=a@corp.com":              false,
		"sqlserver://h:1433/instance?user+id=a@corp.com":     false,
		"sqlserver://mon@h:1433?app+name=a:b@c":              false,
		"sqlserver://h?database=master":                      false,
		"server=h;user id=mon;database=master":               false,
		"server=h;user id=mon;app name=password keeper;":     false,
		"postgres://mon@h:5432/db?sslmode=require":           false,
	} {
		if got := inlinePassword(dsn); got != want {
			t.Errorf("inlinePassword(%q) = %v; want %v", dsn, got, want)
		}
	}
}
