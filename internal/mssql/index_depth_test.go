package mssql

import (
	"strings"
	"testing"
)

// TestHistogramBuild: sys.dm_db_stats_histogram from SQL Server 2016 SP1 CU2 (13.0.4422.0) and on Managed Instance; off
// on Azure SQL Database and below CU2 with the words (task 414's FOLD F12: no DBCC fallback).
func TestHistogramBuild(t *testing.T) {
	cases := []struct {
		major, build, edition int
		ok                    bool
		words                 string
	}{
		{13, 4001, 3, false, "13.0.4422.0"},
		{13, 4421, 2, false, "before SP1 CU2"},
		{13, 4422, 3, true, ""},
		{14, 1000, 3, true, ""},
		{16, 4325, 3, true, ""},
		{12, 0, 8, true, ""},
		{12, 0, 5, false, "Azure SQL Database"},
		{11, 7001, 3, false, "before 2016"},
	}
	for _, c := range cases {
		ok, why := HistogramBuild(c.major, c.build, c.edition)
		if ok != c.ok || (c.words != "" && !strings.Contains(why, c.words)) {
			t.Errorf("HistogramBuild(%d, %d, %d) = %v, %q; want %v with %q", c.major, c.build, c.edition, ok, why, c.ok, c.words)
		}
	}
}

// TestNoHistogramIndex: the index types and column types with no histogram to draw (F13)
func TestNoHistogramIndex(t *testing.T) {
	for _, c := range []struct{ it, lt, want string }{
		{"NONCLUSTERED COLUMNSTORE", "int", "columnstore"},
		{"CLUSTERED COLUMNSTORE", "int", "columnstore"},
		{"XML", "xml", "XML index"},
		{"SPATIAL", "geography", "spatial"},
		{"", "geometry", "geometry column"},
		{"NONCLUSTERED", "int", ""},
		{"CLUSTERED", "datetime2", ""},
		{"", "varbinary", ""},
	} {
		if got := noHistogramIndex(c.it, c.lt); (c.want == "") != (got == "") || !strings.Contains(got, c.want) {
			t.Errorf("noHistogramIndex(%q, %q) = %q; want %q", c.it, c.lt, got, c.want)
		}
	}
}

// TestConstraintsCollector: registered as mssql_constraints, every 6 hours, not on Azure SQL Database
func TestConstraintsCollector(t *testing.T) {
	c := constraintsCollector{}
	if c.Name() != "mssql_constraints" || c.DefaultInterval().Hours() != 6 {
		t.Fatalf("name %s interval %s", c.Name(), c.DefaultInterval())
	}
	if ok, why := c.Applies(Info{Kind: KindAzureDB}); ok || !strings.Contains(why, "Azure SQL Database") {
		t.Errorf("Azure SQL Database: %v %q", ok, why)
	}
	if ok, _ := c.Applies(Info{Kind: KindServer}); !ok {
		t.Errorf("on premises: not applied")
	}
	if !strings.Contains(constraintsSQL, "fk.is_not_trusted = 1 AND fk.is_not_for_replication = 0") ||
		!strings.Contains(constraintsSQL, "cc.is_not_trusted = 1 AND cc.is_disabled = 0 AND cc.is_not_for_replication = 0") {
		t.Errorf("the predicates are not dbachecks 3.0.2's")
	}
}
