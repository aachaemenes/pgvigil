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

// TestCHThresholdsReadOnAStore (B6g-2, N33 / N41; a box row: PGVIGIL_REPO_TEST_DSN): the thresholds dialog's read - the
// live rows of the four 'Apply to' levels of one instance's collection (this instance and collection, this instance and
// every collection, this collection on every instance, everything), DBA Dash's CollectionHealthThresholds_Get reads
// them for its 'Inherited:' values. Another instance's row and an ended row are never among them. Everything runs in one
// transaction rolled back: a row over every instance would reach the other packages' store rows on the same store.
func TestCHThresholdsReadOnAStore(t *testing.T) {
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
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	tag := time.Now().UnixNano() % 1000000000
	coll := fmt.Sprintf("chth%d", tag)
	ids := map[string]int32{}
	for _, key := range []string{"a", "b"} {
		var id int32
		if err := tx.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`,
			fmt.Sprintf("chth-%s-%d", key, tag)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[key] = id
	}
	set := func(pay string) {
		t.Helper()
		var out string
		if err := tx.QueryRow(ctx, `SELECT pgvigil.import_collection_health_threshold(now(), $1::jsonb)->>'outcome'`, pay).Scan(&out); err != nil {
			t.Fatalf("%s: %v", pay, err)
		}
		if out != "done" {
			t.Fatalf("%s: outcome %q, want done", pay, out)
		}
	}
	a, b := ids["a"], ids["b"]
	set(fmt.Sprintf(`{"op": "set", "instance_id": %d, "collection": %q, "warn_fails_in_row": 2, "ui_user": "t"}`, a, coll))
	set(fmt.Sprintf(`{"op": "set", "instance_id": %d, "collection": %q, "warn_fails_in_row": 3, "ui_user": "t"}`, a, coll)) // ends the row above
	set(fmt.Sprintf(`{"op": "set", "instance_id": %d, "warn_fail_minutes": 20, "ui_user": "t"}`, a))
	set(fmt.Sprintf(`{"op": "set", "collection": %q, "crit_fail_pct": 40, "ui_user": "t"}`, coll))
	set(`{"op": "set", "min_runs": 6, "ui_user": "t"}`)
	set(fmt.Sprintf(`{"op": "set", "instance_id": %d, "collection": %q, "warn_fails_in_row": 5, "ui_user": "t"}`, b, coll)) // another instance's
	read := func(id int32, c string) string {
		t.Helper()
		rows, err := tx.Query(ctx, `SELECT concat_ws('|', CASE WHEN r.instance_id IS NULL THEN '*' WHEN r.instance_id = $3 THEN 'a' ELSE 'other' END,
		           CASE WHEN r.collection IS NULL THEN '*' WHEN r.collection = $4 THEN 'c' ELSE r.collection END,
		           coalesce(r.warn_fails_in_row::text, '-'), coalesce(r.warn_fail_minutes::text, '-'), coalesce(r.crit_fail_pct::text, '-'),
		           coalesce(r.min_runs::text, '-'), coalesce(r.dont_monitor::text, '-'))
		      FROM (`+sqlCHThresholds+"\n"+`) r`, id, c, a, coll)
		if err != nil {
			t.Fatalf("the dialog's read: %v", err)
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			var v string
			if err := rows.Scan(&v); err != nil {
				t.Fatal(err)
			}
			out = append(out, v)
		}
		if err := rows.Err(); err != nil {
			t.Fatalf("the dialog's read: %v", err)
		}
		return strings.Join(out, " ; ")
	}
	// the four levels in DBA Dash's order, the live row of each only; b's row not among them
	if got, want := read(a, coll), "a|c|3|-|-|-|- ; a|*|-|20|-|-|- ; *|c|-|-|40.00|-|- ; *|*|-|-|-|6|-"; got != want {
		t.Errorf("instance a's collection: got %q, want %q", got, want)
	}
	// a row with no instance (the collection grain): this collection on every instance, everything
	if got, want := read(0, coll), "*|c|-|-|40.00|-|- ; *|*|-|-|-|6|-"; got != want {
		t.Errorf("the collection on every instance: got %q, want %q", got, want)
	}
	// every collection of instance a (no collection named): this instance and everything
	if got, want := read(a, ""), "a|*|-|20|-|-|- ; *|*|-|-|-|6|-"; got != want {
		t.Errorf("every collection of instance a: got %q, want %q", got, want)
	}
}
