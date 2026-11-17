package web

// The custom report view's own settings (parity set 3, migration 0372: custom_reports.view, one jsonb object): who sees
// a report - its visibility rules by engine, tag and instance (DBA Dash's Visibility..., L84) - and who may open and run
// it - its access, a LIST of role names (DBA Dash's ReportVisibilityRole, L85; Allen's Q160 on DBA Dash's per-feature
// roles or pgvigil's three is open, so the list holds role names, never a fixed three). An empty view ('{}', every
// report before 0372) is visible everywhere and open to every role: such a report renders exactly as before.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"sync"

	"github.com/jackc/pgx/v5/pgconn"
	mssql "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/engines"
)

// reportVisibility: a report is listed on an instance that is included, or that is not excluded and meets the engine
// and the tag rules (each empty = any); under a tag folder when that tag is among the rules (or there are none); on
// the fleet always.
type reportVisibility struct {
	Engines []string `json:"engines,omitempty"` // postgres | sqlserver
	Tags    []string `json:"tags,omitempty"`    // a tag as the tree names it (key:value or key)
	Include []string `json:"include,omitempty"` // instance names, listed whatever the other rules say
	Exclude []string `json:"exclude,omitempty"` // instance names, never listed
}

// reportView is custom_reports.view. Every later key of set 3 (result sets, the pair, the URL label, the layout, the
// links, the charts) is added here with its own check in validView (a picker sits on its parameter, in params).
type reportView struct {
	Visibility *reportVisibility `json:"visibility,omitempty"`
	Access     []string          `json:"access,omitempty"` // role names; empty = every role
	// StatusFromMessages: the run's own messages - PostgreSQL's RAISE NOTICE / INFO, SQL Server's PRINT and an ad hoc
	// RAISERROR (50000) - are the page's status in place of 'Completed' (DBA Dash's ShowInfoMessages, L90); the
	// engine's own warnings are left out as DBA Dash leaves them
	StatusFromMessages bool `json:"status_from_messages,omitempty"`
	// Collections: the collections the report's data comes from, which its Trigger Collection button names (DBA Dash's
	// Associate Collection, L98)
	Collections []string `json:"collections,omitempty"`
}

// reportPicker is a parameter's picker (DBA Dash's Pickers, L95): a list of values (a select), a text box (Enter
// runs the report) or a query whose first column is the value and whose second, when it has one, the words shown. A
// picker on the menu bar sits on the run's own toolbar; the others under Parameters.
type reportPicker struct {
	Kind   string   `json:"kind"`             // list | text | query
	Values []string `json:"values,omitempty"` // list: the values in order
	Query  string   `json:"query,omitempty"`  // query: one read-only statement, run as the report runs, on its target
	Menu   bool     `json:"menu,omitempty"`
}

// validPicker checks a parameter's picker: a list's values (and its default) are values of the parameter's type
func validPicker(p reportParam) error {
	x := p.Picker
	if x == nil {
		return nil
	}
	switch x.Kind {
	case "list":
		if len(x.Values) == 0 || len(x.Values) > 1000 || x.Query != "" {
			return fmt.Errorf("parameter %q: a list picker has 1 to 1000 values and no query", p.Name)
		}
		for _, v := range x.Values {
			if len(v) > 400 || strings.ContainsRune(v, 0) {
				return fmt.Errorf("parameter %q: a picker value is at most 400 characters and holds no NUL", p.Name)
			}
			if strings.TrimSpace(v) == "" {
				continue // the empty item: the parameter's default (DBA Dash's empty key)
			}
			if _, err := paramValue(reportParam{Name: p.Name, Type: p.Type}, &v); err != nil {
				return fmt.Errorf("parameter %q: the picker value %w", p.Name, err)
			}
		}
		if p.Default != nil && strings.TrimSpace(*p.Default) != "" && !slices.Contains(x.Values, *p.Default) {
			return fmt.Errorf("parameter %q: its default %q is not one of its picker's values", p.Name, *p.Default)
		}
	case "text":
		if len(x.Values) > 0 || x.Query != "" {
			return fmt.Errorf("parameter %q: a text picker has no values and no query", p.Name)
		}
	case "query":
		if strings.TrimSpace(x.Query) == "" || len(x.Query) > 20000 || len(x.Values) > 0 {
			return fmt.Errorf("parameter %q: a query picker has its query (at most 20000 characters) and no values", p.Name)
		}
	default:
		return fmt.Errorf("parameter %q: a picker's kind is list, text or query", p.Name)
	}
	return nil
}

// validCollections checks the collections a report names: each one pgvigil collects, of the report's engine (a report
// on the repository may name either engine's)
func validCollections(engine string, names []string) error {
	if len(names) > 50 {
		return errors.New("a report names at most 50 collections")
	}
	for _, c := range names {
		e, ok := engines.EngineOf(c)
		switch {
		case !ok:
			return fmt.Errorf("collections: %q is no collection of pgvigil's", c)
		case engine != "store" && e != engine:
			return fmt.Errorf("collections: %q is a %s collection and the report runs on %s", c, e, engine)
		}
	}
	return nil
}

// noteList keeps a run's own messages when its report asks (status_from_messages): the last maxNotes, each cut at
// noteMax characters; PostgreSQL's arrive on the connection's reader, so the list is locked
type noteList struct {
	mu sync.Mutex
	l  []string
}

const (
	maxNotes = 20
	noteMax  = 1000
)

func (n *noteList) add(s string) {
	if r := []rune(s); len(r) > noteMax {
		s = string(r[:noteMax]) + "..."
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	n.l = append(n.l, s)
	if len(n.l) > maxNotes {
		n.l = n.l[len(n.l)-maxNotes:]
	}
}

// list is the messages kept (nil for a run whose report does not ask)
func (n *noteList) list() []string {
	if n == nil {
		return nil
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	return slices.Clone(n.l)
}

// pg is a PostgreSQL connection's notice handler: RAISE NOTICE and RAISE INFO (the severity as the server names it,
// never localized), not the engine's WARNING or DEBUG lines
func (n *noteList) pg(_ *pgconn.PgConn, x *pgconn.Notice) {
	sev := x.SeverityUnlocalized
	if sev == "" {
		sev = x.Severity
	}
	if sev == "NOTICE" || sev == "INFO" {
		n.add(x.Message)
	}
}

// ms keeps a SQL Server message: PRINT (0) and an ad hoc RAISERROR (50000) at a severity that is no error, as DBA Dash
// keeps them (the engine's own warnings - 'Null value is eliminated by an aggregate' - are no note for the reader)
func (n *noteList) ms(msg any) {
	if e, ok := msg.(mssql.Error); ok && (e.Number == 0 || e.Number == 50000) {
		n.add(e.Message)
	}
}

// validView checks a view's keys as validReport checks params / columns / rules.
func validView(v *reportView) error {
	if x := v.Visibility; x != nil {
		for _, e := range x.Engines {
			if e != "postgres" && e != "sqlserver" {
				return fmt.Errorf("visibility: engine %q is not postgres or sqlserver", e)
			}
		}
		for name, list := range map[string][]string{"tags": x.Tags, "include": x.Include, "exclude": x.Exclude} {
			if len(list) > 1000 {
				return fmt.Errorf("visibility: at most 1000 %s", name)
			}
			for _, s := range list {
				if strings.TrimSpace(s) == "" || len(s) > 400 || strings.ContainsRune(s, 0) {
					return fmt.Errorf("visibility: a %s entry is empty, over 400 characters or holds a NUL", name)
				}
			}
		}
		if len(x.Engines) == 0 && len(x.Tags) == 0 && len(x.Include) == 0 && len(x.Exclude) == 0 {
			v.Visibility = nil // no rule: stored as none
		}
	}
	for _, a := range v.Access {
		if roleRank(a) < 0 {
			return fmt.Errorf("access: %q is not a role (viewer, operator, admin)", a)
		}
	}
	return nil
}

// viewOf reads a stored view; one this server cannot read is the empty view's opposite for access (refused) - a
// report is never opened to every role because its rules could not be read
func viewOf(raw []byte) (reportView, error) {
	var v reportView
	if len(raw) == 0 {
		return v, nil
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		return reportView{Access: []string{"admin"}}, err
	}
	return v, nil
}

// visibleOn says whether a report with this view is listed on the scope: an instance (its name, engine, tags), a tag
// folder (tag), or the fleet (neither).
func visibleOn(v reportView, inst *scopeInstance, tag string) bool {
	x := v.Visibility
	if x == nil {
		return true
	}
	switch {
	case inst != nil:
		if slices.Contains(x.Include, inst.Name) {
			return true
		}
		if slices.Contains(x.Exclude, inst.Name) {
			return false
		}
		if len(x.Engines) > 0 && !slices.Contains(x.Engines, inst.Engine) {
			return false
		}
		if len(x.Tags) > 0 && !slices.ContainsFunc(inst.Tags, func(t string) bool { return slices.Contains(x.Tags, t) }) {
			return false
		}
		return true
	case tag != "":
		return len(x.Tags) == 0 || slices.Contains(x.Tags, tag)
	}
	return true
}

// accessOK says whether the role may open and run a report with this view: an empty list = every role; an admin
// always may (the report is the admins' to change)
func accessOK(v reportView, role string) bool {
	return len(v.Access) == 0 || role == "admin" || slices.Contains(v.Access, role)
}

// accessWords is the refusal of a role outside the list
func accessWords(v reportView) string {
	return "You do not have access to this report: it needs the " + strings.Join(v.Access, " or the ") + " role"
}

// roleOf is the request's role name: every role check open with the login off or on a demo (as roleCan); "" when the
// role could not be read (no access then)
func (s *Server) roleOf(r *http.Request) string {
	if s.auth == nil || s.demo != nil {
		return "admin"
	}
	wh, ok := whoOf(r)
	if !ok {
		wh = s.sessionWho(r)
	}
	if wh.err != nil {
		return ""
	}
	return wh.role
}

// scopeInstance is what visibleOn reads of an instance
type scopeInstance struct {
	Name, Engine string
	Tags         []string
}

// scopeOf reads the instance a request's 'i' names (nil for none)
func (s *Server) scopeOf(ctx context.Context, id int64) (*scopeInstance, error) {
	if id <= 0 {
		return nil, nil
	}
	var x scopeInstance
	err := s.pool.QueryRow(ctx, `SELECT name, engine, tags FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&x.Name, &x.Engine, &x.Tags)
	if err != nil {
		return nil, err
	}
	return &x, nil
}

// filterVisible keeps a report list's rows visible on the scope (the list's 'view' column read per row)
func filterVisible(t *table, inst *scopeInstance, tag string) {
	if t == nil {
		return
	}
	j := slices.Index(t.Columns, "view")
	if j < 0 {
		return
	}
	kept := t.Rows[:0]
	for _, r := range t.Rows {
		raw, _ := json.Marshal(r[j])
		v, err := viewOf(raw)
		if err == nil && visibleOn(v, inst, tag) {
			kept = append(kept, r)
		}
	}
	t.Rows = kept
}
