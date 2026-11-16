package plans

// The SQL Server plan warnings: the First Responder Kit's sp_BlitzCache 8.34 (and four sp_Blitz 8.34 checks) read a
// showplan for some fifty kinds of trouble - implicit conversions, expensive lookups, spools, sorts, UDFs, cursors,
// stale statistics and the rest - each with its own threshold. MSSQLPlanWarnings raises the same warnings, with the
// same thresholds and words, from one showplan document (an estimated plan as Query Store keeps it, a cached plan, a
// .sqlplan file), so a plan is judged where pgvigil already holds it. The rules are written here from a reading of
// those procedures (MIT, Brent Ozar Unlimited; THIRD-PARTY-NOTICES.md); no SQL of theirs is used. Where pgvigil reads
// differently it says so on the rule: each statement is judged on its own plan, not its whole batch's; a rule fires
// on any operator that meets it, not on one the engine happened to reach first.

import (
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"
)

// MSSQLMaxPlan is the largest showplan MSSQLPlanWarnings reads, in bytes of the string; a larger one is refused.
const MSSQLMaxPlan = 32 << 20

const showplanNS = "http://schemas.microsoft.com/sqlserver/2004/07/showplan"

// MSSQLWarnInput is what the caller knows beside the plan. A zero value judges every rule that needs nothing else.
type MSSQLWarnInput struct {
	// CostThreshold is the server's 'cost threshold for parallelism' (sys.configurations value). 0 = the five rules
	// that compare with it (expensive key lookup, sort, index spool, table spool, nearly parallel) are not judged.
	CostThreshold int
	// NearParallelPct is how far under the cost threshold a serial plan is 'nearly parallel', in percent (0 = 10).
	NearParallelPct int
	// Now is the server's clock in the zone the plan's statistics dates are written in (UTC on Azure SQL Database);
	// the zero time = the stale statistics rule is not judged.
	Now time.Time
	// Runtime holds the statement's runtime averages; nil = every rule that needs one is not judged.
	Runtime *MSSQLRuntime
}

// MSSQLRuntime is a statement's runtime averages per execution. A nil field was not given: the rule that needs it is
// not judged and says which number it lacked.
type MSSQLRuntime struct {
	Executions    *float64 // completed executions in the window
	AvgCPUMS      *float64 // CPU per execution, ms
	AvgRows       *float64 // rows returned per execution
	AvgWritePages *float64 // logical writes per execution, 8 KB pages
	AvgSpillPages *float64 // pages spilled to tempdb per execution
	AvgCompileMS  *float64 // compile duration per compile, ms (Query Store's average compile duration)
}

// Num returns a pointer to v, for an MSSQLRuntime field.
func Num(v float64) *float64 { return &v }

// MSSQLWarning is one warning on one statement.
type MSSQLWarning struct {
	Code  string // the rule's name (sp_BlitzCache's column name where it has one)
	Row   string // the Darling re-grade row it answers, '#27'
	Stmt  int    // the statement's place in the document, from 1 (as PlanStatsUsed counts statements)
	Plan  int    // the QueryPlan's place inside the statement, from 1 (a cursor statement holds one per operation)
	Node  int    // the operator's NodeId; -1 = the statement as a whole
	Words string // what sp_BlitzCache says, then pgvigil's detail
	Rule  string // where the rule and its threshold come from, 'sp_BlitzCache 8.34 L4941'
}

// MSSQLNotJudged is a rule a statement could not be judged on, and why.
type MSSQLNotJudged struct {
	Code string
	Stmt int
	Why  string
}

// MSSQLMissingIndex is one index the optimizer asked for while it compiled a statement: a hint to weigh, never DDL to
// run as written.
type MSSQLMissingIndex struct {
	Stmt       int     // the statement's place in the document, from 1
	Impact     float64 // the optimizer's estimate of the statement's cost saved, in percent
	Database   string  // brackets taken off
	Schema     string
	Table      string
	Equality   []string // the key columns compared with =
	Inequality []string // the key columns compared otherwise
	Include    []string // the columns the statement reads besides
}

// MSSQLMissingIndexes returns the missing-index requests of every statement in a showplan document, each tied to its
// statement (the behaviour Glenn Berry's missing-index query shows; the fields as sp_BlitzCache 8.34 L4586-4627 reads
// them).
func MSSQLMissingIndexes(plan string) []MSSQLMissingIndex {
	root, err := parseShowplan(plan)
	if err != nil {
		return nil
	}
	var out []MSSQLMissingIndex
	for _, s := range statements(root) {
		for _, qp := range s.plans {
			for _, g := range kidsPath(qp, "MissingIndexes", "MissingIndexGroup") {
				impact, _ := g.num("Impact")
				for _, mi := range kidsPath(g, "MissingIndex") {
					m := MSSQLMissingIndex{Stmt: s.ord, Impact: impact, Database: unbracketName(mi.attr("Database")),
						Schema: unbracketName(mi.attr("Schema")), Table: unbracketName(mi.attr("Table"))}
					for _, cg := range kidsPath(mi, "ColumnGroup") {
						var cols []string
						for _, col := range kidsPath(cg, "Column") {
							cols = append(cols, unbracketName(col.attr("Name")))
						}
						switch cg.attr("Usage") {
						case "EQUALITY":
							m.Equality = append(m.Equality, cols...)
						case "INEQUALITY":
							m.Inequality = append(m.Inequality, cols...)
						case "INCLUDE":
							m.Include = append(m.Include, cols...)
						}
					}
					out = append(out, m)
				}
			}
		}
	}
	return out
}

// unbracketName takes the brackets off a name as a showplan writes it ('[dbo]' -> 'dbo', ']]' -> ']').
func unbracketName(s string) string {
	if len(s) >= 2 && s[0] == '[' && s[len(s)-1] == ']' {
		return strings.ReplaceAll(s[1:len(s)-1], "]]", "]")
	}
	return s
}

// xnode is one element of a showplan document: its local name, its attributes by local name, its children.
type xnode struct {
	name   string
	attrs  map[string]string
	kids   []*xnode
	parent *xnode
}

func (n *xnode) attr(k string) string { return n.attrs[k] }

// flag reads an xs:boolean attribute as either spelling: '1' and 'true' are true; '0', 'false' and absent are false.
func (n *xnode) flag(k string) bool {
	switch strings.ToLower(strings.TrimSpace(n.attrs[k])) {
	case "1", "true":
		return true
	}
	return false
}

// num reads a numeric attribute; ok is false when it is absent or not a number.
func (n *xnode) num(k string) (float64, bool) {
	s, ok := n.attrs[k]
	if !ok {
		return 0, false
	}
	f, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	return f, err == nil
}

// stmtNames are the showplan's statement elements, in the order PlanStatsUsed counts them.
var stmtNames = map[string]bool{"StmtSimple": true, "StmtCond": true, "StmtCursor": true, "StmtReceive": true, "StmtUseDb": true}

// walk visits n's subtree in document order; f returning false skips that node's children.
func (n *xnode) walk(f func(*xnode) bool) {
	if !f(n) {
		return
	}
	for _, k := range n.kids {
		k.walk(f)
	}
}

// own visits n's subtree in document order without entering a nested statement (the statements a non-inlined function
// or a procedure call nests in an estimated plan are judged as statements of their own).
func (n *xnode) own(f func(*xnode)) {
	n.walk(func(d *xnode) bool {
		if d != n && stmtNames[d.name] {
			return false
		}
		f(d)
		return true
	})
}

// all returns the elements of n's own subtree named name (n itself included when it is one).
func (n *xnode) all(name string) []*xnode {
	var out []*xnode
	n.own(func(d *xnode) {
		if d.name == name {
			out = append(out, d)
		}
	})
	return out
}

// has reports whether n's own subtree holds an element named name.
func (n *xnode) has(name string) bool { return len(n.all(name)) > 0 }

// child returns n's first child named name, or nil.
func (n *xnode) child(name string) *xnode {
	for _, k := range n.kids {
		if k.name == name {
			return k
		}
	}
	return nil
}

// path follows child names from n; nil when a step is missing.
func (n *xnode) path(names ...string) *xnode {
	cur := n
	for _, s := range names {
		if cur = cur.child(s); cur == nil {
			return nil
		}
	}
	return cur
}

// parseShowplan reads a showplan document into its element tree; the root must be the showplan namespace's
// ShowPlanXML.
func parseShowplan(plan string) (*xnode, error) {
	if len(plan) > MSSQLMaxPlan {
		return nil, fmt.Errorf("the plan is %d bytes, over the %d read", len(plan), MSSQLMaxPlan)
	}
	dec := xml.NewDecoder(strings.NewReader(plan))
	var root, cur *xnode
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("the plan does not parse: %w", err)
		}
		switch t := tok.(type) {
		case xml.StartElement:
			n := &xnode{name: t.Name.Local, attrs: make(map[string]string, len(t.Attr)), parent: cur}
			for _, a := range t.Attr {
				if a.Name.Space == "" || a.Name.Space == showplanNS {
					n.attrs[a.Name.Local] = a.Value
				}
			}
			if cur == nil {
				if root != nil {
					return nil, errors.New("the plan holds more than one document")
				}
				if t.Name.Local != "ShowPlanXML" || t.Name.Space != showplanNS {
					return nil, fmt.Errorf("the plan's root is %s %s, not the showplan's ShowPlanXML", t.Name.Space, t.Name.Local)
				}
				root = n
			} else {
				cur.kids = append(cur.kids, n)
			}
			cur = n
		case xml.EndElement:
			if cur != nil {
				cur = cur.parent
			}
		}
	}
	if root == nil {
		return nil, errors.New("the plan holds no ShowPlanXML element")
	}
	return root, nil
}

// mstmt is one judged statement: a StmtSimple or StmtCursor with its own plans and operators.
type mstmt struct {
	n        *xnode
	ord      int
	typ      string   // StatementType
	cost     float64  // StatementSubTreeCost; 0 when absent, as sp_BlitzCache sets it (L3364, L3429-3434)
	parallel bool     // any of its own operators parallel (L2451, per statement)
	plans    []*xnode // its own QueryPlan elements
	relops   []*xnode // its own RelOp elements
}

// statements numbers every statement element of the document in order and returns the judged ones.
func statements(root *xnode) []*mstmt {
	var out []*mstmt
	ord := 0
	root.walk(func(d *xnode) bool {
		if !stmtNames[d.name] {
			return true
		}
		ord++
		if d.name != "StmtSimple" && d.name != "StmtCursor" {
			return true // a StmtCond's own condition plan is not judged (sp_BlitzCache reads StmtSimple and StmtCursor)
		}
		s := &mstmt{n: d, ord: ord, typ: d.attr("StatementType")}
		s.cost, _ = d.num("StatementSubTreeCost")
		s.plans = d.all("QueryPlan")
		s.relops = d.all("RelOp")
		for _, r := range s.relops {
			if r.flag("Parallel") {
				s.parallel = true
			}
		}
		out = append(out, s)
		return true
	})
	return out
}

// planOrd is the place of the QueryPlan holding node n among s's own plans, from 1 (0 = none).
func (s *mstmt) planOrd(n *xnode) int {
	for p := n; p != nil; p = p.parent {
		if p.name == "QueryPlan" {
			for i, q := range s.plans {
				if q == p {
					return i + 1
				}
			}
		}
	}
	return 0
}

// statTime reads a StatisticsInfo LastUpdate ('2026-11-16T01:50:12.12', the server's clock, no zone) as a time in UTC
// standing for that clock.
func statTime(s string) (time.Time, bool) {
	t, err := time.Parse("2006-01-02T15:04:05.999999999", strings.TrimSpace(s))
	return t, err == nil
}

// nodeID is a RelOp's NodeId, or -1.
func nodeID(n *xnode) int {
	if v, ok := n.num("NodeId"); ok {
		return int(v)
	}
	return -1
}

// MSSQLPlanWarnings reads one showplan document and returns the warnings of each statement in it, the rules it could
// not judge, and an error when the document is not a showplan it can read (no warnings then).
func MSSQLPlanWarnings(plan string, in MSSQLWarnInput) ([]MSSQLWarning, []MSSQLNotJudged, error) {
	root, err := parseShowplan(plan)
	if err != nil {
		return nil, nil, err
	}
	c := &wctx{in: in}
	for _, s := range statements(root) {
		c.s = s
		for _, r := range rules {
			r(c)
		}
	}
	return c.warns, c.nj, nil
}

// wctx is one statement under judgement and what has been found.
type wctx struct {
	s     *mstmt
	in    MSSQLWarnInput
	warns []MSSQLWarning
	nj    []MSSQLNotJudged
}

func (c *wctx) add(code, row string, at *xnode, words, rule string) {
	w := MSSQLWarning{Code: code, Row: row, Stmt: c.s.ord, Node: -1, Words: words, Rule: rule}
	if at != nil {
		w.Plan = c.s.planOrd(at)
		if at.name == "RelOp" {
			w.Node = nodeID(at)
		}
	}
	c.warns = append(c.warns, w)
}

func (c *wctx) notJudged(code, why string) {
	c.nj = append(c.nj, MSSQLNotJudged{Code: code, Stmt: c.s.ord, Why: why})
}

// ctp is the cost threshold, or 0 with the rule noted as not judged.
func (c *wctx) ctp(code string) int {
	if c.in.CostThreshold <= 0 {
		c.notJudged(code, "no cost threshold for parallelism given")
	}
	return c.in.CostThreshold
}

// rt returns a runtime number, or ok false with the rule noted as not judged.
func (c *wctx) rt(code, what string, pick func(*MSSQLRuntime) *float64) (float64, bool) {
	if c.in.Runtime != nil {
		if p := pick(c.in.Runtime); p != nil {
			return *p, true
		}
	}
	c.notJudged(code, "no "+what+" given")
	return 0, false
}

// kidsPath returns every node reached from n by the child names, each step any child of that name.
func kidsPath(n *xnode, names ...string) []*xnode {
	cur := []*xnode{n}
	for _, s := range names {
		var next []*xnode
		for _, c := range cur {
			for _, k := range c.kids {
				if k.name == s {
					next = append(next, k)
				}
			}
		}
		cur = next
	}
	return cur
}

// udfs returns the distinct function names of the UserDefinedFunction elements in n's subtree, CLR or not.
func udfs(n *xnode, clr bool) []string {
	var out []string
	for _, u := range n.all("UserDefinedFunction") {
		if u.flag("IsClrFunction") != clr {
			continue
		}
		name := u.attr("FunctionName")
		found := false
		for _, o := range out {
			found = found || o == name
		}
		if !found {
			out = append(out, name)
		}
	}
	return out
}

// ops returns the statement's RelOps of one physical operator (and logical operator, when given).
func (s *mstmt) ops(physical, logical string) []*xnode {
	var out []*xnode
	for _, r := range s.relops {
		if r.attr("PhysicalOp") == physical && (logical == "" || r.attr("LogicalOp") == logical) {
			out = append(out, r)
		}
	}
	return out
}

func numOr(n *xnode, k string, def float64) float64 {
	if v, ok := n.num(k); ok {
		return v
	}
	return def
}

// rules is every rule, in the design's order; each looks at c.s and adds what it finds.
var rules = []func(*wctx){
	ruleImplicitConversions, ruleBlitzImplicitConversion, ruleKeyLookupExpensive, ruleLookup, ruleMissingIndexes,
	ruleFunctions, ruleBlitzScalarUDF, ruleComputedFilter, ruleComputedScalar, ruleMSTVF, ruleTVFJoin, ruleTableVariable,
	ruleCursor, ruleNearParallel, ruleForcedSerial, ruleIndexSpool, ruleTableSpool, ruleSortExpensive, ruleRemoteQuery,
	ruleBigSpills,
}

// #22: a PlanAffectingConvert warning naming CONVERT_IMPLICIT (sp_BlitzCache 8.34 L3449-3453); its issue and expression
// in the words (L4259-4260).
func ruleImplicitConversions(c *wctx) {
	var parts []string
	var at *xnode
	for _, qp := range c.s.plans {
		for _, pac := range kidsPath(qp, "Warnings", "PlanAffectingConvert") {
			if strings.Contains(pac.attr("Expression"), "CONVERT_IMPLICIT") {
				if at == nil {
					at = qp
				}
				parts = append(parts, pac.attr("ConvertIssue")+": "+pac.attr("Expression"))
			}
		}
	}
	if at != nil {
		c.add("implicit_conversions", "#22", at, "Implicit Conversions ("+strings.Join(parts, "; ")+")", "sp_BlitzCache 8.34 L3449-3453")
	}
}

// #174: sp_Blitz's check 63 - CONVERT_IMPLICIT anywhere in the statement's plan text and an Index Scan in it
// (sp_Blitz 8.34 L8338-8341); judged per plan, where sp_Blitz looks at its top 20 only.
func ruleBlitzImplicitConversion(c *wctx) {
	conv, scan := false, false
	c.s.n.own(func(d *xnode) {
		for _, v := range d.attrs {
			conv = conv || strings.Contains(v, "CONVERT_IMPLICIT")
		}
		scan = scan || (d.name == "RelOp" && d.attr("PhysicalOp") == "Index Scan")
	})
	if conv && scan {
		c.add("blitz_implicit_conversion", "#174", c.s.n, "Implicit Conversion: comparing two fields that are not the same data type, with an index scan", "sp_Blitz 8.34 check 63, L8338-8341")
	}
}

// lookups are the statement's RelOps reading an index by lookup (a Key Lookup, a RID Lookup's IndexScan Lookup).
func (s *mstmt) lookups() []*xnode {
	var out []*xnode
	for _, r := range s.relops {
		for _, is := range kidsPath(r, "IndexScan") {
			if is.flag("Lookup") {
				out = append(out, r)
				break
			}
		}
	}
	return out
}

// #27: the costliest lookup at least half the statement's cost, the statement at least half the cost threshold (integer
// division, as @ctp is INT) (sp_BlitzCache 8.34 L4941; the lookup's cost L3553-3559).
func ruleKeyLookupExpensive(c *wctx) {
	lk := c.s.lookups()
	if len(lk) == 0 {
		return
	}
	ctp := c.ctp("is_key_lookup_expensive")
	if ctp == 0 {
		return
	}
	var top *xnode
	best := -1.0
	for _, r := range lk {
		if v := numOr(r, "EstimatedTotalSubtreeCost", 0); v > best {
			best, top = v, r
		}
	}
	if c.s.cost >= float64(ctp/2) && best >= c.s.cost*0.5 {
		c.add("is_key_lookup_expensive", "#27", top, fmt.Sprintf("Expensive Key Lookup (%.4g of the statement's %.4g)", best, c.s.cost), "sp_BlitzCache 8.34 L4941")
	}
}

// #176: sp_Blitz's check 118 - any lookup, at any cost (sp_Blitz 8.34 L8402).
func ruleLookup(c *wctx) {
	if lk := c.s.lookups(); len(lk) > 0 {
		c.add("lookup", "#176", lk[0], fmt.Sprintf("RID or Key Lookups (%d): a covering index would avoid them", len(lk)), "sp_Blitz 8.34 check 118, L8402")
	}
}

// #8, #177: the optimizer's missing-index requests (sp_BlitzCache 8.34 L3206, L5010; sp_Blitz 8.34 check 65, L8433).
func ruleMissingIndexes(c *wctx) {
	n := 0
	var at *xnode
	for _, qp := range c.s.plans {
		g := kidsPath(qp, "MissingIndexes", "MissingIndexGroup")
		if len(g) > 0 && at == nil {
			at = qp
		}
		n += len(g)
	}
	if n > 0 {
		c.add("missing_index_count", "#8,#177", at, fmt.Sprintf("Missing Indexes (%d)", n), "sp_BlitzCache 8.34 L3206, L5010")
	}
}

// #31, #32: the scalar functions a Compute Scalar calls - every UDF under an operator that computes a value, the
// operator's whole subtree as sp_BlitzCache's '//' reads it (sp_BlitzCache 8.34 L3535-3542, L5034-5035).
func ruleFunctions(c *wctx) {
	var tsql, clr []string
	var atT, atC *xnode
	for _, r := range c.s.relops {
		if len(kidsPath(r, "ComputeScalar", "DefinedValues", "DefinedValue", "ScalarOperator")) == 0 {
			continue
		}
		for _, f := range udfs(r, false) {
			if !slicesContains(tsql, f) {
				tsql = append(tsql, f)
			}
			if atT == nil {
				atT = r
			}
		}
		for _, f := range udfs(r, true) {
			if !slicesContains(clr, f) {
				clr = append(clr, f)
			}
			if atC == nil {
				atC = r
			}
		}
	}
	if len(tsql) > 0 {
		c.add("function_count", "#31", atT, fmt.Sprintf("Calls %d Function(s): %s", len(tsql), strings.Join(tsql, ", ")), "sp_BlitzCache 8.34 L3535, L3541, L5034")
	}
	if len(clr) > 0 {
		c.add("clr_function_count", "#32", atC, fmt.Sprintf("Calls %d CLR Function(s): %s", len(clr), strings.Join(clr, ", ")), "sp_BlitzCache 8.34 L3536, L3542, L5035")
	}
}

func slicesContains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// #179: sp_Blitz's check 67 - any user-defined function in the plan (sp_Blitz 8.34 L8496).
func ruleBlitzScalarUDF(c *wctx) {
	if u := c.s.n.all("UserDefinedFunction"); len(u) > 0 {
		c.add("blitz_scalar_udf", "#179", c.s.n, "Scalar UDFs: a user-defined function that may inhibit parallelism ("+u[0].attr("FunctionName")+")", "sp_Blitz 8.34 check 67, L8496")
	}
}

// #45: a UDF compared in a Filter (sp_BlitzCache 8.34 L3731-3737, L5048).
func ruleComputedFilter(c *wctx) {
	for _, r := range c.s.relops {
		if len(kidsPath(r, "Filter", "Predicate", "ScalarOperator", "Compare", "ScalarOperator", "UserDefinedFunction")) > 0 && len(udfs(r, false)) > 0 {
			c.add("is_computed_filter", "#45", r, "Filter UDF ("+strings.Join(udfs(r, false), ", ")+")", "sp_BlitzCache 8.34 L3731-3737, L5048")
			return
		}
	}
}

// #43: a Compute Scalar producing a computed column, with a UDF under it (sp_BlitzCache 8.34 L3714-3720, L5046).
func ruleComputedScalar(c *wctx) {
	for _, r := range c.s.relops {
		computed := false
		for _, cr := range kidsPath(r, "ComputeScalar", "DefinedValues", "DefinedValue", "ColumnReference") {
			computed = computed || cr.flag("ComputedColumn")
		}
		if computed && len(udfs(r, false)) > 0 {
			c.add("is_computed_scalar", "#43", r, "Computed Column UDF ("+strings.Join(udfs(r, false), ", ")+")", "sp_BlitzCache 8.34 L3714-3720, L5046")
			return
		}
	}
}

// #63: a table-valued function at the fixed estimate of a multi-statement TVF, 100 or 1 rows (sp_BlitzCache 8.34
// L4142-4146), compared as a number.
func ruleMSTVF(c *wctx) {
	for _, r := range c.s.relops {
		if r.attr("LogicalOp") != "Table-valued function" {
			continue
		}
		if v, ok := r.num("EstimateRows"); ok && (v == 100 || v == 1) {
			c.add("is_mstvf", "#63", r, fmt.Sprintf("MSTVFs (estimated at the fixed %g rows)", v), "sp_BlitzCache 8.34 L4142-4146")
			return
		}
	}
}

// #23: a join with a table-valued function in the statement (sp_BlitzCache 8.34 L3478-3485: both under one operator,
// the statement's top operator holding all).
func ruleTVFJoin(c *wctx) {
	var tvf *xnode
	join := false
	for _, r := range c.s.relops {
		if tvf == nil && r.attr("LogicalOp") == "Table-valued function" {
			tvf = r
		}
		join = join || strings.Contains(r.attr("LogicalOp"), "Join")
	}
	if tvf != nil && join {
		c.add("tvf_join", "#23", tvf, "Function Join", "sp_BlitzCache 8.34 L3478-3485")
	}
}

// #34: a table variable read (an object named @...) (sp_BlitzCache 8.34 L3517-3526).
func ruleTableVariable(c *wctx) {
	for _, o := range c.s.n.all("Object") {
		if t := o.attr("Table"); len(t) > 1 && t[1] == '@' {
			c.add("is_table_variable", "#34", o, "Table Variables ("+t+")", "sp_BlitzCache 8.34 L3517-3526")
			return
		}
	}
}

// #10, #12, #13: a cursor statement, its kind from its own CursorPlan. sp_BlitzCache reads the cursor from plan
// attributes and zero hashes (L4980-4995), which a stored plan does not carry; its 'not forward only' words cannot
// fire (L3632 sets only 1): pgvigil fires when the plan says ForwardOnly false.
func ruleCursor(c *wctx) {
	if c.s.n.name != "StmtCursor" {
		return
	}
	cp := c.s.n.child("CursorPlan")
	if cp == nil {
		c.add("is_cursor", "#10", c.s.n, "Cursor", "pgvigil (sp_BlitzCache 8.34 L4980-4995 reads plan attributes)")
		return
	}
	kind := cp.attr("CursorActualType")
	c.add("is_cursor", "#10", c.s.n, strings.TrimSpace("Cursor "+kind+" "+cp.attr("CursorConcurrency")), "pgvigil (sp_BlitzCache 8.34 L4980-4995 reads plan attributes)")
	if v, ok := cp.attrs["ForwardOnly"]; ok && (strings.EqualFold(v, "false") || v == "0") {
		c.add("cursor_not_forward_only", "#12", c.s.n, "Cursor; not forward only", "pgvigil (sp_BlitzCache 8.34 L3632, L5014: its words never fire)")
	}
	if kind == "Dynamic" {
		c.add("is_cursor_dynamic", "#13", c.s.n, "Cursor; dynamic", "sp_BlitzCache 8.34 L3659-3665")
	}
}

// #16: a serial plan just under the cost threshold (sp_BlitzCache 8.34 L4937, @ctp_threshold_pct L4845).
func ruleNearParallel(c *wctx) {
	if c.s.parallel || c.s.n.name != "StmtSimple" {
		return
	}
	ctp := c.ctp("near_parallel")
	if ctp == 0 {
		return
	}
	pct := c.in.NearParallelPct
	if pct <= 0 {
		pct = 10
	}
	if lo := float64(ctp) * (1 - float64(pct)/100.0); c.s.cost >= lo && c.s.cost <= float64(ctp) {
		c.add("near_parallel", "#16", c.s.n, fmt.Sprintf("Nearly Parallel (cost %.4g, the threshold %d)", c.s.cost, ctp), "sp_BlitzCache 8.34 L4937, L4845")
	}
}

// #26: a serial plan the optimizer could not make parallel, with its reason (sp_BlitzCache 8.34 L3903-3908 reads only
// that a reason exists).
func ruleForcedSerial(c *wctx) {
	if c.s.parallel {
		return
	}
	for _, qp := range c.s.plans {
		if why, ok := qp.attrs["NonParallelPlanReason"]; ok {
			c.add("is_forced_serial", "#26", qp, "Forced Serialization: "+why, "sp_BlitzCache 8.34 L3903-3908")
			return
		}
	}
}

// #55, #56: an eager index spool in a SELECT - its cost (IO * CPU * rebinds, at least 1) a tenth of the statement's,
// the statement over a fifth of the threshold; its rows at least the rows a run returns over the runs (sp_BlitzCache
// 8.34 L4947-4948, the spool L3825-3840). Each spool judged.
func ruleIndexSpool(c *wctx) {
	if c.s.typ != "SELECT" {
		return
	}
	sp := c.s.ops("Index Spool", "Eager Spool")
	if len(sp) == 0 {
		return
	}
	if ctp := c.ctp("is_spool_expensive"); ctp > 0 {
		for _, r := range sp {
			cost := numOr(r, "EstimateIO", 0) * numOr(r, "EstimateCPU", 0) * max(numOr(r, "EstimateRebinds", 0), 1)
			if c.s.cost > float64(ctp/5) && cost >= c.s.cost*0.1 {
				c.add("is_spool_expensive", "#55", r, fmt.Sprintf("Expensive Index Spool (%.4g of the statement's %.4g)", cost, c.s.cost), "sp_BlitzCache 8.34 L4947, L3840")
				break
			}
		}
	}
	rows, ok1 := c.rt("is_spool_more_rows", "rows returned", func(r *MSSQLRuntime) *float64 { return r.AvgRows })
	if !ok1 {
		return
	}
	exec := 1.0
	if c.in.Runtime.Executions != nil && *c.in.Runtime.Executions != 0 {
		exec = *c.in.Runtime.Executions
	}
	for _, r := range sp {
		if n := numOr(r, "EstimateRows", 0); n >= rows/exec {
			c.add("is_spool_more_rows", "#56", r, fmt.Sprintf("Large Index Row Spool (%.4g rows)", n), "sp_BlitzCache 8.34 L4948, L3839")
			break
		}
	}
}

// #57, #58: a lazy table spool in a SELECT - its cost (IO * CPU * rows * rebinds, at least 1) a quarter of the
// statement's, the statement over a fifth of the threshold; its rows times rebinds at least the rows a run returns
// over the runs (sp_BlitzCache 8.34 L4949-4950, the spool L3852-3867). Each spool judged.
func ruleTableSpool(c *wctx) {
	if c.s.typ != "SELECT" {
		return
	}
	sp := c.s.ops("Table Spool", "Lazy Spool")
	if len(sp) == 0 {
		return
	}
	if ctp := c.ctp("is_table_spool_expensive"); ctp > 0 {
		for _, r := range sp {
			cost := numOr(r, "EstimateIO", 0) * numOr(r, "EstimateCPU", 0) * numOr(r, "EstimateRows", 0) * max(numOr(r, "EstimateRebinds", 0), 1)
			if c.s.cost > float64(ctp/5) && cost >= c.s.cost/4 {
				c.add("is_table_spool_expensive", "#57", r, fmt.Sprintf("Expensive Table Spool (%.4g of the statement's %.4g)", cost, c.s.cost), "sp_BlitzCache 8.34 L4949, L3867")
				break
			}
		}
	}
	rows, ok := c.rt("is_table_spool_more_rows", "rows returned", func(r *MSSQLRuntime) *float64 { return r.AvgRows })
	if !ok {
		return
	}
	exec := 1.0
	if c.in.Runtime.Executions != nil && *c.in.Runtime.Executions != 0 {
		exec = *c.in.Runtime.Executions
	}
	for _, r := range sp {
		if n := numOr(r, "EstimateRows", 0) * numOr(r, "EstimateRebinds", 0); n >= rows/exec {
			c.add("is_table_spool_more_rows", "#58", r, fmt.Sprintf("Many Rows Table Spool (%.4g rows)", n), "sp_BlitzCache 8.34 L4950, L3866")
			break
		}
	}
}

// #44: the costliest sort (IO + CPU) at least half the statement's cost, the statement at least half the threshold
// (sp_BlitzCache 8.34 L4942, the sort L3586-3595).
func ruleSortExpensive(c *wctx) {
	so := c.s.ops("Sort", "")
	if len(so) == 0 {
		return
	}
	ctp := c.ctp("is_sort_expensive")
	if ctp == 0 {
		return
	}
	var top *xnode
	best := -1.0
	for _, r := range so {
		if v := numOr(r, "EstimateIO", 0) + numOr(r, "EstimateCPU", 0); v > best {
			best, top = v, r
		}
	}
	if c.s.cost >= float64(ctp/2) && best >= c.s.cost*0.5 {
		c.add("is_sort_expensive", "#44", top, fmt.Sprintf("Expensive Sort (%.4g of the statement's %.4g)", best, c.s.cost), "sp_BlitzCache 8.34 L4942")
	}
}

// #28: the costliest remote operator at least 5 % of the statement's cost (sp_BlitzCache 8.34 L4943, L3570-3576).
func ruleRemoteQuery(c *wctx) {
	var top *xnode
	best := -1.0
	for _, r := range c.s.relops {
		if strings.Contains(r.attr("PhysicalOp"), "Remote") {
			if v := numOr(r, "EstimatedTotalSubtreeCost", 0); v > best {
				best, top = v, r
			}
		}
	}
	if top != nil && best >= c.s.cost*0.05 {
		c.add("is_remote_query_expensive", "#28", top, fmt.Sprintf("Expensive Remote Query (%.4g of the statement's %.4g)", best, c.s.cost), "sp_BlitzCache 8.34 L4943")
	}
}

// #62: over 500 MB spilled per run (pages / 128 > 499) (sp_BlitzCache 8.34 L4952); a runtime number only.
func ruleBigSpills(c *wctx) {
	if v, ok := c.rt("is_big_spills", "spill average", func(r *MSSQLRuntime) *float64 { return r.AvgSpillPages }); ok && v/128 > 499 {
		c.add("is_big_spills", "#62", c.s.n, fmt.Sprintf(">500mb Spills (%.0f MB per run)", v/128), "sp_BlitzCache 8.34 L4952")
	}
}
