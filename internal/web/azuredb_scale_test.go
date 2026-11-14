package web

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
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
	tag, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_azuredb_minute (instance_id, snapshot_at, samples, avg_cpu_percent, max_cpu_percent,
	     avg_data_io_percent, max_data_io_percent, avg_log_write_percent, max_log_write_percent, dtu_limit, avg_dtu_percent, max_dtu_percent,
	     avg_dtu, max_dtu, dtu_buckets, cpu_buckets, data_buckets, log_buckets)
	   SELECT i, $2::timestamptz + m * interval '1 minute', 4, (i + m) % 100, (i + m) % 100 + 0.5, m % 50, m % 50, i % 30, i % 30, 50,
	          (i + m) % 100, (i + m) % 100 + 0.5, (i + m) % 100 / 2.0, ((i + m) % 100 + 0.5) / 2.0,
	          ARRAY[1,0,0,0,0,0,0,0,0,3]::smallint[], ARRAY[0,1,0,0,0,0,0,0,3,0]::smallint[], ARRAY[4,0,0,0,0,0,0,0,0,0]::smallint[], ARRAY[0,0,4,0,0,0,0,0,0,0]::smallint[]
	     FROM unnest($1::int[]) i, generate_series(0, 1439) m`, ids, from24)
	if err != nil {
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
	t.Logf("one minute's writes of %d databases, one after another: %v (%v a database)", fleet, imp.Round(time.Millisecond), (imp / fleet).Round(time.Microsecond))
	if imp > 30*time.Second {
		t.Errorf("one minute's writes of the fleet took %v, want under 30 s", imp)
	}

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
