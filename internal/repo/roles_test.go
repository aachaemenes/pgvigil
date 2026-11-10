package repo

import (
	"context"
	"os"
	"regexp"
	"sort"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestCollectorMayCallWhatRepoCalls: every pgvigil function this package's collector-side code calls must be
// executable by pgvigil_collector (apply_roles decides by name; a function outside its lists is the reader's only,
// and the collection that needs it then fails on every run under the collector login). Needs a migrated repository:
// PGVIGIL_REPO_TEST_DSN (skipped without it).
func TestCollectorMayCallWhatRepoCalls(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	src, err := os.ReadFile("repo.go")
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, m := range regexp.MustCompile(`pgvigil\.([a-z_0-9]+)\(`).FindAllStringSubmatch(string(src), -1) {
		seen[m[1]] = true
	}
	// the owner's own calls (migrate, purge) are not the collector's
	for _, n := range []string{"apply_roles", "purge"} {
		delete(seen, n)
	}
	names := make([]string, 0, len(seen))
	for n := range seen {
		names = append(names, n)
	}
	sort.Strings(names)
	if len(names) < 5 {
		t.Fatalf("only %d function names found in repo.go: the pattern no longer matches", len(names))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	for _, n := range names {
		var total, allowed int
		err := conn.QueryRow(ctx, `SELECT count(*), count(*) FILTER (WHERE has_function_privilege('pgvigil_collector', p.oid, 'EXECUTE'))
		                             FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'pgvigil' AND p.proname = $1`, n).Scan(&total, &allowed)
		if err != nil {
			t.Fatal(err)
		}
		if total == 0 {
			continue // a table or view of that name read with a call-like text; not a function
		}
		if allowed != total {
			t.Errorf("pgvigil.%s: pgvigil_collector may execute %d of its %d form(s)", n, allowed, total)
		}
	}
}
