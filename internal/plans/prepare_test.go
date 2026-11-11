package plans

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// The second layer under ScanSQL: prepareOne sends the text over the extended protocol, so the server itself takes one
// statement. A text of several - which ScanSQL may misread - is refused, the read-only transaction is still the one it
// was (its rollback works) and nothing was created. PGVIGIL_REPO_DSN names a PostgreSQL to run against; skipped
// without it.
func TestPrepareOneStatement(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_DSN not set")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		t.Fatal(err)
	}
	text := "SELECT $1::int; COMMIT; CREATE TABLE pgvigil_prepare_one_pwn ()"
	err = prepareOne(ctx, tx, "pgvigil_prepare_one", text)
	if err == nil || !strings.Contains(err.Error(), "cannot insert multiple commands into a prepared statement") {
		t.Fatalf("a text of three statements: %v", err)
	}
	if err := tx.Rollback(ctx); err != nil {
		t.Fatalf("the transaction after the refusal: %v", err)
	}
	var n int
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM pg_class WHERE relname = 'pgvigil_prepare_one_pwn'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("the table was made (%d) or the read failed: %v", n, err)
	}
	// one statement still prepares
	tx, err = conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := prepareOne(ctx, tx, "pgvigil_prepare_one", "SELECT $1::int"); err != nil {
		t.Fatalf("one statement: %v", err)
	}
}
