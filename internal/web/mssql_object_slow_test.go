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

// TestMSSQLObjectSlowOnAStore (OBJ, DBA Dash's object window E10: Slow Queries fixed to the object, grouped by client
// app - SlowQueries.cs FixedObjectName, groupBy client_app_name; SlowQueriesSummary_Get's SQ.object_name = @ObjectName,
// the bare name as the capture records it, the database from the context): /api/mssql/procs part=object_slow&name=
// [&dbname=] reads the window's rpc_completed / sql_batch_completed rows of 0065's mssql_slow_events with that object
// name (case-insensitive) in that database (none given: every database), one row per client app, the longest total
// first; a missing name = 400.
func TestMSSQLObjectSlowOnAStore(t *testing.T) {
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
		fmt.Sprintf("objsl-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_slow_events WHERE instance_id = $1`, id)
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
	exec(`SELECT pgvigil.ensure_month_partition('mssql_slow_events', $1)`, at)
	// Sales usp_a: appA 100 and 300 ms, appB 50 ms, and a statement of it (sp_statement_completed: not a completion);
	// HR usp_a: appA 999 ms; Sales other: appA 500 ms
	for i, e := range []struct {
		event, db, obj, app string
		ms                  int
	}{{"rpc_completed", "Sales", "usp_a", "appA", 100}, {"rpc_completed", "Sales", "usp_a", "appA", 300}, {"rpc_completed", "Sales", "usp_a", "appB", 50},
		{"sp_statement_completed", "Sales", "usp_a", "appA", 7000}, {"rpc_completed", "HR", "usp_a", "appA", 999}, {"rpc_completed", "Sales", "other", "appA", 500}} {
		exec(`INSERT INTO pgvigil.mssql_slow_events (instance_id, event_at, event_key, snapshot_at, event_name, duration_ms, cpu_ms, logical_reads, writes,
		        result, object_name, program_name, database_name)
		      VALUES ($1, $2, $3, $2, $4, $5, 1, 10, 0, 'OK', $6, $7, $8)`, id, at.Add(time.Duration(i)*time.Second), fmt.Sprintf("k%d", i), e.event, e.ms, e.obj, e.app, e.db)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(name, db string, wantCode int) []map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {at.Add(-time.Hour).Format(time.RFC3339)}, "to": {at.Add(time.Hour).Format(time.RFC3339)}, "part": {"object_slow"}}
		if name != "" {
			q.Set("name", name)
		}
		if db != "" {
			q.Set("dbname", db)
		}
		rec := httptest.NewRecorder()
		s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?"+q.Encode(), nil))
		if rec.Code != wantCode {
			t.Fatalf("object_slow name=%q dbname=%q: %d %s (want %d)", name, db, rec.Code, rec.Body.String(), wantCode)
		}
		if wantCode != http.StatusOK {
			return nil
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw["object_slow"]; tb != nil {
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
	row := func(r map[string]any) string {
		return fmt.Sprintf("%v %g %g %g", r["client_app"], num(r["events"]), num(r["total_ms"]), num(r["worst_ms"]))
	}
	for _, n := range []string{"usp_a", "USP_A"} {
		got := call(n, "Sales", http.StatusOK)
		if len(got) != 2 || row(got[0]) != "appA 2 400 300" || row(got[1]) != "appB 1 50 50" {
			t.Errorf("Sales %s: %v, want appA 2 completions 400 ms (worst 300) then appB 1 of 50 ms", n, got)
		}
	}
	if got := call("usp_a", "", http.StatusOK); len(got) != 2 || row(got[0]) != "appA 3 1399 999" {
		t.Errorf("usp_a in every database: %v, want appA 3 completions 1399 ms (worst 999) first", got)
	}
	call("", "Sales", http.StatusBadRequest)
}
