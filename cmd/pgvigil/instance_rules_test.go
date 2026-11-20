package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestConnFromDSNTakesOnlyTheDSN: what the shell would add (PGPASSWORD, PGPORT, PGDATABASE, the running account's
// passfile) is never taken - only what the connection string names; a service, a second host and a key a page instance
// does not keep are refused in words.
func TestConnFromDSNTakesOnlyTheDSN(t *testing.T) {
	pass := filepath.Join(t.TempDir(), "pgpass")
	if err := os.WriteFile(pass, []byte("*:*:*:*:filepw\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PGPASSWORD", "envpw")
	t.Setenv("PGPORT", "5433")
	t.Setenv("PGDATABASE", "envdb")
	t.Setenv("PGPASSFILE", pass)
	t.Setenv("PGSERVICE", "")
	for _, c := range []struct {
		dsn, auth, pw, db string
		port              int
	}{
		{"host=db1 user=mon", "pgpass", "", "", 5432},
		{"postgres://mon@pg7/app", "pgpass", "", "app", 5432},
		{"host=db1 user=mon password=pw port=6432 dbname=x", "password", "pw", "x", 6432},
		{"postgres://mon:pw@pg7:6433/app?sslmode=require", "password", "pw", "app", 6433},
	} {
		got, err := connFromDSN(config.EnginePostgres, c.dsn)
		if err != nil {
			t.Errorf("%s: %v", c.dsn, err)
			continue
		}
		if got.Auth != c.auth || got.Password != c.pw || got.DBName != c.db || got.Port != c.port {
			t.Errorf("%s: auth %s, password %q, db %q, port %d - want %s %q %q %d (nothing of the shell's)", c.dsn, got.Auth, got.Password, got.DBName, got.Port, c.auth, c.pw, c.db, c.port)
		}
	}
	for dsn, says := range map[string]string{
		"host=db1 user=mon service=prod":                    "service",
		"host=db1 user=mon target_session_attrs=read-write": "target_session_attrs",
		"host=a,b user=mon":                                 "more than one host",
		"postgres://mon@pg7/app?sslrootcert=/etc/ca.pem":    "sslrootcert",
	} {
		if _, err := connFromDSN(config.EnginePostgres, dsn); err == nil || !strings.Contains(err.Error(), says) {
			t.Errorf("%s: %v, want a refusal naming %q", dsn, err, says)
		}
	}
	t.Setenv("PGSERVICE", "prod")
	if _, err := connFromDSN(config.EnginePostgres, "host=db1 user=mon"); err == nil || !strings.Contains(err.Error(), "PGSERVICE") {
		t.Errorf("PGSERVICE set: %v", err)
	}
}

// TestConnFromDSNKeepsSQLServerOptions: an ADO string's options travel as a URL's do (msdsn's own defaults do not).
func TestConnFromDSNKeepsSQLServerOptions(t *testing.T) {
	c, err := connFromDSN(config.EngineSQLServer, "server=s1;user id=u;password=p;TrustServerCertificate=true;encrypt=true")
	if err != nil {
		t.Fatal(err)
	}
	extra := strings.ToLower(c.Extra)
	if !strings.Contains(extra, "trustservercertificate=true") || !strings.Contains(extra, "encrypt=true") {
		t.Errorf("an ADO string's options: %q, want both kept", c.Extra)
	}
}

// TestPlatformRefusal: the engine's own platform words, as pgvigil.yaml takes them.
func TestPlatformRefusal(t *testing.T) {
	for _, c := range []struct {
		engine, platform string
		ok               bool
	}{
		{config.EngineSQLServer, "aurora", false}, {config.EnginePostgres, "rdss", false}, {config.EnginePostgres, "aurora", true},
		{config.EngineSQLServer, "azuresqlmi", true}, {config.EnginePostgres, "auto", true},
	} {
		if why := config.PlatformRefusal(c.engine, c.platform); (why == "") != c.ok {
			t.Errorf("%s %s: %q, want taken %v", c.engine, c.platform, why, c.ok)
		}
	}
}

// TestSplitTags: -tag splits on white space, as the page's field.
func TestSplitTags(t *testing.T) {
	if got := strings.Join(splitTags([]string{"env prod", "team"}), ","); got != "env,prod,team" {
		t.Errorf("%q", got)
	}
}

// TestOSAccountNotFromUSER: on Linux the audit's account comes from the uid, never from $USER.
func TestOSAccountNotFromUSER(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux reads the uid")
	}
	t.Setenv("USER", "planted-by-the-command-line")
	if a := osAccount(); strings.Contains(a, "planted-by-the-command-line") {
		t.Errorf("osAccount %q took $USER", a)
	}
}
