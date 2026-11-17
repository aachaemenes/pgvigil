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

// TestObjectExecutionDBADashTypesE1 (control audit E1; DBA Dash's ObjectExecutionSummary Type menu L245-291 with the
// object types of Microsoft Learn's sys.dm_exec_procedure_stats (P, PC, X), sys.dm_exec_trigger_stats (TR, TA) and
// sys.dm_exec_function_stats (FN), read 2026-11-17): types= takes DBA Dash's six codes - a CLR procedure, an extended
// procedure and a CLR trigger each a box of its own - beside the three kind words (every type of the kind, as before);
// each row carries its type_code; the page draws the six boxes in DBA Dash's order and the type column in its words.
func TestObjectExecutionDBADashTypesE1(t *testing.T) {
	if k, err := objectKinds("P,PC,X,TR,TA,FN,procedure"); err != nil || fmt.Sprint(k) != "[P PC X TR TA FN procedure]" {
		t.Errorf("objectKinds(the six codes and a kind) = %v, %v", k, err)
	}
	if _, err := objectKinds("FS"); err == nil {
		t.Error("objectKinds(FS) took a type DBA Dash's menu does not list")
	}
	b, err := os.ReadFile("../../web/src/mssql_objexec.ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "[['P', 'Procedure'], ['TR', 'Trigger'], ['PC', 'CLR Procedure'], ['TA', 'CLR Trigger'], ['FN', 'Scalar Function'], ['X', 'Extended Stored Procedure']]") ||
		!strings.Contains(string(b), "{ key: 'type_code', label: 'type'") {
		t.Error("mssql_objexec.ts: the Type boxes are not DBA Dash's six, or the type column does not read type_code")
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
		fmt.Sprintf("objtypes-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_proc_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_proc_read WHERE instance_id = $1`,
			`DELETE FROM pgvigil.mssql_func_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_func_read WHERE instance_id = $1`,
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
	at := time.Now().UTC().Truncate(time.Minute).Add(-20 * time.Minute)
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read", "mssql_func_sample", "mssql_func_read"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, at)
	}
	exec(`INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs) VALUES ($1, $2, 60, 3)`, id, at)
	// the durations order the list: x_ext 60, clr_proc 50, sql_proc 40, trg_clr 30, trg_sql 20, fn 10 (ms)
	exec(`INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	      VALUES ($1, $2, 5, 101, 'sales', 'dbo', 'sql_proc', 'SQL_STORED_PROCEDURE', 1, 1, 40000, 1, 0, 0, 60),
	             ($1, $2, 5, 102, 'sales', 'dbo', 'clr_proc', 'CLR_STORED_PROCEDURE', 1, 1, 50000, 1, 0, 0, 60),
	             ($1, $2, 1, 103, 'master', 'sys', 'x_ext', 'EXTENDED_STORED_PROCEDURE', 1, 1, 60000, 1, 0, 0, 60)`, id, at)
	exec(`INSERT INTO pgvigil.mssql_func_read (instance_id, snapshot_at, interval_secs, functions, triggers) VALUES ($1, $2, 60, 1, 2)`, id, at)
	exec(`INSERT INTO pgvigil.mssql_func_sample (instance_id, snapshot_at, kind, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	      VALUES ($1, $2, 'function', 5, 201, 'sales', 'dbo', 'fn', 'SQL_SCALAR_FUNCTION', 1, 1, 10000, 1, 0, 0, 60),
	             ($1, $2, 'trigger', 5, 301, 'sales', 'dbo', 'trg_sql', 'SQL_TRIGGER', 1, 1, 20000, 1, 0, 0, 60),
	             ($1, $2, 'trigger', 5, 302, 'sales', 'dbo', 'trg_clr', 'CLR_TRIGGER', 1, 1, 30000, 1, 0, 0, 60)`, id, at)
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(types string) string {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {at.Add(-10 * time.Minute).Format(time.RFC3339)}, "to": {at.Add(10 * time.Minute).Format(time.RFC3339)}, "part": {"objects"}}
		if types != "" {
			q.Set("types", types)
		}
		rec := httptest.NewRecorder()
		s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", q.Encode(), rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var n []string
		if tb := raw["objects"]; tb != nil {
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				n = append(n, fmt.Sprint(m["type_code"], ":", m["object_name"]))
			}
		}
		return strings.Join(n, " ")
	}
	for _, c := range [][2]string{
		{"", "X:x_ext PC:clr_proc P:sql_proc TA:trg_clr TR:trg_sql FN:fn"},
		{"PC", "PC:clr_proc"},
		{"P", "P:sql_proc"},
		{"X,TA", "X:x_ext TA:trg_clr"},
		{"TR,FN", "TR:trg_sql FN:fn"},
		{"procedure", "X:x_ext PC:clr_proc P:sql_proc"}, // a kind word: every type of the kind, as before
		{"trigger,P", "P:sql_proc TA:trg_clr TR:trg_sql"},
	} {
		if got := call(c[0]); got != c[1] {
			t.Errorf("types=%s:\n got %s\nwant %s", c[0], got, c[1])
		}
	}
}
