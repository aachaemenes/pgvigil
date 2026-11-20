package repo

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestFindingsValueCollation (a lab run: 0190 failed on a fresh store with 42P16): a findings
// arm's value built from a catalog name (relname, nspname: type name, collation "C") carries COLLATE "default", or
// pgvigil.findings - its value text with the default collation since 0110 - cannot be re-created over it. 0166's lines
// only: a line rule over every file cannot tell a catalog name from pgvigil's own text columns of the same names
// (a.rolname, d.datname copied as text) - TestViewsValueCollationOnAStore is the guard for every view
func TestFindingsValueCollation(t *testing.T) {
	b, err := os.ReadFile("sql/0166_collection_health.sql")
	if err != nil {
		t.Fatal(err)
	}
	for i, l := range strings.Split(string(b), "\n") {
		if strings.Contains(l, "AS value") && (strings.Contains(l, "relname") || strings.Contains(l, "nspname")) && !strings.Contains(l, `COLLATE "default"`) {
			t.Errorf("0166 L%d builds value from a catalog name without COLLATE \"default\": %s", i+1, strings.TrimSpace(l))
		}
	}
}

// TestViewsValueCollationOnAStore: on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped
// without it) no view of the pgvigil schema has a value column whose collation is not the default - a catalog name
// (type name, collation "C") left uncast in an arm stops the next CREATE OR REPLACE of pgvigil.findings with 42P16 (a
// lab run), at the migration that adds the arm if not before; whatever file the arm is in and whatever name it reads
func TestViewsValueCollationOnAStore(t *testing.T) {
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
	rows, err := pool.Query(ctx, `SELECT c.relname::text, coalesce(co.collname::text, a.attcollation::text)
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_collation co ON co.oid = a.attcollation
 WHERE n.nspname = 'pgvigil' AND c.relkind IN ('v', 'm') AND a.attname = 'value' AND NOT a.attisdropped
   AND a.attcollation <> 0 AND a.attcollation <> 'pg_catalog.default'::regcollation
 ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	views := 0
	for rows.Next() {
		var view, coll string
		if err := rows.Scan(&view, &coll); err != nil {
			t.Fatal(err)
		}
		views++
		t.Errorf("the view pgvigil.%s has a value column collated %q, not the default: cast it (::text COLLATE \"default\") before an arm of pgvigil.findings reads it", view, coll)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'pgvigil' AND c.relkind = 'v' AND a.attname = 'value' AND NOT a.attisdropped`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n < 10 {
		t.Errorf("%d pgvigil views have a value column, want 10 or more (the findings arms): is this a migrated repository?", n)
	}
	t.Logf("%d pgvigil views with a value column, %d of them not collated by default", n, views)
}
