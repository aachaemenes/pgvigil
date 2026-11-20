package main

import (
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestServiceAccountRefusal: the SID -user resolves to runs pgvigil only as one user account (a gMSA may resolve as a
// computer); a group, a local group, a well-known group and a SID that names many accounts are refused - 'Log on as a
// service' would go to every member.
func TestServiceAccountRefusal(t *testing.T) {
	for _, c := range []struct {
		sid  string
		use  uint32
		gmsa bool
		ok   bool
	}{
		{"S-1-5-21-1-2-3-1105", sidUser, false, true},
		{"S-1-5-21-1-2-3-1106", sidComputer, true, true},
		{"S-1-5-21-1-2-3-1106", sidComputer, false, false},
		{"S-1-5-21-1-2-3-513", sidGroup, false, false},  // Domain Users
		{"S-1-5-32-545", sidAlias, false, false},        // BUILTIN\Users
		{"S-1-5-21-1-2-3-1201", sidAlias, false, false}, // a local group
		{"S-1-5-21-1-2-3-1202", sidGroup, false, false}, // a domain group
		{"S-1-5-11", sidWellKnownGroup, false, false},   // Authenticated Users
		{"S-1-1-0", sidWellKnownGroup, false, false},    // Everyone
	} {
		why := serviceAccountRefusal(c.sid, c.use, c.gmsa)
		if (why == "") != c.ok {
			t.Errorf("serviceAccountRefusal(%s, kind %d, gmsa %v) = %q, want taken %v", c.sid, c.use, c.gmsa, why, c.ok)
		}
	}
}

// TestGrantFailureStops: a refused 'Log on as a service' ends the install on a fresh host and where -user names
// another account than the service runs as; it goes on only where the service already runs as this very account.
func TestGrantFailureStops(t *testing.T) {
	for _, c := range []struct {
		exists      bool
		runsAs, use string
		stops       bool
	}{
		{false, "", `.\pgvsvc`, true},
		{true, `NT SERVICE\pgvigil`, `CORP\svc-new`, true},
		{true, `.\pgvold`, `.\pgvnew`, true},
		{true, `CORP\svc-pgvigil`, `corp\SVC-pgvigil`, false},
		{true, ` .\pgvsvc `, `.\pgvsvc`, false},
	} {
		if got := grantFailureStops(c.exists, c.runsAs, c.use); got != c.stops {
			t.Errorf("grantFailureStops(exists %v, runs as %q, -user %q) = %v, want %v", c.exists, c.runsAs, c.use, got, c.stops)
		}
	}
}

// TestNeedsLogonRightBuiltins: the virtual account and the built-in service accounts take no grant; any other does.
func TestNeedsLogonRightBuiltins(t *testing.T) {
	for user, want := range map[string]bool{
		`NT SERVICE\pgvigil`: false, "LocalSystem": false, `NT AUTHORITY\LocalService`: false, `nt authority\NetworkService`: false,
		`.\pgvsvc`: true, `CORP\pgv-gmsa$`: true, `CORP\svc-pgvigil`: true,
	} {
		if got := needsLogonRight(user); got != want {
			t.Errorf("needsLogonRight(%q) = %v, want %v", user, got, want)
		}
	}
}

// TestOtherVirtualAccountRefused: NT SERVICE\pgvigil is pgvigil's virtual account; another service's is refused.
func TestOtherVirtualAccountRefused(t *testing.T) {
	for user, ok := range map[string]bool{`NT SERVICE\pgvigil`: true, `nt service\PGVIGIL`: true, `NT SERVICE\MSSQLSERVER`: false, `NT SERVICE\pgvigil2`: false} {
		_, err := checkWindowsAccount(user, "HOST", false)
		if (err == nil) != ok {
			t.Errorf("checkWindowsAccount(%q) = %v, want taken %v", user, err, ok)
		}
	}
}

// TestKeptAccountRules: a re-run without -user keeps the installed account unchecked (LocalSystem set by hand
// included); -user naming the installed named account again keeps its stored password; -user is used trimmed.
func TestKeptAccountRules(t *testing.T) {
	for _, installed := range []string{"LocalSystem", `NT AUTHORITY\LocalService`, `.\pgvsvc`, `CORP\pgv-gmsa$`} {
		o := installOptions{User: `NT SERVICE\pgvigil`, set: map[string]bool{}}
		keepInstalledAccount(&o, installed, true)
		if _, err := prepareAccount(&o, "windows", "HOST", strings.NewReader("")); err != nil || o.User != installed {
			t.Errorf("a re-run over a service running as %q: %v (user %q), want it kept with no check", installed, err, o.User)
		}
	}
	o := installOptions{User: `.\PGVSVC`, set: map[string]bool{"user": true}}
	keepInstalledAccount(&o, `.\pgvsvc`, true)
	if kind, err := prepareAccount(&o, "windows", "HOST", strings.NewReader("")); err != nil || kind != accountNamed {
		t.Errorf("-user naming the installed account again: kind %v, %v - want accountNamed, its stored password kept", kind, err)
	}
	o = installOptions{User: `.\pgvother`, set: map[string]bool{"user": true}}
	keepInstalledAccount(&o, `.\pgvsvc`, true)
	if _, err := prepareAccount(&o, "windows", "HOST", strings.NewReader("")); err == nil || !strings.Contains(err.Error(), "password-stdin") {
		t.Errorf("-user naming another account without -password-stdin: %v, want the refusal naming -password-stdin", err)
	}
	o = installOptions{User: " CORP\\pgv-gmsa$ ", set: map[string]bool{"user": true}}
	if _, err := prepareAccount(&o, "windows", "HOST", strings.NewReader("")); err != nil || o.User != `CORP\pgv-gmsa$` {
		t.Errorf("-user with spaces: %v, user %q - want it trimmed for every later step", err, o.User)
	}
}

// TestPasswordStdinDropsABOM: a BOM a UTF-8 pipe put first is no part of the password; the rest, a non-ASCII
// character included, is read as it was sent.
func TestPasswordStdinDropsABOM(t *testing.T) {
	for in, want := range map[string]string{"\ufeffP\u00e4sswort-2026\r\n": "P\u00e4sswort-2026", "P\u00e4sswort-2026\n": "P\u00e4sswort-2026"} {
		if got, err := readServicePassword(strings.NewReader(in)); err != nil || got != want {
			t.Errorf("readServicePassword(%q) = %q, %v - want %q", in, got, err, want)
		}
	}
}

// TestGMSANameQuotedInTheScript: a gMSA name with an apostrophe (a sAMAccountName character) prints PowerShell lines
// that parse - the ' doubled inside single quotes; ; , = and + are no part of a gMSA name.
func TestGMSANameQuotedInTheScript(t *testing.T) {
	script, err := gmsaScript(`CORP\o'neil-gmsa$`, []string{"HOST$"})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`-Name 'o''neil-gmsa'`, `-Identity 'o''neil-gmsa'`, `pgvigil install -user 'CORP\o''neil-gmsa$'`} {
		if !strings.Contains(script, want) {
			t.Errorf("the script has no %s:\n%s", want, script)
		}
	}
	for _, name := range []string{`CORP\a;b$`, `CORP\a,b$`, `CORP\a=b$`, `CORP\a+b$`, `CO;RP\ab$`} {
		if config.IsGMSAName(name) {
			t.Errorf("IsGMSAName(%q) = true: the character is no part of an account name", name)
		}
	}
}

// TestInstallScriptsKeepTheInstalledAccount: install.ps1 pipes the password as UTF-8 without a BOM, set in the
// caller's scope before the pipe; both installers refuse an account where the service is installed on the online
// path too; the docs/ and deploy/ copies are the same.
func TestInstallScriptsKeepTheInstalledAccount(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	ps := read("../../docs/install.ps1")
	if !regexp.MustCompile(`(?s)\$OutputEncoding = New-Object System\.Text\.UTF8Encoding \$false\s*\n\s*return Invoke-Native \{ \$plain \| & \$exePath install`).MatchString(ps) {
		t.Error("install.ps1 does not set $OutputEncoding to UTF-8 without a BOM right before the password's pipe")
	}
	if !strings.Contains(ps, "-ServiceAccount (or PGVIGIL_SERVICE_ACCOUNT) goes with a fresh install: the service pgvigil is installed") {
		t.Error("install.ps1's online path does not refuse an account over the installed service")
	}
	sh := read("../../docs/install.sh")
	if !strings.Contains(sh, "--user goes with a fresh install: the installed collector keeps its account") {
		t.Error("install.sh's online path does not refuse --user over the installed collector")
	}
	for _, f := range []string{"install.ps1", "install.sh"} {
		if read("../../docs/"+f) != read("../../deploy/"+f) {
			t.Errorf("docs/%s and deploy/%s differ", f, f)
		}
	}
}
