package mssql

import (
	"strings"
	"testing"
)

func TestParseVersion(t *testing.T) {
	for _, c := range []struct {
		in                  string
		major, minor, build int
	}{
		{"16.0.4135.4", 16, 0, 4135},
		{"15.0.2000.5", 15, 0, 2000},
		{"12.0.2000.8", 12, 0, 2000},
		{"10.50.6000.34", 10, 50, 6000},
		{"", 0, 0, 0},
		{"abc", 0, 0, 0},
		{"17", 17, 0, 0},
		{" 16.0.x ", 16, 0, 0},
	} {
		a, b, d := parseVersion(c.in)
		if a != c.major || b != c.minor || d != c.build {
			t.Errorf("parseVersion(%q) = %d, %d, %d; want %d, %d, %d", c.in, a, b, d, c.major, c.minor, c.build)
		}
	}
}

func TestKindOf(t *testing.T) {
	for _, c := range []struct {
		ee     int
		rds    bool
		forced string
		want   Kind
	}{
		{3, false, "", KindServer},
		{3, false, "auto", KindServer},
		{2, true, "auto", KindRDS},
		{5, false, "auto", KindAzureDB},
		{8, false, "", KindAzureMI},
		{5, true, "", KindAzureDB},
		{3, true, "onprem", KindServer},
		{3, false, "rds", KindRDS},
		{3, false, "azuresqlmi", KindAzureMI},
		{3, false, "azuresqldb", KindAzureDB},
	} {
		if got := kindOf(c.ee, c.rds, c.forced); got != c.want {
			t.Errorf("kindOf(%d, %v, %q) = %s; want %s", c.ee, c.rds, c.forced, got, c.want)
		}
	}
}

func TestWithAppName(t *testing.T) {
	for in, want := range map[string]string{
		"sqlserver://u@h:1433?database=master":            "sqlserver://u@h:1433?database=master&app+name=pgvigil",
		"sqlserver://u@h:1433":                            "sqlserver://u@h:1433?app+name=pgvigil",
		"server=h;user id=u;database=master;":             "server=h;user id=u;database=master;app name=pgvigil",
		"server=h;user id=u;app name=mine":                "server=h;user id=u;app name=mine",
		"sqlserver://u@h?database=master&app+name=theirs": "sqlserver://u@h?database=master&app+name=theirs",
		"odbc:server=h;user id=u":                         "odbc:server=h;user id=u",
	} {
		if got := withAppName(in); got != want {
			t.Errorf("withAppName(%q) = %q; want %q", in, got, want)
		}
	}
}

func TestEveryCollectionIsPrefixed(t *testing.T) {
	if len(Names()) == 0 {
		t.Fatal("no SQL Server collection is registered")
	}
	for _, n := range Names() {
		if !strings.HasPrefix(n, Prefix) {
			t.Errorf("collection %q does not start with %q", n, Prefix)
		}
	}
}

// the settings every collector session starts with; proof-mssql-base.sh's part F names this test
func TestSessionSetup(t *testing.T) {
	for _, want := range []string{"SET LOCK_TIMEOUT 2000", "SET DEADLOCK_PRIORITY LOW", "SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED"} {
		if !strings.Contains(sessionSetup, want) {
			t.Errorf("the session setup lacks %q", want)
		}
	}
}
