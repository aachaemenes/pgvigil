package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): import_admin_file_test (migration 0261, the
// ServiceConfig takes' ST1) keeps the last connection test of an instance of pgvigil.yaml by its name and audits it as
// the page's own tests are; it refuses a name the file does not list and a name the page owns, keeps the newer of two
// tests (an older one is audited, answered 'not kept'), and prunes nothing (another serve's file may name other rows).
func TestAdminFileTestsOnAStore(t *testing.T) {
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
	tag := time.Now().UnixNano() % 1000000000
	name := func(s string) string { return fmt.Sprintf("ftest-%s-%d", s, tag) }
	user := fmt.Sprintf("ftest-user-%d", tag)
	defer func() {
		for _, q := range []string{
			`DELETE FROM pgvigil.admin_file_tests WHERE name LIKE $1`, `DELETE FROM pgvigil.admin_instances WHERE name LIKE $1`,
		} {
			if _, err := pool.Exec(context.Background(), q, fmt.Sprintf("ftest-%%-%d", tag)); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_audit WHERE ui_user = $1`, user); err != nil {
			t.Error(err)
		}
	}()
	one := func(q string, args ...any) string {
		t.Helper()
		var s *string
		if err := pool.QueryRow(ctx, q, args...).Scan(&s); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		if s == nil {
			return "<nil>"
		}
		return *s
	}
	// call sends one test's result and answers the import's outcome and detail
	call := func(at time.Time, target string, ok any, detail string, names []string) string {
		t.Helper()
		pay := map[string]any{"ui_user": user, "client": "192.0.2.7", "name": target, "ok": ok, "detail": detail}
		if names != nil {
			pay["file_names"] = names
		}
		b, err := json.Marshal(pay)
		if err != nil {
			t.Fatal(err)
		}
		return one(`SELECT (r->>'outcome') || '|' || (r->>'detail') FROM pgvigil.import_admin_file_test($1, $2::jsonb) r`, at, string(b))
	}
	now := time.Now().UTC().Truncate(time.Second)
	a, b, p, gone := name("a"), name("b"), name("page"), name("gone")
	names := []string{a, b, p, gone}

	// a connected test, then a failed one of another instance: one row each, audited as the page's tests are
	if got := call(now, a, true, "connected: PostgreSQL 17.2, as pgvigil_monitor", names); got != "done|tested "+a {
		t.Errorf("a connected: %s", got)
	}
	if got := call(now, b, false, "dial tcp 192.0.2.9:5432: connect: connection refused", names); got != "done|tested "+b {
		t.Errorf("b failed: %s", got)
	}
	if got := call(now, gone, true, "connected", names); got != "done|tested "+gone {
		t.Errorf("gone connected: %s", got)
	}
	if got := one(`SELECT string_agg(name || ' ' || tested_ok::text || ' ' || tested_by, ', ' ORDER BY name) FROM pgvigil.admin_file_tests WHERE name LIKE $1`,
		fmt.Sprintf("ftest-%%-%d", tag)); got != fmt.Sprintf("%s true %s, %s false %s, %s true %s", a, user, b, user, gone, user) {
		t.Errorf("the rows: %s", got)
	}
	if got := one(`SELECT string_agg(op || '|' || outcome || '|' || detail, ' ;; ' ORDER BY audit_id) FROM pgvigil.admin_audit WHERE ui_user = $1 AND target IN ($2, $3)`, user, a, b); got != "instance tested|done|connected ;; instance tested|done|failed: dial tcp 192.0.2.9:5432: connect: connection refused" {
		t.Errorf("the audit: %s", got)
	}

	// refusals: a name the file does not list; no list at all; a name the page owns; no result
	if got := call(now, name("other"), true, "connected", names); got != "refused|not an instance of pgvigil.yaml" {
		t.Errorf("an unlisted name: %s", got)
	}
	if got := call(now, a, true, "connected", nil); got != "refused|file_names must list the instances of pgvigil.yaml" {
		t.Errorf("no file_names: %s", got)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.admin_instances (name, engine, dsn_ref, auth, host, created_by, updated_by)
	                             VALUES ($1, 'postgres', 'file:/nonexistent/ftest', 'password', '192.0.2.8', $2, $2)`, p, user); err != nil {
		t.Fatal(err)
	}
	if got := call(now, p, true, "connected", names); got != "refused|an instance added in the page: its test is kept on its own row" {
		t.Errorf("a page instance's name: %s", got)
	}
	if got := call(now, a, nil, "connected", names); got != "refused|ok must be true or false" {
		t.Errorf("no ok: %s", got)
	}
	if got := one(`SELECT count(*)::text FROM pgvigil.admin_audit WHERE ui_user = $1 AND outcome = 'refused' AND op = 'instance tested'`, user); got != "4" {
		t.Errorf("refused audit rows: %s, want 4", got)
	}
	if got := one(`SELECT count(*)::text FROM pgvigil.admin_file_tests WHERE name = $1`, p); got != "0" {
		t.Errorf("the page instance got a file test row: %s", got)
	}

	// the newer test wins: a late answer of an older test changes nothing, a newer one replaces
	if got := call(now.Add(-time.Minute), a, false, "an older test, answered late", names); got != "done|not kept: a newer test of "+a+" is stored" {
		t.Errorf("an older test: %s", got)
	}
	if got := one(`SELECT tested_ok::text || '|' || tested_detail FROM pgvigil.admin_file_tests WHERE name = $1`, a); got != "true|connected: PostgreSQL 17.2, as pgvigil_monitor" {
		t.Errorf("after an older test: %s", got)
	}
	if got := call(now.Add(time.Minute), a, false, "timeout: context deadline exceeded", names); got != "done|tested "+a {
		t.Errorf("a newer test: %s", got)
	}
	if got := one(`SELECT tested_ok::text || '|' || tested_detail FROM pgvigil.admin_file_tests WHERE name = $1`, a); got != "false|timeout: context deadline exceeded" {
		t.Errorf("after a newer test: %s", got)
	}

	// a test with a file that no longer lists a name (another serve's, or a later one) leaves that name's row alone
	if got := call(now.Add(2*time.Minute), b, true, "connected", []string{a, b, p}); got != "done|tested "+b {
		t.Errorf("b again: %s", got)
	}
	if got := one(`SELECT string_agg(name, ', ' ORDER BY name) FROM pgvigil.admin_file_tests WHERE name LIKE $1`, fmt.Sprintf("ftest-%%-%d", tag)); got != a+", "+b+", "+gone {
		t.Errorf("after a file without a name: %s (want %s, %s, %s: nothing pruned)", got, a, b, gone)
	}
	if got := one(`SELECT detail FROM pgvigil.admin_audit WHERE ui_user = $1 AND target = $2 ORDER BY audit_id DESC LIMIT 1 OFFSET 1`, user, a); got != "failed: an older test, answered late (not kept: a newer test is stored)" {
		t.Errorf("the older test's audit row: %s", got)
	}
}
