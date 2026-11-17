package web

// The custom report view's own settings (parity set 3, migration 0372: custom_reports.view, one jsonb object): who sees
// a report - its visibility rules by engine, tag and instance (DBA Dash's Visibility..., L84) - and who may open and run
// it - its access, a LIST of role names (DBA Dash's ReportVisibilityRole, L85; Allen's Q160 on DBA Dash's per-feature
// roles or pgvigil's three is open, so the list holds role names, never a fixed three). An empty view ('{}', every
// report before 0372) is visible everywhere and open to every role: such a report renders exactly as before.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"slices"
	"strings"
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
// links, the charts) is added here with its own check in validView.
type reportView struct {
	Visibility *reportVisibility `json:"visibility,omitempty"`
	Access     []string          `json:"access,omitempty"` // role names; empty = every role
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
