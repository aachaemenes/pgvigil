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

// TestAzureDBMeasuresOnAStore (control audit row A2: DBA Dash's Azure DB chart's measures, AzureDBResourceStats.cs
// DBColumns L72-93): /api/mssql/azuredb's minutes, hours and grouped parts carry every measure DBA Dash charts - beyond
// CPU, data IO, log write and DTU %: Avg Memory %, XTP Storage %, Avg / Max CPU % (Instance), Avg / Max Memory %
// (Instance), Max Worker %, Max Session %, Avg DTU, Max DTU, DTU Limit, CPU Limit - each average weighed by the samples.
func TestAzureDBMeasuresOnAStore(t *testing.T) {
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
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("azmeas-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1`, id)
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	d1 := time.Date(2026, 10, 10, 1, 0, 0, 0, time.UTC)
	if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition('mssql_azuredb_minute', $1)`, d1); err != nil {
		t.Fatal(err)
	}
	z := `'{0,0,0,0,0,0,0,0,0,0}'`
	// two minutes: 4 samples with XTP 10 %, instance CPU 20 % (max 30), instance memory 40 % (max 50), 5 DTUs (max 8);
	// then 4 with 30 / 40 (60) / 60 (70) / 15 (20); the limits 100 DTUs
	for i, m := range []struct{ xtp, icpu, icpuMax, imem, imemMax, dtu, dtuMax float64 }{{10, 20, 30, 40, 50, 5, 8}, {30, 40, 60, 60, 70, 15, 20}} {
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_azuredb_minute (instance_id, snapshot_at, samples, avg_cpu_percent, max_cpu_percent,
		      avg_xtp_storage_percent, max_xtp_storage_percent, avg_instance_cpu_percent, max_instance_cpu_percent, avg_instance_memory_percent,
		      max_instance_memory_percent, avg_dtu, max_dtu, dtu_limit, avg_memory_usage_percent, dtu_buckets, cpu_buckets, data_buckets, log_buckets)
		      VALUES ($1, $2, 4, 1, 2, $3, $3, $4, $5, $6, $7, $8, $9, 100, 12, `+z+`, `+z+`, `+z+`, `+z+`)`,
			id, d1.Add(time.Duration(i)*time.Minute), m.xtp, m.icpu, m.icpuMax, m.imem, m.imemMax, m.dtu, m.dtuMax); err != nil {
			t.Fatal(err)
		}
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	get := func(part, step string) map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {d1.Add(-time.Hour).Format(time.RFC3339)}, "to": {d1.Add(time.Hour).Format(time.RFC3339)}, "part": {part}}
		if step != "" {
			q.Set("step", step)
		}
		rec := httptest.NewRecorder()
		s.MSSQLAzureDB(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/azuredb?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("part=%s: %d %s", part, rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		tb := raw[part]
		if tb == nil || len(tb.Rows) == 0 {
			t.Fatalf("part=%s: no row", part)
		}
		m := map[string]any{}
		for i, c := range tb.Columns {
			m[c] = tb.Rows[len(tb.Rows)-1][i] // the oldest row (newest first): the first minute, or the one bucket
		}
		return m
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
	mins := get("minutes", "")
	for k, want := range map[string]float64{"xtp_storage_percent": 10, "avg_instance_cpu_percent": 20, "max_instance_cpu_percent": 30,
		"avg_instance_memory_percent": 40, "max_instance_memory_percent": 50, "avg_dtu": 5, "max_dtu": 8, "dtu_limit": 100, "avg_memory_usage_percent": 12} {
		if got := num(mins[k]); got != want {
			t.Errorf("minutes: %s %v, want %v", k, mins[k], want)
		}
	}
	// the hour and a 2-hour bucket: the two minutes weighed by their samples
	want := map[string]float64{"xtp_storage_percent": 20, "avg_instance_cpu_percent": 30, "max_instance_cpu_percent": 60,
		"avg_instance_memory_percent": 50, "max_instance_memory_percent": 70, "avg_dtu": 10, "max_dtu": 20, "dtu_limit": 100}
	for _, p := range [][2]string{{"hours", ""}, {"grouped", "120"}} {
		row := get(p[0], p[1])
		for k, w := range want {
			if got := num(row[k]); got != w {
				t.Errorf("%s: %s %v, want %v", p[0], k, row[k], w)
			}
		}
	}
}

// TestAzureMeasurePickerIsDBADashs (control audit rows A2 / A3): the Azure charts' toolbar offers DBA Dash's measure
// list for the database (DBColumns, 20) and the pool (PoolColumns, 13) in its order and words, with its defaults (Max
// CPU %, Max Data %, Max Log Write %), and the pages draw one chart per axis of the measures chosen.
func TestAzureMeasurePickerIsDBADashs(t *testing.T) {
	read := func(p string) string {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	src := read("../../web/src/azure_charts.ts")
	labels := func(list string) []string {
		m := regexp.MustCompile(`(?s)export const ` + list + `: Measure\[\] = \[(.*?)\];`).FindStringSubmatch(src)
		if m == nil {
			t.Fatalf("azure_charts.ts: no %s", list)
		}
		var out []string
		for _, l := range regexp.MustCompile(`label: '([^']*)'`).FindAllStringSubmatch(m[1], -1) {
			out = append(out, l[1])
		}
		return out
	}
	db := "Avg CPU %|Avg Data %|Avg Log Write %|Avg DTU %|Avg Memory %|XTP Storage %|Avg CPU % (Instance)|Avg Memory % (Instance)|Max Worker %|Max Session %|" +
		"Max CPU %|Max Data %|Max Log Write %|Max CPU % (Instance)|Max Memory % (Instance)|Max DTU %|Avg DTU|Max DTU|DTU Limit|CPU Limit"
	if got := strings.Join(labels("dbMeasures"), "|"); got != db {
		t.Errorf("dbMeasures:\n got %s\nwant %s", got, db)
	}
	pl := "Avg CPU %|Avg Data %|Avg Log Write %|Avg DTU %|Max Worker %|Max Session %|Max CPU %|Max Data %|Max Log Write %|Max DTU %|Avg DTU|Max DTU|DTU Limit"
	if got := strings.Join(labels("poolMeasures"), "|"); got != pl {
		t.Errorf("poolMeasures:\n got %s\nwant %s", got, pl)
	}
	if n := strings.Count(src, "shown: true"); n != 6 {
		t.Errorf("azure_charts.ts: %d measures shown by default, want 6 (Max CPU %%, Max Data %%, Max Log Write %% on each list)", n)
	}
	for _, f := range []string{"../../web/src/azuredb.ts", "../../web/src/pools.ts"} {
		if !strings.Contains(read(f), "measureCharts(") {
			t.Errorf("%s does not draw the chosen measures (measureCharts)", f)
		}
	}
}
