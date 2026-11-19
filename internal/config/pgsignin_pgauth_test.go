package config

import (
	"strings"
	"testing"
)

// PGAUTH M1 (Allen's Q249 = the recommendation; decision 2 = WARN): the password-shaped sign-in methods - pg_hba's
// ldap, radius, pam, bsd and password - make the server ask the client for the password in clear (inside TLS when
// there is TLS). pgvigil's guard reads the method from PostgreSQL 16's SYSTEM_USER ('auth_method:identity', NULL
// under trust; the method word is pg_hba's: hba.c UserAuthName) and the dsn's sslmode, and warns - never refuses -
// when such a method signs in without sslmode=verify-full.

// TestSSLModeOfPGAUTH: the sslmode a dsn opens with, as pgx reads it - the keyword or URL query, else PGSSLMODE,
// else pgx's default 'prefer'; a string that does not parse is the empty string (unread).
func TestSSLModeOfPGAUTH(t *testing.T) {
	t.Setenv("PGSSLMODE", "")
	for _, c := range []struct{ dsn, want string }{
		{"host=db1 user=pgvigil sslmode=verify-full sslrootcert=system", "verify-full"},
		{"host=db1 user=pgvigil", "prefer"},
		{"postgres://pgvigil@db1:5432/postgres?sslmode=require", "require"},
		{"host=db1 sslmode='verify-ca'", "verify-ca"},
		{"host=db1 sslmode=disable sslmode=require", ""},
	} {
		if got := SSLModeOf(c.dsn); got != c.want {
			t.Errorf("SSLModeOf(%q) = %q, want %q", c.dsn, got, c.want)
		}
	}
	t.Setenv("PGSSLMODE", "verify-full")
	if got := SSLModeOf("host=db1"); got != "verify-full" {
		t.Errorf("with PGSSLMODE=verify-full and no keyword: %q, want verify-full", got)
	}
	if got := SSLModeOf("host=db1 sslmode=require"); got != "require" {
		t.Errorf("the keyword before PGSSLMODE: %q, want require", got)
	}
}

// TestPasswordShapedPGAUTH: SYSTEM_USER's method word, and whether that method has the client send the password in
// clear (ldap, radius, pam, bsd, password); scram-sha-256 / md5 never send it, cert / gss / sspi / peer / ident use
// none, and NULL (trust) is no method at all.
func TestPasswordShapedPGAUTH(t *testing.T) {
	for _, c := range []struct {
		systemUser, method string
		sends              bool
	}{
		{"ldap:cn=pgvigil,ou=svc,dc=example,dc=com", "ldap", true},
		{"radius:pgvigil", "radius", true},
		{"pam:pgvigil", "pam", true},
		{"bsd:pgvigil", "bsd", true},
		{"password:pgvigil", "password", true},
		{"scram-sha-256:pgvigil", "scram-sha-256", false},
		{"md5:pgvigil", "md5", false},
		{"cert:CN=pgvigil", "cert", false},
		{"gss:pgvigil@PGV.TEST", "gss", false},
		{"", "", false},
	} {
		m, sends := PasswordShaped(c.systemUser)
		if m != c.method || sends != c.sends {
			t.Errorf("PasswordShaped(%q) = %q, %v; want %q, %v", c.systemUser, m, sends, c.method, c.sends)
		}
	}
}

// TestSignInWarnPGAUTH: the guard's words - a password-shaped method without verify-full names the method, the
// setting to use and sslrootcert; verify-full, or a method that sends no password, says nothing.
func TestSignInWarnPGAUTH(t *testing.T) {
	w := SignInWarn("ldap", "prefer")
	for _, want := range []string{"ldap", "sslmode=prefer", "verify-full", "sslrootcert"} {
		if !strings.Contains(w, want) {
			t.Errorf("SignInWarn(ldap, prefer) = %q: no %q", w, want)
		}
	}
	if w := SignInWarn("radius", ""); !strings.Contains(w, "not read") {
		t.Errorf("SignInWarn(radius, unread) = %q: it should say the sslmode was not read", w)
	}
	for _, c := range [][2]string{{"ldap", "verify-full"}, {"scram-sha-256", "disable"}, {"cert", "require"}, {"", "prefer"}} {
		if w := SignInWarn(c[0], c[1]); w != "" {
			t.Errorf("SignInWarn(%q, %q) = %q, want none", c[0], c[1], w)
		}
	}
}

// TestPageDSNCarriesVerifyFullPGAUTH: an instance of Admin > Instances signs in to an ldap / radius / pam server by
// its 'password' kind with sslmode=verify-full in its driver options; the page door opens sslrootcert as 'system'
// only (a public CA: a private CA's file is pgvigil.yaml's), and BuildDSN carries both keys.
func TestPageDSNCarriesVerifyFullPGAUTH(t *testing.T) {
	opts := "sslmode=verify-full sslrootcert=system"
	if why := PageDoorRefusal("dir1", EnginePostgres, "password", opts); why != "" {
		t.Fatalf("the page door refuses %q: %s", opts, why)
	}
	if why := PageDoorRefusal("dir1", EnginePostgres, "password", "sslmode=verify-full sslrootcert=/etc/pgvigil/ca.pem"); why == "" {
		t.Error("the page door opens a CA file on serve's host")
	}
	dsn, err := BuildDSN(Conn{Engine: EnginePostgres, Auth: "password", Host: "db1", Login: "pgvigil", Password: "secret", Extra: opts})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(dsn, "sslmode=verify-full") || !strings.Contains(dsn, "sslrootcert=system") || SSLModeOf(dsn) != "verify-full" {
		t.Errorf("BuildDSN = %q: want sslmode=verify-full and sslrootcert=system", strings.Replace(dsn, "secret", "***", 1))
	}
}
