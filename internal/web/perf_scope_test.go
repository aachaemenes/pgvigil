package web

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestPerfScopeOnAStore (TAGTREE): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it) the tag scope
// of /api/perfsummary (sqlPerfScope) holds the instances the pages' own rule holds (web/src/fleet.ts inTagScope): a
// written tag exactly; 'untagged' = no tag at all; '<key>:' with no value = no value of that key (the tree's '(no <key>)'
// folder), a key read without regard to case, a plain word's key being 'tag'; NULL = every instance.
func TestPerfScopeOnAStore(t *testing.T) {
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
	sfx := time.Now().UnixNano() % 1000000000
	tags := map[string][]string{
		"a": {"env:prod", "team:x"},
		"b": {"env:staging"},
		"c": {"team:y"},
		"d": {},
		"e": {"prodbox"},
	}
	var ids []int
	for _, n := range []string{"a", "b", "c", "d", "e"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.2', 170002, false, $2::text[], 'postgres')`,
			fmt.Sprintf("perfscope-%s-%d", n, sfx), tags[n]).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`, ids); err != nil {
			t.Error(err)
		}
	}()
	// $1 and $2 (the window) are unused by the scope itself: typed here so the statement prepares
	q := sqlPerfScope + ` SELECT string_agg(split_part(instance, '-', 2), '' ORDER BY instance) FROM inst
	 WHERE $1::text IS NULL AND $2::text IS NULL AND instance LIKE $5`
	for _, c := range []struct {
		scope any
		want  string
	}{
		{nil, "abcde"},
		{"env:prod", "a"},
		{"untagged", "d"},
		{"env:", "cde"},
		{"ENV:", "cde"},
		{"team:", "bde"},
		{"tag:", "abcd"},
		{"prodbox", "e"},
	} {
		var got *string
		if err := pool.QueryRow(ctx, q, nil, nil, "postgres", c.scope, fmt.Sprintf("perfscope-%%-%d", sfx)).Scan(&got); err != nil {
			t.Fatalf("scope %v: %v", c.scope, err)
		}
		g := ""
		if got != nil {
			g = *got
		}
		if g != c.want {
			t.Errorf("scope %v: instances %q, want %q", c.scope, strings.Split(g, ""), strings.Split(c.want, ""))
		}
	}
}
