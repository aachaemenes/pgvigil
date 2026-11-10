package plans

import (
	"errors"
	"regexp"
	"strconv"
	"strings"
)

// ParseText reads a text plan (EXPLAIN's default format, auto_explain's text format, pg_store_plans' text) into
// the JSON shape EXPLAIN (FORMAT JSON) gives, for the fields the plan rules read: each node's type, relation,
// index, CTE name, join type and strategy, its estimate and actual rows and loops, the filter and the rows it
// removed, the sort method and space, the hash and hash aggregate batches, the heap blocks of a bitmap heap scan,
// the heap fetches, the workers planned and launched, the per-worker sort lines; and at the top the planning and
// execution times, the triggers and JIT's timing. Everything else is left in the text, which the viewer draws.
//
// auto_explain's "Query Text:" (and "Query Parameters:") lines before the plan become "Query Text".
func ParseText(text string) (map[string]any, error) {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	top := map[string]any{}
	type frame struct {
		col   int // the column of the node's text
		node  map[string]any
		kids  int    // children that are not subplans (Outer, Inner)
		label string // a subplan label waiting for the node's next child
	}
	var stack []frame
	var root map[string]any
	var queryLines []string
	inQuery, inJIT := false, false
	var triggers []any

	for _, raw := range lines {
		line := strings.TrimRight(raw, " \t")
		if strings.TrimSpace(line) == "" {
			continue
		}
		col := len(line) - len(strings.TrimLeft(line, " "))
		body := strings.TrimSpace(line)

		if root == nil {
			// before the plan: auto_explain's query text (it may run over several lines) and parameters
			switch {
			case strings.HasPrefix(body, "Query Text:") && col == 0:
				inQuery = true
				queryLines = append(queryLines, strings.TrimSpace(strings.TrimPrefix(body, "Query Text:")))
				continue
			case strings.HasPrefix(body, "Query Parameters:") && col == 0:
				inQuery = false
				top["Query Parameters"] = strings.TrimSpace(strings.TrimPrefix(body, "Query Parameters:"))
				continue
			}
			if !isNodeLine(body) {
				if inQuery {
					queryLines = append(queryLines, line)
				}
				continue
			}
			inQuery = false
			root = parseNode(body)
			stack = append(stack, frame{col: col, node: root})
			continue
		}

		// after the root: a top-level line (column 0), a JIT block line, a child node, or a node property
		if col == 0 && !strings.HasPrefix(body, "->") {
			inJIT = false
			switch {
			case strings.HasPrefix(body, "Planning Time:"):
				setMS(top, "Planning Time", body)
			case strings.HasPrefix(body, "Execution Time:"):
				setMS(top, "Execution Time", body)
			case strings.HasPrefix(body, "Trigger "):
				if t := parseTrigger(body); t != nil {
					triggers = append(triggers, t)
				}
			case body == "JIT:":
				inJIT = true
				top["JIT"] = map[string]any{}
			}
			continue
		}
		if inJIT {
			parseJIT(top["JIT"].(map[string]any), body)
			continue
		}
		if strings.HasPrefix(body, "->") {
			nodeText := strings.TrimSpace(strings.TrimPrefix(body, "->"))
			nodeCol := col + (len(body) - len(nodeText))
			for len(stack) > 1 && stack[len(stack)-1].col >= col {
				stack = stack[:len(stack)-1]
			}
			parent := &stack[len(stack)-1]
			child := parseNode(nodeText)
			if label := parent.label; label != "" {
				parent.label = ""
				rel := "SubPlan"
				if strings.HasPrefix(label, "InitPlan") || strings.HasPrefix(label, "CTE ") {
					rel = "InitPlan"
				}
				child["Parent Relationship"] = rel
				child["Subplan Name"] = label
			} else {
				switch parent.kids {
				case 0:
					child["Parent Relationship"] = "Outer"
				case 1:
					child["Parent Relationship"] = "Inner"
				default:
					child["Parent Relationship"] = "Member"
				}
				parent.kids++
			}
			kids, _ := parent.node["Plans"].([]any)
			parent.node["Plans"] = append(kids, child)
			stack = append(stack, frame{col: nodeCol, node: child})
			continue
		}
		// a property: it belongs to the deepest node whose text starts left of it
		for len(stack) > 1 && stack[len(stack)-1].col >= col {
			stack = stack[:len(stack)-1]
		}
		owner := &stack[len(stack)-1]
		if subplanLabel.MatchString(body) {
			owner.label = body
			continue
		}
		parseProp(owner.node, body)
	}
	if root == nil {
		return nil, errors.New("no plan node found in the text (a node line carries (cost=...) or (actual ...))")
	}
	top["Plan"] = root
	if len(queryLines) > 0 {
		top["Query Text"] = strings.TrimSpace(strings.Join(queryLines, "\n"))
	}
	if triggers != nil {
		top["Triggers"] = triggers
	}
	return top, nil
}

var (
	costRE   = regexp.MustCompile(`\(cost=([0-9.]+)\.\.([0-9.]+) rows=([0-9.]+) width=([0-9]+)\)`)
	actualRE = regexp.MustCompile(`\(actual (?:time=([0-9.]+)\.\.([0-9.]+) )?rows=([0-9.]+) loops=([0-9]+)\)`)
	neverRE  = regexp.MustCompile(`\(never executed\)`)
	// SubPlan 1, InitPlan 1 (returns $0), CTE name: the label line above a subplan's node
	subplanLabel = regexp.MustCompile(`^(SubPlan \d+|InitPlan \d+|CTE \S+)( .*)?$`)
	joinRE       = regexp.MustCompile(`^(Nested Loop|Merge|Hash)(?: (Left|Right|Full|Semi|Anti|Right Semi|Right Anti))? Join$`)
)

func isNodeLine(s string) bool {
	return costRE.MatchString(s) || actualRE.MatchString(s) || neverRE.MatchString(s)
}

// nodeTypes in the order they are tried: a longer name before its prefix.
var nodeTypes = []string{
	"Index Only Scan", "Index Scan", "Bitmap Heap Scan", "Bitmap Index Scan", "Seq Scan", "Sample Scan", "Tid Range Scan", "Tid Scan",
	"Subquery Scan", "Function Scan", "Table Function Scan", "Values Scan", "CTE Scan", "Named Tuplestore Scan", "WorkTable Scan",
	"Foreign Scan", "Custom Scan", "Incremental Sort", "Sort", "Group", "WindowAgg", "Unique", "LockRows", "Limit", "Materialize",
	"Memoize", "Result", "ProjectSet", "Merge Append", "Append", "Recursive Union", "BitmapAnd", "BitmapOr", "Gather Merge", "Gather",
	"Hash", "Aggregate", "SetOp",
}

// parseNode reads a node line's head and its parenthesised numbers.
func parseNode(s string) map[string]any {
	n := map[string]any{}
	head := s
	if i := strings.Index(s, " ("); i >= 0 {
		head = strings.TrimSpace(s[:i])
	}
	if m := costRE.FindStringSubmatch(s); m != nil {
		n["Startup Cost"], n["Total Cost"], n["Plan Rows"], n["Plan Width"] = num(m[1]), num(m[2]), num(m[3]), num(m[4])
	}
	if m := actualRE.FindStringSubmatch(s); m != nil {
		if m[1] != "" {
			n["Actual Startup Time"], n["Actual Total Time"] = num(m[1]), num(m[2])
		}
		n["Actual Rows"], n["Actual Loops"] = num(m[3]), num(m[4])
	} else if neverRE.MatchString(s) {
		n["Actual Rows"], n["Actual Loops"] = 0.0, 0.0
	}
	if strings.HasPrefix(head, "Parallel ") {
		n["Parallel Aware"] = true
		head = strings.TrimPrefix(head, "Parallel ")
	}
	head = strings.TrimPrefix(head, "Async ")
	for _, p := range []string{"Partial ", "Finalize ", "Simple "} {
		if strings.HasPrefix(head, p) {
			n["Partial Mode"] = strings.TrimSpace(p)
			head = strings.TrimPrefix(head, p)
		}
	}
	name, rest := head, ""
	for _, kw := range []string{" using ", " on "} {
		if i := strings.Index(head, kw); i >= 0 && (rest == "" || i < len(name)) {
			name, rest = head[:i], head[i:]
		}
	}
	switch {
	case joinRE.MatchString(name):
		m := joinRE.FindStringSubmatch(name)
		t := m[1] + " Join"
		if m[1] == "Nested Loop" {
			t = "Nested Loop"
		}
		jt := m[2]
		if jt == "" {
			jt = "Inner"
		}
		n["Node Type"], n["Join Type"] = t, jt
	case name == "Nested Loop":
		n["Node Type"], n["Join Type"] = "Nested Loop", "Inner"
	case name == "HashAggregate", name == "GroupAggregate", name == "MixedAggregate", name == "Aggregate":
		n["Node Type"] = "Aggregate"
		n["Strategy"] = map[string]string{"HashAggregate": "Hashed", "GroupAggregate": "Sorted", "MixedAggregate": "Mixed", "Aggregate": "Plain"}[name]
	case name == "HashSetOp", name == "SetOp":
		n["Node Type"] = "SetOp"
	case name == "Insert" || name == "Update" || name == "Delete" || name == "Merge":
		n["Node Type"], n["Operation"] = "ModifyTable", name
	default:
		n["Node Type"] = name
		for _, t := range nodeTypes {
			if name == t || strings.HasPrefix(name, t+" ") {
				n["Node Type"] = t
				if strings.HasSuffix(name, " Backward") {
					n["Scan Direction"] = "Backward"
				}
				break
			}
		}
	}
	// "using idx on rel alias", "on rel alias"
	if strings.HasPrefix(rest, " using ") {
		r := strings.TrimPrefix(rest, " using ")
		idx := r
		if i := strings.Index(r, " on "); i >= 0 {
			idx, rest = r[:i], r[i:]
		} else {
			rest = ""
		}
		n["Index Name"] = idx
	}
	if strings.HasPrefix(rest, " on ") {
		f := strings.Fields(strings.TrimPrefix(rest, " on "))
		if len(f) > 0 {
			obj := f[0]
			switch n["Node Type"] {
			case "CTE Scan":
				n["CTE Name"] = obj
			case "Function Scan":
				n["Function Name"] = obj
			case "Bitmap Index Scan":
				n["Index Name"] = obj
			case "Subquery Scan", "Values Scan", "WorkTable Scan":
				n["Alias"] = obj
			default:
				if i := strings.LastIndex(obj, "."); i > 0 {
					n["Schema"], obj = obj[:i], obj[i+1:]
				}
				n["Relation Name"] = obj
			}
			if len(f) > 1 {
				n["Alias"] = f[1]
			} else if _, ok := n["Alias"]; !ok {
				n["Alias"] = obj
			}
		}
	}
	return n
}

var (
	sortMethodRE = regexp.MustCompile(`Sort Method: (.+?)\s+(Disk|Memory): ([0-9]+)kB`)
	bucketsRE    = regexp.MustCompile(`Buckets: ([0-9]+)(?: \(originally ([0-9]+)\))?\s+Batches: ([0-9]+)(?: \(originally ([0-9]+)\))?\s+Memory Usage: ([0-9]+)kB`)
	hashAggRE    = regexp.MustCompile(`Batches: ([0-9]+)\s+Memory Usage: ([0-9]+)kB(?:\s+Disk Usage: ([0-9]+)kB)?`)
	heapBlocksRE = regexp.MustCompile(`Heap Blocks:(?: exact=([0-9]+))?(?: lossy=([0-9]+))?`)
	workerRE     = regexp.MustCompile(`^Worker ([0-9]+):\s+(.*)$`)
	msRE         = regexp.MustCompile(`([0-9.]+) ms`)
	triggerRE    = regexp.MustCompile(`^Trigger(?: (.+?))??(?: for constraint (.+?))?(?: on (\S+))?: time=([0-9.]+) calls=([0-9]+)$`)
	jitTotalRE   = regexp.MustCompile(`Total ([0-9.]+) ms`)
)

// numeric properties kept as numbers
var numProps = map[string]bool{
	"Rows Removed by Filter": true, "Rows Removed by Join Filter": true, "Rows Removed by Index Recheck": true,
	"Heap Fetches": true, "Workers Planned": true, "Workers Launched": true, "Planned Partitions": true,
}

func parseProp(n map[string]any, body string) {
	if m := workerRE.FindStringSubmatch(body); m != nil {
		w := map[string]any{"Worker Number": num(m[1])}
		if sm := sortMethodRE.FindStringSubmatch(m[2]); sm != nil {
			w["Sort Method"], w["Sort Space Type"], w["Sort Space Used"] = sm[1], sm[2], num(sm[3])
		} else if strings.Contains(m[2], "actual") {
			return
		}
		ws, _ := n["Workers"].([]any)
		n["Workers"] = append(ws, w)
		return
	}
	switch {
	case strings.HasPrefix(body, "Sort Method:"):
		if m := sortMethodRE.FindStringSubmatch(body); m != nil {
			n["Sort Method"], n["Sort Space Type"], n["Sort Space Used"] = m[1], m[2], num(m[3])
		}
		return
	case strings.HasPrefix(body, "Buckets:"):
		if m := bucketsRE.FindStringSubmatch(body); m != nil {
			n["Hash Buckets"], n["Hash Batches"], n["Peak Memory Usage"] = num(m[1]), num(m[3]), num(m[5])
			n["Original Hash Buckets"], n["Original Hash Batches"] = num(or(m[2], m[1])), num(or(m[4], m[3]))
		}
		return
	case strings.HasPrefix(body, "Batches:") || strings.HasPrefix(body, "Planned Partitions:"):
		if m := hashAggRE.FindStringSubmatch(body); m != nil {
			n["HashAgg Batches"], n["Peak Memory Usage"] = num(m[1]), num(m[2])
			if m[3] != "" {
				n["Disk Usage"] = num(m[3])
			}
		}
		return
	case strings.HasPrefix(body, "Heap Blocks:"):
		if m := heapBlocksRE.FindStringSubmatch(body); m != nil {
			if m[1] != "" {
				n["Exact Heap Blocks"] = num(m[1])
			}
			if m[2] != "" {
				n["Lossy Heap Blocks"] = num(m[2])
			}
		}
		return
	}
	k, v, ok := strings.Cut(body, ": ")
	if !ok {
		return
	}
	if numProps[k] {
		n[k] = num(strings.TrimSpace(v))
		return
	}
	if _, set := n[k]; !set {
		n[k] = strings.TrimSpace(v)
	}
}

func parseTrigger(body string) map[string]any {
	m := triggerRE.FindStringSubmatch(body)
	if m == nil {
		return nil
	}
	t := map[string]any{"Time": num(m[4]), "Calls": num(m[5])}
	if m[1] != "" {
		t["Trigger Name"] = m[1]
	}
	if m[2] != "" {
		t["Constraint Name"] = m[2]
	}
	if m[3] != "" {
		t["Relation"] = m[3]
	}
	return t
}

func parseJIT(j map[string]any, body string) {
	k, v, ok := strings.Cut(body, ": ")
	if !ok {
		return
	}
	switch k {
	case "Functions":
		j["Functions"] = num(v)
	case "Timing":
		if m := jitTotalRE.FindStringSubmatch(v); m != nil {
			j["Timing"] = map[string]any{"Total": num(m[1])}
		}
	}
}

func setMS(m map[string]any, k, body string) {
	if x := msRE.FindStringSubmatch(body); x != nil {
		m[k] = num(x[1])
	}
}

func num(s string) float64 {
	f, _ := strconv.ParseFloat(s, 64)
	return f
}

func or(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
