package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/web"
)

// TestDemoServeXECapturesScriptOnAStore (j16 (26)): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without
// it) the server `pgvigil demo -serve` opens (demoServe) answers a SQL Server instance's XE captures script
// (GET /api/mssql/xecaptures part=script) with the script under the configuration's default statement-text policy,
// never 'text must be full, normalized or none': the handler refuses an empty policy (fail closed), so the demo must
// hold the default an install with no query_text line holds, as serve's SetPlans gives it. sqltoolsbuild-s2's walk w4
// read the error box on every XE page of the demo's SQL Server instances (i=13, i=15).
func TestDemoServeXECapturesScriptOnAStore(t *testing.T) {
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
	name := fmt.Sprintf("demoxe-%d", time.Now().UnixNano()%1000000000)
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		name).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()

	const port = "18080"
	srv, err := demoServe(ctx, slog.New(slog.NewTextHandler(io.Discard, nil)), dsn, port, nil,
		&web.DemoDoor{DSN: dsn, Instances: []int{id}, Prefix: "demoxe-"})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	req := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/mssql/xecaptures?instance=%d&part=script", id), nil)
	req.Host = "127.0.0.1:" + port
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	body := strings.TrimSpace(rec.Body.String())
	if rec.Code != http.StatusOK {
		t.Fatalf("the demo's XE captures script for %s: HTTP %d %.300s; want 200 and the script", name, rec.Code, body)
	}
	var out struct {
		Script string `json:"script"`
		Policy string `json:"text_policy"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("the reply: %v (%.300s)", err, body)
	}
	if out.Policy != config.DefaultQueryText {
		t.Errorf("text_policy %q, want the configuration's default %q (an install with no query_text line)", out.Policy, config.DefaultQueryText)
	}
	if !strings.Contains(out.Script, "CREATE EVENT SESSION") {
		t.Errorf("the script holds no CREATE EVENT SESSION: %.300s", out.Script)
	}
}
