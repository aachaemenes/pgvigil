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

// TestMSSQLObjectStatementsOnAStore (OBJ, DBA Dash's object window E7: the Query Stats tab = the object's statements,
// its Query Stats report by @ObjectName): /api/mssql/procs part=object_statements&db_id=&module=<schema.name> reads the
// plan cache's statements of the window (the Plan cache page's top read, sqlMSSQLPCTop) cut to that database and to the
// keys whose text names that module (0092 mssql_pc_text.object_name, 'schema.module'), case-insensitive; a missing
// db_id or module = 400.
func TestMSSQLObjectStatementsOnAStore(t *testing.T) {
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
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("objst-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_pc_sample WHERE instance_id = $1`, id)
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
	at := time.Date(2026, 10, 12, 9, 1, 0, 0, time.UTC)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_pc_sample', $1)`, at)
	// Sales (5): 0xA1 a statement of dbo.usp_a (two reads: 3 + 2 runs), 0xB2 of dbo.other; HR (6): 0xC3 of its own dbo.usp_a
	for _, s := range []struct {
		db         int
		key, obj   string
		runs, cpuU int
		after      time.Duration
	}{{5, "0xA1", "dbo.usp_a", 3, 3000, 0}, {5, "0xA1", "dbo.usp_a", 2, 2000, time.Minute}, {5, "0xB2", "dbo.other", 9, 9000, 0}, {6, "0xC3", "dbo.usp_a", 4, 4000, 0}} {
		exec(`INSERT INTO pgvigil.mssql_pc_sample (instance_id, snapshot_at, database_id, query_key, database_name, executions, cpu_us, duration_us,
		        logical_reads, physical_reads, logical_writes, row_count, spills, plans, interval_secs)
		      VALUES ($1, $2, $3, $4, 'db', $5, $6, $6, 0, 0, 0, 0, 0, 1, 60)`, id, at.Add(s.after), s.db, s.key, s.runs, s.cpuU)
		exec(`INSERT INTO pgvigil.mssql_pc_text (instance_id, query_key, database_id, object_name, query, snapshot_at, seen_at)
		      VALUES ($1, $2, $3, $4, 'SELECT 1', $5, $5) ON CONFLICT DO NOTHING`, id, s.key, s.db, s.obj, at)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(dbID, module string, wantCode int) []map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {at.Add(-time.Hour).Format(time.RFC3339)}, "to": {at.Add(time.Hour).Format(time.RFC3339)}, "part": {"object_statements"}}
		if dbID != "" {
			q.Set("db_id", dbID)
		}
		if module != "" {
			q.Set("module", module)
		}
		rec := httptest.NewRecorder()
		s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?"+q.Encode(), nil))
		if rec.Code != wantCode {
			t.Fatalf("object_statements db_id=%q module=%q: %d %s (want %d)", dbID, module, rec.Code, rec.Body.String(), wantCode)
		}
		if wantCode != http.StatusOK {
			return nil
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw["object_statements"]; tb != nil {
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
	for _, mod := range []string{"dbo.usp_a", "DBO.USP_A"} {
		got := call("5", mod, http.StatusOK)
		if len(got) != 1 || got[0]["query_key"] != "0xA1" || fmt.Sprint(got[0]["executions"]) != "5" || fmt.Sprint(got[0]["object_name"]) != "dbo.usp_a" {
			t.Errorf("db 5 module %q: %v, want one statement 0xA1 of dbo.usp_a with 5 runs", mod, got)
		}
	}
	if got := call("6", "dbo.usp_a", http.StatusOK); len(got) != 1 || got[0]["query_key"] != "0xC3" {
		t.Errorf("db 6 module dbo.usp_a: %v, want 0xC3 alone", got)
	}
	if got := call("5", "dbo.nope", http.StatusOK); len(got) != 0 {
		t.Errorf("db 5 module dbo.nope: %v, want none", got)
	}
	call("", "dbo.usp_a", http.StatusBadRequest)
	call("5", "", http.StatusBadRequest)
}
