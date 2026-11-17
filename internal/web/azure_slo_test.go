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

// TestAzureServiceObjectivesOnAStore (P25 task 9: DBA Dash's Azure Service Objectives and Resource Governance): on a
// migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it) /api/azuredb/summary part=slo_history lists each
// tier CHANGE of the scope's Azure SQL Databases (0145's governance history: a period that follows another), the old
// and the new edition, objective and limits and when it changed, the newest first; part=governance gives each
// database's governance row as last read (the view's values, gov) for the Resource Governance grid. A database
// outside the scope is in neither.
func TestAzureServiceObjectivesOnAStore(t *testing.T) {
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
	tag := fmt.Sprintf("azslo:%d", sfx)
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, ARRAY[$2]::text[], 'sqlserver')`,
		fmt.Sprintf("azslo-%d", sfx), tag).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	t1, t2 := time.Now().UTC().Add(-48*time.Hour).Truncate(time.Second), time.Now().UTC().Add(-24*time.Hour).Truncate(time.Second)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	exec(`INSERT INTO pgvigil.mssql_azuredb_governance_history (instance_id, valid_from, valid_to, edition, service_objective, dtu_limit, cpu_limit, gov)
	      VALUES ($1, $2, $3, 'Standard', 'S1', 20, NULL, '{"max_sessions": 600}'), ($1, $3, 'infinity', 'Standard', 'S3', 100, NULL, '{"max_sessions": 2400}')`, id, t1, t2)
	exec(`INSERT INTO pgvigil.mssql_azuredb_governance (instance_id, snapshot_at, since, edition, service_objective, dtu_limit, gov)
	      VALUES ($1, now(), $2, 'Standard', 'S3', 100, '{"max_sessions": 2400, "primary_group_max_workers": 200}')`, id, t2)
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	part := func(name, tagQ string) []map[string]any {
		t.Helper()
		q := url.Values{"part": {name}, "tag": {tagQ}}
		rec := httptest.NewRecorder()
		s.AzureDBSummary(rec, httptest.NewRequest(http.MethodGet, "/api/azuredb/summary?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", name, rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw[name]; tb != nil {
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
	h := part("slo_history", tag)
	if len(h) != 1 || fmt.Sprint(h[0]["old_service_objective"], ">", h[0]["new_service_objective"], " ", h[0]["old_dtu_limit"], ">", h[0]["new_dtu_limit"]) != "S1>S3 20>100" {
		t.Errorf("slo_history %v, want one change S1 -> S3, 20 -> 100 DTUs", h)
	}
	g := part("governance", tag)
	if len(g) != 1 || fmt.Sprint(g[0]["service_objective"]) != "S3" || g[0]["gov"] == nil {
		t.Errorf("governance %v, want the database's row (S3) with its gov", g)
	}
	if len(part("slo_history", "azslo:none")) != 0 || len(part("governance", "azslo:none")) != 0 {
		t.Error("another tag: rows, want none")
	}
}
