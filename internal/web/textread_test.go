package web

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// storedText: the repository's tables (and views) that hold statement text under the capture's policy, with the
// columns that hold it (TEXT-NOW's sweep; the DONE lists every read).
var storedText = map[string][]string{
	"query_text": {"query"}, "statement_text": {"query"}, "log_events": {"statement", "detail", "message"},
	"slow_events": {"statement"}, "slow_events_all": {"statement"}, "plans": {"query", "plan_text"},
	"vacuum_running": {"query"}, "schema_ddl_log": {"statement"}, "pgaudit_events": {"statement", "parameters"},
	"mssql_qs_query": {"query_text"}, "mssql_qs_plan": {"plan_xml"}, "mssql_pc_text": {"query"}, "mssql_pc_list": {"query"},
	"mssql_requests": {"statement"}, "mssql_requests_v": {"statement"}, "mssql_deadlocks": {"victim_statement", "graph", "processes"},
	"mssql_blocked_reports": {"blocking_statement", "blocked_statement", "report"}, "mssql_slow_events": {"statement", "shape"},
	"mssql_attentions": {"statement"}, "mssql_ag_events": {"statement"}, "mssql_trace_events": {"statement"},
	"mssql_audit_events": {"statement"}, "mssql_memory_grant_query": {"statement"}, "mssql_running_plan": {"plan_xml"},
	"mssql_live_plan": {"plan_xml"}, "mssql_statement_text": {"statement"},
}

// textReadAllowed: a SQL text that names a stored text column without returning it, by its constant's name: why.
var textReadAllowed = map[string]string{
	"sqlIOCheckpointLines":    "the checkpoint lines: a server message kind (logparse.DetailIsMessage), kept under every policy",
	"sqlIOCheckpointLog":      "the checkpoint lines: a server message kind (logparse.DetailIsMessage), kept under every policy",
	"sqlLogTempTotal":         "sums the sizes the server's temp_file lines state; returns no text",
	"sqlLogGroupBase":         "the CTE of the log group reads: sqlLogGroups and sqlLogGroupRows tag what they return, the others return counts",
	"repFailedCTE":            "the CTE of the failed-login reads: sqlRepFailedBy's reason and sqlRepFailedDetail tag what they return, sqlRepFailedServer returns counts",
	"sqlMSSQLRunningPlanXML":  "scanned by its handler under planPolicy now (q_mssql_qs_plans.go, 'not shown')",
	"sqlMSSQLQSPlanXML":       "scanned by MSSQLQueryStorePlan under planPolicy now",
	"sqlMSSQLXEDeadlockGraph": "scanned by its .xdl handler under planPolicy now",
	"sqlPgDeadlockEvents":     "scanned by PgDeadlocks through textRule.row",
	"sqlPlanForSuggest":       "scanned by planForSuggest through textRule.row",
}

var sqlTableRE = regexp.MustCompile(`pgvigil\.(\w+)\s+(?:AS\s+)?([a-z][a-z0-9_]*)\b`)

// TestStoredTextTagged: every SQL text of the package that reads a stored-text table and names one of its text
// columns through the table's alias carries a role tag ('"<name>@<role>"', textread.go), so its reply follows the
// instance's query_text policy NOW; a text that only filters on the column is listed in textReadAllowed with why.
func TestStoredTextTagged(t *testing.T) {
	fset := token.NewFileSet()
	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatalf("the package's files: %v", err)
	}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		// the name a literal is bound to: the const / var it starts, else the function it sits in
		name := map[*ast.BasicLit]string{}
		ast.Inspect(af, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.ValueSpec:
				for _, v := range x.Values {
					ast.Inspect(v, func(m ast.Node) bool {
						if bl, ok := m.(*ast.BasicLit); ok && len(x.Names) > 0 {
							name[bl] = x.Names[0].Name
						}
						return true
					})
				}
			case *ast.FuncDecl:
				if x.Body != nil {
					ast.Inspect(x.Body, func(m ast.Node) bool {
						if bl, ok := m.(*ast.BasicLit); ok {
							if _, seen := name[bl]; !seen {
								name[bl] = x.Name.Name
							}
						}
						return true
					})
				}
			}
			return true
		})
		ast.Inspect(af, func(n ast.Node) bool {
			bl, ok := n.(*ast.BasicLit)
			if !ok || bl.Kind != token.STRING {
				return true
			}
			sql, err := strconv.Unquote(bl.Value)
			if err != nil || !strings.Contains(sql, "SELECT") {
				return true
			}
			if strings.Contains(sql, textRoleSep) && regexp.MustCompile(`"[a-z_]*@[a-z]+"`).MatchString(sql) {
				return true
			}
			for _, m := range sqlTableRE.FindAllStringSubmatch(sql, -1) {
				cols, ok := storedText[m[1]]
				if !ok {
					continue
				}
				for _, c := range cols {
					if regexp.MustCompile(`\b` + m[2] + `\.` + c + `\b`).MatchString(sql) {
						if _, ok := textReadAllowed[name[bl]]; !ok {
							t.Errorf("%s: %s reads pgvigil.%s.%s with no role tag: tag the column (textread.go) or list it in textReadAllowed with why",
								fset.Position(bl.Pos()), name[bl], m[1], c)
						}
					}
				}
			}
			return true
		})
	}
}

// TestTextRule: the read rule on one table per policy (the capture's rule again).
func TestTextRule(t *testing.T) {
	tr := &textRule{byID: map[int]string{1: "full", 2: "normalized", 3: "none"}, def: "full"}
	mk := func() *table {
		return &table{Columns: []string{"instance_id@inst", "query@stmt", "plan@doc", "x"},
			Rows: [][]any{{int32(1), "SELECT 1 WHERE a = 'secret'", "<plan/>", "k"}, {int32(2), "SELECT 1 WHERE a = 'secret'", "<plan/>", "k"},
				{int32(3), "SELECT 1 WHERE a = 'secret'", "<plan/>", "k"}, {nil, "SELECT 1 WHERE a = 'secret'", "<plan/>", "k"}}}
	}
	tb := mk()
	tr.table(tb, 0, false)
	if strings.Join(tb.Columns, ",") != "instance_id,query,plan,x" {
		t.Fatalf("columns %v", tb.Columns)
	}
	if tb.Rows[0][1] != "SELECT 1 WHERE a = 'secret'" || tb.Rows[0][2] != "<plan/>" {
		t.Errorf("full: %v", tb.Rows[0])
	}
	if s, _ := tb.Rows[1][1].(string); strings.Contains(s, "secret") || s == "" || tb.Rows[1][2] != nil {
		t.Errorf("normalized: %v", tb.Rows[1])
	}
	if tb.Rows[2][1] != nil || tb.Rows[2][2] != nil || tb.Rows[2][3] != "k" {
		t.Errorf("none: %v", tb.Rows[2])
	}
	if tb.Rows[3][1] != nil || tb.Rows[3][2] != nil {
		t.Errorf("a row with no instance: %v", tb.Rows[3])
	}
	// a place-only column is dropped; the request's own instance places an untagged row
	tb = &table{Columns: []string{"@inst", "q@stmt"}, Rows: [][]any{{int32(3), "SELECT 2"}}}
	tr.table(tb, 0, false)
	if len(tb.Columns) != 1 || tb.Columns[0] != "q" || len(tb.Rows[0]) != 1 || tb.Rows[0][0] != nil {
		t.Errorf("place-only: %v %v", tb.Columns, tb.Rows)
	}
	tb = &table{Columns: []string{"q@stmt"}, Rows: [][]any{{"SELECT 3"}}}
	tr.table(tb, 1, true)
	if tb.Rows[0][0] != "SELECT 3" {
		t.Errorf("the request's instance: %v", tb.Rows)
	}
	// a log event: a message kind keeps its detail; a deadlock's detail goes under none; a plan event's statement is full only
	tb = &table{Columns: []string{"kind@logkind", "detail@logdetail", "statement@stmt"},
		Rows: [][]any{{"corruption", "page 1 damaged", "x"}, {"deadlock", "Process 1: UPDATE t SET a = 5", "UPDATE t SET a = 5"}, {"plan", "", "Seq Scan"}}}
	tr.table(tb, 3, true)
	if tb.Rows[0][1] != "page 1 damaged" || tb.Rows[1][1] != nil || tb.Rows[1][2] != nil || tb.Rows[2][2] != nil {
		t.Errorf("log rows under none: %v", tb.Rows)
	}
	tb = &table{Columns: []string{"kind@logkind", "statement@stmt"}, Rows: [][]any{{"plan", "Seq Scan on t"}}}
	tr.table(tb, 2, true)
	if tb.Rows[0][1] != nil {
		t.Errorf("a plan event under normalized: %v", tb.Rows)
	}
	// a deadlock's processes: each statement under the rule
	tb = &table{Columns: []string{"p@stmtjson"}, Rows: [][]any{{[]any{map[string]any{"statement": "DELETE FROM t WHERE id = 7", "spid": 1.0}}}}}
	tr.table(tb, 3, true)
	if p := tb.Rows[0][0].([]any)[0].(map[string]any); p["statement"] != nil || p["spid"] != 1.0 {
		t.Errorf("processes under none: %v", p)
	}
	// a slow event's shape under none: a procedure's name stays, a statement's shape goes
	tb = &table{Columns: []string{"shape@shape", "object_name@obj"}, Rows: [][]any{{"dbo.p", "dbo.p"}, {"SELECT ? FROM t", nil}}}
	tr.table(tb, 3, true)
	if tb.Rows[0][0] != "dbo.p" || tb.Rows[1][0] != nil {
		t.Errorf("shapes under none: %v", tb.Rows)
	}
	// a union's other branch keeps its words
	tb = &table{Columns: []string{"text@stmt", "@keep"}, Rows: [][]any{{"DBCC FREEPROCCACHE", false}, {"cachestore flush", true}}}
	tr.table(tb, 3, true)
	if tb.Rows[0][0] != nil || tb.Rows[1][0] != "cachestore flush" {
		t.Errorf("keep: %v", tb.Rows)
	}
	// every instance under full: the names back, nothing else
	all := &textRule{byID: map[int]string{1: "full"}, def: "full"}
	tb = &table{Columns: []string{"q@stmt"}, Rows: [][]any{{"SELECT 4"}}}
	all.table(tb, 0, false)
	if tb.Columns[0] != "q" || tb.Rows[0][0] != "SELECT 4" {
		t.Errorf("all full: %v %v", tb.Columns, tb.Rows)
	}
	// the tables of a reply: inside a struct and a map
	out := struct {
		Plans *table `json:"plans"`
		N     int
	}{Plans: &table{}}
	if n := len(tablesIn(map[string]any{"a": &table{}, "b": out})); n != 2 {
		t.Errorf("tablesIn found %d tables, want 2", n)
	}
}
