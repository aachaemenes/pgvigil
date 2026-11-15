package mssql

import (
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

func row(object, counter, inst string, value, ctype int64) collect.Row {
	return collect.Row{"object": object, "counter": counter, "instance": inst, "value": value, "type": ctype}
}

// A fraction and an average get their base by Telegraf's rule (' base', ' (ms)' -> ' base', any case) and by the
// irregular names read on SQL Server 2017-2022; a fraction without its base is 'unpaired'; a base is never a row;
// the system names stay out; an empty instance reads as _Total; the list's kind wins over the type's.
func TestPairCounters(t *testing.T) {
	rows := []collect.Row{
		row("SQLServer:Buffer Manager", "Buffer cache hit ratio", "", 610, typeFraction),
		row("SQLServer:Buffer Manager", "Buffer cache hit ratio base", "", 624, typeBase),
		row("SQLServer:Locks", "Average Wait Time (ms)", "_Total", 6974, typeAverage),
		row("SQLServer:Locks", "Average Wait Time Base", "_Total", 16, typeBase),
		row("SQLServer:Locks", "Average Wait Time (ms)", "Key", 70, typeAverage),
		row("SQLServer:Locks", "Average Wait Time Base", "Key", 7, typeBase),
		row("MSSQL$NAMED:Access Methods", "Worktables From Cache Ratio", "", 40, typeFraction),
		row("MSSQL$NAMED:Access Methods", "Worktables From Cache Base", "", 80, typeBase),
		row("SQLServer:HTTP Storage", "Avg. Bytes/Read", "", 9, typeAverage),
		row("SQLServer:HTTP Storage", "Avg. Bytes/Read BASE", "", 3, typeBase),
		row("SQLServer:FileTable", "Avg time per file I/O request", "", 5, typeAverage),
		row("SQLServer:FileTable", "Time per file I/O request BASE", "", 2, typeBase),
		row("SQLServer:Plan Cache", "Cache Hit Ratio", "SQL Plans", 5, typeFraction), // no base read
		row("SQLServer:Deprecated Features", "Usage", "'::' function calling syntax", 3, typeRawLarge),
		row("SQLServer:Workload Group Stats", "CPU usage %", "internal", 1, typeFraction),
		row("SQLServer:General Statistics", "Logins/sec", "", 120, typeBulk),
		row("SQLServer:General Statistics", "Logouts/sec", "", 119, typeBulk), // not listed
	}
	list := []CounterSpec{
		{Object: "Buffer Manager", Counter: "Buffer cache hit ratio", Scope: "instance"},
		{Object: "Locks", Counter: "Average Wait Time (ms)", Instance: "_Total", Scope: "instance"},
		{Object: "Access Methods", Counter: "Worktables From Cache Ratio", Scope: "instance"},
		{Object: "HTTP Storage", Counter: "Avg. Bytes/Read", Scope: "instance"},
		{Object: "FileTable", Counter: "Avg time per file I/O request", Scope: "instance"},
		{Object: "Plan Cache", Counter: "Cache Hit Ratio", Scope: "instance"},
		{Object: "Deprecated Features", Counter: "Usage", Scope: "instance", Kind: "count"},
		{Object: "Workload Group Stats", Counter: "CPU usage %", Scope: "instance"},
		{Object: "general statistics", Counter: "logins/sec", Scope: "instance"},
	}
	got := map[string]collect.Row{}
	for _, r := range pairCounters(rows, list) {
		got[r["object"].(string)+"|"+r["counter"].(string)+"|"+r["instance"].(string)] = r
	}
	want := map[string]struct {
		kind string
		base any
	}{
		"Buffer Manager|Buffer cache hit ratio|_Total":           {"fraction", int64(624)},
		"Locks|Average Wait Time (ms)|_Total":                    {"average", int64(16)},
		"Access Methods|Worktables From Cache Ratio|_Total":      {"fraction", int64(80)},
		"HTTP Storage|Avg. Bytes/Read|_Total":                    {"average", int64(3)},
		"FileTable|Avg time per file I/O request|_Total":         {"average", int64(2)},
		"Plan Cache|Cache Hit Ratio|SQL Plans":                   {"unpaired", nil},
		"Deprecated Features|Usage|'::' function calling syntax": {"count", nil},
		"General Statistics|Logins/sec|_Total":                   {"rate", nil},
	}
	if len(got) != len(want) {
		t.Errorf("%d rows, want %d: %v", len(got), len(want), got)
	}
	for k, w := range want {
		r, ok := got[k]
		if !ok {
			t.Errorf("no row %s", k)
			continue
		}
		if r["ckind"] != w.kind || r["base"] != w.base || r["kind"] != "ctr" {
			t.Errorf("%s: kind %v base %v, want %s %v", k, r["ckind"], r["base"], w.kind, w.base)
		}
	}
	if _, ok := got["Locks|Average Wait Time (ms)|Key"]; ok {
		t.Error("an instance line read another instance")
	}
	if _, ok := got["Workload Group Stats|CPU usage %|internal"]; ok {
		t.Error("a system name (internal) was kept")
	}
}

func TestCounterKind(t *testing.T) {
	cases := []struct {
		ctype   int64
		given   string
		hasBase bool
		want    string
	}{
		{typeRawLarge, "", false, "gauge"}, {65536, "", false, "gauge"}, {typeBulk, "", false, "rate"}, {typeCounter, "", false, "rate"},
		{typeFraction, "", true, "fraction"}, {typeFraction, "", false, "unpaired"}, {typeAverage, "", true, "average"},
		{typeAverage, "", false, "unpaired"}, {typeRawLarge, "count", false, "count"}, {typeBulk, "gauge", false, "gauge"},
		{999, "", false, "gauge"}, {typeRawLarge, "nonsense", false, "gauge"},
	}
	for _, c := range cases {
		if got := counterKind(c.ctype, c.given, c.hasBase); got != c.want {
			t.Errorf("counterKind(%d, %q, %v) = %s, want %s", c.ctype, c.given, c.hasBase, got, c.want)
		}
	}
}

func TestParseCounterList(t *testing.T) {
	l, err := ParseCounterList([]byte(`[{"object":"General Statistics","counter":"Logins/sec","inst":"","scope":"instance","kind":""},
		{"object":"Databases","counter":"Log Growths","scope":"database","kind":"count"}]`))
	if err != nil || len(l) != 2 || l[1].Kind != "count" || l[1].Scope != "database" {
		t.Fatalf("got %+v, %v", l, err)
	}
	for _, bad := range []string{`{}`, `[{"object":"","counter":"x","scope":"instance"}]`, `[{"object":"a","counter":"x","scope":"server"}]`} {
		if _, err := ParseCounterList([]byte(bad)); err == nil {
			t.Errorf("%s accepted", bad)
		}
	}
	if l, err := ParseCounterList([]byte(`[]`)); err != nil || len(l) != 0 {
		t.Errorf("an empty list: %v %v", l, err)
	}
}

// Only the allow-listed DMV columns reach a statement; a name with a quote is doubled in the counters' IN list; the
// scope picks the objects.
func TestCounterQueries(t *testing.T) {
	list := []CounterSpec{
		{Object: "sys.dm_os_process_memory", Counter: "available_commit_limit_kb", Scope: "instance"},
		{Object: "sys.dm_os_process_memory", Counter: "x; DROP TABLE t --", Scope: "instance"},
		{Object: "sys.dm_os_schedulers", Counter: "failed_to_create_worker", Scope: "instance"},
		{Object: "General Statistics", Counter: "it's", Scope: "instance"},
	}
	q, specs := pseudoQuery("sys.dm_os_process_memory", list)
	if strings.Contains(q, "DROP") || len(specs) != 1 || !strings.Contains(q, "MAX(available_commit_limit_kb) AS available_commit_limit_kb") {
		t.Errorf("pseudo query %q (%d specs)", q, len(specs))
	}
	if q, _ := pseudoQuery("sys.dm_os_schedulers", list); !strings.HasSuffix(q, "WHERE status = N'VISIBLE ONLINE'") {
		t.Errorf("schedulers query %q", q)
	}
	ci := counterQuery(list, "instance")
	if !strings.Contains(ci, "N'it''s'") || strings.Contains(ci, "available_commit_limit_kb") || !strings.Contains(ci, "NOT (RTRIM(object_name) LIKE N'%:Databases'") {
		t.Errorf("instance query %q", ci)
	}
	if cd := counterQuery([]CounterSpec{{Object: "Databases", Counter: "Log Growths", Scope: "database"}}, "database"); strings.Contains(cd, "NOT (") {
		t.Errorf("database query %q", cd)
	}
	if counterQuery(nil, "instance") != "" {
		t.Error("an empty list made a statement")
	}
	rows := pseudoRows("sys.dm_os_process_memory", []collect.Row{{"available_commit_limit_kb": int64(5)}}, specs)
	if len(rows) != 1 || rows[0]["ckind"] != "gauge" || rows[0]["type"] != int64(typeRawLarge) || rows[0]["instance"] != "_Total" {
		t.Errorf("pseudo rows %v", rows)
	}
}

// The counters a page or a rule reads are the same in Go (countersInUse: config validation) and in 0152's defaults
// (used_by: Admin's door and the list function), and every one of them is a default.
func TestCountersInUseMatchMigration(t *testing.T) {
	b, err := os.ReadFile("../repo/sql/0152_mssql_counters.sql")
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	i := strings.Index(s, "UPDATE pgvigil.mssql_counter_defaults d SET used_by")
	j := strings.Index(s[i:], ") AS u(object, counter, why)")
	if i < 0 || j < 0 {
		t.Fatal("0152's used_by block not found")
	}
	re := regexp.MustCompile(`\('((?:[^']|'')*)', '((?:[^']|'')*)', '((?:[^']|'')*)'\)`)
	sqlUse := map[[2]string]string{}
	for _, m := range re.FindAllStringSubmatch(s[i:i+j], -1) {
		sqlUse[[2]string{m[1], m[2]}] = strings.ReplaceAll(m[3], "''", "'")
	}
	if len(sqlUse) != len(countersInUse) {
		t.Errorf("0152 names %d counters in use, countersInUse %d", len(sqlUse), len(countersInUse))
	}
	for k, v := range countersInUse {
		if sqlUse[k] != v {
			t.Errorf("%v: Go %q, 0152 %q", k, v, sqlUse[k])
		}
		if !strings.Contains(s[:i], "('"+k[0]+"', '"+strings.ReplaceAll(k[1], "'", "''")+"', ") {
			t.Errorf("%v is in use but not a default", k)
		}
		if CounterInUse(strings.ToUpper(k[0]), strings.ToLower(k[1])) == "" {
			t.Errorf("CounterInUse misses %v in another case", k)
		}
	}
	if CounterInUse("Deprecated Features", "Usage") != "" {
		t.Error("a counter nothing reads is in use")
	}
}
