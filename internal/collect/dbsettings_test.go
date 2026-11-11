package collect

import (
	"strings"
	"testing"
)

// TestDbSettingBase: an override's text as pg_db_role_setting keeps it (the spellings PostgreSQL 13, 16 and 18 stored
// in the trial of task 163: 'work_mem=256MB', 'jit=true', 'log_statement=ALL', 'enable_indexscan=of',
// 'random_page_cost=1.1e0', 'idle_in_transaction_session_timeout=5min') read into pg_settings.setting's form.
func TestDbSettingBase(t *testing.T) {
	syncCommit := []string{"local", "remote_write", "remote_apply", "on", "off"}
	logStatement := []string{"none", "ddl", "mod", "all"}
	walCompression := []string{"pglz", "lz4", "zstd", "on", "off"}
	levels := []string{"debug5", "debug4", "debug3", "debug2", "debug1", "info", "notice", "warning", "error", "log", "fatal", "panic"}
	cases := []struct {
		name, raw, vartype, unit string
		enum                     []string
		want                     string
		ok                       bool
	}{
		// memory: the base unit kB, 8kB pages, MB
		{"", "256MB", "integer", "kB", nil, "262144", true},
		{"", "1.5MB", "integer", "kB", nil, "1536", true},
		{"", "256 MB", "integer", "kB", nil, "262144", true},
		{"", "4096", "integer", "kB", nil, "4096", true},
		{"", "1GB", "integer", "kB", nil, "1048576", true},
		{"", "128MB", "integer", "8kB", nil, "16384", true},
		{"", "2GB", "integer", "MB", nil, "2048", true},
		{"", "512kB", "integer", "MB", nil, "0", true},  // half a MB: rint rounds half to even
		{"", "1536kB", "integer", "MB", nil, "2", true}, // 1.5 MB to 2
		{"", "256mb", "integer", "kB", nil, "256mb", false},
		// time: ms, s, min
		{"", "5min", "integer", "ms", nil, "300000", true},
		{"", "0", "integer", "ms", nil, "0", true},
		{"", "-1", "integer", "ms", nil, "-1", true},
		{"", "30s", "integer", "ms", nil, "30000", true},
		{"", "100us", "integer", "ms", nil, "0", true},
		{"", "1h", "integer", "s", nil, "3600", true},
		{"", "1d", "integer", "min", nil, "1440", true},
		{"", "90s", "integer", "min", nil, "2", true},
		{"", "2.5", "integer", "ms", nil, "2", true},
		{"", "3.5", "integer", "ms", nil, "4", true},
		{"", "10MB", "integer", "ms", nil, "10MB", false}, // a memory unit on a time setting
		// integers as strtol reads them
		{"", "0x10", "integer", "", nil, "16", true},
		{"", "010", "integer", "", nil, "8", true},
		{"", "010.5", "real", "", nil, "10.5", true},
		{"", "5kB", "integer", "", nil, "5kB", false}, // a unit on a unitless setting
		// reals
		{"", "1.1e0", "real", "", nil, "1.1", true},
		{"", "1.1", "real", "", nil, "1.1", true},
		{"", ".5", "real", "", nil, "0.5", true},
		{"", "20ms", "real", "ms", nil, "20", true},
		{"", "1s", "real", "ms", nil, "1000", true},
		{"", "abc", "real", "", nil, "abc", false},
		// booleans, every spelling parse_bool takes
		{"", "true", "bool", "", nil, "on", true},
		{"", "TRUE", "bool", "", nil, "on", true},
		{"", "of", "bool", "", nil, "off", true},
		{"", "on", "bool", "", nil, "on", true},
		{"", "o", "bool", "", nil, "o", false},
		{"", "y", "bool", "", nil, "on", true},
		{"", "no", "bool", "", nil, "off", true},
		{"", "1", "bool", "", nil, "on", true},
		{"", "0", "bool", "", nil, "off", true},
		{"", "10", "bool", "", nil, "10", false},
		{"", "maybe", "bool", "", nil, "maybe", false},
		// enums: case-blind, and the hidden boolean spellings of an enum that has on and off
		{"", "ALL", "enum", "", logStatement, "all", true},
		{"", "off", "enum", "", syncCommit, "off", true},
		{"", "yes", "enum", "", syncCommit, "on", true},
		{"", "0", "enum", "", syncCommit, "off", true},
		{"", "yes", "enum", "", logStatement, "yes", false},
		// strings, placeholders and masked values stay as written
		{"search_path", `"$user", public`, "string", "", nil, `"$user", public`, false},
		{"app.tenant", "x", "", "", nil, "x", false},
		{"", "<masked>", "integer", "kB", nil, "<masked>", false},
		// the review's cases (guc.c convert_to_base_unit: a fraction rounded to the next smaller unit first)
		{"work_mem", "1.3GB", "integer", "kB", nil, "1362944", true},
		{"effective_cache_size", "1.3GB", "integer", "8kB", nil, "170368", true},
		{"statement_timeout", "0.1d", "integer", "ms", nil, "7200000", true},
		{"idle_in_transaction_session_timeout", "1.01h", "integer", "ms", nil, "3660000", true},
		{"idle_in_transaction_session_timeout", "0.004h", "integer", "ms", nil, "0", true},
		{"vacuum_cost_delay", "0.0005s", "real", "ms", nil, "0", true},
		// strtol: 08 stops at the 8, which is no unit; out of the int range; strtod after a point
		{"", "08", "integer", "", nil, "08", false},
		{"", "08.5", "integer", "", nil, "08.5", false},
		{"", "1e300", "integer", "", nil, "1e300", false},
		{"", "3000000000", "integer", "", nil, "3000000000", false},
		{"", "2147483647", "integer", "", nil, "2147483647", true},
		{"", "-0x10", "integer", "", nil, "-16", true},
		// reals as C's %g prints them
		{"jit_above_cost", "1000000", "real", "", nil, "1e+06", true},
		{"random_page_cost", "1.23456789", "real", "", nil, "1.23457", true},
		{"cpu_operator_cost", "0.00001", "real", "", nil, "1e-05", true},
		{"cpu_operator_cost", "0.0001", "real", "", nil, "0.0001", true},
		{"jit_above_cost", "100000", "real", "", nil, "100000", true},
		// the enum names PostgreSQL shows
		{"wal_compression", "on", "enum", "", walCompression, "pglz", true},
		{"wal_compression", "TRUE", "enum", "", walCompression, "pglz", true},
		{"wal_compression", "no", "enum", "", walCompression, "off", true},
		{"wal_compression", "lz4", "enum", "", walCompression, "lz4", true},
		{"log_min_messages", "debug", "enum", "", levels, "debug2", true},
		{"log_min_messages", "DEBUG1", "enum", "", levels, "debug1", true},
		{"client_min_messages", "bogus", "enum", "", levels, "bogus", false},
	}
	for _, c := range cases {
		got, ok := dbSettingBase(c.name, c.raw, c.vartype, c.unit, c.enum)
		if got != c.want || ok != c.ok {
			t.Errorf("dbSettingBase(%q, %q, %s, %q) = %q, %v; want %q, %v", c.name, c.raw, c.vartype, c.unit, got, ok, c.want, c.ok)
		}
	}
}

// TestDbSettingsSQL: the read is read only, takes its type and unit from pg_settings and never its setting (the
// collector's own session may be under an override), masks as the instance read does, and names every scope.
func TestDbSettingsSQL(t *testing.T) {
	sql := strings.ToLower(dbsettingsSQL)
	for _, w := range []string{"insert ", "update ", "delete ", "alter ", "create ", "drop ", "set_config", "pg_terminate"} {
		if strings.Contains(sql, w) {
			t.Errorf("dbsettingsSQL holds %q", w)
		}
	}
	if strings.Contains(sql, "p.setting") || strings.Contains(sql, "p.reset_val") {
		t.Error("dbsettingsSQL reads the session's own value from pg_settings")
	}
	// TimeZone, DateStyle, IntervalStyle: pg_settings and pg_db_role_setting spell them in mixed case
	if !strings.Contains(dbsettingsSQL, "lower(p.name) = lower(m.name)") {
		t.Error("dbsettingsSQL does not match the name to pg_settings case-blind")
	}
	if !strings.Contains(dbsettingsSQL, settingValueSQL) {
		t.Error("dbsettingsSQL does not mask the value as the instance read does (settingValueSQL)")
	}
	for _, s := range []string{"'role in database'", "'role'", "'database'", "'all roles'"} {
		if !strings.Contains(dbsettingsSQL, s) {
			t.Errorf("dbsettingsSQL names no scope %s", s)
		}
	}
	if _, ok := Get("dbsettings"); !ok {
		t.Error("the dbsettings collection is not registered")
	}
}

func TestStringsOf(t *testing.T) {
	if got := stringsOf([]any{"a", 1, "b"}); len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Errorf("stringsOf([]any) = %v", got)
	}
	if got := stringsOf([]string{"x"}); len(got) != 1 {
		t.Errorf("stringsOf([]string) = %v", got)
	}
	if got := stringsOf(nil); got != nil {
		t.Errorf("stringsOf(nil) = %v", got)
	}
}
