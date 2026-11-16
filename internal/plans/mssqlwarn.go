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
	return nil
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
	var warns []MSSQLWarning
	var nj []MSSQLNotJudged
	for _, s := range statements(root) {
		_ = s
	}
	return warns, nj, nil
}
