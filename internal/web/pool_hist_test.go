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

// TestAzureSummaryPoolHistograms (control audit A5, on migration 0418; DBA Dash's AzureDBPoolSummary_Get with
// @DTUHist / @CPUHist / @DataHist / @LogHist, its pool grid's four histogram columns hidden by default -
// AzureSummary.Designer.cs L930-957): the Azure Summary's Elastic pools grid carries cpu_hist, data_hist, log_hist and
// dtu_hist - the window's minutes' buckets summed - NULL where no minute of the window carries them (a minute stored
// before 0418, a vCore pool's DTU); its maxima read the minutes' stored largest samples (0418), a minute stored before
// 0418 its average. The grid's table names the four in data-default-hidden (join line 14).
func TestAzureSummaryPoolHistograms(t *testing.T) {
	b, err := os.ReadFile("../../web/src/azuredb.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "sec.append(el('h3', {}, 'Elastic pools')")
	j := strings.Index(src, "DBA Dash's Pool history (P25 task 9b)")
	if i < 0 || j < i {
		t.Fatal("azuredb.ts: the Elastic pools grid is not found")
	}
	for _, w := range []string{"hist('cpu_hist', 'CPU histogram')", "hist('data_hist', 'data IO histogram')", "hist('log_hist', 'log write histogram')",
		"hist('dtu_hist', 'DTU histogram')", "['CPU histogram', 'data IO histogram', 'log write histogram', 'DTU histogram']"} {
		if !strings.Contains(src[i:j], w) {
			t.Errorf("azuredb.ts' Elastic pools grid lacks %s", w)
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
	sfx := time.Now().UnixNano() % 1000000000
	tag := fmt.Sprintf("azphist:%d", sfx)
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, ARRAY[$2]::text[], 'sqlserver')`,
		fmt.Sprintf("azphist-%d", sfx), tag).Scan(&id); err != nil {
		t.Fatal(err)
	}
	server := fmt.Sprintf("srvh-%d", sfx)
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_pool_minute WHERE server = $1`, server)
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	at := time.Now().UTC().Truncate(time.Minute).Add(-30 * time.Minute)
	bk := func(k int) []int { b := make([]int, 10); b[k] = 4; return b }
	// two minutes as the collector sends them since 0418 (pool p1: a vCore pool, no eDTU), one minute as 0128 stored it
	js, _ := json.Marshal([]map[string]any{
		{"minute": at.Format(time.RFC3339), "server": server, "pool": "p1", "name_from": "tag", "samples": 4, "avg_cpu_percent": 5, "max_cpu_percent": 8,
			"avg_data_io_percent": 10, "max_data_io_percent": 35, "avg_log_write_percent": 5, "max_log_write_percent": 7,
			"cpu_buckets": bk(0), "data_buckets": bk(1), "log_buckets": bk(0), "dtu_buckets": nil},
		{"minute": at.Add(time.Minute).Format(time.RFC3339), "server": server, "pool": "p1", "name_from": "tag", "samples": 4, "avg_cpu_percent": 95, "max_cpu_percent": 99,
			"avg_data_io_percent": 12, "max_data_io_percent": 20, "avg_log_write_percent": 6, "max_log_write_percent": 9,
			"cpu_buckets": bk(9), "data_buckets": bk(1), "log_buckets": bk(0), "dtu_buckets": nil},
	})
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_pool($1, $2, $3::jsonb)`, id, at.Add(5*time.Minute), string(js)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_pool_minute (server, pool, snapshot_at, samples, avg_cpu_percent, max_cpu_percent, avg_data_io_percent,
	        avg_log_write_percent, instance_id, name_from) VALUES ($1, 'p1', $2, 4, 50, 60, 40, 30, $3, 'tag')`, server, at.Add(2*time.Minute), id); err != nil {
		t.Fatal(err)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	q := url.Values{"from": {at.Add(-10 * time.Minute).Format(time.RFC3339)}, "to": {at.Add(10 * time.Minute).Format(time.RFC3339)}, "part": {"pools"}, "tag": {tag}}
	rec := httptest.NewRecorder()
	s.AzureDBSummary(rec, httptest.NewRequest(http.MethodGet, "/api/azuredb/summary?"+q.Encode(), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
	raw := map[string]*table{}
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	var p map[string]any
	if tb := raw["pools"]; tb != nil {
		for _, r := range tb.Rows {
			m := map[string]any{}
			for i, c := range tb.Columns {
				m[c] = r[i]
			}
			if m["server"] == server {
				p = m
			}
		}
	}
	if p == nil {
		t.Fatal("pool p1 is not listed")
	}
	// the 0128 minute adds no bucket; its data IO average (40) is its largest known, above the stored maxima (35, 20)
	got := fmt.Sprint(p["cpu_hist"], " ", p["data_hist"], " ", p["log_hist"], " ", p["dtu_hist"], " ", p["max_data_io_percent"], " ", p["max_log_write_percent"])
	if want := "[4 0 0 0 0 0 0 0 0 4] [0 8 0 0 0 0 0 0 0 0] [8 0 0 0 0 0 0 0 0 0] <nil> 40 30"; got != want {
		t.Errorf("pool p1:\n got %s\nwant %s", got, want)
	}
}
