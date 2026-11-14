package actions

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
)

// TestExplainAnalyzeLoginsOnAStore (REPORT ROLE, the lead 13:1x): EXPLAIN ANALYZE runs the DBA's statement through its
// own login (explain_dsn), and on a database that is a pgvigil repository that login is refused when it may read the
// UI's password hashes or become one who can. On a migrated repository (PGVIGIL_REPO_TEST_DSN, a superuser, keyword
// form; skipped without it) ExplainAnalyze itself is run with three explain logins: a member of pg_read_all_data and a
// NOINHERIT member of a superuser role are refused in words, nothing run; a login IN ROLE pgvigil_reader alone runs.
func TestExplainAnalyzeLoginsOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	if strings.Contains(dsn, "://") {
		t.Fatal("PGVIGIL_REPO_TEST_DSN must be in keyword form (host=... user=...)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	admin, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = admin.Close(context.Background()) }()
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	pw := "Ea" + hex.EncodeToString(b) // a throwaway login's password, unrelated to its name
	sfx := time.Now().UnixNano() % 1000000000
	name := func(k string) string { return fmt.Sprintf("pgvea_%s_%d", k, sfx) }
	roles := []struct{ key, make string }{
		{"su", "NOLOGIN SUPERUSER"},
		{"rd", "LOGIN IN ROLE pgvigil_reader"},
		{"rad", "LOGIN IN ROLE pg_read_all_data"},
		{"insu", "LOGIN NOINHERIT IN ROLE pgvigil_reader, " + name("su")},
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
	for _, c := range []struct{ key, want string }{ // want "" = done
		{"rd", ""},
		{"rad", "the explain login is a member of pg_read_all_data in a pgvigil repository"},
		{"insu", "the explain login is a member of a superuser role"},
	} {
		g := ExplainGate{Enabled: true, Configured: true, DSN: dsn + " user=" + name(c.key) + " password=" + pw, Timeout: 10 * time.Second}
		r := ExplainRequest{InstanceID: 1, Instance: "repo", Datname: cfg.Database, Statement: "SELECT 1",
			Reason: "the explain login's refusal on a repository, a store test", User: "proof"}
		res, _ := ExplainAnalyze(ctx, Door{Monitor: dsn}, g, r)
		switch {
		case c.want == "" && res.Outcome != Done:
			t.Errorf("%s: %s %q, want done", c.key, res.Outcome, res.Detail)
		case c.want != "" && (res.Outcome != Refused || !strings.Contains(res.Detail, c.want)):
			t.Errorf("%s: %s %q, want refused %q", c.key, res.Outcome, res.Detail, c.want)
		}
	}
}
