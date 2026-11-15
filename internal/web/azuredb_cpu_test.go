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

// TestAzureDBCPUOnAStore (B2a, F5): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it) an Azure
// SQL Database's CPU on the Performance page, the instance's CPU tab and the Performance Summary's CPU cell comes
// from mssql_azuredb_minute - the minutes' averages weighed by their 15-second samples, the per-sample maximum, the
// ten CPU buckets summed (DBA Dash's AzureDBPerformanceSummary_Get) - and a SQL Server's from mssql_cpu_sample as
// before (100 - idle, its count of samples and its buckets).
func TestAzureDBCPUOnAStore(t *testing.T) {
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
	sfx := time.Now().UnixNano() % 1000000000
	ids := map[string]int{}
	for _, platform := range []string{"azuresqldb", "sqlserver"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("azcpu-%s-%d", platform, sfx), platform).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[platform] = id
	}
	az, ss := ids["azuresqldb"], ids["sqlserver"]
	defer func() {
		for _, c := range []struct {
			q    string
			args []any
		}{
			{`DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1`, []any{az}},
			{`DELETE FROM pgvigil.mssql_cpu_sample WHERE instance_id = $1`, []any{ss}},
			{`DELETE FROM pgvigil.instances WHERE instance_id IN ($1, $2)`, []any{az, ss}},
		} {
			if _, err := pool.Exec(context.Background(), c.q, c.args...); err != nil {
				t.Error(err)
			}
		}
	}()
	base := time.Now().UTC().Truncate(time.Hour).Add(-time.Hour) // inside the range below, whatever the hour
	minute := func(m, samples int, avg, top float64, buckets []int) map[string]any {
		return map[string]any{"kind": "minute", "minute": base.Add(time.Duration(m) * time.Minute).Format(time.RFC3339), "samples": samples,
			"avg_cpu_percent": avg, "max_cpu_percent": top, "dtu_buckets": make([]int, 10), "cpu_buckets": buckets,
			"data_buckets": make([]int, 10), "log_buckets": make([]int, 10)}
	}
	p, _ := json.Marshal([]map[string]any{
		minute(0, 4, 10, 30, []int{2, 1, 0, 1, 0, 0, 0, 0, 0, 0}),
		minute(1, 2, 40, 95, []int{0, 0, 0, 0, 1, 0, 0, 0, 0, 1}),
	})
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, now(), $2::jsonb)`, az, string(p)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition('mssql_cpu_sample', $1)`, base); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct, other_pct, idle_pct)
	   VALUES ($1, $2, 1, 20, 10, 70), ($1, $3, 2, 50, 5, 5)`, ss, base, base.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	from, to := base.Add(-time.Minute), base.Add(time.Hour)
	// weighed: (10 x 4 + 40 x 2) / 6 = 20.0; the largest sample 95
	one := func(q string, args ...any) map[string]any {
		t.Helper()
		rows, err := pool.Query(ctx, q, args...)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var out map[string]any
		n := 0
		for rows.Next() {
			vals, err := rows.Values()
			if err != nil {
				t.Fatal(err)
			}
			out = map[string]any{}
			for i, f := range rows.FieldDescriptions() {
				out[f.Name] = vals[i]
			}
			n++
		}
		if n != 1 {
			t.Fatalf("%d rows, want one step", n)
		}
		return out
	}
	// each query wrapped so its numbers come back as plain floats
	perfQ := `SELECT cpu_avg::float8 AS cpu_avg, cpu_max::float8 AS cpu_max, sql_avg::float8 AS sql_avg, machine_read, azure FROM (` + sqlPerfMSSQLCPU + `) q`
	perf := one(perfQ, az, from, to, 3600)
	if s := fmt.Sprintf("%v %v %v %v %v", perf["cpu_avg"], perf["cpu_max"], perf["sql_avg"], perf["machine_read"], perf["azure"]); s != "20 95 20 false true" {
		t.Errorf("Performance page on Azure SQL Database: cpu_avg cpu_max sql_avg machine_read azure = %s, want 20 95 20 false true", s)
	}
	perf = one(perfQ, ss, from, to, 3600)
	if s := fmt.Sprintf("%v %v %v %v %v", perf["cpu_avg"], perf["cpu_max"], perf["sql_avg"], perf["machine_read"], perf["azure"]); s != "62.5 95 35 true false" {
		t.Errorf("Performance page on SQL Server: cpu_avg cpu_max sql_avg machine_read azure = %s, want 62.5 95 35 true false (100 - idle, as before)", s)
	}
	tab := one(`SELECT sql_pct::float8 AS sql_pct, total_max::float8 AS total_max, total_pct::float8 AS total_pct FROM (`+sqlMSSQLCPUSeries+`) q`, az, from, to, 3600)
	if s := fmt.Sprintf("%v %v %v", tab["sql_pct"], tab["total_max"], tab["total_pct"]); s != "20 95 <nil>" {
		t.Errorf("CPU tab on Azure SQL Database: sql_pct total_max total_pct = %s, want 20 95 and no machine figure", s)
	}
	rows, err := pool.Query(ctx, `SELECT instance_id, cpu_samples, cpu_avg::float8 AS cpu_avg, cpu_max::float8 AS cpu_max, cpu_hist, cpu_source FROM (`+sqlPerfSummaryMSSQL+`) q`, from, to, "sqlserver", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	got := map[int]string{}
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			t.Fatal(err)
		}
		r := map[string]any{}
		for i, f := range rows.FieldDescriptions() {
			r[f.Name] = vals[i]
		}
		id, _ := r["instance_id"].(int32)
		got[int(id)] = fmt.Sprintf("%v %v %v %v %v", r["cpu_samples"], r["cpu_avg"], r["cpu_max"], r["cpu_hist"], r["cpu_source"])
	}
	if got[az] != "6 20 95 [2 1 0 1 1 0 0 0 0 1] azure" {
		t.Errorf("Performance Summary on Azure SQL Database: %q, want 6 samples, 20.0, 95.00 and the buckets summed", got[az])
	}
	if got[ss] != "2 62.5 95 [0 0 0 1 0 0 0 0 0 1] scheduler" {
		t.Errorf("Performance Summary on SQL Server: %q, want 2 samples, 62.5, 95 and its own buckets (30 and 95)", got[ss])
	}
}
