package web

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"reflect"
	"regexp"
	"strconv"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/logparse"
	"github.com/aachaemenes/pgvigil/internal/plans"
	"github.com/aachaemenes/pgvigil/internal/textnow"
)

// The statement-text policy AT READ (TEXT-NOW). An instance's query_text policy (full | normalized | none) is applied
// when a row is captured (collect.ApplyTextPolicy), and a later change clears no stored text: an instance moved from
// full to none still holds the texts stored before. So every reply that carries stored statement text applies the
// instance's policy as this request's door set holds it NOW, the capture's own rule again:
//
//	stmt      a statement's text: none = NULL, normalized = the collector's normalized form, full = as stored
//	stmtjson  a JSON value whose "statement" keys are statement texts (a deadlock's processes): stmt on each
//	doc       a document that carries statement text whole - a SQL Server plan, a deadlock graph, a blocked-process
//	          report: full only (the collectors keep these under full only)
//	pgq, pgplan, pgplantext, pgfmt    a PostgreSQL plan row's query, JSON plan, text plan and format: the plan
//	          collector's mask (plans.Mask): none = no plan, normalized = every expression normalized
//	shape     a slow event's statement shape: under none only a procedure's name (the row's obj column) is a shape
//	obj       the object name the shape rule compares with (kept)
//	logkind   a log event's kind_of; logdetail its detail (a server message kind keeps it under every policy, an error's
//	          detail is gone under normalized); logmsg its message (gone under none)
//	inst      the row's instance_id (kept when named, dropped when the tag has no name: "@inst")
//	keep      true on a row that holds no stored statement text (a union's other branch): its columns stay as read
//	setval    a session SET's value: kept for a planner setting (the row's planner column), else under full only - the
//	          capture's rule (collect's sessionsets.go: a custom setting can carry an application's data)
//	planner   whether the row's setting is a planner one (kept)
//	fcheck    a finding's check (its setting or check_name); fdetail, fvalue, ffix its detail, value and fix: for a check
//	          that quotes a statement (findText), the text from the quote on follows the rule, the words before it stay;
//	          fsummary the Summary's cell lines ("<check>: <value> - <detail>"), each by its check
//
// A reply column is tagged in its SQL by its alias, "<name>@<role>"; reply (web.go) applies the rule to every table
// it sends and gives each column back its name, so the pages read the same keys. A row with no instance to place it
// by (an inst column, else the request's own instance=) gets the strictest rule (none). A handler that scans rows
// itself calls textRule's methods.

// textRoleSep separates a reply column's name from its role in a tagged alias.
const textRoleSep = "@"

// textRule is one request's policies, by instance id.
type textRule struct {
	byID map[int]string
	def  string
}

// policy is the instance's policy NOW: full, normalized or none (an unknown instance: none).
func (tr *textRule) policy(id int, known bool) string {
	if !known {
		return "none"
	}
	if p, ok := tr.byID[id]; ok {
		return p
	}
	return "none"
}

// stmt is a stored statement text as the policy shows it now.
func (tr *textRule) stmt(id int, known bool, v any) any {
	s, ok := v.(string)
	if !ok || s == "" {
		return v
	}
	switch tr.policy(id, known) {
	case "none":
		return nil
	case "normalized":
		return collect.NormalizeSQL(s)
	}
	return s
}

// stmtJSON applies stmt to every "statement" key inside a decoded JSON value (a deadlock's processes: each process's
// statement, stored under the policy at capture by xe_shred's policyText).
func (tr *textRule) stmtJSON(id int, known bool, v any) any {
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			if k == "statement" {
				x[k] = tr.stmt(id, known, e)
			} else {
				x[k] = tr.stmtJSON(id, known, e)
			}
		}
	case []any:
		for i, e := range x {
			x[i] = tr.stmtJSON(id, known, e)
		}
	}
	return v
}

// doc is a stored document that carries statement text whole (full only).
func (tr *textRule) doc(id int, known bool, v any) any {
	if v == nil {
		return nil
	}
	if tr.policy(id, known) != "full" {
		return nil
	}
	return v
}

// allFull: every instance this request can name is under full (nothing to change but the column names).
func (tr *textRule) allFull() bool {
	if tr.def != "full" {
		return false
	}
	for _, p := range tr.byID {
		if p != "full" {
			return false
		}
	}
	return true
}

// textRuleOf builds the request's rule from its door set: each instance's policy as doorSet.planPolicy reads it (the
// instance's own, else the file's, else full).
func (s *Server) textRuleOf(ctx context.Context, ds *doorSet) (*textRule, error) {
	tr := &textRule{byID: map[int]string{}, def: ds.planPolicy("")}
	if doorsAllFull(ds) {
		return tr, nil // every policy full (allFull): no instance read, the names back only
	}
	rows, err := s.pool.Query(ctx, `SELECT instance_id, name FROM pgvigil.instances`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int
		var name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, err
		}
		tr.byID[id] = ds.planPolicy(name)
	}
	return tr, rows.Err()
}

// doorsAllFull: every instance's policy on this door set is full (each instance's own, the file's default for the rest).
func doorsAllFull(ds *doorSet) bool {
	if ds.DefaultQT != "" && ds.DefaultQT != "full" {
		return false
	}
	for _, p := range ds.QueryText {
		if p != "" && p != "full" {
			return false
		}
	}
	return true
}

// tablesIn lists the tables a reply value holds: a table, or one inside a map, a slice or a struct's exported fields,
// to textWalkDepth levels (the replies are a table, a map of tables, or a struct or map beside other values, three
// levels at most today; the proof's walk fails on any column name with '@' left in a reply).
func tablesIn(v any) []*table {
	var out []*table
	walkTables(reflect.ValueOf(v), 0, &out)
	return out
}

var tableType = reflect.TypeOf(&table{})

// textWalkDepth bounds the walk (a reply value is a tree; the bound only guards against a cycle).
const textWalkDepth = 16

func walkTables(v reflect.Value, depth int, out *[]*table) {
	if !v.IsValid() || depth > textWalkDepth {
		return
	}
	if v.Type() == tableType {
		if !v.IsNil() {
			*out = append(*out, v.Interface().(*table))
		}
		return
	}
	switch v.Kind() {
	case reflect.Interface, reflect.Pointer:
		if !v.IsNil() {
			walkTables(v.Elem(), depth+1, out)
		}
	case reflect.Map:
		it := v.MapRange()
		for it.Next() {
			walkTables(it.Value(), depth+1, out)
		}
	case reflect.Slice, reflect.Array:
		for i := 0; i < v.Len(); i++ {
			walkTables(v.Index(i), depth+1, out)
		}
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			if v.Type().Field(i).IsExported() {
				walkTables(v.Field(i), depth+1, out)
			}
		}
	}
}

// tagged reports whether a table has a column tagged with a role.
func tagged(t *table) bool {
	for _, c := range t.Columns {
		if strings.Contains(c, textRoleSep) {
			return true
		}
	}
	return false
}

// applyTextNow applies the read rule to every tagged table of a reply value, in place.
func (s *Server) applyTextNow(r *http.Request, v any) error {
	var ts []*table
	for _, t := range tablesIn(v) {
		if tagged(t) {
			ts = append(ts, t)
		}
	}
	if len(ts) == 0 {
		return nil
	}
	// the door set as reply reads it now: a handler that read its own a moment before reads the same policies while the
	// serve runs (the file's, page instances the file's default), so the two reads agree
	tr, err := s.textRuleOf(r.Context(), s.doorsNow())
	if err != nil {
		return err
	}
	// a read of one instance (?instance=N) places a row with no inst column by it
	def, defKnown := 0, false
	if n, err := strconv.Atoi(r.URL.Query().Get("instance")); err == nil && n > 0 {
		def, defKnown = n, true
	}
	for _, t := range ts {
		tr.table(t, def, defKnown)
	}
	return nil
}

// table applies the rule to one table's tagged columns and gives them back their names; a tag with no name (a
// column that only places the row, "@inst") is dropped. A row with no inst column is placed by the request's one
// instance (def), else by none.
func (tr *textRule) table(t *table, def int, defKnown bool) {
	type col struct {
		i          int
		name, role string
	}
	var cols []col
	roleAt := map[string]int{}
	for i, c := range t.Columns {
		name, role, ok := strings.Cut(c, textRoleSep)
		if !ok {
			continue
		}
		cols = append(cols, col{i, name, role})
		if _, seen := roleAt[role]; !seen {
			roleAt[role] = i
		}
	}
	if len(cols) == 0 {
		return
	}
	at := func(row []any, role string) (any, bool) {
		if i, ok := roleAt[role]; ok {
			return row[i], true
		}
		return nil, false
	}
	full := tr.allFull()
	for _, row := range t.Rows {
		if full {
			break
		}
		id, known := def, defKnown
		if v, ok := at(row, "inst"); ok {
			id, known = instID(v)
		}
		pol := tr.policy(id, known)
		// a row that says it holds no stored statement text (a union's other branch, "@keep") is left as read
		if k, ok := at(row, "keep"); ok {
			if b, _ := k.(bool); b {
				continue
			}
		}
		kind, _ := at(row, "logkind")
		kindS, _ := kind.(string)
		for _, c := range cols {
			switch c.role {
			case "stmt":
				// a log event of kind plan: its statement is the plan, kept under full only (applyTextPolicy)
				if kindS == string(logparse.Plan) && pol != "full" {
					row[c.i] = nil
					continue
				}
				row[c.i] = tr.stmt(id, known, row[c.i])
			case "doc":
				row[c.i] = tr.doc(id, known, row[c.i])
			case "stmtjson":
				row[c.i] = tr.stmtJSON(id, known, row[c.i])
			case "shape":
				if pol == "none" && row[c.i] != nil {
					obj, _ := at(row, "obj")
					if o, ok := obj.(string); !ok || o == "" || o != row[c.i] {
						row[c.i] = nil
					}
				}
			case "fdetail", "fvalue", "ffix":
				// a finding's text: only the checks that quote a statement (findText), from the quote on
				ck, _ := at(row, "fcheck")
				cks, _ := ck.(string)
				str, isStr := row[c.i].(string)
				if !textnow.Listed(cks) || !isStr || pol == "full" {
					break
				}
				switch c.role {
				case "fdetail":
					_, row[c.i] = textnow.Finding(cks, "", str, pol)
				case "fvalue":
					row[c.i], _ = textnow.Finding(cks, str, "", pol)
				case "ffix":
					row[c.i] = tr.stmt(id, known, str)
				}
			case "fsummary":
				// the Summary's cell lines, "<check>: <value> - <detail>" each
				switch lines := row[c.i].(type) {
				case []any:
					for k, l := range lines {
						if ls, ok := l.(string); ok {
							lines[k] = textnow.SummaryLine(ls, pol)
						}
					}
				case []string:
					for k, l := range lines {
						lines[k] = textnow.SummaryLine(l, pol)
					}
				}
			case "setval":
				// a session SET's value: a planner setting's is kept under every policy, another's under full only
				if pol != "full" {
					pl, _ := at(row, "planner")
					if b, _ := pl.(bool); !b {
						row[c.i] = nil
					}
				}
			case "logmsg":
				if pol == "none" {
					row[c.i] = nil
				}
			case "logdetail":
				switch {
				// no kind: not a log event's detail (a union's other engine); a message kind: the server's own words
				case row[c.i] == nil || kindS == "" || logparse.DetailIsMessage(logparse.Kind(kindS)):
				case pol == "none", pol == "normalized" && kindS == "error":
					row[c.i] = nil
				case pol == "normalized":
					if s, ok := row[c.i].(string); ok {
						row[c.i] = collect.NormalizeSQL(s)
					}
				}
			}
		}
		tr.pgPlan(row, roleAt, pol)
	}
	// the names back; the place-only columns out
	drop := map[int]bool{}
	for _, c := range cols {
		if c.name == "" {
			drop[c.i] = true
			continue
		}
		t.Columns[c.i] = c.name
	}
	if len(drop) == 0 {
		return
	}
	keep := make([]string, 0, len(t.Columns)-len(drop))
	for i, c := range t.Columns {
		if !drop[i] {
			keep = append(keep, c)
		}
	}
	t.Columns = keep
	for k, row := range t.Rows {
		out := make([]any, 0, len(keep))
		for i, v := range row {
			if !drop[i] {
				out = append(out, v)
			}
		}
		t.Rows[k] = out
	}
}

// pgPlan applies the plan collector's mask (plans.Mask) to a row's PostgreSQL plan columns (pgq, pgplan, pgplantext,
// pgfmt), the capture's rule: none keeps no plan, normalized masks every expression and the query.
func (tr *textRule) pgPlan(row []any, roleAt map[string]int, pol string) {
	iq, hq := roleAt["pgq"]
	ij, hj := roleAt["pgplan"]
	it, ht := roleAt["pgplantext"]
	if (!hq && !hj && !ht) || pol == "full" {
		return
	}
	// a list row that carries the query alone (no plan column): the capture's rule on the query - none keeps no plan
	// row, normalized the query normalized (plans.Mask's own step for the query)
	if !hj && !ht {
		if q, ok := row[iq].(string); ok && q != "" {
			if pol == "none" {
				row[iq] = nil
			} else {
				row[iq] = collect.NormalizeSQL(q)
			}
		}
		return
	}
	var pr plans.Row
	if hq {
		pr.Query, _ = row[iq].(string)
	}
	if ht {
		pr.PlanText, _ = row[it].(string)
	}
	if hj {
		switch p := row[ij].(type) {
		case string:
			pr.Plan = json.RawMessage(p)
		case []byte:
			pr.Plan = json.RawMessage(p)
		case nil:
		default:
			if b, err := json.Marshal(p); err == nil {
				pr.Plan = b
			}
		}
	}
	if i, ok := roleAt["pgfmt"]; ok {
		pr.Format, _ = row[i].(string)
	}
	// a JSON plan read as its text alone (the plan page): masked from that text, as the collector masks the JSON plan
	// (Mask rebuilds the text from the masked JSON; a text that does not parse keeps no plan)
	if pr.Plan == nil && pr.Format == "json" && pr.PlanText != "" {
		pr.Plan = json.RawMessage(pr.PlanText)
	}
	if !collect.MaskPlan(&pr, pol) {
		for _, i := range []int{iq, ij, it} {
			if (i == iq && hq) || (i == ij && hj) || (i == it && ht) {
				row[i] = nil
			}
		}
		return
	}
	if hq && row[iq] != nil {
		row[iq] = pr.Query
	}
	if ht && row[it] != nil {
		row[it] = pr.PlanText
	}
	// the plan back in the form it was read in (a text column stays text, a jsonb column a decoded value)
	if hj && row[ij] != nil && pr.Plan != nil {
		switch row[ij].(type) {
		case string:
			row[ij] = string(pr.Plan)
		case []byte:
			row[ij] = []byte(pr.Plan)
		default:
			var v any
			if err := json.Unmarshal(pr.Plan, &v); err == nil {
				row[ij] = v
			}
		}
	}
}

// instID reads an instance id from a row value (pgx gives int32 for an int column).
func instID(v any) (int, bool) {
	switch x := v.(type) {
	case int32:
		return int(x), true
	case int64:
		return int(x), true
	case int:
		return x, true
	case int16:
		return int(x), true
	case string:
		if n, err := strconv.Atoi(x); err == nil {
			return n, true
		}
	}
	return 0, false
}

// row applies the rule to one row a handler scanned itself: vals[i] has the role roles[i]; the row is the instance
// id's. The values come back in the same order.
func (tr *textRule) row(id int, roles []string, vals []any) []any {
	t := &table{Columns: make([]string, len(roles)), Rows: [][]any{append([]any(nil), vals...)}}
	for i, ro := range roles {
		t.Columns[i] = "c" + strconv.Itoa(i) + textRoleSep + ro
	}
	tr.table(t, id, true)
	return t.Rows[0]
}

// strOf is a text value back as a *string (nil for NULL or a non-text value).
func strOf(v any) *string {
	if s, ok := v.(string); ok {
		return &s
	}
	return nil
}

// textMarkRE is a read's text marker, for a SELECT * over a function whose columns its SQL does not name: a comment
// "/* text: query=stmt, instance_id=inst */" at the end of the SQL; query (web.go) tags those columns of the table it
// returns as an alias would ("query@stmt"), so reply's rule applies to them.
var textMarkRE = regexp.MustCompile(`/\* text: ([a-z_]+=[a-z]+(?:, [a-z_]+=[a-z]+)*) \*/`)

// markText tags the columns a read's text marker names.
func markText(sql string, t *table) {
	m := textMarkRE.FindStringSubmatch(sql)
	if m == nil || t == nil {
		return
	}
	for _, pair := range strings.Split(m[1], ", ") {
		name, role, _ := strings.Cut(pair, "=")
		for i, c := range t.Columns {
			if c == name {
				t.Columns[i] = name + textRoleSep + role
			}
		}
	}
}

// TextPolicy is an instance's query_text policy as this server's doors hold it now (serve gives it to the alert sends:
// alerts.SetTextPolicy).
func (s *Server) TextPolicy(name string) string { return s.doorsNow().planPolicy(name) }

// textNoneWords: why EXPLAIN, EXPLAIN ANALYZE, the index suggestion and its planner check are off for an instance
// whose policy is none now (the lead's T4): they would show or use a statement's text, the text stored before included.
const textNoneWords = `off: this instance's query_text policy is "none": no statement text is shown or used, the text stored before included (EXPLAIN, EXPLAIN ANALYZE and the index suggestion read it)`

// errTextNone is textNoneWords as a refusal.
var errTextNone = errors.New(textNoneWords)

// storeTextWords: the Custom reports page's line while an instance's policy is not full (the lead's T3: the store
// report is the admin's own door, docs/security.html).
const storeTextWords = "A store report reads stored statement text whatever an instance's query_text policy is now: its SQL reads the repository's tables as the reports login (an admin's grant), not through the pages' rule (docs/security.html)."
