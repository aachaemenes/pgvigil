package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestNeedsLogonRightL150 (RELNOTES L150, the lead's 01:14 (2)): every account the install names but the service's
// virtual one is given 'Log on as a service'.
func TestNeedsLogonRightL150(t *testing.T) {
	for user, want := range map[string]bool{
		`NT SERVICE\pgvigil`: false, `nt service\pgvigil`: false,
		`CORP\pgvigil-gmsa$`: true, `CORP\svc-pgvigil`: true, `.\pgvsvc`: true,
	} {
		if got := needsLogonRight(user); got != want {
			t.Errorf("needsLogonRight(%q) = %v, want %v", user, got, want)
		}
	}
}

// TestLogonRightWordsL150: the install's line says the right was read back held; the uninstall's item keeps it and
// says why and how to take it away by hand.
func TestLogonRightWordsL150(t *testing.T) {
	g := logonRightGranted(`CORP\pgvigil-gmsa$`)
	for _, w := range []string{`CORP\pgvigil-gmsa$`, "Log on as a service", "SeServiceLogonRight", "read back", "Group Policy"} {
		if !strings.Contains(g, w) {
			t.Errorf("the grant's line does not say %q: %s", w, g)
		}
	}
	k := logonRightKept(`CORP\svc-pgvigil`)
	for _, w := range []string{`CORP\svc-pgvigil`, "another service", "secpol.msc", "User Rights Assignment"} {
		if !strings.Contains(k, w) {
			t.Errorf("the uninstall's kept line does not say %q: %s", w, k)
		}
	}
}

// TestLogonRightWiredL150: the Windows install grants and reads back the right through LSA by syscall (x/sys has no
// LSA policy calls), and the uninstall's list holds the right as kept - read from the sources, which build on Windows
// only.
func TestLogonRightWiredL150(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	lsa := read("lsa_windows.go")
	for _, p := range []string{"LsaOpenPolicy", "LsaAddAccountRights", "LsaEnumerateAccountRights", "LsaFreeMemory", "LsaClose", "LsaNtStatusToWinError", `"SeServiceLogonRight"`} {
		if !strings.Contains(lsa, p) {
			t.Errorf("lsa_windows.go does not call %s", p)
		}
	}
	svc := read("service_windows.go")
	for _, re := range []string{`needsLogonRight\(o\.User\)[^\n]*\n[^\n]*grantServiceLogon\(o\.User\)`, `logonRightKept\(inst\.User\)`} {
		if !regexp.MustCompile(re).MatchString(svc) {
			t.Errorf("service_windows.go has no %s", re)
		}
	}
}
