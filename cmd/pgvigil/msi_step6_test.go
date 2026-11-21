package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Type.InvokeMember is declared to return object, so a Windows Installer method that returns nothing, called through
// it, gives $null - and PowerShell writes that $null to the output of the function that calls it unless the statement
// assigns, discards or tests it. In msi.yml's Read-Column the null went out ahead of the rows: an absent Binary table
// read as present, and the step asked for a view on a table the package does not have ('OpenView,Sql'). Every
// InvokeMember statement inside a function of the MSI workflow and of its Windows proof assigns its result, discards it
// with [void] or $null =, or sits in a condition (if / while); a statement that does none of these leaks.
func TestMSIInvokeMemberResultsNeverLeak(t *testing.T) {
	fn := regexp.MustCompile(`^(\s*)function\s+[\w-]+`)
	used := regexp.MustCompile(`\[void\]|\$null\s*=|\$[\w:]+(\[[^\]]*\])?\s*\+?=[^=]|\b(if|elseif|while)\s*\(`)
	for _, rel := range []string{".github/workflows/msi.yml", "scripts/proof-msi-win.ps1"} {
		lines := strings.Split(readRepoFile(t, rel), "\n")
		inside, indent, n := false, "", 0
		for i, line := range lines {
			oneLine := false
			if m := fn.FindStringSubmatch(line); m != nil && !inside {
				if strings.Count(line, "{") > strings.Count(line, "}") {
					inside, indent = true, m[1] // its body runs to the '}' at the function's own indentation
					continue
				}
				oneLine = true // 'function F { ... }' on one line: the line is the function
			}
			if inside && strings.TrimRight(line, " \r") == indent+"}" {
				inside = false
				continue
			}
			if !(inside || oneLine) || !strings.Contains(line, ".InvokeMember(") {
				continue
			}
			// each statement of the line that calls InvokeMember, split at ';'
			for _, st := range strings.Split(line, ";") {
				at := strings.Index(st, ".InvokeMember(")
				if at < 0 {
					continue
				}
				n++
				if !used.MatchString(st[:at]) {
					t.Errorf("%s:%d: an InvokeMember result inside a function is neither assigned, discarded nor tested (it leaks into the function's output): %s", rel, i+1, strings.TrimSpace(st))
				}
			}
		}
		if n == 0 {
			t.Errorf("%s: no InvokeMember statement inside a function (the row reads nothing)", rel)
		}
	}
}

// standin runs testdata/msi-step6-standin.ps1 on one reader's own text with a stand-in for the Windows Installer
// object. Under GitHub Actions a missing pwsh fails the row (it is the one place it always runs); elsewhere it skips.
func standin(t *testing.T, source, file, c string) (string, int) {
	t.Helper()
	pwsh, err := exec.LookPath("pwsh")
	if err != nil {
		if os.Getenv("GITHUB_ACTIONS") == "true" {
			t.Fatal("pwsh is not on PATH on a GitHub runner: this row cannot run")
		}
		t.Skip("pwsh is not on PATH")
	}
	out, err := exec.Command(pwsh, "-NoProfile", "-NonInteractive", "-File", filepath.Join("testdata", "msi-step6-standin.ps1"), "-Source", source, "-File", file, "-Case", c).CombinedOutput()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("pwsh: %v", err)
	}
	return plain(string(out)), code
}

// plain takes the colour codes and PowerShell's error-view margins out and joins the lines, so the words of a wrapped
// error read whole whatever the console's width.
func plain(s string) string {
	s = regexp.MustCompile(`\x1b\[[0-9;]*m`).ReplaceAllString(s, "")
	var parts []string
	for _, l := range strings.Split(s, "\n") {
		l = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(l), "step:"))
		l = strings.TrimSpace(strings.TrimLeft(l, "|"))
		if l != "" {
			parts = append(parts, l)
		}
	}
	return strings.Join(parts, " ")
}

func repoPath(t *testing.T, rel string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// msi.yml's step 'the package holds no custom-action DLL' run from its own text by PowerShell 7, as the workflow runs
// it: the package as built has no Binary table and passes; an empty Binary table passes; a Binary table with a row
// fails the step in its words. A step whose query misspells a column or reads another field fails too (the stand-in
// answers only the two queries Windows Installer would, and field 1).
func TestMSIBinaryStepRunsAsWritten(t *testing.T) {
	wf := repoPath(t, ".github/workflows/msi.yml")
	for _, c := range []struct {
		name, want string
		code       int
	}{
		{"absent", "Binary table: absent", 0},
		{"empty", "Binary table: empty", 0},
		{"dll", "the MSI's Binary table holds CustomActionDll: no custom-action DLL may ship (M1)", 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			out, code := standin(t, "step6", wf, c.name)
			if code != c.code || !strings.Contains(out, c.want) {
				t.Errorf("case %s: exit %d, want %d and the words %q; output: %s", c.name, code, c.code, c.want, out)
			}
		})
	}
	text := readRepoFile(t, ".github/workflows/msi.yml")
	for _, m := range []struct{ name, from, to string }{
		{"a misspelled column", "SELECT ``Name`` FROM ``_Tables`` WHERE ``Name`` = 'Binary'", "SELECT ``Nmae`` FROM ``_Tables`` WHERE ``Name`` = 'Binary'"},
		{"another field", "InvokeMember('StringData', 'GetProperty', $null, $rec, 1)", "InvokeMember('StringData', 'GetProperty', $null, $rec, 2)"},
	} {
		t.Run("mutant: "+m.name, func(t *testing.T) {
			if !strings.Contains(text, m.from) {
				t.Fatalf("msi.yml no longer holds %q: the mutant would test nothing", m.from)
			}
			f := filepath.Join(t.TempDir(), "msi.yml")
			if err := os.WriteFile(f, []byte(strings.Replace(text, m.from, m.to, 1)), 0o600); err != nil {
				t.Fatal(err)
			}
			// the empty case: its _Tables read returns a row, so the step reads a field (absent reads none)
			if out, code := standin(t, "step6", f, "empty"); code == 0 {
				t.Errorf("a step with %s passed the stand-in (exit 0): %s", m.name, out)
			}
		})
	}
}

// The M1 child of scripts/proof-msi-win.ps1 run from its own text with the stand-in: 'BINARY absent' for the package
// as built, 'BINARY empty' for an empty Binary table (M1's own EXPECTED: it passes), 'BINARY holds CustomActionDll'
// for a table with a row - never a null of a leaked call among the names.
func TestMSIProofM1ChildRunsAsWritten(t *testing.T) {
	proof := repoPath(t, "scripts/proof-msi-win.ps1")
	for _, c := range []struct{ name, want string }{
		{"absent", "BINARY absent"},
		{"empty", "BINARY empty"},
		{"dll", "BINARY holds CustomActionDll READER"},
	} {
		t.Run(c.name, func(t *testing.T) {
			out, code := standin(t, "m1", proof, c.name)
			if code != 0 || !strings.Contains(out, c.want) {
				t.Errorf("case %s: exit %d, want 0 and the words %q; output: %s", c.name, code, c.want, out)
			}
		})
	}
}
