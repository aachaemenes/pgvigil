package web

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestCollectionHealthCostOnAStore (B6g-1 step 4; a box row:
// PGVIGIL_REPO_TEST_DSN): the page's two statements over one hour. A SQL Server collection on two instances - s1 (10
// runs: 4 failed, 3 of them at an import; 9 imports of 900 ms, the longest 300; every run read its session: 500 ms CPU,
// the highest 120, 20,000 logical reads) and s2 (2 runs, both failed at the read; no import attempted; both read: 60 ms,
// the highest 40, 1,000 reads) - and a PostgreSQL collection on p (5 ok runs, 5 imports of 50 ms, the longest 20; no
// session read; collection names never cross engines). The grid's Failed is the failures but the import failures and
// Import Failed stands apart (DBA Dash's two counts, CollectionHealth_Get.sql L113-114), Failed % is over both (L439);
// the import's average is over the runs that attempted one (NULL with none), the CPU's and the reads' over the runs that
// read them (NULL with none, the page says 'not read'); a row per collection sums them, its maxima the highest, and
// names its engine where all its instances share one (the PostgreSQL collection's cells: 'not read by pgvigil').
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
	coll, pcoll := fmt.Sprintf("mssql_chcost%d", tag), fmt.Sprintf("chcost%d", tag)
	ids := map[string]int32{}
	for key, engine := range map[string]string{"s1": "sqlserver", "s2": "sqlserver", "p": "postgres"} {
		var id int32
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}'::text[], $2)`,
			fmt.Sprintf("chcost-%s-%d", key, tag), engine).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[key] = id
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
	  VALUES ($1, $2, $5, 'c1', 10, 6, 0, 4, 0, 60, 5000, 900, 0, 0, 60, $1, $1, 3, 9, 900, 300, 10, 500, 120, 20000),
	         ($1, $3, $5, 'c1', 3, 0, 0, 3, 0, 0, 450, 200, 0, 0, 60, NULL, $1, 0, 0, 0, 0, 2, 60, 40, 1000),   -- 3 runs, 2 read (one cut by its own timeout)
	         ($1, $4, $6, 'c1', 5, 5, 0, 0, 0, 25, 500, 150, 0, 0, 60, $1, NULL, 0, 5, 50, 20, 0, 0, 0, 0)`,
		hour, ids["s1"], ids["s2"], ids["p"], coll, pcoll); err != nil {
		t.Fatalf("the hour rows (the step's eight columns): %v", err)
	}
	// every collection of the three instances ($5 ''), the scope by their ids
	args := []any{hour, hour.Add(time.Hour), 0, []int32{ids["s1"], ids["s2"], ids["p"]}, "", nil, "{}"}
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
	byInst := read(sqlCHInstance, "r.instance_id")
	for _, c := range []struct{ key, want, what string }{
		{"s1", "1|3|40.00|100|300|500|50|120|20000|2000", "s1 (4 failed, 3 at the import)"},
		{"s2", "3|0|100.00|NULL|NULL|60|30|40|1000|500", "s2 (3 failed at the read, 2 of them read their session; no import attempted: no import figure)"},
		{"p", "0|0|0.00|10|20|NULL|NULL|NULL|NULL|NULL", "p (PostgreSQL: no session read)"},
	} {
		if got := byInst[fmt.Sprint(ids[c.key])]; got != c.want {
			t.Errorf("the row of %s (%s):\n got  %s\n want %s", c.what, head, got, c.want)
		}
	}
	// a row per collection: the sums, the HIGHER maximum (s1's 120 and s2's 40: a sum would read 160), the averages over
	// the runs that have them (CPU over the 12 runs that read it, of 13: 560 / 12 = 47; the import over s1's 9 attempts)
	byColl := read(sqlCHCollection, "r.collection")
	if got, want := byColl[coll], "4|3|53.85|100|300|560|47|120|21000|1750"; got != want {
		t.Errorf("the SQL Server collection's row per collection (%s):\n got  %s\n want %s", head, got, want)
	}
	if got, want := byColl[pcoll], "0|0|0.00|10|20|NULL|NULL|NULL|NULL|NULL"; got != want {
		t.Errorf("the PostgreSQL collection's row per collection (%s):\n got  %s\n want %s", head, got, want)
	}
	// the engine a row per collection names (the page's 'not read by pgvigil' for a PostgreSQL collection's cells)
	eng := map[string]string{}
	rows, err := pool.Query(ctx, `SELECT r.collection, coalesce(r.engine, '-') FROM (`+sqlCHCollection+"\n"+`) r`, args...)
	if err != nil {
		t.Errorf("the row per collection names no engine: %v", err)
	} else {
		for rows.Next() {
			var c, e string
			if err := rows.Scan(&c, &e); err != nil {
				t.Fatal(err)
			}
			eng[c] = e
		}
		rows.Close()
		if eng[coll] != "sqlserver" || eng[pcoll] != "postgres" {
			t.Errorf("the rows per collection's engine: %s %q, %s %q - want sqlserver and postgres", coll, eng[coll], pcoll, eng[pcoll])
		}
	}
}
