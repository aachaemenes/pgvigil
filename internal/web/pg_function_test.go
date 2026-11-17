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

// TestPGFunctionOnAStore (OBJ slice 5, the PostgreSQL twin of the object page: a function of pg_stat_user_functions):
// /api/pgfunction?instance=&db=<dbid>&fn=<funcid>[&part=] serves part=function (its newest read: database, schema, name,
// arguments), part=history (each read's difference from the read before it in the window, function_top's rule: a
// counter that went backwards counts its value since then; newest first) and part=schema (0058's schema_changes of the
// function's name in its schema and database - its overloads' too, each with its identity - every stored change, 200
// at most); db or fn missing = 400.
func TestPGFunctionOnAStore(t *testing.T) {
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
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("pgfn-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.function_stats WHERE instance_id = $1`, id)
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
	t0 := time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)
	exec(`SELECT pgvigil.ensure_month_partition('function_stats', $1)`, t0)
	exec(`SELECT pgvigil.ensure_month_partition('schema_changes', $1)`, t0)
	// fn 5001 public.fn_a(integer) in db 16384: t0 10 calls 100 ms (self 80), t0+5m 15 / 160 / 120, t0+10m 15 / 160 / 120,
	// t0+15m 2 / 30 / 20 (a stats reset); fn 5002 another function
	for i, r := range []struct{ calls, total, self float64 }{{10, 100, 80}, {15, 160, 120}, {15, 160, 120}, {2, 30, 20}} {
		exec(`INSERT INTO pgvigil.function_stats (instance_id, snapshot_at, dbid, datname, funcid, schema_name, func_name, args, calls, total_ms, self_ms)
		      VALUES ($1, $2, 16384, 'app', 5001, 'public', 'fn_a', 'integer', $3, $4, $5)`, id, t0.Add(time.Duration(i)*5*time.Minute), r.calls, r.total, r.self)
		exec(`INSERT INTO pgvigil.function_stats (instance_id, snapshot_at, dbid, datname, funcid, schema_name, func_name, args, calls, total_ms, self_ms)
		      VALUES ($1, $2, 16384, 'app', 5002, 'public', 'fn_b', '', 1, 1, 1)`, id, t0.Add(time.Duration(i)*5*time.Minute))
	}
	// its schema history: fn_a(integer) added, its body changed; an overload fn_a(text) added; fn_b changed
	for _, c := range []struct {
		at                  time.Duration
		ident, name, change string
	}{
		{0, "public.fn_a(integer)", "fn_a", "added"}, {24 * time.Hour, "public.fn_a(integer)", "fn_a", "changed"},
		{48 * time.Hour, "public.fn_a(text)", "fn_a", "added"}, {24 * time.Hour, "public.fn_b()", "fn_b", "changed"}} {
		exec(`INSERT INTO pgvigil.schema_changes (instance_id, snapshot_at, prev_at, dbid, datname, kind, identity, schema_name, object_name, change)
		      VALUES ($1, $2, $2 - interval '1 hour', 16384, 'app', 'function', $3, 'public', $4, $5)`, id, t0.Add(c.at), c.ident, c.name, c.change)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(prt, db, fn string, wantCode int) []map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {t0.Add(time.Minute).Format(time.RFC3339)}, "to": {t0.Add(time.Hour).Format(time.RFC3339)}, "part": {prt}}
		for k, v := range map[string]string{"db": db, "fn": fn} {
			if v != "" {
				q.Set(k, v)
			}
		}
		rec := httptest.NewRecorder()
		s.PGFunction(rec, httptest.NewRequest(http.MethodGet, "/api/pgfunction?"+q.Encode(), nil))
		if rec.Code != wantCode {
			t.Fatalf("pgfunction part=%s db=%q fn=%q: %d %s (want %d)", prt, db, fn, rec.Code, rec.Body.String(), wantCode)
		}
		if wantCode != http.StatusOK {
			return nil
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw[prt]; tb != nil {
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
	if got := call("function", "16384", "5001", http.StatusOK); len(got) != 1 || got[0]["func_name"] != "fn_a" || got[0]["args"] != "integer" || got[0]["datname"] != "app" {
		t.Errorf("part=function: %v, want public.fn_a(integer) in app", got)
	}
	// the window starts after t0: t0+5m (5 calls, 60 ms, self 40), t0+10m (0), t0+15m (the reset: 2 calls, 30 ms)
	var hist []string
	for _, h := range call("history", "16384", "5001", http.StatusOK) {
		hist = append(hist, fmt.Sprintf("%v/%v/%v", h["calls"], h["total_ms"], h["self_ms"]))
	}
	if strings.Join(hist, " ") != "2/30/20 0/0/0 5/60/40" {
		t.Errorf("part=history: %q, want newest first 2/30/20 0/0/0 5/60/40", hist)
	}
	var sch []string
	for _, c := range call("schema", "16384", "5001", http.StatusOK) {
		sch = append(sch, fmt.Sprintf("%v %v", c["identity"], c["change"]))
	}
	if strings.Join(sch, ", ") != "public.fn_a(text) added, public.fn_a(integer) changed, public.fn_a(integer) added" {
		t.Errorf("part=schema: %q, want fn_a's three changes newest first, overloads too (not fn_b's)", sch)
	}
	call("history", "", "5001", http.StatusBadRequest)
	call("history", "16384", "", http.StatusBadRequest)
}

// TestPGFunctionPageIsWired (OBJ slice 5): the PostgreSQL twin is #/pgfunction?i=&db=<dbid>&fn=<funcid>[&otab=]
// (web/src/mssql_object.ts pgFunctionView beside the SQL Server page) - DBA Dash's tabs where PostgreSQL has a twin
// (Object Execution, Schema History) and 'no PostgreSQL twin' with why for the other four; its route through
// scripts/PARITY-S3-wiring.patch (web.go's /api/pgfunction, main.ts' instance page, router.ts' drill tab, home and kept
// key, dbinfo.ts' page key), and the Statements tab's Functions grid's name cell named in join line 13 (i).
func TestPGFunctionPageIsWired(t *testing.T) {
	read := func(p string) string {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	src := read("../../web/src/mssql_object.ts")
	for _, want := range []string{
		"export const pgFunctionTab = 'pgfunction';",
		"export const pgFunctionHref = (ctx: Ctx, db: unknown, fn: unknown, tab?: string, instance = ctx.instance) =>",
		"export async function pgFunctionView(ctx: Ctx): Promise<HTMLElement>",
		"get<Record<string, Table | null>>('pgfunction'",
		"no PostgreSQL twin: pg_stat_statements names no calling function",
		"no PostgreSQL twin: pg_stat_activity names no function",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("mssql_object.ts lacks %q", want)
		}
	}
	patch := read("../../scripts/PARITY-S3-wiring.patch")
	for _, want := range []string{
		"+import { mssqlObjectView, pgFunctionView } from './mssql_object';",
		"+  dbinfo: dbinfoView, db: dbPage, table: tablePage, job: jobPage, index: indexPage, pgfunction: pgFunctionView,",
		"mssqlobject: 'Object', pgfunction: 'Function' };",
		"mssqlobject: 'mssqlprocs', pgfunction: 'statements' };",
		"'obj', 'otab', 'fn']",
		"'oesearch', 'obj', 'otab', 'fn'];",
		"+	api.HandleFunc(\"GET /api/pgfunction\", s.PGFunction)",
	} {
		if !strings.Contains(patch, want) {
			t.Errorf("PARITY-S3-wiring.patch lacks %q", want)
		}
	}
	join := read("../../scripts/PARITY-S3-join-lines.sql")
	if !strings.Contains(join, "(i) web/src/statements.ts") {
		t.Error("join line 13 does not name the Statements tab's Functions grid (i) web/src/statements.ts")
	}
}
