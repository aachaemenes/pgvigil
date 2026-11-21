package main

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// A Windows Installer view's Execute returns nothing, and PowerShell writes that nothing ($null) to the output of the
// function that calls it unless it is discarded: msi.yml's Read-Column then hands back a $null ahead of its rows, an
// absent Binary table reads as present, and the step asks Windows Installer for a view on a table the package does
// not have ('OpenView,Sql'). Every Execute call of the MSI workflow and of its Windows proof is discarded with [void].
func TestMSIExecuteCallsDiscardTheirResult(t *testing.T) {
	for _, rel := range []string{".github/workflows/msi.yml", "scripts/proof-msi-win.ps1"} {
		n := 0
		for i, line := range strings.Split(readRepoFile(t, rel), "\n") {
			if !strings.Contains(line, "InvokeMember('Execute'") {
				continue
			}
			n++
			if !strings.HasPrefix(strings.TrimSpace(line), "[void]") {
				t.Errorf("%s:%d: the Execute call's result is not discarded with [void]: %s", rel, i+1, strings.TrimSpace(line))
			}
		}
		if n == 0 {
			t.Errorf("%s: no InvokeMember('Execute' line (the row reads nothing)", rel)
		}
	}
}

// msi.yml's step 'the package holds no custom-action DLL' run from its own text by PowerShell 7, as the workflow runs
// it, with a stand-in for the Windows Installer object (testdata/msi-step6-standin.ps1): the package as built has no
// Binary table and passes; an empty Binary table passes; a Binary table with a row fails the step in its words.
func TestMSIBinaryStepRunsAsWritten(t *testing.T) {
	pwsh, err := exec.LookPath("pwsh")
	if err != nil {
		t.Skip("pwsh is not on PATH")
	}
	wf, err := filepath.Abs(filepath.Join("..", "..", ".github", "workflows", "msi.yml"))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, want string
		code       int
	}{
		{"absent", "Binary table: absent", 0},
		{"empty", "Binary table: empty", 0},
		{"dll", "holds CustomActionDll: no custom-action DLL may ship", 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			out, err := exec.Command(pwsh, "-NoProfile", "-NonInteractive", "-File", filepath.Join("testdata", "msi-step6-standin.ps1"), "-Workflow", wf, "-Case", c.name).CombinedOutput()
			code := 0
			if ee, ok := err.(*exec.ExitError); ok {
				code = ee.ExitCode()
			} else if err != nil {
				t.Fatalf("pwsh: %v", err)
			}
			if code != c.code || !strings.Contains(string(out), c.want) {
				t.Errorf("case %s: exit %d, want %d and the words %q; output:\n%s", c.name, code, c.code, c.want, out)
			}
		})
	}
}
