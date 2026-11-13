package repo

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestRemoveRaceHeldInactive: a page instance never read is removed while a first read of it is in flight. The
// remove deletes its row (0122, the join's w9e finding 1); the read's ensure_instance insert waits for the remove's
// commit and then goes in held inactive, never active under a name the page no longer lists (the fold's review,
// finding 1: without the name's lock the insert that waited on the deleted row went in active). Needs a migrated
// repository and its owner: PGVIGIL_REPO_TEST_DSN (skipped without it).
func TestRemoveRaceHeldInactive(t *testing.T) {
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
	name := fmt.Sprintf("race-%d", time.Now().UnixNano()%1000000000)
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.instances WHERE name = $1`, `DELETE FROM pgvigil.admin_instances WHERE name = $1`, `DELETE FROM pgvigil.admin_removed WHERE name = $1`} {
			if _, err := pool.Exec(context.Background(), q, name); err != nil {
				t.Error(err)
			}
		}
	}()
	call := func(q pgxQuerier, payload string) string {
		var out string
		if err := q.QueryRow(ctx, `SELECT pgvigil.import_admin_instance(now(), $1::jsonb)->>'outcome'`, payload).Scan(&out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	add := fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"engine":"postgres","dsn_ref":"file:/x/%s.dsn","host":"127.0.0.1","auth":"password"}`, name, name)
	if got := call(pool, add); got != "done" {
		t.Fatalf("add: %s", got)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if got := call(tx, fmt.Sprintf(`{"op":"remove","ui_user":"test","name":%q}`, name)); got != "done" {
		t.Fatalf("remove: %s", got)
	}
	done := make(chan error, 1)
	go func() {
		_, err := pool.Exec(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.4', 160004, false, '{}'::text[], 'postgres')`, name)
		done <- err
	}()
	select {
	case err := <-done:
		t.Fatalf("the read's ensure_instance did not wait for the open remove: %v", err)
	case <-time.After(700 * time.Millisecond):
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal("ensure_instance after the remove: ", err)
	}
	var active bool
	var version string
	if err := pool.QueryRow(ctx, `SELECT is_active, coalesce(server_version, '') FROM pgvigil.instances WHERE name = $1`, name).Scan(&active, &version); err != nil {
		t.Fatal(err)
	}
	if active || version != "16.4" {
		t.Fatalf("after a remove and a read in flight: is_active %t, version %q (want false, 16.4: held inactive)", active, version)
	}
}

// pgxQuerier is a pool or a transaction
type pgxQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}
