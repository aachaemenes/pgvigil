package kits

import (
	"encoding/json"
	"os"
	"regexp"
	"slices"
	"testing"
)

// KITWATCH K3 (F2): the stored baseline and the code agree - every column the collector reads from sp_WhoIsActive BY
// NAME (requestsWIA's w.<col> in internal/mssql/requests.go) is in shapes.json's 'sp_WhoIsActive (collector)' entry
// (the run with exactly the collector's parameters), and shapes.json's kit versions are the ones Checked names. The
// dangerous direction is the code reading a column the shape lacks. Skipped until the first baseline is committed.
func TestPinnedShapes(t *testing.T) {
	b, err := os.ReadFile("shapes.json")
	if os.IsNotExist(err) {
		t.Skip("no shapes.json yet: the first -baseline run writes it")
	}
	if err != nil {
		t.Fatal(err)
	}
	var shapes struct {
		Kits []struct {
			Kit         string `json:"kit"`
			Version     string `json:"version"`
			VersionDate string `json:"version_date"`
		} `json:"kits"`
		Runs []Run `json:"runs"`
	}
	if err := json.Unmarshal(b, &shapes); err != nil {
		t.Fatal(err)
	}
	src, err := os.ReadFile("../../mssql/requests.go")
	if err != nil {
		t.Fatal(err)
	}
	var read []string
	for _, m := range regexp.MustCompile(`\bw\.([A-Za-z_]+)`).FindAllStringSubmatch(string(src), -1) {
		if !slices.Contains(read, m[1]) {
			read = append(read, m[1])
		}
	}
	if len(read) < 10 {
		t.Fatalf("only %d w.<col> in requests.go: the pattern no longer matches requestsWIA", len(read))
	}
	var entry *Run
	for i := range shapes.Runs {
		if shapes.Runs[i].Tool == "sp_WhoIsActive (collector)" {
			entry = &shapes.Runs[i]
		}
	}
	if entry == nil {
		t.Fatal("shapes.json holds no 'sp_WhoIsActive (collector)' entry")
	}
	for _, c := range read {
		if !hasColumn(entry.Sets, c) {
			t.Errorf("requestsWIA reads w.%s, which the stored collector shape does not have", c)
		}
	}
	// every preset parameter the community checks pass (internal/web/q_community.go's c.Preset lines) is a parameter of
	// its tool in the stored shape: a kit that renames one turns the preset into a refused click. The table names each
	// line's tool (three of them write c.Preset[tool] through a const); a preset line added or removed fails the count
	// until the table follows it.
	presets := []struct{ tool, param string }{
		{"sp_IndexCleanup", "@database_name"},
		{"sp_HumanEventsBlockViewer", "@session_name"},
		{"sp_HumanEventsBlockViewer", "@session_name"},
		{"sp_HumanEventsBlockViewer", "@session_name"},
		{"sp_QuickieStore", "@database_name"},
	}
	cs, err := os.ReadFile("../../web/q_community.go")
	if err != nil {
		t.Fatal(err)
	}
	lines := regexp.MustCompile(`c\.Preset\[[^\]]+\] = map\[string\]string\{"(@[A-Za-z_]+)"`).FindAllStringSubmatch(string(cs), -1)
	if len(lines) != len(presets) {
		t.Fatalf("q_community.go sets %d presets, the table names %d: the table follows the code", len(lines), len(presets))
	}
	for i, p := range presets {
		if lines[i][1] != p.param {
			t.Errorf("q_community.go's preset line %d passes %s, the table says %s", i+1, lines[i][1], p.param)
		}
		var tool *Run
		for j := range shapes.Runs {
			if shapes.Runs[j].Tool == p.tool {
				tool = &shapes.Runs[j]
			}
		}
		if tool == nil {
			t.Errorf("shapes.json holds no %s entry", p.tool)
			continue
		}
		if !slices.ContainsFunc(tool.AllParams, func(a Param) bool { return a.Name == p.param }) {
			t.Errorf("the community checks preset %s's %s, which the stored shape does not have", p.tool, p.param)
		}
	}
	dates := map[string]string{"frk": "20260702", "dd": "20261101", "wia": "20260409"}
	for _, k := range shapes.Kits {
		if want, ok := dates[k.Kit]; ok && k.VersionDate != want {
			t.Errorf("shapes.json's %s is dated %s; Checked says %s: re-baseline and Checked move together", k.Kit, k.VersionDate, want)
		}
	}
	for tool, kit := range map[string]string{"sp_Blitz": "frk", "sp_PressureDetector": "dd", "sp_WhoIsActive": "wia"} {
		if c, _ := Checked(tool); c.Date != dates[kit] {
			t.Errorf("Checked(%s) is dated %s, want %s", tool, c.Date, dates[kit])
		}
	}
}
