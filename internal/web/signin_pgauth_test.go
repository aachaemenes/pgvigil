package web

import (
	"strings"
	"testing"
)

// TestSignInNotePGAUTH (PGAUTH M1, decision 2): the connection test's sign-in note - on PostgreSQL 16+ a
// password-shaped method (SYSTEM_USER's word) with a dsn short of sslmode=verify-full is the guard's WARN words; under
// 16, a method that sends no password, a trust sign-in and verify-full say nothing.
func TestSignInNotePGAUTH(t *testing.T) {
	t.Setenv("PGSSLMODE", "")
	if w := signInNote(160004, "ldap:cn=pgvigil,dc=example,dc=com", true, "host=db1 user=pgvigil sslmode=require"); !strings.Contains(w, "ldap") ||
		!strings.Contains(w, "sslmode=require") || !strings.Contains(w, "verify-full") || strings.Contains(w, "cn=") {
		t.Errorf("ldap with sslmode=require: %q, want the guard's words naming ldap and require, never the bind DN", w)
	}
	for _, c := range []struct {
		v       int
		su, dsn string
	}{
		{150008, "", "host=db1"},
		{160004, "scram-sha-256:pgvigil", "host=db1 sslmode=disable"},
		{160004, "", "host=db1"},
		{160004, "radius:pgvigil", "host=db1 sslmode=verify-full sslrootcert=system"},
	} {
		if w := signInNote(c.v, c.su, false, c.dsn); w != "" {
			t.Errorf("signInNote(%d, %q, %q) = %q, want none", c.v, c.su, c.dsn, w)
		}
	}
}
