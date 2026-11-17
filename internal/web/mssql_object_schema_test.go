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

// TestMSSQLObjectSchemaHistoryOnAStore (OBJ, DBA Dash's object window E12: Schema History - the object's changes over
// its stored snapshots, 200 at most, the newest first; ObjectSchemaHistory.cs): /api/mssql/procs part=object_schema&
// db_id=&schema=&name= reads 0058's schema_changes of that procedure, function or trigger in that database
// (case-insensitive names; every stored change, not cut by the window), each with its before / after cut as the Schema
// tab's (400 characters, the cut flag) for its compare; a missing db_id or name = 400.
func TestMSSQLObjectSchemaHistoryOnAStore(t *testing.T) {
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
		fmt.Sprintf("objsh-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.schema_changes WHERE instance_id = $1`, id)
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
	t1 := time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)
	t2 := t1.Add(24 * time.Hour)
	exec(`SELECT pgvigil.ensure_month_partition('schema_changes', $1)`, t1)
	// Sales (5): dbo.usp_a added at t1, its definition changed at t2 (v1 -> v2); dbo.other changed at t2; HR (6): dbo.usp_a added
	for _, c := range []struct {
		at                 time.Time
		db                 int
		name, change, attr string
		before, after      any
	}{{t1, 5, "usp_a", "added", "", nil, "v1"}, {t2, 5, "usp_a", "changed", "definition", "v1", "v2"}, {t2, 5, "other", "changed", "definition", "a", "b"}, {t1, 6, "usp_a", "added", "", nil, "h1"}} {
		var attr any
		if c.attr != "" {
			attr = c.attr
		}
		exec(`INSERT INTO pgvigil.schema_changes (instance_id, snapshot_at, prev_at, dbid, datname, kind, identity, schema_name, object_name, change, attribute, before, after)
		      VALUES ($1, $2, $2 - interval '1 hour', $3, 'db', 'procedure', 'dbo.' || $4::text, 'dbo', $4::text, $5, $6, $7, $8)`, id, c.at, c.db, c.name, c.change, attr, c.before, c.after)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(dbID, schema, name string, wantCode int) []map[string]any {
		t.Helper()
		// a window of one hour around t2 only: the history is not cut by it
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {t2.Add(-time.Hour).Format(time.RFC3339)}, "to": {t2.Add(time.Hour).Format(time.RFC3339)}, "part": {"object_schema"}}
		for k, v := range map[string]string{"db_id": dbID, "schema": schema, "name": name} {
			if v != "" {
				q.Set(k, v)
			}
		}
		rec := httptest.NewRecorder()
		s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?"+q.Encode(), nil))
		if rec.Code != wantCode {
			t.Fatalf("object_schema db_id=%q schema=%q name=%q: %d %s (want %d)", dbID, schema, name, rec.Code, rec.Body.String(), wantCode)
		}
		if wantCode != http.StatusOK {
			return nil
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw["object_schema"]; tb != nil {
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
	for _, n := range [][2]string{{"dbo", "usp_a"}, {"DBO", "USP_A"}} {
		got := call("5", n[0], n[1], http.StatusOK)
		if len(got) != 2 || got[0]["change"] != "changed" || got[0]["before"] != "v1" || got[0]["after"] != "v2" || got[1]["change"] != "added" || got[1]["after"] != "v1" {
			t.Errorf("Sales %s.%s: %v, want its change v1 -> v2 (t2) then its add (t1), whatever the window", n[0], n[1], got)
		}
	}
	if got := call("5", "dbo", "nope", http.StatusOK); len(got) != 0 {
		t.Errorf("Sales dbo.nope: %v, want none", got)
	}
	call("", "dbo", "usp_a", http.StatusBadRequest)
	call("5", "dbo", "", http.StatusBadRequest)
}
