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

// TestDDLExportD3b (control audit D3 b; DBA Dash's Snapshot Summary Export, SchemaSnapshots.cs Export / ExportSchema
// with DBSchemaAtDate_Get: every object's DDL at that date as files): /api/schema part=ddl_at (db=, snap_at=) lists
// each standalone object of the database present at that time - first seen by then, its last add or drop by then not
// a drop - with its definition as of then (the 'before' of its first later definition change or drop, else its
// definition now). The Snapshot Summary's Export button saves them as one .sql file each in a zip (export.ts' zip).
func TestDDLExportD3b(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_db.ts")
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{"part: 'ddl_at'", "await zip(", "saveBlob(", "'Export'"} {
		if !strings.Contains(string(b), w) {
			t.Errorf("mssql_db.ts lacks %s", w)
		}
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
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("ddlat-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.schema_changes WHERE instance_id = $1`, `DELETE FROM pgvigil.schema_objects WHERE instance_id = $1`,
			`DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
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
	t0 := time.Date(2026, 10, 1, 10, 0, 0, 0, time.UTC)
	t1, t2, now := t0.Add(48*time.Hour), t0.Add(120*time.Hour), t0.Add(170*time.Hour)
	exec(`INSERT INTO pgvigil.schema_objects (instance_id, dbid, kind, identity, datname, schema_name, object_name, definition, hash, first_seen, snapshot_at, is_present)
	      VALUES ($1, 5, 'table', 'dbo.A', 'Sales', 'dbo', 'A', 'a1', 'h', $2, $4, true),
	             ($1, 5, 'table', 'dbo.B', 'Sales', 'dbo', 'B', 'b0', 'h', $2, $4, false),
	             ($1, 5, 'procedure', 'dbo.p', 'Sales', 'dbo', 'p', 'p0', 'h', $3, $4, true),
	             ($1, 5, 'column', 'dbo.A.c', 'Sales', 'dbo', 'c', 'c int', 'h', $2, $4, true)`, id, t0, t2, now)
	ch := func(at time.Time, kind, identity, name, change, attr string, before, after any) {
		t.Helper()
		var a any
		if attr != "" {
			a = attr
		}
		exec(`INSERT INTO pgvigil.schema_changes (instance_id, snapshot_at, prev_at, dbid, datname, kind, identity, schema_name, object_name, change, attribute, before, after)
		      VALUES ($1, $2, $2 - interval '1 hour', 5, 'Sales', $3, $4, 'dbo', $5, $6, $7, $8, $9)`, id, at, kind, identity, name, change, a, before, after)
	}
	ch(t1, "table", "dbo.A", "A", "changed", "definition", "a0", "a1")
	ch(t2, "procedure", "dbo.p", "p", "added", "", nil, "p0")
	ch(t2, "table", "dbo.B", "B", "dropped", "", "b0", nil)
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	at := func(snap time.Time) string {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {t0.Format(time.RFC3339)}, "to": {now.Format(time.RFC3339)}, "part": {"ddl_at"}, "db": {"5"},
			"snap_at": {snap.Format(time.RFC3339)}}
		rec := httptest.NewRecorder()
		s.Schema(rec, httptest.NewRequest(http.MethodGet, "/api/schema?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			return fmt.Sprint(rec.Code, " ", rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var n []string
		if tb := raw["ddl_at"]; tb != nil {
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				n = append(n, fmt.Sprint(m["kind"], ":", m["object_name"], "=", m["definition"]))
			}
		}
		return strings.Join(n, " ")
	}
	for _, c := range [][2]any{
		{t0, "table:A=a0 table:B=b0"},     // the first read: A before its change, B before its drop; no column (a part of A)
		{t1, "table:A=a1 table:B=b0"},     // A changed; B still there
		{t2, "procedure:p=p0 table:A=a1"}, // p added, B dropped
		{t0.Add(-time.Hour), ""},          // before the first read: nothing
	} {
		if got := at(c[0].(time.Time)); got != c[1] {
			t.Errorf("ddl_at %s: %q, want %q", c[0].(time.Time).Format(time.RFC3339), got, c[1])
		}
	}
	rec := httptest.NewRecorder()
	s.Schema(rec, httptest.NewRequest(http.MethodGet, "/api/schema?"+url.Values{"instance": {fmt.Sprint(id)}, "part": {"ddl_at"}, "db": {"5"}}.Encode(), nil))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("ddl_at without snap_at: %d, want 400", rec.Code)
	}
}
