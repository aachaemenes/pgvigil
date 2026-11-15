package web

import (
	"strings"
	"testing"
)

func TestParseVersion(t *testing.T) {
	cases := []struct {
		windows []string
		want    toolVersion
	}{
		{[]string{"@Version = '8.34', @VersionDate = '20260702';", "@VersionDate = '20260702';", ""}, toolVersion{"8.34", "2026-07-02"}},
		{[]string{"@version = '3.11',\n    @version_date = '20261101';", "@version_date = '20261101';", ""}, toolVersion{"3.11", "2026-11-01"}},
		{[]string{"", "", "Who Is Active? v2200.20260409 (2026-04-09)"}, toolVersion{"2200.20260409", "2026-04-09"}},
		{[]string{"", "", "Who Is Active? v12.00 (2021-11-10)"}, toolVersion{"12.00", "2021-11-10"}},
		{[]string{"", "", "Who Is Active? v11.32"}, toolVersion{"11.32", ""}},
		{[]string{"", "", ""}, toolVersion{}},
	}
	for _, c := range cases {
		if got := parseVersion(c.windows...); got != c.want {
			t.Errorf("parseVersion(%q) = %+v, want %+v", c.windows, got, c.want)
		}
	}
}

func TestCompareAndWord(t *testing.T) {
	if compareVersions("8.4", "8.34") != -1 || compareVersions("8.34", "8.34") != 0 || compareVersions("8.40", "8.34") != 1 || compareVersions("2200.20260409", "2200.20250101") != 1 {
		t.Fatal("compareVersions")
	}
	// each procedure against its own version in the tested release (Darling Data's differ within one release)
	for _, c := range []struct {
		installed bool
		v, name   string
		want      string
	}{
		{false, "", "sp_Blitz", "not installed"},
		{true, "", "sp_Blitz", "version not read"},
		{true, "8.34", "sp_Blitz", "the tested version"},
		{true, "8.30", "sp_BlitzCache", "older than tested"},
		{true, "8.40", "sp_Blitz", "newer than tested (not tested by pgvigil)"},
		{true, "6.11", "sp_PressureDetector", "the tested version"},
		{true, "5.11", "sp_HumanEventsBlockViewer", "the tested version"},
		{true, "3.11", "sp_HealthParser", "the tested version"},
		{true, "2.11", "sp_IndexCleanup", "the tested version"},
		{true, "3.11", "sp_PressureDetector", "older than tested"},
		{true, "1.0", "sp_NotInTheCatalogue", "version not read"},
		{true, "12.00", "sp_WhoIsActive", "older than tested"},
	} {
		if got := versionWord(c.installed, toolVersion{Version: c.v}, c.name); got != c.want {
			t.Errorf("versionWord(%v, %q, %q) = %q, want %q", c.installed, c.v, c.name, got, c.want)
		}
	}
}

func TestMsServerOf(t *testing.T) {
	for in, want := range map[string]string{
		"sqlserver://reader:secret@10.0.0.5:14331?database=master":        "10.0.0.5,14331",
		"sqlserver://reader:secret@sql01/inst2?database=master":           `sql01\inst2`,
		"sqlserver://reader:secret@sql01:14331/inst2?database=master":     "sql01,14331",
		"server=tcp:sql02,1433;user id=reader;password=secret;app name=x": "sql02,1433",
		"nonsense": "",
	} {
		if got := msServerOf(in); got != want || strings.Contains(got, "secret") {
			t.Errorf("msServerOf(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestInstallScript(t *testing.T) {
	yes, no := true, false
	v834, v830, v611, v311 := "8.34", "8.30", "6.11", "3.11"
	tools := []toolState{
		{communityTool: communityTool{Name: "sp_Blitz", Group: "First Responder Kit", Kind: "proc"}, Installed: &yes, Version: &v834, VersionDate: "2026-07-02", VersionWord: "the tested version"},
		{communityTool: communityTool{Name: "sp_BlitzCache", Group: "First Responder Kit", Kind: "proc"}, Installed: &yes, Version: &v830, VersionDate: "2025-01-01", VersionWord: "older than tested"},
		// one Darling Data release, two versions: not mixed
		{communityTool: communityTool{Name: "sp_PressureDetector", Group: "Darling Data", Kind: "proc"}, Installed: &yes, Version: &v611, VersionDate: "2026-11-01", VersionWord: "the tested version"},
		{communityTool: communityTool{Name: "sp_HealthParser", Group: "Darling Data", Kind: "proc"}, Installed: &yes, Version: &v311, VersionDate: "2026-11-01", VersionWord: "the tested version"},
		{communityTool: communityTool{Name: "sp_WhoIsActive", Group: "sp_WhoIsActive", Kind: "proc"}, Installed: &no, VersionWord: "not installed"},
	}
	s, notes := installScript("prod-1", "sql01,1433", "dba", tools)
	for _, want := range []string{"$SqlInstance = 'sql01,1433'", "Install-DbaFirstResponderKit -SqlInstance $SqlInstance -Database 'dba'", "Install-DbaWhoIsActive -SqlInstance $SqlInstance -Database 'dba'", "-LocalFile", "8.34", "release of 2026-11-01", "2200.20260409", "runs none of it"} {
		if !strings.Contains(s, want) {
			t.Errorf("the script lacks %q:\n%s", want, s)
		}
	}
	if strings.Contains(s, "Install-DbaDarlingData") {
		t.Errorf("Darling Data is at the tested version, the script installs it:\n%s", s)
	}
	if len(notes) != 1 || !strings.Contains(notes[0], "First Responder Kit: mixed versions (sp_Blitz 8.34 of 2026-07-02; sp_BlitzCache 8.30 of 2025-01-01)") {
		t.Errorf("notes = %q", notes)
	}
	s, _ = installScript("prod-1", "", "master", tools[:1])
	if !strings.Contains(s, "nothing to install") {
		t.Errorf("nothing missing: %s", s)
	}
}
