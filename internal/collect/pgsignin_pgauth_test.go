package collect

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// TestPGSigninCollectorPGAUTH (PGAUTH M1, decision 2's finding): pg_signin reads, hourly on PostgreSQL 16 and later,
// how the server signed the read login in - SYSTEM_USER's method word (never its identity: under ldap the bind DN)
// and the session's own pg_stat_ssl row - and carries the sslmode of the instance's dsn (the collector's own config:
// the server cannot see it). Under 16 the method is not readable from the client: skipped in words.
func TestPGSigninCollectorPGAUTH(t *testing.T) {
	t.Setenv("PGSSLMODE", "")
	c := pgSigninCollector{}
	if c.Name() != "pg_signin" || c.DefaultInterval() != time.Hour {
		t.Errorf("name %q every %v, want pg_signin every 1h", c.Name(), c.DefaultInterval())
	}
	if ok, why := c.Applies(platform.Info{ServerVersionNum: 160004}); !ok {
		t.Errorf("PostgreSQL 16 skipped: %s", why)
	}
	if ok, why := c.Applies(platform.Info{ServerVersionNum: 150008}); ok || !strings.Contains(why, "PostgreSQL 16") {
		t.Errorf("PostgreSQL 15: Applies = %v %q, want a skip naming PostgreSQL 16", ok, why)
	}
	if _, err := c.Run(context.Background(), nil, platform.Info{ServerVersionNum: 160004}); !errors.Is(err, ErrSkip) {
		t.Errorf("Run without the instance's config: %v, want ErrSkip", err)
	}
	for _, s := range []string{"system_user", "pg_stat_ssl", "pg_backend_pid()"} {
		if !strings.Contains(pgSigninSQL, s) {
			t.Errorf("the read lacks %q", s)
		}
	}
	r := pgSigninRow("ldap:cn=pgvigil,ou=svc,dc=example,dc=com", true, "host=db1 user=pgvigil sslmode=require")
	if r["kind"] != "signin" || r["method"] != "ldap" || r["clear"] != true || r["ssl"] != true || r["sslmode"] != "require" {
		t.Errorf("the row %v: want kind signin, method ldap, clear true, ssl true, sslmode require", r)
	}
	for k, v := range r {
		if s, ok := v.(string); ok && strings.Contains(s, "cn=") {
			t.Errorf("the row carries the identity in %s: %q", k, s)
		}
	}
	if r := pgSigninRow("", false, "host=db1"); r["method"] != "" || r["clear"] != false || r["sslmode"] != "prefer" {
		t.Errorf("a trust sign-in (SYSTEM_USER NULL): %v, want no method, not clear, sslmode prefer", r)
	}
}
