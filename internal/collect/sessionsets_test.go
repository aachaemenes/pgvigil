package collect

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestParseSessionSet: the spellings pg_stat_statements keeps (the PG 17+ $n form and the literal form of older
// servers), the scopes, the special forms, and the statements that begin SET or RESET but change no setting.
func TestParseSessionSet(t *testing.T) {
	cases := []struct {
		text string
		ok   bool
		want sessionSet
	}{
		{"SET enable_hashjoin = $1", true, sessionSet{Command: "SET", Setting: "enable_hashjoin", Hidden: true, Planner: true}},
		{"SET enable_hashjoin = off", true, sessionSet{Command: "SET", Setting: "enable_hashjoin", Value: "off", Planner: true}},
		{"set enable_hashjoin to 'off';", true, sessionSet{Command: "SET", Setting: "enable_hashjoin", Value: "off", Planner: true}},
		{"SET SESSION random_page_cost = 1.1", true, sessionSet{Command: "SET", Setting: "random_page_cost", Value: "1.1", Planner: true}},
		{"SET LOCAL work_mem = '64MB'", true, sessionSet{Command: "SET LOCAL", Setting: "work_mem", Value: "64MB", Planner: true}},
		{"SET LOCAL work_mem = $1", true, sessionSet{Command: "SET LOCAL", Setting: "work_mem", Hidden: true, Planner: true}},
		{"set session jit = $1", true, sessionSet{Command: "SET", Setting: "jit", Hidden: true, Planner: true}},
		{"SET geqo_threshold = 20", true, sessionSet{Command: "SET", Setting: "geqo_threshold", Value: "20", Planner: true}},
		{"SET plan_cache_mode = force_custom_plan", true, sessionSet{Command: "SET", Setting: "plan_cache_mode", Value: "force_custom_plan", Planner: true}},
		{"SET join_collapse_limit = 1", true, sessionSet{Command: "SET", Setting: "join_collapse_limit", Value: "1", Planner: true}},
		{"SET default_statistics_target = 500", true, sessionSet{Command: "SET", Setting: "default_statistics_target", Value: "500", Planner: true}},
		{"SET search_path = $1", true, sessionSet{Command: "SET", Setting: "search_path", Hidden: true}},
		{"SET search_path TO app, public", true, sessionSet{Command: "SET", Setting: "search_path", Value: "app, public"}},
		{"SET SCHEMA 'app'", true, sessionSet{Command: "SET", Setting: "search_path", Value: "app"}},
		{"SET TIME ZONE 'UTC'", true, sessionSet{Command: "SET", Setting: "timezone", Value: "UTC"}},
		{"SET NAMES 'UTF8'", true, sessionSet{Command: "SET", Setting: "client_encoding", Value: "UTF8"}},
		{"SET application_name = $1", true, sessionSet{Command: "SET", Setting: "application_name", Hidden: true}},
		{"SET app.tenant_id = '42'", true, sessionSet{Command: "SET", Setting: "app.tenant_id", Value: "42"}},
		{`SET "Enable_HashJoin" = off`, true, sessionSet{Command: "SET", Setting: "enable_hashjoin", Value: "off", Planner: true}},
		{"/* app */ SET enable_nestloop = $1", true, sessionSet{Command: "SET", Setting: "enable_nestloop", Hidden: true, Planner: true}},
		{"RESET enable_hashjoin", true, sessionSet{Command: "RESET", Setting: "enable_hashjoin", Planner: true}},
		{"RESET ALL", true, sessionSet{Command: "RESET", Setting: "all"}},
		{"SET effective_io_concurrency = 200", true, sessionSet{Command: "SET", Setting: "effective_io_concurrency", Value: "200"}},
		{"SET session_replication_role = replica", true, sessionSet{Command: "SET", Setting: "session_replication_role", Value: "replica"}},
		{"SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", false, sessionSet{}},
		{"SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY", false, sessionSet{}},
		{"SET CONSTRAINTS ALL DEFERRED", false, sessionSet{}},
		{"SET ROLE app_admin", false, sessionSet{}},
		{"SET SESSION AUTHORIZATION app_admin", false, sessionSet{}},
		{"RESET ROLE", false, sessionSet{}},
		{"RESET SESSION AUTHORIZATION", false, sessionSet{}},
		{"SELECT set_config($1, $2, $3)", false, sessionSet{}},
		// the 58 review's texts: a trailing comment, a $n inside a list, DEFAULT, an empty literal, a leading -- comment
		{"SET enable_hashjoin = $1 -- c", true, sessionSet{Command: "SET", Setting: "enable_hashjoin", Hidden: true, Planner: true}},
		{"SET enable_hashjoin = off /*traceparent='00-ab'*/", true, sessionSet{Command: "SET", Setting: "enable_hashjoin", Value: "off", Planner: true}},
		{"SET search_path = $1, public", true, sessionSet{Command: "SET", Setting: "search_path", Hidden: true}},
		{"SET enable_hashjoin = $1, $2", true, sessionSet{Command: "SET", Setting: "enable_hashjoin", Hidden: true, Planner: true}},
		{"SET enable_hashjoin TO DEFAULT", true, sessionSet{Command: "RESET", Setting: "enable_hashjoin", Planner: true}},
		{"SET LOCAL work_mem = default", true, sessionSet{Command: "RESET", Setting: "work_mem", Planner: true}},
		{"SET application_name = ''", true, sessionSet{Command: "SET", Setting: "application_name", Value: ""}},
		{"-- hint\nSET enable_hashjoin = off", true, sessionSet{Command: "SET", Setting: "enable_hashjoin", Value: "off", Planner: true}},
		{"settle_up()", false, sessionSet{}},
		// the join review's texts: a comment marker inside a quoted value or name is text; a nested block comment
		{"SET x.y = 'a -- b'", true, sessionSet{Command: "SET", Setting: "x.y", Value: "a -- b"}},
		{"SET app.note = 'x /* y */ z'", true, sessionSet{Command: "SET", Setting: "app.note", Value: "x /* y */ z"}},
		{"SET app.note = 'it''s -- fine' -- really", true, sessionSet{Command: "SET", Setting: "app.note", Value: "it's -- fine"}},
		{`SET "odd--name" = 1 /* note */`, true, sessionSet{Command: "SET", Setting: "odd--name", Value: "1"}},
		{"/* a /* nested */ b */ SET jit = off", true, sessionSet{Command: "SET", Setting: "jit", Value: "off", Planner: true}},
		{"SET work_mem = '64MB' -- 'quoted' in a comment", true, sessionSet{Command: "SET", Setting: "work_mem", Value: "64MB", Planner: true}},
	}
	for _, c := range cases {
		got, ok := parseSessionSet(c.text)
		if ok != c.ok || got != c.want {
			t.Errorf("parseSessionSet(%q) = %+v, %v; want %+v, %v", c.text, got, ok, c.want, c.ok)
		}
	}
}

// TestMonitorSetupSettings: the four settings of collect.go's session setup, read from its text, the index read's
// search_path and the Explain's plan_cache_mode, and nothing else; then every SET statement in the module's own Go
// sources (a string literal that is not an UPDATE ... SET; the demo's seed texts and the tests aside) names one of
// them, so a new SET of the tool's own cannot reach the findings as the application's (the fold review's blocker).
func TestMonitorSetupSettings(t *testing.T) {
	want := map[string]bool{"default_transaction_read_only": true, "statement_timeout": true, "lock_timeout": true, "application_name": true,
		"search_path": true, "plan_cache_mode": true}
	if len(monitorSetupSettings) != len(want) {
		t.Errorf("monitorSetupSettings = %v; want %v", monitorSetupSettings, want)
	}
	for n := range want {
		if !monitorSetupSettings[n] {
			t.Errorf("%s is the monitor's own", n)
		}
	}
	if monitorSetupSettings["enable_hashjoin"] {
		t.Errorf("enable_hashjoin is never the monitor's own")
	}
	// the SQL keyword in capitals, as every statement literal of the tree writes it (prose such as "set it to" is not one)
	setStmt := regexp.MustCompile(`\b(?:SET|RESET)\s+(?:LOCAL\s+|SESSION\s+)?([a-z_][a-z0-9_.]*)\s*(?:=|\bTO\b)`)
	seen := 0
	for _, root := range []string{"../../internal", "../../cmd"} {
		err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				if d.Name() == "demo" || d.Name() == "dist" {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") || strings.HasSuffix(path, "sessionsets.go") {
				return nil
			}
			src, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			for _, line := range strings.Split(string(src), "\n") {
				if strings.Contains(strings.ToUpper(line), "UPDATE ") || strings.HasPrefix(strings.TrimSpace(line), "//") {
					continue
				}
				for _, m := range setStmt.FindAllStringSubmatch(line, -1) {
					seen++
					if !monitorSetupSettings[strings.ToLower(m[1])] {
						t.Errorf("%s: the tool SETs %s on an instance; it is not in monitorSetupSettings", path, m[1])
					}
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	if seen < 6 {
		t.Errorf("the source scan found %d SET statements; the setup's four, search_path and plan_cache_mode are expected", seen)
	}
}

// TestIsPlannerSetting: the settled list, and search_path is not on it.
func TestIsPlannerSetting(t *testing.T) {
	for _, n := range []string{"enable_hashjoin", "enable_seqscan", "random_page_cost", "cpu_tuple_cost", "jit_above_cost", "work_mem",
		"jit", "join_collapse_limit", "from_collapse_limit", "geqo", "geqo_threshold", "plan_cache_mode", "default_statistics_target",
		"effective_cache_size", "hash_mem_multiplier", "max_parallel_workers_per_gather"} {
		if !isPlannerSetting(n) {
			t.Errorf("%s is a planner setting", n)
		}
	}
	for _, n := range []string{"search_path", "timezone", "application_name", "statement_timeout", "maintenance_work_mem", "all", "jit_provider", "max_parallel_workers"} {
		if isPlannerSetting(n) {
			t.Errorf("%s is not a planner setting", n)
		}
	}
}
