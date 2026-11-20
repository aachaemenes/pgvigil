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

// TestCHRate24FollowsTheAckOnAStore (a box row: PGVIGIL_REPO_TEST_DSN): the Collection Health page as DBA Dash 4.25.0
// draws it after an acknowledgement of the collector errors - Failed % 24hrs counts from the acknowledgement's hour
// (CollectionHealth_Get.sql L154-169, L443), while Status, Failures In A Row, Runs and Failed stay the range's own (L232,
// L266) and the row says what the acknowledgement left out. One instance: two hours back 5 failed runs, then an
// acknowledgement on the hour, then 5 ok runs. Everything runs in one transaction rolled back.
func TestCHRate24FollowsTheAckOnAStore(t *testing.T) {
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
	name := fmt.Sprintf("chack24-%d", time.Now().UnixNano()%1000000000)
	var id int
	if err := tx.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`, name).Scan(&id); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`SELECT pgvigil.log_collection($1, 'c2', now() - interval '130 minutes', 10, 'error', 'c2 failed')`,
		`SELECT pgvigil.log_collection($1, 'c2', now() - interval '125 minutes', 10, 'error', 'c2 failed again')`,
		`SELECT pgvigil.log_collection($1, 'c2', now() - interval '1 minute', 10, 'ok', NULL)`,
	} {
		if _, err := tx.Exec(ctx, q, id); err != nil {
			t.Fatal(err)
		}
	}
	for _, h := range [][2]int{{2, 5}, {1, 0}} { // {hours back, failed of 5}
		if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collection_health('chack24-beat', jsonb_build_object('health', jsonb_build_array(jsonb_build_object(
		  'instance', $1::text, 'collection', 'c2', 'hour', date_trunc('hour', now()) - make_interval(hours => $2), 'runs', 5, 'ok', 5 - $3::int,
		  'partial', 0, 'error', $3::int, 'skipped', 0, 'rows', 0, 'dur_ms_sum', 50, 'dur_ms_max', 10, 'over_half', 0, 'over_interval', 0))))`,
			name, h[0], h[1]); err != nil {
			t.Fatal(err)
		}
	}
	type row struct {
		status, reason string
		runs, failed   int
		pct24          float64
	}
	read := func() row {
		t.Helper()
		var x row
		n := 0
		// sqlCHInstance's last line is a '--' comment (its ORDER BY's words): the subquery's ')' goes on a line of its own,
		// as collection_health_cost_store_test.go wraps sqlCHCollection - else ') q' is commented out (42601 at the end)
		rows, err := tx.Query(ctx, `SELECT q.status, coalesce(q.status_reason, ''), q.runs::int, q.failed::int, q.failed_pct_24h::float8 FROM (`+sqlCHInstance+"\n"+`) q`,
			time.Now().Add(-24*time.Hour), time.Now(), id, []int32(nil), "c2", []string(nil), "{}")
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		for rows.Next() {
			if err := rows.Scan(&x.status, &x.reason, &x.runs, &x.failed, &x.pct24); err != nil {
				t.Fatal(err)
			}
			n++
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		if n != 1 {
			t.Fatalf("%d rows for c2 of %s, want 1", n, name)
		}
		return x
	}
	before := read()
	if before.pct24 != 50 || before.runs != 10 || before.failed != 5 {
		t.Fatalf("before: %+v - want Failed %% 24hrs 50 (5 of 10), 10 runs, 5 failed", before)
	}
	var outcome string
	if err := tx.QueryRow(ctx, `SELECT pgvigil.import_ack(date_trunc('hour', now()) - interval '1 hour', jsonb_build_object('op', 'add', 'ui_user', 'chack',
	  'kind', 'ack', 'instance_id', $1::int, 'instance_name', $2::text, 'check_key', 'collector errors',
	  'seen_state', 'log_id:' || (SELECT max(log_id) FROM pgvigil.collection_log WHERE instance_id = $1), 'until_change', true))->>'outcome'`,
		id, name).Scan(&outcome); err != nil || outcome != "done" {
		t.Fatalf("the acknowledgement: %q, %v", outcome, err)
	}
	after := read()
	if after.pct24 != 0 {
		t.Errorf("acknowledged an hour back, on the hour: Failed %% 24hrs %v - want 0 (the 5 ok runs since)", after.pct24)
	}
	if after.status != before.status || after.runs != 10 || after.failed != 5 || strings.Contains(after.reason, "acknowledged") {
		t.Errorf("acknowledged: %+v - want the range's status (%q), 10 runs and 5 failed as before; no acknowledged words (no failure in a row is left out)", after, before.status)
	}
}
