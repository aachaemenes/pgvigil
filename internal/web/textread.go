package web

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/logparse"
	"github.com/aachaemenes/pgvigil/internal/plans"
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

// doorsKey carries a handler's door set to reply, so a request reads one generation of the doors (TestDoorsReadOnce).
type doorsKey struct{}

// withDoors is r carrying ds for reply's text rule.
func withDoors(r *http.Request, ds *doorSet) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), doorsKey{}, ds))
}

// doorsOf is the door set a handler put on r, else the one reply reads now.
func (s *Server) doorsOf(r *http.Request) *doorSet {
	if ds, ok := r.Context().Value(doorsKey{}).(*doorSet); ok && ds != nil {
		return ds
	}
	return s.doorsNow()
}

// tablesIn lists the tables a reply value holds: a table, a map of tables, or a map whose values are either.
func tablesIn(v any) []*table {
	switch x := v.(type) {
	case *table:
		if x != nil {
			return []*table{x}
		}
	case map[string]*table:
		out := make([]*table, 0, len(x))
		for _, t := range x {
			if t != nil {
				out = append(out, t)
			}
		}
		return out
	case map[string]any:
		var out []*table
		for _, e := range x {
			switch y := e.(type) {
			case *table, map[string]*table:
				out = append(out, tablesIn(y)...)
			}
		}
		return out
	}
	return nil
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
	tr, err := s.textRuleOf(r.Context(), s.doorsOf(r))
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
		kind, _ := at(row, "logkind")
		kindS, _ := kind.(string)
		for _, c := range cols {
			switch c.role {
			case "stmt":
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
			case "logmsg":
				if pol == "none" {
					row[c.i] = nil
				}
			case "logdetail":
				switch {
				case row[c.i] == nil || logparse.DetailIsMessage(logparse.Kind(kindS)):
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
	if hj && row[ij] != nil && pr.Plan != nil {
		var v any
		if err := json.Unmarshal(pr.Plan, &v); err == nil {
			row[ij] = v
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
