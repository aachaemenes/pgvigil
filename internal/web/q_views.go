package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// ---- the views store (VIEWS slice A; migration 0259) -------------------------------------------------------------------
// Saved page views (DBA Dash's View drop-down) and dashboards (Erik Darling's custom views) in one store.
//   GET  /api/views[?page=<key>]  the user's personal views and every shared one (no state), each with mine and
//                                 loads_by_default; writable / shared_writable / off say what this user may save here
//   GET  /api/views?id=N          one view with its state, when it is shared or the user's own (404 in words otherwise)
//   POST /api/views               save one: no view_id = create; a view_id with the version read = change it
//   POST /api/views/delete        {view_id, version}
// A page key is 'root:<tab>' or 'instance:<tab>' (the router's tab), a dashboard's 'dashboard'. A page view's state is
// {params, layouts[, range]} (the store refuses any other shape): serve keeps the page's own parameters and drops the
// instance, the tag, the view, a snapshot's time and the range (viewDropped), so a view never moves its user to another instance or window; with keep_range the
// range is kept apart in state.range. Reads: pgvigil.ui_view_list / ui_view_get on the read pool. Writes:
// import_view_save / import_view_delete on the actions door's audit pool (the read pool is read-only) with the
// session's user and client, one ui_view_log row per attempt: done 200, refused 400, forbidden 403, conflict 409 (a
// stale version names the stored one; a taken name), each refusal in words. Shared writes: the users SetViewEditors
// names (pgvigil.yaml views.shared_editors; none = nobody, until B24f's 'change shared views' right replaces it).
//                                                                     -> Server.Views, Server.ViewSave, Server.ViewDelete

// viewBodyMax: a request body; the store refuses a state over 64 KB in words (and logs it), so the body may hold more.
const viewBodyMax = 256 << 10

var (
	viewPageKey = regexp.MustCompile(`^(root|instance):[a-z][a-z0-9_]{0,39}$`)
	// viewEditors: the users who may write shared views (lower case), set by serve from pgvigil.yaml
	viewEditors atomic.Pointer[map[string]bool]
)

// viewDropped: the address parameters a page view never keeps: the instance (i, and ti, a tab's own instance), the
// tag, a view's own number, a snapshot's time (at) and the range.
var viewDropped = []string{"i", "ti", "tag", "view", "at", "w", "from", "to"}

// SetViewEditors names the users who may write shared views (pgvigil.yaml views.shared_editors); none = nobody.
func (s *Server) SetViewEditors(names []string) {
	m := map[string]bool{}
	for _, n := range names {
		if n = strings.ToLower(strings.TrimSpace(n)); n != "" {
			m[n] = true
		}
	}
	viewEditors.Store(&m)
}

func viewEditor(user string) bool {
	m := viewEditors.Load()
	return m != nil && (*m)[strings.ToLower(user)]
}

// viewsOff says why views cannot be saved on this server, "" when they can: like alert rules they ride the UI login and
// the actions door's audit login.
func (s *Server) viewsOff() string {
	switch {
	case s.demo != nil:
		return "saving views needs pgvigil serve with a signed-in user: pgvigil demo -serve keeps none"
	case s.auth == nil:
		return "views are saved behind the UI login: this server runs with -no-login (shared views are listed read-only)"
	case s.actions == nil:
		return "saving views is off on this server (no actions door)"
	case s.actions.audit == nil:
		if s.actions.off != "" {
			return "views are written through the actions door's audit login, and it is off: " + s.actions.off
		}
		return "views are written through the actions door's audit login, and it is not connected"
	}
	return ""
}

// Views is GET /api/views: the list, or one view with ?id=.
func (s *Server) Views(w http.ResponseWriter, r *http.Request) {
	user := ""
	if s.auth != nil {
		user = s.sessionUser(r)
	}
	q := r.URL.Query()
	if v := q.Get("id"); v != "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil || id <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("id must be a view's number"))
			return
		}
		t, err := s.query(r.Context(), `SELECT * FROM pgvigil.ui_view_get($1, $2)`, user, id)
		if err == nil && (t == nil || len(t.Rows) == 0) {
			writeErr(w, http.StatusNotFound, fmt.Errorf("no view %d that you may open: a personal view is its owner's alone", id))
			return
		}
		s.reply(w, r, map[string]any{"view": t}, err)
		return
	}
	var page any // NULL: every page (the list page and the sidebar)
	if p := q.Get("page"); p != "" {
		if p != "dashboard" && !viewPageKey.MatchString(p) {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("page %q is not a page key (root:<tab>, instance:<tab> or dashboard)", p))
			return
		}
		page = p
	}
	t, err := s.query(r.Context(), `SELECT * FROM pgvigil.ui_view_list($1, $2)`, user, page)
	off := s.viewsOff()
	if off == "" && user == "" {
		off = "sign in to save a view"
	}
	if err != nil && s.auth == nil {
		// -no-login checks no pgvigil_auth grant at the start: a serve login without it cannot read the store; the page
		// says so in words instead of an error
		s.log.Warn("views: the list could not be read", "err", err)
		off += "; views cannot be read here: this server's repository login may not read them (" + err.Error() + ")"
		t, err = nil, nil
	}
	sharedOff := ""
	switch {
	case off != "":
		sharedOff = off
	case !viewEditor(user):
		sharedOff = "shared views are written by the users named in pgvigil.yaml views.shared_editors"
	}
	s.reply(w, r, map[string]any{"views": t, "writable": off == "", "shared_writable": sharedOff == "", "off": off,
		"shared_off": sharedOff, "user": user}, err)
}

// ViewSave is POST /api/views.
func (s *Server) ViewSave(w http.ResponseWriter, r *http.Request) { s.viewWrite(w, r, "save") }

// ViewDelete is POST /api/views/delete.
func (s *Server) ViewDelete(w http.ResponseWriter, r *http.Request) { s.viewWrite(w, r, "delete") }

func (s *Server) viewWrite(w http.ResponseWriter, r *http.Request, op string) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.viewsOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, viewBodyMax+1))
	if err != nil || len(raw) > viewBodyMax {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 256 KB"))
		return
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return
	}
	pay, err := viewPayload(op, raw)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	pay["ui_user"], pay["client"], pay["shared_ok"] = user, clientIP(r), viewEditor(user)
	b, _ := json.Marshal(pay)
	fn := "import_view_save"
	if op == "delete" {
		fn = "import_view_delete"
	}
	var out []byte
	// the write outlives a client that hangs up (its log row is kept), never the 15 s
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.`+fn+`($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("view: not written", "op", op, "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	var res struct {
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
		ViewID  *int64 `json:"view_id"`
		Version *int   `json:"version"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("%s answered %q", fn, out))
		return
	}
	s.log.Info("view: attempt", "op", op, "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code, ok := map[string]int{"done": http.StatusOK, "refused": http.StatusBadRequest, "forbidden": http.StatusForbidden,
		"conflict": http.StatusConflict}[res.Outcome]
	if !ok {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("%s answered outcome %q", fn, res.Outcome))
		return
	}
	if code != http.StatusOK {
		writeErr(w, code, errors.New(res.Detail))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(res)
}

// viewPayload reads a save or a delete request into the store's payload: the fields the store takes, a page view's
// parameters cut to the page's own (viewDropped out; with keep_range the range kept apart in state.range). The store
// checks the rest (the page key, the name, the 64 KB cap, the right, the version) and logs every refusal.
func viewPayload(op string, raw []byte) (map[string]any, error) {
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.UseNumber()
	var in map[string]any
	if err := dec.Decode(&in); err != nil || in == nil {
		return nil, errors.New("body: a JSON object")
	}
	keep := []string{"view_id", "version"}
	if op == "save" {
		keep = append(keep, "kind", "page", "name", "description", "folder", "shared", "is_default", "state")
	}
	pay := map[string]any{}
	for _, k := range keep {
		if v, ok := in[k]; ok {
			pay[k] = v
		}
	}
	if op != "save" || pay["kind"] != "page" {
		return pay, nil
	}
	st, ok := pay["state"].(map[string]any)
	if !ok {
		return pay, nil // not an object: the store refuses it in words
	}
	params, _ := st["params"].(map[string]any)
	keepRange, _ := in["keep_range"].(bool)
	rng := map[string]any{}
	for _, k := range viewDropped {
		v, had := params[k]
		if !had {
			continue
		}
		if keepRange && (k == "w" || k == "from" || k == "to") {
			rng[k] = v
		}
		delete(params, k)
	}
	delete(st, "range")
	if len(rng) > 0 {
		st["range"] = rng
	}
	return pay, nil
}
