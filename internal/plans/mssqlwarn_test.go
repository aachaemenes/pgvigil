package plans

import (
	"bufio"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The plans under testdata/mssqlwarn/captured are real SQL Server 2022 plans taken by testdata/mssqlwarn/capture.sh
// from a throwaway container (invented names only); cases.tsv says what each must raise.

const warnDir = "testdata/mssqlwarn"

// want is one expected code; stmt 0 = on any statement, else on that statement (cases.tsv's code@n).
type want struct {
	code string
	stmt int
}

type warnCase struct {
	line             int
	name, src        string
	ctp, nowDays     int
	nowSet           bool
	rt               string // "bc", "-" or the explicit k:v list
	raise, not       []want
	nj               []string
	rows, note, text string
}

func splitList(s string) []string {
	if s == "-" || s == "" {
		return nil
	}
	return strings.Split(s, ",")
}

func wantsOf(t *testing.T, line int, s string) []want {
	t.Helper()
	var out []want
	for _, tok := range splitList(s) {
		code, at, found := strings.Cut(tok, "@")
		w := want{code: code}
		if found {
			n, err := strconv.Atoi(at)
			if err != nil || n < 1 {
				t.Fatalf("cases.tsv line %d: %q is not code@<statement>", line, tok)
			}
			w.stmt = n
		}
		out = append(out, w)
	}
	return out
}

func readWarnCases(t *testing.T) []warnCase {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(warnDir, "cases.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	var out []warnCase
	sc := bufio.NewScanner(strings.NewReader(string(b)))
	n := 0
	for sc.Scan() {
		n++
		ln := sc.Text()
		if ln == "" || strings.HasPrefix(ln, "#") || strings.HasPrefix(ln, "case\t") {
			continue
		}
		col := strings.Split(ln, "\t")
		if len(col) != 8 {
			t.Fatalf("cases.tsv line %d: %d columns, not 8", n, len(col))
		}
		c := warnCase{line: n, name: col[0], src: col[1], rt: "-", raise: wantsOf(t, n, col[3]), not: wantsOf(t, n, col[4]),
			nj: splitList(col[5]), rows: col[6], note: col[7], text: ln}
		for _, tok := range strings.Fields(col[2]) {
			k, v, _ := strings.Cut(tok, "=")
			switch k {
			case "ctp":
				if v != "-" {
					if c.ctp, err = strconv.Atoi(v); err != nil {
						t.Fatalf("cases.tsv line %d: ctp %q", n, v)
					}
				}
			case "now":
				if v != "-" {
					d := strings.TrimSuffix(strings.TrimPrefix(v, "+"), "d")
					if c.nowDays, err = strconv.Atoi(d); err != nil {
						t.Fatalf("cases.tsv line %d: now %q", n, v)
					}
					c.nowSet = true
				}
			case "rt":
				c.rt = v
			default:
				t.Fatalf("cases.tsv line %d: unknown input %q", n, tok)
			}
		}
		out = append(out, c)
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// oracleRow is one Statement row of ##BlitzCacheProcs by its column names.
type oracleRow map[string]string

// readOracle reads captured/blitzcache-8.34.tsv: every row of a case (a cursor batch has two: its DECLARE and its
// FETCH), in the file's order.
func readOracle(t *testing.T) map[string][]oracleRow {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(warnDir, "captured", "blitzcache-8.34.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	head := strings.Split(lines[0], "\t")
	out := map[string][]oracleRow{}
	for _, ln := range lines[1:] {
		f := strings.Split(ln, "\t")
		if len(f) != len(head) {
			t.Fatalf("blitzcache-8.34.tsv: a row of %d fields, not %d", len(f), len(head))
		}
		if f[0] == "-" {
			continue
		}
		r := oracleRow{}
		for i, h := range head {
			r[h] = f[i]
		}
		out[f[0]] = append(out[f[0]], r)
	}
	return out
}

func oracleNum(r oracleRow, col string) (float64, bool) {
	v, ok := r[col]
	if !ok || v == "" {
		return 0, false
	}
	f, err := strconv.ParseFloat(v, 64)
	return f, err == nil
}

// stmtOfRow is the statement of a plan an oracle row stands for: the statement carrying the row's QueryHash. A cursor
// batch's statements carry no QueryHash: sp_BlitzCache's two rows of it (the DECLARE by its query's hash, the FETCH by
// a zero hash, 8.34 L4980-4995) both read the cursor's plan, so their statement is the cursor's DECLARE (the CursorPlan
// with the cursor's type).
func stmtOfRow(t *testing.T, plan string, r oracleRow) *mstmt {
	t.Helper()
	root, err := parseShowplan(plan)
	if err != nil {
		t.Fatal(err)
	}
	hash := r["QueryHash"]
	stmts := statements(root)
	for _, s := range stmts {
		if strings.Trim(hash, "0x") != "" && strings.EqualFold(s.n.attr("QueryHash"), hash) {
			return s
		}
	}
	for _, s := range stmts {
		if cp := s.n.child("CursorPlan"); s.n.name == "StmtCursor" && cp != nil && cp.attr("CursorActualType") != "" {
			return s
		}
	}
	t.Fatalf("no statement of the plan stands for the oracle row with QueryHash %s", hash)
	return nil
}

// runtimeOfRow is an oracle row's averages as the runtime of statement stmt.
func runtimeOfRow(r oracleRow, stmt int) *MSSQLRuntime {
	rt := &MSSQLRuntime{Stmt: stmt}
	for col, p := range map[string]**float64{"ExecutionCount": &rt.Executions, "AverageCPU": &rt.AvgCPUMS,
		"AverageReturnedRows": &rt.AvgRows, "AverageWrites": &rt.AvgWritePages, "AvgSpills": &rt.AvgSpillPages} {
		if v, ok := oracleNum(r, col); ok {
			*p = Num(v)
		}
	}
	return rt
}

// runtimeOf builds a case's runtime input on a plan: the oracle row's averages on its own statement (rt=bc) or the
// explicit list (stmt:<n> names the statement).
func runtimeOf(t *testing.T, c warnCase, oracle map[string][]oracleRow, plan string) *MSSQLRuntime {
	t.Helper()
	switch c.rt {
	case "-":
		return nil
	case "bc":
		rs := oracle[c.name]
		if len(rs) != 1 {
			t.Fatalf("cases.tsv line %d: rt=bc but the oracle holds %d rows of %s, not one", c.line, len(rs), c.name)
		}
		return runtimeOfRow(rs[0], stmtOfRow(t, plan, rs[0]).ord)
	}
	rt := &MSSQLRuntime{}
	for _, kv := range strings.Split(c.rt, ",") {
		k, v, _ := strings.Cut(kv, ":")
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			t.Fatalf("cases.tsv line %d: rt %q", c.line, kv)
		}
		switch k {
		case "stmt":
			rt.Stmt = int(f)
		case "exec":
			rt.Executions = Num(f)
		case "cpu":
			rt.AvgCPUMS = Num(f)
		case "rows":
			rt.AvgRows = Num(f)
		case "writes":
			rt.AvgWritePages = Num(f)
		case "spill":
			rt.AvgSpillPages = Num(f)
		case "compile":
			rt.AvgCompileMS = Num(f)
		default:
			t.Fatalf("cases.tsv line %d: unknown runtime number %q", c.line, k)
		}
	}
	return rt
}

// newestStat is the latest StatisticsInfo LastUpdate in the plan (zero when none).
func newestStat(t *testing.T, plan string) time.Time {
	t.Helper()
	root, err := parseShowplan(plan)
	if err != nil {
		t.Fatal(err)
	}
	var last time.Time
	root.walk(func(n *xnode) bool { // the whole document: all() stops at each statement
		if n.name == "StatisticsInfo" {
			if ts, ok := statTime(n.attr("LastUpdate")); ok && ts.After(last) {
				last = ts
			}
		}
		return true
	})
	return last
}

func planPath(name, src string) string {
	return filepath.Join(warnDir, "captured", name+"."+src+".sqlplan")
}

func readPlan(t *testing.T, name, src string) string {
	t.Helper()
	b, err := os.ReadFile(planPath(name, src))
	if err != nil {
		t.Fatalf("no captured %s plan of %s: %v", src, name, err)
	}
	return string(b)
}

// metaCTP is the cost threshold for parallelism the capture's server ran with (capture-meta.tsv's server line).
func metaCTP(t *testing.T) int {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(warnDir, "captured", "capture-meta.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	first, _, _ := strings.Cut(string(b), "\n")
	for _, f := range strings.Split(first, "\t") {
		if v, ok := strings.CutPrefix(f, "ctp="); ok {
			n, err := strconv.Atoi(v)
			if err != nil || n <= 0 {
				t.Fatalf("capture-meta.tsv: ctp %q", v)
			}
			return n
		}
	}
	t.Fatal("capture-meta.tsv: the server line holds no ctp=")
	return 0
}

// has reports whether the code was raised on statement stmt (0 = any); the missing-index hints as 'missing_index_hint'.
func has(warns []MSSQLWarning, plan, code string, stmt int) bool {
	if code == "missing_index_hint" {
		for _, m := range MSSQLMissingIndexes(plan) {
			if stmt == 0 || m.Stmt == stmt {
				return true
			}
		}
		return false
	}
	for _, w := range warns {
		if w.Code == code && (stmt == 0 || w.Stmt == stmt) {
			return true
		}
	}
	return false
}

func (w want) String() string {
	if w.stmt == 0 {
		return w.code
	}
	return fmt.Sprintf("%s@%d", w.code, w.stmt)
}

func codesOf(warns []MSSQLWarning) []string {
	var out []string
	for _, w := range warns {
		if s := fmt.Sprintf("%s@%d", w.Code, w.Stmt); !slices.Contains(out, s) {
			out = append(out, s)
		}
	}
	return out
}

// part1 are the codes of rules part 1; builtParts says which parts the tests hold the rules to (part 2's codes are
// checked once its rules are built).
var part1 = []string{"implicit_conversions", "blitz_implicit_conversion", "is_key_lookup_expensive", "lookup",
	"missing_index_count", "missing_index_hint", "function_count", "blitz_scalar_udf", "clr_function_count",
	"is_computed_filter", "is_computed_scalar", "is_mstvf", "tvf_join", "is_table_variable", "is_cursor",
	"cursor_not_forward_only", "is_cursor_dynamic", "near_parallel", "is_forced_serial", "is_spool_expensive",
	"is_spool_more_rows", "is_table_spool_expensive", "is_table_spool_more_rows", "is_sort_expensive",
	"is_remote_query_expensive", "is_big_spills"}

const builtParts = 2

func checked(code string) bool {
	return builtParts >= 2 || slices.Contains(part1, code)
}

// judgeCase runs one cases.tsv line on one plan source (its own, or the Query Store twin of a cache line).
func judgeCase(t *testing.T, c warnCase, oracle map[string][]oracleRow, src string) {
	t.Helper()
	plan := readPlan(t, c.name, src)
	in := MSSQLWarnInput{CostThreshold: c.ctp, Runtime: runtimeOf(t, c, oracle, plan)}
	if c.nowSet {
		last := newestStat(t, plan)
		if last.IsZero() {
			t.Fatalf("now=+%dd but the plan holds no statistics date", c.nowDays)
		}
		in.Now = last.Add(time.Duration(c.nowDays) * 24 * time.Hour)
	}
	warns, nj, err := MSSQLPlanWarnings(plan, in)
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range warns {
		if builtParts < 2 && !slices.Contains(part1, w.Code) {
			t.Errorf("%s raised on statement %d, a code outside part 1, while builtParts is %d: raise builtParts with part 2", w.Code, w.Stmt, builtParts)
		}
	}
	var njCodes []string
	for _, j := range nj {
		njCodes = append(njCodes, j.Code)
	}
	for _, w := range c.raise {
		if checked(w.code) && !has(warns, plan, w.code, w.stmt) {
			t.Errorf("%s not raised (%s; %s); raised %v", w, c.rows, c.note, codesOf(warns))
		}
	}
	for _, w := range c.not {
		if checked(w.code) && has(warns, plan, w.code, w.stmt) {
			t.Errorf("%s raised but must not be (%s; %s)", w, c.rows, c.note)
		}
	}
	for _, code := range c.nj {
		if checked(code) && !slices.Contains(njCodes, code) {
			t.Errorf("%s not in the not-judged list %v (%s)", code, njCodes, c.note)
		}
	}
}

// qsTwin reports whether a cache line is also run on the case's Query Store plan, and why not when it is not. A
// cached plan is the whole batch, a Query Store plan one statement: a line naming a statement, or giving runtime numbers
// on a batch of several statements, speaks of the batch.
func qsTwin(t *testing.T, c warnCase) (bool, string) {
	t.Helper()
	if c.src != "cache" {
		return false, ""
	}
	if _, err := os.Stat(planPath(c.name, "qs")); err != nil {
		return false, "no Query Store plan captured"
	}
	for _, w := range append(slices.Clone(c.raise), c.not...) {
		if w.stmt != 0 {
			return false, "the line names a statement of the batch"
		}
	}
	if strings.Contains(c.rt, "stmt:") {
		return false, "the runtime names a statement of the batch"
	}
	if c.rt != "-" && c.rt != "bc" {
		root, err := parseShowplan(readPlan(t, c.name, "cache"))
		if err != nil {
			t.Fatal(err)
		}
		if n := len(statements(root)); n > 1 {
			return false, fmt.Sprintf("runtime numbers on a batch of %d statements", n)
		}
	}
	return true, ""
}

func TestMSSQLPlanWarnings(t *testing.T) {
	oracle := readOracle(t)
	twins, notTwin := 0, map[string]int{}
	for _, c := range readWarnCases(t) {
		t.Run(c.name+"/"+strconv.Itoa(c.line), func(t *testing.T) { judgeCase(t, c, oracle, c.src) })
		ok, why := qsTwin(t, c)
		switch {
		case ok:
			twins++
			t.Run(c.name+"/"+strconv.Itoa(c.line)+"/qs", func(t *testing.T) { judgeCase(t, c, oracle, "qs") })
		case why != "":
			notTwin[why]++
		}
	}
	t.Logf("the cache lines run again on their Query Store plans: %d; not: %v", twins, notTwin)
	if twins == 0 {
		t.Error("no cache line ran on its Query Store plan")
	}
}

// The missing-index hint of missing_ix (SELECT b.id FROM dbo.big2 AS b JOIN dbo.tiny AS t ON t.k = b.k WHERE b.v = 12):
// v compared with =, k read besides, on warnlab.dbo.big2, the brackets taken off.
func TestMSSQLMissingIndexFields(t *testing.T) {
	got := MSSQLMissingIndexes(readPlan(t, "missing_ix", "cache"))
	if len(got) != 1 {
		t.Fatalf("%d hints, not 1: %+v", len(got), got)
	}
	m := got[0]
	if m.Stmt != 1 || m.Database != "warnlab" || m.Schema != "dbo" || m.Table != "big2" ||
		!slices.Equal(m.Equality, []string{"v"}) || len(m.Inequality) != 0 || !slices.Equal(m.Include, []string{"k"}) ||
		math.Abs(m.Impact-97.6671) > 1e-9 {
		t.Errorf("the hint is %+v, not statement 1, warnlab.dbo.big2, equality [v], no inequality, include [k], impact 97.6671", m)
	}
}

// A .sqlplan saved by SQL Server Management Studio declares encoding="utf-16"; the plan arrives as text all the same.
func TestMSSQLPlanUTF16Declaration(t *testing.T) {
	plan := readPlan(t, "ic_seek", "cache")
	if strings.HasPrefix(plan, "<?xml") {
		t.Fatal("the captured plan already carries a declaration")
	}
	warns, _, err := MSSQLPlanWarnings(`<?xml version="1.0" encoding="utf-16"?>`+"\n"+plan, MSSQLWarnInput{CostThreshold: 5})
	if err != nil {
		t.Fatalf("a utf-16 declaration refused: %v", err)
	}
	if !has(warns, "", "implicit_conversions", 1) {
		t.Errorf("implicit_conversions not raised under a utf-16 declaration; raised %v", codesOf(warns))
	}
	if _, _, err := MSSQLPlanWarnings(`<?xml version="1.0" encoding="windows-1252"?>`+"\n"+plan, MSSQLWarnInput{}); err == nil {
		t.Error("a windows-1252 declaration accepted: the text's bytes are not that encoding's")
	}
}

// Where a warning points: the QueryPlan's place and the operator holding the element (Plan 0 and Node -1 for the
// statement as a whole).
func TestMSSQLWarningPlaces(t *testing.T) {
	for _, tc := range []struct {
		name, src, code string
		in              MSSQLWarnInput
		plan            int
		node            bool // a NodeId (0 or more), else -1
	}{
		{"table_var", "qs", "is_table_variable", MSSQLWarnInput{}, 1, true},
		{"lookup_hit", "cache", "lookup", MSSQLWarnInput{}, 1, true},
		{"ic_seek", "cache", "implicit_conversions", MSSQLWarnInput{}, 1, false},
		{"clean", "cache", "is_big_spills", MSSQLWarnInput{Runtime: &MSSQLRuntime{AvgSpillPages: Num(64000)}}, 0, false},
	} {
		warns, _, err := MSSQLPlanWarnings(readPlan(t, tc.name, tc.src), tc.in)
		if err != nil {
			t.Fatal(err)
		}
		i := slices.IndexFunc(warns, func(w MSSQLWarning) bool { return w.Code == tc.code })
		if i < 0 {
			t.Errorf("%s: %s not raised", tc.name, tc.code)
			continue
		}
		if w := warns[i]; w.Stmt != 1 || w.Plan != tc.plan || (w.Node >= 0) != tc.node {
			t.Errorf("%s: %s at statement %d plan %d node %d; want statement 1 plan %d node>=0 %v", tc.name, tc.code, w.Stmt, w.Plan, w.Node, tc.plan, tc.node)
		}
	}
}

// oracleCols maps a code to the sp_BlitzCache 8.34 column that holds the same judgement, and how that column fires.
var oracleCols = map[string]struct {
	col  string
	fire func(string) bool
}{}

func oneFires(v string) bool { f, err := strconv.ParseFloat(v, 64); return err == nil && f == 1 }
func posFires(v string) bool { f, err := strconv.ParseFloat(v, 64); return err == nil && f > 0 }

func init() {
	for _, c := range []string{"implicit_conversions", "is_key_lookup_expensive", "is_computed_filter", "is_computed_scalar",
		"is_mstvf", "tvf_join", "is_table_variable", "is_cursor", "is_cursor_dynamic", "near_parallel", "is_forced_serial",
		"is_spool_expensive", "is_spool_more_rows", "is_table_spool_expensive", "is_table_spool_more_rows", "is_sort_expensive",
		"is_remote_query_expensive", "is_big_spills", "is_row_goal", "is_bad_estimate", "is_adaptive", "is_paul_white_electric",
		"backwards_scan", "is_table_scan", "forced_index", "columnstore_row_mode", "index_dml", "table_dml",
		"low_cost_high_cpu", "stale_stats", "compile_timeout", "is_nonsargable", "unparameterized_query", "plan_warnings",
		"relop_warnings", "busy_loops"} {
		oracleCols[c] = struct {
			col  string
			fire func(string) bool
		}{c, oneFires}
	}
	for _, c := range []string{"missing_index_count", "function_count", "clr_function_count", "select_with_writes"} {
		oracleCols[c] = struct {
			col  string
			fire func(string) bool
		}{c, posFires}
	}
	oracleCols["index_ops"] = struct {
		col  string
		fire func(string) bool
	}{"index_ops", func(v string) bool { f, err := strconv.ParseFloat(v, 64); return err == nil && f >= 5 }}
	oracleCols["trace_flags_session"] = struct {
		col  string
		fire func(string) bool
	}{"trace_flags_session", func(v string) bool { return strings.TrimSpace(v) != "" }}
	oracleCols["long_compile"] = struct {
		col  string
		fire func(string) bool
	}{"CompileTime", func(v string) bool { f, err := strconv.ParseFloat(v, 64); return err == nil && f > 5000 }}
	oracleCols["cursor_not_forward_only"] = struct {
		col  string
		fire func(string) bool
	}{"is_forward_only_cursor", func(v string) bool { return v == "0" || strings.HasPrefix(v, "0.") }}
}

// oracleSkip are the codes compared with sp_BlitzCache on no case, each with why (the design's named exceptions).
var oracleSkip = map[string]string{
	"stale_stats":             "sp_BlitzCache compares SYSDATETIME() and a fresh container holds no 7-day-old statistic; pgvigil is given its clock",
	"cursor_not_forward_only": "sp_BlitzCache never sets is_forward_only_cursor to 0 (8.34 L3632, L2797): its words cannot fire",
	"is_cursor":               "sp_BlitzCache's Cursor rests on plan attributes and zero hashes (8.34 L4980-4995), not the plan",
}

// oneOf are the codes sp_BlitzCache judges on one of a statement's candidate operators where pgvigil judges each (the
// design's 'any node' departure, F3): the spools (its spools CTE keeps each distinct spool row and the UPDATE ... JOIN
// on QueryHash takes one, 8.34 L3825-3870), the busy loop (one operator's CASE per statement, L3461-3470) and the scan
// flags (L3677-3702, L3916-3922). On a statement holding more than one candidate the compare is one way: sp_BlitzCache
// fires = pgvigil fires.
var oneOf = map[string]func(*mstmt) int{
	"is_spool_expensive":       func(s *mstmt) int { return len(s.ops("Index Spool", "Eager Spool")) },
	"is_spool_more_rows":       func(s *mstmt) int { return len(s.ops("Index Spool", "Eager Spool")) },
	"is_table_spool_expensive": func(s *mstmt) int { return len(s.ops("Table Spool", "Lazy Spool")) },
	"is_table_spool_more_rows": func(s *mstmt) int { return len(s.ops("Table Spool", "Lazy Spool")) },
	"busy_loops":               func(s *mstmt) int { return len(s.relops) },
	"is_table_scan":            func(s *mstmt) int { return len(s.relops) },
	"backwards_scan":           func(s *mstmt) int { return len(s.relops) },
	"forced_index":             func(s *mstmt) int { return len(s.relops) },
	"columnstore_row_mode":     func(s *mstmt) int { return len(s.relops) },
}

// anyNodeSeen are the one-way compares where pgvigil fires and sp_BlitzCache's kept operator did not, each read: a
// statement where some operator meets the rule and sp_BlitzCache's UPDATE kept another's 0 (the busy loop's inner
// side, a heap's Table Scan under a spool or a function; win_spool's three lazy spools, of which capture 3's
// sp_BlitzCache kept NodeId 2 - 500 rows, no rebind - where capture 2's kept NodeId 10). A new one fails until it is
// read and named here.
var anyNodeSeen = []string{"adaptive/1:busy_loops", "cursor_ff/1:busy_loops", "cursor_ff/2:busy_loops",
	"forced_ix/1:busy_loops", "idx_spool/1:is_table_scan", "lookup_cheap/1:busy_loops", "mstvf_interleaved/1:is_table_scan",
	"tspool_hit/1:is_table_scan", "win_spool/1:busy_loops", "win_spool/1:is_table_spool_more_rows"}

// The capture's oracle rows: 53 cases, a cursor's batch two rows (its DECLARE and its FETCH).
const oracleRowsAtLeast = 56

// A Warnings element's set flags are named in one order on every read (the words of #18 / #2 are compared and kept):
// the element's own children in document order, then its flags sorted. No captured plan sets two flags on one element,
// so the element is built here (a helper's order, not a rule's proof).
func TestMSSQLWarningKindsOrder(t *testing.T) {
	w := &xnode{name: "Warnings", attrs: map[string]string{"UnmatchedIndexes": "true", "SpatialGuess": "1", "NoJoinPredicate": "false", "FullUpdateForOnlineIndexBuild": "true"},
		kids: []*xnode{{name: "SpillToTempDb"}, {name: "ColumnsWithNoStatistics"}, {name: "SpillToTempDb"}}}
	const want = "SpillToTempDb, ColumnsWithNoStatistics, FullUpdateForOnlineIndexBuild, SpatialGuess, UnmatchedIndexes"
	for i := 0; i < 50; i++ {
		if got := warningKinds(w); got != want {
			t.Fatalf("read %d: %q, want %q", i+1, got, want)
		}
	}
}

func TestMSSQLPlanWarningsBlitzCache(t *testing.T) {
	oracle := readOracle(t)
	ctp := metaCTP(t)
	var names []string
	for name := range oracle {
		names = append(names, name)
	}
	sort.Strings(names)
	rows, compared, oneWay := 0, 0, 0
	var pgvigilOnly []string // one-way compares where pgvigil fires and sp_BlitzCache's kept operator did not
	for _, name := range names {
		for i, r := range oracle[name] {
			rows++
			t.Run(fmt.Sprintf("%s/%d", name, i+1), func(t *testing.T) {
				plan := readPlan(t, name, "cache") // a case with an oracle row and no cached plan fails here
				s := stmtOfRow(t, plan, r)
				warns, _, err := MSSQLPlanWarnings(plan, MSSQLWarnInput{CostThreshold: ctp, Runtime: runtimeOfRow(r, s.ord)})
				if err != nil {
					t.Fatal(err)
				}
				for code, oc := range oracleCols {
					if _, skip := oracleSkip[code]; skip || !checked(code) {
						continue
					}
					wantFire := oc.fire(r[oc.col])
					have := has(warns, plan, code, s.ord)
					if cand, ok := oneOf[code]; ok && cand(s) > 1 {
						oneWay++
						if wantFire && !have {
							t.Errorf("%s (statement %d, %d candidates): sp_BlitzCache 8.34 fires (%s = %q), pgvigil does not", code, s.ord, cand(s), oc.col, r[oc.col])
						}
						if have && !wantFire {
							pgvigilOnly = append(pgvigilOnly, fmt.Sprintf("%s/%d:%s", name, i+1, code))
						}
						continue
					}
					if have != wantFire {
						t.Errorf("%s (statement %d): pgvigil %v, sp_BlitzCache 8.34 %v (%s = %q)", code, s.ord, have, wantFire, oc.col, r[oc.col])
					}
				}
				compared++
			})
		}
	}
	t.Logf("oracle rows %d, compared %d, one-way compares %d; pgvigil alone fires on %d: %v", rows, compared, oneWay, len(pgvigilOnly), pgvigilOnly)
	sort.Strings(pgvigilOnly)
	if !slices.Equal(pgvigilOnly, anyNodeSeen) {
		t.Errorf("pgvigil alone fires on %v; the read ones are %v", pgvigilOnly, anyNodeSeen)
	}
	if rows < oracleRowsAtLeast || compared != rows {
		t.Errorf("compared %d of %d oracle rows (the capture holds at least %d)", compared, rows, oracleRowsAtLeast)
	}
}
