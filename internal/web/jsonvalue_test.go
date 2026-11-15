package web

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestQueryJSONValues: a page's table read through Server.query hands the browser PostgreSQL's own text for a
// timestamptz, timestamp or date of +/-infinity (pgx v5 decodes it to a pgtype.InfinityModifier, JSON 1 / -1: the
// Roles page then read rdsadmin's 'password valid until' as 2001-01-01, expired) and for a float NaN or +/-Infinity
// (no JSON form: json.Marshal refused the whole reply), inside arrays too; queryTx (the perf summary's parts) the same.
// PGVIGIL_REPO_TEST_DSN names any PostgreSQL; skipped without it.
func TestQueryJSONValues(t *testing.T) {
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
	const q = `SELECT 'infinity'::timestamptz AS a, '-infinity'::timestamp AS b, 'infinity'::date AS c,
	                  ARRAY['-infinity'::timestamptz] AS d, 'NaN'::float8 AS e, '-Infinity'::float4 AS f, 2::int AS g`
	const want = `{"columns":["a","b","c","d","e","f","g"],"rows":[["infinity","-infinity","infinity",["-infinity"],"NaN","-Infinity",2]]}`
	s := &Server{pool: pool, log: discardLog()}
	tb, err := s.query(ctx, q)
	if err != nil {
		t.Fatal(err)
	}
	if b, err := json.Marshal(tb); err != nil {
		t.Errorf("query: the table does not marshal (the whole reply would fail): %v", err)
	} else if string(b) != want {
		t.Errorf("query JSON\n got %s\nwant %s", b, want)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	tb, err = queryTx(ctx, tx, q)
	if err != nil {
		t.Fatal(err)
	}
	if b, err := json.Marshal(tb); err != nil {
		t.Errorf("queryTx: the table does not marshal (the whole reply would fail): %v", err)
	} else if string(b) != want {
		t.Errorf("queryTx JSON\n got %s\nwant %s", b, want)
	}
}
