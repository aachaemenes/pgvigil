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

// TestDBOptionsByDatabaseOnAStore (P25, F103 DB Options): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped
// without it) /api/mssql/checks?instance=N&db=<name>&part=databases is that database's options row alone - the
// database page's DB Options tab; without db= every database's row, as the Checks page reads it.
func TestDBOptionsByDatabaseOnAStore(t *testing.T) {
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
		fmt.Sprintf("dbopt-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_database_option (instance_id, database_name, database_id, state, options, deviations, snapshot_at)
	      VALUES ($1, 'sales', 5, 'ONLINE', '{"page_verify": "CHECKSUM", "auto_shrink": "off"}', '{}', now()),
	             ($1, 'hr', 6, 'ONLINE', '{"page_verify": "NONE", "auto_shrink": "on"}', '{"auto_shrink": {"status": "warning"}}', now())`, id); err != nil {
		t.Fatal(err)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	names := func(q string) string {
		t.Helper()
		rec := httptest.NewRecorder()
		s.MSSQLChecks(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/checks?instance="+fmt.Sprint(id)+"&part=databases"+q, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", q, rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		tb := raw["databases"]
		if tb == nil {
			t.Fatalf("%s: no databases part", q)
		}
		col := -1
		for i, c := range tb.Columns {
			if c == "database_name" {
				col = i
			}
		}
		var n []string
		for _, r := range tb.Rows {
			n = append(n, fmt.Sprint(r[col]))
		}
		return fmt.Sprint(n)
	}
	if got := names(""); got != "[hr sales]" {
		t.Errorf("the instance: databases %s, want [hr sales]", got)
	}
	if got := names("&db=sales"); got != "[sales]" {
		t.Errorf("db=sales: databases %s, want [sales] alone", got)
	}
}
