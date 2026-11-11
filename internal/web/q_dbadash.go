package web

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/dbadash"
)

// The DBADash door's API (task 55): DBADash's own instances and Summary statuses, read from the DBADash repositories the
// configuration names (internal/dbadash) and kept by 0052. The join wires the route in Handler:
//   GET /api/dbadash                          -> s.DBADash: every configured repository and every present instance
//                                                (the tree's DBADash folders and the fleet grid).
//   GET /api/dbadash?repo=<name>              -> the same, narrowed to one repository.
//   GET /api/dbadash?repo=<name>&id=<n>[&from=..&to=..] -> one DBADash instance: its facts, its Summary statuses with
//                                                DBADash's words, and the status changes of the window.
//   GET /api/dbadash?repo=<name>&id=<n>&page=<key>[&from=..&to=..][&snapshot=..] -> one DBADash page (task 75): ONE
//                                                call of the page's DBADash procedure for the instance, made now through
//                                                the repository's read login (internal/dbadash pages.go); the reply is
//                                                the procedure's result sets as grids, DBADash's version and whether it
//                                                is the proven one. A procedure that fails answers 502 with SQL Server's
//                                                own message. ?page=list returns the page list.
// Every part of the folders and the instance page reads a 0052 read function, never a table, but one: 'pgvigil', the
// SQL Server instance pgvigil itself monitors under the same @@SERVERNAME (pgvigil.mssql_instance.server_name equal,
// case-insensitive, to DBADash's Instance), whose actions door (actions_dsn and its actions: list, task 99) the
// DBADash page's Kill, Start and Stop buttons use through /api/mssql/actions/*: no such instance = no button, and the
// reason. ?part= narrows the reply to one part (the tree asks for part=fleet).

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
	if pg := r.URL.Query().Get("page"); pg != "" {
		s.dbadashPage(w, r, repo, idv, pg)
		return
	}
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
		{"pgvigil", sqlDBADashPgvigil, []any{*repo, id}},
	})
}

// sqlDBADashPgvigil is the SQL Server instance pgvigil monitors itself under the DBADash instance's @@SERVERNAME (the
// actions buttons' door); more than one = the lowest instance_id, said by the count.
const sqlDBADashPgvigil = `
SELECT i.instance_id, i.name, count(*) OVER () AS matches
  FROM pgvigil.dbadash_instances d
  JOIN pgvigil.mssql_instance m ON upper(m.server_name) = upper(d.instance)
  JOIN pgvigil.instances i ON i.instance_id = m.instance_id AND i.engine = 'sqlserver'
 WHERE d.repository = $1 AND d.instance_id = $2
 ORDER BY i.instance_id
 LIMIT 1`

// pageTimeout bounds a page's whole reply (the procedure's own bound is dbadash.PageTimeout).
const pageTimeout = 70 * time.Second

// dbadashPage is GET /api/dbadash?repo=&id=&page=: one DBADash procedure called now for one instance.
func (s *Server) dbadashPage(w http.ResponseWriter, r *http.Request, repo *string, idv, page string) {
	if page == "list" {
		s.reply(w, r, struct {
			Pages  []dbadash.PageDef `json:"pages"`
			Proven string            `json:"proven"`
		}{dbadash.Pages, dbadash.ProvenVersion}, nil)
		return
	}
	def, ok := dbadash.PageByKey(page)
	if !ok {
		writeErr(w, http.StatusBadRequest, errors.New("page must be one of the DBADash pages (page=list names them)"))
		return
	}
	if repo == nil {
		writeErr(w, http.StatusBadRequest, errors.New("page needs repo"))
		return
	}
	id, err := strconv.Atoi(idv)
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("id must be a positive DBADash InstanceID"))
		return
	}
	a := dbadash.PageArgs{InstanceID: id}
	if def.Window {
		if _, a.From, a.To, err = params(r, false); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
	}
	if v := r.URL.Query().Get("snapshot"); v != "" && def.Snapshot {
		if a.Snapshot, err = time.Parse(time.RFC3339Nano, v); err != nil {
			writeErr(w, http.StatusBadRequest, errors.New("snapshot must be an RFC 3339 time"))
			return
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), pageTimeout)
	defer cancel()
	out, err := dbadash.Page(ctx, *repo, page, a)
	switch {
	case errors.Is(err, dbadash.ErrNoRepository):
		writeErr(w, http.StatusNotFound, err)
		return
	case err != nil && out.Procedure == "":
		// before the procedure: the connection, the login or the version read
		s.log.Warn("dbadash page: repository not read", "repository", *repo, "page", page, "err", err)
		writeErr(w, http.StatusBadGateway, err)
		return
	case err != nil:
		s.log.Warn("dbadash page: procedure failed", "repository", *repo, "page", page, "procedure", out.Procedure, "err", err)
		writeErr(w, http.StatusBadGateway, err)
		return
	}
	s.reply(w, r, out, nil)
}
