package web

import (
	"context"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/secrets"
)

// CheckResult is one instance's connection test for 'pgvigil check' (L181): the page's own test
// (testConnectionList), exported - who answered, and the collections that will not run there and why (N59).
type CheckResult struct {
	OK          bool
	Detail      string
	NotRun      []engines.NotRun
	Collections int
	ListNote    string // why the not-run list is missing or partial ("" = read)
	Unknown     string // a server this build does not know, in words (engines.UnknownServer; "" = known or not read)
	Warn        string // PGAUTH M1: the sign-in guard's words ("" = nothing to warn about)
}

// CheckConnection is the one connection test 'pgvigil check' runs per instance: the same 10-second connect, detect
// and not-run list the Admin > Instances page uses, so the command and the page never disagree.
func CheckConnection(ctx context.Context, engine, dsn string, sec *secrets.Ref, in config.Instance, cfg *config.Config) CheckResult {
	t := testConnectionList(ctx, engine, dsn, sec, in, cfg)
	return CheckResult{OK: t.ok, Detail: t.detail, NotRun: t.notRun, Collections: t.collections, ListNote: t.listNote, Unknown: t.unknown, Warn: t.warn}
}

// signInNote (PGAUTH M1; a warning, never a refusal): on PostgreSQL 16+ the guard's words
// when the server signed the login in by a password-shaped method (SYSTEM_USER's word: ldap, radius, pam, bsd,
// password) and the dsn opens with less than sslmode=verify-full; "" otherwise. ssl is the session's pg_stat_ssl.ssl:
// without TLS the password crossed the network in clear, said first.
func signInNote(versionNum int, systemUser string, ssl bool, dsn string) string {
	if versionNum < 160000 {
		return ""
	}
	method, _ := config.PasswordShaped(systemUser)
	w := config.SignInWarn(method, config.SSLModeOf(dsn))
	if w != "" && !ssl {
		w = "this session runs without TLS: " + w
	}
	return w
}
