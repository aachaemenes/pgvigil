package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"

	"golang.org/x/term"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// windowsAccount is what -user names on Windows (RELNOTES L131): the service's virtual account and a gMSA run with no
// password anywhere; a named account is the opt-in, its password read by -password-stdin and kept by the service
// manager alone.
type windowsAccount int

const (
	accountVirtual windowsAccount = iota + 1 // NT SERVICE\<name>
	accountGMSA                              // DOMAIN\name$
	accountNamed                             // DOMAIN\user or .\user, with -password-stdin
)

// passwordStdinHelp is -password-stdin's help.
const passwordStdinHelp = "Windows, with -user DOMAIN\\user or .\\user: read that account's password from stdin, one line " +
	"(never a flag; pgvigil keeps it nowhere, the service manager does). A gMSA needs none and is preferred: Windows " +
	"changes its password itself"

var (
	// namedUser is a Windows user name: 1 to 20 characters (the sAMAccountName rule), none Windows refuses in one.
	namedUser = regexp.MustCompile(`^[^\\/\[\]:;|=,+*?<>"@]{1,20}$`)
	// accountDomain is "." (this host) or a NetBIOS name of 1 to 15 characters.
	accountDomain = regexp.MustCompile(`^(\.|[^\\/:*?"<>|\s.@\[\]]{1,15})$`)
)

// checkWindowsAccount classifies -user and refuses, in words, a form pgvigil does not run as; host is this computer's
// NetBIOS name (its machine account HOST$ is every service's).
func checkWindowsAccount(user, host string, passwordStdin bool) (windowsAccount, error) {
	u := strings.TrimSpace(user)
	if u == "" {
		return 0, errors.New(`-user is empty: leave it out for the virtual account NT SERVICE\pgvigil`)
	}
	if strings.ContainsAny(u, "\"'`") || strings.IndexFunc(u, func(r rune) bool { return r < 0x20 }) >= 0 {
		return 0, fmt.Errorf("-user %q holds a character Windows refuses in an account name", u)
	}
	dom, name, ok := strings.Cut(u, `\`)
	if !ok {
		if strings.Contains(u, "@") {
			return 0, fmt.Errorf(`-user %s: a user principal name is not taken - name the account DOMAIN\user, the service manager's form`, u)
		}
		return 0, fmt.Errorf(`-user %s names no domain: DOMAIN\user for a domain account, .\user for one of this host`, u)
	}
	noPassword := func(what string) error {
		return fmt.Errorf("-user %s: %s has no password - leave out -password-stdin", u, what)
	}
	switch {
	case strings.EqualFold(dom, "NT SERVICE"):
		if passwordStdin {
			return 0, noPassword("a virtual account")
		}
		return accountVirtual, nil
	case strings.EqualFold(dom, "NT AUTHORITY"):
		return 0, fmt.Errorf(`-user %s: an NT AUTHORITY account is shared by every service of this host - pgvigil runs as its virtual account NT SERVICE\pgvigil, a gMSA DOMAIN\name$, or a named account with -password-stdin`, u)
	case strings.HasSuffix(name, "$"):
		if !config.IsGMSAName(u) {
			return 0, fmt.Errorf(`-user %s must be DOMAIN\name$ for a gMSA (a domain of at most 15 characters, a name of at most 15 before its '$')`, u)
		}
		if host != "" && strings.EqualFold(strings.TrimSuffix(name, "$"), host) {
			return 0, fmt.Errorf("-user %s is this host's own machine account: every service of the host shares it - make a gMSA for pgvigil", u)
		}
		if passwordStdin {
			return 0, noPassword("a gMSA")
		}
		return accountGMSA, nil
	}
	if !accountDomain.MatchString(dom) || !namedUser.MatchString(name) {
		return 0, fmt.Errorf(`-user %s must be DOMAIN\user or .\user: a domain of at most 15 characters, a user name of at most 20 characters`, u)
	}
	if !passwordStdin {
		return 0, fmt.Errorf(`-user %s needs its password: give it on stdin with -password-stdin (never on the command line) - or run as a gMSA (DOMAIN\name$), which needs none and is preferred: Windows changes its password itself and none is kept anywhere`, u)
	}
	return accountNamed, nil
}

// readServicePassword reads -password-stdin's one line, without its line end.
func readServicePassword(r io.Reader) (string, error) {
	line, err := bufio.NewReader(r).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", fmt.Errorf("-password-stdin: reading stdin: %w", err)
	}
	pw := strings.TrimRight(line, "\r\n")
	if pw == "" {
		return "", errors.New("-password-stdin: no password on stdin (one line)")
	}
	return pw, nil
}

// prepareAccount checks -user and -password-stdin for goos before anything changes, and reads the password into o.
// An upgrade keeps the installed account and its stored password, so it takes neither check nor password.
func prepareAccount(o *installOptions, goos, host string, stdin io.Reader) (windowsAccount, error) {
	if goos != "windows" {
		if o.PasswordStdin {
			return 0, errors.New("-password-stdin is for a Windows service account: the service here runs as a system user with no password")
		}
		return 0, nil
	}
	if o.Upgrade {
		if o.PasswordStdin {
			return 0, errors.New("-password-stdin does not go with -upgrade: the upgrade keeps the installed account and its password (a new password: the service's Log On tab, or install again with -user and -password-stdin)")
		}
		return 0, nil
	}
	kind, err := checkWindowsAccount(o.User, host, o.PasswordStdin)
	if err != nil || !o.PasswordStdin {
		return kind, err
	}
	in := stdin
	if f, ok := stdin.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
		fmt.Fprintf(os.Stderr, "the password of %s (not shown): ", strings.TrimSpace(o.User))
		b, err := term.ReadPassword(int(f.Fd()))
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return 0, fmt.Errorf("-password-stdin: %w", err)
		}
		in = strings.NewReader(string(b))
	}
	if o.Password, err = readServicePassword(in); err != nil {
		return 0, err
	}
	return kind, nil
}

// netbiosHost is the first label of a host name, at most 15 characters: the name its machine account carries.
func netbiosHost(host string) string {
	h, _, _ := strings.Cut(strings.TrimSpace(host), ".")
	if len(h) > 15 {
		h = h[:15]
	}
	return h
}

// needsLogonRight says whether the install gives user 'Log on as a service' (RELNOTES L150): every account but the
// service's virtual one, which Windows lets run as its service by itself.
func needsLogonRight(user string) bool {
	dom, _, _ := strings.Cut(strings.TrimSpace(user), `\`)
	return !strings.EqualFold(dom, "NT SERVICE")
}

// logonRightGranted is the install's line once the right is read back held.
func logonRightGranted(user string) string {
	return fmt.Sprintf("'Log on as a service' (SeServiceLogonRight) granted to %s and read back held. A Group Policy that "+
		"defines this right replaces the local list at its next refresh: add %s to that policy too.", user, user)
}

// logonRightKept is the uninstall's reason for leaving the right in place.
func logonRightKept(user string) string {
	return fmt.Sprintf("another service may run as %s too, so its 'Log on as a service' right stays; when nothing else "+
		"does, take it away by hand: secpol.msc > Local Policies > User Rights Assignment > Log on as a service", user)
}
