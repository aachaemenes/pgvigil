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
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestObjectExecutionCompareToE3 (control audit E3; DBA Dash's ObjectExecutionSummary Compare To - Previous Period,
// -24hrs offset, -7 days offset, Custom, None - and ObjectExecutionStatsSummary_Get's compare_ columns and diff %):
// part=objects with cmp= (prev, day, week, or a custom window's two ends 'from,to') returns each object's figures over
// the range beside the same figures over the compare window (compare_<column>), FULL JOINed by object - an object of
// one window only keeps its row - and diff_avg_duration_pct / diff_avg_cpu_pct (the change in % of the compare
// figure), on one instance and over a node's instances; a cmp= not on the list, or a custom window whose ends are
// reversed, is a 400. The grid shows each compare column after its measure, DBA Dash's two diffs after theirs.
func TestObjectExecutionCompareToE3(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_objexec.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, w := range []string{"[['', 'None'], ['prev', 'Previous Period'], ['day', '-24hrs offset'], ['week', '-7 days offset'], ['custom', 'Custom']]",
		"`compare_${", "'diff_avg_duration_pct'", "'diff_avg_cpu_pct'", "cmp:", "fromInput("} {
		if !strings.Contains(src, w) {
			t.Errorf("mssql_objexec.ts lacks %s", w)
		}
	}
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
		fmt.Sprintf("objcmp-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
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
	at := time.Now().UTC().Truncate(time.Minute).Add(-60 * time.Minute)
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read", "mssql_func_sample", "mssql_func_read"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, at.Add(-30*time.Minute))
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, at)
	}
	old := at.Add(-20 * time.Minute) // in the previous period of the range [at-10m, at+10m]
	exec(`INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs) VALUES ($1, $2, 60, 1), ($1, $3, 60, 1)`, id, at, old)
	exec(`INSERT INTO pgvigil.mssql_func_read (instance_id, snapshot_at, interval_secs, functions, triggers) VALUES ($1, $2, 60, 1, 0), ($1, $3, 60, 1, 0)`, id, at, old)
	// report: 10 runs each window, 100 ms a run now against 50 then (+100 %), its CPU 50 ms a run both times (0 %)
	exec(`INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	      VALUES ($1, $2, 5, 101, 'sales', 'dbo', 'report', 'SQL_STORED_PROCEDURE', 10, 500000, 1000000, 1, 0, 0, 60),
	             ($1, $3, 5, 101, 'sales', 'dbo', 'report', 'SQL_STORED_PROCEDURE', 10, 500000, 500000, 1, 0, 0, 60)`, id, at, old)
	// fn_old ran in the compare window only
	exec(`INSERT INTO pgvigil.mssql_func_sample (instance_id, snapshot_at, kind, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	      VALUES ($1, $2, 'function', 5, 301, 'sales', 'dbo', 'fn_old', 'SQL_SCALAR_FUNCTION', 4, 1000, 200000, 0, 0, 0, 60)`, id, old)
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(extra url.Values) (int, []map[string]any) {
		t.Helper()
		q := url.Values{"from": {at.Add(-10 * time.Minute).Format(time.RFC3339)}, "to": {at.Add(10 * time.Minute).Format(time.RFC3339)}, "part": {"objects"}}
		for k, v := range extra {
			q[k] = v
		}
		rec := httptest.NewRecorder()
		s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			return rec.Code, nil
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
		return rec.Code, out
	}
	num := func(v any) string {
		if x, ok := v.(string); ok {
			var f float64
			_, _ = fmt.Sscan(x, &f)
			return fmt.Sprint(f)
		}
		return fmt.Sprint(v)
	}
	line := func(rows []map[string]any) string {
		var n []string
		for _, r := range rows {
			n = append(n, fmt.Sprint(r["object_name"], " ", num(r["duration_ms"]), "/", num(r["compare_duration_ms"]), " avg ", num(r["avg_duration_ms"]), "/",
				num(r["compare_avg_duration_ms"]), " diff ", num(r["diff_avg_duration_pct"]), " cpu diff ", num(r["diff_avg_cpu_pct"]), " runs ", num(r["executions"]), "/",
				num(r["compare_executions"])))
		}
		return strings.Join(n, " | ")
	}
	start, end := old.Add(-time.Minute).Format(time.RFC3339), old.Add(time.Minute).Format(time.RFC3339)
	for _, c := range []struct {
		where url.Values
		cmp   string
		want  string
	}{
		{url.Values{"instance": {fmt.Sprint(id)}}, "prev", "report 1000/500 avg 100/50 diff 100 cpu diff 0 runs 10/10 | fn_old <nil>/200 avg <nil>/50 diff <nil> cpu diff <nil> runs <nil>/4"},
		{url.Values{"instance": {fmt.Sprint(id)}}, start + "," + end, "report 1000/500 avg 100/50 diff 100 cpu diff 0 runs 10/10 | fn_old <nil>/200 avg <nil>/50 diff <nil> cpu diff <nil> runs <nil>/4"},
		// a day back: nothing ran then, the compare columns empty
		{url.Values{"instance": {fmt.Sprint(id)}}, "day", "report 1000/<nil> avg 100/<nil> diff <nil> cpu diff <nil> runs 10/<nil>"},
		{url.Values{"instances": {fmt.Sprint(id)}}, "prev", "report 1000/500 avg 100/50 diff 100 cpu diff 0 runs 10/10 | fn_old <nil>/200 avg <nil>/50 diff <nil> cpu diff <nil> runs <nil>/4"},
	} {
		q := url.Values{"cmp": {c.cmp}}
		for k, v := range c.where {
			q[k] = v
		}
		if code, rows := call(q); code != http.StatusOK || line(rows) != c.want {
			t.Errorf("%s:\n got %d %s\nwant %s", q.Encode(), code, line(rows), c.want)
		}
	}
	for _, bad := range []string{"month", end + "," + start, "yesterday,today"} {
		if code, _ := call(url.Values{"instance": {fmt.Sprint(id)}, "cmp": {bad}}); code != http.StatusBadRequest {
			t.Errorf("cmp=%s: %d, want 400", bad, code)
		}
	}
}
