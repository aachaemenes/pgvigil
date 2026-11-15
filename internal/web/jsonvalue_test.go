package web

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestPgCellJSONValues: a custom report's cell (pgCell, q_customreports.go) has a JSON form for a float4 NaN or
// +/-Infinity (returned as it came, json.Marshal refused the whole reply) and inside an array or a composite (not
// walked: an infinity went out as 1, a NaN refused the reply); a finite float4 stays a number.
func TestPgCellJSONValues(t *testing.T) {
	cells := []any{
		pgCell(float32(math.NaN()), pgtype.Float4OID), pgCell(float32(math.Inf(-1)), pgtype.Float4OID), pgCell(float32(1.5), pgtype.Float4OID),
		pgCell([]any{pgtype.Infinity, math.NaN(), int64(3)}, 0), pgCell(map[string]any{"a": pgtype.NegativeInfinity}, 0),
	}
	b, err := json.Marshal(cells)
	if err != nil {
		t.Fatalf("the cells do not marshal (the whole reply would fail): %v", err)
	}
	if want := `["NaN","-Inf",1.5,["infinity","NaN",3],{"a":"-infinity"}]`; string(b) != want {
		t.Errorf("pgCell JSON\n got %s\nwant %s", b, want)
	}
}

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
