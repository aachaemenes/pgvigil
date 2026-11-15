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
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestAgentAlertsScriptOnAStore (C13, B9d): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it),
// GET /api/mssql/agent-alerts-script gives
//   - on a SQL Server whose last read holds an enabled operator with an address ('b-ops') beside a disabled one
//     ('a-off'): applicable, operator 'b-ops', a script that names it and carries the AG block on (@include_ag 1);
//   - on one with no such operator: applicable, no operator, the script's @operator NULL with its example;
//   - on Amazon RDS, on Express (engine edition 4) and on a server whose host platform reads Linux: not applicable
//     with the platform's words and no script;
//   - on a PostgreSQL instance: 400.
func TestAgentAlertsScriptOnAStore(t *testing.T) {
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
	mk := func(name, platform, engine string) int {
		t.Helper()
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, '16.0', 160000, false, '{}'::text[], $3)`, fmt.Sprintf("%s-%d", name, sfx), platform, engine).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	srv, bare, rds, express, pg := mk("b9d-srv", "sqlserver", "sqlserver"), mk("b9d-bare", "sqlserver", "sqlserver"), mk("b9d-rds", "rdssqlserver", "sqlserver"),
		mk("b9d-exp", "sqlserver", "sqlserver"), mk("b9d-pg", "onprem", "postgres")
	linux := mk("b9d-linux", "sqlserver", "sqlserver")
	defer func() {
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		if _, err := pool.Exec(c, `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`, []int{srv, bare, rds, express, pg, linux}); err != nil {
			t.Logf("cleanup: %v", err)
		}
	}()
	for q, args := range map[string][]any{
		`INSERT INTO pgvigil.mssql_instance (instance_id, snapshot_at, engine_edition) VALUES ($1, now(), 3), ($2, now(), 3), ($3, now(), 2), ($4, now(), 4)`:                                                                                 {srv, bare, rds, express},
		`INSERT INTO pgvigil.mssql_agent_operator (instance_id, name, enabled, has_email, snapshot_at) VALUES ($1, 'a-off', false, true, now()), ($1, 'b-ops', true, true, now()), ($2, 'c-nomail', true, false, now())`:                      {srv, bare},
		`INSERT INTO pgvigil.mssql_property (instance_id, name, grp, label, value, ord, snapshot_at) VALUES ($1, 'host_platform', 'Host', 'Platform', 'Windows', 600, now()), ($2, 'host_platform', 'Host', 'Platform', 'Linux', 600, now())`: {srv, linux},
	} {
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%v\n%s", err, q)
		}
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	type reply struct {
		Applicable bool   `json:"applicable"`
		Reason     string `json:"reason"`
		Operator   string `json:"operator"`
		Script     string `json:"script"`
	}
	get := func(id int) (int, reply) {
		rec := httptest.NewRecorder()
		s.MSSQLAgentAlertsScript(rec, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/mssql/agent-alerts-script?instance=%d", id), nil))
		var r reply
		if rec.Code == http.StatusOK {
			if err := json.Unmarshal(rec.Body.Bytes(), &r); err != nil {
				t.Fatal(err)
			}
		}
		return rec.Code, r
	}
	if c, r := get(srv); c != 200 || !r.Applicable || r.Operator != "b-ops" || !strings.Contains(r.Script, "DECLARE @operator sysname = N'b-ops';") || !strings.Contains(r.Script, "DECLARE @include_ag bit = 1;") {
		t.Fatalf("the server with an operator: %d %+v", c, r.Operator)
	}
	if c, r := get(bare); c != 200 || !r.Applicable || r.Operator != "" || !strings.Contains(r.Script, "DECLARE @operator sysname = NULL;") || !strings.Contains(r.Script, "for example N'dba team'") {
		t.Fatalf("the server without an operator with an address: %d operator %q", c, r.Operator)
	}
	for name, id := range map[string]int{"Amazon RDS": rds, "Express": express, "on Linux": linux} {
		if c, r := get(id); c != 200 || r.Applicable || r.Script != "" || !strings.Contains(r.Reason, name) {
			t.Fatalf("%s: %d %+v", name, c, r)
		}
	}
	if c, _ := get(pg); c != http.StatusBadRequest {
		t.Fatalf("a PostgreSQL instance: %d, want 400", c)
	}
}
