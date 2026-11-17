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

// TestPoolMeasuresOnAStore (control audit A3, migration 0418; the lead's 11-17 14:37): import_mssql_pool (re-made by
// 0418 from its newest text) stores a minute's max_data_io_percent, max_log_write_percent and max_edtu_percent; the
// pool's minutes, hours and grouped parts carry them, and the DTUs DBA Dash charts - Avg DTU, Max DTU, DTU Limit - from
// the pool's DTU limit of 0395's limit history (the period covering the minute; the view itself holds no DTU limit,
// Microsoft Learn): none where no period covers it (the dbmanager opt-in off). The picker no longer lists those six as
// not stored.
func TestPoolMeasuresOnAStore(t *testing.T) {
	src, err := os.ReadFile("../../web/src/azure_charts.ts")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(src), "control audit A3") {
		t.Error("azure_charts.ts still lists the pool's maxima and DTUs as not stored (control audit A3)")
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
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("plmeas-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	server := fmt.Sprintf("srvm-%d", sfx)
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_pool_minute WHERE server = $1`, server)
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	d1 := time.Date(2026, 10, 10, 1, 0, 0, 0, time.UTC)
	minute := func(at time.Time, edtu, maxEdtu, maxData, maxLog float64) map[string]any {
		return map[string]any{"minute": at.Format(time.RFC3339), "server": server, "pool": "p1", "name_from": "tag", "samples": 4,
			"avg_cpu_percent": 1, "max_cpu_percent": 2, "avg_edtu_percent": edtu, "max_edtu_percent": maxEdtu,
			"max_data_io_percent": maxData, "max_log_write_percent": maxLog}
	}
	// 01:00 and 01:01 inside a limit period of 200 DTUs; 03:00 after it ends
	js, _ := json.Marshal([]map[string]any{minute(d1, 50, 80, 30, 25), minute(d1.Add(time.Minute), 30, 40, 10, 5), minute(d1.Add(2*time.Hour), 10, 20, 1, 1)})
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_pool($1, $2, $3::jsonb)`, id, d1.Add(3*time.Hour), string(js)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_pool_limit_history (instance_id, server, pool, valid_from, valid_to, dtu_limit, storage_limit_mb)
	                             VALUES ($1, $2, 'p1', $3, $4, 200, 5120)`, id, server, d1.Add(-time.Hour), d1.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	get := func(part, step string) []map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {d1.Add(-time.Hour).Format(time.RFC3339)}, "to": {d1.Add(4 * time.Hour).Format(time.RFC3339)}, "part": {part}}
		if step != "" {
			q.Set("step", step)
		}
		rec := httptest.NewRecorder()
		s.MSSQLPool(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/pool?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("part=%s: %d %s", part, rec.Code, rec.Body.String())
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
	num := func(v any) any {
		switch x := v.(type) {
		case float64:
			return x
		case string:
			var f float64
			_, _ = fmt.Sscan(x, &f)
			return f
		}
		return v
	}
	line := func(r map[string]any) string {
		return fmt.Sprintf("%v %v %v %v %v %v", num(r["max_data_io_percent"]), num(r["max_log_write_percent"]), num(r["max_edtu_percent"]),
			num(r["avg_dtu"]), num(r["max_dtu"]), num(r["dtu_limit"]))
	}
	// the minutes, newest first: 03:00 (no period: no DTUs), 01:01, 01:00 (200 DTUs: 50 % = 100 DTUs, 80 % = 160)
	mins := get("minutes", "")
	var got []string
	for _, r := range mins {
		got = append(got, line(r))
	}
	if want := "1 1 20 <nil> <nil> <nil> | 10 5 40 60 80 200 | 30 25 80 100 160 200"; strings.Join(got, " | ") != want {
		t.Errorf("minutes:\n got %s\nwant %s", strings.Join(got, " | "), want)
	}
	// the 01:00 hour and its 2-hour bucket: the two minutes' maxima, their DTUs averaged by the samples (100 and 60: 80)
	for _, p := range [][2]string{{"hours", ""}, {"grouped", "120"}} {
		rows := get(p[0], p[1])
		if len(rows) == 0 {
			t.Errorf("%s: no row", p[0])
			continue
		}
		if g := line(rows[len(rows)-1]); g != "30 25 80 80 160 200" {
			t.Errorf("%s' oldest bucket: %s, want 30 25 80 80 160 200", p[0], g)
		}
	}
}
