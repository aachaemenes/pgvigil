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

// TestObjectChartMeasuresE5 (control audit E5; DBA Dash's ObjectExecutionLineChart.cs L46-62 and its Date Grouping):
// the object page's chart offers DBA Dash's fifteen measures in its order and words on its three axes (Primary,
// Executions, Pages), Avg CPU, Executions/min and Avg Duration shown by default, with the Date Grouping list; part=history
// takes step= (DBA Dash's groupings in minutes, its buckets counted from 1900-01-01 as dbo.DateGroupingMins counts) and
// returns each measure; any other step is a 400.
func TestObjectChartMeasuresE5(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_object.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "export const objMeasures: Measure[] = [")
	if i < 0 {
		t.Fatal("mssql_object.ts: no objMeasures list")
	}
	j := strings.Index(src[i:], "];")
	var labels []string
	shown := 0
	for _, m := range regexp.MustCompile(`\{ key: '[a-z_]+', label: '([^']+)', axis: '(Primary|Executions|Pages)'(, shown: true)? \}`).FindAllStringSubmatch(src[i:i+j], -1) {
		labels = append(labels, m[1])
		if m[3] != "" {
			shown++
		}
	}
	want := "Avg CPU (sec)|Total CPU (sec)|CPU (ms/sec)|Executions/min|Max Executions/min|Execution Count|Avg Duration (sec)|Total Duration (sec)|" +
		"Duration (ms/sec)|Avg Logical Reads|Total Logical Reads|Avg Physical Reads|Total Physical Reads|Avg Writes|Total Writes"
	if strings.Join(labels, "|") != want || shown != 3 {
		t.Errorf("objMeasures:\n got %s (%d shown)\nwant %s (3 shown)", strings.Join(labels, "|"), shown, want)
	}
	for _, w := range []string{"chartToolbar('mssqlobject'", "measureCharts(", "objStep("} {
		if !strings.Contains(src, w) {
			t.Errorf("mssql_object.ts' Object Execution tab lacks %s", w)
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
		fmt.Sprintf("objchart-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_proc_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_proc_read WHERE instance_id = $1`,
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
	d0 := time.Date(2026, 10, 15, 0, 0, 0, 0, time.UTC) // a Thursday
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, d0)
	}
	// two 600-second reads of the procedure inside one 2-hour bucket
	for _, r := range []struct {
		at                          time.Duration
		runs, cpu, dur, lr, pr, wrt int
	}{{70 * time.Minute, 10, 2000000, 4000000, 100, 10, 4}, {100 * time.Minute, 30, 1000000, 2000000, 200, 20, 8}} {
		exec(`INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs) VALUES ($1, $2, 600, 1)`, id, d0.Add(r.at))
		exec(`INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
		        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
		      VALUES ($1, $2, 5, 101, 'sales', 'dbo', 'usp_chart', 'SQL_STORED_PROCEDURE', $3, $4, $5, $6, $7, $8, 600)`, id, d0.Add(r.at), r.runs, r.cpu, r.dur, r.lr, r.pr, r.wrt)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(step string) (int, []map[string]any) {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {d0.Format(time.RFC3339)}, "to": {d0.Add(4 * time.Hour).Format(time.RFC3339)},
			"db_id": {"5"}, "object": {"101"}, "part": {"history"}, "step": {step}}
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
		if tb := raw["history"]; tb != nil {
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
		switch x := v.(type) {
		case string:
			var f float64
			_, _ = fmt.Sscan(x, &f)
			return fmt.Sprint(f)
		}
		return fmt.Sprint(v)
	}
	// a bucket's start in UTC (the reply's zone is the server's)
	utc := func(v any) string {
		tm, err := time.Parse(time.RFC3339Nano, fmt.Sprint(v))
		if err != nil {
			return fmt.Sprint(v)
		}
		return tm.UTC().Format("2006-01-02T15:04:05")
	}
	code, rows := call("120")
	if code != http.StatusOK || len(rows) != 1 {
		t.Fatalf("step=120: %d, %d rows, want one 00:00 bucket", code, len(rows))
	}
	r := rows[0]
	var got []string
	for _, k := range []string{"execution_count", "total_cpu_sec", "avg_cpu_sec", "cpu_ms_sec", "executions_min", "max_executions_min",
		"total_duration_sec", "avg_duration_sec", "duration_ms_sec", "total_logical_reads", "avg_logical_reads",
		"total_physical_reads", "avg_physical_reads", "total_writes", "avg_writes"} {
		got = append(got, k+"="+num(r[k]))
	}
	// 40 runs over 1,200 seconds: 3 s CPU, 6 s duration; the second read ran 3 a minute
	if w := "execution_count=40 total_cpu_sec=3 avg_cpu_sec=0.075 cpu_ms_sec=2.5 executions_min=2 max_executions_min=3 total_duration_sec=6 " +
		"avg_duration_sec=0.15 duration_ms_sec=5 total_logical_reads=300 avg_logical_reads=7.5 total_physical_reads=30 avg_physical_reads=0.75 " +
		"total_writes=12 avg_writes=0.3"; strings.Join(got, " ") != w {
		t.Errorf("step=120:\n got %s\nwant %s", strings.Join(got, " "), w)
	}
	if at := utc(r["snapshot_at"]); at != "2026-10-15T00:00:00" {
		t.Errorf("step=120's bucket %s, want 2026-10-15T00:00:00", at)
	}
	// 7 days counted from 1900-01-01 (a Monday): the bucket starts Monday 2026-10-12, never the Unix week's Thursday
	if _, rows := call("10080"); len(rows) != 1 || utc(rows[0]["snapshot_at"]) != "2026-10-12T00:00:00" {
		t.Errorf("step=10080: %v, want one bucket at 2026-10-12T00:00:00", rows)
	}
	if code, _ := call("7"); code != http.StatusBadRequest {
		t.Errorf("step=7: %d, want 400", code)
	}
}
