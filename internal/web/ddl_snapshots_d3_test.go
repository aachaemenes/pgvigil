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

// TestDDLSnapshotsD3 (control audit D3 a; DBA Dash's Snapshot Summary, SchemaCompare/SchemaSnapshots.cs with
// DDLSnapshots_Get and DDLSnapshotDiff_Get): /api/schema part=ddl_snapshots lists a database's (db=) or the instance's
// schema snapshots newest first, paged by DBA Dash's Page Size (100 / 200 / 500 / 1000 / 5000) and page= - a snapshot
// is a read that found changes, its Created / Modified / Dropped counted by standalone object (a column, an index or a
// constraint counts as its table modified), Validated the read before the next snapshot (the newest: the last read),
// Valid For (Days) as DATEDIFF(d) counts it, plus each database's BASELINE at its first read (which stores no change:
// its objects are its Created); part=ddl_snapshot_objects (db=, snap_at=) lists one snapshot's objects - a baseline's
// with their definition as of that read. The Snapshot Summary tab draws the list with Previous / Next / Page Size and
// the chosen snapshot's objects, in DBA Dash's words.
func TestDDLSnapshotsD3(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_db.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, w := range []string{"part: 'ddl_snapshots'", "part: 'ddl_snapshot_objects'", "[100, 200, 500, 1000, 5000]", "'Previous'", "'Next'",
		"'Snapshot Date'", "'Validated Date'", "'Valid For (Days)'", "'Days Since Validation'", "'Created'", "'Modified'", "'Dropped'"} {
		if !strings.Contains(src, w) {
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
		fmt.Sprintf("ddlsnap-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.schema_changes WHERE instance_id = $1`, `DELETE FROM pgvigil.schema_objects WHERE instance_id = $1`,
			`DELETE FROM pgvigil.schema_databases WHERE instance_id = $1`, `DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
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
	at := func(s string) time.Time { tm, _ := time.Parse("2006-01-02 15:04", s); return tm.UTC() }
	t0, t1, t2, last := at("2026-10-01 10:00"), at("2026-10-03 10:00"), at("2026-10-06 10:00"), at("2026-10-08 12:00")
	exec(`INSERT INTO pgvigil.schema_databases (instance_id, dbid, datname, snapshot_at, first_read, objects)
	      VALUES ($1, 5, 'Sales', $2, $3, 2), ($1, 6, 'HR', $2, $3, 0)`, id, last, t0)
	exec(`INSERT INTO pgvigil.schema_objects (instance_id, dbid, kind, identity, datname, schema_name, object_name, definition, hash, first_seen, snapshot_at, is_present)
	      VALUES ($1, 5, 'table', 'dbo.A', 'Sales', 'dbo', 'A', 'a1', 'h', $2, $4, true),
	             ($1, 5, 'table', 'dbo.B', 'Sales', 'dbo', 'B', 'b0', 'h', $2, $4, false),
	             ($1, 5, 'procedure', 'dbo.p', 'Sales', 'dbo', 'p', 'p0', 'h', $3, $4, true)`, id, t0, t2, last)
	ch := func(snap, prev time.Time, db int, kind, identity, name, parent, change, attr string, before, after any) {
		t.Helper()
		var p, a any
		if parent != "" {
			p = parent
		}
		if attr != "" {
			a = attr
		}
		exec(`INSERT INTO pgvigil.schema_changes (instance_id, snapshot_at, prev_at, dbid, datname, kind, identity, schema_name, object_name, parent, change, attribute, before, after)
		      VALUES ($1, $2, $3, $4, 'db', $5, $6, 'dbo', $7, $8, $9, $10, $11, $12)`, id, snap, prev, db, kind, identity, name, p, change, a, before, after)
	}
	// t1 (the read before it 10-02 23:00): A's definition changed and a column added to it - A modified, once
	ch(t1, at("2026-10-02 23:00"), 5, "table", "dbo.A", "A", "", "changed", "definition", "a0", "a1")
	ch(t1, at("2026-10-02 23:00"), 5, "column", "dbo.A.c", "c", "dbo.A", "added", "", nil, "c int")
	// t2 (the read before it 10-05 08:00): p added, B dropped
	ch(t2, at("2026-10-05 08:00"), 5, "procedure", "dbo.p", "p", "", "added", "", nil, "p0")
	ch(t2, at("2026-10-05 08:00"), 5, "table", "dbo.B", "B", "", "dropped", "", "b0", nil)
	// HR: one change of its own (another database)
	ch(t1, at("2026-10-02 23:00"), 6, "view", "dbo.v", "v", "", "added", "", nil, "v0")
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(extra url.Values) (int, []map[string]any) {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {t0.Add(-time.Hour).Format(time.RFC3339)}, "to": {last.Add(time.Hour).Format(time.RFC3339)}}
		for k, v := range extra {
			q[k] = v
		}
		rec := httptest.NewRecorder()
		s.Schema(rec, httptest.NewRequest(http.MethodGet, "/api/schema?"+q.Encode(), nil))
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
	day := func(v any) string {
		tm, err := time.Parse(time.RFC3339Nano, fmt.Sprint(v))
		if err != nil {
			return fmt.Sprint(v)
		}
		return tm.UTC().Format("01-02 15:04")
	}
	list := func(rows []map[string]any) string {
		var n []string
		for _, r := range rows {
			n = append(n, fmt.Sprint(r["database"], " ", day(r["snapshot_at"]), " valid ", day(r["validated_at"]), " ", r["valid_for_days"], "d ",
				r["created"], "/", r["modified"], "/", r["dropped"], " base ", r["baseline"]))
		}
		return strings.Join(n, " | ")
	}
	want := "Sales 10-06 10:00 valid 10-08 12:00 2d 1/0/1 base false | Sales 10-03 10:00 valid 10-05 08:00 2d 0/1/0 base false | " +
		"Sales 10-01 10:00 valid 10-02 23:00 1d 2/0/0 base true"
	if code, rows := call(url.Values{"part": {"ddl_snapshots"}, "db": {"5"}}); code != http.StatusOK || list(rows) != want {
		t.Errorf("ddl_snapshots db=5:\n got %d %s\nwant %s", code, list(rows), want)
	}
	// the instance's: HR's change and baseline beside Sales'
	if code, rows := call(url.Values{"part": {"ddl_snapshots"}}); code != http.StatusOK || len(rows) != 5 {
		t.Errorf("ddl_snapshots (the instance): %d %s, want Sales' three and HR's two", code, list(rows))
	}
	if code, rows := call(url.Values{"part": {"ddl_snapshots"}, "db": {"5"}, "page": {"2"}, "size": {"100"}}); code != http.StatusOK || len(rows) != 0 {
		t.Errorf("page=2: %d %d rows, want none", code, len(rows))
	}
	for _, bad := range []url.Values{{"size": {"7"}}, {"page": {"0"}}} {
		q := url.Values{"part": {"ddl_snapshots"}, "db": {"5"}}
		for k, v := range bad {
			q[k] = v
		}
		if code, _ := call(q); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", bad.Encode(), code)
		}
	}
	objs := func(rows []map[string]any) string {
		var n []string
		for _, r := range rows {
			n = append(n, fmt.Sprint(r["kind"], ":", r["object_name"], " ", r["change"], " ", r["after"]))
		}
		return strings.Join(n, " | ")
	}
	if code, rows := call(url.Values{"part": {"ddl_snapshot_objects"}, "db": {"5"}, "snap_at": {t1.Format(time.RFC3339)}}); code != http.StatusOK ||
		objs(rows) != "table:A changed a1 | column:c added c int" {
		t.Errorf("ddl_snapshot_objects t1: %d %s", code, objs(rows))
	}
	// the baseline: A as it was then (the 'before' of its later change), B as it was (its drop's 'before'); p came later
	if code, rows := call(url.Values{"part": {"ddl_snapshot_objects"}, "db": {"5"}, "snap_at": {t0.Format(time.RFC3339)}}); code != http.StatusOK ||
		objs(rows) != "table:A added a0 | table:B added b0" {
		t.Errorf("ddl_snapshot_objects the baseline: %d %s", code, objs(rows))
	}
	if code, _ := call(url.Values{"part": {"ddl_snapshot_objects"}, "db": {"5"}}); code != http.StatusBadRequest {
		t.Errorf("ddl_snapshot_objects without snap_at: %d, want 400", code)
	}
}
