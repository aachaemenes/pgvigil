package mssql

import (
	"context"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
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

// TestOnDemandDecision: the on-demand routes' database refusals (F7, F14): a secondary for the fragmentation read only,
// a system database, one not online, one the login cannot enter; the cloud services' own databases before any read
func TestOnDemandDecision(t *testing.T) {
	ok := collect.Row{"quoted_name": "[d]", "database_state": "ONLINE", "can_enter": int64(1), "not_user": int64(0), "secondary": int64(0)}
	with := func(k string, v any) collect.Row {
		r := collect.Row{}
		for a, b := range ok {
			r[a] = b
		}
		r[k] = v
		return r
	}
	for _, c := range []struct {
		row       collect.Row
		secondary bool
		want      string
	}{
		{ok, true, ""},
		{with("secondary", int64(1)), true, "secondary replica"},
		{with("secondary", int64(1)), false, ""},
		{with("not_user", int64(1)), false, "system database"},
		{with("database_state", "OFFLINE"), false, "offline"},
		{with("can_enter", int64(0)), false, "cannot enter"},
	} {
		q, err := onDemandDecision(c.row, "d", c.secondary)
		switch {
		case c.want == "" && (err != nil || q != "[d]"):
			t.Errorf("%v: %q %v; want [d]", c.row, q, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%v: %v; want %q", c.row, err, c.want)
		}
	}
	for _, name := range []string{"rdsadmin", "GCLOUD_CLOUDSQLADMIN"} {
		if _, err := OnDemandDatabase(context.Background(), nil, name, false); err == nil || !strings.Contains(err.Error(), "cloud service's own database") {
			t.Errorf("%s: %v", name, err)
		}
	}
}
