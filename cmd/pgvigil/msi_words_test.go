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
// MajorUpgrade that refuses a downgrade, puts the program under ProgramFiles and the data under ProgramData, and makes
// the service by running 'pgvigil install' as a deferred custom action (install.go stays the one owner of the service,
// its ACLs and the config) - never WiX's own ServiceInstall tables.
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
		`CommonAppDataFolder`,
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

// TestMSIWorkflowWordsL189 (L189, Q4 a): the CI job builds the MSI on windows-latest from the tree's own
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
	// Q3 (a): no operator group - a named difference from PerformanceMonitor, for a principle: pgvigil's access is one
	// model (roles in its own store); a Windows group would be a second door beside it
	if !strings.Contains(docs, "operator group") {
		t.Errorf("docs/msi.md does not name the operator-group difference (Q3 a)")
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

// TestInstallScriptNativeCallsWrapped (L189, the lead's 15:28 - sqltoolsbuild-s2's finding): install.ps1 runs under
// $ErrorActionPreference = 'Stop', and Windows PowerShell 5.1 turns a native program's stderr into an error record
// wherever it is redirected (ISE, a remoting session, '2>&1 | Tee-Object'): a SUCCESSFUL 'pgvigil install' then throws on
// its first slog INFO line. Every call of the downloaded pgvigil.exe goes through the script's Invoke-Native (stderr read
// under 'Continue', judged by the exit code) - none is a bare '& <exe> install'.
func TestInstallScriptNativeCallsWrapped(t *testing.T) {
	ps := readRepoFile(t, "docs/install.ps1")
	bare := regexp.MustCompile(`(?m)^\s*&\s*(\$exe|\(Join-Path \$work \$asset\))\s+(@up|install)\b`)
	for _, m := range bare.FindAllString(ps, -1) {
		t.Errorf("install.ps1 runs pgvigil.exe bare under 'Stop' (5.1 throws on its stderr in ISE): %q - call it through Invoke-Native", strings.TrimSpace(m))
	}
	wrapped := regexp.MustCompile(`Invoke-Native\s*\{\s*&\s*(\$exe|\(Join-Path \$work \$asset\))\s+(@up|install)\b`)
	if n := len(wrapped.FindAllString(ps, -1)); n != 3 {
		t.Errorf("install.ps1 has %d install calls through Invoke-Native, want 3 (the offline upgrade and install, the online install)", n)
	}
	if dep := readRepoFile(t, "deploy/install.ps1"); dep != ps {
		t.Errorf("deploy/install.ps1 differs from docs/install.ps1 (scripts/proof-install.sh L40 compares them)")
	}
}
