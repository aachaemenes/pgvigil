package config

import (
	"crypto/tls"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"
)

// PGAUTH M1: the guard for a password-shaped sign-in (a warning, never a refusal). pg_hba's
// ldap, radius, pam, bsd and password methods make the server ask the client for the password in clear - inside the
// session's TLS when there is TLS - so only sslmode=verify-full (the server's certificate and its name checked) keeps
// it from a server that is not the one named. scram-sha-256 and md5 never send it; cert, gss, sspi, peer and ident
// use none.

// SSLModeOf is the server-certificate check a PostgreSQL dsn opens with, read from pgx's own parse (pgconn.ParseConfig -
// pgauth12 S1: the keyword or the URL key with its aliases such as ssl=true, the service file, PGSSLMODE and
// PGSSLROOTCERT, sslrootcert=system forcing verify-full - never a reading of the text beside it), in sslmode's words for
// the weakest TLS config the connect may use (the main one and each fallback): "verify-full" when each checks the
// server's certificate and its name, "verify-ca" when each checks the chain but not the name, "require" when TLS is
// used and some config checks no certificate, "prefer" / "allow" when one of the configs is no TLS at all (prefer
// tries TLS first), "disable" when none is (a Unix socket too); "" when the dsn does not parse.
func SSLModeOf(dsn string) string {
	pc, err := pgconn.ParseConfig(dsn)
	if err != nil {
		return ""
	}
	cfgs := []*tls.Config{pc.TLSConfig}
	for _, f := range pc.Fallbacks {
		cfgs = append(cfgs, f.TLSConfig)
	}
	plain, weakest := 0, 3 // 3 verify-full, 2 verify-ca, 1 no certificate check
	for _, c := range cfgs {
		switch {
		case c == nil:
			plain++
		case c.InsecureSkipVerify && c.VerifyPeerCertificate != nil:
			weakest = min(weakest, 2)
		case c.InsecureSkipVerify:
			weakest = min(weakest, 1)
		}
	}
	switch {
	case plain == len(cfgs):
		return "disable"
	case plain > 0 && cfgs[0] == nil:
		return "allow"
	case plain > 0:
		return "prefer"
	}
	return []string{"", "require", "verify-ca", "verify-full"}[weakest]
}

// passwordShaped: pg_hba's methods whose client sends the password in clear (hba.c UserAuthName's words)
var passwordShaped = map[string]bool{"ldap": true, "radius": true, "pam": true, "bsd": true, "password": true}

// PasswordShaped reads PostgreSQL 16's SYSTEM_USER ('auth_method:identity'; empty for NULL, trust): the method word,
// and whether that method has the client send the password in clear. The identity is never returned (under ldap it is
// the bind DN).
func PasswordShaped(systemUser string) (method string, sendsPassword bool) {
	method, _, _ = strings.Cut(systemUser, ":")
	return method, passwordShaped[method]
}

// SignInWarn is the guard's words for a session signed in by method with the dsn's sslmode (SSLModeOf), or the empty
// string when there is nothing to warn about (verify-full, or a method that sends no password). The words say what the
// mode leaves open (pgauth12 N3): verify-ca checks the chain but not the server's name; require, prefer and allow check
// no certificate; disable has no TLS; a mode not read may check none.
func SignInWarn(method, sslmode string) string {
	if !passwordShaped[method] || sslmode == "verify-full" {
		return ""
	}
	var open string
	switch sslmode {
	case "":
		open = "the sslmode could not be read: it may check no server certificate"
	case "verify-ca":
		open = "sslmode=verify-ca does not check the server's name"
	case "disable":
		open = "sslmode=disable has no TLS: the password crosses the network in clear"
	default:
		open = "sslmode=" + sslmode + " checks no server certificate"
	}
	return "the server signs this login in by " + method + ", which has pgvigil send the password in clear inside the session, and " +
		open + ": set sslmode=verify-full with sslrootcert (the server's CA file, or 'system' for a public CA)"
}
