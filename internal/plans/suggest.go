package plans

// A suggested index under a statement and under an EXPLAIN (parity3 task 125; pghero's suggested index with its
// reasoning). Suggest reads a plan's JSON form: a sequential scan whose filter compares plain columns of its table
// with a constant or a parameter (=, = ANY of a constant array, <, <=, >, >=, IS NULL) is a candidate for a btree index
// on those columns, the equalities first and one range column last. A cast column is not one (the index would not
// serve it). Each scan of a partitioned table is a partition: the suggestion names the partition. The reasoning names the scan, its estimated (and, after ANALYZE, its
// actual and removed) rows and the conditions used. A LIKE, an OR or an expression is not suggested; the reason says
// which.
//
// Hypo checks one suggestion with the planner: through hypopg on the monitored server (hypopg_create_index makes a
// hypothetical index that lives in the session only), the statement planned before and after, in a read-only
// transaction that is rolled back and with hypopg_reset() before it ends. Without hypopg in that database the result
// says 'not planner-checked'. pgvigil never runs the CREATE INDEX: the text is for the DBA.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// NotChecked is the label of a suggestion the planner has not checked.
const NotChecked = "not planner-checked"

// Suggestion is one suggested index.
type Suggestion struct {
	Table     string   `json:"table"`
	Columns   []string `json:"columns"`
	DDL       string   `json:"ddl"`
	Node      string   `json:"node"`
	PlanRows  float64  `json:"plan_rows"`
	Actual    *float64 `json:"actual_rows,omitempty"`
	Removed   *float64 `json:"rows_removed,omitempty"`
	Why       []string `json:"why"`
	ScanCost  float64  `json:"scan_cost"`
	Condition string   `json:"condition"`
}

// Skipped is a scan whose filter suggested nothing, with the reason.
type Skipped struct {
	Node   string `json:"node"`
	Reason string `json:"reason"`
}

const (
	identPat = `(?:[a-z_][a-z0-9_$]*|"(?:[^"]|"")+")`
	// a cast as EXPLAIN prints it: a type name, quoted or schema-qualified, maybe an array, maybe more than one
	castPat = `(?:::` + identPat + `(?:\.` + identPat + `)?(?: [a-z]+)*(?:\[\])?(?:\([0-9, ]+\))?)`
)

var (
	// a plain column as EXPLAIN prints it: bare, alias-qualified, or double-quoted, maybe in parentheses; no cast
	colRE = regexp.MustCompile(`^\(*(` + identPat + `\.)?(` + identPat + `)\)*$`)
	// a column under a cast: a btree on the column does not serve the cast's result
	castColRE = regexp.MustCompile(`^\(*(?:` + identPat + `\.)?` + identPat + `\)*` + castPat + `+\)*$`)
	// the right-hand side: a constant (a quoted literal, a number, NULL, true / false) or a parameter, maybe cast
	constRE = regexp.MustCompile(`^\(*(?:'(?:[^']|'')*'|-?[0-9]+(?:\.[0-9]+)?|\$[0-9]+|NULL|true|false)\)*` + castPat + `*\)*$`)
	// = ANY of a constant array (IN (...) as EXPLAIN prints it)
	anyRE = regexp.MustCompile(`^ANY \((.+)\)$`)
	opRE  = regexp.MustCompile(`^(.+?)\s+(=|<>|<=|>=|<|>|~~\*?|!~~\*?|IS NULL|IS NOT NULL)(?:\s+(.+))?$`)
)

// Suggest reads a plan's JSON form (NormalizeJSON's object) and returns its suggestions and the scans it skipped.
func Suggest(plan map[string]any) ([]Suggestion, []Skipped) {
	root, _ := plan["Plan"].(map[string]any)
	if root == nil {
		return nil, nil
	}
	var out []Suggestion
	var skipped []Skipped
	seen := map[string]bool{}
	var walk func(n map[string]any)
	walk = func(n map[string]any) {
		if nt, _ := n["Node Type"].(string); nt == "Seq Scan" {
			if s, why := fromScan(n); s != nil {
				k := s.Table + "\x00" + strings.Join(s.Columns, ",")
				if !seen[k] {
					seen[k] = true
					out = append(out, *s)
				}
			} else if why != "" {
				skipped = append(skipped, Skipped{Node: scanName(n), Reason: why})
			}
		}
		if kids, ok := n["Plans"].([]any); ok {
			for _, k := range kids {
				if m, ok := k.(map[string]any); ok {
					walk(m)
				}
			}
		}
	}
	walk(root)
	// the costliest scan first
	sort.SliceStable(out, func(i, j int) bool { return out[i].ScanCost > out[j].ScanCost })
	return out, skipped
}

// unquote returns an identifier as the catalog stores it: a text plan prints "Orders", a JSON plan Orders.
func unquote(s string) string {
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return strings.ReplaceAll(s[1:len(s)-1], `""`, `"`)
	}
	return s
}

// relOf: the scan's table and schema as the catalog stores them ("" = the plan names no schema: no VERBOSE).
func relOf(n map[string]any) (rel, sch string) {
	r, _ := n["Relation Name"].(string)
	sc, _ := n["Schema"].(string)
	return unquote(r), unquote(sc)
}

func scanName(n map[string]any) string {
	rel, _ := n["Relation Name"].(string)
	alias, _ := n["Alias"].(string)
	s := "Seq Scan on " + rel
	if alias != "" && alias != rel {
		s += " " + alias
	}
	return s
}

func num64(v any) (float64, bool) {
	f, ok := v.(float64)
	return f, ok
}

// fromScan: the suggestion of one sequential scan, or why there is none ("" = nothing to say: no filter).
func fromScan(n map[string]any) (*Suggestion, string) {
	rel, sch := relOf(n)
	filter, _ := n["Filter"].(string)
	if rel == "" || filter == "" {
		return nil, ""
	}
	switch {
	case sch == "pg_catalog" || sch == "information_schema" || strings.HasPrefix(sch, "pg_temp") || strings.HasPrefix(sch, "pg_toast"):
		return nil, "a system catalog or temporary table"
	case sch == "" && strings.HasPrefix(rel, "pg_"):
		return nil, "a pg_ name without a schema in the plan: taken as a system catalog"
	}
	alias, _ := n["Alias"].(string)
	alias = unquote(alias)
	conj, ok := splitAnd(filter)
	if !ok {
		return nil, "the filter has an OR: one btree index does not serve it; consider an index per branch"
	}
	var eq, rng, used []string
	var why []string
	for _, c := range conj {
		m := opRE.FindStringSubmatch(c)
		if m == nil {
			why = append(why, fmt.Sprintf("%s: not a column compared with a value", c))
			continue
		}
		lhs, op, rhs := strings.TrimSpace(m[1]), m[2], strings.TrimSpace(m[3])
		cm := colRE.FindStringSubmatch(lhs)
		if cm == nil {
			if castColRE.MatchString(lhs) {
				why = append(why, fmt.Sprintf("%s: the column is cast, so a btree on the column does not serve it (an expression index is the DBA's call)", c))
			} else {
				why = append(why, fmt.Sprintf("%s: an expression, not a plain column (an expression index is the DBA's call)", c))
			}
			continue
		}
		if q := unquote(strings.TrimSuffix(cm[1], ".")); q != "" && q != alias && q != rel {
			why = append(why, fmt.Sprintf("%s: a column of another relation", c))
			continue
		}
		col := quoteIdent(unquote(cm[2]))
		switch op {
		case "IS NULL":
			eq = appendOnce(eq, col)
		case "=":
			if m := anyRE.FindStringSubmatch(rhs); m != nil {
				rhs = m[1] // = ANY of a constant array: an equality for the index
			}
			if !constRE.MatchString(rhs) {
				why = append(why, fmt.Sprintf("%s: compared with another column (a join condition)", c))
				continue
			}
			eq = appendOnce(eq, col)
		case "<", "<=", ">", ">=":
			if !constRE.MatchString(rhs) {
				why = append(why, fmt.Sprintf("%s: compared with another column", c))
				continue
			}
			rng = appendOnce(rng, col)
		case "~~", "~~*", "!~~", "!~~*":
			why = append(why, fmt.Sprintf("%s: a LIKE; a btree serves only a left-anchored pattern (text_pattern_ops), a pg_trgm GIN index serves any: the DBA's call", c))
			continue
		default:
			why = append(why, fmt.Sprintf("%s: %s is not served by a btree", c, op))
			continue
		}
		used = append(used, c)
	}
	cols := eq
	for _, r := range rng {
		if !contains(cols, r) {
			cols = append(cols, r) // one range column, after the equalities
			break
		}
	}
	if len(cols) == 0 {
		if len(why) == 0 {
			return nil, "no condition a btree serves"
		}
		return nil, strings.Join(why, "; ")
	}
	if len(cols) > 4 {
		cols = cols[:4]
	}
	s := &Suggestion{Table: rel, Columns: cols, Node: scanName(n), Condition: strings.Join(used, " AND ")}
	s.PlanRows, _ = num64(n["Plan Rows"])
	s.ScanCost, _ = num64(n["Total Cost"])
	if a, ok := num64(n["Actual Rows"]); ok {
		loops, ok := num64(n["Actual Loops"])
		if !ok || loops < 1 {
			loops = 1
		}
		a *= loops
		s.Actual = &a
	}
	if r, ok := num64(n["Rows Removed by Filter"]); ok {
		loops, ok := num64(n["Actual Loops"])
		if !ok || loops < 1 {
			loops = 1
		}
		r *= loops
		s.Removed = &r
	}
	tbl := quoteIdent(rel)
	if sch != "" {
		tbl = quoteIdent(sch) + "." + tbl
	}
	s.DDL = fmt.Sprintf("CREATE INDEX CONCURRENTLY ON %s (%s)", tbl, strings.Join(cols, ", "))
	s.Why = append(s.Why, fmt.Sprintf("%s reads the whole table and keeps the rows where %s", s.Node, s.Condition))
	s.Why = append(s.Why, fmt.Sprintf("estimated rows out: %.0f (scan cost %.2f)", s.PlanRows, s.ScanCost))
	if s.Actual != nil {
		line := fmt.Sprintf("actual rows out: %.0f", *s.Actual)
		if s.Removed != nil {
			line += fmt.Sprintf(", removed by the filter: %.0f", *s.Removed)
		}
		s.Why = append(s.Why, line)
	}
	if sch == "" {
		s.Why = append(s.Why, "the plan names no schema (EXPLAIN without VERBOSE): the text names the table the statement's search_path finds; qualify it before you run it")
	}
	if len(eq) > 0 && len(rng) > 0 {
		s.Why = append(s.Why, "the equality columns lead, the range column follows: the index finds one range per equality")
	}
	s.Why = append(s.Why, why...)
	return s, ""
}

func appendOnce(xs []string, x string) []string {
	if contains(xs, x) {
		return xs
	}
	return append(xs, x)
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

var simpleIdent = regexp.MustCompile(`^[a-z_][a-z0-9_$]*$`)

// reserved are PostgreSQL's reserved key words (and those that may be a function or type name only): as an
// identifier each must be quoted, as quote_ident does.
var reserved = map[string]bool{}

func init() {
	for _, w := range strings.Fields(`all analyse analyze and any array as asc asymmetric authorization binary both case cast check collate
		collation column concurrently constraint create cross current_catalog current_date current_role current_schema current_time
		current_timestamp current_user default deferrable desc distinct do else end except false fetch for foreign freeze from full
		grant group having ilike in initially inner intersect into is isnull join lateral leading left like limit localtime
		localtimestamp natural not notnull null offset on only or order outer overlaps placing primary references returning right
		select session_user similar some symmetric system_user table tablesample then to trailing true union unique user using
		variadic verbose when where window with`) {
		reserved[w] = true
	}
}

// quoteIdent quotes an identifier as quote_ident does: a lower-case plain name that is not a reserved word stays bare.
func quoteIdent(s string) string {
	if simpleIdent.MatchString(s) && !reserved[s] {
		return s
	}
	return `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
}

// splitAnd splits a filter at its top-level ANDs, outer parentheses removed; false when the filter has a top-level
// OR (or an OR at every level the split reaches).
func splitAnd(f string) ([]string, bool) {
	f = stripOuter(strings.TrimSpace(f))
	parts := splitTop(f, " AND ")
	if len(parts) == 1 {
		if len(splitTop(f, " OR ")) > 1 {
			return nil, false
		}
		return []string{f}, true
	}
	var out []string
	for _, p := range parts {
		sub, ok := splitAnd(p)
		if !ok {
			return nil, false
		}
		out = append(out, sub...)
	}
	return out, true
}

// stripOuter removes parentheses that enclose the whole expression.
func stripOuter(s string) string {
	for len(s) >= 2 && s[0] == '(' && s[len(s)-1] == ')' {
		depth, q, dq := 0, false, false
		whole := true
		for i := 0; i < len(s); i++ {
			switch c := s[i]; {
			case c == '\'' && !dq:
				q = !q
			case c == '"' && !q:
				dq = !dq
			case q || dq:
			case c == '(':
				depth++
			case c == ')':
				depth--
				if depth == 0 && i < len(s)-1 {
					whole = false
				}
			}
			if !whole {
				break
			}
		}
		if !whole {
			return s
		}
		s = strings.TrimSpace(s[1 : len(s)-1])
	}
	return s
}

// splitTop splits s at sep where it is outside parentheses and quotes.
func splitTop(s, sep string) []string {
	var out []string
	depth, q, dq, last := 0, false, false, 0
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '\'' && !dq:
			q = !q
		case c == '"' && !q:
			dq = !dq
		case q || dq:
		case c == '(':
			depth++
		case c == ')':
			depth--
		case depth == 0 && strings.HasPrefix(s[i:], sep):
			out = append(out, strings.TrimSpace(s[last:i]))
			last = i + len(sep)
			i += len(sep) - 1
		}
	}
	return append(out, strings.TrimSpace(s[last:]))
}

// HypoResult is one suggestion checked by the planner.
type HypoResult struct {
	Checked    bool    `json:"checked"`
	Note       string  `json:"note"`
	Hypopg     string  `json:"hypopg,omitempty"`
	CostBefore float64 `json:"cost_before,omitempty"`
	CostAfter  float64 `json:"cost_after,omitempty"`
	Used       bool    `json:"used"`
	IndexName  string  `json:"index_name,omitempty"`
	PlanAfter  string  `json:"plan_after,omitempty"`
}

// ddlRE is the only shape Hypo takes: Suggest's own text (a table, one to four plain or quoted columns).
var ddlRE = regexp.MustCompile(`^CREATE INDEX CONCURRENTLY ON ((?:[a-z_][a-z0-9_$]*|"(?:[^"]|"")+")(?:\.(?:[a-z_][a-z0-9_$]*|"(?:[^"]|"")+"))?) \(((?:[a-z_][a-z0-9_$]*|"(?:[^"]|"")+")(?:, (?:[a-z_][a-z0-9_$]*|"(?:[^"]|"")+")){0,3})\)$`)

// Hypo checks one suggested index with the planner through hypopg on the monitored server: the statement's plan cost
// before and with the hypothetical index, and whether the plan uses it. The statement is planned, never run (its
// generic plan when it has $n parameters).
func Hypo(ctx context.Context, dsn, datname, query, ddl string) (HypoResult, error) {
	m := ddlRE.FindStringSubmatch(ddl)
	if m == nil {
		return HypoResult{}, errors.New("not a suggested index's text")
	}
	query = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(query), ";"))
	if len(query) > MaxStatement {
		return HypoResult{}, fmt.Errorf("the statement is longer than %d characters", MaxStatement)
	}
	sc := ScanSQL(query)
	if ok, why := sc.Explainable(); !ok {
		return HypoResult{}, errors.New(why)
	}
	ctx, cancel := context.WithTimeout(ctx, 2*ExplainTimeout+10*time.Second)
	defer cancel()
	conn, err := Connect(ctx, dsn, datname, "pgvigil-hypo", ExplainTimeout)
	if err != nil {
		return HypoResult{}, fmt.Errorf("the monitoring login could not connect to %s: %w", orDefault(datname), err)
	}
	defer func() { _ = conn.Close(context.WithoutCancel(ctx)) }()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return HypoResult{}, err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	mode := pgx.QueryExecModeExec
	var res HypoResult
	var hsch string
	err = tx.QueryRow(ctx, `SELECT e.extversion, n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'hypopg'`, mode).Scan(&res.Hypopg, &hsch)
	if errors.Is(err, pgx.ErrNoRows) {
		res.Note = fmt.Sprintf("%s: hypopg is not installed in %s", NotChecked, orDefault(datname))
		return res, nil
	}
	if err != nil {
		return HypoResult{}, err
	}
	if sc.MaxParam > 0 {
		if _, err := tx.Exec(ctx, `SET LOCAL plan_cache_mode = force_generic_plan`, mode); err != nil {
			return HypoResult{}, fmt.Errorf("plan_cache_mode: %w", err)
		}
	}
	// each plan is prepared afresh, so the second one is planned with the hypothetical index
	cost := func(name string) (float64, string, error) {
		var plan string
		if sc.MaxParam > 0 {
			if err := prepareOne(ctx, tx, name, query); err != nil {
				return 0, "", explainErr(err, datname, sc.Keyword)
			}
			args := strings.TrimSuffix(strings.Repeat("NULL, ", sc.MaxParam), ", ")
			err = tx.QueryRow(ctx, `EXPLAIN (FORMAT JSON) EXECUTE `+name+`(`+args+`)`, mode).Scan(&plan)
		} else {
			err = tx.QueryRow(ctx, `EXPLAIN (FORMAT JSON) `+query, mode).Scan(&plan)
		}
		if err != nil {
			return 0, "", explainErr(err, datname, sc.Keyword)
		}
		obj, err := NormalizeJSON([]byte(plan))
		if err != nil {
			return 0, "", err
		}
		top, _ := obj["Plan"].(map[string]any)
		c, _ := num64(top["Total Cost"])
		return c, plan, nil
	}
	if res.CostBefore, _, err = cost("pgvigil_hypo_before"); err != nil {
		return HypoResult{}, err
	}
	// hypopg takes the statement without CONCURRENTLY
	hypoDDL := strings.Replace(ddl, "CREATE INDEX CONCURRENTLY ON ", "CREATE INDEX ON ", 1)
	// the extension's own schema: it need not be on the login's search_path
	if err := tx.QueryRow(ctx, `SELECT indexname FROM `+quoteIdent(hsch)+`.hypopg_create_index($1)`, mode, hypoDDL).Scan(&res.IndexName); err != nil {
		return HypoResult{}, fmt.Errorf("hypopg_create_index: %w", err)
	}
	var after string
	res.CostAfter, after, err = cost("pgvigil_hypo_after")
	_, rerr := tx.Exec(context.WithoutCancel(ctx), `SELECT `+quoteIdent(hsch)+`.hypopg_reset()`, mode)
	if err != nil {
		return HypoResult{}, err
	}
	if rerr != nil {
		return HypoResult{}, fmt.Errorf("hypopg_reset: %w", rerr)
	}
	res.Checked = true
	res.Used = usesIndex(after, res.IndexName)
	res.PlanAfter = after
	switch {
	case res.Used && res.CostAfter < res.CostBefore:
		res.Note = fmt.Sprintf("planner-checked with hypopg %s: the plan uses the index, cost %.2f -> %.2f", res.Hypopg, res.CostBefore, res.CostAfter)
	case res.Used:
		res.Note = fmt.Sprintf("planner-checked with hypopg %s: the plan uses the index but its cost does not drop (%.2f -> %.2f)", res.Hypopg, res.CostBefore, res.CostAfter)
	default:
		res.Note = fmt.Sprintf("planner-checked with hypopg %s: the planner does not use the index (cost %.2f stays %.2f): not worth creating for this statement", res.Hypopg, res.CostBefore, res.CostAfter)
	}
	return res, nil
}

// usesIndex: whether a JSON plan names the index in any node.
func usesIndex(planJSON, name string) bool {
	var v any
	if json.Unmarshal([]byte(planJSON), &v) != nil || name == "" {
		return false
	}
	var walk func(any) bool
	walk = func(x any) bool {
		switch t := x.(type) {
		case map[string]any:
			if s, _ := t["Index Name"].(string); s == name {
				return true
			}
			for _, c := range t {
				if walk(c) {
					return true
				}
			}
		case []any:
			for _, c := range t {
				if walk(c) {
					return true
				}
			}
		}
		return false
	}
	return walk(v)
}
