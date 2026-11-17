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

// TestDDLInstancesD3c (control audit D3 c; DBA Dash's Snapshot Summary over every instance, SchemaSnapshots.cs
// LoadInstanceSummary with DDLSnapshotInstanceSummary_Get - Instance, Last Updated, Last Validated - and its Instance
// link): /api/schema part=ddl_instances (no instance=; tag= narrows) lists each instance with schema reads, its newest
// snapshot over its databases (a change, else a first read) and its newest read, the newest first; the root page
// 'Schema Snapshots' (the wiring patch: rootTabs, rootGroups' Configuration, rootPages) draws it, the Instance link
// opening that instance's list over its databases (sinst=, ddlSnapshots with a DB column).
func TestDDLInstancesD3c(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	for f, ws := range map[string][]string{
		"../../web/src/mssql_db.ts": {"export async function schemaSnapshotsView(", "part: 'ddl_instances'", "hashParam('sinst')", "'Last Updated'", "'Last Validated'",
			"label: 'Instance'", "{ key: 'database', label: 'DB' }"},
		"../../scripts/PARITY-S3-wiring.patch": {"+import { mssqlDbView, schemaSnapshotsView } from './mssql_db';", "schemasnapshots: schemaSnapshotsView",
			"schemasnapshots: 'Schema Snapshots'", "'diff', 'schemasnapshots'"},
	} {
		src := read(f)
		for _, w := range ws {
			if !strings.Contains(src, w) {
				t.Errorf("%s lacks %s", f, w)
			}
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
	sfx := time.Now().UnixNano() % 1000000000
	tag := fmt.Sprintf("ddlinst:%d", sfx)
	var ids []int
	for _, n := range []string{"a", "b", "c"} {
		var id int
		tags := []string{tag}
		if n == "c" {
			tags = []string{}
		}
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, $2::text[], 'sqlserver')`,
			fmt.Sprintf("ddlinst-%s-%d", n, sfx), tags).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.schema_changes WHERE instance_id = ANY ($1)`, `DELETE FROM pgvigil.schema_databases WHERE instance_id = ANY ($1)`,
			`DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`} {
			if _, err := pool.Exec(context.Background(), q, ids); err != nil {
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
	// a: two databases, a change on the second at t0+3d, read last t0+5d; b: one database never changed, read last t0+1d
	exec(`INSERT INTO pgvigil.schema_databases (instance_id, dbid, datname, snapshot_at, first_read, objects)
	      VALUES ($1, 5, 'Sales', $3, $4, 1), ($1, 6, 'HR', $5, $4, 1), ($2, 5, 'Ledger', $6, $4, 1), ($7, 5, 'Other', $6, $4, 1)`,
		ids[0], ids[1], t0.Add(120*time.Hour), t0, t0.Add(96*time.Hour), t0.Add(24*time.Hour), ids[2])
	exec(`INSERT INTO pgvigil.schema_changes (instance_id, snapshot_at, prev_at, dbid, datname, kind, identity, schema_name, object_name, change, attribute, before, after)
	      VALUES ($1, $2, $2 - interval '1 hour', 6, 'HR', 'view', 'dbo.v', 'dbo', 'v', 'added', NULL, NULL, 'v0')`, ids[0], t0.Add(72*time.Hour))
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	rec := httptest.NewRecorder()
	s.Schema(rec, httptest.NewRequest(http.MethodGet, "/api/schema?"+url.Values{"part": {"ddl_instances"}, "tag": {tag}}.Encode(), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("ddl_instances: %d %s", rec.Code, rec.Body.String())
	}
	raw := map[string]*table{}
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	day := func(v any) string {
		tm, err := time.Parse(time.RFC3339Nano, fmt.Sprint(v))
		if err != nil {
			return fmt.Sprint(v)
		}
		return tm.UTC().Format("01-02")
	}
	var got []string
	if tb := raw["ddl_instances"]; tb != nil {
		for _, r := range tb.Rows {
			m := map[string]any{}
			for i, c := range tb.Columns {
				m[c] = r[i]
			}
			got = append(got, fmt.Sprint(m["instance"], " ", day(m["last_updated"]), " ", day(m["last_validated"]), " ", m["databases"]))
		}
	}
	want := fmt.Sprintf("ddlinst-a-%d 10-04 10-06 2 | ddlinst-b-%d 10-01 10-02 1", sfx, sfx)
	if strings.Join(got, " | ") != want {
		t.Errorf("ddl_instances tag=%s:\n got %s\nwant %s (c is not in the tag)", tag, strings.Join(got, " | "), want)
	}
}
