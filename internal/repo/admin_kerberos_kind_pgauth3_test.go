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

// TestPageKerberosKindOnAStorePGAUTH3 (pgauth3 B1, migration 0488): Admin > Instances stores a PostgreSQL instance of
// the 'kerberos' kind - the role and the host, no secret (the collector's host holds the keytab or the cache and
// krb5.conf) - and refuses a SQL Server instance of that kind in words; the table's check refuses such a row too.
// Before 0488 the store refused the kind outright ('auth is sql, windows, ... password or pgpass').
func TestPageKerberosKindOnAStorePGAUTH3(t *testing.T) {
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
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	sfx := time.Now().UnixNano() % 1000000000
	pg, ms := fmt.Sprintf("pgk-%d", sfx), fmt.Sprintf("msk-%d", sfx)
	call := func(payload string) (string, string) {
		t.Helper()
		var out, detail string
		if err := tx.QueryRow(ctx, `SELECT a->>'outcome', coalesce(a->>'detail', '') FROM pgvigil.import_admin_instance(now(), $1::jsonb) a`, payload).Scan(&out, &detail); err != nil {
			t.Fatal(err)
		}
		return out, detail
	}
	if out, d := call(fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"engine":"postgres","platform":"auto","dsn_ref":"file:/x/%s.dsn","host":"ad1.example.com","auth":"kerberos"}`, pg, pg)); out != "done" {
		t.Fatalf("a PostgreSQL instance of the kerberos kind: %s %q, want done", out, d)
	}
	var auth string
	if err := tx.QueryRow(ctx, `SELECT auth FROM pgvigil.admin_instances WHERE name = $1`, pg).Scan(&auth); err != nil || auth != "kerberos" {
		t.Errorf("the stored kind: %q (%v), want kerberos", auth, err)
	}
	if out, d := call(fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"engine":"sqlserver","platform":"auto","dsn_ref":"file:/x/%s.dsn","host":"sql1.example.com","auth":"kerberos"}`, ms, ms)); out != "refused" || !strings.Contains(d, "is not one of the sqlserver engine's") {
		t.Errorf("a SQL Server instance of the kerberos kind: %s %q, want refused naming the engine's kinds", out, d)
	}
	// the table's own check: a kerberos row turned into a SQL Server one is refused (23514)
	if _, err := tx.Exec(ctx, `SAVEPOINT s`); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `UPDATE pgvigil.admin_instances SET engine = 'sqlserver' WHERE name = $1`, pg); err == nil || !strings.Contains(err.Error(), "admin_instances_auth_check") {
		t.Errorf("a kerberos row made a SQL Server one: %v, want the auth check's refusal", err)
	}
	if _, err := tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); err != nil {
		t.Fatal(err)
	}
}
