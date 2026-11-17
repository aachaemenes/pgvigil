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

// TestObjectCompareChartE3 (control audit E3 b, the compare chart moved from E5; DBA Dash's ObjectExecutionSummary
// RefreshChart: under Compare To a second object chart, titled '(Compare)', over the compare window): part=history_compare
// with cmp= (objCompareWindow's values) is part=history over the compare window, its own step when none is chosen; a
// cmp= not on the list is a 400. The object page reads ocmp= from its address (kept through a range change: the wiring
// patch's two key lists) and draws the compare charts; the Object Execution grid's name cell carries its Compare To.
func TestObjectCompareChartE3(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	for f, ws := range map[string][]string{
		"../../web/src/mssql_object.ts":        {"part: 'history_compare'", "hashParam('ocmp')", "'Object Execution (Compare)'"},
		"../../web/src/mssql_objexec.ts":       {"ocmp: cmpArg"},
		"../../scripts/PARITY-S3-wiring.patch": {"'obj', 'otab', 'fn', 'ocmp']", "'oesearch', 'obj', 'otab', 'fn', 'ocmp'];"},
	} {
		src := read(f)
		for _, w := range ws {
			if !strings.Contains(src, w) {
				t.Errorf("%s lacks %s", f, w)
			}
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
		fmt.Sprintf("objcmpc-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
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
	d0 := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, d0)
	}
	// the range is 12:00-14:00; one read a day earlier (the -24hrs window), 12 runs over 600 s
	yday := d0.Add(-24*time.Hour + 30*time.Minute)
	exec(`INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs) VALUES ($1, $2, 600, 1)`, id, yday)
	exec(`INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	      VALUES ($1, $2, 5, 101, 'sales', 'dbo', 'usp_cmp', 'SQL_STORED_PROCEDURE', 12, 1, 1, 0, 0, 0, 600)`, id, yday)
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(cmp string) (int, []map[string]any) {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {d0.Format(time.RFC3339)}, "to": {d0.Add(2 * time.Hour).Format(time.RFC3339)},
			"db_id": {"5"}, "object": {"101"}, "part": {"history_compare"}, "cmp": {cmp}, "step": {"60"}}
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
		if tb := raw["history_compare"]; tb != nil {
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
	code, rows := call("day")
	if code != http.StatusOK || len(rows) != 1 {
		t.Fatalf("cmp=day: %d, %d rows, want the 1-hour step of yesterday's read", code, len(rows))
	}
	tm, _ := time.Parse(time.RFC3339Nano, fmt.Sprint(rows[0]["snapshot_at"]))
	if got := fmt.Sprint(tm.UTC().Format("2006-01-02T15:04"), " ", rows[0]["execution_count"], " ", rows[0]["executions_min"]); got != "2026-10-14T12:00 12 1.2" &&
		got != "2026-10-14T12:00 12 1.200" {
		t.Errorf("cmp=day: %s, want 2026-10-14T12:00 12 1.2 (12 runs over 600 s)", got)
	}
	if code, rows := call("prev"); code != http.StatusOK || len(rows) != 0 {
		t.Errorf("cmp=prev: %d %v, want no step (nothing read 10:00-12:00)", code, rows)
	}
	if code, _ := call("month"); code != http.StatusBadRequest {
		t.Errorf("cmp=month: %d, want 400", code)
	}
}
