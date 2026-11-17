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

// TestObjectExecutionOnAStore (P25, F102 / F505: DBA Dash's Object Execution): on a migrated repository
// (PGVIGIL_REPO_TEST_DSN, skipped without it) /api/mssql/procs part=objects is ONE list of the procedures, the scalar
// functions and the triggers that ran (0343's function and trigger stats beside the procedures'), each row its kind
// and its Period Time (the seconds its kind's reads cover); types= keeps the kinds asked (DBA Dash's Type filter) and
// search= the objects whose schema or name holds the text; db= one database, as the other parts.
func TestObjectExecutionOnAStore(t *testing.T) {
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
		fmt.Sprintf("objexec-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
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
	at := time.Now().UTC().Truncate(time.Minute).Add(-20 * time.Minute)
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read", "mssql_func_sample", "mssql_func_read"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, at)
	}
	exec(`INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs) VALUES ($1, $2, 60, 1)`, id, at)
	exec(`INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	      VALUES ($1, $2, 5, 101, 'sales', 'dbo', 'sales_report', 'SQL_STORED_PROCEDURE', 10, 1000, 50000, 100, 0, 0, 60)`, id, at)
	exec(`INSERT INTO pgvigil.mssql_func_read (instance_id, snapshot_at, interval_secs, functions, triggers) VALUES ($1, $2, 120, 1, 1)`, id, at)
	exec(`INSERT INTO pgvigil.mssql_func_sample (instance_id, snapshot_at, kind, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	      VALUES ($1, $2, 'function', 5, 201, 'sales', 'dbo', 'fn_tax', 'SQL_SCALAR_FUNCTION', 100, 2000, 20000, 10, 0, 0, 120),
	             ($1, $2, 'trigger', 6, 301, 'hr', 'audit', 'trg_payroll', 'SQL_TRIGGER', 5, 3000, 90000, 50, 0, 5, 120)`, id, at)

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(extra url.Values) []map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {at.Add(-10 * time.Minute).Format(time.RFC3339)}, "to": {at.Add(10 * time.Minute).Format(time.RFC3339)}, "part": {"objects"}}
		for k, v := range extra {
			q[k] = v
		}
		rec := httptest.NewRecorder()
		s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", q.Encode(), rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw["objects"]; tb != nil {
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				out = append(out, m)
			}
		}
		return out
	}
	list := func(rows []map[string]any) string {
		var n []string
		for _, r := range rows {
			n = append(n, fmt.Sprint(r["kind"], ":", r["object_name"], "@", r["period_secs"]))
		}
		return fmt.Sprint(n)
	}
	// every kind, the longest total duration first: the trigger 90 ms, the procedure 50 ms, the function 20 ms
	if got := list(call(nil)); got != "[trigger:trg_payroll@120 procedure:sales_report@60 function:fn_tax@120]" {
		t.Errorf("objects %s, want the three kinds in one list, each with its kind's period", got)
	}
	if got := list(call(url.Values{"types": {"function,trigger"}})); got != "[trigger:trg_payroll@120 function:fn_tax@120]" {
		t.Errorf("types=function,trigger: %s, want the trigger and the function alone", got)
	}
	if got := list(call(url.Values{"search": {"TAX"}})); got != "[function:fn_tax@120]" {
		t.Errorf("search=TAX: %s, want fn_tax alone (the search ignores case)", got)
	}
	if got := list(call(url.Values{"search": {"audit"}})); got != "[trigger:trg_payroll@120]" {
		t.Errorf("search=audit: %s, want trg_payroll (its schema holds the text)", got)
	}
	if got := list(call(url.Values{"db": {"5"}})); got != "[procedure:sales_report@60 function:fn_tax@120]" {
		t.Errorf("db=5: %s, want sales' procedure and function", got)
	}
	rec := httptest.NewRecorder()
	s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?instance="+fmt.Sprint(id)+"&part=objects&types=view", nil))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("types=view: %d, want 400 (only procedure, function, trigger)", rec.Code)
	}
}

// TestObjectExecutionSearchPastTheCutOnAStore (review part 5's finding 6): the kind and search filters apply inside
// each kind's read, before its 2,000-row cut - on an instance with 2,001 procedures in the range, a search for the
// one with the least duration (2,001st) finds it, and types=function over them lists none of the procedures; with no
// filter the list holds 2,000 rows, the longest duration first.
func TestObjectExecutionSearchPastTheCutOnAStore(t *testing.T) {
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
		fmt.Sprintf("objcut-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
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
	at := time.Now().UTC().Truncate(time.Minute).Add(-20 * time.Minute)
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read", "mssql_func_sample", "mssql_func_read"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, at)
	}
	exec(`INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs) VALUES ($1, $2, 300, 2001)`, id, at)
	// proc_1 .. proc_2001: proc_<g> ran (3000 - g) ms, so proc_2001 is the 2,001st by duration
	exec(`INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	      SELECT $1, $2, 5, 1000 + g, 'sales', 'dbo', 'proc_' || g, 'SQL_STORED_PROCEDURE', 1, 0, (3000 - g) * 1000, 0, 0, 0, 300
	        FROM generate_series(1, 2001) g`, id, at)

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(extra url.Values) []string {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {at.Add(-10 * time.Minute).Format(time.RFC3339)}, "to": {at.Add(10 * time.Minute).Format(time.RFC3339)}, "part": {"objects"}}
		for k, v := range extra {
			q[k] = v
		}
		rec := httptest.NewRecorder()
		s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", q.Encode(), rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []string
		if tb := raw["objects"]; tb != nil {
			for _, r := range tb.Rows {
				for i, c := range tb.Columns {
					if c == "object_name" {
						out = append(out, fmt.Sprint(r[i]))
					}
				}
			}
		}
		return out
	}
	if got := call(url.Values{"search": {"proc_2001"}}); fmt.Sprint(got) != "[proc_2001]" {
		t.Errorf("search=proc_2001: %v, want [proc_2001] (the 2,001st by duration: the search runs before the cut)", got)
	}
	if got := call(url.Values{"types": {"function"}}); len(got) != 0 {
		t.Errorf("types=function: %d rows, want none (no function ran)", len(got))
	}
	if got := call(nil); len(got) != 2000 || got[0] != "proc_1" || got[1999] != "proc_2000" {
		n := len(got)
		first, last := "", ""
		if n > 0 {
			first, last = got[0], got[n-1]
		}
		t.Errorf("no filter: %d rows (%s .. %s), want 2000 (proc_1 .. proc_2000, the longest duration first)", n, first, last)
	}
}
