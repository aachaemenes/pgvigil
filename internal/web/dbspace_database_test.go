package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestDBSpaceByDatabaseOnAStore (P25, F103 DB Space): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without
// it) /api/dbspace?instance=N&db=<name> on a SQL Server instance is that database's DB Space: its row alone in
// databases, and its own size over the days in history (not the instance's total). Without db= both are the
// instance's, as before.
func TestDBSpaceByDatabaseOnAStore(t *testing.T) {
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
		fmt.Sprintf("dbspace-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_database_size WHERE instance_id = $1`, `DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
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
	at := time.Now().UTC().Add(-2 * time.Hour)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_database_size', $1)`, at)
	exec(`INSERT INTO pgvigil.mssql_files (instance_id, database_id, file_id, database_name, file_name, type_desc, filegroup, size_bytes, snapshot_at, first_seen)
	      VALUES ($1, 5, 1, 'sales', 'sales', 'ROWS', 'PRIMARY', 1000, $2, $2), ($1, 5, 2, 'sales', 'sales_log', 'LOG', NULL, 200, $2, $2),
	             ($1, 6, 1, 'hr', 'hr', 'ROWS', 'PRIMARY', 5000, $2, $2)`, id, at)
	exec(`INSERT INTO pgvigil.mssql_database_size (instance_id, snapshot_at, database_name, data_bytes, log_bytes, data_used_bytes, log_used_bytes, files)
	      VALUES ($1, $2, 'sales', 1000, 200, 600, 50, 2), ($1, $2, 'hr', 5000, 0, 4000, 0, 1)`, id, at)

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(q string) map[string][]map[string]any {
		t.Helper()
		rec := httptest.NewRecorder()
		s.DBSpace(rec, httptest.NewRequest(http.MethodGet, "/api/dbspace?instance="+fmt.Sprint(id)+q, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", q, rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		out := map[string][]map[string]any{}
		for name, tb := range raw {
			if tb == nil {
				continue
			}
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				out[name] = append(out[name], m)
			}
		}
		return out
	}
	names := func(rows []map[string]any) string {
		var n []string
		for _, r := range rows {
			n = append(n, fmt.Sprint(r["database"]))
		}
		return fmt.Sprint(n)
	}
	whole := call("")
	if got := names(whole["databases"]); got != "[hr sales]" {
		t.Errorf("the instance: databases %s, want [hr sales]", got)
	}
	if len(whole["history"]) != 1 || fmt.Sprint(whole["history"][0]["allocated_bytes"]) != "6200" {
		t.Errorf("the instance: history %v, want one bucket of 6200 bytes (both databases)", whole["history"])
	}
	sales := call("&db=sales")
	if got := names(sales["databases"]); got != "[sales]" {
		t.Errorf("db=sales: databases %s, want [sales]", got)
	}
	if len(sales["history"]) != 1 || fmt.Sprint(sales["history"][0]["allocated_bytes"]) != "1200" || fmt.Sprint(sales["history"][0]["used_bytes"]) != "650" {
		t.Errorf("db=sales: history %v, want one bucket of 1200 bytes allocated, 650 used (sales alone)", sales["history"])
	}
}
