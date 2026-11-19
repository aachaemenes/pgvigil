package main

import (
	"io"
	"os"
	"strings"
	"testing"
)

// TestPrintGMSAL142 (RELNOTES L142, the lead's 01:14 (3)): the script a domain admin runs to make the gMSA, printed by
// pgvigil and never run by it.
func TestPrintGMSAL142(t *testing.T) {
	s, err := gmsaScript(`CORP\pgvigil-gmsa$`, []string{"SQL01$", "pgvigil-hosts"})
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{
		"pgvigil runs none of it",
		"Get-KdsRootKey",
		"Add-KdsRootKey",
		"New-ADServiceAccount -Name 'pgvigil-gmsa'",
		"(Get-ADDomain).DNSRoot",
		"-PrincipalsAllowedToRetrieveManagedPassword 'SQL01$','pgvigil-hosts'",
		"Test-ADServiceAccount -Identity 'pgvigil-gmsa'",
		`pgvigil install -user 'CORP\pgvigil-gmsa$'`,
		`CREATE LOGIN [CORP\pgvigil-gmsa$] FROM WINDOWS;`,
	} {
		if !strings.Contains(s, w) {
			t.Errorf("the script does not say %q:\n%s", w, s)
		}
	}
	for _, c := range []struct {
		user   string
		hosts  []string
		refuse string
	}{
		{`CORP\svc-pgvigil`, []string{"SQL01$"}, "gMSA"},
		{`CORP\pgvigil-gmsa$`, nil, "-host"},
		{`CORP\pgvigil-gmsa$`, []string{"SQL01$", "a'b"}, "character"},
		{`CORP\pgvigil-gmsa$`, []string{" "}, "-host"},
	} {
		if _, err := gmsaScript(c.user, c.hosts); err == nil || !strings.Contains(err.Error(), c.refuse) {
			t.Errorf("%q %q: %v, want a refusal saying %q", c.user, c.hosts, err, c.refuse)
		}
	}
}

// TestInstallPrintGMSAL142: 'pgvigil install -print-gmsa' prints the script on any OS, its -host defaulting to this
// host's machine account, and changes nothing; -host goes with -print-gmsa only.
func TestInstallPrintGMSAL142(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w
	got := make(chan string)
	go func() {
		b, _ := io.ReadAll(r)
		got <- string(b)
	}()
	code := run([]string{"install", "-print-gmsa", "-user", `CORP\pgvigil-gmsa$`, "-config", "/nonexistent/pgvigil.yaml"})
	_ = w.Close()
	os.Stdout = old
	out := <-got
	host, _ := os.Hostname()
	if code != 0 || !strings.Contains(out, "New-ADServiceAccount") || !strings.Contains(out, "'"+netbiosHost(host)+"$'") {
		t.Errorf("install -print-gmsa: exit %d, out:\n%s", code, out)
	}
	if _, err := os.Stat("/nonexistent/pgvigil.yaml"); err == nil {
		t.Errorf("install -print-gmsa wrote a configuration")
	}
	if _, err := parseInstallArgs("install", []string{"-host", "SQL01$"}, installOptions{User: "u"}); err == nil || !strings.Contains(err.Error(), "-print-gmsa") {
		t.Errorf("-host without -print-gmsa: %v, want a refusal naming -print-gmsa", err)
	}
}
