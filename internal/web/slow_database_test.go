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

// TestSlowByDatabaseOnAStore (P25, F103 Slow Queries): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped
// without it) /api/mssql/xe?instance=N&db=<name> cuts the slow queries to the events that ran in that database - the
// shapes and the series both; without db= every database's, as the instance's Slow queries page reads them.
func TestSlowByDatabaseOnAStore(t *testing.T) {
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
		fmt.Sprintf("slowdb-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_slow_events WHERE instance_id = $1`, `DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
			if _, err := pool.Exec(context.Background(), q, id); err != nil {
				t.Error(err)
			}
		}
	}()
	at := time.Now().UTC().Truncate(time.Minute).Add(-20 * time.Minute)
	if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition('mssql_slow_events', $1)`, at); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_slow_events (instance_id, event_at, event_key, snapshot_at, event_name, database_name, shape_key, shape, duration_ms)
	      VALUES ($1, $2, 'a', $2, 'rpc_completed', 'sales', 's1', 'EXEC dbo.sales_report', 3000),
	             ($1, $2, 'b', $2, 'rpc_completed', 'sales', 's1', 'EXEC dbo.sales_report', 2000),
	             ($1, $2, 'c', $2, 'sql_batch_completed', 'hr', 'h1', 'SELECT * FROM payroll', 9000)`, id, at); err != nil {
		t.Fatal(err)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(part, db string) []map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {at.Add(-10 * time.Minute).Format(time.RFC3339)}, "to": {at.Add(10 * time.Minute).Format(time.RFC3339)}, "part": {part}}
		if db != "" {
			q.Set("db", db)
		}
		rec := httptest.NewRecorder()
		s.MSSQLXE(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/xe?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", q.Encode(), rec.Code, rec.Body.String())
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
	shapes := func(db string) string {
		var n []string
		for _, r := range call("slow_shapes", db) {
			n = append(n, fmt.Sprint(r["shape_key"], "=", r["events"]))
		}
		return fmt.Sprint(n)
	}
	events := func(db string) float64 {
		var n float64
		for _, r := range call("slow_series", db) {
			if v, ok := r["events"].(float64); ok {
				n += v
			}
		}
		return n
	}
	if got := shapes(""); got != "[h1=1 s1=2]" {
		t.Errorf("the instance: shapes %s, want [h1=1 s1=2] (hr's 9 s first)", got)
	}
	if got := shapes("sales"); got != "[s1=2]" {
		t.Errorf("db=sales: shapes %s, want [s1=2] (hr's batch left out)", got)
	}
	if got := events(""); got != 3 {
		t.Errorf("the instance: %v events in the series, want 3", got)
	}
	if got := events("sales"); got != 2 {
		t.Errorf("db=sales: %v events in the series, want 2", got)
	}
}
