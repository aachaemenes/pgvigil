package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestWindowsAccountFormL131: -user on Windows is the virtual account or a
// gMSA with no password, or a named account only with -password-stdin; every other form is refused in words.
func TestWindowsAccountFormL131(t *testing.T) {
	cases := []struct {
		user   string
		pw     bool
		want   windowsAccount
		refuse string
	}{
		{`NT SERVICE\pgvigil`, false, accountVirtual, ""},
		{`nt service\pgvigil`, false, accountVirtual, ""},
		{`CORP\pgvigil-gmsa$`, false, accountGMSA, ""},
		{`CORP\svc-pgvigil`, true, accountNamed, ""},
		{`.\pgvsvc`, true, accountNamed, ""},
		{`SQL01\pgvsvc`, true, accountNamed, ""},
		{`CORP\svc-pgvigil`, false, 0, "-password-stdin"},
		{`CORP\pgvigil-gmsa$`, true, 0, "has no password"},
		{`NT SERVICE\pgvigil`, true, 0, "has no password"},
		{`CORP\SQL01$`, false, 0, "machine account"},
		{`corp\sql01$`, false, 0, "machine account"},
		{`NT AUTHORITY\NetworkService`, false, 0, "every service"},
		{`NT AUTHORITY\LocalSystem`, false, 0, "every service"},
		{`svc@corp.example`, true, 0, `DOMAIN\user`},
		{`pgvsvc`, true, 0, `.\user`},
		{`CORP\an-account-name-of-31-chars`, true, 0, "20 characters"},
		{`CORP\a"b`, true, 0, "character"},
		{`CORP\gmsa-name-of-16ch$`, false, 0, `DOMAIN\name$`},
		{"", false, 0, "empty"},
	}
	for _, c := range cases {
		got, err := checkWindowsAccount(c.user, "SQL01", c.pw)
		switch {
		case c.refuse == "" && err != nil:
			t.Errorf("%q (password %v): refused %v, want taken", c.user, c.pw, err)
		case c.refuse == "" && got != c.want:
			t.Errorf("%q: kind %d, want %d", c.user, got, c.want)
		case c.refuse != "" && (err == nil || !strings.Contains(err.Error(), c.refuse)):
			t.Errorf("%q (password %v): %v, want a refusal saying %q", c.user, c.pw, err, c.refuse)
		}
	}
}

// TestReadServicePasswordL131: -password-stdin's one line, without its line end; nothing read is a refusal that never
// repeats what it read.
func TestReadServicePasswordL131(t *testing.T) {
	for in, want := range map[string]string{"s3cret\n": "s3cret", "s3cret\r\n": "s3cret", "s3 cret": "s3 cret", "first\nsecond\n": "first"} {
		got, err := readServicePassword(strings.NewReader(in))
		if err != nil || got != want {
			t.Errorf("stdin %q: %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"", "\n", "\r\n"} {
		if _, err := readServicePassword(strings.NewReader(in)); err == nil || !strings.Contains(err.Error(), "no password") {
			t.Errorf("stdin %q: %v, want 'no password'", in, err)
		}
	}
}

// TestPrepareAccountL131: the check runs on Windows when -user or -password-stdin is named; -password-stdin elsewhere
// and with -upgrade is refused; the password lands in the options and in no error.
func TestPrepareAccountL131(t *testing.T) {
	const pw = "Pv9-not-in-any-error"
	parse := func(args ...string) installOptions {
		o, err := parseInstallArgs("install", args, installOptions{User: `NT SERVICE\pgvigil`})
		if err != nil {
			t.Fatalf("parse %v: %v", args, err)
		}
		return o
	}
	o := parse("-user", `CORP\svc-pgvigil`, "-password-stdin")
	kind, err := prepareAccount(&o, "windows", "SQL01", strings.NewReader(pw+"\n"))
	if err != nil || kind != accountNamed || o.Password != pw {
		t.Errorf("windows, a named account: kind %d, password set %v, %v", kind, o.Password == pw, err)
	}
	o = parse()
	if kind, err := prepareAccount(&o, "windows", "SQL01", strings.NewReader("")); err != nil || kind != accountVirtual || o.Password != "" {
		t.Errorf("windows, the default: kind %d, %v", kind, err)
	}
	for _, c := range []struct {
		goos   string
		args   []string
		refuse string
	}{
		{"linux", []string{"-password-stdin"}, "Windows"},
		{"windows", []string{"-upgrade", "-password-stdin"}, "-upgrade"},
		{"windows", []string{"-user", `CORP\svc-pgvigil`}, "-password-stdin"},
		{"windows", []string{"-user", `CORP\pgvigil-gmsa$`, "-password-stdin"}, "has no password"},
	} {
		o := parse(c.args...)
		_, err := prepareAccount(&o, c.goos, "SQL01", strings.NewReader(pw+"\n"))
		if err == nil || !strings.Contains(err.Error(), c.refuse) {
			t.Errorf("%s %v: %v, want a refusal saying %q", c.goos, c.args, err, c.refuse)
		}
		if err != nil && strings.Contains(err.Error(), pw) {
			t.Errorf("%s %v: the refusal repeats the password", c.goos, c.args)
		}
	}
	if _, err := parseInstallArgs("uninstall", []string{"-password-stdin"}, installOptions{}); err == nil {
		t.Errorf("uninstall took -password-stdin")
	}
}

// TestServicePasswordWiredL131: the Windows install hands the password to the service manager on create and on update
// (a NULL password on update keeps the stored one) and never logs it - read from the source, which builds on Windows only.
func TestServicePasswordWiredL131(t *testing.T) {
	b, err := os.ReadFile("service_windows.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, re := range []string{`Password:\s+o\.Password`, `c\.Password = o\.Password`} {
		if !regexp.MustCompile(re).MatchString(src) {
			t.Errorf("service_windows.go has no %s", re)
		}
	}
	if regexp.MustCompile(`log\.\w+\([^\n]*Password`).MatchString(src) {
		t.Errorf("service_windows.go logs a Password")
	}
}
