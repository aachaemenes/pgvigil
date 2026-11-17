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
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestSplitObjectName (OBJ, DBA Dash's object window E1): a one, two or three part name is read counting back from the
// object, a dot inside [brackets] or "quotes" is part of the name, ]] and "" inside them are one ] or ", each part is
// trimmed and an empty part is no part (DBADashGUI/Performance/DetailForm.cs SplitName L143-184).
func TestSplitObjectName(t *testing.T) {
	for _, c := range []struct{ in, db, schema, name string }{
		{"usp_a", "", "", "usp_a"},
		{"dbo.usp_a", "", "dbo", "usp_a"},
		{"Sales.dbo.usp_a", "Sales", "dbo", "usp_a"},
		{"[dbo].[usp.Get]", "", "dbo", "usp.Get"},
		{`"we""ird"."x]y"`, "", `we"ird`, "x]y"},
		{"[a]]b].c", "", "a]b", "c"},
		{"Sales..usp_a", "Sales", "", "usp_a"},
		{" dbo . usp_a ", "", "dbo", "usp_a"},
		{"a.b.c.d", "b", "c", "d"},
		{"", "", "", ""},
	} {
		db, schema, name := splitObjectName(c.in)
		if db != c.db || schema != c.schema || name != c.name {
			t.Errorf("splitObjectName(%q) = (%q, %q, %q), want (%q, %q, %q)", c.in, db, schema, name, c.db, c.schema, c.name)
		}
	}
}

// TestMSSQLObjectLookupOnAStore (OBJ E1-E2): /api/mssql/procs part=object_lookup&obj=<name>[&dbname=] finds one procedure,
// function or trigger of an instance by its name, case-insensitive, in the window's execution statistics
// (mssql_proc_sample, mssql_func_sample) and in the schema snapshot's present objects (schema_objects), one row per
// object (a statistics row wins: it carries the object id); a three-part name's database wins over dbname= (db= stays
// the endpoint's database id); each row its
// database, ids, schema, name, kind, type and source; no match = no row; a missing or over-long name = 400.
func TestMSSQLObjectLookupOnAStore(t *testing.T) {
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
		fmt.Sprintf("objlk-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_proc_sample WHERE instance_id = $1`, id)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_func_sample WHERE instance_id = $1`, id)
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
	at := time.Date(2026, 10, 12, 9, 0, 0, 0, time.UTC)
	for _, tb := range []string{"mssql_proc_sample", "mssql_func_sample"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, at)
	}
	// Sales (5): dbo.usp_a 101 and sales.usp_a 102; HR (6): dbo.usp_a 201; Sales: dbo.fn_b 301 (function), dbo.tr_c 401
	// (trigger); the schema snapshot: Sales dbo.usp_a (the same object as 101) and dbo.usp_only (no statistics)
	for _, p := range []struct {
		db     int
		dbName string
		schema string
		obj    int
		name   string
	}{{5, "Sales", "dbo", 101, "usp_a"}, {5, "Sales", "sales", 102, "usp_a"}, {6, "HR", "dbo", 201, "usp_a"}} {
		exec(`INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
		        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
		      VALUES ($1, $2, $3, $4, $5, $6, $7, 'SQL_STORED_PROCEDURE', 10, 1000, 2000, 100, 0, 0, 60)`, id, at, p.db, p.obj, p.dbName, p.schema, p.name)
	}
	for _, f := range []struct {
		kind, name, typ string
		obj             int
	}{{"function", "fn_b", "SQL_SCALAR_FUNCTION", 301}, {"trigger", "tr_c", "SQL_TRIGGER", 401}} {
		exec(`INSERT INTO pgvigil.mssql_func_sample (instance_id, snapshot_at, kind, database_id, object_id, database_name, schema_name, object_name, type_desc,
		        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
		      VALUES ($1, $2, $3, 5, $4, 'Sales', 'dbo', $5, $6, 1, 0, 100, 0, 0, 0, 60)`, id, at, f.kind, f.obj, f.name, f.typ)
	}
	for _, o := range []string{"usp_a", "usp_only"} {
		exec(`INSERT INTO pgvigil.schema_objects (instance_id, dbid, kind, identity, datname, schema_name, object_name, hash, first_seen, snapshot_at)
		      VALUES ($1, 5, 'procedure', $2, 'Sales', 'dbo', $3, 'h', $4, $4)`, id, "dbo."+o, o, at)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	lookup := func(obj, db string, wantCode int) []map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {at.Add(-time.Hour).Format(time.RFC3339)}, "to": {at.Add(time.Hour).Format(time.RFC3339)}, "part": {"object_lookup"}}
		if obj != "" {
			q.Set("obj", obj)
		}
		if db != "" {
			q.Set("dbname", db)
		}
		rec := httptest.NewRecorder()
		s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?"+q.Encode(), nil))
		if rec.Code != wantCode {
			t.Fatalf("object_lookup obj=%q db=%q: %d %s (want %d)", obj, db, rec.Code, rec.Body.String(), wantCode)
		}
		if wantCode != http.StatusOK {
			return nil
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw["object_lookup"]; tb != nil {
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
	key := func(rows []map[string]any) string {
		var k []string
		for _, r := range rows {
			k = append(k, fmt.Sprintf("%v.%v.%v/%v/%v/%v", r["database_name"], r["schema_name"], r["object_name"], r["object_id"], r["kind"], r["source"]))
		}
		return strings.Join(k, " ")
	}
	for _, c := range []struct{ obj, db, want string }{
		{"dbo.usp_a", "Sales", "Sales.dbo.usp_a/101/procedure/statistics"},
		{"DBO.USP_A", "sales", "Sales.dbo.usp_a/101/procedure/statistics"},
		{"usp_a", "Sales", "Sales.dbo.usp_a/101/procedure/statistics Sales.sales.usp_a/102/procedure/statistics"},
		{"usp_a", "", "HR.dbo.usp_a/201/procedure/statistics Sales.dbo.usp_a/101/procedure/statistics Sales.sales.usp_a/102/procedure/statistics"},
		{"HR.dbo.usp_a", "Sales", "HR.dbo.usp_a/201/procedure/statistics"},
		{"[dbo].[fn_b]", "Sales", "Sales.dbo.fn_b/301/function/statistics"},
		{"tr_c", "Sales", "Sales.dbo.tr_c/401/trigger/statistics"},
		{"usp_only", "Sales", "Sales.dbo.usp_only/<nil>/procedure/schema"},
		{"nope", "Sales", ""},
	} {
		if got := key(lookup(c.obj, c.db, http.StatusOK)); got != c.want {
			t.Errorf("object_lookup obj=%q db=%q: %q, want %q", c.obj, c.db, got, c.want)
		}
	}
	lookup("", "Sales", http.StatusBadRequest)
	lookup(strings.Repeat("x", 400), "Sales", http.StatusBadRequest)
}

// TestMSSQLObjectPageIsWired (OBJ, the lead's 11-17 13:27 / 13:42 D1 (b)): DBA Dash's object window is the page
// #/mssqlobject?i=&db=&obj=[&otab=] (web/src/mssql_object.ts) - the object in the address, every link to it a real
// href (Ctrl+click opens a tab), DBA Dash's tabs in its order (ObjectDetailControl.BuildTabs), the lookup's words for
// several matches and none; its route through scripts/PARITY-S3-wiring.patch (main.ts, router.ts, dbinfo.ts' page keys).
func TestMSSQLObjectPageIsWired(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_object.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, want := range []string{
		"export const mssqlObjectTab = 'mssqlobject';",
		"export const mssqlObjectHref = (ctx: Ctx, db: string, obj: string, tab?: string, instance = ctx.instance) =>",
		"hrefWith(ctx, mssqlObjectTab, { db, obj, otab: tab }, instance)",
		"export async function mssqlObjectView(ctx: Ctx): Promise<HTMLElement>",
		"['objexec', 'Object Execution'], ['querystats', 'Query Stats'], ['running', 'Running Queries'], ['slow', 'Slow Queries'], ['qs', 'Query Store'], ['schema', 'Schema History']",
		"part: 'object_lookup'",
		"objects match the name",
		"is not in the store",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("mssql_object.ts lacks %q", want)
		}
	}
	p, err := os.ReadFile("../../scripts/PARITY-S3-wiring.patch")
	if err != nil {
		t.Fatal(err)
	}
	patch := string(p)
	for _, want := range []string{
		"+import { mssqlObjectView, pgFunctionView } from './mssql_object';", // slice 5 widened the one import line
		"mssqldb: mssqlDbView, mssqlobject: mssqlObjectView,",
		"mssqldb: 'Database', mssqlobject: 'Object' };",
		"mssqldb: 'dbspace', mssqlobject: 'mssqlprocs' };",
		"'idx', 'dbtab', 'fg', 'obj', 'otab']",
		"'dbtab', 'fg', 'oesearch', 'obj', 'otab'];",
	} {
		if !strings.Contains(patch, want) {
			t.Errorf("PARITY-S3-wiring.patch lacks %q", want)
		}
	}
	// the hunk header of main.ts' first hunk counts the added import (git apply checks the counts)
	if !regexp.MustCompile(`(?m)^@@ -60,6 \+60,8 @@ import \{ mssqlJobs \} from './mssql_jobs';$`).MatchString(patch) {
		t.Error("PARITY-S3-wiring.patch: main.ts' first hunk header does not count two added imports (@@ -60,6 +60,8 @@)")
	}
}
