package web

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestOverviewCollectionFailingDontMonitorOnAStore (B6g-2 DONT-MONITOR (a); a box row:
// PGVIGIL_REPO_TEST_DSN): the overview's daily check 'collection failing' leaves out a collection its Collection Health
// threshold sets Don't monitor - as 0121's finding arm does - and lists it again under a level that monitors it. One
// transaction rolled back: a threshold over every instance would reach the other packages' store rows.
func TestOverviewCollectionFailingDontMonitorOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	stmt := ""
	for _, c := range overviewChecks {
		if c.name == "collection failing" {
			stmt = c.sql
		}
	}
	if stmt == "" {
		t.Fatal("no overview check named 'collection failing'")
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
	tag := time.Now().UnixNano() % 1000000000
	coll := fmt.Sprintf("odm%d", tag)
	var id int32
	if err := tx.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("odm-%d", tag)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, duration_ms, status, note)
	                           VALUES ($1, $2, now(), 10, 'error', 'proof: boom')`, id, coll); err != nil {
		t.Fatal(err)
	}
	listed := func() int {
		t.Helper()
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM (`+stmt+"\n"+`) c WHERE c.instance_id = $2 AND c.object = $3`, "{}", id, coll).Scan(&n); err != nil {
			t.Fatalf("the overview check: %v", err)
		}
		return n
	}
	set := func(pay string) {
		t.Helper()
		var out string
		if err := tx.QueryRow(ctx, `SELECT pgvigil.import_collection_health_threshold(now(), $1::jsonb)->>'outcome'`, pay).Scan(&out); err != nil || out != "done" {
			t.Fatalf("%s: outcome %q, %v", pay, out, err)
		}
	}
	if n := listed(); n != 1 {
		t.Fatalf("before any threshold: %d row(s), want 1", n)
	}
	set(fmt.Sprintf(`{"op": "set", "collection": %q, "dont_monitor": true, "ui_user": "t"}`, coll))
	if n := listed(); n != 0 {
		t.Errorf("the collection set Don't monitor on every instance: %d row(s), want 0", n)
	}
	set(fmt.Sprintf(`{"op": "set", "instance_id": %d, "collection": %q, "dont_monitor": false, "ui_user": "t"}`, id, coll))
	if n := listed(); n != 1 {
		t.Errorf("the instance's own level monitors it again: %d row(s), want 1", n)
	}
}
