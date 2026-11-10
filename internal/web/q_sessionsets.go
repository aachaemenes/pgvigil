package web

import (
	"net/http"
)

// The session SETs section of the Configuration tab (task 58): GET /api/sessionsets?instance=<id>&[from=&to=]
// (Server.SessionSets) is the last session_sets read's state (ok, or 'not available' with the reason:
// pg_stat_statements absent, or pg_stat_statements.track_utility off) and every SET, SET LOCAL and RESET the
// instance's sessions ran, per role and database, with the calls gained in the window and whether it fires the
// finding "a planner setting changed by the application's sessions" (pgvigil.session_sets_window, 0055). The Compare
// tab reads the same list for its SETs column. No Summary column: the finding reaches the Findings through
// sessionsets_findings.

const sqlSessionSetsState = `
SELECT snapshot_at, status, reason, track_utility FROM pgvigil.session_sets_state WHERE instance_id = $1`

const sqlSessionSetsRows = `SELECT * FROM pgvigil.session_sets_window($1, $2, $3)`

// SessionSets serves the session SETs of one instance over the window.
func (s *Server) SessionSets(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{
		{"state", sqlSessionSetsState, []any{id}},
		{"sets", sqlSessionSetsRows, []any{id, from, to}},
	})
}
