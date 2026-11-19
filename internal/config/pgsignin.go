package config

import (
	"os"
	"strings"
)

// PGAUTH M1: the guard for a password-shaped sign-in (Allen's Q249, decision 2: a WARN, never a refusal). pg_hba's
// ldap, radius, pam, bsd and password methods make the server ask the client for the password in clear - inside the
// session's TLS when there is TLS - so only sslmode=verify-full (the server's certificate and its name checked) keeps
// it from a server that is not the one named. scram-sha-256 and md5 never send it; cert, gss, sspi, peer and ident
// use none.

// SSLModeOf is the sslmode a PostgreSQL dsn opens with, as pgx reads it: the keyword (or the URL's query key), else
// the PGSSLMODE variable, else pgx's default 'prefer'. A string that does not parse gives the empty string.
func SSLModeOf(dsn string) string {
	kv, err := pgSettings(dsn)
	if err != nil {
		return ""
	}
	if v := kv["sslmode"]; v != "" {
		return v
	}
	if v := os.Getenv("PGSSLMODE"); v != "" {
		return v
	}
	return "prefer"
}

// passwordShaped: pg_hba's methods whose client sends the password in clear (hba.c UserAuthName's words)
var passwordShaped = map[string]bool{"ldap": true, "radius": true, "pam": true, "bsd": true, "password": true}

// PasswordShaped reads PostgreSQL 16's SYSTEM_USER ('auth_method:identity'; empty for NULL, trust): the method word,
// and whether that method has the client send the password in clear. The identity is never returned (under ldap it is
// the bind DN).
func PasswordShaped(systemUser string) (method string, clear bool) {
	method, _, _ = strings.Cut(systemUser, ":")
	return method, passwordShaped[method]
}

// SignInWarn is the guard's words for a session signed in by method with the dsn's sslmode, or the empty string when
// there is nothing to warn about (verify-full, or a method that sends no password).
func SignInWarn(method, sslmode string) string {
	if !passwordShaped[method] || sslmode == "verify-full" {
		return ""
	}
	mode := "sslmode=" + sslmode
	if sslmode == "" {
		mode = "the sslmode not read"
	}
	return "the server signs this login in by " + method + ", which has pgvigil send the password in clear inside the session, and " +
		mode + " checks no server certificate: set sslmode=verify-full with sslrootcert (the server's CA file, or 'system' for a public CA)"
}
