package mssql

import (
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

func TestChecksCollectorsRegistered(t *testing.T) {
	for name, every := range map[string]time.Duration{"mssql_checks": time.Hour, "mssql_identity": 6 * time.Hour} {
		c, ok := Get(name)
		if !ok {
			t.Fatalf("%s is not registered", name)
		}
		if c.DefaultInterval() != every {
			t.Errorf("%s: default interval %v, want %v", name, c.DefaultInterval(), every)
		}
		if ok, why := c.Applies(Info{Kind: KindAzureDB, ViewServerState: true, ViewAnyDefinition: true}); ok || !strings.Contains(why, "Azure SQL Database") {
			t.Errorf("%s on Azure SQL Database: %v %q", name, ok, why)
		}
		for _, k := range []Kind{KindServer, KindRDS, KindAzureMI} {
			if ok, why := c.Applies(Info{Kind: k, ViewServerState: true, ViewAnyDefinition: true}); !ok {
				t.Errorf("%s on %s: skipped: %s", name, k, why)
			}
		}
	}
	// the checks need no right to run; the identity scan needs the tables' definitions
	if ok, _ := (checksCollector{}).Applies(Info{Kind: KindServer}); !ok {
		t.Error("mssql_checks must run for a login with the public role only")
	}
	if ok, why := (identityCollector{}).Applies(Info{Kind: KindServer}); ok || !strings.Contains(why, "VIEW ANY DEFINITION") {
		t.Errorf("mssql_identity without VIEW ANY DEFINITION: %v %q", ok, why)
	}
}

func TestServerOptionRules(t *testing.T) {
	big := machineFacts{CPUs: 16, NUMANodes: 1, PhysMB: 8192, EngineEdition: 3, Kind: KindServer, Major: 16}
	cases := []struct {
		name       string
		value      int64
		m          machineFacts
		status     string
		severity   string
		ruleHas    string
		advisedHas string
	}{
		{"priority boost", 1, big, "crit", "critical", "sp_Blitz 126", "0"},
		{"priority boost", 0, big, "ok", "", "", ""},
		{"xp_cmdshell", 1, big, "warn", "warning", "dbachecks XpCmdShellDisabled", "0"},
		{"xp_cmdshell", 0, big, "ok", "", "", ""},
		{"cost threshold for parallelism", 5, big, "warn", "warning", "sp_Blitz 188", "50"},
		{"cost threshold for parallelism", 30, big, "warn", "info", "sp_PerfCheck 1004", "50"},
		{"cost threshold for parallelism", 50, big, "ok", "", "", ""}, // not the default, and the best practice
		{"max server memory (MB)", unlimitedMemoryMB, big, "warn", "warning", "dbachecks MaxMemory", ""},
		{"max server memory (MB)", 4096, big, "ok", "", "", ""},
		{"max server memory (MB)", 9000, big, "warn", "warning", "sp_Blitz 50", ""},
		{"max server memory (MB)", 7900, big, "warn", "warning", "sp_PerfCheck 1002", ""},
		{"max server memory (MB)", 4096, machineFacts{Kind: KindServer}, "ok", "", "", ""},
		{"max server memory (MB)", unlimitedMemoryMB, machineFacts{Kind: KindAzureMI}, "none", "", "", ""},
		{"max degree of parallelism", 0, big, "warn", "info", "sp_Blitz 188", "8"},
		{"max degree of parallelism", 0, machineFacts{CPUs: 32, NUMANodes: 2, Kind: KindServer}, "warn", "info", "sp_Blitz 188", "16"},
		{"max degree of parallelism", 0, machineFacts{CPUs: 4, NUMANodes: 1, Kind: KindServer}, "ok", "", "", ""},
		{"max degree of parallelism", 0, machineFacts{Kind: KindServer}, "ok", "", "", ""},
		{"max degree of parallelism", 8, big, "ok", "", "", ""},
		{"min server memory (MB)", 0, big, "ok", "", "", ""},
		{"min server memory (MB)", 16, big, "ok", "", "", ""},
		{"min server memory (MB)", 1024, big, "warn", "info", "sp_Blitz 1036", "0"},
		{"remote access", 1, big, "ok", "", "", ""},
		{"remote access", 0, big, "warn", "info", "sp_Blitz 1048", "1"},
		{"remote admin connections", 0, big, "warn", "info", "sp_Blitz 100", "1"},
		{"remote admin connections", 1, big, "ok", "", "", ""},
		{"backup compression default", 0, big, "warn", "info", "sp_Blitz 116", "1"},
		{"backup compression default", 0, machineFacts{EngineEdition: 4, Kind: KindServer}, "ok", "", "", ""},
		{"backup compression default", 0, machineFacts{EngineEdition: 2, Edition: "Web Edition (64-bit)", Kind: KindServer}, "ok", "", "", ""},
		{"Agent XPs", 1, big, "ok", "", "", ""},
		{"Agent XPs", 0, big, "ok", "", "", ""},
		{"blocked process threshold (s)", 3, big, "warn", "warning", "blocked process threshold", ""},
		{"blocked process threshold (s)", 5, big, "ok", "", "", ""},
		{"blocked process threshold (s)", 0, big, "ok", "", "", ""},
		{"fill factor (%)", 80, big, "warn", "warning", "sp_Blitz 1020", "0"},
		{"fill factor (%)", 100, big, "ok", "", "", ""},
		{"default trace enabled", 0, big, "warn", "warning", "dbachecks DefaultTrace", "1"},
		{"an option no list knows", 7, big, "none", "", "", ""},
	}
	for _, c := range cases {
		v := judgeServerOption(c.name, c.value, c.m)
		if v.Status != c.status || v.Severity != c.severity || !strings.Contains(v.Rule, c.ruleHas) || !strings.Contains(v.Advised, c.advisedHas) {
			t.Errorf("%s = %d: status %q severity %q rule %q advised %q; want %q %q rule ~%q advised ~%q",
				c.name, c.value, v.Status, v.Severity, v.Rule, v.Advised, c.status, c.severity, c.ruleHas, c.advisedHas)
		}
		if (v.Severity != "") != (v.Explain != "" && v.Rule != "") {
			t.Errorf("%s = %d: a broken rule names its rule and says why, a met one raises nothing: %+v", c.name, c.value, v)
		}
	}
	// min server memory against max server memory, through the rows (the rule reads max from the same read)
	rows, fs := serverOptionRows([]collect.Row{
		{"name": "max server memory (MB)", "value_in_use": int64(4096), "value_set": int64(4096)},
		{"name": "min server memory (MB)", "value_in_use": int64(4096), "value_set": int64(4096)},
		{"name": "xp_cmdshell", "value_in_use": int64(0), "value_set": int64(1)},
	}, big)
	if len(rows) != 3 || len(fs) != 1 || fs[0].Rule != "sp_Blitz 190" || fs[0].Object != "min server memory (MB)" || fs[0].Value != "4096" || fs[0].Area != AreaConfig {
		t.Errorf("min = max: rows %d findings %+v", len(rows), fs)
	}
	if rows[2]["status"] != "ok" { // the value in use is judged, never the value set and not yet in use
		t.Errorf("xp_cmdshell set and not in use: %v", rows[2])
	}
}

func TestConfigDefaults(t *testing.T) {
	if len(configDefaults) != 109 {
		t.Errorf("%d defaults; sp_Blitz's table has 108 and min server memory makes 109", len(configDefaults))
	}
	for key := range serverOptionRules {
		if key != strings.ToLower(key) {
			t.Errorf("rule key %q is not lower case", key)
		}
		if _, ok := configDefaults[key]; !ok {
			t.Errorf("rule %q names no option of the defaults table (a typo makes the rule dead)", key)
		}
	}
	for name, want := range map[string]int64{"cost threshold for parallelism": 5, "max server memory (mb)": 2147483647, "remote access": 1,
		"two digit year cutoff": 2049, "clr strict security": 1, "xp_cmdshell": 0, "cursor threshold": -1} {
		if d, ok := configDefaults[name]; !ok || d.value != want {
			t.Errorf("default of %q: %+v, want %d", name, d, want)
		}
	}
}

func TestTraceFlagRows(t *testing.T) {
	raw := []collect.Row{
		{"TraceFlag": int64(1117), "Status": int64(1), "Global": int64(1), "Session": int64(0)},
		{"TraceFlag": int64(3226), "Status": int64(1), "Global": int64(1), "Session": int64(0)},
		{"TraceFlag": int64(9999), "Status": int64(1), "Global": int64(1), "Session": int64(0)},
		{"TraceFlag": int64(1222), "Status": int64(1), "Global": int64(0), "Session": int64(1)}, // this session's only
	}
	rows, fs := traceFlagRows(raw, Info{Kind: KindServer, Major: 16})
	got := map[int64]string{}
	for _, r := range rows {
		got[r["flag"].(int64)] = r["status"].(string) + "/" + map[int]string{0: "off", 1: "on"}[r["is_on"].(int)]
	}
	want := map[int64]string{1117: "warn/on", 3226: "ok/on", 9999: "warn/on", 7745: "warn/off"}
	if len(got) != len(want) {
		t.Fatalf("flags %v, want %v", got, want)
	}
	for f, w := range want {
		if got[f] != w {
			t.Errorf("flag %d: %s, want %s", f, got[f], w)
		}
	}
	if len(fs) != 3 {
		t.Errorf("%d findings, want 3 (1117 redundant, 9999 unknown, 7745 off): %+v", len(fs), fs)
	}
	// before SQL Server 2016 flag 1117 is in order; a managed platform is not asked for the advised flags
	rows, fs = traceFlagRows(raw[:1], Info{Kind: KindRDS, Major: 12})
	if len(rows) != 1 || rows[0]["status"] != "ok" || len(fs) != 0 {
		t.Errorf("1117 before 2016 on RDS: %v %+v", rows, fs)
	}
	// Azure SQL Managed Instance answers 12 and runs the current engine: the flag is redundant there
	if rows, _ = traceFlagRows(raw[:1], Info{Kind: KindAzureMI, Major: 12}); rows[0]["status"] != "warn" {
		t.Errorf("1117 on Managed Instance: %v", rows[0])
	}
	if rows, fs = traceFlagRows(nil, Info{Kind: KindRDS, Major: 16}); len(rows) != 0 || len(fs) != 0 {
		t.Errorf("no flag on: %v %+v", rows, fs)
	}
}

// The one read of the flags (mssql_traceflags) carries the checks' verdicts: a global flag its verdict, a flag of
// the collector's session alone none, a flag listed with Status 0 nothing, an advised flag that is off an 'advised'
// row, and the checks' area row and findings.
func TestTraceFlagPayload(t *testing.T) {
	raw := []collect.Row{
		{"TraceFlag": int64(1211), "Status": int64(1), "Global": int64(1), "Session": int64(0)},
		{"TraceFlag": int64(3226), "Status": int64(1), "Global": int64(1), "Session": int64(0)},
		{"TraceFlag": int64(1222), "Status": int64(1), "Global": int64(0), "Session": int64(1)}, // this session's only
		{"TraceFlag": int64(652), "Status": int64(0), "Global": int64(1), "Session": int64(0)},  // listed, off
	}
	out := traceFlagPayload(raw, Info{Kind: KindServer, Major: 16})
	kinds := map[string]int{}
	flags := map[int64]collect.Row{}
	for _, r := range out {
		k, _ := r["kind"].(string)
		kinds[k]++
		switch k {
		case "flag":
			f, _ := num(r["trace_flag"])
			flags[f] = r
		case "advised":
			if r["trace_flag"] != int64(7745) || r["status"] != "warn" || r["severity"] != sevInfo || r["rule"] != "Glenn Berry Q5" {
				t.Errorf("advised row: %v", r)
			}
		case "area":
			if r["area"] != AreaTraceFlags || r["read"] != 1 {
				t.Errorf("area row: %v", r)
			}
		case "finding":
			if r["area"] != AreaTraceFlags {
				t.Errorf("finding of another area: %v", r)
			}
		}
	}
	if kinds["read"] != 1 || kinds["flag"] != 3 || kinds["advised"] != 1 || kinds["area"] != 1 || kinds["finding"] != 2 {
		t.Fatalf("row kinds %v, want read 1, flag 3, advised 1, area 1, finding 2 (1211 on, 7745 off)", kinds)
	}
	if r := flags[1211]; r["status"] != "warn" || r["severity"] != sevWarning || r["rule"] != "sp_Blitz 74" || r["explain"] == nil {
		t.Errorf("1211: %v", r)
	}
	if r := flags[3226]; r["status"] != "ok" || r["severity"] != nil {
		t.Errorf("3226: %v", r)
	}
	if r := flags[1222]; r["status"] != nil || r["global"] != int64(0) || r["session"] != int64(1) {
		t.Errorf("1222 (the session's): %v", r)
	}
	if _, ok := flags[652]; ok {
		t.Errorf("652 is listed off and was carried: %v", flags[652])
	}
	// no flag on: the read row, the area row, the advised flags
	out = traceFlagPayload(nil, Info{Kind: KindServer, Major: 16})
	if len(out) != 6 || out[0]["kind"] != "read" {
		t.Errorf("no flag on: %v", out)
	}
}

func TestBuildCatalogue(t *testing.T) {
	for major, newest := range map[int]int{13: 7055, 14: 3530, 15: 4470, 16: 4255, 17: 4055} {
		rows := builds[major]
		if len(rows) == 0 || rows[0].Build != newest {
			t.Fatalf("major %d: newest build %v, want %d", major, rows, newest)
		}
		for i := 1; i < len(rows); i++ {
			if rows[i].Build >= rows[i-1].Build {
				t.Errorf("major %d: builds not strictly descending at %d (%d after %d)", major, i, rows[i].Build, rows[i-1].Build)
			}
		}
	}
	n := 0
	for _, rows := range builds {
		n += len(rows)
	}
	if n != 211 { // 214 lines, three builds listed twice
		t.Errorf("%d builds, want 211", n)
	}
	// a build listed twice keeps the row released first
	want := map[[2]int]string{{14, 3257}: "RTM CU18", {15, 4073}: "CU8", {16, 4236}: "CU23 v2"}
	for k, branch := range want {
		for _, r := range builds[k[0]] {
			if r.Build == k[1] && r.Branch != branch {
				t.Errorf("%d.0.%d kept %q, want %q (the row released first)", k[0], k[1], r.Branch, branch)
			}
		}
	}
	if isCU("CU23 v2") || isCU("CU4 GDR") || isCU("RC0") || !isCU("CU25") || !isCU("SP3") {
		t.Error("isCU: a re-release, a security release and a preview are not cumulative updates")
	}
}

func TestJudgeBuild(t *testing.T) {
	now := time.Date(2026, 11, 11, 0, 0, 0, 0, time.UTC)
	checks := func(fs []checkFinding) string {
		var s []string
		for _, f := range fs {
			s = append(s, f.Check+"/"+f.Severity)
		}
		return strings.Join(s, ", ")
	}
	// SQL Server 2022 CU14 (16.0.4135): sixteen builds behind the newest, eleven of them cumulative updates, released over a year before it
	info := Info{Kind: KindServer, Major: 16, Build: 4135, ProductVersion: "16.0.4135.4"}
	v := judgeBuild(info, now)
	if !v.Known || !v.Exact || v.Own.Branch != "CU14" || v.Newest.Build != 4255 || v.Behind != 16 || v.CUs != 11 || v.Status != "warn" {
		t.Errorf("CU14: %+v own %+v", v, v.Own)
	}
	if got := checks(v.findings(info)); got != "updates behind/warning" {
		t.Errorf("CU14 findings: %s", got)
	}
	// the newest build of the catalogue: nothing to raise
	info = Info{Kind: KindServer, Major: 16, Build: 4255, ProductVersion: "16.0.4255.1"}
	if v = judgeBuild(info, now); v.Behind != 0 || v.Status != "ok" || len(v.findings(info)) != 0 {
		t.Errorf("newest: %+v %s", v, checks(v.findings(info)))
	}
	// one cumulative update behind, under a year: advice
	info = Info{Kind: KindServer, Major: 16, Build: 4245, ProductVersion: "16.0.4245.2"}
	if v = judgeBuild(info, now); v.Behind != 2 || v.CUs != 1 || checks(v.findings(info)) != "updates behind/info" {
		t.Errorf("CU24: %+v %s", v, checks(v.findings(info)))
	}
	// newer than the catalogue: not behind, said in the note
	info = Info{Kind: KindServer, Major: 16, Build: 4315, ProductVersion: "16.0.4315.2"}
	if v = judgeBuild(info, now); !v.Newer || v.Behind != 0 || v.Status != "ok" || !strings.Contains(v.Note, "newer than the catalogue") || len(v.findings(info)) != 0 {
		t.Errorf("newer: %+v", v)
	}
	// a build between two of the catalogue takes the one under it
	info = Info{Kind: KindServer, Major: 16, Build: 4137, ProductVersion: "16.0.4137.1"}
	if v = judgeBuild(info, now); v.Exact || v.Own.Build != 4135 {
		t.Errorf("between: %+v own %+v", v, v.Own)
	}
	// SQL Server 2016 SP3: extended support ended 2026-07-14
	info = Info{Kind: KindServer, Major: 13, Build: 7055, ProductVersion: "13.0.7055.9"}
	if got := checks(judgeBuild(info, now).findings(info)); got != "support ended/warning" {
		t.Errorf("2016 SP3: %s", got)
	}
	// SQL Server 2019: mainstream support ended 2025-01-07, extended runs to 2030
	info = Info{Kind: KindServer, Major: 15, Build: 4470, ProductVersion: "15.0.4470.1"}
	if got := checks(judgeBuild(info, now).findings(info)); got != "mainstream support ended/info" {
		t.Errorf("2019: %s", got)
	}
	// SQL Server 2017 a hundred days before the end of its extended support
	info = Info{Kind: KindServer, Major: 14, Build: 3530, ProductVersion: "14.0.3530.1"}
	if got := checks(judgeBuild(info, time.Date(2027, 7, 4, 0, 0, 0, 0, time.UTC)).findings(info)); got != "support ending/warning" {
		t.Errorf("2017 near its end: %s", got)
	}
	// SQL Server 2016 SP3 GDR, fully patched: the Azure Feature Pack builds above it are another branch
	info = Info{Kind: KindServer, Major: 13, Build: 6490, ProductVersion: "13.0.6490.1"}
	if v = judgeBuild(info, now); v.Behind != 0 || !v.Exact || v.Newest.Build != 6490 {
		t.Errorf("2016 SP3 GDR 6490: behind %d, newest %v", v.Behind, v.Newest)
	}
	// a build the catalogue does not list (an RTM GDR of 2019): advice, the text says so and never borrows a date
	info = Info{Kind: KindServer, Major: 15, Build: 2120, ProductVersion: "15.0.2120.1"}
	v = judgeBuild(info, now)
	fs := v.findings(info)
	if v.Exact || len(fs) == 0 || fs[0].Severity != "info" || !strings.Contains(fs[0].Explain, "does not list") || !strings.Contains(v.Note, "not in the catalogue") {
		t.Errorf("2019 build 2120: %+v %+v", v, fs)
	}
	// a managed service and an unknown major are not weighed
	for _, in := range []Info{{Kind: KindAzureMI, Major: 12}, {Kind: KindServer, Major: 18, Build: 100}} {
		if v = judgeBuild(in, now); v.Known || v.Note == "" || len(v.findings(in)) != 0 || v.Status != "none" {
			t.Errorf("%s major %d: %+v", in.Kind, in.Major, v)
		}
	}
}

// db is a healthy user database; over changes it.
func db(over collect.Row) dbFacts {
	r := collect.Row{"database_id": int64(7), "database_name": "app", "state": "ONLINE", "user_access": "MULTI_USER", "read_only": int64(0),
		"in_standby": int64(0), "recovery_model": "FULL", "compatibility_level": int64(160), "collation": "SQL_Latin1_General_CP1_CI_AS",
		"owner": "sa", "page_verify": "CHECKSUM", "auto_close": int64(0), "auto_shrink": int64(0), "auto_create_stats": int64(1),
		"auto_update_stats": int64(1), "auto_update_stats_async": int64(0), "trustworthy": int64(0), "db_chaining": int64(0),
		"snapshot_isolation": "OFF", "rcsi": int64(0), "delayed_durability": "DISABLED", "target_recovery_secs": int64(60),
		"containment": "NONE", "cdc": int64(0), "broker": int64(0), "forced_parameterization": int64(0), "is_snapshot": int64(0),
		"log_reuse_wait": "NOTHING", "age_days": int64(400), "checkdb_never": int64(0), "checkdb_age_min": int64(60),
		"checkdb_at_utc": "2026-11-10T23:00:00Z", "log_size_mb": float64(64), "log_used_pct": float64(12.34), "vlf_count": int64(8)}
	for k, v := range over {
		r[k] = v
	}
	return dbFacts{r}
}

func TestDatabaseRules(t *testing.T) {
	srv := serverFactsOf(Info{Kind: KindServer, Major: 16}, "SQL_Latin1_General_CP1_CI_AS")
	if dev, fs := judgeDatabase(db(nil), srv); len(dev) != 0 || len(fs) != 0 {
		t.Fatalf("a healthy database deviates: %v %+v", dev, fs)
	}
	cases := []struct {
		over             collect.Row
		key, status, sev string
		area, ruleHas    string
	}{
		{collect.Row{"auto_close": int64(1)}, "auto_close", "warn", "warning", AreaDBOptions, "sp_Blitz 12"},
		{collect.Row{"auto_shrink": int64(1)}, "auto_shrink", "warn", "warning", AreaDBOptions, "sp_Blitz 13"},
		{collect.Row{"page_verify": "NONE"}, "page_verify", "crit", "critical", AreaDBOptions, "sp_Blitz 14"},
		{collect.Row{"page_verify": "TORN_PAGE_DETECTION"}, "page_verify", "warn", "warning", AreaDBOptions, "sp_Blitz 14"},
		{collect.Row{"auto_create_stats": int64(0)}, "auto_create_stats", "warn", "warning", AreaDBOptions, "sp_Blitz 15"},
		{collect.Row{"auto_update_stats": int64(0)}, "auto_update_stats", "warn", "warning", AreaDBOptions, "sp_Blitz 16"},
		{collect.Row{"trustworthy": int64(1)}, "trustworthy", "warn", "warning", AreaDBOptions, "dbachecks Trustworthy"},
		{collect.Row{"compatibility_level": int64(130)}, "compatibility_level", "warn", "info", AreaDBOptions, "dbachecks CompatibilityLevel"},
		{collect.Row{"delayed_durability": "FORCED"}, "delayed_durability", "warn", "warning", AreaDBOptions, "sp_PerfCheck 7008"},
		{collect.Row{"target_recovery_secs": int64(0)}, "target_recovery_secs", "warn", "info", AreaDBOptions, "sp_Blitz 257"},
		{collect.Row{"rcsi": int64(1)}, "rcsi", "warn", "info", AreaDBOptions, "sp_Blitz 133"},
		{collect.Row{"owner": nil}, "owner", "warn", "info", AreaDBOptions, "sp_Blitz 213"},
		{collect.Row{"collation": "Latin1_General_100_CI_AS"}, "collation", "warn", "info", AreaDBOptions, "Test-DbaDbCollation"},
		{collect.Row{"state": "SUSPECT"}, "state", "crit", "critical", AreaDBState, "sp_Blitz 102"},
		{collect.Row{"state": "OFFLINE"}, "state", "warn", "warning", AreaDBState, "sp_Blitz 102"},
		{collect.Row{"user_access": "SINGLE_USER"}, "user_access", "warn", "warning", AreaDBState, "sp_PerfCheck 7003"},
		{collect.Row{"log_used_pct": float64(80)}, "log_used_pct", "warn", "warning", AreaLog, "LogfilePercentUsed"},
		{collect.Row{"log_used_pct": float64(95.5)}, "log_used_pct", "crit", "critical", AreaLog, "LogfilePercentUsed"},
		{collect.Row{"vlf_count": int64(200)}, "vlf_count", "warn", "info", AreaLog, "Glenn Berry Q36"},
		{collect.Row{"vlf_count": int64(600)}, "vlf_count", "warn", "warning", AreaLog, "dbachecks VirtualLogFile"},
		{collect.Row{"vlf_count": int64(1000)}, "vlf_count", "warn", "warning", AreaLog, "sp_Blitz 69"},
		{collect.Row{"checkdb_never": int64(1)}, "last_good_checkdb", "crit", "critical", AreaCheckDB, "sp_Blitz 68"},
		{collect.Row{"checkdb_age_min": int64(8 * 1440)}, "last_good_checkdb", "warn", "warning", AreaCheckDB, "dbachecks LastGoodCheckDb"},
		{collect.Row{"checkdb_age_min": int64(7*1440 + 12*60)}, "last_good_checkdb", "warn", "warning", AreaCheckDB, "dbachecks LastGoodCheckDb"},
		{collect.Row{"checkdb_age_min": int64(15 * 1440)}, "last_good_checkdb", "crit", "critical", AreaCheckDB, "sp_Blitz 68"},
	}
	for _, c := range cases {
		dev, fs := judgeDatabase(db(c.over), srv)
		cell := dev[c.key]
		if len(dev) != 1 || len(fs) != 1 || cell["status"] != c.status || cell["severity"] != c.sev || !strings.Contains(cell["rule"], c.ruleHas) ||
			fs[0].Area != c.area || fs[0].Object != "app" || fs[0].Severity != c.sev {
			t.Errorf("%v: cells %v findings %+v; want %s %s %s in %s", c.over, dev, fs, c.key, c.status, c.ruleHas, c.area)
		}
	}
	// what must NOT be raised
	quiet := []collect.Row{
		{"state": "RESTORING"},                                                 // a log shipping or mirroring target
		{"checkdb_never": int64(1), "age_days": int64(2)},                      // a new database, not checked yet
		{"checkdb_never": int64(1), "read_only": int64(1)},                     // read only: CHECKDB cannot stamp it
		{"checkdb_never": nil},                                                 // not read
		{"database_id": int64(2), "checkdb_never": int64(1)},                   // tempdb is never checked
		{"database_id": int64(2), "page_verify": "NONE"},                       // tempdb's page verify is not the rule's
		{"database_id": int64(4), "trustworthy": int64(1), "broker": int64(1)}, // msdb ships that way
		{"database_id": int64(1), "db_chaining": int64(1)},                     // master ships that way
		{"compatibility_level": int64(160)},
		{"log_used_pct": float64(74.9)},
		{"vlf_count": int64(199)},
		{"checkdb_age_min": int64(6 * 1440)},
		{"checkdb_age_min": int64(7*1440 + 60)}, // a weekly CHECKDB running now: inside the half day's grace
		{"is_snapshot": int64(1), "auto_close": int64(1), "page_verify": "NONE"},
	}
	for _, over := range quiet {
		if dev, fs := judgeDatabase(db(over), srv); len(dev) != 0 || len(fs) != 0 {
			t.Errorf("%v must raise nothing: %v %+v", over, dev, fs)
		}
	}
	// Azure SQL Managed Instance has no version to hold a compatibility level to
	if dev, _ := judgeDatabase(db(collect.Row{"compatibility_level": int64(130)}), serverFactsOf(Info{Kind: KindAzureMI, Major: 12}, "")); len(dev) != 0 {
		t.Errorf("compatibility level on Managed Instance: %v", dev)
	}
	// the values the grid shows
	v := databaseValues(db(collect.Row{"checkdb_never": int64(1), "adr": nil}))
	if v["auto_close"] != "off" || v["auto_create_stats"] != "on" || v["page_verify"] != "CHECKSUM" || v["last_good_checkdb"] != "never" ||
		v["log_used_pct"] != 12.3 || v["vlf_count"] != int64(8) {
		t.Errorf("values: %v", v)
	}
	if _, has := v["adr"]; has {
		t.Error("an option the server does not have must be absent, never off")
	}
	if got := databaseValues(db(nil))["last_good_checkdb"]; got != "2026-11-10T23:00:00Z" {
		t.Errorf("last good CHECKDB: %v", got)
	}
	// every rule names a column of the grid, and every column key is one the read returns
	keys := map[string]bool{}
	for _, o := range databaseOptions {
		keys[o.Key] = true
		if o.Key != "last_good_checkdb" && !strings.Contains(databasesSQL+" log_size_mb log_used_pct vlf_count", " "+o.Key) {
			t.Errorf("grid column %q is not a column of the read", o.Key)
		}
	}
	for _, r := range databaseRules {
		if !keys[r.key] {
			t.Errorf("rule %q judges %q, which is no column of the grid", r.check, r.key)
		}
	}
}

func TestDatabasesQuery(t *testing.T) {
	old := databasesQuery(map[string]bool{})
	if strings.Contains(old, "is_ledger_on") || strings.Contains(old, "is_optimized_locking_on") || strings.Contains(old, "is_accelerated_database_recovery_on") {
		t.Error("a server without the newer columns must not be asked for them")
	}
	now := databasesQuery(map[string]bool{"is_ledger_on": true, "is_optimized_locking_on": true, "is_accelerated_database_recovery_on": true})
	for _, c := range []string{"d.is_ledger_on", "d.is_optimized_locking_on", "d.is_accelerated_database_recovery_on"} {
		if !strings.Contains(now, c) {
			t.Errorf("the read lacks %s", c)
		}
	}
	if strings.Contains(old, "%!") || strings.Contains(now, "%!") {
		t.Error("a format verb was left unfilled")
	}
	if !hasVLFView(Info{Kind: KindServer, Major: 13, Build: 5026}) || hasVLFView(Info{Kind: KindServer, Major: 13, Build: 4001}) || !hasVLFView(Info{Kind: KindAzureMI, Major: 12}) {
		t.Error("sys.dm_db_log_info is SQL Server 2016 SP2 (13.0.5026) and later, and on Managed Instance")
	}
}

func TestSuspectPageRows(t *testing.T) {
	page := func(db string, event, errors, age int64) collect.Row {
		return collect.Row{"database_name": db, "file_id": int64(1), "page_id": int64(153), "event_type": event, "error_count": errors,
			"age_days": age, "last_update_utc": "2026-11-10T10:00:00Z"}
	}
	rows, fs := suspectPageRows([]collect.Row{page("a", 2, 3, 1), page("a", 1, 1, 40), page("b", 3, 1, 45), page("c", 5, 1, 2), page("c", 4, 1, 2)})
	if len(rows) != 5 || rows[0]["kind"] != "suspect_page" || rows[0]["event"] != "bad checksum" {
		t.Fatalf("rows: %v", rows)
	}
	if len(fs) != 2 || fs[0].Object != "a" || fs[0].Severity != "critical" || fs[0].Value != "2" || fs[1].Object != "b" || fs[1].Severity != "warning" {
		t.Errorf("findings (a critical: a page under 30 days; b a warning: older; c none: repaired and restored): %+v", fs)
	}
	var full []collect.Row
	for i := 0; i < suspectNearCap; i++ {
		full = append(full, page("z", 5, 1, 100))
	}
	if _, fs = suspectPageRows(full); len(fs) != 1 || fs[0].Rule != "dbachecks SuspectPageLimit" {
		t.Errorf("a table at %d rows: %+v", suspectNearCap, fs)
	}
	if rows, fs = suspectPageRows(nil); len(rows) != 0 || len(fs) != 0 {
		t.Errorf("an empty table: %v %+v", rows, fs)
	}
}

func TestAgentAlertFindings(t *testing.T) {
	names := func(fs []checkFinding) string {
		var s []string
		for _, f := range fs {
			s = append(s, f.Check+"/"+f.Severity)
		}
		return strings.Join(s, ", ")
	}
	// a new server: nothing defined
	if got := names(agentAlertFindings(nil, nil, true, "")); got != "no operator/warning, no alerts for severity 19 to 25/warning, no alerts for corruption errors/warning, no fail-safe operator/info" {
		t.Errorf("a new server: %s", got)
	}
	alert := func(name string, sev, msg, enabled, notifies int64) collect.Row {
		return collect.Row{"name": name, "severity": sev, "message_id": msg, "enabled": enabled, "notifies": notifies, "has_job": int64(0), "include_event_description": int64(1)}
	}
	var all []collect.Row
	for _, s := range alertSeverities {
		all = append(all, alert("sev", s, 0, 1, 1))
	}
	for _, e := range alertErrors {
		all = append(all, alert("err", 0, e, 1, 1))
	}
	ops := []collect.Row{{"name": "dba", "enabled": int64(1)}}
	if fs := agentAlertFindings(all, ops, true, "dba"); len(fs) != 0 {
		t.Errorf("a server set up in full: %s", names(fs))
	}
	// the fail-safe operator out of sp_MSgetalertinfo's row: a name, NULL, no such column, no row
	if op, read, note := failSafeFromRows([]collect.Row{{"AlertFailSafeOperator": " dba ", "AlertNotificationMethod": int64(1)}}); op != "dba" || !read || note != "" {
		t.Errorf("fail-safe set: %q %v %q", op, read, note)
	}
	if op, read, note := failSafeFromRows([]collect.Row{{"AlertFailSafeOperator": nil, "AlertNotificationMethod": int64(0)}}); op != "" || !read || note != "" {
		t.Errorf("fail-safe NULL: %q %v %q", op, read, note)
	}
	if op, read, note := failSafeFromRows([]collect.Row{{"FailSafeOperator": "dba"}}); op != "" || read || !strings.Contains(note, "no AlertFailSafeOperator column") {
		t.Errorf("fail-safe column missing: %q %v %q", op, read, note)
	}
	if _, read, note := failSafeFromRows(nil); read || !strings.Contains(note, "0 rows") {
		t.Errorf("fail-safe no row: %v %q", read, note)
	}
	// the fail-safe operator not readable: its rule is left out, never raised
	if fs := agentAlertFindings(all, ops, false, ""); len(fs) != 0 {
		t.Errorf("fail-safe not read: %s", names(fs))
	}
	// one severity missing, one alert disabled, one that notifies nobody, one without the error's text, a disabled operator
	part := append([]collect.Row{}, all[1:]...)
	part[0] = alert("off", 20, 0, 0, 1)
	part[1] = alert("mute", 21, 0, 1, 0)
	part[2]["include_event_description"] = int64(0)
	got := names(agentAlertFindings(part, []collect.Row{{"name": "dba", "enabled": int64(0)}}, true, "dba"))
	want := "no operator/warning, alert disabled/info, alert without a response/info, alert without the error's text/info, alerts missing for some severities/info"
	if got != want {
		t.Errorf("a server set up in part:\n got %s\nwant %s", got, want)
	}
}

func TestIdentityRows(t *testing.T) {
	raw := []collect.Row{
		{"columns_total": int64(3), "schema_name": "dbo", "table_name": "orders", "column_name": "id", "type_name": "int", "last_value": "2040109465", "max_value": "2147483647", "pct_used": "95.00"},
		{"columns_total": int64(3), "schema_name": "dbo", "table_name": "lines", "column_name": "id", "type_name": "smallint", "last_value": "26214", "max_value": "32767", "pct_used": "80.00"},
		{"columns_total": int64(3), "schema_name": "dbo", "table_name": "notes", "column_name": "id", "type_name": "int", "last_value": "322122547", "max_value": "2147483647", "pct_used": "15.00"},
	}
	rows, fs := identityRows("shop", raw)
	if len(rows) != 3 || rows[0]["status"] != "crit" || rows[1]["status"] != "warn" || rows[2]["status"] != "ok" || rows[0]["pct_used"] != 95.0 {
		t.Fatalf("rows: %v", rows)
	}
	if len(fs) != 2 || fs[0].Severity != "critical" || fs[0].Object != "shop.dbo.orders.id" || fs[0].Value != "95.00" || fs[1].Severity != "warning" || fs[0].Area != AreaIdentity {
		t.Errorf("findings: %+v", fs)
	}
	// a database with identity columns and none at the floor returns the count's row alone
	if rows, fs = identityRows("shop", []collect.Row{{"columns_total": int64(12), "column_name": nil}}); len(rows) != 0 || len(fs) != 0 {
		t.Errorf("no column at the floor: %v %+v", rows, fs)
	}
}

// Nothing of the two collections writes: a statement is a SELECT, a DBCC status command, the fail-safe read, or
// the identity scan's SELECT run through a database's own sys.sp_executesql.
func TestChecksStatementsReadOnly(t *testing.T) {
	for _, q := range []string{checksConfigSQL, databasesColsSQL, databasesQuery(nil), vlfSQL, suspectPagesSQL, agentAlertsSQL, agentOperatorsSQL, identityDatabasesSQL} {
		u := strings.ToUpper(q)
		if !strings.HasPrefix(strings.TrimSpace(u), "SELECT") {
			t.Errorf("not a SELECT: %s", q)
		}
		for _, bad := range []string{"EXEC ", "EXECUTE", "INSERT ", "UPDATE ", "DELETE ", "MERGE ", "XP_", " SP_", ".SP_", "DBCC", " INTO "} {
			if strings.Contains(u, bad) {
				t.Errorf("a statement holds %q: %s", bad, q)
			}
		}
	}
	if traceFlagsSQL != "DBCC TRACESTATUS(-1) WITH NO_INFOMSGS" || logSpaceSQL != "DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS" || failSafeSQL != "EXEC master.dbo.sp_MSgetalertinfo @includeaddresses = 0" {
		t.Error("the three statements that are not a SELECT changed: each is a status read and must stay one")
	}
	scan := strings.ToUpper(identitySQL)
	if !strings.HasPrefix(scan, "EXEC %S.SYS.SP_EXECUTESQL N'SELECT ") {
		t.Errorf("the identity scan is one SELECT through the database's sys.sp_executesql: %s", identitySQL)
	}
	for _, bad := range []string{"INSERT ", "UPDATE ", "DELETE ", "MERGE ", "XP_", " INTO ", "DBCC", "ALTER ", "DROP "} {
		if strings.Contains(scan, bad) {
			t.Errorf("the identity scan holds %q", bad)
		}
	}
	// no payload row carries a column the text policy rewrites
	for _, r := range []collect.Row{checkFinding{}.row(), areaRow("x", true, ""), flagRow(1, true, "", "", ""), judgeBuild(Info{Kind: KindServer, Major: 16, Build: 4135}, time.Now()).row()} {
		for _, k := range []string{"detail", "query", "statement"} {
			if _, has := r[k]; has {
				t.Errorf("a payload row carries %q, which the query-text policy rewrites: %v", k, r)
			}
		}
	}
}
