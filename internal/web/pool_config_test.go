package web

import "testing"

// TestUIPoolConfig reads the UI pool's configuration as Open builds it (uiPoolConfig): every session setting serve
// sends at connect, plan_cache_mode = force_custom_plan among them (the join review d10b, finding b1: the proof's
// PREPARE rows set the mode themselves and cannot see this pool), and the pool's size.
func TestUIPoolConfig(t *testing.T) {
	cfg, err := uiPoolConfig("host=127.0.0.1 port=5432 user=pgvigil_ui dbname=pgvigil pool_max_conns=20", Options{})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"application_name":              "pgvigil-serve",
		"default_transaction_read_only": "on",
		"statement_timeout":             "15000",
		"plan_cache_mode":               "force_custom_plan",
		"jit":                           "off",
		"lock_timeout":                  "2000",
		"search_path":                   "pgvigil, pg_catalog",
	}
	rp := cfg.ConnConfig.RuntimeParams
	for k, v := range want {
		if rp[k] != v {
			t.Errorf("RuntimeParams[%q] = %q, want %q", k, rp[k], v)
		}
	}
	if cfg.MaxConns != 8 || cfg.MinConns != 1 {
		t.Errorf("MaxConns %d, MinConns %d (want 8 and 1)", cfg.MaxConns, cfg.MinConns)
	}
	cfg, err = uiPoolConfig("host=127.0.0.1 user=pgvigil_ui dbname=pgvigil", Options{AppName: "pgvigil-mcp"})
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.ConnConfig.RuntimeParams["application_name"]; got != "pgvigil-mcp" {
		t.Errorf("application_name with o.AppName = %q, want pgvigil-mcp", got)
	}
	if got := cfg.ConnConfig.RuntimeParams["plan_cache_mode"]; got != "force_custom_plan" {
		t.Errorf("plan_cache_mode with o.AppName = %q, want force_custom_plan", got)
	}
}
