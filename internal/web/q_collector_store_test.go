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

// TestCollectorLoadTwoProbedHosts (the review B6f8 #1): an instance two collector hosts read under two dial names, each
// host's probe of its own name answering, is ONE load row whose sums are the minutes written - the probe's rows (one per
// probed host) must not multiply the load's. 3 runs written per host: runs over the hour 6, failures 2, auth failures 2;
// the probe's rounds summed over the two hosts (2) and averaged (0.005 s). One transaction, rolled back.
func TestCollectorLoadTwoProbedHosts(t *testing.T) {
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
	var id int
	if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`,
		fmt.Sprintf("twohost-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	for k, h := range []string{"a", "b"} {
		coll := fmt.Sprintf("twohost-%s-%d", h, sfx)
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
			VALUES ($1, $1, 'linux', 'console', 'x', 1, now() - interval '1 hour', now())`, coll); err != nil {
			t.Fatal(err)
		}
		target := fmt.Sprintf("postgres:db%s-%d:5432", h, sfx)
		for m := 1; m <= 3; m++ {
			// one failure and one refused login on each host's first minute
			if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures, target, rt_count, rt_ms_sum, rt_ms_max)
				VALUES (date_trunc('minute', now()) - make_interval(mins => $1), $2, $3, 1, 1, 1, $4, $4, $5, 1, 5, 5)`, m+k*3, id, coll, map[bool]int{true: 1, false: 0}[m == 1], target); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_probe (minute, collector_id, host, address, method, sent, answered, ms_sum, ms_max)
			VALUES (date_trunc('minute', now()) - interval '2 minutes', $1, $2, $3, 'tcp', 1, 1, 5, 5)`,
			coll, fmt.Sprintf("db%s-%d", h, sfx), fmt.Sprintf("10.9.%d.1", k)); err != nil {
			t.Fatal(err)
		}
	}
	var n, runs, failures, auth, rounds int
	var avg string
	if err := tx.QueryRow(ctx, `SELECT count(*) OVER ()::int, runs_1h::int, failures_1h::int, auth_failures_1h::int, coalesce(probe_rounds_1h, 0)::int, coalesce(probe_avg_s::text, '-') FROM (`+sqlCollectorLoad+`) x`, id).
		Scan(&n, &runs, &failures, &auth, &rounds, &avg); err != nil {
		t.Fatalf("the Collector page's load query on a store: %v", err)
	}
	if n != 1 || runs != 6 || failures != 2 || auth != 2 {
		t.Errorf("rows %d, runs over the hour %d, failures %d, refused logins %d; want 1 row, 6, 2, 2 (3 minutes written per host, the probe's rows not multiplying them)", n, runs, failures, auth)
	}
	if rounds != 2 || avg != "0.005" {
		t.Errorf("the probe over the hour: %d round(s), %s s; want 2 rounds (one per probed host) at 0.005 s", rounds, avg)
	}
}
