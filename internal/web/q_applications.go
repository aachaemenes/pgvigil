package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
)

// Applications (task 310, migration 0136): which application each server and database serves, its owners and
// contacts. The reads answer every reader; contacts are personal data, so they come only from their own GET, with the
// UI login on, through the ui_ function the serve login may call (never in the list, one application's answer, an
// import's answer or an audit row). The writes go through the actions door's audit login like Admin > Instances',
// with this page's own words when they are off, a body of 64 KB (500 targets of an assign), the source forced
// 'entered' (only 312's import passes another), and one gate per write (appCanEdit: every signed-in user until the
// viewer / operator / admin roles exist).

// appBodyLimit holds an assign of 500 targets (about 30 KB) with room.
const appBodyLimit = 64 << 10

// applicationsOff says why this server takes no application write ("" when it does).
func (s *Server) applicationsOff() string {
	switch {
	case s.demo != nil:
		return "changing applications needs pgvigil serve with a signed-in user (this is pgvigil demo -serve)"
	case s.auth == nil:
		return "changing applications needs the UI login: this server runs with -no-login"
	case s.actions == nil:
		return "changing applications is off on this server: it has no actions door (every change is written through its audit login)"
	case s.actions.audit == nil:
		if s.actions.off != "" {
			return "changing applications goes through the actions door's audit login, and it is off: " + s.actions.off
		}
		return "changing applications goes through the actions door's audit login, and it is not connected"
	}
	return ""
}

// appCanEdit is the one gate of every application write: any signed-in user today (decision E3), the roles' check
// here when they exist ("" = allowed).
func (s *Server) appCanEdit(user string) string {
	if user == "" {
		return "login required"
	}
	return ""
}

// appBody is the writes' door: the header, the page's off words, the login, the gate, a body of appBodyLimit at most.
func (s *Server) appBody(w http.ResponseWriter, r *http.Request) (string, map[string]any, bool) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return "", nil, false
	}
	if why := s.applicationsOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
		return "", nil, false
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return "", nil, false
	}
	if why := s.appCanEdit(user); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
		return "", nil, false
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, appBodyLimit+1))
	if err != nil || len(raw) > appBodyLimit {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: unreadable or over %d KB", appBodyLimit>>10))
		return "", nil, false
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return "", nil, false
	}
	var in map[string]any
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return "", nil, false
	}
	if in == nil { // a body of null decodes to a nil map (review B, m1)
		writeErr(w, http.StatusBadRequest, errors.New("body: a JSON object is required"))
		return "", nil, false
	}
	return user, in, true
}

// appWrite runs one write function of 0136 for the signed-in user, its source forced 'entered'.
func (s *Server) appWrite(w http.ResponseWriter, r *http.Request, fn string) {
	user, in, ok := s.appBody(w, r)
	if !ok {
		return
	}
	in["ui_user"], in["client"], in["source"] = user, clientIP(r), "entered"
	a, raw, err := s.callImport(r.Context(), fn, in)
	if busy := appBusy(err); busy != nil { // task 312: an import's apply holds the write lock (review B, m3)
		writeErr(w, http.StatusConflict, busy)
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	s.answer(w, a, raw, nil)
}

// ApplicationsWrite is POST /api/admin/applications (op add, edit, rename, remove).
func (s *Server) ApplicationsWrite(w http.ResponseWriter, r *http.Request) {
	s.appWrite(w, r, "import_app_application")
}

// ApplicationContactsWrite is POST /api/admin/applications/contacts (op add, edit, remove).
func (s *Server) ApplicationContactsWrite(w http.ResponseWriter, r *http.Request) {
	s.appWrite(w, r, "import_app_contact")
}

// ApplicationsAssignWrite is POST /api/admin/applications/assign (op assign, unassign, mark, unmark over targets).
func (s *Server) ApplicationsAssignWrite(w http.ResponseWriter, r *http.Request) {
	s.appWrite(w, r, "import_app_assign")
}

// ApplicationRoutesWrite is POST /api/admin/applications/routes (op set, remove): a contact's alerts through a
// configured smtp channel (owner-routed alerts, internal/alerts/routes.go).
func (s *Server) ApplicationRoutesWrite(w http.ResponseWriter, r *http.Request) {
	s.appWrite(w, r, "import_app_contact_route")
}

// appID is the {id} of a route, 0 when it is not a whole number.
func appID(r *http.Request) int {
	n, err := strconv.Atoi(r.PathValue("id"))
	if err != nil || n <= 0 {
		return 0
	}
	return n
}

// ApplicationsList is GET /api/applications: every application, its owner team (with the login on), its servers and
// databases, and the page's audit rows.
func (s *Server) ApplicationsList(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	owner := `NULL::text`
	if s.auth != nil {
		owner = `pgvigil.ui_app_owner_team(a.app_id)`
	}
	apps, err := s.query(ctx, `SELECT a.app_id, a.name, a.tier, a.environment, `+owner+` AS owner_team,
	       (SELECT count(DISTINCT x.instance_id) FROM pgvigil.app_databases(a.app_id) x) AS servers,
	       (SELECT count(*) FROM pgvigil.app_databases(a.app_id) x WHERE x.database_name IS NOT NULL AND x.absent_since IS NULL) AS databases,
	       a.version
	  FROM pgvigil.app_applications a ORDER BY lower(a.name)`)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("applications: %w", err))
		return
	}
	audit, err := s.query(ctx, `SELECT at, ui_user, client, op, target, outcome, detail FROM pgvigil.admin_audit
	  WHERE op LIKE 'app\_%' ORDER BY audit_id DESC LIMIT 200`)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("audit: %w", err))
		return
	}
	// an application: tag that is not taken (decision E5): a file's tag (instances.tags: from pgvigil.yaml, or a DBA Dash
	// import's "Application" tag - the row does not say which, so the words name both: the j14 join review, N1) or an
	// older override of the key - the tag view leaves both out, the page names them
	fileTags, err := s.query(ctx, `SELECT i.instance_id, i.name AS instance, t.tag, 'pgvigil.yaml or a DBA Dash import' AS source
	  FROM pgvigil.instances i CROSS JOIN LATERAL unnest(i.tags) AS t(tag)
	 WHERE i.is_active AND EXISTS (SELECT 1 FROM pgvigil.tag_split(t.tag) k WHERE k.key = 'application')   -- the view's own split (review B, m4)
	UNION ALL
	SELECT i.instance_id, i.name, 'application:' || v.value, 'a tag override'
	  FROM pgvigil.instance_tag_overrides o JOIN pgvigil.instances i ON i.instance_id = o.instance_id
	  CROSS JOIN LATERAL unnest(o.vals) AS v(value)
	 WHERE i.is_active AND o.key = 'application'
	 ORDER BY 2, 3`)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("file tags: %w", err))
		return
	}
	off := s.applicationsOff()
	s.reply(w, r, map[string]any{"can_edit": off == "", "why_not": off, "applications": apps, "audit": audit, "file_tags": fileTags}, nil)
}

// ApplicationOne is GET /api/applications/{id}: its fields with each one's source, and its servers and databases
// (own or inherited, absent since, renamed to). No contact field.
func (s *Server) ApplicationOne(w http.ResponseWriter, r *http.Request) {
	ctx, id := r.Context(), appID(r)
	if id == 0 {
		writeErr(w, http.StatusBadRequest, errors.New("an application's id is a whole number"))
		return
	}
	app, err := s.query(ctx, `SELECT a.app_id, a.name, a.description, a.tier, a.environment, a.cmdb_url, a.version, a.created_at, a.created_by,
	       (SELECT jsonb_object_agg(f.field, jsonb_build_object('source', f.source, 'set_at', f.set_at, 'set_by', f.set_by))
	          FROM pgvigil.app_field_source f WHERE f.object_kind = 'application' AND f.object_id = a.app_id) AS sources
	  FROM pgvigil.app_applications a WHERE a.app_id = $1`, id)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("application: %w", err))
		return
	}
	if len(app.Rows) == 0 {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no application %d", id))
		return
	}
	dbs, err := s.query(ctx, `SELECT x.instance_id, i.name AS instance, i.engine, x.database_name, x.own, x.absent_since, x.renamed_to,
	       a.environment, a.source, a.set_at, a.set_by
	  FROM pgvigil.app_databases($1) x
	  JOIN pgvigil.instances i ON i.instance_id = x.instance_id
	  LEFT JOIN pgvigil.app_assignments a ON a.instance_id = x.instance_id AND x.own
	        AND coalesce(a.database_name, '') = coalesce(x.database_name, '')
	 ORDER BY i.name, x.database_name NULLS FIRST`, id)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("databases: %w", err))
		return
	}
	off := s.applicationsOff()
	s.reply(w, r, map[string]any{"can_edit": off == "", "why_not": off, "application": app, "databases": dbs}, nil)
}

// ApplicationContacts is GET /api/applications/{id}/contacts: the contacts and their alert routes, with the UI login on only.
func (s *Server) ApplicationContacts(w http.ResponseWriter, r *http.Request) {
	if s.auth == nil {
		writeErr(w, http.StatusForbidden, errors.New("contacts hidden: the login is off (they are personal data)"))
		return
	}
	id := appID(r)
	if id == 0 {
		writeErr(w, http.StatusBadRequest, errors.New("an application's id is a whole number"))
		return
	}
	ctx := r.Context()
	t, err := s.query(ctx, `SELECT contact_id, role, kind, name, email, phone, cmdb_url, ord FROM pgvigil.ui_app_contacts_of($1)`, id)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("contacts: %w", err))
		return
	}
	// owner-routed alerts: the contacts' routes, and the configured smtp channels a route may go through (never a
	// route's own derived channel)
	routes, err := s.query(ctx, `SELECT route_id, contact_id, contact, channel_name, min_severity, enabled, set_at, set_by
	  FROM pgvigil.ui_app_contact_routes_of($1)`, id)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("routes: %w", err))
		return
	}
	channels, err := s.query(ctx, `SELECT c.name, c.min_severity FROM pgvigil.alert_channels c
	 WHERE c.is_configured AND c.kind = 'smtp' AND c.name NOT LIKE 'contact-%' ORDER BY c.name`)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("channels: %w", err))
		return
	}
	off := s.applicationsOff()
	s.reply(w, r, map[string]any{"can_edit": off == "", "why_not": off, "contacts": t, "routes": routes, "channels": channels}, nil)
}

// ApplicationsUnassigned is GET /api/applications/unassigned: every present database with no application, and the
// databases marked 'not an application' (the page's Unmark).
func (s *Server) ApplicationsUnassigned(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	t, err := s.query(ctx, `SELECT u.instance_id, i.name AS instance, u.engine, u.database_name
	  FROM pgvigil.app_unassigned() u JOIN pgvigil.instances i ON i.instance_id = u.instance_id`)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("unassigned: %w", err))
		return
	}
	marked, err := s.query(ctx, `SELECT m.instance_id, i.name AS instance, i.engine, m.database_name, m.set_at, m.set_by
	  FROM pgvigil.app_not_application m JOIN pgvigil.instances i ON i.instance_id = m.instance_id
	 ORDER BY i.name, m.database_name`)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("marked: %w", err))
		return
	}
	off := s.applicationsOff()
	s.reply(w, r, map[string]any{"can_edit": off == "", "why_not": off, "unassigned": t, "marked": marked}, nil)
}
