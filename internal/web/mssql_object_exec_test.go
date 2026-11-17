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

// TestMSSQLObjectExecutionOfAnyKindOnAStore (OBJ, DBA Dash's object window E5: Object Execution of one procedure,
// function or trigger): /api/mssql/procs db_id=&object=&kind=procedure|function|trigger reads part=intervals and
// part=history of that object from its kind's statistics (0084 mssql_proc_sample / mssql_proc_read for a procedure, 0343
// mssql_func_sample / mssql_func_read for a function or a trigger); no kind = a procedure, as before; any other kind = 400.
func TestMSSQLObjectExecutionOfAnyKindOnAStore(t *testing.T) {
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
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("objex-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read", "mssql_func_sample", "mssql_func_read"} {
			_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.`+tb+` WHERE instance_id = $1`, id)
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	t1 := time.Date(2026, 10, 12, 9, 1, 0, 0, time.UTC)
	t2 := t1.Add(time.Minute)
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read", "mssql_func_sample", "mssql_func_read"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, t1)
	}
	// the function 301: t1 2 runs over 4 ms, t2 1 run of 1 ms; the trigger 401: t2 one run; the procedure 101: t1 one run
	for _, at := range []time.Time{t1, t2} {
		exec(`INSERT INTO pgvigil.mssql_func_read (instance_id, snapshot_at, interval_secs, functions, triggers) VALUES ($1, $2, 60, 1, 1)`, id, at)
	}
	fn := func(at time.Time, kind string, obj, runs, durUS int) {
		t.Helper()
		exec(`INSERT INTO pgvigil.mssql_func_sample (instance_id, snapshot_at, kind, database_id, object_id, database_name, schema_name, object_name, type_desc,
		        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
		      VALUES ($1, $2, $3, 5, $4, 'Sales', 'dbo', $7, 'X', $5, 0, $6, 0, 0, 0, 60)`, id, at, kind, obj, runs, durUS, fmt.Sprintf("o%d", obj))
	}
	fn(t1, "function", 301, 2, 4000)
	fn(t2, "function", 301, 1, 1000)
	fn(t2, "trigger", 401, 1, 500)
	exec(`INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs) VALUES ($1, $2, 60, 1)`, id, t1)
	exec(`INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	      VALUES ($1, $2, 5, 101, 'Sales', 'dbo', 'usp_a', 'SQL_STORED_PROCEDURE', 1, 0, 3000, 0, 0, 0, 60)`, id, t1)
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(obj int, kind, prt string, wantCode int) []map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {t1.Add(-time.Hour).Format(time.RFC3339)}, "to": {t2.Add(time.Hour).Format(time.RFC3339)},
			"db_id": {"5"}, "object": {fmt.Sprint(obj)}, "part": {prt}}
		if kind != "" {
			q.Set("kind", kind)
		}
		rec := httptest.NewRecorder()
		s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?"+q.Encode(), nil))
		if rec.Code != wantCode {
			t.Fatalf("object=%d kind=%q part=%s: %d %s (want %d)", obj, kind, prt, rec.Code, rec.Body.String(), wantCode)
		}
		if wantCode != http.StatusOK {
			return nil
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw[prt]; tb != nil {
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
	num := func(v any) float64 {
		switch x := v.(type) {
		case float64:
			return x
		case string:
			var f float64
			_, _ = fmt.Sscan(x, &f)
			return f
		}
		return -1
	}
	if got := call(301, "function", "intervals", http.StatusOK); len(got) != 2 || num(got[0]["executions"]) != 1 || num(got[0]["duration_ms"]) != 1 ||
		num(got[1]["executions"]) != 2 || num(got[1]["duration_ms"]) != 4 || num(got[1]["avg_duration_ms"]) != 2 {
		t.Errorf("function 301 intervals: %v, want t2 1 run 1 ms, then t1 2 runs 4 ms (2 ms each)", got)
	}
	runs := 0.0
	for _, h := range call(301, "function", "history", http.StatusOK) {
		runs += num(h["executions"])
	}
	if runs != 3 {
		t.Errorf("function 301 history: %v runs over its steps, want 3", runs)
	}
	if got := call(401, "trigger", "intervals", http.StatusOK); len(got) != 1 || num(got[0]["duration_ms"]) != 0.5 {
		t.Errorf("trigger 401 intervals: %v, want one run of 0.5 ms", got)
	}
	for _, k := range []string{"", "procedure"} {
		if got := call(101, k, "intervals", http.StatusOK); len(got) != 1 || num(got[0]["duration_ms"]) != 3 {
			t.Errorf("procedure 101 (kind %q) intervals: %v, want one run of 3 ms", k, got)
		}
	}
	call(301, "view", "intervals", http.StatusBadRequest)
}
