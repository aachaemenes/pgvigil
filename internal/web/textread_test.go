package web

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
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
	"mssql_live_plan": {"plan_xml"}, "mssql_statement_text": {"statement"}, "mssql_waiting_tasks": {"statement"},
	"mssql_versionstore_latest": {"holder_statement"}, "mssql_versionstore_sample": {"holder_statement"},
	"vacuum_xmin_holders": {"detail"}, "pi_sql": {"digest", "full_text"},
	// a session SET's text and value: a custom setting's value can carry an application's data (full only, as captured)
	"session_sets": {"query", "value"},
	// a finding's value and detail: the checks that quote a statement (internal/textnow's findText) carry stored text,
	// in the views that hold those checks (TestChecksInMigrations ties the names to the migrations)
	"alert_state": {"value"}, "ack_suppressed": {"value"}, "alert_occurrences": {"value"}, "alert_sent": {"value"},
	"findings": {"detail", "value"}, "alert_findings": {"detail", "value"}, "findings_alerts": {"detail", "value"},
	"memory_findings": {"detail"}, "mssql_running_findings": {"detail"}, "mssql_xe_findings": {"detail", "object"},
	"mssql_storage_findings": {"detail"}, "mssql_blocking_findings": {"detail"}, "mssql_cpu_findings": {"detail"},
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
	"sqlPoolerConnTrace":      "counts over pgvigil.pooler_conns; returns no text",
	"sqlPoolerConnClients":    "the client rows of pgvigil.pooler_conns: head_query and backend_query are not selected",
	"sqlIOFindings":           "pgvigil.findings filtered to track_io_timing (a setting rule; it quotes no statement)",
	"sqlPoolerFindings":       "memory_findings filtered to the two pooler checks (they quote no statement)",
	"sqlMSSQLStorageChecks":   "mssql_storage_findings without the version store checks (the only ones of the view that quote a statement)",
}

// textFuncAllowed: a repository function whose body names a stored text column but whose result carries none: why.
var textFuncAllowed = map[string]string{
	"mssql_plan_sources": "returns has_plan, never the plan",
}

var (
	// a table's read: its name, and its alias when it has one (an un-aliased read names its columns bare)
	sqlTableRE = regexp.MustCompile(`pgvigil\.(\w+)(?:\s+(?:AS\s+)?([a-z][a-z0-9_]*))?`)
	// a function's read, whatever columns the SQL takes from it
	sqlCallRE = regexp.MustCompile(`pgvigil\.(\w+)\(`)
	textTagRE = regexp.MustCompile(`"[a-z_]*@[a-z]+"`)
)

// textTagged: a SQL text carries a role tag or the text marker (the rule then applies to every tagged column it returns).
func textTagged(sql string) bool { return textTagRE.MatchString(sql) || textMarkRE.MatchString(sql) }

// readsStoredText lists the storedText columns a SQL text names: through a table's alias, or bare beside an
// un-aliased table.
func readsStoredText(sql string) []string {
	var out []string
	for _, m := range sqlTableRE.FindAllStringSubmatch(sql, -1) {
		for _, c := range storedText[m[1]] {
			pat := `\b` + m[2] + `\.` + c + `\b`
			if m[2] == "" {
				pat = `(?:^|[^.\w"])` + c + `\b`
			}
			if regexp.MustCompile(pat).MatchString(sql) {
				out = append(out, "pgvigil."+m[1]+"."+c)
			}
		}
	}
	return out
}

// textFunc is a function a SQL text reads and the stored text column its body names.
type textFunc struct{ fn, col string }

// funcsReadingText lists the functions a SQL text reads whose body (their last definition) returns stored text; an
// import_* function is a write and returns none to a page.
func funcsReadingText(sql string, body map[string]string) []textFunc {
	var out []textFunc
	for _, m := range sqlCallRE.FindAllStringSubmatch(sql, -1) {
		b, ok := body[m[1]]
		if !ok || strings.HasPrefix(m[1], "import_") {
			continue
		}
		if cols := readsStoredText(b); len(cols) > 0 {
			out = append(out, textFunc{m[1], cols[0]})
		}
	}
	return out
}

// funcBodies: each repository function's last definition in the migrations (Glob's order is the name order, the
// order they apply in).
func funcBodies(t *testing.T) map[string]string {
	migrations, err := filepath.Glob(filepath.Join("..", "repo", "sql", "*.sql"))
	if err != nil || len(migrations) == 0 {
		t.Fatalf("the migrations: %v", err)
	}
	defRE := regexp.MustCompile(`CREATE (?:OR REPLACE )?FUNCTION pgvigil\.(\w+)\s*\(`)
	endRE := regexp.MustCompile(`\n(?:CREATE|DROP|ALTER|GRANT|REVOKE|COMMENT|DO )`)
	body := map[string]string{}
	for _, f := range migrations {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		for _, m := range defRE.FindAllStringSubmatchIndex(src, -1) {
			rest := src[m[1]:]
			end := len(rest)
			if e := endRE.FindStringIndex(rest); e != nil {
				end = e[0]
			}
			body[src[m[2]:m[3]]] = src[m[0] : m[1]+end]
		}
	}
	return body
}

// packageSQL calls f with every string literal of the package's non-test files that holds a SELECT, with its position
// and the name it is bound to (the const / var it starts, else the function it sits in).
func packageSQL(t *testing.T, f func(pos token.Position, name, sql string)) {
	fset := token.NewFileSet()
	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatalf("the package's files: %v", err)
	}
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, file, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
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
			if sql, err := strconv.Unquote(bl.Value); err == nil && strings.Contains(sql, "SELECT") {
				f(fset.Position(bl.Pos()), name[bl], sql)
			}
			return true
		})
	}
}

// TestStoredTextTagged: every SQL text of the package that names a stored text column (through a table's alias, or
// bare beside an un-aliased table) carries a role tag ('"<name>@<role>"') or the text marker (textread.go), so its
// reply follows the instance's query_text policy NOW; a text that only filters on the column, or returns none of it,
// is listed in textReadAllowed with why. A tag anywhere in a text covers it whole (a column-by-column check reads a
// CTE's or a subquery's column as returned: review 2 M2's scan, not taken).
func TestStoredTextTagged(t *testing.T) {
	seen := 0
	packageSQL(t, func(pos token.Position, name, sql string) {
		cols := readsStoredText(sql)
		if len(cols) == 0 {
			return
		}
		seen++
		if textTagged(sql) {
			return
		}
		if _, ok := textReadAllowed[name]; ok {
			return
		}
		t.Errorf("%s: %s reads %s with no role tag: tag the column (textread.go) or list it in textReadAllowed with why", pos, name, strings.Join(cols, ", "))
	})
	if seen < 50 {
		t.Errorf("only %d SQL texts read a stored text column: the test reads too little (its patterns?)", seen)
	}
}

// TestStoredTextFuncsMarked: a SQL text that reads a repository function whose last definition returns stored
// statement text (its body names a storedText column) carries the text marker ('/* text: col=role */') or a role tag,
// else it is listed with why (textFuncAllowed by function, textReadAllowed by constant). web.go's three reads get
// their markers from the WIRING patch (scripts/textnow-wiring.patch): without it this test fails on them. A function
// that reads the text through another function is not seen here (the proof's walk is the check of those).
func TestStoredTextFuncsMarked(t *testing.T) {
	body := funcBodies(t)
	seen := 0
	packageSQL(t, func(pos token.Position, name, sql string) {
		for _, fn := range funcsReadingText(sql, body) {
			seen++
			if textTagged(sql) {
				continue
			}
			if _, ok := textFuncAllowed[fn.fn]; ok {
				continue
			}
			if _, ok := textReadAllowed[name]; ok {
				continue
			}
			t.Errorf("%s: %s reads pgvigil.%s(), which returns %s, with no text marker: add '/* text: <col>=<role> */' (textread.go), or list it with why (web.go: apply scripts/textnow-wiring.patch)", pos, name, fn.fn, fn.col)
		}
	})
	if seen < 10 {
		t.Errorf("only %d reads of a function that returns stored text were found: the test reads too little (the migrations' path?)", seen)
	}
}

// TestTextGuardsFlag: the read shapes the two guards missed before review 2 (an un-aliased table's bare column,
// explicit columns over a function, a table added since) are flagged; their tagged forms pass.
func TestTextGuardsFlag(t *testing.T) {
	body := funcBodies(t)
	for _, sql := range []string{
		"SELECT snapshot_at AS at, usename, detail\n  FROM pgvigil.log_events\n WHERE kind = 'auth_fail'",
		"SELECT x.setting, x.value FROM pgvigil.session_sets x WHERE x.instance_id = $1",
		"SELECT m.detail FROM pgvigil.mssql_running_findings m",
	} {
		if len(readsStoredText(sql)) == 0 || textTagged(sql) {
			t.Errorf("not flagged: %q", sql)
		}
	}
	fn := "SELECT f.check_name, f.detail FROM pgvigil.mssql_memory_findings_between($1, $2, $3) f"
	if len(funcsReadingText(fn, body)) == 0 || textTagged(fn) {
		t.Errorf("not flagged: %q", fn)
	}
	if ok := "SELECT snapshot_at AS at, detail AS \"detail@logdetail\", kind AS \"@logkind\"\n  FROM pgvigil.log_events\n WHERE kind = 'auth_fail'"; !textTagged(ok) {
		t.Errorf("a tagged read not seen as tagged: %q", ok)
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
	// a JSON plan read as its text alone (the plan page) under normalized: masked from the text, not blanked (review 1 H1)
	tb = &table{Columns: []string{"format@pgfmt", "plan_text@pgplantext", "query@pgq"},
		Rows: [][]any{{"json", `{"Plan": {"Node Type": "Seq Scan", "Filter": "(a = 'secret-42')"}}`, "SELECT 1 FROM t WHERE a = 'secret-42'"}}}
	tr.table(tb, 2, true)
	if pt, _ := tb.Rows[0][1].(string); pt == "" || strings.Contains(pt, "secret-42") || !strings.Contains(pt, "Seq Scan") {
		t.Errorf("a JSON plan's text under normalized: %v", tb.Rows[0])
	}
	if q, _ := tb.Rows[0][2].(string); q == "" || strings.Contains(q, "secret-42") {
		t.Errorf("a JSON plan's query under normalized: %v", tb.Rows[0])
	}
	// the Plans list's row: the query and the format, no plan column - the query normalized, not blanked
	tb = &table{Columns: []string{"format@pgfmt", "query@pgq"}, Rows: [][]any{{"json", "SELECT 1 FROM t WHERE a = 'secret-42'"}, {"text", "SELECT 2 WHERE b = 7"}}}
	tr.table(tb, 2, true)
	for _, row := range tb.Rows {
		if q, _ := row[1].(string); q == "" || strings.Contains(q, "secret-42") || strings.Contains(q, "= 7") {
			t.Errorf("a list row's query under normalized: %v", row)
		}
	}
	tb = &table{Columns: []string{"format@pgfmt", "query@pgq"}, Rows: [][]any{{"json", "SELECT 1"}}}
	tr.table(tb, 3, true)
	if tb.Rows[0][1] != nil {
		t.Errorf("a list row's query under none: %v", tb.Rows[0])
	}
	// a session SET's value: a planner setting's kept under every policy, a custom one's under full only (review 1 H2)
	mkSets := func() *table {
		return &table{Columns: []string{"setting", "value@setval", "planner@planner"},
			Rows: [][]any{{"app.tenant", "acme", false}, {"enable_hashjoin", "off", true}}}
	}
	for id, want := range map[int]any{1: "acme", 2: nil, 3: nil} {
		tb = mkSets()
		tr.table(tb, id, true)
		if tb.Rows[0][1] != want || tb.Rows[1][1] != "off" || tb.Columns[1] != "value" || tb.Columns[2] != "planner" {
			t.Errorf("session SETs under %s: %v %v", tr.byID[id], tb.Columns, tb.Rows)
		}
	}
	// an xmin holder's detail: a session's words kept, its query by the rule; a slot's kept whole (review 2 L1)
	tb = &table{Columns: []string{"holder@holder", "detail@holderdetail"},
		Rows: [][]any{{"session", "app_erp / erp-api, idle in transaction, client backend: UPDATE t SET a = 'secret-9'"}, {"slot", "logical slot s1 on erp: 3 h behind"}}}
	tr.table(tb, 3, true)
	if tb.Rows[0][1] != "app_erp / erp-api, idle in transaction, client backend" || tb.Rows[1][1] != "logical slot s1 on erp: 3 h behind" || tb.Columns[0] != "holder" {
		t.Errorf("xmin holders under none: %v %v", tb.Columns, tb.Rows)
	}
	tb = &table{Columns: []string{"holder@holder", "detail@holderdetail"}, Rows: [][]any{{"session", "u / a, active, client backend: UPDATE t SET a = 'secret-9'"}}}
	tr.table(tb, 2, true)
	if d, _ := tb.Rows[0][1].(string); !strings.HasPrefix(d, "u / a, active, client backend: UPDATE") || strings.Contains(d, "secret-9") {
		t.Errorf("an xmin holder under normalized: %v", tb.Rows)
	}
	// the door set alone says every policy is full (no instance read)
	if !doorsAllFull(&doorSet{QueryText: map[string]string{"a": "full", "b": ""}, DefaultQT: ""}) ||
		doorsAllFull(&doorSet{QueryText: map[string]string{"a": "none"}, DefaultQT: "full"}) ||
		doorsAllFull(&doorSet{QueryText: map[string]string{}, DefaultQT: "normalized"}) {
		t.Error("doorsAllFull")
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
