package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestReinstallKeepsAccountL131: 'pgvigil install' run again over an installed service without -user keeps the
// account the service runs as (before, the default moved a gMSA service back to the virtual account); -user, -upgrade
// (its own rule) and a host with no service leave the options as they are.
func TestReinstallKeepsAccountL131(t *testing.T) {
	const gmsa = `CORP\pgvigil-gmsa$`
	parse := func(args ...string) installOptions {
		o, err := parseInstallArgs("install", args, installOptions{User: `NT SERVICE\pgvigil`})
		if err != nil {
			t.Fatalf("parse %v: %v", args, err)
		}
		return o
	}
	o := parse()
	keepInstalledAccount(&o, gmsa, true)
	if o.User != gmsa || !o.keptAccount {
		t.Errorf("a re-run without -user: user %q kept %v, want %q kept", o.User, o.keptAccount, gmsa)
	}
	for _, c := range []struct {
		args  []string
		found bool
	}{{[]string{"-user", `CORP\pgvigil-new-gmsa$`}, true}, {[]string{"-upgrade"}, true}, {nil, false}} {
		o := parse(c.args...)
		before := o.User
		keepInstalledAccount(&o, gmsa, c.found)
		if o.User != before || o.keptAccount {
			t.Errorf("%v found %v: user %q kept %v, want %q as it was", c.args, c.found, o.User, o.keptAccount, before)
		}
	}
	// a kept named account keeps its stored password (NULL to the service manager) unless -password-stdin gives one
	o = parse()
	keepInstalledAccount(&o, `CORP\svc-pgvigil`, true)
	if kind, err := prepareAccount(&o, "windows", "SQL01", strings.NewReader("")); err != nil || kind != accountNamed || o.Password != "" {
		t.Errorf("a kept named account: kind %d, password %v, %v", kind, o.Password != "", err)
	}
	o = parse("-password-stdin")
	keepInstalledAccount(&o, `CORP\svc-pgvigil`, true)
	if _, err := prepareAccount(&o, "windows", "SQL01", strings.NewReader("new-one\n")); err != nil || o.Password != "new-one" {
		t.Errorf("a kept named account with -password-stdin: %v, password read %v", err, o.Password == "new-one")
	}
}

// TestInstallScriptsAccountL131: install.ps1 takes -ServiceAccount (or PGVIGIL_SERVICE_ACCOUNT for 'irm | iex') and
// -Help, asks a named account's password with Read-Host -AsSecureString and writes it to -password-stdin's standard
// input as UTF-8 bytes (Invoke-NativeStdin, never a pipe), never a parameter; install.sh takes --user (or
// PGVIGIL_USER) and --help / -h; neither passes an account to an upgrade.
func TestInstallScriptsAccountL131(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	ps := read("../../docs/install.ps1")
	for _, re := range []string{
		`\[string\]\$ServiceAccount`, `\[switch\]\$Help`, `PGVIGIL_SERVICE_ACCOUNT`, `Read-Host -AsSecureString`,
		`Invoke-NativeStdin \$exePath @\('install', '-user', \$account, '-password-stdin'\) \$bytes`, `ZeroFreeBSTR`, `-ServiceAccount goes with a fresh install`,
	} {
		if !regexp.MustCompile(re).MatchString(ps) {
			t.Errorf("install.ps1 has no %s", re)
		}
	}
	if regexp.MustCompile(`(?i)\[(string|securestring)\]\$\w*Password`).MatchString(ps) {
		t.Errorf("install.ps1 takes a password as a parameter")
	}
	sh := read("../../docs/install.sh")
	for _, re := range []string{`--user\)`, `--help\|-h\)`, `PGVIGIL_USER`, `install -user "\$SVCUSER"`, `--user goes with a fresh install`} {
		if !regexp.MustCompile(re).MatchString(sh) {
			t.Errorf("install.sh has no %s", re)
		}
	}
}
