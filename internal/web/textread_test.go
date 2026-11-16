package web

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
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
	// the XE captures' waits and warning samples keep the statement the event carried (0162_mssql_xe_captures.sql)
	"mssql_xe_waits": {"statement"}, "mssql_xe_warning_samples": {"statement"},
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
	"sqlAckLive":              "mssql_deadlocks.processes only inside mssql_deadlock_is_monitors() in a WHERE (0165: the monitor's own deadlocks left out); returns a count and a time",
	"sqlHealthCal":            "mssql_deadlocks.processes only inside mssql_deadlock_is_monitors() in a WHERE (0165: the monitor's own deadlocks left out); returns a count",
}

// textFuncAllowed: a repository function whose body names a stored text column but whose result carries none: why.
var textFuncAllowed = map[string]string{
	"mssql_plan_sources": "returns has_plan, never the plan",
}

var (
	// a table's read: its name, and its alias when it has one (an un-aliased read names its columns bare)
	sqlTableRE = regexp.MustCompile(`pgvigil\.(\w+)(?:\s+(?:AS\s+)?([a-z][a-z0-9_]*))?`)
	// a CTE's head ('WITH name AS (' or ', name AS ('), its body from the parenthesis on
	sqlCTEHeadRE = regexp.MustCompile(`(?:\bWITH\s+(?:RECURSIVE\s+)?|,\s*)(\w+)\s+AS\s+(?:(?:NOT\s+)?MATERIALIZED\s+)?\(`)
	// a select list's star, bare or by its source's name or alias ('SELECT *', 'SELECT st.*', ', b.*')
	sqlStarRE = regexp.MustCompile(`(?:\bSELECT\s+(?:DISTINCT\s+)?|,\s*)(?:(\w+)\.)?\*`)
	// a source a FROM or JOIN names, with its alias when it has one (fromSources drops a schema's or a function's)
	sqlFromRE = regexp.MustCompile(`(?:FROM|JOIN)\s+(\w+)(?:[ \t\n]+(?:AS\s+)?([a-z][a-z0-9_]*))?`)
	// a function's read, whatever columns the SQL takes from it
	sqlCallRE = regexp.MustCompile(`pgvigil\.(\w+)\(`)
	textTagRE = regexp.MustCompile(`"[a-z_]*@[a-z]+"`)
)

// textTagged: a SQL text carries a role tag or the text marker (the rule then applies to every tagged column it returns).
func textTagged(sql string) bool { return textTagRE.MatchString(sql) || textMarkRE.MatchString(sql) }

// readsStoredText lists the storedText columns a SQL text names: through a table's alias, bare beside an
// un-aliased table, or through a CTE that selects a stored text table's every column (starCTEs: 'lg AS (SELECT g.*
// FROM pgvigil.t g ...)' then 'lg.col', or the CTE under an alias of its own).
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
	for name, tables := range starCTEs(sql) {
		names := []string{name}
		for _, f := range fromSources(sql) {
			if f[0] == name && f[1] != "" {
				names = append(names, f[1])
			}
		}
		for _, t := range tables {
			for _, c := range storedText[t] {
				for _, n := range names {
					if regexp.MustCompile(`\b` + n + `\.` + c + `\b`).MatchString(sql) {
						out = append(out, "pgvigil."+t+"."+c+" (through "+name+")")
						break
					}
				}
			}
		}
	}
	sort.Strings(out)
	return out
}

// starCTEs: each CTE of a SQL text whose select list takes every column of a stored text table - a star bare or by
// the table's name or alias, extra columns beside it or not - or of such a CTE (a chain, to its end), with the tables.
func starCTEs(sql string) map[string][]string {
	type cte struct{ name, body string }
	var ctes []cte
	for _, m := range sqlCTEHeadRE.FindAllStringSubmatchIndex(sql, -1) {
		ctes = append(ctes, cte{sql[m[2]:m[3]], sql[m[1]:closeParen(sql, m[1]-1)]})
	}
	out := map[string][]string{}
	for changed := true; changed; {
		changed = false
		for _, c := range ctes {
			if _, done := out[c.name]; done {
				continue
			}
			src := map[string][]string{} // a source's name or alias: the stored text tables behind it
			var all []string
			for _, m := range sqlTableRE.FindAllStringSubmatch(c.body, -1) {
				if _, ok := storedText[m[1]]; ok {
					src[m[1]] = append(src[m[1]], m[1])
					if m[2] != "" {
						src[m[2]] = append(src[m[2]], m[1])
					}
					all = append(all, m[1])
				}
			}
			for _, f := range fromSources(c.body) {
				if ts, ok := out[f[0]]; ok {
					src[f[0]] = append(src[f[0]], ts...)
					if f[1] != "" {
						src[f[1]] = append(src[f[1]], ts...)
					}
					all = append(all, ts...)
				}
			}
			var got []string
			for _, s := range sqlStarRE.FindAllStringSubmatch(c.body, -1) {
				if s[1] == "" {
					got = append(got, all...)
				} else {
					got = append(got, src[s[1]]...)
				}
			}
			if len(got) > 0 {
				out[c.name] = got
				changed = true
			}
		}
	}
	return out
}

// fromSources: each source a FROM or JOIN names without a schema (a CTE's name), with its alias ("" when none); a
// name followed by '.' (a schema) or '(' (a function) is not one.
func fromSources(s string) [][2]string {
	var out [][2]string
	for _, m := range sqlFromRE.FindAllStringSubmatchIndex(s, -1) {
		if e := m[3]; e < len(s) && (s[e] == '.' || s[e] == '(') {
			continue
		}
		alias := ""
		if m[4] >= 0 {
			alias = s[m[4]:m[5]]
		}
		out = append(out, [2]string{s[m[2]:m[3]], alias})
	}
	return out
}

// closeParen is the index of the parenthesis that closes the one at open (a quoted '...' read past), or len(s).
func closeParen(s string, open int) int {
	depth, quoted := 0, false
	for i := open; i < len(s); i++ {
		switch c := s[i]; {
		case quoted:
			if c == '\'' {
				quoted = false
			}
		case c == '\'':
			quoted = true
		case c == '(':
			depth++
		case c == ')':
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return len(s)
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

// packageSQL calls f with every SQL text of the package's non-test files that holds a SELECT - each string literal,
// and each concatenation folded to its whole text (a const or var of the package named in it folded in too, but one
// textReadAllowed lists; any other part ' ? '), since a CTE built in one constant is read in the next - with its
// position and the name it is bound to (the const / var it starts, else the function it sits in).
func packageSQL(t *testing.T, f func(pos token.Position, name, sql string)) {
	fset := token.NewFileSet()
	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatalf("the package's files: %v", err)
	}
	var afs []*ast.File
	vals := map[string]ast.Expr{} // the package's const and var values by name
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, file, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		afs = append(afs, af)
		for _, d := range af.Decls {
			if gd, ok := d.(*ast.GenDecl); ok && (gd.Tok == token.CONST || gd.Tok == token.VAR) {
				for _, sp := range gd.Specs {
					vs := sp.(*ast.ValueSpec)
					for i, n := range vs.Names {
						if i < len(vs.Values) {
							vals[n.Name] = vs.Values[i]
						}
					}
				}
			}
		}
	}
	var fold func(e ast.Expr, depth int) string
	fold = func(e ast.Expr, depth int) string {
		switch x := e.(type) {
		case *ast.BasicLit:
			if s, err := strconv.Unquote(x.Value); err == nil && x.Kind == token.STRING {
				return s
			}
		case *ast.ParenExpr:
			return fold(x.X, depth)
		case *ast.BinaryExpr:
			if x.Op == token.ADD {
				return fold(x.X, depth) + fold(x.Y, depth)
			}
		case *ast.Ident:
			// a constant listed in textReadAllowed stays out: its entry says why its reads are not returned and
			// what the constants built on it tag (sqlLogGroupBase, repFailedCTE)
			if _, allowed := textReadAllowed[x.Name]; allowed {
				break
			}
			if v, ok := vals[x.Name]; ok && depth < 16 {
				return fold(v, depth+1)
			}
		}
		return " ? "
	}
	for _, af := range afs {
		name := map[ast.Node]string{}
		bind := func(n ast.Node, to string) {
			switch n.(type) {
			case *ast.BasicLit, *ast.BinaryExpr:
				if _, seen := name[n]; !seen {
					name[n] = to
				}
			}
		}
		ast.Inspect(af, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.ValueSpec:
				for _, v := range x.Values {
					ast.Inspect(v, func(m ast.Node) bool {
						if len(x.Names) > 0 {
							bind(m, x.Names[0].Name)
						}
						return true
					})
				}
			case *ast.FuncDecl:
				if x.Body != nil {
					ast.Inspect(x.Body, func(m ast.Node) bool {
						bind(m, x.Name.Name)
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
		// each outermost concatenation, whole (its literals were read one by one above)
		ast.Inspect(af, func(n ast.Node) bool {
			be, ok := n.(*ast.BinaryExpr)
			if !ok || be.Op != token.ADD {
				return true
			}
			if sql := fold(be, 0); strings.Contains(sql, "SELECT") {
				f(fset.Position(be.Pos()), name[be], sql)
			}
			return false
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
// explicit columns over a function, a table added since) and before the closing run (a column read through a CTE
// that takes a stored text table's every column: 0119's mssql_memory_findings_between reads its statement as
// lg.statement; a star beside other columns, a CTE over such a CTE, a bare star over one) are flagged; their tagged
// forms are flagged and tagged; a CTE over a stored text table that returns none of its text is not flagged; and a
// CTE built in one constant and read in the next reaches the guards whole (packageSQL's fold).
func TestTextGuardsFlag(t *testing.T) {
	body := funcBodies(t)
	for _, sql := range []string{
		"SELECT snapshot_at AS at, usename, detail\n  FROM pgvigil.log_events\n WHERE kind = 'auth_fail'",
		"SELECT x.setting, x.value FROM pgvigil.session_sets x WHERE x.instance_id = $1",
		"SELECT m.detail FROM pgvigil.mssql_running_findings m",
		"WITH lg AS (SELECT g.* FROM pgvigil.mssql_memory_grant_query g WHERE g.instance_id = $1)\nSELECT lg.session_id, lg.statement FROM lg",
		"WITH q AS MATERIALIZED (SELECT * FROM pgvigil.mssql_requests) SELECT r.session_id, r.statement FROM q r",
		"WITH s AS (SELECT st.*, now() AS due FROM pgvigil.alert_state st) SELECT s.check_name, s.value FROM s",
		"WITH r AS (SELECT b.* FROM pgvigil.mssql_blocked_reports b), d AS (SELECT r.*, 1 AS lvl FROM r) SELECT d.blocked_statement FROM d",
		"WITH lg AS (SELECT g.* FROM pgvigil.mssql_memory_grant_query g), x AS (SELECT * FROM lg) SELECT x.statement FROM x",
	} {
		if len(readsStoredText(sql)) == 0 || textTagged(sql) {
			t.Errorf("not flagged: %q", sql)
		}
	}
	for _, none := range []string{
		"WITH lg AS (SELECT g.* FROM pgvigil.mssql_memory_grant_query g) SELECT lg.session_id, lg.granted_kb FROM lg",
		"WITH lg AS (SELECT g.* FROM pgvigil.mssql_memory_grant_query g), ls AS (SELECT 1 AS n) SELECT ls.n, lg.granted_kb FROM lg, ls",
	} {
		if got := readsStoredText(none); len(got) != 0 {
			t.Errorf("flagged with no stored text returned: %q (%v)", none, got)
		}
	}
	for _, ok := range []string{
		"WITH lg AS (SELECT g.* FROM pgvigil.mssql_memory_grant_query g) SELECT lg.statement AS \"statement@stmt\" FROM lg",
		"SELECT snapshot_at AS at, detail AS \"detail@logdetail\", kind AS \"@logkind\"\n  FROM pgvigil.log_events\n WHERE kind = 'auth_fail'",
	} {
		if len(readsStoredText(ok)) == 0 || !textTagged(ok) {
			t.Errorf("a tagged read not seen as a read, or not as tagged: %q", ok)
		}
	}
	fn := "SELECT f.check_name, f.detail FROM pgvigil.mssql_memory_findings_between($1, $2, $3) f"
	if len(funcsReadingText(fn, body)) == 0 || textTagged(fn) {
		t.Errorf("not flagged: %q", fn)
	}
	whole := map[string]bool{}
	packageSQL(t, func(_ token.Position, name, sql string) {
		switch {
		case name == "sqlMSSQLXEBlockedHeads" && strings.Contains(sql, "pgvigil.mssql_blocked_reports b") && strings.Contains(sql, "b.blocking_statement"):
		case name == "sqlSlowGroups" && strings.Contains(sql, "pgvigil.slow_events_all e") && strings.Contains(sql, "e.statement"):
		default:
			return
		}
		if len(readsStoredText(sql)) > 0 && textTagged(sql) {
			whole[name] = true
		}
	})
	for _, name := range []string{"sqlMSSQLXEBlockedHeads", "sqlSlowGroups"} {
		if !whole[name] {
			t.Errorf("%s: its CTE and the read of it never reached the guards as one text (packageSQL's fold)", name)
		}
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
