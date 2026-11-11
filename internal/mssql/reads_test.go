package mssql

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The helpers of the properties, procedure and index lock collections that no SQL Server at hand exercises: the
// Windows power plan's branches (every sandbox is Linux), the per cent's rounding, the optional columns of an older
// sys.dm_os_sys_info, and the choice of the objects whose names are read.

func TestPowerPlanOf(t *testing.T) {
	const high, balanced = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c", "381b4222-f694-41f0-9685-ff5bb260df2e"
	for _, c := range []struct {
		name      string
		rows      []collect.Row
		value     any
		noteParts []string // every one must be in the note; none = the note is empty
	}{
		{"high performance, braces and upper case", []collect.Row{{"policy_scheme": nil, "scheme": "{" + strings.ToUpper(high) + "}"}}, "High performance", nil},
		{"balanced carries the warning", []collect.Row{{"policy_scheme": nil, "scheme": balanced}}, "Balanced", []string{"High performance"}},
		{"the policy's plan wins over the machine's", []collect.Row{{"policy_scheme": high, "scheme": balanced}}, "High performance", []string{"Group Policy"}},
		{"a balanced policy is named as the policy's", []collect.Row{{"policy_scheme": balanced, "scheme": high}}, "Balanced", []string{"High performance", "Group Policy"}},
		{"ultimate performance is no warning", []collect.Row{{"policy_scheme": nil, "scheme": "e9a42b02-d5df-448d-aa00-03f14749eb61"}}, "Ultimate Performance", nil},
		{"a scheme of the machine's own shows its id", []collect.Row{{"policy_scheme": nil, "scheme": "11111111-2222-3333-4444-555555555555"}}, "11111111-2222-3333-4444-555555555555", []string{"machine's own"}},
		{"no value in either key", []collect.Row{{"policy_scheme": nil, "scheme": nil}}, nil, []string{"not read"}},
		{"an empty policy value falls back", []collect.Row{{"policy_scheme": "  ", "scheme": high}}, "High performance", nil},
		{"no row", nil, nil, []string{"not read"}},
	} {
		v, note := powerPlanOf(c.rows)
		if v != c.value {
			t.Errorf("%s: value %v, want %v", c.name, v, c.value)
		}
		if len(c.noteParts) == 0 && note != "" {
			t.Errorf("%s: note %q, want none", c.name, note)
		}
		for _, p := range c.noteParts {
			if !strings.Contains(note, p) {
				t.Errorf("%s: note %q lacks %q", c.name, note, p)
			}
		}
	}
}

func TestPctText(t *testing.T) {
	for _, c := range []struct {
		part, whole int64
		want        string
	}{
		{1536, 4208, "36.5"}, // DBA Dash's own example: 1,536 MB of 4.1 GB
		{1, 16, "6.3"},       // 6.25: a half goes up (a float formats it 6.2)
		{1536, 24576, "6.3"}, // the same tie on a 24 GB machine
		{0, 5, "0.0"},
		{2, 1, "200.0"}, // more than the machine has
		{1, 3, "33.3"},
		{2, 3, "66.7"},
		{4096, 4096, "100.0"},
	} {
		if got := pctText(c.part, c.whole); got != c.want {
			t.Errorf("pctText(%d, %d) = %q, want %q", c.part, c.whole, got, c.want)
		}
	}
}

func TestSysInfoSQL(t *testing.T) {
	// SQL Server 2016 SP1: none of the three topology columns, both descriptions
	old := sysInfoSQL(map[string]bool{"softnuma_configuration_desc": true, "sql_memory_model_desc": true})
	for _, want := range []string{"CAST(NULL AS bigint) AS socket_count", "CAST(NULL AS bigint) AS cores_per_socket", "CAST(NULL AS bigint) AS numa_nodes",
		"CAST(si.softnuma_configuration_desc AS nvarchar(60)) AS soft_numa", "CAST(si.sql_memory_model_desc AS nvarchar(60)) AS memory_model"} {
		if !strings.Contains(old, want) {
			t.Errorf("an older server's statement lacks %q", want)
		}
	}
	none := sysInfoSQL(map[string]bool{})
	if n := strings.Count(none, "CAST(NULL AS "); n != 5 {
		t.Errorf("no optional column: %d NULL columns, want 5", n)
	}
	if strings.Contains(none, "si.socket_count") || strings.Contains(none, "si.numa_node_count") {
		t.Error("a column the server does not have is still read")
	}
	all := sysInfoSQL(map[string]bool{"socket_count": true, "cores_per_socket": true, "numa_node_count": true, "softnuma_configuration_desc": true, "sql_memory_model_desc": true})
	if strings.Contains(all, "CAST(NULL AS ") {
		t.Error("a current server's statement reads a NULL for a column it has")
	}
}

func TestPropRow(t *testing.T) {
	r := propRow("cpu_count", "Processor", "Logical CPUs", 200, int64(24), "", true)
	if r["value"] != "24" || r["note"] != nil || r["track"] != true || r["kind"] != "property" {
		t.Errorf("a read value: %v", r)
	}
	r = propRow("power_plan", "Processor", "Power plan", 310, nil, "not read: why", true)
	if r["value"] != nil || r["note"] != "not read: why" {
		t.Errorf("a value not read: %v", r)
	}
	if got := propText(yesNo(int64(1))); got != "yes" {
		t.Errorf("yesNo(1) = %q", got)
	}
	if yesNo(nil) != nil {
		t.Error("yesNo(nil) is not nil: a value not read would read as no")
	}
	if got := joinNonEmpty("RTM", "CU27"); got != "RTM CU27" {
		t.Errorf("joinNonEmpty = %v", got)
	}
	if joinNonEmpty(nil, " ") != nil {
		t.Error("joinNonEmpty of nothing is not nil")
	}
}

func TestIndexObjects(t *testing.T) {
	// rows in the collector's order (the most lock wait first): two databases, an object with two indexes, a cap of 2 per database
	rows := []collect.Row{
		{"database_id": int64(5), "object_id": int64(10)}, {"database_id": int64(7), "object_id": int64(30)},
		{"database_id": int64(5), "object_id": int64(10)}, {"database_id": int64(5), "object_id": int64(11)},
		{"database_id": int64(5), "object_id": int64(12)}, {"database_id": int64(5), "object_id": int64(13)},
	}
	want, order, past := indexObjects(rows, 2)
	if len(order) != 2 || order[0] != 5 || order[1] != 7 {
		t.Errorf("the databases' order: %v", order)
	}
	if got := strings.Join(want[5], ","); got != "10,11" {
		t.Errorf("database 5's objects: %s, want 10,11 (the two with the most lock wait, once each)", got)
	}
	if past != 2 {
		t.Errorf("%d objects past the cap, want 2", past)
	}
	// the names land on the right rows, by object and index
	named := []collect.Row{
		{"database_id": int64(5), "object_id": int64(10), "index_id": int64(1)},
		{"database_id": int64(7), "object_id": int64(10), "index_id": int64(1)},
	}
	applyIndexNames(named, 5, []collect.Row{{"object_id": int64(10), "index_id": int64(1), "schema_name": "dbo", "table_name": "t", "index_name": "pk", "index_type": "CLUSTERED"}})
	if named[0]["table_name"] != "t" || named[1]["table_name"] != nil {
		t.Errorf("the names went to the wrong database's row: %v", named)
	}
}

func TestProcStatsQuery(t *testing.T) {
	with, without := procStatsQuery(true), procStatsQuery(false)
	if !strings.Contains(with, "OBJECT_NAME(ps.object_id, ps.database_id)") || strings.Contains(without, "OBJECT_NAME(") {
		t.Error("the names are in the wrong statement")
	}
	for _, q := range []string{with, without} {
		if !strings.Contains(q, "TOP (5001)") || !strings.Contains(q, "ps.plan_handle AS plan_handle") || !strings.Contains(q, "ps.database_id <> 32767") {
			t.Errorf("the statement lost its cut, its plan handle or its resource database filter:\n%s", q)
		}
		if strings.Contains(q, "{{") {
			t.Errorf("a token was left unfilled:\n%s", q)
		}
	}
}
