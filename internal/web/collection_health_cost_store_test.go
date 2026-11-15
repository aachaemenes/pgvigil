package web

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestCollectionHealthCostOnAStore (B6g-1 step 4; a box row: PGVIGIL_REPO_TEST_DSN): the page's two statements over
// one hour of two instances' collection - a SQL Server one (10 runs: 4 failed, 3 of them at an import; 9 imports of
// 900 ms, the longest 300; every run read its session: 500 ms CPU, the highest 120, 20,000 logical reads) and a
// PostgreSQL one (5 ok runs, 5 imports of 50 ms, the longest 20; no session read). The grid's Failed is the failures
// at the read alone and Import Failed stands apart (DBA Dash's two counts, CollectionHealth_Get.sql L113-114), Failed
// % is over both (L439); the import's average is over the runs that imported, the CPU's and the reads' over the runs
// that read them; a row no run read its session for has NULLs there (the page says 'not read'), never 0.
func TestCollectionHealthCostOnAStore(t *testing.T) {
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
	coll := fmt.Sprintf("chcost%d", tag)
	ids := map[string]int32{}
	for name, engine := range map[string]string{fmt.Sprintf("chcost-s-%d", tag): "sqlserver", fmt.Sprintf("chcost-p-%d", tag): "postgres"} {
		var id int32
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}'::text[], $2)`, name, engine).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[engine] = id
		defer func(id int32) {
			if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
				t.Error(err)
			}
		}(id)
	}
	hour := time.Now().UTC().Truncate(time.Hour)
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.collection_health_hour (hour, instance_id, collection, collector_id, runs, ok, partial, failed, skipped,
	         rows_written, dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s, last_ok_at, last_failure_at,
	         import_failed, import_runs, import_ms_sum, import_ms_max, cpu_runs, cpu_ms_sum, cpu_ms_max, reads_sum)
	  VALUES ($1, $2, $4, 'c1', 10, 6, 0, 4, 0, 60, 5000, 900, 0, 0, 60, $1, $1, 3, 9, 900, 300, 10, 500, 120, 20000),
	         ($1, $3, $4, 'c1', 5, 5, 0, 0, 0, 25, 500, 150, 0, 0, 60, $1, NULL, 0, 5, 50, 20, 0, 0, 0, 0)`,
		hour, ids["sqlserver"], ids["postgres"], coll); err != nil {
		t.Fatalf("the hour rows (the step's eight columns): %v", err)
	}
	args := []any{hour, hour.Add(time.Hour), 0, []int32{ids["sqlserver"], ids["postgres"]}, coll, nil, "{}"}
	read := func(stmt, key string) map[string]string {
		t.Helper()
		rows, err := pool.Query(ctx, `SELECT `+key+`::text, concat_ws('|', r.failed, r.import_failed, r.failed_pct, coalesce(r.avg_import_ms::text, 'NULL'),
		           coalesce(r.max_import_ms::text, 'NULL'), coalesce(r.total_cpu_ms::text, 'NULL'), coalesce(r.avg_cpu_ms::text, 'NULL'),
		           coalesce(r.max_cpu_ms::text, 'NULL'), coalesce(r.logical_reads::text, 'NULL'), coalesce(r.avg_logical_reads::text, 'NULL'))
		      FROM (`+stmt+"\n"+`) r`, args...) // a line of its own: the statements end in a line comment
		if err != nil {
			t.Fatalf("the page's statement with the cost columns: %v", err)
		}
		defer rows.Close()
		out := map[string]string{}
		for rows.Next() {
			var k, v string
			if err := rows.Scan(&k, &v); err != nil {
				t.Fatal(err)
			}
			out[k] = v
		}
		if err := rows.Err(); err != nil {
			t.Fatalf("the page's statement with the cost columns: %v", err)
		}
		return out
	}
	const head = "failed | import failed | failed % | avg import | max import | total cpu | avg cpu | max cpu | reads | avg reads"
	byEngine := read(sqlCHInstance, "r.engine")
	if got, want := byEngine["sqlserver"], "1|3|40.00|100|300|500|50|120|20000|2000"; got != want {
		t.Errorf("the SQL Server row (%s):\n got  %s\n want %s", head, got, want)
	}
	if got, want := byEngine["postgres"], "0|0|0.00|10|20|NULL|NULL|NULL|NULL|NULL"; got != want {
		t.Errorf("the PostgreSQL row (%s):\n got  %s\n want %s", head, got, want)
	}
	// a row per collection over both instances: the sums, the higher maximum; the averages over the runs that have them
	if got, want := read(sqlCHCollection, "r.collection")[coll], "1|3|26.67|68|300|500|50|120|20000|2000"; got != want {
		t.Errorf("the row per collection (%s):\n got  %s\n want %s", head, got, want)
	}
}
