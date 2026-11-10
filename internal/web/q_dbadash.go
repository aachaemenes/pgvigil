package web

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
)

// The DBADash door's API (task 55): DBADash's own instances and Summary statuses, read from the DBADash repositories the
// configuration names (internal/dbadash) and kept by 0052. The join wires the route in Handler:
//   GET /api/dbadash                          -> s.DBADash: every configured repository and every present instance
//                                                (the tree's DBADash folders and the fleet grid).
//   GET /api/dbadash?repo=<name>              -> the same, narrowed to one repository.
//   GET /api/dbadash?repo=<name>&id=<n>[&from=..&to=..] -> one DBADash instance: its facts, its Summary statuses with
//                                                DBADash's words, and the status changes of the window.
// Every part reads a 0052 read function, never a table. ?part= narrows the reply to one part (the tree asks for
// part=fleet).

// dbadashRepo reads repo=<name>: 1..100 characters, the configuration's rule (no '/' or control character).
func dbadashRepo(r *http.Request) (*string, error) {
	v := r.URL.Query().Get("repo")
	if v == "" {
		return nil, nil
	}
	if len(v) > 100 || strings.ContainsAny(v, "/\t\r\n") {
		return nil, errors.New("repo must be a configured DBADash repository name")
	}
	return &v, nil
}

// DBADash is the DBADash folders, the fleet grid and one DBADash instance's page.
func (s *Server) DBADash(w http.ResponseWriter, r *http.Request) {
	repo, err := dbadashRepo(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	idv := r.URL.Query().Get("id")
	if idv == "" {
		s.multiPart(w, r, []part{
			{"repositories", `SELECT * FROM pgvigil.dbadash_repositories() WHERE $1::text IS NULL OR repository = $1`, []any{repo}},
			{"fleet", `SELECT * FROM pgvigil.dbadash_fleet($1)`, []any{repo}},
			{"checks", `SELECT * FROM pgvigil.dbadash_checks()`, nil},
		})
		return
	}
	if repo == nil {
		writeErr(w, http.StatusBadRequest, errors.New("id needs repo"))
		return
	}
	id, err := strconv.Atoi(idv)
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("id must be a positive DBADash InstanceID"))
		return
	}
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"instance", `SELECT * FROM pgvigil.dbadash_instance($1, $2)`, []any{*repo, id}},
		{"statuses", `SELECT * FROM pgvigil.dbadash_statuses($1, $2)`, []any{*repo, id}},
		{"changes", `SELECT * FROM pgvigil.dbadash_changes($1, $2, $3, $4)`, []any{*repo, id, from, to}},
	})
}
