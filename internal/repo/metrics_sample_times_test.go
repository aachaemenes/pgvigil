package repo

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// The review's A15: metrics_sample_times (0196) names each family's newest sample by a CASE with no ELSE, and its
// WHERE drops a NULL time, so a family the CASE does not name is silently missing from pgvigil_sample_timestamp_seconds.
// (1) every DISTINCT metric_catalog family has its WHEN arm in the function's body; (2) the arms the joined store adds
// (scripts/b24d-join-lines.sql: counters, xe, waits, collection), each for a family the store's catalog carries, give
// the time of the sample seeded in its table as its points count it. On a store before the join (no such family in
// its catalog) (2) has nothing to seed and says so.
func TestMetricsSampleTimesNamesEveryFamilyOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)

	// (1) the static guard
	rows, err := pool.Query(ctx, `SELECT f.family FROM (SELECT DISTINCT c.family FROM pgvigil.metric_catalog c) f
	  WHERE position('WHEN ''' || f.family || '''' IN pg_get_functiondef('pgvigil.metrics_sample_times(int[])'::regprocedure)) = 0
	  ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	var missing []string
	for rows.Next() {
		var f string
		if err := rows.Scan(&f); err != nil {
			t.Fatal(err)
		}
		missing = append(missing, f)
	}
	rows.Close()
	if len(missing) > 0 {
		t.Errorf("metric_catalog families with no WHEN arm in metrics_sample_times (their pgvigil_sample_timestamp_seconds is never written): %s",
			strings.Join(missing, ", "))
	}

	// (2) the joined families' arms, each against a sample seeded in its own table
	name := fmt.Sprintf("mst-%d", time.Now().UnixNano()%1_000_000_000)
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'auto', NULL::text, NULL::int, false, '{}'::text[], 'sqlserver')`, name).Scan(&id); err != nil {
		t.Fatal(err)
	}
	var undo []string // each seeded table's own DELETE, run before the instance's (two of the tables hold no reference to it)
	t.Cleanup(func() {
		for _, q := range undo {
			_, _ = pool.Exec(context.Background(), q, id)
		}
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id)
	})
	var at, hour time.Time
	if err := pool.QueryRow(ctx, `SELECT date_trunc('second', now()) - interval '10 minutes', date_trunc('hour', now()) - interval '2 hours'`).Scan(&at, &hour); err != nil {
		t.Fatal(err)
	}
	// a partitioned table's partition is made by the table's own maker, as its importer makes it: mssql_counter_read and
	// mssql_wait_sample are month-partitioned (0124's and 0064's importers call ensure_month_partition) - a day
	// partition there overlaps the month's (42P17)
	type seed struct {
		table string
		sql   []string // $1 the instance, $2 the sample's time (the hour's start for collection)
		want  time.Time
		del   string // $1 the instance
	}
	seeds := map[string]seed{
		"counters": {"mssql_counter_read", []string{
			`SELECT pgvigil.ensure_month_partition('mssql_counter_read', $2::timestamptz) WHERE $1::int IS NOT NULL`,
			`INSERT INTO pgvigil.mssql_counter_read (instance_id, snapshot_at, scope, rows_read) VALUES ($1::int, $2::timestamptz, 'instance', 1)`}, at,
			`DELETE FROM pgvigil.mssql_counter_read WHERE instance_id = $1`},
		// a done read while the capture ran is a sample; a later read that is not done, or done while the capture was
		// not running, is not (no point of the family)
		"xe": {"mssql_attention_reads", []string{
			`INSERT INTO pgvigil.mssql_attention_reads (instance_id, snapshot_at, state, read_done) VALUES ($1::int, $2::timestamptz, 'running', true),
			   ($1::int, $2::timestamptz + interval '1 minute', 'running', false), ($1::int, $2::timestamptz + interval '2 minutes', 'stopped', true)`}, at,
			`DELETE FROM pgvigil.mssql_attention_reads WHERE instance_id = $1`},
		"waits": {"mssql_wait_sample", []string{
			`SELECT pgvigil.ensure_month_partition('mssql_wait_sample', $2::timestamptz) WHERE $1::int IS NOT NULL`,
			`INSERT INTO pgvigil.mssql_wait_sample (instance_id, snapshot_at, wait_type, waiting_tasks, wait_ms, signal_ms, interval_secs)
			   VALUES ($1::int, $2::timestamptz, 'PAGEIOLATCH_SH', 1, 1, 0, 60)`}, at,
			`DELETE FROM pgvigil.mssql_wait_sample WHERE instance_id = $1`},
		// stamped at the hour's end; the open hour (now's) gives no point, so its row is not the newest sample
		"collection": {"collection_health_hour", []string{
			`INSERT INTO pgvigil.collection_health_hour (hour, instance_id, collection, collector_id, runs, ok, partial, failed, skipped,
			   rows_written, dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval)
			 VALUES ($2::timestamptz, $1::int, 'c1', 'k1', 1, 1, 0, 0, 0, 0, 0, 0, 0, 0), (date_trunc('hour', now()), $1::int, 'c1', 'k1', 1, 1, 0, 0, 0, 0, 0, 0, 0, 0)`}, hour.Add(time.Hour),
			`DELETE FROM pgvigil.collection_health_hour WHERE instance_id = $1`},
	}
	seeded := map[string]time.Time{}
	for family, s := range seeds {
		var inCatalog, haveTable bool
		if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pgvigil.metric_catalog c WHERE c.family = $1 AND c.engine IN ('sqlserver', 'any')),
		                                     to_regclass('pgvigil.' || $2::text) IS NOT NULL`, family, s.table).Scan(&inCatalog, &haveTable); err != nil {
			t.Fatal(err)
		}
		if !inCatalog || !haveTable {
			t.Logf("%s: not in this store's catalog for SQL Server (catalog %v, table %v): nothing to seed", family, inCatalog, haveTable)
			continue
		}
		when := at
		if family == "collection" {
			when = hour
		}
		undo = append(undo, s.del)
		for _, q := range s.sql {
			if _, err := pool.Exec(ctx, q, id, when); err != nil {
				t.Fatalf("%s's seed: %v\n%s", family, err, q)
			}
		}
		seeded[family] = s.want
	}
	got := map[string]time.Time{}
	rows, err = pool.Query(ctx, `SELECT family, at FROM pgvigil.metrics_sample_times(ARRAY[$1::int])`, id)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var f string
		var a time.Time
		if err := rows.Scan(&f, &a); err != nil {
			t.Fatal(err)
		}
		got[f] = a
	}
	rows.Close()
	for family, want := range seeded {
		a, ok := got[family]
		switch {
		case !ok:
			t.Errorf("%s: a sample seeded at %s, but metrics_sample_times names no time for the family", family, want.UTC().Format(time.RFC3339))
		case !a.Equal(want):
			t.Errorf("%s: metrics_sample_times names %s, want %s (the newest sample its points count)", family, a.UTC().Format(time.RFC3339), want.UTC().Format(time.RFC3339))
		}
	}
	t.Logf("seeded %d joined families on this store, metrics_sample_times named %d families for the instance", len(seeded), len(got))
}
