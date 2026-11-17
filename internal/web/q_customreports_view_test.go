package web

import (
	"strings"
	"testing"
)

// TestValidViewRefuses: parity set 3's view keys refused in words, and an empty view stored as none ('{}' draws as
// before 0372)
func TestValidViewRefuses(t *testing.T) {
	bad := map[string]reportView{
		"an engine":            {Visibility: &reportVisibility{Engines: []string{"oracle"}}},
		"a role":               {Access: []string{"owner"}},
		"a set twice":          {Sets: []reportSetView{{Set: 0, Name: "a"}, {Set: 0, Name: "b"}}},
		"a set's number":       {Sets: []reportSetView{{Set: 50, Name: "a"}}},
		"a pair without words": {Pair: &reportPair{ReportID: 3}},
		"a javascript url":     {URL: "javascript:alert(1)"},
		"a label without url":  {URLLabel: "Runbook"},
		"a height":             {Layout: &reportLayout{Heights: map[string]int{"0": 50}}},
		"a chart layout":       {Layout: &reportLayout{ChartLayout: "grid"}},
		"two links on one":     {Links: []reportLink{{Column: "a", Kind: "url"}, {Column: "A", Kind: "text"}}},
		"a link's kind":        {Links: []reportLink{{Column: "a", Kind: "mailto"}}},
		"a drill's report":     {Links: []reportLink{{Column: "a", Kind: "drill"}}},
		"a tree's tab":         {Links: []reportLink{{Column: "a", Kind: "tree", InstanceColumn: "iid", Tab: "../x"}}},
		"a chart's type":       {Charts: []reportChart{{Type: "Bubble", X: "t", Metrics: []string{"v"}}}},
		"a chart's metrics":    {Charts: []reportChart{{Type: "Line", X: "t"}}},
		"a system chart twice": {SystemCharts: []string{"cpu", "cpu"}},
		"a system chart":       {SystemCharts: []string{"memory"}},
	}
	for name, v := range bad {
		if err := validView(&v); err == nil {
			t.Errorf("%s: taken, want refused", name)
		}
	}
	empty := reportView{Visibility: &reportVisibility{}, Sets: []reportSetView{{Set: 1}}, Layout: &reportLayout{}}
	if err := validView(&empty); err != nil || empty.Visibility != nil || empty.Sets != nil || empty.Layout != nil {
		t.Errorf("an empty view: %v %+v, want stored as none", err, empty)
	}
	ok := reportView{URL: "https://example.org/runbook", URLLabel: "Runbook", Pair: &reportPair{ReportID: 3, Label: "Charts"},
		Links:  []reportLink{{Column: "n", Kind: "drill", ReportID: 4, Map: map[string]string{"n": "n"}, Open: "panel"}},
		Charts: []reportChart{{Type: "Scatter", X: "t", Metrics: []string{"v"}, HiddenWhen: "hide"}}, SystemCharts: []string{"cpu", "blocking"}}
	if err := validView(&ok); err != nil {
		t.Errorf("a full view refused: %v", err)
	}
}

// TestValidPickerTypes: a list picker's values and default are values of the parameter's type
func TestValidPickerTypes(t *testing.T) {
	d := func(s string) *string { return &s }
	cases := []struct {
		p    reportParam
		want bool
	}{
		{reportParam{Name: "k", Type: "text", Default: d("a"), Picker: &reportPicker{Kind: "list", Values: []string{"a", "b"}}}, true},
		{reportParam{Name: "k", Type: "text", Default: d("c"), Picker: &reportPicker{Kind: "list", Values: []string{"a", "b"}}}, false},
		{reportParam{Name: "n", Type: "int", Picker: &reportPicker{Kind: "list", Values: []string{"1", "x"}}}, false},
		{reportParam{Name: "q", Type: "text", Picker: &reportPicker{Kind: "text", Values: []string{"a"}}}, false},
		{reportParam{Name: "q", Type: "text", Picker: &reportPicker{Kind: "query"}}, false},
		{reportParam{Name: "q", Type: "text", Picker: &reportPicker{Kind: "query", Query: "SELECT 1"}}, true},
		{reportParam{Name: "q", Type: "text", Picker: &reportPicker{Kind: "radio"}}, false},
	}
	for i, c := range cases {
		if err := validPicker(c.p); (err == nil) != c.want {
			t.Errorf("case %d: %v, want taken %v", i, err, c.want)
		}
	}
}

// TestToolCallBindsByType: a custom tool's values are bound as text and cast to the catalog's type, never spliced; a
// type or a SQL Server name not of the catalog's shape is refused
func TestToolCallBindsByType(t *testing.T) {
	v := func(s string) *string { return &s }
	stmt, args, _, err := toolCall("postgres", customTool{Name: "cr_echo", Params: []customArgs{{Name: "n", Type: "integer"}, {Name: "m", Type: "text"}}},
		map[string]*string{"n": v("5; DROP TABLE x")})
	if err != nil || stmt != `SELECT * FROM "pgvigil_tools"."cr_echo"("n" => (@a1::text)::integer)` || args["a1"] != "5; DROP TABLE x" {
		t.Errorf("named: %q %v %v", stmt, args, err)
	}
	stmt, _, _, err = toolCall("postgres", customTool{Name: "f", Params: []customArgs{{Type: "integer"}, {Type: "text"}}}, map[string]*string{"$2": v("x")})
	if err != nil || stmt != `SELECT * FROM "pgvigil_tools"."f"(NULL::integer, (@a2::text)::text)` {
		t.Errorf("positional: %q %v", stmt, err)
	}
	for _, typ := range []string{"integer); DROP TABLE x; --", "int -- x", "text;"} {
		if _, _, _, err := toolCall("postgres", customTool{Name: "f", Params: []customArgs{{Name: "a", Type: typ}}}, nil); err == nil {
			t.Errorf("type %q taken", typ)
		}
	}
	stmt, _, ms, err := toolCall("sqlserver", customTool{Name: "x]y", Params: []customArgs{{Name: "@n", Type: "int"}}}, map[string]*string{"n": v("5")})
	if err != nil || stmt != "EXEC [pgvigil_tools].[x]]y] @n = @a1" || len(ms) != 1 {
		t.Errorf("sql server: %q %v %v", stmt, ms, err)
	}
	if _, _, _, err := toolCall("sqlserver", customTool{Name: "x", Params: []customArgs{{Name: "@n; DROP", Type: "int"}}}, nil); err == nil || !strings.Contains(err.Error(), "binds") {
		t.Errorf("a SQL Server name with a space taken: %v", err)
	}
}
