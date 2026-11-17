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

// TestAzureSeriesByDateGroupingOnAStore (P25 task 10: DBA Dash's Date Grouping on the Azure DB and pool resource
// charts): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it) /api/mssql/azuredb part=days groups
// the window's minutes by UTC day as part=hours groups them by hour (each average weighed by its samples, the maximum
// the largest, the day's minutes counted, partial under 1440), and /api/mssql/pool gains part=hours and part=days over
// the pool's minutes (CPU, data IO, log write and eDTU averages weighed by samples, the CPU and workers / sessions
// maxima the largest, the storage shares the bucket's last minute's) - newest first, as the minutes are.
func TestAzureSeriesByDateGroupingOnAStore(t *testing.T) {
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
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("azseries-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	server := fmt.Sprintf("srvs-%d", sfx)
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_pool_minute WHERE server = $1`, server)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1`, id)
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
	// two UTC days of a fixed past month: day 1 two minutes (CPU 10 and 30, 4 samples each), day 2 one (50, 2 samples)
	d1 := time.Date(2026, 10, 10, 1, 0, 0, 0, time.UTC)
	d2 := d1.Add(24 * time.Hour)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_azuredb_minute', $1)`, d1)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_pool_minute', $1)`, d1)
	z := `'{0,0,0,0,0,0,0,0,0,0}'`
	for _, m := range []struct {
		at      time.Time
		samples int
		cpu     float64
	}{{d1, 4, 10}, {d1.Add(time.Minute), 4, 30}, {d2, 2, 50}} {
		exec(`INSERT INTO pgvigil.mssql_azuredb_minute (instance_id, snapshot_at, samples, avg_cpu_percent, max_cpu_percent, dtu_buckets, cpu_buckets, data_buckets, log_buckets)
		      VALUES ($1, $2, $3, $4, $4 + 5, `+z+`, `+z+`, `+z+`, `+z+`)`, id, m.at, m.samples, m.cpu)
	}
	// the pool: hour 1 two minutes (CPU 20 and 40, 4 samples each; storage used 40 then 41), hour 2 one (60, 2 samples)
	exec(`INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at) VALUES ($1, $2, 'pool1', $3)`, id, server, d1)
	for _, m := range []struct {
		at      time.Time
		samples int
		cpu     float64
		used    float64
	}{{d1, 4, 20, 40}, {d1.Add(time.Minute), 4, 40, 41}, {d1.Add(time.Hour), 2, 60, 42}} {
		exec(`INSERT INTO pgvigil.mssql_pool_minute (server, pool, snapshot_at, samples, avg_cpu_percent, max_cpu_percent, avg_edtu_percent, max_worker_percent,
		        used_storage_percent, instance_id, name_from) VALUES ($1, 'pool1', $2, $3, $4, $4 + 5, $4, 10, $5, $6, 'tag')`, server, m.at, m.samples, m.cpu, m.used, id)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(h func(http.ResponseWriter, *http.Request), path, part string) []map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {d1.Add(-time.Hour).Format(time.RFC3339)}, "to": {d2.Add(time.Hour).Format(time.RFC3339)}, "part": {part}}
		rec := httptest.NewRecorder()
		h(rec, httptest.NewRequest(http.MethodGet, path+"?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s part=%s: %d %s", path, part, rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw[part]; tb != nil {
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
	line := func(rows []map[string]any, cols ...string) string {
		var l []string
		for _, r := range rows {
			var v []string
			for _, c := range cols {
				v = append(v, fmt.Sprint(r[c]))
			}
			l = append(l, strings.Join(v, " "))
		}
		return strings.Join(l, " | ")
	}
	days := call(s.MSSQLAzureDB, "/api/mssql/azuredb", "days")
	if got, want := line(days, "minutes", "samples", "avg_cpu_percent", "max_cpu_percent", "partial"), "1 2 50 55 true | 2 8 20 35 true"; got != want {
		t.Errorf("the Azure tab's days:\n got %s\nwant %s (newest first; CPU weighed by samples; the maximum the largest)", got, want)
	}
	if len(days) == 2 {
		if at, _ := time.Parse(time.RFC3339, fmt.Sprint(days[1]["snapshot_at"])); !at.Equal(time.Date(2026, 10, 10, 0, 0, 0, 0, time.UTC)) {
			t.Errorf("day 1 at %v, want its UTC midnight", days[1]["snapshot_at"])
		}
	}
	ph := call(s.MSSQLPool, "/api/mssql/pool", "hours")
	if got, want := line(ph, "minutes", "samples", "avg_cpu_percent", "max_cpu_percent", "avg_edtu_percent", "max_worker_percent", "used_storage_percent"),
		"1 2 60 65 60 10 42 | 2 8 30 45 30 10 41"; got != want {
		t.Errorf("the pool's hours:\n got %s\nwant %s (newest first; weighed by samples; storage the hour's last minute's)", got, want)
	}
	pd := call(s.MSSQLPool, "/api/mssql/pool", "days")
	if got, want := line(pd, "minutes", "samples", "avg_cpu_percent", "max_cpu_percent", "used_storage_percent"), "3 10 36 65 42"; got != want {
		t.Errorf("the pool's days:\n got %s\nwant %s ((20x4 + 40x4 + 60x2) / 10 = 36)", got, want)
	}
}

// TestAzureChartToolbarIsWired (P25 task 10, sweep L135: DBA Dash's resource chart toolbar): the Azure tab and the
// Elastic pool page draw their charts under one toolbar (web/src/azure_charts.ts chartToolbar): Date Grouping (auto,
// minute, hour, day: the part the charts and the grid read; auto keeps the window's own rule) and Columns per chart
// (1, 2 or 3 a row); the page's own range and Refresh stay the page's; Smooth lines / Points are chart.ts's (a join
// line to its owner, not this file's). The check reads the source.
func TestAzureChartToolbarIsWired(t *testing.T) {
	read := func(file string) string {
		t.Helper()
		b, err := os.ReadFile("../../web/src/" + file)
		if err != nil {
			t.Fatalf("web/src/%s: %v", file, err)
		}
		return string(b)
	}
	tb := read("azure_charts.ts")
	for _, w := range []string{"export function chartToolbar(", "Date Grouping", "Columns per chart", "'auto'", "'minute'", "'hour'", "'day'"} {
		if !strings.Contains(tb, w) {
			t.Errorf("azure_charts.ts has no %s", w)
		}
	}
	if !regexp.MustCompile(`\[1, 2, 3\]`).MatchString(tb) {
		t.Error("azure_charts.ts offers no 1, 2 or 3 charts a row")
	}
	for _, f := range []string{"azuredb.ts", "pools.ts"} {
		src := read(f)
		if !strings.Contains(src, "chartToolbar(") || !strings.Contains(src, "from './azure_charts'") {
			t.Errorf("%s draws no chart toolbar (chartToolbar from azure_charts.ts)", f)
		}
	}
	if !strings.Contains(read("pools.ts"), "lineChart(") {
		t.Error("pools.ts draws no chart of the pool's figures")
	}
}
