package web

import (
	"os"
	"strings"
	"testing"
)

// sp_DBPermissions' pin (P25 row 75; the lead's 10:4x GO (a)): sqlstudent144/SQL-Server-Scripts at this commit, its
// file's sha256 as read 2026-11-17 (= DBA Dash 4.24.1's manifest pin)
const (
	wantDBPermsCommit = "970f29200339d3c05364016f202d813617675737"
	wantDBPermsSHA256 = "d57e18ab7d8e43d82444e2954beca9a6b9b80e79e9dd3ba65d7754d5c04fd7c7"
)

// TestCommunityDBPermissions (P25 row 75: DBA Dash's database sp_DBPermissions tab): the catalogue lists
// sp_DBPermissions in its own group with its source; its version is read from its header line against the tested V7.0;
// the install script (no dbatools installer exists for it) fetches the pinned commit's file, stops unless its SHA256 is
// the pin, then installs it into master - pgvigil runs none of it; THIRD-PARTY-NOTICES names it.
func TestCommunityDBPermissions(t *testing.T) {
	var tool *communityTool
	for i := range communityTools {
		if communityTools[i].ID == "sp_DBPermissions" {
			tool = &communityTools[i]
		}
	}
	if tool == nil {
		t.Fatal("the catalogue has no sp_DBPermissions")
	}
	if tool.Group != "SQLStudies" || tool.Engine != "sqlserver" || tool.Kind != "proc" || !strings.Contains(tool.URL, "sqlstudent144/SQL-Server-Scripts") {
		t.Errorf("sp_DBPermissions' entry %+v, want group SQLStudies, a SQL Server proc, its source sqlstudent144/SQL-Server-Scripts", *tool)
	}
	if got := testedOf("sp_DBPermissions"); got != "7.0" {
		t.Errorf("the tested version %q, want 7.0", got)
	}
	if v := parseVersion("-- sp_DBPermissions V7.0\n-- Kenneth Fisher"); v.Version != "7.0" {
		t.Errorf("the version read from its header %q, want 7.0", v.Version)
	}
	no := false
	script, _ := installScript("db1", "srv1", "master", []toolState{{communityTool: *tool, Installed: &no, VersionWord: "not installed"}})
	for _, w := range []string{"https://raw.githubusercontent.com/sqlstudent144/SQL-Server-Scripts/" + wantDBPermsCommit + "/sp_DBPermissions.sql",
		"Get-FileHash", wantDBPermsSHA256, "Invoke-DbaQuery", "sp_DBPermissions V7.0"} {
		if !strings.Contains(script, w) {
			t.Errorf("the install script has no %s:\n%s", w, script)
		}
	}
	b, err := os.ReadFile("../../THIRD-PARTY-NOTICES.md")
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{"sp_DBPermissions", "Copyright (c) 2019 sqlstudent144", wantDBPermsCommit} {
		if !strings.Contains(string(b), w) {
			t.Errorf("THIRD-PARTY-NOTICES.md has no %s", w)
		}
	}
}

// TestDBPermissionsTabIsWired (P25 row 75): the database page's last tab is sp_DBPermissions (after Service Broker,
// DBA Dash's order), run through the door with @DBName = the database, its words for a procedure not installed, for
// Azure SQL Database and for the door off.
func TestDBPermissionsTabIsWired(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_db.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, w := range []string{"['servicebroker', 'Service Broker'], ['dbpermissions', 'sp_DBPermissions']", "case 'dbpermissions':",
		"'community/run'", "tool: 'sp_DBPermissions'", "DBName: db", "is not installed", "Azure SQL Database"} {
		if !strings.Contains(src, w) {
			t.Errorf("mssql_db.ts has no %s", w)
		}
	}
}
