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
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestExecStatsDBADashControlsE6 (control audit E6; DBA Dash's Performance > Execution Stats, ObjectExecution.cs
// L255-271 and its Designer's Top / Include Other, ObjectExecutionStats_Get's measures and its {Other} row): the strip
// offers DBA Dash's fifteen measures in its order (Total Duration first, the default), Top 5 / 10 / 20 / 40, Include
// Other (on, DBA Dash's default) and the Date Grouping list; part=execstats takes those measures by DBA Dash's names
// (value: the measure; per_sec stays for the older six), include_other=1 (the objects outside the top summed per step
// into {Other}, ids -1) and step= (DBA Dash's groupings in minutes, buckets from 1900-01-01); a step or a measure not on
// the lists is a 400.
func TestExecStatsDBADashControlsE6(t *testing.T) {
	b, err := os.ReadFile("../../web/src/performance.ts")
	if err != nil {
		t.Fatal(err)
	}
	perf := string(b)
	i, j := strings.Index(perf, "const esMeasures"), strings.Index(perf, "export interface PerfCut")
	if i < 0 || j < i {
		t.Fatal("performance.ts: the strip is not found")
	}
	strip := perf[i:j]
	var labels []string
	for _, m := range regexp.MustCompile(`\['([A-Za-z_]+)', '([^']+)', '[^']*'\]`).FindAllStringSubmatch(strip[:strings.Index(strip, ";")], -1) {
		labels = append(labels, m[1]+"="+m[2])
	}
	want := "TotalDuration=Total Duration|duration_ms_per_sec=Duration (ms/sec)|AvgDuration=Avg Duration|TotalCPU=Total CPU|cpu_ms_per_sec=CPU (ms/sec)|" +
		"AvgCPU=Avg CPU|ExecutionCount=Execution Count|ExecutionsPerMin=Executions Per Min|MaxExecutionsPerMin=Max Executions Per Min|" +
		"TotalLogicalReads=Total Logical Reads|AvgLogicalReads=Avg Logical Reads|TotalPhysicalReads=Total Physical Reads|" +
		"AvgPhysicalReads=Avg Physical Reads|TotalWrites=Total Writes|AvgWrites=Avg Writes"
	if strings.Join(labels, "|") != want {
		t.Errorf("esMeasures:\n got %s\nwant %s", strings.Join(labels, "|"), want)
	}
	for _, w := range []string{"[5, 10, 20, 40]", "'Include Other'", "include_other:", "step:", "dateGroupings", "r.value", "'{Other}'"} {
		if !strings.Contains(strip, w) {
			t.Errorf("the strip lacks %s", w)
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
		fmt.Sprintf("esdd-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
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
	at := time.Date(2026, 10, 15, 0, 30, 0, 0, time.UTC) // a Thursday
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read", "mssql_func_sample", "mssql_func_read"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, at)
	}
	exec(`INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs) VALUES ($1, $2, 100, 2)`, id, at)
	exec(`INSERT INTO pgvigil.mssql_func_read (instance_id, snapshot_at, interval_secs, functions, triggers) VALUES ($1, $2, 100, 1, 0)`, id, at)
	// report: 0.5 s over 2 runs; payroll: 0.2 s over 50 runs; fn_tax: 0.1 s over 900 runs - one 100-second read each kind
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
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {at.Add(-20 * time.Minute).Format(time.RFC3339)}, "to": {at.Add(10 * time.Minute).Format(time.RFC3339)}, "part": {"execstats"}}
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
				v := fmt.Sprint(m["value"])
				if x, ok := m["value"].(string); ok {
					var f float64
					_, _ = fmt.Sscan(x, &f)
					v = fmt.Sprint(f)
				}
				out = append(out, fmt.Sprint(m["object"], "@", m["database_id"], ":", m["object_id"], "=", v))
			}
		}
		return rec.Code, out
	}
	for _, c := range []struct {
		q    url.Values
		want string
	}{
		{url.Values{"measure": {"TotalDuration"}, "top": {"1"}}, "[sales.dbo.report@5:101=0.5]"},
		{url.Values{"measure": {"TotalDuration"}, "top": {"1"}, "include_other": {"1"}}, "[sales.dbo.report@5:101=0.5 {Other}@-1:-1=0.3]"},
		// per minute: fn_tax 900 runs over 100 s = 540; the others' 52 over their 100 s = 31.2
		{url.Values{"measure": {"ExecutionsPerMin"}, "top": {"1"}, "include_other": {"1"}}, "[sales.dbo.fn_tax@5:301=540 {Other}@-1:-1=31.2]"},
		// the average over the {Other} row as a whole: (0.2 + 0.1) s over 950 runs
		{url.Values{"measure": {"AvgDuration"}, "top": {"1"}, "include_other": {"1"}}, "[sales.dbo.report@5:101=0.25 {Other}@-1:-1=0.000316]"},
		{url.Values{"measure": {"TotalLogicalReads"}, "top": {"2"}, "include_other": {"1"}}, "[hr.dbo.payroll@6:201=10 sales.dbo.report@5:101=10 {Other}@-1:-1=0]"},
	} {
		if code, got := call(c.q); code != http.StatusOK || fmt.Sprint(got) != c.want {
			t.Errorf("%s: %d %v, want %s", c.q.Encode(), code, got, c.want)
		}
	}
	// 7 days counted from 1900-01-01 (a Monday): the step starts Monday 2026-10-12
	rec := httptest.NewRecorder()
	q := url.Values{"instance": {fmt.Sprint(id)}, "from": {at.Add(-20 * time.Minute).Format(time.RFC3339)}, "to": {at.Add(10 * time.Minute).Format(time.RFC3339)},
		"part": {"execstats"}, "measure": {"TotalDuration"}, "top": {"1"}, "step": {"10080"}}
	s.Performance(rec, httptest.NewRequest(http.MethodGet, "/api/performance?"+q.Encode(), nil))
	var raw map[string]*table
	_ = json.Unmarshal(rec.Body.Bytes(), &raw)
	if tb := raw["execstats"]; rec.Code != http.StatusOK || tb == nil || len(tb.Rows) != 1 {
		t.Errorf("step=10080: %d %s", rec.Code, rec.Body.String())
	} else {
		for k, c := range tb.Columns {
			if c == "snapshot_at" {
				if tm, err := time.Parse(time.RFC3339Nano, fmt.Sprint(tb.Rows[0][k])); err != nil || tm.UTC().Format("2006-01-02T15:04") != "2026-10-12T00:00" {
					t.Errorf("step=10080's step %v, want 2026-10-12T00:00Z", tb.Rows[0][k])
				}
			}
		}
	}
	for _, bad := range []url.Values{{"measure": {"TotalDuration"}, "step": {"7"}}, {"measure": {"Bogus"}}} {
		if code, _ := call(bad); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", bad.Encode(), code)
		}
	}
}
