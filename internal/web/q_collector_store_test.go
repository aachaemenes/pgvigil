package web

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestCollectorLoadOnAStore (B24h-1e; the box run vis-b24hrt, whose /api/collector answered nothing): on a migrated
// repository (PGVIGIL_REPO_TEST_DSN, skipped without it) the Collector page's load query runs - the outer SELECT reads
// only what its CTEs name - and an instance with three measured minutes (40, 50 and 60 ms) reads its query round trip
// over the hour as 0.050 s on average and 0.060 s at most. One transaction, rolled back.
func TestCollectorLoadOnAStore(t *testing.T) {
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
	sfx := time.Now().UnixNano() % 1000000000
	coll := fmt.Sprintf("rtstore-%d", sfx)
	var id int
	if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`,
		fmt.Sprintf("rtstore-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
		VALUES ($1, $1, 'linux', 'console', 'x', 1, now() - interval '1 hour', now())`, coll); err != nil {
		t.Fatal(err)
	}
	for k, ms := range []int{40, 50, 60} {
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures, target, rt_count, rt_ms_sum, rt_ms_max)
			VALUES (date_trunc('minute', now()) - make_interval(mins => $1), $2, $3, 1, 1, 1, 0, 0, 'postgres:rthost:5432', 1, $4, $5)`, k+1, id, coll, ms, ms); err != nil {
			t.Fatal(err)
		}
	}
	// the page's own query as it runs (a column its outer SELECT reads that no CTE names is 42703 here, data or none)
	var n int
	var name string
	if err := tx.QueryRow(ctx, `SELECT count(*), coalesce(max(instance), '') FROM (`+sqlCollectorLoad+`) x`, id).Scan(&n, &name); err != nil {
		t.Fatalf("the Collector page's load query on a store: %v", err)
	}
	if n != 1 || name == "" {
		t.Errorf("rows %d, instance %q; want 1 row naming the instance asked", n, name)
	}
	var avg, top string
	if err := tx.QueryRow(ctx, `SELECT coalesce(rt_avg_s::text, '-'), coalesce(rt_max_s::text, '-') FROM (`+sqlCollectorLoad+`) x`, id).Scan(&avg, &top); err != nil {
		t.Fatal(err)
	}
	if avg != "0.050" || top != "0.060" {
		t.Errorf("the round trip over the hour reads %s / %s s, want 0.050 / 0.060 (40, 50, 60 ms)", avg, top)
	}
}
