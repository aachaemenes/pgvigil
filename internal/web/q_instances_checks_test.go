package web

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestFileInstanceAndEngine: an instance of the file is found by its exact name; no engine named means PostgreSQL.
func TestFileInstanceAndEngine(t *testing.T) {
	a := &InstancesAdmin{File: []config.Instance{{Name: "pg-1"}, {Name: "sql-1", Engine: config.EngineSQLServer}}}
	if in, ok := a.fileInstance("sql-1"); !ok || engineOf(in) != config.EngineSQLServer {
		t.Errorf("sql-1: found %v, engine %s", ok, engineOf(in))
	}
	if in, ok := a.fileInstance("pg-1"); !ok || engineOf(in) != config.EnginePostgres {
		t.Errorf("pg-1: found %v, engine %s", ok, engineOf(in))
	}
	for _, n := range []string{"", "PG-1", "pg-1 ", "pg"} {
		if _, ok := a.fileInstance(n); ok {
			t.Errorf("%q found among the file's instances", n)
		}
	}
}

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): the page's part 'checks' (ST1) - one row per
// instance of the file and of the page with its last test, its newest ok collection's age and its failing
// collections - and op 'test' for an instance of the file: tested as the file's own dsn, the result kept by its
// name, a typed host or an unknown name left to the page's own test.
func TestInstanceChecksOnAStore(t *testing.T) {
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
	tag := time.Now().UnixNano() % 1000000000
	name := func(s string) string { return fmt.Sprintf("chk-%s-%d", s, tag) }
	user := fmt.Sprintf("chk-user-%d", tag)
	like := fmt.Sprintf("chk-%%-%d", tag)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.admin_file_tests WHERE name LIKE $1`, `DELETE FROM pgvigil.admin_instances WHERE name LIKE $1`,
			`DELETE FROM pgvigil.instances WHERE name LIKE $1`} {
			if _, err := pool.Exec(context.Background(), q, like); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_audit WHERE ui_user = $1`, user); err != nil {
			t.Error(err)
		}
	}()
	fa, fb, fself, pg := name("fa"), name("fb"), name("self"), name("page")
	// fa: collected (ok 26 s ago and an older ok), two collections failing now; fb: never seen; the page's instance: one ok
	var ida, idp int
	for n, id := range map[string]*int{fa: &ida, pg: &idp} {
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.2', 170002, false, '{}', 'postgres')`, n).Scan(id); err != nil {
			t.Fatal(err)
		}
	}
	exec(`INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, duration_ms, status, note) VALUES
	        ($1, 'activity', now() - interval '26 seconds', 5, 'ok', NULL), ($1, 'databases', now() - interval '2 hours', 5, 'ok', NULL),
	        ($1, 'tablestats', now() - interval '3 minutes', 5, 'error', 'permission denied for table t'),
	        ($1, 'jobs', now() - interval '50 minutes', 5, 'error', 'an older failure'),
	        ($1, 'serverlog', now() - interval '1 minute', 5, 'skipped', 'no read door'),
	        ($2, 'activity', now() - interval '10 minutes', 5, 'ok', NULL)`, ida, idp)
	exec(`INSERT INTO pgvigil.admin_instances (name, engine, dsn_ref, auth, host, created_by, updated_by, tested_at, tested_ok, tested_detail)
	      VALUES ($1, 'postgres', 'file:/nonexistent/chk', 'password', '192.0.2.8', $2, $2, now() - interval '1 hour', false, 'timeout')`, pg, user)
	exec(`INSERT INTO pgvigil.admin_file_tests (name, tested_at, tested_ok, tested_detail, tested_by) VALUES ($1, now() - interval '5 minutes', true, 'connected: PostgreSQL 17.2, as m', $2)`, fa, user)

	s := &Server{pool: pool, log: discardLog(), actions: &Actions{audit: pool}}
	// fself's dsn is this store's own: a server that answers; fb's resolves to nothing
	s.SetInstancesAdmin(InstancesAdmin{File: []config.Instance{{Name: fa, DSNRaw: dsn}, {Name: fb}, {Name: fself, DSNRaw: dsn}}})
	a := s.instAdmin()
	read := func() map[string]map[string]any {
		t.Helper()
		out := map[string]any{}
		if err := s.instanceChecks(ctx, a, out); err != nil {
			t.Fatal(err)
		}
		tb := out["checks"].(*table)
		rows := map[string]map[string]any{}
		for _, r := range tb.Rows {
			m := map[string]any{}
			for i, c := range tb.Columns {
				m[c] = r[i]
			}
			rows[fmt.Sprint(m["name"])] = m
		}
		return rows
	}
	rows := read()
	for _, n := range []string{fa, fb, fself, pg} {
		if rows[n] == nil {
			t.Fatalf("no checks row for %s", n)
		}
	}
	got := func(n string, cols ...string) string {
		var out []string
		for _, c := range cols {
			out = append(out, fmt.Sprint(rows[n][c]))
		}
		return strings.Join(out, "|")
	}
	if g := got(fa, "source", "tested_ok", "tested_detail", "failing_n", "failing_collection", "failing_note"); g != "file|true|connected: PostgreSQL 17.2, as m|2|tablestats|permission denied for table t" {
		t.Errorf("fa: %s", g)
	}
	if age, ok := rows[fa]["collected_age_s"].(int64); !ok || age < 26 || age > 60 {
		t.Errorf("fa's age: %v (want 26 s and a little)", rows[fa]["collected_age_s"])
	}
	if g := got(fb, "source", "tested_at", "instance_id", "last_collected", "collected_age_s", "failing_n", "failing_collection"); g != "file|<nil>|<nil>|<nil>|<nil>|0|<nil>" {
		t.Errorf("fb (never tested, never seen): %s", g)
	}
	if g := got(pg, "source", "tested_ok", "tested_detail", "failing_n"); g != "page|false|timeout|0" {
		t.Errorf("the page's instance: %s", g)
	}
	if age, ok := rows[pg]["collected_age_s"].(int64); !ok || age < 600 || age > 640 {
		t.Errorf("the page instance's age: %v (want about 600 s)", rows[pg]["collected_age_s"])
	}

	// op 'test' of a file instance: the file's own dsn, the result kept and audited
	post := func(in map[string]any) (bool, map[string]any) {
		t.Helper()
		rec := httptest.NewRecorder()
		handled := s.fileInstanceTest(rec, httptest.NewRequest(http.MethodPost, "/api/admin/instances", nil), user, in)
		var body map[string]any
		if handled {
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("the answer: %v: %s", err, rec.Body.String())
			}
			if strings.Contains(rec.Body.String(), "host=") || strings.Contains(rec.Body.String(), dsn) {
				t.Errorf("the answer holds the dsn: %s", rec.Body.String())
			}
		}
		return handled, body
	}
	if h, b := post(map[string]any{"op": "test", "name": fself}); !h || b["ok"] != true || !strings.HasPrefix(fmt.Sprint(b["detail"]), "connected: PostgreSQL ") || b["kept"] != true {
		t.Errorf("a file instance that answers: handled %v, %v", h, b)
	}
	if h, b := post(map[string]any{"op": "test", "name": fb}); !h || b["ok"] != false || b["detail"] != emptyFileDSN || b["kept"] != true {
		t.Errorf("a file instance whose dsn is empty: handled %v, %v", h, b)
	}
	rows = read()
	if g := got(fself, "tested_ok"); g != "true" {
		t.Errorf("fself after its test: %s", g)
	}
	if g := got(fb, "tested_ok", "tested_detail"); g != "false|"+emptyFileDSN {
		t.Errorf("fb after its test: %s", g)
	}
	var audited int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE ui_user = $1 AND op = 'instance tested' AND outcome = 'done' AND target IN ($2, $3)`, user, fself, fb).Scan(&audited); err != nil || audited != 2 {
		t.Errorf("audit rows of the two tests: %d (%v), want 2", audited, err)
	}
	// left to the page's own test: a typed host, a typed password, an unknown name, a name the page owns
	for label, in := range map[string]map[string]any{
		"a typed host":     {"op": "test", "name": fself, "host": "192.0.2.9"},
		"a typed password": {"op": "test", "name": fself, "password": "x"},
		"an unknown name":  {"op": "test", "name": name("nobody")},
		"the page's name":  {"op": "test", "name": pg},
	} {
		if h, _ := post(in); h {
			t.Errorf("%s was answered as a file instance's test", label)
		}
	}
}
