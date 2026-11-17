package mssql

import (
	"fmt"
	"strings"
	"testing"
	"time"

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

// Inlineability: the databases asked are the ones with a listed scalar function (a trigger's database is not), and
// one database's answer becomes an 'inline_read' row and one 'inline' row per function with the flags as booleans
// (a NULL flag stays NULL).
func TestFuncInlineRows(t *testing.T) {
	rows := []collect.Row{{"kind": "function", "database_id": int64(7)}, {"kind": "trigger", "database_id": int64(9)},
		{"kind": "function", "database_id": int64(5)}, {"kind": "function", "database_id": int64(7)}}
	if got := inlineDatabases(rows); len(got) != 2 || got[0] != 5 || got[1] != 7 {
		t.Errorf("the databases asked: %v, want [5 7]", got)
	}
	got := inlineRows(5, []collect.Row{{"object_id": int64(10), "is_inlineable": int64(1), "inline_type": int64(0)},
		{"object_id": int64(11), "is_inlineable": int64(0), "inline_type": nil}})
	if len(got) != 3 || got[0]["kind"] != "inline_read" || got[0]["database_id"] != int64(5) {
		t.Fatalf("the rows: %v", got)
	}
	if got[1]["is_inlineable"] != true || got[1]["inline_type"] != false || got[2]["is_inlineable"] != false || got[2]["inline_type"] != nil {
		t.Errorf("the flags: %v / %v", got[1], got[2])
	}
	if q := fmt.Sprintf(funcInlineSQL, "[appdb]"); !strings.Contains(q, "[appdb].sys.sql_modules") || !strings.Contains(q, "o.type = 'FN'") {
		t.Errorf("the read: %s", q)
	}
	now := time.Now()
	if !funcInlineSent.due("srv|1", now) {
		t.Fatal("a database never asked is due")
	}
	funcInlineSent.mark("srv|1", now)
	if funcInlineSent.due("srv|1", now.Add(59*time.Minute)) || !funcInlineSent.due("srv|1", now.Add(time.Hour)) {
		t.Error("a database is asked again after an hour, not before")
	}
}

// A database whose functions ran but which the login cannot enter (or which is not online) is named in one note,
// by the read's own database name, else by its id; none left out = no note.
func TestFuncInlineNamesTheUnaskedDatabases(t *testing.T) {
	rows := []collect.Row{{"kind": "function", "database_id": int64(5), "database_name": "appdb"},
		{"kind": "function", "database_id": int64(6), "database_name": "pvfs2"}, {"kind": "function", "database_id": int64(7)}}
	got := inlineUnasked(rows, []int64{5, 6, 7}, map[int64]string{5: "[appdb]"})
	if len(got) != 1 || got[0]["kind"] != "collector_error" || got[0]["source"] != "sys.sql_modules" {
		t.Fatalf("the note: %v, want one collector_error from sys.sql_modules", got)
	}
	msg, _ := got[0]["message"].(string)
	for _, want := range []string{"pvfs2", "database id 7", "not read"} {
		if !strings.Contains(msg, want) {
			t.Errorf("the note %q lacks %q", msg, want)
		}
	}
	if strings.Contains(msg, "appdb") {
		t.Errorf("the note %q names appdb, which was asked", msg)
	}
	if got := inlineUnasked(rows, []int64{5, 6}, map[int64]string{5: "[appdb]", 6: "[pvfs2]"}); len(got) != 0 {
		t.Errorf("every database asked: %v, want no note", got)
	}
	var many []int64
	for i := int64(10); i < 25; i++ {
		many = append(many, i)
	}
	if g := inlineUnasked(nil, many, nil); len(g) != 1 {
		t.Errorf("fifteen databases: %v, want one note", g)
	} else if m, _ := g[0]["message"].(string); !strings.Contains(m, "and 5 more") || strings.Contains(m, "database id 20") {
		t.Errorf("fifteen databases: %q, want ten named and 'and 5 more'", m)
	}
}

// The hourly mark of a database's inlineability read is set once the run's rows are stored (AfterStore), so a run
// whose import failed asks again at the next read; a database without an inline_read row stays due.
func TestFuncInlineMarkedAfterTheStore(t *testing.T) {
	now := time.Now()
	if !funcInlineSent.due("srv-as|5", now) {
		t.Fatal("a database never asked is due")
	}
	funcStatsCollector{}.AfterStore(Info{ServerName: "srv-as"}, []collect.Row{{"kind": "inline_read", "database_id": int64(5)},
		{"kind": "function", "database_id": int64(6)}})
	if funcInlineSent.due("srv-as|5", now) {
		t.Error("database 5's stored inline read: asked again within the hour")
	}
	if !funcInlineSent.due("srv-as|6", now) {
		t.Error("database 6 had no inline read: it must stay due")
	}
}
