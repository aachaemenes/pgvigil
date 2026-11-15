package web

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/repo"
)

// TestAzureDBFleetScaleOnAStore (B2a, the design's 'the collector's fan-out with two more minute collections at 1,819
// instances: a B2a store test'): on a migrated repository (PGVIGIL_REPO_TEST_DSN) and only with PGVIGIL_SCALE_TEST=1
// (it writes about 2.6 million rows), 1,819 Azure SQL Databases with a day of minutes each:
//   - one minute's writes of the whole fleet, 1,819 calls of import_mssql_azuredb_resources one after another (the
//     collector's workers run them side by side: this is the slow bound), end in under 30 s, half the minute;
//   - the Azure Summary (sqlAzureDBFleet) and the Performance summary's SQL Server part (sqlPerfSummaryMSSQL, its
//     Azure SQL Database arm) over 1 hour and over 24 hours, and one database's Azure tab window (sqlAzureDBSummary)
//     over 24 hours, on a pool with JIT off (the UI's, web.go), each return every database and end in under 30 s;
//     every time is logged for the DONE.
//
// The collector's side is read from the code, not timed here: each collection of an instance runs in its own
// goroutine and opens its own connection per run (internal/sched/sched.go, mssql.RunOnce), so N1 is one more
// connection a minute per Azure SQL Database: 12 SQL Server collections a minute where 11 were.
func TestAzureDBFleetScaleOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" || os.Getenv("PGVIGIL_SCALE_TEST") != "1" {
		t.Skip("PGVIGIL_REPO_TEST_DSN and PGVIGIL_SCALE_TEST=1 are not both set")
	}
	const fleet = 1819
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["jit"] = "off"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	sfx := time.Now().UnixNano() % 1000000000
	var ids []int32
	if err := pool.QueryRow(ctx, `SELECT array_agg(pgvigil.ensure_instance(format('azscale-%s-%s', $1::text, g), 'azuresqldb', '12.0', 120000, false,
	     '{}'::text[], 'sqlserver') ORDER BY g) FROM generate_series(1, $2) g`, fmt.Sprint(sfx), fleet).Scan(&ids); err != nil {
		t.Fatal(err)
	}
	if len(ids) != fleet {
		t.Fatalf("%d instances made, want %d", len(ids), fleet)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.mssql_azuredb_read WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(context.Background(), q, ids); err != nil {
				t.Error(err)
			}
		}
	}()

	// a day of minutes for every database, seeded in SQL: 1,440 a database
	now := time.Now().UTC().Truncate(time.Minute)
	from24 := now.Add(-24 * time.Hour)
	start := time.Now()
	for _, at := range []time.Time{from24, now} {
		if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition('mssql_azuredb_minute', $1)`, at); err != nil {
			t.Fatal(err)
		}
	}
	// the seed is the store a release with B2a and before 0167 leaves (B2a-N2's first build): the hours' trigger is held
	// off for it, the minutes go in time order as the collector writes them (a minute of every database, then the next:
	// one database's day spread over the heap, the pass's finding 7), and 'pgvigil purge' builds the hours after
	if _, err := pool.Exec(ctx, `ALTER TABLE pgvigil.mssql_azuredb_minute DISABLE TRIGGER mssql_azuredb_hour_ins`); err != nil {
		t.Fatal(err)
	}
	tag, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_azuredb_minute (instance_id, snapshot_at, samples, avg_cpu_percent, max_cpu_percent,
	     avg_data_io_percent, max_data_io_percent, avg_log_write_percent, max_log_write_percent, dtu_limit, avg_dtu_percent, max_dtu_percent,
	     avg_dtu, max_dtu, dtu_buckets, cpu_buckets, data_buckets, log_buckets)
	   SELECT i, $2::timestamptz + m * interval '1 minute', 4, (i + m) % 100, (i + m) % 100 + 0.5, m % 50, m % 50, i % 30, i % 30, 50,
	          (i + m) % 100, (i + m) % 100 + 0.5, (i + m) % 100 / 2.0, ((i + m) % 100 + 0.5) / 2.0,
	          ARRAY[1,0,0,0,0,0,0,0,0,3]::smallint[], ARRAY[0,1,0,0,0,0,0,0,3,0]::smallint[], ARRAY[4,0,0,0,0,0,0,0,0,0]::smallint[], ARRAY[0,0,4,0,0,0,0,0,0,0]::smallint[]
	     FROM generate_series(0, 1439) m, unnest($1::int[]) i ORDER BY m, i`, ids, from24)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `ALTER TABLE pgvigil.mssql_azuredb_minute ENABLE TRIGGER mssql_azuredb_hour_ins`); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `ANALYZE pgvigil.mssql_azuredb_minute`); err != nil {
		t.Fatal(err)
	}
	t.Logf("seeded %d minutes (%d databases x 1,440) in %v", tag.RowsAffected(), fleet, time.Since(start).Round(time.Millisecond))

	// one minute's writes of the fleet, one import call a database
	payload, _ := json.Marshal([]map[string]any{{"kind": "minute", "minute": now.Format(time.RFC3339), "samples": 4, "avg_cpu_percent": 12.5,
		"max_cpu_percent": 40.0, "dtu_limit": 50.0, "avg_dtu_percent": 12.5, "max_dtu_percent": 40.0, "avg_dtu": 6.25, "max_dtu": 20.0,
		"dtu_buckets": []int{2, 1, 0, 0, 1, 0, 0, 0, 0, 0}, "cpu_buckets": []int{2, 1, 0, 0, 1, 0, 0, 0, 0, 0},
		"data_buckets": []int{4, 0, 0, 0, 0, 0, 0, 0, 0, 0}, "log_buckets": []int{4, 0, 0, 0, 0, 0, 0, 0, 0, 0}}})
	start = time.Now()
	for _, id := range ids {
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, $2, $3::jsonb)`, id, now.Add(40*time.Second), string(payload)); err != nil {
			t.Fatal(err)
		}
	}
	imp := time.Since(start)
	t.Logf("one minute's writes of %d databases during the first build (each trigger call heals 200 ms at most): %v (%v a database)", fleet, imp.Round(time.Millisecond), (imp / fleet).Round(time.Microsecond))
	if imp > 30*time.Second {
		t.Errorf("one minute's writes of the fleet took %v, want under 30 s", imp)
	}
	// the first build by 'pgvigil purge' (one instance a transaction), then one minute's writes on built hours
	start = time.Now()
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	built, hourRows, failed, err := r.AzureDBHoursHeal(ctx)
	r.Close()
	if err != nil || failed != 0 {
		t.Fatalf("the first build: %v, %d failed", err, failed)
	}
	t.Logf("the first build of %d databases' day (purge): %d instances, %d hour rows in %v", fleet, built, hourRows, time.Since(start).Round(time.Millisecond))
	payload2, _ := json.Marshal([]map[string]any{{"kind": "minute", "minute": now.Add(time.Minute).Format(time.RFC3339), "samples": 4, "avg_cpu_percent": 12.5,
		"max_cpu_percent": 40.0, "dtu_limit": 50.0, "avg_dtu_percent": 12.5, "max_dtu_percent": 40.0, "avg_dtu": 6.25, "max_dtu": 20.0,
		"dtu_buckets": []int{2, 1, 0, 0, 1, 0, 0, 0, 0, 0}, "cpu_buckets": []int{2, 1, 0, 0, 1, 0, 0, 0, 0, 0},
		"data_buckets": []int{4, 0, 0, 0, 0, 0, 0, 0, 0, 0}, "log_buckets": []int{4, 0, 0, 0, 0, 0, 0, 0, 0, 0}}})
	start = time.Now()
	for _, id := range ids {
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, $2, $3::jsonb)`, id, now.Add(100*time.Second), string(payload2)); err != nil {
			t.Fatal(err)
		}
	}
	imp2 := time.Since(start)
	t.Logf("one minute's writes of %d databases on built hours (the trigger's recompute): %v", fleet, imp2.Round(time.Millisecond))
	if imp2 > 30*time.Second {
		t.Errorf("one minute's writes on built hours took %v, want under 30 s", imp2)
	}
	var heap, idx int64
	_ = pool.QueryRow(ctx, `SELECT coalesce(sum(pg_relation_size(c.oid)), 0), coalesce(sum(pg_indexes_size(c.oid)), 0)
	  FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = 'pgvigil.mssql_azuredb_hour'::regclass`).Scan(&heap, &idx)
	t.Logf("the hours of a day at %d databases: heap %d bytes, key %d bytes (x 730 for two years: heap %.1f GB, key %.1f GB)", fleet, heap, idx,
		float64(heap)*730/1e9, float64(idx)*730/1e9)

	// the readers over the fleet
	idset := map[int32]bool{}
	for _, id := range ids {
		idset[id] = true
	}
	count := func(name, q string, args ...any) {
		t.Helper()
		start := time.Now()
		rows, err := pool.Query(ctx, q, args...)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		n := 0
		for rows.Next() {
			v, err := rows.Values()
			if err != nil {
				t.Fatalf("%s: %v", name, err)
			}
			if id, ok := v[0].(int32); ok && idset[id] {
				n++
			}
		}
		if err := rows.Err(); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		took := time.Since(start)
		t.Logf("%s: %d of the fleet's databases in %v", name, n, took.Round(time.Millisecond))
		if n != fleet || took > 30*time.Second {
			t.Errorf("%s: %d databases in %v, want %d in under 30 s", name, n, took, fleet)
		}
	}
	for _, w := range []struct {
		name string
		from time.Time
	}{{"1 hour", now.Add(-time.Hour)}, {"24 hours", from24}} {
		count("the Azure Summary over "+w.name, sqlAzureDBFleet, w.from, now.Add(time.Minute), "sqlserver", nil)
		count("the Performance summary's SQL Server part over "+w.name, sqlPerfSummaryMSSQL, w.from, now.Add(time.Minute), "sqlserver", nil)
	}
	start = time.Now()
	var samples *int64
	if err := pool.QueryRow(ctx, `SELECT samples FROM (`+sqlAzureDBSummary+`) s`, ids[fleet/2], from24, now.Add(time.Minute)).Scan(&samples); err != nil {
		t.Fatal(err)
	}
	took := time.Since(start)
	t.Logf("one database's Azure tab window over 24 hours: %v samples in %v", scaleSamples(samples), took.Round(time.Millisecond))
	if samples == nil || *samples != 1441*4 || took > 30*time.Second {
		t.Errorf("the Azure tab's window: %v samples in %v, want %d in under 30 s", scaleSamples(samples), took, 1441*4)
	}
}

func scaleSamples(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}
