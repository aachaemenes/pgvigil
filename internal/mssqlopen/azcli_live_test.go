package mssqlopen

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// TestAzCliLive (RELNOTES L173's live leg, the B2 lab's pool leg on this laptop): a real Azure SQL Database signs the
// az CLI's account in through fedauth=ActiveDirectoryAzCli - the lab makes that account the server's Entra admin.
// Skipped without PGVIGIL_AZCLI_DSN; PGVIGIL_AZCLI_UPN, when set, is the login the server must report. The login is
// compared, never printed.
func TestAzCliLive(t *testing.T) {
	dsn, want := os.Getenv("PGVIGIL_AZCLI_DSN"), os.Getenv("PGVIGIL_AZCLI_UPN")
	if dsn == "" {
		t.Skip("PGVIGIL_AZCLI_DSN not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	db, err := Open(dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = db.Close() }()
	var who, dbName string
	if err := db.QueryRowContext(ctx, "SELECT SUSER_SNAME(), DB_NAME()").Scan(&who, &dbName); err != nil {
		t.Fatalf("the az sign-in: %v", err)
	}
	same := want == "" || strings.EqualFold(who, want)
	if want == "" {
		t.Logf("signed in through the az CLI's account to %s; the login not compared (PGVIGIL_AZCLI_UPN not set)", dbName)
	} else {
		t.Logf("signed in through the az CLI's account to %s; the login is that account: %v", dbName, same)
	}
	if !same {
		t.Errorf("the server reports another login than the az CLI's account")
	}
}
