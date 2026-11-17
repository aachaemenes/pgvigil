package mssql

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The two reads of mssql_funcstats: each its own view and its own kind, procstats' shape (one row over the cap asked
// for, the most CPU first, the resource database left out), with the names or without them.
func TestFuncStatsStatements(t *testing.T) {
	if len(funcStatsViews) != 2 {
		t.Fatalf("mssql_funcstats reads %d views, want the functions' and the triggers'", len(funcStatsViews))
	}
	want := map[string]string{"function": "sys.dm_exec_function_stats", "trigger": "sys.dm_exec_trigger_stats"}
	for _, v := range funcStatsViews {
		if want[v.kind] != v.view {
			t.Errorf("kind %q reads %q, want %q", v.kind, v.view, want[v.kind])
		}
		for _, names := range []bool{true, false} {
			q := funcStatsQuery(v.kind, v.view, names, map[string]bool{})
			for _, part := range []string{"SELECT TOP (5001) '" + v.kind + "' AS kind", "FROM " + v.view + " fs", "WHERE fs.database_id <> 32767",
				"ORDER BY fs.total_worker_time DESC, fs.plan_handle", "fs.plan_handle AS plan_handle", "fs.cached_time AS cached_time",
				"CAST(fs.execution_count AS bigint) AS execution_count", "CAST(fs.type_desc AS nvarchar(60)) AS type_desc"} {
				if !strings.Contains(q, part) {
					t.Errorf("%s (names %v) lacks %q:\n%s", v.kind, names, part, q)
				}
			}
			if strings.Contains(q, "{{") {
				t.Errorf("%s (names %v): a token was left unfilled:\n%s", v.kind, names, q)
			}
			if got := strings.Contains(q, "OBJECT_NAME(fs.object_id, fs.database_id)"); got != names {
				t.Errorf("%s: the name functions are in the statement %v, want %v", v.kind, got, names)
			}
			if !names && !strings.Contains(q, "CAST(NULL AS nvarchar(128)) AS object_name") {
				t.Errorf("%s without the names must send NULL names:\n%s", v.kind, q)
			}
		}
	}
}

// Every figure a server may lack - the spills and the 12 extremes - is that view's own column where
// sys.all_columns lists it and NULL where it does not, never a 0. sys.dm_exec_function_stats has no spills column
// at all (Microsoft Learn), so the functions' three spills figures are NULL beside ten read extremes.
func TestFuncStatsFigures(t *testing.T) {
	cols := map[string]string{"spills": "total_spills"}
	for _, c := range procStatsSpread {
		cols[c.key] = c.col
	}
	if len(cols) != 13 {
		t.Fatalf("%d figures, want the spills and 12 extremes", len(cols))
	}
	all, noSpills := map[string]bool{}, map[string]bool{}
	for key, col := range cols {
		all[col] = true
		if !strings.Contains(key, "spills") {
			noSpills[col] = true
		}
	}
	for _, v := range funcStatsViews {
		for _, names := range []bool{true, false} {
			none := funcStatsQuery(v.kind, v.view, names, map[string]bool{})
			with := funcStatsQuery(v.kind, v.view, names, all)
			part := funcStatsQuery(v.kind, v.view, names, noSpills)
			for key, col := range cols {
				null, own := "CAST(NULL AS bigint) AS "+key, "CAST(fs."+col+" AS bigint) AS "+key
				if !strings.Contains(none, null) || strings.Contains(none, "fs."+col+" ") {
					t.Errorf("%s %s (names %v): a view without %s must send NULL and not read it", v.kind, key, names, col)
				}
				if !strings.Contains(with, own) || strings.Contains(with, null) {
					t.Errorf("%s %s (names %v): a view with %s must send its own column", v.kind, key, names, col)
				}
				wantNull := strings.Contains(key, "spills")
				if strings.Contains(part, null) != wantNull || strings.Contains(part, own) == wantNull {
					t.Errorf("%s %s (names %v) on a view without spills: NULL form %v, want %v", v.kind, key, names, strings.Contains(part, null), wantNull)
				}
			}
		}
	}
}

// A DDL or logon trigger has no OBJECT_NAME: the server lists a server's under database id 1 and a database's under
// its database, both unnamed (read on SQL Server 2022). The names come from sys.server_triggers and the database's
// sys.triggers; a named row, a function row and a trigger neither catalog lists are left as they are.
func TestTriggerNames(t *testing.T) {
	rows := []collect.Row{
		{"kind": "trigger", "database_id": int64(5), "object_id": int64(100), "object_name": "t_ai", "schema_name": "dbo"},
		{"kind": "trigger", "database_id": int64(1), "object_id": int64(200), "object_name": nil},
		{"kind": "trigger", "database_id": int64(5), "object_id": int64(300), "object_name": nil},
		{"kind": "trigger", "database_id": int64(6), "object_id": int64(300), "object_name": nil},
		{"kind": "trigger", "database_id": int64(5), "object_id": int64(200), "object_name": nil},
		{"kind": "function", "database_id": int64(1), "object_id": int64(200), "object_name": nil},
		{"kind": "trigger", "database_id": int64(1), "object_id": int64(400), "object_name": nil},
	}
	server := map[int64]string{200: "srv_ddl"}
	byDB := map[int64]map[int64]string{5: {300: "db_ddl"}, 1: {400: "master_db_ddl"}}
	if got := unnamedTriggerDatabases(rows, server); len(got) != 3 || got[0] != 1 || got[1] != 5 || got[2] != 6 {
		t.Errorf("the databases whose sys.triggers is asked: %v, want [1 5 6] (a server trigger's row asks none)", got)
	}
	nameTriggers(rows, server, byDB)
	want := []struct{ name, scope any }{
		{"t_ai", nil}, {"srv_ddl", "server"}, {"db_ddl", "database"}, {nil, nil}, {nil, nil}, {nil, nil}, {"master_db_ddl", "database"},
	}
	for i, w := range want {
		if rows[i]["object_name"] != w.name || rows[i]["trigger_scope"] != w.scope {
			t.Errorf("row %d: name %v scope %v, want %v %v", i, rows[i]["object_name"], rows[i]["trigger_scope"], w.name, w.scope)
		}
	}
}
