package web

import (
	"net/http"
)

// B24f's join wiring for saved views: its writes' refusal words beside roles.go's routeWhat, and
// the shared view's admin rule. A personal view is its owner's at any role (it changes nothing others live with: viewer);
// a shared view's save, rename or delete needs admin ('change shared views'), in place of pgvigil.yaml
// views.shared_editors as 0259 planned. compose/run reads the repository only: viewer.
func init() {
	routeWhat["POST /api/views"] = "saving a view"
	routeWhat["POST /api/views/delete"] = "deleting a view"
	routeWhat["POST /api/compose/run"] = "reading a dashboard panel"
}

const sharedViewWhat = "changing a shared view"

// sharedViewWhy: "" when the request's user may write shared views, else the role's words (the views list's shared_off)
func (s *Server) sharedViewWhy(r *http.Request) string {
	if s.roleCan(r)["admin"] {
		return ""
	}
	wh, ok := whoOf(r)
	if !ok {
		wh = s.sessionWho(r)
	}
	if wh.err != nil {
		return "the role could not be read: " + wh.err.Error() // roleOK's 503 words
	}
	return roleWords(sharedViewWhat, needAdmin, wh)
}

// viewSharedRefused is the store's detail when it refuses a shared write without shared_ok (0259 import_view_save /
// import_view_delete): serve answers it in the role's words.
const viewSharedRefused = "changing a shared view needs the admin role"

// viewRoleWords answers the store's refusal of a shared write: the store is the one judge of a shared write (shared_ok
// is roleCan(r)["admin"], true only on a positive admin read: never failing open) and the one writer of ui_view_log, so
// the refused attempt is logged before this answers - 403 in the role's words (B24f's text). A role that could not be
// read never gets here: the route's needViewer gate (roleOK) answers 503 before the handler, and that request is not
// logged (q_views.go); the 503 below only keeps the words right if this is called from another path.
func (s *Server) viewRoleWords(r *http.Request) (int, string) {
	wh, ok := whoOf(r)
	if !ok {
		wh = s.sessionWho(r)
	}
	if wh.err != nil {
		return http.StatusServiceUnavailable, "the role could not be read: " + wh.err.Error()
	}
	return http.StatusForbidden, roleWords(sharedViewWhat, needAdmin, wh)
}
