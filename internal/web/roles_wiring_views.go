package web

import (
	"errors"
	"fmt"
	"net/http"
	"regexp"

	"github.com/jackc/pgx/v5"
)

// B24f's join wiring for rel-viewsb: its writes' refusal words beside roles.go's routeWhat, and
// the shared view's admin rule. A personal view is its owner's at any role (it changes nothing others live with: viewer);
// a shared view's save, rename or delete needs admin (Q2: 'change shared views'), in place of pgvigil.yaml
// views.shared_editors as 0259 planned. compose/run reads the repository only: viewer.
func init() {
	routeWhat["POST /api/views"] = "saving a view"
	routeWhat["POST /api/views/delete"] = "deleting a view"
	routeWhat["POST /api/compose/run"] = "reading a dashboard panel"
}

const sharedViewWhat = "changing a shared view"

var viewIDDigits = regexp.MustCompile(`^[0-9]{1,18}$`) // the store's own test of a view_id (0259 import_view_save)

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

// viewRole refuses, below admin, a save that makes a view shared and a save or a delete of one that is shared now -
// read here through ui_view_get (a read error refuses: the check never fails open); the store refuses the same through
// shared_ok. The body's shared and a view_id of plain digits are read as the store's own tests read them (a JSON string
// "true" or "12" too); a view_id in another number form (2e0) is left to the store, which refuses a shared view
// without shared_ok in the same words.
// true = go on.
func (s *Server) viewRole(w http.ResponseWriter, r *http.Request, user string, pay map[string]any) bool {
	if s.roleCan(r)["admin"] {
		return true
	}
	shared := fmt.Sprint(pay["shared"]) == "true"
	if v, ok := pay["view_id"]; ok && !shared {
		if id := fmt.Sprint(v); viewIDDigits.MatchString(id) {
			err := s.pool.QueryRow(r.Context(), `SELECT shared FROM pgvigil.ui_view_get($1, $2::bigint)`, user, id).Scan(&shared)
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				s.log.Warn("view: the role check could not read the view", "view_id", id, "err", err)
				writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("view %s could not be read to check the role: %v", id, err))
				return false
			}
		}
	}
	return !shared || s.roleOK(w, r, needAdmin, sharedViewWhat)
}
