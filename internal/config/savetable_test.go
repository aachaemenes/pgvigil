package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// Task 7b (Save Table's write door): doors: save_table: on, off by default; save_table in an instance's actions: list
// on both engines (review-29 N9: today both lists refuse it as unknown); a PostgreSQL instance naming save_table whose
// actions_dsn is its dsn is refused (review-29 B1) - and only that one: a config that loads today keeps loading.

func TestSaveTableDoorSwitch(t *testing.T) {
	var off Config
	b, err := yaml.Marshal(off.Doors)
	if err != nil || !strings.Contains(string(b), "save_table: false") {
		t.Errorf("doors with no save_table key: %q, %v - want save_table: false (off by default)", b, err)
	}
	var on Config
	if err := yaml.Unmarshal([]byte("doors:\n  save_table: on\n"), &on); err != nil {
		t.Fatalf("doors: save_table: on: %v", err)
	}
	if b, _ := yaml.Marshal(on.Doors); !strings.Contains(string(b), "save_table: true") {
		t.Errorf("doors: save_table: on reads as %q - want save_table: true", b)
	}
}

func TestSaveTableInActionsList(t *testing.T) {
	ok := Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{
		{Name: "pg-save", DSNRaw: "env:PG_DSN", ActionsDSNRaw: "env:PG_ACT", Actions: []string{"save_table"}},
		{Name: "pg-save-jobs", DSNRaw: "env:PG_DSN2", ActionsDSNRaw: "env:PG_ACT2", Actions: []string{"job_stop", "save_table"}},
		{Name: "ms-save", Engine: "sqlserver", DSNRaw: "env:MS_DSN", ActionsDSNRaw: "env:MS_ACT", Actions: []string{"kill", "save_table"}},
	}}
	if err := ok.Validate(); err != nil {
		t.Errorf("a config naming save_table: %v (want accepted on both engines)", err)
	}
	for name, in := range map[string]Instance{
		"pg twice": {Name: "pg-twice", DSNRaw: "env:PG_DSN", ActionsDSNRaw: "env:PG_ACT", Actions: []string{"save_table", "save_table"}},
		"ms twice": {Name: "ms-twice", Engine: "sqlserver", DSNRaw: "env:MS_DSN", ActionsDSNRaw: "env:MS_ACT", Actions: []string{"save_table", "save_table"}},
	} {
		c := Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{in}}
		if err := c.Validate(); err == nil || !strings.Contains(err.Error(), "twice") {
			t.Errorf("%s: %v (want refused: names save_table twice)", name, err)
		}
	}
	// the unknown-kind words list save_table among the known ones on both engines
	for name, in := range map[string]Instance{
		"pg": {Name: "pg-bad", DSNRaw: "env:PG_DSN", ActionsDSNRaw: "env:PG_ACT", Actions: []string{"save_tables"}},
		"ms": {Name: "ms-bad", Engine: "sqlserver", DSNRaw: "env:MS_DSN", ActionsDSNRaw: "env:MS_ACT", Actions: []string{"save_tables"}},
	} {
		c := Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{in}}
		if err := c.Validate(); err == nil || !strings.Contains(err.Error(), "save_table,") && !strings.Contains(err.Error(), "save_table)") && !strings.Contains(err.Error(), "save_table and") {
			t.Errorf("%s: an unknown kind: %v (want refused, naming save_table among the known ones)", name, err)
		}
	}
}

func TestSaveTablePGActionsLoginIsNotTheReadLogin(t *testing.T) {
	same := Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{
		{Name: "pg-same", DSNRaw: "env:PG_DSN", ActionsDSNRaw: "env:PG_DSN", Actions: []string{"save_table"}},
	}}
	if err := same.Validate(); err == nil || !strings.Contains(err.Error(), "actions_dsn is the instance's dsn") {
		t.Errorf("a PostgreSQL instance naming save_table with actions_dsn = dsn: %v (want refused: the actions login must be a login of its own)", err)
	}
	// without save_table the same pair loads as it does today (cancel / terminate; no config that loads stops loading)
	today := Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{
		{Name: "pg-today", DSNRaw: "env:PG_DSN", ActionsDSNRaw: "env:PG_DSN"},
	}}
	if err := today.Validate(); err != nil {
		t.Errorf("a PostgreSQL instance without save_table, actions_dsn = dsn: %v (want accepted, as today)", err)
	}
}

// review-31 part B N18: through the real loader - a file with no doors: save_table key loads it OFF (another door named
// or none), one that says on loads it on; the Marshal check above cannot fail if the loader ever applied a default
func TestSaveTableDoorSwitchThroughLoad(t *testing.T) {
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	for _, c := range []struct {
		body string
		want bool
	}{
		{"repository:\n  dsn: env:REPO\n", false},
		{"repository:\n  dsn: env:REPO\ndoors:\n  page_instance_reads: off\n", false},
		{"repository:\n  dsn: env:REPO\ndoors:\n  save_table: on\n", true},
	} {
		if err := os.WriteFile(p, []byte(c.body), 0o600); err != nil {
			t.Fatal(err)
		}
		cfg, err := Load(p)
		if err != nil || cfg.Doors.SaveTable != c.want {
			t.Errorf("%q: loaded %+v, %v - want doors.save_table %v", c.body, cfg, err, c.want)
		}
	}
}
