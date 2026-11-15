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
