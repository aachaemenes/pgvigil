package collect

import "testing"

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
		{"settle_up()", false, sessionSet{}},
	}
	for _, c := range cases {
		got, ok := parseSessionSet(c.text)
		if ok != c.ok || got != c.want {
			t.Errorf("parseSessionSet(%q) = %+v, %v; want %+v, %v", c.text, got, ok, c.want, c.ok)
		}
	}
}

// TestIsPlannerSetting: the settled list, and search_path is not on it.
func TestIsPlannerSetting(t *testing.T) {
	for _, n := range []string{"enable_hashjoin", "enable_seqscan", "random_page_cost", "cpu_tuple_cost", "jit_above_cost", "work_mem",
		"jit", "join_collapse_limit", "from_collapse_limit", "geqo", "geqo_threshold", "plan_cache_mode", "default_statistics_target"} {
		if !isPlannerSetting(n) {
			t.Errorf("%s is a planner setting", n)
		}
	}
	for _, n := range []string{"search_path", "timezone", "application_name", "statement_timeout", "maintenance_work_mem", "all", "jit_provider"} {
		if isPlannerSetting(n) {
			t.Errorf("%s is not a planner setting", n)
		}
	}
}
