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

// TestObjectPageEveryKindD1 (control audit D1; DBA Dash's Schema tab on every object node, Main.cs L2087 / L2102 and
// its SchemaSnapshots region: DDLHistoryForObject_Get paged by Page Size 100 / 200 / 500 / 1000 / 5000 with Previous /
// Next): the object page takes a table, a view or any standalone object of the schema snapshot - part=object_lookup
// finds it with its kind; part=object_schema&kind=<its kind> lists its own changes and its children's (a column, an
// index, a constraint or a trigger whose parent is its identity), never another table's, newest first, page= and
// size= DBA Dash's; without kind= the read keeps its procedure / function / trigger rule. The page shows such an object
// its Schema History tab alone, with DBA Dash's paging.
func TestObjectPageEveryKindD1(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_object.ts")
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{"const modules = new Set(['procedure', 'function', 'trigger'])", "[100, 200, 500, 1000, 5000]", "'Previous'", "'Next'", "kind: String(o.kind"} {
		if !strings.Contains(string(b), w) {
			t.Errorf("mssql_object.ts lacks %s", w)
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
		fmt.Sprintf("objtbl-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
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
	at := time.Now().UTC().Truncate(time.Minute).Add(-time.Hour)
	exec(`INSERT INTO pgvigil.schema_objects (instance_id, dbid, kind, identity, datname, schema_name, object_name, hash, first_seen, snapshot_at)
	      VALUES ($1, 5, 'table', 'dbo.Orders', 'Sales', 'dbo', 'Orders', 'h', $2, $2)`, id, at)
	for i, c := range []struct {
		kind, identity, name, parent, change string
	}{
		{"table", "dbo.Orders", "Orders", "", "added"},
		{"column", "dbo.Orders.Total", "Total", "dbo.Orders", "added"},
		{"index", "ix_orders_date on dbo.Orders", "ix_orders_date", "dbo.Orders", "added"},
		{"trigger", "dbo.trg_orders", "trg_orders", "dbo.Orders", "changed"},
		{"column", "dbo.Other.Total", "Total", "dbo.Other", "added"}, // another table's column
	} {
		var parent any
		if c.parent != "" {
			parent = c.parent
		}
		exec(`INSERT INTO pgvigil.schema_changes (instance_id, snapshot_at, prev_at, dbid, datname, kind, identity, schema_name, object_name, parent, change, attribute, before, after)
		      VALUES ($1, $2, $2 - interval '1 hour', 5, 'Sales', $3, $4, 'dbo', $5, $6, $7, NULL, NULL, 'x')`, id, at.Add(time.Duration(i)*time.Minute), c.kind, c.identity, c.name, parent, c.change)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(extra url.Values) (int, []map[string]any) {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {at.Add(-time.Hour).Format(time.RFC3339)}, "to": {at.Add(time.Hour).Format(time.RFC3339)}}
		for k, v := range extra {
			q[k] = v
		}
		rec := httptest.NewRecorder()
		s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			return rec.Code, nil
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw[q.Get("part")]; tb != nil {
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				out = append(out, m)
			}
		}
		return rec.Code, out
	}
	if code, rows := call(url.Values{"part": {"object_lookup"}, "obj": {"dbo.Orders"}, "dbname": {"Sales"}}); code != http.StatusOK || len(rows) != 1 ||
		fmt.Sprint(rows[0]["kind"], " ", rows[0]["source"]) != "table schema" {
		t.Errorf("object_lookup dbo.Orders: %d %v, want the table from the schema snapshot", code, rows)
	}
	names := func(rows []map[string]any) string {
		var n []string
		for _, r := range rows {
			n = append(n, fmt.Sprint(r["kind"], ":", r["object_name"]))
		}
		return strings.Join(n, " ")
	}
	hist := url.Values{"part": {"object_schema"}, "db_id": {"5"}, "schema": {"dbo"}, "name": {"Orders"}, "kind": {"table"}}
	if code, rows := call(hist); code != http.StatusOK || names(rows) != "trigger:trg_orders index:ix_orders_date column:Total table:Orders" {
		t.Errorf("object_schema kind=table: %d %s, want its trigger, index, column and itself, newest first, never dbo.Other's column", code, names(rows))
	}
	// DBA Dash's paging: page 2 of size 100 is empty here; a size not on its list, or page 0, is a 400
	p2 := url.Values{"page": {"2"}, "size": {"100"}}
	for k, v := range hist {
		p2[k] = v
	}
	if code, rows := call(p2); code != http.StatusOK || len(rows) != 0 {
		t.Errorf("page=2 size=100: %d %d rows, want none", code, len(rows))
	}
	for _, bad := range []url.Values{{"size": {"7"}}, {"page": {"0"}}, {"kind": {"column"}}} {
		q := url.Values{}
		for k, v := range hist {
			q[k] = v
		}
		for k, v := range bad {
			q[k] = v
		}
		if code, _ := call(q); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", bad.Encode(), code)
		}
	}
	// without kind= the read keeps its modules' rule: the table's own rows are not listed
	old := url.Values{"part": {"object_schema"}, "db_id": {"5"}, "schema": {"dbo"}, "name": {"Orders"}}
	if code, rows := call(old); code != http.StatusOK || len(rows) != 0 {
		t.Errorf("object_schema without kind: %d %s, want none (procedure / function / trigger only)", code, names(rows))
	}
}
