package collect

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestCustomRightsLogins (CUSTOMRIGHTS): the custom checks run the DBA's own SQL read-only, and
// customRights refuses, on the SESSION user, a login whose rights a read-only transaction does not stop. On a server
// where PGVIGIL_CUSTOM_TEST_SUPER_DSN (a superuser, keyword form) may make roles - skipped without it - a pg_monitor
// login runs; refused: a NOINHERIT member of a superuser role (one statement can SET ROLE to it) and a superuser that
// connects as a pg_monitor role (ALTER ROLE ... SET role: the check would read the role it started as, and the
// statement can set it back with set_config('role', 'none', true)).
func TestCustomRightsLogins(t *testing.T) {
	sdsn := os.Getenv("PGVIGIL_CUSTOM_TEST_SUPER_DSN")
	if sdsn == "" {
		t.Skip("PGVIGIL_CUSTOM_TEST_SUPER_DSN not set")
	}
	if strings.Contains(sdsn, "://") {
		t.Fatal("PGVIGIL_CUSTOM_TEST_SUPER_DSN must be in keyword form (host=... user=...)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	admin, err := pgx.Connect(ctx, sdsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = admin.Close(context.Background()) }()
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	pw := "Cr" + hex.EncodeToString(b) // a throwaway login's password, unrelated to its name
	sfx := time.Now().UnixNano() % 1000000000
	name := func(k string) string { return fmt.Sprintf("pgvcr_%s_%d", k, sfx) }
	roles := []struct{ key, make string }{
		{"su", "NOLOGIN SUPERUSER"},
		{"mon", "LOGIN IN ROLE pg_monitor"},
		{"insu", "LOGIN NOINHERIT IN ROLE pg_monitor, " + name("su")},
		{"suset", "LOGIN SUPERUSER"},
	}
	defer func() {
		for i := len(roles) - 1; i >= 0; i-- {
			if _, err := admin.Exec(context.Background(), `DROP ROLE IF EXISTS `+name(roles[i].key)); err != nil {
				t.Error(err)
			}
		}
	}()
	for _, r := range roles {
		if _, err := admin.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s PASSWORD '%s' %s`, name(r.key), pw, r.make)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := admin.Exec(ctx, `ALTER ROLE `+name("suset")+` SET role = `+name("mon")); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ key, want string }{ // want "" = runs
		{"mon", ""},
		{"insu", "a member of a superuser role"},
		{"suset", "superuser"},
	} {
		conn, err := Connect(ctx, config.Instance{Name: c.key, DSNRaw: sdsn + " user=" + name(c.key) + " password=" + pw})
		if err != nil {
			t.Fatalf("%s: %v", c.key, err)
		}
		got := customRights(ctx, conn)
		_ = conn.Close(context.Background())
		switch {
		case c.want == "" && got != nil:
			t.Errorf("%s: refused, want it to run: %v", c.key, got)
		case c.want != "" && (got == nil || !strings.Contains(got.Error(), "the login is "+c.want)):
			t.Errorf("%s: %v, want refused 'the login is %s'", c.key, got, c.want)
		}
	}
}
