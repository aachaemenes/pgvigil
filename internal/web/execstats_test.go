package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestExecStatsOnAStore (P25 task 5, the sweep's L15: DBA Dash's SQL Server Performance > Execution Stats): on a
// migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it) /api/performance part=execstats gives, per step,
// the top N objects (procedures, functions and triggers) by the measure over the window, each one's measure per
// second of the reads' time (duration and CPU in ms/sec); measure= picks the measure (duration, cpu, executions,
// logical_reads, physical_reads, writes), top= how many objects (1-50), db= one database (its page); a measure not
// on the list is refused.
func TestExecStatsOnAStore(t *testing.T) {
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
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("execstats-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_proc_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_proc_read WHERE instance_id = $1`,
			`DELETE FROM pgvigil.mssql_func_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_func_read WHERE instance_id = $1`,
			`DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
			if _, err := pool.Exec(context.Background(), q, id); err != nil {
				t.Error(err)
			}
		}
	}()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	at := time.Now().UTC().Truncate(time.Hour).Add(-30 * time.Minute)
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read", "mssql_func_sample", "mssql_func_read"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, at)
	}
	exec(`INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs) VALUES ($1, $2, 100, 2)`, id, at)
	exec(`INSERT INTO pgvigil.mssql_func_read (instance_id, snapshot_at, interval_secs, functions, triggers) VALUES ($1, $2, 100, 1, 0)`, id, at)
	// sales.dbo.report: 500 ms of duration over 100 s = 5 ms/sec, 2 executions; hr.dbo.payroll: 200 ms, 50 executions;
	// sales.dbo.fn_tax: 100 ms, 900 executions
	exec(`INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	      VALUES ($1, $2, 5, 101, 'sales', 'dbo', 'report', 'SQL_STORED_PROCEDURE', 2, 300000, 500000, 10, 0, 0, 100),
	             ($1, $2, 6, 201, 'hr', 'dbo', 'payroll', 'SQL_STORED_PROCEDURE', 50, 100000, 200000, 10, 0, 0, 100)`, id, at)
	exec(`INSERT INTO pgvigil.mssql_func_sample (instance_id, snapshot_at, kind, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	      VALUES ($1, $2, 'function', 5, 301, 'sales', 'dbo', 'fn_tax', 'SQL_SCALAR_FUNCTION', 900, 50000, 100000, 0, 0, 0, 100)`, id, at)

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(extra url.Values) (int, []string) {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {at.Add(-10 * time.Minute).Format(time.RFC3339)}, "to": {at.Add(10 * time.Minute).Format(time.RFC3339)}, "part": {"execstats"}}
		for k, v := range extra {
			q[k] = v
		}
		rec := httptest.NewRecorder()
		s.Performance(rec, httptest.NewRequest(http.MethodGet, "/api/performance?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			return rec.Code, nil
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []string
		if tb := raw["execstats"]; tb != nil {
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				out = append(out, fmt.Sprint(m["object"], "=", m["per_sec"]))
			}
		}
		return 200, out
	}
	if code, got := call(url.Values{"measure": {"duration"}, "top": {"2"}}); code != 200 || fmt.Sprint(got) != "[hr.dbo.payroll=2 sales.dbo.report=5]" {
		t.Errorf("duration top 2: %d %v, want report 5 and payroll 2 ms/sec (fn_tax's 1 not in the top 2)", code, got)
	}
	if code, got := call(url.Values{"measure": {"executions"}, "top": {"1"}}); code != 200 || fmt.Sprint(got) != "[sales.dbo.fn_tax=9]" {
		t.Errorf("executions top 1: %d %v, want fn_tax at 9 /sec", code, got)
	}
	if code, got := call(url.Values{"measure": {"duration"}, "top": {"5"}, "db": {"hr"}}); code != 200 || fmt.Sprint(got) != "[hr.dbo.payroll=2]" {
		t.Errorf("db=hr: %d %v, want payroll alone", code, got)
	}
	if code, _ := call(url.Values{"measure": {"waits"}}); code != http.StatusBadRequest {
		t.Errorf("measure=waits: %d, want 400", code)
	}
}
