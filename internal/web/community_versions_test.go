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
	for _, c := range []struct {
		installed bool
		v, group  string
		want      string
	}{
		{false, "", "First Responder Kit", "not installed"},
		{true, "", "First Responder Kit", "version not read"},
		{true, "8.34", "First Responder Kit", "the tested version"},
		{true, "8.30", "First Responder Kit", "older than tested"},
		{true, "8.40", "First Responder Kit", "newer than tested (not tested by pgvigil)"},
		{true, "3.11", "Darling Data", "the tested version"},
	} {
		if got := versionWord(c.installed, toolVersion{Version: c.v}, c.group); got != c.want {
			t.Errorf("versionWord(%v, %q, %q) = %q, want %q", c.installed, c.v, c.group, got, c.want)
		}
	}
}

func TestMsServerOf(t *testing.T) {
	for in, want := range map[string]string{
		"sqlserver://reader:secret@10.0.0.5:14331?database=master":        "10.0.0.5,14331",
		"sqlserver://reader:secret@sql01/inst2?database=master":           `sql01\inst2`,
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
	v834, v830, v311 := "8.34", "8.30", "3.11"
	tools := []toolState{
		{communityTool: communityTool{Name: "sp_Blitz", Group: "First Responder Kit", Kind: "proc"}, Installed: &yes, Version: &v834, VersionWord: "the tested version"},
		{communityTool: communityTool{Name: "sp_BlitzCache", Group: "First Responder Kit", Kind: "proc"}, Installed: &yes, Version: &v830, VersionWord: "older than tested"},
		{communityTool: communityTool{Name: "sp_PressureDetector", Group: "Darling Data", Kind: "proc"}, Installed: &yes, Version: &v311, VersionWord: "the tested version"},
		{communityTool: communityTool{Name: "sp_WhoIsActive", Group: "sp_WhoIsActive", Kind: "proc"}, Installed: &no, VersionWord: "not installed"},
	}
	s, notes := installScript("prod-1", "sql01,1433", "dba", tools)
	for _, want := range []string{"$SqlInstance = 'sql01,1433'", "Install-DbaFirstResponderKit -SqlInstance $SqlInstance -Database 'dba'", "Install-DbaWhoIsActive -SqlInstance $SqlInstance -Database 'dba'", "-LocalFile", "8.34", "3.11", "runs none of it"} {
		if !strings.Contains(s, want) {
			t.Errorf("the script lacks %q:\n%s", want, s)
		}
	}
	if strings.Contains(s, "Install-DbaDarlingData") {
		t.Errorf("Darling Data is at the tested version, the script installs it:\n%s", s)
	}
	if len(notes) != 1 || !strings.Contains(notes[0], "First Responder Kit: mixed versions") {
		t.Errorf("notes = %q", notes)
	}
	s, _ = installScript("prod-1", "", "master", tools[:1])
	if !strings.Contains(s, "nothing to install") {
		t.Errorf("nothing missing: %s", s)
	}
}
