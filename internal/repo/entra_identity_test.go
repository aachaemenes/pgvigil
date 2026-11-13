package repo

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// 0127 re-creates import_admin_instance to take auth entra-identity (CLOUDSQL C1). The function must stay 0122's in
// every other line: an edit of 0122's function in place (allowed before a release) that 0127 does not carry would be
// undone on every store, since 0127 runs after 0122. With its three entra-identity changes taken back out, 0127's
// function is 0122's, character for character.
func TestAdmin0127IsAdmin0122PlusEntraIdentity(t *testing.T) {
	body := func(file string) string {
		t.Helper()
		b, err := migrations.ReadFile("sql/" + file)
		if err != nil {
			t.Fatal(err)
		}
		s := string(b)
		i := strings.Index(s, "CREATE OR REPLACE FUNCTION pgvigil.import_admin_instance(")
		if i < 0 {
			t.Fatalf("%s: no import_admin_instance", file)
		}
		j := strings.Index(s[i:], "END $$;")
		if j < 0 {
			t.Fatalf("%s: import_admin_instance has no end", file)
		}
		return s[i : i+j]
	}
	got := body("0127_entra_identity.sql")
	for _, c := range []struct{ now, was string }{
		{"('sql', 'windows', 'entra', 'entra-identity', 'password', 'pgpass')", "('sql', 'windows', 'entra', 'password', 'pgpass')"},
		{"'auth is sql, windows, entra or entra-identity (SQL Server), password or pgpass (PostgreSQL)'", "'auth is sql, windows or entra (SQL Server), password or pgpass (PostgreSQL)'"},
		{"('sql', 'windows', 'entra', 'entra-identity')))", "('sql', 'windows', 'entra')))"},
	} {
		if strings.Count(got, c.now) != 1 {
			t.Fatalf("0127's import_admin_instance holds %q %d times, want once", c.now, strings.Count(got, c.now))
		}
		got = strings.Replace(got, c.now, c.was, 1)
	}
	if want := body("0122_instances_admin.sql"); got != want {
		gl, wl := strings.Split(got, "\n"), strings.Split(want, "\n")
		for k := 0; k < len(gl) && k < len(wl); k++ {
			if gl[k] != wl[k] {
				t.Fatalf("0127's import_admin_instance differs from 0122's beyond entra-identity at its line %d:\n0127: %s\n0122: %s", k+1, gl[k], wl[k])
			}
		}
		t.Fatalf("0127's import_admin_instance has %d lines, 0122's %d", len(gl), len(wl))
	}
}

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): 0127 replaced 0122's auth CHECK (one CHECK on
// admin_instances.auth, taking entra-identity), and import_admin_instance adds a SQL Server with auth entra-identity
// and refuses it for PostgreSQL in its own words.
func TestEntraIdentityOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var checks int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pg_constraint WHERE conrelid = 'pgvigil.admin_instances'::regclass AND contype = 'c'
	                                AND pg_get_constraintdef(oid) LIKE '%auth%'`).Scan(&checks); err != nil {
		t.Fatal(err)
	}
	if checks != 1 {
		t.Fatalf("admin_instances has %d CHECKs on auth, want 1 (0127's)", checks)
	}
	name := fmt.Sprintf("mi-%d", time.Now().UnixNano()%1000000000)
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.instances WHERE name = $1`, `DELETE FROM pgvigil.admin_instances WHERE name = $1`} {
			if _, err := pool.Exec(context.Background(), q, name); err != nil {
				t.Error(err)
			}
		}
	}()
	call := func(engine string) (string, string) {
		var outcome, detail string
		payload := fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"engine":%q,"dsn_ref":"file:/x/%s.dsn","host":"srv1.database.windows.net","auth":"entra-identity"}`, name, engine, name)
		if err := pool.QueryRow(ctx, `SELECT r->>'outcome', r->>'detail' FROM pgvigil.import_admin_instance(now(), $1::jsonb) AS t(r)`, payload).Scan(&outcome, &detail); err != nil {
			t.Fatal(err)
		}
		return outcome, detail
	}
	if o, d := call("postgres"); o != "refused" || d != "auth entra-identity is not one of the postgres engine's" {
		t.Fatalf("entra-identity for PostgreSQL: %s %q", o, d)
	}
	if o, d := call("sqlserver"); o != "done" {
		t.Fatalf("entra-identity for SQL Server: %s %q", o, d)
	}
	var auth string
	if err := pool.QueryRow(ctx, `SELECT auth FROM pgvigil.admin_instances WHERE name = $1`, name).Scan(&auth); err != nil || auth != "entra-identity" {
		t.Fatalf("the row's auth %q, %v", auth, err)
	}
}
