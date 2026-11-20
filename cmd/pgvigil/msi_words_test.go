package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func readRepoFile(t *testing.T, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", filepath.FromSlash(rel)))
	if err != nil {
		t.Fatalf("%s: %v", rel, err)
	}
	return string(b)
}

// TestMSIPackageWordsL189 (L189, M1/M2): the WiX package exists at packaging/msi/, pinned to WixToolset.Sdk 5.0.2
// (MS-RL, no fee; v6 starts the maintenance fee - not taken), is perMachine with a fixed UpgradeCode and a
// MajorUpgrade that refuses a downgrade, puts the program under ProgramFiles (the folder under ProgramData is made by
// 'pgvigil install' alone: the wxs names none there since rn-l189 N3), and makes the service by running 'pgvigil install' as a
// deferred custom action (install.go stays the one owner of the service, its ACLs and the config) - never WiX's own
// ServiceInstall tables.
func TestMSIPackageWordsL189(t *testing.T) {
	proj := readRepoFile(t, "packaging/msi/pgvigil.wixproj")
	for _, want := range []string{`Sdk="WixToolset.Sdk/5.0.2"`} {
		if !strings.Contains(proj, want) {
			t.Errorf("pgvigil.wixproj lacks %q (the pinned build tool)", want)
		}
	}
	wxs := readRepoFile(t, "packaging/msi/pgvigil.wxs")
	for _, want := range []string{
		`Scope="perMachine"`,
		`UpgradeCode="`,
		`<MajorUpgrade`,
		`DowngradeErrorMessage=`,
		`ProgramFiles64Folder`,
		`pgvigil.exe`,
		`install`,
		`Execute="deferred"`,
	} {
		if !strings.Contains(wxs, want) {
			t.Errorf("pgvigil.wxs lacks %q", want)
		}
	}
	for _, never := range []string{"<ServiceInstall", "<ServiceControl"} {
		if strings.Contains(wxs, never) {
			t.Errorf("pgvigil.wxs holds %q: the service is made by 'pgvigil install' (M2 a), never by the MSI's own tables", never)
		}
	}
}

// TestMSIWorkflowWordsL189: the CI job builds the MSI on windows-latest from the tree's own
// windows/amd64 binary, validates it (ICE inside the WiX build; the Binary table checked empty of custom-action DLLs),
// and proves a silent install, an upgrade over the previous MSI, a refused downgrade and an uninstall; unsigned until
// the code-signing certificate's secret exists, said in the docs with SmartScreen's warning.
func TestMSIWorkflowWordsL189(t *testing.T) {
	wf := readRepoFile(t, ".github/workflows/msi.yml")
	for _, want := range []string{
		"windows-latest",
		"GOOS=windows",
		"/qn",
		"uninstall",
		"downgrade",
	} {
		if !strings.Contains(wf, want) {
			t.Errorf("msi.yml lacks %q", want)
		}
	}
	docs := readRepoFile(t, "docs/msi.md")
	for _, want := range []string{"SmartScreen", "unsigned", "msiexec"} {
		if !strings.Contains(docs, want) {
			t.Errorf("docs/msi.md lacks %q", want)
		}
	}
	// no operator group - a named difference from PerformanceMonitor, for a principle: pgvigil's access is one
	// model (roles in its own store); a Windows group would be a second door beside it
	if !strings.Contains(docs, "operator group") {
		t.Errorf("docs/msi.md does not name the operator-group difference")
	}
}

// TestInstallScriptRefusesAnMSIMachineL189 (L189, M3; PerformanceMonitor #6480's rule): docs/install.ps1 refuses a
// machine whose installed pgvigil came from the MSI (the UpgradeCode present) and names msiexec as the way; docs lead
// with the MSI on Windows.
func TestInstallScriptRefusesAnMSIMachineL189(t *testing.T) {
	ps := readRepoFile(t, "docs/install.ps1")
	if !strings.Contains(ps, "UpgradeCode") && !strings.Contains(ps, "Win32_Product") && !strings.Contains(ps, "msi") {
		t.Errorf("docs/install.ps1 has no MSI-machine refusal")
	}
	for _, want := range []string{"msiexec"} {
		if !strings.Contains(ps, want) {
			t.Errorf("docs/install.ps1 lacks %q (the named way on an MSI machine)", want)
		}
	}
}

// TestInstallScriptNativeCallsWrapped: install.ps1 runs under
// $ErrorActionPreference = 'Stop', and Windows PowerShell 5.1 turns a native program's stderr into an error record
// wherever it is redirected (ISE, a remoting session, '2>&1 | Tee-Object'): a SUCCESSFUL 'pgvigil install' then throws on
// its first slog INFO line. Every call of the downloaded pgvigil.exe goes through the script's Invoke-Native (stderr read
// under 'Continue', judged by the exit code) - none is a bare '& <exe> install'. Since RELNOTES L131 the offline and the
// online install call Invoke-PgvigilInstall, whose three calls (no account; a gMSA or NT SERVICE account;
// -password-stdin) take the exe as $exePath.
func TestInstallScriptNativeCallsWrapped(t *testing.T) {
	ps := readRepoFile(t, "docs/install.ps1")
	exe := `(\$exe|\$exePath|\(Join-Path \$work \$asset\))\s+(@up|install)\b`
	all := regexp.MustCompile(`&\s*`+exe).FindAllString(ps, -1)
	wrapped := regexp.MustCompile(`Invoke-Native\s*\{\s*(\$plain\s*\|\s*)?&\s*`+exe).FindAllString(ps, -1)
	if len(all) != len(wrapped) {
		t.Errorf("install.ps1 runs pgvigil.exe %d time(s), %d of them through Invoke-Native: a bare call throws on its stderr under 'Stop' in 5.1's ISE - call it through Invoke-Native", len(all), len(wrapped))
	}
	if len(wrapped) != 4 {
		t.Errorf("install.ps1 has %d install calls through Invoke-Native, want 4 (the offline upgrade; Invoke-PgvigilInstall's three)", len(wrapped))
	}
	if n := len(regexp.MustCompile(`Invoke-PgvigilInstall\s+(\$exe|\(Join-Path \$work \$asset\))\s`).FindAllString(ps, -1)); n != 2 {
		t.Errorf("install.ps1 calls Invoke-PgvigilInstall %d time(s), want 2 (the offline and the online install)", n)
	}
	if dep := readRepoFile(t, "deploy/install.ps1"); dep != ps {
		t.Errorf("deploy/install.ps1 differs from docs/install.ps1 (scripts/proof-install.sh L40 compares them)")
	}
}

// packedGUID is Windows Installer's packed form of a GUID (Installer\UpgradeCodes' key): each of the first three groups
// reversed, then every pair of the rest swapped.
func packedGUID(g string) string {
	hex := strings.ToUpper(strings.ReplaceAll(g, "-", ""))
	rev := func(s string) string {
		b := []byte(s)
		for i, j := 0, len(b)-1; i < j; i, j = i+1, j-1 {
			b[i], b[j] = b[j], b[i]
		}
		return string(b)
	}
	out := rev(hex[0:8]) + rev(hex[8:12]) + rev(hex[12:16])
	for i := 16; i < 32; i += 2 {
		out += rev(hex[i : i+2])
	}
	return out
}

// TestMSIUpgradeCodeTiedL189 (rn-l189, the words test's gap): the wxs's UpgradeCode is the one both install.ps1 copies
// refuse by, and its packed form (computed here) is the one their comment names - a GUID changed on either side
// fails here, never silently ends the refusal.
func TestMSIUpgradeCodeTiedL189(t *testing.T) {
	wxs := readRepoFile(t, "packaging/msi/pgvigil.wxs")
	m := regexp.MustCompile(`UpgradeCode="([0-9A-Fa-f-]{36})"`).FindStringSubmatch(wxs)
	if m == nil {
		t.Fatal("pgvigil.wxs has no UpgradeCode GUID")
	}
	packed := packedGUID(m[1])
	for _, f := range []string{"docs/install.ps1", "deploy/install.ps1"} {
		ps := readRepoFile(t, f)
		if !strings.Contains(ps, "'"+m[1]+"'") {
			t.Errorf("%s does not refuse by the wxs's UpgradeCode %s", f, m[1])
		}
		if !strings.Contains(ps, packed) {
			t.Errorf("%s does not name the packed form %s of %s", f, packed, m[1])
		}
	}
}

// TestMSIActionsL189: the package's actions as they are built - every one
// deferred and not impersonated; the install without its start (-no-start, -bin the MSI's own file) and checked; the
// start, the stop and the uninstall ignored; net.exe by its full path; each action's condition (the stop on an
// upgrade's removal alone, the uninstall on a removal that is no upgrade, the install and the start on no removal);
// the old version removed after InstallInitialize (a failed upgrade rolls back whole), a same-version rebuild an
// upgrade; the PATH entry; the launch condition refusing another installer's service.
func TestMSIActionsL189(t *testing.T) {
	wxs := readRepoFile(t, "packaging/msi/pgvigil.wxs")
	actions := regexp.MustCompile(`(?s)<CustomAction\s[^>]*/>`).FindAllString(wxs, -1)
	if len(actions) != 4 {
		t.Fatalf("pgvigil.wxs has %d custom actions, want 4 (install, start, uninstall, stop)", len(actions))
	}
	want := map[string][]string{
		"PgvInstall":   {`ExeCommand="install -no-start -bin &quot;[#PgvigilExeFile]&quot;"`, `Return="check"`},
		"PgvStart":     {`[System64Folder]net.exe&quot; start pgvigil"`, `Return="ignore"`},
		"PgvUninstall": {`ExeCommand="uninstall"`, `Return="ignore"`},
		"PgvStop":      {`[System64Folder]net.exe&quot; stop pgvigil"`, `Return="ignore"`},
	}
	for _, a := range actions {
		id := regexp.MustCompile(`Id="(\w+)"`).FindStringSubmatch(a)
		if id == nil || want[id[1]] == nil {
			t.Errorf("an unexpected custom action: %s", a)
			continue
		}
		for _, w := range append(want[id[1]], `Execute="deferred"`, `Impersonate="no"`) {
			if !strings.Contains(a, w) {
				t.Errorf("%s lacks %s", id[1], w)
			}
		}
	}
	for _, w := range []string{
		`<Custom Action="PgvStop" After="InstallInitialize" Condition="UPGRADINGPRODUCTCODE" />`,
		`<Custom Action="PgvUninstall" After="PgvStop" Condition="(REMOVE=&quot;ALL&quot;) AND NOT UPGRADINGPRODUCTCODE" />`,
		`<Custom Action="PgvInstall" After="InstallFiles" Condition="NOT REMOVE" />`,
		`<Custom Action="PgvStart" After="PgvInstall" Condition="NOT REMOVE" />`,
		`Schedule="afterInstallInitialize"`,
		`AllowSameVersionUpgrades="yes"`,
		`<Environment Id="PgvigilPath" Name="PATH" Value="[INSTALLFOLDER]"`,
		`<Launch Condition="Installed OR WIX_UPGRADE_DETECTED OR WIX_DOWNGRADE_DETECTED OR NOT PGVSERVICEIMAGE"`,
		`Key="SYSTEM\CurrentControlSet\Services\pgvigil" Name="ImagePath"`,
	} {
		if !strings.Contains(wxs, w) {
			t.Errorf("pgvigil.wxs lacks %s", w)
		}
	}
	if strings.Contains(wxs, "DATAFOLDER") {
		t.Error("pgvigil.wxs still names DATAFOLDER: a public property nothing reads (N3)")
	}
}

// TestInstallScriptMSIOrderL189 (rn-l189 N9, S3, the words test's gap): the MSI refusal comes before any download and
// lets a download-only run through; the install and the upgrade stream their output (-Stream) and no caller prints
// it again.
func TestInstallScriptMSIOrderL189(t *testing.T) {
	ps := readRepoFile(t, "docs/install.ps1")
	refuse := strings.Index(ps, "if ((Test-MsiInstall) -and $env:PGVIGIL_NO_SERVICE -ne '1')")
	download := strings.Index(ps, "Invoke-WebRequest")
	if refuse < 0 || download < 0 || refuse > download {
		t.Errorf("the MSI refusal (at %d, download-only let through) must come before the first download (at %d)", refuse, download)
	}
	streamed := regexp.MustCompile(`Invoke-Native\s*\{[^}]*&\s*(\$exe|\$exePath)\s+(@up|install)[^}]*\}\s*-Stream`).FindAllString(ps, -1)
	if len(streamed) != 4 {
		t.Errorf("%d install calls stream their output, want 4 (the offline upgrade; Invoke-PgvigilInstall's three)", len(streamed))
	}
	if regexp.MustCompile(`Write-Host \$\w+\.Out`).MatchString(ps) {
		t.Error("a caller prints an install's output again after -Stream showed it")
	}
}

// TestMSIDocsWordsL189 (rn-l189 S4, S5, S6, N12): docs/msi.md says what is true today - not yet a release asset, the
// removal retires the host, the upgrade's order (migrate, then the MSI, then Start-Service), repo.dsn and the start
// after a fresh install, four actions - and none of the sentences that were false.
func TestMSIDocsWordsL189(t *testing.T) {
	docs := readRepoFile(t, "docs/msi.md")
	for _, w := range []string{"not yet a release asset", "retired as a collector", "repo.dsn", "Start-Service pgvigil", "four actions", "/norestart"} {
		if !strings.Contains(docs, w) {
			t.Errorf("docs/msi.md lacks %q", w)
		}
	}
	for _, never := range []string{"the repository is never\ntouched", "the repository is never touched", "run before the removal", "the two actions", "the first way to install"} {
		if strings.Contains(docs, never) {
			t.Errorf("docs/msi.md still says %q", never)
		}
	}
	if up := readRepoFile(t, "docs/upgrade.md"); !strings.Contains(up, "## A machine installed from the MSI") {
		t.Error("docs/upgrade.md has no MSI way back (S8)")
	}
}
